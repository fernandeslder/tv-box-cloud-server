# 10 — Legion 7 AI Server (one command per OS)

The Legion 7 (RTX 4080 Laptop 12GB VRAM, 32GB RAM) is the GPU worker. It dual-boots **CachyOS** and **Windows 11**; each OS has one idempotent setup script (re-run anytime to repair/update). The TV box tries `legion-linux`, then `legion-win` (`LEGION_HOSTS` in `scripts/ai-queue.sh`), so whichever OS is booted just works with no TV-box reconfig.

## Run it
| OS | Command | Tailscale name |
|---|---|---|
| CachyOS/Arch (Ubuntu/Debian tolerated) | `./legion/setup-linux.sh` | `legion-linux` |
| Windows 11 | double-click `legion\setup-windows.bat` (or `.\legion\setup-windows.ps1`; asks for admin) | `legion-win` |

Options: `--no-models` / `-NoModels` skips the ~10GB model pulls. `TS_AUTHKEY=tskey-...` gives unattended Tailscale login (otherwise it prints a login URL). `IMMICH_VERSION=v3.2.4` must equal the TV box's `docker/.env` value (default `v3.2.4`; saved to `docker/ml-laptop/.env`, which is required by the compose file).

Prerequisite (not scripted): a working NVIDIA driver (`nvidia-smi` shows the 4080). On CachyOS use its driver tooling (`chwd`/`nvidia-dkms`), on Windows a Game Ready/Studio driver. Reboot after a first Docker/WSL2 install, then re-run.

What each script does: Tailscale + hostname → Docker + NVIDIA container toolkit (Windows: Docker Desktop/WSL2) → **native Ollama** with `OLLAMA_HOST=0.0.0.0`, `OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_KEEP_ALIVE=5m` → firewall for TCP 11434/3003/9000 from the tailnet (`100.64.0.0/10`) + local subnet only (ufw/firewalld on Linux, Windows Firewall rule on Windows; Linux also restricts Docker-published ports via `DOCKER-USER`) → model pulls → `docker/ml-laptop/compose.yml` profiles `photos` + `audio` (the `ollama` profile is not used; Ollama is native) → health table of `:11434/api/tags`, `:3003/ping`, `:9000`.

If you change networks (new LAN subnet), re-run the script so the LAN rule follows.

## Finish: point Immich at it
In Immich admin → Settings → Machine Learning set the URL to `http://legion-linux:3003` (or `legion-win`), or set `IMMICH_ML_URL` on the TV box. Use the Tailscale *name*, never the IP. Server and ML versions must match. Keep the TV-box CPU ML container enabled so photos still get faces slowly with zero Legion. Verify from the TV box: `curl http://legion-linux:11434/api/tags`.

## Models (pulled per OS, ~10GB each side)
```
qwen2.5:3b-instruct   # Jev (System 1): secrets judge + fit-checks, ~2GB VRAM, seconds per snippet
qwen2.5:7b-instruct   # System 2: names genuinely new categories, ~5GB VRAM, slow lane (swapped in on demand)
moondream             # vision: screenshots / handwriting / nasty layouts, ~2GB VRAM
# llava:7b            # optional captions, ~5GB VRAM (manual: ollama pull llava:7b)
whisper small         # STT via compose profile `audio` (:9000): speech-vs-music + transcripts, ~2GB VRAM
Immich ML (CUDA)      # compose profile `photos` (:3003): faces/CLIP search
```
Jev engine default is `qwen2.5:3b-instruct` (stand-in); swap `JEV_MODEL` for a decision-tuned engine anytime (Kev, Laya, SemIf, NanoJev; see `docs/06-ai-classification.md`).

## VRAM rule: one workload family at a time
12GB is shared. Ollama self-swaps (one resident model, 5 min keep-alive). Immich ML and whisper hold VRAM while loaded, so before a big doc-caption/vision run: `docker compose --profile photos stop` in `docker/ml-laptop` and start it again afterwards.

## When the Legion is offline (expected, it's a laptop)
Default-deny queue on the TV box (design: `docs/06-ai-classification.md`, worker: `scripts/ai-queue.sh` every 5 min):
- Uploads land in `inbox/` → Tier 0 deterministic scan runs on the TV box → hit goes to `private/`, clean goes to `files/` tagged `pending-ai`.
- `pending-ai` files are usable locally but **excluded from offsite/cloud copy and enrichment** until screened (local USB restic backup still includes them).
- When any Legion OS comes online, the worker drains the queue oldest-first. Nothing to configure per boot.

## Dota 2 on CachyOS (migration blocker, for an agent session on the Legion)
Check: matching `nvidia-dkms` + kernel (reboot after updates), native Steam (not flatpak), Proton-GE via ProtonUp-Qt, verify game files, A/B `-vulkan` vs `-dx11`.
Make sure `vulkaninfo` sees the 4080 (not the iGPU) and no overlay conflicts. Once fixed, CachyOS is home and Windows stays as fallback; no TV-box changes either way.
