#!/bin/bash
export LC_ALL=C.UTF-8

#==============================================================================
# ISO 媒体信息提取服务 - Cron 扫描模式
# 功能：每分钟扫描一次未处理文件，替代 inotifywait 实时监控
# 作者：Fantastic-Probe Team
#==============================================================================

set -euo pipefail

# 动态读取版本号
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="3.3.7"  # 硬编码默认值 - 删除 TMDB 缓存功能

if [ -f "$SCRIPT_DIR/get-version.sh" ]; then
    source "$SCRIPT_DIR/get-version.sh"
elif command -v git &> /dev/null && [ -d "$SCRIPT_DIR/.git" ]; then
    VERSION=$(git -C "$SCRIPT_DIR" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "3.3.2")
fi

#==============================================================================
# 配置参数
#==============================================================================

# 配置文件路径
CONFIG_FILE="${CONFIG_FILE:-/etc/fantastic-probe/config}"

# 默认配置
STRM_ROOT="/mnt/sata1/media/媒体库/strm"
LOG_FILE="/var/log/fantastic_probe.log"
ERROR_LOG_FILE="/var/log/fantastic_probe_errors.log"

# Cron 模式专用配置
CRON_LOCK_FILE="/tmp/fantastic_probe_cron_scanner.lock"
FAILURE_CACHE_DB="/var/lib/fantastic-probe/failure_cache.db"
MAX_RETRY_COUNT=3  # 失败多少次后停止尝试
SCAN_BATCH_SIZE=50  # 每次扫描最多处理多少个文件

# 加载配置文件
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# 确保失败缓存目录存在
CACHE_DIR=$(dirname "$FAILURE_CACHE_DB")
mkdir -p "$CACHE_DIR"

#==============================================================================
# 日志函数
#==============================================================================

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # 只输出到日志文件，避免重复（crontab 会捕获 stderr）
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
# 并发控制（flock 机制）
#==============================================================================

acquire_lock() {
    # 尝试获取锁（非阻塞）
    exec 200>"$CRON_LOCK_FILE"

    if ! flock -n 200; then
        log_warn "上一个扫描任务仍在运行，跳过本次扫描"
        return 1
    fi

    # 写入当前 PID
    echo $$ >&200
    log_debug "已获取扫描锁（PID: $$）"
    return 0
}

release_lock() {
    # 锁会在脚本退出时自动释放（文件描述符关闭）
    log_debug "释放扫描锁"
}

trap release_lock EXIT

#==============================================================================
# 失败缓存管理（SQLite）
#==============================================================================

init_failure_cache() {
    # 初始化 SQLite 数据库
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

    # 查询失败次数
    local failure_count
    failure_count=$(sqlite3 "$FAILURE_CACHE_DB" \
        "SELECT failure_count FROM failure_cache WHERE file_path='$file_path';" 2>/dev/null || echo "0")

    if [ -z "$failure_count" ]; then
        failure_count=0
    fi

    # 检查是否超过最大重试次数
    if [ "$failure_count" -ge "$MAX_RETRY_COUNT" ]; then
        log_debug "跳过（已失败 $failure_count 次）: $file_path"
        return 0  # 跳过
    fi

    return 1  # 不跳过
}

record_failure() {
    local file_path="$1"
    local error_message="${2:-未知错误}"
    local current_time
    current_time=$(date +%s)

    # 插入或更新失败记录
    sqlite3 "$FAILURE_CACHE_DB" <<SQL
INSERT INTO failure_cache (file_path, failure_count, last_failure_time, last_error_message)
VALUES ('$file_path', 1, $current_time, '$error_message')
ON CONFLICT(file_path) DO UPDATE SET
    failure_count = failure_count + 1,
    last_failure_time = $current_time,
    last_error_message = '$error_message';
SQL

    # 获取更新后的失败次数
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
    # 清空失败缓存（重启时调用）
    if [ -f "$FAILURE_CACHE_DB" ]; then
        rm -f "$FAILURE_CACHE_DB"
        log_info "失败缓存已清空"
    fi
}

