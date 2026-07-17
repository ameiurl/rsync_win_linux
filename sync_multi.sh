#!/bin/bash
# 基于 syncd 架构的多项目双向实时同步脚本
# 采用 FIFO 事件聚合模式，同步期间变更不丢失
# 版本: 6.0

# ============================================================================
# 配置
# ============================================================================
SYNC_MODE="bidirectional"   # bidirectional | unidirectional

SSH_USER="Administrator"
SSH_HOST="192.168.1.9"
# SSH_USER="amei"
# SSH_HOST="192.168.1.3"
SSH_PORT="22"
WIN_RSYNC_PATH="\"D:/Program Files (x86)/cwRsync/bin/rsync.exe\""

RETRY_MAX=10
LOG_FILE="/home/amei/multi_sync.log"
PID_FILE="/tmp/multi_sync.pid"
STATE_DIR="/tmp/sync_state"

PROJECT_BASE_NAMES=(
    "mallphp"
    "admin_frontend"
    "store_uniapp"
    "admin_diy_frontend"
)

RSYNC_EXCLUDES=(
    "--exclude=.git/" "--exclude=.svn/" "--exclude=.idea/" "--exclude=.vscode/"
    "--exclude=node_modules/" "--exclude=runtime/" "--exclude=unpackage/" "--exclude=cache/"
    "--exclude=/config/database.local.php" "--exclude=*.bak" "--exclude=.env" "--exclude=.env.development"
    "--exclude=*.log" "--exclude=*.tmp" "--exclude=*.swp" "--exclude=*.zip" "--exclude=~$*"
)

INOTIFY_EXCLUDE_PATTERN='(\.git/|\.svn/|\.idea/|\.vscode/|node_modules/|runtime/|unpackage/|cache/|^config/database\.local\.php$|\.bak$|\.env$|\.log$|\.tmp$|\.swp$|^~\$.*)'

# ============================================================================
# 初始化
# ============================================================================
PROJECT_NAMES=()
LINUX_DIRS=()
WIN_DIRS=()
ALL_PIDS=()

for name in "${PROJECT_BASE_NAMES[@]}"; do
    PROJECT_NAMES+=("$name")
    LINUX_DIRS+=("/server/www/$name")
    WIN_DIRS+=("D:\\www\\$name")
done

# ============================================================================
# 工具函数
# ============================================================================
log() {
    local proj="$1" level="$2" msg="$3"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    local color="" sym=""
    case "$level" in
        SYNC)   color='\033[0;36m'; sym="🔄" ;;
        EVENT)  color='\033[0;32m'; sym="📢" ;;
        ERROR)  color='\033[0;31m'; sym="❌" ;;
        INIT)   color='\033[0;32m'; sym="🚀" ;;
        SKIP)   color='\033[0;35m'; sym="⏭️" ;;
        OK)     color='\033[0;32m'; sym="✅" ;;
        WARN)   color='\033[0;33m'; sym="⚠️"  ;;
        *)      color='\033[0;90m'; sym="ℹ️"  ;;
    esac
    echo -e "[$ts] ${color}${sym} [${proj}]${color} ${msg}\033[0m" | tee -a "$LOG_FILE"
}

is_bidirectional() { [[ "$SYNC_MODE" == "bidirectional" ]]; }

to_cygdrive() {
    local w="$1"
    local drive="${w:0:1}"
    local path="${w:3}"
    path="${path//\\//}"
    echo "/cygdrive/${drive,,}/${path}"
}

ssh_dest() { echo "${SSH_USER}@${SSH_HOST}"; }

# ============================================================================
# 全局 rsync 互斥锁（避免多个 rsync 同时连接 cwRsync 导致 error 12）
# ============================================================================
GLOBAL_LOCK="/tmp/rsync_global.lock"

acquire_global_lock() {
    local holder
    while ! (set -o noclobber; echo "$$" > "$GLOBAL_LOCK") 2>/dev/null; do
        holder=$(cat "$GLOBAL_LOCK" 2>/dev/null)
        if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
            rm -f "$GLOBAL_LOCK"  # 死锁清理
        fi
        sleep 0.5
    done
}

