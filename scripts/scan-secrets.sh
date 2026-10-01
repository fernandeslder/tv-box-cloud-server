#!/usr/bin/env bash
# scan-secrets.sh — Tier 0/1 secrets screening for new files. Local only, never cloud.
# Usage:
#   ./scan-secrets.sh <file-or-dir>            # Tier 0: TruffleHog deterministic scan (CPU, ms)
#   ./scan-secrets.sh --llm <text-file>        # Tier 1: "Jeff" judge on Legion via Ollama
# Exit 0 = clean, 1 = secrets found (route to private/), 2 = couldn't scan (stay queued).
set -euo pipefail
cd "$(dirname "$0")"

LEGION_HOSTS="${LEGION_HOSTS:-legion-linux legion-win}"  # dual-boot Legion: whichever OS is up
JUDGE_MODEL="${JUDGE_MODEL:-qwen2.5:3b-instruct}"

legion_ollama() {
  # ${LEGION_OLLAMA:-} wins if set; else first reachable host in LEGION_HOSTS
  if [ -n "${LEGION_OLLAMA:-}" ]; then echo "$LEGION_OLLAMA"; return 0; fi
  for h in $LEGION_HOSTS; do
    curl -sf -m 5 "http://$h:11434/api/tags" >/dev/null 2>&1 && { echo "http://$h:11434"; return 0; }
  done
  echo "error: no Legion OS reachable (tried: $LEGION_HOSTS)" >&2
  return 1
}

if [ "${1:-}" = "--llm" ]; then
  FILE="${2:?usage: scan-secrets.sh --llm <text-file>}"
  OLLAMA_URL="$(legion_ollama)" || exit 2  # exit 2 = legion offline, keep job queued
  PROMPT="Does the following text contain secret credentials (API keys, passwords, auth tokens, private keys)? Reply with exactly YES <type> or NO. Text: $(head -c 6000 "$FILE")"
  ANSWER=$(curl -s -m 120 "$OLLAMA_URL/api/generate" \
    -d "$(python3 -c "import json,sys; print(json.dumps({'model': sys.argv[1], 'prompt': open(sys.argv[2]).read()[:6000], 'stream': False}))" "$JUDGE_MODEL" <(echo "$PROMPT"))" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('response',''))")
  echo "$ANSWER"
  echo "$ANSWER" | grep -qi '^YES' && exit 1 || exit 0
fi

TARGET="${1:?usage: scan-secrets.sh <file-or-dir>}"
command -v docker >/dev/null 2>&1 || { echo "scan-secrets: docker missing, Tier-0 unavailable" >&2; exit 2; }
MOUNT="$(realpath "$TARGET")"
# --no-verification: never phone providers to "verify" a live key.
docker run --rm -v "$MOUNT:/scan:ro" trufflesecurity/trufflehog:latest \
  filesystem /scan --no-verification --fail
