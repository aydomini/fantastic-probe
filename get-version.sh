#!/bin/bash
export LC_ALL=C.UTF-8

#==============================================================================
# 动态版本号获取脚本
# 功能：从 Git tags 或 GitHub API 动态获取版本号
# 使用方法：
#   source ./get-version.sh
#   echo "当前版本：$VERSION"
#==============================================================================

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 默认版本号（最后的回退方案）
VERSION="3.1.3"

#==============================================================================
# 方法 1：从本地 Git tags 获取（如果在 git 仓库中）
#==============================================================================

get_version_from_git_tag() {
    if command -v git &> /dev/null && [ -d "$SCRIPT_DIR/.git" ]; then
        # 获取最新的 tag（去掉 'v' 前缀）
        local tag=$(git -C "$SCRIPT_DIR" describe --tags --abbrev=0 2>/dev/null)
        if [ -n "$tag" ]; then
            # 移除 'v' 前缀（如果有）
            echo "${tag#v}"
            return 0
        fi
    fi
    return 1
}

#==============================================================================
# 方法 2：从 GitHub API 获取最新 release 版本
#==============================================================================

get_version_from_github_api() {
    local repo="${1:-aydomini/fantastic-probe}"
    local timeout=5

    # 优先使用 curl，回退到 wget
    if command -v curl &> /dev/null; then
        local response=$(curl -s --max-time $timeout "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null)
        if [ -n "$response" ]; then
            # 提取 tag_name 字段，移除 'v' 前缀
            local version=$(echo "$response" | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)
            if [ -n "$version" ]; then
                echo "${version#v}"
                return 0
            fi
        fi
    elif command -v wget &> /dev/null; then
        local response=$(wget -q -O- --timeout=$timeout "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null)
        if [ -n "$response" ]; then
            local version=$(echo "$response" | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)
            if [ -n "$version" ]; then
                echo "${version#v}"
                return 0
            fi
        fi
    fi

    return 1
}

#==============================================================================
# 方法 3：从当前脚本的注释中读取（备选方案）
#==============================================================================

get_version_from_script_comment() {
    local calling_script="${1:-}"

    if [ -f "$calling_script" ]; then
        # 查找 "版本: v2.x.x" 或 "VERSION=2.x.x" 模式
        local version=$(grep -E "版本:|VERSION=" "$calling_script" | head -1 | grep -oP '\d+\.\d+\.\d+')
        if [ -n "$version" ]; then
            echo "$version"
            return 0
        fi
    fi

    return 1
}

#==============================================================================
# 主函数：尝试多个方法获取版本号
#==============================================================================

# 尝试获取版本号（按优先级）
VERSION=$(get_version_from_git_tag) || \
VERSION=$(get_version_from_github_api "aydomini/fantastic-probe") || \
VERSION=$(get_version_from_script_comment "$1") || \
VERSION="3.1.1"  # 最终回退到硬编码默认值

#==============================================================================
# 导出变量
#==============================================================================

export VERSION

# 如果直接执行此脚本，输出版本信息
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # 支持 --version 参数，仅输出版本号（供脚本解析使用）
    if [ "$1" = "--version" ]; then
        echo "$VERSION"
    else
        # 人类可读的友好输出格式
        echo "=========================================="
        echo "Fantastic-Probe 版本信息"
        echo "=========================================="
        echo ""
        echo "当前版本：$VERSION"
        echo ""

        # 显示获取来源
        if command -v git &> /dev/null && [ -d "$SCRIPT_DIR/.git" ] && git -C "$SCRIPT_DIR" describe --tags &>/dev/null 2>&1; then
            echo "来源：Git tags ($(git -C "$SCRIPT_DIR" describe --tags --abbrev=0))"
        elif echo "$VERSION" | grep -qE "^\d+\.\d+\.\d+$"; then
            echo "来源：GitHub API 或硬编码默认值"
        else
            echo "来源：硬编码默认值"
        fi
    fi
fi
