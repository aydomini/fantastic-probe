# Fantastic-Probe - ISO 媒体信息实时提取服务

自动监控 strm 目录，实时提取 ISO 文件的媒体信息并生成 Emby 兼容的 JSON 文件。

---

## 🚀 快速开始

### 一键安装（推荐）

最简单的安装方式，自动检测系统并安装所有依赖：

```bash
curl -fsSL https://raw.githubusercontent.com/aydomini/fantastic-probe/main/install.sh | sudo bash
```

或使用 wget：

```bash
wget -qO- https://raw.githubusercontent.com/aydomini/fantastic-probe/main/install.sh | sudo bash
```

安装脚本会自动完成：
- ✅ 检测系统类型和包管理器
- ✅ 安装所有必需依赖
- ✅ 运行交互式配置向导
- ✅ 配置并启动 systemd 服务
- ✅ 设置开机自启动

<details>
<summary><b>📦 其他安装方式</b>（点击展开）</summary>

### Debian/Ubuntu deb 包

适合 Debian/Ubuntu 用户，提供原生包管理器体验：

```bash
# 下载 deb 包
wget https://github.com/aydomini/fantastic-probe/releases/download/v2.6.1/fantastic-probe_2.6.1_all.deb

# 安装
sudo apt install ./fantastic-probe_2.6.1_all.deb
```

安装后配置：

```bash
# 编辑配置文件
sudo nano /etc/fantastic-probe/config

# 启动服务
sudo systemctl enable --now fantastic-probe-monitor
```

### 手动安装

传统的手动安装方式：

```bash
# 1. 克隆仓库
git clone https://github.com/aydomini/fantastic-probe.git
cd fantastic-probe

# 2. 运行安装脚本
sudo bash fantastic-probe-install.sh
```

### 支持的系统

- ✅ **Debian / Ubuntu** (apt)
- ✅ **RHEL / CentOS / Fedora** (dnf/yum)
- ✅ **Arch Linux / Manjaro** (pacman)
- ✅ **openSUSE** (zypper)

</details>

---

## 🔧 配置管理

### 统一管理工具

安装后会提供统一的管理工具 `fp-config`，集成配置管理、服务管理和日志查看功能：

```bash
# 交互式菜单（推荐）
sudo fp-config

# 或直接执行特定操作
sudo fp-config show       # 查看当前配置
sudo fp-config strm       # 修改 STRM 根目录
sudo fp-config ffprobe    # 重新配置 FFprobe
sudo fp-config status     # 查看服务状态
sudo fp-config logs       # 查看实时日志
```

### 常用操作

**配置相关**：
- **更换 FFprobe 包**：`sudo fp-config ffprobe`
- **修改监控目录**：`sudo fp-config strm`
- **直接编辑配置**：`sudo fp-config edit`

### ⚠️ 监控目录权限注意事项

**重要**：如果监控目录由安装脚本创建，它会以 root 身份创建。安装时会提示您设置合适的权限。

**如果需要以普通用户身份向监控目录写入文件，可以**：

1. **设置特定用户所有（推荐）**：
   ```bash
   # 适用于 Emby/Jellyfin 等媒体服务器
   sudo chown -R emby:emby /mnt/sata1/media/媒体库/strm

   # 或设置为您的用户名
   sudo chown -R $USER:$USER /mnt/sata1/media/媒体库/strm
   ```

2. **验证权限是否正确**：
   ```bash
   ls -ld /mnt/sata1/media/媒体库/strm
   ```

   应该显示您期望的所有者，如 `emby emby` 或您的用户名。

**服务管理**：
- **查看服务状态**：`sudo fp-config status`
- **重启服务**：`sudo fp-config restart`
- **启动/停止服务**：`sudo fp-config start/stop`

**日志管理**：
- **实时监控日志**：`sudo fp-config logs`
- **查看错误日志**：`sudo fp-config logs-error`
- **查看系统日志**：`sudo fp-config logs-system`
- **清空日志文件**：`sudo fp-config logs-clear`

