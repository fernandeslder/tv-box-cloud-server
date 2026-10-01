# 06 — Smart sorting: always visible to you, gated only at the outside door

Locked rules:
1. **Everything you upload is always accessible to you** (Nextcloud/Immich), scanned or not, secret or not.
2. Files with secrets live in **`private/`** — same apps, same login, just a separate folder. Not hidden, not deleted.
3. **Nothing unprocessed or secret-bearing goes to outside APIs.** Your TV box + Legion = allowed (you own them). Third-party APIs = only for files that passed screening, only if you enable it.
4. **Type-sort runs on-device** by file type (photo/doc/music/video/other) — instant, no AI needed.
5. **Subcategorization** (whose face, scenery vs receipt, doc topics): Legion models first (free); cheap outside APIs allowed **only for clean-screened files**.

```
inbox/ --> ingest.sh: type-sort by MIME/extension --> Photos/ Documents/ Music/ Videos/ Other/
  Documents: extract text (pdftotext/tesseract) --> TIER 0 TruffleHog (tvbox CPU, ms)
  Photos/Videos/Music: Tier 0 text-scan skipped at ingest (OCR-ing everything on CPU is too slow)
           |
  TIER 0 HIT --> private/ (still yours, still in Nextcloud) + tag `has-secrets`, never outside
  clean / unscanned --> stays where it is + tag `pending-ai` + job in .ai-queue/
           |
  Legion online? ai-queue.sh drains oldest-first (Legion is YOURS, so unprocessed files may go there):
    - doc transcript --> qwen2.5:3b judge ("Jeff" role) --> HIT? private/ : clean
    - photo --> moondream transcribes visible text --> judge transcript --> HIT? private/ : clean
    - clean photo --> Immich faces/CLIP (Legion CUDA, or slow TV-box CPU fallback)
           |
  CLEAN + you opted in --> enrichment may use cheap outside APIs (never before this point)
```

## TIER 0 — deterministic secret scan (TV box, always available)
`./scripts/scan-secrets.sh <file>` — TruffleHog, `--no-verification` (never phones providers to "verify" a live key). Catches AWS/GCP/GitHub/Stripe-style keys, private keys, high-entropy tokens. Exit 1 = move to `private/`.

## TIER 1 + vision — Legion 7, all local (see `docs/10`)
- Judge: `qwen2.5:3b-instruct` (or `llama3.2:3b`), ~2GB VRAM, seconds per snippet. Prompt is fixed: *"Does this text contain secret credentials? YES <type> / NO."*
- Vision: `moondream` transcribes screenshots/handwriting; its transcript goes through the same judge. Covers your screenshot-upload case with no extra tooling.
- Orchestration (12GB VRAM): Ollama max-1-loaded + 5-min eviction swaps judge↔vision; Immich ML bulk jobs overnight. Full table in `docs/10`.

## Enrichment + paid escalation router (paid = last resort, minimized by code)
Priority ladder: **free local > self-hosted Legion > paid**. The router (`scripts/router.sh`, policy in `configs/router.conf`) enforces it per file:
- `SECRET` verdict → **BLOCKED** from paid, always. Coded, not just policy.
- `CLEAN` + confidence ≥ 70 → done locally, $0.
- `CLEAN` + confidence < 70 → escalate **only the ~4KB text transcript** (never raw files/images) to the cheapest provider in order, **only if** `PAID_ENABLED=true`, a key exists, and the monthly cap (`PAID_MONTHLY_CAP_USD`, default $2) isn't hit. Otherwise the job waits as `needs-paid`.
- Every escalation is booked in `.ai-queue/spend.log`; over budget → automatic DEFER. Paid off (default) → low-confidence CLEAN is accepted locally and logged.
- Subcategorization beyond secrets (faces, scenery, doc topics): Legion free by default. Outside APIs only ever see clean-screened transcripts, only if you opt in.

### Cheapest paid models (researched + verified Sep 2026, per-escalation ≈ 1000 in / 50 out)
| # | Provider / model | In $/1M | Out $/1M | $/call | Free tier | Endpoint |
|---|---|---|---|---|---|---|
| 1 | **Groq `openai/gpt-oss-20b`** (default first) | 0.075 | 0.30 | **0.00009** | rate-limited free tier, no card | OpenAI-compatible ✓ |
| 2 | **Gemini `gemini-2.5-flash-lite`** (fallback) | 0.10 | 0.40 | **0.00012** | generous AI Studio free tier | OpenAI-compatible ✓ |
Also-rans: Mistral Ministral 3B ($0.10/$0.10), DeepSeek Flash ($0.15/$0.60 off-peak), Together/Fireworks small models ($0.02–0.07 in). Anthropic Haiku (~$0.00125/call) is 10x the price — never for this job. Rock-bottom OpenRouter routes ($0.01 in) exist but run through obscure resellers — rejected for reliability.
- All providers speak OpenAI `/chat/completions`, so adding one = 3 lines in `configs/router.conf`, no code changes.
- You opted into training-on-data terms, which unlocks the free tiers above as overflow: Groq free tier and Gemini AI Studio free tier can absorb escalations at $0 before paid billing even starts.
- At ~$0.0001/call, the $2 default cap buys ~20,000 escalations/month. You will realistically spend $0.

## Offline Legion? (expected — it's a laptop)
Uploads still land, sort, and stay visible. Docs get Tier 0 immediately; everything else waits as `pending-ai`, usable locally, excluded from offsite/cloud copy. Local USB restic backup includes all of it (never leaves the house). Queue drains when `legion-linux` or `legion-win` answers.
