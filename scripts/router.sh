#!/usr/bin/env bash
# router.sh — confidence-gated escalation. Source it, don't run it.
# Priority: FREE local > self-hosted (Legion) > PAID (minimized, capped).
# Hard rule (code-enforced): SECRET verdicts NEVER route to paid APIs.
# Cost control: escalation sends at most ~4KB of transcript text, never raw files.
_ROUTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_CONF="${ROUTER_CONF:-$_ROUTER_DIR/../configs/router.conf}"
[ -f "$ROUTER_CONF" ] && set -a && . "$ROUTER_CONF" && set +a

PAID_ENABLED="${PAID_ENABLED:-false}"
ROUTER_CONFIDENCE_MIN="${ROUTER_CONFIDENCE_MIN:-70}"
PAID_MONTHLY_CAP_USD="${PAID_MONTHLY_CAP_USD:-2.00}"
PAID_PROVIDER_ORDER="${PAID_PROVIDER_ORDER:-gemini}"
GEMINI_MODEL="${GEMINI_MODEL:-gemini-2.0-flash}"
PAID_EST_PER_CALL_USD="${PAID_EST_PER_CALL_USD:-0.002}"
QUEUE_DIR_ROUTER="${AI_QUEUE_DIR:-/mnt/pool/.ai-queue}"
LEDGER_FILE="${LEDGER_FILE:-$QUEUE_DIR_ROUTER/spend.log}"

month_spend() {  # USD spent this calendar month
  local m sum
  m="$(date +%Y-%m)"; sum=0
  [ -f "$LEDGER_FILE" ] || { echo "0"; return; }
  sum="$(awk -v m="$m" '$1 ~ "^"m {s+=$4} END {printf "%.4f", s+0}' "$LEDGER_FILE")"
  echo "$sum"
}

over_budget() {
  awk -v s="$(month_spend)" -v c="$PAID_MONTHLY_CAP_USD" 'BEGIN {exit !(s+0 >= c+0)}'
}

# router_decide <CLEAN|SECRET> <confidence 0-100> -> stdout: LOCAL | PAID | DEFER | BLOCKED
router_decide() {
  local verdict="${1:?}" conf="${2:-0}"
  if [ "$verdict" = "SECRET" ]; then echo "BLOCKED"; return; fi       # hard block, no paid
  if [ "$conf" -ge "$ROUTER_CONFIDENCE_MIN" ]; then echo "LOCAL"; return; fi
  if [ "$PAID_ENABLED" != "true" ]; then echo "LOCAL"; return; fi    # accepted locally, logged
  if over_budget; then echo "DEFER"; return; fi
  echo "PAID"
}

router_spend_record() {  # $1=provider $2=job $3=amount
  mkdir -p "$(dirname "$LEDGER_FILE")"
  echo "$(date +%Y-%m-%dT%H:%M) $1 $2 $3" >> "$LEDGER_FILE"
}

# router_paid_opinion <transcript-file> -> 0 clean, 1 secret, 2 defer/fail. Records spend.
router_paid_opinion() {
  local txt="${1:?}" provider resp verdict conf
  [ "$PAID_ENABLED" = "true" ] || return 2
  if over_budget; then return 2; fi
  for provider in $PAID_PROVIDER_ORDER; do
    case "$provider" in
      gemini)
        [ -n "${GEMINI_API_KEY:-}" ] || continue
        resp="$(python3 - "$GEMINI_MODEL" "$GEMINI_API_KEY" "$txt" <<'EOF'
import json, sys, urllib.request
model, key, path = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()[:4000]
prompt = ("Does this text contain secret credentials (API keys, passwords, auth tokens, private keys)? "
          "Reply first line EXACTLY: VERDICT: CLEAN or VERDICT: SECRET, CONFIDENCE: 0-100. Text: " + text)
req = urllib.request.Request(
    f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={key}",
    json.dumps({"contents": [{"parts": [{"text": prompt}]}]}).encode(),
    {"Content-Type": "application/json"})
try:
    r = json.load(urllib.request.urlopen(req, timeout=60))
    print(r["candidates"][0]["content"]["parts"][0]["text"])
except Exception as e:
    sys.stderr.write(f"paid-call-failed: {e}\n"); sys.exit(2)
EOF
)" || continue
        verdict="$(echo "$resp" | grep -oi 'VERDICT: *SECRET' | head -n1 || true)"
        conf="$(echo "$resp" | grep -oi 'CONFIDENCE: *[0-9]\+' | grep -o '[0-9]\+' | head -n1)"
        router_spend_record "gemini" "$(basename "$txt")" "$PAID_EST_PER_CALL_USD"
        if [ -n "$verdict" ]; then return 1; fi
        return 0
        ;;
    esac
  done
  return 2
}
