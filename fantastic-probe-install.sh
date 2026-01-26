#!/bin/bash
export LC_ALL=C.UTF-8

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
        sqlite3)
            if [ "$pkg_manager" = "apt" ]; then
                echo "sqlite3"
            elif [ "$pkg_manager" = "pacman" ]; then
                echo "sqlite"
            else
                echo "sqlite3"
            fi
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
    echo "  - genisoimage"
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

# 检查 sqlite3（Cron 模式必需）
if ! command -v sqlite3 &> /dev/null; then
    pkg_name=$(get_package_name "$PKG_MANAGER" "sqlite3")
    echo "   需要安装: $pkg_name (sqlite3，Cron 模式必需)"
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

# 检查 inotify-tools（inotify 模式可选，Cron 模式不需要）
if ! command -v inotifywait &> /dev/null; then
    echo "   ⚠️  inotify-tools 未安装（仅 inotify 模式需要，Cron 模式不需要）"
    echo "      默认使用 Cron 模式，跳过 inotify-tools 安装"
    echo "      如需使用 inotify 模式，请手动安装: apt-get install inotify-tools"
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

# 2. 安装 Cron 扫描器和处理库
echo "2️⃣  安装 Cron 扫描器和处理库..."

# 安装版本号获取脚本（支持动态版本号）
VERSION_SCRIPT="$SCRIPT_DIR/get-version.sh"
TARGET_VERSION_SCRIPT="/usr/local/bin/get-version.sh"

if [ -f "$VERSION_SCRIPT" ]; then
    cp "$VERSION_SCRIPT" "$TARGET_VERSION_SCRIPT"
    chmod +x "$TARGET_VERSION_SCRIPT"
    echo "   ✅ 版本号获取脚本已安装到: $TARGET_VERSION_SCRIPT"
else
    echo "   ⚠️  版本号获取脚本不存在（不影响正常使用，将使用硬编码版本号）"
fi
echo ""

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

# 安装 Cron 扫描器和处理库（Cron 模式必需）
echo "   ✅ 安装 Cron 扫描器和处理库..."

CRON_SCANNER="$SCRIPT_DIR/fantastic-probe-cron-scanner.sh"
PROCESS_LIB="$SCRIPT_DIR/fantastic-probe-process-lib.sh"
TARGET_CRON_SCANNER="/usr/local/bin/fantastic-probe-cron-scanner"
TARGET_PROCESS_LIB="/usr/local/lib/fantastic-probe-process-lib.sh"

# 检查文件是否存在
if [ -f "$CRON_SCANNER" ]; then
    cp "$CRON_SCANNER" "$TARGET_CRON_SCANNER"
    chmod +x "$TARGET_CRON_SCANNER"
    echo "   ✅ Cron 扫描器已安装到: $TARGET_CRON_SCANNER"
else
    echo "   ⚠️  未找到 Cron 扫描器（跳过，不影响正常使用）"
fi

if [ -f "$PROCESS_LIB" ]; then
    mkdir -p /usr/local/lib
    cp "$PROCESS_LIB" "$TARGET_PROCESS_LIB"
    chmod +x "$TARGET_PROCESS_LIB"
    echo "   ✅ 处理库已安装到: $TARGET_PROCESS_LIB"
else
    echo "   ⚠️  未找到处理库（跳过，不影响正常使用）"
fi

