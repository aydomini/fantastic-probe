#!/bin/bash
export LC_ALL=C.UTF-8

#==============================================================================
# 动态版本号获取脚本
# 功能：从本地 Git tags 或硬编码默认值获取版本号
# 使用方法：
#   source ./get-version.sh
#   echo "当前版本：$VERSION"
#
# 注意：此脚本仅用于获取"本地版本"，不从 GitHub API 获取远程版本
#==============================================================================

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 默认版本号（最后的回退方案）
VERSION="3.3.5"

#==============================================================================
# 方法 1：从本地 Git tags 获取（如果在 git 仓库中）
#==============================================================================

get_version_from_git_tag() {
    if command -v git &> /dev/null && [ -d "$SCRIPT_DIR/.git" ]; then
        # 获取最新的项目版本 tag（排除 ffprobe 相关）
        # 只匹配 v 开头的版本号 tag
        local tag=$(git -C "$SCRIPT_DIR" tag -l "v*" | sort -V | tail -1)
        if [ -n "$tag" ]; then
            # 移除 'v' 前缀
            echo "${tag#v}"
            return 0
        fi
    fi
    return 1
}

#==============================================================================
# 方法 2：从当前脚本的注释中读取（备选方案）
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
# 主函数：获取本地版本号
#==============================================================================

# 获取版本号（按优先级）
# 注意：不从 GitHub API 获取，那是"远程版本"，应由调用者自行处理
VERSION=$(get_version_from_git_tag) || \
VERSION=$(get_version_from_script_comment "$1") || \
VERSION="3.3.5"  # 最终回退到硬编码默认值

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
        if command -v git &> /dev/null && [ -d "$SCRIPT_DIR/.git" ]; then
            git_tag=$(git -C "$SCRIPT_DIR" tag -l "v*" | sort -V | tail -1)
            if [ -n "$git_tag" ]; then
                echo "来源：本地 Git tags ($git_tag)"
            else
                echo "来源：硬编码默认值"
            fi
        else
            echo "来源：硬编码默认值（非 Git 仓库）"
        fi
    fi
fi
