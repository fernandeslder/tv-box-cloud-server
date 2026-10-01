#!/usr/bin/env bash
# sort-docs.sh — on-premise document sorting. NOTHING here leaves your hardware.
# Usage:
#   sort-docs.sh --stage0 <file> <transcript>   # local keyword rules -> private/<Cat>/
#                                               # exit 0 placed, 1 no-match
#   sort-docs.sh --stage1 <file> <transcript>   # Legion LLM: name-priority summary ->
#                                               # Documents/<Cat>/ + .summary.txt sidecar
#                                               # exit 0 placed, 2 defer (Legion offline)
set -euo pipefail
cd "$(dirname "$0")"
POOL="${POOL_ROOT:-/mnt/pool}"
MODE="${1:?usage: sort-docs.sh --stage0|--stage1 <file> <transcript>}"
FILE="${2:?}"; TXT="${3:-/dev/null}"

place() {  # $1=dest-dir — collision-safe move
  mkdir -p "$POOL/$1"
  local t="$POOL/$1/$(basename "$FILE")"
  [ -e "$t" ] && t="$POOL/$1/$(date +%s)-$(basename "$FILE")"
  mv "$FILE" "$t"; echo "DOC $t" >&2; echo "$t"
}

if [ "$MODE" = "--stage0" ]; then
  # Local regexes over filename + transcript. IDs / finance / health NEVER go to any API —
  # if it's easily identified here, it stays here. Period.
  HAY="$(basename "$FILE") $(head -c 6000 "$TXT" 2>/dev/null || true)"
  if echo "$HAY" | grep -qiE "passport|driver.?licen[cs]e|work permit|national id|residence permit|birth certificate|social security"; then
    place "private/IDs"; exit 0
  fi
  if echo "$HAY" | grep -qiE "bank statement|payslip|salary slip|tax return|\biban\b|account number|routing number"; then
    place "private/Finance"; exit 0
  fi
  if echo "$HAY" | grep -qiE "prescription|diagnosis|lab result|medical report|\bpatient\b|vaccination"; then
    place "private/Health"; exit 0
  fi
  exit 1
fi

# --stage1: Legion LLM (YOUR hardware, allowed). Filename gets highest weight,
# then summary of content decides the folder.
[ -n "${LEGION_OLLAMA:-}" ] || { echo "sort-docs: no LEGION_OLLAMA" >&2; exit 2; }
OUT="$(mktemp)"
PROMPT="You organize personal documents. The FILENAME matters most, content second. Reply EXACTLY two lines: CATEGORY: <one of Bills Work Travel Manuals Receipts Legal Other> then SUMMARY: <one short line>. Filename: $(basename "$FILE"). Content: $(head -c 1500 "$TXT" 2>/dev/null || true)"
if ! curl -sf -m 120 "$LEGION_OLLAMA/api/generate" \
    -d "$(python3 -c "import json,sys; print(json.dumps({'model': sys.argv[1], 'prompt': open(sys.argv[2]).read()[:2000], 'stream': False}))" "${JUDGE_MODEL:-qwen2.5:3b-instruct}" <(echo "$PROMPT"))" \
    -o "$OUT" 2>/dev/null; then
  rm -f "$OUT"; echo "sort-docs: legion LLM unreachable" >&2; exit 2
fi
RESP="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('response',''))" "$OUT")"
rm -f "$OUT"
CAT="$(echo "$RESP" | grep -oi 'CATEGORY: *[A-Za-z]*' | grep -oi 'Bills\|Work\|Travel\|Manuals\|Receipts\|Legal\|Other' | head -n1 || true)"
SUM="$(echo "$RESP" | grep -oi 'SUMMARY:.*' | head -n1 || true)"
[ -n "$CAT" ] || CAT="Other"
DEST="$(place "Documents/$CAT")"
[ -n "$SUM" ] && echo "$SUM" > "$DEST.summary.txt" || true
