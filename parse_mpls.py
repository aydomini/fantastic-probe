#!/usr/bin/env python3
"""
MPLS 语言信息解析脚本
用途：从蓝光 MPLS 播放列表文件中提取音轨和字幕的语言信息
版本：1.0.0
日期：2026-01-20

参考资料：
- https://thomasguymer.co.uk/blog/2018/2018-02-21/
- Blu-ray Disc Specification
"""

import struct
import sys
import json
from typing import Dict, List, Any


def read_uint16_be(data: bytes, offset: int) -> int:
    """读取大端序 16 位无符号整数"""
    return struct.unpack('>H', data[offset:offset+2])[0]


def read_uint32_be(data: bytes, offset: int) -> int:
    """读取大端序 32 位无符号整数"""
    return struct.unpack('>I', data[offset:offset+4])[0]


def read_uint8(data: bytes, offset: int) -> int:
    """读取 8 位无符号整数"""
    return data[offset]


def read_string(data: bytes, offset: int, length: int) -> str:
    """读取 ASCII 字符串"""
    return data[offset:offset+length].decode('ascii', errors='ignore')


def parse_stn_table(data: bytes, offset: int) -> Dict[str, List[Dict[str, Any]]]:
    """
    解析 STN_table（Stream Number Table）
    这是 MPLS 文件中包含音轨和字幕语言信息的关键部分

    STN_table 结构（简化）：
    - length (2 bytes): STN_table 长度
    - reserved (2 bytes)
    - num_video (1 byte): 视频流数量
    - num_audio (1 byte): 音频流数量
    - num_pg (1 byte): PG 字幕流数量（图形字幕）
    - num_ig (1 byte): IG 流数量
    - ... (各种流的详细信息)
    """
    try:
        # 读取 STN_table 长度
        stn_length = read_uint16_be(data, offset)
        offset += 2

        # 跳过保留字节
        offset += 2

        # 读取流数量
        num_video = read_uint8(data, offset)
        offset += 1

        num_audio = read_uint8(data, offset)
        offset += 1

        num_pg = read_uint8(data, offset)
        offset += 1

        num_ig = read_uint8(data, offset)
        offset += 1

        # 读取次级视频流数量
        num_secondary_video = read_uint8(data, offset)
        offset += 1

        # 读取次级音频流数量
        num_secondary_audio = read_uint8(data, offset)
        offset += 1

        # 读取次级 PG 流数量
        num_secondary_pg = read_uint8(data, offset)
        offset += 1

        # 跳过保留字节
        offset += 5

        audio_streams = []
        subtitle_streams = []

        # 解析主视频流（跳过，我们不需要视频流的语言信息）
        for i in range(num_video):
            # 每个视频流条目长度固定（通常 8 bytes）
            offset += 8

        # 解析主音频流
        for i in range(num_audio):
            try:
                # 音频流条目结构（简化）:
                # - stream_type (1 byte)
                # - ... (多个字段)
                # - lang_code (3 bytes): 语言代码，如 "eng", "jpn"

                # 跳到语言代码位置（偏移可能需要调整）
                # 典型偏移：1 (stream_type) + 2 (reserved) + ... = 通常在偏移 4-6 处

                # 简化实现：尝试多个可能的偏移
                lang_code = None
                for lang_offset in [4, 5, 6, 7, 8]:
                    try:
                        test_lang = read_string(data, offset + lang_offset, 3)
                        # 验证是否是有效的语言代码（3 个小写字母）
                        if len(test_lang) == 3 and test_lang.islower() and test_lang.isalpha():
                            lang_code = test_lang
                            break
                    except:
                        continue

                if lang_code:
                    audio_streams.append({
                        "index": i,
                        "language": lang_code,
                        "type": "audio"
                    })

                # 跳到下一个音频流条目（长度可变，简化为固定长度）
                offset += 16  # 近似长度，需要根据实际格式调整

            except Exception as e:
                # 解析单个音频流失败，继续下一个
                offset += 16
                continue

        # 解析 PG 字幕流（图形字幕）
        for i in range(num_pg):
            try:
                # PG 流条目结构与音频流类似
                lang_code = None
                for lang_offset in [4, 5, 6, 7, 8]:
                    try:
                        test_lang = read_string(data, offset + lang_offset, 3)
                        if len(test_lang) == 3 and test_lang.islower() and test_lang.isalpha():
                            lang_code = test_lang
                            break
                    except:
                        continue

                if lang_code:
                    subtitle_streams.append({
                        "index": i,
                        "language": lang_code,
                        "type": "subtitle"
                    })

                offset += 16

            except Exception as e:
                offset += 16
                continue

        return {
            "audio_streams": audio_streams,
            "subtitle_streams": subtitle_streams
        }

    except Exception as e:
        print(json.dumps({"error": f"STN_table 解析失败: {str(e)}"}), file=sys.stderr)
        return {
            "audio_streams": [],
            "subtitle_streams": []
        }


