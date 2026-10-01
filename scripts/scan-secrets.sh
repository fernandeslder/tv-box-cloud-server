#!/usr/bin/env bash
# scan-secrets.sh — Tier 0/1 secrets screening for new files. Local only, never cloud.
# Usage:
#   ./scan-secrets.sh <file-or-dir>            # Tier 0: TruffleHog deterministic scan (CPU, ms)
#   ./scan-secrets.sh --llm <text-file>        # Tier 1: Jev (System 1) judge on Legion via Ollama
#     stdout: judge answer whose first line is "VERDICT: CLEAN|SECRET, CONFIDENCE: 0-100"
# Exit 0 = clean (any confidence — caller routes on confidence), 1 = secret, 2 = couldn't scan.
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "--llm" ]; then
  FILE="${2:?usage: scan-secrets.sh --llm <text-file>}"
  # Jev noul decision (structured, typed) — never grep prose. See jev.sh.
  OUT="$(./jev.sh noul "Does this text contain secret credentials (API keys, passwords, auth tokens, private keys)? Text: $(head -c 6000 "$FILE")")" || exit 2
  DEC="$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['decision'])")"
  CON="$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['confidence'])")"
  if [ "$DEC" = "yes" ]; then echo "VERDICT: SECRET, CONFIDENCE: $CON"; exit 1; fi
  echo "VERDICT: CLEAN, CONFIDENCE: $CON"; exit 0
fi

TARGET="${1:?usage: scan-secrets.sh <file-or-dir>}"
command -v docker >/dev/null 2>&1 || { echo "scan-secrets: docker missing, Tier-0 unavailable" >&2; exit 2; }
MOUNT="$(realpath "$TARGET")"
# --no-verification: never phone providers to "verify" a live key.
docker run --rm -v "$MOUNT:/scan:ro" trufflesecurity/trufflehog:latest \
  filesystem /scan --no-verification --fail
