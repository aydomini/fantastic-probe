#!/bin/bash

#==============================================================================
# Fantastic-Probe 自动更新助手
# 功能：等待队列清空后执行服务更新
#==============================================================================

set -euo pipefail

#==============================================================================
# 配置
#==============================================================================

SERVICE_NAME="fantastic-probe-monitor"
QUEUE_FILE="/tmp/fantastic_probe_queue.fifo"
LOG_FILE="/var/log/fantastic_probe.log"
UPDATE_LOCK="/tmp/fantastic-probe-auto-update.lock"
MAX_WAIT_TIME=3600  # 最长等待1小时

#==============================================================================
# 日志函数
#==============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log_info() {
    log "ℹ️  INFO: $*"
}

log_warn() {
    log "⚠️  WARN: $*"
}

log_error() {
    log "❌ ERROR: $*"
}

log_success() {
    log "✅ SUCCESS: $*"
}

#==============================================================================
# 清理函数
#==============================================================================

cleanup() {
    rm -f "$UPDATE_LOCK"
}

trap cleanup EXIT

#==============================================================================
# 检查是否有任务正在处理
#==============================================================================

is_queue_active() {
    # 检查队列文件是否存在
    if [ ! -p "$QUEUE_FILE" ]; then
        return 1  # 队列不存在，认为不活跃
    fi

    # 检查是否有进程正在读取队列（queue processor）
    # 通过检查是否有进程打开了队列文件
    if lsof -t "$QUEUE_FILE" >/dev/null 2>&1; then
        return 0  # 有进程在使用队列
    else
        return 1  # 队列空闲
    fi
}

#==============================================================================
# 等待队列清空
#==============================================================================

wait_for_queue_empty() {
    local wait_start
    wait_start=$(date +%s)

    log_info "等待任务队列清空..."

    while is_queue_active; do
        local elapsed=$(($(date +%s) - wait_start))

        if [ $elapsed -ge $MAX_WAIT_TIME ]; then
            log_error "等待队列清空超时（${MAX_WAIT_TIME}秒），取消自动更新"
            return 1
        fi

        if [ $((elapsed % 60)) -eq 0 ]; then
            log_info "队列仍在处理任务，已等待 ${elapsed} 秒..."
        fi

        sleep 10
    done

    log_success "任务队列已清空"
    return 0
}

#==============================================================================
# 执行更新
#==============================================================================

perform_update() {
    local version="$1"

    log_info "=========================================="
    log_info "开始自动更新到版本: $version"
    log_info "=========================================="

    # 1. 等待队列清空
    if ! wait_for_queue_empty; then
        log_error "更新失败：任务队列未能清空"
        return 1
    fi

    # 2. 停止服务
    log_info "停止服务: $SERVICE_NAME"
    if ! systemctl stop "$SERVICE_NAME"; then
        log_error "停止服务失败"
        return 1
    fi

    # 等待服务完全停止
    sleep 3

    # 3. 执行更新安装
    log_info "下载并执行安装脚本..."
    if command -v curl &> /dev/null; then
        if curl -fsSL "https://raw.githubusercontent.com/aydomini/fantastic-probe/main/install.sh" | bash; then
            log_success "更新安装成功"
        else
            log_error "更新安装失败，尝试恢复服务..."
            systemctl start "$SERVICE_NAME" || true
            return 1
        fi
    else
        log_error "curl 命令不可用，无法下载更新"
        systemctl start "$SERVICE_NAME" || true
        return 1
    fi

    # 4. 验证服务状态
    sleep 3
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_success "=========================================="
        log_success "自动更新完成！服务已恢复运行"
        log_success "新版本: $version"
        log_success "=========================================="
        return 0
    else
        log_error "更新后服务未能正常启动"
        log_error "请手动检查: systemctl status $SERVICE_NAME"
        return 1
    fi
}

#==============================================================================
# 主函数
#==============================================================================

main() {
    local target_version="${1:-unknown}"

    # 检查是否以 root 运行
    if [ "$EUID" -ne 0 ]; then
        log_error "自动更新助手必须以 root 权限运行"
        exit 1
    fi

    # 防止重复执行
    if [ -f "$UPDATE_LOCK" ]; then
        log_warn "检测到更新锁文件，可能有更新正在进行"
        exit 0
    fi

    # 创建锁文件
    echo $$ > "$UPDATE_LOCK"

    # 执行更新
    if perform_update "$target_version"; then
        exit 0
    else
        exit 1
    fi
}

# 如果没有提供版本参数，从更新标记文件读取
if [ $# -eq 0 ]; then
    UPDATE_MARKER="/tmp/fantastic-probe-update-marker"
    if [ -f "$UPDATE_MARKER" ]; then
        VERSION=$(cat "$UPDATE_MARKER")
        rm -f "$UPDATE_MARKER"
        main "$VERSION"
    else
        echo "错误：未提供版本号且未找到更新标记文件"
        exit 1
    fi
else
    main "$@"
fi
