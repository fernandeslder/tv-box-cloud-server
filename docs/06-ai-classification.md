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

## Enrichment + escalation router (free first, paid last-resort, minimized by code)
Priority ladder: **free local > self-hosted Legion > FREE external > paid**.
The router (`scripts/router.sh`, policy in `configs/router.conf`,
daily picks in `configs/router.managed.conf`) enforces it per file:
- `SECRET` verdict -> **BLOCKED** from everything outside. Coded, not just policy.
- `CLEAN` + confidence >= 70 -> done locally, $0.
- `CLEAN` + confidence < 70 -> escalate **only the ~4KB text transcript**
  (never raw files/images), in order:
  1. **OpenCode free tier via CLI** (`opencode run --model ...`, your quota,
     $0 -- proven working; one `opencode auth login` on the box),
  2. **OpenRouter `:free` daily pick** ($0, free key),
  3. **Paid, cheapest-first** (daily-ranked, capped).
- Guards: `PAID_ENABLED=false` by default (free steps run regardless);
  monthly cap ($2 default) in `spend.log`; over budget -> `needs-paid` wait.
  Paid-off -> low-confidence CLEAN accepted locally and logged.
- `scripts/price-check.sh` (daily 06:00 timer) pulls OpenRouter's public catalog
  (~1MB), ranks for our shape (1000 in / 50 out), refreshes paid + free picks.
  Never touches keys, switches, or budget.
- Subcategorization beyond secrets (faces, scenery, doc topics): Legion free by default.
  Outside APIs only ever see clean-screened transcripts, only if you opt in.

### Cheapest paid models (researched + verified Sep 2026, per-escalation ≈ 1000 in / 50 out)
| # | Provider / model | In $/1M | Out $/1M | $/call | Free tier | Endpoint |
|---|---|---|---|---|---|---|
| 1 | **Groq `openai/gpt-oss-20b`** (default first) | 0.075 | 0.30 | **0.00009** | rate-limited free tier, no card | OpenAI-compatible ✓ |
| 2 | **Gemini `gemini-2.5-flash-lite`** (fallback) | 0.10 | 0.40 | **0.00012** | generous AI Studio free tier | OpenAI-compatible ✓ |
Also-rans: Mistral Ministral 3B ($0.10/$0.10), DeepSeek Flash ($0.15/$0.60 off-peak), Together/Fireworks small models ($0.02–0.07 in). Anthropic Haiku (~$0.00125/call) is 10x the price — never for this job. Rock-bottom OpenRouter routes ($0.01 in) exist but run through obscure resellers — rejected for reliability.
- All providers speak OpenAI `/chat/completions`, so adding one = 3 lines in `configs/router.conf`, no code changes.
- You opted into training-on-data terms, which unlocks the free tiers above as overflow: Groq free tier and Gemini AI Studio free tier can absorb escalations at $0 before paid billing even starts.
- At ~$0.0001/call, the $2 default cap buys ~20,000 escalations/month. You will realistically spend $0.

## Faces — Immich does this (Google-Photos-style)
- Face detection runs inside immich-machine-learning (InsightFace, Legion CUDA or TV-box CPU fallback) automatically on every photo in the Immich library.
- Name people once in the Immich app (People view); every photo of them becomes searchable by name, and Smart Search answers "photos of X at the beach".
- Sorted `Photos/` get the same treatment: add `/mnt/pool/Photos` as an Immich **external library** (read-only) so faces + CLIP search cover your sorted folders too — no duplicates, no double storage. See `docs/04`.
- Person names live in Immich's database (backed up with Postgres), not in filenames.

## Audio — speech vs music (whisper on YOUR Legion)
- Every audio job goes to faster-whisper (`small`, ~2GB VRAM, `:9000`, profile `audio`): 8+ transcribed words = speech/recording, else music.
- Speech goes to `Recordings/` + transcript, and the transcript runs the same Tier-1 secrets judge (a recorded password is still a password).
- Music goes to `Music/<Artist>/[<Album>/]` from embedded tags (ffprobe), `Artist - Title` filename fallback.

## Music metadata + fuzzy artists
- Song name = filename (never renamed). Album = folder when the tag exists, else tracks sit directly under the artist.
- Artist dedup is fuzzy (difflib >= 0.87 on whitespace-normalized names): "Beatles", "Beat les", "  beatles", one-letter typos all land in one folder. A new folder is created only when nothing existing is close.

## Documents — filename first, summary second, private never leaves
- Stage 0 (`sort-docs.sh --stage0`, TV box, zero network): filename + transcript regexes sort IDs / Finance / Health straight into `private/<Cat>/` — a driver's license has no "password" in it, so Tier-0 alone would miss it. This stage never calls anything, not even the Legion.
- Stage 1 (`--stage1`, Legion LLM, your hardware): filename weighted highest + content summary decides `Documents/Bills|Work|Travel|Manuals|Receipts|Legal|Other/` + a one-line `.summary.txt` sidecar.
- `private/` is fully sorted too (`IDs/ Finance/ Health/ Other/`), fully visible to you, and code-blocked from every outside API including paid escalation.

## Offline Legion? (expected — it's a laptop)
Uploads still land, sort, and stay visible. Docs get Tier 0 immediately; everything else waits as `pending-ai`, usable locally, excluded from offsite/cloud copy. Local USB restic backup includes all of it (never leaves the house). Queue drains when `legion-linux` or `legion-win` answers.
