#!/bin/bash
# 基于 syncd 架构的多项目双向实时同步脚本
# 采用 FIFO 事件聚合模式，同步期间变更不丢失
# 版本: 6.1
#
# v6.1 变更:
#   - 修复: L→W 的 --delete 在 Windows 有新变更未回传时会误删 Windows 文件
#     (新增 windows_dirty 保护锁: 轮询器检测到 Windows 变更即挂锁禁用 --delete,
#      仅当轮询器确认 Windows 干净后解除, 失败/中断期间保持锁以保护数据)
#   - 修复: L→W 后的 3s ignore_until 窗口会丢弃真实 Linux 编辑事件 (已移除该机制,
#     回音防护由 should_skip 10s 窗口承担)
#   - 修复: 轮询 dry-run 方向不敏感, 会把 Linux 侧变更误当 Windows 变更,
#     造成徒劳循环并掩盖 inotify 丢事件 (dry-run 增加 --update, 只检测 Windows 更新)
#   - 修复: inotify 排除正则锚定失效 (^config/... 与 ^~$.* 对绝对路径永不匹配)
#   - 修复: 轮询 dry-run 绕过全局锁 (cwRsync 并发连接 error 12 隐患)
#   - 修复: 同步子进程僵尸累积 (watcher 检测到退出后 wait 收割)
#   - 修复: 临时文件清理 glob /tmp/rsync_*_*.XXXXXX 永不匹配 (泄漏)
#   - 优化: FIFO 聚合改为 drain 模式, 一个事件突发只补跑一轮全量同步
#   - 优化: ssh 增加 ConnectTimeout/BatchMode/ServerAliveInterval,
#     rsync 增加 --timeout, 防止 Windows 离线时挂死并拖死全局锁
#   - 优化: 日志文件按大小轮转, 文件内不再写入 ANSI 颜色码
#
# 已知设计约束 (有意为之):
#   - Windows 上的删除不会传播到 Linux (W→L 无 --delete, 避免竞态删文件);
#     Linux 为删除权威端. 若 Windows 上误删, 下次 L→W 会复制回来.
#   - L→W 的 --delete 仍存在 ≤1 个轮询周期(5s)的误删窗口: Windows 新建文件后、
#     轮询尚未检测到之前, 若恰好发生 Linux 事件触发 L→W, 该文件可能被删.
#     如需彻底消除, 可把轮询间隔调小, 或 L→W 前先做一次 W→L dry-run 确认干净.

# ============================================================================
# 配置
# ============================================================================
SYNC_MODE="bidirectional"   # bidirectional | unidirectional

SSH_USER="amei"
SSH_HOST="192.168.1.10"
SSH_PORT="22"
# 远程 ssh 选项: 防止 Windows 离线/睡眠时 ssh 长时间挂起
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes -o ServerAliveInterval=15"
WIN_RSYNC_PATH="\"D:/Program Files (x86)/cwRsync/bin/rsync.exe\""

RETRY_MAX=10
LOG_FILE="/home/amei/multi_sync.log"
LOG_MAX_SIZE=10485760        # 10MB, 超出后轮转为 .1
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

# 注意: inotifywait 用完整绝对路径匹配正则, 锚定模式必须允许路径前缀
INOTIFY_EXCLUDE_PATTERN='(\.git/|\.svn/|\.idea/|\.vscode/|node_modules/|runtime/|unpackage/|cache/|(^|/)config/database\.local\.php$|\.bak$|\.env(\.development)?$|\.log$|\.tmp$|\.swp$|(^|/)~\$.*)'

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
    # 日志轮转
    if [ -f "$LOG_FILE" ]; then
        local sz=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "${sz:-0}" -gt "$LOG_MAX_SIZE" ]; then
            mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
            : > "$LOG_FILE"
            echo "[$ts] ℹ️ [MAIN] 日志已轮转 (>${LOG_MAX_SIZE}B)" >> "$LOG_FILE"
        fi
    fi
    # 终端带颜色, 文件只写纯文本
    printf "[%s] ${color}%s [%s]${color} %s\033[0m\n" "$ts" "$sym" "$proj" "$msg"
    printf "[%s] %s [%s] %s\n" "$ts" "$sym" "$proj" "$msg" >> "$LOG_FILE"
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

# 统计并记录 itemized 变更；stdout 返回变更数
report_changes() {
    local proj="$1" direction="$2" tmp="$3"
    local changes show
    changes=$(grep -E '^[><cfhpguax*]' "$tmp" 2>/dev/null | wc -l)
    [ "$changes" -gt 0 ] || { echo 0; return; }
    log "$proj" "SYNC" "$direction: ${changes} 个文件变更"
    show=20
    [ "$changes" -gt 20 ] && show=5
    grep -E '^[><cfhpguax*]' "$tmp" 2>/dev/null | head -n "$show" | while IFS= read -r l; do
        log "$proj" "SYNC" "  $l"
    done
    [ "$changes" -gt 20 ] && log "$proj" "SYNC" "  (仅显示前5条, 共${changes}条)"
    echo "$changes"
}

