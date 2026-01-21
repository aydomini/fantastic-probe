#!/bin/bash

echo "=========================================="
echo "查看 pympls API 和用法"
echo "=========================================="
echo ""

# 1. 查看 pympls 的实际内容
echo "1️⃣  查看 pympls 模块内容..."
python3 <<'PYEOF'
import pympls
import inspect

print("   pympls 模块位置:", pympls.__file__)
print("")
print("   pympls 可用函数和类:")
for name, obj in inspect.getmembers(pympls):
    if not name.startswith('_'):
        print(f"     - {name}: {type(obj).__name__}")
print("")

# 查看是否有 parse 函数
if hasattr(pympls, 'parse'):
    print("   ✅ 找到 parse 函数")
    sig = inspect.signature(pympls.parse)
    print(f"     签名: {sig}")
elif hasattr(pympls, 'Mpls'):
    print("   ✅ 找到 Mpls 类")
    print("     方法:")
    for name, method in inspect.getmembers(pympls.Mpls, predicate=inspect.ismethod):
        if not name.startswith('_'):
            print(f"       - {name}")
elif hasattr(pympls, 'MPLS'):
    print("   ✅ 找到 MPLS 类")
    print("     方法:")
    for name, method in inspect.getmembers(pympls.MPLS, predicate=inspect.ismethod):
        if not name.startswith('_'):
            print(f"       - {name}")
else:
    print("   ⚠️  未找到标准的 parse 函数或 Mpls/MPLS 类")
    print("   所有成员:", dir(pympls))
PYEOF
echo ""

# 2. 查看 __init__.py 的前 50 行
echo "2️⃣  查看 pympls/__init__.py 前 50 行..."
head -50 /usr/local/lib/python3.11/dist-packages/pympls/__init__.py
echo ""

# 3. 搜索关键函数定义
echo "3️⃣  搜索关键函数定义..."
grep -n "^def \|^class " /usr/local/lib/python3.11/dist-packages/pympls/__init__.py | head -20
echo ""

# 4. 尝试不同的 API 调用方式
echo "4️⃣  测试实际 API 调用..."
TEST_ISO="/mnt/sata1/media/媒体库/strm/test/活着.To Live 1994 1080p JPN Blu-ray AVC LPCM 2.0.iso"
TEMP_MOUNT=$(mktemp -d)
mount -o ro,loop "$TEST_ISO" "$TEMP_MOUNT" 2>/dev/null
MPLS_FILE="$TEMP_MOUNT/BDMV/PLAYLIST/00001.mpls"

echo "   测试文件: $MPLS_FILE"
echo ""

# 尝试 1: pympls.parse()
echo "   尝试 1: pympls.parse(file_path)"
python3 <<PYEOF "$MPLS_FILE"
import sys
import pympls

mpls_file = sys.argv[1]
try:
    if hasattr(pympls, 'parse'):
        result = pympls.parse(mpls_file)
        print("   ✅ parse() 可用")
        print(f"   结果类型: {type(result)}")
        if hasattr(result, '__dict__'):
            print(f"   结果属性: {list(result.__dict__.keys())}")
    else:
        print("   ❌ 没有 parse() 函数")
except Exception as e:
    print(f"   ❌ 错误: {e}")
PYEOF
echo ""

# 尝试 2: pympls.Mpls()
echo "   尝试 2: pympls.Mpls(file_path)"
python3 <<PYEOF "$MPLS_FILE"
import sys
import pympls

mpls_file = sys.argv[1]
try:
    if hasattr(pympls, 'Mpls'):
        obj = pympls.Mpls(mpls_file)
        print("   ✅ Mpls() 可用")
        print(f"   对象类型: {type(obj)}")
        if hasattr(obj, '__dict__'):
            print(f"   对象属性: {list(obj.__dict__.keys())[:10]}")
    else:
        print("   ❌ 没有 Mpls 类")
except Exception as e:
    print(f"   ❌ 错误: {e}")
PYEOF
echo ""

# 尝试 3: 读取文件内容后解析
echo "   尝试 3: 读取二进制内容后解析"
python3 <<PYEOF "$MPLS_FILE"
import sys
import pympls

mpls_file = sys.argv[1]
try:
    with open(mpls_file, 'rb') as f:
        data = f.read()

    if hasattr(pympls, 'parse'):
        result = pympls.parse(data)
        print("   ✅ parse(bytes) 可用")
        print(f"   结果类型: {type(result)}")
    elif hasattr(pympls, 'Mpls'):
        # 尝试看看 Mpls 是否有 from_bytes 或类似方法
        if hasattr(pympls.Mpls, 'from_bytes'):
            result = pympls.Mpls.from_bytes(data)
            print("   ✅ Mpls.from_bytes() 可用")
        else:
            print("   ⚠️  未找到合适的方法")
    else:
        print("   ❌ 无法解析")
except Exception as e:
    print(f"   ❌ 错误: {e}")
PYEOF
echo ""

umount "$TEMP_MOUNT"
rmdir "$TEMP_MOUNT"

echo "=========================================="
echo "如果上面都失败，可能需要查看 pympls 的 GitHub 文档"
echo "或者尝试重新安装最新版 pympls"
echo "=========================================="
