#!/bin/bash
# 权限修复版双向实时监控同步脚本 - Arch Linux ↔ Windows
# 需要: inotify-tools (Linux), PowerShell (Windows)

# 配置参数
SSH_USER="amei"
SSH_HOST="192.168.1.3"
SSH_PORT="22"
LINUX_DIR="/server/www/mallphp"
WIN_DIR="D:\\www\\mallphp" # PowerShell/Windows path
WIN_CYGDRIVE_PATH="/cygdrive/d/www/mallphp" # Cygwin path for rsync target on Windows
WIN_RSYNC_PATH="\"D:/Program Files (x86)/cwRsync/bin/rsync.exe\""
LOG_FILE="/var/log/bidirectional_sync.log"
LOCK_FILE="/tmp/rsync_bidirectional.lock"
MAX_WAIT=60 # 增加锁定等待时间
# 设置普通用户（修改为你的实际用户名）
NORMAL_USER="amei"
NORMAL_GROUP="amei"

# 创建日志目录
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 定义排除列表 (rsync格式)
RSYNC_EXCLUDES=(
    "--exclude=.git/"
    "--exclude=.svn/"
    "--exclude=.idea/"
    "--exclude=.vscode/"
    "--exclude=node_modules/"
    "--exclude=vendor/"
    "--exclude=.env"
    "--exclude=*.log"
    "--exclude=*.tmp"
    "--exclude=*.swp"
    "--exclude=~$*"
)

# 定义排除列表 (inotifywait ERE regex格式)
INOTIFY_EXCLUDE_PATTERN='(\.git/|\.svn/|\.idea/|\.vscode/|node_modules/|vendor/|\.env$|\.log$|\.tmp$|\.swp$|^~\$.*)'

