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

fix_linux_permissions() {
    local target_dir="$1"
    log "PERMS" "🔧 正在为 '$target_dir' 应用标准权限 (User: $NORMAL_USER)"

    # 使用 sudo (如果需要且可用)
    local SUDO_CMD=""
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null; then
            SUDO_CMD="sudo"
        else
            log "PERMS" "⚠️ 警告: 非 root 用户且无 sudo 命令，权限修复可能不完整。"
        fi
    fi

    # 批量修复，更高效
    $SUDO_CMD chown -R "$NORMAL_USER:$NORMAL_GROUP" "$target_dir"
    $SUDO_CMD find "$target_dir" -type d -exec chmod 755 {} +
    $SUDO_CMD find "$target_dir" -type f -exec chmod 644 {} +
    log "PERMS" "🔩 基本权限 (chown/chmod) 已应用。"
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
        
        # 权限修复逻辑保持不变
        if [ -n "$(find "$LINUX_DIR" -not \( -user "$NORMAL_USER" -and -group "$NORMAL_GROUP" \) -print -quit)" ]; then
            log "PERMS" "🔩 检测到权限不匹配，开始修复..."
            fix_linux_permissions "$LINUX_DIR"
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

# 防抖处理循环
debounce_and_sync_linux() {
    log "INFO" "🚀 [L-SYNC] 防抖同步服务已启动"
    while true; do
        # 等待标志文件出现
        while [ ! -f "$LINUX_CHANGE_FLAG" ]; do
            sleep 1
        done

        # 标志出现，开始防抖计时
        log "EVENT" "📢 检测到 Linux 变化，启动 3 秒防抖计时器..."
        rm -f "$LINUX_CHANGE_FLAG" # 消耗掉旧的标志
        sleep 3 # 防抖窗口

        # 如果在 3 秒内又有新变化（标志文件被再次创建），则循环到下一次，重新计时
        if [ -f "$LINUX_CHANGE_FLAG" ]; then
            log "EVENT" "⏱️ 防抖期间检测到新变化，重置计时器。"
            continue
        fi

        # 计时结束且无新变化，执行同步
        log "EVENT" "🟢 防抖计时结束，执行同步操作。"
        sync_linux_to_win
    done
}


monitor_windows_changes() {
    log "INFO" "🔍 [W-MON] 开始轮询监控 Windows 目录: $WIN_DIR (间隔 10s)"
    local previous_state=""
    
    while true; do
        # 获取当前文件系统状态快照
        # 增加了错误处理，如果ssh失败，则循环继续而不是退出
        local current_state
        current_state=$(ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
            "powershell -Command \"Get-ChildItem -Recurse -Path '$WIN_DIR' -Exclude @('.git', '.svn', '.idea', '.vscode', 'node_modules', 'vendor', 'runtime', '*.log', '*.tmp', '.env', '*.swp', '~\$*') | Select-Object FullName, LastWriteTime, Length | Sort-Object FullName | ConvertTo-Json -Compress\"" 2>/dev/null)
        
        # 如果命令失败或返回空，则跳过本次检查
        if [ -z "$current_state" ]; then
            log "WARN" "⚠️ [W-MON] 无法获取 Windows 目录状态 (网络或权限问题?)，15秒后重试。"
            sleep 15
            continue
        fi
        
        # 首次运行时初始化状态
        if [ -z "$previous_state" ]; then
            previous_state="$current_state"
            sleep 10 # 初始化的等待时间
            continue
        fi
        
        # 比较快照
        if [ "$previous_state" != "$current_state" ]; then
            log "EVENT" "📢 检测到 Windows 目录状态变化"
            sync_win_to_linux
            # 同步后立即更新状态，避免重复触发
            previous_state=$(ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
            "powershell -Command \"Get-ChildItem -Recurse -Path '$WIN_DIR' -Exclude @('.git', '.svn', '.idea', '.vscode', 'node_modules', 'vendor', 'runtime', '*.log', '*.tmp', '.env', '*.swp', '~\$*') | Select-Object FullName, LastWriteTime, Length | Sort-Object FullName | ConvertTo-Json -Compress\"" 2>/dev/null)
        fi

        sleep 10 # 轮询间隔
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

