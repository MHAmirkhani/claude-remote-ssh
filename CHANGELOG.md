# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Planned
- Self-hosted FRP backend as an alternative to Pinggy
- Multi-server support (one desktop, multiple VMs)
- Encrypted Gist payloads via `age`
- Native macOS menu bar client
- Docker Compose deployment option
- Windows service mode as an alternative to Task Scheduler

---

## [1.0.0] — 2026-09-24

First stable release. The pipeline has been validated end-to-end on Ubuntu 22.04 behind a restrictive NAT, with Claude Desktop on Windows 11.

### Added — Server

- **Automated installer** (`server/setup-server.sh`):
  - Downloads and installs Xray-core `v25.9.11` with checksum validation.
  - Generates a template Xray config on first install.
  - Creates and enables `xray.service` and `pinggy-tunnel.service`.
  - Sets up `/etc/claude-remote-ssh/tunnel.env` with `chmod 600`.
  - Installs `update-xray.sh` and `check-tunnel.sh` helpers.
  - Creates a shell alias for `check-tunnel` in `/etc/profile.d/`.
  - Generates an Ed25519 keypair for the target user if missing.
- **Watchdog daemon** (`server/pinggy-auto.sh`):
  - Process liveness check every 30 seconds.
  - **DNS health check** every 90 seconds to detect zombie tunnels.
  - **58-minute rotation** to pre-empt Pinggy's free-tier expiry.
  - Graceful shutdown via `trap` on `SIGTERM`/`SIGINT`/`SIGHUP`.
  - Atomic URL publication to GitHub Gist via `jq` and `curl --retry`.
- **Xray config generator** (`server/update-xray.sh`):
  - Parses `vless://` URLs including query parameters.
  - Supports `tcp` (with HTTP header), `ws`, and `grpc` transports.
  - Backs up previous configs to `/usr/local/etc/xray/backups/`.
  - Validates the config with `xray -test` before restarting.
  - Tests the SOCKS proxy after restart and reports the public IP.
- **Health checker** (`server/check-tunnel.sh`):
  - Six independent checks: Xray service, SOCKS proxy, Pinggy service, tunnel process, DNS resolution, Gist sync.
  - Color-coded output with `[OK]` / `[FAIL]` / `[WARN]` markers.
  - Summary with actionable troubleshooting hints.
- **Systemd isolation** using `EnvironmentFile` with `chmod 600` permissions.

### Added — Desktop (Windows)

- **Installer** (`desktop-windows/setup-desktop.ps1`):
  - Compatible with Windows PowerShell 5.1+ **and** PowerShell 7+.
  - Prompts for Gist URL, SSH user, and host alias.
  - Installs the sync script to `%USERPROFILE%\.claude-remote-ssh\`.
  - Registers a Scheduled Task that runs every 5 minutes.
  - Merges `mcp-ssh` into Claude Desktop's config **without overwriting existing MCP servers**.
  - Writes to **both** possible Claude config paths (direct install + MSIX).
- **Sync script** (`desktop-windows/update-tunnel.ps1`):
  - **Non-destructive** SSH config editing (regex-based `Host` block replacement).
  - **Cache-busting** via `?cb=<unix_timestamp>` and `Cache-Control: no-cache`.
  - Idempotent: skips work if the config is already current.
  - Handles commit-hash-suffixed raw URLs gracefully.

### Added — Desktop (macOS / Linux)

- **Sync script** (`client-unix/update-tunnel.sh`):
  - Robust Bash implementation with `set -uo pipefail`.
  - Prefers `python3` for parsing; falls back to `awk` if unavailable.
  - Validates the tunnel URL format and port range before editing.
  - Uses an atomic `mktemp` + `mv` pattern to avoid corruption.
  - Compatible with `cron` (Linux) and `launchd` (macOS).

### Added — Documentation

- Complete 6-part documentation suite:
  - `docs/01-prerequisites.md` — accounts, tokens, verification checklist.
  - `docs/02-server-setup.md` — server installation and operations.
  - `docs/03-desktop-setup.md` — Windows and Unix client setup.
  - `docs/04-claude-mcp.md` — MCP configuration reference.
  - `docs/05-troubleshooting.md` — diagnostic workflow and fixes.
  - `docs/06-architecture.md` — design rationale and tradeoffs.

### Added — CI/CD

- GitHub Actions workflow with:
  - `shellcheck` on all shell scripts.
  - JSON validation for `xray-config.json` and `claude_desktop_config.json`.
  - `PSScriptAnalyzer` on PowerShell scripts (Windows runner).
  - Secret scanning (fails on `ghp_*` patterns in tracked files).

### Fixed

- **Zombie tunnel detection**: Previous watchdog versions only checked `kill -0`, which returns success even when the tunnel is dead. Added DNS resolution check.
- **PowerShell 5.1 compatibility**: Removed `-AsHashtable` (PS 6+ only) from `setup-desktop.ps1` and replaced with `[PSCustomObject]` manipulation.
- **CDN cache staleness**: Added `?cb=` query parameter because `raw.githubusercontent.com` caches aggressively.
- **MITM host key rotation**: Set `StrictHostKeyChecking accept-new` to handle Pinggy's rotating edge hosts without user intervention.

### Security

- GitHub tokens are never echoed to stdout or written to logs.
- All credential files use `chmod 600`.
- Xray listens only on `127.0.0.1:10809` — not exposed on the network.
- CI fails on any committed `ghp_*` pattern.

---

## Format Reference

### Categories

- **Added** — new features
- **Changed** — changes to existing functionality
- **Deprecated** — soon-to-be-removed features
- **Removed** — features removed in this release
- **Fixed** — bug fixes
- **Security** — security-relevant changes

### Versioning

- **MAJOR** — incompatible changes to the install interface or config format
- **MINOR** — backward-compatible feature additions
- **PATCH** — backward-compatible bug fixes

---

## Links

- [Keep a Changelog](https://keepachangelog.com/)
- [Semantic Versioning](https://semver.org/)
- [Repository](https://github.com/MHAmirkhani/claude-remote-ssh)
- [Issues](https://github.com/MHAmirkhani/claude-remote-ssh/issues)
- [Releases](https://github.com/MHAmirkhani/claude-remote-ssh/releases)

[Unreleased]: https://github.com/MHAmirkhani/claude-remote-ssh/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/MHAmirkhani/claude-remote-ssh/releases/tag/v1.0.0
