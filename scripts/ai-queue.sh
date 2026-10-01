#!/usr/bin/env bash
# ai-queue.sh — drain the pending-AI queue when any Legion OS is reachable.
# Runs every 5 min via configs/systemd/ai-queue.{service,timer}. Quiet exit when offline.
set -euo pipefail
cd "$(dirname "$0")"
QUEUE="${AI_QUEUE_DIR:-/mnt/pool/.ai-queue}"
LEGION_HOSTS="${LEGION_HOSTS:-legion-linux legion-win}"

legion_up() {
  for h in $LEGION_HOSTS; do
    curl -sf -m 5 "http://$h:11434/api/tags" >/dev/null 2>&1 && { echo "$h"; return 0; }
  done
  return 1
}

HOST="$(legion_up)" || { echo "legion offline, queue waits"; exit 0; }
export LEGION_OLLAMA="http://$HOST:11434"
echo "legion reachable via $HOST, draining $QUEUE"

mkdir -p "$QUEUE/done"
for job in "$QUEUE"/*.pending; do
  [ -e "$job" ] || { echo "queue empty"; exit 0; }
  target="$(head -n 1 "$job")"
  if [ ! -e "$target" ]; then mv "$job" "$QUEUE/done/$(basename "$job").missing"; continue; fi
  # Tier-1 judge on extracted text sidecar (<job>.txt written at ingest by Tier 0 step)
  if ./scan-secrets.sh --llm "$job.txt" 2>/dev/null; then
    rm -f "$target.pending-ai" 2>/dev/null || true  # placeholder: real tagging via Immich/Nextcloud API
    echo "CLEAN $target"
  else
    echo "FLAGGED $target -> quarantine"
    mkdir -p /mnt/pool/quarantine
    mv "$target" /mnt/pool/quarantine/ 2>/dev/null || true
  fi
  mv "$job" "$QUEUE/done/"
done
