#!/bin/bash
export LC_ALL=C.UTF-8

#==============================================================================
# ISO Media Info Extraction Service - Cron Scanner Mode
# Scans for unprocessed files every minute (alternative to inotifywait)
# Author: Fantastic-Probe Team
#==============================================================================

set -euo pipefail

# Read version dynamically
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="1.2.2"  # Hardcoded default

if [ -f "$SCRIPT_DIR/get-version.sh" ]; then
    source "$SCRIPT_DIR/get-version.sh"
elif command -v git &> /dev/null && [ -d "$SCRIPT_DIR/.git" ]; then
    VERSION=$(git -C "$SCRIPT_DIR" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "4.2.2")
fi

#==============================================================================
# Configuration
#==============================================================================

# Configuration file path
CONFIG_FILE="${CONFIG_FILE:-/etc/fantastic-probe/config}"

# Default configuration
STRM_ROOT="/mnt/sata1/media/媒体库/strm"
LOG_FILE="/var/log/fantastic_probe.log"
ERROR_LOG_FILE="/var/log/fantastic_probe_errors.log"

# Cron-specific configuration
CRON_LOCK_FILE="/tmp/fantastic_probe_cron_scanner.lock"
FAILURE_CACHE_DB="/var/lib/fantastic-probe/failure_cache.db"
MAX_RETRY_COUNT=3  # Stop retrying after this many failures
SCAN_BATCH_SIZE=10  # Max files to process per scan

# Load configuration file
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Compatibility with config file variable names (config.template uses CRON_ prefix)
MAX_RETRY_COUNT=${CRON_MAX_RETRY_COUNT:-$MAX_RETRY_COUNT}
SCAN_BATCH_SIZE=${CRON_SCAN_BATCH_SIZE:-$SCAN_BATCH_SIZE}

# Ensure failure cache directory exists
CACHE_DIR=$(dirname "$FAILURE_CACHE_DB")
mkdir -p "$CACHE_DIR"

#==============================================================================
# Logging functions
#==============================================================================

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Log only to file to avoid duplicate output (crontab captures stderr)
    echo "[$timestamp] [CRON] $1" >> "$LOG_FILE"
}

log_info() {
    log "ℹ️  INFO: $1"
}

log_warn() {
    log "⚠️  WARN: $1"
}

log_error() {
    log "❌ ERROR: $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CRON] $1" >> "$ERROR_LOG_FILE"
}

log_success() {
    log "✅ SUCCESS: $1"
}

log_debug() {
    if [ "${DEBUG:-false}" = "true" ]; then
        log "🔍 DEBUG: $1"
    fi
}

#==============================================================================
# Concurrency control (flock mechanism)
#==============================================================================

acquire_lock() {
    # Try to acquire lock (non-blocking)
    exec 200>"$CRON_LOCK_FILE"

    if ! flock -n 200; then
        log_warn "上一个扫描任务仍在运行，跳过本次扫描"
        return 1
    fi

    # Write current PID
    echo $$ >&200
    log_debug "已获取扫描锁（PID: $$）"
    return 0
}

release_lock() {
    # Lock is automatically released on script exit (file descriptor closed)
    log_debug "释放扫描锁"
}

trap release_lock EXIT

#==============================================================================
# Cleanup stale mount points (prevent leftover from previous abnormal exits)
#==============================================================================

cleanup_stale_mounts() {
    log_debug "检查并清理残留的 bd-lang 挂载点..."

    # Find all /tmp/bd-lang-* mount points (extract path between "on" and "type")
    local stale_mounts=$(mount | grep "/tmp/bd-lang-" | sed -E 's/.* on (\/tmp\/bd-lang-[0-9]+) type .*/\1/' || true)

    if [ -n "$stale_mounts" ]; then
        log_warn "发现残留挂载点，正在清理..."
        echo "$stale_mounts" | while read -r mount_point; do
            # Validate mount point path is not empty and has correct format
            if [ -n "$mount_point" ] && [[ "$mount_point" =~ ^/tmp/bd-lang-[0-9]+$ ]]; then
                log_info "  清理挂载点: $mount_point"
                sudo umount -f "$mount_point" 2>/dev/null || true
                sudo rmdir "$mount_point" 2>/dev/null || true
            else
                log_debug "  跳过无效路径: '$mount_point'"
            fi
        done
    fi

    # Clean empty /tmp/bd-lang-* directories
    find /tmp -maxdepth 1 -type d -name "bd-lang-*" -empty -exec sudo rmdir {} \; 2>/dev/null || true
}

#==============================================================================
# Failure cache management (SQLite)
#==============================================================================

