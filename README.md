# Fantastic-Probe

Automatic media info extraction and metadata scraping service for STRM files.

## Features

- **Two-Stage Processing Architecture**
  - Stage 1: Metadata scraping (TMDB → NFO + posters + backdrops + actor thumbnails)
  - Stage 2: Media info extraction (FFprobe → append `<fileinfo>` to NFO)
  - Execution order: Stage 1 → Stage 2 (perfectly aligned!)

- **Universal STRM Support**
  - ISO.STRM: Extract media info from ISO files via FFprobe bluray:/dvd: protocol
  - Regular STRM: Support HTTP links, Alist integration, and local video files

- **Smart Scanning**
  - Cron-based scanner: Auto-scan every minute
  - Intelligent retry mechanism: Max 3 attempts with failure cache
  - Configurable task interval: Prevent cloud storage throttling

- **Rich Metadata**
  - Auto-generate Kodi/Emby compatible NFO files
  - Download posters, backdrops, and actor thumbnails
  - Extract video streams, audio tracks, and subtitles with language info

- **Easy Configuration**
  - Interactive configuration panel: `sudo fp-config`
  - One-click enable/disable stages
  - TMDB proxy support (HTTP/HTTPS/SOCKS5)

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
2. Install dependencies (sqlite3, jq, curl, etc.)
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
- Optionally remove config files, logs, and cache database

---

## Quick Start

After installation, use the configuration tool:

```bash
sudo fp-config
```

Basic commands:

```bash
sudo fp-config show          # View current configuration
sudo fp-config logs          # View live logs
sudo fp-config check-update  # Check for updates
```

---

## Project Info

**Repository:** [https://github.com/aydomini/fantastic-probe](https://github.com/aydomini/fantastic-probe)

**License:** MIT

**Author:** aydomini

**Documentation:** [CHANGELOG.md](CHANGELOG.md)
