#!/bin/bash

echo "=========================================="
echo "深入探索 pympls 语言信息"
echo "=========================================="
echo ""

TEST_ISO="/mnt/sata1/media/媒体库/strm/test/活着.To Live 1994 1080p JPN Blu-ray AVC LPCM 2.0.iso"
TEMP_MOUNT=$(mktemp -d)

echo "1️⃣  挂载 ISO..."
mount -o ro,loop "$TEST_ISO" "$TEMP_MOUNT" 2>&1
MPLS_FILE="$TEMP_MOUNT/BDMV/PLAYLIST/00001.mpls"
echo "   ✅ 挂载成功"
echo ""

echo "2️⃣  深入探索 MPLS 对象..."

cat > /tmp/explore_pympls.py <<'PYEOF'
import sys
import json
import pympls

mpls_file = sys.argv[1]

try:
    mpls = pympls.MPLS(mpls_file)
    print("   ✅ MPLS 解析成功")
    print("")

    # 1. 查看 PlayList 内容
    print("   📋 PlayList 结构:")
    if hasattr(mpls, 'PlayList') and isinstance(mpls.PlayList, dict):
        for key, value in mpls.PlayList.items():
            print(f"     - {key}: {type(value).__name__}")
            if key == 'PlayItems' and isinstance(value, list):
                print(f"       PlayItems 数量: {len(value)}")
                if len(value) > 0:
                    print(f"       PlayItem[0] 类型: {type(value[0])}")
                    if isinstance(value[0], dict):
                        print(f"       PlayItem[0] 键: {list(value[0].keys())}")
    print("")

    # 2. 尝试 get_play_item 方法
    print("   🎬 测试 get_play_item():")
    if hasattr(mpls, 'get_play_item'):
        try:
            # 尝试获取第一个 PlayItem
            play_item = mpls.get_play_item(0)
            print(f"     ✅ get_play_item(0) 成功")
            print(f"     类型: {type(play_item)}")
            if isinstance(play_item, dict):
                for key, value in play_item.items():
                    if isinstance(value, bytes):
                        print(f"       - {key}: bytes({len(value)})")
                    elif isinstance(value, dict):
                        print(f"       - {key}: dict({list(value.keys())})")
                    else:
                        print(f"       - {key}: {value}")
        except Exception as e:
            print(f"     ❌ 失败: {e}")
    print("")

    # 3. 尝试 get_stn_table 方法
    print("   📊 测试 get_stn_table():")
    if hasattr(mpls, 'get_stn_table'):
        try:
            # STN Table 应该包含流信息
            stn_table = mpls.get_stn_table(0)  # 第一个 PlayItem 的 STN Table
            print(f"     ✅ get_stn_table(0) 成功")
            print(f"     类型: {type(stn_table)}")

            if isinstance(stn_table, dict):
                print(f"     STN Table 键: {list(stn_table.keys())}")
                print("")

                # 查找音轨和字幕
                for key, value in stn_table.items():
                    print(f"     - {key}:")
                    if isinstance(value, list):
                        print(f"       数量: {len(value)}")
                        if len(value) > 0:
                            print(f"       第一项: {value[0]}")
                    elif isinstance(value, dict):
                        print(f"       键: {list(value.keys())}")
                    else:
                        print(f"       值: {value}")
        except Exception as e:
            print(f"     ❌ 失败: {e}")
    print("")

    # 4. 尝试 get_stream_attributes 方法
    print("   🎵 测试 get_stream_attributes():")
    if hasattr(mpls, 'get_stream_attributes'):
        try:
            # 尝试不同的参数组合
            for stream_type in ['audio', 'video', 'subtitle', 0, 1, 2]:
                try:
                    attrs = mpls.get_stream_attributes(0, stream_type)
                    print(f"     ✅ get_stream_attributes(0, {stream_type}): {attrs}")
                except:
                    pass
        except Exception as e:
            print(f"     ❌ 失败: {e}")
    print("")

    # 5. 直接访问 PlayList 数据结构
    print("   🔍 直接访问 PlayList['PlayItems']:")
    if hasattr(mpls, 'PlayList') and 'PlayItems' in mpls.PlayList:
        play_items = mpls.PlayList['PlayItems']
        print(f"     PlayItems 数量: {len(play_items)}")

        if len(play_items) > 0:
            play_item = play_items[0]
            print(f"     PlayItem[0] 键: {list(play_item.keys())}")

            # 查找 STN 或 Stream 相关的键
            for key, value in play_item.items():
                if 'STN' in key.upper() or 'STREAM' in key.upper():
                    print(f"     ✅ 找到: {key}")
                    print(f"       类型: {type(value)}")
                    if isinstance(value, dict):
                        print(f"       子键: {list(value.keys())}")
                        # 深入查看
                        for subkey, subvalue in value.items():
                            if isinstance(subvalue, list):
                                print(f"         - {subkey}: list({len(subvalue)} 项)")
                                if len(subvalue) > 0 and isinstance(subvalue[0], dict):
                                    print(f"           第一项键: {list(subvalue[0].keys())}")
                                    # 显示第一项的内容
                                    for k, v in subvalue[0].items():
                                        if 'LANG' in k.upper() or 'CODE' in k.upper():
                                            print(f"           ⭐ {k}: {v}")
                            else:
                                print(f"         - {subkey}: {subvalue}")
    print("")

    # 6. 尝试找到语言代码
    print("   🌍 搜索语言代码 (LanguageCode):")

    def search_language_codes(obj, path="", depth=0):
        """递归搜索对象中的语言代码"""
        if depth > 5:  # 限制递归深度
            return

        if isinstance(obj, dict):
            for key, value in obj.items():
                new_path = f"{path}.{key}" if path else key
                if 'LANG' in key.upper() or 'CODE' in key.upper():
                    print(f"     🎯 {new_path}: {value}")
                search_language_codes(value, new_path, depth + 1)
        elif isinstance(obj, list):
            for i, item in enumerate(obj[:3]):  # 只看前3项
                new_path = f"{path}[{i}]"
                search_language_codes(item, new_path, depth + 1)

    search_language_codes(mpls.PlayList, "PlayList")
    print("")

    print("   ✅ 探索完成！")

except Exception as e:
    print(f"   ❌ 错误: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYEOF

python3 /tmp/explore_pympls.py "$MPLS_FILE"

echo ""
echo "3️⃣  卸载 ISO..."
umount "$TEMP_MOUNT"
rmdir "$TEMP_MOUNT"
echo "   ✅ 已卸载"
echo ""

echo "=========================================="
echo "探索完成"
echo "=========================================="
