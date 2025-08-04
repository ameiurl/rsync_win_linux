#!/bin/bash
# 权限修复与防抖增强版 - 多项目双向实时监控同步脚本
# 作者: AMEI (基于原版修改)
# 版本: 3.2 (最终美化版)
# 功能: 支持同时监控和同步多个独立的目录对，并正确处理交叉变更。

# --- 全局配置 (所有项目共享) ---
SSH_USER="amei"
SSH_HOST="192.168.1.3"
SSH_PORT="22"
WIN_RSYNC_PATH="\"D:/Program Files (x86)/cwRsync/bin/rsync.exe\"" # 注意引号的使用
# LOG_FILE="/var/log/multi_sync.log"
LOG_FILE="/home/amei/multi_sync.log"
PID_FILE="/tmp/multi_sync.pid"

# 权限修复相关
NORMAL_USER="amei"
NORMAL_GROUP="amei"

# --- 项目配置 (关键改动) ---
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
RSYNC_EXCLUDES=(
    "--exclude=.git/" "--exclude=.svn/" "--exclude=.idea/" "--exclude=.vscode/"
    "--exclude=node_modules/" "--exclude=runtime/" "--exclude=unpackage/" "--exclude=cache/"
    "--exclude=/config/database.local.php" "--exclude=*.bak" "--exclude=.env"
    "--exclude=*.log" "--exclude=*.tmp" "--exclude=*.swp" "--exclude=~$*"
)

# inotifywait ERE 正则表达式格式
INOTIFY_EXCLUDE_PATTERN='(\.git/|\.svn/|\.idea/|\.vscode/|node_modules/|runtime/|unpackage/|cache/|^config/database\.local\.php$|\.bak$|\.env$|\.log$|\.tmp$|\.swp$|^~\$.*)'
INOTIFY_EXCLUDE_PATTERN=$(echo "$INOTIFY_EXCLUDE_PATTERN" | tr -d ' \n')

# --- 工具函数 ---

# 【日志优化】日志函数，增加颜色和格式
log() {
    local project_name="$1"
    local level="$2"
    local message="$3"
    
    # 定义颜色
    local C_RESET='\033[0m'
    local C_CYAN='\033[0;36m'
    local C_GREEN='\033[0;32m'
    local C_YELLOW='\033[0;33m'
    local C_RED='\033[0;31m'
    local C_BLUE='\033[0;34m'
    local C_GRAY='\033[0;90m'

    local color=""
    local symbol=""
    case "$level" in
        "EVENT")    color="$C_CYAN";   symbol="📢" ;;
        "RECONCILE")color="$C_GREEN";  symbol="🤝" ;;
        "SYNC")     color="$C_BLUE";   symbol="🔄" ;;
        "LOCK")     color="$C_YELLOW"; symbol="🔒" ;;
        "INFO")     color="$C_GRAY";   symbol="ℹ️" ;;
        "INIT")     color="$C_GREEN";  symbol="🚀" ;;
        "L-MON")    color="$C_GRAY";   symbol="🐧" ;;
        "W-MON")    color="$C_GRAY";   symbol="🪟" ;;
        "ERROR")    color="$C_RED";    symbol="❌" ;;
        *)          color="$C_RESET";  symbol="➡️" ;;
    esac

    # 对 SYNC_DETAIL 特殊处理，增加缩进
    if [[ "$level" == "SYNC_DETAIL" ]]; then
        echo -e "    $message" | tee -a "$LOG_FILE"
    else
        echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${C_GREEN}[$project_name]${C_RESET} ${color}${symbol} $message${C_RESET}" | tee -a "$LOG_FILE"
    fi
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


# --- 核心同步函数 (已参数化) ---

sync_linux_to_win() {
    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3"
    log "$project_name" "SYNC" "L→W: 推送 Linux 变更到 Windows"
    
    local rsync_output_file; rsync_output_file=$(mktemp "/tmp/rsync_${project_name}_linux_out.XXXXXX")

    rsync -avzi --no-owner --no-group --delete \
          -e "ssh -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" \
          "${RSYNC_EXCLUDES[@]}" "$linux_dir/" "$SSH_USER@$SSH_HOST:$win_cygdrive_path/" > "$rsync_output_file" 2>&1
    local exit_code=$?
    
    if [ -s "$rsync_output_file" ]; then
        log "$project_name" "SYNC_DETAIL" "--- rsync 输出 (L→W) ---"
        sed 's/^/    /g' "$rsync_output_file" | tee -a "$LOG_FILE" > /dev/null
        log "$project_name" "SYNC_DETAIL" "--- 结束输出 ---"
    fi
    rm -f "$rsync_output_file"

    if [ $exit_code -ne 0 ]; then
        log "$project_name" "ERROR" "L→W 推送失败 [代码 $exit_code]"
    fi
}

