#!/usr/bin/env bash
# ai-queue.sh — drain the pending-AI queue while a Legion is reachable. Quiet exit when offline.
# Runs every 5 min via configs/systemd/ai-queue.{service,timer} under flock.
# Routing (router.sh): Stage-0 local rules > Legion judge (unredacted: your hardware) >
#   external opinion (redacted, typed, capped) ONLY for low-confidence CLEAN. SECRET never leaves.
# Every job ends in done/ — nothing retries forever: binaries without text are marked done at once,
# and an unreachable external opinion is retried MAX_TRIES times, then the local verdict stands.
set -euo pipefail
cd "$(dirname "$0")"
POOL="${POOL_ROOT:-/mnt/pool}"
QUEUE="${AI_QUEUE_DIR:-$POOL/.ai-queue}"
export AI_QUEUE_DIR="$QUEUE"
. ./router.sh
PRIVATE_DIR="$POOL/private"
VISION_MODEL="${VISION_MODEL:-moondream}"
LEGION_HOSTS="${LEGION_HOSTS:-legion-linux legion-win}"
MAX_TRIES="${ROUTER_MAX_TRIES:-12}"

TMPS=()
mktmp() { local f; f="$(mktemp)"; TMPS+=("$f"); printf '%s' "$f"; }
cleanup() { [ "${#TMPS[@]}" -eq 0 ] || rm -f "${TMPS[@]}"; }
trap cleanup EXIT

legion_up() {
  local h
  for h in $LEGION_HOSTS; do
    curl -sf -m 5 "http://$h:11434/api/tags" >/dev/null 2>&1 && { echo "$h"; return 0; }
  done
  return 1
}

vision_transcript() {  # $1=ollama-base $2=image -> stdout transcript of visible text
  python3 - "$1" "$2" "$VISION_MODEL" <<'PY'
import json, sys, base64, urllib.request
base, img, model = sys.argv[1], sys.argv[2], sys.argv[3]
with open(img, 'rb') as f:
    b64 = base64.b64encode(f.read()).decode()
req = urllib.request.Request(base + '/api/generate',
    json.dumps({'model': model,
                'prompt': 'Transcribe any text, codes, or passwords visible in this image. If none, reply NONE.',
                'images': [b64], 'stream': False}).encode())
print(json.load(urllib.request.urlopen(req, timeout=300)).get('response', 'NONE'))
PY
}

jfield() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

to_private() {  # to_private <target> -> 0 moved
  ./safe-move.sh "$1" "$PRIVATE_DIR" >/dev/null 2>&1 && [ ! -e "$1" ]
}
bump_tries() {
  local f n=0
  f="$QUEUE/tries/$(basename "$CURRENT_JOB")"; mkdir -p "$QUEUE/tries"
  [ -f "$f" ] && n="$(cat "$f")"
  n=$((n + 1)); echo "$n" > "$f"; echo "$n"
}

# route_transcript <transcript> <target> -> 0 clean-final, 1 secret-final (moved), 2 defer (stay queued)
route_transcript() {
  local txt="$1" target="$2" out rc=0 verdict conf decision
  out="$(./scan-secrets.sh --llm "$txt")" || rc=$?
  [ "$rc" -eq 2 ] && return 2                                    # Legion vanished mid-run
  verdict="$(jfield "$out" verdict)"; conf="$(jfield "$out" confidence)"
  decision="$(router_decide "$verdict" "$conf")"
  case "$decision" in
    BLOCKED)
      if to_private "$target"; then echo "FLAGGED $target -> private/ (conf $conf)"; return 1; fi
      echo "MOVE-FAILED $target (stays queued)"; return 2 ;;
    LOCAL)
      [ "$conf" -ge "$ROUTER_CONFIDENCE_MIN" ] && echo "CLEAN $target (conf $conf)" \
        || echo "CLEAN? $target (low confidence $conf, external opinion unavailable: accepted locally)"
      return 0 ;;
    EXTERNAL)
      echo "ESCALATING $target (conf $conf): redacted transcript only"
      rc=0; router_external_opinion "$txt" || rc=$?
      case "$rc" in
        0) echo "CLEAN $target (external opinion)"; return 0 ;;
        1) if to_private "$target"; then echo "FLAGGED $target -> private/ (external opinion)"; return 1; fi
           echo "MOVE-FAILED $target (stays queued)"; return 2 ;;
        *) local n; n="$(bump_tries)"
           if [ "$n" -ge "$MAX_TRIES" ]; then echo "CLEAN? $target (external unavailable after $n tries: accepted locally)"; return 0; fi
           echo "EXTERNAL-UNAVAILABLE $target (try $n/$MAX_TRIES, stays queued)"; return 2 ;;
      esac ;;
  esac
  return 2
}

