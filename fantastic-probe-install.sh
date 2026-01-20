#!/bin/bash

#==============================================================================
# ISO 媒体信息提取服务 - 安装脚本（实时监控版本）
#==============================================================================

set -e

#==============================================================================
# 包管理器检测和多发行版支持
#==============================================================================

# 检测包管理器
detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        echo "apt"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v yum &> /dev/null; then
        echo "yum"
    elif command -v pacman &> /dev/null; then
        echo "pacman"
    elif command -v zypper &> /dev/null; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

# 检测发行版信息
detect_distro() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        echo "$NAME"
    else
        echo "Unknown"
    fi
}

# 安装软件包（统一接口）
install_package() {
    local pkg_manager="$1"
    shift
    local packages=("$@")

    echo "   使用包管理器: $pkg_manager"
    echo "   安装软件包: ${packages[*]}"

    case "$pkg_manager" in
        apt)
            apt-get update -qq
            apt-get install -y "${packages[@]}"
            ;;
        dnf)
            dnf install -y "${packages[@]}"
            ;;
        yum)
            yum install -y "${packages[@]}"
            ;;
        pacman)
            pacman -Sy --noconfirm "${packages[@]}"
            ;;
        zypper)
            zypper install -y "${packages[@]}"
            ;;
        *)
            echo "❌ 错误: 不支持的包管理器: $pkg_manager"
            return 1
            ;;
    esac
}

# 获取包名（不同发行版的包名可能不同）
get_package_name() {
    local pkg_manager="$1"
    local package_type="$2"

    case "$package_type" in
        inotify-tools)
            echo "inotify-tools"
            ;;
        jq)
            echo "jq"
            ;;
        genisoimage)
            if [ "$pkg_manager" = "pacman" ]; then
                echo "cdrtools"  # Arch Linux 使用 cdrtools
            else
                echo "genisoimage"
            fi
            ;;
        p7zip)
            if [ "$pkg_manager" = "apt" ]; then
                echo "p7zip-full"
            elif [ "$pkg_manager" = "dnf" ] || [ "$pkg_manager" = "yum" ]; then
                echo "p7zip p7zip-plugins"
            else
                echo "p7zip"
            fi
            ;;
        *)
            echo "$package_type"
            ;;
    esac
}

#==============================================================================
# 主安装流程
#==============================================================================

echo "=========================================="
echo "ISO 媒体信息提取服务 - 安装程序"
echo "=========================================="
echo ""

# 检查是否以 root 运行
if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 root 权限运行此脚本"
    echo "   sudo bash $0"
    exit 1
fi

# 检测系统环境
PKG_MANAGER=$(detect_package_manager)
DISTRO=$(detect_distro)

echo "📊 系统信息："
echo "   发行版: $DISTRO"
echo "   包管理器: $PKG_MANAGER"
echo ""

if [ "$PKG_MANAGER" = "unknown" ]; then
    echo "❌ 错误: 无法识别的包管理器"
    echo ""
    echo "支持的发行版："
    echo "  - Debian/Ubuntu (apt)"
    echo "  - RHEL/CentOS/Fedora (dnf/yum)"
    echo "  - Arch Linux/Manjaro (pacman)"
    echo "  - openSUSE (zypper)"
    echo ""
    echo "请手动安装以下依赖："
    echo "  - inotify-tools"
    echo "  - jq"
    echo "  - genisoimage 或 p7zip"
    echo ""
    exit 1
fi

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "📁 脚本目录: $SCRIPT_DIR"
echo ""

# 1. 安装依赖
echo "1️⃣  检查并安装依赖..."
echo ""

PACKAGES_TO_INSTALL=()

# 检查 inotify-tools
if ! command -v inotifywait &> /dev/null; then
    pkg_name=$(get_package_name "$PKG_MANAGER" "inotify-tools")
    echo "   需要安装: $pkg_name (inotify-tools)"
    PACKAGES_TO_INSTALL+=($pkg_name)
fi

# 检查 jq
if ! command -v jq &> /dev/null; then
    pkg_name=$(get_package_name "$PKG_MANAGER" "jq")
    echo "   需要安装: $pkg_name (jq)"
    PACKAGES_TO_INSTALL+=($pkg_name)
fi

# 检查 isoinfo（genisoimage 或 cdrtools）
if ! command -v isoinfo &> /dev/null; then
    pkg_name=$(get_package_name "$PKG_MANAGER" "genisoimage")
    echo "   需要安装: $pkg_name (提供 isoinfo 命令)"
    PACKAGES_TO_INSTALL+=($pkg_name)
fi

