#!/bin/bash

#==============================================================================
# ISO 文件处理核心库
# 功能：提供独立的文件处理函数，供 Cron 扫描器复用
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
# 提取蓝光语言标签（bd_list_titles）
#==============================================================================

extract_bluray_language_tags() {
    local mount_point="$1"

    log_debug "  准备提取蓝光语言标签..."

    # 检查 bd_list_titles 是否可用
    if ! command -v bd_list_titles &> /dev/null; then
        log_warn "  ⚠️  bd_list_titles 未安装，跳过语言标签提取"
        log_warn "  安装命令: sudo apt-get install libbluray-bin"
        echo "{\"audio_languages\":[],\"subtitle_languages\":[],\"chapters\":0}"
        return 1
    fi

    # 检查是否为蓝光目录
    if [ ! -d "$mount_point/BDMV" ]; then
        log_debug "  非蓝光目录，跳过 bd_list_titles"
        echo "{\"audio_languages\":[],\"subtitle_languages\":[],\"chapters\":0}"
        return 1
    fi

    log_info "  执行 bd_list_titles 提取语言标签..."

    # 执行 bd_list_titles -l，忽略 stderr（BD-J 警告）
    local bd_output=$(bd_list_titles -l "$mount_point" 2>/dev/null)

    if [ -z "$bd_output" ]; then
        log_error "  ❌ bd_list_titles 输出为空"
        echo "{\"audio_languages\":[],\"subtitle_languages\":[],\"chapters\":0}"
        return 1
    fi

    # 使用 Python 解析输出（通过 stdin 传递，避免 heredoc 注入风险）
    local result=$(echo "$bd_output" | python3 << 'EOF'
import sys
import re
import json

# 从 stdin 读取 bd_list_titles 输出
content = sys.stdin.read()

# 找到最长标题（主标题）
max_duration = 0
max_index = None
chapters = 0

for match in re.finditer(r'index:\s*(\d+)\s+duration:\s*(\d+):(\d+):(\d+)\s+chapters:\s*(\d+)', content):
    index = int(match.group(1))
    h, m, s = int(match.group(2)), int(match.group(3)), int(match.group(4))
    chapter_count = int(match.group(5))
    duration = h * 3600 + m * 60 + s

    if duration > max_duration:
        max_duration = duration
        max_index = index
        chapters = chapter_count

if max_index is None:
    print(json.dumps({
        'audio_languages': [],
        'subtitle_languages': [],
        'chapters': 0
    }))
    sys.exit(0)

# 提取主标题区段
pattern = rf'index:\s*{max_index}\s.*?(?=index:\s*\d+|\Z)'
main_match = re.search(pattern, content, re.DOTALL)

audio_langs = []
subtitle_langs = []

if main_match:
    main_text = main_match.group(0)

    # 提取音频语言（必须是带缩进的行）
    aud_match = re.search(r'^\s+AUD:\s*(.+)', main_text, re.MULTILINE)
    if aud_match:
        audio_langs = aud_match.group(1).strip().split()

    # 提取字幕语言（必须是带缩进的行）
    pg_match = re.search(r'^\s+PG\s*:\s*(.+)', main_text, re.MULTILINE)
    if pg_match:
        subtitle_langs = pg_match.group(1).strip().split()

# 输出 JSON
result = {
    'audio_languages': audio_langs,
    'subtitle_languages': subtitle_langs,
    'chapters': chapters
}

print(json.dumps(result))
EOF
)

    if [ -z "$result" ]; then
        log_error "  ❌ 语言标签解析失败"
        echo "{\"audio_languages\":[],\"subtitle_languages\":[],\"chapters\":0}"
        return 1
    fi

    # 验证 JSON 格式
    if ! echo "$result" | jq -e . >/dev/null 2>&1; then
        log_error "  ❌ 语言标签 JSON 格式无效"
        echo "{\"audio_languages\":[],\"subtitle_languages\":[],\"chapters\":0}"
        return 1
    fi

    local audio_count=$(echo "$result" | jq '.audio_languages | length')
    local subtitle_count=$(echo "$result" | jq '.subtitle_languages | length')
    local chapter_count=$(echo "$result" | jq '.chapters')

    log_info "  ✅ 语言标签提取成功: ${audio_count} 音频, ${subtitle_count} 字幕, ${chapter_count} 章节"

    echo "$result"
    return 0
}

#==============================================================================
# 转换为 Emby MediaSourceInfo 格式
#==============================================================================

