#!/bin/bash
# 权限修复与防抖增强版 - 双向实时监控同步脚本
# v6: 引入同步前安全检查，彻底解决竞态条件下的数据丢失问题

# --- 配置参数 ---
SSH_USER="amei"
SSH_HOST="192.168.1.3"
SSH_PORT="22"
LINUX_DIR="/server/www/mallphp"
WIN_DIR="D:\\www\\mallphp" # PowerShell/Windows 路径
WIN_CYGDRIVE_PATH="/cygdrive/d/www/mallphp" # Cygwin 路径 (用于 rsync)
WIN_RSYNC_PATH="\"D:/Program Files (x86)/cwRsync/bin/rsync.exe\"" # 注意引号的使用

LOG_FILE="/var/log/mallphp_sync.log"
LOCK_FILE="/tmp/mallphp_sync.lock"
PID_FILE="/tmp/mallphp_sync.pid"

# 用于防抖的临时标志文件
LINUX_CHANGE_FLAG="/tmp/mallphp_sync.flag"

### ★★★ 新增：用于存储上一次同步后 Windows 状态的快照文件 ★★★
WIN_STATE_FILE="/tmp/mallphp_win_state.snapshot"

# 普通用户（用于权限修复）
NORMAL_USER="amei"
NORMAL_GROUP="amei"

# --- 日志与锁 ---
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" || { echo "错误：无法创建或写入日志文件 $LOG_FILE"; exit 1; }
touch "$LOCK_FILE" && rm -f "$LOCK_FILE" || { echo "错误：无法在 /tmp 中创建锁文件"; exit 1; }

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "$LOG_FILE"
}

# --- 排除列表 (不变) ---
RSYNC_EXCLUDES=(
    "--exclude=.git/" "--exclude=.svn/" "--exclude=.idea/" "--exclude=.vscode/"
    "--exclude=node_modules/" "--exclude=vendor/" "--exclude=runtime/" "--exclude=cache/"
    "--exclude=/config/database.local.php" "--exclude=*.bak" "--exclude=.env" "--exclude=*.log"
    "--exclude=*.tmp" "--exclude=*.swp" "--exclude=~$*"
)
INOTIFY_EXCLUDE_PATTERN='(\.git/|\.svn/|\.idea/|\.vscode/|node_modules/|vendor/|runtime/|cache/|^config/database\.local\.php$|\.bak$|\.env$|\.log$|\.tmp$|\.swp$|^~\$.*)'

# --- 核心辅助函数 ---