# 检查 7z（Blu-ray MPLS 语言提取必需）
if ! command -v 7z &> /dev/null; then
    pkg_name=$(get_package_name "$PKG_MANAGER" "p7zip")
    echo "   需要安装: $pkg_name (Blu-ray MPLS 语言提取必需)"
    PACKAGES_TO_INSTALL+=($pkg_name)
fi

# 安装依赖
if [ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]; then
    echo ""
    install_package "$PKG_MANAGER" "${PACKAGES_TO_INSTALL[@]}"
    echo "   ✅ 依赖安装完成"
else
    echo "   ✅ 所有依赖已安装"
fi
echo ""

# 2. 停止旧服务（如果存在）
echo "2️⃣  停止旧服务..."
if systemctl is-active --quiet fantastic-probe-monitor.service; then
    echo "   停止运行中的服务..."
    systemctl stop fantastic-probe-monitor.service
    echo "   ✅ 服务已停止"
else
    echo "   ✅ 无运行中的服务"
fi
echo ""

# 3. 复制监控脚本
echo "3️⃣  安装监控脚本..."
MONITOR_SCRIPT="$SCRIPT_DIR/fantastic-probe-monitor.sh"
TARGET_SCRIPT="/usr/local/bin/fantastic-probe-monitor"

if [ ! -f "$MONITOR_SCRIPT" ]; then
    echo "   ❌ 找不到监控脚本: $MONITOR_SCRIPT"
    exit 1
fi

cp "$MONITOR_SCRIPT" "$TARGET_SCRIPT"
chmod +x "$TARGET_SCRIPT"
echo "   ✅ 监控脚本已安装到: $TARGET_SCRIPT"

# 安装自动更新助手
AUTO_UPDATE_HELPER="$SCRIPT_DIR/auto-update-helper.sh"
TARGET_HELPER="/usr/local/bin/fantastic-probe-auto-update"

if [ -f "$AUTO_UPDATE_HELPER" ]; then
    cp "$AUTO_UPDATE_HELPER" "$TARGET_HELPER"
    chmod +x "$TARGET_HELPER"
    echo "   ✅ 自动更新助手已安装到: $TARGET_HELPER"
else
    echo "   ⚠️  未找到自动更新助手（跳过，不影响正常使用）"
fi

# 安装配置工具
CONFIG_TOOL="$SCRIPT_DIR/fp-config.sh"
TARGET_CONFIG_TOOL="/usr/local/bin/fp-config"
TARGET_CONFIG_TOOL_OLD="/usr/local/bin/fantastic-probe-config"

if [ -f "$CONFIG_TOOL" ]; then
    cp "$CONFIG_TOOL" "$TARGET_CONFIG_TOOL"
    chmod +x "$TARGET_CONFIG_TOOL"
    echo "   ✅ 配置工具已安装到: $TARGET_CONFIG_TOOL"

    # 创建软链接保持向后兼容
    ln -sf "$TARGET_CONFIG_TOOL" "$TARGET_CONFIG_TOOL_OLD"
    echo "   ✅ 兼容链接已创建: $TARGET_CONFIG_TOOL_OLD"

    echo "      提示：使用 'sudo fp-config' 可随时修改配置"
else
    echo "   ⚠️  未找到配置工具（跳过，不影响正常使用）"
fi
echo ""

# 4. 配置服务（交互式向导）
echo "4️⃣  配置服务..."
CONFIG_DIR="/etc/fantastic-probe"
CONFIG_FILE="$CONFIG_DIR/config"

# 创建配置目录
mkdir -p "$CONFIG_DIR"

# 检查是否存在旧配置
RECONFIGURE_FFPROBE=false
if [ -f "$CONFIG_FILE" ]; then
    echo "   发现现有配置文件: $CONFIG_FILE"
    echo ""
    echo "   配置选项："
    echo "     1) 保留现有配置（推荐，快速升级）"
    echo "     2) 仅重新配置 FFprobe 路径（推荐给想使用预编译包的用户）"
    echo "     3) 完全重新配置（重新设置所有配置项）"
    echo ""
    read -p "   请选择 [1/2/3，默认: 1]: " config_choice
    config_choice="${config_choice:-1}"

    case "$config_choice" in
        1)
            echo "   ✅ 保留现有配置"
            CONFIG_WIZARD_SKIP=true
            ;;
        2)
            echo "   将重新配置 FFprobe 路径..."
            CONFIG_WIZARD_SKIP=true
            RECONFIGURE_FFPROBE=true
            ;;
        3)
            echo "   将完全重新配置..."
            CONFIG_WIZARD_SKIP=false
            ;;
        *)
            echo "   ⚠️  无效选择，默认保留现有配置"
            CONFIG_WIZARD_SKIP=true
            ;;
    esac
    echo ""
