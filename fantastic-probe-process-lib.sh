#!/bin/bash

#==============================================================================
# ISO 文件处理核心库
# 功能：提供独立的文件处理函数，供 Cron 扫描器和实时监控器复用
# 作者：Fantastic-Probe Team
#==============================================================================

# 本文件仅包含函数定义，不直接执行
# 使用方式: source fantastic-probe-process-lib.sh

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

    # 通知 Emby 刷新媒体库（如果已启用）
    notify_emby_refresh "$json_file"

    return 0
}

#==============================================================================
# STRM 文件解析和处理模块（新增 - v3.2.0）
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

    # 1. 检查是否需要阶段1（媒体信息提取）
    local json_file="${strm_dir}/${strm_name}-mediainfo.json"
    if [[ ! -f "$json_file" ]]; then
        tasks="$tasks stage1"
        log_debug "    需要执行: 阶段1（媒体信息提取）"
    else
        log_debug "    跳过阶段1（已有 JSON）"
    fi

    # 2. 检查是否需要阶段2（NFO 生成）
    if [[ "${ENABLE_NFO:-true}" == "true" ]]; then
        local nfo_file="${strm_dir}/${strm_name}.nfo"
        if [[ ! -f "$nfo_file" ]]; then
            tasks="$tasks stage2_nfo"
            log_debug "    需要执行: 阶段2-NFO（NFO 生成）"
        else
            log_debug "    跳过 NFO 生成（已存在）"
        fi
    fi

    # 3. 检查是否需要下载图片
    if [[ "${DOWNLOAD_IMAGES:-true}" == "true" ]] && [[ "${ENABLE_NFO:-true}" == "true" ]]; then
        local needs_images=false

        # 对于电视剧，检查多层级图片
        if is_tv_show "$strm_name"; then
            local structure_info=$(analyze_tv_show_structure "$strm_file" 2>/dev/null)
            if [[ $? -eq 0 ]]; then
                local series_dir=$(echo "$structure_info" | cut -d'|' -f1)
                local season_dir=$(echo "$structure_info" | cut -d'|' -f2)

                # 检查剧集级图片
                if [[ ! -f "${series_dir}/poster.jpg" ]] || [[ ! -f "${series_dir}/fanart.jpg" ]]; then
                    needs_images=true
                fi

                # 检查季级图片
                if [[ ! -f "${season_dir}/season-poster.jpg" ]]; then
                    needs_images=true
                fi

                # 检查单集缩略图
                if [[ ! -f "${strm_dir}/${strm_name}.jpg" ]]; then
                    needs_images=true
                fi
            else
                # 目录结构分析失败，但仍需下载图片
                needs_images=true
            fi
        else
            # 对于电影，检查海报和背景图
            if [[ ! -f "${strm_dir}/${strm_name}-poster.jpg" ]] || \
               [[ ! -f "${strm_dir}/${strm_name}-fanart.jpg" ]]; then
                needs_images=true
            fi
        fi

        if [[ "$needs_images" == true ]]; then
            tasks="$tasks stage2_images"
            log_debug "    需要执行: 阶段2-图片（图片下载）"
        else
            log_debug "    跳过图片下载（已存在）"
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

    log_info "  开始远程分析 HTTP 媒体..."
    log_debug "  URL: ${url:0:80}..."
    log_debug "  参数: analyzeduration=$analyzeduration, probesize=$probesize, timeout=${timeout}s"

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
        return 1
    elif [[ $exit_code -ne 0 ]]; then
        log_error "  FFprobe 远程分析失败（退出码: $exit_code）"
        log_debug "  错误输出: $ffprobe_output"
        return 1
    fi

    # 验证输出有效性
    if [[ -z "$ffprobe_output" ]] || ! echo "$ffprobe_output" | jq -e '.streams' >/dev/null 2>&1; then
        log_error "  FFprobe 输出无效或为空"
        return 1
    fi

    log_success "  ✅ 远程媒体分析完成"

    echo "$ffprobe_output"
    return 0
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

    log_info "  开始分析本地媒体..."
    log_debug "  路径: $path"
    log_debug "  参数: analyzeduration=$analyzeduration, probesize=$probesize"

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
        return 1
    elif [[ $exit_code -ne 0 ]]; then
        log_error "  FFprobe 分析失败（退出码: $exit_code）"
        log_debug "  错误输出: $ffprobe_output"
        return 1
    fi

    # 验证输出有效性
    if [[ -z "$ffprobe_output" ]] || ! echo "$ffprobe_output" | jq -e '.streams' >/dev/null 2>&1; then
        log_error "  FFprobe 输出无效或为空"
        return 1
    fi

    log_success "  ✅ 本地媒体分析完成"

    echo "$ffprobe_output"
    return 0
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

    # 通知 Emby 刷新媒体库
    notify_emby_refresh "$json_file"

    return 0
}