<details>
<summary><b>📋 配置文件说明</b>（点击展开）</summary>

### 配置文件位置

配置文件：`/etc/fantastic-probe/config`

首次安装后，安装程序会运行交互式配置向导。如需修改配置：

```bash
sudo nano /etc/fantastic-probe/config
```

### 主要配置项

| 配置项 | 说明 | 默认值 |
|-------|------|--------|
| `STRM_ROOT` | STRM 文件监控目录 | `/mnt/sata1/media/媒体库/strm` |
| `FFPROBE` | ffprobe 可执行文件路径 | `/usr/bin/ffprobe` |
| `LOG_FILE` | 主日志文件 | `/var/log/fantastic_probe.log` |
| `ERROR_LOG_FILE` | 错误日志文件 | `/var/log/fantastic_probe_errors.log` |
| `FFPROBE_TIMEOUT` | ffprobe 命令超时（秒）<br>**说明**：单个 ffprobe 命令的最大执行时间 | `300` |
| `MAX_FILE_PROCESSING_TIME` | 任务总超时（秒）<br>**说明**：包括预检查、ffprobe、后处理的总时间<br>**要求**：必须 > `FFPROBE_TIMEOUT` | `600` |
| `DEBOUNCE_TIME` | 防抖时间（秒） | `5` |
| `AUTO_UPDATE_CHECK` | 是否自动检查更新 | `true` |
| `AUTO_UPDATE_INSTALL` | 是否自动安装更新 | `false` |

**超时配置说明**：
- `FFPROBE_TIMEOUT`（300秒）：控制单个 ffprobe 命令的超时时间
- `MAX_FILE_PROCESSING_TIME`（600秒）：控制整个任务的超时时间，包括：
  - 预检查（文件存在性、权限检查）
  - ffprobe 执行
  - JSON 生成和权限设置
  - 建议：`MAX_FILE_PROCESSING_TIME` ≥ `FFPROBE_TIMEOUT` + 60 秒

**文件权限说明**：
- 生成的 JSON 文件会**自动继承** STRM 文件的所有者和权限
- 无需手动配置权限，确保与媒体库文件权限一致

### 修改配置后重启服务

```bash
sudo systemctl restart fantastic-probe-monitor
```

</details>

---

## 🔄 更新

### 方式 1：手动更新（推荐）

```bash
# 下载并运行更新脚本
curl -fsSL https://raw.githubusercontent.com/aydomini/fantastic-probe/main/update.sh | sudo bash

# 或直接运行一键安装（会保留现有配置）
curl -fsSL https://raw.githubusercontent.com/aydomini/fantastic-probe/main/install.sh | sudo bash
```

### 方式 2：自动更新

服务默认每 24 小时检查一次更新，发现新版本时会在日志中提示。

**启用自动安装更新**：

```bash
# 编辑配置文件
sudo nano /etc/fantastic-probe/config

# 修改以下配置
AUTO_UPDATE_CHECK=true
AUTO_UPDATE_INSTALL=true  # 启用自动安装更新

# 重启服务
sudo systemctl restart fantastic-probe-monitor
```

**工作原理**：
- 主服务检测到新版本后，会启动后台更新助手
- 更新助手等待任务队列清空（最长等待 1 小时）
- 队列清空后，停止服务 → 执行更新 → 启动服务
- 整个过程无需人工干预，且不会丢失任务

### 检查版本

```bash
# 查看当前版本
grep "CURRENT_VERSION" /usr/local/bin/fantastic-probe-monitor

# 查看日志中的版本信息
journalctl -u fantastic-probe-monitor | grep "版本:"
```

---

## 🗑️ 卸载

```bash
cd /tmp/Fantastic-Probe/
chmod +x fantastic-probe-uninstall.sh
sudo bash fantastic-probe-uninstall.sh
```

### 卸载过程

卸载脚本会执行以下步骤：

