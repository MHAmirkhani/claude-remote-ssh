# claude-remote-ssh

> Bridge **Claude Desktop** to firewalled, NAT-restricted Linux servers â€” zero public IP, no port forwarding, and no dedicated VPS required.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI Validation](https://github.com/MHAmirkhani/claude-remote-ssh/actions/workflows/validate.yml/badge.svg)](https://github.com/MHAmirkhani/claude-remote-ssh/actions)
[![Claude MCP](https://img.shields.io/badge/MCP-Compatible-purple.svg)](https://modelcontextprotocol.io/)

---

## Overview

In heavily filtered network environments (such as university labs or restricted regional zones), servers often:
- Lack public IP addresses (strictly behind CGNAT)
- Suffer UDP blocking (breaking WireGuard, Tailscale, and ZeroTier)
- Block direct inbound connections on all ports
- Can only reliably establish outbound TCP traffic over port 443

**claude-remote-ssh** combines **Xray** (outbound TCP proxy), **Pinggy** (reverse TCP tunnel), **GitHub Gist** (secure mailbox relay), and **Model Context Protocol (MCP)** to establish a resilient, self-healing reverse SSH pipeline that Claude Desktop uses directly.

---

## Architecture

```
+--------------------------+                 +----------------------------+
|  Restricted Linux VM     |   TCP / 443     |  Remote Proxy Server       |
|  (Ubuntu Behind NAT)     | --------------> |  (VLESS / Trojan Provider) |
+------------+-------------+                 +----------------------------+
             |
             | 1. Opens reverse TCP tunnel via Pinggy
             |    (routed through local Xray SOCKS5 proxy on 127.0.0.1:10809)
             v
+--------------------------+
|  Pinggy Edge Server      |  Generates public endpoint:
|  (Over TLS / Port 443)   |  tcp://xyz.pinggy-free.link:PORT
+------------+-------------+
             |
             | 2. VM pushes ephemeral URL via GitHub REST API
             v
+--------------------------+
|  GitHub Secret Gist      |  Mailbox: topo_tunnel.txt
|  (Encrypted Relay)       |
+------------+-------------+
             |
             | 3. Client polls Gist with cache-busting headers
             v
+--------------------------+
|  Desktop Workstation     |
|  - update-tunnel.ps1     | Updates ~/.ssh/config non-destructively
|  - Windows Task / Cron   | Synchronizes every 5 minutes
|  - Claude Desktop (MCP)  | Executes tools through alias "topo-server"
+------------+-------------+
             |
             | 4. End-to-End Encrypted SSH Session
             v
+--------------------------+
|  VM OpenSSH Daemon (22)  |
+--------------------------+
```

---

## Comparison

| Solution | UDP Blocked? | CGNAT / No Public IP? | Requires VPS? | Survives CDN Cache? |
|---|:---:|:---:|:---:|:---:|
| Direct SSH | âŒ Fails | âŒ Fails | N/A | N/A |
| Tailscale / WireGuard | âŒ Fails | âŒ Blocked | âŒ Needs DERP | N/A |
| Cloudflare Argo Tunnel | âš ï¸ Regional Bans | âœ… Yes | âŒ No | N/A |
| **claude-remote-ssh** | **âœ… Works (TCP only)** | **âœ… Works** | **âœ… No VPS needed** | **âœ… Yes (Cache-busted)** |

---

## Key Features

- **Strict TCP/443 Egress**: Operates entirely over standard outbound HTTPS ports.
- **Autonomous Watchdog**: Health check loop monitors connection state and self-heals in `< 30s`.
- **Tunnel Lifecycle Management**: Handles Pinggy free tier 60-minute rotations smoothly.
- **Non-Destructive SSH Management**: Updates only designated Host blocks in `~/.ssh/config`.
- **Safe MCP Integration**: Injects `@aiondadotcom/mcp-ssh` without clobbering existing desktop MCP setups.
- **Cross-Platform Client**: Full support for Windows (PowerShell/Task Scheduler) and Unix/macOS (Bash/Cron).

---

## Quick Start

### 1. Prerequisites
Ensure you have:
- Target Linux Server (Ubuntu 20.04+) with `sudo` rights.
- Active VLESS / Trojan proxy configuration.
- GitHub account with a **Secret Gist** and **Personal Access Token (classic)** with `gist` scope.
- Windows or macOS/Linux client with Claude Desktop and Node.js 20+.

### 2. Server Installation
```bash
git clone https://github.com/MHAmirkhani/claude-remote-ssh.git
cd claude-remote-ssh/server
sudo bash setup-server.sh
```

### 3. Client Setup (Windows)
Open PowerShell and run:
```powershell
cd desktop-windows
powershell -ExecutionPolicy Bypass -File .\setup-desktop.ps1
```

### 4. Claude Desktop Configuration
1. Fully exit Claude Desktop from the system tray.
2. Relaunch Claude Desktop.
3. In conversation, prompt:
   > "SSH into topo-server and show system status: `hostname; uptime; whoami`"

---

## Documentation

- [01 - Prerequisites](docs/01-prerequisites.md)
- [02 - Server Setup](docs/02-server-setup.md)
- [03 - Desktop Setup](docs/03-desktop-setup.md)
- [04 - Claude MCP Configuration](docs/04-claude-mcp.md)
- [05 - Troubleshooting Guide](docs/05-troubleshooting.md)
- [06 - Deep Architecture](docs/06-architecture.md)

---

## Security & Ethics

- GitHub tokens are stored in strict `600` access credential files, never in public repositories.
- Tunnel URLs only forward traffic to the VM's local SSH daemon; authentication remains protected by standard SSH asymmetric keys (`ed25519`).
- Review [SECURITY.md](SECURITY.md) for full vulnerability reporting procedures.

---

## License

Distributed under the [MIT License](LICENSE).
---

## Author

**Mohammad H. Amirkhani**

- **GitHub**: [@MHAmirkhani](https://github.com/MHAmirkhani)
- **Affiliation**: Iran University of Science and Technology (IUST)
- **Website**: [Amirkhani.me](https://Amirkhani.me)
- **Telegram**: [@IUseGentoo_BTW](https://t.me/IUseGentoo_BTW)
- **Email**: Amirkhani.MohammadH@gmail.com
