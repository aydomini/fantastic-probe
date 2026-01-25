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
| `FFPROBE_TIMEOUT` | ffprobe 命令超时（秒） | `300` |
| `MAX_FILE_PROCESSING_TIME` | 任务总超时（秒）<br>**说明**：包括预检查、ffprobe、后处理的总时间 | `600` |
| `DEBOUNCE_TIME` | 防抖时间（秒） | `5` |
| `AUTO_UPDATE_CHECK` | 是否自动检查更新 | `true` |
| `AUTO_UPDATE_INSTALL` | 是否自动安装更新 | `false` |

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
/usr/local/bin/get-version.sh

# 或查看日志中的版本信息
journalctl -u fantastic-probe-monitor | grep "版本"
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

## 🐛 故障排查与常见问题

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

### 权限问题

**症状**：无法向监控目录写入文件，或服务无法读取文件。

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
   # 推荐：设置为特定用户所有
   sudo chown -R emby:emby /mnt/sata1/media/媒体库/strm

   # 或设置为您的用户名
   sudo chown -R $USER:$USER /mnt/sata1/media/媒体库/strm
   ```

4. **检查生成的 JSON 文件权限**：
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

### 常见问题解答

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
- 只处理以 `.iso.strm` 结尾的文件

### 任务队列机制

**为什么需要任务队列？**
- 防止高并发场景下资源耗尽（每个 ISO 处理需要 1-5 分钟）
- 保证一次只处理一个文件，避免系统崩溃

**队列工作原理**：
```
inotify 监控 → 防抖检查 → 加入队列 → 队列处理器（串行）→ 生成 JSON
```

**处理流程**：
1. **服务启动**：扫描现有文件 → 创建任务队列 → 启动队列处理器 → 监控文件系统
2. **检测新文件**：inotify 检测到文件 → 防抖检查 → 添加到队列
3. **队列处理**：串行处理，等待文件稳定（10秒）→ 预检查 → 提取媒体信息 → 生成 JSON

**优势**：
- ✅ 保证一次只处理一个文件
- ✅ 避免资源耗尽
- ✅ 智能预检查，避免无效处理
- ✅ 超时保护，卡死任务自动终止
- ✅ 错误隔离，单个任务失败不影响后续

### 生成的文件

对于 `xxx.iso.strm` 文件，会生成 `xxx.iso-mediainfo.json`，包含：
- `Size` - ISO 文件实际大小（字节）
- `RunTimeTicks` - 媒体时长
- `MediaStreams` - 视频/音频/字幕流信息
- `Chapters` - 章节信息

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

---

## 📚 文档

- **[CHANGELOG.md](CHANGELOG.md)** - 版本历史和更新日志

---

**项目**: Fantastic-Probe
**作者**: aydomini
**仓库**: https://github.com/aydomini/fantastic-probe
**许可**: MIT License
**更新**: 2026-01-25