1. ✅ **停止并禁用服务**：自动停止运行中的服务
2. ✅ **删除程序文件**：移除主程序、自动更新助手、配置工具
3. ✅ **清理临时文件**：清理锁文件、队列文件、临时目录
4. ✅ **清理 logrotate**：移除日志轮转配置
5. ❓ **询问删除配置**：保留配置可在重新安装时使用
6. ❓ **询问删除日志**：用户选择是否删除日志文件
7. ❓ **询问删除 JSON**：用户选择是否删除生成的媒体信息文件

**注意**：配置文件、日志文件、JSON 文件默认保留（会询问用户）

---

## 🐛 故障排查

### 服务无法启动

```bash
# 查看服务状态和详细错误
sudo fp-config status
# 或使用系统命令查看更多细节
systemctl status fantastic-probe-monitor -l
journalctl -u fantastic-probe-monitor -n 50

# 检查依赖
which inotifywait  # 应该返回路径
which jq           # 应该返回路径
which ffprobe      # 检查 ffprobe
```

**常见问题**：
- 缺少依赖：根据系统安装 `inotify-tools` 和 `jq`
- FFprobe 路径错误：运行 `sudo fp-config ffprobe` 重新配置
- 监控目录不存在：运行 `sudo fp-config show` 检查配置

### 文件未被处理

```bash
# 1. 确认服务运行
sudo fp-config status

# 2. 查看实时日志
sudo fp-config logs

# 3. 手动测试
touch /mnt/sata1/media/媒体库/strm/test.iso.strm
# 立即查看日志，应该看到处理记录

# 4. 检查文件名
# 必须以 .iso.strm 结尾
# 路径必须在监控目录内
```

### 权限问题排查

**症状**：无法向监控目录写入 .iso.strm 文件，或者服务无法读取文件。

**诊断步骤**：

1. **检查监控目录权限**：
   ```bash
   ls -ld /mnt/sata1/media/媒体库/strm
   ```
   应该显示您期望的所有者（如 `emby emby` 或您的用户名）

2. **检查当前用户是否可以写入**：
   ```bash
   # 以目标用户身份测试（如 emby）
   sudo -u emby touch /mnt/sata1/media/媒体库/strm/test.txt

   # 如果成功，清理测试文件
   sudo -u emby rm /mnt/sata1/media/媒体库/strm/test.txt
   ```

3. **修复权限问题**：
   ```bash
   # 方式1：设置为特定用户所有（推荐）
   sudo chown -R emby:emby /mnt/sata1/media/媒体库/strm

   # 方式2：设置宽松权限（不推荐）
   sudo chmod 777 /mnt/sata1/media/媒体库/strm
   ```

4. **检查已生成的 JSON 文件权限**：
   ```bash
   ls -l /mnt/sata1/media/媒体库/strm/*.json
   ```
   JSON 文件会自动继承 STRM 文件的所有者和权限

### JSON 格式错误

```bash
# 验证 JSON 格式
jq . /path/to/xxx.iso-mediainfo.json

# 查看错误日志
sudo fp-config logs-error
```

### 磁盘空间不足

```bash
# 检查可用空间
df -h /mnt/sata1/media/媒体库/strm/

# 清理日志释放空间
sudo fp-config logs-clear
```

---

<details>
<summary><b>📦 预编译 FFprobe</b>（点击展开）</summary>

项目在 `static/` 目录提供了预编译的 ffprobe 二进制文件，方便用户快速部署。

### 支持的架构

- **x86_64** (64位 Intel/AMD): `ffprobe_linux_x64.zip`
- **ARM64** (64位 ARM): `ffprobe_linux_arm64.zip`

### FFprobe 安装选项

运行安装脚本时，如果检测到预编译包，会提供三种选项：

```
   🎬 FFprobe 路径配置

      ✅ 检测到预编译 ffprobe（x86_64）

      选项：
        1) 使用项目提供的预编译 ffprobe（推荐，已优化）
        2) 使用系统已安装的 ffprobe
        3) 手动指定 ffprobe 路径

      请选择 [1/2/3，默认: 1]:
```

