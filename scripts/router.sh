#!/usr/bin/env bash
# router.sh — confidence-gated escalation. Source it, don't run it.
# Priority: FREE local > self-hosted (Legion) > PAID (minimized, capped).
# Hard rule (code-enforced): SECRET verdicts NEVER route to paid APIs.
# Cost control: escalation sends at most ~4KB of transcript text, never raw files.
_ROUTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_CONF="${ROUTER_CONF:-$_ROUTER_DIR/../configs/router.conf}"
[ -f "$ROUTER_CONF" ] && set -a && . "$ROUTER_CONF" && set +a
# Machine-managed daily picks (price-check.sh). Overrides router.conf — never hand-edit.
ROUTER_MANAGED="${ROUTER_MANAGED:-$_ROUTER_DIR/../configs/router.managed.conf}"
[ -f "$ROUTER_MANAGED" ] && set -a && . "$ROUTER_MANAGED" && set +a

PAID_ENABLED="${PAID_ENABLED:-false}"
ROUTER_CONFIDENCE_MIN="${ROUTER_CONFIDENCE_MIN:-70}"
PAID_MONTHLY_CAP_USD="${PAID_MONTHLY_CAP_USD:-2.00}"
PAID_PROVIDER_ORDER="${PAID_PROVIDER_ORDER:-gemini}"
GEMINI_MODEL="${GEMINI_MODEL:-gemini-2.5-flash-lite}"  # legacy default; provider blocks below win
GROQ_MODEL="${GROQ_MODEL:-openai/gpt-oss-20b}"
GROQ_BASE_URL="${GROQ_BASE_URL:-https://api.groq.com/openai/v1}"
GEMINI_BASE_URL="${GEMINI_BASE_URL:-https://generativelanguage.googleapis.com/v1beta/openai/}"
PAID_EST_PER_CALL_USD="${PAID_EST_PER_CALL_USD:-0.0002}"
QUEUE_DIR_ROUTER="${AI_QUEUE_DIR:-/mnt/pool/.ai-queue}"
LEDGER_FILE="${LEDGER_FILE:-$QUEUE_DIR_ROUTER/spend.log}"
PRICES_FILE="${PRICES_FILE:-$_ROUTER_DIR/../configs/prices.json}"

# Free-tier via OpenCode CLI (your quota, $0). One `opencode auth login` on the box, once.
OPENCODE_ENABLED="${OPENCODE_ENABLED:-true}"
OPENCODE_MODEL="${OPENCODE_MODEL:-opencode/mimo-v2.6-flash-free}"
OPENCODE_TIMEOUT="${OPENCODE_TIMEOUT:-120}"

# OpenRouter pipe (one key, daily-picked models). FREE_MODEL = :free pick ($0),
# MODEL = cheapest paid pick (capped). Managed by price-check.sh.
OPENROUTER_BASE_URL="${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}"
OPENROUTER_MODEL="${OPENROUTER_MODEL:-}"
OPENROUTER_FREE_MODEL="${OPENROUTER_FREE_MODEL:-}"
OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"

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
# Ladder inside escalation: opencode-free ($0 quota) -> openrouter-:free ($0) -> paid (capped).
# Transcript-only (~4KB), clean files only — SECRET never reaches here (caller BLOCKED it).
router_paid_opinion() {
  local txt="${1:?}" out="" rc=0 verdict
  [ "$PAID_ENABLED" = "true" ] || [ "$OPENCODE_ENABLED" = "true" ] || return 2

  # Step 0 — OpenCode free tier via CLI ($0, your quota).
  if [ "$OPENCODE_ENABLED" = "true" ]; then
    out="$(free_opencode_call "$txt")" || rc=$?
    if [ "$rc" -eq 0 ]; then
      verdict="$(echo "$out" | grep -oi 'VERDICT: *SECRET' | head -n1 || true)"
      router_spend_record "opencode-free" "$(basename "$txt")" "0.0000"
      if [ -n "$verdict" ]; then return 1; fi
      return 0
    fi
    # rc=2 (no CLI / not logged in / timeout) -> fall through silently
  fi

  # Step 1 — OpenRouter :free pick ($0, needs free key).
  if [ -n "$OPENROUTER_API_KEY" ] && [ -n "$OPENROUTER_FREE_MODEL" ]; then
    out=""; rc=0
    out="$(paid_openai_call "$OPENROUTER_BASE_URL" "$OPENROUTER_FREE_MODEL" "$OPENROUTER_API_KEY" "$txt")" || rc=$?
    if [ "$rc" -eq 0 ]; then
      verdict="$(echo "$out" | grep -oi 'VERDICT: *SECRET' | head -n1 || true)"
      router_spend_record "openrouter-free" "$(basename "$txt")" "0.0000"
      if [ -n "$verdict" ]; then return 1; fi
      return 0
    fi
  fi

  # Step 2 — paid, cheapest-first, capped. Every provider speaks OpenAI /chat/completions.
  [ "$PAID_ENABLED" = "true" ] || return 2
  if over_budget; then return 2; fi
  local provider upper base model key
  for provider in $(effective_paid_order); do
    if over_budget; then return 2; fi
    upper="$(echo "$provider" | tr '[:lower:]' '[:upper:]')"
    base="${upper}_BASE_URL"; base="${!base:-}"
    model="${upper}_MODEL"; model="${!model:-}"
    key="${upper}_KEY"; key="${!key:-}"
    [ -n "$key" ] && [ -n "$base" ] && [ -n "$model" ] || continue
    out=""; rc=0
    out="$(paid_openai_call "$base" "$model" "$key" "$txt")" || rc=$?
    [ "$rc" -eq 0 ] || continue
    verdict="$(echo "$out" | grep -oi 'VERDICT: *SECRET' | head -n1 || true)"
    router_spend_record "$provider" "$(basename "$txt")" "$PAID_EST_PER_CALL_USD"
    if [ -n "$verdict" ]; then return 1; fi
    return 0
  done
  return 2
}

