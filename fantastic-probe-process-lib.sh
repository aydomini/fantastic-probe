#!/bin/bash

#==============================================================================
# ISO 文件处理核心库
# 功能：提供独立的文件处理函数，供 Cron 扫描器和实时监控器复用
# 作者：Fantastic-Probe Team
#==============================================================================

# 本文件仅包含函数定义，不直接执行
# 使用方式: source fantastic-probe-process-lib.sh

#==============================================================================
# 全局变量 - TMDB 速率限制
#==============================================================================

# 上次TMDB请求时间戳（毫秒）
LAST_TMDB_REQUEST_TIME=0

#==============================================================================
# TMDB 速率限制包装函数
#==============================================================================
# 功能：确保TMDB API调用之间有足够间隔，防止触发速率限制
# 参数：无
# 返回：无
#==============================================================================

tmdb_rate_limit() {
    local interval_ms="${TMDB_REQUEST_INTERVAL:-500}"

    # 获取当前时间戳（毫秒）
    local current_time=$(date +%s%3N 2>/dev/null || echo "0")

    # 如果date不支持%3N（毫秒），回退到秒级
    if [[ "$current_time" == "0" || "$current_time" == *"%3N"* ]]; then
        current_time=$(($(date +%s) * 1000))
    fi

    local elapsed=$((current_time - LAST_TMDB_REQUEST_TIME))

    if [ $elapsed -lt $interval_ms ] && [ $LAST_TMDB_REQUEST_TIME -gt 0 ]; then
        local sleep_time=$(awk "BEGIN {printf \"%.3f\", ($interval_ms - $elapsed) / 1000}")
        log_debug "  TMDB速率限制：等待 ${sleep_time}秒"
        sleep "$sleep_time"
    fi

    # 更新上次请求时间
    LAST_TMDB_REQUEST_TIME=$(date +%s%3N 2>/dev/null || echo "$(($(date +%s) * 1000))")
    if [[ "$LAST_TMDB_REQUEST_TIME" == *"%3N"* ]]; then
        LAST_TMDB_REQUEST_TIME=$(($(date +%s) * 1000))
    fi
}

#==============================================================================
# TMDB API 调用重试包装函数
#==============================================================================
# 功能：带重试机制的TMDB API调用，自动处理429错误和网络抖动
# 参数：
#   $1: API URL
#   $2: 错误提示信息
# 返回：
#   输出：API响应JSON
#   退出码：0=成功，1=失败
#==============================================================================

tmdb_api_call_with_retry() {
    local url="$1"
    local error_msg="${2:-TMDB API调用}"
    local timeout="${TMDB_TIMEOUT:-30}"
    local max_retries="${TMDB_RETRY_COUNT:-3}"
    local delay_429="${TMDB_RETRY_DELAY_429:-10}"
    local delay_other="${TMDB_RETRY_DELAY_OTHER:-3}"

    # 代理配置
    local proxy_enabled="${TMDB_PROXY_ENABLED:-false}"
    local proxy_url="${TMDB_PROXY_URL:-}"
    local proxy_timeout="${TMDB_PROXY_TIMEOUT:-60}"
    local proxy_fallback="${TMDB_PROXY_FALLBACK:-direct}"

    local retry_count=0

    while [ $retry_count -lt $max_retries ]; do
        if [ $retry_count -gt 0 ]; then
            log_debug "  ${error_msg}：第${retry_count}次重试"
        fi

        # 速率限制
        tmdb_rate_limit

        # API调用
        local response
        local http_code

        # 构建 curl 参数
        local curl_opts=(-s -w "%{http_code}")
        local current_timeout="$timeout"
        local use_proxy=false

        # 判断是否使用代理
        if [ "$proxy_enabled" = "true" ] && [ -n "$proxy_url" ]; then
            curl_opts+=(--proxy "$proxy_url")
            current_timeout="$proxy_timeout"
            use_proxy=true
            if [ $retry_count -eq 0 ]; then
                log_debug "  使用代理: $proxy_url"
            fi
        fi

        curl_opts+=(--max-time "$current_timeout")

        # 使用临时文件存储响应
        local temp_response=$(mktemp)
        http_code=$(curl "${curl_opts[@]}" -o "$temp_response" "$url" 2>&1)
        local curl_exit=$?
        response=$(cat "$temp_response" 2>/dev/null || echo "{}")
        rm -f "$temp_response"

        # 检查curl是否成功
        if [ $curl_exit -ne 0 ]; then
            log_warn "  ${error_msg}失败：网络错误（退出码: $curl_exit）"

            # 代理失败降级逻辑
            if [ "$use_proxy" = true ] && [ "$proxy_fallback" = "direct" ]; then
                log_warn "  代理失败，尝试直连..."

                # 使用临时文件存储响应
                temp_response=$(mktemp)
                http_code=$(curl -s -w "%{http_code}" -o "$temp_response" --max-time "$timeout" "$url" 2>&1)
                curl_exit=$?
                response=$(cat "$temp_response" 2>/dev/null || echo "{}")
                rm -f "$temp_response"

                if [ $curl_exit -eq 0 ]; then
                    log_info "  ✅ 直连成功"
                    # 继续处理响应
                else
                    log_warn "  直连也失败（退出码: $curl_exit）"
                    retry_count=$((retry_count + 1))
                    if [ $retry_count -lt $max_retries ]; then
                        log_debug "  等待${delay_other}秒后重试..."
                        sleep "$delay_other"
                    fi
                    continue
                fi
            else
                retry_count=$((retry_count + 1))
                if [ $retry_count -lt $max_retries ]; then
                    log_debug "  等待${delay_other}秒后重试..."
                    sleep "$delay_other"
                fi
                continue
            fi
        fi

        # 检查HTTP状态码
        if [[ "$http_code" == "200" ]]; then
            # 验证JSON有效性
            if echo "$response" | jq empty 2>/dev/null; then
                echo "$response"
                return 0
            else
                log_warn "  ${error_msg}失败：响应JSON无效"
                retry_count=$((retry_count + 1))
                if [ $retry_count -lt $max_retries ]; then
                    sleep "$delay_other"
                fi
                continue
            fi
        elif [[ "$http_code" == "429" ]]; then
            log_warn "  ${error_msg}失败：触发速率限制（429 Too Many Requests）"
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                log_warn "  等待${delay_429}秒后重试（速率限制恢复）..."
                sleep "$delay_429"
            fi
            continue
        else
            log_warn "  ${error_msg}失败：HTTP $http_code"
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                sleep "$delay_other"
            fi
            continue
        fi
    done

    # 所有重试失败
    log_error "  ${error_msg}失败（已重试${max_retries}次）"
    echo "{}"
    return 1
}

#==============================================================================
# 通知 Emby 刷新媒体库
#==============================================================================

