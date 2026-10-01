# 10 — Legion 7 AI Server Setup (do this WHILE the TV box installs)

Your Legion 7 (RTX 4080 Laptop 12GB VRAM, 32GB RAM) is the GPU worker. It dual-boots **Windows 11** and **CachyOS** — this doc covers **both**, plus what happens when the Legion is offline (it won't always be).

Shared facts (both OSes): Tailscale with per-boot hostnames `legion-win` / `legion-linux`, same models, same VRAM policy. The TV box tries `legion-linux` first, then `legion-win` (`LEGION_HOSTS` in `scripts/scan-secrets.sh`), so whichever OS is booted just works with no TV-box reconfig.

## Models (same list, both OSes — pull once per OS, ~10GB each side)
```
qwen2.5:3b-instruct   # Jev (System 1): secrets judge + fit-checks, ~2GB VRAM, seconds per snippet
qwen2.5:7b-instruct   # System 2: names genuinely new categories, ~5GB VRAM, slow lane (Ollama swaps it in on demand)
moondream             # vision: screenshots / handwriting / nasty layouts, ~2GB VRAM
# llava:7b            # optional captions, ~5GB VRAM — only if you want chatty descriptions
faster-whisper small  # STT: speech-vs-music + recording transcripts, ~2GB VRAM (compose profile `audio`, :9000)
Jev engine default: qwen2.5:3b-instruct (stand-in). Swap JEV_MODEL to a true decision-tuned engine anytime: Kev 0.8B/4B/9B, Laya, SemIf, or NanoJev 0.6B (NanoJev is small enough to run on the TV box itself — see `docs/06`).
```
Ollama env (both OSes): `OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_KEEP_ALIVE=5m` — one resident model max, auto-swap. This is the LLM-side orchestration; nothing else needed.

## Path A — Windows 11 (current daily driver for Dota 2)
1. Install **Tailscale** (Windows), log in, set machine name `legion-win`. Note: use the *name*, not the IP, everywhere.
2. Install recent **NVIDIA driver** (Game Ready or Studio).
3. Install **Ollama for Windows** (native app). In Settings/env set the two vars above, and bind LAN access: `OLLAMA_HOST=0.0.0.0` + Windows Firewall rule allowing TCP 11434 from the Tailscale range (`100.64.0.0/10`) and LAN. Verify from TV box: `curl http://legion-win:11434/api/tags`.
4. Install **WSL2 + Ubuntu** + **Docker Desktop** (WSL2 backend, Ubuntu integration on). For Immich remote ML: `docker compose --profile photos up -d` in `docker/ml-laptop` (runs `:3003`). In Immich Admin → ML Settings add `http://legion-win:3003`. Versions must match the TV box.
5. `ollama pull qwen2.5:3b-instruct` + `ollama pull moondream` + `ollama pull qwen2.5:7b-instruct` (System 2, slow lane).

## Path B — CachyOS (target once Dota is fixed)
1. Boot CachyOS, install **Tailscale** (`sudo pacman -S tailscale; sudo systemctl enable --now tailscaled; sudo tailscale up`), set machine name `legion-linux`.
2. NVIDIA + Docker (CachyOS ships recent kernels; use DKMS driver so updates don't break it):
   ```bash
   sudo pacman -S nvidia-dkms nvidia-utils docker docker-compose nvidia-container-toolkit
   sudo systemctl enable --now docker
   sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
   docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi
   ```
3. Ollama native (`curl -fsSL https://ollama.com/install.sh | sh`), `/etc/systemd/system/ollama.service.d/override.conf` with the two env vars + `OLLAMA_HOST=0.0.0.0`, firewall (`ufw`/`firewalld`) open 11434 to tailnet/LAN only. `ollama pull` the same two models.
4. Same compose profiles as Path A (`photos` for Immich ML `:3003`), same Immich admin step with `http://legion-linux:3003`.
5. Note: model weights download twice (once per OS, separate disks). ~10GB each side — budget for it.

## When the Legion is offline (expected — it's a laptop)
Default-deny queue on the TV box (full design: `docs/06-ai-classification.md`, worker: `scripts/ai-queue.sh` every 5 min via `configs/systemd/ai-queue.*`):
- Uploads land in `inbox/` → Tier 0 deterministic scan runs immediately (TV-box CPU, always available) → hit goes to `private/`, clean goes to `files/` tagged `pending-ai`.
- `pending-ai` files are fully usable locally but **excluded from offsite/cloud copy and enrichment** until screened. Local USB restic backup still includes them (never leaves the premises — fine).
- When any Legion OS comes online, the worker drains the queue oldest-first (Tier-1 judge, Immich re-triggers its own ML automatically; keep the TV-box CPU ML container enabled so photos still get faces slowly with zero Legion).
- Nothing to configure per boot — the worker probes `legion-linux` then `legion-win` and uses whichever answers.

## Dota 2 on CachyOS (the migration blocker — agent task for the other device)
Known-good checklist for your agent session on the Legion: CachyOS kernel + `nvidia-dkms` matching (reboot after updates), Steam via `steam` (native runtime, not flatpak, for shader cache sanity), Proton-GE via ProtonUp-Qt, verify game files, launch options `-vulkan` vs `-dx11` A/B, disable overlays/mango overlay conflicts, check `vulkaninfo` sees the 4080 (not iGPU). If the agent fixes it, Path B becomes home and Path A stays as fallback — no TV-box changes needed either way.
