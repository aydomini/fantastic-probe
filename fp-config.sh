#!/bin/bash

#==============================================================================
# Fantastic-Probe 配置工具
# 功能：允许用户随时修改配置而无需重新安装
#==============================================================================

set -euo pipefail

#==============================================================================
# 清理函数
#==============================================================================

# 临时目录变量（全局）
TEMP_DIR=""

cleanup() {
    # 清理临时目录（如果存在）
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR" 2>/dev/null || true
    fi
}

# 设置退出时自动清理
trap cleanup EXIT INT TERM

#==============================================================================
# 配置
#==============================================================================

SERVICE_NAME="fantastic-probe-monitor"
CONFIG_FILE="/etc/fantastic-probe/config"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATIC_DIR="/usr/share/fantastic-probe/static"  # 预编译包本地缓存路径
FFPROBE_RELEASE_TAG="ffprobe-prebuilt-v1.0"     # FFprobe 预编译包版本

#==============================================================================
# 工具函数
#==============================================================================

# 检查是否以 root 运行
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "❌ 错误: 此工具需要 root 权限"
        echo "   请使用: sudo fantastic-probe-config"
        exit 1
    fi
}

# 加载当前配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    else
        echo "❌ 错误: 配置文件不存在: $CONFIG_FILE"
        echo "   请先安装 Fantastic-Probe"
        exit 1
    fi
}