fi

# 配置向导
if [ "$CONFIG_WIZARD_SKIP" != "true" ]; then
    echo ""
    echo "   配置向导："
    echo "   ----------"

    # STRM_ROOT 配置
    echo ""
    echo "   📁 STRM 根目录配置"
    echo "      说明：监控的 .iso.strm 文件所在的根目录"
    read -p "      请输入路径 [默认: /mnt/sata1/media/媒体库/strm]: " user_strm_root
    user_strm_root="${user_strm_root:-/mnt/sata1/media/媒体库/strm}"

    # 验证目录是否存在
    if [ ! -d "$user_strm_root" ]; then
        echo "      ⚠️  警告: 目录不存在: $user_strm_root"
        read -p "      是否创建该目录？[Y/n]: " create_dir
        create_dir="${create_dir:-Y}"

        if [[ "$create_dir" =~ ^[Yy]$ ]]; then
            mkdir -p "$user_strm_root"
            echo "      ✅ 目录已创建: $user_strm_root"

            # 权限配置
            echo ""
            echo "      📋 权限配置"
            echo "         说明：如果其他用户（如 Emby、Jellyfin 或普通用户）需要向此目录写入文件，"
            echo "              请指定合适的所有者。"
            echo ""
            echo "         选项："
            echo "           1) 保持 root 所有（仅root可写入）"
            echo "           2) 设置为特定用户（如 emby、jellyfin 等）"
            echo "           3) 设置宽松权限（所有用户可写入，chmod 777）"
            echo ""
            read -p "         请选择 [1/2/3，默认: 1]: " owner_choice
            owner_choice="${owner_choice:-1}"

            case "$owner_choice" in
                1)
                    echo "         ✅ 目录所有者: root:root (仅root可写入)"
                    ;;
                2)
                    read -p "         请输入用户名（如 emby）: " target_user
                    if id "$target_user" &>/dev/null; then
                        chown -R "$target_user:$target_user" "$user_strm_root"
                        chmod 755 "$user_strm_root"
                        echo "         ✅ 目录所有者已设置为: $target_user:$target_user"
                    else
                        echo "         ⚠️  用户 '$target_user' 不存在，保持root所有"
                        echo "         提示：可在安装后手动设置: sudo chown -R 用户名:用户名 $user_strm_root"
                    fi
                    ;;
                3)
                    chmod 777 "$user_strm_root"
                    echo "         ✅ 目录权限已设置为777（所有用户可写入）"
                    echo "         ⚠️  注意：这会降低安全性，仅建议用于测试环境"
                    ;;
                *)
                    echo "         ⚠️  无效选择，保持root所有"
                    ;;
            esac
        else
            echo "      ⚠️  请确保在启动服务前创建该目录"
        fi
    fi

    # FFPROBE 配置
    echo ""
    echo "   🎬 FFprobe 路径配置"
    echo "      说明：ffprobe 用于提取蓝光/DVD 媒体信息"
    echo ""

    # 检测架构
    ARCH=$(uname -m)
    PREBUILT_AVAILABLE=false
    PREBUILT_URL=""
    ARCH_NAME=""
    FFPROBE_RELEASE_TAG="ffprobe-prebuilt-v1.0"  # FFprobe 预编译包版本

    # 根据架构确定下载 URL
    if [ "$ARCH" = "x86_64" ]; then
        PREBUILT_AVAILABLE=true
        PREBUILT_URL="https://github.com/aydomini/fantastic-probe/releases/download/$FFPROBE_RELEASE_TAG/ffprobe_linux_x64.zip"
        ARCH_NAME="x86_64"
    elif [ "$ARCH" = "aarch64" ]; then
        PREBUILT_AVAILABLE=true
        PREBUILT_URL="https://github.com/aydomini/fantastic-probe/releases/download/$FFPROBE_RELEASE_TAG/ffprobe_linux_arm64.zip"
        ARCH_NAME="ARM64"
    fi

    # 自动下载并安装预编译包（优先方案）
    if [ "$PREBUILT_AVAILABLE" = true ]; then
        echo "      ✅ 检测到架构: $ARCH_NAME"
        echo "      ✅ 项目提供了预编译 ffprobe"
        echo ""
        read -p "      是否下载并安装预编译 ffprobe？[Y/n]: " auto_install
        auto_install="${auto_install:-Y}"

        if [[ "$auto_install" =~ ^[Yy]$ ]]; then
            echo ""
            echo "      📥 正在下载预编译 ffprobe..."

            # 检查 unzip 是否可用
            if ! command -v unzip &> /dev/null; then
                echo "      ⚠️  需要安装 unzip 工具"
                install_package "$PKG_MANAGER" "unzip"
            fi

            # 下载到临时目录
            TEMP_DIR="/tmp/ffprobe-install-$$"
            mkdir -p "$TEMP_DIR"

            # 使用 curl 或 wget 下载（带进度条）
            if command -v curl &> /dev/null; then
                if curl -fL "$PREBUILT_URL" -o "$TEMP_DIR/ffprobe.zip" --progress-bar; then
                    echo "      ✅ 下载完成"
                else
                    echo "      ❌ 下载失败"
                    rm -rf "$TEMP_DIR"
                    user_ffprobe=""
                fi
            elif command -v wget &> /dev/null; then
                if wget --show-progress "$PREBUILT_URL" -O "$TEMP_DIR/ffprobe.zip" 2>&1; then
                    echo "      ✅ 下载完成"
                else
                    echo "      ❌ 下载失败"
                    rm -rf "$TEMP_DIR"
                    user_ffprobe=""
                fi
            else
                echo "      ❌ 错误: 需要 curl 或 wget"
                rm -rf "$TEMP_DIR"
                user_ffprobe=""
            fi

            # 如果下载成功，解压并安装
            if [ -f "$TEMP_DIR/ffprobe.zip" ]; then
                echo "      📦 正在安装..."

                if unzip -q "$TEMP_DIR/ffprobe.zip" -d "$TEMP_DIR" 2>/dev/null; then
                    # 安装到 /usr/local/bin
                    if [ -f "$TEMP_DIR/ffprobe" ]; then
                        cp "$TEMP_DIR/ffprobe" /usr/local/bin/ffprobe
                        chmod +x /usr/local/bin/ffprobe
                        user_ffprobe="/usr/local/bin/ffprobe"

                        # 验证安装
                        if /usr/local/bin/ffprobe -version &> /dev/null; then
                            echo "      ✅ ffprobe 已安装到: /usr/local/bin/ffprobe"
                            echo "      ✅ 安装成功！"

                            # 保存下载的 zip 供 fp-config 后续使用
                            TARGET_STATIC_DIR="/usr/share/fantastic-probe/static"
                            mkdir -p "$TARGET_STATIC_DIR"
                            if [ "$ARCH" = "x86_64" ]; then
                                cp "$TEMP_DIR/ffprobe.zip" "$TARGET_STATIC_DIR/ffprobe_linux_x64.zip"
                            else
                                cp "$TEMP_DIR/ffprobe.zip" "$TARGET_STATIC_DIR/ffprobe_linux_arm64.zip"
                            fi
                        else
                            echo "      ❌ 安装失败: ffprobe 无法执行"
                            user_ffprobe=""
                        fi
                    else
                        echo "      ❌ 错误: 解压后未找到 ffprobe"
                        user_ffprobe=""
                    fi
                else
                    echo "      ❌ 解压失败"
                    user_ffprobe=""
                fi
            fi

            # 清理临时文件
            rm -rf "$TEMP_DIR"
        else
            echo "      ℹ️  跳过自动安装，进入手动配置..."
            user_ffprobe=""
        fi
    fi

    # 手动配置（回退方案）
    if [ -z "$user_ffprobe" ]; then
        echo ""
        echo "      🔍 手动配置 FFprobe"
        echo ""
        echo "      选项："
        echo "        1) 使用系统已安装的 ffprobe（需先安装 ffmpeg）"
        echo "        2) 手动指定 ffprobe 路径"
        echo "        3) 跳过配置（稍后使用 fp-config 配置）"
        echo ""
        read -p "      请选择 [1/2/3，默认: 1]: " manual_choice
        manual_choice="${manual_choice:-1}"

        case "$manual_choice" in
            1)
                # 使用系统 ffprobe
                if command -v ffprobe &> /dev/null; then
                    detected_ffprobe=$(command -v ffprobe)
                    echo "      ✅ 检测到: $detected_ffprobe"
                    user_ffprobe="$detected_ffprobe"
                else
                    echo "      ❌ 系统中未检测到 ffprobe"
                    echo ""
                    echo "      请先安装 ffmpeg："
                    echo "         Debian/Ubuntu: apt-get install -y ffmpeg"
                    echo "         RHEL/CentOS:   dnf install -y ffmpeg"
                    echo "         Arch Linux:    pacman -S ffmpeg"
                    echo ""
                    read -p "      现在安装 ffmpeg？[y/N]: " install_now

                    if [[ "$install_now" =~ ^[Yy]$ ]]; then
                        install_package "$PKG_MANAGER" "ffmpeg"
                        if command -v ffprobe &> /dev/null; then
                            user_ffprobe=$(command -v ffprobe)
                            echo "      ✅ ffmpeg 安装成功: $user_ffprobe"
                        else
                            echo "      ❌ 安装失败"
                            user_ffprobe="/usr/bin/ffprobe"  # 占位符
                        fi
                    else
                        user_ffprobe="/usr/bin/ffprobe"  # 占位符
                    fi
                fi
                ;;
            2)
                # 手动指定路径
                echo ""
                read -p "      请输入 ffprobe 完整路径: " user_ffprobe

                if [ -z "$user_ffprobe" ]; then
                    user_ffprobe="/usr/bin/ffprobe"  # 占位符
                    echo "      ⚠️  路径为空，使用默认值: $user_ffprobe"
                fi
                ;;
            3)
                # 跳过配置
                user_ffprobe="/usr/bin/ffprobe"  # 占位符
                echo "      ⚠️  已跳过配置，将使用默认路径: $user_ffprobe"
                ;;
            *)
                user_ffprobe="/usr/bin/ffprobe"  # 占位符
                echo "      ⚠️  无效选择，使用默认值: $user_ffprobe"
                ;;
        esac
    fi

    # 最终验证
    echo ""
    if [ -n "$user_ffprobe" ] && [ -x "$user_ffprobe" ]; then
        echo "      ✅ FFprobe 配置完成: $user_ffprobe"
    else
        echo "      ⚠️  警告: ffprobe 不存在或不可执行: $user_ffprobe"
        echo "      ⚠️  服务可能无法正常启动！"
        echo ""
        echo "      安装后请执行以下操作之一："
        echo "        1) 安装 ffmpeg: apt-get install -y ffmpeg"
        echo "        2) 重新配置: fp-config ffprobe"
        echo "        3) 手动编辑: /etc/fantastic-probe/config"
        echo ""
        read -p "      按回车键继续安装..." dummy
    fi

    echo ""
    echo "   生成配置文件..."

    # 使用配置模板（如果存在）或生成配置
    if [ -f "$SCRIPT_DIR/config/config.template" ]; then
        cp "$SCRIPT_DIR/config/config.template" "$CONFIG_FILE"
        # 替换配置值
        sed -i "s|^STRM_ROOT=.*|STRM_ROOT=\"$user_strm_root\"|" "$CONFIG_FILE"
        sed -i "s|^FFPROBE=.*|FFPROBE=\"$user_ffprobe\"|" "$CONFIG_FILE"
    else
        # 手动生成配置文件
        cat > "$CONFIG_FILE" <<EOF
