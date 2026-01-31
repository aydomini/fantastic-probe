#!/bin/bash
#==============================================================================
# ISO 语言标签提取诊断脚本（独立版）
# 用途：诊断为什么 bd_list_titles 提取语言标签失败
# 使用：sudo bash standalone-diagnose.sh "/path/to/your.iso"
#==============================================================================

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "用法: sudo bash $0 <ISO文件路径>"
    echo ""
    echo "示例:"
    echo "  sudo bash $0 '/mnt/sata1/media/媒体库/pan_115/cloud/01-电影/大陆电影/阳光灿烂的日子 (1995) - [tmdbid-161285]/阳光灿烂的日子 (1995) - BluRay - [tmdbid-161285].iso'"
    exit 1
fi

ISO_PATH="$1"

if [ ! -f "$ISO_PATH" ]; then
    echo "❌ 错误：ISO 文件不存在"
    echo "   路径: $ISO_PATH"
    exit 1
fi

echo "=========================================="
echo "ISO 语言标签提取诊断"
echo "=========================================="
echo "ISO 文件: $ISO_PATH"
echo ""

# 步骤 1: 检查必要工具
echo "[1/6] 检查必要工具..."
MISSING_TOOLS=0

if command -v bd_list_titles &> /dev/null; then
    echo "  ✅ bd_list_titles 可用"
else
    echo "  ❌ bd_list_titles 未安装"
    echo "     安装命令: sudo apt-get install libbluray-bin"
    MISSING_TOOLS=1
fi

if command -v jq &> /dev/null; then
    echo "  ✅ jq $(jq --version)"
else
    echo "  ❌ jq 未安装"
    MISSING_TOOLS=1
fi

if command -v python3 &> /dev/null; then
    echo "  ✅ python3 $(python3 --version)"
else
    echo "  ❌ python3 未安装"
    MISSING_TOOLS=1
fi

if [ $MISSING_TOOLS -eq 1 ]; then
    echo ""
    echo "❌ 缺少必要工具，请先安装后再运行"
    exit 1
fi

echo ""

# 步骤 2: 挂载 ISO
echo "[2/6] 挂载 ISO..."
MOUNT_POINT="/tmp/diagnose-mount-$$"
sudo mkdir -p "$MOUNT_POINT"
echo "  挂载点: $MOUNT_POINT"

cleanup() {
    echo ""
    echo "[清理] 卸载 ISO..."
    sudo umount "$MOUNT_POINT" 2>/dev/null || true
    sudo rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

if sudo mount -o loop,ro "$ISO_PATH" "$MOUNT_POINT" 2>&1; then
    echo "  ✅ 挂载成功"
else
    echo "  ❌ 挂载失败"
    exit 1
fi

echo ""

# 步骤 3: 检查蓝光目录结构
echo "[3/6] 检查蓝光目录结构..."
if [ -d "$MOUNT_POINT/BDMV" ]; then
    echo "  ✅ 存在 BDMV 目录"
    echo ""
    echo "  目录内容:"
    ls -lh "$MOUNT_POINT/BDMV" | head -10 | sed 's/^/    /'
else
    echo "  ❌ 不存在 BDMV 目录（非蓝光 ISO）"
    exit 1
fi

echo ""

# 步骤 4: 执行 bd_list_titles
echo "[4/6] 执行 bd_list_titles..."
BD_OUTPUT_FILE="/tmp/bd-output-$$.txt"
BD_ERROR_FILE="/tmp/bd-error-$$.txt"

bd_list_titles -l "$MOUNT_POINT" > "$BD_OUTPUT_FILE" 2> "$BD_ERROR_FILE" || true

echo "  输出行数: $(wc -l < "$BD_OUTPUT_FILE")"
echo "  错误行数: $(wc -l < "$BD_ERROR_FILE")"

if [ -s "$BD_OUTPUT_FILE" ]; then
    echo ""
    echo "  ✅ bd_list_titles 输出（前 50 行）:"
    cat "$BD_OUTPUT_FILE" | head -50 | sed 's/^/    /'

    # 保存完整输出
    echo ""
    echo "  完整输出已保存: $BD_OUTPUT_FILE"
else
    echo ""
    echo "  ❌ bd_list_titles 输出为空"
fi

if [ -s "$BD_ERROR_FILE" ]; then
    echo ""
    echo "  ⚠️  错误输出:"
    cat "$BD_ERROR_FILE" | head -10 | sed 's/^/    /'
fi

echo ""

# 步骤 5: Python 解析测试
echo "[5/6] Python 解析测试..."

LANG_TAGS_JSON=$(cat "$BD_OUTPUT_FILE" | python3 << 'EOF'
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
        'chapters': 0,
        'error': 'No valid title found'
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
    'chapters': chapters,
    'main_title_index': max_index,
    'main_title_duration_seconds': max_duration
}

print(json.dumps(result, indent=2))
EOF
)

