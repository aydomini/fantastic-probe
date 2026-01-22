#!/bin/bash

#==============================================================================
# ISO 媒体信息提取服务 - 实时监控版本
# 功能：实时监控 strm 目录，自动处理新增的 .iso.strm 文件
# 作者：Fantastic-Probe Team
# 版本：v2.9.1
#==============================================================================

# 版本号（用于更新检查和版本显示）
VERSION="2.9.1"

set -euo pipefail

#==============================================================================
# 配置参数
#==============================================================================

# 配置文件路径
CONFIG_FILE="${CONFIG_FILE:-/etc/fantastic-probe/config}"

# 默认配置（如果配置文件不存在，使用以下默认值）
# STRM 根目录
STRM_ROOT="/mnt/sata1/media/媒体库/strm"

# FFprobe 路径
FFPROBE="/usr/bin/ffprobe"

# 日志文件
LOG_FILE="/var/log/fantastic_probe.log"
ERROR_LOG_FILE="/var/log/fantastic_probe_errors.log"

# 锁文件（防止并发运行）
LOCK_FILE="/tmp/fantastic_probe_monitor.lock"

# 任务队列文件（FIFO）
QUEUE_FILE="/tmp/fantastic_probe_queue.fifo"

# 超时时间（秒）
FFPROBE_TIMEOUT=300

# 单个文件最大处理时间（秒）
MAX_FILE_PROCESSING_TIME=600

# 防抖时间（秒）- 同一文件在此时间内的重复事件会被忽略
DEBOUNCE_TIME=5

# 自动更新配置
AUTO_UPDATE_CHECK=true
AUTO_UPDATE_INSTALL=false

# 加载配置文件（如果存在）
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

#==============================================================================
# 全局变量
#==============================================================================

# 已处理文件的时间戳记录（防抖）
declare -A PROCESSED_FILES

#==============================================================================
# 清理函数
#==============================================================================

cleanup() {
    local exit_code=$?

    log_info "监控服务正在停止..."

    # 移除锁文件
    if [ -f "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE"
    fi

    # 移除队列文件
    if [ -p "$QUEUE_FILE" ]; then
        rm -f "$QUEUE_FILE"
    fi

    # 杀死可能存在的子进程
    pkill -P $$ 2>/dev/null || true

    if [ $exit_code -ne 0 ]; then
        log_warn "监控服务异常退出（退出码: $exit_code）"
    else
        log_info "监控服务已停止"
    fi

    exit $exit_code
}

trap cleanup EXIT
trap 'log_warn "收到中断信号，正在停止..."; exit 130' INT TERM

#==============================================================================
# 日志函数
#==============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE" >&2
}

log_info() {
    log "ℹ️  INFO: $1"
}

log_warn() {
    log "⚠️  WARN: $1"
}

log_error() {
    log "❌ ERROR: $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$ERROR_LOG_FILE"
}

log_success() {
    log "✅ SUCCESS: $1"
}

log_debug() {
    # 仅在调试模式下输出（默认不输出，减少日志噪音）
    if [ "${DEBUG:-false}" = "true" ]; then
        log "🔍 DEBUG: $1"
    fi
}

#==============================================================================
# 配置验证
#==============================================================================

