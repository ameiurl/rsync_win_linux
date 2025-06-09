#!/bin/bash
# -----------------------------------------------------------------------------
# 通用型双向实时同步脚本 - 核心逻辑
# 版本: 3.0
#
# 使用方法:
#   ./bidirectional_sync.sh /path/to/your_project.conf
#
# 此脚本是核心引擎，不应被编辑。
# 所有设置都从指定的配置文件中加载。
# -----------------------------------------------------------------------------

# --- 脚本初始化与参数处理 ---
SCRIPT_NAME=$(basename "$0")

if [ "$#" -ne 1 ]; then
    echo "❌ 错误: 必须提供一个配置文件作为参数。" >&2
    echo "   用法: $SCRIPT_NAME /path/to/your_config.conf" >&2
    exit 1
fi

CONFIG_FILE="$1"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ 错误: 在 '$CONFIG_FILE' 未找到配置文件" >&2
    exit 1
fi

# 加载指定的配置文件
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# --- 核心功能 (不应被编辑) ---

# 创建必要的目录和文件，并检查权限
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" || { echo "❌ 错误: 无法创建或写入日志文件 '$LOG_FILE'。请检查权限。" >&2; exit 1; }
touch "$LOCK_FILE" &>/dev/null || { echo "❌ 错误: 无法创建或写入锁文件 '$LOCK_FILE'。请检查权限。" >&2; exit 1; }
rm -f "$LOCK_FILE" # 确保启动时锁文件是干净的

# 初始化去抖计时器
LAST_LINUX_EVENT=0
LAST_WIN_EVENT=0

# 日志函数，会加上项目名称前缀
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$PROJECT_NAME] $1" | tee -a "$LOG_FILE"
}

# 锁机制
acquire_lock() {
    local waited=0
    while [ -f "$LOCK_FILE" ] && [ $waited -lt $MAX_WAIT ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if [ $waited -ge $MAX_WAIT ]; then
        log "⛔ 等待锁定超时 ($MAX_WAIT 秒)，放弃同步: $1"
        return 1
    fi
    # 将进程ID写入锁文件，便于调试
    echo $$ > "$LOCK_FILE"
    return 0
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# 权限修复函数
fix_linux_permissions() {
    local target_dir="$1"
    log "🔧 正在为 Linux 目录 '$target_dir' 应用权限 (用户: $NORMAL_USER, 用户组: $NORMAL_GROUP)"

    local SUDO_CMD=""
    if [ "$(id -u)" -ne 0 ]; then SUDO_CMD="sudo"; fi

    $SUDO_CMD chown -R "$NORMAL_USER:$NORMAL_GROUP" "$target_dir"
    find "$target_dir" -type d -exec $SUDO_CMD chmod 755 {} \;
    find "$target_dir" -type f -exec $SUDO_CMD chmod 644 {} \;
    find "$target_dir" \( -name "*.sh" -o -name "*.py" \) -perm /u+x -exec $SUDO_CMD chmod u+x {} \;

    if command -v setfacl >/dev/null; then
        $SUDO_CMD setfacl -R -b "$target_dir" &>/dev/null
        log "🔩 Linux 权限已应用"
    else
        log "🔩 Linux 权限 (基本 chmod) 已应用。未找到 setfacl。"
    fi
}

# 从Linux同步到Windows
sync_linux_to_win() {
    local current_time=$(date +%s)
    if [[ $((current_time - LAST_LINUX_EVENT)) -lt 2 && $LAST_LINUX_EVENT -ne 0 ]]; then return; fi
    LAST_LINUX_EVENT=$current_time

    if ! acquire_lock "Linux → Windows"; then return; fi
    
    log "🔄 开始同步: Linux → Windows"
    # shellcheck disable=SC2068
    rsync -avz --no-owner --no-group \
          -e "ssh -p $SSH_PORT" \
          --rsync-path="$WIN_RSYNC_PATH" \
          --delete \
          "${RSYNC_EXCLUDES[@]}" \
          "$LINUX_DIR/" \
          "$SSH_USER@$SSH_HOST:$WIN_CYGDRIVE_PATH/" > >(tee -a "$LOG_FILE") 2>&1
    
    local exit_code=${PIPESTATUS[0]}
    if [ $exit_code -eq 0 ]; then log "✅ 同步成功: Linux → Windows";
    elif [ $exit_code -eq 23 ]; then log "⚠️  部分文件同步失败 (代码 23): Linux → Windows";
    else log "❌ 同步失败 [代码 $exit_code]: Linux → Windows"; fi
 
    release_lock   
}

# 从Windows同步到Linux
sync_win_to_linux() {
    local current_time=$(date +%s)
    if [[ $((current_time - LAST_WIN_EVENT)) -lt 2 && $LAST_WIN_EVENT -ne 0 ]]; then return; fi
    LAST_WIN_EVENT=$current_time

    if ! acquire_lock "Windows → Linux"; then return; fi
    
    log "🔄 开始同步: Windows → Linux"
    local rsync_output_file=$(mktemp /tmp/rsync_win_out_${PROJECT_NAME}.XXXXXX)
    
    # shellcheck disable=SC2068
    rsync -avzi --no-owner --no-group \
          -e "ssh -p $SSH_PORT" \
          --rsync-path="$WIN_RSYNC_PATH" \
          --delete \
          "${RSYNC_EXCLUDES[@]}" \
          "$SSH_USER@$SSH_HOST:$WIN_CYGDRIVE_PATH/" \
          "$LINUX_DIR/" > "$rsync_output_file" 2>&1

    local exit_code=${PIPESTATUS[0]}
    cat "$rsync_output_file" | tee -a "$LOG_FILE"

    if [ $exit_code -eq 0 ]; then
        log "✅ 同步成功: Windows → Linux"
        local needs_permission_fix=false
        if grep -q -E '^(>|c)[fd]\+{9,}' "$rsync_output_file"; then
            log "🔩 检测到 rsync 创建了新文件/目录。"
            needs_permission_fix=true
        fi
        if [ "$needs_permission_fix" = false ] && \
           [ -n "$(find "$LINUX_DIR" -not \( -user "$NORMAL_USER" -and -group "$NORMAL_GROUP" \) -print -quit)" ]; then
            log "🔩 检测到 Linux 目录中存在权限不正确的文件/目录。"
            needs_permission_fix=true
        fi
        if [ "$needs_permission_fix" = true ]; then
            fix_linux_permissions "$LINUX_DIR"
        else
            log "🔩 未检测到需要修复权限的情况，跳过。"
        fi
    elif [ $exit_code -eq 23 ]; then log "⚠️  部分文件同步失败 (代码 23): Windows → Linux";
    else log "❌ 同步失败 [代码 $exit_code]: Windows → Linux"; fi

    rm -f "$rsync_output_file"
    release_lock   
}

# 清理函数
cleanup() {
    log "🛑 接收到信号，为项目 '$PROJECT_NAME' 停止所有进程..."
    pkill -P $$
    release_lock
    log "已平滑关闭。"
    exit 0
}

# 日志轮转函数
rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE")" -gt 10485760 ]; then # 10MB
        mv "$LOG_FILE" "${LOG_FILE}.old"
        touch "$LOG_FILE"
        log "📋 日志文件已轮转"
    fi
}

