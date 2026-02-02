# Fantastic-Probe

Automatic media information extraction service for Emby STRM files, optimized for Blu-ray ISO/BDMV media with advanced HDR and Dolby Vision detection.

## Features

- **Blu-ray Support**: Direct ISO/BDMV processing without mounting (via ffprobe-libbluray)
- **Dolby Vision Detection**: Accurate Profile 7 (dual-layer BDMV) recognition
- **Smart Metadata Extraction**: Duration, chapters, audio/subtitle languages via bd_list_titles
- **Emby Integration**: Auto-refresh media library after processing
- **Cron Scanner**: Periodic scanning mode (replaces inotifywait for network mounts)
- **Failure Retry**: SQLite-based retry mechanism with configurable limits
- **Cloud-Friendly**: Optimized for rclone mounts (115 Cloud, etc.)

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

**Optional**:

- `curl` or `wget` - Emby API integration

Install on Debian/Ubuntu:

```bash
sudo apt-get update
sudo apt-get install python3 jq sqlite3 libbluray-bin ffmpeg curl
```

## Configuration

Run the interactive configuration tool:

```bash
sudo fp-config
```

Key settings:

- **STRM Root Directory**: Path to your STRM files
- **Emby Integration**: API URL and key for auto-refresh
- **Cron Scanner**: Batch size and retry limits
- **Logging**: Log file paths and rotation

Configuration file: `/etc/fantastic-probe/config`

## Usage

### Automatic Processing (Cron Mode)

After installation, the cron scanner runs automatically every minute:

```bash
# Check status
sudo systemctl status cron

# View logs
sudo tail -f /var/log/fantastic_probe.log
```

### Manual Processing

Process a single ISO file:

```bash
sudo bash fantastic-probe-process-lib.sh /path/to/movie.iso
```

## How It Works

1. **Scanner** discovers unprocessed `.iso` files in STRM root
2. **Detector** identifies ISO type (Blu-ray/DVD)
3. **Extractor** runs ffprobe and bd_list_titles to gather metadata
4. **Converter** transforms to Emby MediaSourceInfo format
5. **Writer** outputs `mediainfo.json` next to the ISO file
6. **Notifier** triggers Emby library refresh (if configured)

## Advanced Features

### Dolby Vision Profile 7 Detection

Automatically detects BDMV dual-layer Dolby Vision:

- Identifies 2+ HDR video streams with HDMV codec tags
- Correctly displays "Dolby Vision" instead of "HDR10" in Emby

### Smart Retry Mechanism

Failed files are cached in SQLite with:

- Retry count tracking
- Configurable max retries (default: 3)
- Automatic cleanup of expired entries

### FUSE Mount Optimization

Detects rclone/FUSE mounts and adjusts:

- Longer retry intervals (60/30/15s vs 30/20/10s)
- Prevents cloud storage rate limiting

## Troubleshooting

### Check dependencies

```bash
sudo fp-config  # Option: Check dependencies
```

### View error logs

```bash
sudo tail -f /var/log/fantastic_probe_errors.log
```

### Clear failure cache

```bash
sudo rm /var/lib/fantastic-probe/failure_cache.db
```

### Cleanup stale mounts

```bash
sudo umount /tmp/iso_mount_*
```

## Uninstall

```bash
sudo bash fantastic-probe-uninstall.sh
```

Removes:

- All scripts from `/usr/local/bin/`
- Configuration from `/etc/fantastic-probe/`
- Cron job
- Logs (optional)

## License

MIT

## Credits

- **ffprobe-libbluray**: Blu-ray ISO parsing
- **bd_list_titles**: Main title and language tag extraction
- **jq**: High-performance JSON processing
