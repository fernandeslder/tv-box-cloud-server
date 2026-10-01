# 06 — Smart sorting: always visible to you, gated only at the outside door

Locked rules:
1. **Everything you upload is always accessible to you** (Nextcloud/Immich), scanned or not, secret or not.
2. Files with secrets live in **`private/`** — same apps, same login, just a separate folder. Not hidden, not deleted.
3. **Nothing unprocessed or secret-bearing goes to outside APIs.** Your TV box + Legion = allowed (you own them). Third-party APIs = only for files that passed screening, only if you enable it.
4. **Type-sort runs on-device** by file type (photo/doc/video/other) — instant, no AI needed.
5. **Subcategorization** (whose face, scenery vs receipt, doc topics): Legion models first (free); cheap outside APIs allowed **only for clean-screened files**.

```
inbox/ --> ingest.sh: type-sort by MIME/extension --> Photos/ Documents/ Videos/ Other/
  Documents: extract text (pdftotext/tesseract) --> TIER 0 TruffleHog (tvbox CPU, ms)
  Photos/Videos: Tier 0 text-scan skipped at ingest (OCR-ing every photo on CPU is too slow)
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

## Enrichment of CLEAN files (optional, cheapest-first)
Default is Legion (free): Immich search/faces, Ollama captions → Immich tags. If you outgrow that, cheapest outside options, **clean files only**:
1. **Google Gemini Flash** — generous free tier, good doc/image categorization.
2. **Cloudflare Workers AI** — pay-per-use, cheap at low volume.
3. **Jina embeddings/reader** — free tier, good for semantic file search.
Enable one by adding its key to `docker/.env` + a worker call in `ai-queue.sh`. Secret/`pending-ai` files are code-blocked from this path (the worker only picks jobs marked clean).

## Offline Legion? (expected — it's a laptop)
Uploads still land, sort, and stay visible. Docs get Tier 0 immediately; everything else waits as `pending-ai`, usable locally, excluded from offsite/cloud copy. Local USB restic backup includes all of it (never leaves the house). Queue drains when `legion-linux` or `legion-win` answers.
