#!/bin/bash
# 权限修复与防抖增强版 - 双向实时监控同步脚本
# 解决了高频文件变更导致的同步中断问题

# --- 配置参数 ---
SSH_USER="amei"
SSH_HOST="192.168.1.3"
SSH_PORT="22"
LINUX_DIR="/server/www"
WIN_DIR="D:\\www" # PowerShell/Windows 路径
WIN_CYGDRIVE_PATH="/cygdrive/d/www" # Cygwin 路径 (用于 rsync)
WIN_RSYNC_PATH="\"D:/Program Files (x86)/cwRsync/bin/rsync.exe\"" # 注意引号的使用

LOG_FILE="/var/log/www_sync.log"
LOCK_FILE="/tmp/rsync_www.lock"
PID_FILE="/tmp/www_sync.pid"

# 用于防抖的临时标志文件
LINUX_CHANGE_FLAG="/tmp/linux_change.flag"

### 新增：同步静默功能相关配置 ###
# 用于防止同步回声的状态文件
LAST_SYNC_DIR_FILE="/tmp/www_last_sync_dir"
LAST_SYNC_TIME_FILE="/tmp/www_last_sync_time"
# 在一次同步后，忽略反向“回声”变化的秒数
SILENCE_PERIOD=15

# 普通用户（用于权限修复）
NORMAL_USER="amei"
NORMAL_GROUP="amei"

# --- 日志与锁 ---
# 确保日志目录和文件存在且可写
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" || { echo "错误：无法创建或写入日志文件 $LOG_FILE"; exit 1; }
# 确保当前用户对锁文件有权限
touch "$LOCK_FILE" && rm -f "$LOCK_FILE" || { echo "错误：无法在 /tmp 中创建锁文件"; exit 1; }


log() {
    # tee -a 会将标准输入追加到文件并打印到标准输出
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "$LOG_FILE"
}

# --- 排除列表 ---

# rsync 格式
RSYNC_EXCLUDES=(
    "--exclude=.git/"
    "--exclude=.svn/"
    "--exclude=.idea/"
    "--exclude=.vscode/"
    "--exclude=node_modules/"
    "--exclude=vendor/"
    "--exclude=runtime/"
    # --- 新增规则 ---
    "--exclude=cache/"                 # 1. 排除所有名为 'cache' 的子目录
    "--exclude=/config/database.local.php" # 2. 排除根目录下的特定文件
    "--exclude=*.bak"                  # 3. 排除所有 .bak 文件
    # --- 原有规则 ---
    "--exclude=.env"
    "--exclude=*.log"
    "--exclude=*.tmp"
    "--exclude=*.swp"
    "--exclude=~$*"
)

# inotifywait ERE 正则表达式格式
# 注意：每个模式用 | (或) 分隔
INOTIFY_EXCLUDE_PATTERN='(
    \.git/|
    \.svn/|
    \.idea/|
    \.vscode/|
    node_modules/|
    vendor/|
    runtime/|
    # --- 新增规则 (与 rsync 对应) ---
    cache/|                            # 1. 匹配任何路径下的 'cache/'
    ^config/database\.local\.php$|     # 2. 匹配根目录下精确的文件名 (注意^ $和\.的使用)
    \.bak$|                            # 3. 匹配以 .bak 结尾的文件
    # --- 原有规则 ---
    \.env$|
    \.log$|
    \.tmp$|
    \.swp$|
    ^~\$.*
)'
# 为了可读性，我将正则表达式拆分成了多行。在shell中，这会被合并为一行。
INOTIFY_EXCLUDE_PATTERN=$(echo "$INOTIFY_EXCLUDE_PATTERN" | tr -d ' \n')

# --- 核心功能函数 ---

