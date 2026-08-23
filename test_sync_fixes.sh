#!/bin/bash
# 单元测试: 验证 v6.2 的 4 个修复 (不依赖真实 ssh/rsync/inotifywait)
cd "$(dirname "$0")"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"

# 截取到 "# 入口" 之前: 只含配置 + 函数定义
# 同时替换 LOG_FILE/STATE_DIR/GLOBAL_LOCK: funcs.sh 内的硬编码赋值会覆盖
# 下方 export, 不替换则测试会污染生产状态目录 /tmp/sync_state 并争抢
# 生产全局锁 /tmp/rsync_global.lock (v6.10 修复)
sed '/^# 入口$/,$d; s|LOG_FILE="/home/amei/multi_sync.log"|LOG_FILE="'"$T"'/app.log"|; s|^STATE_DIR="/tmp/sync_state"|STATE_DIR="'"$T"'/state"|; s|^GLOBAL_LOCK="/tmp/rsync_global.lock"|GLOBAL_LOCK="'"$T"'/global.lock"|' sync_multi.sh > "$T/funcs.sh"

# 假 rsync: 记录参数, 输出 itemized 变更, 按 FAKE_RSYNC_RC 退出
cat > "$T/bin/rsync" <<'EOF'
#!/bin/bash
echo "ARGS:$*" >> "${FAKE_LOG:?}"
printf '>f+++++++++ app/foo.php\n'
printf '*deleting   app/old.php\n'
[ -n "${FAKE_DEL_FILE:-}" ] && [ -f "$FAKE_DEL_FILE" ] && cat "$FAKE_DEL_FILE"
exit "${FAKE_RSYNC_RC:-0}"
EOF
chmod +x "$T/bin/rsync"

export PATH="$T/bin:$PATH"
export FAKE_LOG="$T/fake.log"
export FAKE_RSYNC_RC=0

# 覆盖脚本默认路径后 source (函数内引用的是运行时变量)
STATE_DIR="$T/state"; LOG_FILE="$T/app.log"; GLOBAL_LOCK="$T/global.lock"
export STATE_DIR LOG_FILE GLOBAL_LOCK
. "$T/funcs.sh"
ensure_state_dir

pass=0; fail=0
chk() { # $1 描述, $2 实际, $3 期望
    if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1));
    else echo "FAIL: $1 (got='$2' want='$3')"; fail=$((fail+1)); fi
}

# ---- T1: report_changes 用全局变量返回, record_sync 可正常工作 ----
tmp=$(mktemp); printf '>f+++++++++ x\n' > "$tmp"
report_changes mallphp "L→W" "$tmp"
chk "REPORT_CHANGES=1" "$REPORT_CHANGES" "1"
tmp2=$(mktemp)
report_changes mallphp "L→W" "$tmp2"
chk "无变更时 REPORT_CHANGES=0" "$REPORT_CHANGES" "0"

# ---- T2: filter_escape ----
chk "filter_escape 转义" "$(filter_escape 'a*b?c[d\e')" 'a\*b\?c\[d\\e'

# ---- T3: run_rsync_locked (调用方持锁) ----
rm -f "$FAKE_LOG"
acquire_global_lock mallphp
run_rsync_locked mallphp "$T/out1" -x dummy
rc=$?
release_global_lock
chk "run_rsync_locked rc=0" "$rc" "0"
chk "锁已释放" "$([ -f "$GLOBAL_LOCK" ] && echo yes || echo no)" "no"

# ---- T4: L→W 无 dirty → 带 --delete, 台账清空, last_L2W 记录 ----
mkdir -p "$STATE_DIR/mallphp"
printf '/app/dead.php\n' > "$STATE_DIR/mallphp/pending_deletes"
rm -f "$FAKE_LOG"
sync_linux_to_win mallphp /server/www/mallphp /cygdrive/d/www/mallphp
chk "T4 L→W rc=0" "$?" "0"
grep -q -- '--delete' "$FAKE_LOG" && t=yes || t=no
chk "T4 带 --delete" "$t" "yes"
chk "T4 台账已清空(截断)" "$([ -s "$STATE_DIR/mallphp/pending_deletes" ] && echo no || echo yes)" "yes"
chk "T4 台账文件仍存在(未删除)" "$([ -e "$STATE_DIR/mallphp/pending_deletes" ] && echo yes || echo no)" "yes"
chk "T4 last_L2W 已记录" "$([ -f "$STATE_DIR/mallphp/last_L2W" ] && echo yes || echo no)" "yes"