#==============================================================================
# TMDB 元数据刮削模块（阶段2 - v3.2.0）
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

    # 提取 tmdbid（如果存在）
    local tmdbid=""
    if [[ "$filename" =~ \[tmdbid-([0-9]+)\] ]]; then
        tmdbid="${BASH_REMATCH[1]}"
        log_info "  ✅ 从文件名提取 TMDB ID: $tmdbid"
    fi

    # 提取年份（支持多种格式）
    local year=""
    if [[ "$filename" =~ \(([0-9]{4})\) ]] || [[ "$filename" =~ \.([0-9]{4})\. ]]; then
        year="${BASH_REMATCH[1]}"
        log_debug "  提取年份: $year"
    fi

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

    # 移除 tmdbid
    title=$(echo "$title" | sed -E 's/\s*-?\s*\[tmdbid-[0-9]+\]//g')

    # 移除年份
    title=$(echo "$title" | sed -E 's/\s*[\(\.]?[0-9]{4}[\)\.]?//g')

    # 移除季集信息
    title=$(echo "$title" | sed -E 's/[Ss][0-9]{1,2}[Ee][0-9]{1,2}.*//g')

    # 移除质量标签
    title=$(echo "$title" | sed -E 's/(1080p|720p|2160p|4K|BluRay|WEB-DL|HDTV|BDRip|DVDRip|x264|x265|HEVC).*//i')

    # 替换分隔符为空格
    title=$(echo "$title" | sed -E 's/[\.\-_]+/ /g')

    # 去除首尾空格
    title=$(echo "$title" | xargs)

    log_info "  解析结果: 标题='$title', 年份='$year', TMDB ID='$tmdbid', 季='$season', 集='$episode'"

    # 输出格式：title|year|tmdbid|season|episode
    echo "${title}|${year}|${tmdbid}|${season}|${episode}"
    return 0
}

#------------------------------------------------------------------------------
# URL 编码函数
#------------------------------------------------------------------------------

urlencode() {
    local string="$1"
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
    local title="$1"
    local year="${2:-}"
    local tmdb_id="${3:-}"
    local api_key="${TMDB_API_KEY}"
    local language="${TMDB_LANGUAGE:-zh-CN}"
    local timeout="${TMDB_TIMEOUT:-30}"

    if [[ -z "$api_key" ]]; then
        log_error "  TMDB API Key 未配置"
        return 1
    fi

    local tmdb_data=""

    # 如果有 tmdb_id，直接查询
    if [[ -n "$tmdb_id" ]]; then
        log_info "  使用 TMDB ID 查询: $tmdb_id"

        tmdb_data=$(curl -s --max-time "$timeout" \
            "https://api.themoviedb.org/3/movie/${tmdb_id}?api_key=${api_key}&language=${language}")

        if [[ $? -eq 0 ]] && echo "$tmdb_data" | jq -e '.id' >/dev/null 2>&1; then
            log_success "  ✅ TMDB 查询成功（ID: $tmdb_id）"
            echo "$tmdb_data"
            return 0
        else
            log_warn "  ⚠️  TMDB ID 查询失败，尝试搜索"
        fi
    fi

    # 搜索电影
    log_info "  搜索 TMDB 电影: $title${year:+ ($year)}"

    local encoded_title=$(urlencode "$title")
    local search_url="https://api.themoviedb.org/3/search/movie?api_key=${api_key}&language=${language}&query=${encoded_title}"

    if [[ -n "$year" ]]; then
        search_url="${search_url}&year=${year}"
    fi

    local search_result=$(curl -s --max-time "$timeout" "$search_url")

    if [[ $? -ne 0 ]]; then
        log_error "  TMDB API 请求失败"
        return 1
    fi

    # 提取第一个结果
    tmdb_data=$(echo "$search_result" | jq -r '.results[0] // empty')

    if [[ -z "$tmdb_data" || "$tmdb_data" == "null" ]]; then
        log_warn "  ⚠️  TMDB 未找到匹配结果: $title"
        return 1
    fi

    local found_title=$(echo "$tmdb_data" | jq -r '.title')
    local found_id=$(echo "$tmdb_data" | jq -r '.id')

    log_success "  ✅ TMDB 匹配成功: $found_title (ID: $found_id)"

    echo "$tmdb_data"
    return 0
}

