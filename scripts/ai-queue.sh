#!/usr/bin/env bash
# ai-queue.sh — drain the pending-AI queue when any Legion OS is reachable.
# Runs every 5 min via configs/systemd/ai-queue.{service,timer}. Quiet exit when offline.
# The Legion is YOURS, so unprocessed files may go there. Outside APIs: clean files only.
set -euo pipefail
cd "$(dirname "$0")"
QUEUE="${AI_QUEUE_DIR:-/mnt/pool/.ai-queue}"
LEGION_HOSTS="${LEGION_HOSTS:-legion-linux legion-win}"
JUDGE_MODEL="${JUDGE_MODEL:-qwen2.5:3b-instruct}"
VISION_MODEL="${VISION_MODEL:-moondream}"

legion_up() {
  for h in $LEGION_HOSTS; do
    curl -sf -m 5 "http://$h:11434/api/tags" >/dev/null 2>&1 && { echo "$h"; return 0; }
  done
  return 1
}

judge_text() {  # $1=ollama-base $2=text-file -> exit 0 clean, 1 secrets
  ./scan-secrets.sh --llm "$2" >/dev/null 2>&1
}

vision_transcript() {  # $1=ollama-base $2=image -> stdout transcript of visible text
  python3 - "$1" "$2" <<'EOF'
import json, sys, base64, urllib.request
base, img = sys.argv[1], sys.argv[2]
with open(img, 'rb') as f:
    b64 = base64.b64encode(f.read()).decode()
req = urllib.request.Request(base + '/api/generate',
    json.dumps({'model': 'moondream',
                'prompt': 'Transcribe any text, codes, or passwords visible in this image. If none, reply NONE.',
                'images': [b64], 'stream': False}).encode())
print(json.load(urllib.request.urlopen(req, timeout=300)).get('response', 'NONE'))
EOF
}

HOST="$(legion_up)" || { echo "legion offline, queue waits"; exit 0; }
OLLAMA="http://$HOST:11434"
export LEGION_OLLAMA="$OLLAMA"
echo "legion reachable via $HOST, draining $QUEUE"

mkdir -p "$QUEUE/done" /mnt/pool/private
for job in "$QUEUE"/*.pending; do
  [ -e "$job" ] || { echo "queue empty"; exit 0; }
  target="$(head -n 1 "$job")"
  if [ ! -e "$target" ]; then mv "$job" "$QUEUE/done/$(basename "$job").missing"; continue; fi

  case "$target" in
    *.jpg|*.jpeg|*.png|*.gif|*.webp|*.JPG|*.PNG)
      # Screenshot/photo: transcribe on YOUR Legion, judge the transcript.
      transcript="$(mktemp)"
      if ! vision_transcript "$OLLAMA" "$target" > "$transcript"; then
        rm -f "$transcript"; echo "VISION-BUSY $target (stays queued)"; continue
      fi
      if grep -qi '^NONE' "$transcript"; then
        echo "CLEAN $target (no text visible, Immich will index it)"
      else
        rc=0; judge_text "$OLLAMA" "$transcript" || rc=$?
        if [ "$rc" -eq 0 ]; then
          echo "CLEAN $target (text harmless)"
        elif [ "$rc" -eq 1 ]; then
          echo "FLAGGED $target -> private/"
          mv "$target" /mnt/pool/private/ 2>/dev/null || true
        else
          rm -f "$transcript"; echo "JUDGE-BUSY $target (stays queued)"; continue
        fi
      fi
      rm -f "$transcript"
      ;;
    *)
      if [ -f "$job.txt" ] || [ -f "${job%.pending}.txt" ]; then
        txt="$job.txt"; [ -f "$txt" ] || txt="${job%.pending}.txt"
        rc=0; judge_text "$OLLAMA" "$txt" || rc=$?
        if [ "$rc" -eq 0 ]; then
          echo "CLEAN $target"
        elif [ "$rc" -eq 1 ]; then
          echo "FLAGGED $target -> private/"
          mv "$target" /mnt/pool/private/ 2>/dev/null || true
        else
          echo "JUDGE-BUSY $target (stays queued)"; continue
        fi
      else
        echo "SKIP $target (no transcript yet, stays pending-ai)"
        continue
      fi
      ;;
  esac
  mv "$job" "$QUEUE/done/"
done