# Fantastic-Probe 配置文件
# 版本：2.2.0

# STRM 根目录
STRM_ROOT="$user_strm_root"

# FFprobe 路径
FFPROBE="$user_ffprobe"

# 日志文件
LOG_FILE="/var/log/fantastic_probe.log"
ERROR_LOG_FILE="/var/log/fantastic_probe_errors.log"

# 锁文件
LOCK_FILE="/tmp/fantastic_probe_monitor.lock"

# 任务队列文件（FIFO）
QUEUE_FILE="/tmp/fantastic_probe_queue.fifo"

# 超时时间（秒）
FFPROBE_TIMEOUT=300

# 单个文件最大处理时间（秒）
MAX_FILE_PROCESSING_TIME=600

# 防抖时间（秒）
DEBOUNCE_TIME=5

# 自动更新配置
AUTO_UPDATE_CHECK=true
AUTO_UPDATE_INSTALL=false
EOF
    fi

    chmod 644 "$CONFIG_FILE"
    echo "   ✅ 配置文件已生成: $CONFIG_FILE"
    echo ""
    echo "   配置摘要："
    echo "   - STRM 目录: $user_strm_root"
    echo "   - FFprobe 路径: $user_ffprobe"
    echo ""
fi

# 4.5. 单独重新配置 FFprobe（针对老用户升级）
if [ "$RECONFIGURE_FFPROBE" = "true" ]; then
    echo ""
    echo "4️⃣.5️⃣  重新配置 FFprobe..."
    echo ""
    echo "   🎬 FFprobe 路径配置"
    echo "      说明：ffprobe 用于提取蓝光/DVD 媒体信息"
    echo ""

    # 检测架构
    ARCH=$(uname -m)
    PREBUILT_AVAILABLE=false
    PREBUILT_URL=""
    ARCH_NAME=""
    FFPROBE_RELEASE_TAG="ffprobe-prebuilt-v1.0"  # FFprobe 预编译包版本

    # 根据架构确定下载 URL
    if [ "$ARCH" = "x86_64" ]; then
        PREBUILT_AVAILABLE=true
        PREBUILT_URL="https://github.com/aydomini/fantastic-probe/releases/download/$FFPROBE_RELEASE_TAG/ffprobe_linux_x64.zip"
        ARCH_NAME="x86_64"
    elif [ "$ARCH" = "aarch64" ]; then
        PREBUILT_AVAILABLE=true
        PREBUILT_URL="https://github.com/aydomini/fantastic-probe/releases/download/$FFPROBE_RELEASE_TAG/ffprobe_linux_arm64.zip"
        ARCH_NAME="ARM64"
    fi

    # 自动下载并安装预编译包（优先方案）
    user_ffprobe=""
    if [ "$PREBUILT_AVAILABLE" = true ]; then
        echo "      ✅ 检测到架构: $ARCH_NAME"
        echo "      ✅ 项目提供了预编译 ffprobe"
        echo ""
        read -p "      是否下载并安装预编译 ffprobe？[Y/n]: " auto_install
        auto_install="${auto_install:-Y}"

        if [[ "$auto_install" =~ ^[Yy]$ ]]; then
            echo ""
            echo "      📥 正在下载预编译 ffprobe..."

            # 检查 unzip 是否可用
            if ! command -v unzip &> /dev/null; then
                echo "      ⚠️  需要安装 unzip 工具"
                install_package "$PKG_MANAGER" "unzip"
            fi

            # 下载到临时目录
            TEMP_DIR="/tmp/ffprobe-install-$$"
            mkdir -p "$TEMP_DIR"

            # 使用 curl 或 wget 下载（带进度条）
            if command -v curl &> /dev/null; then
                if curl -fL "$PREBUILT_URL" -o "$TEMP_DIR/ffprobe.zip" --progress-bar; then
                    echo "      ✅ 下载完成"
                else
                    echo "      ❌ 下载失败"
                    rm -rf "$TEMP_DIR"
                    user_ffprobe=""
                fi
            elif command -v wget &> /dev/null; then
                if wget --show-progress "$PREBUILT_URL" -O "$TEMP_DIR/ffprobe.zip" 2>&1; then
                    echo "      ✅ 下载完成"
                else
                    echo "      ❌ 下载失败"
                    rm -rf "$TEMP_DIR"
                    user_ffprobe=""
                fi
            else
                echo "      ❌ 错误: 需要 curl 或 wget"
                rm -rf "$TEMP_DIR"
                user_ffprobe=""
            fi

            # 如果下载成功，解压并安装
            if [ -f "$TEMP_DIR/ffprobe.zip" ]; then
                echo "      📦 正在安装..."

                if unzip -q "$TEMP_DIR/ffprobe.zip" -d "$TEMP_DIR" 2>/dev/null; then
                    # 安装到 /usr/local/bin
                    if [ -f "$TEMP_DIR/ffprobe" ]; then
                        cp "$TEMP_DIR/ffprobe" /usr/local/bin/ffprobe
                        chmod +x /usr/local/bin/ffprobe
                        user_ffprobe="/usr/local/bin/ffprobe"

                        # 验证安装
                        if /usr/local/bin/ffprobe -version &> /dev/null; then
                            echo "      ✅ ffprobe 已安装到: /usr/local/bin/ffprobe"
                            echo "      ✅ 安装成功！"

                            # 保存下载的 zip 供 fp-config 后续使用
                            TARGET_STATIC_DIR="/usr/share/fantastic-probe/static"
                            mkdir -p "$TARGET_STATIC_DIR"
                            if [ "$ARCH" = "x86_64" ]; then
                                cp "$TEMP_DIR/ffprobe.zip" "$TARGET_STATIC_DIR/ffprobe_linux_x64.zip"
                            else
                                cp "$TEMP_DIR/ffprobe.zip" "$TARGET_STATIC_DIR/ffprobe_linux_arm64.zip"
                            fi
                        else
                            echo "      ❌ 安装失败: ffprobe 无法执行"
                            user_ffprobe=""
                        fi
                    else
                        echo "      ❌ 错误: 解压后未找到 ffprobe"
                        user_ffprobe=""
                    fi
                else
                    echo "      ❌ 解压失败"
                    user_ffprobe=""
                fi
            fi

            # 清理临时文件
            rm -rf "$TEMP_DIR"
        else
            echo "      ℹ️  跳过自动安装，进入手动配置..."
        fi
    fi

    # 手动配置（回退方案）
    if [ -z "$user_ffprobe" ]; then
        echo ""
        echo "      🔍 手动配置 FFprobe"
        echo ""
        echo "      选项："
        echo "        1) 使用系统已安装的 ffprobe（需先安装 ffmpeg）"
        echo "        2) 手动指定 ffprobe 路径"
        echo "        3) 保持原配置不变"
        echo ""
        read -p "      请选择 [1/2/3，默认: 1]: " manual_choice
        manual_choice="${manual_choice:-1}"

        case "$manual_choice" in
            1)
                # 使用系统 ffprobe
                if command -v ffprobe &> /dev/null; then
                    detected_ffprobe=$(command -v ffprobe)
                    echo "      ✅ 检测到: $detected_ffprobe"
                    user_ffprobe="$detected_ffprobe"
                else
                    echo "      ❌ 系统中未检测到 ffprobe"
                    echo ""
                    echo "      请先安装 ffmpeg："
                    echo "         Debian/Ubuntu: apt-get install -y ffmpeg"
                    echo "         RHEL/CentOS:   dnf install -y ffmpeg"
                    echo "         Arch Linux:    pacman -S ffmpeg"
                    echo ""
                    read -p "      现在安装 ffmpeg？[y/N]: " install_now

                    if [[ "$install_now" =~ ^[Yy]$ ]]; then
                        install_package "$PKG_MANAGER" "ffmpeg"
                        if command -v ffprobe &> /dev/null; then
                            user_ffprobe=$(command -v ffprobe)
                            echo "      ✅ ffmpeg 安装成功: $user_ffprobe"
                        else
                            echo "      ❌ 安装失败，保持原配置"
                            # 读取原配置
                            if [ -f "$CONFIG_FILE" ]; then
                                user_ffprobe=$(grep "^FFPROBE=" "$CONFIG_FILE" | cut -d'"' -f2)
                            fi
                        fi
                    else
                        # 读取原配置
                        if [ -f "$CONFIG_FILE" ]; then
                            user_ffprobe=$(grep "^FFPROBE=" "$CONFIG_FILE" | cut -d'"' -f2)
                            echo "      保持原配置: $user_ffprobe"
                        fi
                    fi
                fi
                ;;
            2)
                # 手动指定路径
                echo ""
                read -p "      请输入 ffprobe 完整路径: " user_ffprobe

                if [ -z "$user_ffprobe" ]; then
                    # 读取原配置
                    if [ -f "$CONFIG_FILE" ]; then
                        user_ffprobe=$(grep "^FFPROBE=" "$CONFIG_FILE" | cut -d'"' -f2)
                        echo "      ⚠️  路径为空，保持原配置: $user_ffprobe"
                    else
                        user_ffprobe="/usr/bin/ffprobe"
                        echo "      ⚠️  路径为空，使用默认值: $user_ffprobe"
                    fi
                fi
                ;;
            3)
                # 保持原配置
                if [ -f "$CONFIG_FILE" ]; then
                    user_ffprobe=$(grep "^FFPROBE=" "$CONFIG_FILE" | cut -d'"' -f2)
                    echo "      保持原配置: $user_ffprobe"
                else
                    user_ffprobe="/usr/bin/ffprobe"
                    echo "      ⚠️  配置文件不存在，使用默认值: $user_ffprobe"
                fi
                ;;
            *)
                # 读取原配置
                if [ -f "$CONFIG_FILE" ]; then
                    user_ffprobe=$(grep "^FFPROBE=" "$CONFIG_FILE" | cut -d'"' -f2)
                    echo "      ⚠️  无效选择，保持原配置: $user_ffprobe"
                else
                    user_ffprobe="/usr/bin/ffprobe"
                    echo "      ⚠️  无效选择，使用默认值: $user_ffprobe"
                fi
                ;;
        esac
    fi

    # 更新配置文件
    if [ -n "$user_ffprobe" ] && [ -f "$CONFIG_FILE" ]; then
        sed -i.bak "s|^FFPROBE=.*|FFPROBE=\"$user_ffprobe\"|" "$CONFIG_FILE"
        rm -f "$CONFIG_FILE.bak"
        echo ""
        echo "   ✅ FFprobe 路径已更新: $user_ffprobe"

        # 验证是否可执行
        if [ ! -x "$user_ffprobe" ]; then
            echo ""
            echo "   ⚠️  警告: ffprobe 不存在或不可执行: $user_ffprobe"
            echo "   ⚠️  服务可能无法正常启动！"
            echo ""
            echo "   请执行以下操作之一："
            echo "     1) 安装 ffmpeg: apt-get install -y ffmpeg"
            echo "     2) 重新配置: fp-config ffprobe"
            echo "     3) 手动编辑: /etc/fantastic-probe/config"
            echo ""
            read -p "   按回车键继续..." dummy
        fi
    elif [ -z "$user_ffprobe" ]; then
        echo "   ❌ 错误: ffprobe 路径为空，无法更新配置"
    elif [ ! -f "$CONFIG_FILE" ]; then
        echo "   ❌ 错误: 配置文件不存在: $CONFIG_FILE"
    fi
    echo ""
