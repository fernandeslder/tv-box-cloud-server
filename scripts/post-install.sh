#!/usr/bin/env bash
# post-install.sh — one-time wiring after `docker compose up -d`. Idempotent; each step is
# best-effort (a failed step prints how to do it by hand and never aborts the install).
#   * wait for the stack
#   * Nextcloud: cron mode, external storage for the sorted folders, sane defaults
#   * Immich: create the admin account + external library on Photos/ (API; best effort)
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "$REPO_DIR/docker"
dc() { docker compose "$@"; }
occ() { dc exec -T -u www-data nextcloud php occ "$@"; }

echo "Waiting for Nextcloud to finish its first-run install (can take a few minutes)..."
ready=0
for _ in $(seq 1 90); do
  if occ status 2>/dev/null | grep -q 'installed: true'; then ready=1; break; fi
  sleep 5
done
if [ "$ready" -eq 1 ]; then
  occ background:cron >/dev/null 2>&1 || true
  occ config:system:set default_phone_region --value="$(env_get REGION CA)" >/dev/null 2>&1 || true
  occ config:system:set maintenance_window_start --type=integer --value=1 >/dev/null 2>&1 || true
  occ config:system:set memcache.local --value='\OC\Memcache\APCu' >/dev/null 2>&1 || true
  occ config:system:set memcache.locking --value='\OC\Memcache\Redis' >/dev/null 2>&1 || true
  occ config:system:set redis host --value=redis >/dev/null 2>&1 || true
  occ config:system:set redis port --value=6379 --type=integer >/dev/null 2>&1 || true
  occ app:enable files_external >/dev/null 2>&1 || true
  existing="$(occ files_external:list --output=json 2>/dev/null || echo '[]')"
  admin="$(env_get NEXTCLOUD_ADMIN_USER admin)"
  for d in Uploads Photos Documents Music Videos Recordings Other private; do
    if printf '%s' "$existing" | grep -q "\"mount_point\": *\"/$d\""; then continue; fi
    id="$(occ files_external:create "$d" local null::null -c "datadir=/external/$d" --output=json 2>/dev/null | tr -dc '0-9' || true)"
    if [ -n "$id" ]; then
      occ files_external:option "$id" filesystem_check_changes 1 >/dev/null 2>&1 || true
      [ "$d" = private ] && occ files_external:applicable --add-user "$admin" "$id" >/dev/null 2>&1 || true
      ok "Nextcloud folder '$d' linked to the sorted library"
    else warn "could not link '$d' in Nextcloud (Settings > Administration > External storage)"; fi
  done
else
  warn "Nextcloud did not finish installing in time: re-run: sudo ./scripts/post-install.sh"
fi

# --- Immich: admin + external library (best effort; v3 API) ---------------------
ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(dc ps -q immich-server | head -n1)" 2>/dev/null || true)"
if [ -n "$ip" ]; then
  EMAIL="$(env_get IMMICH_ADMIN_EMAIL)" PASS="$(env_get IMMICH_ADMIN_PASSWORD)" IP="$ip" python3 - <<'PY' || warn "Immich auto-setup skipped: open https://photos.$(env_get DOMAIN) once and create the admin, then add /external/photos as an External Library"
import json, os, time, urllib.request, urllib.error
base = f"http://{os.environ['IP']}:2283/api"
def call(path, body=None, token=None):
    req = urllib.request.Request(base + path, json.dumps(body).encode() if body is not None else None,
        {"Content-Type": "application/json", **({"Authorization": f"Bearer {token}"} if token else {})})
    return json.load(urllib.request.urlopen(req, timeout=30))
for _ in range(60):
    try: call("/server/ping"); break
    except Exception: time.sleep(5)
try:
    call("/auth/admin-sign-up", {"email": os.environ["EMAIL"], "name": "Admin", "password": os.environ["PASS"]})
except urllib.error.HTTPError:
    pass  # admin already exists
login = call("/auth/login", {"email": os.environ["EMAIL"], "password": os.environ["PASS"]})
tok = login["accessToken"]
try:
    req = urllib.request.Request(base + "/libraries", headers={"Authorization": f"Bearer {tok}"})
    existing = json.load(urllib.request.urlopen(req, timeout=30))
except Exception:
    existing = []
if not any("/external/photos" in l.get("importPaths", []) for l in existing):
    call("/libraries", {"name": "Sorted Photos", "ownerId": login["userId"], "importPaths": ["/external/photos"]}, tok)
print("immich: admin + external library ready")
PY
fi
ok "post-install done"
