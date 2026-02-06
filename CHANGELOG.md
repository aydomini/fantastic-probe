# Changelog

All notable changes to Fantastic-Probe are documented here.

---

## [1.2.2] - 2026-02-06

### New Features

- Automatic upload to cloud storage with configurable file types
- Directory-grouped upload with batch interval optimization
- Show-level file support for TV series metadata
- Real-time console feedback and progress display
- SQLite database for persistent upload status
- Config panel for upload management

---

## [1.2.1] - 2026-02-02

### Initial Release

- **Blu-ray ISO support**: Direct processing via ffprobe-libbluray
- **Dolby Vision detection**: Accurate Profile 7 recognition for BDMV dual-layer
- **Smart metadata extraction**: Duration, chapters, audio/subtitle languages via bd_list_titles
- **Emby integration**: Auto-refresh after processing
- **Cron scanner**: Periodic scanning mode for network mounts
- **Failure retry**: SQLite-based retry with configurable limits
- **Cloud-friendly**: Optimized for rclone mounts (115 Cloud, etc.)

### Technical Features

- ffprobe + libbluray for Blu-ray structure parsing
- bd_list_titles for main title and language tag extraction
- jq for efficient JSON processing
- FUSE mount detection with adaptive retry intervals
- Automatic mount point cleanup and error recovery

---

