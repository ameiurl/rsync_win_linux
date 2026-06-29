#!/bin/bash
# 权限修复与防抖增强版 - 多项目双向实时监控同步脚本
# 作者: AMEI (基于原版修改)
# 版本: 5.0 (支持单向/双向模式切换)
# 功能: 支持同时监控和同步多个独立的目录对，可选单向或双向同步

# --- 同步模式配置 ---
# 可选值: "bidirectional" (双向) 或 "unidirectional" (单向: Linux → Windows)
# 可通过命令行参数覆盖: --mode=unidirectional 或 --mode=bidirectional
# 简写: -u (单向) 或 -b (双向)
SYNC_MODE=unidirectional

# --- 全局配置 (所有项目共享) ---
# SSH_USER="amei"
# SSH_HOST="192.168.1.3"
SSH_USER="Administrator"
SSH_HOST="192.168.1.9"
SSH_PORT="22"
WIN_RSYNC_PATH="\"D:/Program Files (x86)/cwRsync/bin/rsync.exe\"" # 注意引号的使用
SSH_OPTS="-p $SSH_PORT -o ControlMaster=auto -o ControlPath=/tmp/ssh_mux_%r@%h:%p -o ControlPersist=60"
RETRY_MAX=10
LOG_FILE="/home/amei/multi_sync.log"
PID_FILE="/tmp/multi_sync.pid"
STATE_DIR="/tmp/sync_state"  # 状态目录（双向模式使用）

# 权限修复相关
NORMAL_USER="amei"
NORMAL_GROUP="amei"

PROJECT_BASE_NAMES=(
    "mallphp"
    "admin_frontend"
    "store_uniapp"
)

# 以下数组将根据 PROJECT_BASE_NAMES 自动生成，无需手动修改
PROJECT_NAMES=()
LINUX_DIRS=()
WIN_DIRS=()

# 自动生成项目名称和目录路径
for name in "${PROJECT_BASE_NAMES[@]}"; do
    PROJECT_NAMES+=("$name")
    LINUX_DIRS+=("/server/www/$name")
    WIN_DIRS+=("D:\\www\\$name")
done

# --- 全局排除列表 (所有项目共享) ---
RSYNC_EXCLUDES=(
    "--exclude=.git/" "--exclude=.svn/" "--exclude=.idea/" "--exclude=.vscode/"
    "--exclude=node_modules/" "--exclude=runtime/" "--exclude=unpackage/" "--exclude=cache/"
    "--exclude=/config/database.local.php" "--exclude=*.bak" "--exclude=.env" "--exclude=.env.development"
    "--exclude=*.log" "--exclude=*.tmp" "--exclude=*.swp" "--exclude=*.zip" "--exclude=~$*"
)

# inotifywait ERE 正则表达式格式
INOTIFY_EXCLUDE_PATTERN='(\.git/|\.svn/|\.idea/|\.vscode/|node_modules/|runtime/|unpackage/|cache/|^config/database\.local\.php$|\.bak$|\.env$|\.log$|\.tmp$|\.swp$|^~\$.*)'

