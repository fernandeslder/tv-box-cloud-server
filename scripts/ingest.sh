#!/usr/bin/env bash
# ingest.sh — sort inbox uploads by type, Tier-0 scan docs, route secrets to private/.
# Usage: ./ingest.sh <inbox-dir>
# EVERYTHING stays accessible to you in Nextcloud/Immich. Only EXTERNAL sending is gated.
#   Photos/ Documents/ Videos/ Other/  — type-sorted, usable immediately
#   private/                            — secrets found, still yours, just separated
set -euo pipefail
cd "$(dirname "$0")"
INBOX="${1:?usage: ingest.sh <inbox-dir>}"
POOL="${POOL_ROOT:-/mnt/pool}"
QUEUE="$POOL/.ai-queue"
mkdir -p "$POOL/Photos" "$POOL/Documents" "$POOL/Videos" "$POOL/Other" "$POOL/private" "$QUEUE"

filetype() {
  local ext="${1##*.}"
  case "${ext,,}" in
    jpg|jpeg|png|gif|webp|heic|heif|raw|cr2|nef|arw|dng|tif|tiff|bmp) echo Photos; return ;;
    mp4|mkv|avi|mov|webm|m4v) echo Videos; return ;;
    mp3|flac|ogg|oga|wav|m4a|opus|aac) echo Other; return ;;  # audio -> Other (no Music tree per spec)
    pdf|txt|md|rst|csv|doc|docx|odt|xls|xlsx|ods|ppt|pptx|odp|epub) echo Documents; return ;;
  esac
  case "$(file -b --mime-type "$1")" in
    image/*) echo Photos ;; video/*) echo Videos ;;
    text/*|application/pdf|application/*document*|application/msword*) echo Documents ;;
    *) echo Other ;;
  esac
}

extract_text() {  # $1=file $2=out.txt — best-effort, empty is fine
  case "$1" in
    *.pdf|*.PDF) pdftotext "$1" "$2" 2>/dev/null || true ;;
    *.txt|*.md|*.csv) head -c 20000 "$1" > "$2" 2>/dev/null || true ;;
    *) tesseract "$1" stdout -l eng > "$2" 2>/dev/null || true ;;  # scans / screenshots
  esac
}

for src in "$INBOX"/*; do
  [ -e "$src" ] || { echo "inbox empty"; exit 0; }
  [ -f "$src" ] || continue
  base="$(basename "$src")"
  type="$(filetype "$src")"
  dest="$POOL/$type/$base"
  if ! mv -n "$src" "$dest" 2>/dev/null; then
    dest="$POOL/$type/$(date +%s)-$base"
    mv "$src" "$dest"
  fi
  echo "SORTED [$type] $base"

  if [ "$type" = "Documents" ]; then
    stem="${base%.*}"
    txt="$QUEUE/$stem.txt"
    extract_text "$dest" "$txt"
    rc=0; ./scan-secrets.sh "$dest" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "CLEAN $base -> queued Tier-1"
      echo "$dest" > "$QUEUE/$stem.pending"
    elif [ "$rc" -eq 1 ]; then
      echo "SECRETS $base -> private/"
      mv "$dest" "$POOL/private/"
    else
      echo "UNSCANNED $base (scanner unavailable) -> stays pending-ai"
      echo "$dest" > "$QUEUE/$stem.pending"
    fi
  else
    # Photos/Videos/Other: text-scan skipped at ingest (CPU OCR on everything is too slow).
    # Vision screening happens on the Legion via ai-queue.sh — allowed, it's yours.
    echo "$dest" > "$QUEUE/${base%.*}.pending"
    echo "QUEUED [$type] $base (pending-ai)"
  fi
done