validate_config() {
    local errors=0

    # 验证 STRM_ROOT
    if [ -z "$STRM_ROOT" ]; then
        echo "❌ 错误: STRM_ROOT 未配置" >&2
        errors=$((errors + 1))
    elif [ ! -d "$STRM_ROOT" ]; then
        echo "❌ 错误: STRM_ROOT 目录不存在: $STRM_ROOT" >&2
        errors=$((errors + 1))
    fi

    # 验证 FFPROBE
    if [ -z "$FFPROBE" ]; then
        echo "❌ 错误: FFPROBE 未配置" >&2
        errors=$((errors + 1))
    elif [ ! -x "$FFPROBE" ]; then
        echo "❌ 错误: FFPROBE 不可执行或不存在: $FFPROBE" >&2
        echo "   提示: 运行 'which ffprobe' 查找 ffprobe 路径" >&2
        errors=$((errors + 1))
    fi

    # 验证超时配置
    if ! [[ "$FFPROBE_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$FFPROBE_TIMEOUT" -le 0 ]; then
        echo "❌ 错误: FFPROBE_TIMEOUT 必须是正整数: $FFPROBE_TIMEOUT" >&2
        errors=$((errors + 1))
    fi

    if ! [[ "$MAX_FILE_PROCESSING_TIME" =~ ^[0-9]+$ ]] || [ "$MAX_FILE_PROCESSING_TIME" -le 0 ]; then
        echo "❌ 错误: MAX_FILE_PROCESSING_TIME 必须是正整数: $MAX_FILE_PROCESSING_TIME" >&2
        errors=$((errors + 1))
    fi

    # 验证 MAX_FILE_PROCESSING_TIME 必须大于 FFPROBE_TIMEOUT
    if [ "$MAX_FILE_PROCESSING_TIME" -le "$FFPROBE_TIMEOUT" ]; then
        echo "❌ 错误: MAX_FILE_PROCESSING_TIME ($MAX_FILE_PROCESSING_TIME) 必须大于 FFPROBE_TIMEOUT ($FFPROBE_TIMEOUT)" >&2
        echo "   建议: MAX_FILE_PROCESSING_TIME 至少应该是 FFPROBE_TIMEOUT + 60 秒" >&2
        errors=$((errors + 1))
    fi

    if ! [[ "$DEBOUNCE_TIME" =~ ^[0-9]+$ ]] || [ "$DEBOUNCE_TIME" -le 0 ]; then
        echo "❌ 错误: DEBOUNCE_TIME 必须是正整数: $DEBOUNCE_TIME" >&2
        errors=$((errors + 1))
    fi

    # 检查日志文件目录是否存在
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    if [ ! -d "$log_dir" ]; then
        echo "⚠️  警告: 日志目录不存在: $log_dir，将尝试创建" >&2
        mkdir -p "$log_dir" || {
            echo "❌ 错误: 无法创建日志目录: $log_dir" >&2
            errors=$((errors + 1))
        }
    fi

    if [ $errors -gt 0 ]; then
        echo "" >&2
        echo "配置验证失败，共 $errors 个错误" >&2
        echo "请检查配置文件: $CONFIG_FILE" >&2
        return 1
    fi

    return 0
}

#==============================================================================
# 版本检查和自动更新
#==============================================================================

VERSION_CHECK_URL="https://raw.githubusercontent.com/aydomini/fantastic-probe/main/version.json"
VERSION_CHECK_CACHE="/var/cache/fantastic-probe-last-check"
VERSION_CHECK_INTERVAL=86400  # 24小时检查一次

check_for_updates() {
    # 如果禁用了自动更新检查，直接返回
    if [ "${AUTO_UPDATE_CHECK:-true}" != "true" ]; then
        return 0
    fi

    # 节流检查（避免频繁请求）
    if [ -f "$VERSION_CHECK_CACHE" ]; then
        local last_check
        last_check=$(cat "$VERSION_CHECK_CACHE" 2>/dev/null || echo "0")
        local now
        now=$(date +%s)
        if [ $((now - last_check)) -lt "$VERSION_CHECK_INTERVAL" ]; then
            return 0
        fi
    fi

    # 检查网络工具是否可用
    if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
        return 0
    fi

    # 获取最新版本信息（静默失败）
    local version_info
    if command -v curl &> /dev/null; then
        version_info=$(curl -fsSL "$VERSION_CHECK_URL" 2>/dev/null || echo "")
    elif command -v wget &> /dev/null; then
        version_info=$(wget -qO- "$VERSION_CHECK_URL" 2>/dev/null || echo "")
    fi

    if [ -z "$version_info" ]; then
        return 0
    fi

    # 解析版本信息
    if command -v jq &> /dev/null; then
        local latest_version
        latest_version=$(echo "$version_info" | jq -r '.version' 2>/dev/null || echo "")

        if [ -n "$latest_version" ] && [ "$latest_version" != "$VERSION" ]; then
            log_warn "检测到新版本: $latest_version（当前: $VERSION）"
            log_info "运行以下命令更新:"
            log_info "  sudo bash /usr/local/bin/fantastic-probe-update"
            log_info "  或: curl -fsSL https://raw.githubusercontent.com/aydomini/fantastic-probe/main/update.sh | sudo bash"

            # 如果启用了自动更新安装
            if [ "${AUTO_UPDATE_INSTALL:-false}" = "true" ]; then
                log_info "自动更新已启用，准备更新..."

                # 创建更新标记文件
                local update_marker="/tmp/fantastic-probe-update-marker"
                echo "$latest_version" > "$update_marker"

                # 检查自动更新助手是否存在
                local update_helper="/usr/local/bin/fantastic-probe-auto-update"
                if [ -x "$update_helper" ]; then
                    log_info "启动后台更新助手（将等待队列清空后执行更新）"
                    # 在后台启动更新助手（detached进程）
                    nohup "$update_helper" "$latest_version" >> "$LOG_FILE" 2>&1 &
                    disown
                    log_info "更新任务已提交，助手将在队列清空后自动执行更新"
                else
                    log_warn "自动更新助手不存在，请手动更新"
                    log_warn "运行: curl -fsSL https://raw.githubusercontent.com/aydomini/fantastic-probe/main/update.sh | sudo bash"
                fi
            fi
        fi
    fi

    # 记录检查时间
    mkdir -p "$(dirname "$VERSION_CHECK_CACHE")"
    date +%s > "$VERSION_CHECK_CACHE"
}

#==============================================================================
# 检查磁盘空间
#==============================================================================

check_disk_space() {
    local target_dir="$1"
    local min_free_mb=100

    local available_mb=$(df -BM "$target_dir" | awk 'NR==2 {print $4}' | sed 's/M//')

    if [ "$available_mb" -lt "$min_free_mb" ]; then
        log_error "磁盘空间不足: ${target_dir} (可用: ${available_mb}MB)"
        return 1
    fi

    return 0
}

#==============================================================================
# 检测 ISO 文件是否位于 FUSE 挂载点（v2.9.0 新增）
#==============================================================================

is_fuse_mount() {
    local iso_path="$1"

    # 方法1：路径匹配（快速，推荐）
    # 检测常见 FUSE 网盘挂载关键词
    if echo "$iso_path" | grep -qE "(pan_115|alist|clouddrive|rclone|strm_cloud|webdav|davfs)"; then
        log_debug "  检测到 FUSE 挂载路径（路径匹配）"
        return 0
    fi

    # 方法2：检查 /proc/mounts（精确但慢，仅在 Linux 上可用）
    if [ -f /proc/mounts ]; then
        local mount_point
        mount_point=$(df "$iso_path" 2>/dev/null | tail -1 | awk '{print $6}')
        if [ -n "$mount_point" ]; then
            if grep -q "^[^ ]* $mount_point fuse" /proc/mounts 2>/dev/null; then
                log_debug "  检测到 FUSE 挂载点（/proc/mounts 验证）"
                return 0
            fi
        fi
    fi

    return 1
}

#==============================================================================
# 智能检测 ISO 类型（v2.7.11 优化：完全移除 mount，改用智能判断）
#==============================================================================

detect_iso_type() {
    local iso_path="$1"
    local strm_file="${2:-}"  # 可选：.strm 文件路径，用于文件名判断

    # v2.7.11 终极优化：完全移除 mount 检测
    #
    # 为什么移除 mount？
    #   - fuse 网盘 mount ISO 需要 2-4 分钟（下载索引数据）
    #   - 批量处理时累计时间不可接受（100 个文件 = 6+ 小时）
    #   - mount 的唯一目的是判断 bluray 还是 dvd（不值得等待）
    #
    # 新方案：智能判断 + ffprobe 直接探测
    #   策略 1：文件名识别（90% 覆盖率，5 秒内完成）
    #     - "BluRay" → bluray
    #     - "DVD" → dvd
    #     - "BD" / "Blu-ray" → bluray
    #   策略 2：统计优先级（bluray 优先，90%+ 成功率）
    #     - 用户的 ISO 文件 90%+ 是蓝光
    #     - 先尝试 bluray:，失败后再尝试 dvd:
    #   策略 3：ffprobe 远快于 mount
    #     - mount：2-4 分钟（需要解析文件系统）
    #     - ffprobe：5-10 秒（只读取流头部）
    #
    # 性能对比：
    #   旧方案（mount）：单文件 4 分钟，100 文件 400 分钟
    #   新方案（智能判断）：单文件 5-10 秒，100 文件 8-16 分钟
    #   提升：25-30 倍速度！

    log_info "  智能检测 ISO 类型（无需 mount，速度提升 25 倍）..."

    local iso_type=""
    local filename=""

    # 策略 1：从文件名智能识别（最快，5 秒内）
    if [ -n "$strm_file" ]; then
        filename=$(basename "$strm_file" .iso.strm)
    else
        filename=$(basename "$iso_path" .iso)
    fi

    log_debug "  文件名: $filename"

    # 检查文件名中的关键词（不区分大小写）
    if echo "$filename" | grep -iE "(BluRay|Blu-ray|BD|BDMV)" >/dev/null 2>&1; then
        iso_type="bluray"
        log_info "  ✅ 文件名识别: 蓝光 ISO（包含 BluRay/BD 标识）"
    elif echo "$filename" | grep -iE "(DVD|VIDEO_TS)" >/dev/null 2>&1; then
        iso_type="dvd"
        log_info "  ✅ 文件名识别: DVD ISO（包含 DVD 标识）"
    else
        # 策略 2：无法从文件名判断，使用统计优先级（bluray 优先）
        log_info "  文件名无类型标识，使用统计优先级（90%+ 是蓝光）"
        iso_type="bluray"  # 默认蓝光（最常见）
        log_debug "  假设: 蓝光 ISO（如失败将自动尝试 DVD）"
    fi

    # 返回结果（由 extract_mediainfo 验证并自动回退）
    echo "$iso_type"
    return 0
}

#==============================================================================

# 提取媒体信息（v2.7.17：纯 ffprobe 方案）
#==============================================================================

extract_mediainfo_with_language_enhancement() {
    local iso_path="$1"
    local iso_type="$2"

    log_info "  使用 ffprobe 提取媒体信息..."

    local ffprobe_json
    ffprobe_json=$(extract_mediainfo "$iso_path" "$iso_type")

    if [ -z "$ffprobe_json" ] || ! echo "$ffprobe_json" | jq -e '.streams' >/dev/null 2>&1; then
        log_error "  ❌ ffprobe 提取失败"
        return 1
    fi

    log_info "  ✅ ffprobe 提取成功"

    echo "$ffprobe_json"
    return 0
}

#==============================================================================

# v2.7.11 已废弃：此函数太复杂，已被 extract_mediainfo_with_language_enhancement() 替代
extract_mediainfo_from_mpls() {
    log_warn "  extract_mediainfo_from_mpls() 已废弃，请使用新方案"
    return 1
}

#==============================================================================
# ffprobe 错误诊断（v2.9.0 新增）
#==============================================================================

diagnose_ffprobe_error() {
    local error_msg="$1"
    local iso_path="$2"
    local iso_type="${3:-unknown}"

    log_error ""
    log_error "========== 错误诊断 =========="

    # FUSE 未就绪错误（最常见）
    if echo "$error_msg" | grep -qE "bdmv_parse_header|udfread ERROR|nav_get_title_list"; then
        if is_fuse_mount "$iso_path"; then
            log_warn "诊断：FUSE 网盘文件数据未完全缓存"
            log_warn "说明：首次访问大文件需要时间下载到本地"
            log_warn ""
            log_warn "建议："
            log_warn "  1. 等待 3-5 分钟后重新处理（推荐）"
            log_warn "  2. 手动触发缓存："
            log_warn "     dd if=\"$iso_path\" of=/dev/null bs=1M count=100"
            log_warn "  3. 检查网络连接和网盘挂载状态"
        else
            log_error "诊断：文件可能损坏"
            log_error "说明：非 FUSE 文件出现此错误通常表示文件真正损坏"
            log_error ""
            log_error "建议："
            log_error "  1. 检查文件完整性（md5sum 或 sha256sum）"
            log_error "  2. 尝试重新下载或创建 ISO 文件"
        fi
    # 文件真正损坏或已删除
    elif echo "$error_msg" | grep -qE "Input/output error|No such file"; then
        log_error "诊断：文件损坏或已删除"
        log_error ""
        log_error "建议："
        log_error "  1. 检查文件是否存在：ls -lh \"$iso_path\""
        log_error "  2. 检查文件系统是否正常"
        log_error "  3. 尝试重新下载或恢复文件"
    # 协议不支持
    elif echo "$error_msg" | grep -qE "Protocol not found"; then
        log_error "诊断：ffprobe 不支持 ${iso_type} 协议"
        log_error ""
        log_error "建议："
        log_error "  1. 检查 ffprobe 版本（需要 >=4.4）"
        log_error "  2. 检查编译选项是否启用 bluray 支持："
        log_error "     ffprobe -protocols 2>&1 | grep bluray"
        log_error "  3. 重新编译 ffmpeg 或安装完整版本"
    # 超时错误
    elif echo "$error_msg" | grep -qE "Terminated|timeout"; then
        log_error "诊断：ffprobe 执行超时"
        log_error ""
        log_error "建议："
        log_error "  1. 增加超时时间（当前：${FFPROBE_TIMEOUT:-300}秒）"
        log_error "  2. 检查 FUSE 网盘是否响应缓慢"
        log_error "  3. 尝试在非高峰时段处理"
    # 未知错误
    else
        log_error "诊断：未知错误"
        log_error ""
        log_error "建议："
        log_error "  1. 查看完整错误信息（见上方日志）"
        log_error "  2. 手动运行以下命令排查："
        log_error "     ffprobe -i \"${iso_type}:${iso_path}\""
        log_error "  3. 检查系统日志：dmesg | tail -50"
    fi

    log_error "=============================="
    log_error ""
}

#==============================================================================
# 提取媒体信息（v2.7.11 优化：智能回退 + 重试机制）
#==============================================================================

extract_mediainfo() {
    local iso_path="$1"
    local iso_type="$2"

    # v2.7.12 优化：增强日志，捕获详细错误信息
    #   1. 显示 ffprobe 真实错误信息
    #   2. 显示每次尝试的耗时
    #   3. 保留 stderr 用于调试

    log_debug "  准备提取媒体信息（协议: ${iso_type:-未知}）..."

    # 如果 iso_type 为空（旧代码兼容），默认 bluray
    if [ -z "$iso_type" ]; then
        log_warn "  ISO 类型未知，使用默认值 bluray..."
        iso_type="bluray"
    fi

    # 尝试主协议（带重试）
    log_info "  尝试 ${iso_type} 协议..."
    local ffprobe_json=""
    local retry_count=0
    local max_retries=3

    # v2.9.0: 动态重试间隔（FUSE 文件 vs 本地文件）
    local retry_intervals=(30 20 10)  # 默认：递减间隔
    if is_fuse_mount "$iso_path"; then
        # FUSE 文件可能需要更长时间缓存数据
        retry_intervals=(60 30 15)
        log_debug "  FUSE 文件检测：使用长重试间隔 (60/30/15秒)"
    else
        log_debug "  本地文件检测：使用标准重试间隔 (30/20/10秒)"
    fi

    while [ $retry_count -lt $max_retries ]; do
        if [ $retry_count -gt 0 ]; then
            # v2.9.0: 动态重试间隔
            local wait_time=${retry_intervals[$((retry_count - 1))]}
            log_warn "  ${iso_type} 协议第 ${retry_count} 次失败，等待 ${wait_time} 秒后重试..."
            sleep $wait_time
        fi

        local start_time=$(date +%s)
        log_info "  执行 ffprobe（尝试 $((retry_count + 1))/$max_retries，超时 ${FFPROBE_TIMEOUT}秒）..."

        # 捕获 stderr 用于调试
        local ffprobe_stderr=$(mktemp)
        ffprobe_json=$(timeout "$FFPROBE_TIMEOUT" "$FFPROBE" -v error -print_format json \
            -show_format -show_streams -show_chapters \
            -protocol_whitelist "file,${iso_type}" \
            -i "${iso_type}:${iso_path}" 2>"$ffprobe_stderr")
        local ffprobe_exit=$?
        local duration=$(($(date +%s) - start_time))

        if [ $ffprobe_exit -eq 124 ]; then
            log_error "  ❌ ffprobe 超时（>${FFPROBE_TIMEOUT}秒）"
        elif [ $ffprobe_exit -ne 0 ]; then
            log_warn "  ffprobe 失败（退出码 $ffprobe_exit，耗时 ${duration}秒）"
            # 显示错误信息（方便调试）
            if [ -s "$ffprobe_stderr" ]; then
                log_warn "  错误信息（前5行）："
                head -5 "$ffprobe_stderr" | while IFS= read -r line; do
                    log_warn "    $line"
                done
            fi
        fi
        rm -f "$ffprobe_stderr"

        if [ -n "$ffprobe_json" ] && echo "$ffprobe_json" | jq -e '.streams' >/dev/null 2>&1; then
            log_info "  ✅ ${iso_type} 协议成功（尝试 $((retry_count + 1))/$max_retries，耗时 ${duration}秒）"
            echo "$ffprobe_json"
            return 0
        fi

        # 失败了，清空 ffprobe_json 继续重试
        ffprobe_json=""
        retry_count=$((retry_count + 1))
    done

    # 主协议失败，尝试备用协议
    local fallback_type=""
    if [ "$iso_type" = "bluray" ]; then
        fallback_type="dvd"
    else
        fallback_type="bluray"
    fi

    log_warn "  ${iso_type} 协议失败（已重试 $max_retries 次），尝试 ${fallback_type} 协议..."
    retry_count=0

    # v2.9.0: 备用协议也使用动态间隔（复用主协议的设置）
    # retry_intervals 已在主协议中根据 FUSE 检测设置
    local last_error_msg=""  # 保存最后一次错误信息用于诊断

    while [ $retry_count -lt $max_retries ]; do
        if [ $retry_count -gt 0 ]; then
            # v2.9.0: 动态重试间隔
            local wait_time=${retry_intervals[$((retry_count - 1))]}
            log_warn "  ${fallback_type} 协议第 ${retry_count} 次失败，等待 ${wait_time} 秒后重试..."
            sleep $wait_time
        fi

        local start_time=$(date +%s)
        log_info "  执行 ffprobe（备用协议，尝试 $((retry_count + 1))/$max_retries，超时 ${FFPROBE_TIMEOUT}秒）..."

        # 捕获 stderr 用于调试
        local ffprobe_stderr=$(mktemp)
        ffprobe_json=$(timeout "$FFPROBE_TIMEOUT" "$FFPROBE" -v error -print_format json \
            -show_format -show_streams -show_chapters \
            -protocol_whitelist "file,${fallback_type}" \
            -i "${fallback_type}:${iso_path}" 2>"$ffprobe_stderr")
        local ffprobe_exit=$?
        local duration=$(($(date +%s) - start_time))

        if [ $ffprobe_exit -eq 124 ]; then
            log_error "  ❌ ffprobe 超时（>${FFPROBE_TIMEOUT}秒）"
        elif [ $ffprobe_exit -ne 0 ]; then
            log_warn "  ffprobe 失败（退出码 $ffprobe_exit，耗时 ${duration}秒）"
            # 显示错误信息（方便调试）
            if [ -s "$ffprobe_stderr" ]; then
                log_warn "  错误信息（前5行）："
                head -5 "$ffprobe_stderr" | while IFS= read -r line; do
                    log_warn "    $line"
                done
                # v2.9.0: 保存最后一次错误信息用于诊断
                last_error_msg=$(cat "$ffprobe_stderr")
            fi
        fi
        rm -f "$ffprobe_stderr"

        if [ -n "$ffprobe_json" ] && echo "$ffprobe_json" | jq -e '.streams' >/dev/null 2>&1; then
            log_info "  ✅ ${fallback_type} 协议成功（备用协议，尝试 $((retry_count + 1))/$max_retries，耗时 ${duration}秒）"
            echo "$ffprobe_json"
            return 0
        fi

        # 失败了，清空 ffprobe_json 继续重试
        ffprobe_json=""
        retry_count=$((retry_count + 1))
    done

    # 两种协议都失败
    log_error "  ⚠️  bluray 和 dvd 协议均失败（各重试 $max_retries 次）"

    # v2.9.0: 调用错误诊断函数
    if [ -n "$last_error_msg" ]; then
        diagnose_ffprobe_error "$last_error_msg" "$iso_path" "$fallback_type"
    else
        log_error "  未能捕获详细错误信息，请查看上方日志"
        log_error "  建议: 尝试手动运行："
        log_error "        ffprobe -i \"bluray:${iso_path}\""
    fi

    return 1
}

#==============================================================================
# 转换为 Emby MediaSourceInfo 格式
#==============================================================================

convert_to_emby_format() {
    local ffprobe_json="$1"
    local strm_file="$2"
    local iso_file_size="${3:-0}"  # ISO 文件实际大小（字节）

    echo "$ffprobe_json" | jq -c --arg strm_file "$strm_file" --arg iso_size "$iso_file_size" '
    def lang_code:
        if . == "chi" or . == "zh" or . == "zho" then "Chinese"
        elif . == "eng" then "English"
        elif . == "jpn" or . == "ja" then "Japanese"
        elif . == "kor" or . == "ko" then "Korean"
        elif . == "spa" or . == "es" then "Spanish"
        elif . == "fre" or . == "fra" or . == "fr" then "French"
        elif . == "ger" or . == "deu" or . == "de" then "German"
        elif . == "ita" or . == "it" then "Italian"
        elif . == "por" or . == "pt" then "Portuguese"
        elif . == "rus" or . == "ru" then "Russian"
        elif . == "ara" or . == "ar" then "Arabic"
        elif . == "hin" or . == "hi" then "Hindi"
        elif . == "tha" or . == "th" then "Thai"
        elif . == "vie" or . == "vi" then "Vietnamese"
        else . end;

    def lang_detail:
        if .tags.title then
            if (.tags.title | test("(?i)simplified|chs")) then "Chinese Simplified"
            elif (.tags.title | test("(?i)traditional|cht")) then "Chinese Traditional"
            elif (.tags.title | test("(?i)cantonese|yue")) then "Chinese"
            else (.tags.language | lang_code)
            end
        elif .tags.language == "chi" or .tags.language == "zh" or .tags.language == "zho" then "Chinese"
        elif .tags.language then (.tags.language | lang_code)
        else null end;

    def codec_upper:
        if . == "hdmv_pgs_subtitle" then "PGSSUB"
        elif . == "subrip" then "SUBRIP"
        elif . == "ass" then "ASS"
        elif . == "webvtt" then "WEBVTT"
        elif . == "dvd_subtitle" then "DVDSUB"
        elif . == "mov_text" then "TX3G"
        else (. | ascii_upcase)
        end;

    def video_range:
        if .color_transfer == "smpte2084" then
            if .side_data_list and (.side_data_list[] | select(.side_data_type == "DOVI configuration record")) then
                "DolbyVision"
            else
                "HDR10"
            end
        elif .color_transfer == "arib-std-b67" then "HLG"
        else "SDR"
        end;

    [{
        "MediaSourceInfo": {
            "Chapters": [],
            "Protocol": "File",
            "Type": "Default",
            "Container": (.format.format_name // "unknown"),
            "Size": ($iso_size | tonumber),
            "Name": ($strm_file | split("/")[-1] | split(".iso.strm")[0]),
            "IsRemote": true,
            "HasMixedProtocols": false,
            "RunTimeTicks": ((.format.duration // "0" | tonumber) * 10000000 | floor),
            "SupportsTranscoding": true,
            "SupportsDirectStream": true,
            "SupportsDirectPlay": true,
            "IsInfiniteStream": false,
            "RequiresOpening": false,
            "RequiresClosing": false,
            "RequiresLooping": false,
            "SupportsProbing": true,
            "MediaStreams": [
                .streams[] |
                {
                    "Codec": (.codec_name | codec_upper),
                    "Language": (if .codec_type != "video" then (.tags.language // null) else null end),
                    "ColorTransfer": (if .codec_type == "video" then .color_transfer else null end),
                    "ColorPrimaries": (if .codec_type == "video" then .color_primaries else null end),
                    "ColorSpace": (if .codec_type == "video" then .color_space else null end),
                    "TimeBase": .time_base,
                    "Title": (if .codec_type != "video" then (.tags.title // null) else null end),
                    "VideoRange": (if .codec_type == "video" then video_range else null end),
                    "DisplayTitle": (
                        if .codec_type == "video" then
                            (if (.height // 0) >= 2160 then "4K "
                             elif (.height // 0) >= 1440 then "2K "
                             elif (.height // 0) >= 1080 then "1080p "
                             elif (.height // 0) >= 720 then "720p "
                             elif (.height // 0) > 0 then ((.height | tostring) + "p ")
                             else "" end) +
                            (if video_range == "DolbyVision" then "Dolby Vision "
                             elif video_range == "HDR10" then "HDR10 "
                             elif video_range == "HLG" then "HLG "
                             else "" end) +
                            (.codec_name | ascii_upcase)
                        elif .codec_type == "audio" then
                            ((.tags.language // "" | lang_code) + (if (.tags.language // "") != "" then " " else "" end)) +
                            (.codec_name | ascii_upcase) + " " +
                            (if .channels == 1 then "mono"
                             elif .channels == 2 then "stereo"
                             else ((.channels | tostring) + ".1")
                             end) +
                            (if .disposition.default == 1 then " (默认)" else "" end)
                        elif .codec_type == "subtitle" then
                            (lang_detail // (.tags.language // "" | lang_code)) +
                            (if .tags.title and (.tags.title | test("(?i)sdh|hearing")) then " (SDH " else " (" end) +
                            (if .disposition.default == 1 then "默认 " else "" end) +
                            (.codec_name | codec_upper) + ")"
                        else
                            (.codec_name | ascii_upcase)
                        end
                    ),
                    "DisplayLanguage": (
                        if .codec_type == "subtitle" then lang_detail
                        elif .tags.language then (.tags.language | lang_code)
                        else null end
                    ),
                    "IsInterlaced": (if .field_order then (.field_order != "progressive") else false end),
                    "BitRate": (.bit_rate // null | if . then (. | tonumber) else null end),
                    "BitDepth": (.bits_per_raw_sample // null | if . then (. | tonumber) else null end),
                    "RefFrames": (.refs // null | if . then (. | tonumber) else null end),
                    "IsDefault": (.disposition.default == 1),
                    "IsForced": (.disposition.forced == 1),
                    "IsHearingImpaired": (
                        if .codec_type == "subtitle" and .tags.title then
                            (.tags.title | test("(?i)sdh|hearing"))
                        else
                            (.disposition.hearing_impaired == 1)
                        end
                    ),
                    "Height": (.height // null | if . then (. | tonumber) else null end),
                    "Width": (.width // null | if . then (. | tonumber) else null end),
                    "AverageFrameRate": (
                        if .avg_frame_rate and .avg_frame_rate != "0/0" then
                            (.avg_frame_rate | split("/") | (.[0] | tonumber) / (.[1] | tonumber) | floor)
                        else null end
                    ),
                    "RealFrameRate": (
                        if .r_frame_rate and .r_frame_rate != "0/0" then
                            (.r_frame_rate | split("/") | (.[0] | tonumber) / (.[1] | tonumber) | floor)
                        else null end
                    ),
                    "Profile": .profile,
                    "Type": (.codec_type |
                        if . == "video" then "Video"
                        elif . == "audio" then "Audio"
                        elif . == "subtitle" then "Subtitle"
                        else . end
                    ),
                    "AspectRatio": .display_aspect_ratio,
                    "Index": .index,
                    "IsExternal": false,
                    "IsTextSubtitleStream": (
                        if .codec_type == "subtitle" then
                            (.codec_name | IN("subrip", "ass", "webvtt", "mov_text", "srt"))
                        else false end
                    ),
                    "SupportsExternalStream": (.codec_type == "subtitle"),
                    "Protocol": "File",
                    "PixelFormat": (if .codec_type == "video" then .pix_fmt else null end),
                    "Level": (.level // null | if . then (. | tonumber) else null end),
                    "IsAnamorphic": false,
                    "ExtendedVideoType": (
                        if .codec_type == "video" then
                            if video_range == "DolbyVision" then "DolbyVision"
                            else "None"
                            end
                        else "None"
                        end
                    ),
                    "ExtendedVideoSubType": (
                        if .codec_type == "video" and video_range == "DolbyVision" then
                            if .side_data_list then
                                (.side_data_list[] | select(.side_data_type == "DOVI configuration record") |
                                "DoviProfile" + (.dv_profile | tostring) + (.dv_level | tostring))
                            else "None"
                            end
                        else "None"
                        end
                    ),
                    "ExtendedVideoSubTypeDescription": (
                        if .codec_type == "video" and video_range == "DolbyVision" then
                            if .side_data_list then
                                (.side_data_list[] | select(.side_data_type == "DOVI configuration record") |
                                "Profile " + (.dv_profile | tostring) + "." + (.dv_level | tostring))
                            else "None"
                            end
                        else "None"
                        end
                    ),
                    "ChannelLayout": (if .codec_type == "audio" then .channel_layout else null end),
                    "Channels": (.channels // null | if . then (. | tonumber) else null end),
                    "SampleRate": (.sample_rate // null | if . then (. | tonumber) else null end),
                    "AttachmentSize": 0,
                    "SubtitleLocationType": (if .codec_type == "subtitle" then "InternalStream" else null end)
                } | with_entries(select(.value != null))
            ],
            "Formats": [],
            "Bitrate": (.format.bit_rate // null | if . then (. | tonumber) else null end),
            "RequiredHttpHeaders": {},
            "AddApiKeyToDirectStreamUrl": false,
            "ReadAtNativeFramerate": false
        },
        "Chapters": [
            ((.chapters // []) | to_entries[] |
            {
                "StartPositionTicks": (.value.start_time // "0" | tonumber * 10000000 | floor),
                "Name": (.value.tags.title // ("Chapter " + ((.key + 1) | tostring | if length == 1 then ("0" + .) else . end))),
                "MarkerType": "Chapter",
                "ChapterIndex": .key
            })
        ]
    }]
    ' 2>/dev/null
}

#==============================================================================
# 处理单个 ISO strm 文件
#==============================================================================

process_iso_strm() {
    local strm_file="$1"
    local strm_dir="$(dirname "$strm_file")"
    local strm_name="$(basename "$strm_file" .strm)"

    # 检查是否已有 JSON 文件
    local json_pattern="${strm_dir}/${strm_name}-mediainfo.json"
    if [ -f "$json_pattern" ]; then
        log_info "跳过（已有JSON）: $strm_file"
        return 0
    fi

    log_info "处理新文件: $strm_file"

    # 检查磁盘空间
    if ! check_disk_space "$strm_dir"; then
        log_error "磁盘空间不足，跳过: $strm_file"
        return 1
    fi

    # 读取 ISO 路径
    local iso_path
    iso_path=$(head -n 1 "$strm_file" | tr -d '\r\n')

    if [ -z "$iso_path" ]; then
        log_error "strm 文件为空: $strm_file"
        return 1
    fi

    # v2.8.0: 删除固定 60 秒等待，改用智能重试机制
    # 检查 ISO 文件
    # v2.9.0: FUSE 网盘文件智能等待机制
    # 问题：FUSE 挂载点配置了目录列表缓存（如 60 秒）
    # 现象：.iso.strm 和 .iso 同时移动到目录，但 FUSE 缓存未刷新，导致 .iso 文件暂时不可见
    # 解决：检测到 FUSE 文件不存在时，主动刷新缓存并等待
    if [ ! -f "$iso_path" ]; then
        # 判断是否为 FUSE 挂载点
        if is_fuse_mount "$iso_path"; then
            log_warn "ISO 文件暂时不可见（FUSE 目录缓存未刷新）"
            log_info "尝试刷新 FUSE 目录缓存..."

            # 主动触发缓存刷新：访问父目录
            local iso_dir=$(dirname "$iso_path")
            ls "$iso_dir" >/dev/null 2>&1 || true

            # 等待 FUSE 缓存刷新（根据 FUSE 配置调整，通常 60 秒）
            log_info "等待 60 秒让 FUSE 目录缓存刷新..."
            sleep 60

            # 重新检查
            if [ ! -f "$iso_path" ]; then
                log_error "等待后 ISO 文件仍不存在: $iso_path"
                log_error "可能原因："
                log_error "  1. 文件移动失败或路径错误"
                log_error "  2. FUSE 挂载异常（尝试重新挂载网盘）"
                log_error "  3. .strm 文件内容路径错误"
                return 1
            fi

            log_info "✅ FUSE 缓存已刷新，ISO 文件已可见"
        else
            # 本地文件不存在，直接失败
            log_error "ISO 文件不存在: $iso_path"
            return 1
        fi
    fi

    if [ ! -r "$iso_path" ]; then
        log_error "ISO 文件不可读: $iso_path"
        return 1
    fi

    log_info "  ISO 路径: $iso_path"

    # 智能检测 ISO 类型（v2.7.11：无需重试，总是成功）
    log_info "  智能检测 ISO 类型..."
    local iso_type
    iso_type=$(detect_iso_type "$iso_path" "$strm_file")

    log_info "  ISO 类型: ${iso_type^^}"

    # 提取媒体信息（v2.7.17：纯 ffprobe 方案）
    local ffprobe_output
    log_info "  开始提取媒体信息..."
    ffprobe_output=$(extract_mediainfo_with_language_enhancement "$iso_path" "$iso_type")

    if [ -z "$ffprobe_output" ] || ! echo "$ffprobe_output" | jq -e '.streams' >/dev/null 2>&1; then
        log_error "媒体信息提取失败: $iso_path"
        return 1
    fi

    # 获取 ISO 文件实际大小（使用 du 而非 stat，对 fuse 网盘更友好）
    # 注意：不能从 ffprobe 的 .format.size 获取，因为 bluray:/dvd: 协议返回的是播放列表大小，而非 ISO 文件大小
    local iso_size=$(du -b "$iso_path" 2>/dev/null | awk '{print $1}' || echo "0")

    if [ "$iso_size" != "0" ]; then
        local iso_size_mb=$(awk -v size="$iso_size" 'BEGIN {printf "%.2f", size/1024/1024}')
        local iso_size_gb=$(awk -v size="$iso_size" 'BEGIN {printf "%.2f", size/1024/1024/1024}')

        # 显示文件大小（仅用于日志）
        if awk -v gb="$iso_size_gb" 'BEGIN {exit (gb >= 1) ? 0 : 1}'; then
            log_info "  ISO 大小: ${iso_size_gb} GB (${iso_size} bytes)"
        else
            log_info "  ISO 大小: ${iso_size_mb} MB (${iso_size} bytes)"
        fi
    else
        log_warn "  ⚠️  无法获取 ISO 文件大小（可能是网盘挂载问题）"
        iso_size="0"
    fi

    # 转换为 Emby 格式（传递 ISO 文件大小）
    local emby_json
    emby_json=$(convert_to_emby_format "$ffprobe_output" "$strm_file" "$iso_size")

    if [ -z "$emby_json" ]; then
        log_error "JSON 转换失败: $strm_file"
        return 1
    fi

    # 验证 JSON 格式
    if ! echo "$emby_json" | jq -e . >/dev/null 2>&1; then
        log_error "生成的 JSON 格式无效: $strm_file"
        return 1
    fi

    # 原子写入
    local json_file="${strm_dir}/${strm_name}-mediainfo.json"
    local temp_json="${json_file}.tmp"

    if ! echo "$emby_json" > "$temp_json"; then
        log_error "写入临时文件失败: $temp_json"
        rm -f "$temp_json"
        return 1
    fi

    if ! mv "$temp_json" "$json_file"; then
        log_error "重命名文件失败: $temp_json -> $json_file"
        rm -f "$temp_json"
        return 1
    fi

    # 自适应文件权限：复制 STRM 文件的所有者和权限到 JSON 文件
    if [ -f "$strm_file" ]; then
        # 跨平台兼容的 stat 命令
        local strm_owner=""
        if stat -c '%U:%G' "$strm_file" >/dev/null 2>&1; then
            # Linux
            strm_owner=$(stat -c '%U:%G' "$strm_file")
        elif stat -f '%Su:%Sg' "$strm_file" >/dev/null 2>&1; then
            # macOS/BSD
            strm_owner=$(stat -f '%Su:%Sg' "$strm_file")
        fi

        # 如果成功获取所有者，则应用到 JSON 文件
        if [ -n "$strm_owner" ]; then
            chown "$strm_owner" "$json_file" 2>/dev/null || true
        fi

        # 设置 JSON 文件为可读可写（644）
        chmod 644 "$json_file" 2>/dev/null || true
    fi

    log_success "已生成: $json_file"

    # 显示简要信息
    local video_count=$(echo "$ffprobe_output" | jq '[.streams[] | select(.codec_type=="video")] | length')
    local audio_count=$(echo "$ffprobe_output" | jq '[.streams[] | select(.codec_type=="audio")] | length')
    local subtitle_count=$(echo "$ffprobe_output" | jq '[.streams[] | select(.codec_type=="subtitle")] | length')

    log_info "  视频流: $video_count, 音频流: $audio_count, 字幕流: $subtitle_count"

    return 0
}

#==============================================================================
# 防抖处理
#==============================================================================

should_process_file() {
    local file="$1"
    local current_time=$(date +%s)

    # 检查是否最近处理过
    if [ -n "${PROCESSED_FILES[$file]:-}" ]; then
        local last_time=${PROCESSED_FILES[$file]}
        local elapsed=$((current_time - last_time))

        if [ $elapsed -lt $DEBOUNCE_TIME ]; then
            return 1  # 跳过（防抖）
        fi
    fi

    # 记录处理时间
    PROCESSED_FILES[$file]=$current_time
    return 0
}

#==============================================================================
# 处理文件事件（添加到队列）
#==============================================================================

handle_file_event() {
    local event_file="$1"

    # 只处理 .iso.strm 文件
    if [[ ! "$event_file" =~ \.iso\.strm$ ]]; then
        return 0
    fi

    # 防抖检查
    if ! should_process_file "$event_file"; then
        log_info "跳过（防抖）: $event_file"
        return 0
    fi

    # 检查文件是否存在
    if [ ! -f "$event_file" ]; then
        log_warn "文件已不存在: $event_file"
        return 0
    fi

    # 添加到队列（非阻塞写入）
    echo "$event_file" >> "$QUEUE_FILE" 2>/dev/null || true
    log_info "已加入队列: $(basename "$event_file")"
}

#==============================================================================
# 启动时扫描现有文件
#==============================================================================

scan_existing_files() {
    log_info "=========================================="
    log_info "启动扫描：检查现有未处理文件"
    log_info "=========================================="

    local strm_files=()
    while IFS= read -r -d '' file; do
        strm_files+=("$file")
    done < <(find "$STRM_ROOT" -type f -name "*.iso.strm" -print0 2>/dev/null)

    local total=${#strm_files[@]}
    log_info "找到 $total 个 .iso.strm 文件"

    if [ $total -eq 0 ]; then
        log_info "没有需要处理的文件"
        return 0
    fi

    local processed=0
    local skipped=0
    local failed=0

    # 临时关闭 errexit，避免单个文件失败导致函数退出
    set +e

    for strm_file in "${strm_files[@]}"; do
        local strm_dir="$(dirname "$strm_file")"
        local strm_name="$(basename "$strm_file" .strm)"
        local json_file="${strm_dir}/${strm_name}-mediainfo.json"

        if [ -f "$json_file" ]; then
            ((skipped++)) || true
        else
            log_info "处理现有文件: $strm_file"
            if process_iso_strm "$strm_file" 2>&1; then
                ((processed++)) || true
            else
                ((failed++)) || true
                log_warn "处理失败，跳过: $strm_file"
            fi

            # v2.8.0: 任务间隔 - 避免频繁请求触发风控
            if [ $((processed + failed)) -lt $((total - skipped)) ]; then
                log_info "⏳ 任务间隔：等待 10 秒后处理下一个文件（避免频繁请求）"
                sleep 10
            fi
        fi
    done

    # 恢复 errexit
    set -e

    log_info "=========================================="
    log_info "启动扫描完成"
    log_info "总计: $total, 已处理: $processed, 已存在: $skipped, 失败: $failed"
    log_info "=========================================="
    echo "" >&2

    return 0
}

#==============================================================================
# 任务队列处理器（消费者）
#==============================================================================

queue_processor() {
    log_info "任务队列处理器已启动"

    # 从命名管道读取（自动 FIFO，读取即删除）
    while read -r strm_file; do
        log_info "已从队列读取: $(basename "$strm_file")"

        # 等待文件写入完成 + 避免触发网盘频率限制
        sleep 10

        # ==================== 预检查阶段 ====================

        # 检查1：文件是否存在
        if [ ! -f "$strm_file" ]; then
            log_warn "队列中的文件已不存在，跳过: $strm_file"
            continue
        fi

        # 检查2：是否已有 mediainfo JSON 文件
        local strm_dir="$(dirname "$strm_file")"
        local strm_name="$(basename "$strm_file" .strm)"
        local json_file="${strm_dir}/${strm_name}-mediainfo.json"

        if [ -f "$json_file" ]; then
            log_info "跳过（已有JSON）: $(basename "$strm_file")"
            continue
        fi

        # 检查3：文件是否可读
        if [ ! -r "$strm_file" ]; then
            log_error "文件不可读，跳过: $strm_file"
            continue
        fi

        # ==================== 任务执行阶段 ====================

        log_info "=========================================="
        log_info "从队列处理: $(basename "$strm_file")"
        log_info "=========================================="

        # 关键修复：错误隔离，防止单个文件失败导致 queue_processor 退出
        # 保持串行执行（一次只处理一个 ISO，避免网盘风控）
        set +e
        process_iso_strm "$strm_file"
        local exit_code=$?
        set -e

        if [ $exit_code -eq 0 ]; then
            log_success "✅ 文件处理成功"
        else
            log_error "❌ 文件处理失败（退出码: $exit_code）"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: 任务失败（退出码: $exit_code） - $strm_file" >> /var/log/fantastic_probe_errors.log
        fi

        echo "" >&2
        # 继续处理下一个任务（串行，避免网盘并发风控）
    done < "$QUEUE_FILE"  # 从命名管道持续读取
}

#==============================================================================
# 主函数 - 监控服务
#==============================================================================

main() {
    # 验证配置
    if ! validate_config; then
        exit 1
    fi

    # 检查更新（如果启用）
    check_for_updates

    log_info "=========================================="
    log_info "ISO 媒体信息提取服务启动（实时监控模式）"
    log_info "版本: $VERSION"
    log_info "=========================================="

    # 检查锁文件
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            log_error "服务已在运行（PID: $lock_pid）"
            exit 1
        else
            log_warn "发现过期锁文件，清除后继续"
            rm -f "$LOCK_FILE"
        fi
    fi

    echo $$ > "$LOCK_FILE"

    # 检查依赖
    if ! command -v inotifywait &> /dev/null; then
        log_error "未安装 inotify-tools，请执行: apt-get install inotify-tools"
        exit 1
    fi

    if [ ! -x "$FFPROBE" ]; then
        log_error "FFprobe 不存在或不可执行: $FFPROBE"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "未安装 jq，请执行: apt-get install jq"
        exit 1
    fi

    # 检查监控目录
    if [ ! -d "$STRM_ROOT" ]; then
        log_error "STRM 根目录不存在: $STRM_ROOT"
        exit 1
    fi

    log_info "监控目录: $STRM_ROOT"
    log_info "防抖时间: ${DEBOUNCE_TIME}秒"
    log_info "任务队列: 串行处理（防止资源耗尽）"

    # 启动时扫描现有文件（即使失败也继续）
    scan_existing_files || log_warn "启动扫描出现错误，但服务将继续运行"

    # 创建任务队列（命名管道 FIFO）
    log_info "初始化任务队列..."
    rm -f "$QUEUE_FILE"
    mkfifo "$QUEUE_FILE"
    log_info "任务队列已创建: $QUEUE_FILE"

    # 启动任务队列处理器（后台进程）
    queue_processor &
    QUEUE_PID=$!
    log_info "任务队列处理器已启动（PID: $QUEUE_PID）"

    # 开始监控
    log_info "=========================================="
    log_info "开始实时监控文件系统事件..."
    log_info "=========================================="

    # 监控循环（带自动重启机制）
    while true; do
        log_info "启动 inotifywait 监控..."

        # 临时禁用 errexit，防止监控循环因单个错误退出
        set +e

        # 使用 inotifywait 监控目录
        # -m: 持续监控模式
        # -r: 递归监控子目录
        # -e: 监控的事件类型（create, moved_to）
        # --format: 输出格式（只输出文件路径）
        inotifywait -m -r -e create -e moved_to --format '%w%f' "$STRM_ROOT" 2>/dev/null | \
        while read -r event_file; do
            # 确保单个文件事件处理失败不会中断监控
            handle_file_event "$event_file" || log_warn "处理文件事件失败: $event_file"
        done

        # 恢复 errexit
        set -e

        # 如果 inotifywait 意外退出，等待后重启
        log_error "⚠️  inotifywait 监控意外退出，5秒后自动重启..."
        sleep 5
    done
}

# 执行主函数
main "$@"
