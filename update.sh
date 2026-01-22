#!/bin/bash

#==============================================================================
# Fantastic-Probe 更新脚本
#==============================================================================

set -e

VERSION_CHECK_URL="https://raw.githubusercontent.com/aydomini/fantastic-probe/main/version.json"
CURRENT_VERSION="2.8.0"
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/aydomini/fantastic-probe/main/install.sh"

#==============================================================================
# 颜色输出
#==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}ℹ️  $1${NC}"
}

warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

error() {
    echo -e "${RED}❌ $1${NC}"
}

success() {
    echo -e "${GREEN}✅ $1${NC}"
}

#==============================================================================
# 版本比较函数
#==============================================================================

version_gt() {
    # 比较两个版本号，如果 $1 > $2 返回 0，否则返回 1
    test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

#==============================================================================
# 主逻辑
#==============================================================================

echo "=========================================="
echo "Fantastic-Probe 更新检查"
echo "=========================================="
echo ""

# 检查权限
if [ "$EUID" -ne 0 ]; then
    error "请使用 root 权限运行此脚本"
    echo "   sudo bash $0"
    exit 1
fi

# 检查网络工具
if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
    error "缺少网络工具（curl 或 wget）"
    exit 1
fi

# 获取最新版本信息
info "检查最新版本..."

if command -v curl &> /dev/null; then
    VERSION_INFO=$(curl -fsSL "$VERSION_CHECK_URL" 2>/dev/null)
elif command -v wget &> /dev/null; then
    VERSION_INFO=$(wget -qO- "$VERSION_CHECK_URL" 2>/dev/null)
fi

if [ -z "$VERSION_INFO" ]; then
    error "无法获取版本信息，请检查网络连接"
    exit 1
fi

# 解析版本信息（需要 jq）
if ! command -v jq &> /dev/null; then
    error "缺少 jq 工具，无法解析版本信息"
    exit 1
fi

LATEST_VERSION=$(echo "$VERSION_INFO" | jq -r '.version')
RELEASE_DATE=$(echo "$VERSION_INFO" | jq -r '.release_date')
CHANGELOG=$(echo "$VERSION_INFO" | jq -r '.changelog')

echo ""
echo "当前版本: $CURRENT_VERSION"
echo "最新版本: $LATEST_VERSION"
echo "发布日期: $RELEASE_DATE"
echo ""

# 比较版本
if [ "$LATEST_VERSION" = "$CURRENT_VERSION" ]; then
    success "已是最新版本！"
    exit 0
elif version_gt "$CURRENT_VERSION" "$LATEST_VERSION"; then
    warn "当前版本高于远程版本（可能是开发版本）"
    exit 0
fi

# 发现新版本
echo -e "${BLUE}🎉 发现新版本！${NC}"
echo ""
echo "更新内容："
echo "  $CHANGELOG"
echo ""

# 询问是否更新
read -p "是否现在更新？[Y/n]: " do_update
do_update="${do_update:-Y}"

if [[ ! "$do_update" =~ ^[Yy]$ ]]; then
    info "已取消更新"
    exit 0
fi

# 执行更新
echo ""
info "开始更新 Fantastic-Probe..."
echo "=========================================="
echo ""

# 下载并执行安装脚本
if command -v curl &> /dev/null; then
    curl -fsSL "$INSTALL_SCRIPT_URL" | bash
elif command -v wget &> /dev/null; then
    wget -qO- "$INSTALL_SCRIPT_URL" | bash
fi

# 更新完成
echo ""
echo "=========================================="
success "更新完成！"
echo "=========================================="
echo ""