get_failure_stats() {
    # 获取失败统计信息
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
# 处理单个文件（使用独立处理库）
#==============================================================================

# 加载处理库函数
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

    # 检查失败缓存
    if should_skip_file "$strm_file"; then
        return 0
    fi

    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "开始处理: $(basename "$strm_file")"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 检查配置开关
    local enable_strm="${ENABLE_STRM:-true}"
    if [ "$enable_strm" != "true" ]; then
        log_warn "STRM 处理已禁用，跳过"
        return 0
    fi

    # ==================== 步骤1：任务规划 ====================
    log_info "[步骤1/4] 任务规划"

    local tasks=$(plan_strm_tasks "$strm_file")

    if [ -z "$tasks" ]; then
        log_info "  ✅ 所有任务已完成，无需处理"
        return 0
    fi

    log_info "  计划执行: $tasks"

    # 对于电视剧，提前分析目录结构
    local strm_name="$(basename "$strm_file" .strm)"
    local tv_structure_info=""
    if is_tv_show "$strm_name"; then
        log_info "  检测到电视剧，分析目录结构..."
        tv_structure_info=$(analyze_tv_show_structure "$strm_file" 2>&1)
        if [ $? -ne 0 ]; then
            log_warn "  ⚠️  电视剧目录结构分析失败，使用简单识别"
            tv_structure_info=""
        fi
    fi

    # 智能检测 STRM 类型
    local strm_type
    strm_type=$(detect_strm_type "$strm_file")
    log_debug "  STRM 类型: $strm_type"

    # ==================== 步骤2：阶段1 - 媒体信息提取 ====================
    local stage1_success=true

    if echo "$tasks" | grep -q "stage1"; then
        log_info "[步骤2/4] 阶段1 - 媒体信息提取"

        set +e
        if [ "$strm_type" = "iso" ]; then
            if [ "${ENABLE_ISO_STRM:-true}" = "true" ]; then
                process_iso_strm_full "$strm_file"
                if [ $? -ne 0 ]; then
                    stage1_success=false
                fi
            else
                log_warn "  ISO.STRM 处理已禁用，跳过"
            fi
        else
            if [ "${ENABLE_VIDEO_STRM:-true}" = "true" ]; then
                process_video_strm_full "$strm_file"
                if [ $? -ne 0 ]; then
                    stage1_success=false
                fi
            else
                log_warn "  普通 STRM 处理已禁用，跳过"
            fi
        fi
        set -e

        if [ "$stage1_success" = false ]; then
            log_error "  ❌ 阶段1失败"
            record_failure "$strm_file" "阶段1失败"
            return 1
        fi

        log_success "  ✅ 阶段1完成"
    else
        log_info "[步骤2/4] 跳过阶段1（已有媒体信息）"
    fi

    # ==================== 步骤3：阶段2 - 元数据刮削 ====================
    if echo "$tasks" | grep -q "stage2"; then
        log_info "[步骤3/4] 阶段2 - 元数据刮削"

        set +e
        # 传递目录结构信息（如果是电视剧）
        if [ -n "$tv_structure_info" ]; then
            scrape_metadata_full "$strm_file" "$tv_structure_info"
        else
            scrape_metadata_full "$strm_file"
        fi

        if [ $? -ne 0 ]; then
            log_warn "  ⚠️  阶段2失败"
            # 检查阶段1是否完成（有 JSON 文件）
            if [ -f "${strm_dir}/${strm_name}-mediainfo.json" ]; then
                # 阶段1完成 + 阶段2失败 → 记录为失败，防止无限重试
                record_failure "$strm_file" "阶段2失败（NFO或图片）"
            fi
            set -e
            return 1
        else
            log_success "  ✅ 阶段2完成"
        fi
        set -e
    else
        log_info "[步骤3/4] 跳过阶段2（已有元数据）"
    fi

    # ==================== 步骤4：通知 Emby 刷新 ====================
    if [ "${EMBY_ENABLED:-false}" = "true" ]; then
        log_info "[步骤4/4] 通知 Emby 刷新媒体库"

        # 构造 JSON 文件路径
        local strm_dir="$(dirname "$strm_file")"
        local strm_name="$(basename "$strm_file" .strm)"
        local json_file="${strm_dir}/${strm_name}-mediainfo.json"

        # 调用通知函数（来自 process-lib.sh）
        notify_emby_refresh "$json_file"
    else
        log_info "[步骤4/4] 跳过 Emby 通知（未启用）"
    fi

    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "✅ 处理完成: $(basename "$strm_file")"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    return 0
}

