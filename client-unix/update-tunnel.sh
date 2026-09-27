#!/usr/bin/env bash
# ==============================================================================
# claude-remote-ssh: macOS / Linux Desktop SSH Synchronizer
#
# Usage: ./update-tunnel.sh <GIST_RAW_URL> [SSH_USER] [HOST_ALIAS]
# Default: ./update-tunnel.sh <URL> user topo-server
#
# Behavior:
#   - Fetches tunnel endpoint from GitHub Gist (with cache-busting)
#   - Non-destructively updates the matching Host block in ~/.ssh/config
#   - Preserves all other host entries and comments
# ==============================================================================

set -uo pipefail

GIST_RAW_URL="${1:-}"
SSH_USER="${2:-user}"
HOST_ALIAS="${3:-topo-server}"

# --- Validate input ---
if [[ -z "$GIST_RAW_URL" ]]; then
    echo "Usage: $0 <GIST_RAW_URL> [SSH_USER] [HOST_ALIAS]" >&2
    echo "Example: $0 'https://gist.githubusercontent.com/USER/ID/raw/topo_tunnel.txt' user topo-server" >&2
    exit 1
fi

# --- Fetch endpoint from Gist (with cache busting) ---
CACHE_BUSTER=$(date +%s)
FULL_URL="${GIST_RAW_URL}?cb=${CACHE_BUSTER}"

TUNNEL_ADDR=$(curl -sS --max-time 20 --retry 3 -H "Cache-Control: no-cache" -H "Pragma: no-cache" "$FULL_URL" 2>/dev/null | tr -d '[:space:]')

if [[ -z "$TUNNEL_ADDR" ]]; then
    echo "[!] Failed to fetch tunnel address from Gist (empty response)." >&2
    exit 1
fi

if [[ "$TUNNEL_ADDR" == "initial" ]]; then
    echo "[i] Gist mailbox is uninitialized. Waiting for server to publish..." >&2
    exit 0
fi

# --- Parse tcp://host:port ---
CLEAN_ADDR="${TUNNEL_ADDR#tcp://}"
NEW_HOST="${CLEAN_ADDR%%:*}"
NEW_PORT="${CLEAN_ADDR##*:}"

# Validate host and port
if [[ -z "$NEW_HOST" || -z "$NEW_PORT" || "$NEW_HOST" == "$NEW_PORT" ]]; then
    echo "[!] Malformed tunnel address: $TUNNEL_ADDR" >&2
    exit 1
fi

if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || (( NEW_PORT < 1 || NEW_PORT > 65535 )); then
    echo "[!] Invalid port number: $NEW_PORT" >&2
    exit 1
fi

# --- Prepare SSH config path ---
SSH_DIR="${HOME}/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

CONFIG_FILE="${SSH_DIR}/config"
touch "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# --- Check if we need to update at all (early exit) ---
if grep -qE "^\s*Host\s+${HOST_ALIAS}\s*$" "$CONFIG_FILE" 2>/dev/null; then
    # Extract the block for this alias and check current HostName
    CURRENT_HOST=$(awk -v alias="$HOST_ALIAS" '
        $1 == "Host" && $2 == alias { in_block=1; next }
        in_block && $1 == "Host" { exit }
        in_block && $1 == "HostName" { print $2; exit }
    ' "$CONFIG_FILE")

    CURRENT_PORT=$(awk -v alias="$HOST_ALIAS" '
        $1 == "Host" && $2 == alias { in_block=1; next }
        in_block && $1 == "Host" { exit }
        in_block && $1 == "Port" { print $2; exit }
    ' "$CONFIG_FILE")

    if [[ "$CURRENT_HOST" == "$NEW_HOST" && "$CURRENT_PORT" == "$NEW_PORT" ]]; then
        echo "[+] Tunnel configuration for '${HOST_ALIAS}' is current (${NEW_HOST}:${NEW_PORT})."
        exit 0
    fi
fi

# --- Update config file non-destructively ---
TMP_CONF=$(mktemp)
trap 'rm -f "$TMP_CONF"' EXIT

# Prefer python3 for robust parsing; fall back to awk if unavailable
if command -v python3 > /dev/null 2>&1; then
    python3 - "$CONFIG_FILE" "$TMP_CONF" "$HOST_ALIAS" "$NEW_HOST" "$SSH_USER" "$NEW_PORT" <<'PYEOF'
import sys, re

conf_path, tmp_path, alias, host, user, port = sys.argv[1:7]

try:
    with open(conf_path, 'r', encoding='utf-8') as f:
        content = f.read()
except FileNotFoundError:
    content = ""

new_block = f"""Host {alias}
    HostName {host}
    User {user}
    Port {port}
    AddressFamily inet
    StrictHostKeyChecking accept-new
    ServerAliveInterval 60
    TCPKeepAlive yes"""

# Match `Host <alias>` line followed by indented options until the next Host or EOF
pattern = rf"(?ms)(^|\n)Host\s+{re.escape(alias)}\s*(\n(?:[ \t]+[^\n]*\n?)*)"

if re.search(pattern, content):
    updated = re.sub(pattern, rf"\g<1>{new_block}\n", content)
else:
    updated = (content.rstrip() + "\n\n" + new_block + "\n").lstrip("\n")

with open(tmp_path, 'w', encoding='utf-8') as f:
    f.write(updated)
PYEOF
else
    # awk fallback (works on macOS and Linux without Python)
    awk -v alias="$HOST_ALIAS" -v host="$NEW_HOST" -v user="$SSH_USER" -v port="$NEW_PORT" '
    BEGIN {
        new_block = "Host " alias "\n    HostName " host "\n    User " user "\n    Port " port "\n    AddressFamily inet\n    StrictHostKeyChecking accept-new\n    ServerAliveInterval 60\n    TCPKeepAlive yes"
        in_block = 0
        found = 0
    }
    {
        if ($1 == "Host" && $2 == alias) {
            if (!found) {
                print new_block
                found = 1
            }
            in_block = 1
            next
        }
        if (in_block && $1 == "Host") {
            in_block = 0
        }
        if (!in_block) {
            print
        }
    }
    END {
        if (!found) {
            print ""
            print new_block
        }
    }
    ' "$CONFIG_FILE" > "$TMP_CONF"
fi

# Atomic replace
mv "$TMP_CONF" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

echo "[+] Updated SSH alias '${HOST_ALIAS}' -> ${NEW_HOST}:${NEW_PORT}"
