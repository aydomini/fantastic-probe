# Fantastic-Probe

Automatic media information extraction service for Emby STRM files, optimized for Blu-ray ISO/BDMV media with advanced HDR and Dolby Vision detection.

## Installation

### Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/aydomini/fantastic-probe/master/install.sh | sudo bash
```

Or using wget:

```bash
wget -qO- https://raw.githubusercontent.com/aydomini/fantastic-probe/master/install.sh | sudo bash
```

### Manual Install

```bash
git clone -b master https://github.com/aydomini/fantastic-probe.git
cd fantastic-probe
sudo bash fantastic-probe-install.sh
```

## Dependencies

**Required**:

- `python3` - bd_list_titles output parsing
- `jq` - JSON processing
- `sqlite3` - Failure cache database
- `bd_list_titles` (libbluray-bin) - Blu-ray language tag extraction
- `ffprobe` (ffmpeg) - Media information extraction

## Uninstall

```bash
sudo bash fantastic-probe-uninstall.sh
```

Removes:

- All scripts from `/usr/local/bin/`
- Configuration from `/etc/fantastic-probe/`
- Cron job
- Logs (optional)