**选项说明**：

| 选项 | 说明 | 适用场景 |
|------|------|---------|
| **1** | 使用预编译 ffprobe | 系统未安装 ffprobe，或希望使用统一版本 |
| **2** | 使用系统 ffprobe | 已通过 `apt install ffmpeg` 等方式安装 |
| **3** | 手动指定路径 | 自己编译的 ffprobe 或特殊路径 |

### 预编译版本优势

- ✅ **免编译**：无需安装完整 ffmpeg 包
- ✅ **体积小**：只包含 ffprobe，不含 ffmpeg 和其他工具
- ✅ **版本统一**：确保兼容性
- ✅ **静态链接**：无额外依赖
- ✅ **跨发行版**：可在所有 Linux 发行版运行

### 手动安装预编译 ffprobe

如需手动安装：

```bash
# 解压对应架构的包
unzip static/ffprobe_linux_x64.zip

# 安装到系统路径
sudo cp ffprobe /usr/local/bin/ffprobe
sudo chmod +x /usr/local/bin/ffprobe

# 验证安装
ffprobe -version
```

</details>

<details>
<summary><b>✨ 核心特性</b>（点击展开）</summary>

| 特性 | 说明 |
|------|------|
| ⚡ **实时响应** | 新增 .iso.strm 文件后秒级响应并加入队列 |
| 🔄 **自动重启** | 服务崩溃自动恢复（10秒延迟） |
| 📊 **日志管理** | 自动轮转（10MB/1备份，总空间约20MB） |
| 🛡️ **高可靠性** | 启动扫描 + 防抖机制 + 容错处理 |
| 💾 **低资源占用** | 空闲时 CPU 0% / 内存 ~15MB |
| 🎯 **智能检测** | 自动识别 Bluray/DVD 协议 |
| 🚦 **任务队列** | 串行处理，防止高并发场景下资源耗尽 |
| 🎬 **MPLS 语言提取** | 从蓝光播放列表提取准确的音轨/字幕语言信息 |

</details>

<details>
<summary><b>🎯 工作原理</b>（点击展开）</summary>

### 监控逻辑

**监控的事件**：
- `CREATE` - 新文件创建
- `MOVED_TO` - 文件移动到监控目录

**过滤条件**：
- ✅ 只处理以 `.iso.strm` 结尾的文件
- ❌ 其他文件（.mp4.strm、.mkv.strm 等）会被跳过
- ❌ 不监控文件修改（`MODIFY` 事件）

**触发示例**：
```bash
# ✅ 会触发处理
touch /mnt/.../strm/movie.iso.strm
mv /tmp/movie.iso.strm /mnt/.../strm/

# ❌ 不会触发处理
touch /mnt/.../strm/movie.mp4.strm  # 不是 .iso.strm
echo "new" > movie.iso.strm          # modify 事件，不监控
```

### 监控流程

1. **服务启动**
   - 扫描现有未处理文件
   - 创建任务队列（FIFO）
   - 启动队列处理器（后台进程）
   - 开始监控文件系统事件

2. **检测新文件**
   - inotify 检测到 `.iso.strm` 文件创建
   - 防抖检查（5秒内重复事件跳过）
   - **添加到任务队列**（不是立即处理）

3. **队列处理器**
   - **串行处理**：一次只处理一个文件
   - 从队列读取文件路径（阻塞读取）
   - 等待文件写入完成并避免网盘风控（10秒）
   - **预检查阶段**：
     - 检查文件是否存在
     - 检查是否已有 mediainfo JSON（避免重复处理）
     - 检查文件是否可读
   - **任务执行阶段**：
     - 后台执行处理任务
     - 超时控制：单个任务最长 300 秒（5分钟）
     - 错误处理：失败任务自动跳过，不阻塞队列
   - 提取媒体信息并生成 JSON