fi

# 5. 安装 systemd 服务
echo "5️⃣  安装 systemd 服务..."
SERVICE_FILE="$SCRIPT_DIR/fantastic-probe-monitor.service"
TARGET_SERVICE="/etc/systemd/system/fantastic-probe-monitor.service"

if [ ! -f "$SERVICE_FILE" ]; then
    echo "   ❌ 找不到服务文件: $SERVICE_FILE"
    exit 1
fi

cp "$SERVICE_FILE" "$TARGET_SERVICE"
chmod 644 "$TARGET_SERVICE"
echo "   ✅ 服务文件已安装到: $TARGET_SERVICE"
echo ""

# 6. 创建日志文件
echo "6️⃣  创建日志文件..."
touch /var/log/fantastic_probe.log
touch /var/log/fantastic_probe_errors.log
chmod 644 /var/log/fantastic_probe.log
chmod 644 /var/log/fantastic_probe_errors.log
echo "   ✅ 日志文件已创建"
echo ""

# 7. 配置 logrotate（日志轮转）
echo "7️⃣  配置日志轮转..."
LOGROTATE_FILE="$SCRIPT_DIR/logrotate-fantastic-probe.conf"
TARGET_LOGROTATE="/etc/logrotate.d/fantastic-probe"

if [ -f "$LOGROTATE_FILE" ]; then
    cp "$LOGROTATE_FILE" "$TARGET_LOGROTATE"
    chmod 644 "$TARGET_LOGROTATE"
    echo "   ✅ logrotate 配置已安装"
    echo "   ℹ️  日志文件达到 10MB 时自动轮转，保留最近 1 个备份（总空间约 20MB）"
