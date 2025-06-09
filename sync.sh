#!/bin/bash
# 权限修复与防抖增强版 - 双向实时监控同步脚本
# 解决了高频文件变更导致的同步中断问题

# --- 配置参数 ---
SSH_USER="amei"
SSH_HOST="192.168.1.3"
SSH_PORT="22"
LINUX_DIR="/server/www/mallphp"
WIN_DIR="D:\\www\\mallphp" # PowerShell/Windows 路径
WIN_CYGDRIVE_PATH="/cygdrive/d/www/mallphp" # Cygwin 路径 (用于 rsync)
WIN_RSYNC_PATH="\"D:/Program Files (x86)/cwRsync/bin/rsync.exe\"" # 注意引号的使用

LOG_FILE="/var/log/mallphp_sync.log"
LOCK_FILE="/tmp/rsync_mallphp.lock"
PID_FILE="/tmp/mallphp_sync.pid"

# 用于防抖的临时标志文件
LINUX_CHANGE_FLAG="/tmp/linux_change.flag"

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
    "--exclude=.env"
    "--exclude=*.log"
    "--exclude=*.tmp"
    "--exclude=*.swp"
    "--exclude=~$*"
)
# inotifywait ERE 正则表达式格式
INOTIFY_EXCLUDE_PATTERN='(\.git/|\.svn/|\.idea/|\.vscode/|node_modules/|vendor/|runtime/|\.env$|\.log$|\.tmp$|\.swp$|^~\$.*)'

# --- 核心功能函数 ---

source "$(dirname "$0")/sync_common.sh"
