load helpers
setup() {
  mk_tmp; export ENV_FILE="$T/env"; PORT=$((20000 + RANDOM % 20000)); export CF_API_BASE="http://127.0.0.1:$PORT"
  python3 "$REPO/tests/mock_cloudflare.py" "$PORT" & MOCK=$!
  for _ in $(seq 1 30); do curl -s -o /dev/null "$CF_API_BASE/x" && break; sleep 0.1; done
  printf 'DOMAIN=example.org\nCF_API_TOKEN=goodtoken\nPUBLIC_HOSTS="files photos"\nTVBOX_HOSTNAME=tvbox\n' > "$ENV_FILE"
}
teardown() { kill "$MOCK" 2>/dev/null || true; rm -rf "$T"; }
state() { curl -s -H "Authorization: Bearer goodtoken" "$CF_API_BASE/__state"; }

@test "creates tunnel, ingress, CNAMEs and stores the tunnel token" {
  run "$REPO/scripts/cloudflare.sh"; [ "$status" -eq 0 ]
  grep -q '^CF_TUNNEL_TOKEN=TUNNEL-TOKEN-XYZ' "$ENV_FILE"
  s="$(state)"
  python3 - "$s" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
assert [t["name"] for t in s["tunnels"]] == ["tvbox"]
names = sorted(r["name"] for r in s["dns"]); assert names == ["files.example.org", "photos.example.org"], names
assert all(r["content"] == "TUN1.cfargotunnel.com" and r["proxied"] for r in s["dns"])
rules = s["config"]["config"]["ingress"]
assert rules[-1] == {"service": "http_status:404"}
assert {r["hostname"] for r in rules[:-1]} == {"files.example.org", "photos.example.org"}
assert all(r["service"] == "https://caddy:443" and r["originRequest"]["originServerName"] == r["hostname"] for r in rules[:-1])
PY
}
@test "is idempotent: a second run creates nothing new" {
  "$REPO/scripts/cloudflare.sh" >/dev/null; run "$REPO/scripts/cloudflare.sh"; [ "$status" -eq 0 ]
  python3 - "$(state)" <<'PY'
import json, sys
s = json.loads(sys.argv[1]); assert len(s["tunnels"]) == 1 and len(s["dns"]) == 2
PY
}
@test "a bad token explains the manual route and does not fail the install" {
  sed -i 's/goodtoken/badtoken/' "$ENV_FILE"; run "$REPO/scripts/cloudflare.sh"; [ "$status" -eq 0 ]
  [[ "$output" == *"Manual route"* ]]; ! grep -q '^CF_TUNNEL_TOKEN=.\+' "$ENV_FILE"
}
@test "an unknown domain explains itself" {
  sed -i 's/example.org/nope.example/' "$ENV_FILE"; run "$REPO/scripts/cloudflare.sh"; [ "$status" -eq 0 ]; [[ "$output" == *"not found"* ]]
}
@test "no token/domain: skips quietly" {
  printf 'DOMAIN=home.lan\n' > "$ENV_FILE"; run "$REPO/scripts/cloudflare.sh"; [ "$status" -eq 0 ]; [[ "$output" == *skipping* ]]
}
