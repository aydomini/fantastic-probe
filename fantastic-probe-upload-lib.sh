#!/bin/bash
export LC_ALL=C.UTF-8

#==============================================================================
# Fantastic-Probe Upload Library
# Provides automatic JSON upload to network storage functionality
# Author: Fantastic-Probe Team
#==============================================================================

set -euo pipefail

#==============================================================================
# Configuration
#==============================================================================

# Upload database path
UPLOAD_CACHE_DB="${UPLOAD_CACHE_DB:-/var/lib/fantastic-probe/upload_cache.db}"

# Upload lock file (ensure serial uploads)
UPLOAD_LOCK_FILE="${UPLOAD_LOCK_FILE:-/tmp/fantastic-probe-upload.lock}"

# Upload interval (seconds between uploads, default 15s)
UPLOAD_INTERVAL="${UPLOAD_INTERVAL:-15}"

# Log file path (inherit from main config if available)
LOG_FILE="${LOG_FILE:-/var/log/fantastic_probe.log}"
ERROR_LOG_FILE="${ERROR_LOG_FILE:-/var/log/fantastic_probe_errors.log}"

# Ensure upload cache directory exists
CACHE_DIR=$(dirname "$UPLOAD_CACHE_DB")
mkdir -p "$CACHE_DIR"

#==============================================================================
# Logging functions (compatible with existing log system)
#==============================================================================

upload_log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [UPLOAD] $1" >> "$LOG_FILE"
}

upload_log_info() {
    upload_log "ℹ️  INFO: $1"
}

upload_log_warn() {
    upload_log "⚠️  WARN: $1"
}

upload_log_error() {
    upload_log "❌ ERROR: $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [UPLOAD] $1" >> "$ERROR_LOG_FILE"
}

upload_log_success() {
    upload_log "✅ SUCCESS: $1"
}

upload_log_debug() {
    if [ "${DEBUG:-false}" = "true" ]; then
        upload_log "🔍 DEBUG: $1"
    fi
}

#==============================================================================
# Database initialization
#==============================================================================