# ---- T4b: 台账清空后 dry-run 正常且不带 exclude-from (exit 11 回归) ----
rm -f "$FAKE_LOG"
dryrun_w2l_changes mallphp /server/www/mallphp /cygdrive/d/www/mallphp
chk "T4b dry-run rc=0 (无台账)" "$DRYRUN_RC" "0"
grep -q -- '--exclude-from=' "$FAKE_LOG" && t=yes || t=no
chk "T4b 空台账不带 exclude-from" "$t" "no"

# ---- T5: 有 dirty → 不带 --delete, 台账保留 ----
: > "$STATE_DIR/mallphp/windows_dirty"
printf '/app/dead2.php\n' > "$STATE_DIR/mallphp/pending_deletes"
rm -f "$FAKE_LOG"
sync_linux_to_win mallphp /server/www/mallphp /cygdrive/d/www/mallphp
grep -q -- '--delete' "$FAKE_LOG" && t=yes || t=no
chk "T5 dirty 时不带 --delete" "$t" "no"
chk "T5 台账保留" "$([ -f "$STATE_DIR/mallphp/pending_deletes" ] && echo yes || echo no)" "yes"

# ---- T6: dry-run 计数走全局变量, 失败分支不污染 ----
rm -f "$STATE_DIR/mallphp/windows_dirty" "$FAKE_LOG"
dryrun_w2l_changes mallphp /server/www/mallphp /cygdrive/d/www/mallphp
chk "T6 DRYRUN_CHANGES=2" "$DRYRUN_CHANGES" "2"
chk "T6 DRYRUN_RC=0" "$DRYRUN_RC" "0"
grep -q -- '--exclude-from=' "$FAKE_LOG" && t=yes || t=no
chk "T6 dry-run 带台账排除" "$t" "yes"

rm -f "$STATE_DIR/mallphp/pending_deletes" "$FAKE_LOG"
FAKE_RSYNC_RC=255 dryrun_w2l_changes mallphp /server/www/mallphp /cygdrive/d/www/mallphp
chk "T6b 失败时 DRYRUN_CHANGES=0" "$DRYRUN_CHANGES" "0"
chk "T6b 失败时 DRYRUN_RC=255" "$DRYRUN_RC" "255"

# ---- T7: W→L 带台账排除, w2l_active 清理, last_W2L 记录 ----
rm -f "$STATE_DIR/mallphp/last_L2W" "$FAKE_LOG"
printf '/app/dead4.php\n' > "$STATE_DIR/mallphp/pending_deletes"
sync_win_to_linux mallphp /server/www/mallphp /cygdrive/d/www/mallphp
chk "T7 W→L rc=0" "$?" "0"
grep -q -- '--exclude-from=' "$FAKE_LOG" && t=yes || t=no
chk "T7 W→L 带台账排除" "$t" "yes"
chk "T7 w2l_active 已清理" "$([ -f "$STATE_DIR/mallphp/w2l_active" ] && echo yes || echo no)" "no"
chk "T7 last_W2L 已记录" "$([ -f "$STATE_DIR/mallphp/last_W2L" ] && echo yes || echo no)" "yes"
chk "T7 need_l2w_confirm 已标记" "$([ -f "$STATE_DIR/mallphp/need_l2w_confirm" ] && echo yes || echo no)" "yes"

# ---- T8: 回音抑制生效 (bug1 修复后 should_skip 真正工作) ----
rm -f "$FAKE_LOG"
before=$(grep -c 'ARGS:' "$FAKE_LOG" 2>/dev/null || echo 0)
sync_linux_to_win mallphp /server/www/mallphp /cygdrive/d/www/mallphp   # last_W2L 刚记录 → 应 SKIP
after=$(grep -c 'ARGS:' "$FAKE_LOG" 2>/dev/null || echo 0)
chk "T8 should_skip 生效 (L→W 被跳过)" "$after" "$before"