log_rsync_failure() {
    local proj="$1" direction="$2" rc="$3" tmp="$4"
    log "$proj" "ERROR" "$direction 失败 (exit=$rc)"
    tail -n 3 "$tmp" 2>/dev/null | while IFS= read -r l; do
        [ -n "$l" ] && log "$proj" "ERROR" "  $l"
    done
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
# 带全局锁的 W→L dry-run: 只统计 Windows 侧更新的变更
# (--update 过滤掉"Linux 比 Windows 新"的文件, 那些由 inotify 触发的 L→W 负责,
#  避免方向混淆: 否则 Linux 侧变更会触发徒劳的 W→L 循环)
# ============================================================================
dryrun_w2l_changes() {
    local proj="$1" ldir="$2" wdir="$3"
    local tmp rc changes
    tmp=$(mktemp "/tmp/rsync_dry_${proj}.XXXXXX")

    acquire_global_lock
    rsync -rtin --update --no-owner --no-group --no-perms \
        --modify-window=2 --timeout=30 \
        -e "ssh $SSH_OPTS -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" \
        "${RSYNC_EXCLUDES[@]}" \
        "$(ssh_dest):$wdir/" "$ldir/" > "$tmp" 2>&1
    rc=$?
    release_global_lock

    changes=$(grep -E '^[><cfhpguax*]' "$tmp" 2>/dev/null | wc -l)
    if [ $rc -ne 0 ] && [ $rc -ne 24 ]; then
        # 失败时每 60s 只记一次, 避免 Windows 离线期间刷屏
        local fail_ts_file="$STATE_DIR/$proj/dry_fail_ts"
        local now=$(date +%s)
        local last_fail=0
        [ -f "$fail_ts_file" ] && last_fail=$(cat "$fail_ts_file" 2>/dev/null || echo 0)
        if [ $((now - last_fail)) -gt 60 ]; then
            log "$proj" "ERROR" "W→L dry-run 失败 (exit=$rc)"
            tail -n 2 "$tmp" 2>/dev/null | while IFS= read -r l; do
                [ -n "$l" ] && log "$proj" "ERROR" "  $l"
            done
            date +%s > "$fail_ts_file"
        fi
        changes=0
    fi
    rm -f "$tmp"
    echo "$changes"
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
    local rc=0 changes

    # 数据保护: Windows 侧有未回传变更时禁用 --delete,
    # 防止误删 Windows 上新建/刚修改的文件 (见头部注释的竞态说明)
    local del_args=()
    if [ ! -f "$STATE_DIR/$proj/windows_dirty" ]; then
        del_args=(--delete)
    fi

    run_rsync "$proj" "$tmp" \
        -avzi --update "${del_args[@]}" \
        --no-owner --no-group --no-perms --partial \
        --modify-window=2 --omit-dir-times --timeout=30 \
        -e "ssh $SSH_OPTS -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" \
        "${RSYNC_EXCLUDES[@]}" \
        "$ldir/" "$(ssh_dest):$wdir/"
    rc=$?

    if [ $rc -eq 0 ] || [ $rc -eq 24 ]; then
        changes=$(report_changes "$proj" "L→W" "$tmp")
        if [ "$changes" -gt 0 ]; then
            record_sync "$proj" "L2W"   # 仅实际有变更时记录时间戳
        fi
    else
        log_rsync_failure "$proj" "L→W" "$rc" "$tmp"
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
    local rc=0 changes

    # W→L: 只新增和更新，不删除（避免竞态删除 Linux 新创建的文件/目录）
    # 删除统一由 L→W 方向的 --delete 控制（Linux 为权威端）
    run_rsync "$proj" "$tmp" \
        -rtzi --update --no-owner --no-group --no-perms --partial \
        --modify-window=2 --omit-dir-times --timeout=30 \
        -e "ssh $SSH_OPTS -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" \
        "${RSYNC_EXCLUDES[@]}" \
        "$(ssh_dest):$wdir/" "$ldir/"
    rc=$?

    if [ $rc -eq 0 ] || [ $rc -eq 24 ]; then
        changes=$(report_changes "$proj" "W→L" "$tmp")
        if [ "$changes" -gt 0 ]; then
            record_sync "$proj" "W2L"
        fi
        # 注意: windows_dirty 由轮询器统一管理 (干净确认后清除),
        # 不在同步函数里清除, 避免 W→L 循环期间出现 --delete 暴露窗口
    else
        log_rsync_failure "$proj" "W→L" "$rc" "$tmp"
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

    local run_pipe result_pipe pid
    local waiting=0
    run_pipe=$(mktemp -u); mkfifo "$run_pipe"
    result_pipe=$(mktemp -u); mkfifo "$result_pipe"
    exec 3<>"$run_pipe"
    exec 4<>"$result_pipe"

    # 退出时清理 FIFO
    trap "exec 3>&-; exec 4>&-; rm -f '$run_pipe' '$result_pipe'" EXIT

    # 注意: 管道右侧在子 shell 中运行, 不能用 local
    inotifywait -m -q -r \
        -e CREATE,CLOSE_WRITE,DELETE,MODIFY,MOVED_FROM,MOVED_TO \
        --excludei "$INOTIFY_EXCLUDE_PATTERN" \
        --format '%e|%w%f' "$ldir" 2>/dev/null | \
    while IFS='|' read -r events file; do
        # 过滤目录 MODIFY 事件（文件修改导致的目录 mtime 更新是噪音）
        # DELETE,ISDIR / CREATE,ISDIR / MOVE 事件必须保留，否则目录增删无法同步
        [[ "$events" =~ MODIFY ]] && [[ "$events" =~ ISDIR ]] && continue

        # 检查上次同步是否已完成（顺便 wait 收割僵尸进程）
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null
            pid=""
        fi

        if [ -z "$pid" ]; then
            # 无进行中的同步 → 启动新的后台同步
            (
                sync_linux_to_win "$proj" "$ldir" "$wdir"
                # 聚合: drain 同步期间排队的全部 token, 只补跑一轮
                # (父进程按 "ok" 节流, 补跑期间的新 token 由内层循环继续消化)
                pending=false
                while read -t0.001 -u3 2>/dev/null; do pending=true; done
                if $pending; then
                    echo "ok" >&4
                    sync_linux_to_win "$proj" "$ldir" "$wdir"
                    while read -t0.001 -u3 2>/dev/null; do
                        echo "ok" >&4
                        sync_linux_to_win "$proj" "$ldir" "$wdir"
                    done
                fi
                # 写入完成时间戳，W→L 据此判断是否需要等待
                date +%s > "$STATE_DIR/$proj/l2w_done"
            ) &
            pid=$!
            echo "$pid" > "$STATE_DIR/$proj/l2w_pid"
            waiting=0
        else
            # 同步正在进行 → 通知后台进程"结束后再跑一轮"
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

        # dry-run 检测 Windows 侧变化 (带全局锁, 只统计 Windows 更新的文件)
        local changes
        changes=$(dryrun_w2l_changes "$proj" "$ldir" "$wdir")

        if [ "$changes" -eq 0 ]; then
            # Windows 确认干净: 解除 --delete 保护锁 (也是失败/中断后的恢复路径)
            rm -f "$STATE_DIR/$proj/windows_dirty"
            continue
        fi

        # 检测到 Windows 变化: 立即挂 dirty 保护锁 (期间 L→W 禁用 --delete),
        # 尽早保护, 避免并发触发的 L→W 误删 Windows 新文件
        : > "$STATE_DIR/$proj/windows_dirty"
        log "$proj" "EVENT" "检测到 Windows 变化 ($changes 项), 锁定 windows_dirty (L→W --delete 暂时禁用)"

        # 等待 3 秒后重新确认，避免与 inotify 触发的 L→W 同步竞态
        # 场景：Linux 删除了文件，inotify 还没执行 L→W，但轮询先检测到了差异
        # 如果不等待，W→L 会把 Windows 上尚未被删除的文件复制回 Linux
        sleep 3
        changes=$(dryrun_w2l_changes "$proj" "$ldir" "$wdir")

        if [ "$changes" -eq 0 ]; then
            rm -f "$STATE_DIR/$proj/windows_dirty"
            log "$proj" "OK" "变化已由 L→W 处理, 跳过 W→L"
            continue
        fi

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

        # dirty 锁已在检测到变化时挂上; 循环直到干净 (同步期间的新变更一并处理)
        local loop=0
        while true; do
            sync_win_to_linux "$proj" "$ldir" "$wdir" || break

            changes=$(dryrun_w2l_changes "$proj" "$ldir" "$wdir")

            if [ "$changes" -eq 0 ]; then
                rm -f "$STATE_DIR/$proj/windows_dirty"
                break
            fi
            ((loop++))
            [ $loop -ge 10 ] && { log "$proj" "WARN" "W→L 循环达到上限,暂停 (保留 dirty 锁)"; break; }
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
rm -f "$GLOBAL_LOCK" /tmp/rsync_l2w_* /tmp/rsync_w2l_* /tmp/rsync_dry_*

# 清理函数
cleanup() {
    echo -e "\n\033[0;33m🛑 收到信号，正在清理...\033[0m"
    rm -f "$PID_FILE"
    [ ${#ALL_PIDS[@]} -gt 0 ] && kill "${ALL_PIDS[@]}" 2>/dev/null
    sleep 1
    [ ${#ALL_PIDS[@]} -gt 0 ] && kill -9 "${ALL_PIDS[@]}" 2>/dev/null
    is_bidirectional && rm -rf "$STATE_DIR"
    rm -f "$GLOBAL_LOCK" /tmp/rsync_l2w_* /tmp/rsync_w2l_* /tmp/rsync_dry_*
    echo -e "\033[0;32m👋 已停止\033[0m"
    exit 0
}
trap cleanup SIGINT SIGTERM

log "MAIN" "INIT" "========== v6.1 启动 (PID: $$) =========="
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