acquire_lock() {
    local lock_content="$1"
    if (set -o noclobber; echo "$lock_content" > "$LOCK_FILE") 2> /dev/null; then
        return 0
    else
        return 1
    fi
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# ★★★ 新增：获取 Windows 状态的独立函数，供多处调用 ★★★
get_windows_state() {
    ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
        "powershell -Command \"Get-ChildItem -Recurse -Path '$WIN_DIR' -Exclude @('.git', '.svn', '.idea', '.vscode', 'node_modules', 'vendor', 'runtime', '*.log', '*.tmp', '.env', '*.swp', '~\$*') | Select-Object FullName, LastWriteTime, Length | Sort-Object FullName | ConvertTo-Json -Compress\"" 2>/dev/null
}

# 权限修复函数 (不变)
fix_linux_permissions() {
    # ... 此函数逻辑不变 ...
    local target_dir="$1"; shift; local ignored_paths=("$@")
    log "🔧 正在为 Linux 目录 '$target_dir' 应用权限 (用户: $NORMAL_USER, 用户组: $NORMAL_GROUP)"
    local find_prune_args=()
    if [ ${#ignored_paths[@]} -gt 0 ]; then
        local prune_conditions=(-path "${ignored_paths[0]}")
        for ((i=1; i<${#ignored_paths[@]}; i++)); do
            prune_conditions+=(-o -path "${ignored_paths[i]}")
        done
        find_prune_args=( \( "${prune_conditions[@]}" \) -prune -o )
    fi
    local SUDO_CMD=""
    if [ "$(id -u)" -ne 0 ]; then SUDO_CMD="sudo"; fi
    find "$target_dir" "${find_prune_args[@]}" -exec $SUDO_CMD chown "$NORMAL_USER:$NORMAL_GROUP" {} + >/dev/null 2>&1
    find "$target_dir" "${find_prune_args[@]}" -type d -exec $SUDO_CMD chmod 755 {} + >/dev/null 2>&1
    find "$target_dir" "${find_prune_args[@]}" -type f -exec $SUDO_CMD chmod 644 {} + >/dev/null 2>&1
    log "🔩 Linux 权限已应用"
}


# --- 同步核心函数 ---

sync_linux_to_win() {
    while ! acquire_lock "$$:L2W"; do
        # ... 死锁检测逻辑不变 ...
        if [ -f "$LOCK_FILE" ]; then local holder_info; holder_info=$(cat "$LOCK_FILE" 2>/dev/null); local holder_pid; holder_pid=${holder_info%%:*}; if [[ -n "$holder_pid" && ! -f "/proc/$holder_pid/cmdline" ]]; then log "LOCK" "检测到死锁 (持有者 PID $holder_pid 不存在)，强制释放。"; release_lock; fi; fi
        sleep 1
    done
    log "LOCK" "成功获取锁: Linux → Windows"

    log "SYNC" "🔄 开始同步: Linux → Windows"
    rsync -avzi --no-owner --no-group --delete -e "ssh -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" "${RSYNC_EXCLUDES[@]}" "$LINUX_DIR/" "$SSH_USER@$SSH_HOST:$WIN_CYGDRIVE_PATH/" >/dev/null 2>&1
    local exit_code=$?

    if [ $exit_code -eq 0 ] || [ $exit_code -eq 23 ]; then
        if [ $exit_code -eq 0 ]; then log "SYNC" "✅ 同步成功: Linux → Windows"; else log "SYNC" "⚠️ 部分文件同步失败 (代码 23): Linux → Windows"; fi
        ### ★★★ 修改：同步成功后，更新 Windows 状态快照 ★★★
        local new_state; new_state=$(get_windows_state)
        if [ -n "$new_state" ]; then
            echo "$new_state" > "$WIN_STATE_FILE"
            log "STATE" "[L2W] Windows 状态快照已更新。"
        else
            log "ERROR" "[L2W] 同步后无法获取新的 Windows 状态，快照未更新！"
        fi
    else
        log "SYNC" "❌ 同步失败 [代码 $exit_code]: Linux → Windows"
    fi
 
    release_lock
    log "LOCK" "锁已释放 (L→W)"
}


sync_win_to_linux() {
    while ! acquire_lock "$$:W2L"; do
        # ... 死锁检测逻辑不变 ...
        if [ -f "$LOCK_FILE" ]; then local holder_info; holder_info=$(cat "$LOCK_FILE" 2>/dev/null); local holder_pid; holder_pid=${holder_info%%:*}; if [[ -n "$holder_pid" && ! -f "/proc/$holder_pid/cmdline" ]]; then log "LOCK" "检测到死锁 (持有者 PID $holder_pid 不存在)，强制释放。"; release_lock; fi; fi
        sleep 1
    done
    log "LOCK" "成功获取锁: Windows → Linux"

    log "SYNC" "🔄 开始同步: Windows → Linux"
    rsync -avzi --no-owner --no-group --delete -e "ssh -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" "${RSYNC_EXCLUDES[@]}" "$SSH_USER@$SSH_HOST:$WIN_CYGDRIVE_PATH/" "$LINUX_DIR/" >/dev/null 2>&1
    local exit_code=$?
    
    if [ $exit_code -eq 0 ] || [ $exit_code -eq 23 ]; then
        if [ $exit_code -eq 0 ]; then log "SYNC" "✅ 同步成功: Windows → Linux"; else log "SYNC" "⚠️ 部分文件同步失败 (代码 23): Windows → Linux"; fi
        
        ### ★★★ 修改：同步成功后，更新 Windows 状态快照 ★★★
        local new_state; new_state=$(get_windows_state)
        if [ -n "$new_state" ]; then
            echo "$new_state" > "$WIN_STATE_FILE"
            log "STATE" "[W2L] Windows 状态快照已更新。"
        else
            log "ERROR" "[W2L] 同步后无法获取新的 Windows 状态，快照未更新！"
        fi
        
        # 权限修复逻辑不变
        local ignored_paths=("$LINUX_DIR/.git" "$LINUX_DIR/node_modules" "$LINUX_DIR/vendor" "$LINUX_DIR/runtime")
        fix_linux_permissions "$LINUX_DIR" "${ignored_paths[@]}"

    else
        log "SYNC" "❌ 同步失败 [代码 $exit_code]: Windows → Linux"
    fi

    release_lock
    log "LOCK" "锁已释放 (W→L)"
}


# --- 监控与触发器 ---

monitor_linux_changes() {
    log "INFO" "🔍 [L-MON] 开始监控 Linux 目录: $LINUX_DIR"
    inotifywait -m -r -q -e create,delete,modify,move \
                --excludei "$INOTIFY_EXCLUDE_PATTERN" \
                "$LINUX_DIR" |
    while read -r path action file; do
        # 如果锁是 W2L，说明是回声，忽略
        if [ -f "$LOCK_FILE" ] && [[ "$(cat "$LOCK_FILE" 2>/dev/null)" == *":W2L" ]]; then
            log "SILENCE" "🔇 [L-MON] 检测到 W→L 同步导致的回声，忽略 inotify 事件。"
            continue
        fi
        touch "$LINUX_CHANGE_FLAG"
    done
}


### ★★★ 修改：最核心的修改，增加同步前安全检查 ★★★
debounce_and_sync_linux() {
    log "INFO" "🚀 [L-SYNC] 防抖同步服务已启动 (带安全检查)"
    while true; do
        while [ ! -f "$LINUX_CHANGE_FLAG" ]; do sleep 0.5; done

        log "EVENT" "📢 检测到 Linux 变化，进入 2 秒稳定期..."
        while [ -f "$LINUX_CHANGE_FLAG" ]; do rm -f "$LINUX_CHANGE_FLAG"; sleep 2; done
        log "EVENT" "🟢 文件系统已稳定，准备处理..."

        # ★★★ 核心安全检查 (Sync Guard) ★★★
        log "GUARD" "🛡️  正在执行 L→W 同步前安全检查..."
        local last_known_state; last_known_state=$(cat "$WIN_STATE_FILE" 2>/dev/null)
        local current_win_state; current_win_state=$(get_windows_state)

        if [ -z "$current_win_state" ]; then
            log "WARN" "🛡️  [GUARD] 无法获取当前 Windows 状态，跳过本次 L→W 同步以策安全。"
            continue
        fi

        if [[ -n "$last_known_state" && "$last_known_state" != "$current_win_state" ]]; then
            log "GUARD" "🛡️  [GUARD] 检测到 Windows 存在未同步的更改！"
            log "GUARD" "🛡️  [GUARD] ‼️ 已中止本次 L→W 同步，以防止数据丢失。等待 W→L 同步优先执行。"
            continue
        fi
        log "GUARD" "🛡️  [GUARD] 安全检查通过，Windows 目录是干净的。"
        
        # 只有在安全检查通过后才执行同步
        sync_linux_to_win
    done
}


### ★★★ 修改：Windows 监控逻辑简化 ★★★
monitor_windows_changes() {
    log "INFO" "🔍 [W-MON] 启动 Windows 目录监控 (间隔 10s)"
    
    local previous_state; previous_state=$(cat "$WIN_STATE_FILE" 2>/dev/null)
    if [ -z "$previous_state" ]; then
        log "INFO" "[W-MON] 快照文件不存在，正在初始化 Windows 目录状态..."
        previous_state=$(get_windows_state)
        if [ -n "$previous_state" ]; then
            echo "$previous_state" > "$WIN_STATE_FILE"
            log "INFO" "[W-MON] Windows 目录状态初始化完成。"
        else
            log "WARN" "[W-MON] 初始化 Windows 状态失败，将在循环中重试。"
        fi
    fi

    while true; do
        sleep 10
        local current_state; current_state=$(get_windows_state)

        if [ -z "$current_state" ]; then
            log "WARN" "⚠️ [W-MON] 无法获取 Windows 目录状态，15秒后重试。"
            sleep 5
            continue
        fi

        if [ "$previous_state" == "$current_state" ]; then
            continue
        fi

        # 检测到变化，直接尝试同步。锁机制会处理并发问题。
        log "EVENT" "📢 检测到 Windows 目录变化，准备同步 W→L。"
        sync_win_to_linux
        
        # 同步后，直接从快照文件更新状态，而不是再次远程获取
        # 因为 sync_win_to_linux 成功后会保证快照文件是新的
        previous_state=$(cat "$WIN_STATE_FILE" 2>/dev/null)
    done
}

# --- 脚本主程序 ---
main() {
    if [ -f "$PID_FILE" ] && ps -p "$(cat "$PID_FILE")" > /dev/null; then
        log "ERROR" "❌ 脚本已在运行 (PID: $(cat "$PID_FILE"))。请先停止旧实例。"
        exit 1
    fi
    echo $$ > "$PID_FILE"

    cleanup() {
        log "INFO" "🛑 接收到信号，正在清理并退出..."
        ### ★★★ 修改：清理时也移除新增的状态文件 ★★★
        rm -f "$PID_FILE" "$LOCK_FILE" "$LINUX_CHANGE_FLAG" "$WIN_STATE_FILE"
        pkill -P $$ # 杀死所有由该脚本启动的子进程
        log "INFO" "👋 脚本已停止。"
        exit 0
    }
    trap cleanup SIGINT SIGTERM

    log "INFO" "🚀 脚本启动 (PID: $$)"
    
    # 清理所有临时/状态文件
    rm -f "$LOCK_FILE" "$LINUX_CHANGE_FLAG" "$WIN_STATE_FILE"
    
    log "INIT" "执行初始同步..."
    # 初始同步 W->L 优先，确保 Linux 拿到最新版本，并生成初始快照
    sync_win_to_linux
    sync_linux_to_win # 随后 L->W 会因为快照一致而顺利执行
    log "INIT" "✅ 初始同步完成。"

    # 启动后台监控进程
    monitor_linux_changes &
    L_MON_PID=$!
    
    debounce_and_sync_linux &
    L_SYNC_PID=$!

    monitor_windows_changes &
    W_MON_PID=$!

    log "INFO" "✅ 所有监控进程已启动。"
    log "INFO" "Linux Watcher PID: $L_MON_PID, Syncer PID: $L_SYNC_PID, Windows Watcher PID: $W_MON_PID"
    log "INFO" "日志文件位于: $LOG_FILE"
    log "INFO" "脚本正在后台运行，按 Ctrl+C 停止。"

    wait
}

main "$@"
