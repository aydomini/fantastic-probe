#!/bin/bash
#==============================================================================
# bd_list_titles 语言标签提取测试脚本
# 用途：独立测试 bd_list_titles 输出解析逻辑（修复后的版本）
# 使用方法：./test-bd-parse.sh /path/to/bluray.iso
#==============================================================================

set -euo pipefail

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

#==============================================================================
# 主函数
#==============================================================================

main() {
    local iso_path="$1"

    log_info "=========================================="
    log_info "bd_list_titles 语言标签提取测试"
    log_info "=========================================="
    log_info "ISO 文件: $iso_path"
    echo

    # 检查文件是否存在
    if [ ! -f "$iso_path" ]; then
        log_error "ISO 文件不存在: $iso_path"
        exit 1
    fi

    # 检查 bd_list_titles 是否安装
    if ! command -v bd_list_titles &> /dev/null; then
        log_error "bd_list_titles 未安装，请执行: sudo apt-get install libbluray-bin"
        exit 1
    fi

    # 挂载 ISO
    log_info "挂载 ISO 文件..."
    local mount_point="/tmp/bd-test-$$"
    sudo mkdir -p "$mount_point"

    if ! sudo mount -o loop,ro "$iso_path" "$mount_point" 2>/dev/null; then
        log_error "ISO 挂载失败"
        sudo rmdir "$mount_point"
        exit 1
    fi

    log_success "ISO 挂载成功: $mount_point"
    echo

    # 检查是否为蓝光目录
    if [ ! -d "$mount_point/BDMV" ]; then
        log_warn "非蓝光目录（无 BDMV 文件夹）"
        sudo umount "$mount_point"
        sudo rmdir "$mount_point"
        exit 1
    fi

    log_success "检测到蓝光目录"
    echo

    # 执行 bd_list_titles
    log_info "执行 bd_list_titles -l \"$mount_point\" ..."
    local bd_output_file="/tmp/bd-output-$$.txt"
    local bd_error_file="/tmp/bd-error-$$.txt"

    bd_list_titles -l "$mount_point" > "$bd_output_file" 2> "$bd_error_file" || true

    # 检查错误输出
    if [ -s "$bd_error_file" ]; then
        log_warn "bd_list_titles 有错误输出:"
        head -10 "$bd_error_file" | while IFS= read -r line; do
            log_warn "  $line"
        done
        echo
    fi

    # 检查输出是否为空
    if [ ! -s "$bd_output_file" ]; then
        log_error "bd_list_titles 输出为空"
        sudo umount "$mount_point"
        sudo rmdir "$mount_point"
        rm -f "$bd_output_file" "$bd_error_file"
        exit 1
    fi

    local output_size=$(wc -c < "$bd_output_file" | tr -d ' ')
    local output_lines=$(wc -l < "$bd_output_file" | tr -d ' ')
    log_info "bd_list_titles 输出统计:"
    log_info "  - ${output_lines} 行"
    log_info "  - ${output_size} 字节"
    echo

    # 显示输出前 10 行
    log_info "bd_list_titles 输出前 10 行:"
    log_info "----------------------------------------"
    head -10 "$bd_output_file" | while IFS= read -r line; do
        echo "  $line"
    done
    log_info "----------------------------------------"
    echo

    # 使用 Python 解析（修复后的版本：使用临时脚本文件 + 管道）
    log_info "使用 Python 解析语言标签..."
    local python_script="/tmp/bd-parse-$$.py"

    cat > "$python_script" << 'PYTHON_SCRIPT'
import sys
import re
import json

# 从 stdin 读取 bd_list_titles 输出
content = sys.stdin.read()

# 找到最长标题（主标题）
max_duration = 0
max_index = None
chapters = 0

for match in re.finditer(r'index:\s*(\d+)\s+duration:\s*(\d+):(\d+):(\d+)\s+chapters:\s*(\d+)', content):
    index = int(match.group(1))
    h, m, s = int(match.group(2)), int(match.group(3)), int(match.group(4))
    chapter_count = int(match.group(5))
    duration = h * 3600 + m * 60 + s

    if duration > max_duration:
        max_duration = duration
        max_index = index
        chapters = chapter_count

if max_index is None:
    print(json.dumps({
        'audio_languages': [],
        'subtitle_languages': [],
        'chapters': 0
    }))
    sys.exit(0)

# 提取主标题区段
pattern = rf'index:\s*{max_index}\s.*?(?=index:\s*\d+|\Z)'
main_match = re.search(pattern, content, re.DOTALL)

audio_langs = []
subtitle_langs = []

if main_match:
    main_text = main_match.group(0)

    # 提取音频语言（必须是带缩进的行）
    aud_match = re.search(r'^\s+AUD:\s*(.+)', main_text, re.MULTILINE)
    if aud_match:
        audio_langs = aud_match.group(1).strip().split()

    # 提取字幕语言（必须是带缩进的行）
    pg_match = re.search(r'^\s+PG\s*:\s*(.+)', main_text, re.MULTILINE)
    if pg_match:
        subtitle_langs = pg_match.group(1).strip().split()

# 输出 JSON
result = {
    'audio_languages': audio_langs,
    'subtitle_languages': subtitle_langs,
    'chapters': chapters
}

print(json.dumps(result, indent=2, ensure_ascii=False))
PYTHON_SCRIPT

    # 通过管道传递数据给 Python 脚本
    local result=$(cat "$bd_output_file" | python3 "$python_script")
    local parse_exit_code=$?

    # 清理临时文件
    rm -f "$python_script" "$bd_output_file" "$bd_error_file"

    if [ $parse_exit_code -ne 0 ]; then
        log_error "Python 解析失败（退出码: $parse_exit_code）"
        sudo umount "$mount_point"
        sudo rmdir "$mount_point"
        exit 1
    fi

    # 验证 JSON 格式
    if ! echo "$result" | jq . > /dev/null 2>&1; then
        log_error "解析结果不是有效的 JSON"
        sudo umount "$mount_point"
        sudo rmdir "$mount_point"
        exit 1
    fi

    log_success "语言标签解析成功！"
    echo

    # 显示解析结果
    log_info "解析结果:"
    log_info "=========================================="
    echo "$result" | jq .
    log_info "=========================================="
    echo

    # 提取统计信息
    local audio_count=$(echo "$result" | jq -r '.audio_languages | length')
    local subtitle_count=$(echo "$result" | jq -r '.subtitle_languages | length')
    local chapter_count=$(echo "$result" | jq -r '.chapters')

    log_success "统计信息:"
    log_success "  - 音频语言: ${audio_count} 种"
    log_success "  - 字幕语言: ${subtitle_count} 种"
    log_success "  - 章节数: ${chapter_count}"
    echo

    # 卸载 ISO
    log_info "卸载 ISO..."
    sudo umount "$mount_point"
    sudo rmdir "$mount_point"
    log_success "ISO 已卸载"
    echo

    log_success "=========================================="
    log_success "测试完成！"
    log_success "=========================================="
}

# 入口
if [ $# -ne 1 ]; then
    echo "用法: $0 <ISO文件路径>"
    echo "示例: $0 /path/to/bluray.iso"
    exit 1
fi

main "$1"
