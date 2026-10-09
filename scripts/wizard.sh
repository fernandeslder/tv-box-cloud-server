#!/usr/bin/env bash
# wizard.sh — create/complete docker/.env. Asks a handful of questions, generates every secret.
#   wizard.sh              ask (only what is missing), keep everything already set
#   wizard.sh --yes        no questions: detect + generate (reads TVBOX_SEED / /opt/tvbox-seed.env first)
#   wizard.sh --reconfigure  ask everything again, keep generated secrets
# A seed file is a plain KEY=VALUE env file (same keys as docker/.env.example) that pre-answers questions.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

YES=0; RECONF=0
for a in "$@"; do case "$a" in --yes) YES=1 ;; --reconfigure) RECONF=1 ;; esac; done
[ -t 0 ] || YES=1
[ -n "${TVBOX_NONINTERACTIVE:-}" ] && YES=1

FRESH=0
[ -f "$ENV_FILE" ] || { FRESH=1; install -m 600 /dev/null "$ENV_FILE"; cp "$REPO_DIR/docker/.env.example" "$ENV_FILE"; chmod 600 "$ENV_FILE"; }
chmod 600 "$ENV_FILE"

# Seed file: on a brand-new env it overrides the example defaults; afterwards it only fills empty keys.
SEED="${TVBOX_SEED:-${TVBOX_ENV_FILE:-/opt/tvbox-seed.env}}"
if [ -f "$SEED" ]; then
  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue ;; esac
    [[ "$k" =~ ^[A-Z0-9_]+$ ]] || continue
    v="${v%$'\r'}"   # seed edited on Windows
    if [ "$FRESH" -eq 1 ] || [ -z "$(env_get "$k")" ]; then env_set "$k" "$v"; fi
  done < "$SEED"
  ok "applied seed answers from $SEED"
fi

ask() {  # ask KEY "Question" default   (hidden=1 for secrets)
  local key="$1" q="$2" def="${3:-}" cur ans
  cur="$(env_get "$key")"
  if [ -n "$cur" ] && [ "$RECONF" -eq 0 ]; then return 0; fi
  [ -n "$cur" ] && def="$cur"
  if [ "$YES" -eq 1 ]; then env_set "$key" "$def"; return 0; fi
  if [ "${hidden:-0}" = 1 ]; then read -r -s -p "$q ${def:+[keep current]}: " ans </dev/tty; echo
  else read -r -p "$q ${def:+[$def]}: " ans </dev/tty; fi
  env_set "$key" "${ans:-$def}"
}
yn() {  # yn "Question" default(y/n) -> 0 for yes
  local ans def="$2"
  [ "$YES" -eq 1 ] && { [ "$def" = y ]; return; }
  read -r -p "$1 [$( [ "$def" = y ] && echo Y/n || echo y/N )]: " ans </dev/tty
  ans="${ans:-$def}"; [[ "$ans" =~ ^[Yy] ]]
}
secret() { [ -n "$(env_get "$1")" ] || env_set "$1" "$(rand "${2:-24}")"; }

# ---------------------------------------------------------------- auto-detect
dev="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1 || true)"
ip4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)"
cidr="$(ip -4 -o addr show dev "${dev:-lo}" 2>/dev/null | awk '{print $4}' | head -n1 || true)"
net="$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "${cidr:-192.168.1.1/24}" 2>/dev/null || echo 192.168.1.0/24)"
tz="$(timedatectl show -p Timezone --value 2>/dev/null || echo Europe/London)"
uid="$(id -u "$TVBOX_USER" 2>/dev/null || echo 1000)"; gid="$(id -g "$TVBOX_USER" 2>/dev/null || echo 1000)"

if [ -z "$(env_get TZ)" ] || [ "$(env_get TZ)" = Europe/London ]; then env_set TZ "$tz"; fi
env_set PUID "$uid"; env_set PGID "$gid"
vg="$(getent group video | cut -d: -f3 || true)"; rg="$(getent group render | cut -d: -f3 || true)"
env_set VIDEO_GID "${vg:-44}"; env_set RENDER_GID "${rg:-105}"
if [ -z "$(env_get LAN_IP)" ] || [ "$(env_get LAN_IP)" = 192.168.1.10 ]; then env_set LAN_IP "${ip4:-192.168.1.10}"; env_set LAN_CIDR "$net"; fi

echo
echo "TV Box setup — a few questions (Enter accepts the default)."
echo

# ---------------------------------------------------------------- domain / TLS
if [ "$RECONF" -eq 1 ] || [ "$(env_get DOMAIN)" = home.lan ] || [ -z "$(env_get DOMAIN)" ]; then
  if [ "$YES" -eq 0 ]; then
    echo "Domain: if you own one on Cloudflare (e.g. example.com) the box gets trusted HTTPS with"
    echo "nothing to install on phones/PCs, and optional public share links. Otherwise leave blank."
    read -r -p "Your domain (blank = LAN-only 'home.lan'): " d </dev/tty
    [ -n "${d:-}" ] && env_set DOMAIN "$d"
  fi
