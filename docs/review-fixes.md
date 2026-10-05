# Review fixes — what changed, and what to watch on first boot

Maps every finding of `review-2026-10-05-compiled.md` to its fix. Status: **T** = covered by the bats suite, **S** = static (shellcheck/compose/Caddy validation), **H** = needs real hardware to confirm.

## P0
| # | Finding | Fix | |
|---|---|---|---|
| 1 | Untracked files break clone | committed; `unbound.conf` tracked; init-user-db removed (Immich ships its own Postgres image) | S |
| 2 | `.env.immich` never rendered | removed `env_file`; Immich/Postgres get `environment:` interpolated from `docker/.env` (required vars fail loudly) | T |
| 3 | `eval` without export | `eval` gone; `env_get/env_set` read the env file as data; steps read it themselves | T |
| 4 | Caddy `nextcloud:8081` | proxies `nextcloud:80`; Nextcloud given trusted proxy/overwrite env natively | T |
| 5 | scripts not executable | `chmod +x`; a test asserts every script is executable | T |
| 6 | `backup.sh` path/User/scope | no `~`; root-safe; backs up to a dedicated backup disk; DB dumps, Teleporter, Caddy CA, configs; docs match | H |
| 7 | Pool perms/format/shadow dirs | `disks.sh` formats blank disks after typed confirmation, sentinel + `chattr +i` mountpoints, group `www-data` setgid, fail loud if pool absent | T/H |
| 8 | Sorted trees invisible | Samba `Cloud`/`Uploads`; Nextcloud External Storage for each tree; Immich external library on `Photos/` | H |

## P1
| Finding | Fix |
|---|---|
| `categorize.sh:29` syntax error | fixed; summaries work |
| `price-check` -> `router.sh` RCE | config files are parsed as data (`conf-load.sh`, no `source`); ids validated by regex; atomic write; OpenRouter removed (T) |
| `effective_paid_order` no-op guard | the whole multi-provider order logic was replaced by a single typed tier ladder (T) |
| `router_decide` killed the free ladder | low-confidence CLEAN now reaches free tiers whenever a key exists (T) |
| Low-conf exfil, no redaction, prose parsing | `redact.py` fails closed; `extllm.py` demands typed JSON; Command Code only; capped ledger (T) |
| LAN-wide 0.0.0.0 + socket | only 53/80/443/445 published; ufw private ranges; Dockge removed; Watchtower label-gated, not Caddy/DBs/Immich/Nextcloud; Beszel agent socket `:ro` (T for ports) |
| `htpc` + docker group + autologin | user-agnostic; trade-off documented (convenience-first, headless option) |
| Queue never drains / `.judge` leak | every job ends in `done/`; binaries terminal; no `.judge` files; retries bounded (T) |
| `nextcloud-proxy.sh` | deleted; replaced by native env vars |
| Watchtower updates Caddy | excluded |
| Pi-hole `8080o,[::]:8080o` | `8080`, not published |
| Secrets `644` | `.env` and `router.conf` created mode 600 (T) |
| `sort-music` traversal / exit code collision | sanitiser; python failure exits 2 (T) |
| `immich-library` + `git add -A` | mount removed; ignores for secrets/data; docs forbid blind `git add -A` (T) |

## Medium / Low
Docs drift fixed (all docs rewritten; `docs/11` reference removed; thresholds 0.82; backups nightly; compose paths). `.gitignore` widened (T). `ingest`: flock, oldest-first, settle window, nested folders, OOXML/ODF/epub extraction, OCR only on images/scanned PDFs, filename rules on every type (T). Chunked LLM judging instead of truncation (T). `/tmp/tmp.*.judge` glob wipe gone. Spend ledger moved to `/var/lib/tvbox` and backed up, tab-separated (T). Redis persistence off. Jellyfin gets video/render groups. `30-docker` group set in every branch. `60-tailscale` handles `ssh` vs `sshd`. Pi-hole UI proxied at its own hostname (no `/pihole` SPA breakage). LICENSE, CI (shellcheck + bats + compose + Caddy), log rotation, memory cap on the CPU ML container, separate DB root password, Nextcloud admin password generated and saved, restic password escrow instructions, alerting via `notify.sh`/ntfy.

## Not verifiable off-box — watch these on first boot
1. `disks.sh` format/mount/unplug/replug against your real USB enclosures (the mergerfs `+>`/`-` live branch changes use `setfattr` on `/mnt/pool/.mergerfs`).
2. Nextcloud first-run install + `post-install.sh` external-storage `occ` calls (option names vary a little across major versions); the Immich admin/library API calls (v3).
3. The tunnel guard path lists for share pages (Caddy logic is tested; the real Nextcloud/Immich paths need a live share link).
4. `cloudflare.sh` against the live Cloudflare API (falls back to dashboard instructions on any error); Caddy's xcaddy build.
5. Samba/Avahi/wsdd discovery from Windows, macOS, Android.
6. The autoinstall seed and the Legion scripts (see their READMEs).
