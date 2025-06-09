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
LOG_FILE="/var/log/mallphp_sync.log"
LOCK_FILE="/tmp/rsync_mallphp.lock"
MAX_WAIT=60 # 增加锁定等待时间
# 设置普通用户（修改为你的实际用户名）
NORMAL_USER="amei"
NORMAL_GROUP="amei"

# 创建日志目录
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# 初始化去抖计时器
LAST_LINUX_EVENT=0
LAST_WIN_EVENT=0
LAST_PERMISSION_RESET=0

source "$(dirname "$0")/sync_common.sh"
