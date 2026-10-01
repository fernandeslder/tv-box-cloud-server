# 10 — Legion 7 AI Server Setup (do this WHILE the TV box installs)

Your Legion 7 (RTX 4080 Laptop 12GB VRAM, 32GB RAM) is the GPU worker. The TV box has no useful GPU for AI, so all heavy models live here and the TV box calls them over Tailscale. Do this in parallel with `docs/01` step 6.

Assumes stock **Windows 11**. (If you ever put Linux on the Legion, use `docker/ml-laptop/compose.yml` profile `ollama` instead of the native Ollama app below — same models, same env vars.)

## Step 1 — Base software (~20 min, mostly downloads)
1. Install **Tailscale** (Windows), log in with the same account as the TV box. Note this machine's tailnet IP (`100.x.y.z`).
2. Install **NVIDIA Game Ready / Studio driver** (recent) — required for GPU in WSL2 + Ollama.
3. Install **WSL2 + Ubuntu**: `wsl --install -d Ubuntu` in an admin terminal, reboot if asked.
4. Install **Docker Desktop** (WSL2 backend, default). In Settings → Resources → WSL integration, enable Ubuntu. GPU works inside WSL2 containers automatically with a recent NVIDIA driver — verify later with `docker run --rm --gpus all nvidia/cuda:12-cpu... ` (see step 4).
5. Install **Ollama for Windows** (native app — simplest reliable GPU path, auto-updates). Native Ollama, not Docker, so VRAM isn't split with a VM layer.

## Step 2 — Pull the models (the "Jeff" + OCR-vision set)
In a terminal (`ollama` is on PATH after install):
```powershell
ollama pull qwen2.5:3b-instruct   # the "Jeff" role: secrets judge, ~2GB VRAM, seconds per snippet
ollama pull moondream             # vision: screenshots / handwriting / nasty layouts, ~2GB VRAM
# optional, only if you want chatty captions later:
# ollama pull llava:7b            # ~5GB VRAM, best captions, slowest swap
```
Set Ollama to swap models instead of hoarding VRAM (Settings → or env):
```
OLLAMA_MAX_LOADED_MODELS=1
OLLAMA_KEEP_ALIVE=5m
```
With this, asking the secrets judge unloads the caption model and vice versa — this **is** the orchestration for the LLM side: one resident model max, 5-minute eviction, everything else queues behind it. No extra tooling needed.

## Step 3 — Immich remote ML (Docker in WSL2, profile `photos`)
```bash
cd /path/to/tv-box-cloud-server/docker/ml-laptop
docker compose --profile photos up -d
```
- This runs `immich-machine-learning:release-cuda` on `:3003`. **Version must match the TV box's Immich version** — update both together.
- In Immich (on the TV box): Admin → ML Settings → add `http://<legion-tailnet-IP>:3003`.
- VRAM while running: CLIP/SigLIP ~1–5GB + face models ~1GB. Don't run photo bulk-jobs at the same time as big caption jobs (see orchestration policy below).

## Step 4 — Verify GPU everywhere
```bash
# WSL2 Ubuntu:
docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi
# Windows PowerShell:
ollama run qwen2.5:3b-instruct "reply OK"
```
Then from the TV box: `curl http://<legion-tailnet-IP>:3003/` should answer, and `curl http://<legion-tailnet-IP>:11434/api/tags` should list Ollama models.

## Orchestration policy (12GB VRAM can't hold everything — so don't try)
| Workload | Where | VRAM | When |
|---|---|---|---|
| Secrets judge (`qwen2.5:3b`) | Ollama native | ~2GB | on demand, preempts (fast, seconds) |
| Screenshot/vision OCR (`moondream`) | Ollama native | ~2GB | on demand, swaps with judge automatically |
| Photo embeddings+faces (Immich ML) | Docker `:3003` | ~2–6GB | bulk overnight / idle; **stop before big doc-caption runs**: `docker compose --profile photos stop` |
| Captions (`llava:7b`, optional) | Ollama native | ~5GB | queued behind the above, unloads after 5m idle |

Rules:
1. One GPU job family at a time for big runs (photos overnight, documents on demand).
2. Secrets checks always win — they're tiny and fast.
3. Ollama side needs no manual work (max-1-loaded + keep-alive does the swap). Only Immich ML needs a manual stop/start around huge jobs.
4. Nothing on this machine is exposed publicly — bind everything to Tailscale/LAN. The ML port has no auth.

## What "done" looks like
- [ ] `ollama list` shows `qwen2.5:3b-instruct` + `moondream`
- [ ] Immich on TV box → ML URL set, test photo gets faces + search
- [ ] `scripts/scan-secrets.sh` Tier-1 check reaches `http://<legion-tailnet-IP>:11434` (see `docs/06`)
