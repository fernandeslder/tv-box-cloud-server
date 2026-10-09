#!/usr/bin/env bash
# verify.sh — prove the backups can actually be restored (weekly via backup-verify.timer).
#   1. the newest snapshot exists and is recent (VERIFY_MAX_AGE_DAYS, default 3)
#   2. restic's own integrity check on a rotating data subset (VERIFY_DATA_PCT, default 5%)
#   3. restores a random sample of real files (VERIFY_SAMPLE, default 20, each <= 50MB)
#      and byte-compares them with the live copy (skipped for files changed since the snapshot)
#   4. the database dumps inside the snapshot are valid gzip streams
# Never writes outside a temp dir; restores nothing into the live tree. Exit 0 = good.
set -euo pipefail
. "$(cd "$(dirname "$0")/../scripts" && pwd)/lib.sh"
need_root
NOTIFY="$REPO_DIR/scripts/notify.sh"
fail() { "$NOTIFY" error "backup verification FAILED: $*" || true; die "$*"; }

mp="$(disk_mp_for_role backup)"
REPO="${RESTIC_REPO:-${mp:+$mp/restic}}"
[ -n "${REPO:-}" ] || fail "no backup disk online (sudo tvbox disks sync)"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$TVBOX_ETC/restic-password}"
[ -s "$RESTIC_PASSWORD_FILE" ] || fail "missing restic password file $RESTIC_PASSWORD_FILE"
SAMPLE="${VERIFY_SAMPLE:-$(env_get VERIFY_SAMPLE 20)}"
PCT="${VERIFY_DATA_PCT:-$(env_get VERIFY_DATA_PCT 5)}"
MAXAGE="${VERIFY_MAX_AGE_DAYS:-3}"

# restic stamps snapshots with local time + UTC offset and nanoseconds: parse it properly.
snap="$(restic -r "$REPO" snapshots latest --json 2>/dev/null | python3 -c '
import json, sys, re, datetime
s = json.load(sys.stdin)
if not s: sys.exit(1)
s = max(s, key=lambda x: x["time"])
m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.\d+)?(Z|[+-]\d\d:\d\d)?", s["time"])
off = m.group(2) or "Z"
t = datetime.datetime.fromisoformat(m.group(1) + ("+00:00" if off == "Z" else off))
now = datetime.datetime.now(datetime.timezone.utc)
print(s["short_id"], int((now - t).total_seconds()), int(t.timestamp()))
')" || fail "no snapshots in $REPO"
read -r snap_id snap_age snap_epoch <<<"$snap"
age_days=$(( snap_age / 86400 ))
[ "$age_days" -le "$MAXAGE" ] || fail "newest snapshot is $age_days days old (limit $MAXAGE)"
ok "newest snapshot $snap_id is $age_days day(s) old"

restic -r "$REPO" check --read-data-subset="${PCT}%" >/dev/null 2>&1 || fail "restic check found damage"
ok "repository integrity ($PCT% of data blobs re-read)"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# Pick the sample: regular files in the snapshot under the pool, small enough to restore quickly.
restic -r "$REPO" ls latest --json 2>/dev/null | SAMPLE="$SAMPLE" POOL="$STORAGE_ROOT" python3 -c '
import json, os, random, sys
pool = os.environ["POOL"].rstrip("/") + "/"
files = []
for line in sys.stdin:
    try: n = json.loads(line)
    except ValueError: continue
    if n.get("type") == "file" and n.get("path", "").startswith(pool) and 0 < n.get("size", 0) <= 50 * 1024 * 1024:
        files.append(n["path"])
random.shuffle(files)
for p in files[: int(os.environ["SAMPLE"])]: print(p)
' > "$tmp/sample.txt" || true

checked=0; skipped=0; bad=0
if [ -s "$tmp/sample.txt" ]; then
  inc=(); while IFS= read -r p; do inc+=(--include "$p"); done < "$tmp/sample.txt"
  restic -r "$REPO" restore latest --target "$tmp/r" "${inc[@]}" >/dev/null 2>&1 || fail "test restore failed"
  while IFS= read -r p; do
    r="$tmp/r$p"
    [ -f "$r" ] || { echo "missing from restore: $p" >&2; bad=$((bad + 1)); continue; }
    if [ ! -f "$p" ] || [ "$(stat -c %Y "$p")" -gt "$snap_epoch" ]; then skipped=$((skipped + 1)); continue; fi
    if cmp -s "$p" "$r"; then checked=$((checked + 1)); else echo "DIFFERS: $p" >&2; bad=$((bad + 1)); fi
  done < "$tmp/sample.txt"
  [ "$bad" -eq 0 ] || fail "$bad sampled file(s) did not restore identically"
  ok "restored $checked sampled file(s) byte-identical ($skipped changed since the snapshot)"
else
  warn "no pool files in the snapshot to sample (empty library?)"
fi

# Database dumps are the difference between 'files back' and 'photos back'.
restic -r "$REPO" restore latest --target "$tmp/d" --include "$CACHE_ROOT/db-dumps" >/dev/null 2>&1 || true
dumps=0
for f in "$tmp/d$CACHE_ROOT/db-dumps"/*.sql.gz; do
  [ -e "$f" ] || continue
  gzip -t "$f" 2>/dev/null || fail "database dump $(basename "$f") is corrupt"
  dumps=$((dumps + 1))
done
ok "$dumps database dump(s) are valid"

install -d "$TVBOX_STATE"; date -Is > "$TVBOX_STATE/last-verify"
echo "verify: OK $(date -Is)"
