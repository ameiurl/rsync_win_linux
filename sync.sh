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

### 新增：同步静默功能相关配置 ###
# 用于防止同步回声的状态文件
LAST_SYNC_DIR_FILE="/tmp/mallphp_last_sync_dir"
LAST_SYNC_TIME_FILE="/tmp/mallphp_last_sync_time"
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

source "$(dirname "$0")/sync_common.sh"
