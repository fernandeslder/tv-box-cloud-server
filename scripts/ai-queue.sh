#!/usr/bin/env bash
# ai-queue.sh — drain the pending-AI queue when any Legion OS is reachable.
# Runs every 5 min via configs/systemd/ai-queue.{service,timer}. Quiet exit when offline.
# Routing (scripts/router.sh): FREE local > self-hosted Legion > PAID (only low-confidence
# CLEAN, only if PAID_ENABLED, only within monthly cap). SECRET verdicts NEVER go paid.
set -euo pipefail
cd "$(dirname "$0")"
. ./router.sh
POOL="${POOL_ROOT:-/mnt/pool}"
QUEUE="${AI_QUEUE_DIR:-$POOL/.ai-queue}"
PRIVATE_DIR="$POOL/private"
LEGION_HOSTS="${LEGION_HOSTS:-legion-linux legion-win}"
JUDGE_MODEL="${JUDGE_MODEL:-qwen2.5:3b-instruct}"
VISION_MODEL="${VISION_MODEL:-moondream}"

legion_up() {
  for h in $LEGION_HOSTS; do
    curl -sf -m 5 "http://$h:11434/api/tags" >/dev/null 2>&1 && { echo "$h"; return 0; }
  done
  return 1
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

parse_verdict() { grep -oi 'VERDICT: *\(CLEAN\|SECRET\)' "$1" | head -n1 | grep -oi 'CLEAN\|SECRET' || echo "UNKNOWN"; }
parse_conf() { grep -oi 'CONFIDENCE: *[0-9]\+' "$1" | grep -o '[0-9]\+' | head -n1 || echo 0; }

# route_transcript <transcript-file> <target-path> -> 0 clean-final, 1 secret-final, 2 defer
route_transcript() {
  local txt="$1" target="$2" out="" rc=0 verdict conf decision
  out="$(./scan-secrets.sh --llm "$txt")" || rc=$?
  [ "$rc" -eq 2 ] && return 2                                   # Legion vanished mid-run
  echo "$out" > "$txt.judge"
  verdict="$(parse_verdict "$txt.judge")"; conf="$(parse_conf "$txt.judge")"
  if [ "$verdict" = "UNKNOWN" ]; then echo "UNPARSEABLE $target (stays queued)"; return 2; fi
  decision="$(router_decide "$verdict" "$conf")"
  case "$decision" in
    LOCAL)   echo "CLEAN $target (local, conf $conf)"; return 0 ;;
    BLOCKED) echo "FLAGGED $target -> private/"; mv "$target" "$PRIVATE_DIR/" 2>/dev/null || true; return 1 ;;
    DEFER)   echo "NEEDS-PAID $target (conf $conf, over budget/off — stays queued)"; return 2 ;;
    PAID)
      echo "ESCALATING $target (conf $conf) — transcript only, ~4KB"
      rc=0; router_paid_opinion "$txt" || rc=$?
      if [ "$rc" -eq 0 ]; then echo "CLEAN $target (paid second opinion)"; return 0; fi
      if [ "$rc" -eq 1 ]; then echo "FLAGGED $target -> private/ (paid confirms)"; mv "$target" "$PRIVATE_DIR/" 2>/dev/null || true; return 1; fi
      echo "PAID-FAILED $target (stays queued)"; return 2 ;;
  esac
}

HOST="$(legion_up)" || { echo "legion offline, queue waits"; exit 0; }
OLLAMA="http://$HOST:11434"
export LEGION_OLLAMA="$OLLAMA"
echo "legion reachable via $HOST, draining $QUEUE (paid: $PAID_ENABLED, min-conf: $ROUTER_CONFIDENCE_MIN)"

mkdir -p "$QUEUE/done" "$PRIVATE_DIR"
for job in "$QUEUE"/*.pending; do
  [ -e "$job" ] || { echo "queue empty"; exit 0; }
  target="$(head -n 1 "$job")"
  if [ ! -e "$target" ]; then mv "$job" "$QUEUE/done/$(basename "$job").missing"; continue; fi

  case "$target" in
    *.jpg|*.jpeg|*.png|*.gif|*.webp|*.JPG|*.PNG)
      transcript="$(mktemp)"
      if ! vision_transcript "$OLLAMA" "$target" > "$transcript"; then
        rm -f "$transcript"; echo "VISION-BUSY $target (stays queued)"; continue
      fi
      if grep -qi '^NONE' "$transcript"; then
        echo "CLEAN $target (no text visible, Immich will index it)"
      else
        rc=0; route_transcript "$transcript" "$target" || rc=$?
        rm -f "$transcript"
        [ "$rc" -eq 2 ] && continue
      fi
      ;;
    *)
      if [ -f "$job.txt" ] || [ -f "${job%.pending}.txt" ]; then
        txt="$job.txt"; [ -f "$txt" ] || txt="${job%.pending}.txt"
        rc=0; route_transcript "$txt" "$target" || rc=$?
        [ "$rc" -eq 2 ] && continue
      else
        echo "SKIP $target (no transcript yet, stays pending-ai)"
        continue
      fi
      ;;
  esac
  mv "$job" "$QUEUE/done/"
done