# --- 命令行参数解析 ---
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--unidirectional|--one-way)
                SYNC_MODE="unidirectional"
                shift
                ;;
            -b|--bidirectional|--two-way)
                SYNC_MODE="bidirectional"
                shift
                ;;
            --mode=*)
                SYNC_MODE="${1#*=}"
                shift
                ;;
            -h|--help)
                exit 0
                ;;
            *)
                echo -e "\033[0;31m❌ 未知参数: $1\033[0m"
                exit 1
                ;;
        esac
    done
    
    # 验证模式值
    if [[ "$SYNC_MODE" != "bidirectional" && "$SYNC_MODE" != "unidirectional" ]]; then
        echo -e "\033[0;31m❌ 无效的同步模式: $SYNC_MODE\033[0m"
        echo "有效值: bidirectional (双向) 或 unidirectional (单向)"
        exit 1
    fi
}
# --- 工具函数 ---
log() {
    local project_name="$1"
    local level="$2"
    local message="$3"
    
    # BASHPID 能准确反映当前子进程的ID
    local pid="$BASHPID"

    # 颜色和符号定义
    local C_RESET='\033[0m'; local C_CYAN='\033[0;36m'; local C_GREEN='\033[0;32m'; local C_YELLOW='\033[0;33m'; local C_RED='\033[0;31m'; local C_BLUE='\033[0;34m'; local C_GRAY='\033[0;90m'; local C_MAGENTA='\033[0;35m'
    local color=""; local symbol=""
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
        "MAIN")     color="$C_GREEN";  symbol="🎬" ;;
        "SKIP")     color="$C_MAGENTA";symbol="⏭️" ;;
        "DEBUG")    color="$C_GRAY";   symbol="🔧" ;;
        "SUCCESS")  color="$C_GREEN";  symbol="✅" ;;
        "MODE")     color="$C_YELLOW"; symbol="⚙️" ;;
        *)          color="$C_RESET";  symbol="➡️" ;;
    esac

    # 对 SYNC_DETAIL 特殊处理，增加缩进
    if [[ "$level" == "SYNC_DETAIL" ]]; then
        echo -e "    $message" | tee -a "$LOG_FILE"
    else
        # 在日志中加入 BASHPID
        echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [PID:$pid] ${C_GREEN}[$project_name]${C_RESET} ${color}${symbol} $message${C_RESET}" | tee -a "$LOG_FILE"
    fi
}

# 检查是否为双向模式
is_bidirectional() {
    [[ "$SYNC_MODE" == "bidirectional" ]]
}

# 确保状态目录存在（仅双向模式需要）
ensure_state_dir() {
    if is_bidirectional; then
        mkdir -p "$STATE_DIR"
        for project_name in "${PROJECT_NAMES[@]}"; do
            mkdir -p "$STATE_DIR/$project_name"
        done
    fi
}

# 记录同步操作（防回环，仅双向模式使用）
record_sync() {
    if ! is_bidirectional; then
        return 0
    fi
    
    local project_name="$1"
    local direction="$2"  # "L2W" 或 "W2L"
    local state_file="$STATE_DIR/$project_name/last_sync"
    echo "$(date +%s):$direction" > "$state_file"
}

# 检查是否刚刚同步过（避免回环，仅双向模式使用）
should_skip_sync() {
    if ! is_bidirectional; then
        return 1  # 单向模式不需要跳过
    fi
    
    local project_name="$1"
    local direction="$2"
    local state_file="$STATE_DIR/$project_name/last_sync"
    
    if [ ! -f "$state_file" ]; then
        return 1  # 不跳过
    fi
    
    local last_sync_info
    last_sync_info=$(cat "$state_file")
    local last_sync_time="${last_sync_info%%:*}"
    local last_sync_dir="${last_sync_info##*:}"
    local current_time
    current_time=$(date +%s)
    local time_diff=$((current_time - last_sync_time))
    
    # 如果15秒内刚做过反向同步，则跳过（增加到15秒）
    if [ "$direction" == "W2L" ] && [ "$last_sync_dir" == "L2W" ] && [ $time_diff -lt 15 ]; then
        log "$project_name" "SKIP" "跳过 W→L 同步（${time_diff}秒前刚执行过 L→W）"
        return 0  # 跳过
    fi
    if [ "$direction" == "L2W" ] && [ "$last_sync_dir" == "W2L" ] && [ $time_diff -lt 15 ]; then
        log "$project_name" "SKIP" "跳过 L→W 同步（${time_diff}秒前刚执行过 W→L）"
        return 0  # 跳过
    fi
    
    return 1  # 不跳过
}

# 锁函数保持不变
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
        log "$project_name" "LOCK" "等待锁... (当前持有者 PID: $holder_pid)"
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

