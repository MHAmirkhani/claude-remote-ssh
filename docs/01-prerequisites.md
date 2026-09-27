# 01 — Prerequisites

Before installing **claude-remote-ssh**, gather the following infrastructure, accounts, and credentials. This document walks you through every prerequisite step-by-step, with verification commands you can run at each stage.

---

## Table of Contents

1. [Target Linux Server](#1-target-linux-server)
2. [Proxy Subscription](#2-proxy-subscription)
3. [GitHub Account & Credentials](#3-github-account--credentials)
4. [Desktop Client](#4-desktop-client)
5. [Verification Checklist](#5-verification-checklist)

---

## 1. Target Linux Server

The server is the machine you want to reach from Claude Desktop. It must be reachable via SSH **from your desktop** at least once, before tunnel setup.

### Required

| Attribute | Value |
|---|---|
| **Operating System** | Ubuntu 20.04 LTS / 22.04 LTS / 24.04 LTS |
| **Access** | Root or `sudo`-capable user |
| **Network** | Behind NAT — no public IP required |
| **Outbound** | Must allow TCP to port 443 |

### Verify on the server

```bash
# OS version
lsb_release -a

# Sudo access
sudo -v

# Outbound connectivity
curl -sI --max-time 5 https://github.com/ | head -1
# Expect: HTTP/2 200  (or 301/302)

# Check if UDP is blocked (common in restricted networks)
timeout 3 nc -u 8.8.8.8 53 </dev/null && echo "UDP works" || echo "UDP likely blocked"
```

> 💡 **Note:** If UDP is blocked, this is *expected* and the whole point of the project. The pipeline uses TCP only.

---

## 2. Proxy Subscription

Because the target server's network typically filters outbound traffic, you need a **paid proxy subscription** to give the server free internet access. This is the *only* paid component of the entire setup.

### Required Attributes

Your provider must offer a config that includes:

| Attribute | Notes |
|---|---|
| **Protocol** | `VLESS` or `Trojan` |
| **Transport** | `TCP` with HTTP header, **or** WebSocket |
| **TLS** | Optional (works without it if the network blocks TLS to unknown SNI) |
| **Location** | Outside your restricted region (e.g., EU, US, TR) |

> ⚠️ **Avoid providers that only offer UDP-based protocols** (Hysteria, TUIC, QUIC). They will not work.

### What You'll Need

Extract these values from your provider's subscription:

```
address   = e.g. fr.example.com
port      = e.g. 443
uuid      = e.g. 26d2a41c-ea39-4bd7-bfdf-8c9f2b6a03c6
encryption = none  (or mlkem768x25519plus... for Xray 25+)
host/sni  = e.g. www.rust-lang.org
path      = e.g. /  or  /tr/xxxxx
```

The easiest way to capture them is to ask your provider for a **`vless://` URL**. It looks like:

```
vless://UUID@HOST:PORT?encryption=...&security=none&type=tcp&headerType=http&host=SNI&path=%2F#label
```

You'll paste this URL into `update-xray.sh` during server setup, and it will generate the Xray config automatically.

### Verify proxy connectivity (before proceeding)

Test the subscription on a laptop that can access it:

- **Windows:** Import into v2rayN, connect, visit `https://api.ipify.org` — should show a foreign IP.
- **macOS:** Import into V2Box or FoXray, same test.
- **Linux:** Use `xray` directly — same as `update-xray.sh` does.

If it doesn't work on a laptop, it won't work on the server.

---

## 3. GitHub Account & Credentials

You need **two things** from GitHub:

### 3a. A Secret Gist (the URL mailbox)

This is the file the server writes the tunnel URL to, and the desktop reads from. It contains only the ephemeral tunnel URL — no tokens, no keys.

**Steps:**

1. Go to [gist.github.com](https://gist.github.com).
2. In **Filename including extension**, enter: `topo_tunnel.txt`
3. In the content area, type: `initial` (this is the placeholder the client checks for).
4. Click **Create secret gist** (not public).
5. After saving, look at the URL in your browser:

   ```
   https://gist.github.com/YOUR_USERNAME/0123456789abcdef0123456789abcdef
                                        └─────────── Gist ID ───────────┘
   ```

6. **Copy the Gist ID** (the 32-character hex string). You'll need it during server setup.

> 💡 **Tip:** Click the **Raw** button on your gist, then copy the raw URL. It looks like:
> ```
> https://gist.githubusercontent.com/USERNAME/GIST_ID/raw/topo_tunnel.txt
> ```
> You'll paste this exact URL into the desktop setup script.

### 3b. A Personal Access Token (classic)

This allows the server to update the Gist automatically.

**Steps:**

1. Go to [github.com/settings/tokens](https://github.com/settings/tokens).
2. Click **Generate new token** → **Generate new token (classic)**.
3. Fill in:
   - **Note:** `claude-remote-ssh-sync`
   - **Expiration:** 90 days (recommended; rotate periodically)
   - **Scopes:** check **only** ☑️ `gist`
4. Click **Generate token**.
5. **Copy the token immediately** — GitHub never shows it again. It looks like:

   ```
   ghp_YOUR_TOKEN_HERE
   ```

> 🔒 **Security:**
> - Never commit this token to a repository.
> - Never paste it into chat / AI assistants.
> - Rotate it every 90 days.
> - If compromised, revoke immediately at [github.com/settings/tokens](https://github.com/settings/tokens).

---

## 4. Desktop Client

The desktop is where Claude Desktop runs and where you initiate SSH sessions.

### Supported Platforms

- ✅ **Windows 10 / 11**
- ✅ **macOS 12+**
- ✅ **Linux** (any modern distribution with Bash)

### Required Software

| Software | Version | Purpose |
|---|---|---|
| **Node.js** | 20 or higher | Runs the MCP SSH server (`mcp-ssh`) |
| **Claude Desktop** | Latest | The AI client that drives the SSH tools |
| **OpenSSH client** | Any | Ships with Windows 10+ and all Unix |

### Verify on the desktop

**Windows (PowerShell):**
```powershell
node --version     # v20.x or higher
npx --version      # 10.x or higher
ssh -V             # OpenSSH_8.x or higher
Test-Path "$env:LOCALAPPDATA\AnthropicClaude\Claude.exe"   # Should return True
```

**macOS / Linux:**
```bash
node --version     # v20.x or higher
npx --version      # 10.x or higher
ssh -V             # OpenSSH_8.x or higher
```

### If Node.js is missing

- **Windows / macOS:** Download the LTS installer from [nodejs.org](https://nodejs.org).
- **Ubuntu/Debian:**
  ```bash
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
  ```
- **Arch / Fedora:** Use the system package manager (`sudo pacman -S nodejs npm` / `sudo dnf install nodejs`).

### If Claude Desktop is missing

Download from [claude.ai/download](https://claude.ai/download).

Then enable **Developer Mode**:
- Open Claude Desktop → **Help** → **Troubleshooting** → **Enable Developer Mode**

You should see a **Developer** menu appear in the top bar.

---

## 5. Verification Checklist

Before proceeding to [docs/02-server-setup.md](02-server-setup.md), confirm all of these:

### Server

- [ ] SSH access works from your desktop
- [ ] `sudo -v` succeeds
- [ ] Outbound TCP/443 works (e.g., `curl -I https://github.com/` returns 2xx)
- [ ] You know the target user (e.g., `user`, `ubuntu`, `root`)

### Proxy

- [ ] You have a working `vless://` or `trojan://` URL
- [ ] It connects successfully from a test device
- [ ] The output IP is in a foreign country

### GitHub

- [ ] Secret Gist created with file `topo_tunnel.txt` containing `initial`
- [ ] Gist ID copied (32-char hex)
- [ ] Gist **raw URL** copied
- [ ] Personal Access Token generated with `gist` scope
- [ ] Token stored in a **password manager** (not in a text file)

### Desktop

- [ ] Node.js 20+ installed
- [ ] `npx --version` works
- [ ] Claude Desktop installed
- [ ] Claude Developer Mode enabled

---

## Next Steps

Once every checkbox above is ticked, proceed to:

➡️ **[02 — Server Setup](02-server-setup.md)**

---

## Common Pitfalls

| Pitfall | Prevention |
|---|---|
| Using a public Gist | Always choose **Create secret gist** |
| Token with too many scopes | Only check `gist` — never `repo` or `admin` |
| Testing the proxy only on the desktop | Test it from a network as close to the server as possible |
| Forgetting to enable Developer Mode | MCP won't appear without it |
| Using an old Node.js | MCP servers need Node 20+ — install fresh |
