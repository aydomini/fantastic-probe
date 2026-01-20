#!/bin/bash

#==============================================================================
# Fantastic-Probe 一键安装脚本
# 用法: curl -fsSL https://raw.githubusercontent.com/aydomini/fantastic-probe/main/install.sh | sudo bash
#==============================================================================

set -e

REPO_URL="https://github.com/aydomini/fantastic-probe"
REPO_RAW_URL="https://raw.githubusercontent.com/aydomini/fantastic-probe"
VERSION="${1:-main}"  # 默认使用 main 分支，可指定版本标签
INSTALL_DIR="/tmp/fantastic-probe-install-$$"

# 清理临时文件函数
cleanup() {
    if [ -d "$INSTALL_DIR" ]; then
        echo "清理临时文件..."
        cd /
        rm -rf "$INSTALL_DIR"
    fi
}

# 设置退出时自动清理（即使脚本失败或中断也会执行）
trap cleanup EXIT INT TERM

#==============================================================================
# 颜色输出
#==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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
# 主安装流程
#==============================================================================

echo "=========================================="
echo "Fantastic-Probe 一键安装"
echo "=========================================="
echo ""

# 1. 检查权限
if [ "$EUID" -ne 0 ]; then
    error "请使用 root 权限运行此脚本"
    echo "   curl -fsSL https://raw.githubusercontent.com/aydomini/fantastic-probe/main/install.sh | sudo bash"
    exit 1
fi

# 2. 检测系统环境
info "检测系统环境..."
if [ -f /etc/os-release ]; then
    # 保存 VERSION 变量（防止被 os-release 覆盖）
    INSTALL_VERSION="$VERSION"
    # shellcheck source=/dev/null
    source /etc/os-release
    echo "   发行版: $NAME"
    # 恢复 VERSION 变量
    VERSION="$INSTALL_VERSION"
else
    warn "无法检测发行版信息"
fi

# 3. 检查依赖工具
info "检查必需工具..."
MISSING_TOOLS=()

if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
    MISSING_TOOLS+=("curl 或 wget")
fi

if ! command -v tar &> /dev/null; then
    MISSING_TOOLS+=("tar")
fi

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    error "缺少必需工具: ${MISSING_TOOLS[*]}"
    echo ""
    echo "请先安装这些工具："
    echo "  Debian/Ubuntu: apt-get install curl tar"
    echo "  RHEL/CentOS:   dnf install curl tar"
    echo "  Arch Linux:    pacman -S curl tar"
    exit 1
fi

# 4. 下载项目文件
info "下载 Fantastic-Probe (版本: $VERSION)..."

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

if [ "$VERSION" = "main" ]; then
    # 下载主分支
    DOWNLOAD_URL="$REPO_URL/archive/refs/heads/main.tar.gz"
else
    # 下载指定版本标签
    DOWNLOAD_URL="$REPO_URL/archive/refs/tags/$VERSION.tar.gz"
fi

if command -v curl &> /dev/null; then
    curl -fsSL "$DOWNLOAD_URL" -o fantastic-probe.tar.gz
elif command -v wget &> /dev/null; then
    wget -q "$DOWNLOAD_URL" -O fantastic-probe.tar.gz
fi

if [ ! -f fantastic-probe.tar.gz ]; then
    error "下载失败，请检查网络连接或版本号是否正确"
    echo "   仓库地址: $REPO_URL"
    echo "   版本: $VERSION"
    exit 1
fi

success "下载完成"

# 5. 解压文件
info "解压文件..."
tar -xzf fantastic-probe.tar.gz --strip-components=1
success "解压完成"

# 6. 运行安装脚本
echo ""
info "开始安装 Fantastic-Probe..."
echo "=========================================="
echo ""

if [ -f "$INSTALL_DIR/fantastic-probe-install.sh" ]; then
    bash "$INSTALL_DIR/fantastic-probe-install.sh"
else
    error "找不到安装脚本: fantastic-probe-install.sh"
    exit 1
fi

# 7. 安装完成
echo ""
echo "=========================================="
success "Fantastic-Probe 安装完成！"
echo "=========================================="
echo ""
echo "🎉 服务已启动并设置为开机自启"
echo ""
echo "常用命令："
echo "  查看服务状态: systemctl status fantastic-probe-monitor"
echo "  查看日志:     tail -f /var/log/fantastic_probe.log"
echo "  重启服务:     systemctl restart fantastic-probe-monitor"
echo "  停止服务:     systemctl stop fantastic-probe-monitor"
echo ""
echo "配置文件位置: /etc/fantastic-probe/config"
echo "修改配置后需重启服务: systemctl restart fantastic-probe-monitor"
echo ""
