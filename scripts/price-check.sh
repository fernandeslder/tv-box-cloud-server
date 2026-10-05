#!/usr/bin/env bash
# price-check.sh — daily model-list refresh against the live Command Code catalogue.
# Drops model ids that no longer exist from each tier, tops tiers up from the catalogue when
# they run dry, and writes configs/router.managed.conf ATOMICALLY with validated ids only
# (so the router never sees a malformed or injected value). Never touches keys, caps or switches.
# Usage: ./price-check.sh [catalog.json]   # no arg = download the live catalogue
set -euo pipefail
cd "$(dirname "$0")"
. ./conf-load.sh
load_conf ../configs/router.conf.example   # defaults
load_conf ../configs/router.conf           # your overrides
SNAP="${1:-}"
CONF="${ROUTER_MANAGED:-../configs/router.managed.conf}"
if [ -z "$SNAP" ]; then
  SNAP="$(mktemp)"; trap 'rm -f "$SNAP"' EXIT
  curl -fsS -m 60 --retry 3 "${CC_BASE_URL:-https://api.commandcode.ai/provider/v1}/models" -o "$SNAP" \
    || { echo "price-check: catalogue unreachable, keeping current picks" >&2; exit 0; }
fi

tmp="$(mktemp "$CONF.XXXXXX")"
CC_FREE_MODELS="${CC_FREE_MODELS:-}" CC_VALUE_MODELS="${CC_VALUE_MODELS:-}" CC_STRONG_MODELS="${CC_STRONG_MODELS:-}" \
python3 - "$SNAP" > "$tmp" <<'PY'
import json, os, re, sys, datetime
ID = re.compile(r"^[A-Za-z0-9._:/-]+$")
cat = json.load(open(sys.argv[1])).get("data", [])
chat = {m["id"]: m for m in cat if ID.match(m.get("id", "")) and "/chat/completions" in m.get("supported_endpoints", [])}
lists = {k: [x for x in os.environ.get(f"CC_{k}_MODELS", "").split() if ID.match(x)] for k in ("FREE", "VALUE", "STRONG")}
out = {}
for k, ids in lists.items():
    out[k] = [i for i in ids if i in chat]
# Top up the free tier from the catalogue (free is identifiable by name; never guess paid tiers).
if len(out["FREE"]) < 2:
    for i in sorted(chat):
        if (i.endswith(":free") or "-free" in i or "space-bunny" in i) and i not in out["FREE"]:
            out["FREE"].append(i)
        if len(out["FREE"]) >= 3:
            break
now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
print(f"# MANAGED by price-check.sh ({now}). Do not hand-edit: edit router.conf instead.")
for k in ("FREE", "VALUE", "STRONG"):
    if out[k]:
        print(f'CC_{k}_MODELS="{" ".join(out[k])}"')
sys.stderr.write("free: %s\nvalue: %s\nstrong: %s\n" % tuple(" ".join(out[k]) or "(none)" for k in ("FREE", "VALUE", "STRONG")))
PY
chmod 644 "$tmp"; mv -f "$tmp" "$CONF"
echo "price-check: wrote $CONF"
