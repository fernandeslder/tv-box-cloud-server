#!/usr/bin/env bash
# sort-music.sh — speech-vs-music split + Artist/[Album]/ organization. ON-PREMISE ONLY.
# Usage: WHISPER_URL=http://<legion>:9000 ./sort-music.sh <audio-file-under-pool>
# Exit 0 = organized as music. Exit 1 = speech -> Recordings/ (transcript on stdout).
# Exit 2 = defer (whisper unreachable or ffprobe missing — stays pending-ai).
set -euo pipefail
cd "$(dirname "$0")"
POOL="${POOL_ROOT:-/mnt/pool}"
mkdir -p "$POOL/Music"
FILE="${1:?usage: sort-music.sh <audio-file>}"
WHISPER_URL="${WHISPER_URL:-}"
command -v ffprobe >/dev/null 2>&1 || { echo "sort-music: ffprobe missing" >&2; exit 2; }

tags() {  # artist|album|title (empty fields allowed)
  ffprobe -v error -show_entries format_tags=artist,album,title \
    -of default=nw=1 "$FILE" 2>/dev/null | sed 's/^TAG://' || true
}
ARTIST="$(tags | grep -i '^artist=' | cut -d= -f2- | head -n1 || true)"
ALBUM="$(tags | grep -i '^album=' | cut -d= -f2- | head -n1 || true)"
jev_split() {  # $1=basename-noext -> "ARTIST<TAB>TITLE" (Jev fields decision, typed)
  local out artist title only
  ARTISTS="$(cd "$POOL/Music" 2>/dev/null && find . -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort | head -n 30 | tr '\n' ',' | sed 's/,$//')"
  out="$( { echo "You know music: artists, songs, albums. Music filename (may be 'Artist - Title', 'Title - Artist', or just 'Title'; words may run together): $1. Artists already in library: $ARTISTS. artist = the performing artist (use your knowledge; empty string if truly unidentifiable), title = the song name, title_only = true if no artist is identifiable."; } | ./jev.sh fields '{"artist":"string","title":"string","title_only":"boolean"}' -)" || return 2
  artist="$(echo "$out" | python3 -c "import json,sys; print(json.load(sys.stdin).get('artist',''))")"
  title="$(echo "$out" | python3 -c "import json,sys; print(json.load(sys.stdin).get('title',''))")"
  only="$(echo "$out" | python3 -c "import json,sys; print('yes' if json.load(sys.stdin).get('title_only') else 'no')")"
  [ -n "$title" ] || return 1
  if [ "$only" = "yes" ] || [ -z "$artist" ]; then printf 'Unknown Artist\t%s' "$title";
  else printf '%s\t%s' "$artist" "$title"; fi
}
if [ -z "$ARTIST" ]; then  # no embedded tag: Jev splits by general knowledge
  basebn="$(basename "$FILE")"; basebn="${basebn%.*}"
  SPLIT=""
  if [ -n "${LEGION_OLLAMA:-}" ]; then
    SPLIT="$(jev_split "$basebn" 2>/dev/null)" || SPLIT=""
  fi
  if [ -n "$SPLIT" ]; then
    ARTIST="${SPLIT%%$'\t'*}"
    [ -n "$ARTIST" ] || ARTIST="Unknown Artist"
  else  # Jev unreachable: dumb "A - B" heuristic, corrected on next queue pass
    case "$basebn" in *" - "*) ARTIST="${basebn%% - *}";; *) ARTIST="Unknown Artist";; esac
  fi
fi

# Speech check via Legion whisper (OpenAI-compatible /v1/audio/transcriptions).
[ -n "$WHISPER_URL" ] || { echo "sort-music: no WHISPER_URL" >&2; exit 2; }
TRANSCRIPT="$(mktemp)"
if ! curl -sf -m 300 -F file=@"$FILE" -F response_format=json \
    "$WHISPER_URL/v1/audio/transcriptions" -o "$TRANSCRIPT" 2>/dev/null; then
  rm -f "$TRANSCRIPT"; echo "sort-music: whisper unreachable" >&2; exit 2
fi
TEXT="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('text',''))" "$TRANSCRIPT" 2>/dev/null)" || { rm -f "$TRANSCRIPT"; echo "sort-music: bad whisper JSON" >&2; exit 2; }
WORDS="$(echo "$TEXT" | wc -w)"
if [ "$WORDS" -ge 8 ]; then
  SPOKEN="$TEXT"
  rm -f "$TRANSCRIPT"
  if [ "${NOMOVE:-0}" = "1" ]; then
    # Caller decides placement (ai-queue routes the transcript first).
    echo "$SPOKEN"; exit 1
  fi
  dest="$(./safe-move.sh "$FILE" "$POOL/Recordings")"
  echo "$SPOKEN"
  echo "SPEECH $dest ($WORDS words)" >&2
  exit 1
fi
rm -f "$TRANSCRIPT"

# Fuzzy artist match — three passes over normalized names:
#   1. plain ratio, 2. ignoring a leading "the ", 3. alphanumeric-only
# (catches "BeatLes", "  beatles ", one-letter typos, "Beat les" vs "The Beatles").
# Threshold 0.82; a new folder is created only when nothing existing is close.
MATCH="$(python3 - "$POOL/Music" "$ARTIST" <<'EOF'
import difflib, os, re, sys
music, artist = sys.argv[1], sys.argv[2]
def norm(s):
    return " ".join(s.strip().lower().split())
def variants(s):
    s = norm(s)
    yield s
    yield re.sub(r"^the ", "", s)
    yield re.sub(r"[^a-z0-9]", "", s)
cands = [d for d in os.listdir(music)
         if os.path.isdir(os.path.join(music, d)) and d != "Recordings"]
best, score = "", 0.0
for d in cands:
    s = max(difflib.SequenceMatcher(None, a, b).ratio()
            for a in variants(artist) for b in variants(d))
    if s > score:
        best, score = d, s
print(best if score >= 0.82 else "")
EOF
)" || exit 2   # python failure must not look like exit 1 (= speech)
# Tags and model output are untrusted: no slashes, no leading dots, no control chars, bounded length.
# shellcheck disable=SC1003
clean() {
  local v
  v="$(printf '%s' "$1" | tr -d '\000-\037' | tr '/\\' '__' | sed 's/^[[:space:].]*//;s/[[:space:]]*$//;s/[[:space:]]\+/ /g' | cut -c1-80)"
  case "$v" in ''|.|..) v="Unknown Artist" ;; esac
  printf '%s' "$v"
}
if [ -n "$MATCH" ]; then ARTIST="$MATCH"; else ARTIST="$(clean "$ARTIST")"; fi
if [ -n "$ALBUM" ]; then ALBUM="$(clean "$ALBUM")"; fi
dest="$POOL/Music/$ARTIST"
[ -n "$ALBUM" ] && dest="$dest/$ALBUM"
target="$(./safe-move.sh "$FILE" "$dest")"
echo "MUSIC $target" >&2
