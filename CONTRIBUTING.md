# Contributing to claude-remote-ssh

We welcome community contributions to improve resilience in restricted network environments.

## Development Guidelines

1. **Branching**:
   - Create focused feature branches from `main` (e.g., `feature/systemd-hardening` or `fix/gist-timeout`).
2. **Quality & Formatting**:
   - Shell scripts must pass `shellcheck` with zero warnings.
   - PowerShell scripts must pass `PSScriptAnalyzer`.
   - Maintain UTF-8 encoding with UNIX line endings (`LF`) for shell scripts.
3. **Secret Hygiene**:
   - Never commit tokens, proxy endpoints, or private keys. The CI suite automatically fails on leaked credentials.
4. **Pull Requests**:
   - Describe the test environment (e.g., Ubuntu version, network constraints).
   - Ensure documentation updates accompany structural changes.