# --- 核心同步函数（修复版）---
sync_linux_to_win() {
    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3"

    # 双向模式下检查防回环
    if is_bidirectional && should_skip_sync "$project_name" "L2W"; then
        return 0
    fi

    log "$project_name" "SYNC" "L→W: 推送 Linux 变更..."
    local rsync_output_file; rsync_output_file=$(mktemp "/tmp/rsync_${project_name}_linux_out.XXXXXX")
    local exit_code=0
    local max_retries=10
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        # 使用 --update 和 --omit-dir-times 避免不必要的目录时间戳更新
        rsync -avzi --update --no-owner --no-group --delete \
              --modify-window=2 --omit-dir-times \
              -e "ssh $SSH_OPTS" --rsync-path="$WIN_RSYNC_PATH" \
              "${RSYNC_EXCLUDES[@]}" "$linux_dir/" "$SSH_USER@$SSH_HOST:$win_cygdrive_path/" > "$rsync_output_file" 2>&1
        exit_code=$?

        # 退出码 12 (protocol data stream error) 是 cwRsync 的间歇性 socket 问题，重试即可恢复
        if [ $exit_code -eq 12 ] && [ $attempt -lt $max_retries ]; then
            local delay=$((1 + RANDOM % 4))  # 1-4 秒随机延迟，打破时序共振
            log "$project_name" "INFO" "L→W socket 错误 [代码 12]，${attempt}/${max_retries} 次重试，等待 ${delay} 秒..."
            sleep "$delay"
            ((attempt++))
            continue
        fi
        break
    done

    # 只输出实际有变化的内容（过滤掉只有时间戳变化的）
    if [ -s "$rsync_output_file" ]; then
        local has_real_changes=$(grep -E "^[><cfhpguax*]" "$rsync_output_file" | head -1)
        if [ -n "$has_real_changes" ]; then
            log "$project_name" "SYNC_DETAIL" "--- rsync 输出 (L→W) ---"
            sed 's/^/    /g' "$rsync_output_file" | tee -a "$LOG_FILE" > /dev/null
            log "$project_name" "SYNC_DETAIL" "--- 结束输出 ---"
        fi
    fi

    rm -f "$rsync_output_file"

    if [ $exit_code -eq 0 ] || [ $exit_code -eq 24 ]; then
        record_sync "$project_name" "L2W"
        log "$project_name" "INFO" "L→W 同步完成"
    else
        log "$project_name" "ERROR" "L→W 推送失败 [代码 $exit_code]（已重试 $((attempt - 1)) 次）"
    fi
}

