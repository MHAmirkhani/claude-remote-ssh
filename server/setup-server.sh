#!/usr/bin/env bash
# ==============================================================================
# claude-remote-ssh: Server Provisioning Script
# Supported Platforms: Ubuntu 20.04, 22.04, 24.04 LTS
#
# Installs:
#   - Xray-core proxy
#   - pinggy-auto watchdog service
#   - update-xray.sh helper
#   - check-tunnel.sh helper
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1" >&2; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

echo ""
echo "======================================================"
echo "  claude-remote-ssh Server Setup"
echo "======================================================"
echo ""

if [[ $EUID -ne 0 ]]; then
    err "This installation script must be executed as root (e.g., sudo bash setup-server.sh)."
    exit 1
fi

# Determine target user and home directory
TARGET_USER="${SUDO_USER:-$(id -un)}"
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
    err "Could not resolve valid home directory for user: $TARGET_USER"
    exit 1
fi

info "Configuring service for user: $TARGET_USER ($USER_HOME)"

# ------------------------------------------------------------------------------
# Interactive configuration prompts
# ------------------------------------------------------------------------------
read -r -p "Enter GitHub Token (classic, 'gist' scope only): " GITHUB_TOKEN
read -r -p "Enter GitHub Gist ID: " GIST_ID
read -r -p "Enter Gist target filename [default: topo_tunnel.txt]: " GIST_FILENAME
GIST_FILENAME="${GIST_FILENAME:-topo_tunnel.txt}"

if [[ -z "$GITHUB_TOKEN" || -z "$GIST_ID" ]]; then
    err "Both GitHub Token and Gist ID are strictly required."
    exit 1
fi

# Determine script directory (for locating helper files)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info "Script directory: $SCRIPT_DIR"

# ------------------------------------------------------------------------------
# Step 1: Install Dependencies
# ------------------------------------------------------------------------------
log "Installing operating system dependencies..."
apt-get update -qq
apt-get install -y -qq curl wget unzip netcat-openbsd openssh-server jq ca-certificates

# ------------------------------------------------------------------------------
# Step 2: Install Xray Core
# ------------------------------------------------------------------------------
XRAY_VERSION="v25.9.11"
XRAY_BIN="/usr/local/bin/xray"

if [[ -x "$XRAY_BIN" ]]; then
    info "Xray core binary already located: $("$XRAY_BIN" version | head -n 1)"
else
    log "Downloading and installing Xray-core (${XRAY_VERSION})..."
    TMP_DIR=$(mktemp -d)
    wget -q "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip" -O "${TMP_DIR}/xray.zip"
    unzip -o -q "${TMP_DIR}/xray.zip" -d "${TMP_DIR}"
    install -m 755 "${TMP_DIR}/xray" /usr/local/bin/xray
    install -m 644 "${TMP_DIR}/geoip.dat" /usr/local/bin/geoip.dat
    install -m 644 "${TMP_DIR}/geosite.dat" /usr/local/bin/geosite.dat
    rm -rf "${TMP_DIR}"
    log "Xray installed successfully: $(/usr/local/bin/xray version | head -n 1)"
fi

# ------------------------------------------------------------------------------
# Step 3: Template Configuration for Xray
# ------------------------------------------------------------------------------
mkdir -p /usr/local/etc/xray

if [[ ! -f /usr/local/etc/xray/config.json ]]; then
    log "Generating default template at /usr/local/etc/xray/config.json"

    if [[ -f "${SCRIPT_DIR}/xray-config.json" ]]; then
        cp "${SCRIPT_DIR}/xray-config.json" /usr/local/etc/xray/config.json
    else
        cat > /usr/local/etc/xray/config.json <<'XRAY_CONF'
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "socks-for-ssh",
      "port": 10809,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": false }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "YOUR_PROVIDER_HOST",
            "port": 443,
            "users": [
              {
                "id": "YOUR_UUID_HERE",
                "encryption": "none",
                "flow": ""
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none",
        "tcpSettings": {
          "header": {
            "type": "http",
            "request": {
              "path": ["/"],
              "headers": { "Host": ["YOUR_SNI_HOST"] }
            }
          }
        }
      },
      "mux": { "enabled": false }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["socks-for-ssh"], "outboundTag": "proxy" },
      { "type": "field", "outboundTag": "direct", "ip": ["geoip:private"] }
    ]
  }
}
XRAY_CONF
    fi

    warn "ACTION REQUIRED: Edit /usr/local/etc/xray/config.json with your actual VLESS node credentials."
    warn "You can also use: sudo update-xray.sh \"vless://...\" (after setup completes)."
fi

# ------------------------------------------------------------------------------
# Step 4: Setup Xray Systemd Service
# ------------------------------------------------------------------------------
log "Configuring systemd service for Xray..."
cat > /etc/systemd/system/xray.service <<'SERVICE_CONF'
[Unit]
Description=Xray Core Proxy Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SERVICE_CONF

systemctl daemon-reload
systemctl enable xray.service
systemctl restart xray.service

# ------------------------------------------------------------------------------
# Step 5: Secure Credential Environment File
# ------------------------------------------------------------------------------
log "Writing credential environment file..."
mkdir -p /etc/claude-remote-ssh
cat > /etc/claude-remote-ssh/tunnel.env <<ENV_CONF
GITHUB_TOKEN=${GITHUB_TOKEN}
GIST_ID=${GIST_ID}
GIST_FILENAME=${GIST_FILENAME}
SOCKS_PROXY=127.0.0.1:10809
ENV_CONF
chmod 600 /etc/claude-remote-ssh/tunnel.env
chown -R "$TARGET_USER:$TARGET_USER" /etc/claude-remote-ssh

