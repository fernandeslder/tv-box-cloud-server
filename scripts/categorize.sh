#!/usr/bin/env bash
# categorize.sh — two-stage categorization.
#   System 1 (Jev decision model): does the item fit a PRE-EXISTING category? (choice)
#   System 2 (slower bigger model): only if Jev says NEW — invents the category name.
# All decisions are typed (jev.sh noul/choice/fields over Ollama structured outputs).
# Free-text summaries are display-only, never control flow.
# Usage: categorize.sh <root-dir> <item-name> <content-file>
#   root-dir: existing categories = its subdirectories (new ones created on demand)
#   stdout:  "CATEGORY: <name>" newline "SUMMARY: <one line>"
#   exit 0 = categorized, 2 = defer (Legion unreachable / invalid decision)
# Models (Legion Ollama, YOUR hardware — nothing external; any Jev-compatible
# weights such as Kev/NanoJev are drop-in via JEV_MODEL):
#   JEV_MODEL  System 1: qwen2.5:3b-instruct (fast fit-check)
#   SYS2_MODEL System 2: qwen2.5:7b-instruct — generative lane ONLY (invents new
#     category names). NEVER a fallback for System 1 decisions; those fall back
#     NanoJev-ward (see jev.sh) or stay queued.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="${1:?usage: categorize.sh <root-dir> <item-name> <content-file>}"
ITEM="${2:?}"; CONTENT="${3:-/dev/null}"
SYS2_MODEL="${SYS2_MODEL:-qwen2.5:7b-instruct}"
mkdir -p "$ROOT"

DIRS="$(cd "$ROOT" && find . -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort | head -n 60)"
EXCERPT="$(head -c 1500 "$CONTENT" 2>/dev/null || true)"

summary_of() {  # $1=item $2=excerpt -> one short line (display only, never parsed for flow)
  { echo "Summarize this personal file in one short line. Name: $1. Content: $2"; } | ./jev.sh fields '{"summary":"string"}' - \
    2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('summary','')}" 2>/dev/null || true
}

fuzzy_dir() {  # $1=root $2=want -> existing dir at ratio>=0.8 else empty
  python3 - "$1" "$2" <<'EOF'
import difflib, os, sys
root, want = sys.argv[1], sys.argv[2]
norm = lambda s: " ".join(s.strip().lower().split())
best, score = "", 0.0
for d in os.listdir(root):
    if not os.path.isdir(os.path.join(root, d)):
        continue
    s = difflib.SequenceMatcher(None, norm(want), norm(d)).ratio()
    if s > score:
        best, score = d, s
print(best if score >= 0.82 else "")
EOF
}

if [ -n "$DIRS" ]; then
  # ---- System 1 (Jev choice): fit existing, or NEW? ----
  OPTS="$(echo "$DIRS" | tr '\n' '|' | sed 's/|$//')|NEW"
  S1="$( { echo "File this personal item. Item name matters most, content second. Item: $ITEM. Content: $EXCERPT."; } | ./jev.sh choice - "$OPTS")" || exit 2
  WANT="$(echo "$S1" | python3 -c "import json,sys; print(json.load(sys.stdin)['decision'])")"
  if [ "$WANT" != "NEW" ]; then
    CAT="$(fuzzy_dir "$ROOT" "$WANT")"
    if [ -n "$CAT" ]; then
      SUM="$(summary_of "$ITEM" "$EXCERPT")"
      echo "CATEGORY: $CAT"; echo "SUMMARY: ${SUM:-$ITEM}"; exit 0
    fi
    # Jev named nothing real — fall through to System 2.
  fi
fi

# ---- System 2: NEW pile (or empty root) — invent the category name ----
LIST="$(echo "$DIRS" | tr '\n' ',' | sed 's/,$//')"
[ -n "$LIST" ] || LIST="(none yet)"
S2="$( { echo "You organize personal files. Existing folders: $LIST. Item: $ITEM. Content: $EXCERPT. Invent ONE short folder name (1-3 words) fitting alongside the existing ones, specific enough to be useful, general enough to reuse. category = the folder name, summary = one short line about the item."; } | JEV_MODEL="$SYS2_MODEL" ./jev.sh fields '{"category":"string","summary":"string"}' -)" || exit 2
CAT2="$(echo "$S2" | python3 -c "import json,sys; print(json.load(sys.stdin).get('category',''))")"
SUM2="$(echo "$S2" | python3 -c "import json,sys; print(json.load(sys.stdin).get('summary',''))")"
CAT2="$(echo "$CAT2" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[^A-Za-z0-9 _-]//g;s/[[:space:]]\+/ /g' | cut -c1-40)"
[ -n "$CAT2" ] || { echo "categorize: system2 gave no name" >&2; exit 2; }
echo "CATEGORY: $CAT2"; echo "SUMMARY: ${SUM2:-$ITEM}"
