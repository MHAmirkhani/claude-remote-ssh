#!/usr/bin/env bash
# ==============================================================================
# Pinggy Auto-Tunnel & Resilient Watchdog Daemon
# Manages SSH reverse tunnel through Xray SOCKS5 proxy and synchronizes
# the ephemeral URL to a private GitHub Gist mailbox.
#
# Features:
#   - Process liveness check (kill -0)
#   - DNS health check (detects stale tunnels that zombie processes hide)
#   - 58-minute rotation for Pinggy free tier
#   - Graceful shutdown via trap
# ==============================================================================

set -uo pipefail

# Load environment configuration if available
if [[ -f /etc/claude-remote-ssh/tunnel.env ]]; then
    # shellcheck disable=SC1091
    source /etc/claude-remote-ssh/tunnel.env
fi

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GIST_ID="${GIST_ID:-}"
GIST_FILENAME="${GIST_FILENAME:-topo_tunnel.txt}"
SOCKS_PROXY="${SOCKS_PROXY:-127.0.0.1:10809}"

LOG_FILE="/tmp/pinggy_output.log"
PID_FILE="/tmp/pinggy_tunnel.pid"
URL_FILE="/tmp/pinggy_url.txt"

# Health check interval and rotation interval (seconds)
HEALTH_CHECK_INTERVAL=90
ROTATION_INTERVAL=3480   # 58 minutes

if [[ -z "$GITHUB_TOKEN" || -z "$GIST_ID" ]]; then
    echo "[$(date -u)] [x] Missing mandatory GITHUB_TOKEN or GIST_ID environment variables." >&2
    exit 1
fi

publish_url() {
    local target_url="$1"
    local json_payload
    json_payload=$(jq -n --arg file "$GIST_FILENAME" --arg content "$target_url" \
        '{"files": {($file): {"content": $content}}}')

    local response
    response=$(curl -sS --max-time 15 --retry 3 -X PATCH \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        "https://api.github.com/gists/${GIST_ID}" 2>&1)

    if echo "$response" | grep -q '"id":'; then
        echo "[$(date -u)] [+] Successfully published tunnel endpoint: $target_url"
        return 0
    else
        echo "[$(date -u)] [!] Failed updating Gist: $response" >&2
        return 1
    fi
}

stop_tunnel() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
    fi
    rm -f "$URL_FILE"
}

cleanup() {
    echo "[$(date -u)] [i] Shutting down watchdog and child tunnels..."
    stop_tunnel
    exit 0
}

trap cleanup SIGTERM SIGINT SIGHUP EXIT

start_tunnel() {
    stop_tunnel
    echo "[$(date -u)] [i] Establishing outbound tunnel via ${SOCKS_PROXY}..."
    : > "$LOG_FILE"

    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ServerAliveInterval=20 \
        -o ServerAliveCountMax=3 \
        -o ConnectTimeout=15 \
        -o "ProxyCommand=nc -X 5 -x ${SOCKS_PROXY} %h %p" \
        -p 443 \
        -R 0:localhost:22 \
        tcp@a.pinggy.io > "$LOG_FILE" 2>&1 &

    local tunnel_pid=$!
    echo "$tunnel_pid" > "$PID_FILE"

    # Poll log file for endpoint string (up to 25 seconds)
    local elapsed=0
    local parsed_url=""
    while [[ $elapsed -lt 25 ]]; do
        sleep 2
        elapsed=$((elapsed + 2))
        parsed_url=$(grep -oE 'tcp://[a-zA-Z0-9.-]+\.pinggy(-free)?\.link:[0-9]+' "$LOG_FILE" | head -n 1 || true)
        if [[ -n "$parsed_url" ]]; then
            break
        fi
    done

    if [[ -n "$parsed_url" ]]; then
        echo "$parsed_url" > "$URL_FILE"
        publish_url "$parsed_url"
        return 0
    fi

    echo "[$(date -u)] [x] Could not extract tunnel URL from log within timeout. Log excerpt:" >&2
    tail -n 20 "$LOG_FILE" >&2
    return 1
}

# --- Health Check ---
# Returns 0 if tunnel URL is resolvable, 1 otherwise.
health_check() {
    if [[ ! -f "$URL_FILE" ]]; then
        return 1
    fi

    local url host
    url=$(cat "$URL_FILE" 2>/dev/null || true)
    [[ -z "$url" ]] && return 1

    host=$(echo "$url" | sed 's|tcp://||' | cut -d: -f1)

    if getent hosts "$host" > /dev/null 2>&1; then
        return 0
    fi

    echo "[$(date -u)] [!] Health check FAILED — DNS for '$host' does not resolve."
    return 1
}

# --- Main Supervisor Loop ---
START_TIME=$(date +%s)
start_tunnel || true

LAST_HEALTH_CHECK=$(date +%s)

while true; do
    sleep 30

    # --- Liveness check ---
    if [[ -f "$PID_FILE" ]]; then
        PID=$(cat "$PID_FILE" 2>/dev/null || true)
        if [[ -z "$PID" ]] || ! kill -0 "$PID" 2>/dev/null; then
            echo "[$(date -u)] [!] Tunnel process died. Restarting immediately..."
            start_tunnel || true
            START_TIME=$(date +%s)
            LAST_HEALTH_CHECK=$(date +%s)
            continue
        fi
    else
        start_tunnel || true
        START_TIME=$(date +%s)
        LAST_HEALTH_CHECK=$(date +%s)
        continue
    fi

    # --- DNS health check (every HEALTH_CHECK_INTERVAL seconds) ---
    NOW=$(date +%s)
    if (( NOW - LAST_HEALTH_CHECK >= HEALTH_CHECK_INTERVAL )); then
        LAST_HEALTH_CHECK=$NOW
        if ! health_check; then
            echo "[$(date -u)] [!] Tunnel is unhealthy (stale DNS). Restarting..."
            start_tunnel || true
            START_TIME=$(date +%s)
            continue
        fi
    fi

    # --- Rotation (every ROTATION_INTERVAL seconds) ---
    if (( NOW - START_TIME >= ROTATION_INTERVAL )); then
        echo "[$(date -u)] [i] 58-minute rotation limit reached. Refreshing tunnel..."
        start_tunnel || true
        START_TIME=$(date +%s)
        LAST_HEALTH_CHECK=$(date +%s)
    fi
done