init_upload_cache_db() {
    # Initialize SQLite database for upload tracking
    sqlite3 "$UPLOAD_CACHE_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS upload_cache (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    json_file TEXT NOT NULL UNIQUE,
    target_path TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    upload_count INTEGER DEFAULT 0,
    last_upload_time INTEGER,
    last_error_message TEXT,
    created_at INTEGER DEFAULT (strftime('%s', 'now')),
    updated_at INTEGER DEFAULT (strftime('%s', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_status ON upload_cache(status);
CREATE INDEX IF NOT EXISTS idx_json_file ON upload_cache(json_file);
CREATE INDEX IF NOT EXISTS idx_last_upload_time ON upload_cache(last_upload_time);
SQL

    upload_log_debug "上传缓存数据库已初始化: $UPLOAD_CACHE_DB"
}

#==============================================================================
# Path mapping function
#==============================================================================

calculate_target_path() {
    local json_file="$1"

    # Validate JSON file exists
    if [ ! -f "$json_file" ]; then
        upload_log_error "JSON文件不存在: $json_file"
        return 1
    fi

    # Calculate corresponding STRM file path
    # Example: /path/to/movie.iso-mediainfo.json -> /path/to/movie.iso.strm
    local strm_file="${json_file%.iso-mediainfo.json}.iso.strm"

    # Validate STRM file exists
    if [ ! -f "$strm_file" ]; then
        upload_log_error "对应的STRM文件不存在: $strm_file"
        return 1
    fi

    # Read target ISO path from STRM file content
    local iso_path
    iso_path=$(head -n 1 "$strm_file" | tr -d '\r\n')

    # Validate ISO path is not empty
    if [ -z "$iso_path" ]; then
        upload_log_error "STRM文件内容为空: $strm_file"
        return 1
    fi

    # Calculate target JSON path by replacing .iso with .iso-mediainfo.json
    local target_path="${iso_path%.iso}.iso-mediainfo.json"

    upload_log_debug "路径映射: $json_file -> $target_path"
    echo "$target_path"
    return 0
}

#==============================================================================
# Database record functions
#==============================================================================

record_upload_pending() {
    local json_file="$1"
    local target_path="$2"
    local now
    now=$(date +%s)

    sqlite3 "$UPLOAD_CACHE_DB" <<SQL
INSERT OR REPLACE INTO upload_cache (json_file, target_path, status, created_at, updated_at)
VALUES ('$json_file', '$target_path', 'pending', $now, $now);
SQL

    upload_log_debug "记录待上传: $json_file"
}

record_upload_success() {
    local json_file="$1"
    local now
    now=$(date +%s)

    sqlite3 "$UPLOAD_CACHE_DB" <<SQL
UPDATE upload_cache
SET status = 'success',
    upload_count = upload_count + 1,
    last_upload_time = $now,
    last_error_message = NULL,
    updated_at = $now
WHERE json_file = '$json_file';
SQL

    upload_log_success "上传成功: $json_file"
}

record_upload_failure() {
    local json_file="$1"
    local error_message="$2"
    local now
    now=$(date +%s)

    # Escape single quotes in error message
    error_message="${error_message//\'/\'\'}"

    sqlite3 "$UPLOAD_CACHE_DB" <<SQL
UPDATE upload_cache
SET status = 'failed',
    upload_count = upload_count + 1,
    last_upload_time = $now,
    last_error_message = '$error_message',
    updated_at = $now
WHERE json_file = '$json_file';
SQL

    upload_log_error "上传失败: $json_file - $error_message"
}

#==============================================================================
# Core upload function (with flock for serial execution)
#==============================================================================

upload_json_single() {
    local json_file="$1"

    # Validate JSON file exists
    if [ ! -f "$json_file" ]; then
        upload_log_error "JSON文件不存在，跳过上传: $json_file"
        return 1
    fi

    # Calculate target path
    local target_path
    if ! target_path=$(calculate_target_path "$json_file"); then
        record_upload_failure "$json_file" "路径映射失败"
        return 1
    fi

    # Record pending status
    record_upload_pending "$json_file" "$target_path"

    # Acquire upload lock (ensure serial uploads)
    upload_log_info "等待上传锁: $(basename "$json_file")"

    (
        # Use flock to ensure only one upload at a time
        flock -x 201

        upload_log_info "开始上传: $(basename "$json_file")"
        upload_log_debug "  源文件: $json_file"
        upload_log_debug "  目标路径: $target_path"

        # Ensure target directory exists
        local target_dir
        target_dir=$(dirname "$target_path")

        if [ ! -d "$target_dir" ]; then
            upload_log_info "  创建目标目录: $target_dir"
            if ! mkdir -p "$target_dir" 2>/dev/null; then
                record_upload_failure "$json_file" "无法创建目标目录: $target_dir"
                upload_log_error "  无法创建目标目录: $target_dir"
                return 1
            fi
        fi

        # Perform upload (copy JSON to target path)
        local start_time
        start_time=$(date +%s)

        if cp "$json_file" "$target_path" 2>/dev/null; then
            local end_time
            end_time=$(date +%s)
            local duration=$((end_time - start_time))

            # Record success
            record_upload_success "$json_file"
            upload_log_success "上传完成: $(basename "$json_file") (耗时: ${duration}秒)"

            # Wait for upload interval (rate limiting)
            if [ "$UPLOAD_INTERVAL" -gt 0 ]; then
                upload_log_debug "  等待 ${UPLOAD_INTERVAL} 秒（上传间隔）"
                sleep "$UPLOAD_INTERVAL"
            fi

            return 0
        else
            # Record failure
            local error_msg="复制文件失败"
            record_upload_failure "$json_file" "$error_msg"
            upload_log_error "  $error_msg"
            return 1
        fi

    ) 201>"$UPLOAD_LOCK_FILE"

    return $?
}

#==============================================================================
# Async upload wrapper (non-blocking)
#==============================================================================

upload_json_async() {
    local json_file="$1"

    # Launch upload in background
    upload_log_debug "异步上传任务启动: $(basename "$json_file")"

    (
        upload_json_single "$json_file"
    ) &

    # Detach from parent process
    disown
}

#==============================================================================
# Bulk upload function (for existing JSON files)
#==============================================================================

upload_all_pending() {
    local strm_root="${1:-$STRM_ROOT}"

    upload_log_info "开始批量上传扫描: $strm_root"

    # Find all JSON files that don't exist in database or have failed status
    local total_count=0
    local success_count=0
    local failure_count=0

    # Find all *.iso-mediainfo.json files
    while IFS= read -r json_file; do
        total_count=$((total_count + 1))

        # Check if file exists in database with success status
        local db_status
        db_status=$(sqlite3 "$UPLOAD_CACHE_DB" \
            "SELECT status FROM upload_cache WHERE json_file='$json_file';" 2>/dev/null || echo "")

        if [ "$db_status" = "success" ]; then
            upload_log_debug "跳过已上传: $(basename "$json_file")"
            continue
        fi

        upload_log_info "处理文件 $total_count: $(basename "$json_file")"

        # Upload file (serial, blocking)
        if upload_json_single "$json_file"; then
            success_count=$((success_count + 1))
        else
            failure_count=$((failure_count + 1))
        fi

    done < <(find "$strm_root" -type f -name "*.iso-mediainfo.json" 2>/dev/null || true)

    upload_log_info "批量上传完成: 总计 $total_count 个文件, 成功 $success_count 个, 失败 $failure_count 个"
}

#==============================================================================
# Retry failed uploads
#==============================================================================

retry_failed_uploads() {
    upload_log_info "开始重试失败的上传任务"

    local success_count=0
    local failure_count=0

    # Query all failed uploads from database
    local failed_files
    failed_files=$(sqlite3 "$UPLOAD_CACHE_DB" \
        "SELECT json_file FROM upload_cache WHERE status='failed' ORDER BY updated_at;" 2>/dev/null || echo "")

    if [ -z "$failed_files" ]; then
        upload_log_info "没有失败的上传任务"
        return 0
    fi

    # Retry each failed file
    while IFS= read -r json_file; do
        if [ -z "$json_file" ]; then
            continue
        fi

        upload_log_info "重试上传: $(basename "$json_file")"

        # Upload file (serial, blocking)
        if upload_json_single "$json_file"; then
            success_count=$((success_count + 1))
        else
            failure_count=$((failure_count + 1))
        fi

    done <<< "$failed_files"

    upload_log_info "重试完成: 成功 $success_count 个, 仍失败 $failure_count 个"
}

#==============================================================================
# Cleanup and maintenance
#==============================================================================

cleanup_upload_cache() {
    local days_to_keep="${1:-30}"

    upload_log_info "清理 $days_to_keep 天前的上传记录"

    local cutoff_time
    cutoff_time=$(date -d "$days_to_keep days ago" +%s 2>/dev/null || date -v-${days_to_keep}d +%s)

    local deleted_count
    deleted_count=$(sqlite3 "$UPLOAD_CACHE_DB" \
        "DELETE FROM upload_cache WHERE status='success' AND updated_at < $cutoff_time; SELECT changes();" 2>/dev/null || echo "0")

    upload_log_info "已清理 $deleted_count 条旧记录"
}

get_upload_stats() {
    upload_log_info "上传统计信息:"

    local total_count
    total_count=$(sqlite3 "$UPLOAD_CACHE_DB" \
        "SELECT COUNT(*) FROM upload_cache;" 2>/dev/null || echo "0")

    local success_count
    success_count=$(sqlite3 "$UPLOAD_CACHE_DB" \
        "SELECT COUNT(*) FROM upload_cache WHERE status='success';" 2>/dev/null || echo "0")

    local failed_count
    failed_count=$(sqlite3 "$UPLOAD_CACHE_DB" \
        "SELECT COUNT(*) FROM upload_cache WHERE status='failed';" 2>/dev/null || echo "0")

    local pending_count
    pending_count=$(sqlite3 "$UPLOAD_CACHE_DB" \
        "SELECT COUNT(*) FROM upload_cache WHERE status='pending';" 2>/dev/null || echo "0")

    upload_log_info "  总计: $total_count"
    upload_log_info "  成功: $success_count"
    upload_log_info "  失败: $failed_count"
    upload_log_info "  待上传: $pending_count"
}

#==============================================================================
# Initialization on library load
#==============================================================================

# Initialize database when library is sourced
init_upload_cache_db
