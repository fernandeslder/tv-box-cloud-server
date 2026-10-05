# Compiled Codebase Review — tv-box-cloud-server — 2026-10-05

**Orchestrated models:**
- `commandcode/laguna-s-2-1-free#max` — max reasoning, unlimited depth
- `commandcode/space-bunny-alpha#max` — max reasoning, unlimited depth
- `commandcode/ling-3-1-flash-free#max` — max reasoning, unlimited depth
- `commandcode-anthropic/claude-sonnet-5-5#low` — token-optimal, concise only

**Orchestrator verification:** re-read `scripts/router.sh`, `scripts/install.sh`, `scripts/categorize.sh:29`, `scripts/ai-queue.sh`, `scripts/price-check.sh`, `scripts/40-storage.sh`, `scripts/nextcloud-proxy.sh`, `backups/backup.sh`, `docker/net/Caddyfile`, `docker/net/compose.yml`, `docker/cloud/compose.yml`, `.gitignore`, and ran `git status`, `ls -l`, `grep git-add`. Status below as `Verified` vs `Reported`.

---

## Consensus: do not run `install.sh` as-is

All 3 deep reviewers agree: design + docs are strong, fresh-install path is broken. Two systemic causes:

1. **Uncommitted work:** 7 modified + 3 untracked. `Verified` via `git status --short`.
   - `M docker/.env.example, docker/cloud/.env.immich.example, docker/cloud/compose.yml, docker/media/compose.yml, docker/ml-laptop/compose.yml, docker/net/Caddyfile, docker/net/compose.yml`
   - `?? docker/cloud/init-user-db.sh, docker/net/unbound.conf, scripts/nextcloud-proxy.sh`
2. **Docs drifted from code:** Presidio, `docs/11`, thresholds, backup scope, verify claims.

Sonnet-low missed most of this — it spot-checked only, hallucinated some line numbers. Its unique value: socket-proxy, separate DB passwords, restic key escrow.

---

## P0 — verified, fix before first boot

### 1. Untracked files break clone
`Verified`. `docker/net/compose.yml:10` and `docker/cloud/compose.yml:37` bind-mount `unbound.conf` / `init-user-db.sh`; missing source becomes a directory, unbound/postgres entrypoint fail.
**Fix:** `git add` + commit all 7M+3U.

### 2. `scripts/install.sh:10` — `.env.immich` never rendered
`Verified`. `.env.immich.example:2-4` claims install renders it; code does plain `cp`. `env_file` does not interpolate, so `immich-server` gets literal `DB_PASSWORD=${IMMICH_DB_PASSWORD:?...}`, postgres gets real password via `environment:` at `docker/cloud/compose.yml:42`. Immich crash-loops.
**Fix:** `envsubst`/sed render or move `DB_*` to `environment:`.

### 3. `scripts/install.sh:13` — `eval` without `export`
`Verified`. Sets shell vars, then `./40-storage.sh` child sees nothing → no fstab UUIDs → pool never mounts → `/mnt/pool/*` dirs created on NVMe root. Also `eval` injection.
**Fix:** `set -a; eval; set +a` or whitelist `while read`, no `eval`.

### 4. `docker/net/Caddyfile:34` — `reverse_proxy nextcloud:8081`
`Verified`. `docker/cloud/compose.yml:68` is `8081:80` (host:container); inside compose network it listens on `80`. All other upstreams use container ports. `files.home.lan` → 502.
**Fix:** `nextcloud:80`.

### 5. `ingest.sh` / `nextcloud-proxy.sh` / `init-user-db.sh` not executable
`Verified` via `ls -l` (all `664`). `ingest.service ExecStart` → systemd 203/EXEC, inbox never drains.
**Fix:** `chmod +x`.

### 6. `backups/backup.sh:21` — `~/tv-box-cloud-server/...` + `User=root` → `/root/...`
`Verified` script line. `set -e` aborts before `/mnt/pool` backup. Plus scope gap: script backs up `.env`, `.kodi`, `/mnt/pool` only — no `pg_dump`, no mariadb dump, no Teleporter, no Caddy/Pi-hole data. DBs live on `${CACHE_ROOT}` (NVMe) → re-flash loses Immich metadata + Nextcloud accounts.
**Fix:** absolute repo path, add dumps + Teleporter + Caddy data, reconcile `docs/08-ops-runbook.md`.

### 7. Pool perms + storage
`Verified` `scripts/40-storage.sh:5,17` mkdirs as root, no `chown`, no `mkfs`, `mount -a || log "deferred — ok"`. Runtime units run as `htpc` → permission-denied; blank disks → shadow dirs on NVMe, data stranded.
**Fix:** format-if-blank + sentinel, `chown htpc`, fail loud if pool absent. Add `nofail`, `After=`/`Requires=` for mergerfs vs automount race.

