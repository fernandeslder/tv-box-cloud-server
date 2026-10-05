# 05 — Network: Pi-hole + Unbound + Caddy + Tailscale (+ Cloudflare)

## DNS: Pi-hole v6 -> Unbound (recursive, no third party)
Pi-hole answers `*.<domain>` with the box's LAN IP (`FTLCONF_misc_dnsmasq_lines`), everything else goes to Unbound. Blocklists to start: OISD Big + Hagezi Multi Pro. Never add a public resolver as "secondary" (clients load-share and bypass filtering).

## Ports on the host
| Port | Owner |
|---|---|
| 53 tcp/udp | Pi-hole |
| 80, 443 | Caddy (the only web entry) |
| 445 | Samba |
| nothing else | admin UIs are reachable only through Caddy by name |

`ufw` allows private ranges + Tailscale only. (Docker-published ports bypass ufw, which is why only 53/80/443 are published at all.)

## Router
1. **Reserve the box's IP** in the router (DHCP reservation). Wi-Fi -> Ethernet changes the IP: `tvbox-netwatch` notices and re-points DNS/Tailscale (`tvbox update-ip`), but the router DNS setting must follow.
2. Make the router's DHCP hand out the box's IP as **DNS**. If your router (some Bell Home Hub firmwares) will not let you, set the DNS server by hand in each device's Wi-Fi settings (devices on Tailscale already get it through Split DNS). Until DNS points at the box, `https://<name>.<domain>` will not resolve on the LAN.
Fallback if DNS breaks: set the router DNS back to your ISP's, then `docker logs pihole`.

## TLS (Caddy)
- **Domain on Cloudflare (recommended):** Caddy builds with the Cloudflare DNS plugin and gets a real wildcard cert via DNS-01 using your API token. Nothing to install on any device. The cert exists even though the names only resolve on your LAN/tailnet.
- **No domain:** `tls internal` (own CA). Every device installs `https://setup.<domain>/root.crt` once.

## Away from home: Tailscale
`60-tailscale-ssh.sh` installs it, enables forwarding and advertises your LAN subnet. Two one-time clicks in the Tailscale admin console: **approve the subnet route**, and add **Split DNS** `<domain>` -> the box's LAN IP. Then phones reach `photos.<domain>` exactly as at home. (FOSS purist path: Headscale or plain WireGuard — Caddy/Pi-hole don't care.)

## Public share links (optional): Cloudflare Tunnel
`scripts/cloudflare.sh` creates the tunnel + CNAMEs via the API (token needs Zone:Read, DNS:Edit, Account>Cloudflare Tunnel:Edit). The `cloudflared` container dials out; Caddy recognises tunnel traffic (`Cf-Connecting-Ip` header) and then:
- **Nextcloud**: allows only share-link/static paths (`/s/*`, `/public.php*` …); `/login`, `/remote.php/dav`, `/apps/files` return 403.
- **Immich**: blocks `/api/auth`, `/api/admin`, users/API keys and **uploads**; shared albums (key-protected by Immich) work.
- Everything else (Pi-hole, dashboards, media…): 403.
Limits: Cloudflare's free proxy caps request bodies at 100MB and discourages video streaming — upload large videos over Tailscale/LAN. **Verify a real share link end to end after setup**; if a share page misses assets, add the path in `docker/net/Caddyfile` (`@files_tunnel_blocked`).

## Companion services
Homepage (`home.`), Uptime Kuma (`status.`), Beszel (`metrics.`; pair once then `--profile agent`), Watchtower (only label-enabled UIs: never DNS, Caddy, databases, Immich, Nextcloud, VPN).
