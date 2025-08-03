#!/bin/bash
# 权限修复与防抖增强版 - 多项目双向实时监控同步脚本
# 作者: AMEI (基于原版修改)
# 版本: 3.0 (双向和解模型)
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

# --- 核心同步函数 (已参数化) ---

sync_linux_to_win() {
    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3"
    log "$project_name" "SYNC" "  L→W: 开始将 Linux 变更推送到 Windows"
    
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
        log "$project_name" "SYNC_DETAIL" "  --- rsync 输出 (L→W) ---"
        sed 's/^/    /g' "$rsync_output_file" | tee -a "$LOG_FILE"
        log "$project_name" "SYNC_DETAIL" "  --- 结束输出 ---"
    fi
    rm -f "$rsync_output_file"

    if [ $exit_code -ne 0 ]; then
        log "$project_name" "SYNC" "  ❌ L→W: 推送失败 [代码 $exit_code]"
    fi
}

#sync_win_to_linux() {
#    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3"
#    log "$project_name" "SYNC" "  W→L: 开始将 Windows 变更拉取到 Linux"
#    
#    local rsync_output_file; rsync_output_file=$(mktemp "/tmp/rsync_${project_name}_win_out.XXXXXX")
#
#    # shellcheck disable=SC2068
#    rsync -avzi --no-owner --no-group --delete \
#          -e "ssh -p $SSH_PORT" \
#          --rsync-path="$WIN_RSYNC_PATH" \
#          "${RSYNC_EXCLUDES[@]}" \
#          "$SSH_USER@$SSH_HOST:$win_cygdrive_path/" \
#          "$linux_dir/" > "$rsync_output_file" 2>&1
#    local exit_code=$?
#    
#    if [ -s "$rsync_output_file" ]; then
#       log "$project_name" "SYNC_DETAIL" "  --- rsync 输出 (W→L) ---"
#        sed 's/^/    /g' "$rsync_output_file" | tee -a "$LOG_FILE"
#        log "$project_name" "SYNC_DETAIL" "  --- 结束输出 ---"
#    fi
#    rm -f "$rsync_output_file"
#    
#    if [ $exit_code -ne 0 ]; then
#        log "$project_name" "SYNC" "  ❌ W→L: 拉取失败 [代码 $exit_code]"
#    fi
#}

# $1: project_name, $2: linux_dir, $3: win_cygdrive_path
sync_win_to_linux() {
    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3"
    log "$project_name" "SYNC" "  W→L: 开始将 Windows 变更拉取到 Linux"
    
    # --- 步骤 1: 更新已存在的文件，并处理删除 ---
    # --existing: 只更新在目标（Linux）上已经存在的文件。
    # -p: 保留这些已存在文件的权限。
    # --delete: 删除那些在源（Windows）上不存在的文件。
    # 这一步不会创建任何新文件。
    log "$project_name" "SYNC" "    - 步骤 1/2: 更新和删除已存在的文件..."
    rsync -rtzi --existing --delete \
          -e "ssh -p $SSH_PORT" \
          --rsync-path="$WIN_RSYNC_PATH" \
          "${RSYNC_EXCLUDES[@]}" \
          "$SSH_USER@$SSH_HOST:$win_cygdrive_path/" \
          "$linux_dir/"

    # --- 步骤 2: 添加新文件，并设置默认权限 ---
    # --ignore-existing: 不触摸任何已经存在的文件。
    # --chmod: 只为这一步创建的新文件和目录设置权限。
    # -l: 拷贝符号链接。
    # 注意：这里没有 -p (--perms) 选项，因为我们不关心源的权限。
    log "$project_name" "SYNC" "    - 步骤 2/2: 添加新文件并设置默认权限(D755, F644)..."
    rsync -rtzl --ignore-existing \
          --chmod=D755,F644 \
          -e "ssh -p $SSH_PORT" \
          --rsync-path="$WIN_RSYNC_PATH" \
          "${RSYNC_EXCLUDES[@]}" \
          "$SSH_USER@$SSH_HOST:$win_cygdrive_path/" \
          "$linux_dir/"
    
    # 由于我们分成了两步，统一在这里记录一个成功/失败信息
    # 这里的 exit_code 判断可以简化或移除，因为主要错误会在 rsync 执行时显示
    log "$project_name" "SYNC" "  ✅ W→L: 拉取完成。"
}

