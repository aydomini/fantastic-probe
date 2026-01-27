# Fantastic-Probe - ISO 媒体信息实时提取服务

自动监控 STRM 目录，实时提取 ISO 文件的媒体信息并生成 Emby 兼容的 JSON 文件。

---

## 安装流程

### 一键安装（推荐）

使用以下命令自动安装：

```bash
curl -fsSL https://raw.githubusercontent.com/aydomini/fantastic-probe/main/install.sh | sudo bash
```

或使用 wget：

```bash
wget -qO- https://raw.githubusercontent.com/aydomini/fantastic-probe/main/install.sh | sudo bash
```

**安装脚本会自动完成：**

1. 检测系统类型（支持 Debian/Ubuntu、RHEL/CentOS/Fedora、Arch Linux、openSUSE）
2. 安装必需依赖（`sqlite3`、`jq` 等）
3. 运行交互式配置向导（配置 STRM 根目录、FFprobe 路径等）
4. 安装预编译 FFprobe（可选，支持 x86_64 和 ARM64 架构）
5. 配置 Cron 定时任务（默认每分钟扫描一次）
6. 配置日志轮转（自动管理日志大小）

### 手动安装

```bash
# 1. 克隆仓库
git clone https://github.com/aydomini/fantastic-probe.git
cd fantastic-probe

# 2. 运行安装脚本
sudo bash fantastic-probe-install.sh
```

### 支持的系统

- ✅ Debian / Ubuntu (apt)
- ✅ RHEL / CentOS / Fedora (dnf/yum)
- ✅ Arch Linux / Manjaro (pacman)
- ✅ openSUSE (zypper)

---

## 更新流程

### 手动更新

```bash
# 下载并运行更新脚本
curl -fsSL https://raw.githubusercontent.com/aydomini/fantastic-probe/main/update.sh | sudo bash

# 或直接运行一键安装（会保留现有配置）
curl -fsSL https://raw.githubusercontent.com/aydomini/fantastic-probe/main/install.sh | sudo bash
```

更新过程会：
- 保留现有配置文件
- 自动备份并替换主程序
- 无需重新配置

### 检查版本

```bash
# 查看当前版本
/usr/local/bin/get-version.sh

# 或查看配置工具显示的版本信息
sudo fp-config show
```

---

## 卸载流程

```bash
cd /tmp/Fantastic-Probe/
chmod +x fantastic-probe-uninstall.sh
sudo bash fantastic-probe-uninstall.sh
```

### 卸载过程详解

卸载脚本会按以下步骤执行：

**1. 删除脚本和工具**
- 删除主程序：`fantastic-probe-monitor`、`fantastic-probe-cron-scanner`
- 删除辅助工具：`fp-config`、`get-version.sh`
- 删除处理库：`fantastic-probe-process-lib.sh`

**2. 清理临时文件**
- 删除锁文件、队列文件、更新标记等

**3. 删除 Cron 任务**
- 移除 `/etc/cron.d/fantastic-probe` 定时任务配置

**4. 询问删除失败缓存**
- 可选择删除失败文件记录数据库 `/var/lib/fantastic-probe/failure_cache.db`

**5. 清理 logrotate 配置**
- 删除日志轮转配置 `/etc/logrotate.d/fantastic-probe`

**6. 询问删除配置文件**（可选）
- 可选择保留 `/etc/fantastic-probe/config` 配置文件
- 保留配置可在重新安装时使用

**7. 询问删除日志文件**（可选）
- `/var/log/fantastic_probe.log`（主日志）
- `/var/log/fantastic_probe_errors.log`（错误日志）

**8. 询问删除生成的 JSON 文件**（可选）
- 删除所有 `*.iso-mediainfo.json` 文件
- ⚠️ 注意：删除后 Emby 需要重新扫描媒体库

---

## 配置管理工具（fp-config）

### 统一管理工具

安装后提供统一的管理工具 `fp-config`，集成配置管理、日志查看和故障排查功能：

```bash
# 交互式菜单（推荐）
sudo fp-config

# 或直接执行特定操作
sudo fp-config show       # 查看当前配置
sudo fp-config strm       # 修改 STRM 根目录
sudo fp-config ffprobe    # 重新配置 FFprobe
sudo fp-config logs       # 查看实时日志
```

### 核心功能

#### 配置管理