# 创建失败缓存目录（Cron 模式使用）
echo "   ✅ 创建失败缓存目录..."
mkdir -p /var/lib/fantastic-probe
chmod 755 /var/lib/fantastic-probe
echo "   ✅ 缓存目录已创建: /var/lib/fantastic-probe"

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

    # 检测架构和可用选项
    ARCH=$(uname -m)
    PREBUILT_AVAILABLE=false
    PREBUILT_URL=""
    LOCAL_PREBUILT=""
    ARCH_NAME=""
    FFPROBE_RELEASE_TAG="ffprobe-prebuilt-v1.0"

    if [ "$ARCH" = "x86_64" ]; then
        ARCH_NAME="x86_64"
        PREBUILT_URL="https://github.com/aydomini/fantastic-probe/releases/download/$FFPROBE_RELEASE_TAG/ffprobe_linux_x64.zip"
        # 检查本地是否有预编译包
        if [ -f "$SCRIPT_DIR/static/ffprobe_linux_x64.zip" ]; then
            LOCAL_PREBUILT="$SCRIPT_DIR/static/ffprobe_linux_x64.zip"
            PREBUILT_AVAILABLE=true
        else
            PREBUILT_AVAILABLE=true  # 可以从 GitHub 下载
        fi
    elif [ "$ARCH" = "aarch64" ]; then
        ARCH_NAME="ARM64"
        PREBUILT_URL="https://github.com/aydomini/fantastic-probe/releases/download/$FFPROBE_RELEASE_TAG/ffprobe_linux_arm64.zip"
        # 检查本地是否有预编译包
        if [ -f "$SCRIPT_DIR/static/ffprobe_linux_arm64.zip" ]; then
            LOCAL_PREBUILT="$SCRIPT_DIR/static/ffprobe_linux_arm64.zip"
            PREBUILT_AVAILABLE=true
        else
            PREBUILT_AVAILABLE=true  # 可以从 GitHub 下载
        fi
    fi

    # 展示选项菜单
    echo "      ✅ 检测到架构: $ARCH_NAME"
    echo ""
    echo "      选项："

    if [ "$PREBUILT_AVAILABLE" = true ]; then
        if [ -n "$LOCAL_PREBUILT" ]; then
            echo "        1) 使用项目提供的预编译 ffprobe（推荐，本地已包含）"
        else
            echo "        1) 使用项目提供的预编译 ffprobe（推荐，需从 GitHub 下载）"
        fi
    fi
    echo "        2) 使用系统已安装的 ffprobe（需先安装 ffmpeg）"
    echo "        3) 手动指定 ffprobe 路径"
    echo ""

    read -p "      请选择 [1/2/3，默认: 1]: " ffprobe_choice
    ffprobe_choice="${ffprobe_choice:-1}"

    case "$ffprobe_choice" in
        1)
            # 使用项目预编译包
            if [ "$PREBUILT_AVAILABLE" = false ]; then
                echo "      ❌ 当前架构不支持预编译包"
                user_ffprobe=""
            else
                echo ""

                # 检查 unzip
                if ! command -v unzip &> /dev/null; then
                    echo "      ⚠️  需要安装 unzip 工具"
                    install_package "$PKG_MANAGER" "unzip"
                fi

                TEMP_DIR="/tmp/ffprobe-install-$$"
                mkdir -p "$TEMP_DIR"

                PREBUILT_SOURCE=""

                # 优先使用本地预编译包
                if [ -n "$LOCAL_PREBUILT" ]; then
                    echo "      📦 使用本地预编译包..."
                    PREBUILT_SOURCE="$LOCAL_PREBUILT"
                else
                    # 从 GitHub 下载
                    echo "      📥 从 GitHub 下载预编译 ffprobe..."

                    if command -v curl &> /dev/null; then
                        if curl -fL "$PREBUILT_URL" -o "$TEMP_DIR/ffprobe.zip" --progress-bar; then
                            echo "      ✅ 下载完成"
                            PREBUILT_SOURCE="$TEMP_DIR/ffprobe.zip"
                        else
                            echo "      ❌ 下载失败"
                        fi
                    elif command -v wget &> /dev/null; then
                        if wget --show-progress "$PREBUILT_URL" -O "$TEMP_DIR/ffprobe.zip" 2>&1; then
                            echo "      ✅ 下载完成"
                            PREBUILT_SOURCE="$TEMP_DIR/ffprobe.zip"
                        else
                            echo "      ❌ 下载失败"
                        fi
                    else
                        echo "      ❌ 错误: 需要 curl 或 wget"
                    fi
                fi

                # 解压并安装
                if [ -n "$PREBUILT_SOURCE" ]; then
                    echo "      📦 正在安装..."

                    if unzip -q "$PREBUILT_SOURCE" -d "$TEMP_DIR" 2>/dev/null; then
                        if [ -f "$TEMP_DIR/ffprobe" ]; then
                            cp "$TEMP_DIR/ffprobe" /usr/local/bin/ffprobe
                            chmod +x /usr/local/bin/ffprobe

                            if /usr/local/bin/ffprobe -version &> /dev/null; then
                                echo "      ✅ ffprobe 已安装到: /usr/local/bin/ffprobe"
                                user_ffprobe="/usr/local/bin/ffprobe"

                                # 保存到系统缓存供 fp-config 使用
                                TARGET_STATIC_DIR="/usr/share/fantastic-probe/static"
                                mkdir -p "$TARGET_STATIC_DIR"
                                if [ "$ARCH" = "x86_64" ]; then
                                    cp "$PREBUILT_SOURCE" "$TARGET_STATIC_DIR/ffprobe_linux_x64.zip"
                                else
                                    cp "$PREBUILT_SOURCE" "$TARGET_STATIC_DIR/ffprobe_linux_arm64.zip"
                                fi
                                echo "      ✅ 安装成功！"
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
                else
                    user_ffprobe=""
                fi

                # 清理临时文件
                rm -rf "$TEMP_DIR"
            fi
            ;;
        2)
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
                        user_ffprobe=""
                    fi
                else
                    user_ffprobe=""
                fi
            fi
            ;;
        3)
            # 手动指定路径
            echo ""
            read -p "      请输入 ffprobe 完整路径: " user_ffprobe

            if [ -z "$user_ffprobe" ]; then
                echo "      ⚠️  路径为空"
                user_ffprobe=""
            elif [ ! -f "$user_ffprobe" ]; then
                echo "      ⚠️  文件不存在: $user_ffprobe"
                user_ffprobe=""
            elif [ ! -x "$user_ffprobe" ]; then
                echo "      ⚠️  文件不可执行: $user_ffprobe"
                user_ffprobe=""
            else
                echo "      ✅ 使用指定路径: $user_ffprobe"
            fi
            ;;
        *)
            echo "      ⚠️  无效选择"
            user_ffprobe=""
            ;;
    esac

    # 如果上述方法都失败，提供最后机会
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

