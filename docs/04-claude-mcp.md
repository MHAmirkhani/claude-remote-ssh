# 04 — Claude Desktop MCP Configuration

This guide explains how Claude Desktop talks to your remote server through the **Model Context Protocol (MCP)**, how to configure the `mcp-ssh` server, and how to verify everything works end-to-end.

---

## Table of Contents

1. [What is MCP?](#what-is-mcp)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Config File Locations](#config-file-locations)
5. [Configuration Content](#configuration-content)
6. [Enabling Developer Mode](#enabling-developer-mode)
7. [Restarting Claude Desktop](#restarting-claude-desktop)
8. [Verification](#verification)
9. [Using MCP from Claude](#using-mcp-from-claude)
10. [Advanced Configuration](#advanced-configuration)
11. [Troubleshooting](#troubleshooting)
12. [Uninstall](#uninstall)

---

## What is MCP?

**Model Context Protocol (MCP)** is an open standard that allows LLM applications (like Claude Desktop) to connect to external tools and data sources through a uniform interface. It was introduced by Anthropic in late 2024.

An MCP server:
- Runs as a **local process** on your machine
- Communicates with Claude Desktop over **stdio** (standard input/output)
- Exposes one or more **tools** the model can invoke
- Optionally exposes **resources** (data) and **prompts** (templates)

In our case, the MCP server we use is [`@aiondadotcom/mcp-ssh`](https://github.com/aiondadotcom/mcp-ssh), which exposes a single tool: **execute arbitrary SSH commands against aliases defined in `~/.ssh/config`**.

---

## Architecture

```
┌──────────────────┐
│  Claude Desktop  │
│  (Chat UI)       │
└────────┬─────────┘
         │  stdio
         ▼
┌──────────────────────────────┐
│  mcp-ssh server              │
│  (spawned by npx)            │
│                              │
│  Reads: ~/.ssh/config        │
│  Calls: ssh topo-server ...  │
└────────┬─────────────────────┘
         │  SSH
         ▼
┌──────────────────────────────┐
│  Pinggy tunnel endpoint      │
│  tcp://xyz.pinggy-free.link  │
└────────┬─────────────────────┘
         │  forwards to VM:22
         ▼
┌──────────────────────────────┐
│  Target VM sshd              │
│  (Ubuntu, behind NAT)        │
└──────────────────────────────┘
```

The MCP server itself is simple — it runs `ssh <alias> "<command>"` using the system SSH client. All the sophistication (tunnel, proxy, watchdog) happens elsewhere. This means:

- **We don't need to teach MCP about Pinggy.**
- **We don't need to teach MCP about Xray.**
- **We just keep `~/.ssh/config` fresh** — the [desktop sync script](03-desktop-setup.md) handles that.

---

## Prerequisites

Before configuring MCP, ensure:

- [ ] **Node.js 20+** is installed: `node --version`
- [ ] **`npx.cmd`** works: `npx --version` (Windows) / `npx --version` (Unix)
- [ ] **Claude Desktop** is installed and up to date
- [ ] **`ssh topo-server "hostname"`** works from a terminal (see [docs/03](03-desktop-setup.md))
- [ ] Your SSH key is on the server (see [docs/02 § Adding Your Desktop SSH Key](02-server-setup.md#adding-your-desktop-ssh-key))

If `ssh topo-server` fails from the terminal, MCP will fail too. Fix the SSH layer first.

---

## Config File Locations

Claude Desktop on Windows reads its MCP configuration from **one of two paths**, depending on how it was installed:

| Path | Used by | Typical install |
|---|---|---|
| `%APPDATA%\Claude\claude_desktop_config.json` | Direct installer (Squirrel) | Downloaded from claude.ai |
| `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude_desktop_config.json` | MSIX / Microsoft Store | Installed from Store |

**How to determine which one your installation uses:**

```powershell
$paths = @(
    "$env:APPDATA\Claude\claude_desktop_config.json",
    "$env:LOCALAPPDATA\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude_desktop_config.json"
)
foreach ($p in $paths) {
    "$([bool](Test-Path $p))  $p"
}
```

The path that returns `True` is the one Claude actually reads. If **both** exist, the MSIX path takes priority.

> 💡 **The `setup-desktop.ps1` script writes to both paths** to avoid this ambiguity entirely.

**macOS:**
```
~/Library/Application Support/Claude/claude_desktop_config.json
```

**Linux:**
```
~/.config/Claude/claude_desktop_config.json
```

---

## Configuration Content

The MCP server entry uses the following schema:

```json
{
  "mcpServers": {
    "mcp-ssh": {
      "command": "npx.cmd",
      "args": [
        "-y",
        "@aiondadotcom/mcp-ssh"
      ]
    }
  }
}
```

### Field Reference

| Field | Value | Notes |
|---|---|---|
| `mcpServers` | object | Container for all MCP server definitions |
| `mcp-ssh` | object | The name Claude will use to identify this server |
| `command` | `npx.cmd` (Windows) / `npx` (Unix) | The executable to spawn |
| `args` | `["-y", "@aiondadotcom/mcp-ssh"]` | Arguments passed to `npx` |

### Why `npx.cmd` on Windows?

Windows has **two** forms of `npx`:

| File | Type | Runs via |
|---|---|---|
| `npx.ps1` | PowerShell script | PowerShell |
| `npx.cmd` | Batch script | `cmd.exe` |

Claude Desktop spawns MCP servers **without a shell**. This means:
- `npx.ps1` fails silently (Windows can't execute `.ps1` files directly)
- `npx.cmd` works because `.cmd` files have a default handler

**Always use `npx.cmd` on Windows.** On macOS and Linux, plain `npx` is correct.

### Merging, not overwriting

If you already have other MCP servers configured, the setup script **merges** the new entry rather than replacing the whole file:

```json
{
  "mcpServers": {
    "existing-server": { ... },
    "mcp-ssh": {
      "command": "npx.cmd",
      "args": ["-y", "@aiondadotcom/mcp-ssh"]
    }
  }
}
```

Both servers continue to work.

---

## Enabling Developer Mode

MCP servers are **hidden from the UI** unless Developer Mode is enabled.

### Steps

1. Open Claude Desktop.
2. In the menu bar, click **Help**.
3. Select **Troubleshooting** → **Enable Developer Mode**.
4. A new **Developer** menu item appears at the top.

> ⚠️ Developer Mode is required to see the MCP servers list. It does not change the security posture of Claude — it only reveals debugging features.

### Where to find MCP servers

After enabling Developer Mode:

**Settings** → **Developer** → **Local MCP servers**

You should see:

```
mcp-ssh    ● Running
```

A green dot and the word `Running` mean the server spawned successfully. Any other state (or a missing card entirely) indicates a config problem.

---

## Restarting Claude Desktop

MCP configuration is only read **at startup**. After editing the config, you must fully restart:

### Windows

1. Right-click the Claude icon in the **system tray** (bottom-right of the taskbar).
2. Click **Quit** — do **not** just close the window.
3. Wait 3 seconds.
4. Re-launch Claude Desktop.

**Alternative (taskkill):**
```powershell
Get-Process -Name "Claude" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3
Start-Process "$env:LOCALAPPDATA\AnthropicClaude\Claude.exe"
```

### macOS

```bash
osascript -e 'quit app "Claude"'
sleep 3
open -a Claude
```

### Linux

```bash
pkill -f Claude
sleep 3
# Relaunch from your application menu
```

---

## Verification

### Step 1 — Config file is valid JSON

```powershell
Get-Content "$env:APPDATA\Claude\claude_desktop_config.json" | ConvertFrom-Json
```

No error means the JSON parses. A syntax error means Claude will silently ignore the whole file.

### Step 2 — MCP server shows as Running

In Claude Desktop: **Settings** → **Developer** → **Local MCP servers**. Look for:

```
mcp-ssh    ● Running
```

### Step 3 — MCP server starts manually

You can test the server outside Claude:

```powershell
npx -y @aiondadotcom/mcp-ssh --help
```

Expected output starts with:

```
Initializing SSH client...
Creating MCP server...
Setting up request handlers...
Starting MCP SSH Agent on STDIO...
MCP SSH Agent connected and ready!
```

Press `Ctrl+C` to exit.

### Step 4 — SSH works from the terminal

```powershell
ssh topo-server "hostname; date"
```

If this fails, MCP will also fail — fix the SSH layer first.

### Step 5 — Test from Claude

In a new conversation:

> SSH into `topo-server` and run `hostname; uptime; whoami`

Claude will:
1. Invoke the `mcp-ssh` tool
2. Read `~/.ssh/config`
3. Run `ssh topo-server "hostname; uptime; whoami"`
4. Return the output

The first time, you'll see an **Allow** / **Always allow** prompt. Click **Always allow** to skip this next time.

---

## Using MCP from Claude

Once running, `mcp-ssh` enables Claude to run any SSH command on the server. Examples:

### Basic inspection

> SSH into `topo-server` and run: `uname -a; uptime; df -h`

### File management

> List all files in `/media/user/Disk/Project/Topo_Project_v2` on `topo-server`.

### Running scripts

> On `topo-server`, activate the `venv-topo` virtual environment in `/media/user/Disk/Project/Topo_Project_v2` and run `python --version`.

### Long-running jobs

> On `topo-server`, run `x0_dense.sh` in a `tmux` session named `calc` and report back when it's started.

### Checking GPU status

> On `topo-server`, run `nvidia-smi` and summarize the results.

Claude chains multiple SSH calls as needed. There is no session persistence between calls — each command runs in a fresh shell.

### Providing context

You can paste local files into the conversation to give Claude context:

> Here is the contents of my `analyze.py` (pasted below). SSH into `topo-server`, write this file to `/media/user/Disk/Project/Topo_Project_v2/analyze.py`, and run it with the `venv-topo` environment.

---

## Advanced Configuration

### Limiting permissions

To prevent Claude from running destructive commands without confirmation:

1. **Settings** → **Developer** → **mcp-ssh** → **Permissions**
2. Uncheck **Bypass permissions for tool calls**

You'll then get an **Allow** prompt for each tool invocation.

### Custom SSH options

Because `mcp-ssh` inherits `~/.ssh/config`, any SSH option you set there applies. Examples:

```
Host topo-server
    HostName xyz.pinggy-free.link
    User user
    Port 41021
    AddressFamily inet
    StrictHostKeyChecking accept-new
    ServerAliveInterval 60
    TCPKeepAlive yes
    # Custom options:
    Compression yes
    LogLevel ERROR
    IdentityFile ~/.ssh/id_ed25519_topo
```

### Multiple servers

To manage multiple remote hosts, add aliases in `~/.ssh/config` and extend the sync script to poll multiple Gists. Claude can then address each alias by name:

> SSH into `topo-server` and `gpu-server`, and compare their `nvidia-smi` outputs.

### Viewing MCP logs

If `mcp-ssh` doesn't start correctly:

1. In Claude Desktop: **Settings** → **Developer** → **mcp-ssh** → **View logs**
2. Look for:
   - `spawn npx.cmd ENOENT` → Node.js not in PATH
   - `Cannot find module` → `npx` can't download the package
   - `EACCES` → permission issue with Node's npm cache

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `mcp-ssh` not shown in Developer tab | Config path is wrong, or Claude not restarted | [Check config paths](#config-file-locations) and fully quit Claude |
| `mcp-ssh` shows `Failed to connect` | `npx.cmd` can't spawn | Run `npx -y @aiondadotcom/mcp-ssh --help` manually |
| `spawn npx.cmd ENOENT` | Node.js not in system PATH | Reinstall Node.js and reboot |
| Tool call times out | SSH layer is broken | Test `ssh topo-server "hostname"` from terminal |
| `Permission denied (publickey)` | SSH key not on server | See [docs/02 § Adding Your Desktop SSH Key](02-server-setup.md#adding-your-desktop-ssh-key) |
| Config JSON parse error | Syntax error or BOM | Rewrite with `WriteAllText` (UTF-8 no BOM) |

See [docs/05-troubleshooting.md](05-troubleshooting.md) for the full guide.

---

## Uninstall

### Remove `mcp-ssh` from Claude Desktop

Edit the config file:

```powershell
notepad "$env:APPDATA\Claude\claude_desktop_config.json"
```

Delete the `"mcp-ssh"` key inside `"mcpServers"`. If it was the only server, the result should be:

```json
{
  "mcpServers": {}
}
```

Or just delete the file entirely (Claude will recreate it on next launch with no MCP servers).

### Clear the `npx` cache

If you want to reclaim disk space:

```powershell
# Windows
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\npm-cache\_npx"
```

```bash
# macOS / Linux
rm -rf ~/.npm/_npx
```

---

## Next Steps

➡️ **[05 — Troubleshooting](05-troubleshooting.md)**
