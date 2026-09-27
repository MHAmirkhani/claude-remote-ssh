# 05 — Troubleshooting

This guide covers everything that can go wrong in the pipeline, organized by which component fails. Each entry includes the exact symptom, the root cause, and the fix — all derived from real debugging sessions.

---

## Table of Contents

1. [Diagnostic Workflow](#diagnostic-workflow)
2. [Server-Side Issues](#server-side-issues)
3. [Desktop-Side Issues](#desktop-side-issues)
4. [Claude Desktop / MCP Issues](#claude-desktop--mcp-issues)
5. [Network & Firewall Issues](#network--firewall-issues)
6. [Security Warnings](#security-warnings)
7. [Log Reference](#log-reference)
8. [Nuclear Options](#nuclear-options)

---

## Diagnostic Workflow

When something breaks, work **top-down** through the chain. Run these in order and stop at the first failure:

### On the server

```bash
# 1. Is Xray running?
sudo systemctl is-active xray

# 2. Does the SOCKS proxy actually route traffic?
curl -x socks5h://127.0.0.1:10809 -s --max-time 15 https://api.ipify.org; echo

# 3. Is the tunnel service up?
sudo systemctl is-active pinggy-tunnel

# 4. Is the tunnel process alive?
ps aux | grep -E "ssh.*-R 0:localhost:22" | grep -v grep

# 5. What URL is currently published?
cat /tmp/pinggy_url.txt 2>/dev/null || echo "no URL file"

# 6. What's in the Gist right now?
source /etc/claude-remote-ssh/tunnel.env
curl -s -H "Authorization: token ${GITHUB_TOKEN}" \
  "https://api.github.com/gists/${GIST_ID}" | grep -oP '"content":\s*"\K[^"]+' | head -1

# Shortcut: run everything at once
check-tunnel
```

### On the desktop

```powershell
# 1. Does the config file point at the current URL?
Select-String -Path "$env:USERPROFILE\.ssh\config" -Pattern "HostName|Port"

# 2. What does the Gist say?
Invoke-RestMethod -Uri "https://gist.githubusercontent.com/USER/ID/raw/topo_tunnel.txt?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"

# 3. Can we SSH?
ssh -o ConnectTimeout=10 topo-server "hostname; date"

# 4. Is the task scheduler running?
Get-ScheduledTaskInfo -TaskName "UpdateTunnel_topo-server" | Select-Object LastRunTime, LastTaskResult
```

The first step that fails tells you which component to fix.

---

## Server-Side Issues

### Xray fails to start

**Symptom:**
```
sudo systemctl status xray
● xray.service - Xray Core Proxy Service
   Active: failed
```

**Check the exact error:**
```bash
sudo journalctl -u xray -n 50 --no-pager
```

**Common causes:**

| Log message | Cause | Fix |
|---|---|---|
| `failed to load GeoIP: private` | `geoip.dat` missing | `sudo cp /tmp/geoip.dat /usr/local/bin/` |
| `unknown config id: mixed` | Using Xray-specific protocol on V2Ray | Migrate to Xray-core, or change `"protocol": "mixed"` to `"socks"` |
| `address already in use` | Another process on port 10809 | `sudo ss -tlnp \| grep 10809` to identify, then kill |
| `infra/conf: invalid field rule` | Malformed routing rule | Validate JSON with `jq . /usr/local/etc/xray/config.json` |

### SOCKS proxy returns empty

**Symptom:**
```bash
curl -x socks5h://127.0.0.1:10809 -s --max-time 15 https://api.ipify.org; echo
# (empty output)
```

**This means: Xray is running, but the upstream proxy is unreachable.**

**Diagnose:**

```bash
# 1. Is the upstream VLESS host resolvable?
dig +short $(grep -oP '"address":\s*"\K[^"]+' /usr/local/etc/xray/config.json | head -1)

# 2. Can we reach the upstream port?
nc -zv -w 5 fr.example.com 443

# 3. What does Xray say?
sudo journalctl -u xray --since "5 min ago" --no-pager
```

**Likely causes:**

| Cause | Fix |
|---|---|
| Subscription expired | Renew with provider |
| Provider's server is down | Switch to a different `vless://` URL via `update-xray.sh` |
| Upstream port blocked by university | Try a provider on a different port (8443, 2053) |
| DNS poisoning | Use `1.1.1.1` for `dig`, then compare to system resolver |
| Xray config was truncated | Re-run `update-xray.sh` with the URL |

### Pinggy fails to publish URL

**Symptom:**
```
sudo journalctl -u pinggy-tunnel -n 20
[TIMESTAMP] [x] Could not extract tunnel URL from log within timeout.
```

**Diagnose:**
```bash
cat /tmp/pinggy_output.log
```

Look for:

| Output | Meaning |
|---|---|
| `Connection closed by ... port 443` | Pinggy edge rejecting — likely DPI or Cloudflare block |
| `Permission denied` | SSH key issue on Pinggy side (rare) |
| `ProxyCommand exited with non-zero` | Xray SOCKS isn't reachable (see above) |
| `No route to host` | University blocking outbound 443 to Pinggy's IP range |

**If the SOCKS proxy works but Pinggy doesn't:**

Pinggy's free tier occasionally blocks IPs from certain countries. Workarounds:

1. **Retry** — sometimes transient.
2. **Rotate Xray node** — different foreign IP may have better luck.
3. **Switch to an alternative service** (see [Network & Firewall Issues](#network--firewall-issues)).
4. **Upgrade to Pinggy Pro** — removes country-based rate limiting.

### Tunnel process shows but DNS doesn't resolve

**Symptom:**
```
ps aux | grep pinggy
user 12345 ... ssh ... -R 0:localhost:22 tcp@a.pinggy.io
```
But:
```
check-tunnel
[5/6] DNS resolution FAILED (tunnel is dead on Pinggy side)
```

**This is the zombie tunnel problem.** SSH connections can hang for hours after Pinggy has expired the endpoint. `kill -0` still succeeds because the process exists — but the tunnel is a dead man walking.

**The watchdog should catch this within 90 seconds.** If it doesn't:

```bash
# Verify the watchdog is really running
sudo systemctl status pinggy-tunnel

# Check its health check interval
grep HEALTH_CHECK_INTERVAL /usr/local/bin/pinggy-auto.sh

# Manually force a tunnel refresh
sudo systemctl restart pinggy-tunnel
```

If the watchdog is running but not catching the zombie, ensure you're on the latest `pinggy-auto.sh` — older versions only did `kill -0` without DNS checks.

### Gist isn't updating

**Symptom:**
```bash
sudo journalctl -u pinggy-tunnel | grep Gist
[TIMESTAMP] [!] Failed updating Gist: {"message":"Bad credentials", ...}
```

**Cause: GitHub token invalid, expired, or missing scope.**

**Verify the token:**
```bash
source /etc/claude-remote-ssh/tunnel.env
curl -sI -H "Authorization: token ${GITHUB_TOKEN}" https://api.github.com/user | grep -i "x-oauth-scopes"
# Should output: x-oauth-scopes: gist
```

If the output is empty or missing `gist`:

1. Revoke the current token at [github.com/settings/tokens](https://github.com/settings/tokens).
2. Generate a new one with the `gist` scope.
3. Update `/etc/claude-remote-ssh/tunnel.env`:
   ```bash
   sudo nano /etc/claude-remote-ssh/tunnel.env
   # Update GITHUB_TOKEN=...
   sudo systemctl restart pinggy-tunnel
   ```

### `check-tunnel` command not found

**Symptom:**
```bash
$ check-tunnel
check-tunnel: command not found
```

**Cause:** The alias defined in `/etc/profile.d/claude-remote-ssh.sh` isn't loaded in your current shell.

**Fix:**
```bash
source /etc/profile.d/claude-remote-ssh.sh
```

To make it permanent: log out and back in, or add `source /etc/profile.d/claude-remote-ssh.sh` to `~/.bashrc`.

---

## Desktop-Side Issues

### `Could not resolve hostname topo-server`

**Symptom:**
```powershell
ssh topo-server "hostname"
ssh: Could not resolve hostname topo-server: No such host is known.
```

**Two possible causes:**

**a) The SSH config doesn't have the alias.**
```powershell
Test-Path "$env:USERPROFILE\.ssh\config"
Get-Content "$env:USERPROFILE\.ssh\config"
```

If the file is missing or lacks a `Host topo-server` block, the sync script hasn't run.

**b) The alias exists, but the tunnel URL is stale.**
```powershell
Select-String -Path "$env:USERPROFILE\.ssh\config" -Pattern "HostName"
```

Compare against the current Gist:

```powershell
Invoke-RestMethod -Uri "https://gist.githubusercontent.com/USER/ID/raw/topo_tunnel.txt?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
```

If they differ, run the sync script:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude-remote-ssh\update-tunnel.ps1"
```

### `Temporary failure in name resolution`

**Symptom:**
```powershell
ssh topo-server "hostname"
ssh: Could not resolve hostname xyz.pinggy-free.link: Temporary failure in name resolution
```

**Cause:** The Pinggy tunnel has expired (or the edge is unreachable). The URL in `~/.ssh/config` is no longer valid.

**Fix:**
1. Wait up to 90 seconds for the server-side watchdog to rotate.
2. Or force a refresh on the server:
   ```bash
   sudo systemctl restart pinggy-tunnel
   ```
3. Then resync on the desktop:
   ```powershell
   Start-ScheduledTask -TaskName "UpdateTunnel_topo-server"
   ```

### Sync script fetches stale URL from Gist

**Symptom:** The Gist URL and the config file show different values, and the script reports `No change needed. Tunnel is up-to-date.`

**Cause:** The GitHub raw CDN caches content for ~5 minutes. The script may see a stale value.

**Fix:** The cache-buster (`?cb=<unix_timestamp>`) prevents this. Verify it's present:

```powershell
Get-Content "$env:USERPROFILE\.claude-remote-ssh\update-tunnel.ps1" | Select-String "cb="
```

If the line `$requestUri = "${gistBaseUrl}?cb=${cacheBuster}"` isn't present, update the script from the repo.

### Scheduled task result `0x1`

**Symptom:**
```powershell
Get-ScheduledTaskInfo -TaskName "UpdateTunnel_topo-server" | Select-Object LastTaskResult
LastTaskResult
--------------
0x1
```

**Cause:** The script exited with a non-zero status. This is usually a network error when fetching the Gist.

**Diagnose:**

Run the script manually with verbose output:

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File "$env:USERPROFILE\.claude-remote-ssh\update-tunnel.ps1"
```

The output will show the exact error. Common causes:

| Error | Fix |
|---|---|
| `Failed to query Gist endpoint: The remote name could not be resolved` | Check internet connectivity |
| `Failed to query Gist endpoint: 404` | Wrong Gist URL |
| `Failed to query Gist endpoint: 403` | GitHub rate limiting (rare for authenticated requests) |

### PowerShell: `running scripts is disabled`

**Symptom:**
```powershell
npx : File C:\Program Files\nodejs\npx.ps1 cannot be loaded because running scripts is disabled on this system.
```

**Cause:** Windows PowerShell's execution policy blocks `.ps1` files by default.

**Fix (permanent, per-user):**

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Confirm with `Y`, then re-run. This only affects your user — system-wide policy is unchanged.

**Alternative:** Use `npx.cmd` everywhere instead of `npx`. This is what our Claude config does.

---

## Claude Desktop / MCP Issues

### MCP server doesn't appear in Developer tab

**Symptom:** **Settings** → **Developer** → **Local MCP servers** is empty or missing `mcp-ssh`.

**Cause:** Config was written to the wrong path, or Claude wasn't restarted, or the JSON is invalid.

**Diagnose:**

**1. Verify which config path Claude is using:**

```powershell
$paths = @(
    "$env:APPDATA\Claude\claude_desktop_config.json",
    "$env:LOCALAPPDATA\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude_desktop_config.json"
)
foreach ($p in $paths) { "$([bool](Test-Path $p))  $p" }
```

The path with `True` is the active one. If it doesn't contain `mcp-ssh`, that's the issue.

**2. Validate the JSON:**

```powershell
Get-Content "$env:APPDATA\Claude\claude_desktop_config.json" | ConvertFrom-Json
```

A parse error means Claude silently ignores the file.

**3. Fully restart Claude Desktop:**

Right-click the system tray icon → **Quit** → relaunch.

### `spawn npx.cmd ENOENT`

**Symptom:** MCP card shows error: `spawn npx.cmd ENOENT`.

**Cause:** `npx.cmd` isn't in the system PATH that Claude Desktop sees.

**Fix:**

Find the full path:

```powershell
where.exe npx.cmd
# C:\Program Files\nodejs\npx.cmd
```

Edit the Claude config and use the **absolute path**:

```json
{
  "mcpServers": {
    "mcp-ssh": {
      "command": "C:\\Program Files\\nodejs\\npx.cmd",
      "args": ["-y", "@aiondadotcom/mcp-ssh"]
    }
  }
}
```

**Note:** Backslashes must be doubled (`\\`) in JSON.

### MCP card shows `Failed to connect`

**Cause:** `npx` can't download or start the MCP server package.

**Verify manually:**

```powershell
npx -y @aiondadotcom/mcp-ssh --help
```

Expected output ends with `MCP SSH Agent connected and ready!`. If not, the issue is npm/node, not MCP.

**Possible causes:**

| Symptom | Fix |
|---|---|
| Hangs for >60s | npm registry is slow or blocked. Try: `npm config set registry https://registry.npmmirror.com` |
| `Cannot find module` | Clear npm cache: `npm cache clean --force` |
| `EACCES` | Run PowerShell as Administrator once to fix npm cache permissions |

### Claude says "I don't have access to that tool"

**Cause:** Developer Mode is disabled, or MCP server hasn't loaded yet.

**Fix:**

1. **Help** → **Troubleshooting** → **Enable Developer Mode**.
2. Restart Claude Desktop.
3. Verify **Settings** → **Developer** → **mcp-ssh** is **Running**.

### Claude timeout on SSH command

**Symptom:** Claude says `SSH command timed out after 60 seconds`.

**Cause:** SSH is trying to prompt for a password (interactive auth) but has no TTY. The MCP server can't respond to the prompt.

**Fix:** Ensure passwordless SSH works from a terminal:

```powershell
ssh topo-server "hostname"
```

If it prompts for a password, your SSH key isn't on the server:

```powershell
type "$env:USERPROFILE\.ssh\id_ed25519.pub" | ssh -p PORT user@HOST "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

---

## Network & Firewall Issues

### University blocks outbound UDP

**Symptom:** Tailscale, ZeroTier, and WireGuard fail with `relay`, `OFFLINE`, or timeout errors.

**This is expected.** The entire pipeline uses TCP only, so this doesn't affect `claude-remote-ssh`.

Verify TCP is fine:
```bash
curl -I https://github.com
```

If TCP also fails, the network is completely firewalled — talk to your network admin.

### Cloudflare 403 on pinggy.io or GitHub

**Symptom:**
```bash
curl -I https://pinggy.io
HTTP/2 403
server: cloudflare
```

**Cause:** Iranian IP address — Cloudflare's anti-bot blocks them at the CDN level. This is *not* a user error.

**Workarounds:**

1. **Use Xray for the tunnel** — our `pinggy-auto.sh` already routes through Xray, so Pinggy sees the foreign IP.
2. **For manual `curl` tests**, prefix with the proxy:
   ```bash
   curl -x socks5h://127.0.0.1:10809 -I https://pinggy.io
   ```
3. **For GitHub raw**, always add cache-buster and use `api.github.com` for authoritative reads.

### MITM warning: `REMOTE HOST IDENTIFICATION HAS CHANGED`

**Symptom:**
```
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
```

**Cause:** SSH saw a different host key than what's in `~/.ssh/known_hosts`. This can be:

- **Legitimate:** Pinggy routes through different edge nodes each rotation → different host key.
- **Legitimate:** The VM was reinstalled and regenerated its SSH keys.
- **Hostile:** A man-in-the-middle attack.

**Verify:**

1. Get the server's real host key fingerprint:
   ```bash
   sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```
2. When SSH prompts, compare fingerprints.
3. If they match → safe to accept.
4. If they don't → **stop**. Do not accept. Investigate.

**Because Pinggy rotates edge hosts**, our config uses `StrictHostKeyChecking accept-new` to auto-accept *new* keys while still rejecting *changed* keys. If you see a mismatch, it's worth investigating.

### Connection works from server but not desktop

**Symptom:** `ssh user@localhost` works on the server, but `ssh topo-server` fails on the desktop.

**Cause:** The tunnel is broken or the desktop's Gist hasn't synced.

**Diagnose on the desktop:**

```powershell
# Does the config point at the right host?
Select-String -Path "$env:USERPROFILE\.ssh\config" -Pattern "HostName"

# What does the Gist say?
Invoke-RestMethod -Uri "https://gist.githubusercontent.com/.../raw/topo_tunnel.txt?cb=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
```

If they match, the tunnel endpoint is stale. Restart the tunnel on the server:

```bash
sudo systemctl restart pinggy-tunnel
```

---

## Security Warnings

### Never commit tokens

If you accidentally committed `tunnel.env` or `claude_desktop_config.json` containing a token:

1. **Immediately revoke** the token at [github.com/settings/tokens](https://github.com/settings/tokens).
2. Generate a new one.
3. Remove the file from git history:
   ```bash
   git filter-branch --force --index-filter \
     'git rm --cached --ignore-unmatch path/to/file' \
     --prune-empty --tag-name-filter cat -- --all
   ```
4. Force push: `git push --force --all`.
5. Update the server's `/etc/claude-remote-ssh/tunnel.env` with the new token.

### Token scope hygiene

Verify your GitHub token has **only** `gist` scope:

```bash
curl -sI -H "Authorization: token ghp_REDACTED" https://api.github.com/user \
  | grep -i "x-oauth-scopes"
```

If it lists more than `gist`, revoke and create a new one. Minimal scope limits blast radius if leaked.

---

## Log Reference

### Server logs

| Path | Content |
|---|---|
| `sudo journalctl -u xray -f` | Xray proxy activity (per-connection) |
| `sudo journalctl -u pinggy-tunnel -f` | Watchdog and tunnel lifecycle |
| `/tmp/pinggy_output.log` | Raw SSH client output from Pinggy |
| `/tmp/pinggy_tunnel.pid` | PID of the current SSH tunnel child |
| `/tmp/pinggy_url.txt` | Current published tunnel URL |

### Desktop logs

| Path | Content |
|---|---|
| `%USERPROFILE%\.claude-remote-ssh\update-tunnel.ps1` | Sync script itself |
| `%USERPROFILE%\.ssh\config` | Generated SSH config |
| `%APPDATA%\Claude\claude_desktop_config.json` | MCP configuration |
| Claude → Settings → Developer → View logs | MCP server stdout/stderr |

### Useful one-liners

**Server — show everything at once:**
```bash
sudo journalctl -u xray -u pinggy-tunnel -n 50 --no-pager
```

**Desktop — show everything at once:**
```powershell
Get-Content "$env:USERPROFILE\.ssh\config"
Get-Content "$env:APPDATA\Claude\claude_desktop_config.json"
Get-ScheduledTaskInfo -TaskName "UpdateTunnel_topo-server"
```

---

## Nuclear Options

When all else fails:

### Reset the whole server side

```bash
# Stop services
sudo systemctl stop pinggy-tunnel xray

# Clear runtime state
sudo rm -f /tmp/pinggy_{output.log,tunnel.pid,url.txt}

# Reinstall Xray config from a fresh URL
sudo update-xray.sh "vless://FRESH_UUID@HOST:PORT?..."

# Restart
sudo systemctl start xray
sudo systemctl start pinggy-tunnel

# Wait and verify
sleep 25
check-tunnel
```

### Reset the whole desktop side

```powershell
# Stop scheduled task
Stop-ScheduledTask -TaskName "UpdateTunnel_topo-server" -ErrorAction SilentlyContinue

# Clear SSH config
Remove-Item "$env:USERPROFILE\.ssh\config" -ErrorAction SilentlyContinue

# Clear sync script
Remove-Item -Recurse -Force "$env:USERPROFILE\.claude-remote-ssh" -ErrorAction SilentlyContinue

# Reinstall
cd desktop-windows
powershell -ExecutionPolicy Bypass -File .\setup-desktop.ps1
```

### Full reprovision

Last resort — treat the server as fresh:

```bash
# On the server
sudo rm -rf /etc/claude-remote-ssh /usr/local/etc/xray
sudo rm -f  /usr/local/bin/{pinggy-auto.sh,update-xray.sh,check-tunnel.sh,xray}

# Re-clone and reinstall
cd ~
rm -rf claude-remote-ssh
git clone https://github.com/MHAmirkhani/claude-remote-ssh.git
cd claude-remote-ssh/server
sudo bash setup-server.sh
```

---

## Getting Help

If you've exhausted this guide, open an issue:

**Include:**

1. **Distro/OS:** `lsb_release -a` output + `uname -r`
2. **Xray version:** `xray version`
3. **Chain status:** `check-tunnel` output
4. **Relevant logs:** last 50 lines of `journalctl -u xray` and `journalctl -u pinggy-tunnel`
5. **Redacted config:** `~/.ssh/config` and `claude_desktop_config.json` (with tokens/hosts replaced)

**Do NOT include:**

- GitHub tokens
- SSH private keys
- Full VLESS URLs with UUIDs

**Redact before posting:**

```bash
# Server
sed 's/ghp_[A-Za-z0-9]*/ghp_REDACTED/g' /etc/claude-remote-ssh/tunnel.env
```

```powershell
# Desktop
(Get-Content "$env:USERPROFILE\.ssh\config") -replace 'ghp_[A-Za-z0-9]*', 'ghp_REDACTED'
```

---

## Next Steps

➡️ **[06 — Architecture](06-architecture.md)**
