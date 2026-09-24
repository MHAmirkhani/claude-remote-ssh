# 03 - Desktop Setup Guide

## Windows Client Setup

1. Open PowerShell and navigate to `desktop-windows`:
   ```powershell
   cd desktop-windows
   powershell -ExecutionPolicy Bypass -File .\setup-desktop.ps1
   ```
2. When prompted:
   - Paste the Raw Gist URL.
   - Enter your VM SSH user name.
   - Specify your desired SSH host alias (default: `topo-server`).

### Validating Windows Scheduled Task
Verify the task is active and polling:
```powershell
Get-ScheduledTask -TaskName "UpdateTunnel_topo-server" | Select-Object TaskName, State
```

## Unix / macOS Client Setup

Add periodic cron synchronization:
```bash
chmod +x client-unix/update-tunnel.sh
crontab -e
```
Add the following line to synchronize every 5 minutes:
```cron
*/5 * * * * /path/to/client-unix/update-tunnel.sh "https://gist.githubusercontent.com/.../raw/topo_tunnel.txt" ubuntu topo-server >/dev/null 2>&1
```