# ---- T9: 删除台账记录格式 (复刻 linux_watcher 内嵌逻辑) ----
rm -f "$STATE_DIR/mallphp/last_W2L"
events="DELETE"; file="/server/www/mallphp/app/old.php"; ldir="/server/www/mallphp"
if [[ "$events" =~ DELETE ]] || [[ "$events" =~ MOVED_FROM ]]; then
    if [ ! -f "$STATE_DIR/mallphp/w2l_active" ] && ! should_skip mallphp W2L; then
        rel="${file#$ldir/}"
        if [ "$rel" != "$file" ] && [ -n "$rel" ]; then
            rel=$(filter_escape "$rel")
            if [[ "$events" =~ ISDIR ]]; then printf '/%s/\n' "$rel"; else printf '/%s\n' "$rel"; fi
        fi
    fi
fi > "$T/rec.out"
chk "T9 文件删除记录格式" "$(cat "$T/rec.out")" "/app/old.php"

events="DELETE,ISDIR"; file="/server/www/mallphp/app/cache"; ldir="/server/www/mallphp"
if [[ "$events" =~ DELETE ]] || [[ "$events" =~ MOVED_FROM ]]; then
    if [ ! -f "$STATE_DIR/mallphp/w2l_active" ] && ! should_skip mallphp W2L; then
        rel="${file#$ldir/}"
        if [ "$rel" != "$file" ] && [ -n "$rel" ]; then
            rel=$(filter_escape "$rel")
            if [[ "$events" =~ ISDIR ]]; then printf '/%s/\n' "$rel"; else printf '/%s\n' "$rel"; fi
        fi
    fi
fi > "$T/rec2.out"
chk "T9 目录删除记录格式" "$(cat "$T/rec2.out")" "/app/cache/"

# ---- T10: W→L 进行中 (w2l_active) 时不记录台账 ----
: > "$STATE_DIR/mallphp/w2l_active"
events="DELETE"; file="/server/www/mallphp/app/foo.php"; ldir="/server/www/mallphp"
if [[ "$events" =~ DELETE ]] || [[ "$events" =~ MOVED_FROM ]]; then
    if [ ! -f "$STATE_DIR/mallphp/w2l_active" ] && ! should_skip mallphp W2L; then
        echo "RECORDED"
    fi
fi > "$T/rec3.out"
chk "T10 w2l_active 时跳过记录" "$(cat "$T/rec3.out")" ""
rm -f "$STATE_DIR/mallphp/w2l_active"

# ---- T11: Windows 删除传播 (凭证校验) ----
mkdir -p "$T/linux/app/olddir"
touch "$T/linux/app/dead.php" "$T/linux/app/keep.php" "$T/linux/app/nodata.php"
# linux_known: dead/olddir 凭证=1000 (旧), keep.php 凭证=2500 (比 last_ok 新), nodata 无凭证
printf '1000\tapp/dead.php\n1000\tapp/olddir\n2500\tapp/keep.php\n' > "$STATE_DIR/mallphp/linux_known"
echo 1999 > "$STATE_DIR/mallphp/last_l2w_ok"
cat > "$T/dellines" <<'EOF'
*deleting   app/dead.php
*deleting   app/keep.php
*deleting   app/nodata.php
*deleting   app/olddir/
EOF
export FAKE_DEL_FILE="$T/dellines"
propagate_win_deletions mallphp "$T/linux" /cygdrive/d/www/mallphp
chk "T11 有凭证的删除已执行" "$([ -f "$T/linux/app/dead.php" ] && echo no || echo yes)" "yes"
chk "T11 凭证过新的保留"     "$([ -f "$T/linux/app/keep.php" ] && echo yes || echo no)" "yes"
chk "T11 无凭证的保留"       "$([ -f "$T/linux/app/nodata.php" ] && echo yes || echo no)" "yes"
chk "T11 有凭证目录已删"     "$([ -d "$T/linux/app/olddir" ] && echo no || echo yes)" "yes"

