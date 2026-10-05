#!/usr/bin/env bash
# ingest.sh — sort inbox uploads by type, Tier-0 scan documents, route secrets to private/.
# Usage: ./ingest.sh <inbox-dir>
# EVERYTHING stays accessible to you (Samba/Nextcloud/Immich). Only EXTERNAL sending is gated.
#   Photos/ Documents/ Music/ Recordings/ Videos/ Other/   type-sorted, usable immediately
#   private/                                                secrets + IDs/finance/health, still yours
# Safe to run concurrently (flock), skips files still being written, never overwrites (safe-move).
set -euo pipefail
cd "$(dirname "$0")"
INBOX="${1:?usage: ingest.sh <inbox-dir>}"
POOL="${POOL_ROOT:-/mnt/pool}"
QUEUE="${AI_QUEUE_DIR:-$POOL/.ai-queue}"
SETTLE_MIN="${INGEST_SETTLE_MIN:-2}"       # a file must be untouched this long (mid-upload guard)
mkdir -p "$POOL/Photos" "$POOL/Documents" "$POOL/Music" "$POOL/Recordings" "$POOL/Videos" "$POOL/Other" "$POOL/private" "$QUEUE"

LOCK="${INGEST_LOCK:-$QUEUE/.ingest.lock}"
exec 9>"$LOCK"; flock -n 9 || { echo "ingest: already running"; exit 0; }

filetype() {
  local ext="${1##*.}"
  case "${ext,,}" in
    jpg|jpeg|png|gif|webp|heic|heif|raw|cr2|nef|arw|dng|tif|tiff|bmp) echo Photos; return ;;
    mp4|mkv|avi|mov|webm|m4v) echo Videos; return ;;
    mp3|flac|ogg|oga|wav|m4a|opus|aac) echo Music; return ;;
    pdf|txt|md|rst|csv|doc|docx|odt|xls|xlsx|ods|ppt|pptx|odp|epub) echo Documents; return ;;
  esac
  case "$(file -b --mime-type "$1")" in
    image/*) echo Photos ;; video/*) echo Videos ;; audio/*) echo Music ;;
    text/*|application/pdf|application/*document*|application/msword*) echo Documents ;;
    *) echo Other ;;
  esac
}

zip_text() {  # zip_text <file> <member-glob...>  -> tag-stripped text from OOXML/ODF/epub members
  unzip -p "$1" "${@:2}" 2>/dev/null | sed -e 's/<[^>]*>/ /g' | tr -s '[:space:]' ' ' | head -c 60000
}
extract_text() {  # $1=file $2=out.txt — best effort; empty is fine
  local f="$1" out="$2" lc
  lc="$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')"
  case "$lc" in
    *.pdf)
      pdftotext -l 20 "$f" "$out" 2>/dev/null || true
      if [ ! -s "$out" ] || [ "$(wc -w < "$out")" -lt 5 ]; then   # scanned PDF: OCR first pages
        local d; d="$(mktemp -d)"
        pdftoppm -r 150 -f 1 -l 3 -png "$f" "$d/p" 2>/dev/null || true
        for p in "$d"/p*.png; do [ -e "$p" ] && tesseract "$p" stdout -l eng 2>/dev/null >> "$out" || true; done
        rm -rf "$d"
      fi ;;
    *.txt|*.md|*.csv|*.rst) head -c 60000 "$f" > "$out" 2>/dev/null || true ;;
    *.docx) zip_text "$f" 'word/document.xml' > "$out" ;;
    *.xlsx) zip_text "$f" 'xl/sharedStrings.xml' > "$out" ;;
    *.pptx) zip_text "$f" 'ppt/slides/slide*.xml' > "$out" ;;
    *.odt|*.ods|*.odp) zip_text "$f" 'content.xml' > "$out" ;;
    *.epub) zip_text "$f" '*.xhtml' '*.html' > "$out" ;;
    *.doc|*.xls|*.ppt) strings -n 6 "$f" 2>/dev/null | head -c 60000 > "$out" || true ;;
    *.jpg|*.jpeg|*.png|*.tif|*.tiff|*.bmp) tesseract "$f" stdout -l eng > "$out" 2>/dev/null || true ;;
    *) : > "$out" ;;
  esac
  [ -f "$out" ] || : > "$out"
}

queue() { echo "$1" > "$QUEUE/$(basename "$1").pending"; }

# Oldest first, only settled files, skip in-flight temp names from sync clients.
while IFS= read -r -d '' src; do
  [ -f "$src" ] || continue
  case "$(basename "$src")" in *.part|*.partial|*.tmp|*.crdownload|.~lock.*|~\$*|.DS_Store|Thumbs.db) continue ;; esac
  type="$(filetype "$src")"
  dest="$(./safe-move.sh "$src" "$POOL/$type")"
  base="$(basename "$dest")"
  echo "SORTED [$type] $base"

  # Stage-0 on the FILENAME for every type: "passport.jpg" is private whatever it contains.
  if [ "$type" != Documents ] && ./sort-docs.sh --stage0 "$dest" /dev/null >/dev/null 2>&1; then
    echo "PRIVATE-SORTED $base (filename rule)"; continue
  fi

  if [ "$type" = Documents ]; then
    # Sidecar names keep the FULL basename (a.pdf + a.txt must not collide).
    txt="$QUEUE/$base.transcript"
    extract_text "$dest" "$txt"
    rc=0; ./scan-secrets.sh "$dest" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 1 ]; then
      echo "SECRETS $base -> private/"
      ./sort-docs.sh --stage0 "$dest" "$txt" >/dev/null 2>&1 || ./safe-move.sh "$dest" "$POOL/private" >/dev/null
      rm -f "$txt"; continue
    fi
    # Stage-0 local rules run on EVERY path (clean, or scanner unavailable): offline, instant.
    rc0=0; ./sort-docs.sh --stage0 "$dest" "$txt" >/dev/null 2>&1 || rc0=$?
    if [ "$rc0" -eq 0 ]; then echo "PRIVATE-SORTED $base (no queue)"; rm -f "$txt"; continue; fi
    [ "$rc" -eq 0 ] && echo "CLEAN $base -> queued Tier-1" || echo "UNSCANNED $base (TruffleHog unavailable) -> queued"
    queue "$dest"
  else
    # Photos/Videos/Music/Other: vision/audio screening happens on the Legion via ai-queue.sh.
    queue "$dest"; echo "QUEUED [$type] $base (pending-ai)"
  fi
done < <(find "$INBOX" -type f -mmin "+$SETTLE_MIN" -printf '%T@ %p\0' | sort -z -n | cut -z -d' ' -f2-)

# Remove sub-folders emptied by the moves (never the inbox itself).
find "$INBOX" -mindepth 1 -type d -empty -mmin "+$SETTLE_MIN" -delete 2>/dev/null || true
