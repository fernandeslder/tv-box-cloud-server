load helpers
setup() { mk_tmp; export ENV_FILE="$T/env" TVBOX_SEED="$T/none" TVBOX_DATA_DIR="$T/data" ROUTER_CONF="$T/router.conf"; "$REPO/scripts/wizard.sh" --yes >/dev/null; }
teardown() { rm -rf "$T"; }
@test "internal mode writes 'tls internal'" {
  "$REPO/scripts/render-config.sh" >/dev/null; [ "$(cat "$T/data/caddy-tls.caddy")" = "tls internal" ]
}
@test "cloudflare mode writes the DNS-01 block" {
  sed -i 's/^TLS_MODE=.*/TLS_MODE=cloudflare/' "$ENV_FILE"; "$REPO/scripts/render-config.sh" >/dev/null
  grep -q 'dns cloudflare' "$T/data/caddy-tls.caddy"
}
@test "onboarding page mentions the apps and the domain" {
  "$REPO/scripts/render-config.sh" >/dev/null; grep -q "photos.home.lan" "$T/data/setup/index.html"; grep -q Immich "$T/data/setup/index.html"
}