# ---- T12: 开关关闭时不传播 ----
PROPAGATE_WIN_DELETE="false"
touch "$T/linux/app/dead.php"
propagate_win_deletions mallphp "$T/linux" /cygdrive/d/www/mallphp
chk "T12 开关关闭时不删" "$([ -f "$T/linux/app/dead.php" ] && echo yes || echo no)" "yes"
PROPAGATE_WIN_DELETE="true"
unset FAKE_DEL_FILE

# ---- T13: seed_linux_known 格式 ----
mkdir -p "$T/seed/app/sub"
touch "$T/seed/app/a.php" "$T/seed/app/sub/b.php"
seed_linux_known mallphp "$T/seed"
grep -q $'\tapp/a.php$' "$STATE_DIR/mallphp/linux_known" && t=yes || t=no
chk "T13 seed 含文件条目" "$t" "yes"
grep -q $'\tapp/sub$' "$STATE_DIR/mallphp/linux_known" && t=yes || t=no
chk "T13 seed 含目录条目" "$t" "yes"
chk "T13 seed 行格式" "$(head -n1 "$STATE_DIR/mallphp/linux_known" | grep -c $'^[0-9][0-9]*\t')" "1"

# ---- T14: record_linux_known 格式 ----
record_linux_known mallphp "app/x.php"
tail -n 1 "$STATE_DIR/mallphp/linux_known" | grep -q $'\tapp/x.php$' && t=yes || t=no
chk "T14 record 格式正确" "$t" "yes"

# ---- T15: 预检中止 (dirty 在重试前挂锁 → 放弃 --delete) ----
sync_precheck_dirty() { return 1; }   # 模拟预检失败
printf '/app/x.php\n' > "$STATE_DIR/mallphp/pending_deletes"
rm -f "$FAKE_LOG"
sync_linux_to_win mallphp /server/www/mallphp /cygdrive/d/www/mallphp
rc=$?
chk "T15 预检中止 rc=10" "$rc" "10"
chk "T15 未执行 rsync" "$(grep -c 'ARGS:' "$FAKE_LOG" 2>/dev/null || echo 0)" "0"
chk "T15 台账保留" "$([ -s "$STATE_DIR/mallphp/pending_deletes" ] && echo yes || echo no)" "yes"
unset -f sync_precheck_dirty

# ---- T16: need_l2w_confirm 清除逻辑 (复刻 windows_watcher 内嵌片段) ----
echo 100 > "$STATE_DIR/mallphp/need_l2w_confirm"
echo 200 > "$STATE_DIR/mallphp/last_l2w_ok"
l2wo=$(cat "$STATE_DIR/mallphp/last_l2w_ok" 2>/dev/null || echo 0)
cts=$(cat "$STATE_DIR/mallphp/need_l2w_confirm" 2>/dev/null || echo 0)
[ "$l2wo" -gt "$cts" ] && rm -f "$STATE_DIR/mallphp/need_l2w_confirm"
chk "T16 last_l2w_ok 推进后清除标记" "$([ -f "$STATE_DIR/mallphp/need_l2w_confirm" ] && echo yes || echo no)" "no"
echo 300 > "$STATE_DIR/mallphp/need_l2w_confirm"
echo 200 > "$STATE_DIR/mallphp/last_l2w_ok"
l2wo=$(cat "$STATE_DIR/mallphp/last_l2w_ok" 2>/dev/null || echo 0)
cts=$(cat "$STATE_DIR/mallphp/need_l2w_confirm" 2>/dev/null || echo 0)
[ "$l2wo" -gt "$cts" ] && rm -f "$STATE_DIR/mallphp/need_l2w_confirm"
chk "T16 last_l2w_ok 未推进则保留标记" "$([ -f "$STATE_DIR/mallphp/need_l2w_confirm" ] && echo yes || echo no)" "yes"

echo
echo "结果: $pass PASS, $fail FAIL"
[ "$fail" -eq 0 ]