HOST="$(legion_up)" || { echo "legion offline, queue waits"; exit 0; }
OLLAMA="http://$HOST:11434"
export LEGION_OLLAMA="$OLLAMA" WHISPER_URL="http://$HOST:9000"
echo "legion reachable via $HOST; draining $QUEUE (external: $(external_available && echo on || echo off), min-conf $ROUTER_CONFIDENCE_MIN, spent this month \$$(month_spend))"

mkdir -p "$QUEUE/done" "$PRIVATE_DIR"
shopt -s nullglob
jobs=("$QUEUE"/*.pending)
[ "${#jobs[@]}" -gt 0 ] || { echo "queue empty"; exit 0; }

for job in "${jobs[@]}"; do
  CURRENT_JOB="$job"
  target="$(head -n 1 "$job")"
  base="${job%.pending}"
  if [ ! -e "$target" ]; then mv "$job" "$QUEUE/done/$(basename "$job").missing"; continue; fi
  lt="$(lower "$target")"

  case "$lt" in
    *.jpg|*.jpeg|*.png|*.gif|*.webp)
      transcript="$(mktmp)"
      if ! vision_transcript "$OLLAMA" "$target" > "$transcript" 2>/dev/null; then echo "VISION-BUSY $target (stays queued)"; continue; fi
      if grep -qi '^NONE' "$transcript"; then
        echo "CLEAN $target (no text visible; Immich indexes it)"
      else
        # Stage-0 local rules on what the photo SAYS: an ID photo never goes to any model beyond the Legion.
        rc0=0; ./sort-docs.sh --stage0 "$target" "$transcript" >/dev/null 2>&1 || rc0=$?
        if [ "$rc0" -ne 0 ]; then
          rc=0; route_transcript "$transcript" "$target" || rc=$?
          [ "$rc" -eq 2 ] && continue
        fi
      fi ;;
    *.mp3|*.flac|*.ogg|*.wav|*.m4a|*.opus|*.aac|*.oga)
      # NOMOVE=1: sort-music only reports speech on stdout; we place it after screening.
      transcript="$(mktmp)"
      rc=0; NOMOVE=1 ./sort-music.sh "$target" > "$transcript" 2>/dev/null || rc=$?
      if [ "$rc" -eq 0 ]; then :                                    # organised under Music/<Artist>/
      elif [ "$rc" -eq 1 ]; then
        rc=0; route_transcript "$transcript" "$target" || rc=$?
        if [ "$rc" -eq 0 ]; then
          { ./safe-move.sh "$target" "$POOL/Recordings" >/dev/null && [ ! -e "$target" ]; } || { echo "MOVE-FAILED $target (stays queued)"; continue; }
        elif [ "$rc" -eq 2 ]; then continue; fi
      else echo "AUDIO-BUSY $target (stays queued)"; continue; fi ;;
    *)
      txt="$base.transcript"
      if [ -f "$txt" ]; then
        rc=0; route_transcript "$txt" "$target" || rc=$?
        [ "$rc" -eq 2 ] && continue
        if [ "$rc" -eq 0 ]; then
          rc2=0; ./sort-docs.sh --stage1 "$target" "$txt" >/dev/null 2>&1 || rc2=$?
          [ "$rc2" -eq 2 ] && { echo "SORT-DEFERRED $target (Legion busy, stays queued)"; continue; }
        fi
      else
        # Video/archive/other: nothing to read. Filename rules already ran at ingest. Terminal.
        echo "DONE $target (binary: no text to screen)"
      fi ;;
  esac
  rm -f "$base.transcript" "$base.txt" "$QUEUE/tries/$(basename "$job")" 2>/dev/null || true
  mv "$job" "$QUEUE/done/"
done
