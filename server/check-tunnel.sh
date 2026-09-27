#!/usr/bin/env bash
# ==============================================================================
# check-tunnel.sh — Full chain health check
# Verifies: Xray → SOCKS → Pinggy → DNS → Gist
# Usage: check-tunnel
# ==============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

OK="${GREEN}[OK]${NC}"
FAIL="${RED}[FAIL]${NC}"
WARN="${YELLOW}[WARN]${NC}"

URL_FILE="/tmp/pinggy_url.txt"

echo ""
echo -e "${BOLD}=====================================================${NC}"
echo -e "${BOLD}  Tunnel Health Check${NC}"
echo -e "${BOLD}=====================================================${NC}"
echo ""

echo -e "${CYAN}[1/6] Xray service${NC}"
if systemctl is-active --quiet xray; then
    UPTIME=$(systemctl show xray -p ActiveEnterTimestamp --value)
    echo -e "  $OK  Xray is running (since $UPTIME)"
    XRAY_OK=1
else
    echo -e "  $FAIL  Xray is NOT running"
    XRAY_OK=0
fi

echo ""
echo -e "${CYAN}[2/6] SOCKS proxy (127.0.0.1:10809)${NC}"
PROXY_IP=$(curl -x socks5h://127.0.0.1:10809 -s --max-time 15 https://api.ipify.org 2>/dev/null || echo "")
if [[ -n "$PROXY_IP" ]]; then
    echo -e "  $OK  Proxy works — public IP: ${BOLD}$PROXY_IP${NC}"
    PROXY_OK=1
else
    echo -e "  $FAIL  Proxy NOT working"
    echo -e "        Run: ${YELLOW}sudo update-xray.sh \"vless://...\"${NC} with a fresh URL"
    PROXY_OK=0
fi

echo ""
echo -e "${CYAN}[3/6] Pinggy tunnel service${NC}"
if systemctl is-active --quiet pinggy-tunnel; then
    echo -e "  $OK  pinggy-tunnel is running"
    PINGGY_OK=1
else
    echo -e "  $FAIL  pinggy-tunnel is NOT running"
    PINGGY_OK=0
fi

echo ""
echo -e "${CYAN}[4/6] Tunnel process${NC}"
TUNNEL_PID=$(ps aux | grep -E "ssh.*-R 0:localhost:22.*pinggy" | grep -v grep | awk '{print $2}' | head -1)
if [[ -n "$TUNNEL_PID" ]]; then
    ELAPSED=$(ps -o etime= -p "$TUNNEL_PID" 2>/dev/null | xargs)
    echo -e "  $OK  SSH tunnel alive (PID $TUNNEL_PID, uptime $ELAPSED)"
    TUNNEL_OK=1
else
    echo -e "  $FAIL  No SSH tunnel process found"
    TUNNEL_OK=0
fi

echo ""
echo -e "${CYAN}[5/6] Current tunnel URL${NC}"
if [[ -f "$URL_FILE" ]]; then
    TUNNEL_URL=$(cat "$URL_FILE")
    echo -e "  $OK  URL: ${BOLD}$TUNNEL_URL${NC}"

    HOST=$(echo "$TUNNEL_URL" | sed 's|tcp://||' | cut -d: -f1)
    if getent hosts "$HOST" > /dev/null 2>&1; then
        echo -e "  $OK  DNS resolution works"
        DNS_OK=1
    else
        echo -e "  $FAIL  DNS resolution FAILED (tunnel is dead on Pinggy side)"
        DNS_OK=0
    fi
else
    echo -e "  $WARN  $URL_FILE not found"
    DNS_OK=0
fi

echo ""
echo -e "${CYAN}[6/6] GitHub Gist${NC}"
if [[ -f /etc/claude-remote-ssh/tunnel.env ]]; then
    # shellcheck disable=SC1091
    source /etc/claude-remote-ssh/tunnel.env

    if [[ -n "${GITHUB_TOKEN:-}" && -n "${GIST_ID:-}" ]]; then
        GIST_CONTENT=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" \
            "https://api.github.com/gists/${GIST_ID}" | grep -oP '"content":\s*"\K[^"]+' | head -1)

        if [[ -n "$GIST_CONTENT" ]]; then
            echo -e "  $OK  Gist URL: ${BOLD}$GIST_CONTENT${NC}"
            if [[ -f "$URL_FILE" ]] && [[ "$GIST_CONTENT" == "$(cat "$URL_FILE")" ]]; then
                echo -e "  $OK  Gist matches local URL"
                GIST_OK=1
            else
                echo -e "  $WARN  Gist differs from local URL"
                GIST_OK=0
            fi
        else
            echo -e "  $FAIL  Could not read Gist"
            GIST_OK=0
        fi
    else
        echo -e "  $FAIL  TOKEN or GIST_ID missing in tunnel.env"
        GIST_OK=0
    fi
else
    echo -e "  $FAIL  /etc/claude-remote-ssh/tunnel.env not found"
    GIST_OK=0
fi

echo ""
echo -e "${BOLD}=====================================================${NC}"
echo -e "${BOLD}  Summary${NC}"
echo -e "${BOLD}=====================================================${NC}"
echo ""

TOTAL=0; PASSED=0
check_result() {
    TOTAL=$((TOTAL + 1))
    if [[ "$2" == "1" ]]; then
        PASSED=$((PASSED + 1))
        echo -e "  $OK  $1"
    else
        echo -e "  $FAIL  $1"
    fi
}

check_result "Xray service"  "$XRAY_OK"
check_result "SOCKS proxy"    "$PROXY_OK"
check_result "Pinggy service" "$PINGGY_OK"
check_result "Tunnel process" "$TUNNEL_OK"
check_result "DNS health"     "${DNS_OK:-0}"
check_result "Gist sync"      "$GIST_OK"

echo ""
if [[ "$PASSED" == "$TOTAL" ]]; then
    echo -e "  ${GREEN}${BOLD}All checks passed! System is fully operational.${NC}"
else
    echo -e "  ${YELLOW}${BOLD}$PASSED/$TOTAL checks passed.${NC}"
    echo ""
    echo -e "  ${CYAN}Troubleshooting hints:${NC}"
    echo -e "    • SOCKS proxy failed → ${YELLOW}sudo update-xray.sh \"vless://...\"${NC}"
    echo -e "    • Pinggy service failed → ${YELLOW}sudo systemctl restart pinggy-tunnel${NC}"
    echo -e "    • Tunnel process missing → ${YELLOW}sudo systemctl restart pinggy-tunnel${NC}"
    echo -e "    • DNS health failed → tunnel expired; watchdog will rotate"
    echo -e "    • Gist sync failed → check ${YELLOW}journalctl -u pinggy-tunnel${NC}"
fi
echo ""
