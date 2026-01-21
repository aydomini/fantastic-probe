#!/bin/bash

echo "=========================================="
echo "正确测试 pympls.MPLS() API"
echo "=========================================="
echo ""

TEST_ISO="/mnt/sata1/media/媒体库/strm/test/活着.To Live 1994 1080p JPN Blu-ray AVC LPCM 2.0.iso"
TEMP_MOUNT=$(mktemp -d)

echo "1️⃣  挂载 ISO..."
if ! mount -o ro,loop "$TEST_ISO" "$TEMP_MOUNT" 2>&1; then
    echo "   ❌ 挂载失败"
    exit 1
fi
echo "   ✅ 挂载成功: $TEMP_MOUNT"
echo ""

MPLS_FILE="$TEMP_MOUNT/BDMV/PLAYLIST/00001.mpls"

echo "2️⃣  测试 pympls.MPLS() 解析..."
echo "   MPLS 文件: $MPLS_FILE"
echo ""

# 创建 Python 测试脚本
cat > /tmp/test_pympls.py <<'PYEOF'
import sys
import json
import pympls

mpls_file = sys.argv[1]

try:
    # 调用 pympls.MPLS 类
    mpls = pympls.MPLS(mpls_file)

    print("   ✅ MPLS 解析成功！")
    print("")

    # 查看对象属性
    print("   对象属性:")
    attrs = [attr for attr in dir(mpls) if not attr.startswith('_')]
    for attr in attrs[:20]:  # 只显示前20个
        print(f"     - {attr}")
    print("")

    # 尝试访问常见属性
    print("   尝试访问音轨/字幕信息...")

    # 检查是否有 PlayList 属性
    if hasattr(mpls, 'PlayList'):
        print("   ✅ 找到 PlayList")
        playlist = mpls.PlayList
        print(f"     类型: {type(playlist)}")
        if hasattr(playlist, '__dict__'):
            print(f"     属性: {list(playlist.__dict__.keys())[:10]}")

    # 检查是否有 Streams 或类似属性
    if hasattr(mpls, 'Streams'):
        print("   ✅ 找到 Streams")
        streams = mpls.Streams
        print(f"     数量: {len(streams) if hasattr(streams, '__len__') else 'unknown'}")

    # 检查是否有 PlayItem 属性
    if hasattr(mpls, 'PlayItem'):
        print("   ✅ 找到 PlayItem")
        playitem = mpls.PlayItem
        print(f"     类型: {type(playitem)}")

    # 尝试序列化整个对象（看看能否转 JSON）
    print("")
    print("   尝试序列化对象...")
    try:
        result = {}
        for attr in attrs:
            value = getattr(mpls, attr, None)
            if value is not None and not callable(value):
                try:
                    # 尝试转成可序列化的格式
                    if isinstance(value, (str, int, float, bool, list, dict)):
                        result[attr] = value
                    elif hasattr(value, '__dict__'):
                        result[attr] = str(value.__dict__)[:200]  # 截断避免太长
                    else:
                        result[attr] = str(value)[:200]
                except:
                    pass

        # 保存到文件
        with open('/tmp/pympls_result.json', 'w') as f:
            json.dump(result, f, indent=2, ensure_ascii=False)
        print("   ✅ 结果已保存: /tmp/pympls_result.json")

        # 显示部分内容
        print("")
        print("   部分结果:")
        for key in list(result.keys())[:10]:
            value = result[key]
            if isinstance(value, str) and len(value) > 100:
                value = value[:100] + "..."
            print(f"     {key}: {value}")

    except Exception as e:
        print(f"   ⚠️  序列化失败: {e}")

    sys.exit(0)

except Exception as e:
    print(f"   ❌ 解析失败: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYEOF

# 运行测试
python3 /tmp/test_pympls.py "$MPLS_FILE"
EXIT_CODE=$?

echo ""
echo "3️⃣  卸载 ISO..."
umount "$TEMP_MOUNT"
rmdir "$TEMP_MOUNT"
echo "   ✅ 已卸载"
echo ""

if [ $EXIT_CODE -eq 0 ]; then
    echo "=========================================="
    echo "✅ pympls.MPLS() 可用！"
    echo "=========================================="
    echo ""
    echo "查看完整结果："
    echo "  cat /tmp/pympls_result.json | jq"
    echo ""
else
    echo "=========================================="
    echo "❌ pympls.MPLS() 不可用"
    echo "=========================================="
    echo ""
    echo "建议使用备选方案："
    echo "  1. 使用 mediainfo 提取语言信息"
    echo "  2. 从文件名推断语言（如 JPN=日语）"
    echo "  3. 完全放弃语言补充"
    echo ""
fi

exit $EXIT_CODE