# ------------------------------------------------------------------------------
# Step 6: Install pinggy-auto watchdog runner
# ------------------------------------------------------------------------------
log "Deploying /usr/local/bin/pinggy-auto.sh..."
if [[ -f "${SCRIPT_DIR}/pinggy-auto.sh" ]]; then
    install -m 755 "${SCRIPT_DIR}/pinggy-auto.sh" /usr/local/bin/pinggy-auto.sh
    info "Installed: /usr/local/bin/pinggy-auto.sh"
else
    err "pinggy-auto.sh not found in ${SCRIPT_DIR}. Aborting."
    exit 1
fi

# ------------------------------------------------------------------------------
# Step 6b: Install update-xray.sh and check-tunnel.sh helpers
# ------------------------------------------------------------------------------
log "Installing helper scripts..."

if [[ -f "${SCRIPT_DIR}/update-xray.sh" ]]; then
    install -m 755 "${SCRIPT_DIR}/update-xray.sh" /usr/local/bin/update-xray.sh
    info "Installed: /usr/local/bin/update-xray.sh"
else
    warn "update-xray.sh not found in ${SCRIPT_DIR} — skipping"
fi

if [[ -f "${SCRIPT_DIR}/check-tunnel.sh" ]]; then
    install -m 755 "${SCRIPT_DIR}/check-tunnel.sh" /usr/local/bin/check-tunnel.sh
    info "Installed: /usr/local/bin/check-tunnel.sh"
else
    warn "check-tunnel.sh not found in ${SCRIPT_DIR} — skipping"
fi

# Create a system-wide alias for `check-tunnel`
log "Creating 'check-tunnel' shell alias..."
cat > /etc/profile.d/claude-remote-ssh.sh <<'PROFILE'
# Aliases for claude-remote-ssh helper scripts
alias check-tunnel="sudo /usr/local/bin/check-tunnel.sh"
PROFILE
chmod 644 /etc/profile.d/claude-remote-ssh.sh

# ------------------------------------------------------------------------------
# Step 7: Setup SSH directory and keys
# ------------------------------------------------------------------------------
log "Setting up SSH directory for $TARGET_USER..."
SSH_DIR="${USER_HOME}/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "${SSH_DIR}/authorized_keys"
chmod 600 "${SSH_DIR}/authorized_keys"
chown -R "${TARGET_USER}:${TARGET_USER}" "$SSH_DIR"

# Generate an Ed25519 keypair if none exists (for the server side, useful for
# diagnostics)
if [[ ! -f "${SSH_DIR}/id_ed25519" ]]; then
    log "Generating Ed25519 keypair for ${TARGET_USER}..."
    sudo -u "$TARGET_USER" ssh-keygen -t ed25519 -f "${SSH_DIR}/id_ed25519" -N "" -q
fi

# ------------------------------------------------------------------------------
# Step 8: Configure Pinggy Tunnel Service
# ------------------------------------------------------------------------------
log "Installing pinggy-tunnel.service..."
cat > /etc/systemd/system/pinggy-tunnel.service <<SERVICE_PINGGY
[Unit]
Description=Pinggy Reverse SSH Tunnel Watchdog
After=network-online.target xray.service
Wants=network-online.target
Requires=xray.service

[Service]
Type=simple
User=${TARGET_USER}
Group=${TARGET_USER}
EnvironmentFile=/etc/claude-remote-ssh/tunnel.env
ExecStart=/usr/local/bin/pinggy-auto.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE_PINGGY

systemctl daemon-reload
systemctl enable pinggy-tunnel.service
systemctl restart pinggy-tunnel.service

# ------------------------------------------------------------------------------
# Final summary
# ------------------------------------------------------------------------------
echo ""
echo "======================================================"
log "Server deployment completed successfully!"
echo "======================================================"
echo ""
echo "Status commands:"
echo "  sudo systemctl status xray"
echo "  sudo systemctl status pinggy-tunnel"
echo "  sudo journalctl -u pinggy-tunnel -f"
echo ""
echo "Helper commands (after re-login or 'source /etc/profile.d/claude-remote-ssh.sh'):"
echo "  check-tunnel                        Full chain health check"
echo "  sudo update-xray.sh \"vless://...\"   Replace Xray config with new VLESS URL"
echo ""
echo "Next steps:"
echo "  1. If not done: configure Xray with real VLESS credentials"
echo "       sudo update-xray.sh \"vless://YOUR_UUID@host:port?params#name\""
echo "     OR edit manually:"
echo "       sudo nano /usr/local/etc/xray/config.json"
echo "       sudo systemctl restart xray"
echo ""
echo "  2. Verify the full chain:"
echo "       check-tunnel"
echo ""
echo "  3. Add your desktop's public SSH key to:"
echo "       ${SSH_DIR}/authorized_keys"
echo "     From the desktop, run:"
echo "       type \$env:USERPROFILE\\.ssh\\id_ed25519.pub | ssh -p PORT user@HOST \"cat >> ~/.ssh/authorized_keys\""
echo ""
echo "  4. On the desktop, follow docs/03-desktop-setup.md"
echo "======================================================"
