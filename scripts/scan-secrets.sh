#!/usr/bin/env bash
# scan-secrets.sh — Tier 0/1 secrets screening. Local only: TruffleHog on this box, Jev on YOUR Legion.
#   ./scan-secrets.sh <file-or-dir>        Tier 0: TruffleHog deterministic scan (offline, --no-verification)
#   ./scan-secrets.sh --llm <text-file>    Tier 1: Jev noul decision, whole text in overlapping chunks
#     stdout: {"verdict":"CLEAN"|"SECRET","confidence":0-100}
# Exit 0 = clean (any confidence; the router decides), 1 = secret, 2 = could not scan.
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "--llm" ]; then
  FILE="${2:?usage: scan-secrets.sh --llm <text-file>}"
  python3 - "$FILE" > "${TMPDIR:-/tmp}/.chunks.$$" <<'PY' || exit 2
import sys
t = open(sys.argv[1], errors="replace").read()
CH, OV, MAXC = 3000, 300, 8
i, n = 0, 0
while i < len(t) and n < MAXC:
    sys.stdout.write(t[i:i + CH].replace("\0", "") + "\0")
    i += CH - OV; n += 1
PY
  trap 'rm -f "${TMPDIR:-/tmp}/.chunks.$$"' EXIT
  any_secret=0; best_secret=0; min_clean=100; seen=0
  while IFS= read -r -d '' chunk; do
    out="$( { echo "Does this text contain secret credentials (API keys, passwords, auth tokens, private keys)? Text:"; printf '%s' "$chunk"; } | ./jev.sh noul - )" || exit 2
    dec="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["decision"], d["confidence"])' "$out")" || exit 2
    seen=1; d="${dec%% *}"; c="${dec##* }"
    if [ "$d" = yes ]; then any_secret=1; [ "$c" -gt "$best_secret" ] && best_secret="$c"
    else [ "$c" -lt "$min_clean" ] && min_clean="$c"; fi
  done < "${TMPDIR:-/tmp}/.chunks.$$"
  if [ "$seen" -eq 0 ]; then printf '{"verdict":"CLEAN","confidence":100}\n'; exit 0; fi   # empty text
  if [ "$any_secret" -eq 1 ]; then printf '{"verdict":"SECRET","confidence":%s}\n' "$best_secret"; exit 1; fi
  printf '{"verdict":"CLEAN","confidence":%s}\n' "$min_clean"; exit 0
fi

TARGET="${1:?usage: scan-secrets.sh <file-or-dir>}"
command -v docker >/dev/null 2>&1 || { echo "scan-secrets: docker missing, Tier-0 unavailable" >&2; exit 2; }
MOUNT="$(realpath "$TARGET")"
# Pinned image + timeout: a hang or surprise update must not stall ingest.
timeout 120 docker run --rm --network none -v "$MOUNT:/scan:ro" trufflesecurity/trufflehog:3.97.9 \
  filesystem /scan --no-verification --fail >/dev/null 2>&1 && exit 0 || rc=$?
# TruffleHog --fail exits 183 when findings exist; map to our contract.
[ "$rc" -eq 183 ] && exit 1
exit 2