echo "  解析结果:"
echo "$LANG_TAGS_JSON" | sed 's/^/    /'

# 保存结果
echo "$LANG_TAGS_JSON" > /tmp/lang-tags-$$.json
echo ""
echo "  语言标签 JSON 已保存: /tmp/lang-tags-$$.json"

echo ""

# 步骤 6: 分析结果
echo "[6/6] 分析结果..."

AUDIO_COUNT=$(echo "$LANG_TAGS_JSON" | jq '.audio_languages | length')
SUBTITLE_COUNT=$(echo "$LANG_TAGS_JSON" | jq '.subtitle_languages | length')
CHAPTER_COUNT=$(echo "$LANG_TAGS_JSON" | jq '.chapters')
MAIN_INDEX=$(echo "$LANG_TAGS_JSON" | jq '.main_title_index // "null"')
DURATION=$(echo "$LANG_TAGS_JSON" | jq '.main_title_duration_seconds // 0')

echo "  主标题索引: $MAIN_INDEX"
echo "  主标题时长: $DURATION 秒 ($(($DURATION / 60)) 分钟)"
echo "  章节数量: $CHAPTER_COUNT"
echo "  音频语言数量: $AUDIO_COUNT"
echo "  字幕语言数量: $SUBTITLE_COUNT"

echo ""

if [ "$AUDIO_COUNT" -gt 0 ] || [ "$SUBTITLE_COUNT" -gt 0 ]; then
    echo "  ✅ 语言标签提取成功！"
    echo ""

    if [ "$AUDIO_COUNT" -gt 0 ]; then
        echo "  音频语言:"
        echo "$LANG_TAGS_JSON" | jq -r '.audio_languages[]' | sed 's/^/    - /'
    fi

    if [ "$SUBTITLE_COUNT" -gt 0 ]; then
        echo ""
        echo "  字幕语言:"
        echo "$LANG_TAGS_JSON" | jq -r '.subtitle_languages[]' | sed 's/^/    - /'
    fi
else
    echo "  ⚠️  未提取到语言标签（结果为 0）"
    echo ""
    echo "  可能的原因:"
    echo "    1. bd_list_titles 输出格式不符合预期"
    echo "    2. 正则表达式匹配失败"
    echo "    3. ISO 不包含语言标签信息"
    echo ""
    echo "  请检查 bd_list_titles 完整输出: $BD_OUTPUT_FILE"
    echo "  特别关注是否包含 'AUD:' 和 'PG:' 行"
fi

echo ""

# 步骤 7: 诊断建议
echo "=========================================="
echo "诊断建议"
echo "=========================================="

if [ ! -s "$BD_OUTPUT_FILE" ]; then
    echo "❌ 问题: bd_list_titles 输出为空"
    echo ""
    echo "可能原因:"
    echo "  1. libbluray-bin 版本过旧"
    echo "  2. ISO 文件损坏"
    echo "  3. 权限不足"
    echo ""
    echo "解决方案:"
    echo "  sudo apt-get update && sudo apt-get install --reinstall libbluray-bin"

elif [ "$AUDIO_COUNT" -eq 0 ] && [ "$SUBTITLE_COUNT" -eq 0 ]; then
    echo "⚠️  问题: bd_list_titles 有输出，但未提取到语言标签"
    echo ""
    echo "请手动检查 bd_list_titles 输出格式:"
    echo "  cat $BD_OUTPUT_FILE | grep -A 5 'index:'"
    echo ""
    echo "如果输出格式与预期不同，需要修改 Python 解析脚本的正则表达式"

else
    echo "✅ 一切正常！语言标签提取成功"
    echo ""
    echo "如果实际运行中仍然显示 '0 音频, 0 字幕'，可能是:"
    echo "  1. JSON 转换阶段出错"
    echo "  2. jq 版本不兼容"
    echo "  3. 语言标签 JSON 传递给 convert_to_emby_format 时出错"
fi

echo ""
echo "=========================================="
echo "诊断完成"
echo "=========================================="
echo ""
echo "生成的文件:"
echo "  - $BD_OUTPUT_FILE (bd_list_titles 完整输出)"
echo "  - $BD_ERROR_FILE (bd_list_titles 错误输出)"
echo "  - /tmp/lang-tags-$$.json (语言标签 JSON)"
echo ""
echo "请将这些文件内容发给开发者以获取进一步帮助"
echo ""

# 不自动清理，保留文件供进一步分析
trap - EXIT
sudo umount "$MOUNT_POINT" 2>/dev/null || true
sudo rmdir "$MOUNT_POINT" 2>/dev/null || true