### 8. Sorted trees invisible
Reported by Bunny C4 + Ling H7, refs consistent (`docker/cloud/compose.yml:70` datadir `/mnt/pool/files` vs `scripts/ingest.sh:12` sorts to `/mnt/pool/{Photos,Documents,...}`, `immich-library` mount `./immich-library` missing on disk + not gitignored). No app serves sorted output. Phone upload → `/mnt/pool/files/inbox` never ingested; inbox → sorted never shown.
**Fix:** Nextcloud `external_storage` mounts (`occ mount`) or document gap; wire Immich external library to `${STORAGE_ROOT}/Photos:ro`.

---

## P1 — verified highs

- **`scripts/categorize.sh:29` syntax error.** `Verified`: `print(...get('summary','')}` — `}` vs `)`. Swallowed by `|| true` → every `.summary.txt` is filename. One-char fix.
- **`scripts/price-check.sh:61-64` → `scripts/router.sh:11` RCE.** `Verified`: unquoted `${model-id}` from unauthenticated OpenRouter catalog written to sourced `router.managed.conf`. **Fix:** regex `^[A-Za-z0-9._:/-]+$`, quote, atomic write (`tmp+mv` + `fsync`).
- **`effective_paid_order :135` guard no-op.** `Verified` `scripts/router.sh:122,135`: `sys.argv[3]` is literal `"OPENROUTER_MODEL=..."`, always truthy. Masked downstream by `:106` check. **Fix:** pass value directly.
- **`router_decide :55` kills free ladder by default.** `Verified`: `PAID_ENABLED!=true → LOCAL`, so `router_paid_opinion` free steps (OpenCode → OpenRouter `:free`) never run, contradicting `docs/06-ai-classification.md`. Needs policy decision: let low-conf CLEAN fall through to free steps.
- **Low-conf CLEAN exfil (conditional).** `Verified` code gates on verdict only (`scripts/router.sh:51-57`). With defaults unreachable; with `PAID_ENABLED=true`, `conf 30 CLEAN` transcript ships verbatim to 3 externals, no redaction, prose+grep parsing (`router.sh:76,89,110`, `ai-queue.sh:36-37`) → prompt-injectable. **Fix:** redact (Tier-0 patterns, high-entropy, PEM, digit runs) + typed contract for externals.
- **LAN-wide `0.0.0.0` + no firewall + docker socket.** `Verified` in `docker/net/compose.yml`: `5001`, `3000`, `3001`, `8090`, `8080`, plus Immich/Nextcloud/media ports; `dockge` mounts `/var/run/docker.sock` rw. Only postgres is `127.0.0.1`. **Fix:** bind to `127.0.0.1`/drop publishes behind Caddy, `ufw` default-deny, socket-proxy or `:ro`.
- **`htpc` in `docker` + SDDM autologin.** Reported, refs consistent (`scripts/30-docker.sh:10`, `configs/sddm/autologin.conf`). Docker group = root; desktop untrusted-input surface. **Fix:** separate `server` user or rootless, drop `htpc` from `docker`.
- **Queue never drains for video/Other + `.judge` leak.** `Verified` `scripts/ai-queue.sh:120-137` `*)` requires transcript that nothing produces for mp4/zip → retry every 5m forever; `:139` cleans `.transcript` but not `.transcript.judge`. **Fix:** terminal `done/` state, clean `.judge`.
- **`scripts/nextcloud-proxy.sh:10,12` wrong project.** `Verified`: `-f ../docker/cloud/compose.yml` → project `cloud`, running stack is `docker/compose.yml` → project `docker`; plus `getent hosts caddy` fails cross-network, missing `trusted_domains`, ephemeral IP. **Fix:** `cd ../docker && docker compose exec`, read `CADDY_DOMAIN` from `.env`.
- **Watchtower updates Caddy.** `Verified` `docker/net/compose.yml:60` `enable=true`. Caddy is SPOF for all apps. **Fix:** exclude like DNS/gluetun or pin + `--rollback`.
- **Pi-hole `FTLCONF_webserver_port: 8080o,[::]:8080o`.** `Verified` value at `docker/net/compose.yml:36`. Correction: Laguna called it "invalid" — wrong. Per FTL docs `o` = optional bind, so failure is silent no-UI. **Fix:** make one mandatory (`8080,[::]:8080o`).
- **Secrets `644`.** Reported, consistent: `cp` in `install.sh:9-11`, no `chmod`. **Fix:** `install -m 600` / `chmod 600` for `.env`, `.env.immich`, `router.conf`.
- **`sort-music.sh` traversal + exit-code collision.** `ARTIST/ALBUM` from tags/model unsanitized → `mkdir -p`; `rc=1` means speech but also internal error (e.g. missing `Music/` dir) → misfile to `Recordings/`. **Fix:** sanitize like `categorize.sh:69`, reserve error code.
- **`immich-library` + `git add -A --public`.** `Verified` mount `docker/cloud/compose.yml:13`, dir absent, not in `.gitignore`, `docs/07-remote-access.md:24` instructs `git add -A` + `--public`. Severity: High (requires uploads + push). **Fix:** move out of tree, `**/.env` + `*-library/` ignore, never `-A` to public.

