# 06 - Deep Architecture

## Engineering Rationale

Restricted networks actively profile egress and ingress traffic using Deep Packet Inspection (DPI) and stateful filtering.

### 1. Why SOCKS5 + Reverse Tunnel over 443?
Standard reverse tunneling mechanisms require inbound ports or distinct protocol handshakes (such as UDP for WireGuard or custom TCP ports for FRP).
By chaining:
`OpenSSH Daemon (22) -> Pinggy Reverse Tunnel (TCP/443) -> Xray SOCKS5 -> External Proxy`
all external boundaries view only typical outbound TLS/HTTP traffic over standard port 443.

### 2. Rendezvous via Secret Gist
Because the server has dynamic endpoints (Pinggy free tier cycles hourly), a lightweight coordination channel is required. GitHub Gists provide:
- High availability HTTPS endpoint.
- Programmatic PATCH operations authenticated via granular tokens.
- Complete independence from dedicated coordination servers.

### 3. Cache-Busting Mechanism
GitHub raw endpoints employ aggressive CDN caching. Adding an explicit Unix timestamp query parameter (`?cb=<timestamp>`) accompanied by cache-control headers guarantees the client always resolves the active tunnel endpoint within seconds of rotation.