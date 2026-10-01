#!/usr/bin/env bash
# categorize.sh — two-stage categorization.
#   System 1 (Jev, fast small model): does the item fit a PRE-EXISTING category?
#   System 2 (slower bigger model): only if Jev says NEW — invents the category name.
# Usage: categorize.sh <root-dir> <item-name> <content-file>
#   root-dir: existing categories = its subdirectories (new ones created on demand)
#   stdout:  "CATEGORY: <name>" newline "SUMMARY: <one line>"
#   exit 0 = categorized, 2 = defer (Legion unreachable)
# Models (Legion Ollama, YOUR hardware — nothing external):
#   JEV_MODEL  System 1: qwen2.5:3b-instruct (fast fit-check + summary)
#   SYS2_MODEL System 2: qwen2.5:7b-instruct (names genuinely new categories)
set -euo pipefail
cd "$(dirname "$0")"
ROOT="${1:?usage: categorize.sh <root-dir> <item-name> <content-file>}"
ITEM="${2:?}"; CONTENT="${3:-/dev/null}"
JEV_MODEL="${JEV_MODEL:-qwen2.5:3b-instruct}"
SYS2_MODEL="${SYS2_MODEL:-qwen2.5:7b-instruct}"
[ -n "${LEGION_OLLAMA:-}" ] || { echo "categorize: no LEGION_OLLAMA" >&2; exit 2; }
mkdir -p "$ROOT"

call_ollama() {  # $1=model $2=prompt $3=timeout -> stdout response text
  PROMPT_TEXT="$2" python3 - "$LEGION_OLLAMA" "$1" "$3" <<'EOF' || return 2
import json, os, sys, urllib.request
base, model, timeout = sys.argv[1], sys.argv[2], int(sys.argv[3])
req = urllib.request.Request(base + "/api/generate",
    json.dumps({"model": model, "prompt": os.environ["PROMPT_TEXT"][:3000],
                "stream": False}).encode())
print(json.load(urllib.request.urlopen(req, timeout=timeout)).get("response", ""))
EOF
}

EXISTING="$(cd "$ROOT" && find . -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort | head -n 60)"
[ -n "$EXISTING" ] || EXISTING="(none yet)"
EXCERPT="$(head -c 1500 "$CONTENT" 2>/dev/null || true)"

# ---- System 1 (Jev): fit existing, or NEW? ----
S1="$(call_ollama "$JEV_MODEL" "You file personal items into folders. Existing folders: $(echo "$EXISTING" | tr '\n' ',' | sed 's/,$//'). Item name: $ITEM. Content: $EXCERPT. Reply EXACTLY two lines. Line 1: EXISTING: <folder name from the list> or NEW if nothing fits. Line 2: SUMMARY: <one short line about the item>." 120)" || exit 2
SUM1="$(echo "$S1" | grep -oi 'SUMMARY:.*' | head -n1 || true)"
WANT="$(echo "$S1" | grep -oi 'EXISTING: *[A-Za-z0-9 _-]*' | sed 's/.*EXISTING: *//I' | head -n1 || true)"
if echo "$S1" | grep -qi 'EXISTING:' && [ -n "$WANT" ]; then
  # Fuzzy-resolve Jev's pick against real dirs (it may misspell slightly).
  CAT="$(python3 - "$ROOT" "$WANT" <<'EOF'
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
print(best if score >= 0.8 else "")
EOF
)"
  if [ -n "$CAT" ]; then
    echo "CATEGORY: $CAT"; echo "${SUM1:-SUMMARY: $ITEM}"; exit 0
  fi
fi

# ---- System 2: Jev said NEW (or named nothing real) — invent the category ----
S2="$(call_ollama "$SYS2_MODEL" "You organize personal files. Existing folders: $(echo "$EXISTING" | tr '\n' ',' | sed 's/,$//'). Item: $ITEM. Content: $EXCERPT. Invent ONE short folder name (1-3 words) that fits alongside the existing ones, specific enough to be useful, general enough to reuse. Reply EXACTLY two lines. Line 1: CATEGORY: <name>. Line 2: SUMMARY: <one short line>." 300)" || exit 2
CAT2="$(echo "$S2" | grep -oi 'CATEGORY: *[A-Za-z0-9 _-]*' | sed 's/.*CATEGORY: *//I' | head -n1 || true)"
SUM2="$(echo "$S2" | grep -oi 'SUMMARY:.*' | head -n1 || true)"
CAT2="$(echo "$CAT2" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[^A-Za-z0-9 _-]//g;s/[[:space:]]\+/ /g' | cut -c1-40)"
[ -n "$CAT2" ] || { echo "categorize: system2 gave no name" >&2; exit 2; }
echo "CATEGORY: $CAT2"; echo "${SUM2:-SUMMARY: $ITEM}"
