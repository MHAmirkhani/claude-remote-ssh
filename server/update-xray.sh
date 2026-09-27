#!/usr/bin/env bash
# ==============================================================================
# update-xray.sh — Generate Xray config from a VLESS URL
# Usage: sudo update-xray.sh "vless://UUID@host:port?params#name"
# ==============================================================================

set -euo pipefail

CONFIG_PATH="/usr/local/etc/xray/config.json"
BACKUP_DIR="/usr/local/etc/xray/backups"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1" >&2; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then err "Must be run as root (use sudo)."; exit 1; fi
if [[ $# -lt 1 ]]; then echo "Usage: sudo $0 \"vless://UUID@host:port?params#name\""; exit 1; fi

VLESS_URL="$1"
[[ ! "$VLESS_URL" =~ ^vless:// ]] && { err "URL must start with vless://"; exit 1; }

info "Parsing VLESS URL..."

TMP="${VLESS_URL#vless://}"
TMP="${TMP%%#*}"
USERINFO="${TMP%%@*}"
ADDRESS_PART="${TMP#*@}"

if [[ "$ADDRESS_PART" == *"?"* ]]; then
    HOST_PORT="${ADDRESS_PART%%\?*}"
    QUERY="${ADDRESS_PART#*\?}"
else
    HOST_PORT="$ADDRESS_PART"
    QUERY=""
fi

HOST="${HOST_PORT%%:*}"
PORT="${HOST_PORT##*:}"
UUID="$USERINFO"

[[ -z "$UUID" || -z "$HOST" || -z "$PORT" ]] && { err "Parse failed"; exit 1; }

log "  UUID: $UUID"
log "  Host: $HOST"
log "  Port: $PORT"

ENCRYPTION="none"; SECURITY="none"; NETWORK="tcp"; HEADER_TYPE="none"
PATH_PARAM="/"; SNI_HOST=""; FLOW=""

IFS='&' read -ra PARAMS <<< "$QUERY"
for PARAM in "${PARAMS[@]}"; do
    KEY="${PARAM%%=*}"
    VALUE="${PARAM#*=}"
    VALUE=$(printf '%b' "${VALUE//%/\\x}")
    case "$KEY" in
        encryption) ENCRYPTION="$VALUE" ;;
        security)   SECURITY="$VALUE" ;;
        type)       NETWORK="$VALUE" ;;
        headerType) HEADER_TYPE="$VALUE" ;;
        path)       PATH_PARAM="$VALUE" ;;
        host)       SNI_HOST="$VALUE" ;;
        flow)       FLOW="$VALUE" ;;
    esac
done

[[ -z "$SNI_HOST" ]] && SNI_HOST="$HOST"

log "  Encryption: $ENCRYPTION"
log "  Network:    $NETWORK"
log "  Header:     $HEADER_TYPE"
log "  Host (SNI): $SNI_HOST"
log "  Path:       $PATH_PARAM"
[[ -n "$FLOW" ]] && log "  Flow:       $FLOW"

info "Building Xray config..."

FLOW_LINE=""
[[ -n "$FLOW" ]] && FLOW_LINE=",
                \"flow\": \"$FLOW\""

case "$NETWORK" in
    tcp)
        if [[ "$HEADER_TYPE" == "http" ]]; then
            STREAM_SETTINGS=$(cat <<EOF
        "network": "tcp",
        "security": "$SECURITY",
        "tcpSettings": {
          "header": {
            "type": "http",
            "request": {
              "version": "1.1",
              "method": "GET",
              "path": ["$PATH_PARAM"],
              "headers": {
                "Host": ["$SNI_HOST"],
                "User-Agent": ["Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"]
              }
            }
          }
        }
EOF
)
        else
            STREAM_SETTINGS=$(cat <<EOF
        "network": "tcp",
        "security": "$SECURITY"
EOF
)
        fi
        ;;
    ws)
        STREAM_SETTINGS=$(cat <<EOF
        "network": "ws",
        "security": "$SECURITY",
        "wsSettings": { "path": "$PATH_PARAM", "host": "$SNI_HOST" }
EOF
)
        ;;
    grpc)
        STREAM_SETTINGS=$(cat <<EOF
        "network": "grpc",
        "security": "$SECURITY",
        "grpcSettings": { "serviceName": "$PATH_PARAM" }
EOF
)
        ;;
    *) err "Unsupported network: $NETWORK"; exit 1 ;;
esac

cat > "$CONFIG_PATH" <<EOF
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
            "address": "$HOST",
            "port": $PORT,
            "users": [
              {
                "id": "$UUID",
                "encryption": "$ENCRYPTION"$FLOW_LINE
              }
            ]
          }
        ]
      },
      "streamSettings": {
$STREAM_SETTINGS
      },
      "mux": { "enabled": false }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["socks-for-ssh"], "outboundTag": "proxy" },
      { "type": "field", "outboundTag": "direct", "ip": ["geoip:private"] }
    ]
  },
  "stats": {}
}
EOF

log "Config written to $CONFIG_PATH"

mkdir -p "$BACKUP_DIR"
if [[ -f "$CONFIG_PATH" ]]; then
    cp "$CONFIG_PATH" "$BACKUP_DIR/config.$(date +%Y%m%d-%H%M%S).json"
fi

info "Validating config..."
if ! /usr/local/bin/xray -test -config "$CONFIG_PATH" > /dev/null 2>&1; then
    err "Config validation FAILED:"
    /usr/local/bin/xray -test -config "$CONFIG_PATH"
    exit 1
fi
log "Config is valid."

info "Restarting Xray..."
systemctl restart xray
sleep 3

if systemctl is-active --quiet xray; then
    log "Xray restarted successfully."
else
    err "Xray failed to restart. Check: journalctl -u xray"
    exit 1
fi

info "Testing SOCKS proxy..."
sleep 1
PUBLIC_IP=$(curl -x socks5h://127.0.0.1:10809 -s --max-time 15 https://api.ipify.org || echo "")

if [[ -n "$PUBLIC_IP" ]]; then
    log "Proxy works! Public IP: $PUBLIC_IP"
else
    warn "Proxy test failed. Check Xray logs."
fi

echo ""
log "Done!"
echo ""
echo "Next steps:"
echo "  1. Restart Pinggy tunnel:"
echo "       sudo systemctl restart pinggy-tunnel"
echo "  2. Verify full chain:"
echo "       check-tunnel"
echo ""