# effective_paid_order -> provider names cheapest-first (prices.json), fallback config order.
# Only providers with a key set are listed. "openrouter" uses the daily cheapest-paid pick.
effective_paid_order() {
  python3 - "$PRICES_FILE" "$PAID_PROVIDER_ORDER" \
    "OPENROUTER_MODEL=${OPENROUTER_MODEL:-}" <<'EOF'
import json, os, sys
prices_path, order, or_model = sys.argv[1], sys.argv[2].split(), sys.argv[3]
keyenv = {k: v for k, v in os.environ.items() if k.endswith("_API_KEY")}
keys = {k.replace("_API_KEY", "").lower(): bool(v) for k, v in keyenv.items()}
costs = {}
try:
    table = json.load(open(prices_path)).get("per_call_usd", {})
except Exception:
    table = {}
for p in order:
    if not keys.get(p):
        continue
    if p == "openrouter" and not or_model:
        continue
    costs[p] = table.get(p, table.get(p + "_direct", 9e9))
ranked = sorted(costs, key=lambda p: costs[p])
print(" ".join(ranked) if ranked else " ".join(p for p in order if keys.get(p)))
EOF
}

# free_opencode_call <transcript> -> stdout verdict text. 0 ok, 2 unavailable.
# Prompt travels via stdin (proven: `opencode run` reads stdin), never argv — ps-safe.
free_opencode_call() {
  local txt="${1:?}" prompt
  command -v opencode >/dev/null 2>&1 || return 2
  prompt="Does the following text contain secret credentials (API keys, passwords, auth tokens, private keys)? Reply first line EXACTLY: VERDICT: CLEAN or VERDICT: SECRET, CONFIDENCE: 0-100. Text: $(head -c 6000 "$txt")"
  printf '%s' "$prompt" | timeout "$OPENCODE_TIMEOUT" opencode run --model "$OPENCODE_MODEL" 2>/dev/null || return 2
}

# paid_openai_call <base-url> <model> <key> <transcript> -> stdout verdict text
# Key travels via env (OPENAI_KEY), transcript is read from file inside python — ps-safe.
paid_openai_call() {
  OPENAI_KEY="$3" python3 - "$1" "$2" "$4" <<'EOF'
import json, os, sys, urllib.request
base, model, path = sys.argv[1], sys.argv[2], sys.argv[3]
key = os.environ["OPENAI_KEY"]
text = open(path).read()[:4000]
prompt = ("Does this text contain secret credentials (API keys, passwords, auth tokens, private keys)? "
          "Reply first line EXACTLY: VERDICT: CLEAN or VERDICT: SECRET, CONFIDENCE: 0-100. Text: " + text)
req = urllib.request.Request(base.rstrip("/") + "/chat/completions",
    json.dumps({"model": model,
                "messages": [{"role": "user", "content": prompt}],
                "temperature": 0, "max_tokens": 100}).encode(),
    {"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
try:
    r = json.load(urllib.request.urlopen(req, timeout=60))
    print(r["choices"][0]["message"]["content"])
except Exception as e:
    sys.stderr.write(f"paid-call-failed: {e}\n"); sys.exit(2)
EOF
}
