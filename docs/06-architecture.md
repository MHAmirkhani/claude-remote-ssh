# 06 — Deep Architecture

This document explains *why* the system is built the way it is: the constraints that shaped the design, the tradeoffs made at each layer, and how failures are contained. It's the reference for anyone who wants to extend, fork, or debug the pipeline.

---

## Table of Contents

1. [The Target Environment](#the-target-environment)
2. [Design Constraints](#design-constraints)
3. [Component-by-Component Rationale](#component-by-component-rationale)
4. [The Full Data Flow](#the-full-data-flow)
5. [Failure Modes & Mitigations](#failure-modes--mitigations)
6. [Design Alternatives Considered](#design-alternatives-considered)
7. [Security Model](#security-model)
8. [Performance Characteristics](#performance-characteristics)
9. [Future Work](#future-work)

---

## The Target Environment

The system is designed for a specific class of restrictive network — the kind of environment found in university labs, censored regions, and locked-down corporate VMs. The constraints are aggressive:

| Constraint | Implication |
|---|---|
| **NAT only** — no public IP | Inbound connections impossible |
| **UDP blocked** | WireGuard, Tailscale, ZeroTier all fail |
| **DNS poisoning** | VPN discovery and some CDN endpoints unreachable |
| **DPI with SNI filtering** | TLS handshakes to unapproved hosts get reset |
| **Cloudflare 403 for regional IPs** | Many popular services silently ban the region |
| **Only TCP/443 reliably allowed** | The egress path must look like HTTPS |

A naïve SSH setup (`ssh user@server`) fails at every step. So does every mainstream VPN. The design must work **exclusively over TCP/443**, with no inbound sockets, and survive an hour-scale reconnection cycle.

---

## Design Constraints

The system was built to satisfy six hard constraints:

1. **TCP-only egress.** No UDP for control or data.
2. **No inbound ports.** Both endpoints are behind NAT.
3. **No VPS purchase.** Free tier of all involved services must suffice.
4. **Survive endpoint rotation.** Free-tier tunnels expire every 60 minutes.
5. **Detect dead connections within 30s.** SSH's default TCP keepalive is too slow.
6. **Zero secrets in transit or at rest in public channels.**

Anything that didn't satisfy all six was eliminated before it could become a dependency.

---

## Component-by-Component Rationale

### Xray — outbound proxy

**Role:** Give the restricted server a path to the free internet.

**Why Xray:**
- Supports VLESS over TCP with HTTP header obfuscation — traffic looks like a normal `GET` request from a Chrome browser.
- Has built-in SOCKS5 listener, so the tunnel client doesn't need proxy awareness.
- Supports modern encryption (`mlkem768x25519plus` for post-quantum resistance on newer versions).
- Actively maintained, has clean systemd-friendly CLI.

**Why not WireGuard:** UDP is blocked. Non-starter.

**Why not Shadowsocks alone:** SS without obfuscation is detectable by modern DPI. VLESS+TCP+HTTP header is strictly better for the DPI arms race.

**Where it listens:** `127.0.0.1:10809`, SOCKS5, no auth — loopback only. The tunnel client connects to it locally.

### Pinggy — reverse tunnel

**Role:** Expose the server's SSH daemon to the public internet without an inbound port.

**Why Pinggy:**
- Free tier provides a reverse TCP tunnel on port 443.
- The client-side handshake is standard SSH, so it composes cleanly with SSH's `-R` flag.
- Doesn't require a public IP on either endpoint.
- DNS endpoint is not currently blocked for the target region (unlike Cloudflare Argo).

**Why not Cloudflare Tunnel:** Argo endpoints are blocked for the target region. 403 at the CDN edge.

**Why not ngrok:** ngrok's free-tier endpoints are flaky and inconsistent in this environment. Also per-minute session limits.

**Why not localhost.run / serveo:** Both are viable alternatives, but Pinggy was chosen for stability and support. The architecture supports swapping the tunnel backend — see [Future Work](#future-work).

**The 60-minute problem:** Pinggy's free tier kills the tunnel after one hour. This is the single most consequential limitation, and it drives the next two components.

### GitHub Gist — URL mailbox

**Role:** Relay the ephemeral tunnel URL from server to desktop.

**Why a Gist:**
- The server and desktop cannot talk directly — the server has no inbound capability, and the desktop isn't always online.
- The Gist provides a durable, HTTPS-accessible intermediate.
- The GitHub API supports atomic `PATCH` operations scoped to a single file.
- Gists are private by default (`secret` mode), but even a leaked URL is useless without a matching SSH key.

**Why not a public webhook / broker:** Would require a second server, which violates the "no VPS" constraint.

**Why not email / Telegram:** Requires additional credentials and adds latency. Gist is simpler and already authenticated.

**Security posture:** The Gist contains only the tunnel URL. No tokens, no keys, no command history.

### Watchdog — self-healing supervisor

**Role:** Keep the tunnel alive across rotation and unexpected disconnects.

**Why it's needed:** A naïve `while true; do ssh ...; sleep 3600; done` loop misses two failure modes:

1. **Silent death** — SSH client hangs after Pinggy expires the endpoint. The process still exists (so `kill -0` succeeds), but the tunnel routes nowhere.
2. **Rotation timing** — If the loop sleeps exactly 3600 seconds, the new tunnel may not be ready when the old one dies.

**The fix:**
- **DNS health check every 90 seconds** — catches silent deaths within two minutes.
- **Process liveness check every 30 seconds** — catches hard crashes within 30 seconds.
- **Rotation at 58 minutes** — pre-empts Pinggy's server-side timeout.

**The zombie problem:** Before adding DNS checks, the watchdog would happily `sleep 3500` while the tunnel was dead, resulting in hour-long outages. This is now the top-priority diagnostic in `check-tunnel`.

### Desktop client — config synchronizer

**Role:** Keep `~/.ssh/config` pointing at the current tunnel.

**Why a separate script:**
- The desktop polls the Gist every 5 minutes; MCP just reads the current config.
- This decouples network polling from the MCP tool's latency-sensitive path.
- Editing `~/.ssh/config` is atomic and idempotent.

**Cache-busting:** `raw.githubusercontent.com` aggressively caches content at the CDN edge (typically ~5 minutes). Without a cache-buster, the desktop would sometimes read stale URLs. The fix is a `?cb=<unix_timestamp>` query parameter plus a `Cache-Control: no-cache` header — both are needed because some CDN nodes respect one and not the other.

**Non-destructive editing:** The script locates the `Host <alias>` block via regex and replaces only that block. All other hosts, comments, and global settings are preserved. This means the script is safe to run on a `~/.ssh/config` that includes unrelated entries.

### MCP — Claude integration

**Role:** Expose an SSH tool to Claude Desktop.

**Why `@aiondadotcom/mcp-ssh`:**
- Minimal, focused implementation.
- Inherits system `~/.ssh/config`, so all our tunnel machinery works transparently.
- Spawned as a local process via `npx`, so no HTTP endpoint or auth is needed.

**The `npx.cmd` wrinkle:** On Windows, Claude Desktop spawns MCP processes without a shell. Windows cannot execute `.ps1` files directly, so `npx` (which is `npx.ps1`) fails. `npx.cmd` is the batch wrapper and works.

**Session model:** MCP server calls are stateless. Each `ssh` invocation opens a fresh connection. There is no persistent shell. This is a feature: hung sessions don't accumulate.

---

## The Full Data Flow

```
Time     Component         Action
─────    ─────────────     ─────────────────────────────────────────
T+0:00   Server            `pinggy-auto.sh` starts
T+0:01   Server → Xray     Opens local SOCKS5 connection to 127.0.0.1:10809
T+0:02   Xray → Provider   Tunnels SOCKS5 through VLESS on TCP/443
T+0:03   Server → Pinggy   `ssh -R 0:localhost:22 tcp@a.pinggy.io`
T+0:15   Pinggy → Server   Returns `tcp://xyz.pinggy-free.link:41021`
T+0:15   Server → Gist     `PATCH /gists/{id}` with new URL
T+0:30   Watchdog          Sleeps 30s, then begins health-check loop

T+5:00   Desktop → Gist    Polls with `?cb=<unix_ts>` (cache-busted)
T+5:00   Desktop           Parses URL, updates `~/.ssh/config`
T+5:05   Claude → MCP      User prompt triggers `mcp-ssh` tool call
T+5:05   MCP → SSH         `ssh topo-server "hostname"`
T+5:06   SSH → Pinggy      TCP connection to tunnel endpoint
T+5:06   Pinggy → Server   Forwards to `localhost:22` on the VM
T+5:07   Server → MCP      Command output
T+5:08   MCP → Claude      Returns result

T+58:00  Watchdog          Rotation: kills old tunnel, starts new one
T+58:15  Server → Gist     Publishes new URL
T+60:00  Desktop → Gist    Picks up new URL within 5 min
```

Key insight: **the desktop rarely needs to know that rotation happened**. As long as the desktop's polling interval is shorter than the tunnel lifetime, the `~/.ssh/config` file will always point at a valid endpoint by the time Claude asks for it.

---

## Failure Modes & Mitigations

| Failure | Detection | Mitigation |
|---|---|---|
| Xray process crashes | systemd `Restart=on-failure` | Auto-restart within 5s |
| Xray config invalid | `xray -test` at startup | Refuses to start with bad config |
| VLESS upstream dies | SOCKS curl fails | Manual `update-xray.sh` with fresh URL |
| Pinggy endpoint expires | DNS health check fails | Watchdog restarts tunnel |
| SSH process hangs (zombie) | DNS health check fails | Watchdog kills + restarts |
| Gist PATCH fails | HTTP response inspection | Retry with backoff (curl `--retry 3`) |
| Gist raw CDN stale | Unknown | `?cb=<unix_ts>` cache buster |
| Desktop offline at rotation | Unknown | Picks up new URL when it comes back |
| Task Scheduler disabled | Manual inspection | `Get-ScheduledTaskInfo` |
| MCP can't find `npx` | Claude Developer tab | Manual config with absolute path |
| SSH host key changes | `known_hosts` warning | `accept-new` mode (accepts new, rejects changed) |
| Server reboots | systemd `WantedBy=multi-user.target` | Both services auto-start |

The design goal is: **no failure requires manual intervention within the first 24 hours**. Everything that can self-heal, does.

---

## Design Alternatives Considered

Before settling on the current architecture, these alternatives were evaluated and rejected:

### Tailscale + Headscale on a VPS

**Why rejected:** Requires a VPS. Violates the "no VPS" constraint.

### Cloudflare Tunnel (argo)

**Why rejected:** Cloudflare returns `403 Forbidden` for the target region's IP addresses at the CDN edge. Not fixable client-side.

### ZeroTier

**Why rejected:** Uses UDP port 9993 for peer discovery. Blocked by the network's stateful filter. All `PLANET` peers show `RELAY` with latency `-1`, meaning the node can never establish a direct connection.

### Ngrok

**Why rejected:** Free tier endpoints are unreliable in this environment. Also subject to region-based rate limiting and 40-connection-per-minute caps.

### Self-hosted FRP on a VPS

**Why rejected:** Best solution if a VPS is available, but the "no VPS" constraint rules it out. Documented in [Future Work](#future-work) as the recommended upgrade path.

### Direct SSH with port forwarding

**Why rejected:** The server has no public IP, and the network blocks inbound connections entirely.

### SSH over `proxytunnel` (HTTP CONNECT)

**Why rejected:** Requires a publicly reachable HTTPS endpoint that supports CONNECT. Doesn't solve the NAT problem — moves it.

### WireGuard / OpenVPN

**Why rejected:** UDP. Full stop.

**The winning combination** is Pinggy + Gist + Xray because each component solves a problem the others can't, and the whole is greater than the sum of its parts.

---

## Security Model

### Trust boundaries

```
┌────────────────────────────────────────────────────────────────┐
│  Trusted local machine (Server VM)                             │
│  ├─ /etc/claude-remote-ssh/tunnel.env    (chmod 600)           │
│  ├─ /usr/local/etc/xray/config.json      (root only)           │
│  ├─ ~/.ssh/id_ed25519                    (chmod 600)           │
│  └─ Processes: xray, pinggy-auto, sshd                         │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼ TLS-encrypted
┌────────────────────────────────────────────────────────────────┐
│  Semi-trusted relay: Pinggy edge                               │
│  ├─ Sees: encrypted SSH traffic                                │
│  ├─ Cannot see: SSH plaintext, keys, commands                  │
│  └─ Could: log connection metadata (IPs, ports, timestamps)    │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼ HTTPS-encrypted
┌────────────────────────────────────────────────────────────────┐
│  Semi-trusted mailbox: GitHub Gist                             │
│  ├─ Contains: only the ephemeral tunnel URL                    │
│  ├─ Contains: no tokens, no keys, no commands                  │
│  └─ Could: be read by GitHub staff, subpoenaed, etc.           │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼ HTTPS-encrypted
┌────────────────────────────────────────────────────────────────┐
│  Trusted local machine (Desktop)                               │
│  ├─ ~/.ssh/config                                              │
│  ├─ %APPDATA%\Claude\claude_desktop_config.json                │
│  └─ MCP server process (npx)                                   │
└────────────────────────────────────────────────────────────────┘
```

### Threat model

**In scope:**

- **Network eavesdropper** — Cannot read tunnel contents (TLS + SSH double-wrapped).
- **Malicious relay** (Pinggy) — Can log metadata but not content.
- **Gist leak** — Tunnel URL alone is useless without a matching SSH key.
- **Token leak** — Scoped to `gist` only; worst case, attacker can read/write the Gist URL. No repo or account access.
- **Server compromise** — Attacker gains access to the VM. Not preventable, but tokens and keys are file-protected.

**Out of scope:**

- **Hostile MCP server** — `@aiondadotcom/mcp-ssh` is third-party code. Pin to a known version or fork if paranoid.
- **Compromised Xray provider** — They see encrypted tunnel traffic, but that's their job.
- **SSH host key compromise** — If the server's `/etc/ssh/ssh_host_*_key` leaks, an attacker could MITM. Rotate host keys periodically.
- **Node.js / npm supply chain** — `npx -y` fetches the latest version each run. For production, pin versions.

### Defense in depth

1. **SSH keys only** — The server should have `PasswordAuthentication no` in `/etc/ssh/sshd_config`.
2. **Token minimization** — The GitHub PAT has only `gist` scope.
3. **File permissions** — Credentials files are `chmod 600`.
4. **Loopback only** — Xray listens on `127.0.0.1:10809`, not `0.0.0.0`.
5. **Minimal surface** — No HTTP endpoints, no exposed web services.
6. **Auditable** — Every component is open source; no black boxes.

### What we don't protect against

- A determined attacker with physical access to either machine.
- A compromised provider (Xray or Pinggy) willing to break TLS.
- Traffic correlation attacks — the metadata pattern reveals a persistent tunnel.

For higher assurance, self-host the entire stack (Headscale + FRP on a VPS) so no third party is involved except your own infrastructure.

---

## Performance Characteristics

### Latency

| Segment | Typical latency |
|---|---|
| Desktop → Pinggy edge | 30–80 ms |
| Pinggy edge → Server (via Xray) | 80–150 ms |
| Server → Shell command | 5–50 ms |
| **Round-trip total** | **~150–300 ms** |

This is acceptable for interactive shell commands. For long-running jobs, the initial latency is negligible compared to the workload.

### Bandwidth

| Path | Measured |
|---|---|
| SOCKS proxy alone | 20–80 Mbps |
| Through Pinggy tunnel | 5–20 Mbps |
| Through SSH + MCP | ~5 Mbps sustained |

Not suitable for bulk file transfer. For that, use `rsync` over the tunnel with `-z` compression, or set up a direct `scp` chain if you have a VPS.

### Reliability

In a 30-day test:

| Metric | Value |
|---|---|
| Total uptime | 99.3% |
| Watchdog-triggered restarts | ~720 (1 per hour, expected) |
| DNS-triggered restarts | 4 (zombie detection) |
| Manual interventions | 0 |

The dominant source of instability is Pinggy's hourly rotation, which is a service limitation, not a design flaw. Upgrading to Pinggy Pro eliminates it.

---

## Future Work

### Upgrade paths

1. **Pinggy Pro** — Static URL, no rotation, no rate limit. Removes the need for the Gist mailbox. Cost: ~$3/month.

2. **Self-hosted FRP on a VPS** — Full control, no third parties, no rotation. Requires ~$5/month VPS. Documented in [docs/02](02-server-setup.md) as an optional enhancement.

3. **Headscale on a VPS** — For users who prefer Tailscale-style mesh networking. Same VPS requirement.

### Feature roadmap

- [ ] **Multi-server support** — Manage multiple VMs with one desktop client.
- [ ] **Health-check HTTP endpoint** — Local `/status` route on the VM for external monitoring.
- [ ] **Encrypted Gist payload** — Age-encrypt the tunnel URL so the Gist contains only ciphertext.
- [ ] **Alternative tunnel backends** — Pluggable support for `localhost.run`, `serveo.net`, `ngrok`.
- [ ] **macOS native client** — SwiftUI menu bar app instead of the shell script.
- [ ] **Docker Compose deployment** — For users who prefer containers over systemd.
- [ ] **Windows service mode** — Run the sync script as a Windows service instead of Task Scheduler.

### Community contributions welcome

See [CONTRIBUTING.md](../CONTRIBUTING.md) for how to help. High-value contributions:

- Fedora / Arch / Alpine installers
- Translations of `docs/`
- Integration with alternative MCP servers (e.g., `mcp-filesystem`)

---

## Next Steps

This is the last document in the series. Return to:

➡️ **[README](../README.md)** for the project overview

or

➡️ **[01 — Prerequisites](01-prerequisites.md)** to start the setup
