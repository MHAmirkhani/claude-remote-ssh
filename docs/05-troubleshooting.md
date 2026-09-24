# 05 - Troubleshooting Guide

## Diagnostics Checklist

| Symptom | Root Cause | Solution |
|---|---|---|
| `Could not resolve hostname topo-server` | Gist sync hasn't run yet or invalid raw URL | Run `update-tunnel.ps1` manually; check Task Scheduler |
| `Permission denied (publickey)` | Client public key not authorized on server | Append client `id_ed25519.pub` to server `~/.ssh/authorized_keys` |
| `Pinggy tunnel failed to start` | Local SOCKS proxy unreachable on 10809 | Run `systemctl status xray` and verify node settings |
| Claude shows MCP error `spawn npx ENOENT` | Node.js binary not available in user PATH | Provide absolute path to `npx.cmd` in Claude JSON config |

## Inspecting Logs

### Server Logs
```bash
sudo journalctl -u xray -n 30 --no-pager
sudo journalctl -u pinggy-tunnel -n 30 --no-pager
cat /tmp/pinggy_output.log
```

### Desktop Synchronization Test
```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude-remote-ssh\update-tunnel.ps1"
Get-Content "$env:USERPROFILE\.ssh\config"
```