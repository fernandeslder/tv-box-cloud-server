load helpers
setup() {
  command -v docker-compose >/dev/null || command -v docker >/dev/null || skip "no docker compose binary"
  mk_tmp
  cat > "$T/env" <<E
TZ=UTC
DOMAIN=home.lan
LAN_IP=192.168.1.10
LAN_CIDR=192.168.1.0/24
PIHOLE_PASS=x
IMMICH_VERSION=v3.2.4
IMMICH_DB_PASSWORD=x
NEXTCLOUD_DB_PASSWORD=x
NEXTCLOUD_DB_ROOT_PASSWORD=y
NEXTCLOUD_ADMIN_PASSWORD=z
E
  if command -v docker-compose >/dev/null; then DC=(docker-compose); else DC=(docker compose); fi
}
teardown() { rm -rf "$T"; }
@test "compose config is valid with default profiles" { cd "$REPO/docker"; "${DC[@]}" --env-file "$T/env" config --quiet; }
@test "compose config is valid with every profile on" {
  cd "$REPO/docker"; printf 'COMPOSE_PROFILES=media,docs,torrent,public,agent\nWG_PRIVATE_KEY=k\nCF_TUNNEL_TOKEN=t\n' >> "$T/env"
  "${DC[@]}" --env-file "$T/env" config --quiet
}
@test "missing secrets fail loudly instead of starting with blanks" {
  cd "$REPO/docker"; sed -i '/IMMICH_DB_PASSWORD/d' "$T/env"; run "${DC[@]}" --env-file "$T/env" config --quiet; [ "$status" -ne 0 ]
}
@test "no service publishes admin ports to the LAN" {
  cd "$REPO/docker"; out="$("${DC[@]}" --env-file "$T/env" config)"
  ! grep -E 'published: "?(8080|5001|3000|3001|8090|2283|8081|5432)"?' <<<"$out"
}
@test "caddy config validates (stock caddy, internal TLS)" {
  command -v caddy >/dev/null || [ -x /tmp/opencode/caddy ] || skip "no caddy binary"
  cb="$(command -v caddy || echo /tmp/opencode/caddy)"
  echo "tls internal" > "$T/tls.caddy"; sed "s#/etc/caddy/tls.caddy#$T/tls.caddy#" "$REPO/docker/net/Caddyfile" > "$T/Caddyfile"
  DOMAIN=home.lan run "$cb" validate --config "$T/Caddyfile" --adapter caddyfile; [ "$status" -eq 0 ]
}
