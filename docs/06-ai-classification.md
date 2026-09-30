# 06 — AI Classification (free, offline-first)

## Principle
Cheap local gate first, heavy GPU on laptop, cloud APIs never (or last + quarantined).

```
Immich upload --> local thumbs/EXIF --> Immich ML (remote CUDA) --> faces/CLIP/OCR
  --> Presidio PII gate --> if sensitive: quarantine + local-only tag
  --> else: optional Ollama caption --> Immich tags/auto-albums
  --> else (user-approved only): cheap cloud enrichment
Speed doesn't matter — box is always on, queue drains eventually.
```

## Remote ML on laptop (12GB VRAM, 32GB RAM)
Laptop compose (`docker/ml-laptop/compose.yml`, NOT on tvbox):
```yaml
services:
  immich-machine-learning:
    image: ghcr.io/immich-app/immich-machine-learning:release-cuda
    ports: ["3003:3003"]
    volumes: [model-cache:/cache]
    deploy:
      resources:
        reservations:
          devices: [{driver: nvidia, count: 1, capabilities: [gpu]}]
  ollama:
    image: ollama/ollama:cuda
    ports: ["11434:11434"]
    volumes: [ollama:/root/.ollama]
    # ollama pull moondream; ollama pull llava:7b
```
- Immich Admin → ML Settings → add `http://<laptop-tailnet>:3003`. Versions must match on both hosts. Bind to Tailscale only, never public (no auth on ML port).
- VRAM fit: ViT-B-32 ~1GB (fast/good), SigLIP-SO400M ~4-5GB (best recall), nllb-clip multilingual ~3GB, buffalo_l/antelopev2 face ~1GB, moondream ~5GB, llava:7b ~8GB. All fit 12GB (not all at once — queue them).
- Keep tvbox local `immich-machine-learning` (CPU) as fallback or remove to force remote.

## PII / sensitive-data gate (runs on tvbox, ~1-2GB RAM)
```yaml
services:
  presidio-analyzer:
    image: mcr.microsoft.com/presidio-analyzer:latest
    ports: ["5002:3000"]  # internal only
  presidio-anonymizer:
    image: mcr.microsoft.com/presidio-anonymizer:latest
    ports: ["5001:3000"]
```
Flow: Immich webhook / Paperless consume → OCR (DocTR/PaddleOCR CPU) → `presidio-analyzer:5002` → if score > threshold: quarantine + `local-only` tag, skip cloud. Alt tiny binary: `pii-guard` (Rust, 10x lighter). Images: `presidio-image-redactor`.

## Auto-organization (no manual folders)
- Rely on Immich smart search (`beach sunset dog`), Persons, Map. Script Ollama captions → `PUT /albums` + `POST /tags` via Immich API.
- Nextcloud Memories Recognize (~1.5GB models, needs 4GB RAM) is fallback for files only — worse than Immich, skip for photos.

## Cost
$0. Everything above is offline. Optional fallback: rclone encrypted to B2/Storj, or Ente 10GB free for critical selects. Never send originals to Jina/cloud without passing the Presidio gate.
