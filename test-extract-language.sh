#!/bin/bash

echo "=========================================="
echo "提取 MPLS 音轨和字幕的语言信息"
echo "=========================================="
echo ""

TEST_ISO="/mnt/sata1/media/媒体库/strm/test/活着.To Live 1994 1080p JPN Blu-ray AVC LPCM 2.0.iso"
TEMP_MOUNT=$(mktemp -d)

echo "1️⃣  挂载 ISO..."
mount -o ro,loop "$TEST_ISO" "$TEMP_MOUNT" 2>&1
MPLS_FILE="$TEMP_MOUNT/BDMV/PLAYLIST/00001.mpls"
echo "   ✅ 挂载成功"
echo ""

echo "2️⃣  提取语言信息..."

cat > /tmp/extract_language.py <<'PYEOF'
import sys
import json
import pympls

mpls_file = sys.argv[1]

def bytes_to_str(obj):
    """递归转换 bytes 为字符串"""
    if isinstance(obj, bytes):
        try:
            return obj.decode('utf-8')
        except:
            return obj.decode('latin1', errors='ignore')
    elif isinstance(obj, dict):
        return {k: bytes_to_str(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [bytes_to_str(item) for item in obj]
    else:
        return obj

try:
    mpls = pympls.MPLS(mpls_file)
    print("   ✅ MPLS 解析成功")
    print("")

    play_item = mpls.PlayList['PlayItems'][0]
    stn_table = play_item['STNTable']

    # 提取音轨信息
    print("   🎵 音轨信息:")
    audio_streams = stn_table.get('PrimaryAudioStreamEntries', [])
    print(f"     数量: {len(audio_streams)}")

    for i, audio in enumerate(audio_streams):
        print(f"     音轨 {i}:")

        # StreamEntry
        stream_entry = audio.get('StreamEntry', {})
        stream_entry_clean = bytes_to_str(stream_entry)
        print(f"       StreamEntry: {json.dumps(stream_entry_clean, indent=10, ensure_ascii=False)}")

        # StreamAttributes
        stream_attrs = audio.get('StreamAttributes', {})
        stream_attrs_clean = bytes_to_str(stream_attrs)
        print(f"       StreamAttributes: {json.dumps(stream_attrs_clean, indent=10, ensure_ascii=False)}")
        print("")

    # 提取字幕信息
    print("   📝 字幕信息:")
    subtitle_streams = stn_table.get('PrimaryPGStreamEntries', [])
    print(f"     数量: {len(subtitle_streams)}")

    for i, subtitle in enumerate(subtitle_streams):
        print(f"     字幕 {i}:")

        # StreamEntry
        stream_entry = subtitle.get('StreamEntry', {})
        stream_entry_clean = bytes_to_str(stream_entry)
        print(f"       StreamEntry: {json.dumps(stream_entry_clean, indent=10, ensure_ascii=False)}")

        # StreamAttributes
        stream_attrs = subtitle.get('StreamAttributes', {})
        stream_attrs_clean = bytes_to_str(stream_attrs)
        print(f"       StreamAttributes: {json.dumps(stream_attrs_clean, indent=10, ensure_ascii=False)}")
        print("")

    # 保存完整的 STNTable（清理后）
    stn_clean = bytes_to_str(stn_table)
    with open('/tmp/stn_table.json', 'w') as f:
        json.dump(stn_clean, f, indent=2, ensure_ascii=False)

    print("   ✅ 完整 STNTable 已保存: /tmp/stn_table.json")
    print("")

    # 构建语言映射
    print("   🌍 语言映射:")
    language_map = {
        'audio': [],
        'subtitle': []
    }

    for i, audio in enumerate(audio_streams):
        stream_attrs = audio.get('StreamAttributes', {})
        # 尝试多种可能的语言字段名
        lang = None
        for key in ['LanguageCode', 'Language', 'language_code', 'lang']:
            if key in stream_attrs:
                val = stream_attrs[key]
                if isinstance(val, bytes):
                    lang = val.decode('utf-8', errors='ignore').strip('\x00')
                else:
                    lang = val
                break

        if not lang:
            lang = 'und'

        language_map['audio'].append({
            'Index': i,
            'Language': lang
        })
        print(f"     音轨 {i}: {lang}")

    for i, subtitle in enumerate(subtitle_streams):
        stream_attrs = subtitle.get('StreamAttributes', {})
        lang = None
        for key in ['LanguageCode', 'Language', 'language_code', 'lang']:
            if key in stream_attrs:
                val = stream_attrs[key]
                if isinstance(val, bytes):
                    lang = val.decode('utf-8', errors='ignore').strip('\x00')
                else:
                    lang = val
                break

        if not lang:
            lang = 'und'

        language_map['subtitle'].append({
            'Index': i,
            'Language': lang
        })
        print(f"     字幕 {i}: {lang}")

    print("")
    print("   语言映射 JSON:")
    print(json.dumps(language_map, indent=2, ensure_ascii=False))

    with open('/tmp/language_map.json', 'w') as f:
        json.dump(language_map, f, indent=2, ensure_ascii=False)

    print("")
    print("   ✅ 语言映射已保存: /tmp/language_map.json")

except Exception as e:
    print(f"   ❌ 错误: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYEOF

python3 /tmp/extract_language.py "$MPLS_FILE"

echo ""
echo "3️⃣  卸载 ISO..."
umount "$TEMP_MOUNT"
rmdir "$TEMP_MOUNT"
echo "   ✅ 已卸载"
echo ""

echo "=========================================="
echo "提取完成"
echo "=========================================="
echo ""
echo "查看详细结果："
echo "  cat /tmp/stn_table.json | jq"
echo "  cat /tmp/language_map.json | jq"
echo ""
