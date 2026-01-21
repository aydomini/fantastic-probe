#!/bin/bash

#==============================================================================
# Fantastic-Probe ISO 测试脚本（详细诊断版）
#==============================================================================

set -e

TEST_ISO="/mnt/sata1/media/媒体库/strm/test/活着.To Live 1994 1080p JPN Blu-ray AVC LPCM 2.0.iso"
FFPROBE="/usr/bin/ffprobe"

echo "=========================================="
echo "Fantastic-Probe ISO 测试诊断"
echo "=========================================="
echo ""

# 1. 检查文件
echo "1️⃣  检查 ISO 文件..."
if [ ! -f "$TEST_ISO" ]; then
    echo "   ❌ 文件不存在: $TEST_ISO"
    exit 1
fi

FILE_SIZE=$(du -h "$TEST_ISO" | cut -f1)
echo "   ✅ 文件存在"
echo "   文件大小: $FILE_SIZE"
echo ""

# 2. 检查工具
echo "2️⃣  检查必需工具..."

if ! command -v ffprobe &> /dev/null; then
    echo "   ❌ ffprobe 未安装"
    exit 1
fi
echo "   ✅ ffprobe: $(which ffprobe)"

if ! command -v 7z &> /dev/null; then
    echo "   ⚠️  7z 未安装（MPLS 语言补充将跳过）"
else
    echo "   ✅ 7z: $(which 7z)"
fi

if ! command -v python3 &> /dev/null; then
    echo "   ⚠️  python3 未安装（MPLS 语言补充将跳过）"
else
    PYTHON_VERSION=$(python3 --version 2>&1)
    echo "   ✅ python3: $PYTHON_VERSION"

    if python3 -c "import pympls" 2>/dev/null; then
        echo "   ✅ pympls 已安装"
    else
        echo "   ⚠️  pympls 未安装（MPLS 语言补充将跳过）"
    fi
fi
echo ""

# 3. 测试文件名识别
echo "3️⃣  测试文件名识别..."
FILENAME=$(basename "$TEST_ISO" .iso)
echo "   文件名: $FILENAME"

if echo "$FILENAME" | grep -iE "(BluRay|Blu-ray|BD|BDMV)" >/dev/null 2>&1; then
    ISO_TYPE="bluray"
    echo "   ✅ 识别为蓝光 ISO（包含 Blu-ray 标识）"
elif echo "$FILENAME" | grep -iE "(DVD|VIDEO_TS)" >/dev/null 2>&1; then
    ISO_TYPE="dvd"
    echo "   ✅ 识别为 DVD ISO"
else
    ISO_TYPE="bluray"
    echo "   ⚠️  无法从文件名判断，默认蓝光"
fi
echo ""

# 4. 测试 7z 访问
echo "4️⃣  测试 7z 访问 ISO..."
if command -v 7z &> /dev/null; then
    START_TIME=$(date +%s)
    Z7_STDERR=$(mktemp)

    echo "   执行: timeout 30 7z l \"$TEST_ISO\""
    if timeout 30 7z l "$TEST_ISO" >/dev/null 2>"$Z7_STDERR"; then
        DURATION=$(($(date +%s) - START_TIME))
        echo "   ✅ 7z 检测通过（耗时 ${DURATION}秒）"
    else
        DURATION=$(($(date +%s) - START_TIME))
        echo "   ❌ 7z 检测失败（耗时 ${DURATION}秒）"
        if [ -s "$Z7_STDERR" ]; then
            echo "   错误信息:"
            head -5 "$Z7_STDERR" | sed 's/^/      /'
        fi
    fi
    rm -f "$Z7_STDERR"
else
    echo "   ⏭️  跳过（7z 未安装）"
fi
echo ""

# 5. 测试 ffprobe bluray 协议（第一次）
echo "5️⃣  测试 ffprobe bluray 协议（第一次尝试）..."
START_TIME=$(date +%s)
FFPROBE_STDERR=$(mktemp)

echo "   执行: timeout 90 $FFPROBE -v error -i \"bluray:$TEST_ISO\""
if timeout 90 "$FFPROBE" -v error -print_format json -show_format -show_streams -protocol_whitelist "file,bluray" -i "bluray:$TEST_ISO" >/tmp/ffprobe_output_1.json 2>"$FFPROBE_STDERR"; then
    DURATION=$(($(date +%s) - START_TIME))
    STREAM_COUNT=$(jq '.streams | length' /tmp/ffprobe_output_1.json 2>/dev/null || echo "0")
    echo "   ✅ bluray 协议成功（耗时 ${DURATION}秒，提取 ${STREAM_COUNT} 个流）"

    # 检查语言信息
    AUDIO_COUNT=$(jq '[.streams[] | select(.codec_type=="audio")] | length' /tmp/ffprobe_output_1.json 2>/dev/null || echo "0")
    SUBTITLE_COUNT=$(jq '[.streams[] | select(.codec_type=="subtitle")] | length' /tmp/ffprobe_output_1.json 2>/dev/null || echo "0")
    LANG_COUNT=$(jq '[.streams[] | select(.codec_type=="audio" or .codec_type=="subtitle") | select(.tags.language != "und" and .tags.language != null)] | length' /tmp/ffprobe_output_1.json 2>/dev/null || echo "0")

    echo "   音轨数: $AUDIO_COUNT"
    echo "   字幕数: $SUBTITLE_COUNT"
    echo "   有语言信息: $LANG_COUNT / $((AUDIO_COUNT + SUBTITLE_COUNT))"

    echo ""
    echo "   完整结果已保存: /tmp/ffprobe_output_1.json"
