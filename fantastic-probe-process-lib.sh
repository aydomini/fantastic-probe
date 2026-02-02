#!/bin/bash

#==============================================================================
# Fantastic-Probe Core Library
# Provides standalone media processing functions for Cron scanner
#==============================================================================

#==============================================================================
# Dependency Check Functions
#==============================================================================

check_dependencies() {
    local missing=()
    local optional_missing=()

    if ! command -v python3 &> /dev/null; then
        missing+=("python3 (bd_list_titles 输出解析必需)")
    fi

    if ! command -v jq &> /dev/null; then
        missing+=("jq (JSON 处理必需)")
    fi

    if ! command -v sqlite3 &> /dev/null; then
        missing+=("sqlite3 (失败记录数据库必需)")
    fi

    if ! command -v bd_list_titles &> /dev/null; then
        missing+=("bd_list_titles (蓝光语言标签提取必需，安装 libbluray-bin)")
    fi

    if ! command -v ffprobe &> /dev/null; then
        optional_missing+=("ffprobe (媒体信息提取必需，安装 ffmpeg)")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "❌ 缺少必需依赖："
        for dep in "${missing[@]}"; do
            log_error "   - $dep"
        done
        return 1
    fi

    if [ ${#optional_missing[@]} -gt 0 ]; then
        log_warn "⚠️  缺少可选依赖："
        for dep in "${optional_missing[@]}"; do
            log_warn "   - $dep"
        done
        log_warn "建议安装以确保完整功能"
    fi

    return 0
}

show_dependency_status() {
    local missing_deps=()

    if ! command -v python3 &> /dev/null; then
        missing_deps+=("python3 - bd_list_titles 输出解析")
    fi

    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq - JSON 处理")
    fi

    if ! command -v sqlite3 &> /dev/null; then
        missing_deps+=("sqlite3 - 失败记录数据库")
    fi

    if ! command -v bd_list_titles &> /dev/null; then
        missing_deps+=("bd_list_titles - 蓝光语言标签提取")
    fi

    if ! command -v ffprobe &> /dev/null; then
        missing_deps+=("ffprobe - 媒体信息提取")
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "📦 依赖状态"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""

        for dep in "${missing_deps[@]}"; do
            echo "   ❌ $dep"
            echo "      状态: 未安装"
        done

        echo ""
    fi
}

check_single_dep() {
    local cmd=$1
    local desc=$2

    if command -v "$cmd" &> /dev/null; then
        local version=$("$cmd" --version 2>/dev/null | head -1 || echo "已安装")
        echo "   ✅ $cmd - $desc"
        echo "      版本: $version"
    else
        echo "   ❌ $cmd - $desc"
        echo "      状态: 未安装"
    fi
}

#==============================================================================
# Notify Emby to Refresh Media Library
#==============================================================================

notify_emby_refresh() {
    local json_file="$1"

    if [ "${EMBY_ENABLED:-false}" != "true" ]; then
        log_debug "  Emby 集成未启用，跳过通知"
        return 0
    fi

    if [ -z "${EMBY_URL:-}" ] || [ -z "${EMBY_API_KEY:-}" ]; then
        log_warn "  ⚠️  Emby 配置不完整（缺少 URL 或 API Key），跳过通知"
        return 0
    fi

    if ! command -v curl &> /dev/null; then
        log_warn "  ⚠️  curl 命令不可用，无法通知 Emby"
        return 0
    fi

    local timeout="${EMBY_NOTIFY_TIMEOUT:-5}"
    local emby_url="${EMBY_URL}"
    local api_key="${EMBY_API_KEY}"

    emby_url="${emby_url%/}"

    log_info "  📡 通知 Emby 刷新媒体库..."
    log_debug "  Emby URL: $emby_url"

    (
        local response
        local http_code

        response=$(curl -s -w "\n%{http_code}" \
            --max-time "$timeout" \
            -X POST "${emby_url}/Library/Refresh" \
            -H "X-Emby-Token: ${api_key}" \
            -H "Content-Type: application/json" \
            -d '{}' 2>&1)

        http_code=$(echo "$response" | tail -1)

        if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
            log_success "  ✅ Emby 媒体库刷新请求已发送（HTTP $http_code）"
        else
            log_warn "  ⚠️  Emby API 调用失败（HTTP $http_code）"
            log_debug "  响应: $(echo "$response" | head -n -1)"
        fi
    ) &

    return 0
}

#==============================================================================
# Check Disk Space
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
# Detect FUSE Mount Points
#==============================================================================

is_fuse_mount() {
    local iso_path="$1"

    if echo "$iso_path" | grep -qE "(pan_115|alist|clouddrive|rclone|strm_cloud|webdav|davfs)"; then
        log_debug "  检测到 FUSE 挂载路径（路径匹配）"
        return 0
    fi

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
# Smart ISO Type Detection
#==============================================================================

detect_iso_type() {
    local iso_path="$1"
    local strm_file="${2:-}"

    log_debug "  智能检测 ISO 类型（无需 mount）..."

    local iso_type=""
    local filename=""

    if [ -n "$strm_file" ]; then
        filename=$(basename "$strm_file" .iso.strm)
    else
        filename=$(basename "$iso_path" .iso)
    fi

    log_debug "  文件名: $filename"

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
# Extract Media Info (ffprobe with smart retry)
#==============================================================================

extract_mediainfo() {
    local iso_path="$1"
    local iso_type="$2"

    log_debug "  准备提取媒体信息（协议: ${iso_type:-未知}）..."

    if [ -z "$iso_type" ]; then
        log_warn "  ISO 类型未知，使用默认值 bluray..."
        iso_type="bluray"
    fi

    log_info "  尝试 ${iso_type} 协议..."
    local ffprobe_json=""
    local retry_count=0
    local max_retries=3

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

        # Note: -playlist parameter removed, let ffprobe auto-select
        # Duration issues corrected by bd_list_titles duration override
        local ffprobe_opts="-v error -print_format json -show_format -show_streams -show_chapters -protocol_whitelist file,${iso_type}"

        local ffprobe_stderr=$(mktemp)
        ffprobe_json=$(timeout "$FFPROBE_TIMEOUT" "$FFPROBE" $ffprobe_opts \
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

        # Note: -playlist parameter removed, let ffprobe auto-select
        local ffprobe_opts="-v error -print_format json -show_format -show_streams -show_chapters -protocol_whitelist file,${fallback_type}"

        local ffprobe_stderr=$(mktemp)
        ffprobe_json=$(timeout "$FFPROBE_TIMEOUT" "$FFPROBE" $ffprobe_opts \
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
# Extract Blu-ray Language Tags (bd_list_titles)
#==============================================================================

extract_bluray_language_tags() {
    local mount_point="$1"
    local output_file="${2:-}"

    log_debug "  准备提取蓝光语言标签..."

    if ! command -v bd_list_titles &> /dev/null; then
        log_warn "  ⚠️  bd_list_titles 未安装，跳过语言标签提取"
        log_warn "  安装命令: sudo apt-get install libbluray-bin"
        echo "{\"main_title_index\":null,\"main_title_duration\":0,\"audio_languages\":[],\"subtitle_languages\":[],\"chapters\":0}"
        return 1
    fi

    if [ ! -d "$mount_point/BDMV" ]; then
        log_info "  ⚠️  非蓝光目录（无 BDMV 文件夹），跳过 bd_list_titles"
        echo "{\"main_title_index\":null,\"main_title_duration\":0,\"audio_languages\":[],\"subtitle_languages\":[],\"chapters\":0}"
        return 1
    fi

    log_debug "  执行 bd_list_titles 提取语言标签..."

    # Execute bd_list_titles -l (filter BD-J warnings)
    local bd_error_file="/tmp/bd-error-$$.txt"
    local bd_output=$(bd_list_titles -l "$mount_point" 2>"$bd_error_file")

    # Filter out BD-J warnings, keep only real errors
    local bd_filtered_errors="/tmp/bd-filtered-$$.txt"
    grep -v "BD-J check" "$bd_error_file" > "$bd_filtered_errors" 2>/dev/null || true

    if [ -s "$bd_filtered_errors" ]; then
        log_warn "  ⚠️  bd_list_titles 有错误输出:"
        head -5 "$bd_filtered_errors" | while read line; do log_warn "    $line"; done
    fi
    rm -f "$bd_error_file" "$bd_filtered_errors"

    if [ -z "$bd_output" ]; then
        log_error "  ❌ bd_list_titles 输出为空"
        echo "{\"main_title_index\":null,\"main_title_duration\":0,\"audio_languages\":[],\"subtitle_languages\":[],\"chapters\":0}"
        return 1
    fi

    log_debug "  📋 bd_list_titles 输出前 5 行:"
    echo "$bd_output" | head -5 | while read line; do log_debug "    $line"; done

    # Parse output with Python (via temp script + pipe to avoid heredoc stdin conflict)
    local python_script="/tmp/bd-parse-$$.py"
    cat > "$python_script" << 'PYTHON_SCRIPT'
import sys
import re
import json

content = sys.stdin.read()

# Find longest title (main title)
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
        'main_title_index': None,
        'main_title_duration': 0,
        'audio_languages': [],
        'subtitle_languages': [],
        'chapters': 0
    }))
    sys.exit(0)

# Extract main title section
pattern = rf'index:\s*{max_index}\s.*?(?=index:\s*\d+|\Z)'
main_match = re.search(pattern, content, re.DOTALL)

audio_langs = []
subtitle_langs = []

if main_match:
    main_text = main_match.group(0)

    # Extract audio languages (must be indented lines)
    aud_match = re.search(r'^\s+AUD:\s*(.+)', main_text, re.MULTILINE)
    if aud_match:
        audio_langs = aud_match.group(1).strip().split()

    # Extract subtitle languages (must be indented lines)
    pg_match = re.search(r'^\s+PG\s*:\s*(.+)', main_text, re.MULTILINE)
    if pg_match:
        subtitle_langs = pg_match.group(1).strip().split()

# Output JSON (compact format, no indent)
result = {
    'main_title_index': max_index,
    'main_title_duration': max_duration,
    'audio_languages': audio_langs,
    'subtitle_languages': subtitle_langs,
    'chapters': chapters
}

import os
output_file = os.environ.get('LANG_TAGS_OUTPUT_FILE')
json_str = json.dumps(result, separators=(',', ':'))

if output_file:
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(json_str)
else:
    print(json_str)
PYTHON_SCRIPT

    # Pass data to Python via pipe (use printf to avoid echo escape issues)
    local python_error_file="/tmp/python-error-$$.txt"
    local result

    if [ -n "$output_file" ]; then
        printf '%s\n' "$bd_output" | LANG_TAGS_OUTPUT_FILE="$output_file" python3 "$python_script" 2>"$python_error_file"
        local parse_exit_code=$?

        if [ $parse_exit_code -eq 0 ] && [ -f "$output_file" ]; then
            result=$(cat "$output_file")
        else
            result=""
        fi
    else
        result=$(printf '%s\n' "$bd_output" | python3 "$python_script" 2>"$python_error_file")
        local parse_exit_code=$?
    fi

    rm -f "$python_script"

    if [ $parse_exit_code -ne 0 ]; then
        log_error "  ❌ Python 解析脚本执行失败（退出码: $parse_exit_code）"
        if [ -s "$python_error_file" ]; then
            log_error "  Python 错误详情:"
            head -5 "$python_error_file" | while read line; do log_error "    $line"; done
        fi
        rm -f "$python_error_file"
        echo "{\"audio_languages\":[],\"subtitle_languages\":[],\"chapters\":0}"
        return 1
    fi

    rm -f "$python_error_file"

    if [ -z "$result" ]; then
        log_error "  ❌ 语言标签解析失败（输出为空）"
        echo "{\"audio_languages\":[],\"subtitle_languages\":[],\"chapters\":0}"
        return 1
    fi

    if ! echo "$result" | jq -e . >/dev/null 2>&1; then
        log_error "  ❌ 语言标签 JSON 格式无效"
        log_error "  原始输出: $result"
        echo "{\"audio_languages\":[],\"subtitle_languages\":[],\"chapters\":0}"
        return 1
    fi

    local audio_count=$(echo "$result" | jq '.audio_languages | length')
    local subtitle_count=$(echo "$result" | jq '.subtitle_languages | length')
    local chapter_count=$(echo "$result" | jq '.chapters')

    log_debug "  调试: 语言标签解析完成 - ${audio_count} 音频, ${subtitle_count} 字幕, ${chapter_count} 章节"

    echo "$result"
    return 0
}

#==============================================================================
# Convert to Emby MediaSourceInfo Format
#==============================================================================

convert_to_emby_format() {
    local ffprobe_json="$1"
    local strm_file="$2"
    local iso_file_size="${3:-0}"
    local iso_type="${4:-unknown}"

    # Use fixed path temp file (created by caller)
    local lang_tags_file="/tmp/lang-tags-$$.json"

    if [ ! -f "$lang_tags_file" ]; then
        log_warn "  ⚠️  语言标签临时文件不存在: $lang_tags_file"
        echo '{"main_title_index":null,"main_title_duration":0,"audio_languages":[],"subtitle_languages":[],"chapters":0}' > "$lang_tags_file"
    fi

    # Check if strict filtering needed (Blu-ray with language tags)
    local enable_strict_filter="false"
    if [ "$iso_type" = "bluray" ]; then
        local lang_audio_count=$(jq -r '.audio_languages | length' "$lang_tags_file" 2>/dev/null || echo "0")
        if [ "$lang_audio_count" -gt 0 ]; then
            enable_strict_filter="true"
        fi
    fi

    # Use temp file to capture jq errors
    local jq_error_file="/tmp/jq-error-$$.txt"
    local jq_output

    jq_output=$(echo "$ffprobe_json" | jq -c --arg strm_file "$strm_file" --arg iso_size "$iso_file_size" --arg enable_strict_filter "$enable_strict_filter" --slurpfile lang_tags "$lang_tags_file" '
    # Safe number conversion: fault-tolerant for illegal values
    def safe_number:
        if . == null or . == "" then null
        elif type == "number" then .
        elif type == "string" then (tonumber? // null)
        else null
        end;

    # Safe framerate conversion: supports multiple formats
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
            # Pure number string (e.g. "25"), common in DIY ISOs
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
        # Priority 1: Check side_data for DOVI configuration (universal fallback)
        if .color_transfer == "smpte2084" and .side_data_list then
            ([.side_data_list[] | select(.side_data_type == "DOVI configuration record")] | .[0]) as $dovi |
            if $dovi then
                # Extract Dolby Vision Profile if present
                if $dovi.dv_profile then
                    "DolbyVision Profile " + ($dovi.dv_profile | tostring)
                else
                    "DolbyVision"
                end
            # Detect HDR10+
            elif ([.side_data_list[] | select(.side_data_type == "HDR10+ metadata")] | length > 0) then
                "HDR10+"
            else
                "HDR10"
            end
        # Priority 2: Check MP4/MKV codec_tag_string (direct video files)
        elif (.codec_tag_string // "" | test("^dv(he|h1|av|a1)$")) then
            # Confirm Dolby Vision, try to extract Profile info
            if .side_data_list then
                ([.side_data_list[] | select(.side_data_type == "DOVI configuration record")] | .[0]) as $dovi |
                if $dovi and $dovi.dv_profile then
                    "DolbyVision Profile " + ($dovi.dv_profile | tostring)
                else
                    "DolbyVision"
                end
            else
                # Even without side_data, codec_tag confirms Dolby Vision
                "DolbyVision"
            end
        # Priority 3: Other HDR types
        elif .color_transfer == "smpte2084" then
            "HDR10"
        elif .color_transfer == "arib-std-b67" then "HLG"
        else "SDR"
        end;

    # Calculate video track weight (resolution × framerate)
    def video_weight:
        ((.width // 1920) * (.height // 1080) * ((.avg_frame_rate // "24/1" | safe_framerate) // 24));

    # Pre-calculate: total bitrate and per-type bitrate sums
    # Bitrate fallback: if format.bit_rate missing, calculate from file size
    (.format.bit_rate | safe_number) as $format_bitrate |
    (.format.duration | safe_number) as $duration |
    ($iso_size | tonumber) as $file_size |
    (if $format_bitrate and $format_bitrate > 0 then
        $format_bitrate
     elif $file_size > 0 and $duration > 0 then
        (($file_size * 8) / $duration | floor)
     else
        null
     end) as $total_bitrate |
    ([.streams[] | select(.codec_type == "audio") | (.bit_rate | safe_number // 0)] | add // 0) as $audio_bitrate_sum |
    ([.streams[] | select(.codec_type == "subtitle") | (.bit_rate | safe_number // 0)] | add // 0) as $subtitle_bitrate_sum |
    # Calculate total video bitrate (subtract audio and subtitle from total)
    (if $total_bitrate then ($total_bitrate - $audio_bitrate_sum - $subtitle_bitrate_sum) else null end) as $video_bitrate_total |
    # Count video tracks and their weights
    ([.streams[] | select(.codec_type == "video") | {index: .index, weight: video_weight}]) as $video_tracks |
    ([.streams[] | select(.codec_type == "video") | video_weight] | add // 1) as $video_weight_sum |
    # Count video streams (for Dolby Vision dual-layer detection)
    ([.streams[] | select(.codec_type == "video")] | length) as $video_stream_count |
    ([.streams[] | select(.codec_type == "video" and .color_transfer == "smpte2084")] | length) as $hdr_video_count |
    # BDMV dual-layer Dolby Vision global detection (ISO primary use case)
    (if $video_stream_count >= 2 and
        $hdr_video_count >= 2 and
        (.streams[0].codec_tag_string == "HDMV") then
        "DolbyVision Profile 7"
     else
        null
     end) as $bdmv_dv_detected |

    [{
        "MediaSourceInfo": {
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
                # Calculate language tag array lengths
                ($lang_tags[0].audio_languages // [] | length) as $audio_lang_count |
                ($lang_tags[0].subtitle_languages // [] | length) as $subtitle_lang_count |
                # Parse strict filter flag
                ($enable_strict_filter == "true") as $strict_filter |
                .streams | to_entries[] |
                .key as $idx |
                .value |
                # Calculate current stream index within same type
                (if .codec_type == "audio" then
                    [$all_streams[] | select(.codec_type == "audio") | .index] |
                    to_entries | map(select(.value == $all_streams[$idx].index)) | .[0].key
                 elif .codec_type == "subtitle" then
                    [$all_streams[] | select(.codec_type == "subtitle") | .index] |
                    to_entries | map(select(.value == $all_streams[$idx].index)) | .[0].key
                 else 0
                 end) as $type_index |
                # Filter logic:
                # - If strict filter enabled (Blu-ray with language tags): only output streams with language tags
                # - Otherwise (DVD or no language tags): keep all streams
                select(
                    if .codec_type == "video" then true
                    elif $strict_filter == false then true
                    elif .codec_type == "audio" then $type_index < $audio_lang_count
                    elif .codec_type == "subtitle" then $type_index < $subtitle_lang_count
                    else true
                    end
                ) |
                {
                    "Codec": (.codec_name | codec_upper),
                    "Language": (
                        if .codec_type == "video" then null
                        elif .codec_type == "audio" then
                            # Get audio language from bd_list_titles, otherwise use "und"
                            ($lang_tags[0].audio_languages[$type_index] // .tags.language // "und")
                        elif .codec_type == "subtitle" then
                            # Get subtitle language from bd_list_titles, otherwise use "und"
                            ($lang_tags[0].subtitle_languages[$type_index] // .tags.language // "und")
                        else
                            (.tags.language // null)
                        end
                    ),
                    "DisplayLanguage": (
                        if .codec_type == "video" then null
                        elif .codec_type == "audio" then
                            # Get audio language from bd_list_titles and convert to display name
                            (($lang_tags[0].audio_languages[$type_index] // .tags.language // "und") | lang_code)
                        elif .codec_type == "subtitle" then
                            # Get subtitle language from bd_list_titles and convert to display name
                            (($lang_tags[0].subtitle_languages[$type_index] // .tags.language // "und") | lang_code)
                        else null
                        end
                    ),
                    "ColorTransfer": (if .codec_type == "video" then .color_transfer else null end),
                    "ColorPrimaries": (if .codec_type == "video" then .color_primaries else null end),
                    "ColorSpace": (if .codec_type == "video" then .color_space else null end),
                    "TimeBase": .time_base,
                    "Title": (if .codec_type != "video" then (.tags.title // null) else null end),
                    "VideoRange": (if .codec_type == "video" then ($bdmv_dv_detected // video_range) else null end),
                    "DisplayTitle": (
                        if .codec_type == "video" then
                            (if (.height // 0) >= 2160 then "4K "
                             elif (.height // 0) >= 1440 then "2K "
                             elif (.height // 0) >= 1080 then "1080p "
                             elif (.height // 0) >= 720 then "720p "
                             elif (.height // 0) > 0 then ((.height | tostring) + "p ")
                             else "" end) +
                            (
                                (($bdmv_dv_detected // video_range) | tostring) as $hdr_range |
                                if $hdr_range == "DolbyVision" or ($hdr_range | startswith("DolbyVision")) then "Dolby Vision "
                                elif $hdr_range == "HDR10+" then "HDR10+ "
                                elif $hdr_range == "HDR10" then "HDR10 "
                                elif $hdr_range == "HLG" then "HLG "
                                else "" end
                            ) +
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
                    "IsInterlaced": (if .field_order then (.field_order != "progressive") else false end),
                    "BitRate": (
                        if (.bit_rate | safe_number) then
                            # If stream has bit_rate, use it directly
                            (.bit_rate | safe_number)
                        elif .codec_type == "video" and $video_bitrate_total then
                            # Video track and total video bitrate exists, allocate by weight
                            .index as $current_index |
                            (($video_tracks | map(select(.index == $current_index)) | .[0].weight // null) as $current_weight |
                             if $current_weight and $video_weight_sum > 0 then
                                 (($video_bitrate_total * $current_weight / $video_weight_sum) | floor)
                             else
                                 $video_bitrate_total
                             end)
                        else
                            null
                        end
                    ),
                    "BitDepth": (
                        if (.bits_per_raw_sample | safe_number) then
                            (.bits_per_raw_sample | safe_number)
                        elif .pix_fmt then
                            # Extract bit depth from pix_fmt (e.g. yuv420p10le → 10)
                            (.pix_fmt | capture("p(?<depth>\\d+)") | .depth | tonumber? // 8)
                        else
                            null
                        end
                    ),
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
                    "Profile": (
                        if .codec_type == "audio" then
                            # Enhanced Dolby Atmos recognition
                            if .codec_name == "truehd" and ((.profile // "") | contains("Atmos")) then
                                "Dolby TrueHD + Dolby Atmos"
                            elif .codec_name == "eac3" and ((.profile // "") | contains("Atmos")) then
                                "Dolby Digital Plus + Dolby Atmos"
                            elif .codec_name == "ac3" and ((.profile // "") | contains("Atmos")) then
                                "Dolby Digital + Dolby Atmos"
                            else
                                .profile
                            end
                        else
                            .profile
                        end
                    ),
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
                    "SupportsExternalStream": (
                        if .codec_type == "subtitle" then true
                        else false end
                    ),
                    "Protocol": "File",
                    "PixelFormat": (if .codec_type == "video" then .pix_fmt else null end),
                    "Level": (.level | safe_number),
                    "IsAnamorphic": false,
                    "ExtendedVideoType": (
                        if .codec_type == "video" then
                            (($bdmv_dv_detected // video_range) |
                            if startswith("DolbyVision") then "DolbyVision"
                            elif . == "HDR10+" then "HDR10Plus"
                            elif . == "HDR10" then "HDR10"
                            elif . == "HLG" then "HLG"
                            else "None"
                            end)
                        else "None"
                        end
                    ),
                    "ExtendedVideoSubType": (
                        if .codec_type == "video" then
                            (($bdmv_dv_detected // video_range) |
                            if startswith("DolbyVision Profile 7") then "DoviProfile76"
                            elif startswith("DolbyVision Profile 8") then "DoviProfile84"
                            elif startswith("DolbyVision") and .side_data_list then
                                (.side_data_list[] | select(.side_data_type == "DOVI configuration record") |
                                "DoviProfile" + (.dv_profile | tostring) + (.dv_level | tostring))
                            else "None"
                            end)
                        else "None"
                        end
                    ),
                    "ExtendedVideoSubTypeDescription": (
                        if .codec_type == "video" then
                            (($bdmv_dv_detected // video_range) |
                            if startswith("DolbyVision Profile 7") then "Profile 7.6 (Bluray)"
                            elif startswith("DolbyVision Profile 8") then "Profile 8.4"
                            elif startswith("DolbyVision") and .side_data_list then
                                (.side_data_list[] | select(.side_data_type == "DOVI configuration record") |
                                "Profile " + (.dv_profile | tostring) + "." + (.dv_level | tostring))
                            else "None"
                            end)
                        else "None"
                        end
                    ),
                    "ChannelLayout": (if .codec_type == "audio" then .channel_layout else null end),
                    "Channels": (.channels | safe_number),
                    "SampleRate": (.sample_rate | safe_number),
                    "AttachmentSize": 0,
                    "SubtitleLocationType": (if .codec_type == "subtitle" then "InternalStream" else null end)
                }
            ],
            "Formats": [],
            "Bitrate": (.format.bit_rate | safe_number),
            "RequiredHttpHeaders": {},
            "AddApiKeyToDirectStreamUrl": false,
            "ReadAtNativeFramerate": false,
            "Chapters": [
                ((.chapters // []) | to_entries[] |
                {
                    "StartPositionTicks": (.value.start_time // "0" | safe_number // 0 | . * 10000000 | floor),
                    "Name": (.value.tags.title // ("Chapter " + ((.key + 1) | tostring | if length == 1 then ("0" + .) else . end))),
                    "MarkerType": "Chapter",
                    "ChapterIndex": .key
                })
            ]
        }
    }]
    ' 2> "$jq_error_file")

    local jq_exit_code=$?

    if [ $jq_exit_code -ne 0 ]; then
        log_error "jq 转换失败（退出码: $jq_exit_code）"
        if [ -s "$jq_error_file" ]; then
            log_error "jq 错误详情:"
            head -10 "$jq_error_file" | while IFS= read -r line; do
                log_error "  $line"
            done
        fi
        rm -f "$jq_error_file" "$lang_tags_file"
        return 1
    fi

    rm -f "$jq_error_file" "$lang_tags_file"
    echo "$jq_output"
}

# Diagnostic function: save failed ffprobe output
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
# Validate Media Duration
#==============================================================================

validate_media_duration() {
    local ffprobe_json="$1"
    local min_duration=1800

    local duration
    duration=$(echo "$ffprobe_json" | jq -r '.format.duration // "0"' 2>/dev/null)

    duration=$(echo "$duration" | awk '{print int($1)}')

    if [ -z "$duration" ] || [ "$duration" = "null" ] || [ "$duration" -eq 0 ]; then
        log_warn "  ⚠️  媒体时长无效或为空"
        return 1
    fi

    if [ "$duration" -lt "$min_duration" ]; then
        log_warn "  ⚠️  媒体时长过短: ${duration}秒 < ${min_duration}秒（30分钟）"
        return 1
    fi

    log_info "  ✅ 媒体时长有效: ${duration}秒"
    return 0
}

#==============================================================================
# Find Emby Item ID by File Path
#==============================================================================

find_emby_item_by_path() {
    local strm_file="$1"
    local emby_url="${EMBY_URL}"
    local api_key="${EMBY_API_KEY}"

    if [ "${EMBY_ENABLED:-false}" != "true" ]; then
        log_debug "  Emby 集成未启用，跳过查找"
        return 1
    fi

    if [ -z "$emby_url" ] || [ -z "$api_key" ]; then
        log_warn "  ⚠️  Emby 配置不完整，跳过查找"
        return 1
    fi

    emby_url="${emby_url%/}"

    # Simple URL encoding (handle spaces only)
    local encoded_path=$(echo "$strm_file" | sed 's/ /%20/g')

    log_debug "  查找 Emby Item: $strm_file"

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
# Delete Emby Item (database record)
#==============================================================================

delete_emby_item() {
    local item_id="$1"
    local emby_url="${EMBY_URL}"
    local api_key="${EMBY_API_KEY}"

    emby_url="${emby_url%/}"

    log_info "  🗑️  删除 Emby 索引记录: $item_id"

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
# Process Single ISO strm File (full workflow)
#==============================================================================

process_iso_strm_full() {
    local strm_file="$1"
    local strm_dir="$(dirname "$strm_file")"
    local strm_name="$(basename "$strm_file" .iso.strm)"

    # Check if JSON already exists
    local json_pattern="${strm_dir}/${strm_name}.iso-mediainfo.json"
    if [ -f "$json_pattern" ]; then
        log_info "跳过（已有JSON）: $strm_file"
        return 0
    fi

    if ! check_disk_space "$strm_dir"; then
        log_error "磁盘空间不足，跳过: $strm_file"
        return 1
    fi

    local iso_path
    iso_path=$(head -n 1 "$strm_file" | tr -d '\r\n')

    if [ -z "$iso_path" ]; then
        log_error "strm 文件为空: $strm_file"
        return 1
    fi

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

    local iso_type
    iso_type=$(detect_iso_type "$iso_path" "$strm_file")

    log_info "  ISO 类型: ${iso_type^^}"

    # For Blu-ray ISO, mount first to extract language tags and accurate duration
    local lang_tags_file="/tmp/lang-tags-$$.json"

    if [ "$iso_type" = "bluray" ]; then

        local mount_point="/tmp/bd-lang-$$"
        local mount_success=false

        # Clean up possible leftover mount points (from abnormal exits)
        if mountpoint -q "$mount_point" 2>/dev/null; then
            log_warn "  ⚠️  检测到残留挂载点，尝试清理..."
            sudo umount -f "$mount_point" 2>/dev/null || true
        fi
        sudo rmdir "$mount_point" 2>/dev/null || true

        # Create mount point and mount ISO (3-minute timeout)
        if sudo mkdir -p "$mount_point" 2>/dev/null; then
            log_info "  尝试挂载 ISO 提取语言标签（超时：180秒）..."

            # Use timeout to limit mount time (3 minutes)
            if timeout 180 sudo mount -o loop,ro "$iso_path" "$mount_point" 2>/dev/null; then
                mount_success=true
                log_info "  ✅ ISO 挂载成功: $mount_point"

                # Extract language tags and accurate duration (Python writes directly to temp file)
                extract_bluray_language_tags "$mount_point" "$lang_tags_file"

                if [ -f "$lang_tags_file" ] && jq -e . "$lang_tags_file" >/dev/null 2>&1; then
                    local audio_count=$(jq -r '.audio_languages | length' "$lang_tags_file" 2>/dev/null || echo "0")
                    local subtitle_count=$(jq -r '.subtitle_languages | length' "$lang_tags_file" 2>/dev/null || echo "0")
                    local chapter_count=$(jq -r '.chapters // 0' "$lang_tags_file" 2>/dev/null || echo "0")
                    local bd_duration=$(jq -r '.main_title_duration // 0' "$lang_tags_file" 2>/dev/null || echo "0")
                    log_info "  ✅ 提取成功: ${audio_count} 音频 / ${subtitle_count} 字幕 / ${chapter_count} 章节"
                    log_info "  ✅ 准确时长: ${bd_duration}秒 ($(($bd_duration / 3600))h $(($bd_duration % 3600 / 60))m)"
                else
                    log_warn "  ⚠️  语言标签文件生成失败，将使用默认值"
                fi

                # Unmount immediately (with retry and force unmount)
                local unmount_retries=0
                while mountpoint -q "$mount_point" 2>/dev/null && [ $unmount_retries -lt 3 ]; do
                    if sudo umount "$mount_point" 2>/dev/null; then
                        break
                    fi
                    ((unmount_retries++)) || true
                    sleep 1
                done

                # Force unmount if normal unmount fails
                if mountpoint -q "$mount_point" 2>/dev/null; then
                    log_warn "  ⚠️  正常卸载失败，尝试强制卸载..."
                    sudo umount -f "$mount_point" 2>/dev/null || log_error "  ❌ 强制卸载失败: $mount_point"
                fi

                sudo rmdir "$mount_point" 2>/dev/null || true

                if ! mountpoint -q "$mount_point" 2>/dev/null; then
                    log_info "  ✅ ISO 已卸载"
                else
                    log_error "  ❌ ISO 卸载失败，挂载点可能泄漏: $mount_point"
                fi
            else
                log_warn "  ⚠️  ISO 挂载失败或超时（180秒），将跳过语言标签提取"
                sudo rmdir "$mount_point" 2>/dev/null || true
            fi
        else
            log_warn "  ⚠️  无法创建挂载点: $mount_point，将跳过语言标签提取"
        fi
    fi

    # Extract media info (ffprobe auto-selects playlist, duration corrected by bd_list_titles)
    local ffprobe_output
    log_debug "  开始提取媒体信息（ffprobe）..."
    ffprobe_output=$(extract_mediainfo "$iso_path" "$iso_type")

    if [ -z "$ffprobe_output" ] || ! echo "$ffprobe_output" | jq -e '.streams' >/dev/null 2>&1; then
        log_error "媒体信息提取失败: $iso_path"
        return 1
    fi

    # For non-Blu-ray ISO, create default language tags file
    if [ "$iso_type" != "bluray" ]; then
        echo '{"main_title_index":null,"main_title_duration":0,"audio_languages":[],"subtitle_languages":[],"chapters":0}' > "$lang_tags_file"
    fi

    # Verify temp file exists and is valid
    if [ ! -f "$lang_tags_file" ]; then
        log_warn "  ⚠️  语言标签文件不存在，创建默认文件"
        echo '{"main_title_index":null,"main_title_duration":0,"audio_languages":[],"subtitle_languages":[],"chapters":0}' > "$lang_tags_file"
    elif ! jq -e . "$lang_tags_file" >/dev/null 2>&1; then
        log_warn "  ⚠️  语言标签文件格式无效，使用默认值"
        log_warn "  文件内容: $(cat "$lang_tags_file" 2>/dev/null)"
        echo '{"main_title_index":null,"main_title_duration":0,"audio_languages":[],"subtitle_languages":[],"chapters":0}' > "$lang_tags_file"
    fi

    if [ -f "$lang_tags_file" ]; then
        local file_size=$(wc -c < "$lang_tags_file" 2>/dev/null || echo "0")
        local file_content=$(cat "$lang_tags_file" 2>/dev/null || echo "{}")
        log_debug "  🔍 语言标签文件: $lang_tags_file ($file_size bytes)"
        log_debug "  🔍 文件内容: ${file_content:0:200}"
    fi

    # Duration validation and correction (use bd_list_titles duration as fallback)
    local ffprobe_duration=$(echo "$ffprobe_output" | jq -r '.format.duration // "0"' | awk '{print int($1)}')
    local bd_duration=$(jq -r '.main_title_duration // 0' "$lang_tags_file" 2>/dev/null || echo "0")

    # Cross-validate: compare ffprobe and bd_list_titles duration
    if [ "$iso_type" = "bluray" ] && [ "$bd_duration" -gt 0 ] && [ "$ffprobe_duration" -gt 0 ]; then
        local duration_diff=$((ffprobe_duration > bd_duration ? ffprobe_duration - bd_duration : bd_duration - ffprobe_duration))

        # If duration diff > 60 seconds (1 minute), use bd_list_titles duration
        if [ "$duration_diff" -gt 60 ]; then
            log_warn "  ⚠️  时长差异检测: ffprobe=${ffprobe_duration}秒, bd_list_titles=${bd_duration}秒, 差异=${duration_diff}秒"
            log_warn "  ⚠️  使用 bd_list_titles 时长覆盖（更权威）: ${bd_duration}秒"

            ffprobe_output=$(echo "$ffprobe_output" | jq --arg duration "$bd_duration" '.format.duration = $duration')

            log_info "  ✅ 时长已修正为: ${bd_duration}秒 ($(($bd_duration / 3600))小时$(($bd_duration % 3600 / 60))分钟)"
        else
            log_info "  ✅ 时长一致性验证通过: 差异 ${duration_diff}秒"
        fi
    elif [ "$iso_type" = "bluray" ] && [ "$ffprobe_duration" -lt 1800 ] && [ "$bd_duration" -gt 1800 ]; then
        # Fallback: ffprobe duration abnormal (< 30 minutes) but bd duration normal
        log_warn "  ⚠️  ffprobe 时长异常: ${ffprobe_duration}秒 (< 30 分钟)"
        log_warn "  ⚠️  使用 bd_list_titles 时长覆盖: ${bd_duration}秒"

        ffprobe_output=$(echo "$ffprobe_output" | jq --arg duration "$bd_duration" '.format.duration = $duration')

        log_info "  ✅ 时长已修正为: ${bd_duration}秒 ($(($bd_duration / 3600))小时$(($bd_duration % 3600 / 60))分钟)"
    elif [ "$ffprobe_duration" -ge 1800 ]; then
        log_info "  ✅ ffprobe 时长正常: ${ffprobe_duration}秒 ($(($ffprobe_duration / 3600))小时$(($ffprobe_duration % 3600 / 60))分钟)"
    elif [ "$ffprobe_duration" -gt 0 ] && [ "$ffprobe_duration" -lt 1800 ]; then
        log_warn "  ⚠️  媒体时长较短: ${ffprobe_duration}秒 ($(($ffprobe_duration / 60))分钟)"
        log_warn "  ⚠️  这可能是短片/MV/番外篇/预告片，继续处理"
    fi

    # Get actual ISO file size
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

    # Convert to Emby format (convert_to_emby_format reads $lang_tags_file)
    local emby_json
    emby_json=$(convert_to_emby_format "$ffprobe_output" "$strm_file" "$iso_size" "$iso_type")

    if [ -z "$emby_json" ]; then
        debug_save_ffprobe "$ffprobe_output" "$strm_file"
        log_error "JSON 转换失败: $strm_file"
        rm -f "$lang_tags_file"
        return 1
    fi

    if ! echo "$emby_json" | jq -e . >/dev/null 2>&1; then
        log_error "生成的 JSON 格式无效: $strm_file"
        log_error "jq 错误输出:"
        echo "$emby_json" | jq . 2>&1 | head -10 | while IFS= read -r line; do
            log_error "  $line"
        done
        rm -f "$lang_tags_file"
        return 1
    fi

    # Atomic write
    local json_file="${strm_dir}/${strm_name}.iso-mediainfo.json"
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

    # Adaptive file permissions
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

    # Show stream filtering statistics
    local ffprobe_video_count=$(echo "$ffprobe_output" | jq '[.streams[] | select(.codec_type=="video")] | length')
    local ffprobe_audio_count=$(echo "$ffprobe_output" | jq '[.streams[] | select(.codec_type=="audio")] | length')
    local ffprobe_subtitle_count=$(echo "$ffprobe_output" | jq '[.streams[] | select(.codec_type=="subtitle")] | length')

    local output_video_count=$(echo "$emby_json" | jq '.[0].MediaSourceInfo.MediaStreams | [.[] | select(.Type=="Video")] | length')
    local output_audio_count=$(echo "$emby_json" | jq '.[0].MediaSourceInfo.MediaStreams | [.[] | select(.Type=="Audio")] | length')
    local output_subtitle_count=$(echo "$emby_json" | jq '.[0].MediaSourceInfo.MediaStreams | [.[] | select(.Type=="Subtitle")] | length')

    local lang_audio_count=$(jq -r '.audio_languages | length' "$lang_tags_file" 2>/dev/null || echo "0")
    local lang_subtitle_count=$(jq -r '.subtitle_languages | length' "$lang_tags_file" 2>/dev/null || echo "0")

    # Output stream statistics (highlight filtering)
    if [ "$iso_type" = "bluray" ] && [ "$lang_audio_count" -gt 0 ]; then
        # Blu-ray with language tags: show detailed filtering info
        local filtered_audio=$((ffprobe_audio_count - output_audio_count))
        local filtered_subtitle=$((ffprobe_subtitle_count - output_subtitle_count))

        log_info "  视频流: $output_video_count"
        log_info "  音频流: $output_audio_count/$ffprobe_audio_count (语言标签: $lang_audio_count$([ $filtered_audio -gt 0 ] && echo ", 已过滤: $filtered_audio" || echo ""))"
        log_info "  字幕流: $output_subtitle_count/$ffprobe_subtitle_count (语言标签: $lang_subtitle_count$([ $filtered_subtitle -gt 0 ] && echo ", 已过滤: $filtered_subtitle" || echo ""))"
    else
        # DVD or no language tags: show simple statistics
        log_info "  视频流: $output_video_count, 音频流: $output_audio_count, 字幕流: $output_subtitle_count"
    fi

    notify_emby_refresh "$json_file"

    rm -f "$lang_tags_file"

    return 0
}