# 改进的原子锁机制
acquire_lock() {
    local lock_purpose="$1"
    # 使用 noclobber 选项实现原子性操作，防止竞争条件
    if (set -o noclobber; echo "$$" > "$LOCK_FILE") 2> /dev/null; then
        log "LOCK" "成功获取锁: $lock_purpose"
        return 0
    else
        local holder_pid
        holder_pid=$(cat "$LOCK_FILE")
        log "LOCK" "等待锁... (当前持有者 PID: $holder_pid, 目的: $lock_purpose)"
        # 等待，而不是超时放弃。让同步排队执行。
        while ! (set -o noclobber; echo "$$" > "$LOCK_FILE") 2> /dev/null; do
            # 检查持有锁的进程是否还存在，防止死锁
            if ! ps -p "$holder_pid" > /dev/null; then
                log "LOCK" "检测到死锁 (PID $holder_pid 不存在)，强制释放。"
                rm -f "$LOCK_FILE"
            fi
            sleep 1
        done
        log "LOCK" "先前任务完成，已获取锁: $lock_purpose"
        return 0
    fi
}

release_lock() {
    rm -f "$LOCK_FILE"
    log "LOCK" "锁已释放"
}

# --- 权限处理函数 (带忽略功能) ---
fix_linux_permissions() {
    local target_dir="$1"
    shift # 移除第一个参数，剩下的都是要忽略的路径
    local ignored_paths=("$@")

    log "🔧 正在为 Linux 目录 '$target_dir' 应用权限 (用户: $NORMAL_USER, 用户组: $NORMAL_GROUP)"
    # if [ ${#ignored_paths[@]} -gt 0 ]; then
    #     log "    - 忽略以下路径: ${ignored_paths[*]}"
    # fi

    # --- 构建 find 命令的排除参数 ---
    local find_prune_args=()
    if [ ${#ignored_paths[@]} -gt 0 ]; then
        # -path a -o -path b -o -path c
        find_prune_args+=(-path "${ignored_paths[0]}")
        for ((i=1; i<${#ignored_paths[@]}; i++)); do
            find_prune_args+=(-o -path "${ignored_paths[i]}")
        done
        # 完整的排除逻辑: ( -path a -o -path b ) -prune -o <其他操作>
        find_prune_args=( \( "${find_prune_args[@]}" \) -prune -o )
    fi
    
    local SUDO_CMD=""
    if [ "$(id -u)" -ne 0 ]; then SUDO_CMD="sudo"; fi

    # --- 执行带排除功能的 chown 和 chmod ---
    # shellcheck disable=SC2211
    find "$target_dir" "${find_prune_args[@]}" -exec $SUDO_CMD chown "$NORMAL_USER:$NORMAL_GROUP" {} +
    
    # shellcheck disable=SC2211
    find "$target_dir" "${find_prune_args[@]}" -type d -exec $SUDO_CMD chmod 755 {} +
    
    # shellcheck disable=SC2211
    find "$target_dir" "${find_prune_args[@]}" -type f -exec $SUDO_CMD chmod 644 {} +

    log "🔩 Linux 权限已应用"
}

sync_linux_to_win() {
    if ! acquire_lock "Linux → Windows"; then return; fi
    log "SYNC" "🔄 开始同步: Linux → Windows"
    
    local rsync_output_file
    rsync_output_file=$(mktemp /tmp/rsync_linux_out.XXXXXX)

    # rsync 命令本身不变 (为简洁起见，省略输出重定向和日志解析)
    # shellcheck disable=SC2068
    rsync -avzi --no-owner --no-group --delete \
          -e "ssh -p $SSH_PORT" \
          --rsync-path="$WIN_RSYNC_PATH" \
          "${RSYNC_EXCLUDES[@]}" \
          "$LINUX_DIR/" \
          "$SSH_USER@$SSH_HOST:$WIN_CYGDRIVE_PATH/" > "$rsync_output_file" 2>&1
    local exit_code=$?
    rm -f "$rsync_output_file" # 清理临时文件

    if [ $exit_code -eq 0 ]; then
        log "SYNC" "✅ 同步成功: Linux → Windows"
        ### 新增：记录本次成功的同步方向和时间 ###
        echo "L2W" > "$LAST_SYNC_DIR_FILE"
        date +%s > "$LAST_SYNC_TIME_FILE"
    elif [ $exit_code -eq 23 ]; then # 部分文件传输错误
        log "SYNC" "⚠️ 部分文件同步失败 (代码 23): Linux → Windows"
    else
        log "SYNC" "❌ 同步失败 [代码 $exit_code]: Linux → Windows"
    fi
 
    release_lock
}


sync_win_to_linux() {
    if ! acquire_lock "Windows → Linux"; then return; fi
    log "SYNC" "🔄 开始同步: Windows → Linux"
    
    local rsync_output_file
    rsync_output_file=$(mktemp /tmp/rsync_win_out.XXXXXX)

    # shellcheck disable=SC2068
    rsync -avzi --no-owner --no-group --delete \
          -e "ssh -p $SSH_PORT" \
          --rsync-path="$WIN_RSYNC_PATH" \
          "${RSYNC_EXCLUDES[@]}" \
          "$SSH_USER@$SSH_HOST:$WIN_CYGDRIVE_PATH/" \
          "$LINUX_DIR/" > "$rsync_output_file" 2>&1
    local exit_code=$?
    rm -f "$rsync_output_file" # 清理临时文件
    
    if [ $exit_code -eq 0 ]; then
        log "SYNC" "✅ 同步成功: Windows → Linux"

        ### 新增：记录本次成功的同步方向和时间 ###
        echo "W2L" > "$LAST_SYNC_DIR_FILE"
        date +%s > "$LAST_SYNC_TIME_FILE"

        # 定义要忽略权限检查的目录路径 (相对于 $LINUX_DIR)
        # 注意：这里的路径是 find 命令能理解的路径
        local ignored_paths=(
            "$LINUX_DIR/.git"
            "$LINUX_DIR/node_modules"
            "$LINUX_DIR/vendor"
            "$LINUX_DIR/storage/logs"  # 示例：Laravel 的日志目录
            "$LINUX_DIR/bootstrap/cache" # 示例：Laravel 的缓存目录
            "$LINUX_DIR/runtime"
            "$LINUX_DIR/web/temp"
            # 在这里添加更多你需要忽略的完整路径
        )

        # --- 构建 find 命令的排除参数 ---
        local find_prune_args=()
        if [ ${#ignored_paths[@]} -gt 0 ]; then
            # ( -path a -o -path b ) -prune -o
            local prune_conditions=(-path "${ignored_paths[0]}")
            for ((i=1; i<${#ignored_paths[@]}; i++)); do
                prune_conditions+=(-o -path "${ignored_paths[i]}")
            done
            find_prune_args=( \( "${prune_conditions[@]}" \) -prune -o )
        fi
        
        # 权限修复逻辑保持不变
        # 使用 find 命令检查是否有文件的所有者或组不匹配
        # 新增了 -prune 参数来忽略指定目录
        # shellcheck disable=SC2211
        if [ -n "$(find "$LINUX_DIR" "${find_prune_args[@]}" -not \( -user "$NORMAL_USER" -and -group "$NORMAL_GROUP" \) -print -quit)" ]; then
            log "PERMS" "🔩 检测到权限不匹配，开始修复..."
            fix_linux_permissions "$LINUX_DIR" "${ignored_paths[@]}"
        else
            log "PERMS" "🔩 权限检查通过，无需修复。"
        fi
    elif [ $exit_code -eq 23 ]; then
        log "SYNC" "⚠️ 部分文件同步失败 (代码 23): Windows → Linux"
    else
        log "SYNC" "❌ 同步失败 [代码 $exit_code]: Windows → Linux"
    fi


    release_lock
}


# --- 监控与触发器 ---

# ★★★ 关键改进：Linux 监控与防抖触发器 ★★★
monitor_linux_changes() {
    log "INFO" "🔍 [L-MON] 开始监控 Linux 目录: $LINUX_DIR"
    # 步骤1: 侦听事件并“举旗”
    inotifywait -m -r -q -e create,delete,modify,move \
                --excludei "$INOTIFY_EXCLUDE_PATTERN" \
                "$LINUX_DIR" |
    while read -r path action file; do
        # 任何事件都只做一件事：创建标志文件
        touch "$LINUX_CHANGE_FLAG"
    done
}

# ★★★ 关键修正：更健壮的“后沿触发”防抖逻辑 ★★★
debounce_and_sync_linux() {
    log "INFO" "🚀 [L-SYNC] 防抖同步服务已启动 (后沿触发模式)"
    while true; do
        # 1. 等待，直到第一个变化发生（标志文件出现）
        while [ ! -f "$LINUX_CHANGE_FLAG" ]; do
            sleep 0.5 # 短暂休眠，降低 CPU 占用
        done

        # 2. 第一个变化已捕获。现在我们等待系统“安静下来”。
        #    只要在我们的“安静期”（例如 2 秒）内仍有变化，就继续循环。
        log "EVENT" "📢 检测到 Linux 变化，进入 2 秒稳定期..."
        
        while [ -f "$LINUX_CHANGE_FLAG" ]; do
            rm -f "$LINUX_CHANGE_FLAG"
            sleep 2
        done

         ### 新增：检查是否需要“同步静默” ###
        local last_dir=""
        local last_time=0
        # 读取上一次同步的状态
        if [ -f "$LAST_SYNC_DIR_FILE" ]; then last_dir=$(cat "$LAST_SYNC_DIR_FILE"); fi
        if [ -f "$LAST_SYNC_TIME_FILE" ]; then last_time=$(cat "$LAST_SYNC_TIME_FILE"); fi
        
        local current_time
        current_time=$(date +%s)
        
        # 如果上一次同步是 W→L，并且发生时间在静默期内，则跳过本次同步
        if [[ "$last_dir" == "W2L" && $((current_time - last_time)) -lt $SILENCE_PERIOD ]]; then
            log "SILENCE" "🔇 [L-SYNC] 忽略 Linux 变化，因为它可能是由最近的 W→L 同步引起的。"
            continue # 直接进入下一次循环，跳过本次同步
        fi

        log "EVENT" "🟢 文件系统已稳定，执行同步操作。"
        sync_linux_to_win
    done
}

### 最终修复版：带有“二次验证”逻辑的 Windows 监控函数 ###
monitor_windows_changes() {
    log "INFO" "🔍 [W-MON] 启动 Windows 目录监控 (二次验证模式，间隔 10s)"
    
    local previous_state=""
    # 新增状态变量，用于存储待验证的潜在回声状态
    local potential_echo_state="" 

    # 辅助函数，避免代码重复
    get_windows_state() {
        ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
            "powershell -Command \"Get-ChildItem -Recurse -Path '$WIN_DIR' -Exclude @('.git', '.svn', '.idea', '.vscode', 'node_modules', 'vendor', 'runtime', '*.log', '*.tmp', '.env', '*.swp', '~\$*') | Select-Object FullName, LastWriteTime, Length | Sort-Object FullName | ConvertTo-Json -Compress\"" 2>/dev/null
    }

    # 首次运行时初始化基准状态
    previous_state=$(get_windows_state)
    log "INFO" "[W-MON] Windows 目录状态初始化完成。"

    while true; do
        sleep 10 # 固定的轮询间隔
        
        local current_state
        current_state=$(get_windows_state)

        if [ -z "$current_state" ]; then
            log "WARN" "⚠️ [W-MON] 无法获取 Windows 目录状态，15秒后重试。"
            sleep 5 # 额外的等待
            continue
        fi

        # 如果状态无变化，则重置“待验证”状态并继续
        if [ "$previous_state" == "$current_state" ]; then
            potential_echo_state="" # 系统稳定，清除待验证标记
            continue
        fi

        # --- 状态有变化，进入核心判断逻辑 ---

        # 检查是否是 L->W 同步造成的回声
        local last_dir=""
        local last_time=0
        if [ -f "$LAST_SYNC_DIR_FILE" ]; then last_dir=$(cat "$LAST_SYNC_DIR_FILE"); fi
        if [ -f "$LAST_SYNC_TIME_FILE" ]; then last_time=$(cat "$LAST_SYNC_TIME_FILE"); fi
        local time_now=$(date +%s)

        is_in_silence_period=false
        if [[ "$last_dir" == "L2W" && $((time_now - last_time)) -lt $SILENCE_PERIOD ]]; then
            is_in_silence_period=true
        fi

        # --- 决策树 ---
        # 场景1：当前变化发生在静默期内 -> 可能是回声，进入“待验证”
        if $is_in_silence_period && [ -z "$potential_echo_state" ]; then
            log "SILENCE" "🔇 [W-MON] 检测到潜在回声。进入二次验证模式..."
            potential_echo_state="$current_state"
            previous_state="$current_state" # 更新基准以检测下一次变化
            continue

        # 场景2：之前已进入“待验证”，且当前状态与“待验证”时一致 -> 确认是纯回声，忽略
        elif [ -n "$potential_echo_state" ] && [ "$potential_echo_state" == "$current_state" ]; then
            log "SILENCE" "✅ [W-MON] 二次验证通过。确认是纯净的回声，已忽略。"
            potential_echo_state="" # 清除待验证状态
            previous_state="$current_state" # 最终确认基准
            continue
        
        # 场景3：任何其他情况 (不在静默期 / 或在静默期但已有新变化) -> 必须同步
        else
            log "EVENT" "📢 检测到需要同步的 Windows 目录变化。"
            
            # 如果是从“待验证”状态过来的，说明有合法修改混入
            if [ -n "$potential_echo_state" ]; then
                log "INFO" "[W-MON] 二次验证失败：在观察期内检测到新的用户修改。"
                potential_echo_state="" # 清除待验证状态
            fi

            sync_win_to_linux
            
            # 同步后，必须用最新状态更新基准，确保一致性
            previous_state=$(get_windows_state)
            if [ -z "$previous_state" ]; then
                log "WARN" "[W-MON] 同步后更新状态失败，将在下次循环重新初始化。"
            fi
        fi
    done
}

# --- 脚本主程序 ---
main() {
    # 检查 PID 文件，防止脚本多重启动
    if [ -f "$PID_FILE" ] && ps -p "$(cat "$PID_FILE")" > /dev/null; then
        log "ERROR" "❌ 脚本已在运行 (PID: $(cat "$PID_FILE"))。请先停止旧实例。"
        exit 1
    fi
    echo $$ > "$PID_FILE"

    # 清理函数
    cleanup() {
        log "INFO" "🛑 接收到信号，正在清理并退出..."
        rm -f "$PID_FILE" "$LOCK_FILE" "$LINUX_CHANGE_FLAG"
        # 优雅地杀死所有后台子进程
        if [ -n "$L_MON_PID" ]; then kill "$L_MON_PID"; fi
        if [ -n "$L_SYNC_PID" ]; then kill "$L_SYNC_PID"; fi
        if [ -n "$W_MON_PID" ]; then kill "$W_MON_PID"; fi
        log "INFO" "👋 脚本已停止。"
        exit 0
    }
    trap cleanup SIGINT SIGTERM

    log "INFO" "🚀 脚本启动 (PID: $$)"

    ### 新增：在启动时清理旧的状态文件 ###
    rm -f "$LAST_SYNC_DIR_FILE" "$LAST_SYNC_TIME_FILE" "$LINUX_CHANGE_FLAG"
    
    # 初始全量同步 (先拉取，再推送，以远程为准或根据需求调整)
    log "INIT" "执行初始同步..."
    sync_win_to_linux
    sync_linux_to_win
    log "INIT" "✅ 初始同步完成。"

    # 启动后台监控进程
    monitor_linux_changes &
    L_MON_PID=$!
    
    debounce_and_sync_linux &
    L_SYNC_PID=$!

    monitor_windows_changes &
    W_MON_PID=$!

    log "INFO" "✅ 所有监控进程已启动。"
    log "INFO" "Linux Watcher PID: $L_MON_PID"
    log "INFO" "Linux Syncer PID: $L_SYNC_PID"
    log "INFO" "Windows Watcher PID: $W_MON_PID"
    log "INFO" "日志文件位于: $LOG_FILE"
    log "INFO" "脚本正在后台运行，按 Ctrl+C 停止。"

    # 等待所有后台任务结束（实际上是无限等待，直到被 trap 捕获）
    wait
}

# 执行主函数
main "$@"