sync_win_to_linux() {
    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3"
    log "$project_name" "SYNC" "W→L: 拉取 Windows 变更到 Linux"
    
    local rsync_output_file; rsync_output_file=$(mktemp "/tmp/rsync_${project_name}_win_out.XXXXXX")
    local final_exit_code=0

    log "$project_name" "INFO" "步骤 1/2: 更新和删除..."
    rsync -rtzi --existing --delete \
          -e "ssh -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" \
          "${RSYNC_EXCLUDES[@]}" "$SSH_USER@$SSH_HOST:$win_cygdrive_path/" "$linux_dir/" >> "$rsync_output_file" 2>&1
    local exit_code_step1=$?
    if [ $exit_code_step1 -ne 0 ]; then final_exit_code=$exit_code_step1; fi

    log "$project_name" "INFO" "步骤 2/2: 新增文件 (权限 D755, F644)..."
    rsync -rtzl --ignore-existing --chmod=D755,F644 \
          -e "ssh -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" \
          "${RSYNC_EXCLUDES[@]}" "$SSH_USER@$SSH_HOST:$win_cygdrive_path/" "$linux_dir/" >> "$rsync_output_file" 2>&1
    local exit_code_step2=$?
    if [ $exit_code_step2 -ne 0 ]; then final_exit_code=$exit_code_step2; fi

    if [ -s "$rsync_output_file" ]; then
       log "$project_name" "SYNC_DETAIL" "--- rsync 综合输出 (W→L) ---"
        sed 's/^/    /g' "$rsync_output_file" | tee -a "$LOG_FILE" > /dev/null
        log "$project_name" "SYNC_DETAIL" "--- 结束输出 ---"
    fi
    rm -f "$rsync_output_file"
    
    if [ $final_exit_code -ne 0 ]; then
        log "$project_name" "ERROR" "W→L 拉取过程中发生错误 [代码 $final_exit_code]"
    fi
}

# --- 核心和解函数 ---
reconcile_and_sync() {
    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3" trigger_source="$4"
    
    echo | tee -a "$LOG_FILE" # 输出一个空行
    echo | tee -a "$LOG_FILE" # 输出一个空行
    
    if [[ "$trigger_source" == "linux" ]]; then
        sync_linux_to_win "$project_name" "$linux_dir" "$win_cygdrive_path"
        sync_win_to_linux "$project_name" "$linux_dir" "$win_cygdrive_path"
    else 
        sync_win_to_linux "$project_name" "$linux_dir" "$win_cygdrive_path"
        sync_linux_to_win "$project_name" "$linux_dir" "$win_cygdrive_path"
    fi
}

# --- 监控与触发器 (已参数化) ---

monitor_linux_changes() {
    local project_name="$1" linux_dir="$2" change_flag_file="$3"
    log "$project_name" "L-MON" "开始监控 Linux: $linux_dir"
    inotifywait -m -r -q -e create,delete,modify,move \
                --excludei "$INOTIFY_EXCLUDE_PATTERN" \
                "$linux_dir" |
    while read -r path action file; do
        touch "$change_flag_file"
    done
}

debounce_and_sync_linux() {
    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3" \
          lock_file="$4" change_flag_file="$5"
          
    log "$project_name" "L-SYNC" "防抖和解服务已启动。"
    while true; do
        while [ ! -f "$change_flag_file" ]; do sleep 0.5; done

        log "$project_name" "EVENT" "检测到 Linux 变化，准备处理..."
        
        if acquire_lock "$project_name" "$lock_file" "Reconciliation from Linux"; then
            log "$project_name" "INFO" "已获取锁，进入 2 秒稳定期..."
            while [ -f "$change_flag_file" ]; do
                rm -f "$change_flag_file"
                sleep 2
            done
            log "$project_name" "INFO" "文件系统已稳定。"

            reconcile_and_sync "$project_name" "$linux_dir" "$win_cygdrive_path" "linux"
            
            release_lock "$project_name" "$lock_file"
        fi
    done
}

