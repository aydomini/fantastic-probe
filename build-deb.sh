#!/bin/bash

#==============================================================================
# Fantastic-Probe Deb 包构建脚本
#==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="2.4.0"
ARCH="all"
PKG_NAME="fantastic-probe_${VERSION}_${ARCH}"
BUILD_DIR="$SCRIPT_DIR/build/$PKG_NAME"

echo "=========================================="
echo "Fantastic-Probe Deb 包构建"
echo "版本: $VERSION"
echo "=========================================="
echo ""

# 1. 清理旧的构建目录
echo "1️⃣  清理旧的构建文件..."
rm -rf "$SCRIPT_DIR/build"
mkdir -p "$BUILD_DIR"
echo "   ✅ 完成"
echo ""

# 2. 复制 DEBIAN 控制文件
echo "2️⃣  复制 DEBIAN 控制文件..."
cp -r "$SCRIPT_DIR/debian/DEBIAN" "$BUILD_DIR/"
echo "   ✅ 完成"
echo ""

# 3. 安装程序文件
echo "3️⃣  安装程序文件..."

# 主程序
mkdir -p "$BUILD_DIR/usr/local/bin"
cp "$SCRIPT_DIR/fantastic-probe-monitor.sh" \
   "$BUILD_DIR/usr/local/bin/fantastic-probe-monitor"
chmod +x "$BUILD_DIR/usr/local/bin/fantastic-probe-monitor"

echo "   ✅ 主程序已安装"

# systemd 服务文件
mkdir -p "$BUILD_DIR/etc/systemd/system"
cp "$SCRIPT_DIR/fantastic-probe-monitor.service" \
   "$BUILD_DIR/etc/systemd/system/"

echo "   ✅ systemd 服务文件已安装"

# logrotate 配置
mkdir -p "$BUILD_DIR/etc/logrotate.d"
cp "$SCRIPT_DIR/logrotate-fantastic-probe.conf" \
   "$BUILD_DIR/etc/logrotate.d/fantastic-probe"

echo "   ✅ logrotate 配置已安装"

# 配置模板
mkdir -p "$BUILD_DIR/usr/share/doc/fantastic-probe"
cp "$SCRIPT_DIR/config/config.template" \
   "$BUILD_DIR/usr/share/doc/fantastic-probe/"

echo "   ✅ 配置模板已安装"
echo ""

# 4. 设置权限
echo "4️⃣  设置文件权限..."
find "$BUILD_DIR" -type d -exec chmod 755 {} \;
find "$BUILD_DIR" -type f -exec chmod 644 {} \;
chmod +x "$BUILD_DIR/usr/local/bin/fantastic-probe-monitor"
chmod +x "$BUILD_DIR/DEBIAN/postinst"
chmod +x "$BUILD_DIR/DEBIAN/prerm"
chmod +x "$BUILD_DIR/DEBIAN/postrm"
echo "   ✅ 完成"
echo ""

# 5. 构建 deb 包
echo "5️⃣  构建 deb 包..."
dpkg-deb --build "$BUILD_DIR" "$SCRIPT_DIR/build/${PKG_NAME}.deb"
echo "   ✅ 完成"
echo ""

# 6. 检查包质量
echo "6️⃣  检查包质量..."
if command -v lintian &> /dev/null; then
    lintian "$SCRIPT_DIR/build/${PKG_NAME}.deb" || echo "   ⚠️  Lintian 检查发现一些警告（可忽略）"
else
    echo "   ⚠️  未安装 lintian，跳过质量检查"
fi
echo ""

# 7. 显示包信息
echo "=========================================="
echo "✅ Deb 包构建成功！"
echo "=========================================="
echo ""
echo "包文件: $SCRIPT_DIR/build/${PKG_NAME}.deb"
echo "包大小: $(du -h "$SCRIPT_DIR/build/${PKG_NAME}.deb" | cut -f1)"
echo ""
echo "安装命令："
echo "  sudo apt install ./build/${PKG_NAME}.deb"
echo ""
echo "查看包内容："
echo "  dpkg-deb -c build/${PKG_NAME}.deb"
echo ""
