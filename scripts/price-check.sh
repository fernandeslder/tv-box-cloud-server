#!/usr/bin/env bash
# price-check.sh — daily cheapest-model refresh. ~1MB download, nothing else.
# Ranks OpenRouter's public catalog for our shape (1000 text tokens in / 50 out),
# picks cheapest paid + best free, writes machine-managed router config.
# NEVER touches PAID_ENABLED, keys, thresholds, or budget. Safe to run daily.
# Usage: ./price-check.sh [snapshot.json]   # no arg = download live catalog
set -euo pipefail
cd "$(dirname "$0")"
CONF_DIR="./../configs"
SNAP="${1:-}"
[ -n "$SNAP" ] || { SNAP="$(mktemp)"; trap 'rm -f "$SNAP"' EXIT
  curl -sf -m 60 --retry 3 https://openrouter.ai/api/v1/models -o "$SNAP"; }

python3 - "$SNAP" "$CONF_DIR/prices.json" "$CONF_DIR/router.managed.conf" <<'EOF'
import json, sys, datetime
snap_path, prices_path, managed_path = sys.argv[1:4]
IN_TOK, OUT_TOK, PAID_CAP = 1000, 50, 0.001  # ignore paid picks above $0.001/call
BLOCK = ("embedding", "moderation", "tts", "audio", "whisper", "image-gen",
         "guard", "toxic", "nsfw-filter")

def ok(m):
    i = m.get("id", "").lower()
    if any(b in i for b in BLOCK):
        return False
    if "text" not in (m.get("architecture", {}).get("output_modalities", []) or ["text"]):
        return False
    try:
        float(m["pricing"]["prompt"]); float(m["pricing"]["completion"])
    except (KeyError, TypeError, ValueError):
        return False
    return True

def cost(m):
    p = m["pricing"]
    return IN_TOK * float(p["prompt"]) + OUT_TOK * float(p["completion"])

models = [m for m in json.load(open(snap_path)).get("data", []) if ok(m)]
paid = sorted((m for m in models if cost(m) > 0), key=cost)
free = [m for m in models if cost(m) == 0]
free.sort(key=lambda m: (m.get("context_length", 0)), reverse=True)

top_paid = [{"id": m["id"], "per_call_usd": round(cost(m), 6)} for m in paid[:8]]
cheap_paid = next((m for m in paid if cost(m) <= PAID_CAP), None)
top_free = [{"id": m["id"], "context": m.get("context_length", 0)} for m in free[:5]]
PREF = ("qwen", "gemma", "nemotron-3.5-lightning", "mistral", "llama-3", "lfm")
cands = [m for m in free if "instruct" in m["id"].lower()
         or "chat" in m["id"].lower() or "-it:" in m["id"].lower()
         or m["id"].lower().endswith("-it:free")]
cands.sort(key=lambda m: m.get("context_length", 0), reverse=True)
free_pick = next((m["id"] for key in PREF for m in cands if key in m["id"].lower()),
                 cands[0]["id"] if cands else (free[0]["id"] if free else ""))

now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
prices = {"updated": now, "shape": f"{IN_TOK}in/{OUT_TOK}out",
          "per_call_usd": {"openrouter": round(cost(cheap_paid), 6) if cheap_paid else 9e9,
                           "openrouter_free": 0.0,
                           "groq_direct": 0.00009, "gemini_direct": 0.00012},
          "top_paid": top_paid, "top_free": top_free}
json.dump(prices, open(prices_path, "w"), indent=2)

managed = (f"# MANAGED by price-check.sh ({now}). Do not hand-edit — edit router.conf instead.\n"
           f"OPENROUTER_MODEL={cheap_paid['id'] if cheap_paid else ''}\n"
           f"OPENROUTER_FREE_MODEL={free_pick}\n")
open(managed_path, "w").write(managed)

print(f"paid pick: {cheap_paid['id'] if cheap_paid else 'NONE'} "
      f"(${cost(cheap_paid):.6f}/call)" if cheap_paid else "paid pick: NONE")
print(f"free pick: {free_pick or 'NONE'}")
print(f"top paid: {', '.join(m['id'].split('/')[-1][:28] for m in top_paid[:5])}")
EOF
