#!/usr/bin/env python3
"""
pympls 集成脚本
用于从蓝光 MPLS 文件中提取完整的媒体信息
输出格式兼容 Emby MediaSourceInfo
"""

from pympls import MPLS
import sys
import json

def calculate_duration(in_time, out_time):
    """
    计算影片时长（秒）
    蓝光时间基是 45000 Hz
    """
    return (out_time - in_time) / 45000.0

def format_timestamp(timestamp):
    """
    格式化时间戳为 HH:MM:SS
    """
    seconds = int(timestamp / 45000)
    hours = seconds // 3600
    minutes = (seconds % 3600) // 60
    secs = seconds % 60
    return f"{hours:02d}:{minutes:02d}:{secs:02d}"

def parse_mpls_file(mpls_path):
    """解析 MPLS 文件并返回 Emby 兼容的 JSON 格式"""
    try:
        mpls = MPLS(mpls_path)

        # 提取播放列表信息
        playlist = mpls.PlayList
        play_items = playlist.get("PlayItems", [])

        if not play_items:
            return {
                "success": False,
                "error": "No PlayItems found in MPLS",
                "file": mpls_path
            }

        # 获取第一个播放项（主视频）
        main_item = play_items[0]
        stn_table = main_item.get("STNTable", {})

        # 计算时长
        in_time = main_item.get("INTime", 0)
        out_time = main_item.get("OUTTime", 0)
        duration_seconds = calculate_duration(in_time, out_time)

        # 提取音轨
        audio_tracks = []
        for idx, entry in enumerate(stn_table.get("PrimaryAudioStreamEntries", [])):
            attrs = entry.get("StreamAttributes", {})
            audio_tracks.append({
                "Index": idx,
                "Language": attrs.get("LanguageCode", "und"),
                "Codec": get_audio_codec_name(attrs.get("StreamCodingType", 0)),
                "Channels": get_audio_channels(attrs.get("AudioFormat", 0)),
                "SampleRate": get_sample_rate(attrs.get("SampleRate", 0)),
                "Type": "Audio"
            })

        # 提取字幕（PG = 图形字幕）
        subtitle_tracks = []
        for idx, entry in enumerate(stn_table.get("PrimaryPGStreamEntries", [])):
            attrs = entry.get("StreamAttributes", {})
            subtitle_tracks.append({
                "Index": idx,
                "Language": attrs.get("LanguageCode", "und"),
                "Codec": "PGS",  # Presentation Graphic Stream
                "Type": "Subtitle"
            })

        # 提取章节
        marks = mpls.PlayListMarks
        chapters = []
        for idx, mark in enumerate(marks.get("PlayListMarks", [])):
            if mark.get("MarkType") == 1:  # Entry Mark
                timestamp = mark.get("MarkTimeStamp", 0)
                chapters.append({
                    "Index": idx,
                    "StartPositionTicks": int((timestamp / 45000.0) * 10000000),  # Emby 使用 100ns ticks
                    "Name": f"Chapter {idx + 1}",
                    "TimeFormatted": format_timestamp(timestamp)
                })

        # 提取视频流信息
        video_tracks = []
        for idx, entry in enumerate(stn_table.get("PrimaryVideoStreamEntries", [])):
            attrs = entry.get("StreamAttributes", {})
            video_tracks.append({
                "Index": idx,
                "Codec": get_video_codec_name(attrs.get("StreamCodingType", 0)),
                "Width": get_video_width(attrs.get("VideoFormat", 0)),
                "Height": get_video_height(attrs.get("VideoFormat", 0)),
                "FrameRate": get_frame_rate(attrs.get("FrameRate", 0)),
                "Type": "Video"
            })

        result = {
            "success": True,
            "Name": mpls_path.split("/")[-1].replace(".mpls", ""),
            "Path": mpls_path,
            "Container": "mpls",
            "RunTimeTicks": int(duration_seconds * 10000000),  # Emby 使用 100ns ticks
            "Size": 0,  # ISO 大小需要从外部获取
            "MediaStreams": video_tracks + audio_tracks + subtitle_tracks,
            "Chapters": chapters,
            "Duration": format_duration(duration_seconds),
            "DurationSeconds": duration_seconds
        }

        return result

    except Exception as e:
        return {
            "success": False,
            "error": str(e),
            "file": mpls_path
        }

def get_audio_codec_name(coding_type):
    """根据 StreamCodingType 返回音频编解码器名称"""
    codecs = {
        128: "LPCM",
        129: "AC3",
        130: "DTS",
        131: "TrueHD",
        132: "AC3+",
        133: "DTS-HD",
        134: "DTS-HD MA",
        135: "AC3+ (Secondary)"
    }
    return codecs.get(coding_type, f"Unknown({coding_type})")

def get_video_codec_name(coding_type):
    """根据 StreamCodingType 返回视频编解码器名称"""
    codecs = {
        27: "H.264/AVC",
        36: "H.265/HEVC",
        2: "MPEG-2"
    }
    return codecs.get(coding_type, f"Unknown({coding_type})")

def get_audio_channels(audio_format):
    """根据 AudioFormat 返回声道数"""
    channels = {
        1: 1,  # Mono
        3: 2,  # Stereo
        6: 6,  # 5.1
        12: 8  # 7.1
    }
    return channels.get(audio_format, 2)

def get_sample_rate(sample_rate):
    """根据 SampleRate 返回采样率（Hz）"""
    rates = {
        1: 48000,
        4: 96000,
        5: 192000
    }
    return rates.get(sample_rate, 48000)

def get_video_width(video_format):
    """根据 VideoFormat 返回宽度"""
    widths = {
        1: 720,   # 480i
        2: 720,   # 576i
        3: 720,   # 480p
        4: 1920,  # 1080i
        5: 1280,  # 720p
        6: 1920,  # 1080p
        7: 3840,  # 4K
        8: 3840   # 4K
    }
    return widths.get(video_format, 1920)

def get_video_height(video_format):
    """根据 VideoFormat 返回高度"""
    heights = {
        1: 480,
        2: 576,
        3: 480,
        4: 1080,
        5: 720,
        6: 1080,
        7: 2160,
        8: 2160
    }
    return heights.get(video_format, 1080)

def get_frame_rate(frame_rate):
    """根据 FrameRate 返回帧率"""
    rates = {
        1: 23.976,
        2: 24.0,
        3: 25.0,
        4: 29.97,
        6: 50.0,
        7: 59.94
    }
    return rates.get(frame_rate, 23.976)

def format_duration(seconds):
    """格式化时长为 HH:MM:SS"""
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}"

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({
            "success": False,
            "error": "Usage: parse_mpls_pympls.py <mpls_file>"
        }), file=sys.stderr)
        sys.exit(1)

    mpls_path = sys.argv[1]
    result = parse_mpls_file(mpls_path)

    print(json.dumps(result, indent=2, ensure_ascii=False))

    sys.exit(0 if result.get("success") else 1)