release_global_lock() {
    rm -f "$GLOBAL_LOCK"
}

# ============================================================================
# 带重试的 rsync 执行（全局互斥）
# ============================================================================
run_rsync() {
    local label="$1" output_file="$2"; shift 2
    local attempt=1 delay exit_code

    acquire_global_lock "$label"
    while [ $attempt -le $RETRY_MAX ]; do
        rsync "$@" > "$output_file" 2>&1
        exit_code=$?

        if { [ $exit_code -eq 12 ] || [ $exit_code -eq 23 ] || [ $exit_code -eq 11 ]; } && [ $attempt -lt $RETRY_MAX ]; then
            delay=$((1 + RANDOM % 4))
            log "$label" "WARN" "错误 [${exit_code}], 重试 ${attempt}/${RETRY_MAX} (${delay}s)..."
            sleep "$delay"
            ((attempt++))
            continue
        fi
        break
    done
    release_global_lock
    return $exit_code
}

# ============================================================================
# 状态追踪（防回环，仅双向模式）
# ============================================================================
ensure_state_dir() {
    is_bidirectional || return
    mkdir -p "$STATE_DIR"
    for p in "${PROJECT_NAMES[@]}"; do
        mkdir -p "$STATE_DIR/$p"
    done
}

record_sync() {
    is_bidirectional || return
    date +%s > "$STATE_DIR/$1/last_$2"
}

should_skip() {
    # $1 = project name, $2 = 要检查的反方向 (e.g. 当前要 L→W，检查 W2L)
    is_bidirectional || return 1
    local proj="$1" opposite="${2:-}"
    local f="$STATE_DIR/$proj/last_${opposite}"
    [ ! -f "$f" ] && return 1

    local now=$(date +%s)
    local last=$(cat "$f")
    [ $((now - last)) -lt 10 ] && return 0
    return 1
}

# ============================================================================
# 核心同步函数
# ============================================================================
sync_linux_to_win() {
    local proj="$1" ldir="$2" wdir="$3"
    local is_init="${4:-false}"   # 初始同步不检查防回环

    if ! $is_init; then
        should_skip "$proj" "W2L" && { log "$proj" "SKIP" "跳过 L→W (刚刚 W→L)"; return 0; }
    fi

    local tmp=$(mktemp "/tmp/rsync_l2w_${proj}.XXXXXX")
    local rc=0

    run_rsync "$proj" "$tmp" \
        -avzi --update --delete --no-owner --no-group \
        --modify-window=2 --omit-dir-times \
        -e "ssh -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" \
        "${RSYNC_EXCLUDES[@]}" \
        "$ldir/" "$(ssh_dest):$wdir/"
    rc=$?

    if [ $rc -eq 0 ] || [ $rc -eq 24 ]; then
        local changes=$(grep -E '^[><cfhpguax*]' "$tmp" 2>/dev/null | wc -l)
        if [ "$changes" -gt 0 ]; then
            log "$proj" "SYNC" "L→W: ${changes} 个文件变更"
            if [ "$changes" -le 20 ]; then
                grep -E '^[><cfhpguax*]' "$tmp" | while IFS= read -r l; do
                    log "$proj" "SYNC" "  $l"
                done
            else
                log "$proj" "SYNC" "  (前5条) ..."
                grep -E '^[><cfhpguax*]' "$tmp" | head -5 | while IFS= read -r l; do
                    log "$proj" "SYNC" "  $l"
                done
            fi
            record_sync "$proj" "L2W"   # 仅实际有变更时记录时间戳
            # L→W 完成后，inotify 侧 3 秒内忽略所有事件
            # 防止 rsync 在 Windows 端写入文件后引发 inotify 回音
            is_bidirectional && echo $(($(date +%s) + 3)) > "$STATE_DIR/$proj/ignore_until"
        fi
    else
        log "$proj" "ERROR" "L→W 失败 (exit=$rc)"
    fi
    rm -f "$tmp"
    return $rc
}

