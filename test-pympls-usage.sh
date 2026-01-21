#!/bin/bash

# 测试 pympls 正确调用方式

echo "测试 pympls 安装和调用方式..."
echo ""

# 1. 检查 pympls 是否安装
echo "1️⃣  检查 pympls 安装..."
if python3 -c "import pympls" 2>/dev/null; then
    echo "   ✅ pympls 已安装"
else
    echo "   ❌ pympls 未安装"
    exit 1
fi
echo ""

# 2. 查找 pympls 安装位置
echo "2️⃣  查找 pympls 位置..."
PYMPLS_PATH=$(python3 -c "import pympls; print(pympls.__file__)" 2>/dev/null)
echo "   pympls 位置: $PYMPLS_PATH"
PYMPLS_DIR=$(dirname "$PYMPLS_PATH")
echo "   pympls 目录: $PYMPLS_DIR"
echo ""

# 3. 查找 mpls.py 脚本
echo "3️⃣  查找 mpls.py 脚本..."
if [ -f "$PYMPLS_DIR/mpls.py" ]; then
    echo "   ✅ 找到: $PYMPLS_DIR/mpls.py"
    MPLS_SCRIPT="$PYMPLS_DIR/mpls.py"
elif [ -f "$PYMPLS_DIR/__main__.py" ]; then
    echo "   ✅ 找到: $PYMPLS_DIR/__main__.py"
    MPLS_SCRIPT="$PYMPLS_DIR/__main__.py"
else
    echo "   ⚠️  未找到 mpls.py，尝试其他方式"
    ls -la "$PYMPLS_DIR"
    echo ""
fi
echo ""

# 4. 测试不同调用方式
echo "4️⃣  测试 pympls 调用方式..."
TEST_ISO="/mnt/sata1/media/媒体库/strm/test/活着.To Live 1994 1080p JPN Blu-ray AVC LPCM 2.0.iso"

# 挂载 ISO
TEMP_MOUNT=$(mktemp -d)
mount -o ro,loop "$TEST_ISO" "$TEMP_MOUNT" 2>/dev/null
MPLS_FILE="$TEMP_MOUNT/BDMV/PLAYLIST/00001.mpls"

echo "   测试文件: $MPLS_FILE"
echo ""

# 方式 1: python3 -m pympls.mpls
echo "   方式 1: python3 -m pympls.mpls"
if python3 -m pympls.mpls "$MPLS_FILE" >/tmp/test_method_1.json 2>&1; then
    echo "   ✅ 成功"
    jq '.MediaStreams | length' /tmp/test_method_1.json 2>/dev/null || echo "   (但输出格式不对)"
else
    echo "   ❌ 失败"
    head -3 /tmp/test_method_1.json
fi
echo ""

# 方式 2: python3 mpls.py
if [ -n "$MPLS_SCRIPT" ]; then
    echo "   方式 2: python3 $MPLS_SCRIPT"
    if python3 "$MPLS_SCRIPT" "$MPLS_FILE" >/tmp/test_method_2.json 2>&1; then
        echo "   ✅ 成功"
        jq '.MediaStreams | length' /tmp/test_method_2.json 2>/dev/null || echo "   (但输出格式不对)"
    else
        echo "   ❌ 失败"
        head -3 /tmp/test_method_2.json
    fi
    echo ""
fi

# 方式 3: python3 -m pympls
echo "   方式 3: python3 -m pympls"
if python3 -m pympls "$MPLS_FILE" >/tmp/test_method_3.json 2>&1; then
    echo "   ✅ 成功"
    jq '.MediaStreams | length' /tmp/test_method_3.json 2>/dev/null || echo "   (但输出格式不对)"
else
    echo "   ❌ 失败"
    head -3 /tmp/test_method_3.json
fi
echo ""

# 方式 4: 直接用 Python 代码调用
echo "   方式 4: Python 代码直接调用"
python3 <<'PYEOF' "$MPLS_FILE" >/tmp/test_method_4.json 2>&1
import sys
import json
import pympls

mpls_file = sys.argv[1]
try:
    result = pympls.parse(mpls_file)
    print(json.dumps(result, indent=2, ensure_ascii=False))
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

if [ $? -eq 0 ]; then
    echo "   ✅ 成功"
    jq '.MediaStreams | length' /tmp/test_method_4.json 2>/dev/null || echo "   输出: $(head -1 /tmp/test_method_4.json)"
else
    echo "   ❌ 失败"
    head -3 /tmp/test_method_4.json
fi
echo ""

# 卸载
umount "$TEMP_MOUNT"
rmdir "$TEMP_MOUNT"

echo "=========================================="
echo "测试完成，查看完整输出："
echo "  cat /tmp/test_method_*.json | jq"
echo "=========================================="
