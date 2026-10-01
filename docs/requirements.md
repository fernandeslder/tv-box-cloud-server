# Requirements (compiled from owner notes — source of truth for reviews)

## Device + roles
- One always-on box over HDMI to a smart TV: doubles as TV box + personal cloud server.
- TV: YouTube, Twitch, Moonlight (gaming PC), browser, IPTV, Stremio + Torrentio, own music (Navidrome, self-hosted Spotify), Jellyfin for local media. USB HID remotes work; x86 has no native HDMI-CEC.
- Network: Pi-hole ad-blocking required. Tailscale for remote (free = fine); Headscale/WireGuard documented as FOSS purist path.
- Repo must be fully reproducible: flash → git clone → install.sh → compose up; agent-redoable over SSH. Lives at github.com/fernandeslder/tv-box-cloud-server.

## Storage
- 238GB NVMe = cache (Docker, DBs, thumbs). 1TB + 4TB HDDs (later) = mergerfs pool, ext4 per-disk, no RAID/ZFS.
- 1Gbps LAN uploads. Auto phone photo upload. No manual folders — everything auto-sorted, always visible to the owner (Nextcloud/Immich), scanned or not.
- `inbox/` is the single Uploads target (phone auto-upload + manual downloads). Sorted trees: Photos/ Documents/ Music/ Recordings/ Videos/ Other/ + private/.

## Threat model (secrets, not PII)
- Only secret credentials matter (API keys, passwords, tokens, private keys). Names/addresses are NOT a concern.
- Secrets live in `private/` — still visible to owner, same apps. NOTHING unprocessed or secret-bearing goes to outside APIs (only TV box + Legion, which are owned). Clean-screened files may use outside APIs if enabled.

## AI offload (Legion 7: RTX 4080 12GB, 32GB, dual-boot Win11/CachyOS, often offline)
- Heavy models on Legion via Tailscale (`legion-linux`/`legion-win` hostnames). Offline-tolerant: default-deny queue, `pending-ai` usable locally, excluded from offsite copy; CPU fallbacks where possible.
- VRAM rule: one workload family at a time; Ollama max-1-loaded + 5-min eviction.

## Cost policy
- Priority: FREE first, self-hosted second (even closed-source), FOSS preferred, PAID last-resort minimized by a confidence-gated router (transcript-only ~4KB escalation, monthly cap, ledger). Paid OFF by default.
- Daily price-check refreshes cheapest paid + free picks (OpenRouter catalog). Free escalation ladder: OpenCode CLI free tier ($0 quota) → OpenRouter :free → paid capped.

## System 1 vs System 2 (Jev, not Jeff)
- System 1 = decision model: typed noul/choice/score with calibrated confidence, never parsed prose (`scripts/jev.sh` over Ollama structured outputs; exit 2 = defer).
- Jev engine default qwen2.5:3b-instruct is a stand-in; real drop-ins: Kev, Laya, SemIf, NanoJev 0.6B.
- System-1 fallback chain: Legion engine → local NanoJev (TV-box CPU) → defer. NEVER System 2 for System-1 decisions. Valid low-confidence = answer, not failure.
- System 2 (qwen2.5:7b) generative lane ONLY: invents new category names. Categorization workflow: fit existing → else NEW → System 2 names → file it.

## Sorting specifics
- Faces: Immich auto-detect (InsightFace), name once in app, search by person; sorted Photos/ as read-only external library.
- Audio: whisper speech-vs-music (8+ words = recording → Recordings/ + transcript judged like any text); music → Music/<Artist>/[<Album>/], filename = song name, never renamed; fuzzy artist dedup (the/typo/space-insensitive, ~0.82).
- Music filenames (Artist-Title / Title-Artist / Title-only) split by Jev general knowledge, dumb-split fallback only.
- Documents: filename-first priority + one-line summary sidecar; stage-0 local regexes (IDs/Finance/Health → private/, zero network) run BEFORE any model; secrets-hit docs also sub-sorted into private/.