# 改进后的锁机制
acquire_lock() {
    local waited=0
    while [ -f "$LOCK_FILE" ] && [ $waited -lt $MAX_WAIT ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if [ $waited -ge $MAX_WAIT ]; then
        log "⛔ 等待锁定超时，放弃同步: $1"
        return 1
    fi
    return 0
}

# --- 权限处理函数 (Linux - 简化版，但使用默认 ACL) ---
fix_linux_permissions() {
    local target_dir="$1"
    log "🔧 正在为 Linux 目录 '$target_dir' 应用权限 (用户: $NORMAL_USER, 用户组: $NORMAL_GROUP)"

    # 确保 NORMAL_USER 拥有所有文件。如果脚本不是以 root 运行，可能需要 sudo。
    # 如果以 NORMAL_USER 身份运行，并且文件已归 NORMAL_USER 所有，则 chown/chmod 不需要 sudo。
    # 但 setfacl 通常需要 sudo。
    local SUDO_CMD=""
    if [ "$(id -u)" -ne 0 ] && ! (sudo -n true 2>/dev/null); then # 检查是否非 root 且无法免密 sudo
      log "⚠️ 警告: 当前非 root 用户，且 sudo -n 不可用。权限可能无法完全应用。"
    elif [ "$(id -u)" -ne 0 ]; then # 如果非 root 但 sudo -n 可用（或需要密码）
      SUDO_CMD="sudo"
    fi

    $SUDO_CMD chown -R "$NORMAL_USER:$NORMAL_GROUP" "$target_dir"
    # 标准权限: 目录 User=rwx, Group=rx, Other=rx
    #           文件 User=rw, Group=r, Other=r
    find "$target_dir" -type d -exec $SUDO_CMD chmod 755 {} \;
    find "$target_dir" -type f -exec $SUDO_CMD chmod 644 {} \;
    # 使常见脚本类型对所有者可执行 (如果 755 已设置，则组和其他用户也可执行)
    find "$target_dir" \( -name "*.sh" -o -name "*.py" -o -name "*.pl" -o -name "*.cgi" \) -perm /u+x -exec $SUDO_CMD chmod u+x {} \;


    # 设置默认 ACL: 在 $target_dir 中新创建的文件/目录将继承这些权限。
    # u:NORMAL_USER:rwx, g:NORMAL_GROUP:r-x (组用户读和执行), o::r-x (其他用户读和执行)
    # 如果你的组需要写权限，请修改。
    if command -v setfacl >/dev/null; then # 检查 setfacl 命令是否存在
        $SUDO_CMD setfacl -R -b "$target_dir" 2>/dev/null # 清理已存在的 ACL
        $SUDO_CMD setfacl -R -d -m "u:$NORMAL_USER:rwx,g:$NORMAL_GROUP:rx,o::rx" "$target_dir" # 设置默认ACL
        $SUDO_CMD setfacl -R -m "u:$NORMAL_USER:rwx,g:$NORMAL_GROUP:rx,o::rx" "$target_dir" # 应用到现有文件
        log "🔩 Linux 权限 (包括 ACL - 如果可用) 已为 '$target_dir' 应用"
    else
        log "🔩 Linux 权限 (基本 chmod) 已为 '$target_dir' 应用。未找到 setfacl 命令。"
    fi
}

sync_linux_to_win() {
    if ! acquire_lock "Linux → Windows"; then
        return
    fi

    # 添加去抖计时器
    if [ -z "$last_linux_event" ]; then
        last_linux_event=$(date +%s)
    else
        current_time=$(date +%s)
        elapsed=$((current_time - last_linux_event))

        # 如果1秒内有连续事件，合并处理
        if [ $elapsed -lt 1 ]; then
            log "⏱️ 合并连续事件（${elapsed}秒内）"
            return
        fi
        last_linux_event=$current_time
    fi
    
    touch "$LOCK_FILE"
    log "🔄 开始同步: Linux → Windows"
    
    # shellcheck disable=SC2068
    rsync -avz --no-owner --no-group --chmod=ugo=rwX \
          -e "ssh -p $SSH_PORT" \
          --rsync-path="$WIN_RSYNC_PATH" \
          --delete \
          ${RSYNC_EXCLUDES[@]} \
          "$LINUX_DIR/" \
          "$SSH_USER@$SSH_HOST:$WIN_CYGDRIVE_PATH/" 2>&1 | tee -a "$LOG_FILE"
    
    local exit_code=${PIPESTATUS[0]}
    if [ $exit_code -eq 0 ]; then
        log "✅ 同步成功: Linux → Windows"
    elif [ $exit_code -eq 23 ]; then
        log "⚠️  部分文件同步失败 (代码 23): Linux → Windows"
    else
        log "❌ 同步失败 [代码 $exit_code]: Linux → Windows"
    fi
    
    rm -f "$LOCK_FILE"
}

sync_win_to_linux() {
    if ! acquire_lock "Linux → Windows"; then
        return
    fi
    
    touch "$LOCK_FILE"
    log "🔄 开始同步: Windows → Linux"

    local rsync_output_file
    rsync_output_file=$(mktemp /tmp/rsync_win_out.XXXXXX) # 创建临时文件捕获rsync输出
    
    # shellcheck disable=SC2068
    rsync -avz --no-owner --no-group \
          -e "ssh -p $SSH_PORT" \
          --rsync-path="$WIN_RSYNC_PATH" \
          --delete \
          ${RSYNC_EXCLUDES[@]} \
          "$SSH_USER@$SSH_HOST:$WIN_CYGDRIVE_PATH/" \
          "$LINUX_DIR/" > "$rsync_output_file" | tee -a "$LOG_FILE"
    
    local exit_code=${PIPESTATUS[0]}
    if [ $exit_code -eq 0 ]; then
        log "✅ 同步成功: Windows → Linux"
        
        if grep -q -v -e '^sending incremental file list' -e '^sent .* bytes  received .* bytes' -e '^total size is .* speedup is' "$rsync_output_file"; then
            fix_linux_permissions "$LINUX_DIR"
            last_permission_reset=$(date +%s)
        else
            log "🔩 未检测到从 Windows 实际传输文件数据。跳过权限修复。"
        fi
    elif [ $exit_code -eq 23 ]; then
        log "⚠️  部分文件同步失败 (代码 23): Windows → Linux"
    else
        log "❌ 同步失败 [代码 $exit_code]: Windows → Linux"
    fi

    rm -f "$rsync_output_file" # 删除临时文件
    rm -f "$LOCK_FILE"
}

# 清理函数
cleanup() {
    log "🛑 接收到信号，停止所有进程..."
    pkill -P $$  # 终止所有子进程
    rm -f "$LOCK_FILE"
    exit 0
}

# 设置信号捕获
trap cleanup SIGINT SIGTERM

# 初始同步 - 修复死锁问题
log "🚀 脚本 ($SCRIPT_NAME PID:$$) 已启动。正在执行初始同步..."

# 先同步Linux到Windows
sync_linux_to_win

# 再同步Windows到Linux
sync_win_to_linux

log "🔔 初始同步完成($SCRIPT_NAME PID:$$)。"

# Linux 端监控
(
    log "🔍 开始监控 Linux 目录: $LINUX_DIR"
    inotifywait -m -r -e create,delete,modify,move \
                --exclude "$INOTIFY_EXCLUDE_PATTERN" \
                "$LINUX_DIR" |
    while read -r path action file; do
        log "📢 Linux 变化: $action $file (在路径 $path)"
        sync_linux_to_win
    done
) &

# Windows 端监控 (简化可靠的检测方法)
(
    log "🔍 开始监控 Windows 目录: $WIN_DIR"
    
    # 初始化状态
    previous_state=""
    last_sync_time=0
    
    while true; do
        sleep 5
        current_time=$(date +%s)
        
        # 如果最近有同步操作，跳过检测
        if [ $((current_time - last_sync_time)) -lt 5 ]; then
            continue
        fi
        
        # 获取当前文件系统状态
        current_state=$(ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
            "powershell -Command \"\
                \$items = Get-ChildItem -Recurse -Path '$WIN_DIR' -Exclude @('.git', '.svn', '.idea', '.vscode', 'node_modules', 'vendor', '*.log', '*.tmp', '.env', '*.swp', '~\$*') | \
                    Select-Object FullName, LastWriteTime, Length, @{Name='IsDirectory';Expression={\$_.PSIsContainer}}; \
                \$items | ConvertTo-Json\"" || continue)
        
        # 检查SSH命令是否成功
        if [ $? -ne 0 ]; then
            log "⚠️ Windows 监控: SSH命令执行失败，等待重试..."
            sleep 10
            continue
        fi
        
        # 如果为空，跳过
        if [ -z "$current_state" ]; then
            log "⚠️ Windows 监控: 当前状态为空，跳过检测"
            continue
        fi
        
        # 第一次运行，设置初始状态
        if [ -z "$previous_state" ]; then
            previous_state="$current_state"
            continue
        fi
        
        # 比较状态
        if [ "$previous_state" != "$current_state" ]; then
            log "📢 Windows 检测到变化"
            sync_win_to_linux
            previous_state="$current_state"
        fi
    done
) &

# 等待所有后台进程
wait
