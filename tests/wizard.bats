load helpers
setup() { mk_tmp; export ENV_FILE="$T/env" TVBOX_SEED="$T/none"; }
teardown() { rm -rf "$T"; }
@test "--yes generates a complete env with unique random secrets and mode 600" {
  run "$REPO/scripts/wizard.sh" --yes; [ "$status" -eq 0 ]
  [ "$(stat -c %a "$ENV_FILE")" = 600 ]
  for k in PIHOLE_PASS IMMICH_DB_PASSWORD NEXTCLOUD_DB_PASSWORD NEXTCLOUD_DB_ROOT_PASSWORD NEXTCLOUD_ADMIN_PASSWORD SMB_PASSWORD LAN_IP DOMAIN IMMICH_VERSION; do
    v="$(grep "^$k=" "$ENV_FILE" | cut -d= -f2-)"; [ -n "$v" ]; done
  a="$(grep ^IMMICH_DB_PASSWORD= "$ENV_FILE")"; b="$(grep ^NEXTCLOUD_DB_PASSWORD= "$ENV_FILE")"; [ "${a#*=}" != "${b#*=}" ]
}
@test "re-running keeps existing secrets" {
  "$REPO/scripts/wizard.sh" --yes; before="$(grep ^PIHOLE_PASS= "$ENV_FILE")"
  "$REPO/scripts/wizard.sh" --yes; [ "$(grep ^PIHOLE_PASS= "$ENV_FILE")" = "$before" ]
}
@test "seed file pre-answers questions" {
  printf 'DOMAIN=example.org\nTVBOX_HOSTNAME=mybox\n' > "$T/seed"; TVBOX_SEED="$T/seed" run "$REPO/scripts/wizard.sh" --yes
  grep -q '^DOMAIN=example.org' "$ENV_FILE"; grep -q '^TVBOX_HOSTNAME=mybox' "$ENV_FILE"
}
@test "no Cloudflare token means local-CA mode and no public profile" {
  "$REPO/scripts/wizard.sh" --yes; grep -q '^TLS_MODE=internal' "$ENV_FILE"; ! grep -q '^COMPOSE_PROFILES=.*public' "$ENV_FILE"
}
@test "a Cloudflare token + domain switches to trusted certs" {
  printf 'DOMAIN=example.org\nCF_API_TOKEN=tok\n' > "$T/seed"; TVBOX_SEED="$T/seed" "$REPO/scripts/wizard.sh" --yes
  grep -q '^TLS_MODE=cloudflare' "$ENV_FILE"
}
