#!/bin/bash

#==============================================================================
# ISO 媒体信息提取服务 - 卸载脚本
#==============================================================================

set -e

echo "=========================================="
echo "ISO 媒体信息提取服务 - 卸载程序"
echo "=========================================="
echo ""

# 检查是否以 root 运行
if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 root 权限运行此脚本"
    echo "   sudo bash $0"
    exit 1
fi

# 1. 删除脚本和工具
echo "1️⃣  删除脚本和工具..."
FILES_REMOVED=0

if [ -f "/usr/local/bin/fantastic-probe-cron-scanner" ]; then
    rm -f /usr/local/bin/fantastic-probe-cron-scanner
    echo "   ✅ Cron 扫描器已删除"
    FILES_REMOVED=$((FILES_REMOVED + 1))
fi

if [ -f "/usr/local/lib/fantastic-probe-process-lib.sh" ]; then
    rm -f /usr/local/lib/fantastic-probe-process-lib.sh
    echo "   ✅ 处理库已删除"
    FILES_REMOVED=$((FILES_REMOVED + 1))
fi

if [ -f "/usr/local/bin/fantastic-probe-auto-update" ]; then
    rm -f /usr/local/bin/fantastic-probe-auto-update
    echo "   ✅ 自动更新助手已删除"
    FILES_REMOVED=$((FILES_REMOVED + 1))
fi

if [ -f "/usr/local/bin/fp-config" ]; then
    rm -f /usr/local/bin/fp-config
    echo "   ✅ 配置工具已删除"
    FILES_REMOVED=$((FILES_REMOVED + 1))
fi

# 删除兼容性软链接
if [ -L "/usr/local/bin/fantastic-probe-config" ] || [ -f "/usr/local/bin/fantastic-probe-config" ]; then
    rm -f /usr/local/bin/fantastic-probe-config
    echo "   ✅ 兼容链接已删除"
    FILES_REMOVED=$((FILES_REMOVED + 1))
fi

# 删除版本号获取脚本
if [ -f "/usr/local/bin/get-version.sh" ]; then
    rm -f /usr/local/bin/get-version.sh
    echo "   ✅ 版本号获取脚本已删除"
    FILES_REMOVED=$((FILES_REMOVED + 1))
fi

# 删除预编译包
if [ -d "/usr/share/fantastic-probe" ]; then
    rm -rf /usr/share/fantastic-probe
    echo "   ✅ 预编译包已删除"
    FILES_REMOVED=$((FILES_REMOVED + 1))
fi

if [ $FILES_REMOVED -eq 0 ]; then
    echo "   ✅ 所有脚本均不存在"
fi
echo ""

# 6. 清理临时文件和锁文件
echo "2️⃣  清理临时文件和锁文件..."
TEMP_FILES_REMOVED=0

if [ -p "/tmp/fantastic_probe_queue.fifo" ]; then
    rm -f /tmp/fantastic_probe_queue.fifo
    echo "   ✅ 队列文件已删除"
    TEMP_FILES_REMOVED=$((TEMP_FILES_REMOVED + 1))
fi

if [ -f "/tmp/fantastic-probe-update-marker" ]; then
    rm -f /tmp/fantastic-probe-update-marker
    echo "   ✅ 更新标记文件已删除"
    TEMP_FILES_REMOVED=$((TEMP_FILES_REMOVED + 1))
fi

if [ -f "/tmp/fantastic-probe-auto-update.lock" ]; then
    rm -f /tmp/fantastic-probe-auto-update.lock
    echo "   ✅ 更新锁文件已删除"
    TEMP_FILES_REMOVED=$((TEMP_FILES_REMOVED + 1))
fi

# 清理 Cron 扫描器锁文件
if [ -f "/tmp/fantastic_probe_cron_scanner.lock" ]; then
    rm -f /tmp/fantastic_probe_cron_scanner.lock
    echo "   ✅ Cron 扫描器锁文件已删除"
    TEMP_FILES_REMOVED=$((TEMP_FILES_REMOVED + 1))
fi

# 清理可能的临时安装目录
if [ -d "/tmp/fantastic-probe-install-"* ]; then
    rm -rf /tmp/fantastic-probe-install-*
    echo "   ✅ 临时安装目录已删除"
    TEMP_FILES_REMOVED=$((TEMP_FILES_REMOVED + 1))
fi

if [ $TEMP_FILES_REMOVED -eq 0 ]; then
    echo "   ✅ 无临时文件需要清理"
fi
echo ""

