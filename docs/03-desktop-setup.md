# 03 — Desktop Setup

This guide covers the client-side installation: the PowerShell/Bash synchronizer that keeps `~/.ssh/config` pointing at the current tunnel endpoint, plus the Claude Desktop MCP configuration.

The desktop client's only job is to poll the GitHub Gist every 5 minutes and, if the tunnel URL has changed, update the matching `Host` block in `~/.ssh/config`. Everything else (tunnel, proxy, watchdog) runs on the server.

---

## Table of Contents

1. [How the Client Works](#how-the-client-works)
2. [Windows Setup](#windows-setup)
3. [macOS / Linux Setup](#macos--linux-setup)
4. [Claude Desktop MCP Configuration](#claude-desktop-mcp-configuration)
5. [Verification](#verification)
6. [Routine Operations](#routine-operations)
7. [Uninstall](#uninstall)
8. [Common Issues](#common-issues)

---

## How the Client Works

```
┌───────────────────────────────────────────────────────────────┐
│  1. Scheduled task fires every 5 minutes                      │
│  2. Fetch raw Gist with cache-buster (?cb=<unix_ts>)         │
│  3. If URL is "initial" or empty → skip                       │
│  4. If URL matches current ~/.ssh/config → skip               │
│  5. Otherwise → replace the Host topo-server block atomically │
└───────────────────────────────────────────────────────────────┘
```

The script is **non-destructive**: it locates the `Host <alias>` block by regex and replaces only that block. Any other hosts, comments, or settings in `~/.ssh/config` are preserved.

---

## Windows Setup

### Prerequisites

- Windows 10 / 11
- PowerShell 5.1+ (built-in) or PowerShell 7+
- Node.js 20+ — verify with:
  ```powershell
  node --version    # v20.x or higher
  npx --version
  ```
- OpenSSH client (built into Windows 10+):
  ```powershell
  ssh -V    # OpenSSH_8.x or higher
  ```

### Step 1 — Clone the repository

```powershell
git clone https://github.com/MHAmirkhani/claude-remote-ssh.git
cd claude-remote-ssh\desktop-windows
```

### Step 2 — Run the installer

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-desktop.ps1
```

The script will prompt for:

| Prompt | Example | Notes |
|---|---|---|
| **Gist Raw URL** | `https://gist.githubusercontent.com/USER/ID/raw/topo_tunnel.txt` | From your secret gist |
| **SSH target user** | `user` | The user on the server (default: `user`) |
| **SSH Host alias** | `topo-server` | The name you'll type for `ssh` (default: `topo-server`) |

### What the installer does

1. Creates `%USERPROFILE%\.claude-remote-ssh\`
2. Generates `update-tunnel.ps1` from the template, injecting your Gist URL and SSH preferences
3. Runs the script once immediately (initial sync)
4. Registers a Scheduled Task `UpdateTunnel_<alias>` that runs every 5 minutes
5. Merges `mcp-ssh` into both possible Claude Desktop config paths

### Verifying the scheduled task

```powershell
Get-ScheduledTask -TaskName "UpdateTunnel_topo-server" | Select-Object TaskName, State
```

Expected output:

```
TaskName                 State
--------                 -----
UpdateTunnel_topo-server Ready
```

Check the last run:

```powershell
Get-ScheduledTaskInfo -TaskName "UpdateTunnel_topo-server" | Select-Object LastRunTime, LastTaskResult
```

`LastTaskResult` should be `0`.

### Testing the sync manually

```powershell
# Run the script directly
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude-remote-ssh\update-tunnel.ps1"

# Inspect the result
Select-String -Path "$env:USERPROFILE\.ssh\config" -Pattern "Host topo-server" -Context 0,6
```

### Testing SSH

```powershell
ssh topo-server "hostname; whoami; date"
```

Should connect without a password (assuming your SSH key is on the server — see [docs/02 § Adding Your Desktop SSH Key](02-server-setup.md#adding-your-desktop-ssh-key)).

---

## macOS / Linux Setup

### Prerequisites

- macOS 12+ or any modern Linux distribution
- Node.js 20+
- OpenSSH client (built into macOS and all major Linux distributions)

### Step 1 — Clone the repository

```bash
git clone https://github.com/MHAmirkhani/claude-remote-ssh.git
cd claude-remote-ssh/client-unix
```

### Step 2 — Install and run once

```bash
chmod +x update-tunnel.sh
./update-tunnel.sh "https://gist.githubusercontent.com/USER/ID/raw/topo_tunnel.txt" user topo-server
```

Usage:

```
./update-tunnel.sh <GIST_RAW_URL> [SSH_USER] [HOST_ALIAS]
```

Defaults:
- `SSH_USER` = `user`
- `HOST_ALIAS` = `topo-server`

Expected output:

```
[+] Updated SSH alias 'topo-server' -> xyz.pinggy-free.link:41021
```

If the alias is already up-to-date:

```
[+] Tunnel configuration for 'topo-server' is current (xyz.pinggy-free.link:41021).
```

### Step 3 — Automate with cron (Linux) or launchd (macOS)

#### Option A — cron (Linux)

Open your crontab:

```bash
crontab -e
```

Add:

```cron
*/5 * * * * $HOME/.claude-remote-ssh/update-tunnel.sh "https://gist.githubusercontent.com/USER/ID/raw/topo_tunnel.txt" user topo-server >/dev/null 2>&1
```

> 💡 The script is idempotent, so running every 5 minutes produces no side effects when nothing has changed.

#### Option B — launchd (macOS)

Create a LaunchAgent plist:

```bash
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/com.claude-remote-ssh.tunnel.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude-remote-ssh.tunnel</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/YOUR_USERNAME/.claude-remote-ssh/update-tunnel.sh</string>
        <string>https://gist.githubusercontent.com/USER/ID/raw/topo_tunnel.txt</string>
        <string>user</string>
        <string>topo-server</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/claude-remote-ssh.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claude-remote-ssh.err</string>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.claude-remote-ssh.tunnel.plist
```

Verify:

```bash
launchctl list | grep claude-remote-ssh
```

### Step 4 — Test SSH

```bash
ssh topo-server "hostname; whoami; date"
```

---

## Claude Desktop MCP Configuration

The desktop installer writes the MCP config automatically. This section explains what it does and how to verify.

### What is MCP?

Claude Desktop supports **MCP (Model Context Protocol)** servers that expose tools to the model. The `mcp-ssh` server is a local Node.js process that runs `ssh` commands on your behalf using your `~/.ssh/config` — including the freshly-synced `topo-server` alias.

### Where the config lives

Claude Desktop on Windows reads its MCP config from one of two locations, depending on how it was installed:

| Path | Used by |
|---|---|
| `%APPDATA%\Claude\claude_desktop_config.json` | Direct installer |
| `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude_desktop_config.json` | Microsoft Store / MSIX installer |

The setup script writes to **both** paths, so it works regardless of installation type.

### Config content

The merged config looks like this (other MCP servers preserved):

```json
{
  "mcpServers": {
    "mcp-ssh": {
      "command": "npx.cmd",
      "args": ["-y", "@aiondadotcom/mcp-ssh"]
    }
  }
}
```

> 💡 **Why `npx.cmd` and not `npx`?**  
> On Windows, PowerShell blocks `.ps1` execution by default. Claude Desktop spawns commands without a shell, so it can't run `npx.ps1`. `npx.cmd` is the batch wrapper — it bypasses the PowerShell execution policy.

### Enabling Developer Mode

Before MCP servers appear, you must enable Developer Mode:

1. Open Claude Desktop
2. Menu bar → **Help** → **Troubleshooting**
3. Click **Enable Developer Mode**

A new **Developer** menu should appear at the top.

### Verifying the MCP server

1. In Claude Desktop: **Settings** → **Developer**
2. Under **Local MCP servers**, you should see:

   ```
   mcp-ssh    ● Running
   ```

If it shows an error, click **View logs** for that entry.

### Testing from Claude

In a new conversation:

> SSH into `topo-server` and run: `hostname; uptime; whoami`

The first time, Claude may ask for permission to use the tool. Click **Allow** or **Always allow**.

You should receive output from your server within seconds.

---

## Verification

Full end-to-end checklist:

### On the desktop

- [ ] `node --version` returns v20+
- [ ] Scheduled task / cron entry exists
- [ ] `ssh topo-server "hostname"` works without a password
- [ ] Claude Desktop shows `mcp-ssh` as **Running**
- [ ] Claude can execute remote commands

### One-line health check

**Windows:**
```powershell
Select-String -Path "$env:USERPROFILE\.ssh\config" -Pattern "HostName|Port" | Select-Object -First 2
ssh -o ConnectTimeout=10 topo-server "hostname; date"
```

**macOS / Linux:**
```bash
grep -E "HostName|Port" ~/.ssh/config | head -2
ssh -o ConnectTimeout=10 topo-server "hostname; date"
```

---

## Routine Operations

### Force a manual sync

**Windows:**
```powershell
Start-ScheduledTask -TaskName "UpdateTunnel_topo-server"
# or
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude-remote-ssh\update-tunnel.ps1"
```

**macOS / Linux:**
```bash
~/.claude-remote-ssh/update-tunnel.sh "https://gist.githubusercontent.com/.../raw/topo_tunnel.txt" user topo-server
```

### Check the scheduled task

**Windows:**
```powershell
Get-ScheduledTaskInfo -TaskName "UpdateTunnel_topo-server"
```

**Linux:**
```bash
grep update-tunnel /var/log/syslog | tail -5
```

**macOS:**
```bash
tail -20 /tmp/claude-remote-ssh.log
```

### Disable / re-enable the task

**Windows:**
```powershell
Disable-ScheduledTask -TaskName "UpdateTunnel_topo-server"
Enable-ScheduledTask  -TaskName "UpdateTunnel_topo-server"
```

**Linux:** comment out the crontab line.

**macOS:**
```bash
launchctl unload ~/Library/LaunchAgents/com.claude-remote-ssh.tunnel.plist
launchctl load   ~/Library/LaunchAgents/com.claude-remote-ssh.tunnel.plist
```

---

## Uninstall

### Windows

```powershell
# Remove the scheduled task
Unregister-ScheduledTask -TaskName "UpdateTunnel_topo-server" -Confirm:$false

# Remove the sync script
Remove-Item -Recurse -Force "$env:USERPROFILE\.claude-remote-ssh"

# Remove mcp-ssh from Claude Desktop config (edit manually)
notepad "$env:APPDATA\Claude\claude_desktop_config.json"
# Delete the "mcp-ssh" entry inside "mcpServers"

# Remove the SSH alias (edit manually)
notepad "$env:USERPROFILE\.ssh\config"
# Delete the "Host topo-server" block
```

### macOS / Linux

```bash
# Linux — remove cron entry
crontab -l | grep -v 'update-tunnel.sh' | crontab -

# macOS — remove launch agent
launchctl unload ~/Library/LaunchAgents/com.claude-remote-ssh.tunnel.plist
rm -f ~/Library/LaunchAgents/com.claude-remote-ssh.tunnel.plist

# Remove the sync script
rm -rf ~/.claude-remote-ssh

# Remove the SSH alias (edit manually)
$EDITOR ~/.ssh/config
# Delete the "Host topo-server" block
```

---

## Common Issues

| Symptom | Likely cause | Fix |
|---|---|---|
| `Could not resolve hostname topo-server` | `~/.ssh/config` is stale | Run the sync script manually |
| `Connection timed out` | Tunnel expired on Pinggy side | Wait 60s for the watchdog to rotate, or restart on server |
| `Permission denied (publickey)` | Key not on server | See [docs/02 § Adding Your Desktop SSH Key](02-server-setup.md#adding-your-desktop-ssh-key) |
| Scheduled task shows `LastTaskResult: 0x1` | Script error | Run manually and inspect output |
| MCP server missing in Claude | Wrong config path or `npx` blocked | See [docs/04](04-claude-mcp.md) |
| `npx : cannot be loaded because running scripts is disabled` | PowerShell Execution Policy | Run the script with `-ExecutionPolicy Bypass`, or use `npx.cmd` in the config |

For deeper diagnostics, see [docs/05-troubleshooting.md](05-troubleshooting.md).

---

## Next Steps

➡️ **[04 — Claude MCP](04-claude-mcp.md)**
