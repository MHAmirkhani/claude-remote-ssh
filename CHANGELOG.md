# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-09-24

### Added
- Automated server installer (`server/setup-server.sh`) with dependency validation.
- Watchdog daemon (`server/pinggy-auto.sh`) with URL extraction and automatic Gist syncing.
- Systemd isolation using `EnvironmentFile` with mode `0600` permissions.
- Non-destructive SSH config management in PowerShell and Bash clients.
- Automated cache-busting on raw Gist endpoints to eliminate stale DNS propagation delays.
- Full Claude Desktop MCP integration via `@aiondadotcom/mcp-ssh`.
- Cross-platform client support (Windows PowerShell + Unix/macOS Bash).
- GitHub Actions CI workflow covering ShellCheck, JSON validation, and PSScriptAnalyzer.
- Complete 6-part documentation suite.