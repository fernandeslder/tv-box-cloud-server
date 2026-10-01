#!/usr/bin/env bash
# sort-music.sh — speech-vs-music split + Artist/[Album]/ organization. ON-PREMISE ONLY.
# Usage: WHISPER_URL=http://<legion>:9000 ./sort-music.sh <audio-file-under-pool>
# Exit 0 = organized as music. Exit 1 = speech -> Recordings/ (transcript on stdout).
# Exit 2 = defer (whisper unreachable or ffprobe missing — stays pending-ai).
set -euo pipefail
cd "$(dirname "$0")"
POOL="${POOL_ROOT:-/mnt/pool}"
FILE="${1:?usage: sort-music.sh <audio-file>}"
WHISPER_URL="${WHISPER_URL:-}"
command -v ffprobe >/dev/null 2>&1 || { echo "sort-music: ffprobe missing" >&2; exit 2; }

tags() {  # artist|album|title (empty fields allowed)
  ffprobe -v error -show_entries format_tags=artist,album,title \
    -of default=nw=1 "$FILE" 2>/dev/null | sed 's/^TAG://' || true
}
ARTIST="$(tags | grep -i '^artist=' | cut -d= -f2- | head -n1 || true)"
ALBUM="$(tags | grep -i '^album=' | cut -d= -f2- | head -n1 || true)"
if [ -z "$ARTIST" ]; then  # fallback: "Artist - Title.ext"
  base="$(basename "$FILE")"; base="${base%.*}"
  case "$base" in *" - "*) ARTIST="${base%% - *}";; *) ARTIST="Unknown Artist";; esac
fi

# Speech check via Legion whisper (OpenAI-compatible /v1/audio/transcriptions).
[ -n "$WHISPER_URL" ] || { echo "sort-music: no WHISPER_URL" >&2; exit 2; }
TRANSCRIPT="$(mktemp)"
if ! curl -sf -m 300 -F file=@"$FILE" -F response_format=json \
    "$WHISPER_URL/v1/audio/transcriptions" -o "$TRANSCRIPT" 2>/dev/null; then
  rm -f "$TRANSCRIPT"; echo "sort-music: whisper unreachable" >&2; exit 2
fi
WORDS="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('text',''))" "$TRANSCRIPT" | wc -w)"
if [ "$WORDS" -ge 8 ]; then
  SPOKEN="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('text',''))" "$TRANSCRIPT")"
  rm -f "$TRANSCRIPT"
  if [ "${NOMOVE:-0}" = "1" ]; then
    # Caller decides placement (ai-queue routes the transcript first).
    echo "$SPOKEN"; exit 1
  fi
  mkdir -p "$POOL/Recordings"
  dest="$POOL/Recordings/$(basename "$FILE")"
  [ -e "$dest" ] && dest="$POOL/Recordings/$(date +%s)-$(basename "$FILE")"
  mv "$FILE" "$dest"
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
)"
clean() { echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]]\+/ /g'; }
if [ -n "$MATCH" ]; then ARTIST="$MATCH"; else ARTIST="$(clean "$ARTIST")"; fi
ALBUM="$(clean "$ALBUM")"
dest="$POOL/Music/$ARTIST"
[ -n "$ALBUM" ] && dest="$dest/$ALBUM"
mkdir -p "$dest"
target="$dest/$(basename "$FILE")"
[ -e "$target" ] && target="$dest/$(date +%s)-$(basename "$FILE")"
mv "$FILE" "$target"
echo "MUSIC $target" >&2
