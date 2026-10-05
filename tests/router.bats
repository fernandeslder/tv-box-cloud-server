load helpers
setup() {
  mk_tmp
  export ROUTER_CONF="$T/none" ROUTER_MANAGED="$T/none2" LEDGER_FILE="$T/spend.log" AI_QUEUE_DIR="$T"
  cat > "$T/fake-extllm" <<'F'
#!/usr/bin/env bash
# fake external model: behaviour chosen by env FAKE_<mode>
mode="$1"; model="${2:-}"; cat >/dev/null
echo "$mode $model" >> "$FAKE_LOG"
case "$mode:$model" in
  jev:*)  [ -n "${FAKE_JEV:-}" ] && { echo "$FAKE_JEV"; exit 0; }; exit 2 ;;
  chat:*) v="FAKE_$(echo "$model" | tr -c 'A-Za-z0-9\n' '_')"; [ -n "${!v:-}" ] && { echo "${!v}"; exit 0; }; exit 2 ;;
esac
F
  chmod +x "$T/fake-extllm"; export EXTLLM="$T/fake-extllm" FAKE_LOG="$T/calls"; : > "$FAKE_LOG"
  echo "my notes about the garden" > "$T/doc.txt"
}
teardown() { rm -rf "$T"; }
src() { . "$REPO/scripts/router.sh"; }

@test "SECRET is BLOCKED regardless of confidence or settings" {
  COMMAND_CODE_API_KEY=k; src
  [ "$(router_decide SECRET 100)" = BLOCKED ]; [ "$(router_decide SECRET 0)" = BLOCKED ]
}
@test "high confidence CLEAN stays local" { COMMAND_CODE_API_KEY=k; src; [ "$(router_decide CLEAN 90)" = LOCAL ]; }
@test "low confidence CLEAN goes external only with a key" {
  COMMAND_CODE_API_KEY=k; src; [ "$(router_decide CLEAN 40)" = EXTERNAL ]
  COMMAND_CODE_API_KEY=""; src; [ "$(router_decide CLEAN 40)" = LOCAL ]
}
@test "external stops at the first confident answer (free tier before paid)" {
  export COMMAND_CODE_API_KEY=k CC_USE_JEV=false CC_FREE_MODELS="a/free" CC_VALUE_MODELS="b/value" \
         'FAKE_a_free={"verdict":"CLEAN","confidence":95}'; src
  run router_external_opinion "$T/doc.txt"; [ "$status" -eq 0 ]
  ! grep -q 'b/value' "$FAKE_LOG"
}
@test "low confidence climbs to the next tier" {
  export COMMAND_CODE_API_KEY=k CC_USE_JEV=false CC_FREE_MODELS="a/free" CC_VALUE_MODELS="b/value" \
         'FAKE_a_free={"verdict":"CLEAN","confidence":40}' 'FAKE_b_value={"verdict":"CLEAN","confidence":92}'; src
  run router_external_opinion "$T/doc.txt"; [ "$status" -eq 0 ]; grep -q 'b/value' "$FAKE_LOG"
}
@test "external SECRET answer returns 1" {
  export COMMAND_CODE_API_KEY=k CC_USE_JEV=false CC_FREE_MODELS="a/free" 'FAKE_a_free={"verdict":"SECRET","confidence":88}'; src
  run router_external_opinion "$T/doc.txt"; [ "$status" -eq 1 ]
}
@test "EXTERNAL_MAX_TIER=free never calls paid tiers" {
  export COMMAND_CODE_API_KEY=k CC_USE_JEV=false EXTERNAL_MAX_TIER=free CC_FREE_MODELS="a/free" CC_VALUE_MODELS="b/value" \
         'FAKE_a_free={"verdict":"CLEAN","confidence":10}' 'FAKE_b_value={"verdict":"CLEAN","confidence":99}'; src
  run router_external_opinion "$T/doc.txt"; ! grep -q 'b/value' "$FAKE_LOG"
}
@test "monthly cap blocks paid tiers but not free" {
  export COMMAND_CODE_API_KEY=k CC_USE_JEV=false CC_FREE_MODELS="a/free" CC_VALUE_MODELS="b/value" EXTERNAL_MONTHLY_CAP_USD=1.00 \
         'FAKE_a_free={"verdict":"CLEAN","confidence":10}' 'FAKE_b_value={"verdict":"CLEAN","confidence":99}'
  printf '%s\tx\tj\t5.0000\n' "$(date +%Y-%m-%dT%H:%M)" > "$LEDGER_FILE"; src
  run router_external_opinion "$T/doc.txt"; grep -q 'a/free' "$FAKE_LOG"; ! grep -q 'b/value' "$FAKE_LOG"
}
@test "malformed or untyped replies are ignored (exit 2 overall)" {
  export COMMAND_CODE_API_KEY=k CC_USE_JEV=false CC_FREE_MODELS="a/free" 'FAKE_a_free=VERDICT: CLEAN CONFIDENCE: 99'; src
  run router_external_opinion "$T/doc.txt"; [ "$status" -eq 2 ]
}
@test "model ids that are not plain tokens are never used" {
  export COMMAND_CODE_API_KEY=k CC_USE_JEV=false CC_VALUE_MODELS="" CC_STRONG_MODELS="" CC_FREE_MODELS='x;touch$IFS'"$T"'/pwned' 'FAKE_a_free={"verdict":"CLEAN","confidence":99}'; src
  run router_external_opinion "$T/doc.txt"; [ ! -e "$T/pwned" ]; [ ! -s "$FAKE_LOG" ]
}
@test "spend is recorded as tab-separated ledger and summed per month" {
  export COMMAND_CODE_API_KEY=k CC_USE_JEV=false CC_FREE_MODELS="" CC_VALUE_MODELS="b/value" CC_EST_VALUE=0.25 'FAKE_b_value={"verdict":"CLEAN","confidence":99}'; src
  run router_external_opinion "$T/doc.txt"; [ "$(month_spend)" = "0.2500" ]
}
@test "nothing is sent when redaction would be needed but the redactor is missing" {
  export COMMAND_CODE_API_KEY=k CC_USE_JEV=false CC_FREE_MODELS="a/free" 'FAKE_a_free={"verdict":"CLEAN","confidence":99}'; src
  _ROUTER_DIR="$T/nowhere" run router_external_opinion "$T/doc.txt"; [ "$status" -eq 2 ]; [ ! -s "$FAKE_LOG" ]
}
