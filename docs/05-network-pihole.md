# 05 — Network: Pi-hole + Unbound + Caddy + Tailscale

## Choice: Pi-hole v6 + Unbound (recursive)
AdGuard Home is objectively easier (native DoH/DoT, per-client toggles) but you asked for Pi-hole — and v6 closed the gap (no more lighttpd/PHP, embedded web + REST, native HTTPS UI). Pi-hole+Unbound = only fully-recursive (no-third-party) option + biggest blocklist community.

- Images: `pihole/pihole:latest` (~200MB), `mvance/unbound:latest`.
- RAM: ~100MB + ~30MB. 1M domains fine on this box.
- Blocklists to start: `OISD Big (https://big.oisd.nl)` + `Hagezi Multi Pro`. Don't stack 12 lists.
- Do NOT run Pi-hole + AdGuard on one host (both need :53). No `1.1.1.1` as "secondary" — clients load-share and bypass filtering.

## Ports (critical)
| Host port | Owner |
|---|---|
| 53/tcp+udp | Pi-hole only (`FTLCONF_dns_listeningMode: ALL`) |
| 80,443 | Caddy only. Pi-hole web remapped to `8080:8080` via `FTLCONF_webserver_port: '8080o,[::]:8080o'` |
| 5335 | Unbound internal only (Pi-hole upstream `unbound#5335`) |
| 67/udp | nobody (DHCP stays on router) |

Do the `systemd-resolved` stub fix first (see `02-os-postinstall.md`).

## Split-DNS + Caddy
- Caddy owns :80/:443, serves `*.home.lan` (or real domain via Cloudflare DNS-01 so LAN+WAN share one Let's Encrypt cert; pure-LAN `tls internal` is fine).
- Pi-hole → Local DNS: `*.home.lan → <caddy-LAN-IP>`. Wildcard needs dnsmasq file (enable `misc.etc_dnsmasq_d` Expert first): `address=/.home.lan/192.168.x.10` in `/etc/dnsmasq.d/02-wildcard.conf`.
- Router DHCP hands out Pi-hole IP as sole DNS. Optional firewall redirect outbound :53→Pi-hole (catches hardcoded TV/IoT DNS).
- Compose: `docker/net/compose.yml`. See `.env.example` for `PIHOLE_PASS`.

## Remote without port forwarding: Tailscale
- Install on host (not in Compose): `tailscale up --accept-dns`. No router forwards.
- Admin → DNS → Split DNS: `home.lan → 100.x.y.z` (Pi-hole tailnet IP).
- Caddy binds LAN + tailnet. Don't use Tailscale Serve for throughput — Caddy `reverse_proxy` is ~5-10x faster.

## Companion services (all behind Caddy, all `restart: unless-stopped`)
- **Dockge** (`:5001`) — Compose-native Docker mgmt, lighter than Portainer.
- **Homepage** (`:3000`) — family dashboard at `home.lan`.
- **Uptime Kuma** (`:3001`) — monitor Pi-hole/Caddy/cloud.
- **Beszel** (`:8090`) — lightweight metrics (better than Netdata here).
- **Gluetun + qBittorrent** (separate `torrent/compose.yml`, `network_mode: service:gluetun`, kill-switch = netns, bind qbit to `tun0`, verify IP ≠ home IP).
- **Watchtower fork `nickfedor/watchtower`** (containrrr is EOL): cron 4am, label-gated. Auto-update Homepage/Dockge/Kuma/Caddy only. **Exclude Pi-hole, Unbound, Gluetun, qBittorrent** (`enable=false`).
