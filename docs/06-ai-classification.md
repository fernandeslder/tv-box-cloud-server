# 06 — Secrets Screening + OCR (local only, never cloud)

Your threat model: **secret credentials only** (API keys, passwords, tokens, private keys). Not names/addresses — the models already have that kind of data and you don't care. Consequence: nothing flagged (or checkable) ever leaves your LAN, and the screening models all run on hardware you own.

```
Any new file --> extract text (below) --> TIER 0 deterministic scan (tvbox CPU, ms)
  --> HIT: quarantine + tag `has-secrets`, NEVER cloud, done
  --> clean/ambiguous --> TIER 1 local LLM judge on Legion (seconds, optional/sampled)
       --> HIT: quarantine + tag. Clean: eligible for normal pipeline.
```

## Text extraction (TV box CPU — fast, free)
- PDFs with text: `pdftotext` (`poppler-utils`, installed by `scripts/10-base.sh`).
- Scans / image-only PDFs / screenshots: `tesseract` (same script installs it). Good enough for printed text, seconds per page on CPU.
- Hard cases (handwriting, complex screenshot layouts): send the image to `moondream` on the Legion (see `docs/10`) and scan its transcript. Last resort, GPU seconds.

## TIER 0 — deterministic secret scan (always on, TV box, milliseconds)
**TruffleHog** (free, open-source, maintained) over the extracted text:
```bash
./scripts/scan-secrets.sh /mnt/pool/files/new-upload.pdf
```
- Uses the `trufflesecurity/trufflehog` image, `--no-verification` (no network calls to "verify" keys — verification would phone home to providers, never do that with real secrets).
- Catches AWS/GCP/GitHub/Stripe-style keys, private keys, high-entropy tokens, generic password assignments. Exit 1 = secrets found → file gets quarantined + tagged, excluded from any cloud backup/enrichment.
- Gitleaks is a fine alternative with a bigger ruleset, but its licensing got awkward — TruffleHog stays free.

## TIER 1 — the "Jeff" judge (Legion 7, local small LLM, seconds)
For ambiguous Tier-0 output or file types regex can't judge (prose notes containing a pasted password, config files with odd formats):
- Model: **`qwen2.5:3b-instruct` via Ollama** (the role you called "Jev/Jeff": cheap, local, ~2GB VRAM). Alternatives: `llama3.2:3b-instruct`. Any 3B instruct model works.
- `scan-secrets.sh --llm` sends the **extracted text snippet** (never the original binary) to `http://<legion-tailnet-IP>:11434` with a fixed prompt: *"Does this text contain secret credentials (API keys, passwords, tokens, private keys)? Answer YES/NO + type."*
- Fully local (Tailscale LAN). Sending credential-containing text to your own Legion is the entire point — it never goes to a third party.
- Sample, don't exhaust: run Tier 1 on Tier-0 warnings + spot-checks. Tier 0 alone is enough for most files; speed doesn't matter (box is always on, queue drains).

## Orchestration (why models don't fight over 12GB VRAM)
They never co-run at full size: Ollama keeps max 1 model loaded with 5-min eviction (judge ↔ moondream swap automatically), Immich ML bulk photo jobs run overnight and get stopped before big doc-caption runs. Full policy + VRAM table: `docs/10-legion-ai-server.md`.

## Legion offline? Default-deny queue (the Legion is a laptop — plan for it)
- New files land in `/mnt/pool/inbox/` → Tier 0 runs immediately (TV-box CPU, always available). Hit → `/mnt/pool/quarantine/`. Clean → `/mnt/pool/files/` tagged `pending-ai` + a job file in `/mnt/pool/.ai-queue/`.
- `pending-ai` = usable locally, but **excluded from offsite/cloud copy and any enrichment** until Tier 1 clears it. Local USB restic backup still includes it (never leaves the house — fine).
- `scripts/ai-queue.sh` (systemd timer `configs/systemd/ai-queue.*`, every 5 min) probes `legion-linux` then `legion-win`; whichever dual-boot OS answers drains the queue oldest-first. Exit 2 from `scan-secrets.sh --llm` means offline — job stays queued, no error noise.
- Photos degrade gracefully too: keep the TV-box CPU `immich-machine-learning` container enabled as fallback (slow faces), remote CUDA as primary. Immich re-triggers its own ML jobs when the remote returns.

## What NEVER happens
- Secret-flagged files are never sent to any cloud API, never included in unencrypted cloud backup, never embedded for "cheap enrichment".
- Presidio/PII stack from earlier drafts is dropped from the default path — it solved a problem you don't have. (Keep the compose entries only if you later want PII redaction for shared albums.)