fi
DOMAIN="$(env_get DOMAIN home.lan)"
if [ "$DOMAIN" != home.lan ]; then
  if [ -z "$(env_get CF_API_TOKEN)" ] || [ "$RECONF" -eq 1 ]; then
    if [ "$YES" -eq 0 ]; then
      cat <<EOF

Cloudflare API token — create at dash.cloudflare.com/profile/api-tokens > Create Token > Custom:
   Zone > Zone > Read        (zone: $DOMAIN)
   Zone > DNS  > Edit        (zone: $DOMAIN)
   Account > Cloudflare Tunnel > Edit     (only for public share links)
EOF
      hidden=1 ask CF_API_TOKEN "Paste the token (hidden, Enter to skip)" ""
    fi
  fi
  if [ -n "$(env_get CF_API_TOKEN)" ]; then env_set TLS_MODE cloudflare; else env_set TLS_MODE internal; warn "no token: using the local CA (install root.crt once per device)"; fi
else
  env_set TLS_MODE internal
fi

# ---------------------------------------------------------------- features
seed_has() { [ -f "$SEED" ] && grep -qE "^$1=" "$SEED"; }
profiles=()
# Unattended with a seed that already says it: the seed wins over the built-in defaults.
if [ "$YES" -eq 1 ] && [ "$RECONF" -eq 0 ] && seed_has TVBOX_DESKTOP; then :
elif yn "Install the TV desktop (Plasma + Kodi) — is this box plugged into a TV?" y; then env_set TVBOX_DESKTOP yes; else env_set TVBOX_DESKTOP no; fi
KEEP_PROFILES=0
if [ "$YES" -eq 1 ] && [ "$RECONF" -eq 0 ] && seed_has COMPOSE_PROFILES; then KEEP_PROFILES=1; fi
if yn "Media apps (Jellyfin movies, Navidrome music, Audiobookshelf)?" y; then profiles+=(media); fi
if yn "Paperless-ngx: archive scans/PDFs with OCR + full-text search (adds ~1GB RAM)?" n; then profiles+=(docs); fi
if yn "Torrent client behind a VPN kill-switch (needs a VPN account)?" n; then
  profiles+=(torrent)
  hidden=0 ask VPN_PROVIDER "VPN provider (gluetun name, e.g. protonvpn, mullvad)" protonvpn
  hidden=1 ask WG_PRIVATE_KEY "WireGuard private key from your VPN" ""
fi
if [ "$(env_get TLS_MODE)" = cloudflare ] && [ -n "$(env_get CF_API_TOKEN)" ]; then
  if yn "Allow public Nextcloud share links + Immich shared albums via a Cloudflare Tunnel (no port forwarding)?" y; then profiles+=(public); fi
fi
if [ "$KEEP_PROFILES" -eq 1 ]; then :
elif [ -n "${profiles[*]:-}" ]; then env_set COMPOSE_PROFILES "$(IFS=,; echo "${profiles[*]}")"; else env_set COMPOSE_PROFILES ""; fi

# ---------------------------------------------------------------- AI + Tailscale (optional)
if [ -z "$(env_get COMMAND_CODE_API_KEY)" ] && [ -n "${COMMAND_CODE_API_KEY:-}" ]; then env_set COMMAND_CODE_API_KEY "$COMMAND_CODE_API_KEY"; fi
if [ "$YES" -eq 0 ] && [ -z "$(env_get COMMAND_CODE_API_KEY)" ]; then
  echo; echo "Optional: Command Code API key lets the box ask cheap/free cloud models for a second opinion on"
  echo "low-confidence file screening (redacted first). Skip it and everything stays on your own hardware."
  hidden=1 ask COMMAND_CODE_API_KEY "Command Code API key (Enter to skip)" ""
fi
if [ "$YES" -eq 0 ] && [ -z "$(env_get TAILSCALE_AUTHKEY)" ]; then
  hidden=1 ask TAILSCALE_AUTHKEY "Tailscale auth key for unattended login (Enter = log in via link later)" ""
fi

# ---------------------------------------------------------------- generated secrets
for s in PIHOLE_PASS IMMICH_DB_PASSWORD NEXTCLOUD_DB_PASSWORD NEXTCLOUD_DB_ROOT_PASSWORD NEXTCLOUD_ADMIN_PASSWORD IMMICH_ADMIN_PASSWORD SMB_PASSWORD PAPERLESS_ADMIN_PASSWORD; do secret "$s"; done
secret PAPERLESS_SECRET_KEY 50
[ -n "$(env_get PAPERLESS_ADMIN_USER)" ] || env_set PAPERLESS_ADMIN_USER admin
[ -n "$(env_get NEXTCLOUD_ADMIN_USER)" ] || env_set NEXTCLOUD_ADMIN_USER admin
[ -n "$(env_get IMMICH_VERSION)" ] || env_set IMMICH_VERSION v3.2.4
env_set IMMICH_ADMIN_EMAIL "$(env_get IMMICH_ADMIN_EMAIL "admin@$DOMAIN")"
case "$(env_get IMMICH_ADMIN_EMAIL)" in admin@home.lan|"") env_set IMMICH_ADMIN_EMAIL "admin@$DOMAIN" ;; esac

ok "docker/.env ready ($(grep -cE '^[A-Z_]+=.+' "$ENV_FILE") values set)"
