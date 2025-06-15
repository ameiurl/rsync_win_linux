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
    if [ ${#ignored_paths[@]} -gt 0 ]; then
        log "    - 忽略以下路径: ${ignored_paths[*]}"
    fi

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
    
    # 临时文件用于捕获 rsync 的详细输出
    local rsync_output_file
    rsync_output_file=$(mktemp /tmp/rsync_linux_out.XXXXXX)

    # ★★★ 关键修改 ★★★
    # 1. 添加 -i (--itemize-changes) 参数用于详细诊断
    # 2. 将标准输出和错误都重定向到临时文件
    # shellcheck disable=SC2068
    rsync -avzi --no-owner --no-group --delete \
          -e "ssh -p $SSH_PORT" \
          --rsync-path="$WIN_RSYNC_PATH" \
          "${RSYNC_EXCLUDES[@]}" \
          "$LINUX_DIR/" \
          "$SSH_USER@$SSH_HOST:$WIN_CYGDRIVE_PATH/" > "$rsync_output_file" 2>&1

    # 3. 使用 $? 而不是 ${PIPESTATUS[0]}
    local exit_code=$?
    
    # 将 rsync 的详细输出打印到主日志文件
    if [ -s "$rsync_output_file" ]; then
        log "SYNC_DETAIL" "--- rsync 输出 ---"
        # 使用 sed 添加缩进，方便阅读
        sed 's/^/    /g' "$rsync_output_file" | tee -a "$LOG_FILE"
        log "SYNC_DETAIL" "--- 结束输出 ---"
    fi
    
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
    
    # 临时文件用于捕获 rsync 的详细输出
    local rsync_output_file
    rsync_output_file=$(mktemp /tmp/rsync_win_out.XXXXXX)

    # ★★★ 关键修改 ★★★
    # 1. 添加 -i (--itemize-changes) 参数用于详细诊断
    # 2. 将标准输出和错误都重定向到临时文件
    # shellcheck disable=SC2068
    rsync -avzi --no-owner --no-group --delete \
          -e "ssh -p $SSH_PORT" \
          --rsync-path="$WIN_RSYNC_PATH" \
          "${RSYNC_EXCLUDES[@]}" \
          "$SSH_USER@$SSH_HOST:$WIN_CYGDRIVE_PATH/" \
          "$LINUX_DIR/" > "$rsync_output_file" 2>&1

    # 3. 使用 $? 而不是 ${PIPESTATUS[0]}
    local exit_code=$?
    
    # 将 rsync 的详细输出打印到主日志文件
    if [ -s "$rsync_output_file" ]; then
        log "SYNC_DETAIL" "--- rsync 输出 (Win→Lin) ---"
        # 使用 sed 添加缩进，方便阅读
        sed 's/^/    /g' "$rsync_output_file" | tee -a "$LOG_FILE"
        log "SYNC_DETAIL" "--- 结束输出 ---"
    fi
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
            # 将检测到的标志消耗掉
            rm -f "$LINUX_CHANGE_FLAG"
            # 等待一小段“安静”时间
            sleep 2
            # 循环会再次检查在这 2 秒内，`monitor_linux_changes` 是否又创建了新的标志文件。
            # 如果创建了，说明变化仍在继续，循环将继续。
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

        # 3. 如果能跳出上面的 while 循环，说明我们刚刚经历了完整的 2 秒“安静期”，
        #    文件系统已经稳定。现在是执行同步的最佳时机。
        log "EVENT" "🟢 文件系统已稳定，执行同步操作。"
        sync_linux_to_win
    done
}

### ★★★ 最终修正版 v3：添加时间戳检查 ★★★
monitor_windows_changes() {
    log "INFO" "🔍 [W-MON] 开始轮询监控 Windows 目录 (使用 rsync dry-run, 间隔 10s)"
    
    while true; do
        # -t 参数是检查文件修改的关键！
        local rsync_args=(
            -rtin           # ★★★ 关键修正：添加 -t (--times) 参数 ★★★
            --delete 
            --no-owner 
            --no-group
            -e "ssh -p $SSH_PORT"
            --rsync-path="$WIN_RSYNC_PATH"
            "${RSYNC_EXCLUDES[@]}"
            "$SSH_USER@$SSH_HOST:$WIN_CYGDRIVE_PATH/"
            "$LINUX_DIR/"
        )

        local dry_run_output
        dry_run_output=$(rsync "${rsync_args[@]}" 2>&1)
        local exit_code=$?
        
        # 仅当 rsync 本身执行失败时（如连接中断）才认为是错误
        if [ $exit_code -ne 0 ]; then
            if [ $exit_code -eq 24 ]; then
                log "DEBUG" "[W-MON] rsync dry-run 返回 code 24 (文件在传输中消失)，忽略。"
            else
                log "WARN" "⚠️ [W-MON] rsync dry-run 严重失败 [代码 $exit_code]。检查连接或远程路径。"
                log "WARN" "    - 错误信息: ${dry_run_output}"
                sleep 30 
                continue
            fi
        fi

        # 使用能匹配文件和目录变化的正则表达式
        if echo "$dry_run_output" | grep -q -E '^[.><*c]'; then
            log "EVENT" "📢 [W-MON] 检测到 Windows 目录有变化"
            log "DEBUG" "[W-MON] Matched changes:"
            echo "$dry_run_output" | grep -E '^[.><*c]' | while IFS= read -r line; do log "DEBUG" "[W-MON]   - $line"; done

            # 回声抑制逻辑
            local last_dir="" last_time=0
            if [ -f "$LAST_SYNC_DIR_FILE" ]; then last_dir=$(cat "$LAST_SYNC_DIR_FILE"); fi
            if [ -f "$LAST_SYNC_TIME_FILE" ]; then last_time=$(cat "$LAST_SYNC_TIME_FILE"); fi
            local current_time; current_time=$(date +%s)

            if [[ "$last_dir" == "L2W" && $((current_time - last_time)) -lt $SILENCE_PERIOD ]]; then
                log "SILENCE" "🔇 [W-MON] 忽略 Windows 变化 (回声抑制)"
            else
                sync_win_to_linux
            fi
        fi

        sleep 10
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