else
    EXIT_CODE=$?
    DURATION=$(($(date +%s) - START_TIME))

    if [ $EXIT_CODE -eq 124 ]; then
        echo "   ❌ 超时（>${DURATION}秒）"
    else
        echo "   ❌ 失败（退出码 $EXIT_CODE，耗时 ${DURATION}秒）"
    fi

    if [ -s "$FFPROBE_STDERR" ]; then
        echo "   错误信息:"
        head -10 "$FFPROBE_STDERR" | sed 's/^/      /'
    fi
fi
rm -f "$FFPROBE_STDERR"
echo ""

# 6. 测试 ffprobe bluray 协议（第二次，模拟重试）
echo "6️⃣  测试 ffprobe bluray 协议（10秒后重试）..."
echo "   等待 10 秒（模拟 fuse 初始化）..."
sleep 10

START_TIME=$(date +%s)
FFPROBE_STDERR=$(mktemp)

echo "   执行: timeout 90 $FFPROBE -v error -i \"bluray:$TEST_ISO\""
if timeout 90 "$FFPROBE" -v error -print_format json -show_format -show_streams -protocol_whitelist "file,bluray" -i "bluray:$TEST_ISO" >/tmp/ffprobe_output_2.json 2>"$FFPROBE_STDERR"; then
    DURATION=$(($(date +%s) - START_TIME))
    STREAM_COUNT=$(jq '.streams | length' /tmp/ffprobe_output_2.json 2>/dev/null || echo "0")
    echo "   ✅ bluray 协议成功（耗时 ${DURATION}秒，提取 ${STREAM_COUNT} 个流）"
    echo "   完整结果已保存: /tmp/ffprobe_output_2.json"
else
    EXIT_CODE=$?
    DURATION=$(($(date +%s) - START_TIME))

    if [ $EXIT_CODE -eq 124 ]; then
        echo "   ❌ 超时（>${DURATION}秒）"
    else
        echo "   ❌ 失败（退出码 $EXIT_CODE，耗时 ${DURATION}秒）"
    fi

    if [ -s "$FFPROBE_STDERR" ]; then
        echo "   错误信息:"
        head -10 "$FFPROBE_STDERR" | sed 's/^/      /'
    fi
fi
rm -f "$FFPROBE_STDERR"
echo ""

# 7. 测试 MPLS 提取（如果 7z 和 pympls 可用）
if command -v 7z &> /dev/null && python3 -c "import pympls" 2>/dev/null; then
    echo "7️⃣  测试 MPLS 语言提取..."

    # 创建临时目录
    TEMP_DIR=$(mktemp -d)

    # 提取 PLAYLIST
    echo "   提取 PLAYLIST 目录..."
    START_TIME=$(date +%s)
    Z7_STDERR=$(mktemp)

    if timeout 60 7z x "$TEST_ISO" "BDMV/PLAYLIST/*" -o"$TEMP_DIR" -y >/dev/null 2>"$Z7_STDERR"; then
        DURATION=$(($(date +%s) - START_TIME))
        echo "   ✅ PLAYLIST 提取成功（耗时 ${DURATION}秒）"

        # 查找最大的 MPLS 文件
        LARGEST_MPLS=$(find "$TEMP_DIR" -name "*.mpls" -type f -printf '%s %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

        if [ -n "$LARGEST_MPLS" ]; then
            MPLS_SIZE=$(du -h "$LARGEST_MPLS" | cut -f1)
            echo "   ✅ 找到 MPLS: $(basename "$LARGEST_MPLS") ($MPLS_SIZE)"

            # 使用 pympls 解析
            echo "   解析 MPLS..."
            PYMPLS_STDERR=$(mktemp)

            if python3 -m pympls.mpls "$LARGEST_MPLS" >/tmp/pympls_output.json 2>"$PYMPLS_STDERR"; then
                echo "   ✅ pympls 解析成功"

                MPLS_AUDIO=$(jq '[.MediaStreams[] | select(.Type=="Audio")] | length' /tmp/pympls_output.json 2>/dev/null || echo "0")
                MPLS_SUBTITLE=$(jq '[.MediaStreams[] | select(.Type=="Subtitle")] | length' /tmp/pympls_output.json 2>/dev/null || echo "0")

                echo "   MPLS 音轨: $MPLS_AUDIO"
                echo "   MPLS 字幕: $MPLS_SUBTITLE"
                echo ""
                echo "   完整结果已保存: /tmp/pympls_output.json"
            else
                EXIT_CODE=$?
                echo "   ❌ pympls 解析失败（退出码 $EXIT_CODE）"
                if [ -s "$PYMPLS_STDERR" ]; then
                    echo "   错误信息:"
                    head -10 "$PYMPLS_STDERR" | sed 's/^/      /'
                fi
            fi
            rm -f "$PYMPLS_STDERR"
        else
            echo "   ❌ 未找到 MPLS 文件"
        fi
    else
        DURATION=$(($(date +%s) - START_TIME))
        echo "   ❌ PLAYLIST 提取失败（耗时 ${DURATION}秒）"
        if [ -s "$Z7_STDERR" ]; then
            echo "   错误信息:"
            head -5 "$Z7_STDERR" | sed 's/^/      /'
        fi
    fi

    rm -f "$Z7_STDERR"
    rm -rf "$TEMP_DIR"
else
    echo "7️⃣  跳过 MPLS 测试（缺少 7z 或 pympls）"
fi
echo ""

# 8. 总结
echo "=========================================="
echo "测试完成"
echo "=========================================="
echo ""
echo "查看详细结果："
echo "  ffprobe 第一次: cat /tmp/ffprobe_output_1.json | jq"
echo "  ffprobe 第二次: cat /tmp/ffprobe_output_2.json | jq"
echo "  pympls 输出: cat /tmp/pympls_output.json | jq"
echo ""