convert_to_emby_format() {
    local ffprobe_json="$1"
    local strm_file="$2"
    local iso_file_size="${3:-0}"
    local language_tags_json="${4:-{\"audio_languages\":[],\"subtitle_languages\":[],\"chapters\":0}}"

    echo "$ffprobe_json" | jq -c --arg strm_file "$strm_file" --arg iso_size "$iso_file_size" --argjson lang_tags "$language_tags_json" '
    # 安全数值转换函数：容错处理非法值
    def safe_number:
        if . == null or . == "" then null
        elif type == "number" then .
        elif type == "string" then (tonumber? // null)
        else null
        end;

    # 安全帧率转换函数：支持多种格式
    def safe_framerate:
        if . == null or . == "" or . == "0/0" then null
        elif (type == "number") then (. | floor)
        elif (contains("/")) then
            (split("/") |
             if length == 2 and (.[1] | safe_number) != null and (.[1] | safe_number) != 0 then
                 ((.[0] | safe_number) / (.[1] | safe_number) | floor)
             else null
             end)
        else
            # 纯数字字符串（如 "25"），DIY ISO 常见格式
            (safe_number | if . then (. | floor) else null end)
        end;

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
            "RunTimeTicks": ((.format.duration // "0" | safe_number // 0) * 10000000 | floor),
            "SupportsTranscoding": true,
            "SupportsDirectStream": true,
            "SupportsDirectPlay": true,
            "IsInfiniteStream": false,
            "RequiresOpening": false,
            "RequiresClosing": false,
            "RequiresLooping": false,
            "SupportsProbing": true,
            "MediaStreams": [
                .streams as $all_streams |
                .streams | to_entries[] |
                .key as $idx |
                .value |
                # 计算当前流在同类型中的索引
                (if .codec_type == "audio" then
                    [$all_streams[] | select(.codec_type == "audio") | .index] |
                    to_entries | map(select(.value == $all_streams[$idx].index)) | .[0].key
                 elif .codec_type == "subtitle" then
                    [$all_streams[] | select(.codec_type == "subtitle") | .index] |
                    to_entries | map(select(.value == $all_streams[$idx].index)) | .[0].key
                 else 0
                 end) as $type_index |
                {
                    "Codec": (.codec_name | codec_upper),
                    "Language": (
                        if .codec_type == "video" then null
                        elif .codec_type == "audio" then
                            # 从 bd_list_titles 获取音频语言，否则使用 "und"
                            ($lang_tags.audio_languages[$type_index] // .tags.language // "und")
                        elif .codec_type == "subtitle" then
                            # 从 bd_list_titles 获取字幕语言，否则使用 "und"
                            ($lang_tags.subtitle_languages[$type_index] // .tags.language // "und")
                        else
                            (.tags.language // null)
                        end
                    ),
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
                    "BitRate": (.bit_rate | safe_number),
                    "BitDepth": (.bits_per_raw_sample | safe_number),
                    "RefFrames": (.refs | safe_number),
                    "IsDefault": (.disposition.default == 1),
                    "IsForced": (.disposition.forced == 1),
                    "IsHearingImpaired": (
                        if .codec_type == "subtitle" and .tags.title then
                            (.tags.title | test("(?i)sdh|hearing"))
                        else
                            (.disposition.hearing_impaired == 1)
                        end
                    ),
                    "Height": (.height | safe_number),
                    "Width": (.width | safe_number),
                    "AverageFrameRate": (.avg_frame_rate | safe_framerate),
                    "RealFrameRate": (.r_frame_rate | safe_framerate),
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
                    "Level": (.level | safe_number),
                    "IsAnamorphic": false,
                    "ExtendedVideoType": (
                        if .codec_type == "video" then
                            if video_range == "DolbyVision" then "DolbyVision"
                            elif video_range == "HDR10" then "HDR10"
                            elif video_range == "HLG" then "HLG"
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
                    "Channels": (.channels | safe_number),
                    "SampleRate": (.sample_rate | safe_number),
                    "AttachmentSize": 0,
                    "SubtitleLocationType": (if .codec_type == "subtitle" then "InternalStream" else null end)
                } | with_entries(select(.value != null))
            ],
            "Formats": [],
            "Bitrate": (.format.bit_rate | safe_number),
            "RequiredHttpHeaders": {},
            "AddApiKeyToDirectStreamUrl": false,
            "ReadAtNativeFramerate": false
        },
        "Chapters": [
            ((.chapters // []) | to_entries[] |
            {
                "StartPositionTicks": (.value.start_time // "0" | safe_number // 0 | . * 10000000 | floor),
                "Name": (.value.tags.title // ("Chapter " + ((.key + 1) | tostring | if length == 1 then ("0" + .) else . end))),
                "MarkerType": "Chapter",
                "ChapterIndex": .key
            })
        ]
    }]
    ' 2>&1  # 临时改为显示错误，用于诊断 JSON 转换失败问题
}

# 临时诊断函数：保存失败的 ffprobe 输出
debug_save_ffprobe() {
    local ffprobe_output="$1"
    local strm_file="$2"
    local timestamp=$(date +%s)
    local debug_file="/tmp/failed-ffprobe-${timestamp}.json"
    echo "$ffprobe_output" > "$debug_file"
    log_error "已保存失败的 ffprobe 输出: $debug_file"
    log_error "文件路径: $strm_file"
}

#==============================================================================
# 验证媒体时长是否有效
#==============================================================================

validate_media_duration() {
    local ffprobe_json="$1"
    local min_duration=1800  # 30 分钟（硬编码）

    # 从 ffprobe JSON 中提取 duration
    local duration
    duration=$(echo "$ffprobe_json" | jq -r '.format.duration // "0"' 2>/dev/null)

    # 转换为整数（去除小数部分）
    duration=$(echo "$duration" | awk '{print int($1)}')

    if [ -z "$duration" ] || [ "$duration" = "null" ] || [ "$duration" -eq 0 ]; then
        log_warn "  ⚠️  媒体时长无效或为空"
        return 1  # 无效
    fi

    if [ "$duration" -lt "$min_duration" ]; then
        log_warn "  ⚠️  媒体时长过短: ${duration}秒 < ${min_duration}秒（30分钟）"
        return 1  # 无效
    fi

    log_info "  ✅ 媒体时长有效: ${duration}秒"
    return 0  # 有效
}

#==============================================================================
# 通过文件路径查找 Emby Item ID
#==============================================================================

find_emby_item_by_path() {
    local strm_file="$1"
    local emby_url="${EMBY_URL}"
    local api_key="${EMBY_API_KEY}"

    # 检查是否启用 Emby
    if [ "${EMBY_ENABLED:-false}" != "true" ]; then
        log_debug "  Emby 集成未启用，跳过查找"
        return 1
    fi

    # 验证配置
    if [ -z "$emby_url" ] || [ -z "$api_key" ]; then
        log_warn "  ⚠️  Emby 配置不完整，跳过查找"
        return 1
    fi

    # 移除 URL 末尾的斜杠
    emby_url="${emby_url%/}"

    # URL 编码路径（简单处理，仅处理空格）
    local encoded_path=$(echo "$strm_file" | sed 's/ /%20/g')

    log_debug "  查找 Emby Item: $strm_file"

    # 调用 Emby API 查找 Item
    local response
    local http_code

    if ! command -v curl &> /dev/null; then
        log_warn "  ⚠️  curl 命令不可用，无法查找 Emby Item"
        return 1
    fi

    response=$(curl -s -w "\n%{http_code}" --max-time 10 \
        -X GET "${emby_url}/Items?Path=${encoded_path}&Fields=Path&api_key=${api_key}" \
        2>&1)

    http_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | head -n -1)

    if [ "$http_code" != "200" ]; then
        log_warn "  ⚠️  Emby API 查找失败（HTTP $http_code）"
        return 1
    fi

    # 提取 Item ID
    local item_id
    item_id=$(echo "$body" | jq -r '.Items[0].Id // empty' 2>/dev/null)

    if [ -z "$item_id" ] || [ "$item_id" = "null" ]; then
        log_debug "  未在 Emby 中找到对应的 Item"
        return 1
    fi

    log_debug "  找到 Emby Item ID: $item_id"
    echo "$item_id"
    return 0
}

#==============================================================================
# 删除 Emby Item（数据库记录）
#==============================================================================

delete_emby_item() {
    local item_id="$1"
    local emby_url="${EMBY_URL}"
    local api_key="${EMBY_API_KEY}"

    # 移除 URL 末尾的斜杠
    emby_url="${emby_url%/}"

    log_info "  🗑️  删除 Emby 索引记录: $item_id"

    # 调用 Emby DELETE API
    local response
    local http_code

    response=$(curl -s -w "\n%{http_code}" --max-time 10 \
        -X DELETE "${emby_url}/Items?Ids=${item_id}&api_key=${api_key}" \
        2>&1)

    http_code=$(echo "$response" | tail -1)

    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        log_success "  ✅ Emby 索引记录已删除（HTTP $http_code）"
        return 0
    else
        log_error "  ❌ Emby 删除失败（HTTP $http_code）"
        log_debug "  响应: $(echo "$response" | head -n -1)"
        return 1
    fi
}

#==============================================================================
# 删除无效媒体（Emby 索引 + 文件夹）
#==============================================================================

delete_invalid_media() {
    local strm_file="$1"
    local reason="${2:-未知原因}"

    # 检查是否启用自动删除
    if [ "${EMBY_DELETE_INVALID_ITEMS:-false}" != "true" ]; then
        log_debug "  无效媒体自动删除功能未启用，跳过删除"
        return 0
    fi

    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_warn "🗑️  检测到无效媒体，开始自动删除流程"
    log_warn "  文件: $strm_file"
    log_warn "  原因: $reason"
    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 获取文件夹路径
    local folder_path
    folder_path=$(dirname "$strm_file")

    # 步骤 1：删除 Emby 索引（如果启用了 Emby）
    if [ "${EMBY_ENABLED:-false}" = "true" ]; then
        log_info "  步骤 1/2：删除 Emby 索引记录"

        local item_id
        item_id=$(find_emby_item_by_path "$strm_file")

        if [ -n "$item_id" ] && [ "$item_id" != "null" ]; then
            if delete_emby_item "$item_id"; then
                log_success "  ✅ Emby 索引删除成功"
            else
                log_warn "  ⚠️  Emby 索引删除失败，但继续删除文件"
            fi
        else
            log_info "  ℹ️  未在 Emby 中找到对应项目，跳过 Emby 删除"
        fi
    else
        log_info "  ℹ️  Emby 未启用，跳过 Emby 索引删除"
    fi

    # 步骤 2：删除文件系统中的文件夹
    log_info "  步骤 2/2：删除文件夹及所有内容"
    log_info "  文件夹: $folder_path"

    if [ ! -d "$folder_path" ]; then
        log_error "  ❌ 文件夹不存在: $folder_path"
        return 1
    fi

    # 记录将要删除的内容（用于审计）
    local file_count
    file_count=$(find "$folder_path" -type f 2>/dev/null | wc -l | tr -d ' ')

    log_info "  包含 $file_count 个文件"

    # 执行删除
    if rm -rf "$folder_path" 2>/dev/null; then
        log_success "  ✅ 文件夹删除成功: $folder_path"
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "🗑️  无效媒体删除完成"
        log_success "  原因: $reason"
        log_success "  已删除: $folder_path"
        log_success "  文件数: $file_count"
        log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return 0
    else
        log_error "  ❌ 文件夹删除失败: $folder_path"
        log_error "  可能的原因: 权限不足或文件正在使用"
        return 1
    fi
}

#==============================================================================
# 处理单个 ISO strm 文件（完整流程）
#==============================================================================

process_iso_strm_full() {
    local strm_file="$1"
    local strm_dir="$(dirname "$strm_file")"
    local strm_name="$(basename "$strm_file" .iso.strm)"

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

    # 提取蓝光语言标签（需要挂载 ISO）
    local language_tags_json="{\"audio_languages\":[],\"subtitle_languages\":[],\"chapters\":0}"

    if [ "$iso_type" = "bluray" ]; then
        log_info "  挂载 ISO 以提取语言标签..."

        local mount_point="/tmp/bd-lang-$$"
        local mount_success=false

        # 创建挂载点
        if sudo mkdir -p "$mount_point" 2>/dev/null; then
            # 尝试挂载
            if sudo mount -o loop,ro "$iso_path" "$mount_point" 2>/dev/null; then
                mount_success=true
                log_info "  ✅ ISO 挂载成功"

                # 提取语言标签
                language_tags_json=$(extract_bluray_language_tags "$mount_point")

                # 立即卸载
                sudo umount "$mount_point" 2>/dev/null || true
                sudo rmdir "$mount_point" 2>/dev/null || true

                log_info "  ✅ ISO 已卸载"
            else
                log_warn "  ⚠️  ISO 挂载失败，跳过语言标签提取"
                sudo rmdir "$mount_point" 2>/dev/null || true
            fi
        else
            log_warn "  ⚠️  创建挂载点失败，跳过语言标签提取"
        fi
    fi

    # 验证媒体时长
    if ! validate_media_duration "$ffprobe_output"; then
        log_error "媒体时长无效: $strm_file"

        # 触发自动删除（如果启用）
        delete_invalid_media "$strm_file" "媒体时长无效（< 30 分钟）"

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

    # 转换为 Emby 格式（合并语言标签）
    local emby_json
    emby_json=$(convert_to_emby_format "$ffprobe_output" "$strm_file" "$iso_size" "$language_tags_json")

    if [ -z "$emby_json" ]; then
        # 保存失败的 ffprobe 输出用于诊断
        debug_save_ffprobe "$ffprobe_output" "$strm_file"
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