init_failure_cache() {
    # Initialize SQLite database
    sqlite3 "$FAILURE_CACHE_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS failure_cache (
    file_path TEXT PRIMARY KEY,
    failure_count INTEGER DEFAULT 0,
    last_failure_time INTEGER,
    last_error_message TEXT,
    created_at INTEGER DEFAULT (strftime('%s', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_failure_count ON failure_cache(failure_count);
CREATE INDEX IF NOT EXISTS idx_last_failure_time ON failure_cache(last_failure_time);
SQL

    log_debug "失败缓存数据库已初始化"
}

should_skip_file() {
    local file_path="$1"

    # Query failure count
    local failure_count
    failure_count=$(sqlite3 "$FAILURE_CACHE_DB" \
        "SELECT failure_count FROM failure_cache WHERE file_path='$file_path';" 2>/dev/null || echo "0")

    if [ -z "$failure_count" ]; then
        failure_count=0
    fi

    # Check if exceeds max retry count
    if [ "$failure_count" -ge "$MAX_RETRY_COUNT" ]; then
        log_debug "跳过（已失败 $failure_count 次）: $file_path"
        return 0  # Skip
    fi

    return 1  # Don't skip
}

record_failure() {
    local file_path="$1"
    local error_message="${2:-未知错误}"
    local current_time
    current_time=$(date +%s)

    # Insert or update failure record
    sqlite3 "$FAILURE_CACHE_DB" <<SQL
INSERT INTO failure_cache (file_path, failure_count, last_failure_time, last_error_message)
VALUES ('$file_path', 1, $current_time, '$error_message')
ON CONFLICT(file_path) DO UPDATE SET
    failure_count = failure_count + 1,
    last_failure_time = $current_time,
    last_error_message = '$error_message';
SQL

    # Get updated failure count
    local new_count
    new_count=$(sqlite3 "$FAILURE_CACHE_DB" \
        "SELECT failure_count FROM failure_cache WHERE file_path='$file_path';")

    log_warn "文件处理失败（第 $new_count/$MAX_RETRY_COUNT 次）: $(basename "$file_path")"

    if [ "$new_count" -ge "$MAX_RETRY_COUNT" ]; then
        log_error "文件已达到最大重试次数，将不再尝试: $file_path"
        log_error "错误原因: $error_message"
        log_info "如需重新尝试，请删除缓存数据库: $FAILURE_CACHE_DB"
    fi
}

clear_failure_cache() {
    # Clear failure cache (called on restart)
    if [ -f "$FAILURE_CACHE_DB" ]; then
        rm -f "$FAILURE_CACHE_DB"
        log_info "失败缓存已清空"
    fi
}

get_failure_stats() {
    # Get failure statistics
    if [ ! -f "$FAILURE_CACHE_DB" ]; then
        echo "失败缓存数据库不存在"
        return
    fi

    local total_failures
    local permanent_failures

    total_failures=$(sqlite3 "$FAILURE_CACHE_DB" "SELECT COUNT(*) FROM failure_cache;" 2>/dev/null || echo "0")
    permanent_failures=$(sqlite3 "$FAILURE_CACHE_DB" "SELECT COUNT(*) FROM failure_cache WHERE failure_count >= $MAX_RETRY_COUNT;" 2>/dev/null || echo "0")

    echo "失败缓存统计: 总计 $total_failures 个文件，永久失败 $permanent_failures 个"
}

#==============================================================================
# Process single file (using standalone process library)
#==============================================================================

# Load process library functions
load_process_library() {
    local lib_paths=(
        "/usr/local/lib/fantastic-probe-process-lib.sh"
        "$SCRIPT_DIR/fantastic-probe-process-lib.sh"
        "/usr/local/bin/fantastic-probe-process-lib.sh"
    )

    for lib_path in "${lib_paths[@]}"; do
        if [ -f "$lib_path" ]; then
            log_debug "加载处理库: $lib_path"
            # shellcheck source=/dev/null
            source "$lib_path"
            return 0
        fi
    done

    log_error "找不到处理库文件，请检查以下路径："
    for lib_path in "${lib_paths[@]}"; do
        log_error "  - $lib_path"
    done
    return 1
}

process_iso_strm() {
    local strm_file="$1"

    # Check failure cache
    if should_skip_file "$strm_file"; then
        return 0
    fi

    log_info "开始处理: $(basename "$strm_file")"

    # Call function from process library
    local error_output
    local exit_code

    set +e
    error_output=$(process_iso_strm_full "$strm_file" 2>&1)
    exit_code=$?
    set -e

    if [ $exit_code -eq 0 ]; then
        log_success "处理成功: $(basename "$strm_file")"
        return 0
    else
        # Extract error message (last line)
        local error_message
        error_message=$(echo "$error_output" | tail -1 | sed 's/.*ERROR: //' || echo "处理失败")

        log_error "处理失败: $(basename "$strm_file") - $error_message"
        record_failure "$strm_file" "$error_message"
        return 1
    fi
}

#==============================================================================
# Scan for unprocessed files
#==============================================================================

scan_and_process() {
    # Validate monitoring directory
    if [ ! -d "$STRM_ROOT" ]; then
        log_error "STRM 根目录不存在: $STRM_ROOT"
        return 1
    fi

    # Initialize failure cache (silent)
    init_failure_cache

    # Find all .iso.strm files without JSON
    local pending_files=()

    while IFS= read -r -d '' strm_file; do
        local strm_dir
        local strm_name
        local json_file

        strm_dir="$(dirname "$strm_file")"
        strm_name="$(basename "$strm_file" .iso.strm)"
        json_file="${strm_dir}/${strm_name}.iso-mediainfo.json"

        # Check if JSON already exists
        if [ ! -f "$json_file" ]; then
            pending_files+=("$strm_file")
        fi
    done < <(find "$STRM_ROOT" -type f -name "*.iso.strm" -print0 2>/dev/null)

    local total_pending=${#pending_files[@]}

    # Completely silent on empty scans
    if [ $total_pending -eq 0 ]; then
        return 0
    fi

    # Batch processing (limit per scan to avoid long running)
    local processed=0
    local succeeded=0
    local failed=0

    for strm_file in "${pending_files[@]}"; do
        # Stop at batch limit
        if [ $processed -ge $SCAN_BATCH_SIZE ]; then
            log_warn "已达到批量限制（$SCAN_BATCH_SIZE），剩余 $((total_pending - processed)) 个文件将在下次扫描处理"
            break
        fi

        # Process file (serial to prevent resource exhaustion)
        if process_iso_strm "$strm_file"; then
            ((succeeded++)) || true
        else
            ((failed++)) || true
        fi

        ((processed++)) || true

        # Interval between tasks (prevent cloud storage rate limiting)
        if [ $processed -lt $SCAN_BATCH_SIZE ] && [ $processed -lt $total_pending ]; then
            sleep 10
        fi
    done

    return 0
}

#==============================================================================
# Main function
#==============================================================================

main() {
    # Check if SQLite is installed
    if ! command -v sqlite3 &> /dev/null; then
        log_error "未安装 sqlite3，请执行: apt-get install sqlite3"
        exit 1
    fi

    # Load process library
    if ! load_process_library; then
        log_error "加载处理库失败，无法继续执行"
        exit 1
    fi

    # Check dependencies (silent check on startup)
    if ! check_dependencies; then
        log_error "依赖检查失败，请安装缺失的依赖后重试"
        log_error "详细信息见上方日志"
        exit 1
    fi
    # No output when dependencies are satisfied to keep logs clean

    # Try to acquire lock
    if ! acquire_lock; then
        exit 0  # Silent exit (previous task still running)
    fi

    # Clean up stale mount points
    cleanup_stale_mounts

    # Execute scan
    scan_and_process

    # Lock is automatically released in EXIT trap
}

# Support command line arguments
case "${1:-scan}" in
    scan)
        main
        ;;
    clear-cache)
        log_info "清空失败缓存..."
        clear_failure_cache
        log_success "失败缓存已清空"
        ;;
    stats)
        init_failure_cache
        get_failure_stats

        # Show detailed information
        if [ -f "$FAILURE_CACHE_DB" ]; then
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "永久失败的文件列表（失败次数 >= $MAX_RETRY_COUNT）："
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Check if there are failed files
            failure_count=$(sqlite3 "$FAILURE_CACHE_DB" \
                "SELECT COUNT(*) FROM failure_cache WHERE failure_count >= $MAX_RETRY_COUNT;" 2>/dev/null || echo "0")

            if [ "$failure_count" -eq 0 ]; then
                echo "  ✅ 暂无永久失败的文件"
            else
                # Use formatted output (table mode)
                sqlite3 -header -column "$FAILURE_CACHE_DB" <<SQL