def parse_mpls(mpls_path: str) -> Dict[str, Any]:
    """
    解析 MPLS 文件，提取语言信息

    MPLS 文件结构：
    1. Header (12 bytes): "MPLS" + version info
    2. PlayList section: 播放列表元数据
    3. PlayItem section: 播放项信息（包含 STN_table）
    4. Mark section: 章节标记
    """
    try:
        with open(mpls_path, 'rb') as f:
            data = f.read()

        # 验证文件头（应该是 "MPLS"）
        if data[:4] != b'MPLS':
            return {
                "error": "Not a valid MPLS file",
                "audio_streams": [],
                "subtitle_streams": []
            }

        # 跳过 Header (12 bytes)
        offset = 12

        # 读取 PlayList section 起始位置和长度
        playlist_start_addr = read_uint32_be(data, offset)
        offset += 4

        playlist_mark_start_addr = read_uint32_be(data, offset)
        offset += 4

        # 跳转到 PlayList section
        offset = playlist_start_addr

        # 读取 PlayList section 长度
        playlist_length = read_uint32_be(data, offset)
        offset += 4

        # 跳过保留字节
        offset += 2

        # 读取 PlayItem 数量
        num_playitems = read_uint16_be(data, offset)
        offset += 2

        # 读取子路径数量
        num_subpaths = read_uint16_be(data, offset)
        offset += 2

        if num_playitems == 0:
            return {
                "error": "No PlayItems found",
                "audio_streams": [],
                "subtitle_streams": []
            }

        # 只解析第一个 PlayItem（主视频）
        # PlayItem 结构：
        # - PlayItem 长度 (2 bytes)
        # - Clip 信息
        # - ... (多个字段)
        # - STN_table (包含语言信息)

        playitem_length = read_uint16_be(data, offset)
        offset += 2

        # 跳过 Clip 文件名 (5 bytes)
        offset += 5

        # 跳过 Clip 编码类型 (4 bytes)
        offset += 4

        # 跳过多个标志和时间信息（简化）
        # 实际偏移需要根据规范精确计算
        offset += 20

        # 尝试在接下来的 200 字节内查找 STN_table
        # STN_table 通常以特定的模式开始
        stn_found = False
        search_range = min(200, len(data) - offset)

        for search_offset in range(search_range):
            try:
                # 尝试解析 STN_table
                result = parse_stn_table(data, offset + search_offset)
                if result["audio_streams"] or result["subtitle_streams"]:
                    stn_found = True
                    return result
            except:
                continue

        if not stn_found:
            return {
                "warning": "STN_table not found or empty",
                "audio_streams": [],
                "subtitle_streams": []
            }

    except Exception as e:
        return {
            "error": f"MPLS 解析失败: {str(e)}",
            "audio_streams": [],
            "subtitle_streams": []
        }


def main():
    """主函数"""
    if len(sys.argv) < 2:
        print(json.dumps({
            "error": "Usage: parse_mpls.py <mpls_file>",
            "audio_streams": [],
            "subtitle_streams": []
        }), file=sys.stderr)
        sys.exit(1)

    mpls_path = sys.argv[1]
    result = parse_mpls(mpls_path)

    # 输出 JSON 格式结果
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