sync_win_to_linux() {
    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3"

    if ! is_bidirectional; then
        return 0
    fi

    if should_skip_sync "$project_name" "W2L"; then
        return 0
    fi

    log "$project_name" "SYNC" "W→L: 拉取 Windows 变更..."
    local rsync_output_file; rsync_output_file=$(mktemp "/tmp/rsync_${project_name}_win_out.XXXXXX")
    local final_exit_code=0
    local has_real_changes=false
    local attempt exit_code delay

    # 步骤 1: 同步目录结构
    attempt=1
    while [ $attempt -le $RETRY_MAX ]; do
        rsync -d --recursive --no-owner --no-group --chmod=D755 \
              --modify-window=2 --omit-dir-times \
              -e "ssh $SSH_OPTS" --rsync-path="$WIN_RSYNC_PATH" \
              "${RSYNC_EXCLUDES[@]}" "$SSH_USER@$SSH_HOST:$win_cygdrive_path/" "$linux_dir/" > "$rsync_output_file" 2>&1
        exit_code=$?
        if [ $exit_code -eq 12 ] && [ $attempt -lt $RETRY_MAX ]; then
            delay=$((1 + RANDOM % 4))
            log "$project_name" "INFO" "W→L 目录同步 socket 错误 [代码 12]，${attempt}/${RETRY_MAX} 次重试，等待 ${delay} 秒..."
            sleep "$delay"
            ((attempt++))
            continue
        fi
        break
    done
    if [ $exit_code -ne 0 ] && [ $exit_code -ne 24 ]; then
        final_exit_code=$exit_code
    fi

    # 步骤 2: 更新已存在文件（保护权限）
    attempt=1
    while [ $attempt -le $RETRY_MAX ]; do
        rsync -rtzi --update --existing --no-owner --no-group --no-perms \
              --modify-window=2 --omit-dir-times \
              -e "ssh $SSH_OPTS" --rsync-path="$WIN_RSYNC_PATH" \
              "${RSYNC_EXCLUDES[@]}" "$SSH_USER@$SSH_HOST:$win_cygdrive_path/" "$linux_dir/" >> "$rsync_output_file" 2>&1
        exit_code=$?
        if [ $exit_code -eq 12 ] && [ $attempt -lt $RETRY_MAX ]; then
            delay=$((1 + RANDOM % 4))
            log "$project_name" "INFO" "W→L 更新文件 socket 错误 [代码 12]，${attempt}/${RETRY_MAX} 次重试，等待 ${delay} 秒..."
            sleep "$delay"
            ((attempt++))
            continue
        fi
        break
    done

    if grep -E "^>f" "$rsync_output_file" > /dev/null 2>&1; then
        has_real_changes=true
    fi

    if [ $exit_code -ne 0 ] && [ $exit_code -ne 24 ]; then
        final_exit_code=$exit_code
    fi

    # 步骤 3: 新增文件（设置权限）
    attempt=1
    while [ $attempt -le $RETRY_MAX ]; do
        rsync -rtzl --ignore-existing --chmod=D755,F644 \
              --modify-window=2 --omit-dir-times \
              -e "ssh $SSH_OPTS" --rsync-path="$WIN_RSYNC_PATH" \
              "${RSYNC_EXCLUDES[@]}" "$SSH_USER@$SSH_HOST:$win_cygdrive_path/" "$linux_dir/" >> "$rsync_output_file" 2>&1
        exit_code=$?
        if [ $exit_code -eq 12 ] && [ $attempt -lt $RETRY_MAX ]; then
            delay=$((1 + RANDOM % 4))
            log "$project_name" "INFO" "W→L 新增文件 socket 错误 [代码 12]，${attempt}/${RETRY_MAX} 次重试，等待 ${delay} 秒..."
            sleep "$delay"
            ((attempt++))
            continue
        fi
        break
    done

    if grep -E "^>f\+\+\+\+\+\+\+\+\+" "$rsync_output_file" > /dev/null 2>&1; then
        has_real_changes=true
    fi

    if [ $exit_code -ne 0 ] && [ $exit_code -ne 24 ]; then
        final_exit_code=$exit_code
    fi

    # 步骤 4: 删除多余文件
    attempt=1
    while [ $attempt -le $RETRY_MAX ]; do
        rsync -rd --delete --existing --ignore-non-existing --no-owner --no-group --no-perms \
              --modify-window=2 --omit-dir-times \
              -e "ssh $SSH_OPTS" --rsync-path="$WIN_RSYNC_PATH" \
              "${RSYNC_EXCLUDES[@]}" "$SSH_USER@$SSH_HOST:$win_cygdrive_path/" "$linux_dir/" >> "$rsync_output_file" 2>&1
        exit_code=$?
        if [ $exit_code -eq 12 ] && [ $attempt -lt $RETRY_MAX ]; then
            delay=$((1 + RANDOM % 4))
            log "$project_name" "INFO" "W→L 删除文件 socket 错误 [代码 12]，${attempt}/${RETRY_MAX} 次重试，等待 ${delay} 秒..."
            sleep "$delay"
            ((attempt++))
            continue
        fi
        break
    done

    if grep -E "^\*deleting" "$rsync_output_file" > /dev/null 2>&1; then
        has_real_changes=true
    fi

    if [ $exit_code -ne 0 ] && [ $exit_code -ne 24 ]; then
        final_exit_code=$exit_code
    fi

    # 只有实际有文件变化时才输出日志
    if [ "$has_real_changes" = true ] && [ -s "$rsync_output_file" ]; then
        log "$project_name" "SYNC_DETAIL" "--- rsync 综合输出 (W→L) ---"
        grep -v "^\.d\.\.t\.\.\.\.\.\." "$rsync_output_file" | sed 's/^/    /g' | tee -a "$LOG_FILE" > /dev/null
        log "$project_name" "SYNC_DETAIL" "--- 结束输出 ---"
    fi

    rm -f "$rsync_output_file"

    if [ $final_exit_code -eq 0 ] || [ $final_exit_code -eq 24 ]; then
        if [ "$has_real_changes" = true ]; then
            record_sync "$project_name" "W2L"
            log "$project_name" "INFO" "W→L 同步完成（有实际文件变化）"
        else
            log "$project_name" "INFO" "W→L 检查完成（仅时间戳差异，无实际变化）"
        fi
    else
        log "$project_name" "ERROR" "W→L 拉取过程中发生错误 [代码 $final_exit_code]"
    fi
}