# 6.5 删除 Cron 任务
echo "3️⃣  删除 Cron 任务..."
if [ -f "/etc/cron.d/fantastic-probe" ]; then
    rm -f /etc/cron.d/fantastic-probe
    echo "   ✅ Cron 任务已删除"
else
    echo "   ✅ Cron 任务不存在"
fi
echo ""

# 6.6 询问是否删除失败缓存数据库
echo "4️⃣  失败缓存数据库处理..."
if [ -f "/var/lib/fantastic-probe/failure_cache.db" ]; then
    read -p "   是否删除失败缓存数据库？[Y/n]: " delete_cache
    delete_cache="${delete_cache:-Y}"

    if [[ "$delete_cache" =~ ^[Yy]$ ]]; then
        rm -f /var/lib/fantastic-probe/failure_cache.db
        rmdir /var/lib/fantastic-probe 2>/dev/null || true
        echo "   ✅ 失败缓存数据库已删除"
    else
        echo "   ℹ️  失败缓存数据库保留在: /var/lib/fantastic-probe/failure_cache.db"
    fi
else
    echo "   ✅ 失败缓存数据库不存在"
    # 删除空目录
    rmdir /var/lib/fantastic-probe 2>/dev/null || true
fi
echo ""

# 7. 清理 logrotate 配置
echo "5️⃣  清理 logrotate 配置..."
if [ -f "/etc/logrotate.d/fantastic-probe" ]; then
    rm -f /etc/logrotate.d/fantastic-probe
    echo "   ✅ logrotate 配置已删除"
else
    echo "   ✅ logrotate 配置不存在"
fi
echo ""

# 8. 询问是否删除配置文件
echo "6️⃣  配置文件处理..."
if [ -d "/etc/fantastic-probe" ]; then
    read -p "   是否删除配置文件？ (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf /etc/fantastic-probe
        echo "   ✅ 配置目录已删除"
    else
        echo "   ℹ️  配置文件保留在: /etc/fantastic-probe/"
        echo "      如需重新安装，配置将被保留"
    fi
else
    echo "   ✅ 配置目录不存在"
fi
echo ""

# 9. 询问是否删除日志
echo "7️⃣  日志文件处理..."
read -p "   是否删除日志文件？ (y/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -f /var/log/fantastic_probe.log
    rm -f /var/log/fantastic_probe_errors.log
    echo "   ✅ 日志文件已删除"
else
    echo "   ℹ️  日志文件保留在:"
    echo "      /var/log/fantastic_probe.log"
    echo "      /var/log/fantastic_probe_errors.log"
fi
echo ""

# 10. 生成的 JSON 文件处理（已禁用，防止误删用户数据）
echo "8️⃣  生成的 JSON 文件处理..."
echo "   ℹ️  JSON 文件已被保留（包含宝贵的媒体信息扫描结果）"
echo "   ℹ️  如需手动清理，请运行："
echo "      find <STRM_ROOT> -type f -name '*-mediainfo.json' -delete"
echo ""

# 以下代码已禁用，防止卸载时误删用户数据
# 如需删除 JSON 文件，请手动执行上述命令
#
# read -p "   是否删除所有生成的 .iso-mediainfo.json 文件？ (y/N): " -n 1 -r
# echo ""
# if [[ $REPLY =~ ^[Yy]$ ]]; then
#     # 尝试从配置文件读取 STRM_ROOT
#     STRM_ROOT="/mnt/sata1/media/媒体库/strm"  # 默认值
#     if [ -f "/etc/fantastic-probe/config" ]; then
#         # shellcheck source=/dev/null
#         source "/etc/fantastic-probe/config"
#     fi
#
#     if [ -d "$STRM_ROOT" ]; then
#         JSON_COUNT=$(find "$STRM_ROOT" -type f -name "*.iso-mediainfo.json" 2>/dev/null | wc -l)
#         if [ "$JSON_COUNT" -gt 0 ]; then
#             find "$STRM_ROOT" -type f -name "*.iso-mediainfo.json" -delete
#             echo "   ✅ 已删除 $JSON_COUNT 个 JSON 文件"
#         else
#             echo "   ℹ️  没有找到 JSON 文件"
#         fi
#     else
#         echo "   ℹ️  STRM 目录不存在: $STRM_ROOT"
#     fi
# else
#     echo "   ℹ️  JSON 文件保留"
# fi
# echo ""

# 卸载完成
echo "=========================================="
echo "✅ 卸载完成！"
echo "=========================================="
echo ""
echo "ℹ️  如需恢复定时任务方式，请运行:"