sync_win_to_linux() {
    is_bidirectional || return 0
    local proj="$1" ldir="$2" wdir="$3"
    local is_init="${4:-false}"

    if ! $is_init; then
        should_skip "$proj" "L2W" && { log "$proj" "SKIP" "跳过 W→L (刚刚 L→W)"; return 0; }
    fi

    local tmp=$(mktemp "/tmp/rsync_w2l_${proj}.XXXXXX")
    local rc=0

    # W→L: 只新增和更新，不删除（避免竞态删除 Linux 新创建的文件/目录）
    # 删除统一由 L→W 方向的 --delete 控制
    run_rsync "$proj" "$tmp" \
        -rtzi --update --no-owner --no-group --no-perms \
        --modify-window=2 --omit-dir-times \
        -e "ssh -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" \
        "${RSYNC_EXCLUDES[@]}" \
        "$(ssh_dest):$wdir/" "$ldir/"
    rc=$?

    if [ $rc -eq 0 ] || [ $rc -eq 24 ]; then
        local changes=$(grep -E '^[><cfhpguax*]' "$tmp" 2>/dev/null | wc -l)
        if [ "$changes" -gt 0 ]; then
            log "$proj" "SYNC" "W→L: ${changes} 个文件变更"
            if [ "$changes" -le 20 ]; then
                grep -E '^[><cfhpguax*]' "$tmp" | while IFS= read -r l; do
                    log "$proj" "SYNC" "  $l"
                done
            else
                log "$proj" "SYNC" "  (前5条) ..."
                grep -E '^[><cfhpguax*]' "$tmp" | head -5 | while IFS= read -r l; do
                    log "$proj" "SYNC" "  $l"
                done
            fi
            record_sync "$proj" "W2L"
        fi
    else
        log "$proj" "ERROR" "W→L 失败 (exit=$rc)"
    fi
    rm -f "$tmp"
    return $rc
}

# ============================================================================
# Linux 监控 + syncd FIFO 事件聚合
# ============================================================================
linux_watcher() {
    local proj="$1" ldir="$2" wdir="$3"
    log "$proj" "INIT" "Linux 监控启动 (FIFO 聚合模式)"

    local run_pipe result_pipe pid waiting
    run_pipe=$(mktemp -u); mkfifo "$run_pipe"
    result_pipe=$(mktemp -u); mkfifo "$result_pipe"
    exec 3<>"$run_pipe"
    exec 4<>"$result_pipe"

    # 退出时清理 FIFO
    trap "exec 3>&-; exec 4>&-; rm -f '$run_pipe' '$result_pipe'" EXIT

    local ignore_file ignore_until now
    inotifywait -m -q -r \
        -e CREATE,CLOSE_WRITE,DELETE,MODIFY,MOVED_FROM,MOVED_TO \
        --excludei "$INOTIFY_EXCLUDE_PATTERN" \
        --format '%e|%w%f' "$ldir" 2>/dev/null | \
    while IFS='|' read -r events file; do
        # 过滤目录 MODIFY 事件（文件修改导致的目录 mtime 更新是噪音）
        # DELETE,ISDIR / CREATE,ISDIR / MOVE 事件必须保留，否则目录增删无法同步
        [[ "$events" =~ MODIFY ]] && [[ "$events" =~ ISDIR ]] && continue

        # 双向模式下检查是否在忽略时间窗口内（L→W 完成后 5s 内忽略所有事件）
        ignore_file="$STATE_DIR/$proj/ignore_until"
        if is_bidirectional && [ -f "$ignore_file" ]; then
            ignore_until=$(cat "$ignore_file")
            now=$(date +%s)
            if [ "$now" -lt "$ignore_until" ]; then
                continue  # 窗口内，直接丢弃事件
            fi
            rm -f "$ignore_file"  # 窗口已过期，清理
        fi

        # 检查上次同步是否已完成
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            pid=""
        fi

        if [ -z "$pid" ]; then
            # 无进行中的同步 → 启动新的后台同步
            (
                sync_linux_to_win "$proj" "$ldir" "$wdir"
                # 检查管道，处理同步期间到达的新事件
                while read -t0.001 -u3 2>/dev/null; do
                    echo "ok" >&4
                    sync_linux_to_win "$proj" "$ldir" "$wdir"
                done
                # 写入完成时间戳，W→L 据此判断是否需要等待
                date +%s > "$STATE_DIR/$proj/l2w_done"
            ) &
            pid=$!
            echo "$pid" > "$STATE_DIR/$proj/l2w_pid"
            waiting=0
        else
            # 同步正在进行 → 通知后台进程"结束后再跑一次"
            if [ $waiting -eq 1 ]; then
                read -t0.001 -u4 2>/dev/null && waiting=0
            fi
            if [ $waiting -eq 0 ]; then
                echo "run" >&3
                waiting=1
            fi
        fi
    done

    # inotifywait 意外退出时告警
    log "$proj" "ERROR" "Linux 监控意外退出 (inotifywait 终止)"
}