.width 50 8 20 40
SELECT
    file_path AS '文件路径',
    failure_count AS '失败次数',
    datetime(last_failure_time, 'unixepoch', 'localtime') AS '最后失败时间',
    CASE
        WHEN length(last_error_message) > 40
        THEN substr(last_error_message, 1, 37) || '...'
        ELSE last_error_message
    END AS '错误信息'
FROM failure_cache
WHERE failure_count >= $MAX_RETRY_COUNT
ORDER BY last_failure_time DESC;
SQL
            fi
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        fi
        ;;
    reset-file)
        if [ -z "${2:-}" ]; then
            echo "用法: $0 reset-file <文件路径>"
            exit 1
        fi

        init_failure_cache
        sqlite3 "$FAILURE_CACHE_DB" "DELETE FROM failure_cache WHERE file_path='$2';"
        log_success "已重置文件的失败记录: $2"
        ;;
    *)
        echo "用法: $0 {scan|clear-cache|stats|reset-file <文件路径>}"
        echo ""
        echo "命令说明："
        echo "  scan         执行扫描和处理（默认）"
        echo "  clear-cache  清空失败缓存数据库"
        echo "  stats        显示失败统计信息"
        echo "  reset-file   重置指定文件的失败记录"
        exit 1
        ;;
esac