```bash
sudo fp-config show       # 查看当前配置
sudo fp-config strm       # 修改 STRM 根目录
sudo fp-config ffprobe    # 重新配置 FFprobe 路径
sudo fp-config emby       # 配置 Emby 媒体库集成
sudo fp-config edit       # 直接编辑配置文件
```

#### 失败文件管理（Cron 模式）

```bash
sudo fp-config failure-list      # 查看失败文件列表
sudo fp-config failure-clear     # 清空失败缓存
sudo fp-config failure-reset     # 重置单个文件的失败记录
```

#### 日志管理

```bash
sudo fp-config logs              # 查看实时主日志
sudo fp-config logs-error        # 查看错误日志
sudo fp-config logs-clear        # 清空日志文件
```

#### 服务管理

```bash
sudo fp-config status            # 查看服务状态
sudo fp-config restart           # 重启服务
sudo fp-config start             # 启动服务
sudo fp-config stop              # 停止服务
```

#### 系统管理

```bash
sudo fp-config check-update      # 检查更新
sudo fp-config install-update    # 安装更新
sudo fp-config uninstall         # 卸载服务
```

### FFprobe 配置详解

#### 核心要求

⚠️ **重要**：ffprobe 必须**编译支持 bluray 和 dvd 协议**才能读取 ISO 文件。

本项目使用 ffprobe 的 `bluray:` 和 `dvd:` 协议直接读取 ISO 文件内容：
```bash
# 核心命令示例
ffprobe -protocol_whitelist "file,bluray" -i "bluray:/path/to/file.iso"
ffprobe -protocol_whitelist "file,dvd" -i "dvd:/path/to/file.iso"
```

**为什么需要预编译包？**
- 系统自带的 ffprobe（`apt install ffmpeg`）**通常不支持** bluray/dvd 协议
- 需要在编译 ffmpeg 时启用 `--enable-libbluray` 和 `--enable-libdvdread`
- 本项目提供的预编译包已包含这些协议支持

#### 预编译 FFprobe 包

项目在 GitHub Release 中提供预编译的 ffprobe 二进制文件：

- **x86_64**（64位 Intel/AMD）：`ffprobe_linux_x64.zip`
- **ARM64**（64位 ARM）：`ffprobe_linux_arm64.zip`

**优势：**
- ✅ **已编译支持 bluray/dvd 协议**（核心功能）
- 免编译，无需安装完整 ffmpeg 包
- 体积小，只包含 ffprobe
- 静态链接，无额外依赖
- 跨发行版兼容

#### 安装选项

运行 `sudo fp-config ffprobe` 时，提供三种选项：

1. **使用预编译 ffprobe**（推荐）
   - 自动从 GitHub Release 下载
   - 或使用本地缓存（如已下载）
   - 安装到 `/usr/local/bin/ffprobe`

2. **使用系统 ffprobe**
   - 使用系统已安装的 ffmpeg 包
   - 需先安装：`sudo apt-get install -y ffmpeg`

3. **手动指定路径**
   - 适用于自己编译的 ffprobe
   - 或特殊路径（如 Docker 容器内）

#### 离线安装预编译包

```bash
# 1. 从 GitHub Release 下载对应架构的包
wget https://github.com/aydomini/fantastic-probe/releases/download/ffprobe-prebuilt-v1.0/ffprobe_linux_x64.zip

# 2. 解压
unzip ffprobe_linux_x64.zip

# 3. 安装到系统路径
sudo cp ffprobe /usr/local/bin/ffprobe
sudo chmod +x /usr/local/bin/ffprobe

# 4. 验证安装
ffprobe -version
```

### Emby 媒体库集成

启用后，每次生成媒体信息 JSON 文件时自动通知 Emby 刷新媒体库。

```bash
# 配置 Emby 集成
sudo fp-config emby
```

**配置步骤：**

1. 选择是否启用 Emby 集成
2. 输入 Emby 服务器地址（如 `http://127.0.0.1:8096`）
3. 输入 Emby API 密钥（在 Emby 控制台 → 高级 → 安全 → API 密钥中生成）
4. 测试连接（可选，推荐）
5. 保存配置

**配置示例：**

```bash
EMBY_ENABLED=true
EMBY_URL="http://127.0.0.1:8096"
EMBY_API_KEY="your-api-key-here"
EMBY_NOTIFY_TIMEOUT=5
```

---

## 配置文件说明

### 配置文件位置

`/etc/fantastic-probe/config`

### 主要配置项

