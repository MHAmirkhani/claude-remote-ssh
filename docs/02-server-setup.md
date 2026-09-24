# 02 - Server Setup Guide

## Automated Deployment (Recommended)

1. Clone repository to the remote server:
   ```bash
   git clone https://github.com/MHAmirkhani/claude-remote-ssh.git
   cd claude-remote-ssh/server
   ```
2. Execute the setup script with administrative rights:
   ```bash
   sudo bash setup-server.sh
   ```
3. Input prompted values:
   - Personal Access Token
   - Gist ID
   - Target Gist filename (Default: `topo_tunnel.txt`)

## Customizing Xray Proxy Credentials

Edit `/usr/local/etc/xray/config.json`:
```json
"vnext": [
  {
    "address": "proxy.yourdomain.com",
    "port": 443,
    "users": [
      {
        "id": "00000000-0000-0000-0000-000000000000",
        "encryption": "none"
      }
    ]
  }
]
```

Restart Xray and verify egress:
```bash
sudo systemctl restart xray
curl -x socks5h://127.0.0.1:10809 -s https://api.ipify.org
```

## Service Health Checks
```bash
sudo systemctl status pinggy-tunnel
sudo journalctl -u pinggy-tunnel -n 50 --no-pager
```