else
    echo "   ⚠️  找不到 logrotate 配置文件，跳过（日志将不会自动轮转）"
fi
echo ""

# 8. 重新加载 systemd
echo "8️⃣  重新加载 systemd..."
systemctl daemon-reload
echo "   ✅ systemd 配置已重新加载"
echo ""

# 9. 启用服务（开机自启）
echo "9️⃣  启用服务（开机自启）..."
systemctl enable fantastic-probe-monitor.service
echo "   ✅ 服务已设置为开机自启"
echo ""

# 10. 启动服务
echo "🔟 启动服务..."
systemctl start fantastic-probe-monitor.service
sleep 2

if systemctl is-active --quiet fantastic-probe-monitor.service; then
    echo "   ✅ 服务启动成功"
else
    echo "   ❌ 服务启动失败"
    echo ""
    echo "   查看错误信息:"
    systemctl status fantastic-probe-monitor.service
    exit 1
fi
echo ""

# 9. 显示服务状态
echo "9️⃣  服务状态:"
systemctl status fantastic-probe-monitor.service --no-pager -l
echo ""

# 10. 移除旧的 cron 任务（如果存在）
echo "🔟 清理旧的 cron 任务..."
if crontab -l 2>/dev/null | grep -q "fantastic-probe"; then
    echo "   检测到旧的 cron 任务，建议手动清理:"
    echo "   crontab -e"
    echo "   删除包含 'fantastic-probe' 的行"
    echo ""
    echo "   ⚠️  提示：现在使用实时监控，无需 cron 定时任务"
else
    echo "   ✅ 无旧的 cron 任务"
fi
echo ""

# 安装完成
echo "=========================================="
echo "✅ 安装完成！"
echo "=========================================="
echo ""
echo "📝 常用命令:"
echo ""
echo "  查看服务状态:"
echo "    systemctl status fantastic-probe-monitor"
echo ""
echo "  查看实时日志:"
echo "    tail -f /var/log/fantastic_probe.log"
echo ""
echo "  查看错误日志:"
echo "    tail -f /var/log/fantastic_probe_errors.log"
echo ""
echo "  查看系统日志:"
echo "    journalctl -u fantastic-probe-monitor -f"
echo ""
echo "  停止服务:"
echo "    systemctl stop fantastic-probe-monitor"
echo ""
echo "  启动服务:"
echo "    systemctl start fantastic-probe-monitor"
echo ""
echo "  重启服务:"
echo "    systemctl restart fantastic-probe-monitor"
echo ""
echo "  禁用开机自启:"
echo "    systemctl disable fantastic-probe-monitor"
echo ""
echo "=========================================="
echo "🎉 服务现在正在后台运行，实时监控 .iso.strm 文件！"
echo "=========================================="