| 配置项 | 说明 | 默认值 |
|-------|------|--------|
| `STRM_ROOT` | STRM 文件监控目录 | `/mnt/sata1/media/媒体库/strm` |
| `FFPROBE` | ffprobe 可执行文件路径 | `/usr/bin/ffprobe` |
| `LOG_FILE` | 主日志文件 | `/var/log/fantastic_probe.log` |
| `ERROR_LOG_FILE` | 错误日志文件 | `/var/log/fantastic_probe_errors.log` |
| `FFPROBE_TIMEOUT` | ffprobe 命令超时（秒） | `300` |
| `MAX_FILE_PROCESSING_TIME` | 任务总超时（秒）<br>包括预检查、ffprobe、后处理的总时间 | `600` |
| `DEBOUNCE_TIME` | 防抖时间（秒） | `5` |
| `CRON_MAX_RETRY_COUNT` | Cron 模式最大重试次数 | `3` |
| `CRON_SCAN_BATCH_SIZE` | Cron 单次扫描文件限制 | `10` |
| `EMBY_ENABLED` | 是否启用 Emby 集成 | `false` |
| `EMBY_URL` | Emby 服务器地址 | `""` |
| `EMBY_API_KEY` | Emby API 密钥 | `""` |

**文件权限说明：**
- 生成的 JSON 文件会**自动继承** STRM 文件的所有者和权限
- 无需手动配置权限，确保与媒体库文件权限一致

### 修改配置后应用

```bash
# Cron 模式（默认）：配置会自动生效，无需重启
# 配置将在下次 Cron 任务执行时自动应用（最多等待 1 分钟）
```

---

## ffprobe 可以从 ISO.strm 文件中提取的信息

根据 `fantastic-probe-process-lib.sh` 的实现，ffprobe 可以从 ISO 文件中提取以下媒体信息：

### 1. 格式信息（Container）

- **容器格式**（Container）：如 `mpegts`、`matroska` 等
- **时长**（Duration）：媒体总时长（转换为 Emby 的 RunTimeTicks 格式）
- **比特率**（Bitrate）：整体比特率
- **文件大小**（Size）：ISO 文件实际大小

### 2. 视频流信息

- **编解码器**（Codec）：如 `H264`、`HEVC`、`VC1` 等
- **分辨率**（Width/Height）：视频宽度和高度
- **帧率**（FrameRate）：平均帧率和实际帧率
- **HDR 类型**（VideoRange）：
  - `SDR`：标准动态范围
  - `HDR10`：HDR10 格式
  - `DolbyVision`：杜比视界（包括 Profile 信息）
  - `HLG`：混合对数伽马
- **色彩信息**：
  - 色彩传输特性（ColorTransfer）：如 `smpte2084`（HDR10）、`arib-std-b67`（HLG）
  - 色彩原色（ColorPrimaries）
  - 色彩空间（ColorSpace）
- **编码信息**：
  - 编码配置（Profile）：如 `High`、`Main` 等
  - 编码级别（Level）
  - 参考帧数（RefFrames）
  - 比特深度（BitDepth）
  - 像素格式（PixelFormat）
- **画面特性**：
  - 宽高比（AspectRatio）
  - 是否隔行扫描（IsInterlaced）

### 3. 音频流信息

- **编解码器**（Codec）：如 `DTS`、`AC3`、`TRUEHD`、`AAC` 等
- **语言**（Language）：音轨语言代码（自动转换为完整语言名称）
  - 支持语言：Chinese、English、Japanese、Korean、Spanish、French、German、Italian、Portuguese、Russian、Arabic、Hindi、Thai、Vietnamese
- **声道**（Channels）：声道数（如 2、6、8）
  - 自动识别：mono（单声道）、stereo（立体声）、5.1、7.1 等
- **采样率**（SampleRate）：音频采样率
- **比特率**（BitRate）：音频比特率
- **声道布局**（ChannelLayout）：如 `5.1(side)`
- **标记**（Disposition）：
  - 是否默认音轨（IsDefault）
  - 是否强制音轨（IsForced）

### 4. 字幕流信息

- **格式**（Codec）：如 `PGSSUB`（蓝光字幕）、`DVDSUB`、`SUBRIP`、`ASS`、`WEBVTT` 等
- **语言**（Language）：字幕语言
  - 智能识别简繁体中文：
    - `Chinese Simplified`（简体中文）
    - `Chinese Traditional`（繁体中文）
    - `Chinese`（粤语或未区分简繁）
