#!/bin/bash
# 基于 syncd 架构的多项目双向实时同步脚本
# 采用 FIFO 事件聚合模式，同步期间变更不丢失
# 版本: 6.7
#
# v6.7 变更:
#   - 修复: --exclude=~$* 因双引号被展开成命令行参数 (无参数时变成 --exclude=~,
#     带 -b 等参数时变成 --exclude=~-b), Office 临时文件排除失效/误伤
#     (改为单引号字面量)
#   - 修复: Windows 删除 + 其它变更同时发生时, W→L 传输期间落地的回音
#     CREATE 事件会启动 L→W, 此时 last_W2L 尚未记录 (读到旧时间戳, 10s
#     回音抑制失效), 把 Windows 刚删除的文件复制回去, 使 v6.6 的删除传播
#     盲区依然存在 (W→L 进行中 (w2l_active) 时不再启动新 L→W, 改为排队,
#     由 W→L 完成后的 drain/轮询确认兜底, 变更只延迟不丢失)
#   - 修复: Ctrl+C 清理后 inotifywait/管道子 shell/瞬时同步子进程成孤儿
#     继续运行 (清理时收割 watcher 进程树 + l2w_pid 台账)
#   - 修复: --exclude=/config/database.local.php 根锚定与 inotify 任意深度
#     匹配不一致, 子目录的 database.local.php 会被 W→L 拉取 (改为 **/ 任意深度)
#   - 测试: test_sync_fixes.sh 的 LOG_FILE 覆盖无效, 单元测试日志会写入
#     正式日志文件 (已修复)
#
# v6.6 变更:
#   - 修复: Windows 同时有修改+删除时, 删除传播只在"干净分支"执行, 而 W→L
#     回音触发的 L→W 会先把"Windows 已删除、Linux 尚未删除"的文件复制回
#     Windows, 使删除被撤销 (检测到变化挂锁后立即执行一次删除传播)
#
# v6.5 变更:
#   - 修复: 带 --delete 的 L→W 在重试循环期间若轮询器挂上 windows_dirty,
#     仍会按旧参数继续执行并误删 (每次重试前在锁内重新预检 dirty 锁,
#     已挂锁则中止本次执行)
#   - 修复: W→L 落地的文件其 linux_known 凭证晚于 last_l2w_ok, 且回音 L→W
#     被 10s 抑制跳过, 导致 last_l2w_ok 不前进、Windows 删除传播无限期延迟
#     (W→L 有变更后写 need_l2w_confirm 标记, 轮询干净时补跑一次确认 L→W
#     推进 last_l2w_ok, 成功后清除标记)
#
# v6.4 变更:
#   - 新增: Windows 删除同步到 Linux (PROPAGATE_WIN_DELETE 开关, 默认开启):
#     * linux_known 台账 (启动全量快照 + inotify CREATE/MOVED_TO 增量)
#       加 last_l2w_ok (最近一次成功 L→W 完成时间) 双凭证校验:
#       只删除能证明"在成功 L→W 之前就存在于 Linux"的路径,
#       避免误删 Linux 新建、尚未同步到 Windows 的文件
#     * dry-run 检测 → 凭证校验 → 本地删除, 全程持全局锁, 不与 L→W 交错
#     * 无凭证路径一律跳过 (保守降级): inotify 丢事件时宁可不删也不错删
#   - 残余风险: 同一路径"先删后建"且新建事件恰被 inotify 丢弃时可能误删 (极窄)
#
# v6.3 变更:
#   - 修复: --exclude-from 检查与删除台账清空的竞态导致 rsync exit 11
#     ("failed to open exclude file"): dry-run/W→L 改为在全局锁内读取台账
#     并拼参数, L→W 改为在锁内截断清空 (不再 rm 删除文件)
#
# v6.2 变更:
#   - 修复: report_changes/dryrun_w2l_changes 把 log 输出混入 $(...) 捕获值,
#     导致 "integer expression expected" 报错、record_sync 从不执行、
#     should_skip 10s 回音抑制整体失效 (改为全局变量返回计数)
#   - 修复: windows_dirty 检查与全局锁不原子, 排队等锁的 L→W 仍带 --delete
#     执行, 误删等锁期间 Windows 新建的文件 (检查移入全局锁内)
#   - 修复: 脏锁期间 Linux 删除的文件被 W→L "复活" (新增 pending_deletes
#     删除台账: inotify 记录删除路径, W→L/dry-run 排除这些路径,
#     L→W 带 --delete 成功后清空; 轮询确认干净后主动触发一次 L→W
#     清掉 Windows 上的残留副本)
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
#   - Linux 删除经 pending_deletes 台账传播 (防复活, 见 v6.2 变更);
#     若删除恰好发生在 W→L 同步进行中或其完成 10s 内, 台账可能漏记,
#     该次删除仍存在被复活的窄窗口.
#   - Windows 删除传播到 Linux (v6.4) 依赖 linux_known/last_l2w_ok 凭证;
#     无凭证的候选路径一律不删, inotify 丢事件时该特性自动降级为不删.
#   - L→W 的 --delete 仍存在 ≤1 个轮询周期(5s)的误删窗口: Windows 新建文件后、
#     轮询尚未检测到之前, 若恰好发生 Linux 事件触发 L→W, 该文件可能被删.
#     如需彻底消除, 可把轮询间隔调小, 或 L→W 前先做一次 W→L dry-run 确认干净.

