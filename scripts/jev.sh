#!/usr/bin/env bash
# jev.sh — System 1 decision client. Typed decisions (noul/choice/score), never parsed prose.
# Implements the Jev contract (TypeSafe /v1/systemone concepts) over any Ollama-hosted
# decision model via structured outputs (JSON schema in `format`, temperature 0).
# Any Jev-compatible weights (Kev, NanoJev, Laya…) are drop-in via JEV_MODEL.
# Usage:
#   jev.sh noul "prompt"                  -> {"decision":"yes"|"no","confidence":0-100}
#   jev.sh choice "prompt" "opt1|opt2|.."  -> {"decision":"<one of opts>","confidence":0-100}
#   jev.sh score "prompt"                 -> {"score":0-100}
#   jev.sh fields '{"a":"string",...}' "prompt" -> validated JSON object
# Exit 0 = valid decision on stdout. Exit 2 = unreachable/invalid (caller defers).
# Env: JEV_URL (default $LEGION_OLLAMA, else localhost),
#      JEV_MODEL (System 1 primary — Legion decision engine, default qwen2.5:3b-instruct),
#      JEV_FALLBACK_URL (default http://localhost:11434 — TV box itself),
#      JEV_FALLBACK_MODEL (System 1 fallback — NanoJev 0.6B class; empty = no fallback),
#      JEV_TIMEOUT (default 120).
# Fallback rule: primary failure/invalid output retries ONCE on the fallback engine.
# A valid-but-low-confidence decision is an ANSWER, not a failure — it never
# triggers fallback (confidence is the router's job). System 2 models are NEVER
# consulted for System 1 decisions; different lanes.
set -euo pipefail
_JEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_JEV_CONF="${ROUTER_CONF:-$_JEV_DIR/../configs/router.conf}"
[ -f "$_JEV_CONF" ] && set -a && . "$_JEV_CONF" && set +a
JEV_URL="${JEV_URL:-${LEGION_OLLAMA:-http://localhost:11434}}"
JEV_MODEL="${JEV_MODEL:-qwen2.5:3b-instruct}"
JEV_FALLBACK_URL="${JEV_FALLBACK_URL:-http://localhost:11434}"
JEV_FALLBACK_MODEL="${JEV_FALLBACK_MODEL:-}"
JEV_TIMEOUT="${JEV_TIMEOUT:-120}"

fetch() {  # $1=url $2=model $3=schema $4=prompt -> stdout raw content, rc 2 on any failure
  PROMPT_TEXT="$4" SCHEMA_TEXT="$3" python3 - "$1" "$2" "$JEV_TIMEOUT" <<'EOF' 2>/dev/null || return 2
import json, os, sys, urllib.request
try:
    base, model, timeout = sys.argv[1], sys.argv[2], int(sys.argv[3])
    schema = json.loads(os.environ["SCHEMA_TEXT"])
    grounded = (os.environ["PROMPT_TEXT"]
                + "\nRespond with JSON matching this schema, nothing else: "
                + json.dumps(schema))
    req = urllib.request.Request(base + "/api/chat",
        json.dumps({"model": model,
                    "messages": [{"role": "user", "content": grounded[:3000]}],
                    "stream": False, "format": schema,
                    "options": {"temperature": 0}}).encode())
    r = json.load(urllib.request.urlopen(req, timeout=timeout))
    print(r["message"]["content"])
except Exception as e:
    sys.stderr.write(f"jev: call failed: {e}\n")
    sys.exit(2)
EOF
}

# Validators: $1 = raw content -> stdout normalized JSON, rc 2 if not a real decision.
# A malformed answer counts as "can't decide" and DOES trigger NanoJev fallback.
v_noul() {
  python3 -c "
import json, re, sys
d = json.loads(sys.argv[1])
dec = str(d.get('decision', '')).lower()
con = ''.join(re.findall(r'[0-9]+', str(d.get('confidence', ''))))
assert dec in ('yes', 'no') and con, 'not-a-decision'
print(json.dumps({'decision': dec, 'confidence': int(con)}))" "$1"
}
v_choice() {  # options via $OPTS_CSV (pipe-separated)
  OPTS_CSV="$OPTS_CSV" python3 - "$1" <<'EOF2'
import json, os, re, sys
d = json.loads(sys.argv[1])
opts = os.environ["OPTS_CSV"].split("|")
dec = str(d.get("decision", ""))
con = "".join(re.findall(r"[0-9]+", str(d.get("confidence", ""))))
assert dec in opts and con, "not-a-decision"
print(json.dumps({"decision": dec, "confidence": int(con)}))
EOF2
}
v_score() {
  python3 -c "
import json, re, sys
d = json.loads(sys.argv[1])
sc = ''.join(re.findall(r'[0-9]+', str(d.get('score', ''))))
assert sc, 'not-a-decision'
print(json.dumps({'score': int(sc)}))" "$1"
}
v_json() {
  echo "$1" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)))" || return 2
}
attempt() {  # $1=url $2=model $3=schema $4=prompt $5=validator -> normalized or rc 2
  local raw
  raw="$(fetch "$1" "$2" "$3" "$4")" || return 2
  "$5" "$raw" || return 2
}
call() {  # $1=schema $2=prompt $3=validator -> normalized JSON; Legion S1, then NanoJev
  local out
  if out="$(attempt "$JEV_URL" "$JEV_MODEL" "$1" "$2" "$3")"; then echo "$out"; return 0; fi
  if [ -n "$JEV_FALLBACK_MODEL" ]; then
    if out="$(attempt "$JEV_FALLBACK_URL" "$JEV_FALLBACK_MODEL" "$1" "$2" "$3")"; then
      echo "$out"; return 0
    fi
  fi
  return 2
}
CMD="${1:?usage: jev.sh noul|choice|score|fields ...}"; shift
# Prompt "-": read the prompt from stdin instead of argv, so secret-bearing
# text never appears in process listings. Callers handling transcripts must use it.
case "$CMD" in
  noul)
    if [ "$1" = "-" ]; then set -- "$(cat)"; fi
    call '{"type":"object","properties":{"decision":{"type":"string"},"confidence":{"type":"number"}},"required":["decision","confidence"]}' "$1" v_noul || exit 2
    ;;
  choice)
    if [ "$1" = "-" ]; then set -- "$(cat)" "$2"; fi
    OPTS="$2"
    SCHEMA="$(python3 -c "import json,sys; print(json.dumps({'type':'object','properties':{'decision':{'type':'string','enum':sys.argv[1].split('|')},'confidence':{'type':'number'}},'required':['decision','confidence']}))" "$OPTS")"
    OPTS_CSV="$OPTS" call "$SCHEMA" "$1" v_choice || exit 2
    ;;
  score)
    if [ "$1" = "-" ]; then set -- "$(cat)"; fi
    call '{"type":"object","properties":{"score":{"type":"number"}},"required":["score"]}' "$1" v_score || exit 2
    ;;
  fields)
    if [ "$2" = "-" ]; then set -- "$1" "$(cat)"; fi
    call "{\"type\":\"object\",\"properties\":$1,\"required\":[]}" "$2" v_json || exit 2
    ;;
  *) echo "usage: jev.sh noul|choice|score|fields ..." >&2; exit 2;;
esac
