#!/bin/bash
# 权限修复与防抖增强版 - 多项目双向实时监控同步脚本
# 作者: AMEI (基于原版修改)
# 版本: 2.0
# 功能: 支持同时监控和同步多个独立的目录对。

# --- 全局配置 (所有项目共享) ---
SSH_USER="amei"
SSH_HOST="192.168.1.3"
SSH_PORT="22"
WIN_RSYNC_PATH="\"D:/Program Files (x86)/cwRsync/bin/rsync.exe\"" # 注意引号的使用
# LOG_FILE="/var/log/multi_sync.log"
LOG_FILE="/home/amei/multi_sync.log"
PID_FILE="/tmp/multi_sync.pid"

# 同步静默功能: 在一次同步后，忽略反向“回声”变化的秒数
SILENCE_PERIOD=15

# 权限修复相关
NORMAL_USER="amei"
NORMAL_GROUP="amei"

# --- 项目配置 (关键改动) ---
# 使用并列数组定义每个项目。确保数组索引对应。
# 例如: PROJECT_NAMES[0] 对应 LINUX_DIRS[0] 和 WIN_DIRS[0]

PROJECT_NAMES=(
    "mallphp"
    "adminvue"
    "chidian_store_uniapp"
)

LINUX_DIRS=(
    "/server/www/mallphp"
    "/server/www/adminvue"
    "/server/www/chidian_store_uniapp"
)

WIN_DIRS=(
    "D:\\www\\mallphp"   # PowerShell/Windows 路径
    "D:\\www\\adminvue"
    "D:\\www\\chidian_store_uniapp"
)

# --- 全局排除列表 (所有项目共享) ---
# 如果需要为每个项目设置不同的排除规则，可以将其也定义为数组。
# 为简化起见，这里使用全局规则。

# rsync 格式
RSYNC_EXCLUDES=(
    "--exclude=.git/"
    "--exclude=.svn/"
    "--exclude=.idea/"
    "--exclude=.vscode/"
    "--exclude=node_modules/"
    "--exclude=runtime/"
    "--exclude=unpackage/"
    "--exclude=cache/"
    "--exclude=/config/database.local.php" # 注意: 此规则对所有项目生效
    "--exclude=*.bak"
    "--exclude=.env"
    "--exclude=*.log"
    "--exclude=*.tmp"
    "--exclude=*.swp"
    "--exclude=~$*"
)

# inotifywait ERE 正则表达式格式
INOTIFY_EXCLUDE_PATTERN='(
    \.git/|
    \.svn/|
    \.idea/|
    \.vscode/|
    node_modules/|
    runtime/|
    unpackage/|
    cache/|
    ^config/database\.local\.php$|
    \.bak$|
    \.env$|
    \.log$|
    \.tmp$|
    \.swp$|
    ^~\$.*
)'
# 合并为单行
INOTIFY_EXCLUDE_PATTERN=$(echo "$INOTIFY_EXCLUDE_PATTERN" | tr -d ' \n')


# --- 工具函数 ---

# 日志 (已参数化，增加项目名)
log() {
    local project_name="$1"
    local level="$2"
    local message="$3"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$project_name] [$level] $message" | tee -a "$LOG_FILE"
}

# 锁 (已参数化)
acquire_lock() {
    local project_name="$1"
    local lock_file="$2"
    local lock_purpose="$3"
    if (set -o noclobber; echo "$$" > "$lock_file") 2> /dev/null; then
        log "$project_name" "LOCK" "成功获取锁: $lock_purpose"
        return 0
    else
        local holder_pid
        holder_pid=$(cat "$lock_file")
        log "$project_name" "LOCK" "等待锁... (当前持有者 PID: $holder_pid, 目的: $lock_purpose)"
        while ! (set -o noclobber; echo "$$" > "$lock_file") 2> /dev/null; do
            if ! ps -p "$holder_pid" > /dev/null; then
                log "$project_name" "LOCK" "检测到死锁 (PID $holder_pid 不存在)，强制释放。"
                rm -f "$lock_file"
            fi
            sleep 1
        done
        log "$project_name" "LOCK" "先前任务完成，已获取锁: $lock_purpose"
        return 0
    fi
}

release_lock() {
    local project_name="$1"
    local lock_file="$2"
    rm -f "$lock_file"
    log "$project_name" "LOCK" "锁已释放"
}

