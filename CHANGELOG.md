# Changelog

All notable changes to ClaudeBox will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- **VPN Gateway** (`vpn-gw` command): Shared AmneziaWG container that all ClaudeBox slots
  route through, so multiple parallel sessions share one VPN connection.
  - `claudebox vpn-gw start|stop|status`
  - Dedicated `claudebox-vpn` Docker bridge network (172.20.0.0/16)
  - Startup hook automatically replaces default route in each client container
  - DNS fixed via direct resolv.conf rewrite when gateway is active
- **VPN Routing** (`vpn-routing` command): Route corporate VPN CIDRs through the host
  into containers (or through the VPN gateway for bypass rules).
  - `claudebox vpn-routing enable|disable|add|remove|list`
  - Stored per-project in `profiles.ini [vpn-routing]`
- **Mount command** (`mount`): Bind-mount extra host directories into the container workspace.
  - `claudebox mount add|remove|list`
  - Stored per-project in `profiles.ini [mounts]`
  - Mounts applied automatically at container launch
- **Proxy command** (`proxy`): Forward HTTP/HTTPS proxy env vars into containers.
  - `claudebox proxy add|remove|list|show`
  - Scripts live in `~/.config/proxy/*.sh`; sourced at launch, forwarded via `-e` flags
- **AmneziaWG profile**: Install AmneziaWG kernel module and tools for in-container or
  gateway VPN tunnels.
- **AOSP/ADB profile**: Route ADB through the host's `adb` server so USB-attached devices
  are visible inside the container (`ANDROID_ADB_SERVER_ADDRESS=host.docker.internal`).
- **`kill` command**: Stop running ClaudeBox containers.
- **`project` command**: Open a project by name or hash from any directory.
- **`iproute2`** installed in the base image so `ip route` is always available.
- VPN gateway documentation at `docs/vpn-gateway.md`.

### Fixed
- `host.docker.internal` resolves to the wrong bridge IP on the `claudebox-vpn` network;
  now uses `VPN_GW_SUBNET_GW` directly when the VPN gateway is active (affects ADB).
- `vpn-routing`, `vpn-gw`, `mount`, `proxy` no longer require a slot or Docker image
  (`get_command_requirements` returns `"none"`).

## [2.0.0] - 2025-07-25

### Added
- **macOS Support**: Full macOS compatibility
  - Docker Desktop detection (no systemctl on macOS)
  - Fixed UID/GID mismatches (macOS uses 501:20 vs Linux 1000:1000)
  - Python PATH configuration for uv-managed installations
- **Build System Overhaul**: New versioned release system
  - Version tracking with `CLAUDEBOX_VERSION` constant
  - Builds output to `dist/` directory
  - Creates versioned archives (e.g., `claudebox-2.0.0.tar.gz`)
  - Self-extracting installer (`claudebox.run`)
- **PATH Setup**: Automatic PATH configuration detection
  - Shows setup instructions when `~/.local/bin` not in PATH
  - Works with both bash and zsh

### Changed
- **Docker BuildKit**: Removed cache mounts to fix macOS permission issues
- **Python Management**: Updated to use uv with `--python-preference managed`
- **Installation**: Improved first-time setup experience

### Fixed
- **macOS Docker**: Fixed "systemctl: command not found" error
- **Build Permissions**: Resolved npm cache permission errors on macOS
- **Python Availability**: Fixed Python not in PATH in tmux sessions
- **CLI Architecture**: Complete refactor of CLI parsing system
  - Fixed `--verbose` flag changing program behavior
  - Fixed `rebuild` command not continuing to requested action
  - Fixed inconsistent flag parsing across multiple locations
  - Implemented clean four-bucket architecture (host-only, control, script, pass-through)
  - All parsing now happens in single location (`lib/cli.sh`)
  - Predictable, maintainable flag handling
- **Docker Entrypoint**: Simplified to only handle control flags
  - Removed complex argument parsing
  - Control flags (`--enable-sudo`, `--disable-firewall`) extracted cleanly
  - Everything else passes through to Claude CLI

### Documentation
- Added `docs/cli-implementation.md` - Complete CLI architecture reference
- Added `docs/slot-management-system.md` - Comprehensive slot system documentation
- Updated `docs/checksum-and-naming-system.md` - Fixed slot checksum explanation
- Documented approved core image architecture for future implementation

## [1.0.0] - Previous Releases
## [2025-06-25]

### Fixed
- Fixed profile selection logic to handle empty profile values correctly (#24)

## [2025-06-22]

### Added
- Cross-platform host detection for Linux and macOS (#22)
- Filesystem case-sensitivity detection for macOS (HFS+/APFS)
- Docker BuildKit normalization for case-insensitive filesystems

### Changed
- Improved host OS detection with proper error handling
- Enhanced cross-platform script path resolution
- Pinned git-delta version to 0.17.0 for consistency

### Fixed
- Fixed grep -P flag compatibility issue on macOS (#21)
- Resolved issues with case-insensitive filesystem handling on macOS

## [2025-06-21]

### Changed
- Multiple README improvements and documentation updates
- Enhanced Docker build process and configuration

## [2025-06-20]

### Fixed
- Resolved initialization errors in the claudebox script
- Improved container performance and stability

### Removed
- Removed duplicate code blocks for cleaner codebase

## [2025-06-19]

### Added
- BuildX compatibility check for Docker builds
- Enhanced WSL (Windows Subsystem for Linux) support

### Changed
- Streamlined feature set and workflow improvements
- Improved error handling and user feedback

## Earlier Changes

### Initial Features
- Project-specific Docker containers for isolated development environments
- Profile system for language and tool installations
- Firewall configuration with allowlist support
- Persistent storage for project data
- Multi-project support with separate containers per project