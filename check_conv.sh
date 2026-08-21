#!/bin/bash
# 一致性检查器: 等待 L→W 与 W→L 双向 dry-run 均干净 (0 变更)
# 用法: check_conv.sh <label> [超时秒, 默认 60]
# 退出码: 0 = 收敛, 1 = 超时未收敛
# 同时输出双方差异明细到 /tmp/check_conv_diff.txt
set -u
LABEL="${1:-conv}"
TIMEOUT="${2:-60}"
PROJ="__synctest"
LDIR="/server/www/__synctest"
WDIR="/cygdrive/d/www/__synctest"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes -o ServerAliveInterval=15"
WIN_RSYNC_PATH="\"D:/Program Files (x86)/cwRsync/bin/rsync.exe\""
EXCL=(--exclude=.git/ --exclude=.svn/ --exclude=.idea/ --exclude=.vscode/
      --exclude=node_modules/ --exclude=runtime/ --exclude=unpackage/ --exclude=cache/
      --exclude=/config/database.local.php --exclude=*.bak --exclude=.env --exclude=.env.development
      --exclude=*.log --exclude=*.tmp --exclude=*.swp --exclude=*.zip --exclude='~$*')

acquire_lock() {  # 与测试实例同一把锁, 避免并发连接 cwRsync (error 12)
    while ! (set -o noclobber; echo "$$" > /tmp/rsync_global_test.lock) 2>/dev/null; do
        sleep 0.5
    done
}
release_lock() { rm -f /tmp/rsync_global_test.lock; }

count_w2l() {  # W→L dry-run 变更数
    local tmp
    tmp=$(mktemp /tmp/ck_w2l.XXXXXX)
    acquire_lock
    timeout 45 rsync -rtin --update --no-owner --no-group --no-perms --modify-window=2 --timeout=30 \
        -e "ssh $SSH_OPTS -p 22" --rsync-path="$WIN_RSYNC_PATH" \
        "${EXCL[@]}" "amei@192.168.1.10:$WDIR/" "$LDIR/" > "$tmp" 2>&1
    local rc=$?
    release_lock
    grep -cE '^[><cfhpguax*]' "$tmp" 2>/dev/null || true
    [ $rc -ne 0 ] && [ $rc -ne 24 ] && echo "RC_$rc"
    rm -f "$tmp"
}

count_l2w() {  # L→W dry-run --delete 变更数
    local tmp
    tmp=$(mktemp /tmp/ck_l2w.XXXXXX)
    acquire_lock
    timeout 45 rsync -avzi --update --delete --no-owner --no-group --no-perms --modify-window=2 \
        --omit-dir-times --timeout=30 \
        -e "ssh $SSH_OPTS -p 22" --rsync-path="$WIN_RSYNC_PATH" \
        "${EXCL[@]}" "$LDIR/" "amei@192.168.1.10:$WDIR/" > "$tmp" 2>&1
    local rc=$?
    release_lock
    grep -cE '^[><cfhpguax*]' "$tmp" 2>/dev/null || true
    [ $rc -ne 0 ] && [ $rc -ne 24 ] && echo "RC_$rc"
    cp "$tmp" /tmp/check_conv_diff.txt 2>/dev/null
    rm -f "$tmp"
}

start=$(date +%s)
while true; do
    c1=$(count_w2l)
    c2=$(count_l2w)
    if [[ "$c1" == "0" && "$c2" == "0" ]]; then
        echo "✅ $LABEL 已收敛 (W→L=$c1 L→W=$c2, 用时 $(( $(date +%s) - start ))s)"
        exit 0
    fi
    now=$(date +%s)
    if [ $(( now - start )) -ge "$TIMEOUT" ]; then
        echo "❌ $LABEL 未收敛 (W→L=$c1 L→W=$c2, 超时 ${TIMEOUT}s)"
        echo "--- L→W dry-run 剩余差异 ---"
        cat /tmp/check_conv_diff.txt 2>/dev/null | head -20
        exit 1
    fi
    sleep 3
done
