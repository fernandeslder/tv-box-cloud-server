#!/usr/bin/env bash
# nextcloud-proxy.sh — tell Nextcloud it sits behind Caddy (idempotent).
# Run once after `docker compose up -d`: sudo ./scripts/nextcloud-proxy.sh
# Sets trusted_proxies (Caddy's container IP, resolved inside the net),
# overwriteprotocol=https and overwritehost=files.<domain>. Without this,
# logins through https://files.home.lan loop or warn about reverse proxies.
set -euo pipefail
cd "$(dirname "$0")"
DOMAIN="${CADDY_DOMAIN:-home.lan}"
CADDY_IP="$(docker compose -f ../docker/cloud/compose.yml exec -T nextcloud getent hosts caddy | awk '{print $1}')"
[ -n "$CADDY_IP" ] || { echo "nextcloud-proxy: cannot resolve caddy IP (is the cloud stack up?)" >&2; exit 1; }
occ() { docker compose -f ../docker/cloud/compose.yml exec -T -u www-data nextcloud php occ "$@"; }
occ config:system:set trusted_proxies 0 --value="$CADDY_IP"
occ config:system:set overwriteprotocol --value=https
occ config:system:set overwritehost --value="files.$DOMAIN"
echo "nextcloud-proxy: ok (caddy=$CADDY_IP host=files.$DOMAIN)"