# 显示当前配置
show_current_config() {
    echo ""
    echo "📋 当前配置："
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📁 STRM 根目录: $STRM_ROOT"
    echo "  🎬 FFprobe 路径: $FFPROBE"
    echo "  📝 日志文件: $LOG_FILE"
    echo "  ⏱️  FFprobe 超时: ${FFPROBE_TIMEOUT}秒"
    echo "  ⏱️  最大处理时间: ${MAX_FILE_PROCESSING_TIME}秒"
    echo "  ⏱️  防抖时间: ${DEBOUNCE_TIME}秒"
    echo "  🔄 自动检查更新: ${AUTO_UPDATE_CHECK}"
    echo "  🔄 自动安装更新: ${AUTO_UPDATE_INSTALL}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# 重启服务
restart_service() {
    echo ""
    echo "🔄 重启服务以应用配置..."

    if systemctl restart "$SERVICE_NAME"; then
        echo "   ✅ 服务重启成功"
        sleep 2
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            echo "   ✅ 服务运行正常"
        else
            echo "   ⚠️  警告: 服务未能正常启动"
            echo "   请检查: systemctl status $SERVICE_NAME"
        fi
    else
        echo "   ❌ 服务重启失败"
        echo "   请检查: systemctl status $SERVICE_NAME"
        return 1
    fi
    echo ""
}

# 更新配置文件中的某一行
update_config_line() {
    local key="$1"
    local value="$2"

    if [ -f "$CONFIG_FILE" ]; then
        # 创建备份
        cp "$CONFIG_FILE" "$CONFIG_FILE.bak"

        # 更新配置行
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$CONFIG_FILE"

        # 删除备份
        rm -f "$CONFIG_FILE.bak"

        echo "   ✅ 配置已更新: $key=\"$value\""
    else
        echo "   ❌ 配置文件不存在"
        return 1
    fi
}

#==============================================================================
# 配置修改函数
#==============================================================================

# 修改 STRM 根目录
change_strm_root() {
    echo ""
    echo "📁 修改 STRM 根目录"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   当前目录: $STRM_ROOT"
    echo ""
    read -p "   请输入新的 STRM 根目录路径: " new_strm_root

    if [ -z "$new_strm_root" ]; then
        echo "   ⚠️  未输入路径，取消修改"
        return 1
    fi

    # 验证目录
    if [ ! -d "$new_strm_root" ]; then
        echo "   ⚠️  警告: 目录不存在: $new_strm_root"
        read -p "   是否创建该目录？[Y/n]: " create_dir
        create_dir="${create_dir:-Y}"

        if [[ "$create_dir" =~ ^[Yy]$ ]]; then
            mkdir -p "$new_strm_root"
            echo "   ✅ 目录已创建"
        else
            echo "   ⚠️  目录不存在，配置可能无法正常工作"
        fi
    fi

    # 更新配置
    update_config_line "STRM_ROOT" "$new_strm_root"
    STRM_ROOT="$new_strm_root"

    # 询问是否重启服务
    read -p "   是否立即重启服务以应用配置？[Y/n]: " do_restart
    do_restart="${do_restart:-Y}"

    if [[ "$do_restart" =~ ^[Yy]$ ]]; then
        restart_service
    else
        echo "   ⚠️  配置已更新，但需要重启服务才能生效"
        echo "   手动重启: sudo systemctl restart $SERVICE_NAME"
    fi
}

# 重新配置 FFprobe
reconfigure_ffprobe() {
    echo ""
    echo "🎬 重新配置 FFprobe"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   当前路径: $FFPROBE"
    echo "   说明：ffprobe 用于提取蓝光/DVD 媒体信息"
    echo ""

    # 检测架构和预编译包
    ARCH=$(uname -m)
    PREBUILT_AVAILABLE=false
    PREBUILT_SOURCE=""  # 本地路径或 GitHub URL
    ARCH_NAME=""

    # 优先使用本地缓存，如果没有则从 GitHub 下载
    if [ "$ARCH" = "x86_64" ]; then
        ARCH_NAME="x86_64"
        if [ -f "$STATIC_DIR/ffprobe_linux_x64.zip" ]; then
            PREBUILT_AVAILABLE=true
            PREBUILT_SOURCE="$STATIC_DIR/ffprobe_linux_x64.zip"
        else
            PREBUILT_AVAILABLE=true
            PREBUILT_SOURCE="https://github.com/aydomini/fantastic-probe/releases/download/$FFPROBE_RELEASE_TAG/ffprobe_linux_x64.zip"
        fi
    elif [ "$ARCH" = "aarch64" ]; then
        ARCH_NAME="ARM64"
        if [ -f "$STATIC_DIR/ffprobe_linux_arm64.zip" ]; then
            PREBUILT_AVAILABLE=true
            PREBUILT_SOURCE="$STATIC_DIR/ffprobe_linux_arm64.zip"
        else
            PREBUILT_AVAILABLE=true
            PREBUILT_SOURCE="https://github.com/aydomini/fantastic-probe/releases/download/$FFPROBE_RELEASE_TAG/ffprobe_linux_arm64.zip"
        fi
    fi

    local new_ffprobe=""

    # 自动安装预编译包（优先方案）
    if [ "$PREBUILT_AVAILABLE" = true ]; then
        echo "   ✅ 检测到架构: $ARCH_NAME"
        echo "   ✅ 找到项目提供的预编译 ffprobe"
        echo ""
        read -p "   是否自动安装预编译 ffprobe？[Y/n]: " auto_install
        auto_install="${auto_install:-Y}"

        if [[ "$auto_install" =~ ^[Yy]$ ]]; then
            echo ""

            # 检查 unzip 是否可用
            if ! command -v unzip &> /dev/null; then
                echo "   ⚠️  需要安装 unzip 工具"
                read -p "   现在安装 unzip？[Y/n]: " install_unzip
                if [[ "$install_unzip" =~ ^[Yy]$ ]]; then
                    apt-get update && apt-get install -y unzip
                else
                    echo "   ❌ 无法继续，需要 unzip"
                    return 1
                fi
            fi

            # 准备临时目录
            TEMP_DIR="/tmp/ffprobe-config-$$"
            mkdir -p "$TEMP_DIR"

            # 判断是本地文件还是需要下载
            if [[ "$PREBUILT_SOURCE" =~ ^https:// ]]; then
                # 从 GitHub 下载
                echo "   📥 正在下载预编译 ffprobe..."

                if command -v curl &> /dev/null; then
                    if curl -fL "$PREBUILT_SOURCE" -o "$TEMP_DIR/ffprobe.zip" --progress-bar; then
                        echo "   ✅ 下载完成"
                        PREBUILT_ZIP="$TEMP_DIR/ffprobe.zip"
                    else
                        echo "   ❌ 下载失败"
                        rm -rf "$TEMP_DIR"
                        return 1
                    fi
                elif command -v wget &> /dev/null; then
                    if wget --show-progress "$PREBUILT_SOURCE" -O "$TEMP_DIR/ffprobe.zip" 2>&1; then
                        echo "   ✅ 下载完成"
                        PREBUILT_ZIP="$TEMP_DIR/ffprobe.zip"
                    else
                        echo "   ❌ 下载失败"
                        rm -rf "$TEMP_DIR"
                        return 1
                    fi
                else
                    echo "   ❌ 错误: 需要 curl 或 wget"
                    rm -rf "$TEMP_DIR"
                    return 1
                fi
            else
                # 使用本地缓存
                echo "   📦 使用本地缓存..."
                PREBUILT_ZIP="$PREBUILT_SOURCE"
            fi

            # 解压并安装
            echo "   📦 正在安装..."
            if unzip -q "$PREBUILT_ZIP" -d "$TEMP_DIR" 2>/dev/null; then
                # 安装到 /usr/local/bin
                if [ -f "$TEMP_DIR/ffprobe" ]; then
                    cp "$TEMP_DIR/ffprobe" /usr/local/bin/ffprobe
                    chmod +x /usr/local/bin/ffprobe
                    new_ffprobe="/usr/local/bin/ffprobe"

                    # 验证安装
                    if /usr/local/bin/ffprobe -version &> /dev/null; then
                        echo "   ✅ ffprobe 已安装到: /usr/local/bin/ffprobe"
                        echo "   ✅ 安装成功！"

                        # 如果是从 GitHub 下载的，保存到本地缓存
                        if [[ "$PREBUILT_SOURCE" =~ ^https:// ]]; then
                            mkdir -p "$STATIC_DIR"
                            if [ "$ARCH" = "x86_64" ]; then
                                cp "$TEMP_DIR/ffprobe.zip" "$STATIC_DIR/ffprobe_linux_x64.zip"
                            else
                                cp "$TEMP_DIR/ffprobe.zip" "$STATIC_DIR/ffprobe_linux_arm64.zip"
                            fi
                            echo "   ✅ 已保存到本地缓存"
                        fi
                    else
                        echo "   ❌ 安装失败: ffprobe 无法执行"
                        new_ffprobe=""
                    fi
                else
                    echo "   ❌ 错误: 解压后未找到 ffprobe"
                    new_ffprobe=""
                fi
            else
                echo "   ❌ 解压失败"
                new_ffprobe=""
            fi

            # 清理临时文件
            rm -rf "$TEMP_DIR"
        else
            echo "   ℹ️  跳过自动安装，进入手动配置..."
        fi
    fi

    # 手动配置（回退方案）
    if [ -z "$new_ffprobe" ]; then
        echo ""
        echo "   🔍 手动配置 FFprobe"
        echo ""
        echo "   选项："
        echo "     1) 使用系统已安装的 ffprobe（需先安装 ffmpeg）"
        echo "     2) 手动指定 ffprobe 路径"
        echo "     3) 保持原配置不变"
        echo ""
        read -p "   请选择 [1/2/3，默认: 1]: " manual_choice
        manual_choice="${manual_choice:-1}"

        case "$manual_choice" in
            1)
                # 使用系统 ffprobe
                if command -v ffprobe &> /dev/null; then
                    detected_ffprobe=$(command -v ffprobe)
                    echo "   ✅ 检测到: $detected_ffprobe"
                    new_ffprobe="$detected_ffprobe"
                else
                    echo "   ❌ 系统中未检测到 ffprobe"
                    echo ""
                    echo "   请先安装 ffmpeg："
                    echo "      Debian/Ubuntu: apt-get install -y ffmpeg"
                    echo "      RHEL/CentOS:   dnf install -y ffmpeg"
                    echo "      Arch Linux:    pacman -S ffmpeg"
                    echo ""
                    read -p "   现在安装 ffmpeg？[y/N]: " install_now

                    if [[ "$install_now" =~ ^[Yy]$ ]]; then
                        apt-get update && apt-get install -y ffmpeg
                        if command -v ffprobe &> /dev/null; then
                            new_ffprobe=$(command -v ffprobe)
                            echo "   ✅ ffmpeg 安装成功: $new_ffprobe"
                        else
                            echo "   ❌ 安装失败，保持原配置"
                            new_ffprobe="$FFPROBE"
                        fi
                    else
                        echo "   ℹ️  保持原配置: $FFPROBE"
                        new_ffprobe="$FFPROBE"
                    fi
                fi
                ;;
            2)
                # 手动指定路径
                echo ""
                read -p "   请输入 ffprobe 完整路径: " new_ffprobe

                if [ -z "$new_ffprobe" ]; then
                    echo "   ⚠️  路径为空，保持原配置: $FFPROBE"
                    new_ffprobe="$FFPROBE"
                fi
                ;;
            3)
                # 保持原配置
                echo "   ℹ️  保持原配置: $FFPROBE"
                new_ffprobe="$FFPROBE"
                ;;
            *)
                echo "   ⚠️  无效选择，保持原配置: $FFPROBE"
                new_ffprobe="$FFPROBE"
                ;;
        esac
    fi

    # 更新配置文件
    if [ -n "$new_ffprobe" ]; then
        update_config_line "FFPROBE" "$new_ffprobe"
        FFPROBE="$new_ffprobe"
        echo ""
        echo "   ✅ FFprobe 路径已更新: $new_ffprobe"

        # 验证是否可执行
        if [ ! -x "$new_ffprobe" ]; then
            echo ""
            echo "   ⚠️  警告: ffprobe 不存在或不可执行: $new_ffprobe"
            echo "   ⚠️  服务可能无法正常启动！"
            echo ""
            echo "   请执行以下操作之一："
            echo "     1) 安装 ffmpeg: apt-get install -y ffmpeg"
            echo "     2) 重新配置: fp-config ffprobe"
            echo "     3) 手动编辑: /etc/fantastic-probe/config"
        fi
    else
        echo "   ❌ 错误: 无法确定 ffprobe 路径"
        return 1
    fi

    # 询问是否重启服务
    echo ""
    read -p "   是否立即重启服务以应用配置？[Y/n]: " do_restart
    do_restart="${do_restart:-Y}"

    if [[ "$do_restart" =~ ^[Yy]$ ]]; then
        restart_service
    else
        echo "   ⚠️  配置已更新，但需要重启服务才能生效"
        echo "   手动重启: sudo systemctl restart $SERVICE_NAME"
    fi
}

# 修改自动更新设置
change_auto_update() {
    echo ""
    echo "🔄 修改自动更新设置"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   当前设置："
    echo "     自动检查更新: ${AUTO_UPDATE_CHECK}"
    echo "     自动安装更新: ${AUTO_UPDATE_INSTALL}"
    echo ""

    # 修改自动检查更新
    read -p "   是否启用自动检查更新？[Y/n]: " check_update
    check_update="${check_update:-Y}"

    if [[ "$check_update" =~ ^[Yy]$ ]]; then
        update_config_line "AUTO_UPDATE_CHECK" "true"
        AUTO_UPDATE_CHECK="true"
    else
        update_config_line "AUTO_UPDATE_CHECK" "false"
        AUTO_UPDATE_CHECK="false"
    fi

    # 修改自动安装更新
    echo ""
    echo "   ⚠️  注意: 自动安装更新会在队列清空后自动更新服务"
    read -p "   是否启用自动安装更新？[y/N]: " install_update
    install_update="${install_update:-N}"

    if [[ "$install_update" =~ ^[Yy]$ ]]; then
        update_config_line "AUTO_UPDATE_INSTALL" "true"
        AUTO_UPDATE_INSTALL="true"
    else
        update_config_line "AUTO_UPDATE_INSTALL" "false"
        AUTO_UPDATE_INSTALL="false"
    fi

    echo ""
    echo "   ✅ 自动更新设置已更新"

    # 询问是否重启服务
    read -p "   是否立即重启服务以应用配置？[Y/n]: " do_restart
    do_restart="${do_restart:-Y}"

    if [[ "$do_restart" =~ ^[Yy]$ ]]; then
        restart_service
    fi
}

# 直接编辑配置文件
edit_config_file() {
    echo ""
    echo "📝 编辑配置文件"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   配置文件: $CONFIG_FILE"
    echo ""

    # 检查编辑器
    EDITOR="${EDITOR:-nano}"

    if ! command -v "$EDITOR" &> /dev/null; then
        EDITOR="vi"
    fi

    echo "   使用编辑器: $EDITOR"
    echo "   ⚠️  警告: 请确保配置语法正确（KEY=\"VALUE\" 格式）"
    echo ""
    read -p "   按 Enter 继续，或 Ctrl+C 取消..."

    # 打开编辑器
    "$EDITOR" "$CONFIG_FILE"

    echo ""
    echo "   ✅ 编辑完成"

    # 询问是否重启服务
    read -p "   是否立即重启服务以应用配置？[Y/n]: " do_restart
    do_restart="${do_restart:-Y}"

    if [[ "$do_restart" =~ ^[Yy]$ ]]; then
        restart_service
    else
        echo "   ⚠️  配置已修改，但需要重启服务才能生效"
        echo "   手动重启: sudo systemctl restart $SERVICE_NAME"
    fi
}

#==============================================================================
# 服务管理函数
#==============================================================================

# 查看服务状态
show_service_status() {
    echo ""
    echo "📊 服务状态"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    systemctl status "$SERVICE_NAME" --no-pager || true
    echo ""
}

# 启动服务
start_service() {
    echo ""
    echo "▶️  启动服务..."

    if systemctl start "$SERVICE_NAME"; then
        echo "   ✅ 服务启动成功"
        sleep 2
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            echo "   ✅ 服务运行正常"
        else
            echo "   ⚠️  警告: 服务未能正常启动"
            echo "   请检查: systemctl status $SERVICE_NAME"
        fi
    else
        echo "   ❌ 服务启动失败"
        return 1
    fi
    echo ""
}

# 停止服务
stop_service() {
    echo ""
    echo "⏹️  停止服务..."

    if systemctl stop "$SERVICE_NAME"; then
        echo "   ✅ 服务已停止"
    else
        echo "   ❌ 服务停止失败"
        return 1
    fi
    echo ""
}

#==============================================================================
# 系统管理函数
#==============================================================================

# 检查更新
check_updates() {
    echo ""
    echo "🔍 检查更新"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "   正在检查 GitHub 仓库..."

    # 获取本地版本（优先使用 get-version.sh，回退到直接读取）
    LOCAL_VERSION=""

    if [ -f "/usr/local/bin/get-version.sh" ]; then
        # 使用 get-version.sh 获取动态版本号
        LOCAL_VERSION=$(bash /usr/local/bin/get-version.sh 2>/dev/null | grep "当前版本" | cut -d'：' -f2 | tr -d ' ' || echo "")
    fi

    # 回退方案：从安装的脚本中读取
    if [ -z "$LOCAL_VERSION" ] && [ -f "/usr/local/bin/fantastic-probe-monitor" ]; then
        LOCAL_VERSION=$(grep "^VERSION=" /usr/local/bin/fantastic-probe-monitor | head -1 | cut -d'"' -f2 || echo "unknown")
    fi

    # 最终回退
    if [ -z "$LOCAL_VERSION" ]; then
        LOCAL_VERSION="unknown"
    fi

    echo "   本地版本: $LOCAL_VERSION"
    echo ""

    # 获取远程最新版本（排除 ffprobe 相关的 releases）
    # 从所有 releases 中过滤出项目版本（排除 tag_name 包含 "ffprobe" 的）
    REMOTE_VERSION=$(curl -fsSL "https://api.github.com/repos/aydomini/fantastic-probe/releases" 2>/dev/null | \
        grep -E '"tag_name":|"draft":|"prerelease":' | \
        paste -d ' ' - - - | \
        grep '"draft": false' | \
        grep '"prerelease": false' | \
        grep -v 'ffprobe' | \
        head -1 | \
        sed -E 's/.*"tag_name": "v?([^"]+)".*/\1/' || echo "")

    if [ -z "$REMOTE_VERSION" ]; then
        # 如果没有找到项目版本的 Release，从主分支获取版本号
        echo "   ℹ️  仓库中暂无正式版本 Release"
        echo "   正在从主分支获取版本信息..."
        REMOTE_VERSION=$(curl -fsSL "https://raw.githubusercontent.com/aydomini/fantastic-probe/main/fantastic-probe-monitor.sh" 2>/dev/null | \
            grep "^VERSION=" | head -1 | cut -d'"' -f2 || echo "")

        if [ -z "$REMOTE_VERSION" ]; then
            echo "   ❌ 无法获取远程版本信息"
            echo "   请检查网络连接或访问: https://github.com/aydomini/fantastic-probe"
            echo ""
            return 1
        fi
        echo "   主分支版本: $REMOTE_VERSION"
    fi

    echo "   最新版本: $REMOTE_VERSION"
    echo ""

    # 比较版本
    if [ "$LOCAL_VERSION" = "$REMOTE_VERSION" ]; then
        echo "   ✅ 已是最新版本"
    else
        echo "   🎉 发现新版本: $LOCAL_VERSION → $REMOTE_VERSION"
        echo ""
        read -p "   是否立即安装更新？[y/N]: " install_now
        if [[ "$install_now" =~ ^[Yy]$ ]]; then
            install_updates
        fi
    fi
    echo ""
}

# 安装更新
install_updates() {
    echo ""
    echo "📦 安装更新"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # 确认操作
    echo "   ⚠️  注意："
    echo "      1. 更新过程中服务将暂时停止"
    echo "      2. 配置文件将保留"
    echo "      3. 建议在任务队列空闲时更新"
    echo ""
    read -p "   确认继续？[y/N]: " confirm
    confirm="${confirm:-N}"

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "   ℹ️  操作已取消"
        echo ""
        return 1
    fi

    # 停止服务
    echo ""
    echo "   ⏹️  停止服务..."
    systemctl stop "$SERVICE_NAME" || true

    # 下载并运行安装脚本（保留配置）
    echo ""
    echo "   📥 下载更新..."
    TEMP_DIR="/tmp/fantastic-probe-update-$$"
    mkdir -p "$TEMP_DIR"

    if curl -fsSL "https://raw.githubusercontent.com/aydomini/fantastic-probe/main/install.sh" -o "$TEMP_DIR/install.sh"; then
        echo "   ✅ 下载完成"
        echo ""
        echo "   🔧 正在安装..."
        echo ""

        # 运行安装脚本（会自动检测并保留配置）
        bash "$TEMP_DIR/install.sh"

        # 清理临时文件
        rm -rf "$TEMP_DIR"

        echo ""
        echo "   ✅ 更新完成！"
        echo ""

        # 重启服务
        echo "   🔄 重启服务..."
        if systemctl restart "$SERVICE_NAME"; then
            echo "   ✅ 服务已启动"
            echo ""
            echo "   查看服务状态: systemctl status $SERVICE_NAME"
            echo "   查看日志:     tail -f /var/log/fantastic_probe.log"
        else
            echo "   ⚠️  服务启动失败，请检查日志"
            echo "   查看详细错误: systemctl status $SERVICE_NAME"
        fi
    else
        echo "   ❌ 下载失败"
        echo "   请检查网络连接或手动更新"
        rm -rf "$TEMP_DIR"

        # 尝试重启服务
        echo ""
        echo "   🔄 尝试重启服务..."
        systemctl start "$SERVICE_NAME" || true
        return 1
    fi
    echo ""
}

# 卸载服务
uninstall_service() {
    echo ""
    echo "🗑️  卸载 Fantastic-Probe"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "   ⚠️  警告："
    echo "      此操作将完全卸载 Fantastic-Probe 服务"
    echo "      包括服务、脚本和系统配置"
    echo ""
    echo "   可选择保留："
    echo "      - 配置文件 (/etc/fantastic-probe/)"
    echo "      - 日志文件 (/var/log/fantastic_probe*.log)"
    echo "      - 生成的 JSON 文件 (*.iso-mediainfo.json)"
    echo ""
    read -p "   确认卸载？请输入 YES 确认: " confirm

    if [ "$confirm" != "YES" ]; then
        echo "   ℹ️  操作已取消"
        echo ""
        return 1
    fi

    # 执行卸载
    echo ""
    echo "   🔧 开始卸载..."
    echo ""

    # 1. 停止服务
    echo "   1️⃣  停止服务..."
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl stop "$SERVICE_NAME"
        echo "      ✅ 服务已停止"
    else
        echo "      ✅ 服务未运行"
    fi

    # 2. 禁用服务
    echo "   2️⃣  禁用服务..."
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl disable "$SERVICE_NAME"
        echo "      ✅ 服务已禁用"
    else
        echo "      ✅ 服务未启用"
    fi

    # 3. 删除服务文件
    echo "   3️⃣  删除服务文件..."
    if [ -f "/etc/systemd/system/$SERVICE_NAME.service" ]; then
        rm -f "/etc/systemd/system/$SERVICE_NAME.service"
        echo "      ✅ 服务文件已删除"
    else
        echo "      ✅ 服务文件不存在"
    fi

    # 4. 重新加载 systemd
    echo "   4️⃣  重新加载 systemd..."
    systemctl daemon-reload
    echo "      ✅ systemd 配置已重新加载"

    # 5. 删除脚本和工具
    echo "   5️⃣  删除脚本和工具..."
    rm -f /usr/local/bin/fantastic-probe-monitor
    rm -f /usr/local/bin/fantastic-probe-auto-update
    rm -f /usr/local/bin/fp-config
    rm -f /usr/local/bin/fantastic-probe-config
    rm -f /usr/local/bin/get-version.sh
    echo "      ✅ 所有脚本已删除"

    # 5.5. 删除预编译包
    if [ -d "/usr/share/fantastic-probe" ]; then
        rm -rf /usr/share/fantastic-probe
        echo "      ✅ 预编译包已删除"
    fi

    # 6. 清理临时文件
    echo "   6️⃣  清理临时文件..."
    rm -f /tmp/fantastic_probe_monitor.lock
    rm -f /tmp/fantastic_probe_queue.fifo
    rm -f /tmp/fantastic-probe-update-marker
    rm -f /tmp/fantastic-probe-auto-update.lock
    rm -rf /tmp/fantastic-probe-install-* 2>/dev/null || true
    echo "      ✅ 临时文件已清理"

    # 7. 清理 logrotate 配置
    echo "   7️⃣  清理 logrotate 配置..."
    if [ -f "/etc/logrotate.d/fantastic-probe" ]; then
        rm -f /etc/logrotate.d/fantastic-probe
        echo "      ✅ logrotate 配置已删除"
    else
        echo "      ✅ logrotate 配置不存在"
    fi

    # 8. 询问是否删除配置文件
    echo ""
    echo "   8️⃣  配置文件处理..."
    if [ -d "/etc/fantastic-probe" ]; then
        read -p "      是否删除配置文件？[y/N]: " delete_config
        if [[ "$delete_config" =~ ^[Yy]$ ]]; then
            rm -rf /etc/fantastic-probe
            echo "      ✅ 配置目录已删除"
        else
            echo "      ℹ️  配置文件保留在: /etc/fantastic-probe/"
        fi
    else
        echo "      ✅ 配置目录不存在"
    fi

    # 9. 询问是否删除日志
    echo ""
    echo "   9️⃣  日志文件处理..."
    read -p "      是否删除日志文件？[y/N]: " delete_logs
    if [[ "$delete_logs" =~ ^[Yy]$ ]]; then
        rm -f /var/log/fantastic_probe.log
        rm -f /var/log/fantastic_probe_errors.log
        echo "      ✅ 日志文件已删除"
    else
        echo "      ℹ️  日志文件保留"
    fi

    # 10. 询问是否删除生成的 JSON 文件
    echo ""
    echo "   🔟 生成的 JSON 文件处理..."
    echo "      ⚠️  注意：删除 JSON 文件会导致 Emby 需要重新扫描媒体库"
    read -p "      是否删除所有 .iso-mediainfo.json 文件？[y/N]: " delete_json

    if [[ "$delete_json" =~ ^[Yy]$ ]] && [ -d "$STRM_ROOT" ]; then
        JSON_COUNT=$(find "$STRM_ROOT" -type f -name "*.iso-mediainfo.json" 2>/dev/null | wc -l)
        if [ "$JSON_COUNT" -gt 0 ]; then
            find "$STRM_ROOT" -type f -name "*.iso-mediainfo.json" -delete
            echo "      ✅ 已删除 $JSON_COUNT 个 JSON 文件"
        else
            echo "      ℹ️  没有找到 JSON 文件"
        fi
    else
        echo "      ℹ️  JSON 文件保留"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   ✅ Fantastic-Probe 卸载完成！"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    exit 0
}

#==============================================================================
# 日志管理函数
#==============================================================================

# 查看实时主日志
view_logs() {
    echo ""
    echo "📝 实时主日志（按 Ctrl+C 退出）"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    tail -f "$LOG_FILE" 2>/dev/null || echo "❌ 日志文件不存在: $LOG_FILE"
}

# 查看错误日志
view_error_logs() {
    echo ""
    echo "⚠️  错误日志（最近 50 行）"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    if [ -f "$ERROR_LOG_FILE" ]; then
        tail -50 "$ERROR_LOG_FILE"
    else
        echo "ℹ️  暂无错误日志"
    fi
    echo ""
}

# 查看系统日志
view_system_logs() {
    echo ""
    echo "🖥️  系统日志（最近 50 行，按 Ctrl+C 退出）"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    journalctl -u "$SERVICE_NAME" -n 50 -f
}

# 清空日志文件
clear_logs() {
    echo ""
    echo "🗑️  清空日志文件"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   ⚠️  警告: 此操作将删除所有历史日志"
    echo ""
    read -p "   确定要清空日志吗？[y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        truncate -s 0 "$LOG_FILE" 2>/dev/null && echo "   ✅ 主日志已清空"
        truncate -s 0 "$ERROR_LOG_FILE" 2>/dev/null && echo "   ✅ 错误日志已清空"
    else
        echo "   ℹ️  操作已取消"
    fi
    echo ""
}

#==============================================================================
# 主菜单
#==============================================================================

show_menu() {
    echo ""
    echo "╔════════════════════════════════════════════════╗"
    echo "║    Fantastic-Probe 管理工具                    ║"
    echo "╚════════════════════════════════════════════════╝"
    echo ""
    echo "  配置管理"
    echo "  ────────"
    echo "  1) 查看当前配置"
    echo "  2) 修改 STRM 根目录"
    echo "  3) 重新配置 FFprobe"
    echo "  4) 修改自动更新设置"
    echo "  5) 直接编辑配置文件"
    echo ""
    echo "  服务管理"
    echo "  ────────"
    echo "  6) 查看服务状态"
    echo "  7) 启动服务"
    echo "  8) 停止服务"
    echo "  9) 重启服务"
    echo ""
    echo "  日志管理"
    echo "  ────────"
    echo "  10) 查看实时日志"
    echo "  11) 查看错误日志"
    echo "  12) 查看系统日志"
    echo "  13) 清空日志文件"
    echo ""
    echo "  系统管理"
    echo "  ────────"
    echo "  14) 检查更新"
    echo "  15) 安装更新"
    echo "  16) 卸载服务"
    echo ""
    echo "  0) 退出"
    echo ""
    read -p "请选择操作 [0-16]: " choice
    echo ""

    case "$choice" in
        1)
            show_current_config
            read -p "按 Enter 返回菜单..."
            ;;
        2)
            change_strm_root
            read -p "按 Enter 返回菜单..."
            ;;
        3)
            reconfigure_ffprobe
            read -p "按 Enter 返回菜单..."
            ;;
        4)
            change_auto_update
            read -p "按 Enter 返回菜单..."
            ;;
        5)
            edit_config_file
            read -p "按 Enter 返回菜单..."
            ;;
        6)
            show_service_status
            read -p "按 Enter 返回菜单..."
            ;;
        7)
            start_service
            read -p "按 Enter 返回菜单..."
            ;;
        8)
            stop_service
            read -p "按 Enter 返回菜单..."
            ;;
        9)
            restart_service
            read -p "按 Enter 返回菜单..."
            ;;
        10)
            view_logs
            ;;
        11)
            view_error_logs
            read -p "按 Enter 返回菜单..."
            ;;
        12)
            view_system_logs
            ;;
        13)
            clear_logs
            read -p "按 Enter 返回菜单..."
            ;;
        14)
            check_updates
            read -p "按 Enter 返回菜单..."
            ;;
        15)
            install_updates
            read -p "按 Enter 返回菜单..."
            ;;
        16)
            uninstall_service
            ;;
        0)
            echo "👋 再见！"
            exit 0
            ;;
        *)
            echo "❌ 无效选择"
            read -p "按 Enter 返回菜单..."
            ;;
    esac
}