# Emby 媒体库集成（可选）
EMBY_ENABLED=false
EMBY_URL=""
EMBY_API_KEY=""
EMBY_NOTIFY_TIMEOUT=5
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

    # 检测架构和可用选项
    ARCH=$(uname -m)
    PREBUILT_AVAILABLE=false
    PREBUILT_URL=""
    LOCAL_PREBUILT=""
    ARCH_NAME=""
    FFPROBE_RELEASE_TAG="ffprobe-prebuilt-v1.0"

    if [ "$ARCH" = "x86_64" ]; then
        ARCH_NAME="x86_64"
        PREBUILT_URL="https://github.com/aydomini/fantastic-probe/releases/download/$FFPROBE_RELEASE_TAG/ffprobe_linux_x64.zip"
        # 检查本地是否有预编译包
        if [ -f "$SCRIPT_DIR/static/ffprobe_linux_x64.zip" ]; then
            LOCAL_PREBUILT="$SCRIPT_DIR/static/ffprobe_linux_x64.zip"
            PREBUILT_AVAILABLE=true
        else
            PREBUILT_AVAILABLE=true  # 可以从 GitHub 下载
        fi
    elif [ "$ARCH" = "aarch64" ]; then
        ARCH_NAME="ARM64"
        PREBUILT_URL="https://github.com/aydomini/fantastic-probe/releases/download/$FFPROBE_RELEASE_TAG/ffprobe_linux_arm64.zip"
        # 检查本地是否有预编译包
        if [ -f "$SCRIPT_DIR/static/ffprobe_linux_arm64.zip" ]; then
            LOCAL_PREBUILT="$SCRIPT_DIR/static/ffprobe_linux_arm64.zip"
            PREBUILT_AVAILABLE=true
        else
            PREBUILT_AVAILABLE=true  # 可以从 GitHub 下载
        fi
    fi

    # 展示选项菜单
    echo "      ✅ 检测到架构: $ARCH_NAME"
    echo ""
    echo "      选项："

    if [ "$PREBUILT_AVAILABLE" = true ]; then
        if [ -n "$LOCAL_PREBUILT" ]; then
            echo "        1) 使用项目提供的预编译 ffprobe（推荐，本地已包含）"
        else
            echo "        1) 使用项目提供的预编译 ffprobe（推荐，需从 GitHub 下载）"
        fi
    fi
    echo "        2) 使用系统已安装的 ffprobe（需先安装 ffmpeg）"
    echo "        3) 手动指定 ffprobe 路径"
    echo ""

    read -p "      请选择 [1/2/3，默认: 1]: " ffprobe_choice
    ffprobe_choice="${ffprobe_choice:-1}"

    # 自动下载并安装预编译包（优先方案）
    user_ffprobe=""

    case "$ffprobe_choice" in
        1)
            # 使用项目预编译包
            if [ "$PREBUILT_AVAILABLE" = false ]; then
                echo "      ❌ 当前架构不支持预编译包"
                user_ffprobe=""
            else
                echo ""

                # 检查 unzip
                if ! command -v unzip &> /dev/null; then
                    echo "      ⚠️  需要安装 unzip 工具"
                    install_package "$PKG_MANAGER" "unzip"
                fi

                TEMP_DIR="/tmp/ffprobe-install-$$"
                mkdir -p "$TEMP_DIR"

                PREBUILT_SOURCE=""

                # 优先使用本地预编译包
                if [ -n "$LOCAL_PREBUILT" ]; then
                    echo "      📦 使用本地预编译包..."
                    PREBUILT_SOURCE="$LOCAL_PREBUILT"
                else
                    # 从 GitHub 下载
                    echo "      📥 从 GitHub 下载预编译 ffprobe..."

                    if command -v curl &> /dev/null; then
                        if curl -fL "$PREBUILT_URL" -o "$TEMP_DIR/ffprobe.zip" --progress-bar; then
                            echo "      ✅ 下载完成"
                            PREBUILT_SOURCE="$TEMP_DIR/ffprobe.zip"
                        else
                            echo "      ❌ 下载失败"
                        fi
                    elif command -v wget &> /dev/null; then
                        if wget --show-progress "$PREBUILT_URL" -O "$TEMP_DIR/ffprobe.zip" 2>&1; then
                            echo "      ✅ 下载完成"
                            PREBUILT_SOURCE="$TEMP_DIR/ffprobe.zip"
                        else
                            echo "      ❌ 下载失败"
                        fi
                    else
                        echo "      ❌ 错误: 需要 curl 或 wget"
                    fi
                fi

                # 解压并安装
                if [ -n "$PREBUILT_SOURCE" ]; then
                    echo "      📦 正在安装..."

                    if unzip -q "$PREBUILT_SOURCE" -d "$TEMP_DIR" 2>/dev/null; then
                        if [ -f "$TEMP_DIR/ffprobe" ]; then
                            cp "$TEMP_DIR/ffprobe" /usr/local/bin/ffprobe
                            chmod +x /usr/local/bin/ffprobe

                            if /usr/local/bin/ffprobe -version &> /dev/null; then
                                echo "      ✅ ffprobe 已安装到: /usr/local/bin/ffprobe"
                                user_ffprobe="/usr/local/bin/ffprobe"

                                # 保存到系统缓存供 fp-config 使用
                                TARGET_STATIC_DIR="/usr/share/fantastic-probe/static"
                                mkdir -p "$TARGET_STATIC_DIR"
                                if [ "$ARCH" = "x86_64" ]; then
                                    cp "$PREBUILT_SOURCE" "$TARGET_STATIC_DIR/ffprobe_linux_x64.zip"
                                else
                                    cp "$PREBUILT_SOURCE" "$TARGET_STATIC_DIR/ffprobe_linux_arm64.zip"
                                fi
                                echo "      ✅ 安装成功！"
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
                else
                    user_ffprobe=""
                fi

                # 清理临时文件
                rm -rf "$TEMP_DIR"
            fi
            ;;
        2)
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
                        user_ffprobe=""
                    fi
                else
                    user_ffprobe=""
                fi
            fi
            ;;
        3)
            # 手动指定路径
            echo ""
            read -p "      请输入 ffprobe 完整路径: " user_ffprobe

            if [ -z "$user_ffprobe" ]; then
                echo "      ⚠️  路径为空"
                user_ffprobe=""
            elif [ ! -f "$user_ffprobe" ]; then
                echo "      ⚠️  文件不存在: $user_ffprobe"
                user_ffprobe=""
            elif [ ! -x "$user_ffprobe" ]; then
                echo "      ⚠️  文件不可执行: $user_ffprobe"
                user_ffprobe=""
            else
                echo "      ✅ 使用指定路径: $user_ffprobe"
            fi
            ;;
        *)
            echo "      ⚠️  无效选择"
            user_ffprobe=""
            ;;
    esac

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

