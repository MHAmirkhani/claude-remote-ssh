# Security Policy

`claude-remote-ssh` bridges a firewalled server and a desktop AI assistant over a chain of third-party relays. Security is not a feature — it's the foundation. This document describes the threat model, the mitigations in place, and how to report vulnerabilities.

---

## Table of Contents

1. [Supported Versions](#supported-versions)
2. [Threat Model](#threat-model)
3. [Security Architecture](#security-architecture)
4. [Mitigations by Component](#mitigations-by-component)
5. [User Responsibilities](#user-responsibilities)
6. [Known Limitations](#known-limitations)
7. [Reporting a Vulnerability](#reporting-a-vulnerability)
8. [Disclosure Policy](#disclosure-policy)
9. [Acknowledgments](#acknowledgments)

---

## Supported Versions

Security updates are provided for the following versions:

| Version | Supported | Notes |
|---|---|---|
| `1.0.x` | ✅ Yes | Current stable release |
| `< 1.0` | ❌ No | Pre-release; not recommended |
| `main` branch | ✅ Yes | Development; use at your own risk |

If you're running a fork with modifications, apply upstream security patches manually or rebase regularly.

---

## Threat Model

### In-Scope Threats

The following adversaries are explicitly considered:

| Adversary | Capability | Impact |
|---|---|---|
| **Network eavesdropper** | Passive packet capture on the route between desktop, Pinggy, and server | Cannot read tunnel contents (double-wrapped TLS + SSH) |
| **Malicious relay** (Pinggy) | Terminates TLS at the edge | Cannot read SSH plaintext; can log connection metadata |
| **Gist reader** | Reads the ephemeral tunnel URL from GitHub | Useless without a matching SSH private key |
| **Token leaker** | Obtains the GitHub PAT | Can read/write one Gist; no repo or account access |
| **Hostile MCP server** | Malicious replacement for `@aiondadotcom/mcp-ssh` | Would gain code execution as the desktop user |
| **Compromised provider** | Xray provider inspects proxy traffic | Sees encrypted SSH payload, not plaintext |
| **Physical access attacker** | Direct access to server or desktop | Can read credentials from disk (mitigated by file permissions) |

### Out-of-Scope Threats

The following are explicitly **not** defended against:

- **Compromised kernel or rootkit** on either endpoint
- **Global passive adversary** performing traffic correlation across multiple links
- **Quantum adversary** capable of breaking TLS 1.3 or Ed25519
- **Supply chain compromise** of Node.js, `npx`, or the npm registry
- **Nation-state hardware implants**
- **User error** — e.g., pasting a token into a public channel

If your threat model includes any of the above, this project is not appropriate for you. Consider self-hosting all components on a hardened VPS with reproducible builds.

### Assumptions

- The target server is **owned and operated by you** — not a shared or unauthorized system.
- The desktop is a **trusted device** under your physical control.
- The Xray provider is **honest-but-curious** — they don't actively try to break your traffic, but they may log metadata.
- GitHub is **not actively hostile** to your account.

---

## Security Architecture

### Trust Boundaries

```
┌─────────────────────────────────────────────────────────────────────┐
│  TRUSTED: Server VM                                                 │
│  ├─ /etc/claude-remote-ssh/tunnel.env     chmod 600, owner-only     │
│  ├─ /usr/local/etc/xray/config.json       root-only, 644           │
│  ├─ ~/.ssh/id_ed25519                     chmod 600                 │
│  ├─ ~/.ssh/authorized_keys                chmod 600                 │
│  └─ systemd services: xray, pinggy-tunnel                           │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼ TLS 1.3 (via Xray)
┌─────────────────────────────────────────────────────────────────────┐
│  SEMI-TRUSTED: Pinggy Edge                                          │
│  ├─ Terminates outer TLS                                            │
│  ├─ Cannot read inner SSH                                           │
│  └─ May log: source IP, tunnel ID, byte counts, timestamps         │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼ HTTPS / TLS 1.3
┌─────────────────────────────────────────────────────────────────────┐
│  SEMI-TRUSTED: GitHub Gist                                          │
│  ├─ Stores ONLY the ephemeral tunnel URL                            │
│  ├─ Never contains tokens, keys, or commands                        │
│  └─ May be read by GitHub, subpoenaed, or accidentally leaked       │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼ HTTPS / TLS 1.3
┌─────────────────────────────────────────────────────────────────────┐
│  TRUSTED: Desktop                                                   │
│  ├─ ~/.ssh/config                          chmod 600                 │
│  ├─ ~/.claude-remote-ssh/update-tunnel.ps1                          │
│  ├─ %APPDATA%\Claude\claude_desktop_config.json                     │
│  └─ MCP server process (spawned via npx)                            │
└─────────────────────────────────────────────────────────────────────┘
```

### Defense in Depth

The pipeline applies the following layered defenses:

1. **Transport encryption (outer):** TLS 1.3 between the server and Xray provider, then between Xray and Pinggy, then between the desktop and Pinggy.
2. **Transport encryption (inner):** SSH (Ed25519 keys, ChaCha20-Poly1305 or AES-GCM) inside the tunnel.
3. **Authentication (proxy):** VLESS UUID + optional encryption (ML-KEM-768 on Xray 25+).
4. **Authentication (SSH):** Ed25519 public-key cryptography. Password auth should be disabled server-side.
5. **Authorization (GitHub):** Token scoped to `gist` only — no repo, no admin, no user data.
6. **File permissions:** All credential files use `chmod 600`.
7. **Network binding:** Xray listens only on `127.0.0.1:10809` — not exposed externally.
8. **Process isolation:** systemd unit with `NoNewPrivileges=true` and minimal capabilities.
9. **CI enforcement:** GitHub Actions fails on any committed `ghp_*` pattern.

---

## Mitigations by Component

### GitHub Access Tokens

**Requirements:**

- Only the `gist` scope is permitted.
- Never grant `repo`, `admin:org`, `user`, or `delete_repo`.
- Store in `/etc/claude-remote-ssh/tunnel.env` with `chmod 600`, owned by the SSH user.
- Never embed tokens in shell history, log files, or Git repositories.

**Verification:**

```bash
source /etc/claude-remote-ssh/tunnel.env
curl -sI -H "Authorization: token ${GITHUB_TOKEN}" https://api.github.com/user \
  | grep -i "x-oauth-scopes"
# Expected: x-oauth-scopes: gist
```

**Rotation:**

- Rotate every 90 days, or immediately if compromised.
- Revoke old tokens at [github.com/settings/tokens](https://github.com/settings/tokens).
- To rotate without downtime:
  1. Generate a new token.
  2. Update `/etc/claude-remote-ssh/tunnel.env`.
  3. `sudo systemctl restart pinggy-tunnel`.
  4. Revoke the old token.

### Network Egress & Encryption

- All outbound traffic uses **TCP/443** only — never UDP.
- Xray wraps proxy traffic in HTTP-header obfuscation to defeat DPI.
- Pinggy tunnels are **raw TCP** — they cannot decrypt the SSH payload inside.
- The desktop uses `ssh` with an Ed25519 key (never a password).

**What this protects against:**

- Passive network monitoring between all three hops.
- DPI middleboxes looking for recognizable VPN signatures.
- Server-side firewall rules that block non-443 egress.

**What this does NOT protect against:**

- Metadata analysis (an observer can still see that a persistent tunnel exists).
- A compromised Xray provider that logs connection metadata.
- Side-channel attacks on the server or desktop hardware.

### SSH Host Key Hygiene

The default config uses:

```
StrictHostKeyChecking accept-new
```

This means:

- **New** host keys are accepted automatically (required because Pinggy rotates edge nodes).
- **Changed** host keys are **rejected**, preventing silent MITM.

**For higher assurance:** Pin the server's host key explicitly.

1. On the server, get the fingerprint:
   ```bash
   sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```

2. On the desktop, add a `KnownHostsFile` directive scoped to the alias:
   ```
   Host topo-server
       HostName xyz.pinggy-free.link
       User user
       Port 41021
       KnownHostsFile ~/.ssh/known_hosts.topo
       StrictHostKeyChecking yes
   ```
   
3. Pre-populate `~/.ssh/known_hosts.topo` with the correct fingerprint.

**Caveat:** Because Pinggy routes through different edge IPs, pinning the *edge* key is impractical. Pin the **server's** host key by using a jump host or by copying the key manually:

```bash
ssh-keyscan -p PORT HOST >> ~/.ssh/known_hosts.topo
```

Then verify the first entry matches the server's fingerprint.

### MCP Server Supply Chain

The `mcp-ssh` server is fetched via `npx -y @aiondadotcom/mcp-ssh`, which downloads the **latest** version every time it runs.

**Risks:**

- A compromised npm package would execute arbitrary code as the desktop user.
- Network-level attackers could serve a malicious package if npm's TLS were compromised.

**Mitigations:**

- Pin to a specific version in the Claude config:
  ```json
  "args": ["-y", "@aiondadotcom/mcp-ssh@1.2.3"]
  ```
- Audit the package before first use: `npm view @aiondadotcom/mcp-ssh`
- Run Claude Desktop in a sandboxed OS user account for high-risk environments.
- For maximum assurance, vendor the source:
  ```bash
  git clone https://github.com/aiondadotcom/mcp-ssh.git
  cd mcp-ssh && npm install && npm run build
  # Then point "command" at ./dist/index.js
  ```

---

## User Responsibilities

You are responsible for the following:

- **Only access systems you own** or have explicit authorization to access.
- **Never commit secrets** to public repositories.
- **Keep the server patched** — apply OS updates regularly.
- **Rotate tokens** every 90 days.
- **Disable SSH password authentication** on the server:
  ```
  # /etc/ssh/sshd_config
  PasswordAuthentication no
  PermitRootLogin no
  ```
- **Restrict `~/.ssh/authorized_keys`** to keys you recognize.
- **Monitor `journalctl -u pinggy-tunnel`** for unexpected restarts or Gist updates.
- **Revoke credentials immediately** if you suspect compromise.

---

## Known Limitations

### 1. Metadata leakage

An observer on any link can determine:

- The existence of a persistent tunnel to a Pinggy edge.
- The approximate byte volume and timing of traffic.
- The tunnel endpoint's hostname and port.

The **contents** are protected, but the **pattern** is not.

### 2. Gist URL exposure

If the Gist is accidentally made public (unlikely — it defaults to secret), anyone can:

- See the current tunnel URL.
- Attempt connections to the exposed SSH port.
- **Not** authenticate (SSH key required).

To mitigate: enable 2FA on your GitHub account and periodically audit Gist visibility at [gist.github.com](https://gist.github.com).

### 3. Pinggy correlation

Pinggy assigns a subdomain derived from the Xray exit IP (e.g., `xyz-45-140-205-72.run.pinggy-free.link`). This means:

- The Xray exit IP is visible in the tunnel hostname.
- Correlating the tunnel to the Xray provider is trivial.
- Correlating it further to the specific user requires additional work.

### 4. Free-tier rate limits

Pinggy's free tier may rate-limit or throttle traffic from certain regions. This is a service limitation, not a security issue, but it may affect availability.

### 5. `npx` execution on every run

Each Claude session spawns `npx -y @aiondadotcom/mcp-ssh`, which re-resolves the package. If npm's registry is compromised, this is an attack vector. Pin the version for production use.

---

## Reporting a Vulnerability

**Do NOT open a public GitHub issue for security vulnerabilities.**

### Preferred channel

Use GitHub's **Private Vulnerability Reporting**:

1. Go to the [Security tab](https://github.com/MHAmirkhani/claude-remote-ssh/security/advisories/new) of the repository.
2. Click **Report a vulnerability**.
3. Fill in the advisory form.

This routes the report privately to maintainers without alerting the public.

### Alternative channel

If you cannot use GitHub's reporting tool, email:

**Amirkhani.MohammadH [at] gmail [dot] com**

Encrypt your message with PGP if possible — key available on request.

### What to include

A high-quality report includes:

1. **Summary** — one sentence describing the issue.
2. **Severity assessment** — CVSS score or qualitative (Low/Medium/High/Critical).
3. **Reproduction steps** — minimal, deterministic, and complete.
4. **Affected versions** — which commits or releases are vulnerable.
5. **Impact analysis** — what an attacker can achieve.
6. **Suggested fix** — if you have one.
7. **Proof of concept** — code, screenshots, or a private repo.
8. **Disclosure preference** — your timeline and any constraints.

### What not to include

- GitHub tokens (even expired ones)
- SSH private keys
- Full VLESS URLs
- Personal information about other users

If a PoC requires a working Gist or VLESS endpoint, redact the sensitive parts and describe the structure instead.

### Response timeline

| Stage | Target |
|---|---|
| **Initial acknowledgment** | Within **48 hours** |
| **Triage and severity assessment** | Within **5 days** |
| **Fix or mitigation** | Within **7 days** for High/Critical |
| **Patch release** | Within **14 days** for High/Critical |
| **Public disclosure** | Coordinated with reporter; typically 30–90 days after fix |

If the issue is not reproducible or falls outside scope, we will explain why.

### Recognition

Unless you request anonymity, we will credit you:

- In the `CHANGELOG.md` under **Security**.
- In the GitHub Security Advisory.
- Optionally in the README's **Acknowledgments** section.

---

## Disclosure Policy

We follow a **coordinated disclosure** model:

1. **Reporter** submits the issue privately.
2. **Maintainers** confirm the issue and assess severity.
3. **A fix** is developed and tested in a private branch.
4. **A patch release** is published.
5. **A public advisory** is published after the fix is available.
6. **Credit** is given to the reporter (unless anonymity is requested).

### Early disclosure

If a vulnerability is being actively exploited in the wild, we will:

- Publish an advisory immediately, even before a fix is available.
- Provide mitigation steps in the advisory.
- Release a patch as soon as technically possible.

### Embargoes

We are willing to coordinate with the reporter on a disclosure timeline. The maximum embargo we accept is **90 days** from the initial report. Beyond that, we reserve the right to publish our own advisory with or without a fix.

---

## Acknowledgments

We thank the following security researchers for responsible disclosure. (This list will grow as reports are received.)

*No vulnerabilities have been reported as of the 1.0.0 release.*

---

## Related Documentation

- [docs/06-architecture.md](docs/06-architecture.md) — Design rationale and threat model details
- [docs/05-troubleshooting.md](docs/05-troubleshooting.md) — Common issues including MITM warnings
- [CONTRIBUTING.md](CONTRIBUTING.md) — Secret hygiene guidelines for contributors

---

## Contact

- **Security reports:** [GitHub Security Advisory](https://github.com/MHAmirkhani/claude-remote-ssh/security/advisories/new) (preferred) or email
- **General questions:** [GitHub Discussions](https://github.com/MHAmirkhani/claude-remote-ssh/discussions)
- **Non-security bugs:** [GitHub Issues](https://github.com/MHAmirkhani/claude-remote-ssh/issues)

---

*Last updated: 2026-09-24*