#==============================================================================
# 扫描未处理文件
#==============================================================================

scan_and_process() {
    # 验证监控目录
    if [ ! -d "$STRM_ROOT" ]; then
        log_error "STRM 根目录不存在: $STRM_ROOT"
        return 1
    fi

    # 初始化失败缓存（静默）
    init_failure_cache

    # 查找所有没有 JSON 的 .iso.strm 文件
    local pending_files=()

    while IFS= read -r -d '' strm_file; do
        local strm_dir
        local strm_name
        local json_file

        strm_dir="$(dirname "$strm_file")"
        strm_name="$(basename "$strm_file" .strm)"
        json_file="${strm_dir}/${strm_name}-mediainfo.json"

        # 检查是否已有 JSON
        if [ ! -f "$json_file" ]; then
            pending_files+=("$strm_file")
        fi
    done < <(find "$STRM_ROOT" -type f -name "*.strm" -print0 2>/dev/null)

    local total_pending=${#pending_files[@]}

    # 空扫描时静默（只记录一行摘要）
    if [ $total_pending -eq 0 ]; then
        log_info "扫描完成，无待处理文件"
        return 0
    fi

    # 有文件时输出详细信息
    log_info "=========================================="
    log_info "扫描任务启动（版本: $VERSION）"
    log_info "$(get_failure_stats)"
    log_info "发现 $total_pending 个待处理文件"
    log_info "=========================================="

    # 批量处理（限制单次处理数量，避免长时间运行）
    local processed=0
    local succeeded=0
    local failed=0

    for strm_file in "${pending_files[@]}"; do
        # 达到批量限制，停止本次扫描
        if [ $processed -ge $SCAN_BATCH_SIZE ]; then
            log_info "已达到批量限制（$SCAN_BATCH_SIZE），剩余 $((total_pending - processed)) 个文件将在下次扫描处理"
            break
        fi

        log_info "处理 $((processed + 1))/$total_pending: $(basename "$strm_file")"

        # 处理文件（串行，防止资源耗尽）
        if process_iso_strm "$strm_file"; then
            ((succeeded++)) || true
        else
            ((failed++)) || true
        fi

        ((processed++)) || true

        # 任务间隔（防止频繁访问网盘触发限流）
        if [ $processed -lt $SCAN_BATCH_SIZE ] && [ $processed -lt $total_pending ]; then
            sleep 5
        fi
    done

    log_info "=========================================="
    log_info "Cron 扫描任务完成"
    log_info "总计: $processed, 成功: $succeeded, 失败: $failed"
    log_info "=========================================="

    return 0
}

#==============================================================================
# 主函数
#==============================================================================

main() {
    # 检查 SQLite 是否安装
    if ! command -v sqlite3 &> /dev/null; then
        log_error "未安装 sqlite3，请执行: apt-get install sqlite3"
        exit 1
    fi

    # 加载处理库
    if ! load_process_library; then
        log_error "加载处理库失败，无法继续执行"
        exit 1
    fi

    # 尝试获取锁
    if ! acquire_lock; then
        exit 0  # 静默退出（上一个任务仍在运行）
    fi

    # 执行扫描
    scan_and_process

    # 锁会在 EXIT trap 中自动释放
}

# 支持命令行参数
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

        # 显示详细信息
        if [ -f "$FAILURE_CACHE_DB" ]; then
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "永久失败的文件列表（失败次数 >= $MAX_RETRY_COUNT）："
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # 检查是否有失败文件
            failure_count=$(sqlite3 "$FAILURE_CACHE_DB" \
                "SELECT COUNT(*) FROM failure_cache WHERE failure_count >= $MAX_RETRY_COUNT;" 2>/dev/null || echo "0")

            if [ "$failure_count" -eq 0 ]; then
                echo "  ✅ 暂无永久失败的文件"
            else
                # 使用格式化输出（表格模式）
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
