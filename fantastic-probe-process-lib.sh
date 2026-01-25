#!/bin/bash

#==============================================================================
# ISO 文件处理核心库
# 功能：提供独立的文件处理函数，供 Cron 扫描器和实时监控器复用
# 作者：Fantastic-Probe Team
#==============================================================================

# 本文件仅包含函数定义，不直接执行
# 使用方式: source fantastic-probe-process-lib.sh

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

    return 0
}