---

## Medium / Low consolidation

- Docs drift: `docs/04:38` Presidio, missing `docs/11-phone-setup.md` (Caddyfile:9), `0.82` vs `0.87`, nightly vs weekly backup, `06:56` 06:00 vs `daily`, Prowlarr/Sonarr listed but absent, `torrent/compose.yml` path wrong, `90-verify.sh` claims vs reality, `README:16-19` `./scripts` after `cd docker`, duplicate numbering in `09`, duplicated Honest-exceptions in `00`.
- `.gitignore` too narrow: `Verified` — covers `docker/.env`, `cloud/.env.immich`, `router.*`, `docker/*/data/` but not `ml-laptop/.env`, `media/.env`, `immich-library/`.
- `ingest` no `flock` (ai-queue has it), glob order not oldest-first, mid-upload ingest, tesseract on docx/epub/zip, `jev.sh` 3000 vs `scan-secrets` 6000 truncation, `/tmp/tmp.*.judge` glob wipe, `spend.log` space-in-filename breaks `awk $4` cap, non-atomic `prices.json`, Redis RDB on, Jellyfin missing `group_add video/render`, `40-storage` UUID-rerun duplicates, `30-docker` group only in one branch, `60-tailscale` `sshd` vs `ssh` unit, `Caddyfile:17` `/pihole*` SPA breakage, `install.sh:22-28` convoluted loop.
- Stage-0 skipped on UNSCANNED path (`ingest.sh:63-71`, `ai-queue.sh:120-137` doc branch) — cheap offline regex should run everywhere.
- Office/epub extraction gap: Tier-0 + tesseract miss zip containers → empty transcript → CLEAN.
- Missing: LICENSE (public repo plan), firewall, log rotation (`daemon.json`), resource limits, DB root vs user same password (`docker/cloud/compose.yml:88,91`), Nextcloud admin pw undocumented, restic key no escrow/offsite, no tests/shellcheck/bats, no `docker compose config --quiet` gate, no alerting on timer failure, `spend.log` in excluded `.ai-queue` resets cap on restore.

---

## Strengths (consensus, keep)

Idempotent state-check installer, `bash -n` clean; pinned DNS/Immich/trufflehog/gluetun; expert Unbound (DNSSEC, `private-address`, `qname-minimisation`, correct healthcheck override); `ps`-safe stdin/env + `--no-verification`; `SECRET→BLOCKED` in code; typed Ollama JSON-schema Jev + defer on malformed; free-first + cap + ledger; `safe-move` no-clobber + hash dedup; `flock` ai-queue + `Type=oneshot`; gluetun netns kill-switch; fail-loud restic intent; honest docs with locked decisions.

---

## Top actions (ordered)

1. Commit 7M+3U, `chmod +x` 3 files.
2. Render `.env.immich`, export UUIDs (`set -a`), `chown 600` secrets.
3. Fix Caddy `nextcloud:80`, storage format/sentinel/chown/fail-loud.
4. Fix `backup.sh` path + add DB dumps/Teleporter/Caddy, fix `docs/08`.
5. Fix `categorize.sh:29`, quote+validate `router.managed.conf`, fix `or_model` guard.
6. Decide `router_decide` free-ladder policy + redact before exfil + structured externals.
7. Lock down binds/firewall/socket, separate `htpc` from `docker`, exclude Caddy from Watchtower, fix `nextcloud-proxy.sh` project.
8. Queue hygiene, sanitize music tags, `flock` ingest, atomic writes, docs sync, `shellcheck`+`compose config` gate + LICENSE.

---

### Per-model notes
- **Laguna S 2.1 (max):** caught uncommitted-files blocker, Pi-hole port typo, `router_decide` ladder bug, backup-scope mismatch. Good on reproducibility.
- **Space Bunny Alpha (max):** deepest; verified tags/entrypoints/shell empirically. Found Immich DB auth, Caddy port, invisible sorted trees, DB-less backup, low-conf exfil, `categorize.sh` syntax, price-check RCE, docker-group+autologin, 0.0.0.0, storage shadow-dirs, queue drain, traversal, stage-0 skip, Watchtower-Caddy, proxy script, grep-decisions.
- **Ling 3.1 Flash (max):** broadest file coverage; unique: `eval`-without-export proof, `immich-library` public-push risk, `ingest.sh` 203/EXEC, pool chown, gluetun healthcheck, office-doc hole.
- **Claude Sonnet 5.5 (low, token-optimal):** spot-check only; some line refs off. Unique keeps: socket `:ro`/proxy, separate `MARIADB_ROOT_PASSWORD`, restic key escrow/offsite.
