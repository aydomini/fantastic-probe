# Fantastic-Probe

Automatic media info extraction and metadata scraping service for STRM files.

## Features

- **ISO.STRM Processing** - Extract media info from ISO files via FFprobe bluray:/dvd: protocol
- **Regular STRM Processing** - Support HTTP links, Alist, and local video files
- **TMDB Metadata Scraping** - Auto-generate NFO files and download posters/backdrops
- **Cron-based Scanner** - Auto-scan every minute with smart retry mechanism

---

## Installation

### Quick Install (Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/aydomini/fantastic-probe/main/install.sh | sudo bash
```

Or using wget:

```bash
wget -qO- https://raw.githubusercontent.com/aydomini/fantastic-probe/main/install.sh | sudo bash
```

The installer will:

1. Detect your Linux distribution (Debian/Ubuntu, RHEL/CentOS, Arch, openSUSE)
2. Install dependencies (sqlite3, jq, etc.)
3. Run interactive setup wizard
4. Install prebuilt FFprobe (optional, for x86_64/ARM64)
5. Configure Cron job (scan every minute)
6. Setup log rotation

### Manual Install

```bash
git clone https://github.com/aydomini/fantastic-probe.git
cd fantastic-probe
sudo bash fantastic-probe-install.sh
```

---

## Uninstall

```bash
cd /tmp/Fantastic-Probe/
chmod +x fantastic-probe-uninstall.sh
sudo bash fantastic-probe-uninstall.sh
```

The uninstaller will:

- Remove all scripts and tools
- Delete Cron job
- Optionally remove config files, logs, and generated JSON files

---

## Configuration Tool (fp-config)

### Interactive Menu

```bash
sudo fp-config
```

### Quick Commands

**Configuration:**

```bash
sudo fp-config show            # View current config
sudo fp-config strm-root       # Change STRM root directory
sudo fp-config ffprobe         # Reconfigure FFprobe
sudo fp-config tmdb-config     # Configure TMDB metadata scraping
sudo fp-config performance     # Configure retry & rate limiting
sudo fp-config emby            # Configure Emby integration
sudo fp-config edit            # Edit config file directly
```

**Failure Management (Cron mode):**

```bash
sudo fp-config failure-list    # View failed files
sudo fp-config failure-clear   # Clear failure cache
sudo fp-config failure-reset   # Reset single file retry count
```

**Logs:**

```bash
sudo fp-config logs            # View live logs
sudo fp-config logs-error      # View error logs
```

**Service:**

```bash
sudo fp-config status          # Check service status
sudo fp-config restart         # Restart service
```

**System:**

```bash
sudo fp-config check-update    # Check for updates
sudo fp-config install-update  # Install updates
sudo fp-config uninstall       # Uninstall service
```

---

## FFprobe with Bluray/DVD Protocol

### Why Prebuilt FFprobe?

**IMPORTANT:** FFprobe must be compiled with **bluray and dvd protocol support** to read ISO files.

This project uses FFprobe's `bluray:` and `dvd:` protocols to directly analyze ISO files:

```bash
ffprobe -protocol_whitelist "file,bluray" -i "bluray:/path/to/file.iso"
ffprobe -protocol_whitelist "file,dvd" -i "dvd:/path/to/file.iso"
```

**Why prebuilt package?**

- System FFprobe (from `apt install ffmpeg`) usually **does NOT support** bluray/dvd protocols
- Requires compiling FFmpeg with `--enable-libbluray` and `--enable-libdvdread`
- Our prebuilt package includes these protocols out-of-the-box

### Prebuilt FFprobe Packages

Available on GitHub Releases:

- **x86_64** (64-bit Intel/AMD): `ffprobe_linux_x64.zip`
- **ARM64** (64-bit ARM): `ffprobe_linux_arm64.zip`

**Advantages:**

- ✅ Pre-compiled with bluray/dvd protocol support
- No compilation needed
- Statically linked, no extra dependencies
- Cross-distro compatible

### Installation Options

When running `sudo fp-config ffprobe`, choose:

1. **Use prebuilt FFprobe** (Recommended)
   - Auto-download from GitHub Release
   - Or use local cache if available
   - Installs to `/usr/local/bin/ffprobe`

2. **Use system FFprobe**
   - Use FFmpeg from system package manager
   - Install first: `sudo apt-get install -y ffmpeg`

3. **Specify custom path**
   - For self-compiled FFprobe
   - Or special paths (e.g., Docker containers)

### Manual Installation

```bash
# 1. Download from GitHub Release
wget https://github.com/aydomini/fantastic-probe/releases/download/ffprobe-prebuilt-v1.0/ffprobe_linux_x64.zip

# 2. Extract
unzip ffprobe_linux_x64.zip

# 3. Install
sudo cp ffprobe /usr/local/bin/ffprobe
sudo chmod +x /usr/local/bin/ffprobe

# 4. Verify
ffprobe -version
```

---

## Project Info

**Repository:** [https://github.com/aydomini/fantastic-probe](https://github.com/aydomini/fantastic-probe)

**License:** MIT

**Author:** aydomini

**Documentation:** [CHANGELOG.md](CHANGELOG.md)