4. **结果**
   - 成功：日志记录 ✅ SUCCESS
   - 失败：日志记录 ❌ ERROR，写入错误日志

### 任务队列机制

**为什么需要任务队列？**
- 防止高并发场景下资源耗尽
- 每个 ISO 处理需要 1-5 分钟
- 如果每秒都有新文件，无队列会启动大量并发进程导致系统崩溃

**队列工作原理**：
```
inotify 监控 → 防抖检查 → 加入队列 → 队列处理器（串行）→ 生成 JSON
(生产者)                                    (消费者)
```

**优势**：
- ✅ 保证一次只处理一个文件
- ✅ 避免资源耗尽
- ✅ 文件按顺序处理，先进先出
- ✅ 即使每秒都有新文件，也能稳定运行
- ✅ **智能预检查**：任务执行前验证文件状态，避免无效处理
- ✅ **超时保护**：卡死任务自动终止，不阻塞队列
- ✅ **错误隔离**：单个任务失败不影响后续任务

**示例**：
```
时间轴：每秒1个文件（高并发场景）
├─ 0秒: file1.iso.strm → 加入队列 → 开始处理 (120秒)
├─ 1秒: file2.iso.strm → 加入队列 → 等待
├─ 2秒: file3.iso.strm → 加入队列 → 等待
...
├─ 120秒: file1 处理完成 → 等待10秒 → file2 开始处理 (120秒)
└─ 250秒: file2 处理完成 → 等待10秒 → file3 开始处理

结果：任意时刻只有1个ffprobe运行，系统稳定！✅
注：10秒间隔可避免触发网盘频率限制
```

### 生成的文件

对于 `xxx.iso.strm` 文件，会生成：
- `xxx.iso-mediainfo.json` - Emby 兼容的媒体信息

**JSON 中的关键信息**：
- `Size` - ISO 文件的实际磁盘大小（字节）
- `RunTimeTicks` - 媒体时长
- `MediaStreams` - 视频/音频/字幕流信息
- `Chapters` - 章节信息

**日志显示示例**：
```
[2026-01-20 HH:MM:SS] ℹ️  INFO: 处理: movie.iso.strm
[2026-01-20 HH:MM:SS] ℹ️  INFO:   ISO 路径: /path/to/movie.iso
[2026-01-20 HH:MM:SS] ℹ️  INFO:   ISO 大小: 46.23 GB (49647272960 bytes)
[2026-01-20 HH:MM:SS] ℹ️  INFO:   ISO 类型: BLURAY
[2026-01-20 HH:MM:SS] ℹ️  INFO:   尝试从 MPLS 提取语言信息...
[2026-01-20 HH:MM:SS] ℹ️  INFO:   主播放列表: BDMV/PLAYLIST/00000.mpls (时长: 7200秒)
[2026-01-20 HH:MM:SS] ℹ️  INFO:   从 MPLS 提取语言信息: BDMV/PLAYLIST/00000.mpls
[2026-01-20 HH:MM:SS] ✅ SUCCESS: 成功从 MPLS 提取媒体信息
[2026-01-20 HH:MM:SS] ✅ SUCCESS: 已生成: movie.iso-mediainfo.json
[2026-01-20 HH:MM:SS] ℹ️  INFO:   视频流: 1, 音频流: 3, 字幕流: 15
```

### MPLS 语言提取

**解决的问题**：