# ============================================================================
# 配置
# ============================================================================
SYNC_MODE="bidirectional"   # bidirectional | unidirectional
# 是否把 Windows 上的删除同步到 Linux (仅双向模式, 见 v6.4 变更)
PROPAGATE_WIN_DELETE="true"

SSH_USER="amei"
SSH_HOST="192.168.1.10"
SSH_PORT="22"
# 远程 ssh 选项: 防止 Windows 离线/睡眠时 ssh 长时间挂起
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes -o ServerAliveInterval=15"
WIN_RSYNC_PATH="\"D:/Program Files (x86)/cwRsync/bin/rsync.exe\""

RETRY_MAX=10
LOG_FILE="/tmp/sync_test.log"
LOG_MAX_SIZE=10485760        # 10MB, 超出后轮转为 .1
PID_FILE="/tmp/multi_sync_test.pid"
STATE_DIR="/tmp/sync_state_test"

PROJECT_BASE_NAMES=(
    "__synctest"



)

RSYNC_EXCLUDES=(
    "--exclude=.git/" "--exclude=.svn/" "--exclude=.idea/" "--exclude=.vscode/"
    "--exclude=node_modules/" "--exclude=runtime/" "--exclude=unpackage/" "--exclude=cache/"
    "--exclude=**/config/database.local.php" "--exclude=*.bak" "--exclude=.env" "--exclude=.env.development"
    "--exclude=*.log" "--exclude=*.tmp" "--exclude=*.swp" "--exclude=*.zip" '--exclude=~$*'
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

# 转义 rsync filter 规则的特殊字符, 使删除台账中的路径按字面匹配
filter_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\*/\\*}"
    s="${s//\?/\\?}"
    s="${s//\[/\\[}"
    printf '%s' "$s"
}

ssh_dest() { echo "${SSH_USER}@${SSH_HOST}"; }

# ============================================================================
# 全局 rsync 互斥锁（避免多个 rsync 同时连接 cwRsync 导致 error 12）
# ============================================================================
GLOBAL_LOCK="/tmp/rsync_global_test.lock"

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
# 重试预检 (在锁内、每次 rsync 尝试前调用): windows_dirty 存在 → 返回 1 (中止)
sync_precheck_dirty() {
    [ ! -f "$STATE_DIR/$1/windows_dirty" ]
}

# 可选: 每次 rsync 尝试前执行的检查函数名 (见 run_rsync_locked)
RSYNC_PRECHECK_FN=""

# 前提: 调用方已持有全局锁; 带重试执行 rsync
run_rsync_locked() {
    local label="$1" output_file="$2"; shift 2
    local attempt=1 delay exit_code

    while [ $attempt -le $RETRY_MAX ]; do
        # 每次尝试前重新预检: 重试期间状态可能变化 (如 windows_dirty 被挂锁),
        # 继续按旧参数执行会破坏数据保护语义
        if [ -n "$RSYNC_PRECHECK_FN" ] && ! "$RSYNC_PRECHECK_FN" "$label"; then
            log "$label" "WARN" "预检中止: 执行期间 windows_dirty 已挂锁, 放弃 --delete"
            return 10
        fi
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
    return $exit_code
}

