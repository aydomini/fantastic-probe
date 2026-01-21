#!/bin/bash

#==============================================================================
# Fantastic-Probe ISO 深度诊断脚本
#==============================================================================

TEST_ISO="/mnt/sata1/media/媒体库/strm/test/活着.To Live 1994 1080p JPN Blu-ray AVC LPCM 2.0.iso"

echo "=========================================="
echo "ISO 文件深度诊断"
echo "=========================================="
echo ""

# 1. 文件系统类型检查
echo "1️⃣  检查文件系统类型..."
MOUNT_POINT=$(df "$TEST_ISO" | tail -1 | awk '{print $6}')
FS_TYPE=$(df -T "$TEST_ISO" | tail -1 | awk '{print $2}')
echo "   挂载点: $MOUNT_POINT"
echo "   文件系统: $FS_TYPE"

# 检查是否是 fuse
if mount | grep "$MOUNT_POINT" | grep -i fuse; then
    echo "   ⚠️  这是 FUSE 挂载！"
else
    echo "   ✅ 不是 FUSE 挂载"
fi
echo ""

# 2. 文件详细信息
echo "2️⃣  文件详细信息..."
ls -lh "$TEST_ISO"
echo ""
stat "$TEST_ISO"
echo ""

# 3. 检查是否是符号链接
echo "3️⃣  检查符号链接..."
if [ -L "$TEST_ISO" ]; then
    REAL_PATH=$(readlink -f "$TEST_ISO")
    echo "   ⚠️  这是符号链接，实际路径: $REAL_PATH"
    echo ""
    echo "   实际文件信息:"
    ls -lh "$REAL_PATH"
    TEST_ISO="$REAL_PATH"
else
    echo "   ✅ 不是符号链接"
fi
echo ""

# 4. 文件权限检查
echo "4️⃣  权限检查..."
if [ -r "$TEST_ISO" ]; then
    echo "   ✅ 可读"
else
    echo "   ❌ 不可读"
fi

CURRENT_USER=$(whoami)
echo "   当前用户: $CURRENT_USER"
echo ""

# 5. 文件头检查（ISO 9660 标识）
echo "5️⃣  检查 ISO 文件头..."
# ISO 9660 标准：偏移 32768 字节处应该有 "CD001" 标识
ISO_SIGNATURE=$(dd if="$TEST_ISO" bs=1 skip=32769 count=5 2>/dev/null)
if [ "$ISO_SIGNATURE" = "CD001" ]; then
    echo "   ✅ 这是标准 ISO 9660 文件"
else
    echo "   ⚠️  不是标准 ISO 9660 文件（签名: $ISO_SIGNATURE）"
    echo "   可能是 UDF 或其他格式"
fi
echo ""

# 6. 使用 file 命令详细检查
echo "6️⃣  文件类型详细分析..."
file -b "$TEST_ISO"
echo ""

# 7. 测试 7z 详细模式
echo "7️⃣  测试 7z 详细错误..."
echo "   执行: 7z l -slt \"$TEST_ISO\" 2>&1 | head -50"
7z l -slt "$TEST_ISO" 2>&1 | head -50
echo ""

# 8. 测试 mount 能否挂载
echo "8️⃣  测试 mount 挂载..."
TEMP_MOUNT=$(mktemp -d)
echo "   临时挂载点: $TEMP_MOUNT"

if mount -o ro,loop "$TEST_ISO" "$TEMP_MOUNT" 2>&1; then
    echo "   ✅ mount 挂载成功"
    echo ""
    echo "   查看内容:"
    ls -lh "$TEMP_MOUNT" | head -20
    echo ""

    # 检查是否是蓝光结构
    if [ -d "$TEMP_MOUNT/BDMV" ]; then
        echo "   ✅ 发现 BDMV 目录（蓝光结构）"
        ls -lh "$TEMP_MOUNT/BDMV/"

        if [ -d "$TEMP_MOUNT/BDMV/PLAYLIST" ]; then
            echo ""
            echo "   ✅ 发现 PLAYLIST 目录"
            ls -lh "$TEMP_MOUNT/BDMV/PLAYLIST/" | head -10

            # 找最大的 MPLS
            LARGEST_MPLS=$(find "$TEMP_MOUNT/BDMV/PLAYLIST" -name "*.mpls" -type f -printf '%s %p\n' 2>/dev/null | sort -rn | head -1)
            if [ -n "$LARGEST_MPLS" ]; then
                MPLS_FILE=$(echo "$LARGEST_MPLS" | cut -d' ' -f2-)
                MPLS_SIZE=$(echo "$LARGEST_MPLS" | cut -d' ' -f1)
                echo ""
                echo "   最大 MPLS: $(basename "$MPLS_FILE") (${MPLS_SIZE} 字节)"

                # 尝试用 pympls 解析
                if python3 -c "import pympls" 2>/dev/null; then
                    echo ""
                    echo "   测试 pympls 解析..."
                    if python3 -m pympls.mpls "$MPLS_FILE" >/tmp/pympls_mount_test.json 2>&1; then
                        echo "   ✅ pympls 解析成功"
                        MPLS_AUDIO=$(jq '[.MediaStreams[] | select(.Type=="Audio")] | length' /tmp/pympls_mount_test.json 2>/dev/null || echo "0")
                        MPLS_SUBTITLE=$(jq '[.MediaStreams[] | select(.Type=="Subtitle")] | length' /tmp/pympls_mount_test.json 2>/dev/null || echo "0")
                        echo "   音轨: $MPLS_AUDIO"
                        echo "   字幕: $MPLS_SUBTITLE"

                        # 显示语言信息
                        echo ""
                        echo "   语言信息:"
                        jq '.MediaStreams[] | select(.Type=="Audio" or .Type=="Subtitle") | {Type, Index, Language}' /tmp/pympls_mount_test.json 2>/dev/null | head -30
                    else
                        echo "   ❌ pympls 解析失败"
                        cat /tmp/pympls_mount_test.json 2>/dev/null
                    fi
                fi
            fi
        fi
    elif [ -d "$TEMP_MOUNT/VIDEO_TS" ]; then
        echo "   ✅ 发现 VIDEO_TS 目录（DVD 结构）"
    fi

    umount "$TEMP_MOUNT"
    echo ""
    echo "   ✅ 已卸载"
else
    echo "   ❌ mount 挂载失败"
fi

rmdir "$TEMP_MOUNT" 2>/dev/null
echo ""

# 9. 总结
echo "=========================================="
echo "诊断总结"
echo "=========================================="
echo ""
echo "关键问题："
echo "  - 7z 无法打开此 ISO 文件"
echo "  - 但 ffprobe bluray 协议可以直接读取"
echo ""
echo "可能的原因："
echo "  1. ISO 不是标准格式（UDF 而非 ISO 9660）"
echo "  2. 7z 版本不支持此格式"
echo "  3. 文件系统限制（虽然不是 fuse，但可能有其他限制）"
echo ""
echo "建议方案："
echo "  - 如果 mount 成功，可以改用 mount + pympls 方案"
echo "  - 如果 mount 也失败，直接使用 ffprobe 结果（放弃语言信息）"
echo ""