- **标题**（Title）：字幕标题（如 "中文字幕"、"English (SDH)"）
- **类型识别**：
  - 是否文本字幕（IsTextSubtitleStream）
  - 是否听障字幕（IsHearingImpaired）：自动识别 SDH 标记
- **标记**（Disposition）：
  - 是否默认字幕（IsDefault）
  - 是否强制字幕（IsForced）

### 5. 章节信息

- **章节时间**（StartPositionTicks）：章节起始时间（Emby Ticks 格式）
- **章节名称**（Name）：章节标题（如 "Chapter 01"、自定义章节名）
- **章节索引**（ChapterIndex）：章节编号

### 6. 流元数据

- **流索引**（Index）：流在文件中的索引
- **时间基**（TimeBase）：流的时间基准
- **Disposition 标记**：
  - `default`：默认流
  - `forced`：强制流
  - `hearing_impaired`：听障辅助
  - 其他自定义标记

### 7. 高级媒体特性

- **杜比视界信息**（Dolby Vision）：
  - 自动检测 DV Profile（如 Profile 5、Profile 7）
  - 提取 DV Level 信息
  - 生成完整描述（ExtendedVideoSubTypeDescription）
- **HDR 元数据**：
  - 自动识别 HDR10、HLG、SDR
  - 提取色彩传输特性
- **音频标题智能处理**：
  - 显示语言 + 编解码器 + 声道布局
  - 自动标注默认音轨
- **字幕智能处理**：
  - 自动识别简繁体中文
  - 智能标注 SDH（听障字幕）
  - 显示默认字幕标记

### 输出格式

所有提取的信息会被转换为 Emby `MediaSourceInfo` 格式，保存为 JSON 文件：

```
xxx.iso.strm → xxx.iso-mediainfo.json
```

JSON 文件包含：
- `MediaSourceInfo`：媒体源信息（容器、时长、比特率等）
- `MediaStreams`：所有流信息（视频、音频、字幕）
- `Chapters`：章节信息

---

## 运行模式

### Cron 模式（默认，推荐）

- 定时扫描模式，每分钟执行一次
- 不依赖 `inotifywait`，更稳定
- 自动失败重试机制（最多 3 次）
- 失败文件缓存数据库（避免重复处理）

**查看 Cron 配置：**

```bash
cat /etc/cron.d/fantastic-probe
```

**查看运行日志：**

```bash
sudo fp-config logs
# 或
tail -f /var/log/fantastic_probe.log
```

---

## 日志管理

### 日志文件

- **主日志**：`/var/log/fantastic_probe.log`（所有操作记录）
- **错误日志**：`/var/log/fantastic_probe_errors.log`（仅错误记录）

### 日志轮转

已配置 logrotate 自动管理：
- 单个文件最大 1MB
- 保留 1 个备份
- 总空间约 2MB

### 查看日志

```bash
# 实时主日志
sudo fp-config logs

# 错误日志
sudo fp-config logs-error

# 清空日志
sudo fp-config logs-clear
```

---

## 故障排查

### 常见问题

**Q1: 文件未被处理？**

```bash
# 1. 查看运行日志
sudo fp-config logs

# 2. 检查文件名格式（必须以 .iso.strm 结尾）
ls /path/to/strm/

# 3. 查看失败文件列表（Cron 模式）
sudo fp-config failure-list
```

**Q2: 权限问题？**

```bash
# 检查监控目录权限
ls -ld /path/to/strm/

# 检查生成的 JSON 文件权限（应与 STRM 文件一致）
ls -l /path/to/strm/*.json
```

**Q3: FFprobe 路径错误？**

```bash
# 重新配置 FFprobe
sudo fp-config ffprobe
```

**Q4: JSON 格式错误？**

```bash
# 验证 JSON 格式
jq . /path/to/xxx.iso-mediainfo.json

# 查看错误日志
sudo fp-config logs-error
```

### 日志文件会无限增长吗？

不会。已配置 logrotate 自动管理：
- 单个文件最大 1MB
- 保留 1 个备份
- 总空间约 2MB

---

## 项目信息

**项目名称**：Fantastic-Probe

**作者**：aydomini

**仓库地址**：https://github.com/aydomini/fantastic-probe

**许可证**：MIT License

**文档**：[CHANGELOG.md](CHANGELOG.md) - 版本历史和更新日志

**最后更新**：2026-01-27