# 【修复】改为单向同步，避免回退
reconcile_and_sync() {
    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3" trigger_source="$4"
    
    if [[ "$trigger_source" == "linux" ]]; then
        # Linux变化时，只推送到Windows
        sync_linux_to_win "$project_name" "$linux_dir" "$win_cygdrive_path"
    elif [[ "$trigger_source" == "windows" ]]; then
        # Windows变化时，只拉取到Linux（仅双向模式）
        if is_bidirectional; then
            sync_win_to_linux "$project_name" "$linux_dir" "$win_cygdrive_path"
        fi
    else
        # 启动时执行同步
        if is_bidirectional; then
            log "$project_name" "INIT" "执行初始化双向同步..."
            sync_linux_to_win "$project_name" "$linux_dir" "$win_cygdrive_path"
            sleep 3  # 等待3秒
            sync_win_to_linux "$project_name" "$linux_dir" "$win_cygdrive_path"
        else
            log "$project_name" "INIT" "执行初始化单向同步 (L→W)..."
            sync_linux_to_win "$project_name" "$linux_dir" "$win_cygdrive_path"
        fi
    fi
}

# --- 监控与触发器（改进版）---
monitor_linux_changes() {
    local project_name="$1" linux_dir="$2" change_flag_file="$3"
    log "$project_name" "L-MON" "开始监控 Linux: $linux_dir"
    
    # 添加一个同步后的忽略时间窗口（仅双向模式使用）
    local ignore_file="$STATE_DIR/$project_name/ignore_until"
    
    inotifywait -m -r -q -e create,delete,modify,move,close_write \
                --excludei "$INOTIFY_EXCLUDE_PATTERN" \
                "$linux_dir" |
    while read -r path action file; do
        # 过滤掉属性变化事件和目录的时间戳事件
        if [[ "$action" =~ (ATTRIB|ISDIR) ]]; then
            continue
        fi
        
        # 双向模式下检查是否在忽略时间窗口内
        if is_bidirectional && [ -f "$ignore_file" ]; then
            local ignore_until=$(cat "$ignore_file")
            local current_time=$(date +%s)
            if [ "$current_time" -lt "$ignore_until" ]; then
                continue  # 忽略这个事件
            else
                rm -f "$ignore_file"  # 清理过期的忽略标记
            fi
        fi
        
        touch "$change_flag_file"
    done
}

