# claude-remote-ssh

> Bridge **Claude Desktop** to firewalled, NAT-restricted Linux servers — zero public IP, no port forwarding, no VPS required.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI Validation](https://github.com/MHAmirkhani/claude-remote-ssh/actions/workflows/validate.yml/badge.svg)](https://github.com/MHAmirkhani/claude-remote-ssh/actions)
[![Claude MCP](https://img.shields.io/badge/MCP-Compatible-purple.svg)](https://modelcontextprotocol.io/)
[![Shellcheck](https://img.shields.io/badge/shellcheck-clean-green.svg)](https://www.shellcheck.net/)
[![M8ven Score](https://m8ven.ai/badge/mcp/mhamirkhani-claude-remote-ssh-1xg7bg)](https://m8ven.ai/mcp/mhamirkhani-claude-remote-ssh-1xg7bg)
[![M8ven Score](https://m8ven.ai/badge/mcp/mhamirkhani/claude-remote-ssh)](https://m8ven.ai/mcp/mhamirkhani/claude-remote-ssh)

---

## Overview

Many researchers, students, and engineers work on Linux servers that are locked inside heavily filtered networks:

- **No public IP** (strictly behind CGNAT)
- **UDP blocked** (breaks WireGuard, Tailscale, ZeroTier)
- **Inbound ports blocked** on all protocols
- **DNS poisoning** and **TLS SNI filtering** by DPI middleboxes
- Only reliable egress: **outbound TCP over port 443**

Direct SSH is impossible. VPN meshes fail. Cloudflare WARP and Argo are IP-banned. ngrok endpoints are flaky.

**claude-remote-ssh** chains four independent, TCP-only components into a resilient pipeline that Claude Desktop can drive directly, as if the remote server were local:

1. **Xray** — outbound TCP proxy through a paid VLESS/Trojan provider
2. **Pinggy** — reverse TCP tunnel over port 443 (bypasses DPI)
3. **GitHub Gist** — durable mailbox for the ephemeral tunnel URL
4. **MCP (Model Context Protocol)** — Claude Desktop's native tool-calling interface

---

## Architecture

```
┌───────────────────────────┐         TCP/443        ┌────────────────────────────┐
│  Restricted Linux VM      │ ─────────────────────▶ │  Remote Proxy (VLESS)      │
│  Ubuntu · Behind NAT      │                        │  Paid provider · Foreign   │
└─────────────┬─────────────┘                        └────────────────────────────┘
              │
              │ 1. Open reverse TCP tunnel via Pinggy (through Xray SOCKS5)
              ▼
┌───────────────────────────┐
│  Pinggy Edge Server       │   Generates public endpoint:
│  TLS on port 443          │   tcp://xyz.pinggy-free.link:PORT
└─────────────┬─────────────┘
              │
              │ 2. VM pushes URL via GitHub REST API
              ▼
┌───────────────────────────┐
│  GitHub Secret Gist       │   Mailbox file: topo_tunnel.txt
│  (URL relay, no secrets)  │
└─────────────┬─────────────┘
              │
              │ 3. Client polls Gist every 5 min (cache-busted)
              ▼
┌───────────────────────────┐
│  Desktop Workstation      │
│  ─ update-tunnel.ps1/.sh  │   Non-destructive ~/.ssh/config update
│  ─ Task Scheduler / cron  │   Runs every 5 minutes
│  ─ Claude Desktop + MCP   │   Uses SSH alias "topo-server"
└─────────────┬─────────────┘
              │
              │ 4. End-to-end encrypted SSH session
              ▼
┌───────────────────────────┐
│  VM OpenSSH Daemon (22)   │
└───────────────────────────┘
```

---

## Comparison

| Solution | UDP Blocked? | CGNAT / No Public IP? | Requires VPS? | Survives CDN Cache? |
|---|:---:|:---:|:---:|:---:|
| Direct SSH | ❌ N/A | ❌ Fails | N/A | N/A |
| Tailscale / WireGuard | ❌ Fails | ❌ Needs DERP | ⚠️ Sometimes | N/A |
| Cloudflare Argo Tunnel | ⚠️ Regional bans | ✅ Yes | ❌ No | N/A |
| ngrok | ⚠️ Unreliable | ✅ Yes | ❌ No | N/A |
| **claude-remote-ssh** | **✅ TCP-only** | **✅ Works** | **✅ No VPS** | **✅ Cache-busted** |

---

## Key Features

- ✅ **Strict TCP/443 egress** — works when UDP is fully blocked
- ✅ **Autonomous watchdog** — health check loop detects dead tunnels in `< 30s` and self-heals
- ✅ **Tunnel rotation** — automatically refreshes the 60-minute Pinggy free-tier limit
- ✅ **DNS health check** — catches zombie processes that report as `alive` but route nowhere
- ✅ **Non-destructive SSH config** — edits only the target `Host` block, preserves everything else
- ✅ **Safe MCP integration** — merges `@aiondadotcom/mcp-ssh` without clobbering existing MCP servers
- ✅ **Cross-platform clients** — Windows (PowerShell + Task Scheduler) and Unix/macOS (Bash + cron)
- ✅ **Zero VPS** — free tier works end-to-end

---

## Quick Start

### 1. Prerequisites

| Requirement | Notes |
|---|---|
| Linux server (Ubuntu 20.04 / 22.04 / 24.04) | With `sudo` access, behind NAT |
| VLESS / Trojan subscription | Paid provider with TCP+HTTP config |
| GitHub account | Secret Gist + Personal Access Token (`gist` scope) |
| Desktop | Windows 10/11 **or** macOS / Linux |
| Node.js 20+ | On the desktop ([nodejs.org](https://nodejs.org)) |
| Claude Desktop | [claude.ai/download](https://claude.ai/download) |

See [docs/01-prerequisites.md](docs/01-prerequisites.md) for step-by-step account setup.

### 2. Server Installation

```bash
git clone https://github.com/MHAmirkhani/claude-remote-ssh.git
cd claude-remote-ssh/server
sudo bash setup-server.sh
```

The script prompts for:
- GitHub Token (`gist` scope)
- Gist ID
- Gist filename (default: `topo_tunnel.txt`)

Then installs Xray, deploys the watchdog, and starts `pinggy-tunnel.service`.

### 3. Client Setup

**Windows (PowerShell):**
```powershell
cd desktop-windows
powershell -ExecutionPolicy Bypass -File .\setup-desktop.ps1
```

**macOS / Linux (Bash):**
```bash
cd client-unix
chmod +x update-tunnel.sh
./update-tunnel.sh "https://gist.githubusercontent.com/USER/ID/raw/topo_tunnel.txt" user topo-server
```

### 4. Claude Desktop

1. **Fully quit** Claude Desktop (system tray → Quit, not just close).
2. Relaunch Claude Desktop.
3. In a new conversation, prompt:

> SSH into `topo-server` and show system status: `hostname; uptime; whoami`

Claude will call the `mcp-ssh` tool, which reads `~/.ssh/config`, which points at the current Pinggy tunnel.

---

## How It Works

Each component exists to solve a specific failure mode:

| Layer | Problem solved |
|---|---|
| **Xray** | University network blocks outbound UDP and DNS-poison most domains. Xray tunnels traffic inside a legitimate-looking HTTP request over TCP/443. |
| **Pinggy** | Server has no public IP. Pinggy provides a reverse TCP tunnel endpoint without requiring port forwarding. |
| **GitHub Gist** | Pinggy's free tier rotates the endpoint every 60 minutes. The Gist acts as a durable mailbox the desktop can poll. |
| **Watchdog** | Naive `sleep 3500` loops miss dead tunnels. The watchdog performs DNS health checks every 90 seconds to detect stale endpoints. |
| **Task Scheduler / cron** | The client polls the Gist every 5 minutes with a `?cb=<timestamp>` cache-buster to bypass the raw CDN's edge caching. |
| **MCP** | Claude Desktop's `mcp-ssh` server inherits the system `~/.ssh/config`, so keeping it fresh is enough — no Claude-specific config changes needed. |

See [docs/06-architecture.md](docs/06-architecture.md) for a deep dive.

---

## Operations

Once installed, the system is fully autonomous. Useful commands:

**On the server:**
```bash
check-tunnel                                # Full chain health check
sudo update-xray.sh "vless://..."           # Rotate Xray config from a new URL
sudo systemctl restart pinggy-tunnel        # Force tunnel refresh
sudo journalctl -u pinggy-tunnel -f         # Live tunnel logs
```

**On the client:**
```powershell
# Windows — manual sync
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude-remote-ssh\update-tunnel.ps1"

# Check Task Scheduler status
Get-ScheduledTaskInfo -TaskName "UpdateTunnel_topo-server"
```

```bash
# Unix — manual sync
~/.claude-remote-ssh/update-tunnel.sh "https://gist.githubusercontent.com/..." user topo-server
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Could not resolve hostname topo-server` | Stale `~/.ssh/config` | Run `update-tunnel` manually |
| `Connection timed out` | Tunnel dead on Pinggy side | `sudo systemctl restart pinggy-tunnel` on server |
| `Permission denied (publickey)` | SSH key not on server | Re-add `~/.ssh/id_ed25519.pub` to `authorized_keys` |
| `Temporary failure in name resolution` | Gist URL stale | Wait for watchdog rotation (max 60s) |
| MCP server missing in Claude | Config path or `npx.cmd` issue | See [docs/04-claude-mcp.md](docs/04-claude-mcp.md) |

Full guide: [docs/05-troubleshooting.md](docs/05-troubleshooting.md)

---

## Uninstall

**Server:**
```bash
sudo systemctl disable --now pinggy-tunnel xray
sudo rm -f /usr/local/bin/{pinggy-auto.sh,update-xray.sh,check-tunnel.sh}
sudo rm -rf /etc/claude-remote-ssh /usr/local/etc/xray
sudo rm -f /etc/systemd/system/{pinggy-tunnel,xray}.service
sudo systemctl daemon-reload
```

**Desktop (Windows):**
```powershell
Unregister-ScheduledTask -TaskName "UpdateTunnel_topo-server" -Confirm:$false
Remove-Item -Recurse -Force "$env:USERPROFILE\.claude-remote-ssh"
# Then manually remove the `Host topo-server` block from ~/.ssh/config
```

**Desktop (Unix):**
```bash
# Remove cron entry
crontab -l | grep -v 'update-tunnel.sh' | crontab -
rm -rf ~/.claude-remote-ssh
# Then manually remove the `Host topo-server` block from ~/.ssh/config
```

---

## Documentation

| Document | Description |
|---|---|
| [01 · Prerequisites](docs/01-prerequisites.md) | Accounts, tokens, and initial requirements |
| [02 · Server Setup](docs/02-server-setup.md) | Installing Xray, Pinggy, and the watchdog |
| [03 · Desktop Setup](docs/03-desktop-setup.md) | Windows and Unix client installation |
| [04 · Claude MCP](docs/04-claude-mcp.md) | Configuring Claude Desktop's MCP integration |
| [05 · Troubleshooting](docs/05-troubleshooting.md) | Common errors and their fixes |
| [06 · Architecture](docs/06-architecture.md) | Design rationale and failure analysis |

---

## Security & Ethics

- **Tokens are never committed.** `setup-server.sh` writes them to `/etc/claude-remote-ssh/tunnel.env` with `chmod 600`.
- **Gists hold no secrets.** Only the ephemeral tunnel URL is published. It's useless without a matching SSH key.
- **SSH auth uses Ed25519 keys.** Password auth can be disabled entirely on the server.
- **`StrictHostKeyChecking` is preserved.** The client script uses `accept-new` because Pinggy rotates edge hosts, but you can override it in `~/.ssh/config`.
- **Intended use:** accessing your *own* servers. Do not use this to bypass authorization on systems you don't own.

Review [SECURITY.md](SECURITY.md) for the vulnerability reporting procedure.

---

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

Areas where help is appreciated:
- Additional Unix package managers (Fedora, Arch, Alpine)
- Support for alternative tunnel services (localhost.run, serveo)
- Full macOS `launchd` templates
- Translations of `docs/`

---

## Acknowledgments

Built on the shoulders of:
- [XTLS/Xray-core](https://github.com/XTLS/Xray-core) — the proxy engine
- [Pinggy](https://pinggy.io) — reverse tunnel service
- [@aiondadotcom/mcp-ssh](https://github.com/aiondadotcom/mcp-ssh) — MCP SSH server
- [Anthropic](https://anthropic.com) — Claude Desktop and the Model Context Protocol

---

## License

Distributed under the [MIT License](LICENSE). Use freely, modify, share.

---

## Author

**Mohammad H. Amirkhani**

- GitHub: [@MHAmirkhani](https://github.com/MHAmirkhani)
- Website: [amirkhani.me](https://amirkhani.me)
- Telegram: [@IUseGentoo_BTW](https://t.me/IUseGentoo_BTW)
- Email: Amirkhani.MohammadH@gmail.com
