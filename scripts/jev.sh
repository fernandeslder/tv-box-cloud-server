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
# Env: JEV_URL (default $LEGION_OLLAMA, else localhost — e.g. NanoJev 0.6B on tvbox CPU),
#      JEV_MODEL (default qwen2.5:3b-instruct), JEV_TIMEOUT (default 120).
set -euo pipefail
JEV_URL="${JEV_URL:-${LEGION_OLLAMA:-http://localhost:11434}}"
JEV_MODEL="${JEV_MODEL:-qwen2.5:3b-instruct}"
JEV_TIMEOUT="${JEV_TIMEOUT:-120}"

call() {  # $1=json-schema $2=prompt -> stdout raw JSON (validated by caller shape)
  PROMPT_TEXT="$2" SCHEMA_TEXT="$1" python3 - "$JEV_URL" "$JEV_MODEL" "$JEV_TIMEOUT" <<'EOF' 2>/dev/null || return 2
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

CMD="${1:?usage: jev.sh noul|choice|score|fields ...}"; shift
case "$CMD" in
  noul)
    OUT="$(call '{"type":"object","properties":{"decision":{"type":"string"},"confidence":{"type":"number"}},"required":["decision","confidence"]}' "$1")" || exit 2
    DEC="$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('decision',''))" 2>/dev/null || true)"
    CON="$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('confidence',''))" 2>/dev/null || true)"
    case "${DEC,,}" in yes|no) :;; *) exit 2;; esac
    CON="$(echo "$CON" | grep -o '[0-9]\+' | head -n1)"; [ -n "$CON" ] || exit 2
    printf '{"decision":"%s","confidence":%s}\n' "${DEC,,}" "$CON"
    ;;
  choice)
    OPTS="$2"
    SCHEMA="$(python3 -c "import json,sys; print(json.dumps({'type':'object','properties':{'decision':{'type':'string','enum':sys.argv[1].split('|')},'confidence':{'type':'number'}},'required':['decision','confidence']}))" "$OPTS")"
    OUT="$(call "$SCHEMA" "$1")" || exit 2
    DEC="$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('decision',''))" 2>/dev/null || true)"
    CON="$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('confidence',''))" 2>/dev/null || true)"
    echo "$OPTS" | tr '|' '\n' | grep -qxF "$DEC" || exit 2
    CON="$(echo "$CON" | grep -o '[0-9]\+' | head -n1)"; [ -n "$CON" ] || exit 2
    printf '{"decision":"%s","confidence":%s}\n' "$DEC" "$CON"
    ;;
  score)
    OUT="$(call '{"type":"object","properties":{"score":{"type":"number"}},"required":["score"]}' "$1")" || exit 2
    SC="$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('score',''))" 2>/dev/null || true)"
    SC="$(echo "$SC" | grep -o '[0-9]\+' | head -n1)"; [ -n "$SC" ] || exit 2
    printf '{"score":%s}\n' "$SC"
    ;;
  fields)
    OUT="$(call "{\"type\":\"object\",\"properties\":$1,\"required\":[]}" "$2")" || exit 2
    echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d))" || exit 2
    ;;
  *) echo "usage: jev.sh noul|choice|score|fields ..." >&2; exit 2;;
esac