reconcile_and_sync() {
    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3" trigger_source="$4"
    
    log "$project_name" "RECONCILE" "🤝 开始双向和解 (由 ${trigger_source} 触发)..."
    
    if [[ "$trigger_source" == "linux" ]]; then
        # 顺序: L -> W, then W -> L
        log "$project_name" "RECONCILE" "  ➡️ 步骤 1/2: 推送 Linux 变更 (L→W)"
        sync_linux_to_win "$project_name" "$linux_dir" "$win_cygdrive_path"
        log "$project_name" "RECONCILE" "  ⬅️ 步骤 2/2: 拉取 Windows 变更 (W→L)"
        sync_win_to_linux "$project_name" "$linux_dir" "$win_cygdrive_path"
    else # trigger_source is "windows"
        # 顺序: W -> L, then L -> W
        log "$project_name" "RECONCILE" "  ⬅️ 步骤 1/2: 拉取 Windows 变更 (W→L)"
        sync_win_to_linux "$project_name" "$linux_dir" "$win_cygdrive_path"
        log "$project_name" "RECONCILE" "  ➡️ 步骤 2/2: 推送 Linux 变更 (L→W)"
        sync_linux_to_win "$project_name" "$linux_dir" "$win_cygdrive_path"
    fi

    log "$project_name" "RECONCILE" "✅ 双向和解完成。"
}


# --- 监控与触发器 (已参数化) ---

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

# ---【修改】L-SYNC 触发器 ---
debounce_and_sync_linux() {
    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3" \
          lock_file="$4" change_flag_file="$5"
          
    log "$project_name" "L-SYNC" "🚀 防抖和解服务已启动"
    while true; do
        while [ ! -f "$change_flag_file" ]; do sleep 0.5; done

        log "$project_name" "EVENT" "📢 检测到 Linux 变化，准备处理..."
        
        if acquire_lock "$project_name" "$lock_file" "Reconciliation from Linux"; then
            log "$project_name" "EVENT" "🟢 已获取锁，进入 2 秒稳定期..."
            while [ -f "$change_flag_file" ]; do
                rm -f "$change_flag_file"
                sleep 2
            done
            log "$project_name" "EVENT" "🟢 文件系统已稳定，触发双向和解。"

            # 调用核心和解函数
            reconcile_and_sync "$project_name" "$linux_dir" "$win_cygdrive_path" "linux"
            
            release_lock "$project_name" "$lock_file"
        else
            log "$project_name" "ABORT" "❌ [L-SYNC] 无法获取锁。"
        fi
    done
}

# ---【修改】W-MON 触发器 ---
monitor_windows_changes() {
    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3" \
          lock_file="$4"
          
    log "$project_name" "W-MON" "🔍 开始轮询监控 Windows (间隔 10s)"
    
    while true; do
        sleep 10
        
        local rsync_args=(-rtin --delete --no-owner --no-group -e "ssh -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" "${RSYNC_EXCLUDES[@]}" "$SSH_USER@$SSH_HOST:$win_cygdrive_path/" "$linux_dir/")
        local dry_run_output
        dry_run_output=$(rsync "${rsync_args[@]}" 2>&1)
        local exit_code=$?
        
        if [ $exit_code -ne 0 ] && [ $exit_code -ne 24 ]; then
            log "$project_name" "WARN" "⚠️ [W-MON] rsync dry-run 失败 [代码 $exit_code]。"
            log "$project_name" "WARN" "    - 错误信息: ${dry_run_output}"
            sleep 20; continue
        fi

        if echo "$dry_run_output" | grep -q -E '^[.><*c]'; then
            log "$project_name" "EVENT" "📢 [W-MON] 检测到 Windows 目录有变化"
            
            if acquire_lock "$project_name" "$lock_file" "Reconciliation from Windows"; then
                log "$project_name" "INFO" "[W-MON] 已获取锁，触发双向和解。"
                
                # 调用核心和解函数
                reconcile_and_sync "$project_name" "$linux_dir" "$win_cygdrive_path" "windows"

                release_lock "$project_name" "$lock_file"
            else
                log "$project_name" "INFO" "[W-MON] 锁被 L-SYNC 占用，将在下一轮检查时重试。"
            fi
        fi
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
                  "/tmp/${project_name}_change.flag"
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
        
        log "$project_name" "INIT" "--- 正在初始化项目: $project_name ---"
        log "$project_name" "INIT" "Linux 目录: $linux_dir"
        log "$project_name" "INIT" "Windows 目录: $win_dir -> $win_cygdrive_path"

        # 启动前清理旧的状态文件
        rm -f "$lock_file" "$change_flag_file"

        # 初始同步：执行一次完整的双向和解，确保启动时状态一致
        log "$project_name" "INIT" "执行初始双向和解..."
        reconcile_and_sync "$project_name" "$linux_dir" "$win_cygdrive_path" "linux"
        log "$project_name" "INIT" "✅ 初始和解完成。"

        # 启动后台监控进程
        monitor_linux_changes "$project_name" "$linux_dir" "$change_flag_file" &
        ALL_PIDS+=($!)
        
        debounce_and_sync_linux "$project_name" "$linux_dir" "$win_cygdrive_path" "$lock_file" "$change_flag_file" &
        ALL_PIDS+=($!)

        monitor_windows_changes "$project_name" "$linux_dir" "$win_cygdrive_path" "$lock_file" &
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