# --- 主执行流程 ---
trap cleanup SIGINT SIGTERM

log "🚀 脚本 ($SCRIPT_NAME PID:$$) 已启动。正在执行初始同步..."
sync_linux_to_win
sync_win_to_linux
log "🔔 初始同步完成。开始实时监控..."

# Linux端监控 (子进程)
(
    log "🔍 开始监控 Linux 目录: $LINUX_DIR"
    inotifywait -m -r -e create,delete,modify,move --exclude "$INOTIFY_EXCLUDE_PATTERN" "$LINUX_DIR" |
    while read -r path action file; do
        log "📢 Linux 变化: $action $file"
        sync_linux_to_win
    done
) &

# Windows端监控 (子进程)
(
    log "🔍 开始监控 Windows 目录: $WIN_DIR"
    previous_state=""
    while true; do
        sleep 5
        current_state=$(ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
            "powershell -Command \"try { Get-ChildItem -Recurse -Path '$WIN_DIR' -ErrorAction Stop -Exclude @('.git', '.svn', '.idea', '.vscode', 'node_modules', 'vendor', '*.log', '*.tmp', '.env', '*.swp', '~\$*') | Select-Object FullName, LastWriteTime, Length, @{Name='IsDirectory';Expression={\$_.PSIsContainer}} | ConvertTo-Json -Compress } catch {}\"" || continue)
        if [ -z "$current_state" ] && [ -z "$previous_state" ]; then continue; fi
        if [ -z "$previous_state" ]; then previous_state="$current_state"; continue; fi
        if [ "$previous_state" != "$current_state" ]; then
            log "📢 Windows 检测到变化"
            sync_win_to_linux
            previous_state="$current_state"
        fi
    done
) &

# 日志轮转 (子进程)
( while true; do sleep 3600; rotate_log; done ) &

wait