#------------------------------------------------------------------------------
# 查询 TMDB 电视剧元数据
#------------------------------------------------------------------------------
# 参数：
#   $1: 标题
#   $2: 年份（可选）
#   $3: TMDB ID（可选）
#   $4: 季号（可选）
#   $5: 集号（可选）
# 返回：
#   输出：TMDB JSON 数据
#   退出码：0=成功，1=失败
#------------------------------------------------------------------------------

query_tmdb_tv() {
    local title="$1"
    local year="${2:-}"
    local tmdb_id="${3:-}"
    local season="${4:-}"
    local episode="${5:-}"
    local api_key="${TMDB_API_KEY}"
    local language="${TMDB_LANGUAGE:-zh-CN}"
    local timeout="${TMDB_TIMEOUT:-30}"

    if [[ -z "$api_key" ]]; then
        log_error "  TMDB API Key 未配置"
        return 1
    fi

    local show_data=""

    # 如果有 tmdb_id，直接查询
    if [[ -n "$tmdb_id" ]]; then
        log_info "  使用 TMDB ID 查询电视剧: $tmdb_id"

        show_data=$(curl -s --max-time "$timeout" \
            "https://api.themoviedb.org/3/tv/${tmdb_id}?api_key=${api_key}&language=${language}")

        if [[ $? -eq 0 ]] && echo "$show_data" | jq -e '.id' >/dev/null 2>&1; then
            log_success "  ✅ TMDB 查询成功（ID: $tmdb_id）"
        else
            log_warn "  ⚠️  TMDB ID 查询失败，尝试搜索"
            show_data=""
        fi
    fi

    # 如果没有数据，搜索
    if [[ -z "$show_data" ]]; then
        log_info "  搜索 TMDB 电视剧: $title${year:+ ($year)}"

        local encoded_title=$(urlencode "$title")
        local search_url="https://api.themoviedb.org/3/search/tv?api_key=${api_key}&language=${language}&query=${encoded_title}"

        if [[ -n "$year" ]]; then
            search_url="${search_url}&first_air_date_year=${year}"
        fi

        local search_result=$(curl -s --max-time "$timeout" "$search_url")

        if [[ $? -ne 0 ]]; then
            log_error "  TMDB API 请求失败"
            return 1
        fi

        show_data=$(echo "$search_result" | jq -r '.results[0] // empty')

        if [[ -z "$show_data" || "$show_data" == "null" ]]; then
            log_warn "  ⚠️  TMDB 未找到匹配结果: $title"
            return 1
        fi

        local found_title=$(echo "$show_data" | jq -r '.name')
        local found_id=$(echo "$show_data" | jq -r '.id')

        log_success "  ✅ TMDB 匹配成功: $found_title (ID: $found_id)"
    fi

    # 如果需要查询季和剧集详情
    if [[ -n "$season" && -n "$episode" ]]; then
        local show_id=$(echo "$show_data" | jq -r '.id')
        log_info "  查询季和剧集详情: S${season}E${episode}"

        # 查询季信息（用于生成 Season.nfo）
        local season_data=$(curl -s --max-time "$timeout" \
            "https://api.themoviedb.org/3/tv/${show_id}/season/${season}?api_key=${api_key}&language=${language}")

        if [[ $? -ne 0 ]] || ! echo "$season_data" | jq -e '.id' >/dev/null 2>&1; then
            log_warn "  ⚠️  季信息获取失败"
            season_data="{}"
        else
            log_success "  ✅ 季信息获取成功 (Season $season)"
        fi

        # 查询单集详情（用于生成单集 NFO）
        local episode_data=$(curl -s --max-time "$timeout" \
            "https://api.themoviedb.org/3/tv/${show_id}/season/${season}/episode/${episode}?api_key=${api_key}&language=${language}")

        if [[ $? -eq 0 ]] && echo "$episode_data" | jq -e '.id' >/dev/null 2>&1; then
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

    log_info "  生成电影 NFO: $output_file"

    # 提取字段
    local title=$(echo "$tmdb_data" | jq -r '.title // .original_title')
    local original_title=$(echo "$tmdb_data" | jq -r '.original_title // .title')
    local year=$(echo "$tmdb_data" | jq -r '.release_date // "unknown"' | cut -d'-' -f1)
    local plot=$(echo "$tmdb_data" | jq -r '.overview // ""')
    local rating=$(echo "$tmdb_data" | jq -r '.vote_average // 0')
    local tmdb_id=$(echo "$tmdb_data" | jq -r '.id')
    local release_date=$(echo "$tmdb_data" | jq -r '.release_date // ""')
    local runtime=$(echo "$tmdb_data" | jq -r '.runtime // 0')

    # 生成 NFO（Kodi/Emby 兼容格式）
    cat > "$output_file" << EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<movie>
    <title>$title</title>
    <originaltitle>$original_title</originaltitle>
    <year>$year</year>
    <plot>$plot</plot>
    <rating>$rating</rating>
    <tmdbid>$tmdb_id</tmdbid>
    <premiered>$release_date</premiered>
    <runtime>$runtime</runtime>
    <uniqueid type="tmdb" default="true">$tmdb_id</uniqueid>
</movie>
EOF

    if [[ $? -eq 0 ]]; then
        log_success "  ✅ NFO 文件生成成功"
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

    # 生成单集 NFO
    cat > "$output_file" << EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<episodedetails>
    <title>$episode_title</title>
    <showtitle>$show_title</showtitle>
    <season>$season_num</season>
    <episode>$episode_num</episode>
    <plot>$plot</plot>
    <aired>$air_date</aired>
    <uniqueid type="tmdb" default="true">$tmdb_id</uniqueid>
</episodedetails>
EOF

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

    log_info "  生成总剧集 NFO: $output_file"

    # 提取剧集基本信息
    local show_title=$(echo "$tmdb_data" | jq -r '.name // .original_name')
    local original_title=$(echo "$tmdb_data" | jq -r '.original_name // .name')
    local year=$(echo "$tmdb_data" | jq -r '.first_air_date // "" | split("-")[0]')
    local plot=$(echo "$tmdb_data" | jq -r '.overview // ""')
    local tmdb_id=$(echo "$tmdb_data" | jq -r '.id')
    local rating=$(echo "$tmdb_data" | jq -r '.vote_average // 0')
    local number_of_seasons=$(echo "$tmdb_data" | jq -r '.number_of_seasons // 0')
    local number_of_episodes=$(echo "$tmdb_data" | jq -r '.number_of_episodes // 0')
    local first_air_date=$(echo "$tmdb_data" | jq -r '.first_air_date // ""')

    # 提取类型（可能有多个）
    local genres=$(echo "$tmdb_data" | jq -r '.genres[]?.name' | head -5)

    # 生成总剧集 NFO
    cat > "$output_file" << EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<tvshow>
    <title>$show_title</title>
    <originaltitle>$original_title</originaltitle>
    <year>$year</year>
    <plot>$plot</plot>
    <rating>$rating</rating>
    <premiered>$first_air_date</premiered>
    <status>$(echo "$tmdb_data" | jq -r '.status // ""')</status>
    <studio>$(echo "$tmdb_data" | jq -r '.networks[0].name // ""')</studio>
    <mpaa>$(echo "$tmdb_data" | jq -r '.content_ratings.results[] | select(.iso_3166_1 == "US") | .rating // ""')</mpaa>
    <uniqueid type="tmdb" default="true">$tmdb_id</uniqueid>
    <episodefilecount>$number_of_episodes</episodefilecount>
    <seasoncount>$number_of_seasons</seasoncount>
EOF

    # 添加类型
    while IFS= read -r genre; do
        if [[ -n "$genre" ]]; then
            echo "    <genre>$genre</genre>" >> "$output_file"
        fi
    done <<< "$genres"

    # 结束标签
    echo "</tvshow>" >> "$output_file"

    if [[ $? -eq 0 ]]; then
        log_success "  ✅ 总剧集 NFO 生成成功"
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

download_poster() {
    local tmdb_data="$1"
    local output_file="$2"
    local timeout="${TMDB_TIMEOUT:-30}"
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

    # 调用 /images API 获取原语言图片
    local images_url="https://api.themoviedb.org/3/${media_type}/${tmdb_id}/images?api_key=${api_key}&include_image_language=${original_language},null"
    local images_data=$(curl -s --max-time "$timeout" "$images_url")

    if [[ $? -ne 0 ]]; then
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

    curl -s --max-time "$timeout" -o "$output_file" "$poster_url"

    if [[ $? -eq 0 && -f "$output_file" ]]; then
        log_success "  ✅ 海报下载完成（原语言）"
        return 0
    else
        log_error "  海报下载失败"
        rm -f "$output_file"
        return 1
    fi
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
    local timeout="${TMDB_TIMEOUT:-30}"
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

    # 调用 /images API 获取原语言图片
    local images_url="https://api.themoviedb.org/3/${media_type}/${tmdb_id}/images?api_key=${api_key}&include_image_language=${original_language},null"
    local images_data=$(curl -s --max-time "$timeout" "$images_url")

    if [[ $? -ne 0 ]]; then
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

    curl -s --max-time "$timeout" -o "$output_file" "$backdrop_url"

    if [[ $? -eq 0 && -f "$output_file" ]]; then
        log_success "  ✅ 背景图下载完成（原语言）"
        return 0
    else
        log_error "  背景图下载失败"
        rm -f "$output_file"
        return 1
    fi
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
    local timeout="${TMDB_TIMEOUT:-30}"

    # 提取单集缩略图路径（still_path）
    local still_path=$(echo "$tmdb_data" | jq -r '.episode.still_path // empty')

    if [[ -z "$still_path" || "$still_path" == "null" ]]; then
        log_warn "  ⚠️  未找到单集缩略图路径"
        return 1
    fi

    local thumb_url="https://image.tmdb.org/t/p/original${still_path}"

    log_info "  下载单集缩略图: $output_file"
    log_debug "  缩略图 URL: $thumb_url"

    curl -s --max-time "$timeout" -o "$output_file" "$thumb_url"

    if [[ $? -eq 0 && -f "$output_file" ]]; then
        log_success "  ✅ 单集缩略图下载完成"
        return 0
    else
        log_error "  单集缩略图下载失败"
        rm -f "$output_file"
        return 1
    fi
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
    if [[ "${ENABLE_NFO:-true}" != "true" ]]; then
        log_warn "  NFO 生成已禁用，跳过"
        return 0
    fi

    if [[ -z "${TMDB_API_KEY:-}" ]]; then
        log_warn "  TMDB API Key 未配置，跳过元数据刮削"
        return 0
    fi

    # 1. 从文件名提取信息
    local metadata
    metadata=$(extract_metadata_from_filename "$strm_name")

    local title=$(echo "$metadata" | cut -d'|' -f1)
    local year=$(echo "$metadata" | cut -d'|' -f2)
    local tmdb_id=$(echo "$metadata" | cut -d'|' -f3)
    local season=$(echo "$metadata" | cut -d'|' -f4)
    local episode=$(echo "$metadata" | cut -d'|' -f5)

    if [[ -z "$title" ]]; then
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
        tmdb_data=$(query_tmdb_tv "$title" "$year" "$tmdb_id" "$season" "$episode")
    else
        # 电影
        log_info "  识别为电影"
        tmdb_data=$(query_tmdb_movie "$title" "$year" "$tmdb_id")
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

        # 4. 下载图片（如果启用）
        if [[ "${DOWNLOAD_IMAGES:-true}" == "true" ]]; then
            # 4.1 下载剧集级图片到剧集根目录（只下载一次）
            local series_poster="${series_dir}/poster.jpg"
            local series_fanart="${series_dir}/fanart.jpg"

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

            # 4.2 下载季级图片到季文件夹（每个季只下载一次）
            local season_poster="${season_dir}/season-poster.jpg"
            local season_fanart="${season_dir}/season-fanart.jpg"

            # 从 tmdb_data 中提取季海报路径
            local season_poster_path=$(echo "$tmdb_data" | jq -r '.season.poster_path // empty')
            if [[ ! -f "$season_poster" && -n "$season_poster_path" && "$season_poster_path" != "null" ]]; then
                log_info "  下载季海报 (Season $season)"
                local season_poster_url="https://image.tmdb.org/t/p/original${season_poster_path}"
                curl -s --max-time "${TMDB_TIMEOUT:-30}" -o "$season_poster" "$season_poster_url" &
                local season_poster_pid=$!
            else
                log_debug "  跳过（已有季海报或无季海报路径）"
            fi

            # 季级背景图（可选，通常使用剧集级背景图）
            # 这里暂不下载季级独立背景图，使用剧集级背景图

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
        fi

    else
        # 电影：单层级处理
        log_info "  [电影] 处理单层级 NFO 和图片"

        # 3.1 生成电影 NFO
        generate_movie_nfo "$tmdb_data" "$nfo_file"

        if [[ $? -ne 0 ]]; then
            log_error "  NFO 生成失败"
            return 1
        fi

        # 4. 下载图片（如果启用）
        if [[ "${DOWNLOAD_IMAGES:-true}" == "true" ]]; then
            local poster_file="${strm_dir}/poster.jpg"
            local fanart_file="${strm_dir}/fanart.jpg"

            # 并行下载图片（后台任务）
            if [[ ! -f "$poster_file" ]]; then
                download_poster "$tmdb_data" "$poster_file" &
                local poster_pid=$!
            fi

            if [[ ! -f "$fanart_file" ]]; then
                download_backdrop "$tmdb_data" "$fanart_file" &
                local fanart_pid=$!
            fi

            # 等待下载完成
            wait 2>/dev/null || true
        fi
    fi

    log_success "✅ 元数据刮削完成: $strm_file"
    return 0
}