notify_emby_refresh() {
    local json_file="$1"

    # 检查是否启用 Emby 集成
    if [ "${EMBY_ENABLED:-false}" != "true" ]; then
        log_debug "  Emby 集成未启用，跳过通知"
        return 0
    fi

    # 验证配置完整性
    if [ -z "${EMBY_URL:-}" ] || [ -z "${EMBY_API_KEY:-}" ]; then
        log_warn "  ⚠️  Emby 配置不完整（缺少 URL 或 API Key），跳过通知"
        return 0
    fi

    # 检查 curl 是否可用
    if ! command -v curl &> /dev/null; then
        log_warn "  ⚠️  curl 命令不可用，无法通知 Emby"
        return 0
    fi

    local timeout="${EMBY_NOTIFY_TIMEOUT:-5}"
    local emby_url="${EMBY_URL}"
    local api_key="${EMBY_API_KEY}"

    # 移除 URL 末尾的斜杠（如果有）
    emby_url="${emby_url%/}"

    log_info "  📡 通知 Emby 刷新媒体库..."
    log_debug "  Emby URL: $emby_url"

    # 异步调用 Emby API（不阻塞主流程）
    (
        local response
        local http_code

        # 调用 Emby Library Refresh API
        response=$(curl -s -w "\n%{http_code}" \
            --max-time "$timeout" \
            -X POST "${emby_url}/Library/Refresh" \
            -H "X-Emby-Token: ${api_key}" \
            -H "Content-Type: application/json" \
            -d '{}' 2>&1)

        # 提取 HTTP 状态码
        http_code=$(echo "$response" | tail -1)

        if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
            log_success "  ✅ Emby 媒体库刷新请求已发送（HTTP $http_code）"
        else
            log_warn "  ⚠️  Emby API 调用失败（HTTP $http_code）"
            log_debug "  响应: $(echo "$response" | head -n -1)"
        fi
    ) &

    # 不等待后台任务完成，立即返回
    return 0
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
# 检测 ISO 文件是否位于 FUSE 挂载点
#==============================================================================

is_fuse_mount() {
    local iso_path="$1"

    # 方法1：路径匹配（快速）
    if echo "$iso_path" | grep -qE "(pan_115|alist|clouddrive|rclone|strm_cloud|webdav|davfs)"; then
        log_debug "  检测到 FUSE 挂载路径（路径匹配）"
        return 0
    fi

    # 方法2：检查 /proc/mounts
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
# 智能检测 ISO 类型
#==============================================================================

detect_iso_type() {
    local iso_path="$1"
    local strm_file="${2:-}"

    log_info "  智能检测 ISO 类型（无需 mount）..."

    local iso_type=""
    local filename=""

    if [ -n "$strm_file" ]; then
        filename=$(basename "$strm_file" .iso.strm)
    else
        filename=$(basename "$iso_path" .iso)
    fi

    log_debug "  文件名: $filename"

    # 检查文件名中的关键词
    if echo "$filename" | grep -iE "(BluRay|Blu-ray|BD|BDMV)" >/dev/null 2>&1; then
        iso_type="bluray"
        log_info "  ✅ 文件名识别: 蓝光 ISO"
    elif echo "$filename" | grep -iE "(DVD|VIDEO_TS)" >/dev/null 2>&1; then
        iso_type="dvd"
        log_info "  ✅ 文件名识别: DVD ISO"
    else
        log_info "  文件名无类型标识，使用统计优先级（bluray 优先）"
        iso_type="bluray"
        log_debug "  假设: 蓝光 ISO"
    fi

    echo "$iso_type"
    return 0
}

#==============================================================================
# 提取媒体信息（ffprobe + 智能重试）
#==============================================================================

extract_mediainfo() {
    local iso_path="$1"
    local iso_type="$2"

    log_debug "  准备提取媒体信息（协议: ${iso_type:-未知}）..."

    if [ -z "$iso_type" ]; then
        log_warn "  ISO 类型未知，使用默认值 bluray..."
        iso_type="bluray"
    fi

    # 尝试主协议
    log_info "  尝试 ${iso_type} 协议..."
    local ffprobe_json=""
    local retry_count=0
    local max_retries=3

    # 动态重试间隔
    local retry_intervals=(30 20 10)
    if is_fuse_mount "$iso_path"; then
        retry_intervals=(60 30 15)
        log_debug "  FUSE 文件检测：使用长重试间隔 (60/30/15秒)"
    else
        log_debug "  本地文件检测：使用标准重试间隔 (30/20/10秒)"
    fi

    while [ $retry_count -lt $max_retries ]; do
        if [ $retry_count -gt 0 ]; then
            local wait_time=${retry_intervals[$((retry_count - 1))]}
            log_warn "  ${iso_type} 协议第 ${retry_count} 次失败，等待 ${wait_time} 秒后重试..."
            sleep $wait_time
        fi

        local start_time=$(date +%s)
        log_info "  执行 ffprobe（尝试 $((retry_count + 1))/$max_retries，超时 ${FFPROBE_TIMEOUT}秒）..."

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

        ffprobe_json=""
        retry_count=$((retry_count + 1))
    done

    # 尝试备用协议
    local fallback_type=""
    if [ "$iso_type" = "bluray" ]; then
        fallback_type="dvd"
    else
        fallback_type="bluray"
    fi

    log_warn "  ${iso_type} 协议失败（已重试 $max_retries 次），尝试 ${fallback_type} 协议..."
    retry_count=0

    while [ $retry_count -lt $max_retries ]; do
        if [ $retry_count -gt 0 ]; then
            local wait_time=${retry_intervals[$((retry_count - 1))]}
            log_warn "  ${fallback_type} 协议第 ${retry_count} 次失败，等待 ${wait_time} 秒后重试..."
            sleep $wait_time
        fi

        local start_time=$(date +%s)
        log_info "  执行 ffprobe（备用协议，尝试 $((retry_count + 1))/$max_retries，超时 ${FFPROBE_TIMEOUT}秒）..."

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
            if [ -s "$ffprobe_stderr" ]; then
                log_warn "  错误信息（前5行）："
                head -5 "$ffprobe_stderr" | while IFS= read -r line; do
                    log_warn "    $line"
                done
            fi
        fi
        rm -f "$ffprobe_stderr"

        if [ -n "$ffprobe_json" ] && echo "$ffprobe_json" | jq -e '.streams' >/dev/null 2>&1; then
            log_info "  ✅ ${fallback_type} 协议成功（备用协议，尝试 $((retry_count + 1))/$max_retries，耗时 ${duration}秒）"
            echo "$ffprobe_json"
            return 0
        fi

        ffprobe_json=""
        retry_count=$((retry_count + 1))
    done

    log_error "  ⚠️  bluray 和 dvd 协议均失败（各重试 $max_retries 次）"
    return 1
}

#==============================================================================
# 转换为 Emby MediaSourceInfo 格式
#==============================================================================

convert_to_emby_format() {
    local ffprobe_json="$1"
    local strm_file="$2"
    local iso_file_size="${3:-0}"

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
# 追加媒体信息到 NFO
#==============================================================================
# 功能：提取视频流信息并追加到现有 NFO 文件
# 参数：
#   $1: STRM 文件路径
# 返回：
#   退出码：0=成功，1=失败
#==============================================================================

append_media_info_to_nfo() {
    local strm_file="$1"
    local strm_dir="$(dirname "$strm_file")"
    local strm_name="$(basename "$strm_file" .strm)"

    # 获取 NFO 文件路径
    local nfo_file=$(get_nfo_path "$strm_file")

    if [ ! -f "$nfo_file" ]; then
        log_warn "  ⚠️  NFO 文件不存在，创建基础 NFO: $nfo_file"
        # 创建基础 NFO（只包含文件名）
        if is_tv_show "$strm_name"; then
            create_basic_episode_nfo "$strm_file"
        else
            create_basic_movie_nfo "$strm_file"
        fi
    fi

    log_info "  追加视频流信息到 NFO: $nfo_file"

    # 检测 STRM 类型
    local strm_type=$(detect_strm_type "$strm_file")

    # 提取媒体信息
    local media_info=""
    if [ "$strm_type" = "iso" ]; then
        # ISO.STRM 处理
        local iso_path=$(head -1 "$strm_file" | tr -d '\r\n')
        if [ -z "$iso_path" ] || [ ! -f "$iso_path" ]; then
            log_error "  ISO 文件不存在: $iso_path"
            return 1
        fi

        # 检测 ISO 类型并提取信息
        local iso_type=$(detect_iso_type_smart "$iso_path")
        media_info=$(extract_mediainfo "$iso_path" "$iso_type")
    else
        # 普通 STRM 处理
        local video_path=$(head -1 "$strm_file" | tr -d '\r\n')
        if [ -z "$video_path" ]; then
            log_error "  STRM 内容为空"
            return 1
        fi

        # 检测链接类型
        local link_type=$(detect_link_type "$video_path")

        # 如果是 Alist 链接，尝试获取 raw_url
        if [ "$link_type" = "alist" ] && [ -n "${ALIST_ADDR:-}" ]; then
            video_path=$(get_alist_raw_url "$video_path")
        fi

        # 提取媒体信息
        if [[ "$link_type" == "http" || "$link_type" == "alist" ]]; then
            # 远程 HTTP 分析
            media_info=$(analyze_http_media "$video_path")
        else
            # 本地文件分析
            media_info=$(analyze_local_media "$video_path")
        fi
    fi

    if [ -z "$media_info" ]; then
        log_error "  媒体信息提取失败"
        return 1
    fi

    # 生成 <fileinfo> XML 片段
    local fileinfo_xml=$(generate_fileinfo_xml "$media_info")

    if [ -z "$fileinfo_xml" ]; then
        log_error "  fileinfo XML 生成失败"
        return 1
    fi

    # 检查 NFO 中是否已有 <fileinfo>
    if grep -q "<fileinfo>" "$nfo_file"; then
        log_warn "  NFO 已包含 <fileinfo>，跳过追加"
        return 0
    fi

    # 追加到 NFO（在结束标签前）
    local temp_nfo="${nfo_file}.tmp"

    # 识别 NFO 类型并使用 awk 安全插入（避免 sed 对 XML 标签误解析）
    if grep -q "</movie>" "$nfo_file"; then
        awk -v insert="$fileinfo_xml" '/<\/movie>/ {print insert} {print}' "$nfo_file" > "$temp_nfo"
    elif grep -q "</tvshow>" "$nfo_file"; then
        awk -v insert="$fileinfo_xml" '/<\/tvshow>/ {print insert} {print}' "$nfo_file" > "$temp_nfo"
    elif grep -q "</episodedetails>" "$nfo_file"; then
        awk -v insert="$fileinfo_xml" '/<\/episodedetails>/ {print insert} {print}' "$nfo_file" > "$temp_nfo"
    else
        log_error "  无法识别 NFO 类型"
        return 1
    fi

    # 验证临时文件是否生成成功且不为空
    if [ ! -f "$temp_nfo" ]; then
        log_error "  临时文件生成失败"
        return 1
    fi

    local temp_size=$(stat -c%s "$temp_nfo" 2>/dev/null || stat -f%z "$temp_nfo" 2>/dev/null || echo "0")
    if [ "$temp_size" -lt 100 ]; then
        log_error "  临时文件异常（大小: ${temp_size} 字节），放弃覆盖原 NFO"
        rm -f "$temp_nfo"
        return 1
    fi

    # 原子替换
    mv "$temp_nfo" "$nfo_file"
    log_success "  ✅ 视频流信息已追加到 NFO"
    return 0
}

#------------------------------------------------------------------------------
# 创建基础电影 NFO
#------------------------------------------------------------------------------
create_basic_movie_nfo() {
    local strm_file="$1"
    local strm_name="$(basename "$strm_file" .strm)"
    local nfo_file=$(get_nfo_path "$strm_file")

    cat > "$nfo_file" << EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<movie>
    <title>$strm_name</title>
</movie>
EOF
    log_info "  创建基础 NFO: $nfo_file"
}

#------------------------------------------------------------------------------
# 创建基础剧集 NFO
#------------------------------------------------------------------------------
create_basic_episode_nfo() {
    local strm_file="$1"
    local strm_name="$(basename "$strm_file" .strm)"
    local nfo_file=$(get_nfo_path "$strm_file")

    # 提取季集号
    local season_num=0
    local episode_num=0
    if [[ "$strm_name" =~ S([0-9]{1,2})E([0-9]{1,2}) ]]; then
        season_num=$((10#${BASH_REMATCH[1]}))
        episode_num=$((10#${BASH_REMATCH[2]}))
    fi

    cat > "$nfo_file" << EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<episodedetails>
    <title>$strm_name</title>
    <season>$season_num</season>
    <episode>$episode_num</episode>
</episodedetails>
EOF
    log_info "  创建基础剧集 NFO: $nfo_file"
}

#------------------------------------------------------------------------------
# 生成 fileinfo XML 片段
#------------------------------------------------------------------------------
generate_fileinfo_xml() {
    local ffprobe_json="$1"

    local xml_output="    <fileinfo>
        <streamdetails>"

    # 提取视频流（只取第一个）
    local video_stream=$(echo "$ffprobe_json" | jq -r '.streams[] | select(.codec_type=="video") | @json' | head -1)

    if [ -n "$video_stream" ]; then
        local codec=$(echo "$video_stream" | jq -r '.codec_name // ""')
        local width=$(echo "$video_stream" | jq -r '.width // 0')
        local height=$(echo "$video_stream" | jq -r '.height // 0')
        local aspect_ratio=$(echo "$video_stream" | jq -r '.display_aspect_ratio // ""')
        local duration=$(echo "$ffprobe_json" | jq -r '.format.duration // 0' | awk '{print int($1)}')
        local duration_minutes=$(awk "BEGIN {print int($duration / 60)}")
        local framerate_raw=$(echo "$video_stream" | jq -r '.r_frame_rate // ""')
        local bitrate=$(echo "$video_stream" | jq -r '.bit_rate // ""')
        local field_order=$(echo "$video_stream" | jq -r '.field_order // ""')
        local language=$(echo "$video_stream" | jq -r '.tags.language // ""')
        local default=$(echo "$video_stream" | jq -r '.disposition.default // 0')
        local forced=$(echo "$video_stream" | jq -r '.disposition.forced // 0')

        # 计算宽高比（如果不存在）
        local aspect="$aspect_ratio"
        if [ -z "$aspect" ] || [ "$aspect" = "null" ]; then
            if [ "$width" != "0" ] && [ "$height" != "0" ]; then
                # 计算最简分数形式的宽高比
                local gcd=$(awk "BEGIN {
                    a=$width; b=$height;
                    while(b!=0) { t=b; b=a%b; a=t; }
                    print a;
                }")
                local w_ratio=$((width / gcd))
                local h_ratio=$((height / gcd))
                aspect="${w_ratio}:${h_ratio}"
            fi
        fi

        # 转换帧率为小数（如 "25/1" -> "25.0"）
        local framerate=""
        if [ -n "$framerate_raw" ] && [ "$framerate_raw" != "null" ]; then
            if [[ "$framerate_raw" =~ ^([0-9]+)/([0-9]+)$ ]]; then
                local num="${BASH_REMATCH[1]}"
                local den="${BASH_REMATCH[2]}"
                framerate=$(awk "BEGIN {printf \"%.5f\", $num/$den}")
            else
                framerate="$framerate_raw"
            fi
        fi

        # 判断扫描类型
        local scantype="progressive"
        if [ "$field_order" = "tt" ] || [ "$field_order" = "bb" ] || [ "$field_order" = "tb" ] || [ "$field_order" = "bt" ]; then
            scantype="interlaced"
        fi

        xml_output+="
            <video>"
        [ -n "$codec" ] && [ "$codec" != "null" ] && xml_output+="
                <codec>$codec</codec>"
        [ -n "$codec" ] && [ "$codec" != "null" ] && xml_output+="
                <micodec>$codec</micodec>"
        [ -n "$bitrate" ] && [ "$bitrate" != "null" ] && xml_output+="
                <bitrate>$bitrate</bitrate>"
        [ "$width" != "0" ] && xml_output+="
                <width>$width</width>"
        [ "$height" != "0" ] && xml_output+="
                <height>$height</height>"
        [ -n "$aspect" ] && xml_output+="
                <aspect>$aspect</aspect>"
        [ -n "$aspect" ] && xml_output+="
                <aspectratio>$aspect</aspectratio>"
        [ -n "$framerate" ] && xml_output+="
                <framerate>$framerate</framerate>"
        [ -n "$language" ] && [ "$language" != "null" ] && xml_output+="
                <language>$language</language>"
        xml_output+="
                <scantype>$scantype</scantype>"
        xml_output+="
                <default>$([ "$default" = "1" ] && echo "True" || echo "False")</default>"
        xml_output+="
                <forced>$([ "$forced" = "1" ] && echo "True" || echo "False")</forced>"
        [ "$duration_minutes" != "0" ] && xml_output+="
                <duration>$duration_minutes</duration>"
        [ "$duration" != "0" ] && xml_output+="
                <durationinseconds>$duration</durationinseconds>"
        xml_output+="
            </video>"
    fi

    # 提取音频流（所有音轨）
    local audio_count=$(echo "$ffprobe_json" | jq '[.streams[] | select(.codec_type=="audio")] | length')
    for ((i=0; i<audio_count; i++)); do
        local audio_stream=$(echo "$ffprobe_json" | jq -r ".streams[] | select(.codec_type==\"audio\") | @json" | sed -n "$((i+1))p")
        local codec=$(echo "$audio_stream" | jq -r '.codec_name // ""')
        local language=$(echo "$audio_stream" | jq -r '.tags.language // ""')
        local channels=$(echo "$audio_stream" | jq -r '.channels // 0')
        local bitrate=$(echo "$audio_stream" | jq -r '.bit_rate // ""')
        local sample_rate=$(echo "$audio_stream" | jq -r '.sample_rate // ""')
        local default=$(echo "$audio_stream" | jq -r '.disposition.default // 0')
        local forced=$(echo "$audio_stream" | jq -r '.disposition.forced // 0')

        xml_output+="
            <audio>"
        [ -n "$codec" ] && [ "$codec" != "null" ] && xml_output+="
                <codec>$codec</codec>"
        [ -n "$codec" ] && [ "$codec" != "null" ] && xml_output+="
                <micodec>$codec</micodec>"
        [ -n "$bitrate" ] && [ "$bitrate" != "null" ] && xml_output+="
                <bitrate>$bitrate</bitrate>"
        xml_output+="
                <scantype>progressive</scantype>"
        [ "$channels" != "0" ] && xml_output+="
                <channels>$channels</channels>"
        [ -n "$sample_rate" ] && [ "$sample_rate" != "null" ] && xml_output+="
                <samplingrate>$sample_rate</samplingrate>"
        [ -n "$language" ] && [ "$language" != "null" ] && xml_output+="
                <language>$language</language>"
        xml_output+="
                <default>$([ "$default" = "1" ] && echo "True" || echo "False")</default>"
        xml_output+="
                <forced>$([ "$forced" = "1" ] && echo "True" || echo "False")</forced>"
        xml_output+="
            </audio>"
    done

    # 提取字幕流（所有字幕）
    local subtitle_count=$(echo "$ffprobe_json" | jq '[.streams[] | select(.codec_type=="subtitle")] | length')
    for ((i=0; i<subtitle_count; i++)); do
        local subtitle_stream=$(echo "$ffprobe_json" | jq -r ".streams[] | select(.codec_type==\"subtitle\") | @json" | sed -n "$((i+1))p")
        local codec=$(echo "$subtitle_stream" | jq -r '.codec_name // ""')
        local language=$(echo "$subtitle_stream" | jq -r '.tags.language // ""')
        local default=$(echo "$subtitle_stream" | jq -r '.disposition.default // 0')
        local forced=$(echo "$subtitle_stream" | jq -r '.disposition.forced // 0')
        local width=$(echo "$subtitle_stream" | jq -r '.width // 0')
        local height=$(echo "$subtitle_stream" | jq -r '.height // 0')

        xml_output+="
            <subtitle>"
        [ -n "$codec" ] && [ "$codec" != "null" ] && xml_output+="
                <codec>$codec</codec>"
        [ -n "$codec" ] && [ "$codec" != "null" ] && xml_output+="
                <micodec>$codec</micodec>"
        [ -n "$language" ] && [ "$language" != "null" ] && xml_output+="
                <language>$language</language>"
        [ "$width" != "0" ] && xml_output+="
                <width>$width</width>"
        [ "$height" != "0" ] && xml_output+="
                <height>$height</height>"
        xml_output+="
                <scantype>progressive</scantype>"
        xml_output+="
                <default>$([ "$default" = "1" ] && echo "True" || echo "False")</default>"
        xml_output+="
                <forced>$([ "$forced" = "1" ] && echo "True" || echo "False")</forced>"
        xml_output+="
            </subtitle>"
    done

    xml_output+="
        </streamdetails>
    </fileinfo>"

    echo "$xml_output"
}

#==============================================================================
# 处理单个 ISO strm 文件（完整流程）
#==============================================================================

process_iso_strm_full() {
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

    # 检查 ISO 文件
    if [ ! -f "$iso_path" ]; then
        if is_fuse_mount "$iso_path"; then
            log_warn "ISO 文件暂时不可见（FUSE 目录缓存未刷新）"
            log_info "尝试刷新 FUSE 目录缓存..."

            local iso_dir=$(dirname "$iso_path")
            ls "$iso_dir" >/dev/null 2>&1 || true

            log_info "等待 60 秒让 FUSE 目录缓存刷新..."
            sleep 60

            if [ ! -f "$iso_path" ]; then
                log_error "等待后 ISO 文件仍不存在: $iso_path"
                return 1
            fi

            log_info "✅ FUSE 缓存已刷新，ISO 文件已可见"
        else
            log_error "ISO 文件不存在: $iso_path"
            return 1
        fi
    fi

    if [ ! -r "$iso_path" ]; then
        log_error "ISO 文件不可读: $iso_path"
        return 1
    fi

    log_info "  ISO 路径: $iso_path"

    # 智能检测 ISO 类型
    log_info "  智能检测 ISO 类型..."
    local iso_type
    iso_type=$(detect_iso_type "$iso_path" "$strm_file")

    log_info "  ISO 类型: ${iso_type^^}"

    # 提取媒体信息
    local ffprobe_output
    log_info "  开始提取媒体信息..."
    ffprobe_output=$(extract_mediainfo "$iso_path" "$iso_type")

    if [ -z "$ffprobe_output" ] || ! echo "$ffprobe_output" | jq -e '.streams' >/dev/null 2>&1; then
        log_error "媒体信息提取失败: $iso_path"
        return 1
    fi

    # 获取 ISO 文件实际大小
    local iso_size=$(du -b "$iso_path" 2>/dev/null | awk '{print $1}' || echo "0")

    if [ "$iso_size" != "0" ]; then
        local iso_size_mb=$(awk -v size="$iso_size" 'BEGIN {printf "%.2f", size/1024/1024}')
        local iso_size_gb=$(awk -v size="$iso_size" 'BEGIN {printf "%.2f", size/1024/1024/1024}')

        if awk -v gb="$iso_size_gb" 'BEGIN {exit (gb >= 1) ? 0 : 1}'; then
            log_info "  ISO 大小: ${iso_size_gb} GB (${iso_size} bytes)"
        else
            log_info "  ISO 大小: ${iso_size_mb} MB (${iso_size} bytes)"
        fi
    else
        log_warn "  ⚠️  无法获取 ISO 文件大小"
        iso_size="0"
    fi

    # 转换为 Emby 格式
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

    # 自适应文件权限
    if [ -f "$strm_file" ]; then
        local strm_owner=""
        if stat -c '%U:%G' "$strm_file" >/dev/null 2>&1; then
            strm_owner=$(stat -c '%U:%G' "$strm_file")
        elif stat -f '%Su:%Sg' "$strm_file" >/dev/null 2>&1; then
            strm_owner=$(stat -f '%Su:%Sg' "$strm_file")
        fi

        if [ -n "$strm_owner" ]; then
            chown "$strm_owner" "$json_file" 2>/dev/null || true
        fi

        chmod 644 "$json_file" 2>/dev/null || true
    fi

    log_success "已生成: $json_file"

    # 显示简要信息
    local video_count=$(echo "$ffprobe_output" | jq '[.streams[] | select(.codec_type=="video")] | length')
    local audio_count=$(echo "$ffprobe_output" | jq '[.streams[] | select(.codec_type=="audio")] | length')
    local subtitle_count=$(echo "$ffprobe_output" | jq '[.streams[] | select(.codec_type=="subtitle")] | length')

    log_info "  视频流: $video_count, 音频流: $audio_count, 字幕流: $subtitle_count"

    # Emby 通知已移至 Cron 扫描器步骤4（阶段2完成后统一通知）

    return 0
}

#==============================================================================
# STRM 文件解析和处理模块
#==============================================================================

#------------------------------------------------------------------------------
# 检测 STRM 文件类型
#------------------------------------------------------------------------------
# 参数：
#   $1: STRM 文件路径
# 返回：
#   输出：iso（ISO.STRM）或 video（普通 STRM）
#------------------------------------------------------------------------------

detect_strm_type() {
    local strm_file="$1"

    # 判断文件名是否为 .iso.strm
    if [[ "$strm_file" == *.iso.strm ]]; then
        echo "iso"
        return 0
    fi

    # 读取 STRM 内容判断
    local content=$(head -n 1 "$strm_file" 2>/dev/null | tr -d '\r\n')

    # 如果内容是 .iso 文件路径，也视为 ISO 类型
    if [[ "$content" == *.iso ]]; then
        echo "iso"
        return 0
    fi

    echo "video"
}

#------------------------------------------------------------------------------
# 判断是否为电视剧
#------------------------------------------------------------------------------
# 参数：
#   $1: STRM 文件名（不含路径）
# 返回：
#   退出码：0=是电视剧，1=不是
#------------------------------------------------------------------------------

is_tv_show() {
    local filename="$1"

    # 检测文件名是否包含 S##E## 格式
    if [[ "$filename" =~ S[0-9]{1,2}E[0-9]{1,2} ]]; then
        return 0
    fi

    return 1
}

#------------------------------------------------------------------------------
# 获取 NFO 文件路径
#------------------------------------------------------------------------------
# 功能：智能识别 STRM 对应的 NFO 文件路径
# 参数：
#   $1: STRM 文件路径
# 返回：
#   输出 NFO 文件路径
#------------------------------------------------------------------------------

get_nfo_path() {
    local strm_file="$1"
    local strm_dir="$(dirname "$strm_file")"
    local strm_name="$(basename "$strm_file" .strm)"

    # 判断是否为电视剧
    if is_tv_show "$strm_name"; then
        # 电视剧：返回单集 NFO 路径
        # 格式：S01E01.nfo 或 剧集名 S01E01.nfo
        echo "${strm_dir}/${strm_name}.nfo"
    else
        # 电影：返回 movie.nfo
        echo "${strm_dir}/${strm_name}.nfo"
    fi
}

#------------------------------------------------------------------------------
# 分析电视剧目录结构
#------------------------------------------------------------------------------
# 功能：提前检测电视剧目录结构，识别 series_dir、season_dir
# 参数：
#   $1: STRM 文件路径
# 返回：
#   成功：输出 "series_dir|season_dir|season_number"
#   失败：返回非0退出码
#------------------------------------------------------------------------------

analyze_tv_show_structure() {
    local strm_file="$1"
    local strm_dir="$(dirname "$strm_file")"
    local strm_name="$(basename "$strm_file" .strm)"

    log_debug "  分析电视剧目录结构..."

    # 从文件名提取季号
    local season_num=""
    if [[ "$strm_name" =~ S([0-9]{1,2})E([0-9]{1,2}) ]]; then
        season_num="${BASH_REMATCH[1]}"
        # 去除前导零
        season_num=$((10#$season_num))
        log_debug "    从文件名提取季号: $season_num"
    else
        log_error "    无法从文件名提取季集信息: $strm_name"
        return 1
    fi

    # 检查当前目录名是否包含 "Season"
    local current_dir_name="$(basename "$strm_dir")"
    local season_dir=""
    local series_dir=""

    # 匹配 "Season 01"、"Season 1"、"season 01" 等格式
    if [[ "$current_dir_name" =~ [Ss]eason[[:space:]]*0*$season_num$ ]] || \
       [[ "$current_dir_name" =~ [Ss]eason[[:space:]]*0*${season_num}[[:space:]]* ]]; then
        # 标准结构：Series/Season 01/Episode.strm
        season_dir="$strm_dir"
        series_dir="$(dirname "$season_dir")"
        log_debug "    ✅ 标准结构: Series/Season XX/"

    elif [[ "$current_dir_name" =~ ^S0*$season_num$ ]]; then
        # 变体结构：Series/S01/Episode.strm
        season_dir="$strm_dir"
        series_dir="$(dirname "$season_dir")"
        log_debug "    ✅ 变体结构: Series/SXX/"

    else
        # 扁平结构：Series/Episode.strm（所有季在同一目录）
        season_dir="$strm_dir"
        series_dir="$strm_dir"
        log_warn "    ⚠️  扁平结构（不推荐）: 所有集在剧集根目录"
        log_warn "    ⚠️  建议使用标准结构: Series/Season XX/Episode.strm"
    fi

    # 验证目录存在性
    if [[ ! -d "$series_dir" ]]; then
        log_error "    剧集根目录不存在: $series_dir"
        return 1
    fi

    if [[ ! -d "$season_dir" ]]; then
        log_error "    季文件夹不存在: $season_dir"
        return 1
    fi

    # 输出结果（使用 | 分隔）
    echo "${series_dir}|${season_dir}|${season_num}"

    log_debug "    ✅ 目录结构分析完成"
    log_debug "      剧集根目录: $series_dir"
    log_debug "      季文件夹: $season_dir"
    log_debug "      季号: $season_num"

    return 0
}

#------------------------------------------------------------------------------
# 规划单个 STRM 文件的处理任务
#------------------------------------------------------------------------------
# 功能：提前检测需要执行的任务，避免重复处理
# 参数：
#   $1: STRM 文件路径
# 返回：
#   输出：需要执行的任务列表（用空格分隔）
#   可能的值：stage1 stage2_nfo stage2_images
#------------------------------------------------------------------------------

plan_strm_tasks() {
    local strm_file="$1"
    local strm_dir="$(dirname "$strm_file")"
    local strm_name="$(basename "$strm_file" .strm)"

    local tasks=""

    log_debug "  规划处理任务..."

    # 获取 NFO 文件路径
    local nfo_file=$(get_nfo_path "$strm_file")

    # 检查 NFO 是否存在
    if [[ ! -f "$nfo_file" ]]; then
        # NFO 不存在，规划完整流程
        log_debug "    NFO 不存在: $nfo_file"

        # 先阶段1（生成 NFO 元数据）
        if [[ "${STAGE1_ENABLED:-true}" == "true" ]]; then
            tasks="$tasks stage1"
            log_debug "    需要执行: 阶段1（元数据刮削 - 生成 NFO）"
        fi

        # 再阶段2（追加视频流信息到 NFO）
        if [[ "${STAGE2_ENABLED:-true}" == "true" ]]; then
            tasks="$tasks stage2"
            log_debug "    需要执行: 阶段2（媒体信息提取 - 追加到 NFO）"
        fi
    else
        # NFO 存在，检查是否缺少视频流信息
        log_debug "    NFO 已存在: $nfo_file"

        if [[ "${STAGE2_ENABLED:-true}" == "true" ]]; then
            # 检查 NFO 中是否有 <fileinfo> 标签
            if ! grep -q "<fileinfo>" "$nfo_file" 2>/dev/null; then
                tasks="$tasks stage2"
                log_debug "    需要执行: 阶段2（追加视频流信息到现有 NFO）"
            else
                log_debug "    跳过阶段2（NFO 已包含视频流信息）"
            fi
        fi

        # 检查是否需要重新生成 NFO（阶段1）
        # 一般情况下，NFO 存在就不重新生成，除非用户手动删除
        log_debug "    跳过阶段1（NFO 已存在）"
    fi

    # 对于电视剧，检查是否需要生成 tvshow.nfo（总剧集 NFO）
    if is_tv_show "$strm_name"; then
        local structure_info=$(analyze_tv_show_structure "$strm_file" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            local series_dir=$(echo "$structure_info" | cut -d'|' -f1)
            local tvshow_nfo="${series_dir}/tvshow.nfo"

            if [[ ! -f "$tvshow_nfo" ]] && [[ "${STAGE1_ENABLED:-true}" == "true" ]]; then
                tasks="$tasks stage1_tvshow"
                log_debug "    需要执行: 阶段1（生成 tvshow.nfo）"
            fi
        fi
    fi

    # 输出任务列表（去除首尾空格）
    echo "$tasks" | xargs
}

#------------------------------------------------------------------------------
# 检测链接类型
#------------------------------------------------------------------------------
# 参数：
#   $1: STRM 内容（URL 或路径）
# 返回：
#   输出：http、alist、local 或 unknown
#------------------------------------------------------------------------------

detect_link_type() {
    local content="$1"

    # HTTP(S) 链接
    if [[ "$content" =~ ^http(s)?:// ]]; then
        # 进一步判断是否为 Alist 格式
        if [[ "$content" =~ /d/ && -n "${ALIST_ADDR:-}" ]]; then
            echo "alist"
        else
            echo "http"
        fi
        return 0
    fi

    # 本地绝对路径
    if [[ "$content" =~ ^/ ]]; then
        echo "local"
        return 0
    fi

    echo "unknown"
}

#------------------------------------------------------------------------------
# 解析 HTTP 链接（普通直链）
#------------------------------------------------------------------------------
# 参数：
#   $1: HTTP URL
# 返回：
#   输出：处理后的 URL
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

resolve_http_link() {
    local url="$1"

    log_debug "  链接类型: HTTP 直链"

    # 可选：验证链接有效性
    if [[ "${VALIDATE_HTTP_LINK:-false}" == "true" ]]; then
        log_debug "  验证链接有效性..."
        if ! curl -s -I --connect-timeout 5 --max-time 10 "$url" > /dev/null 2>&1; then
            log_warn "  ⚠️  HTTP 链接可能无效或超时（仍将尝试处理）"
        else
            log_debug "  ✅ 链接验证通过"
        fi
    fi

    echo "$url"
    return 0
}

#------------------------------------------------------------------------------
# 解析 Alist 链接（转换为 raw_url）
#------------------------------------------------------------------------------
# 参数：
#   $1: Alist 直链 URL
# 返回：
#   输出：Alist raw_url 或原链接
#   退出码：0=成功
#------------------------------------------------------------------------------

resolve_alist_link() {
    local dlink="$1"

    log_debug "  链接类型: Alist 直链"

    # 提取文件路径：http://alist:5244/d/path/to/file.mkv → /path/to/file.mkv
    local file_path=$(echo "$dlink" | sed -E 's|.*/d(/.*)|/\1|')

    log_info "  Alist 文件路径: $file_path"

    # 如果配置了 Alist API，尝试获取 raw_url
    if [[ -n "${ALIST_ADDR:-}" && -n "${ALIST_TOKEN:-}" ]]; then
        log_info "  调用 Alist API 获取 raw_url..."

        local raw_url=$(get_alist_raw_url "$file_path")

        if [[ -n "$raw_url" && "$raw_url" != "null" ]]; then
            log_success "  ✅ 获取到 Alist raw_url"
            log_debug "  raw_url: ${raw_url:0:80}..."
            echo "$raw_url"
            return 0
        else
            log_warn "  ⚠️  Alist API 调用失败，回退使用直链"
        fi
    else
        log_debug "  未配置 Alist API，直接使用原链接"
    fi

    # 回退：直接使用原链接
    echo "$dlink"
    return 0
}

#------------------------------------------------------------------------------
# 调用 Alist API 获取 raw_url
#------------------------------------------------------------------------------
# 参数：
#   $1: 文件路径（如 /Movies/movie.mkv）
# 返回：
#   输出：raw_url 或空
#------------------------------------------------------------------------------

get_alist_raw_url() {
    local file_path="$1"
    local timeout="${ALIST_TIMEOUT:-30}"

    # 调用 Alist /api/fs/get
    local response=$(curl -s -X POST \
        --max-time "$timeout" \
        -H "Authorization: ${ALIST_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"path\":\"$file_path\",\"password\":\"\"}" \
        "${ALIST_ADDR}/api/fs/get" 2>&1)

    if [[ $? -ne 0 ]]; then
        log_error "  Alist API 请求失败: $response"
        return 1
    fi

    # 提取 raw_url
    local raw_url=$(echo "$response" | jq -r '.data.raw_url // empty' 2>/dev/null)

    if [[ -z "$raw_url" ]]; then
        log_error "  Alist API 返回空结果"
        log_debug "  响应: $response"
        return 1
    fi

    echo "$raw_url"
    return 0
}

#------------------------------------------------------------------------------
# 解析本地路径
#------------------------------------------------------------------------------
# 参数：
#   $1: 本地文件路径
# 返回：
#   输出：验证后的路径
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

resolve_local_path() {
    local path="$1"

    log_debug "  链接类型: 本地路径"
    log_info "  本地文件: $path"

    # 验证路径是否存在
    if [[ ! -f "$path" ]]; then
        # 检查是否为 FUSE 挂载点
        if is_fuse_mount "$path"; then
            log_warn "  文件暂时不可见（FUSE 目录缓存未刷新）"
            log_info "  尝试刷新 FUSE 目录缓存..."

            local dir=$(dirname "$path")
            ls "$dir" >/dev/null 2>&1 || true

            log_info "  等待 30 秒让 FUSE 目录缓存刷新..."
            sleep 30

            if [[ ! -f "$path" ]]; then
                log_error "  等待后文件仍不存在: $path"
                return 1
            fi

            log_success "  ✅ FUSE 缓存已刷新，文件已可见"
        else
            log_error "  本地文件不存在: $path"
            return 1
        fi
    fi

    # 验证文件可读性
    if [[ ! -r "$path" ]]; then
        log_error "  本地文件不可读: $path"
        return 1
    fi

    echo "$path"
    return 0
}

#------------------------------------------------------------------------------
# 解析 STRM 内容（主函数）
#------------------------------------------------------------------------------
# 参数：
#   $1: STRM 文件路径
# 返回：
#   输出：解析后的 URL 或路径
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

parse_strm_content() {
    local strm_file="$1"

    log_info "  解析 STRM 内容..."

    # 读取第一行
    local content=$(head -n 1 "$strm_file" 2>/dev/null | tr -d '\r\n')

    if [[ -z "$content" ]]; then
        log_error "  STRM 文件为空"
        return 1
    fi

    log_debug "  STRM 内容: ${content:0:100}..."

    # 识别链接类型
    local link_type=$(detect_link_type "$content")

    log_info "  识别的链接类型: $link_type"

    # 根据类型处理
    case "$link_type" in
        "http")
            resolve_http_link "$content"
            ;;
        "alist")
            resolve_alist_link "$content"
            ;;
        "local")
            resolve_local_path "$content"
            ;;
        *)
            log_error "  无法识别的 STRM 格式: $content"
            return 1
            ;;
    esac
}

#------------------------------------------------------------------------------
# 分析远程媒体（HTTP 链接）
#------------------------------------------------------------------------------
# 参数：
#   $1: HTTP URL
# 返回：
#   输出：FFprobe JSON 输出
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

analyze_http_media() {
    local url="$1"
    local timeout="${FFPROBE_TIMEOUT:-300}"
    local analyzeduration="${FFPROBE_HTTP_ANALYZEDURATION:-1M}"
    local probesize="${FFPROBE_HTTP_PROBESIZE:-5M}"
    local max_retries="${FFPROBE_RETRY_COUNT:-3}"
    local retry_intervals="${FFPROBE_RETRY_INTERVALS:-10 5 3}"

    log_info "  开始远程分析 HTTP 媒体..."
    log_debug "  URL: ${url:0:80}..."
    log_debug "  参数: analyzeduration=$analyzeduration, probesize=$probesize, timeout=${timeout}s"

    # 将重试间隔转换为数组
    local intervals_array=($retry_intervals)
    local retry_count=0

    while [ $retry_count -lt $max_retries ]; do
        if [ $retry_count -gt 0 ]; then
            local wait_index=$((retry_count - 1))
            local wait_time=${intervals_array[$wait_index]:-3}
            log_warn "  HTTP分析第${retry_count}次失败，等待${wait_time}秒后重试..."
            sleep "$wait_time"
        fi

        log_info "  执行FFprobe（尝试$((retry_count + 1))/$max_retries）..."

        # FFprobe 远程分析（优化参数，模仿 Emby 行为）
        local ffprobe_output
        ffprobe_output=$(timeout "$timeout" \
            "$FFPROBE" -v quiet -print_format json \
            -show_streams -show_format \
            -analyzeduration "$analyzeduration" \
            -probesize "$probesize" \
            -fflags nobuffer \
            -fflags +fastseek \
            "$url" 2>&1)

        local exit_code=$?

        if [[ $exit_code -eq 124 ]]; then
            log_error "  FFprobe 远程分析超时（${timeout}s）"
            retry_count=$((retry_count + 1))
            continue
        elif [[ $exit_code -ne 0 ]]; then
            log_error "  FFprobe 远程分析失败（退出码: $exit_code）"
            log_debug "  错误输出: ${ffprobe_output:0:200}"
            retry_count=$((retry_count + 1))
            continue
        fi

        # 验证输出有效性
        if [[ -z "$ffprobe_output" ]] || ! echo "$ffprobe_output" | jq -e '.streams' >/dev/null 2>&1; then
            log_error "  FFprobe 输出无效或为空"
            retry_count=$((retry_count + 1))
            continue
        fi

        log_success "  ✅ 远程媒体分析完成（尝试$((retry_count + 1))/$max_retries）"

        echo "$ffprobe_output"
        return 0
    done

    # 所有重试失败
    log_error "  HTTP媒体分析失败（已重试${max_retries}次）"
    return 1
}

#------------------------------------------------------------------------------
# 分析本地媒体
#------------------------------------------------------------------------------
# 参数：
#   $1: 本地文件路径
# 返回：
#   输出：FFprobe JSON 输出
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

analyze_local_media() {
    local path="$1"
    local timeout="${FFPROBE_TIMEOUT:-300}"
    local analyzeduration="${FFPROBE_LOCAL_ANALYZEDURATION:-10M}"
    local probesize="${FFPROBE_LOCAL_PROBESIZE:-20M}"
    local max_retries="${FFPROBE_RETRY_COUNT:-3}"
    local retry_intervals="${FFPROBE_RETRY_INTERVALS:-10 5 3}"

    log_info "  开始分析本地媒体..."
    log_debug "  路径: $path"
    log_debug "  参数: analyzeduration=$analyzeduration, probesize=$probesize"

    # 将重试间隔转换为数组
    local intervals_array=($retry_intervals)
    local retry_count=0

    while [ $retry_count -lt $max_retries ]; do
        if [ $retry_count -gt 0 ]; then
            local wait_index=$((retry_count - 1))
            local wait_time=${intervals_array[$wait_index]:-3}
            log_warn "  本地分析第${retry_count}次失败，等待${wait_time}秒后重试..."
            sleep "$wait_time"
        fi

        log_info "  执行FFprobe（尝试$((retry_count + 1))/$max_retries）..."

        # FFprobe 本地分析（优化参数）
        local ffprobe_output
        ffprobe_output=$(timeout "$timeout" \
            "$FFPROBE" -v quiet -print_format json \
            -show_streams -show_format \
            -analyzeduration "$analyzeduration" \
            -probesize "$probesize" \
            "$path" 2>&1)

        local exit_code=$?

        if [[ $exit_code -eq 124 ]]; then
            log_error "  FFprobe 分析超时（${timeout}s）"
            retry_count=$((retry_count + 1))
            continue
        elif [[ $exit_code -ne 0 ]]; then
            log_error "  FFprobe 分析失败（退出码: $exit_code）"
            log_debug "  错误输出: ${ffprobe_output:0:200}"
            retry_count=$((retry_count + 1))
            continue
        fi

        # 验证输出有效性
        if [[ -z "$ffprobe_output" ]] || ! echo "$ffprobe_output" | jq -e '.streams' >/dev/null 2>&1; then
            log_error "  FFprobe 输出无效或为空"
            retry_count=$((retry_count + 1))
            continue
        fi

        log_success "  ✅ 本地媒体分析完成（尝试$((retry_count + 1))/$max_retries）"

        echo "$ffprobe_output"
        return 0
    done

    # 所有重试失败
    log_error "  本地媒体分析失败（已重试${max_retries}次）"
    return 1
}

#------------------------------------------------------------------------------
# 处理普通 STRM 文件（完整流程）
#------------------------------------------------------------------------------
# 参数：
#   $1: STRM 文件路径
# 返回：
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

process_video_strm_full() {
    local strm_file="$1"
    local strm_dir="$(dirname "$strm_file")"
    local strm_name="$(basename "$strm_file" .strm)"

    # 检查是否已有 JSON 文件
    local json_pattern="${strm_dir}/${strm_name}-mediainfo.json"
    if [[ -f "$json_pattern" ]]; then
        log_info "跳过（已有JSON）: $strm_file"
        return 0
    fi

    log_info "处理新文件: $strm_file"

    # 检查磁盘空间
    if ! check_disk_space "$strm_dir"; then
        log_error "磁盘空间不足，跳过: $strm_file"
        return 1
    fi

    # 1. 解析 STRM 内容
    local media_source
    media_source=$(parse_strm_content "$strm_file")

    if [[ $? -ne 0 ]]; then
        log_error "STRM 解析失败"
        return 1
    fi

    log_success "  ✅ STRM 解析完成: ${media_source:0:80}..."

    # 2. 提取媒体信息
    local ffprobe_output
    local link_type=$(detect_link_type "$(head -n 1 "$strm_file" | tr -d '\r\n')")

    if [[ "$link_type" == "http" || "$link_type" == "alist" ]]; then
        # 远程 HTTP 分析
        ffprobe_output=$(analyze_http_media "$media_source")
    else
        # 本地文件分析
        ffprobe_output=$(analyze_local_media "$media_source")
    fi

    if [[ $? -ne 0 ]]; then
        log_error "媒体信息提取失败"
        return 1
    fi

    # 3. 获取文件大小
    local media_size="0"

    if [[ "$link_type" == "local" ]]; then
        media_size=$(du -b "$media_source" 2>/dev/null | awk '{print $1}' || echo "0")

        if [[ "$media_size" != "0" ]]; then
            local size_mb=$(awk -v size="$media_size" 'BEGIN {printf "%.2f", size/1024/1024}')
            local size_gb=$(awk -v size="$media_size" 'BEGIN {printf "%.2f", size/1024/1024/1024}')

            if awk -v gb="$size_gb" 'BEGIN {exit (gb >= 1) ? 0 : 1}'; then
                log_info "  文件大小: ${size_gb} GB"
            else
                log_info "  文件大小: ${size_mb} MB"
            fi
        fi
    else
        log_debug "  远程文件大小无法获取，使用 format.size（如果有）"
        media_size=$(echo "$ffprobe_output" | jq -r '.format.size // "0"')
    fi

    # 4. 转换为 Emby 格式
    local emby_json
    emby_json=$(convert_to_emby_format "$ffprobe_output" "$strm_file" "$media_size")

    if [[ -z "$emby_json" ]]; then
        log_error "JSON 转换失败"
        return 1
    fi

    # 验证 JSON 格式
    if ! echo "$emby_json" | jq empty 2>/dev/null; then
        log_error "生成的 JSON 格式无效"
        return 1
    fi

    # 5. 原子写入 JSON 文件
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

    # 6. 自适应文件权限
    if [[ -f "$strm_file" ]]; then
        local strm_owner=""
        if stat -c '%U:%G' "$strm_file" >/dev/null 2>&1; then
            strm_owner=$(stat -c '%U:%G' "$strm_file")
        elif stat -f '%Su:%Sg' "$strm_file" >/dev/null 2>&1; then
            strm_owner=$(stat -f '%Su:%Sg' "$strm_file")
        fi

        if [[ -n "$strm_owner" ]]; then
            chown "$strm_owner" "$json_file" 2>/dev/null || true
        fi

        chmod 644 "$json_file" 2>/dev/null || true
    fi

    log_success "已生成: $json_file"

    # 显示简要信息
    local video_count=$(echo "$ffprobe_output" | jq '[.streams[] | select(.codec_type=="video")] | length')
    local audio_count=$(echo "$ffprobe_output" | jq '[.streams[] | select(.codec_type=="audio")] | length')
    local subtitle_count=$(echo "$ffprobe_output" | jq '[.streams[] | select(.codec_type=="subtitle")] | length')

    log_info "  视频流: $video_count, 音频流: $audio_count, 字幕流: $subtitle_count"

    # Emby 通知已移至 Cron 扫描器步骤4（阶段2完成后统一通知）

    return 0
}

#==============================================================================
# TMDB 元数据刮削模块
#==============================================================================

#------------------------------------------------------------------------------
# 从文件名提取元数据信息
#------------------------------------------------------------------------------
# 参数：
#   $1: 文件名（不含扩展名）
# 返回：
#   输出：title|year|tmdbid|season|episode（用 | 分隔）
#------------------------------------------------------------------------------

extract_metadata_from_filename() {
    local filename="$1"

    log_debug "  解析文件名: $filename"

    # 提取 tmdbid（从完整路径提取，支持多种格式）
    local tmdbid=""
    # 格式1: [tmdbid-12345] 或 [tmdb-12345]
    if [[ "$filename" =~ \[tmdb(id)?-([0-9]+)\] ]]; then
        tmdbid="${BASH_REMATCH[2]}"
        log_info "  ✅ 从文件名提取 TMDB ID: $tmdbid (格式1: 方括号)"
    # 格式2: {tmdbid=12345} 或 {tmdb-12345} 或 {tmdb=12345}
    elif [[ "$filename" =~ \{tmdb(id)?[=-]([0-9]+)\} ]]; then
        tmdbid="${BASH_REMATCH[2]}"
        log_info "  ✅ 从文件名提取 TMDB ID: $tmdbid (格式2: 花括号)"
    fi

    # 提取年份（从完整路径提取，支持多种格式）
    local year=""
    if [[ "$filename" =~ \(([0-9]{4})\) ]] || [[ "$filename" =~ \.([0-9]{4})\. ]]; then
        year="${BASH_REMATCH[1]}"
        log_debug "  提取年份: $year"
    fi

    # 移除路径部分，只保留文件名（处理完整路径的情况）
    filename=$(basename "$filename")

    # 提取季集信息（如果是剧集）
    local season=""
    local episode=""
    if [[ "$filename" =~ [Ss]([0-9]{1,2})[Ee]([0-9]{1,2}) ]]; then
        season="${BASH_REMATCH[1]}"
        episode="${BASH_REMATCH[2]}"
        log_debug "  提取季集: S${season}E${episode}"
    fi

    # 提取标题（移除年份、质量标签、tmdbid等）
    local title="$filename"

    # 移除 tmdbid（支持多种格式）
    title=$(echo "$title" | sed -E 's/\s*-?\s*\[tmdb(id)?-[0-9]+\]//g')
    title=$(echo "$title" | sed -E 's/\s*\{tmdb(id)?[=-][0-9]+\}//g')

    # 移除年份（只匹配括号或点号包围的年份，避免误匹配1080p等）
    # 支持格式：(2023) [2023] .2023.
    title=$(echo "$title" | sed -E 's/\s*\([0-9]{4}\)//g; s/\s*\[[0-9]{4}\]//g; s/\.[0-9]{4}\./ /g')

    # 移除季集信息
    title=$(echo "$title" | sed -E 's/[Ss][0-9]{1,2}[Ee][0-9]{1,2}.*//g')

    # 移除质量标签及之后的所有内容
    # 补充完整的质量标签列表：分辨率、格式、编码、HDR、音频、来源等
    title=$(echo "$title" | sed -E 's/[-._[:space:]]+(1080p|720p|2160p|4K|8K|UHD|HDR|HDR10|HDR10\+|DoVi|DV|HLG|BluRay|Blu-ray|BDRip|DVDRip|BRRip|REMUX|WEB-DL|WEBDL|WEB|HDTV|x264|x265|H\.264|H\.265|HEVC|AVC|10bit|8bit|DD|DDP|DD\+|TrueHD|Atmos|DTS|DTS-HD|LPCM|AAC|AC3|FLAC|SDR|iTunes|Amazon|AMZN|Netflix|NF|Hulu|Disney|AppleTV|HBO|MAX).*//i')

    # 替换分隔符为空格
    title=$(echo "$title" | sed -E 's/[\.\-_]+/ /g')

    # 去除首尾空格
    title=$(echo "$title" | xargs)

    # 移除末尾可能残留的分隔符
    title=$(echo "$title" | sed -E 's/[-._[:space:]]+$//')

    # 分离中文名和英文名
    local cn_title=""
    local en_title=""

    # 检查是否包含非ASCII字符（可能是中文）
    if echo "$title" | LC_ALL=C grep -q '[^[:print:][:space:]]'; then
        # 包含非ASCII字符，尝试分离中英文
        # 使用空格分割，假设中文在前，英文在后
        local parts=($title)

        # 遍历每个部分，分类到中文或英文
        for part in "${parts[@]}"; do
            if echo "$part" | LC_ALL=C grep -q '[^[:print:][:space:]]'; then
                # 包含非ASCII字符，归类为中文
                cn_title="$cn_title $part"
            else
                # 纯ASCII字符，归类为英文
                en_title="$en_title $part"
            fi
        done

        # 去除首尾空格
        cn_title=$(echo "$cn_title" | xargs)
        en_title=$(echo "$en_title" | xargs)
    else
        # 纯ASCII标题
        en_title="$title"
    fi

    log_info "  解析结果: 中文标题='$cn_title', 英文标题='$en_title', 年份='$year', TMDB ID='$tmdbid', 季='$season', 集='$episode'"

    # 输出格式：cn_title|en_title|year|tmdbid|season|episode
    echo "${cn_title}|${en_title}|${year}|${tmdbid}|${season}|${episode}"
    return 0
}

#------------------------------------------------------------------------------
# URL 编码函数（支持 UTF-8 中文字符）
#------------------------------------------------------------------------------

urlencode() {
    local string="$1"

    # 优先使用 jq（最可靠，项目已依赖 jq）
    if command -v jq &> /dev/null; then
        echo -n "$string" | jq -sRr @uri
        return 0
    fi

    # 回退方案1：使用 Python
    if command -v python3 &> /dev/null; then
        python3 -c "import urllib.parse; print(urllib.parse.quote('$string'))"
        return 0
    fi

    # 回退方案2：使用 xxd（纯命令行工具）
    if command -v xxd &> /dev/null; then
        echo -n "$string" | xxd -plain | sed 's/\(..\)/%\1/g'
        return 0
    fi

    # 回退方案3：使用 Perl
    if command -v perl &> /dev/null; then
        perl -MURI::Escape -e 'print uri_escape($ARGV[0]);' "$string"
        return 0
    fi

    # 最后兜底：原始方法（仅支持 ASCII）
    log_warn "  ⚠️  未找到 UTF-8 编码工具，中文搜索可能失败"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * ) printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "$encoded"
}

#------------------------------------------------------------------------------
# 查询 TMDB 电影元数据
#------------------------------------------------------------------------------
# 参数：
#   $1: 标题
#   $2: 年份（可选）
#   $3: TMDB ID（可选，如果有则直接查询）
# 返回：
#   输出：TMDB JSON 数据
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

query_tmdb_movie() {
    local cn_title="$1"
    local en_title="$2"
    local year="${3:-}"
    local tmdb_id="${4:-}"
    local api_key="${TMDB_API_KEY}"
    local language="${TMDB_LANGUAGE:-zh-CN}"

    if [[ -z "$api_key" ]]; then
        log_error "  TMDB API Key 未配置"
        return 1
    fi

    local tmdb_data=""

    # 如果有 tmdb_id，直接查询（最高优先级）
    if [[ -n "$tmdb_id" ]]; then
        log_info "  使用 TMDB ID 查询: $tmdb_id"

        tmdb_data=$(tmdb_api_call_with_retry \
            "https://api.themoviedb.org/3/movie/${tmdb_id}?api_key=${api_key}&language=${language}" \
            "通过ID查询电影")

        if [[ "$tmdb_data" != "{}" ]] && echo "$tmdb_data" | jq -e '.id' >/dev/null 2>&1; then
            log_success "  ✅ TMDB 查询成功（ID: $tmdb_id）"
            echo "$tmdb_data"
            return 0
        else
            log_warn "  ⚠️  TMDB ID 查询失败，尝试搜索"
            tmdb_data=""
        fi
    fi

    # 多轮搜索策略
    local search_titles=()

    # 优先使用中文名（如果有）
    if [[ -n "$cn_title" ]]; then
        search_titles+=("$cn_title")
        log_debug "  添加搜索词: $cn_title（中文）"
    fi

    # 其次使用英文名（如果有且与中文名不同）
    if [[ -n "$en_title" && "$en_title" != "$cn_title" ]]; then
        search_titles+=("$en_title")
        log_debug "  添加搜索词: $en_title（英文）"
    fi

    # 如果都没有，返回失败
    if [[ ${#search_titles[@]} -eq 0 ]]; then
        log_error "  没有可用的搜索标题"
        return 1
    fi

    # 依次尝试每个搜索词
    for search_title in "${search_titles[@]}"; do
        log_info "  搜索 TMDB 电影: $search_title${year:+ ($year)}"

        local encoded_title=$(urlencode "$search_title")
        local search_url="https://api.themoviedb.org/3/search/movie?api_key=${api_key}&language=${language}&query=${encoded_title}"

        if [[ -n "$year" ]]; then
            search_url="${search_url}&year=${year}"
        fi

        local search_result
        search_result=$(tmdb_api_call_with_retry "$search_url" "搜索电影: $search_title")

        if [[ "$search_result" == "{}" ]]; then
            log_warn "  ⚠️  TMDB API 请求失败: $search_title"
            continue
        fi

        # 提取第一个结果
        tmdb_data=$(echo "$search_result" | jq -r '.results[0] // empty')

        if [[ -n "$tmdb_data" && "$tmdb_data" != "null" ]]; then
            local found_title=$(echo "$tmdb_data" | jq -r '.title')
            local found_id=$(echo "$tmdb_data" | jq -r '.id')

            log_success "  ✅ TMDB 匹配成功: $found_title (ID: $found_id, 搜索词: $search_title)"
            echo "$tmdb_data"
            return 0
        else
            log_warn "  ⚠️  TMDB 未找到匹配结果: $search_title"
        fi
    done

    # 所有搜索词都失败
    log_error "  TMDB 搜索失败，所有搜索词均未匹配"

    # 提供解决建议
    if [[ -n "$cn_title" && -z "$en_title" ]]; then
        log_warn "  💡 提示：TMDB 搜索引擎不支持中文检索"
        log_warn "  💡 建议解决方案："
        log_warn "     1. 在文件名中添加 [tmdbid-XXXXX] 标识"
        log_warn "     2. 在文件名中添加英文标题"
        log_warn "     3. 使用 tinyMediaManager 等工具批量刮削"
        if [[ -n "$year" ]]; then
            log_warn "  💡 手动查找："
            log_warn "     访问 https://www.themoviedb.org/search?query=$(urlencode "$cn_title")"
        fi
    fi

    return 1
}

#------------------------------------------------------------------------------
# 查询 TMDB 电视剧元数据
#------------------------------------------------------------------------------
# 参数：
#   $1: 中文标题
#   $2: 英文标题
#   $3: 年份（可选）
#   $4: TMDB ID（可选）
#   $5: 季号（可选）
#   $6: 集号（可选）
# 返回：
#   输出：TMDB JSON 数据
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

query_tmdb_tv() {
    local cn_title="$1"
    local en_title="$2"
    local year="${3:-}"
    local tmdb_id="${4:-}"
    local season="${5:-}"
    local episode="${6:-}"
    local api_key="${TMDB_API_KEY}"
    local language="${TMDB_LANGUAGE:-zh-CN}"

    if [[ -z "$api_key" ]]; then
        log_error "  TMDB API Key 未配置"
        return 1
    fi

    local show_data=""

    # 如果有 tmdb_id，直接查询（最高优先级）
    if [[ -n "$tmdb_id" ]]; then
        log_info "  使用 TMDB ID 查询电视剧: $tmdb_id"

        show_data=$(tmdb_api_call_with_retry \
            "https://api.themoviedb.org/3/tv/${tmdb_id}?api_key=${api_key}&language=${language}" \
            "通过ID查询电视剧")

        if [[ "$show_data" != "{}" ]] && echo "$show_data" | jq -e '.id' >/dev/null 2>&1; then
            log_success "  ✅ TMDB 查询成功（ID: $tmdb_id）"
        else
            log_warn "  ⚠️  TMDB ID 查询失败，尝试搜索"
            show_data=""
        fi
    fi

    # 如果没有数据，尝试多轮搜索
    if [[ -z "$show_data" ]]; then
            # 多轮搜索策略
            local search_titles=()

        # 优先使用中文名（如果有）
        if [[ -n "$cn_title" ]]; then
            search_titles+=("$cn_title")
            log_debug "  添加搜索词: $cn_title（中文）"
        fi

        # 其次使用英文名（如果有且与中文名不同）
        if [[ -n "$en_title" && "$en_title" != "$cn_title" ]]; then
            search_titles+=("$en_title")
            log_debug "  添加搜索词: $en_title（英文）"
        fi

        # 如果都没有，返回失败
        if [[ ${#search_titles[@]} -eq 0 ]]; then
            log_error "  没有可用的搜索标题"
            return 1
        fi

        # 依次尝试每个搜索词
        for search_title in "${search_titles[@]}"; do
            log_info "  搜索 TMDB 电视剧: $search_title${year:+ ($year)}"

            local encoded_title=$(urlencode "$search_title")
            local search_url="https://api.themoviedb.org/3/search/tv?api_key=${api_key}&language=${language}&query=${encoded_title}"

            if [[ -n "$year" ]]; then
                search_url="${search_url}&first_air_date_year=${year}"
            fi

            local search_result
            search_result=$(tmdb_api_call_with_retry "$search_url" "搜索电视剧: $search_title")

            if [[ "$search_result" == "{}" ]]; then
                log_warn "  ⚠️  TMDB API 请求失败: $search_title"
                continue
            fi

            show_data=$(echo "$search_result" | jq -r '.results[0] // empty')

            if [[ -n "$show_data" && "$show_data" != "null" ]]; then
                local found_title=$(echo "$show_data" | jq -r '.name')
                local found_id=$(echo "$show_data" | jq -r '.id')

                log_success "  ✅ TMDB 匹配成功: $found_title (ID: $found_id, 搜索词: $search_title)"
                break
            else
                log_warn "  ⚠️  TMDB 未找到匹配结果: $search_title"
                show_data=""
            fi
        done

        # 所有搜索词都失败
        if [[ -z "$show_data" ]]; then
            log_error "  TMDB 搜索失败，所有搜索词均未匹配"
            return 1
        fi
    fi

    # 如果需要查询季和剧集详情
    if [[ -n "$season" && -n "$episode" ]]; then
        local show_id=$(echo "$show_data" | jq -r '.id')
        log_info "  查询季和剧集详情: S${season}E${episode}"

        # 查询季信息（用于生成 Season.nfo）
        local season_data
        season_data=$(tmdb_api_call_with_retry \
            "https://api.themoviedb.org/3/tv/${show_id}/season/${season}?api_key=${api_key}&language=${language}" \
            "查询季信息")

        if [[ "$season_data" == "{}" ]] || ! echo "$season_data" | jq -e '.id' >/dev/null 2>&1; then
            log_warn "  ⚠️  季信息获取失败"
            season_data="{}"
        else
            log_success "  ✅ 季信息获取成功 (Season $season)"
        fi

        # 查询单集详情（用于生成单集 NFO）
        local episode_data
        episode_data=$(tmdb_api_call_with_retry \
            "https://api.themoviedb.org/3/tv/${show_id}/season/${season}/episode/${episode}?api_key=${api_key}&language=${language}" \
            "查询单集详情")

        if [[ "$episode_data" != "{}" ]] && echo "$episode_data" | jq -e '.id' >/dev/null 2>&1; then
            log_success "  ✅ 单集详情获取成功 (S${season}E${episode})"
            # 合并剧集、季和单集信息
            echo "$show_data" | jq --argjson season "$season_data" --argjson ep "$episode_data" '. + {season: $season, episode: $ep}'
            return 0
        else
            log_warn "  ⚠️  单集详情获取失败，仅返回剧集和季信息"
            # 只合并剧集和季信息
            echo "$show_data" | jq --argjson season "$season_data" '. + {season: $season}'
            return 0
        fi
    fi

    echo "$show_data"
    return 0
}

#------------------------------------------------------------------------------
# 获取电影演职人员信息
#------------------------------------------------------------------------------
# 参数：
#   $1: TMDB ID
# 返回：
#   输出：credits JSON 数据
#------------------------------------------------------------------------------

get_movie_credits() {
    local tmdb_id="$1"
    local api_key="${TMDB_API_KEY}"
    local language="${TMDB_LANGUAGE:-zh-CN}"

    log_debug "  调用 TMDB API 获取演职人员信息..."

    local credits_url="https://api.themoviedb.org/3/movie/${tmdb_id}/credits?api_key=${api_key}&language=${language}"

    # 使用重试包装函数
    local response
    response=$(tmdb_api_call_with_retry "$credits_url" "获取演职人员信息")

    echo "$response"
    return 0
}

#------------------------------------------------------------------------------
# 获取电视剧演职人员信息
#------------------------------------------------------------------------------
# 参数：
#   $1: TMDB ID
# 返回：
#   输出：credits JSON 数据
#------------------------------------------------------------------------------

get_tv_credits() {
    local tmdb_id="$1"
    local api_key="${TMDB_API_KEY}"
    local language="${TMDB_LANGUAGE:-zh-CN}"

    log_debug "  调用 TMDB API 获取剧集演职人员信息..."

    local credits_url="https://api.themoviedb.org/3/tv/${tmdb_id}/credits?api_key=${api_key}&language=${language}"

    local response
    response=$(tmdb_api_call_with_retry "$credits_url" "获取剧集演职人员信息")

    echo "$response"
    return 0
}

#------------------------------------------------------------------------------
# 获取电影预告片信息
#------------------------------------------------------------------------------
# 参数：
#   $1: TMDB ID
# 返回：
#   输出：videos JSON 数据（YouTube预告片链接）
#------------------------------------------------------------------------------

get_movie_videos() {
    local tmdb_id="$1"
    local api_key="${TMDB_API_KEY}"

    log_debug "  调用 TMDB API 获取电影预告片..."

    # 先尝试中文预告片
    local videos_url="https://api.themoviedb.org/3/movie/${tmdb_id}/videos?api_key=${api_key}&language=zh-CN"
    local response
    response=$(tmdb_api_call_with_retry "$videos_url" "获取电影预告片（中文）")

    # 检查中文预告片数量
    local count=$(echo "$response" | jq '.results | length' 2>/dev/null || echo "0")

    # 如果中文预告片为空，回退到英文
    if [[ "$count" == "0" ]]; then
        log_debug "  中文预告片为空，尝试英文预告片..."
        videos_url="https://api.themoviedb.org/3/movie/${tmdb_id}/videos?api_key=${api_key}&language=en-US"
        response=$(tmdb_api_call_with_retry "$videos_url" "获取电影预告片（英文）")
    fi

    # 筛选YouTube预告片，生成链接列表（最多3个）
    echo "$response" | jq -r '.results[] | select(.site == "YouTube") | select(.type == "Trailer" or .type == "Teaser") | "https://www.youtube.com/watch?v=" + .key' | head -3
    return 0
}

#------------------------------------------------------------------------------
# 获取电视剧预告片信息
#------------------------------------------------------------------------------
# 参数：
#   $1: TMDB ID
# 返回：
#   输出：videos JSON 数据（YouTube预告片链接）
#------------------------------------------------------------------------------

get_tv_videos() {
    local tmdb_id="$1"
    local api_key="${TMDB_API_KEY}"

    log_debug "  调用 TMDB API 获取剧集预告片..."

    # 先尝试中文预告片
    local videos_url="https://api.themoviedb.org/3/tv/${tmdb_id}/videos?api_key=${api_key}&language=zh-CN"
    local response
    response=$(tmdb_api_call_with_retry "$videos_url" "获取剧集预告片（中文）")

    # 检查中文预告片数量
    local count=$(echo "$response" | jq '.results | length' 2>/dev/null || echo "0")

    # 如果中文预告片为空，回退到英文
    if [[ "$count" == "0" ]]; then
        log_debug "  中文预告片为空，尝试英文预告片..."
        videos_url="https://api.themoviedb.org/3/tv/${tmdb_id}/videos?api_key=${api_key}&language=en-US"
        response=$(tmdb_api_call_with_retry "$videos_url" "获取剧集预告片（英文）")
    fi

    # 筛选YouTube预告片，生成链接列表（最多3个）
    echo "$response" | jq -r '.results[] | select(.site == "YouTube") | select(.type == "Trailer" or .type == "Teaser") | "https://www.youtube.com/watch?v=" + .key' | head -3
    return 0
}

#------------------------------------------------------------------------------
# 获取电影外部 ID（IMDB、TVDB 等）
#------------------------------------------------------------------------------
# 参数：
#   $1: TMDB ID
# 返回：
#   输出：external_ids JSON 数据
#------------------------------------------------------------------------------

get_movie_external_ids() {
    local tmdb_id="$1"
    local api_key="${TMDB_API_KEY}"

    log_debug "  查询电影外部 ID: TMDB ID $tmdb_id"

    local external_ids_url="https://api.themoviedb.org/3/movie/${tmdb_id}/external_ids?api_key=${api_key}"

    local result=$(tmdb_api_call_with_retry "$external_ids_url" "查询电影外部ID")

    if [[ "$result" != "{}" ]]; then
        echo "$result"
        return 0
    else
        log_warn "  ⚠️  电影外部 ID 查询失败"
        echo "{}"
        return 1
    fi
}

#------------------------------------------------------------------------------
# 获取电视剧外部 ID（IMDB、TVDB 等）
#------------------------------------------------------------------------------
# 参数：
#   $1: TMDB ID
# 返回：
#   输出：external_ids JSON 数据
#------------------------------------------------------------------------------

get_tv_external_ids() {
    local tmdb_id="$1"
    local api_key="${TMDB_API_KEY}"

    log_debug "  查询剧集外部 ID: TMDB ID $tmdb_id"

    local external_ids_url="https://api.themoviedb.org/3/tv/${tmdb_id}/external_ids?api_key=${api_key}"

    local result=$(tmdb_api_call_with_retry "$external_ids_url" "查询剧集外部ID")

    if [[ "$result" != "{}" ]]; then
        echo "$result"
        return 0
    else
        log_warn "  ⚠️  剧集外部 ID 查询失败"
        echo "{}"
        return 1
    fi
}

#------------------------------------------------------------------------------
# 生成电影 NFO 文件
#------------------------------------------------------------------------------
# 参数：
#   $1: TMDB JSON 数据
#   $2: 输出 NFO 文件路径
# 返回：
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

generate_movie_nfo() {
    local tmdb_data="$1"
    local output_file="$2"

    # 从输出文件路径提取目录路径
    local nfo_dir=$(dirname "$output_file")

    log_info "  生成电影 NFO: $output_file"

    # 提取字段
    local title=$(echo "$tmdb_data" | jq -r '.title // .original_title')
    local original_title=$(echo "$tmdb_data" | jq -r '.original_title // .title')
    local year=$(echo "$tmdb_data" | jq -r '.release_date // "unknown"' | cut -d'-' -f1)
    local plot=$(echo "$tmdb_data" | jq -r '.overview // ""')
    local rating=$(echo "$tmdb_data" | jq -r '.vote_average // 0')
    local votes=$(echo "$tmdb_data" | jq -r '.vote_count // 0')
    local tmdb_id=$(echo "$tmdb_data" | jq -r '.id')
    local release_date=$(echo "$tmdb_data" | jq -r '.release_date // ""')
    local runtime=$(echo "$tmdb_data" | jq -r '.runtime // 0')
    local tagline=$(echo "$tmdb_data" | jq -r '.tagline // ""')
    local studio=$(echo "$tmdb_data" | jq -r '.production_companies[0].name // ""')
    local set_name=$(echo "$tmdb_data" | jq -r '.belongs_to_collection.name // ""')
    local set_id=$(echo "$tmdb_data" | jq -r '.belongs_to_collection.id // ""')

    # 提取类型（前5个）
    local genres=$(echo "$tmdb_data" | jq -r '.genres[]?.name' | head -5)

    # 提取制作国家（前3个）
    local countries=$(echo "$tmdb_data" | jq -r '.production_countries[]?.name' | head -3)

    # 提取MPAA分级（美国分级）
    local mpaa=$(echo "$tmdb_data" | jq -r '.release_dates.results[] | select(.iso_3166_1 == "US") | .release_dates[0].certification // ""' 2>/dev/null || echo "")

    # 获取演职人员信息
    local credits_data=$(get_movie_credits "$tmdb_id")

    # 获取预告片信息
    local trailers=$(get_movie_videos "$tmdb_id")

    # 获取外部 ID（IMDB、TVDB 等）
    local external_ids=$(get_movie_external_ids "$tmdb_id")
    local imdb_id=$(echo "$external_ids" | jq -r '.imdb_id // ""')
    local tvdb_id=$(echo "$external_ids" | jq -r '.tvdb_id // ""')

    # 生成 NFO（Kodi/Emby 兼容格式）
    cat > "$output_file" << EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<movie>
    <title>$title</title>
    <originaltitle>$original_title</originaltitle>
    <year>$year</year>
    <plot>$plot</plot>
    <outline>$plot</outline>
EOF

    # 添加标语（如果有）
    if [[ -n "$tagline" && "$tagline" != "null" ]]; then
        echo "    <tagline>$tagline</tagline>" >> "$output_file"
    fi

    # 继续基础信息
    cat >> "$output_file" << EOF
    <rating>$rating</rating>
    <votes>$votes</votes>
EOF

    # 添加MPAA分级（如果有）
    if [[ -n "$mpaa" && "$mpaa" != "null" ]]; then
        echo "    <mpaa>$mpaa</mpaa>" >> "$output_file"
    fi

    # 添加制作公司（如果有）
    if [[ -n "$studio" && "$studio" != "null" ]]; then
        echo "    <studio>$studio</studio>" >> "$output_file"
    fi

    # 继续ID和时间信息
    cat >> "$output_file" << EOF
    <tmdbid>$tmdb_id</tmdbid>
    <premiered>$release_date</premiered>
    <runtime>$runtime</runtime>
    <uniqueid type="tmdb" default="true">$tmdb_id</uniqueid>
EOF

    # 添加 IMDB ID（如果有）
    if [[ -n "$imdb_id" && "$imdb_id" != "null" ]]; then
        echo "    <imdbid>$imdb_id</imdbid>" >> "$output_file"
        echo "    <uniqueid type=\"imdb\">$imdb_id</uniqueid>" >> "$output_file"
    fi

    # 添加 TVDB ID（如果有）
    if [[ -n "$tvdb_id" && "$tvdb_id" != "null" ]]; then
        echo "    <tvdbid>$tvdb_id</tvdbid>" >> "$output_file"
        echo "    <uniqueid type=\"tvdb\">$tvdb_id</uniqueid>" >> "$output_file"
    fi

    # 添加类型标签
    while IFS= read -r genre; do
        if [[ -n "$genre" && "$genre" != "null" ]]; then
            echo "    <genre>$genre</genre>" >> "$output_file"
        fi
    done <<< "$genres"

    # 添加制作国家
    while IFS= read -r country; do
        if [[ -n "$country" && "$country" != "null" ]]; then
            echo "    <country>$country</country>" >> "$output_file"
        fi
    done <<< "$countries"

    # 添加系列/合集（如果有）
    if [[ -n "$set_name" && "$set_name" != "null" ]]; then
        echo -n "    <set" >> "$output_file"
        [[ -n "$set_id" && "$set_id" != "null" ]] && echo -n " tmdbcolid=\"$set_id\"" >> "$output_file"
        echo ">" >> "$output_file"
        echo "        <name>$set_name</name>" >> "$output_file"
        echo "    </set>" >> "$output_file"
    fi

    # 添加预告片链接（最多3个）
    if [[ -n "$trailers" ]]; then
        while IFS= read -r trailer; do
            if [[ -n "$trailer" ]]; then
                echo "    <trailer>$trailer</trailer>" >> "$output_file"
            fi
        done <<< "$trailers"
    fi

    # 添加演员信息（前10位主演）
    if [[ -n "$credits_data" && "$credits_data" != "{}" && "$credits_data" != "null" ]]; then
        # 创建 .actors 目录用于存放演员头像
        local actors_dir="${nfo_dir}/.actors"
        mkdir -p "$actors_dir" 2>/dev/null || true

        # 添加编剧信息
        local crew_count=$(echo "$credits_data" | jq -r '(.crew // []) | length')
        if [[ "$crew_count" -gt 0 ]]; then
            echo "$credits_data" | jq -r '((.crew // []) | map(select(.job == "Screenplay" or .job == "Writer")) | unique_by(.name))[] | @json' 2>/dev/null | while IFS= read -r writer_json; do
                local writer_name=$(echo "$writer_json" | jq -r '.name // ""')
                local writer_tmdb_id=$(echo "$writer_json" | jq -r '.id // ""')

                echo -n "    <writer" >> "$output_file"
                [[ -n "$writer_tmdb_id" && "$writer_tmdb_id" != "null" ]] && echo -n " tmdbid=\"$writer_tmdb_id\"" >> "$output_file"
                echo ">$writer_name</writer>" >> "$output_file"

                # 同时添加 credits 标签（Kodi 标准）
                echo -n "    <credits" >> "$output_file"
                [[ -n "$writer_tmdb_id" && "$writer_tmdb_id" != "null" ]] && echo -n " tmdbid=\"$writer_tmdb_id\"" >> "$output_file"
                echo ">$writer_name</credits>" >> "$output_file"
            done
        fi

        # 添加演员并下载头像（使用数组方式防止 null 迭代错误）
        local cast_count=$(echo "$credits_data" | jq -r '(.cast // []) | length')
        if [[ "$cast_count" -gt 0 ]]; then
            echo "$credits_data" | jq -r '((.cast // [])[:10])[] | @json' 2>/dev/null | while IFS= read -r actor_json; do
                local actor_name=$(echo "$actor_json" | jq -r '.name // ""')
                local actor_role=$(echo "$actor_json" | jq -r '.character // ""')
                local profile_path=$(echo "$actor_json" | jq -r '.profile_path // ""')

                # 写入演员信息到 NFO
                echo "    <actor>" >> "$output_file"
                echo "        <name>$actor_name</name>" >> "$output_file"
                echo "        <role>$actor_role</role>" >> "$output_file"
                echo "        <type>Actor</type>" >> "$output_file"

                # 下载演员头像（如果有）
                if [[ -n "$profile_path" && "$profile_path" != "null" ]]; then
                    local thumb_url="https://image.tmdb.org/t/p/w185${profile_path}"
                    local thumb_file="${actors_dir}/${actor_name}.jpg"

                    # 如果头像不存在，则下载
                    if [[ ! -f "$thumb_file" ]]; then
                        log_debug "  下载演员头像: $actor_name"
                        if download_image_with_retry "$thumb_url" "$thumb_file" "演员头像"; then
                            echo "        <thumb>${thumb_file}</thumb>" >> "$output_file"
                        else
                            # 下载失败，使用 URL
                            echo "        <thumb>$thumb_url</thumb>" >> "$output_file"
                        fi
                    else
                        # 使用本地文件
                        echo "        <thumb>${thumb_file}</thumb>" >> "$output_file"
                    fi
                fi

                echo "    </actor>" >> "$output_file"
            done
        fi

        # 添加导演信息
        if [[ "$crew_count" -gt 0 ]]; then
            echo "$credits_data" | jq -r '((.crew // []) | map(select(.job == "Director")))[] |
                "    <director>" + .name + "</director>"' 2>/dev/null >> "$output_file"
        fi
    fi

    # 结束标签
    echo "</movie>" >> "$output_file"

    if [[ $? -eq 0 ]]; then
        log_success "  ✅ NFO 文件生成成功（含演职人员信息）"
        return 0
    else
        log_error "  NFO 文件生成失败"
        return 1
    fi
}

#------------------------------------------------------------------------------
# 生成电视剧 NFO 文件
#------------------------------------------------------------------------------
# 参数：
#   $1: TMDB JSON 数据
#   $2: 输出 NFO 文件路径
# 返回：
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

generate_tv_nfo() {
    local tmdb_data="$1"
    local output_file="$2"

    log_info "  生成单集 NFO: $output_file"

    # 提取剧集字段
    local show_title=$(echo "$tmdb_data" | jq -r '.name // .original_name')
    local tmdb_id=$(echo "$tmdb_data" | jq -r '.id')

    # 提取剧集字段（如果有）
    local episode_title=$(echo "$tmdb_data" | jq -r '.episode.name // ""')
    local season_num=$(echo "$tmdb_data" | jq -r '.episode.season_number // 0')
    local episode_num=$(echo "$tmdb_data" | jq -r '.episode.episode_number // 0')
    local plot=$(echo "$tmdb_data" | jq -r '.episode.overview // .overview // ""')
    local air_date=$(echo "$tmdb_data" | jq -r '.episode.air_date // .first_air_date // ""')
    local episode_rating=$(echo "$tmdb_data" | jq -r '.episode.vote_average // 0')
    local runtime=$(echo "$tmdb_data" | jq -r '.episode.runtime // .episode_run_time[0] // 0')
    local year=$(echo "$air_date" | cut -d'-' -f1)

    # 获取剧集演职人员信息
    local credits_data=$(get_tv_credits "$tmdb_id")

    # 获取外部 ID（IMDB、TVDB 等）
    local external_ids=$(get_tv_external_ids "$tmdb_id")
    local imdb_id=$(echo "$external_ids" | jq -r '.imdb_id // ""')
    local tvdb_id=$(echo "$external_ids" | jq -r '.tvdb_id // ""')

    # 生成单集 NFO（开始部分）
    cat > "$output_file" << EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<episodedetails>
    <title>$episode_title</title>
    <showtitle>$show_title</showtitle>
    <season>$season_num</season>
    <episode>$episode_num</episode>
    <plot>$plot</plot>
    <outline>$plot</outline>
EOF

    # 添加演员信息（前20位主演，符合 Emby 标准）
    if [[ -n "$credits_data" && "$credits_data" != "{}" && "$credits_data" != "null" ]]; then
        local cast_count=$(echo "$credits_data" | jq -r '(.cast // []) | length')
        if [[ "$cast_count" -gt 0 ]]; then
            echo "$credits_data" | jq -r '((.cast // [])[:20])[] | @json' 2>/dev/null | while IFS= read -r actor_json; do
                local actor_name=$(echo "$actor_json" | jq -r '.name // ""')
                local actor_role=$(echo "$actor_json" | jq -r '.character // ""')
                local actor_tmdb_id=$(echo "$actor_json" | jq -r '.id // ""')
                local known_for=$(echo "$actor_json" | jq -r '.known_for_department // ""')

                # 判断演员类型（主演 vs 客串）
                local actor_type="Actor"
                if [[ "$known_for" == "Acting" ]]; then
                    actor_type="Actor"
                else
                    actor_type="GuestStar"
                fi

                # 写入演员信息到 NFO
                echo "    <actor>" >> "$output_file"
                echo "        <name>$actor_name</name>" >> "$output_file"
                [[ -n "$actor_role" && "$actor_role" != "null" ]] && echo "        <role>$actor_role</role>" >> "$output_file"
                echo "        <type>$actor_type</type>" >> "$output_file"
                [[ -n "$actor_tmdb_id" && "$actor_tmdb_id" != "null" ]] && echo "        <tmdbid>$actor_tmdb_id</tmdbid>" >> "$output_file"
                echo "    </actor>" >> "$output_file"
            done
        fi
    fi

    # 添加剩余字段和结束标签
    cat >> "$output_file" << EOF
    <rating>$episode_rating</rating>
    <year>$year</year>
    <aired>$air_date</aired>
    <runtime>$runtime</runtime>
    <uniqueid type="tmdb" default="true">$tmdb_id</uniqueid>
EOF

    # 添加 IMDB ID（如果有）
    if [[ -n "$imdb_id" && "$imdb_id" != "null" ]]; then
        echo "    <imdbid>$imdb_id</imdbid>" >> "$output_file"
        echo "    <uniqueid type=\"imdb\">$imdb_id</uniqueid>" >> "$output_file"
    fi

    # 添加 TVDB ID（如果有）
    if [[ -n "$tvdb_id" && "$tvdb_id" != "null" ]]; then
        echo "    <tvdbid>$tvdb_id</tvdbid>" >> "$output_file"
        echo "    <uniqueid type=\"tvdb\">$tvdb_id</uniqueid>" >> "$output_file"
    fi

    # 结束标签
    echo "</episodedetails>" >> "$output_file"

    if [[ $? -eq 0 ]]; then
        log_success "  ✅ 单集 NFO 生成成功"
        return 0
    else
        log_error "  单集 NFO 生成失败"
        return 1
    fi
}

#------------------------------------------------------------------------------
# 生成总剧集 NFO（Series.nfo）
#------------------------------------------------------------------------------
# 参数：
#   $1: TMDB JSON 数据
#   $2: 输出文件路径（Series.nfo）
# 返回：
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

generate_series_nfo() {
    local tmdb_data="$1"
    local output_file="$2"

    # 从输出文件路径提取目录路径
    local nfo_dir=$(dirname "$output_file")

    log_info "  生成总剧集 NFO: $output_file"

    # 提取剧集基本信息
    local show_title=$(echo "$tmdb_data" | jq -r '.name // .original_name')
    local original_title=$(echo "$tmdb_data" | jq -r '.original_name // .name')
    local year=$(echo "$tmdb_data" | jq -r '.first_air_date // "" | split("-")[0]')
    local plot=$(echo "$tmdb_data" | jq -r '.overview // ""')
    local tmdb_id=$(echo "$tmdb_data" | jq -r '.id')
    local rating=$(echo "$tmdb_data" | jq -r '.vote_average // 0')
    local votes=$(echo "$tmdb_data" | jq -r '.vote_count // 0')
    local number_of_seasons=$(echo "$tmdb_data" | jq -r '.number_of_seasons // 0')
    local number_of_episodes=$(echo "$tmdb_data" | jq -r '.number_of_episodes // 0')
    local first_air_date=$(echo "$tmdb_data" | jq -r '.first_air_date // ""')
    local tagline=$(echo "$tmdb_data" | jq -r '.tagline // ""')

    # 提取类型（可能有多个）
    local genres=$(echo "$tmdb_data" | jq -r '.genres[]?.name' | head -5)

    # 提取制作国家
    local countries=$(echo "$tmdb_data" | jq -r '.origin_country[]? // .production_countries[]?.name' | head -3)

    # 获取剧集演职人员信息
    local credits_data=$(get_tv_credits "$tmdb_id")

    # 获取预告片信息
    local trailers=$(get_tv_videos "$tmdb_id")

    # 获取外部 ID（IMDB、TVDB 等）
    local external_ids=$(get_tv_external_ids "$tmdb_id")
    local imdb_id=$(echo "$external_ids" | jq -r '.imdb_id // ""')
    local tvdb_id=$(echo "$external_ids" | jq -r '.tvdb_id // ""')

    # 生成总剧集 NFO
    cat > "$output_file" << EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<tvshow>
    <title>$show_title</title>
    <originaltitle>$original_title</originaltitle>
    <year>$year</year>
    <plot>$plot</plot>
    <outline>$plot</outline>
EOF

    # 添加标语（如果有）
    if [[ -n "$tagline" && "$tagline" != "null" ]]; then
        echo "    <tagline>$tagline</tagline>" >> "$output_file"
    fi

    # 继续基础信息
    cat >> "$output_file" << EOF
    <rating>$rating</rating>
    <votes>$votes</votes>
    <premiered>$first_air_date</premiered>
    <status>$(echo "$tmdb_data" | jq -r '.status // ""')</status>
    <studio>$(echo "$tmdb_data" | jq -r '.networks[0].name // ""')</studio>
    <mpaa>$(echo "$tmdb_data" | jq -r '.content_ratings.results[] | select(.iso_3166_1 == "US") | .rating // ""')</mpaa>
    <uniqueid type="tmdb" default="true">$tmdb_id</uniqueid>
EOF

    # 添加 IMDB ID（如果有）
    if [[ -n "$imdb_id" && "$imdb_id" != "null" ]]; then
        echo "    <imdbid>$imdb_id</imdbid>" >> "$output_file"
        echo "    <uniqueid type=\"imdb\">$imdb_id</uniqueid>" >> "$output_file"
    fi

    # 添加 TVDB ID（如果有）
    if [[ -n "$tvdb_id" && "$tvdb_id" != "null" ]]; then
        echo "    <tvdbid>$tvdb_id</tvdbid>" >> "$output_file"
        echo "    <uniqueid type=\"tvdb\">$tvdb_id</uniqueid>" >> "$output_file"
    fi

    # 继续剩余字段
    cat >> "$output_file" << EOF
    <episodefilecount>$number_of_episodes</episodefilecount>
    <seasoncount>$number_of_seasons</seasoncount>
EOF

    # 添加类型
    while IFS= read -r genre; do
        if [[ -n "$genre" ]]; then
            echo "    <genre>$genre</genre>" >> "$output_file"
        fi
    done <<< "$genres"

    # 添加制作国家
    while IFS= read -r country; do
        if [[ -n "$country" && "$country" != "null" ]]; then
            echo "    <country>$country</country>" >> "$output_file"
        fi
    done <<< "$countries"

    # 添加预告片链接（最多3个）
    if [[ -n "$trailers" ]]; then
        while IFS= read -r trailer; do
            if [[ -n "$trailer" ]]; then
                echo "    <trailer>$trailer</trailer>" >> "$output_file"
            fi
        done <<< "$trailers"
    fi

    # 添加演员信息（前15位主演）
    if [[ -n "$credits_data" && "$credits_data" != "{}" && "$credits_data" != "null" ]]; then
        # 创建 .actors 目录用于存放演员头像
        local actors_dir="${nfo_dir}/.actors"
        mkdir -p "$actors_dir" 2>/dev/null || true

        # 添加演员并下载头像（使用数组方式防止 null 迭代错误）
        local cast_count=$(echo "$credits_data" | jq -r '(.cast // []) | length')
        if [[ "$cast_count" -gt 0 ]]; then
            echo "$credits_data" | jq -r '((.cast // [])[:15])[] | @json' 2>/dev/null | while IFS= read -r actor_json; do
                local actor_name=$(echo "$actor_json" | jq -r '.name // ""')
                local actor_role=$(echo "$actor_json" | jq -r '.character // ""')
                local profile_path=$(echo "$actor_json" | jq -r '.profile_path // ""')

                # 写入演员信息到 NFO
                echo "    <actor>" >> "$output_file"
                echo "        <name>$actor_name</name>" >> "$output_file"
                echo "        <role>$actor_role</role>" >> "$output_file"
                echo "        <type>Actor</type>" >> "$output_file"

                # 下载演员头像（如果有）
                if [[ -n "$profile_path" && "$profile_path" != "null" ]]; then
                    local thumb_url="https://image.tmdb.org/t/p/w185${profile_path}"
                    local thumb_file="${actors_dir}/${actor_name}.jpg"

                    # 如果头像不存在，则下载
                    if [[ ! -f "$thumb_file" ]]; then
                        log_debug "  下载演员头像: $actor_name"
                        if download_image_with_retry "$thumb_url" "$thumb_file" "演员头像"; then
                            echo "        <thumb>${thumb_file}</thumb>" >> "$output_file"
                        else
                            # 下载失败，使用 URL
                            echo "        <thumb>$thumb_url</thumb>" >> "$output_file"
                        fi
                    else
                        # 使用本地文件
                        echo "        <thumb>${thumb_file}</thumb>" >> "$output_file"
                    fi
                fi

                echo "    </actor>" >> "$output_file"
            done
        fi

        # 添加导演信息（电视剧可能有多个导演）
        local crew_count=$(echo "$credits_data" | jq -r '(.crew // []) | length')
        if [[ "$crew_count" -gt 0 ]]; then
            echo "$credits_data" | jq -r '((.crew // []) | map(select(.job == "Executive Producer" or .job == "Creator")) | unique_by(.name))[] |
                "    <director>" + .name + "</director>"' 2>/dev/null >> "$output_file"
        fi
    fi

    # 结束标签
    echo "</tvshow>" >> "$output_file"

    if [[ $? -eq 0 ]]; then
        log_success "  ✅ 总剧集 NFO 生成成功（含演职人员信息）"
        return 0
    else
        log_error "  总剧集 NFO 生成失败"
        return 1
    fi
}

#------------------------------------------------------------------------------
# 生成季 NFO（Season.nfo）
#------------------------------------------------------------------------------
# 参数：
#   $1: TMDB JSON 数据（包含季信息）
#   $2: 季号
#   $3: 输出文件路径（Season.nfo）
# 返回：
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

generate_season_nfo() {
    local tmdb_data="$1"
    local season_num="$2"
    local output_file="$3"

    log_info "  生成季 NFO: $output_file (Season $season_num)"

    # 提取季信息
    local season_data=$(echo "$tmdb_data" | jq -r ".season")
    local season_name=$(echo "$season_data" | jq -r '.name // "Season '"$season_num"'"')
    local season_overview=$(echo "$season_data" | jq -r '.overview // ""')
    local episode_count=$(echo "$season_data" | jq -r '.episodes | length')
    local air_date=$(echo "$season_data" | jq -r '.air_date // ""')

    # 生成季 NFO
    cat > "$output_file" << EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<season>
    <seasonnumber>$season_num</seasonnumber>
    <title>$season_name</title>
    <plot>$season_overview</plot>
    <episodecount>$episode_count</episodecount>
    <premiered>$air_date</premiered>
</season>
EOF

    if [[ $? -eq 0 ]]; then
        log_success "  ✅ 季 NFO 生成成功 (Season $season_num)"
        return 0
    else
        log_error "  季 NFO 生成失败"
        return 1
    fi
}

#------------------------------------------------------------------------------
# 下载海报
#------------------------------------------------------------------------------
# 参数：
#   $1: TMDB JSON 数据
#   $2: 输出文件路径
# 返回：
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

#------------------------------------------------------------------------------
# 带重试的图片下载函数
#------------------------------------------------------------------------------
# 参数：
#   $1: 图片URL
#   $2: 输出文件路径
#   $3: 描述信息（用于日志）
# 返回：
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

download_image_with_retry() {
    local image_url="$1"
    local output_file="$2"
    local description="${3:-图片}"
    local timeout="${TMDB_TIMEOUT:-30}"
    local max_retries="${IMAGE_DOWNLOAD_RETRY_COUNT:-2}"
    local retry_delay="${IMAGE_DOWNLOAD_RETRY_DELAY:-2}"
    local min_size="${IMAGE_DOWNLOAD_MIN_SIZE:-1024}"

    # 检查文件是否已存在且大小合格（跳过重复下载）
    if [ -f "$output_file" ]; then
        local existing_size=$(stat -c%s "$output_file" 2>/dev/null || stat -f%z "$output_file" 2>/dev/null || echo "0")
        if [ "$existing_size" -ge "$min_size" ]; then
            log_debug "  ${description}已存在（大小: ${existing_size}字节），跳过下载"
            return 0
        else
            log_debug "  ${description}文件过小（${existing_size}字节），重新下载"
            rm -f "$output_file"
        fi
    fi

    # 代理配置
    local proxy_enabled="${TMDB_PROXY_ENABLED:-false}"
    local proxy_url="${TMDB_PROXY_URL:-}"
    local proxy_timeout="${TMDB_PROXY_TIMEOUT:-60}"
    local proxy_fallback="${TMDB_PROXY_FALLBACK:-direct}"

    local retry_count=0

    while [ $retry_count -le $max_retries ]; do
        if [ $retry_count -gt 0 ]; then
            log_warn "  ${description}下载第${retry_count}次失败，等待${retry_delay}秒后重试..."
            sleep "$retry_delay"
        fi

        log_debug "  下载${description}（尝试$((retry_count + 1))/$((max_retries + 1))）: $image_url"

        # 构建 curl 参数
        local curl_opts=(-s -o "$output_file")
        local current_timeout="$timeout"
        local use_proxy=false

        # 判断是否使用代理
        if [ "$proxy_enabled" = "true" ] && [ -n "$proxy_url" ]; then
            curl_opts+=(--proxy "$proxy_url")
            current_timeout="$proxy_timeout"
            use_proxy=true
        fi

        curl_opts+=(--max-time "$current_timeout" "$image_url")

        # 下载图片
        curl "${curl_opts[@]}" 2>&1
        local curl_exit=$?

        # 验证下载结果
        if [[ $curl_exit -eq 0 && -f "$output_file" ]]; then
            local file_size=$(stat -c%s "$output_file" 2>/dev/null || stat -f%z "$output_file" 2>/dev/null || echo "0")

            if [[ "$file_size" -ge "$min_size" ]]; then
                log_success "  ✅ ${description}下载完成（尝试$((retry_count + 1))/$((max_retries + 1))，大小: ${file_size}字节）"
                return 0
            else
                log_warn "  ⚠️  ${description}文件过小（${file_size}字节 < ${min_size}字节），视为下载失败"
                rm -f "$output_file"
            fi
        else
            # 代理失败降级逻辑
            if [ "$use_proxy" = true ] && [ "$proxy_fallback" = "direct" ] && [ $retry_count -eq 0 ]; then
                log_warn "  代理下载失败，尝试直连..."

                # 直连下载
                curl -s --max-time "$timeout" -o "$output_file" "$image_url" 2>&1
                curl_exit=$?

                if [[ $curl_exit -eq 0 && -f "$output_file" ]]; then
                    local file_size=$(stat -c%s "$output_file" 2>/dev/null || stat -f%z "$output_file" 2>/dev/null || echo "0")

                    if [[ "$file_size" -ge "$min_size" ]]; then
                        log_success "  ✅ ${description}下载完成（直连成功，大小: ${file_size}字节）"
                        return 0
                    else
                        log_warn "  ⚠️  ${description}文件过小（${file_size}字节 < ${min_size}字节），视为下载失败"
                        rm -f "$output_file"
                    fi
                fi
            fi
        fi

        retry_count=$((retry_count + 1))
    done

    log_error "  ${description}下载失败（已重试$((max_retries + 1))次）"
    rm -f "$output_file"
    return 1
}

#------------------------------------------------------------------------------
# 下载海报
#------------------------------------------------------------------------------
# 参数：
#   $1: TMDB JSON 数据
#   $2: 输出文件路径
# 返回：
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

download_poster() {
    local tmdb_data="$1"
    local output_file="$2"
    local api_key="${TMDB_API_KEY}"

    # 提取 ID、类型和原语言
    local tmdb_id=$(echo "$tmdb_data" | jq -r '.id // empty')
    local original_language=$(echo "$tmdb_data" | jq -r '.original_language // "en"')
    local media_type="movie"  # 默认为电影

    # 判断是电影还是电视剧（通过是否有 name 字段）
    if echo "$tmdb_data" | jq -e '.name' >/dev/null 2>&1; then
        media_type="tv"
    fi

    if [[ -z "$tmdb_id" || "$tmdb_id" == "null" ]]; then
        log_error "  无法获取 TMDB ID"
        return 1
    fi

    log_info "  下载海报: $output_file (原语言: $original_language)"

    # 调用 /images API 获取原语言图片（使用重试机制）
    local images_url="https://api.themoviedb.org/3/${media_type}/${tmdb_id}/images?api_key=${api_key}&include_image_language=${original_language},null"
    local images_data
    images_data=$(tmdb_api_call_with_retry "$images_url" "获取海报图片列表")

    if [[ "$images_data" == "{}" ]]; then
        log_error "  获取图片列表失败"
        return 1
    fi

    # 提取海报路径（优先原语言，其次无语言标记，按 vote_average 排序）
    local poster_path=$(echo "$images_data" | jq -r '
        .posters
        | sort_by(.vote_average)
        | reverse
        | map(select(.iso_639_1 == "'$original_language'" or .iso_639_1 == null))
        | .[0].file_path // empty
    ')

    # 如果没有找到，回退到主查询的默认图片
    if [[ -z "$poster_path" || "$poster_path" == "null" ]]; then
        log_warn "  ⚠️  未找到原语言海报，使用默认海报"
        poster_path=$(echo "$tmdb_data" | jq -r '.poster_path // empty')
    fi

    if [[ -z "$poster_path" || "$poster_path" == "null" ]]; then
        log_warn "  ⚠️  未找到海报路径"
        return 1
    fi

    local poster_url="https://image.tmdb.org/t/p/original${poster_path}"
    log_debug "  海报 URL: $poster_url"

    # 使用带重试的下载函数
    download_image_with_retry "$poster_url" "$output_file" "海报"
    return $?
}

#------------------------------------------------------------------------------
# 下载背景图
#------------------------------------------------------------------------------
# 参数：
#   $1: TMDB JSON 数据
#   $2: 输出文件路径
# 返回：
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

download_backdrop() {
    local tmdb_data="$1"
    local output_file="$2"
    local api_key="${TMDB_API_KEY}"

    # 提取 ID、类型和原语言
    local tmdb_id=$(echo "$tmdb_data" | jq -r '.id // empty')
    local original_language=$(echo "$tmdb_data" | jq -r '.original_language // "en"')
    local media_type="movie"  # 默认为电影

    # 判断是电影还是电视剧（通过是否有 name 字段）
    if echo "$tmdb_data" | jq -e '.name' >/dev/null 2>&1; then
        media_type="tv"
    fi

    if [[ -z "$tmdb_id" || "$tmdb_id" == "null" ]]; then
        log_error "  无法获取 TMDB ID"
        return 1
    fi

    log_info "  下载背景图: $output_file (原语言: $original_language)"

    # 调用 /images API 获取原语言图片（使用重试机制）
    local images_url="https://api.themoviedb.org/3/${media_type}/${tmdb_id}/images?api_key=${api_key}&include_image_language=${original_language},null"
    local images_data
    images_data=$(tmdb_api_call_with_retry "$images_url" "获取背景图片列表")

    if [[ "$images_data" == "{}" ]]; then
        log_error "  获取图片列表失败"
        return 1
    fi

    # 提取背景图路径（优先原语言，其次无语言标记，按 vote_average 排序）
    local backdrop_path=$(echo "$images_data" | jq -r '
        .backdrops
        | sort_by(.vote_average)
        | reverse
        | map(select(.iso_639_1 == "'$original_language'" or .iso_639_1 == null))
        | .[0].file_path // empty
    ')

    # 如果没有找到，回退到主查询的默认图片
    if [[ -z "$backdrop_path" || "$backdrop_path" == "null" ]]; then
        log_warn "  ⚠️  未找到原语言背景图，使用默认背景图"
        backdrop_path=$(echo "$tmdb_data" | jq -r '.backdrop_path // empty')
    fi

    if [[ -z "$backdrop_path" || "$backdrop_path" == "null" ]]; then
        log_warn "  ⚠️  未找到背景图路径"
        return 1
    fi

    local backdrop_url="https://image.tmdb.org/t/p/original${backdrop_path}"
    log_debug "  背景图 URL: $backdrop_url"

    # 使用带重试的下载函数
    download_image_with_retry "$backdrop_url" "$output_file" "背景图"
    return $?
}

#------------------------------------------------------------------------------
# 下载季度横幅图/背景图（Season Banner/Fanart）
#------------------------------------------------------------------------------
# 参数：
#   $1: TMDB 剧集 ID
#   $2: 季号（去除前导零，如 "1", "2"）
#   $3: 输出文件路径（banner 或 fanart）
# 返回：
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

download_season_backdrop() {
    local show_id="$1"
    local season_number="$2"
    local output_file="$3"
    local api_key="${TMDB_API_KEY}"

    if [[ -z "$show_id" || "$show_id" == "null" ]]; then
        log_error "  无法获取 TMDB 剧集 ID"
        return 1
    fi

    log_info "  下载季度横幅/背景图: Season ${season_number}"

    # 调用季度图片 API
    local images_url="https://api.themoviedb.org/3/tv/${show_id}/season/${season_number}/images?api_key=${api_key}"
    local images_data
    images_data=$(tmdb_api_call_with_retry "$images_url" "获取季度图片列表")

    if [[ "$images_data" == "{}" ]]; then
        log_warn "  ⚠️  获取季度图片列表失败，尝试使用剧集背景图"
        # 回退方案：使用剧集级别的背景图
        local show_images_url="https://api.themoviedb.org/3/tv/${show_id}/images?api_key=${api_key}"
        images_data=$(tmdb_api_call_with_retry "$show_images_url" "获取剧集图片列表")

        if [[ "$images_data" == "{}" ]]; then
            log_error "  获取剧集图片列表也失败"
            return 1
        fi
    fi

    # 提取背景图路径（backdrops 用作横幅图，按评分排序）
    # 注意：添加 null 检查避免 "Cannot iterate over null" 错误
    local backdrop_path=$(echo "$images_data" | jq -r '
        if .backdrops == null or (.backdrops | length) == 0 then
            empty
        else
            .backdrops
            | sort_by(.vote_average)
            | reverse
            | .[0].file_path // empty
        end
    ')

    if [[ -z "$backdrop_path" || "$backdrop_path" == "null" ]]; then
        log_warn "  ⚠️  未找到季度横幅图路径"
        return 1
    fi

    local backdrop_url="https://image.tmdb.org/t/p/original${backdrop_path}"
    log_debug "  季度横幅图 URL: $backdrop_url"

    # 使用带重试的下载函数
    download_image_with_retry "$backdrop_url" "$output_file" "季度横幅图"
    return $?
}

#------------------------------------------------------------------------------
# 下载单集缩略图（Episode Thumb）
#------------------------------------------------------------------------------
# 参数：
#   $1: TMDB JSON 数据（包含 episode.still_path）
#   $2: 输出文件路径
# 返回：
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

download_episode_thumb() {
    local tmdb_data="$1"
    local output_file="$2"

    # 提取单集缩略图路径（still_path）
    local still_path=$(echo "$tmdb_data" | jq -r '.episode.still_path // empty')

    if [[ -z "$still_path" || "$still_path" == "null" ]]; then
        log_warn "  ⚠️  未找到单集缩略图路径"
        return 1
    fi

    local thumb_url="https://image.tmdb.org/t/p/original${still_path}"

    log_info "  下载单集缩略图: $output_file"
    log_debug "  缩略图 URL: $thumb_url"

    # 使用带重试的下载函数
    download_image_with_retry "$thumb_url" "$output_file" "单集缩略图"
    return $?
}

#------------------------------------------------------------------------------
# 下载徽标（Logo/ClearLogo）
#------------------------------------------------------------------------------
# 参数：
#   $1: TMDB JSON 数据
#   $2: 输出文件路径
# 返回：
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

download_logo() {
    local tmdb_data="$1"
    local output_file="$2"
    local api_key="${TMDB_API_KEY}"

    # 提取 ID、类型和原语言
    local tmdb_id=$(echo "$tmdb_data" | jq -r '.id // empty')
    local original_language=$(echo "$tmdb_data" | jq -r '.original_language // "en"')
    local media_type="movie"  # 默认为电影

    # 判断是电影还是电视剧
    if echo "$tmdb_data" | jq -e '.name' >/dev/null 2>&1; then
        media_type="tv"
    fi

    if [[ -z "$tmdb_id" || "$tmdb_id" == "null" ]]; then
        log_error "  无法获取 TMDB ID"
        return 1
    fi

    log_info "  下载徽标: $output_file (原语言: $original_language)"

    # 调用 /images API 获取 logos（使用重试机制）
    local images_url="https://api.themoviedb.org/3/${media_type}/${tmdb_id}/images?api_key=${api_key}&include_image_language=${original_language},en,null"
    local images_data
    images_data=$(tmdb_api_call_with_retry "$images_url" "获取徽标列表")

    if [[ "$images_data" == "{}" ]]; then
        log_warn "  ⚠️  获取图片列表失败"
        return 1
    fi

    # 提取 logo 路径（优先原语言，其次英文，最后无语言标记，按 vote_average 排序）
    local logo_path=$(echo "$images_data" | jq -r '
        .logos
        | sort_by(.vote_average)
        | reverse
        | map(select(.iso_639_1 == "'$original_language'" or .iso_639_1 == "en" or .iso_639_1 == null))
        | .[0].file_path // empty
    ')

    if [[ -z "$logo_path" || "$logo_path" == "null" ]]; then
        log_warn "  ⚠️  未找到徽标路径"
        return 1
    fi

    local logo_url="https://image.tmdb.org/t/p/original${logo_path}"
    log_debug "  徽标 URL: $logo_url"

    # 使用带重试的下载函数
    download_image_with_retry "$logo_url" "$output_file" "徽标"
    return $?
}

#------------------------------------------------------------------------------
# 下载横幅图（Banner）
#------------------------------------------------------------------------------
# 参数：
#   $1: TMDB JSON 数据
#   $2: 输出文件路径
# 返回：
#   退出码：0=成功，1=失败
# 说明：
#   TMDB 没有专门的 banner 类型，使用 backdrop（横版图）作为横幅
#------------------------------------------------------------------------------

download_banner() {
    local tmdb_data="$1"
    local output_file="$2"
    local api_key="${TMDB_API_KEY}"

    # 提取 ID、类型和原语言
    local tmdb_id=$(echo "$tmdb_data" | jq -r '.id // empty')
    local original_language=$(echo "$tmdb_data" | jq -r '.original_language // "en"')
    local media_type="movie"  # 默认为电影

    # 判断是电影还是电视剧
    if echo "$tmdb_data" | jq -e '.name' >/dev/null 2>&1; then
        media_type="tv"
    fi

    if [[ -z "$tmdb_id" || "$tmdb_id" == "null" ]]; then
        log_error "  无法获取 TMDB ID"
        return 1
    fi

    log_info "  下载横幅图: $output_file (原语言: $original_language)"

    # 调用 /images API 获取 backdrops（使用重试机制）
    local images_url="https://api.themoviedb.org/3/${media_type}/${tmdb_id}/images?api_key=${api_key}&include_image_language=${original_language},null"
    local images_data
    images_data=$(tmdb_api_call_with_retry "$images_url" "获取横幅图片列表")

    if [[ "$images_data" == "{}" ]]; then
        log_error "  获取图片列表失败"
        return 1
    fi

    # 提取横幅图路径（使用 backdrops，优先原语言，按 vote_average 排序）
    local banner_path=$(echo "$images_data" | jq -r '
        .backdrops
        | sort_by(.vote_average)
        | reverse
        | map(select(.iso_639_1 == "'$original_language'" or .iso_639_1 == null))
        | .[0].file_path // empty
    ')

    # 如果没有找到，回退到主查询的默认背景图
    if [[ -z "$banner_path" || "$banner_path" == "null" ]]; then
        log_warn "  ⚠️  未找到原语言横幅图，使用默认背景图"
        banner_path=$(echo "$tmdb_data" | jq -r '.backdrop_path // empty')
    fi

    if [[ -z "$banner_path" || "$banner_path" == "null" ]]; then
        log_warn "  ⚠️  未找到横幅图路径"
        return 1
    fi

    local banner_url="https://image.tmdb.org/t/p/original${banner_path}"
    log_debug "  横幅图 URL: $banner_url"

    # 使用带重试的下载函数
    download_image_with_retry "$banner_url" "$output_file" "横幅图"
    return $?
}

#------------------------------------------------------------------------------
# 完整元数据刮削流程（阶段2）
#------------------------------------------------------------------------------
# 参数：
#   $1: STRM 文件路径
# 返回：
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

scrape_metadata_full() {
    local strm_file="$1"
    local tv_structure_info="${2:-}"  # 可选参数：电视剧目录结构信息
    local strm_dir="$(dirname "$strm_file")"
    local strm_name="$(basename "$strm_file" .strm)"

    # 检查是否已有单集/电影 NFO 文件
    local nfo_file="${strm_dir}/${strm_name}.nfo"
    if [[ -f "$nfo_file" ]]; then
        log_info "跳过（已有NFO）: $strm_file"
        return 0
    fi

    log_info "开始刮削元数据: $strm_file"

    # 检查配置
    if [[ "${STAGE1_ENABLED:-true}" != "true" ]]; then
        log_warn "  阶段1已禁用，跳过元数据刮削"
        return 0
    fi

    if [[ -z "${TMDB_API_KEY:-}" ]]; then
        log_warn "  TMDB API Key 未配置，跳过元数据刮削"
        return 0
    fi

    # 1. 从文件名提取信息（传入完整路径以支持从目录名提取 TMDB ID）
    local metadata
    metadata=$(extract_metadata_from_filename "$strm_file")

    local cn_title=$(echo "$metadata" | cut -d'|' -f1)
    local en_title=$(echo "$metadata" | cut -d'|' -f2)
    local year=$(echo "$metadata" | cut -d'|' -f3)
    local tmdb_id=$(echo "$metadata" | cut -d'|' -f4)
    local season=$(echo "$metadata" | cut -d'|' -f5)
    local episode=$(echo "$metadata" | cut -d'|' -f6)

    if [[ -z "$cn_title" && -z "$en_title" ]]; then
        log_error "  无法从文件名提取标题"
        return 1
    fi

    # 2. 查询 TMDB
    local tmdb_data=""
    local is_tv_show=false

    if [[ -n "$season" && -n "$episode" ]]; then
        # 电视剧
        log_info "  识别为电视剧 (S${season}E${episode})"
        is_tv_show=true
        tmdb_data=$(query_tmdb_tv "$cn_title" "$en_title" "$year" "$tmdb_id" "$season" "$episode")
    else
        # 电影
        log_info "  识别为电影"
        tmdb_data=$(query_tmdb_movie "$cn_title" "$en_title" "$year" "$tmdb_id")
    fi

    if [[ $? -ne 0 || -z "$tmdb_data" ]]; then
        log_warn "  ⚠️  TMDB 查询失败，跳过 NFO 生成"
        return 1
    fi

    # 3. 生成 NFO 文件
    if [[ "$is_tv_show" == true ]]; then
        # 电视剧：多层级处理
        log_info "  [电视剧] 处理多层级 NFO 和图片"

        # 识别路径结构（优先使用传入的结构信息）
        local season_dir=""
        local series_dir=""

        if [[ -n "$tv_structure_info" ]]; then
            # 使用预分析的目录结构
            series_dir=$(echo "$tv_structure_info" | cut -d'|' -f1)
            season_dir=$(echo "$tv_structure_info" | cut -d'|' -f2)
            log_debug "  使用预分析的目录结构"
            log_debug "    剧集根目录: $series_dir"
            log_debug "    季文件夹: $season_dir"
        else
            # 回退到简单识别（向后兼容）
            season_dir="$strm_dir"
            series_dir="$(dirname "$season_dir")"
            log_debug "  使用简单目录识别（向后兼容）"
            log_debug "    季文件夹: $season_dir"
            log_debug "    剧集根目录: $series_dir"
        fi

        # 3.1 生成总剧集 NFO（Series.nfo）- 只生成一次
        local series_nfo="${series_dir}/tvshow.nfo"
        if [[ ! -f "$series_nfo" ]]; then
            log_info "  生成总剧集 NFO"
            generate_series_nfo "$tmdb_data" "$series_nfo"
        else
            log_debug "  跳过（已有总剧集 NFO）"
        fi

        # 3.2 生成季 NFO（Season.nfo）- 每个季只生成一次
        local season_nfo="${season_dir}/season.nfo"
        if [[ ! -f "$season_nfo" ]]; then
            log_info "  生成季 NFO (Season $season)"
            generate_season_nfo "$tmdb_data" "$season" "$season_nfo"
        else
            log_debug "  跳过（已有季 NFO）"
        fi

        # 3.3 生成单集 NFO - 每次都生成
        log_info "  生成单集 NFO (S${season}E${episode})"
        generate_tv_nfo "$tmdb_data" "$nfo_file"

        # 4. 下载图片
        # 4.1 下载剧集级图片到剧集根目录（只下载一次）
        local series_poster="${series_dir}/poster.jpg"
        local series_fanart="${series_dir}/fanart.jpg"
        local series_banner="${series_dir}/banner.jpg"
        local series_logo="${series_dir}/logo.png"

        if [[ ! -f "$series_poster" ]]; then
            log_info "  下载剧集海报"
            download_poster "$tmdb_data" "$series_poster" &
            local series_poster_pid=$!
        else
            log_debug "  跳过（已有剧集海报）"
        fi

        if [[ ! -f "$series_fanart" ]]; then
            log_info "  下载剧集背景图"
            download_backdrop "$tmdb_data" "$series_fanart" &
            local series_fanart_pid=$!
        else
            log_debug "  跳过（已有剧集背景图）"
        fi

        if [[ ! -f "$series_banner" ]]; then
            log_info "  下载剧集横幅图"
            download_banner "$tmdb_data" "$series_banner" &
            local series_banner_pid=$!
        else
            log_debug "  跳过（已有剧集横幅图）"
        fi

        if [[ ! -f "$series_logo" ]]; then
            log_info "  下载剧集徽标"
            download_logo "$tmdb_data" "$series_logo" &
            local series_logo_pid=$!
        else
            log_debug "  跳过（已有剧集徽标）"
        fi

        # 4.2 下载季级图片到季文件夹（每个季只下载一次）
        local season_poster="${season_dir}/season-poster.jpg"
        local season_banner="${season_dir}/season-banner.jpg"
        local season_fanart="${season_dir}/season-fanart.jpg"

        # 从 tmdb_data 中提取剧集 ID 和季号
        local show_id=$(echo "$tmdb_data" | jq -r '.id // empty')
        local season_int=$((10#$season))  # 去除前导零

        # 下载季海报（poster）
        local season_poster_path=$(echo "$tmdb_data" | jq -r '.season.poster_path // empty')
        if [[ ! -f "$season_poster" && -n "$season_poster_path" && "$season_poster_path" != "null" ]]; then
            log_info "  下载季海报 (Season $season)"
            local season_poster_url="https://image.tmdb.org/t/p/original${season_poster_path}"
            download_image_with_retry "$season_poster_url" "$season_poster" "季海报" &
            local season_poster_pid=$!
        else
            log_debug "  跳过（已有季海报或无季海报路径）"
        fi

        # 下载季横幅图（banner） - 使用 backdrop 作为横幅
        if [[ ! -f "$season_banner" && -n "$show_id" && "$show_id" != "null" ]]; then
            log_info "  下载季横幅图 (Season $season)"
            download_season_backdrop "$show_id" "$season_int" "$season_banner" &
            local season_banner_pid=$!
        else
            log_debug "  跳过（已有季横幅图或缺少剧集 ID）"
        fi

        # 下载季背景图（fanart） - 也使用 backdrop
        if [[ ! -f "$season_fanart" && -n "$show_id" && "$show_id" != "null" ]]; then
            log_info "  下载季背景图 (Season $season)"
            download_season_backdrop "$show_id" "$season_int" "$season_fanart" &
            local season_fanart_pid=$!
        else
            log_debug "  跳过（已有季背景图或缺少剧集 ID）"
        fi

        # 4.3 下载单集缩略图到单集文件旁边
        local episode_thumb="${strm_dir}/${strm_name}.jpg"
        if [[ ! -f "$episode_thumb" ]]; then
            log_info "  下载单集缩略图 (S${season}E${episode})"
            download_episode_thumb "$tmdb_data" "$episode_thumb" &
            local episode_thumb_pid=$!
        else
            log_debug "  跳过（已有单集缩略图）"
        fi

        # 等待所有后台下载任务完成
        wait 2>/dev/null || true

    else
        # 电影：单层级处理
        log_info "  [电影] 处理单层级 NFO 和图片"

        # 3.1 生成电影 NFO
        generate_movie_nfo "$tmdb_data" "$nfo_file"

        if [[ $? -ne 0 ]]; then
            log_error "  NFO 生成失败"
            return 1
        fi

        # 4. 下载图片
        local poster_file="${strm_dir}/poster.jpg"
        local fanart_file="${strm_dir}/fanart.jpg"
        local banner_file="${strm_dir}/banner.jpg"
        local logo_file="${strm_dir}/logo.png"

        # 并行下载图片（后台任务）
        if [[ ! -f "$poster_file" ]]; then
            log_info "  下载电影海报"
            download_poster "$tmdb_data" "$poster_file" &
            local poster_pid=$!
        else
            log_debug "  跳过（已有电影海报）"
        fi

        if [[ ! -f "$fanart_file" ]]; then
            log_info "  下载电影背景图"
            download_backdrop "$tmdb_data" "$fanart_file" &
            local fanart_pid=$!
        else
            log_debug "  跳过（已有电影背景图）"
        fi

        if [[ ! -f "$banner_file" ]]; then
            log_info "  下载电影横幅图"
            download_banner "$tmdb_data" "$banner_file" &
            local banner_pid=$!
        else
            log_debug "  跳过（已有电影横幅图）"
        fi

        if [[ ! -f "$logo_file" ]]; then
            log_info "  下载电影徽标"
            download_logo "$tmdb_data" "$logo_file" &
            local logo_pid=$!
        else
            log_debug "  跳过（已有电影徽标）"
        fi

        # 等待下载完成
        wait 2>/dev/null || true
    fi

    log_success "✅ 元数据刮削完成: $strm_file"
    return 0
}