# 5. 创建日志文件
echo "5️⃣  创建日志文件..."
touch /var/log/fantastic_probe.log
touch /var/log/fantastic_probe_errors.log
chmod 644 /var/log/fantastic_probe.log
chmod 644 /var/log/fantastic_probe_errors.log
echo "   ✅ 日志文件已创建"
echo ""

# 6. 配置 logrotate（日志轮转）
echo "6️⃣  配置日志轮转..."
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

# 7. 配置 Cron 任务（Cron 模式）
echo "7️⃣  配置 Cron 任务..."

CRON_FILE="/etc/cron.d/fantastic-probe"

# 检查是否已存在
if [ -f "$CRON_FILE" ]; then
    echo "   ℹ️  Cron 任务文件已存在，将覆盖"
    rm -f "$CRON_FILE"
fi

# 创建 Cron 任务文件
cat > "$CRON_FILE" <<'CRONEOF'
# Fantastic-Probe Cron 扫描任务
# 每分钟执行一次扫描

SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 每分钟执行一次扫描（默认 Cron 模式）
*/1 * * * * root /usr/local/bin/fantastic-probe-cron-scanner scan >> /var/log/fantastic_probe.log 2>&1

# 每小时清理孤立锁文件
0 * * * * root rm -f /tmp/fantastic_probe_cron_scanner.lock 2>/dev/null || true
CRONEOF

