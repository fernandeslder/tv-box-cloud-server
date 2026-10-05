# 06 — Smart sorting: always visible to you, gated only at the outside door

Locked rules:
1. **Everything you upload is always visible to you** (Samba / Nextcloud / Immich), scanned or not, secret or not.
2. Files with secrets or sensitive IDs live in **`private/`** — same apps, same login, separate folder. Not hidden, not deleted.
3. **Calls to your own Legion are never redacted** (you own it). **Anything sent to an external API is redacted first**, transcript-only, and never contains a `SECRET`-verdict file.
4. Type-sorting is instant and on-device; AI only does subcategories, secrets-judging and extraction.

```
inbox/ -> ingest.sh (every 5 min + on change; skips files still uploading)
  type-sort by extension/MIME -> Photos Documents Music Recordings Videos Other
  Stage-0 filename rules (all types): passport/license/bank/medical names -> private/<IDs|Finance|Health>
  Documents: text extraction (pdftotext, OCR for scans, docx/xlsx/pptx/odt/epub unzip) -> TruffleHog (Tier 0)
      secret hit -> private/        stage-0 text rules hit -> private/<Cat>/     else -> .ai-queue/<name>.pending
  Photos/Audio/Videos/Other: queued
ai-queue.sh (every 5 min, only while a Legion answers; every job ends in done/):
  photo  -> moondream transcribes visible text -> stage-0 -> judge
  audio  -> whisper: speech (>=8 words) -> Recordings/ + judge ; music -> Music/<Artist>/[Album]/
  doc    -> judge -> Jev categorize -> Documents/<Category>/ + .summary.txt
  video / archive / unknown -> done (nothing to read; filename rules already ran)
```

## Tier 0 — TruffleHog (offline)
`scan-secrets.sh <file>`: pinned image, `--no-verification`, no network. Exit 1 = findings -> `private/`.

## Tier 1 — Jev on the Legion (typed decisions, never prose)
`jev.sh noul|choice|score|fields` talks to an Ollama model with JSON-schema structured output and validates the shape; anything malformed = exit 2 = stays queued. `scan-secrets.sh --llm` judges the **whole** transcript in overlapping 3000-char chunks (a secret on page 3 is not skipped); any chunk "yes" = SECRET. Engines are drop-in via `JEV_MODEL` (default `qwen2.5:3b-instruct`; Kev, Laya, SemIf, NanoJev compatible). Fallback chain: Legion engine -> local NanoJev (`JEV_FALLBACK_*`) -> defer. A valid low-confidence decision is an *answer*, not a failure.

System 2 (`qwen2.5:7b`) only ever **names new folders**; it never makes yes/no decisions.

## External opinion — Command Code Provider API (optional)
Only for **CLEAN + confidence < 70** (default). One provider, one key (`COMMAND_CODE_API_KEY` in `configs/router.conf`, mode 600). The router climbs intelligence tiers until one answer is confident enough:

| Tier | Models (defaults, best-first) | Cost |
|---|---|---|
| `jev` | `typesafe/jev` on `/provider/v1/systemone` — calibrated probability, typed | ~$0.0001 |
| `free` | `poolside/laguna-s-2.1-free`, `inclusionai/ling-3.1-flash:free`, `stealth/space-bunny-alpha` | $0 |
| `value` | `deepseek/deepseek-v4.1-flash`, `z-ai/glm-5.3-flash`, `xiaomi/mimo-v2.5`, `meta/muse-spark-1.2-contributor`, `moonshotai/Kimi-K3` | cents/1000 calls |
| `strong` | `deepseek/deepseek-v4-pro`, `MiniMaxAI/MiniMax-M3`, `zai-org/GLM-5.3` — only if `EXTERNAL_MAX_TIER=strong` | more |

- **Redaction (`redact.py`)** runs first and fails closed: PEM blocks, JWTs, provider-key prefixes, URL credentials, `password:`-style assignments, long digit runs, high-entropy tokens; output capped at 4000 chars. If redaction fails, nothing is sent.
- **Typed replies:** `extllm.py` demands `{"verdict":"CLEAN|SECRET","confidence":0-100}` (or the Jev probability); free text is never parsed, so a document cannot talk its way to a verdict.
- **Cap:** `EXTERNAL_MONTHLY_CAP_USD` (default $2) against a ledger at `/var/lib/tvbox/spend.log` (tab-separated, per-tier estimates `CC_EST_*`). Free models are always allowed; paid tiers stop at the cap.
- **No answer?** Retried up to 12 times (about an hour), then the Legion's verdict stands (logged `CLEAN?`). An external `SECRET` (confidence >= 50) moves the file to `private/`.
- `price-check.sh` (daily) validates every configured id against the live `/provider/v1/models` list and writes `router.managed.conf` atomically with validated ids only. Edit tiers in `router.conf`.
- Because the text is redacted, external models mostly judge *context* ("a note about a prod password"). That is the intended trade-off: they can raise a flag, they never see the secret.
- Set `CC_ZDR=1` for zero-data-retention routing (models without a ZDR upstream are skipped; `typesafe/jev` has none).

## Faces, audio, documents
- **Faces:** Immich (InsightFace) on every photo incl. the read-only sorted `Photos/` external library; names live in Immich's DB (in the nightly dump).
- **Audio:** whisper `small` on the Legion; 8+ words = speech -> `Recordings/` and judged like text; music -> `Music/<Artist>/[Album]/` from tags, else Jev splits the filename. Artist/album names are sanitised (no path separators, no leading dots). Fuzzy artist match >= 0.82.
- **Documents:** filename first, summary second; `private/` is sub-sorted and blocked from every outside API.

## Offline Legion
Uploads still land, sort and stay visible; documents get Tier 0 + stage-0 immediately; the rest waits in `.ai-queue` and drains when `legion-linux` or `legion-win` answers.
