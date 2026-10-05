#!/usr/bin/env bash
# router.sh — confidence-gated external escalation. Source it, don't run it.
# Hard rules (enforced here, not just policy):
#   * SECRET verdicts are BLOCKED: they never reach any external API.
#   * Text is run through redact.py first; if redaction fails, nothing is sent (fail closed).
#   * External answers are typed JSON (extllm.py), never parsed from prose.
#   * A monthly USD cap (ledger) limits spend; free models are always allowed.
_ROUTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_CONF="${ROUTER_CONF:-$_ROUTER_DIR/../configs/router.conf}"
. "$_ROUTER_DIR/conf-load.sh"
load_conf "$ROUTER_CONF"
# Daily machine-managed model lists (price-check.sh). Plain KEY="value" lines, validated before write.
ROUTER_MANAGED="${ROUTER_MANAGED:-$_ROUTER_DIR/../configs/router.managed.conf}"
load_conf "$ROUTER_MANAGED"

EXTERNAL_ENABLED="${EXTERNAL_ENABLED:-true}"
EXTERNAL_MAX_TIER="${EXTERNAL_MAX_TIER:-value}"
EXTERNAL_MONTHLY_CAP_USD="${EXTERNAL_MONTHLY_CAP_USD:-2.00}"
ROUTER_CONFIDENCE_MIN="${ROUTER_CONFIDENCE_MIN:-70}"
CC_USE_JEV="${CC_USE_JEV:-true}"
CC_FREE_MODELS="${CC_FREE_MODELS-poolside/laguna-s-2.1-free inclusionai/ling-3.1-flash:free}"
CC_VALUE_MODELS="${CC_VALUE_MODELS-deepseek/deepseek-v4.1-flash z-ai/glm-5.3-flash}"
CC_STRONG_MODELS="${CC_STRONG_MODELS-deepseek/deepseek-v4-pro}"
CC_EST_JEV="${CC_EST_JEV:-0.0001}"; CC_EST_VALUE="${CC_EST_VALUE:-0.0005}"; CC_EST_STRONG="${CC_EST_STRONG:-0.004}"
COMMAND_CODE_API_KEY="${COMMAND_CODE_API_KEY:-}"
_EXTLLM="${EXTLLM:-$_ROUTER_DIR/extllm.py}"
export COMMAND_CODE_API_KEY CC_ZDR="${CC_ZDR:-0}"

LEDGER_FILE="${LEDGER_FILE:-/var/lib/tvbox/spend.log}"
{ mkdir -p "$(dirname "$LEDGER_FILE")" && touch "$LEDGER_FILE"; } 2>/dev/null \
  || LEDGER_FILE="${AI_QUEUE_DIR:-/tmp}/spend.log"

external_available() { [ "$EXTERNAL_ENABLED" = true ] && [ -n "$COMMAND_CODE_API_KEY" ]; }

month_spend() {  # USD booked this calendar month (tab-separated ledger: ts, provider, job, usd)
  [ -f "$LEDGER_FILE" ] || { echo 0; return; }
  awk -F'\t' -v m="$(date +%Y-%m)" 'index($1, m) == 1 { s += $4 } END { printf "%.4f", s + 0 }' "$LEDGER_FILE"
}
over_budget() { awk -v s="$(month_spend)" -v c="$EXTERNAL_MONTHLY_CAP_USD" 'BEGIN { exit !(s + 0 >= c + 0) }'; }
router_spend_record() {  # provider job usd
  printf '%s\t%s\t%s\t%s\n' "$(date +%Y-%m-%dT%H:%M)" "$1" "$(basename "$2")" "$3" >> "$LEDGER_FILE" 2>/dev/null || true
}

# router_decide <CLEAN|SECRET> <confidence 0-100> -> LOCAL | EXTERNAL | BLOCKED
router_decide() {
  local verdict="${1:?}" conf="${2:-0}"
  [ "$verdict" = SECRET ] && { echo BLOCKED; return; }
  [ "$conf" -ge "$ROUTER_CONFIDENCE_MIN" ] && { echo LOCAL; return; }
  external_available || { echo LOCAL; return; }     # no key/off: accept the Legion's answer, logged by caller
  echo EXTERNAL
}

_json_field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2" 2>/dev/null; }

# router_external_opinion <transcript-file> -> 0 clean, 1 secret, 2 unavailable/no answer
# Climbs jev -> free -> value -> strong (capped by EXTERNAL_MAX_TIER), stops at the first
# answer with confidence >= ROUTER_CONFIDENCE_MIN. Any answer SECRET (conf >= 50) wins immediately.
router_external_opinion() {
  local txt="${1:?}" red out v c tier model tries answered=0 clean_seen=0 est
  external_available || return 2
  red="$("$_ROUTER_DIR/redact.py" 4000 < "$txt")" || { echo "router: redaction failed, nothing sent" >&2; return 2; }

  try_call() {  # try_call <label> <usd> <cmd...>  -> sets v c on success
    local label="$1" usd="$2"; shift 2
    out="$(printf '%s' "$red" | "$@" 2>/dev/null)" || return 1
    v="$(_json_field "$out" verdict)" || return 1; c="$(_json_field "$out" confidence)" || return 1
    case "$v" in CLEAN|SECRET) ;; *) return 1 ;; esac
    router_spend_record "$label" "$txt" "$usd"
    return 0
  }
  judge() {  # judge -> 0/1 final (prints nothing), 3 keep climbing
    answered=1
    if [ "$v" = SECRET ] && [ "$c" -ge 50 ]; then return 1; fi
    [ "$v" = CLEAN ] && clean_seen=1
    if [ "$c" -ge "$ROUTER_CONFIDENCE_MIN" ]; then [ "$v" = SECRET ] && return 1 || return 0; fi
    return 3
  }

  local rc
  if [ "$CC_USE_JEV" = true ] && ! over_budget; then
    if try_call "cc-jev" "$CC_EST_JEV" "$_EXTLLM" jev; then
      rc=0; judge || rc=$?; [ "$rc" -ne 3 ] && return "$rc"
    fi
  fi
  for tier in free value strong; do
    case "$tier" in
      free)   models="$CC_FREE_MODELS";   est=0 ;;
      value)  models="$CC_VALUE_MODELS";  est="$CC_EST_VALUE" ;;
      strong) models="$CC_STRONG_MODELS"; est="$CC_EST_STRONG" ;;
    esac
    [ "$tier" = value ] && [ "$EXTERNAL_MAX_TIER" = free ] && break
    [ "$tier" = strong ] && [ "$EXTERNAL_MAX_TIER" != strong ] && break
    if [ "$tier" != free ] && over_budget; then echo "router: monthly cap reached, staying below paid tiers" >&2; break; fi
    tries=0
    for model in $models; do
      [[ "$model" =~ ^[A-Za-z0-9._:/-]+$ ]] || continue
      tries=$((tries + 1)); [ "$tries" -le 2 ] || break
      try_call "cc-$model" "$est" "$_EXTLLM" chat "$model" || continue
      rc=0; judge || rc=$?; [ "$rc" -ne 3 ] && return "$rc"
    done
  done
  [ "$answered" -eq 1 ] && [ "$clean_seen" -eq 1 ] && return 0   # best effort: nobody flagged it
  return 2
}