chmod 644 "$CRON_FILE"
echo "   ✅ Cron 任务已配置: $CRON_FILE"
echo "   ℹ️  默认模式: Cron（每分钟扫描一次）"
echo "   ℹ️  如需切换到 inotify 实时监控模式，请使用: fp-config"
echo ""

# 8. 清理旧的 cron 任务（如果存在）
echo "8️⃣  清理旧的 cron 任务..."
if crontab -l 2>/dev/null | grep -q "fantastic-probe"; then
    echo "   检测到旧的 cron 任务（用户级别），建议手动清理:"
    echo "   crontab -e"
    echo "   删除包含 'fantastic-probe' 的行"
else
    echo "   ✅ 无旧的 cron 任务"
fi
echo ""

# 安装完成
echo "=========================================="
echo "✅ 安装完成！"
echo "=========================================="
echo ""
echo "ℹ️  Fantastic-Probe 现在使用 Cron 模式（每分钟扫描一次）"
echo ""
echo "📝 常用命令:"
echo ""
echo "  查看 Cron 执行日志:"
echo "    tail -f /var/log/fantastic_probe.log"
echo ""
echo "  查看错误日志:"
echo "    tail -f /var/log/fantastic_probe_errors.log"
echo ""
echo "  查看失败文件列表:"
echo "    fp-config failure-list"
echo ""
echo "  清空失败缓存:"
echo "    fp-config failure-clear"
echo ""
echo "  重置单个文件的失败记录:"
echo "    fp-config failure-reset '/path/to/file.iso.strm'"
echo ""