debounce_and_sync_linux() {
    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3" \
          lock_file="$4" change_flag_file="$5"
          
    log "$project_name" "L-SYNC" "防抖服务已启动。"
    while true; do
        while [ ! -f "$change_flag_file" ]; do sleep 0.5; done

        echo | tee -a "$LOG_FILE"
        log "$project_name" "EVENT" "检测到 Linux 变化，准备处理..."
        if acquire_lock "$project_name" "$lock_file" "Sync from Linux"; then
            log "$project_name" "INFO" "已获取锁，进入 3 秒稳定期..."
            while [ -f "$change_flag_file" ]; do
                rm -f "$change_flag_file"
                sleep 3  # 增加到3秒
            done
            log "$project_name" "INFO" "文件系统已稳定。"
            
            # 双向模式下设置忽略时间窗口（同步后5秒内忽略变化）
            if is_bidirectional; then
                local ignore_file="$STATE_DIR/$project_name/ignore_until"
                echo $(($(date +%s) + 5)) > "$ignore_file"
            fi
            
            reconcile_and_sync "$project_name" "$linux_dir" "$win_cygdrive_path" "linux"
            release_lock "$project_name" "$lock_file"
        fi
    done
}

# Windows 监控函数（仅双向模式使用）
monitor_windows_changes() {
    local project_name="$1" linux_dir="$2" win_cygdrive_path="$3" \
          lock_file="$4"
    
    # 单向模式下直接返回
    if ! is_bidirectional; then
        log "$project_name" "W-MON" "单向模式，跳过 Windows 监控"
        return 0
    fi
          
    log "$project_name" "W-MON" "开始轮询 Windows (间隔 8s)..."
    
    while true; do
        sleep 8
        
        # 简化的检测：直接尝试同步，让 rsync 自己判断是否有变化
        local temp_output
        temp_output=$(rsync -rtin --delete --no-owner --no-group --no-perms \
                     --modify-window=2 \
                     -e "ssh $SSH_OPTS" --rsync-path="$WIN_RSYNC_PATH" \
                     "${RSYNC_EXCLUDES[@]}" "$SSH_USER@$SSH_HOST:$win_cygdrive_path/" "$linux_dir/" 2>&1)
        local exit_code=$?
        
        # 如果有输出且不是错误，说明有变化
        if [ $exit_code -eq 0 ] || [ $exit_code -eq 24 ]; then
            if echo "$temp_output" | grep -E "^[><cfhpguax*]" > /dev/null 2>&1; then
                echo | tee -a "$LOG_FILE"
                log "$project_name" "EVENT" "检测到 Windows 变化"
                if acquire_lock "$project_name" "$lock_file" "Sync from Windows"; then
                    reconcile_and_sync "$project_name" "$linux_dir" "$win_cygdrive_path" "windows"
                    release_lock "$project_name" "$lock_file"
                fi
            fi
        else
            log "$project_name" "DEBUG" "Windows 检测出错，代码: $exit_code"
        fi
    done
}