# 权限修复 (已参数化)
fix_linux_permissions() {
    local project_name="$1"
    local target_dir="$2"
    shift 2 # 移除前两个参数
    local ignored_paths=("$@")

    log "$project_name" "🔧" "正在为 '$target_dir' 应用权限 (用户: $NORMAL_USER, 组: $NORMAL_GROUP)"
    if [ ${#ignored_paths[@]} -gt 0 ]; then
        log "$project_name" "🔧" "    - 忽略以下路径: ${ignored_paths[*]}"
    fi

    local find_prune_args=()
    if [ ${#ignored_paths[@]} -gt 0 ]; then
        find_prune_args+=(-path "${ignored_paths[0]}")
        for ((i=1; i<${#ignored_paths[@]}; i++)); do
            find_prune_args+=(-o -path "${ignored_paths[i]}")
        done
        find_prune_args=( \( "${find_prune_args[@]}" \) -prune -o )
    fi
    
    local SUDO_CMD=""
    if [ "$(id -u)" -ne 0 ]; then SUDO_CMD="sudo"; fi

    find "$target_dir" "${find_prune_args[@]}" -exec $SUDO_CMD chown "$NORMAL_USER:$NORMAL_GROUP" {} +
    find "$target_dir" "${find_prune_args[@]}" -type d -exec $SUDO_CMD chmod 755 {} +
    find "$target_dir" "${find_prune_args[@]}" -type f -exec $SUDO_CMD chmod 644 {} +

    log "$project_name" "🔩" "权限已应用"
}

# --- 核心同步函数 (已参数化) ---

# $1: project_name, $2: linux_dir, $3: win_cygdrive_path, $4: last_sync_dir_file, $5: last_sync_time_file
sync_linux_to_win() {
    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3" last_sync_dir_file="$4" last_sync_time_file="$5"
    log "$project_name" "SYNC" "🔄 开始同步: Linux → Windows"
    
    local rsync_output_file; rsync_output_file=$(mktemp "/tmp/rsync_${project_name}_linux_out.XXXXXX")

    # shellcheck disable=SC2068
    rsync -avzi --no-owner --no-group --delete \
          -e "ssh -p $SSH_PORT" \
          --rsync-path="$WIN_RSYNC_PATH" \
          "${RSYNC_EXCLUDES[@]}" \
          "$linux_dir/" \
          "$SSH_USER@$SSH_HOST:$win_cygdrive_path/" > "$rsync_output_file" 2>&1
    local exit_code=$?
    
    if [ -s "$rsync_output_file" ]; then
        log "$project_name" "SYNC_DETAIL" "--- rsync 输出 (Lin→Win) ---"
        sed 's/^/    /g' "$rsync_output_file" | tee -a "$LOG_FILE"
        log "$project_name" "SYNC_DETAIL" "--- 结束输出 ---"
    fi
    rm -f "$rsync_output_file"

    if [ $exit_code -eq 0 ]; then
        log "$project_name" "SYNC" "✅ 同步成功: Linux → Windows"
        echo "L2W" > "$last_sync_dir_file"
        date +%s > "$last_sync_time_file"
    else
        log "$project_name" "SYNC" "❌ 同步失败 [代码 $exit_code]: Linux → Windows"
    fi
}

# $1: project_name, $2: linux_dir, $3: win_cygdrive_path, $4: last_sync_dir_file, $5: last_sync_time_file
sync_win_to_linux() {
    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3" last_sync_dir_file="$4" last_sync_time_file="$5"
    log "$project_name" "SYNC" "🔄 开始同步: Windows → Linux"
    
    local rsync_output_file; rsync_output_file=$(mktemp "/tmp/rsync_${project_name}_win_out.XXXXXX")

    # shellcheck disable=SC2068
    rsync -avzi --no-owner --no-group --delete \
          -e "ssh -p $SSH_PORT" \
          --rsync-path="$WIN_RSYNC_PATH" \
          "${RSYNC_EXCLUDES[@]}" \
          "$SSH_USER@$SSH_HOST:$win_cygdrive_path/" \
          "$linux_dir/" > "$rsync_output_file" 2>&1
    local exit_code=$?
    
    if [ -s "$rsync_output_file" ]; then
       log "$project_name" "SYNC_DETAIL" "--- rsync 输出 (Win→Lin) ---"
        sed 's/^/    /g' "$rsync_output_file" | tee -a "$LOG_FILE"
        log "$project_name" "SYNC_DETAIL" "--- 结束输出 ---"
    fi
    rm -f "$rsync_output_file"
    
    if [ $exit_code -eq 0 ]; then
        log "$project_name" "SYNC" "✅ 同步成功: Windows → Linux"
        echo "W2L" > "$last_sync_dir_file"
        date +%s > "$last_sync_time_file"
        
        # 权限修复逻辑 (可以根据项目自定义忽略路径)
        # 示例: 仅为 mallphp 项目添加特殊忽略规则
        local ignored_paths=()
        if [[ "$project_name" == "mallphp" ]]; then
            ignored_paths=(
                "$linux_dir/.git"
                "$linux_dir/runtime"
            )
        fi
        
        log "$project_name" "PERMS" "🔩 检查并修复权限..."
        if [ ${#ignored_paths[@]} -gt 0 ]; then
            fix_linux_permissions "$project_name" "$linux_dir" "${ignored_paths[@]}"
        else
            fix_linux_permissions "$project_name" "$linux_dir"
        fi
    else
        log "$project_name" "SYNC" "❌ 同步失败 [代码 $exit_code]: Windows → Linux"
    fi
}


# --- 监控与触发器 (已参数化) ---

# $1: project_name, $2: linux_dir, $3: change_flag_file
monitor_linux_changes() {
    local project_name="$1" linux_dir="$2" change_flag_file="$3"
    log "$project_name" "L-MON" "🔍 开始监控 Linux 目录: $linux_dir"
    inotifywait -m -r -q -e create,delete,modify,move \
                --excludei "$INOTIFY_EXCLUDE_PATTERN" \
                "$linux_dir" |
    while read -r path action file; do
        touch "$change_flag_file"
    done
}

# $1: project_name, $2: linux_dir, $3: win_cygdrive_path, $4..: state_files
debounce_and_sync_linux() {
    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3" \
          lock_file="$4" change_flag_file="$5" last_sync_dir_file="$6" last_sync_time_file="$7"
          
    log "$project_name" "L-SYNC" "🚀 防抖同步服务已启动"
    while true; do
        while [ ! -f "$change_flag_file" ]; do sleep 0.5; done

        log "$project_name" "EVENT" "📢 检测到 Linux 变化，进入 2 秒稳定期..."
        while [ -f "$change_flag_file" ]; do
            rm -f "$change_flag_file"
            sleep 2
        done
        log "$project_name" "EVENT" "🟢 文件系统已稳定，准备执行 L→W 同步。"
        
        local last_dir=""; local last_time=0
        if [ -f "$last_sync_dir_file" ]; then last_dir=$(cat "$last_sync_dir_file"); fi
        if [ -f "$last_sync_time_file" ]; then last_time=$(cat "$last_sync_time_file"); fi
        local current_time; current_time=$(date +%s)
        
        if [[ "$last_dir" == "W2L" && $((current_time - last_time)) -lt $SILENCE_PERIOD ]]; then
            log "$project_name" "SILENCE" "🔇 [L-SYNC] 忽略 Linux 变化（回声）。"
            continue
        fi

        if acquire_lock "$project_name" "$lock_file" "Linux → Windows"; then
            sync_linux_to_win "$project_name" "$linux_dir" "$win_cygdrive_path" "$last_sync_dir_file" "$last_sync_time_file"
            release_lock "$project_name" "$lock_file"
        else
            log "$project_name" "ABORT" "❌ [L-SYNC] 放弃同步，因为锁被 W→L 同步占用。"
        fi
    done
}

# $1: project_name, $2: linux_dir, $3: win_cygdrive_path, $4..: state_files
monitor_windows_changes() {
    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3" \
          lock_file="$4" last_sync_dir_file="$5" last_sync_time_file="$6"
          
    log "$project_name" "W-MON" "🔍 开始轮询监控 Windows 目录 (间隔 10s)"
    
    while true; do
        local rsync_args=(-rtin --delete --no-owner --no-group -e "ssh -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" "${RSYNC_EXCLUDES[@]}" "$SSH_USER@$SSH_HOST:$win_cygdrive_path/" "$linux_dir/")
        local dry_run_output; dry_run_output=$(rsync "${rsync_args[@]}" 2>&1)
        local exit_code=$?
        
        if [ $exit_code -ne 0 ] && [ $exit_code -ne 24 ]; then
            log "$project_name" "WARN" "⚠️ [W-MON] rsync dry-run 失败 [代码 $exit_code]。"
            log "$project_name" "WARN" "    - 错误信息: ${dry_run_output}"
            sleep 30; continue
        fi

        if echo "$dry_run_output" | grep -q -E '^[.><*c]'; then
            log "$project_name" "EVENT" "📢 [W-MON] 检测到 Windows 目录有变化"
            
            local last_dir=""; local last_time=0
            if [ -f "$last_sync_dir_file" ]; then last_dir=$(cat "$last_sync_dir_file"); fi
            if [ -f "$last_sync_time_file" ]; then last_time=$(cat "$last_sync_time_file"); fi
            local current_time; current_time=$(date +%s)

            if [[ "$last_dir" == "L2W" && $((current_time - last_time)) -lt $SILENCE_PERIOD ]]; then
                log "$project_name" "SILENCE" "🔇 [W-MON] 忽略 Windows 变化（回声）。"
                sleep 10; continue
            fi

            if acquire_lock "$project_name" "$lock_file" "Windows → Linux"; then
                sync_win_to_linux "$project_name" "$linux_dir" "$win_cygdrive_path" "$last_sync_dir_file" "$last_sync_time_file"
                release_lock "$project_name" "$lock_file"
            else
                log "$project_name" "INFO" "[W-MON] 锁被 L→W 同步占用，将在下一轮检查时重试。"
            fi
        fi
        sleep 10
    done
}

# --- 脚本主程序 ---
main() {
    # 检查全局 PID 文件
    if [ -f "$PID_FILE" ] && ps -p "$(cat "$PID_FILE")" > /dev/null; then
        log "MAIN" "ERROR" "❌ 主脚本已在运行 (PID: $(cat "$PID_FILE"))。请先停止旧实例。"
        exit 1
    fi
    echo $$ > "$PID_FILE"

    # 存储所有子进程PID的数组
    ALL_PIDS=()
    
    # 清理函数
    cleanup() {
        log "MAIN" "INFO" "🛑 接收到信号，正在清理并退出..."
        rm -f "$PID_FILE"
        
        # 清理所有项目的状态文件
        for project_name in "${PROJECT_NAMES[@]}"; do
            rm -f "/tmp/rsync_${project_name}.lock" \
                  "/tmp/${project_name}_change.flag" \
                  "/tmp/${project_name}_last_sync_dir" \
                  "/tmp/${project_name}_last_sync_time"
        done

        # 优雅地杀死所有后台子进程
        if [ ${#ALL_PIDS[@]} -gt 0 ]; then
            log "MAIN" "INFO" "正在停止所有子进程: ${ALL_PIDS[*]}"
            kill "${ALL_PIDS[@]}"
        fi
        log "MAIN" "INFO" "👋 脚本已停止。"
        exit 0
    }
    trap cleanup SIGINT SIGTERM

    log "MAIN" "INFO" "🚀 主脚本启动 (PID: $$)"

    # 确保日志和锁文件目录存在
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE" || { echo "错误：无法创建或写入日志文件 $LOG_FILE"; exit 1; }
    
    # 遍历并启动每个项目的监控
    for i in "${!PROJECT_NAMES[@]}"; do
        local project_name="${PROJECT_NAMES[i]}"
        local linux_dir="${LINUX_DIRS[i]}"
        local win_dir="${WIN_DIRS[i]}"
        
        # 将 Windows 路径转换为 rsync/Cygwin 路径
        local win_cygdrive_path="/cygdrive/$(echo "$win_dir" | sed 's/\\/\//g' | sed 's/://')"

        # 为项目生成唯一的状态文件路径
        local lock_file="/tmp/rsync_${project_name}.lock"
        local change_flag_file="/tmp/${project_name}_change.flag"
        local last_sync_dir_file="/tmp/${project_name}_last_sync_dir"
        local last_sync_time_file="/tmp/${project_name}_last_sync_time"
        
        log "$project_name" "INIT" "--- 正在初始化项目: $project_name ---"
        log "$project_name" "INIT" "Linux 目录: $linux_dir"
        log "$project_name" "INIT" "Windows 目录: $win_dir -> $win_cygdrive_path"

        # 启动前清理旧的状态文件
        rm -f "$lock_file" "$change_flag_file" "$last_sync_dir_file" "$last_sync_time_file"

        # 初始同步 (可选, 可根据需要注释掉)
        log "$project_name" "INIT" "执行初始同步..."
        sync_linux_to_win "$project_name" "$linux_dir" "$win_cygdrive_path" "$last_sync_dir_file" "$last_sync_time_file"
        sync_win_to_linux "$project_name" "$linux_dir" "$win_cygdrive_path" "$last_sync_dir_file" "$last_sync_time_file"
        log "$project_name" "INIT" "✅ 初始同步完成。"

        # 启动后台监控进程
        monitor_linux_changes "$project_name" "$linux_dir" "$change_flag_file" &
        ALL_PIDS+=($!)
        
        debounce_and_sync_linux "$project_name" "$linux_dir" "$win_cygdrive_path" "$lock_file" "$change_flag_file" "$last_sync_dir_file" "$last_sync_time_file" &
        ALL_PIDS+=($!)

        monitor_windows_changes "$project_name" "$linux_dir" "$win_cygdrive_path" "$lock_file" "$last_sync_dir_file" "$last_sync_time_file" &
        ALL_PIDS+=($!)
    done

    log "MAIN" "INFO" "✅ 所有项目的监控进程已启动。"
    log "MAIN" "INFO" "所有子进程 PIDs: ${ALL_PIDS[*]}"
    log "MAIN" "INFO" "日志文件位于: $LOG_FILE"
    log "MAIN" "INFO" "脚本正在后台运行，按 Ctrl+C 停止。"

    # 等待所有后台任务结束
    wait
}

# --- 执行 ---
main "$@"