#==============================================================================
# 主函数
#==============================================================================

main() {
    check_root
    load_config

    # 如果有参数，直接执行对应功能
    if [ $# -gt 0 ]; then
        case "$1" in
            show|view)
                show_current_config
                ;;
            strm)
                change_strm_root
                ;;
            ffprobe)
                reconfigure_ffprobe
                ;;
            update)
                change_auto_update
                ;;
            edit)
                edit_config_file
                ;;
            restart)
                restart_service
                ;;
            status)
                show_service_status
                ;;
            start)
                start_service
                ;;
            stop)
                stop_service
                ;;
            logs)
                view_logs
                ;;
            logs-error)
                view_error_logs
                ;;
            logs-system)
                view_system_logs
                ;;
            logs-clear)
                clear_logs
                ;;
            check-update)
                check_updates
                ;;
            install-update)
                install_updates
                ;;
            uninstall)
                uninstall_service
                ;;
            *)
                echo "❌ 未知命令: $1"
                echo ""
                echo "用法: fp-config [命令]"
                echo ""
                echo "可用命令："
                echo "  配置管理："
                echo "    show            查看当前配置"
                echo "    strm            修改 STRM 根目录"
                echo "    ffprobe         重新配置 FFprobe"
                echo "    update          修改自动更新设置"
                echo "    edit            直接编辑配置文件"
                echo ""
                echo "  服务管理："
                echo "    restart         重启服务"
                echo "    status          查看服务状态"
                echo "    start           启动服务"
                echo "    stop            停止服务"
                echo ""
                echo "  日志管理："
                echo "    logs            查看实时日志"
                echo "    logs-error      查看错误日志"
                echo "    logs-system     查看系统日志"
                echo "    logs-clear      清空日志文件"
                echo ""
                echo "  系统管理："
                echo "    check-update    检查更新"
                echo "    install-update  安装更新"
                echo "    uninstall       卸载服务"
                echo ""
                exit 1
                ;;
        esac
    else
        # 交互式菜单
        while true; do
            show_menu
        done
    fi
}

main "$@"
