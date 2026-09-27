# 02 — Server Setup

This guide walks through installing **Xray**, the **Pinggy watchdog**, and the helper scripts on your Linux target server. Everything runs on the server; the desktop setup comes later.

---

## Table of Contents

1. [What Gets Installed](#what-gets-installed)
2. [Automated Deployment](#automated-deployment)
3. [Configuring Xray](#configuring-xray)
4. [Verifying the Full Chain](#verifying-the-full-chain)
5. [Adding Your Desktop SSH Key](#adding-your-desktop-ssh-key)
6. [Service Reference](#service-reference)
7. [Routine Operations](#routine-operations)
8. [Updating Xray Credentials](#updating-xray-credentials)
9. [Uninstall](#uninstall)

---

## What Gets Installed

The `setup-server.sh` script provisions the following on the target server:

| Component | Location | Purpose |
|---|---|---|
| **Xray-core** | `/usr/local/bin/xray` | VLESS/Trojan TCP proxy client |
| **Xray config** | `/usr/local/etc/xray/config.json` | Proxy credentials (edit after install) |
| **Xray service** | `/etc/systemd/system/xray.service` | Runs Xray as a daemon |
| **Pinggy watchdog** | `/usr/local/bin/pinggy-auto.sh` | Maintains the reverse SSH tunnel |
| **Pinggy service** | `/etc/systemd/system/pinggy-tunnel.service` | Runs the watchdog as a daemon |
| **Credential file** | `/etc/claude-remote-ssh/tunnel.env` | GitHub token + Gist ID (`chmod 600`) |
| **Helpers** | `/usr/local/bin/update-xray.sh` | Regenerate Xray config from a VLESS URL |
| **Helpers** | `/usr/local/bin/check-tunnel.sh` | Full chain health check |
| **Shell alias** | `/etc/profile.d/claude-remote-ssh.sh` | `check-tunnel` shortcut for all users |

---

## Automated Deployment

### Step 1 — Clone the repository

SSH into the server (or use AnyDesk/VNC), then:

```bash
git clone https://github.com/MHAmirkhani/claude-remote-ssh.git
cd claude-remote-ssh/server
```

### Step 2 — Run the installer

```bash
sudo bash setup-server.sh
```

The script will prompt for three values:

| Prompt | Example | Where to get it |
|---|---|---|
| **GitHub Token** | `ghp_xxxxxxxx...` | [docs/01-prerequisites.md](01-prerequisites.md#3b-a-personal-access-token-classic) |
| **Gist ID** | `051d822078a8681de42c8a1c38d25fcb` | From the Gist URL |
| **Gist filename** | `topo_tunnel.txt` (default) | Press Enter to accept |

The installer will:
1. Install `curl`, `wget`, `unzip`, `netcat-openbsd`, `openssh-server`, `jq`, `ca-certificates`
2. Download and install Xray `v25.9.11` into `/usr/local/bin/`
3. Create a template Xray config
4. Register and start `xray.service`
5. Write `/etc/claude-remote-ssh/tunnel.env` with `chmod 600`
6. Install and register the Pinggy watchdog
7. Register and start `pinggy-tunnel.service`
8. Generate an Ed25519 keypair for the user (if missing)

### Step 3 — Verify the install

```bash
# Both services should be "active (running)"
sudo systemctl status xray
sudo systemctl status pinggy-tunnel

# Watch the tunnel come up (Ctrl+C to exit)
sudo journalctl -u pinggy-tunnel -f
```

You should see a line like:

```
[TIMESTAMP] [+] Successfully published tunnel endpoint: tcp://xyz.pinggy-free.link:41021
```

---

## Configuring Xray

The installer creates a **template** at `/usr/local/etc/xray/config.json` with placeholder values. You must replace them with your actual proxy credentials.

### Option A — Automatic (recommended)

Use the `update-xray.sh` helper. It parses a `vless://` URL and generates the config:

```bash
sudo update-xray.sh "vless://UUID@HOST:PORT?encryption=...&security=none&type=tcp&headerType=http&host=SNI&path=%2F#label"
```

The script will:
1. Parse the URL
2. Generate a complete Xray config
3. Back up the previous config to `/usr/local/etc/xray/backups/`
4. Validate with `xray -test`
5. Restart `xray.service`
6. Test the SOCKS proxy automatically

Expected output:

```
[+] Parsing VLESS URL...
[i]   UUID: 26d2a41c-ea39-4bd7-bfdf-8c9f2b6a03c6
[i]   Host: fr.example.com
[i]   Port: 443
[+]   Encryption: none
[+]   Network:    tcp
[+]   Header:     http
[+]   Host (SNI): www.rust-lang.org
[+]   Path:       /
[+] Config written to /usr/local/etc/xray/config.json
[i] Validating config...
[+] Config is valid.
[i] Restarting Xray...
[+] Xray restarted successfully.
[i] Testing SOCKS proxy...
[+] Proxy works! Public IP: 45.140.205.72
```

If the last line shows a foreign IP, you're done.

### Option B — Manual

Edit the config file directly:

```bash
sudo nano /usr/local/etc/xray/config.json
```

Replace these placeholders:

| Placeholder | Replace with |
|---|---|
| `YOUR_PROVIDER_HOST` | e.g. `fr.example.com` |
| `YOUR_UUID_HERE` | e.g. `26d2a41c-ea39-4bd7-bfdf-8c9f2b6a03c6` |
| `YOUR_SNI_HOST` | e.g. `www.rust-lang.org` |
| `"encryption": "none"` | The `encryption` value from your URL (or `none`) |

Then validate and restart:

```bash
sudo /usr/local/bin/xray -test -config /usr/local/etc/xray/config.json
sudo systemctl restart xray
```

### Verify egress works

```bash
curl -x socks5h://127.0.0.1:10809 -s --max-time 15 https://api.ipify.org; echo
```

Expected: a **foreign IP address** (not your VM's IP).

If empty or the VM's own IP is returned, the proxy is not working — check `journalctl -u xray`.

---

## Verifying the Full Chain

Run the built-in health check:

```bash
check-tunnel
```

> If `check-tunnel` isn't recognized, either log out and back in, or run `source /etc/profile.d/claude-remote-ssh.sh` first.

You should see six `[OK]` lines and a summary:

```
=====================================================
  Tunnel Health Check
=====================================================

[1/6] Xray service
  [OK]  Xray is running (since Sat 2026-09-26 06:05:03 UTC)

[2/6] SOCKS proxy (127.0.0.1:10809)
  [OK]  Proxy works — public IP: 45.140.205.72

[3/6] Pinggy tunnel service
  [OK]  pinggy-tunnel is running

[4/6] Tunnel process
  [OK]  SSH tunnel alive (PID 2441499, uptime 00:12:34)

[5/6] Current tunnel URL
  [OK]  URL: tcp://uflcx-45-140-205-72.run.pinggy-free.link:42283
  [OK]  DNS resolution works

[6/6] GitHub Gist
  [OK]  Gist URL: tcp://uflcx-45-140-205-72.run.pinggy-free.link:42283
  [OK]  Gist matches local URL

=====================================================
  Summary
=====================================================

  [OK]  Xray service
  [OK]  SOCKS proxy
  [OK]  Pinggy service
  [OK]  Tunnel process
  [OK]  DNS health
  [OK]  Gist sync

  All checks passed! System is fully operational.
```

If any check fails, the summary provides a fix hint.

---

## Adding Your Desktop SSH Key

For the desktop client to log in without a password, its public key must be added to the server's `~/.ssh/authorized_keys`.

### On the desktop (Windows)

```powershell
# Generate a key if you don't have one
if (-not (Test-Path "$env:USERPROFILE\.ssh\id_ed25519.pub")) {
    ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\id_ed25519" -N '""'
}

# Copy it to the server (replace PORT/HOST with the tunnel URL parts)
type "$env:USERPROFILE\.ssh\id_ed25519.pub" | ssh -p PORT user@HOST "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
```

### On the desktop (macOS / Linux)

```bash
ssh-copy-id -p PORT user@HOST
```

### Verify

From the desktop, try a passwordless login:

```bash
ssh -p PORT user@HOST "hostname; date"
```

If you get a shell prompt without a password, the key is set up correctly.

> ⚠️ **Important:** The Pinggy URL changes every 60 minutes. Once the desktop setup script is installed (see [docs/03](03-desktop-setup.md)), the alias `topo-server` will automatically track the current URL.

---

## Service Reference

### `xray.service`

| Command | Purpose |
|---|---|
| `sudo systemctl status xray` | Check state |
| `sudo systemctl restart xray` | Apply a config change |
| `sudo journalctl -u xray -f` | Live logs |
| `sudo /usr/local/bin/xray -test -config /usr/local/etc/xray/config.json` | Validate config |

### `pinggy-tunnel.service`

| Command | Purpose |
|---|---|
| `sudo systemctl status pinggy-tunnel` | Check state |
| `sudo systemctl restart pinggy-tunnel` | Force tunnel refresh |
| `sudo journalctl -u pinggy-tunnel -f` | Live logs |
| `cat /tmp/pinggy_url.txt` | Current tunnel endpoint |
| `cat /tmp/pinggy_output.log` | Raw SSH output from Pinggy |

### Dependency chain

`pinggy-tunnel.service` declares `Requires=xray.service`, so stopping Xray will stop Pinggy too. This is intentional — the tunnel needs the SOCKS proxy.

---

## Routine Operations

### Restart the tunnel (e.g., after rotating Xray)

```bash
sudo systemctl restart pinggy-tunnel
```

The watchdog restarts automatically and publishes a new URL to the Gist within ~20 seconds.

### Update Xray credentials

```bash
sudo update-xray.sh "vless://NEW_UUID@NEW_HOST:PORT?..."
sudo systemctl restart pinggy-tunnel
```

### Check the current URL from anywhere

```bash
# On the server
cat /tmp/pinggy_url.txt

# From the Gist API (no cache)
curl -s -H "Authorization: token $(grep -oP 'GITHUB_TOKEN="\K[^"]+' /etc/claude-remote-ssh/tunnel.env)" \
  "https://api.github.com/gists/$(grep -oP 'GIST_ID="\K[^"]+' /etc/claude-remote-ssh/tunnel.env)" \
  | grep -oP '"content":\s*"\K[^"]+'
```

### Follow watchdog activity

```bash
sudo journalctl -u pinggy-tunnel -f
```

Healthy output every ~58 minutes:

```
[Sat 2026-09-26 07:03:11 UTC] [i] 58-minute rotation limit reached. Refreshing tunnel...
[Sat 2026-09-26 07:03:11 UTC] [i] Establishing outbound tunnel via 127.0.0.1:10809...
[Sat 2026-09-26 07:03:27 UTC] [+] Successfully published tunnel endpoint: tcp://xyz.pinggy-free.link:41234
```

---

## Updating Xray Credentials

When your proxy subscription rotates (which can happen every few days with some providers), you have two paths:

### Path 1 — Same URL still works

Just restart Xray to pick up any provider-side changes:

```bash
sudo systemctl restart xray
```

### Path 2 — Provider gives you a new URL

```bash
sudo update-xray.sh "vless://..."
sudo systemctl restart pinggy-tunnel
```

The helper automatically backs up the old config to `/usr/local/etc/xray/backups/`, so you can roll back if needed.

---

## Uninstall

To completely remove the server-side components:

```bash
# Stop and disable services
sudo systemctl disable --now pinggy-tunnel xray

# Remove systemd unit files
sudo rm -f /etc/systemd/system/pinggy-tunnel.service
sudo rm -f /etc/systemd/system/xray.service
sudo systemctl daemon-reload

# Remove binaries and configs
sudo rm -f  /usr/local/bin/{pinggy-auto.sh,update-xray.sh,check-tunnel.sh,xray}
sudo rm -rf /usr/local/etc/xray
sudo rm -rf /etc/claude-remote-ssh
sudo rm -f  /etc/profile.d/claude-remote-ssh.sh

# Optional: remove the SSH key that was generated
# sudo rm -f ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub
```

---

## Next Steps

➡️ **[03 — Desktop Setup](03-desktop-setup.md)**

---

## Common Issues

| Symptom | Likely cause | Fix |
|---|---|---|
| `xray.service` fails to start | Malformed `config.json` | `sudo /usr/local/bin/xray -test -config /usr/local/etc/xray/config.json` |
| `curl` via SOCKS returns empty | Proxy credentials expired | `sudo update-xray.sh "vless://..."` with a fresh URL |
| `pinggy-tunnel` fails to publish URL | GitHub token invalid or Gist ID wrong | Check `/etc/claude-remote-ssh/tunnel.env` and `journalctl -u pinggy-tunnel` |
| `check-tunnel` command not found | Shell alias not loaded | `source /etc/profile.d/claude-remote-ssh.sh` or log out/in |
| Tunnel URL is stale in Gist | Watchdog crashed | `sudo systemctl restart pinggy-tunnel` |

For deeper diagnostics, see [docs/05-troubleshooting.md](05-troubleshooting.md).
