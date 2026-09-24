# Security Policy

## Threat Model & Security Architecture

1. **GitHub Access Tokens**:
   - Must only be granted the minimal `gist` scope.
   - Stored strictly in root-readable `/etc/claude-remote-ssh/tunnel.env` (permissions `0600`).
   - Never embedded inside repository source files.

2. **Network Egress & Encryption**:
   - Outbound tunnel sessions are encapsulated inside SSH over TCP port 443 through Xray SOCKS5 proxy.
   - Remote access to the VM is guarded by standard public-key cryptography (`ed25519`).
   - Pinggy acts strictly as a raw TCP proxy; it cannot decrypt client SSH payload traffic.

3. **SSH Host Key Hygiene**:
   - While `StrictHostKeyChecking accept-new` is used to tolerate dynamic edge-node host key changes, production users can pin target server fingerprints using custom SSH `KnownHostsFile` directives.

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please **do not** open a public issue.
Submit details via GitHub Private Vulnerability Reporting or contact the maintainer directly.
We strive to acknowledge reports within 48 hours and provide patches within 7 days.