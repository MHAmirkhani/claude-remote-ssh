# 01 - Prerequisites

Ensure all required infrastructure and accounts are ready before starting.

## 1. Remote Target Server
- **Operating System**: Ubuntu 20.04 LTS, 22.04 LTS, or 24.04 LTS.
- **Privileges**: Root access (`sudo`).
- **Network Profile**: Restrictive outbound NAT; inbound connections blocked; UDP dropped.

## 2. Proxy Service Subscription
A functional **VLESS** or **Trojan** proxy with TCP encapsulation (HTTP or TLS header) capable of routing traffic outside restrictive regional boundaries.
Obtain:
- Server Hostname / Address
- Port (typically 443)
- User UUID
- SNI Host (e.g., `www.microsoft.com` or custom CDN)

## 3. GitHub Account & Credentials
1. **Private Gist**:
   - Navigate to [gist.github.com](https://gist.github.com).
   - Filename: `topo_tunnel.txt`.
   - Initial Content: `initial`.
   - Select **Create secret gist**.
   - Note the alphanumeric ID from the browser address bar.
2. **Personal Access Token**:
   - Visit **GitHub Settings -> Developer Settings -> Personal access tokens (Tokens classic)**.
   - Name: `claude-remote-ssh-sync`.
   - Scopes: Check **only** `gist`.
   - Generate and securely store the token string.

## 4. Desktop Client
- **Windows 10 / 11** or **macOS / Linux**.
- **Node.js 20+**: Verify via `node --version` and `npx --version`.
- **Claude Desktop**: Installed with developer features enabled.