# ============================================================================
# Windows 轮询 (仅双向模式) + 循环直到干净
# ============================================================================
windows_watcher() {
    is_bidirectional || return 0
    local proj="$1" ldir="$2" wdir="$3"
    log "$proj" "INIT" "Windows 轮询启动 (间隔 5s)"

    sleep 5  # 等待初始 L→W 同步完成

    while true; do
        sleep 5

        # dry-run 检测变化
        local changes
        changes=$(rsync -rtin --no-owner --no-group --no-perms \
            --modify-window=2 \
            -e "ssh -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" \
            "${RSYNC_EXCLUDES[@]}" \
            "$(ssh_dest):$wdir/" "$ldir/" 2>/dev/null | grep -E '^[><cfhpguax*]' | wc -l)

        [ "$changes" -eq 0 ] && continue

        log "$proj" "EVENT" "检测到 Windows 变化 ($changes 项)"

        # 等待 3 秒后重新确认，避免与 inotify 触发的 L→W 同步竞态
        # 场景：Linux 删除了文件，inotify 还没执行 L→W，但轮询先检测到了差异
        # 如果不等待，W→L 会把 Windows 上尚未被删除的文件复制回 Linux
        sleep 3
        changes=$(rsync -rtin --no-owner --no-group --no-perms \
            --modify-window=2 \
            -e "ssh -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" \
            "${RSYNC_EXCLUDES[@]}" \
            "$(ssh_dest):$wdir/" "$ldir/" 2>/dev/null | grep -E '^[><cfhpguax*]' | wc -l)

        [ "$changes" -eq 0 ] && { log "$proj" "OK" "变化已由 L→W 处理, 跳过 W→L"; continue; }

        # 检查 L→W 是否仍在运行（或刚完成，可能马上要跑下一轮）
        # 两种场景跳过 W→L：
        #   1. l2w_pid 存活 → L→W 正运行
        #   2. l2w_done < 3s  → L→W 刚跑完，inotify 事件可能正排队等下一轮
        local l2w_pid_file="$STATE_DIR/$proj/l2w_pid"
        local l2w_done_file="$STATE_DIR/$proj/l2w_done"
        local skip_w2l=false
        if [ -f "$l2w_pid_file" ]; then
            local l2w_pid=$(cat "$l2w_pid_file" 2>/dev/null)
            if [ -n "$l2w_pid" ] && kill -0 "$l2w_pid" 2>/dev/null; then
                log "$proj" "OK" "L→W 仍在运行 (PID $l2w_pid), 跳过 W→L"
                skip_w2l=true
            fi
        fi
        if ! $skip_w2l && [ -f "$l2w_done_file" ]; then
            local l2w_done=$(cat "$l2w_done_file" 2>/dev/null)
            local now=$(date +%s)
            if [ -n "$l2w_done" ] && [ $((now - l2w_done)) -lt 3 ]; then
                log "$proj" "OK" "L→W 刚完成 ($((now - l2w_done))s 前), 跳过 W→L"
                skip_w2l=true
            fi
        fi
        $skip_w2l && continue

        # 循环直到干净：处理同步期间的新变更
        local loop=0
        while true; do
            sync_win_to_linux "$proj" "$ldir" "$wdir" || break

            changes=$(rsync -rtin --no-owner --no-group --no-perms \
                --modify-window=2 \
                -e "ssh -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" \
                "${RSYNC_EXCLUDES[@]}" \
                "$(ssh_dest):$wdir/" "$ldir/" 2>/dev/null | grep -E '^[><cfhpguax*]' | wc -l)

            [ "$changes" -eq 0 ] && break
            ((loop++))
            [ $loop -ge 10 ] && { log "$proj" "WARN" "W→L 循环达到上限,暂停"; break; }
        done
    done
}

