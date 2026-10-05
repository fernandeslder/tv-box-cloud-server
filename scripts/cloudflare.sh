#!/usr/bin/env bash
# cloudflare.sh — create the Cloudflare Tunnel + DNS records for public share links. Idempotent.
# Needs CF_API_TOKEN (Zone:Read, DNS:Edit, Account>Cloudflare Tunnel:Edit) and DOMAIN in docker/.env.
# Writes CF_TUNNEL_TOKEN back to docker/.env. If the API is unreachable/denied it explains the
# manual dashboard route instead of failing the whole install.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TOKEN="$(env_get CF_API_TOKEN)"; DOMAIN="$(env_get DOMAIN)"; HOSTS="$(env_get PUBLIC_HOSTS "files photos")"
HOSTS="${HOSTS//\"/}"
NAME="${TUNNEL_NAME:-$(env_get TVBOX_HOSTNAME tvbox)}"
API=https://api.cloudflare.com/client/v4
[ -n "$TOKEN" ] && [ -n "$DOMAIN" ] && [ "$DOMAIN" != home.lan ] || { echo "cloudflare: no token/domain configured — skipping"; exit 0; }

cf() {  # cf METHOD PATH [json-body] -> body on stdout; non-success => rc 1
  local out
  out="$(curl -sS -m 30 -X "$1" "$API$2" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" ${3:+--data "$3"})" || return 1
  printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("success") else 1)' || { printf 'cloudflare API error on %s %s: %s\n' "$1" "$2" "$(printf '%s' "$out" | head -c 300)" >&2; return 1; }
  printf '%s' "$out"
}
jq_() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }

manual() {
  warn "Automatic tunnel setup failed. Manual route (2 minutes):"
  warn "  1. dash.cloudflare.com > Zero Trust > Networks > Tunnels > Create (Cloudflared), copy the token"
  warn "  2. add it to docker/.env as CF_TUNNEL_TOKEN=..."
  warn "  3. Public hostnames: $(for h in $HOSTS; do printf '%s.%s ' "$h" "$DOMAIN"; done) -> HTTPS -> caddy:443"
  exit 0
}

zone="$(cf GET "/zones?name=$DOMAIN" 2>/dev/null)" || manual
ZONE_ID="$(printf '%s' "$zone" | jq_ 'r=d["result"]; print(r[0]["id"] if r else "")')"
ACCT_ID="$(printf '%s' "$zone" | jq_ 'r=d["result"]; print(r[0]["account"]["id"] if r else "")')"
[ -n "$ZONE_ID" ] || { warn "domain $DOMAIN not found on this Cloudflare account"; manual; }

tl="$(cf GET "/accounts/$ACCT_ID/cfd_tunnel?name=$NAME&is_deleted=false" 2>/dev/null)" || manual
TID="$(printf '%s' "$tl" | jq_ 'r=d["result"]; print(r[0]["id"] if r else "")')"
if [ -z "$TID" ]; then
  created="$(cf POST "/accounts/$ACCT_ID/cfd_tunnel" "{\"name\":\"$NAME\",\"config_src\":\"cloudflare\"}")" || manual
  TID="$(printf '%s' "$created" | jq_ 'print(d["result"]["id"])')"
  ok "created tunnel $NAME"
fi

ingress="$(HOSTS="$HOSTS" DOMAIN="$DOMAIN" python3 - <<'PY'
import json, os
d = os.environ["DOMAIN"]
rules = [{"hostname": f"{h}.{d}", "service": "https://caddy:443",
          "originRequest": {"originServerName": f"{h}.{d}"}} for h in os.environ["HOSTS"].split()]
rules.append({"service": "http_status:404"})
print(json.dumps({"config": {"ingress": rules}}))
PY
)"
cf PUT "/accounts/$ACCT_ID/cfd_tunnel/$TID/configurations" "$ingress" >/dev/null || manual

for h in $HOSTS; do
  fqdn="$h.$DOMAIN"; target="$TID.cfargotunnel.com"
  body="{\"type\":\"CNAME\",\"name\":\"$fqdn\",\"content\":\"$target\",\"proxied\":true}"
  existing="$(cf GET "/zones/$ZONE_ID/dns_records?name=$fqdn" 2>/dev/null)" || manual
  rid="$(printf '%s' "$existing" | jq_ 'r=d["result"]; print(r[0]["id"] if r else "")')"
  if [ -z "$rid" ]; then cf POST "/zones/$ZONE_ID/dns_records" "$body" >/dev/null || manual
  else cf PUT "/zones/$ZONE_ID/dns_records/$rid" "$body" >/dev/null || manual; fi
  ok "DNS $fqdn -> tunnel"
done

tok="$(cf GET "/accounts/$ACCT_ID/cfd_tunnel/$TID/token" | jq_ 'print(d["result"])')" || manual
env_set CF_TUNNEL_TOKEN "$tok"
ok "tunnel ready (token saved to docker/.env)"
