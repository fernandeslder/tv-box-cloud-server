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

place() {  # $1=dest-dir — collision-safe via safe-move.sh (hash-checked, never overwrites)
  local t
  t="$(./safe-move.sh "$FILE" "$POOL/$1")"; echo "DOC $t" >&2; echo "$t"
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

# --stage1: Jev-first dynamic categorization (YOUR hardware — Legion Ollama).
# Filename weighs highest via the prompt; pre-existing folders win; genuinely
# new piles get named by System 2. See categorize.sh for the full workflow.
OUT="$(./categorize.sh "$POOL/Documents" "$(basename "$FILE")" "$TXT" 2>/dev/null)" || exit 2
CAT="$(echo "$OUT" | grep -oi 'CATEGORY:.*' | sed 's/.*CATEGORY: *//I' | head -n1)"
SUM="$(echo "$OUT" | grep -oi 'SUMMARY:.*' | head -n1)"
DEST="$(place "Documents/$CAT")"
[ -n "$SUM" ] && echo "$SUM" > "$DEST.summary.txt" || true
