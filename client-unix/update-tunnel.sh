#!/usr/bin/env bash
# ==============================================================================
# claude-remote-ssh: macOS / Linux Desktop SSH Synchronizer
# ==============================================================================

set -euo pipefail

GIST_RAW_URL="${1:-}"
SSH_USER="${2:-ubuntu}"
HOST_ALIAS="${3:-topo-server}"

if [[ -z "$GIST_RAW_URL" ]]; then
    echo "Usage: $0 <GIST_RAW_URL> [SSH_USER] [HOST_ALIAS]"
    exit 1
fi

CACHE_BUSTER=$(date +%s)
FULL_URL="${GIST_RAW_URL}?cb=${CACHE_BUSTER}"

TUNNEL_ADDR=$(curl -sS -H "Cache-Control: no-cache" "$FULL_URL" | tr -d '[:space:]')

if [[ -z "$TUNNEL_ADDR" || "$TUNNEL_ADDR" == "initial" ]]; then
    echo "[i] Gist mailbox uninitialized. Skipping."
    exit 0
fi

CLEAN_ADDR="${TUNNEL_ADDR#tcp://}"
NEW_HOST="${CLEAN_ADDR%%:*}"
NEW_PORT="${CLEAN_ADDR##*:}"

SSH_DIR="${HOME}/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
CONFIG_FILE="${SSH_DIR}/config"
touch "$CONFIG_FILE"

# Temporary file for atomic rewrite
TMP_CONF=$(mktemp)

# Python snippet to safely replace or append the Host block non-destructively
python3 - <<PYEOF "$CONFIG_FILE" "$TMP_CONF" "$HOST_ALIAS" "$NEW_HOST" "$SSH_USER" "$NEW_PORT"
import sys, re

conf_path, tmp_path, alias, host, user, port = sys.argv[1:7]
with open(conf_path, 'r') as f:
    content = f.read()

new_block = f"""Host {alias}
    HostName {host}
    User {user}
    Port {port}
    AddressFamily inet
    StrictHostKeyChecking accept-new
    ServerAliveInterval 60
    TCPKeepAlive yes"""

pattern = rf"(?ms)(^|\n)Host\s+{re.escape(alias)}\s*(\n(?:[ \t]+[^\n]*\n?)*)"

if re.search(pattern, content):
    updated = re.sub(pattern, rf"\1{new_block}", content)
else:
    updated = (content.rstrip() + "\n\n" + new_block).strip() + "\n"

with open(tmp_path, 'w') as f:
    f.write(updated)
PYEOF

mv "$TMP_CONF" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
echo "[+] Updated SSH alias '${HOST_ALIAS}' -> ${NEW_HOST}:${NEW_PORT}"