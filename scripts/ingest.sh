#!/usr/bin/env bash
# ingest.sh — sort inbox uploads by type, Tier-0 scan docs, route secrets to private/.
# Usage: ./ingest.sh <inbox-dir>
# EVERYTHING stays accessible to you in Nextcloud/Immich. Only EXTERNAL sending is gated.
#   Photos/ Documents/ Music/ Videos/ Other/  — type-sorted, usable immediately
#   private/                            — secrets found, still yours, just separated
set -euo pipefail
cd "$(dirname "$0")"
INBOX="${1:?usage: ingest.sh <inbox-dir>}"
POOL="${POOL_ROOT:-/mnt/pool}"
QUEUE="$POOL/.ai-queue"
mkdir -p "$POOL/Photos" "$POOL/Documents" "$POOL/Music" "$POOL/Recordings" "$POOL/Videos" "$POOL/Other" "$POOL/private" "$QUEUE"

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
  # safe-move: same content -> duplicates/ (you review), different -> "name (1).ext". Never overwrites.
  dest="$(./safe-move.sh "$src" "$POOL/$type")"
  base="$(basename "$dest")"
  echo "SORTED [$type] $base"

  if [ "$type" = "Documents" ]; then
    # Job/sidecar names keep the FULL basename (a.pdf + a.txt must not collide).
    txt="$QUEUE/$base.transcript"
    extract_text "$dest" "$txt"
    rc=0; ./scan-secrets.sh "$dest" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
      # Stage-0 local rules first: IDs/finance/health go private/ even with
      # zero secrets found (a driver's license has no "password" in it).
      rc0=0; ./sort-docs.sh --stage0 "$dest" "$txt" >/dev/null 2>&1 || rc0=$?
      if [ "$rc0" -eq 0 ]; then
        echo "PRIVATE-SORTED $base (no queue)"
        rm -f "$txt"
      else
        echo "CLEAN $base -> queued Tier-1"
        echo "$dest" > "$QUEUE/$base.pending"
      fi
    elif [ "$rc" -eq 1 ]; then
      echo "SECRETS $base -> sub-sorting private/"
      ./sort-docs.sh --stage0 "$dest" "$txt" >/dev/null 2>&1 \
        || ./safe-move.sh "$dest" "$POOL/private" >/dev/null
      rm -f "$txt"
    else
      echo "UNSCANNED $base (scanner unavailable) -> stays pending-ai"
      echo "$dest" > "$QUEUE/$base.pending"
    fi
  else
    # Photos/Videos/Music/Other: text-scan skipped at ingest (CPU OCR on everything is too slow).
    # Vision screening happens on the Legion via ai-queue.sh — allowed, it's yours.
    echo "$dest" > "$QUEUE/$base.pending"
    echo "QUEUED [$type] $base (pending-ai)"
  fi
done