monitor_windows_changes() {
    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3" \
          lock_file="$4"
          
    log "$project_name" "W-MON" "开始轮询 Windows (间隔 10s)..."
    
    while true; do
        sleep 10
        
        local rsync_args=(-rtin --delete --no-owner --no-group -e "ssh -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" "${RSYNC_EXCLUDES[@]}" "$SSH_USER@$SSH_HOST:$win_cygdrive_path/" "$linux_dir/")
        local dry_run_output
        dry_run_output=$(rsync "${rsync_args[@]}" 2>&1)
        local exit_code=$?
        
        if [ $exit_code -ne 0 ] && [ $exit_code -ne 24 ]; then
            log "$project_name" "ERROR" "W-MON rsync dry-run 失败 [代码 $exit_code]。"
            log "$project_name" "INFO" "错误信息: ${dry_run_output}"
            sleep 20; continue
        fi

        if echo "$dry_run_output" | grep -q -E '^[.><*c]'; then
            log "$project_name" "EVENT" "检测到 Windows 目录有变化"
            
            if acquire_lock "$project_name" "$lock_file" "Reconciliation from Windows"; then
                reconcile_and_sync "$project_name" "$linux_dir" "$win_cygdrive_path" "windows"
                release_lock "$project_name" "$lock_file"
            fi
        fi
    done
}

# --- 脚本主程序 ---
main() {
    # 检查全局 PID 文件
    if [ -f "$PID_FILE" ] && ps -p "$(cat "$PID_FILE")" > /dev/null; then
        echo -e "\033[0;31m❌ 主脚本已在运行 (PID: $(cat "$PID_FILE"))。请先停止旧实例。\033[0m"
        exit 1
    fi
    echo $$ > "$PID_FILE"

    # 清理函数
    cleanup() {
        echo -e "\n\033[0;33m🛑 接收到信号，正在清理并退出...\033[0m"
        rm -f "$PID_FILE"
        
        for project_name in "${PROJECT_NAMES[@]}"; do
            rm -f "/tmp/rsync_${project_name}.lock" "/tmp/${project_name}_change.flag"
        done

        if [ ${#ALL_PIDS[@]} -gt 0 ]; then
            echo -e "\033[0;33mℹ️  正在停止所有子进程: ${ALL_PIDS[*]}\033[0m"
            kill "${ALL_PIDS[@]}"
        fi
        echo -e "\033[0;32m👋 脚本已停止。\033[0m"
        exit 0
    }
    trap cleanup SIGINT SIGTERM

    # 【日志优化】在启动时增加一个清晰的标题和空行
    echo | tee -a "$LOG_FILE"
    log "MAIN" "INIT" "================== 脚本启动 =================="

    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE" || { echo "错误：无法创建或写入日志文件 $LOG_FILE"; exit 1; }
    
    for i in "${!PROJECT_NAMES[@]}"; do
        local project_name="${PROJECT_NAMES[i]}"
        local linux_dir="${LINUX_DIRS[i]}"
        local win_dir="${WIN_DIRS[i]}"
        
        local win_cygdrive_path="/cygdrive/$(echo "$win_dir" | sed 's/\\/\//g' | sed 's/://')"
        local lock_file="/tmp/rsync_${project_name}.lock"
        local change_flag_file="/tmp/${project_name}_change.flag"
        
        log "$project_name" "INIT" "初始化项目: $project_name"
        log "$project_name" "INFO" "Linux 目录: $linux_dir"
        log "$project_name" "INFO" "Windows 目录: $win_dir -> $win_cygdrive_path"

        rm -f "$lock_file" "$change_flag_file"

        reconcile_and_sync "$project_name" "$linux_dir" "$win_cygdrive_path" "startup"
        
        monitor_linux_changes "$project_name" "$linux_dir" "$change_flag_file" &
        ALL_PIDS+=($!)
        debounce_and_sync_linux "$project_name" "$linux_dir" "$win_cygdrive_path" "$lock_file" "$change_flag_file" &
        ALL_PIDS+=($!)
        monitor_windows_changes "$project_name" "$linux_dir" "$win_cygdrive_path" "$lock_file" &
        ALL_PIDS+=($!)
    done

    log "MAIN" "INIT" "所有项目的监控进程已启动。"
    log "MAIN" "INFO" "所有子进程 PIDs: ${ALL_PIDS[*]}"
    log "MAIN" "INFO" "日志文件位于: $LOG_FILE"
    echo -e "\033[0;32m✅ 脚本正在后台运行，按 Ctrl+C 停止。\033[0m"

    wait
}

# --- 执行 ---
main "$@"