蓝光光盘的音轨和字幕语言信息存储在 **BDMV/PLAYLIST/*.mpls** 文件中，而不是 M2TS 流文件中。直接从 M2TS 提取会导致语言标签显示为 `undefined`（未指定）。

**工作原理**：

1. **自动查找主播放列表**
   - 扫描 ISO 内的 BDMV/PLAYLIST 目录
   - 逐个分析播放列表时长
   - 选择时长最长的作为主播放列表（通常是正片）

2. **从 MPLS 提取准确的语言信息**
   - 使用 ffprobe 的 bluray 协议读取 mpls 文件
   - 获取准确的音轨语言（Chinese, English, Japanese 等）
   - 获取准确的字幕语言和标题信息

3. **智能回退机制**
   - 如果找不到 MPLS 或提取失败，自动回退到标准方式
   - 确保兼容性和稳定性

**依赖工具**：

- `isoinfo`（genisoimage 包）- 列出 ISO 内的文件（推荐）
- `7z`（p7zip-full 包）- 备选工具

安装脚本会自动安装所需工具。

**效果对比**：

| 提取方式 | 音轨语言 | 字幕语言 | 准确度 |
|---------|---------|---------|--------|
| **直接从 M2TS** | undefined | undefined | ❌ 不准确 |
| **从 MPLS** | Chinese, English, Japanese | Chinese Simplified, English | ✅ 准确 |

**注意事项**：

- 仅适用于蓝光（BLURAY）类型的 ISO
- DVD 仍使用标准提取方式
- 如果 ISO 内没有 BDMV/PLAYLIST 目录，自动回退到标准方式

### 健壮性机制

**问题场景**：队列中的任务在准备执行时可能遇到各种问题：
- 文件已被删除或移动
- 已有 JSON 文件（重复任务）
- 文件权限问题（不可读）
- 任务处理超时或卡死
- ISO 文件损坏或格式错误

**解决方案：三层保护机制**

#### 1. 预检查阶段（执行前验证）

在任务真正开始处理前，进行快速验证：

```
✓ 检查文件是否存在
✓ 检查是否已有 mediainfo JSON（避免重复）
✓ 检查文件是否可读
```

**优势**：
- 快速跳过无效任务（毫秒级）
- 避免浪费资源启动 ffprobe
- 日志清晰显示跳过原因

**日志示例**：
```
[2026-01-20 HH:MM:SS] ⚠️  WARN: 队列中的文件已不存在，跳过: movie.iso.strm
[2026-01-20 HH:MM:SS] ℹ️  INFO: 跳过（已有JSON）: movie.iso.strm
[2026-01-20 HH:MM:SS] ❌ ERROR: 文件不可读，跳过: movie.iso.strm
```

#### 2. 超时保护（防止任务卡死）

**问题**：某些 ISO 文件可能因损坏、权限或网络问题导致 ffprobe 卡死

**解决方案**：
- 单个任务最长执行时间：300 秒（5分钟）
- 超时后自动终止任务进程（kill -9）
- 记录超时日志到错误日志文件
- 自动处理下一个任务

**日志示例**：
```
[2026-01-20 HH:MM:SS] ❌ ERROR: 文件处理超时（300秒），强制终止: movie.iso.strm
```

#### 3. 错误隔离（失败不阻塞队列）

**问题**：某个任务失败可能导致整个队列停止

**解决方案**：
- 使用 `set +e` 临时禁用 errexit
- 捕获任务退出码，记录详细错误信息
- 失败后自动跳过，继续处理下一个任务
- 所有错误写入独立错误日志

**日志示例**：
```
[2026-01-20 HH:MM:SS] ❌ ERROR: 文件处理失败（退出码: 1）
# 同时写入 /var/log/fantastic_probe_errors.log
[2026-01-20 HH:MM:SS] ERROR: 任务失败（退出码: 1） - /path/to/movie.iso.strm
```

**效果**：
- ✅ 单个任务失败不影响其他任务
- ✅ 队列持续运行，不会卡死
- ✅ 所有错误可追溯，方便排查问题

</details>

<details>
<summary><b>📊 性能数据</b>（点击展开）</summary>

### 资源占用

| 状态 | CPU | 内存 | 磁盘 I/O |
|------|-----|------|---------|
| **空闲** | 0% | 15-20 MB | 0 |
| **处理中** | 根据 ISO 大小 | 20-50 MB | 读取 ISO |

### 处理速度

| ISO 大小 | 处理时间（参考） |
|---------|-----------------|
| < 10 GB | 10-30 秒 |
| 10-30 GB | 30-60 秒 |
| 30-50 GB | 1-2 分钟 |
| > 50 GB | 2-5 分钟 |

*实际时间取决于 ISO 内容、磁盘速度和 CPU 性能*

</details>

<details>
<summary><b>❓ 常见问题</b>（点击展开）</summary>

**Q: 实时监控会影响系统性能吗？**

A: 几乎不会。inotify 是内核级别的监控机制，空闲时 CPU 占用接近 0%，比定时全量扫描更高效。

**Q: 可以同时监控多个目录吗？**

A: 当前版本只监控单个根目录，但会递归监控所有子目录。

**Q: 服务崩溃了怎么办？**

A: systemd 会自动重启服务（延迟 10 秒）。查看日志了解崩溃原因：
```bash
journalctl -u fantastic-probe-monitor --since "1 hour ago"
```

**Q: 能否处理已有的文件？**

A: 可以！服务启动时会自动扫描现有文件，处理所有未生成 JSON 的 `.iso.strm` 文件。也可以手动重启服务来触发扫描：
```bash
systemctl restart fantastic-probe-monitor
```

**Q: 如何暂停监控？**

A: 停止服务即可：
```bash
systemctl stop fantastic-probe-monitor
```

需要时重新启动：
```bash
systemctl start fantastic-probe-monitor
```

**Q: 日志文件会无限增长吗？**

A: 不会。已配置 logrotate 自动管理：
- 单个文件最大 10MB
- 保留 1 个备份
- 总空间约 20MB

</details>

<details>
<summary><b>📝 版本历史</b>（点击展开）</summary>

- **v2.6.1** (2026-01-20) - 🐛 修复 jq 脚本错误和日志显示优化：修复 DisplayLanguage 字段引用错误导致 JSON 转换失败，优化日志顺序明确双步骤处理流程（ffprobe 提取基础信息 + MPLS 增强语言信息）
- **v2.6.0** (2026-01-20) - 🎨 集成 7z+MPLS 语言提取功能：支持从蓝光 ISO 的 MPLS 文件中提取音轨和字幕语言信息，自动安装 parse_mpls.py 解析脚本，完整的回退机制确保稳定性
- **v2.5.2** (2026-01-20) - 修复 ISO 文件大小显示问题：移除 bc 依赖，改用系统标准 awk 计算（解决部分系统 ISO 大小显示为 0 MB 的问题）
- **v2.5.1** (2026-01-20) - 禁用 MPLS 提取逻辑，恢复标准提取方式（用户反馈：标准提取信息最完整，ffprobe bluray 协议已自动处理所有逻辑）
- **v2.5.0** (2026-01-20) - MPLS 语言提取支持：提取 BDMV 结构读取蓝光音轨/字幕语言信息，兼容 rclone fuse 挂载，强制安装 7z 依赖，修复临时目录冲突，配置面板更新自动重启
- **v2.4.0** (2026-01-20) - 命名统一：所有命名统一为 `fantastic-probe`，简化用户体验
- **v2.4.0** (2026-01-20) - 通用 Linux 安装方案：多发行版支持、配置文件分离、一键安装脚本、Deb 包支持、自动更新机制
- **v2.2.0** (2026-01-20) - 添加 MPLS 语言提取，解决蓝光音轨/字幕语言 undefined 问题
- **v2.1.1** (2026-01-20) - 增强队列处理器的预检查、超时保护和错误隔离机制
- **v2.1.0** (2026-01-20) - 添加任务队列和并发控制，防止高并发场景下资源耗尽
- **v2.0.2** (2026-01-20) - 添加 ISO 文件实际大小获取和日志显示
- **v2.0.1** (2026-01-20) - 修复启动扫描错误处理，防止服务启动失败
- **v2.0.0** (2026-01-20) - 实时监控版本，基于 inotify

</details>

---

**项目**: Fantastic-Probe
**作者**: aydomini
**仓库**: https://github.com/aydomini/fantastic-probe
**许可**: MIT License
**更新**: 2026-01-20