# --- 脚本主程序 ---
main() {
    # 解析命令行参数
    parse_arguments "$@"
    
    # 检查全局 PID 文件
    if [ -f "$PID_FILE" ] && ps -p "$(cat "$PID_FILE")" > /dev/null; then
        echo -e "\033[0;31m❌ 主脚本已在运行 (PID: $(cat "$PID_FILE"))。请先停止旧实例。\033[0m"
        exit 1
    fi
    echo $$ > "$PID_FILE"
    
    # 确保状态目录存在（仅双向模式需要）
    ensure_state_dir
    
    # 存储所有子进程PID
    declare -a ALL_PIDS=()
    
    # 清理函数
    cleanup() {
        echo -e "\n\033[0;33m🛑 接收到信号，正在清理并退出...\033[0m"
        rm -f "$PID_FILE"
        for project_name in "${PROJECT_NAMES[@]}"; do
            rm -f "/tmp/rsync_${project_name}.lock" "/tmp/${project_name}_change.flag"
        done
        # 仅双向模式有状态目录
        if is_bidirectional; then
            rm -rf "$STATE_DIR"
        fi
        if [ ${#ALL_PIDS[@]} -gt 0 ]; then
            echo -e "\033[0;33mℹ️  正在停止所有子进程: ${ALL_PIDS[*]}\033[0m"
            kill "${ALL_PIDS[@]}" 2>/dev/null
            sleep 1
            kill -9 "${ALL_PIDS[@]}" 2>/dev/null
        fi
        echo -e "\033[0;32m👋 脚本已停止。\033[0m"
        exit 0
    }
    trap cleanup SIGINT SIGTERM
    
    # 脚本启动日志
    echo | tee -a "$LOG_FILE"
    log "MAIN" "INIT" "================== 脚本启动 (PID: $$) =================="
    
    # 显示同步模式
    if is_bidirectional; then
        log "MAIN" "MODE" "同步模式: 双向 (Linux ⇄ Windows)"
    else
        log "MAIN" "MODE" "同步模式: 单向 (Linux → Windows)"
    fi
    
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE" || { echo "错误：无法创建或写入日志文件 $LOG_FILE"; exit 1; }
    
    # 遍历并启动每个项目的监控
    for i in "${!PROJECT_NAMES[@]}"; do
        local project_name="${PROJECT_NAMES[i]}"
        local linux_dir="${LINUX_DIRS[i]}"
        local win_dir="${WIN_DIRS[i]}"
        local win_cygdrive_path="/cygdrive/$(echo "$win_dir" | sed 's/\\/\//g' | sed 's/://' | tr '[:upper:]' '[:lower:]')"
        local lock_file="/tmp/rsync_${project_name}.lock"
        local change_flag_file="/tmp/${project_name}_change.flag"
        
        echo | tee -a "$LOG_FILE"
        log "$project_name" "INIT" "--- 初始化项目: $project_name ---"
        log "$project_name" "INFO" "Linux 目录: $linux_dir"
        log "$project_name" "INFO" "Windows 目录: $win_dir -> $win_cygdrive_path"
        rm -f "$lock_file" "$change_flag_file"
        reconcile_and_sync "$project_name" "$linux_dir" "$win_cygdrive_path" "startup"
        
        # 启动 Linux 监控（始终需要）
        monitor_linux_changes "$project_name" "$linux_dir" "$change_flag_file" &
        ALL_PIDS+=($!)
        log "$project_name" "INFO" "Linux 监控进程已启动 (PID: ${ALL_PIDS[-1]})"
        
        # 启动 Linux 防抖同步
        debounce_and_sync_linux "$project_name" "$linux_dir" "$win_cygdrive_path" "$lock_file" "$change_flag_file" &
        ALL_PIDS+=($!)
        log "$project_name" "INFO" "Linux 同步进程已启动 (PID: ${ALL_PIDS[-1]})"
        
        # 仅双向模式启动 Windows 监控
        if is_bidirectional; then
            monitor_windows_changes "$project_name" "$linux_dir" "$win_cygdrive_path" "$lock_file" &
            ALL_PIDS+=($!)
            log "$project_name" "INFO" "Windows 监控进程已启动 (PID: ${ALL_PIDS[-1]})"
        fi
    done
    
    echo | tee -a "$LOG_FILE"
    log "MAIN" "INIT" "所有项目的监控进程已启动。"
    log "MAIN" "INFO" "所有子进程 PIDs: ${ALL_PIDS[*]}"
    log "MAIN" "INFO" "日志文件位于: $LOG_FILE"
    
    if is_bidirectional; then
        echo -e "\033[0;32m✅ 双向同步正在运行 (Linux ⇄ Windows)\033[0m"
    else
        echo -e "\033[0;32m✅ 单向同步正在运行 (Linux → Windows)\033[0m"
    fi
    echo -e "\033[0;33m📌 按 Ctrl+C 停止脚本\033[0m"
    
    wait
}

# --- 执行 ---
main "$@"