# 统计并记录 itemized 变更; 变更数通过全局变量 REPORT_CHANGES 返回
# (不能通过 echo 返回: log 会写 stdout, 被 $(...) 捕获后破坏数字判断)
report_changes() {
    local proj="$1" direction="$2" tmp="$3"
    local changes show
    REPORT_CHANGES=0
    changes=$(grep -E '^[><cfhpguax*]' "$tmp" 2>/dev/null | wc -l)
    [ "$changes" -gt 0 ] || return
    log "$proj" "SYNC" "$direction: ${changes} 个文件变更"
    show=20
    [ "$changes" -gt 20 ] && show=5
    grep -E '^[><cfhpguax*]' "$tmp" 2>/dev/null | head -n "$show" | while IFS= read -r l; do
        log "$proj" "SYNC" "  $l"
    done
    [ "$changes" -gt 20 ] && log "$proj" "SYNC" "  (仅显示前5条, 共${changes}条)"
    REPORT_CHANGES=$changes
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
# linux_known 台账 (W→L 删除传播的凭证, 见 propagate_win_deletions)
# 每行: epoch<TAB>相对路径  (epoch = 该路径出现在 Linux 上的时间)
# ============================================================================
# 启动时全量快照现有文件/目录 (epoch = 快照时间);
# 只跳过与 RSYNC_EXCLUDES 目录排除一致的大目录, 控制台账体积
seed_linux_known() {
    is_bidirectional || return 0
    local proj="$1" ldir="$2"
    local now=$(date +%s) rel
    : > "$STATE_DIR/$proj/linux_known"
    find "$ldir" \
        \( -name .git -o -name .svn -o -name .idea -o -name .vscode \
           -o -name node_modules -o -name runtime -o -name unpackage -o -name cache \) -prune -o \
        \( -type f -o -type d \) -print 2>/dev/null | while IFS= read -r p; do
        rel="${p#$ldir/}"
        [ "$rel" != "$p" ] && [ -n "$rel" ] && printf '%s\t%s\n' "$now" "$rel"
    done >> "$STATE_DIR/$proj/linux_known"
}

# inotify CREATE/MOVED_TO 增量记录 (W→L 回音产生的 CREATE 噪音无害:
# 只是把凭证时间推迟, 使删除判断更保守)
record_linux_known() {
    is_bidirectional || return 0
    printf '%s\t%s\n' "$(date +%s)" "$2" >> "$STATE_DIR/$1/linux_known"
}

# ============================================================================
# 带全局锁的 W→L dry-run: 只统计 Windows 侧更新的变更
# (--update 过滤掉"Linux 比 Windows 新"的文件, 那些由 inotify 触发的 L→W 负责,
#  避免方向混淆: 否则 Linux 侧变更会触发徒劳的 W→L 循环)
# ============================================================================
dryrun_w2l_changes() {
    local proj="$1" ldir="$2" wdir="$3"
    local tmp rc changes del_excl=()
    DRYRUN_CHANGES=0
    DRYRUN_RC=1
    tmp=$(mktemp "/tmp/rsync_dry_${proj}.XXXXXX")

    acquire_global_lock
    # 删除台账: Linux 已删除、尚未在 Windows 确认删除的路径, W→L 方向跳过 (防复活).
    # 检查必须在锁内 (与 L→W 的锁内清空互斥), 否则文件可能在检查后被清空,
    # rsync 打开 --exclude-from 时报 exit 11
    [ -s "$STATE_DIR/$proj/pending_deletes" ] && \
        del_excl=(--exclude-from="$STATE_DIR/$proj/pending_deletes")

    rsync -rtin --update --no-owner --no-group --no-perms \
        --modify-window=2 --timeout=30 \
        -e "ssh $SSH_OPTS -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" \
        "${del_excl[@]}" \
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
    # 通过全局变量返回 (log 会写 stdout, 不能再用 echo 交给 $(...) 捕获)
    DRYRUN_CHANGES=$changes
    DRYRUN_RC=$rc
}

# ============================================================================
# Windows 删除 → Linux 传播 (可选, 见 PROPAGATE_WIN_DELETE)
# 安全机制: "Linux 有、Windows 无" 可能是 Windows 删除, 也可能是 Linux 新建
# 尚未同步; 只删除能证明"在最近一次成功 L→W 之前就已存在于 Linux"的路径:
#   - linux_known: 启动时全量快照 + inotify CREATE/MOVED_TO 增量 (epoch\tpath)
#   - last_l2w_ok: 最近一次 rc=0 的 L→W 完成时间
# 无凭证路径一律跳过 (保守), 检测/校验/删除全程持全局锁避免与 L→W 交错
# ============================================================================
propagate_win_deletions() {
    is_bidirectional || return 0
    [ "$PROPAGATE_WIN_DELETE" = "true" ] || return 0
    local proj="$1" ldir="$2" wdir="$3"
    local tmp rc del_excl=()
    local known_file="$STATE_DIR/$proj/linux_known"
    [ -s "$known_file" ] || return 0
    tmp=$(mktemp "/tmp/rsync_wdel_${proj}.XXXXXX")

    acquire_global_lock
    local last_ok=0
    [ -f "$STATE_DIR/$proj/last_l2w_ok" ] && \
        last_ok=$(cat "$STATE_DIR/$proj/last_l2w_ok" 2>/dev/null || echo 0)

    [ -s "$STATE_DIR/$proj/pending_deletes" ] && \
        del_excl=(--exclude-from="$STATE_DIR/$proj/pending_deletes")

    # W→L 方向 dry-run --delete: 只列出"Linux 有、Windows 无"的候选删除项
    rsync -rtin --delete --update --no-owner --no-group --no-perms \
        --modify-window=2 --timeout=30 \
        -e "ssh $SSH_OPTS -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" \
        "${del_excl[@]}" \
        "${RSYNC_EXCLUDES[@]}" \
        "$(ssh_dest):$wdir/" "$ldir/" > "$tmp" 2>&1
    rc=$?

    if [ $rc -eq 0 ] || [ $rc -eq 24 ]; then
        local deleted=0 skipped=0 rel ep
        while IFS= read -r l; do
            rel="${l#\*deleting}"
            rel="${rel#"${rel%%[! ]*}"}"
            [ -z "$rel" ] && continue
            # 取该路径最近一次出现在 Linux 上的时间戳 (取最后一条匹配)
            ep=$(awk -F '\t' -v p="${rel%/}" \
                '$2==p {e=$1} END {if (e!="") print e}' "$known_file" 2>/dev/null)
            if [ -n "$ep" ] && [ "$ep" -le "$last_ok" ]; then
                if [[ "$rel" == */ ]]; then
                    # 目录: 只 rmdir 空目录 (子项未删干净的保留)
                    rmdir "$ldir/$rel" 2>/dev/null && \
                        { deleted=$((deleted+1)); log "$proj" "SYNC" "W→L 删除传播: $rel"; }
                else
                    rm -f "$ldir/$rel" && \
                        { deleted=$((deleted+1)); log "$proj" "SYNC" "W→L 删除传播: $rel"; }
                fi
            else
                skipped=$((skipped+1))
            fi
        done < <(grep -E '^\*deleting' "$tmp" 2>/dev/null)
        [ "$deleted" -gt 0 ] && log "$proj" "SYNC" "W→L 删除传播完成: 共删除 ${deleted} 个路径"
        [ "$skipped" -gt 0 ] && log "$proj" "SKIP" "W→L 删除传播: ${skipped} 个候选无凭证, 跳过"
    else
        # 失败限流日志 (同 dryrun_w2l_changes)
        local fail_ts_file="$STATE_DIR/$proj/wdel_fail_ts"
        local now=$(date +%s) last_fail=0
        [ -f "$fail_ts_file" ] && last_fail=$(cat "$fail_ts_file" 2>/dev/null || echo 0)
        if [ $((now - last_fail)) -gt 60 ]; then
            log "$proj" "ERROR" "W→L 删除检测 dry-run 失败 (exit=$rc)"
            date +%s > "$fail_ts_file"
        fi
    fi
    release_global_lock
    rm -f "$tmp"
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
    local rc=0 changes del_args=()

    # 数据保护: Windows 侧有未回传变更时禁用 --delete, 防止误删 Windows 上
    # 新建/刚修改的文件. 检查必须在全局锁内进行, 与 --delete 参数组装保持
    # 原子: 否则排队等锁期间轮询器可能挂上 windows_dirty, 但本进程仍按旧
    # 参数带 --delete 执行 (见头部 v6.2 变更)
    acquire_global_lock "$proj"
    if [ ! -f "$STATE_DIR/$proj/windows_dirty" ]; then
        del_args=(--delete)
    fi

    # 带 --delete 时每次重试前重新预检 dirty 锁 (见 run_rsync_locked)
    [ ${#del_args[@]} -gt 0 ] && RSYNC_PRECHECK_FN=sync_precheck_dirty

    run_rsync_locked "$proj" "$tmp" \
        -avzi --update "${del_args[@]}" \
        --no-owner --no-group --no-perms --partial \
        --modify-window=2 --omit-dir-times --timeout=30 \
        -e "ssh $SSH_OPTS -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" \
        "${RSYNC_EXCLUDES[@]}" \
        "$ldir/" "$(ssh_dest):$wdir/"
    rc=$?
    RSYNC_PRECHECK_FN=""

    if [ $rc -eq 10 ]; then
        # 预检中止: 不更新 last_l2w_ok、不清台账, 直接按失败返回
        release_global_lock
        rm -f "$tmp"
        return 10
    fi

    if [ $rc -eq 0 ]; then
        # 最近一次成功 L→W 的完成时间: W→L 删除传播据此判断"该路径在成功
        # 同步之前就已存在于 Linux" (见 propagate_win_deletions)
        date +%s > "$STATE_DIR/$proj/last_l2w_ok"
        # 带 --delete 的成功运行 = Windows 已确认删除所有台账路径, 清空删除台账.
        # 必须在锁内且用截断而非删除: dry-run/W→L 在锁内读取该文件拼 --exclude-from,
        # 若清空发生在它们读取之后、rsync 打开之前, 会报 "failed to open exclude
        # file" (exit 11); 文件一旦创建就保留为空文件, 彻底消除打开竞态
        # (rc=24 部分完成时保守保留, 下次成功再清)
        [ ${#del_args[@]} -gt 0 ] && : > "$STATE_DIR/$proj/pending_deletes"
    fi
    release_global_lock

    if [ $rc -eq 0 ] || [ $rc -eq 24 ]; then
        report_changes "$proj" "L→W" "$tmp"
        changes=$REPORT_CHANGES
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
    local rc=0 changes del_excl=()

    # W→L: 只新增和更新，不删除（避免竞态删除 Linux 新创建的文件/目录）
    # 删除统一由 L→W 方向的 --delete 控制（Linux 为权威端）
    # 标记 w2l_active, linux_watcher 据此不把 rsync 替换文件的 DELETE 噪音
    # 写入删除台账
    : > "$STATE_DIR/$proj/w2l_active"
    acquire_global_lock "$proj"
    # 删除台账: 排除 Linux 已删除的路径, 防止脏锁期间被 Windows 副本"复活".
    # 检查必须在锁内 (与 L→W 的锁内清空互斥), 否则文件可能在检查后被清空,
    # rsync 打开 --exclude-from 时报 exit 11
    [ -s "$STATE_DIR/$proj/pending_deletes" ] && \
        del_excl=(--exclude-from="$STATE_DIR/$proj/pending_deletes")

    run_rsync_locked "$proj" "$tmp" \
        -rtzi --update --no-owner --no-group --no-perms --partial \
        --modify-window=2 --omit-dir-times --timeout=30 \
        -e "ssh $SSH_OPTS -p $SSH_PORT" --rsync-path="$WIN_RSYNC_PATH" \
        "${del_excl[@]}" \
        "${RSYNC_EXCLUDES[@]}" \
        "$(ssh_dest):$wdir/" "$ldir/"
    rc=$?
    release_global_lock
    rm -f "$STATE_DIR/$proj/w2l_active"

    if [ $rc -eq 0 ] || [ $rc -eq 24 ]; then
        report_changes "$proj" "W→L" "$tmp"
        changes=$REPORT_CHANGES
        if [ "$changes" -gt 0 ]; then
            record_sync "$proj" "W2L"
            # 标记需要一次"确认 L→W": W→L 刚把 Windows 文件落到 Linux,
            # 它们的 linux_known 凭证晚于 last_l2w_ok; 需一次成功 L→W 推进
            # last_l2w_ok 之后, 对这些文件的 Windows 删除才能被传播 (v6.5)
            date +%s > "$STATE_DIR/$proj/need_l2w_confirm"
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

        # 删除台账: 记录 Linux 侧真实删除 (DELETE/MOVED_FROM) 的相对路径,
        # 供 W→L/dry-run 排除, 防止脏锁期间 Linux 删除的文件被 Windows 副本"复活".
        # 回音过滤: W→L 同步进行中 (w2l_active) 或其完成 10s 内的 DELETE 是
        # rsync 替换文件的噪音, 不记录
        if [[ "$events" =~ DELETE ]] || [[ "$events" =~ MOVED_FROM ]]; then
            if [ ! -f "$STATE_DIR/$proj/w2l_active" ] && ! should_skip "$proj" "W2L"; then
                rel="${file#$ldir/}"
                if [ "$rel" != "$file" ] && [ -n "$rel" ]; then
                    rel=$(filter_escape "$rel")
                    if [[ "$events" =~ ISDIR ]]; then
                        printf '/%s/\n' "$rel" >> "$STATE_DIR/$proj/pending_deletes"
                    else
                        printf '/%s\n' "$rel" >> "$STATE_DIR/$proj/pending_deletes"
                    fi
                fi
            fi
        fi

        # linux_known 台账: 记录 CREATE/MOVED_TO 的出现时间, 作为 W→L 删除
        # 传播的凭证 (W→L 回音产生的 CREATE 噪音无害, 只会让判断更保守)
        if [[ "$events" =~ CREATE ]] || [[ "$events" =~ MOVED_TO ]]; then
            rel2="${file#$ldir/}"
            if [ "$rel2" != "$file" ] && [ -n "$rel2" ]; then
                record_linux_known "$proj" "$rel2"
            fi
        fi

        # 回音抑制 (v6.7): W→L 同步进行中 (w2l_active) 时, 当前事件多半是
        # rsync 落地回音. 此刻直接启动 L→W 会读到过期的 last_W2L (W→L 完成
        # 时间尚未记录, 10s 抑制失效), 把 Windows 刚删除的文件复制回去
        # (v6.6 删除传播的盲区). 处理方式: 已有同步在跑则排队, 无同步则跳过,
        # 由 W→L 完成后的 drain 补跑或轮询的确认 L→W 兜底 (变更不丢, 只延迟
        # 到 10s 回音窗口结束).
        if [ -f "$STATE_DIR/$proj/w2l_active" ]; then
            if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
                wait "$pid" 2>/dev/null
                pid=""
            fi
            if [ -n "$pid" ]; then
                if [ $waiting -eq 1 ]; then
                    read -t0.001 -u4 2>/dev/null && waiting=0
                fi
                if [ $waiting -eq 0 ]; then
                    echo "run" >&3
                    waiting=1
                fi
            fi
            continue
        fi

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
        dryrun_w2l_changes "$proj" "$ldir" "$wdir"
        changes=$DRYRUN_CHANGES

        if [ "$changes" -eq 0 ]; then
            # Windows 确认干净: 解除 --delete 保护锁 (也是失败/中断后的恢复路径)
            rm -f "$STATE_DIR/$proj/windows_dirty"
            # Windows 删除 → Linux 传播 (凭证校验, 全程在锁内)
            propagate_win_deletions "$proj" "$ldir" "$wdir"
            # 台账残留或需要确认 L→W 时, 主动跑一次 L→W
            # (dry-run 必须成功, 避免离线时误触发)
            if { [ -s "$STATE_DIR/$proj/pending_deletes" ] || [ -f "$STATE_DIR/$proj/need_l2w_confirm" ]; } \
               && { [ "$DRYRUN_RC" -eq 0 ] || [ "$DRYRUN_RC" -eq 24 ]; }; then
                sync_linux_to_win "$proj" "$ldir" "$wdir"
                # 确认 L→W 完成 (last_l2w_ok 推进) 后清除标记;
                # 若被 10s 回音抑制跳过, 标记保留到下轮重试
                local l2wo=$(cat "$STATE_DIR/$proj/last_l2w_ok" 2>/dev/null || echo 0)
                local cts=$(cat "$STATE_DIR/$proj/need_l2w_confirm" 2>/dev/null || echo 0)
                [ "$l2wo" -gt "$cts" ] && rm -f "$STATE_DIR/$proj/need_l2w_confirm"
            fi
            continue
        fi

        # 检测到 Windows 变化: 立即挂 dirty 保护锁 (期间 L→W 禁用 --delete),
        # 尽早保护, 避免并发触发的 L→W 误删 Windows 新文件
        : > "$STATE_DIR/$proj/windows_dirty"
        log "$proj" "EVENT" "检测到 Windows 变化 ($changes 项), 锁定 windows_dirty (L→W --delete 暂时禁用)"

        # 变化期间立即传播 Windows 删除: 否则本周期内由 W→L 回音触发的 L→W
        # 会把"Windows 已删除、Linux 尚未删除"的文件复制回 Windows,
        # 使删除被撤销 (见 v6.6)
        propagate_win_deletions "$proj" "$ldir" "$wdir"

        # 等待 3 秒后重新确认，避免与 inotify 触发的 L→W 同步竞态
        # 场景：Linux 删除了文件，inotify 还没执行 L→W，但轮询先检测到了差异
        # 如果不等待，W→L 会把 Windows 上尚未被删除的文件复制回 Linux
        sleep 3
        dryrun_w2l_changes "$proj" "$ldir" "$wdir"
        changes=$DRYRUN_CHANGES

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

            dryrun_w2l_changes "$proj" "$ldir" "$wdir"
            changes=$DRYRUN_CHANGES

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
rm -f "$GLOBAL_LOCK" /tmp/rsync_l2w___synctest_* /tmp/rsync_w2l___synctest_* /tmp/rsync_dry___synctest_* /tmp/rsync_wdel___synctest_*

# 清理函数
# 收割 watcher 进程树: inotifywait 与管道右侧子 shell 是 watcher 的子进程,
# 直接 kill watcher 会让它们变孤儿继续同步 (v6.7 修复)
kill_watcher_tree() {
    local p children sig="$1"
    for p in "${ALL_PIDS[@]}"; do
        children=$(pgrep -P "$p" 2>/dev/null)
        kill $sig "$p" 2>/dev/null
        [ -n "$children" ] && kill $sig $children 2>/dev/null
    done
    # 瞬时同步子 shell 不在 ALL_PIDS 中, 用 l2w_pid 台账收割
    if [ -d "$STATE_DIR" ]; then
        for f in "$STATE_DIR"/*/l2w_pid; do
            [ -f "$f" ] && kill $sig "$(cat "$f" 2>/dev/null)" 2>/dev/null
        done
    fi
}

cleanup() {
    echo -e "\n\033[0;33m🛑 收到信号，正在清理...\033[0m"
    rm -f "$PID_FILE"
    [ ${#ALL_PIDS[@]} -gt 0 ] && kill_watcher_tree ""
    sleep 1
    [ ${#ALL_PIDS[@]} -gt 0 ] && kill_watcher_tree -9
    is_bidirectional && rm -rf "$STATE_DIR"
    rm -f "$GLOBAL_LOCK" /tmp/rsync_l2w___synctest_* /tmp/rsync_w2l___synctest_* /tmp/rsync_dry___synctest_* /tmp/rsync_wdel___synctest_*
    echo -e "\033[0;32m👋 已停止\033[0m"
    exit 0
}
trap cleanup SIGINT SIGTERM

log "MAIN" "INIT" "========== v6.7 启动 (PID: $$) =========="
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

    # 快照 Linux 现有文件台账 (W→L 删除传播的凭证基础, 见 propagate_win_deletions)
    seed_linux_known "$p" "$ld"

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