# ============================================================================
# 入口
# ============================================================================

# 参数解析
while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--unidirectional) SYNC_MODE="unidirectional"; shift ;;
        -b|--bidirectional)  SYNC_MODE="bidirectional"; shift ;;
        --mode=*)            SYNC_MODE="${1#*=}"; shift ;;
        -h|--help)
            echo "用法: $0 [-u|-b] [--mode=bidirectional|unidirectional]"
            echo "  -b  双向同步 (默认)"
            echo "  -u  单向同步 (Linux → Windows)"
            exit 0
            ;;
        *) echo -e "\033[0;31m未知参数: $1\033[0m"; exit 1 ;;
    esac
done

# 单例检查
if [ -f "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        echo -e "\033[0;31m❌ 已在运行 (PID: $old_pid)\033[0m"
        exit 1
    fi
    rm -f "$PID_FILE"
fi
# 尝试写 PID 文件，如果权限不足用后备路径
if ! echo $$ > "$PID_FILE" 2>/dev/null; then
    PID_FILE="/tmp/multi_sync_$$.pid"
    echo $$ > "$PID_FILE"
fi

ensure_state_dir
rm -f "$GLOBAL_LOCK" /tmp/rsync_l2w_*.XXXXXX /tmp/rsync_w2l_*.XXXXXX

# 清理函数
cleanup() {
    echo -e "\n\033[0;33m🛑 收到信号，正在清理...\033[0m"
    rm -f "$PID_FILE"
    [ ${#ALL_PIDS[@]} -gt 0 ] && kill "${ALL_PIDS[@]}" 2>/dev/null
    sleep 1
    [ ${#ALL_PIDS[@]} -gt 0 ] && kill -9 "${ALL_PIDS[@]}" 2>/dev/null
    is_bidirectional && rm -rf "$STATE_DIR"
    rm -f "$GLOBAL_LOCK" /tmp/rsync_l2w_*.XXXXXX /tmp/rsync_w2l_*.XXXXXX
    echo -e "\033[0;32m👋 已停止\033[0m"
    exit 0
}
trap cleanup SIGINT SIGTERM

log "MAIN" "INIT" "========== v6.0 启动 (PID: $$) =========="
log "MAIN" "INIT" "模式: $(is_bidirectional && echo '双向 Linux ⇄ Windows' || echo '单向 Linux → Windows')"
log "MAIN" "INIT" "项目数: ${#PROJECT_NAMES[@]}"

touch "$LOG_FILE" 2>/dev/null || true

for i in "${!PROJECT_NAMES[@]}"; do
    p="${PROJECT_NAMES[i]}"
    ld="${LINUX_DIRS[i]}"
    wc=$(to_cygdrive "${WIN_DIRS[i]}")

    log "$p" "INIT" "--- $p ---"
    log "$p" "INIT" "Linux: $ld"
    log "$p" "INIT" "Windows: $(ssh_dest):$wc"

    # 初始同步（不检查防回环）
    log "$p" "INIT" "初始同步 L→W..."
    sync_linux_to_win "$p" "$ld" "$wc" "true"

    if is_bidirectional; then
        sleep 2
        log "$p" "INIT" "初始同步 W→L..."
        sync_win_to_linux "$p" "$ld" "$wc" "true"
    fi

    # 启动监控
    linux_watcher "$p" "$ld" "$wc" &
    ALL_PIDS+=($!)

    if is_bidirectional; then
        windows_watcher "$p" "$ld" "$wc" &
        ALL_PIDS+=($!)
    fi
done

log "MAIN" "OK" "所有监控已启动 (${#ALL_PIDS[@]} 个进程)"
echo -e "\033[0;32m✅ $(is_bidirectional && echo '双向' || echo '单向')同步运行中. 按 Ctrl+C 停止.\033[0m"
echo -e "\033[0;33m📌 日志: $LOG_FILE\033[0m"

wait
