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

---

# Second review pass (2026-10-09)

Found by reading every installer step against a real Ubuntu 26.04 / 24.04 package index and by running the
suite on a btrfs-root machine. Status letters as above (T = bats, S = static, H = needs hardware).

| Finding | Fix | |
|---|---|---|
| `disks.sh` could not recognise the system disk when `/` is a btrfs subvolume (`findmnt` prints `/dev/nvme0n1p2[/@]`) or LVM/LUKS: the system disk was listed as "has data" and `add --force` would have been allowed to wipe it | `root_disks()` walks the device chain (`lsblk -s`) and strips the `[...]` suffix; scan also marks any disk with a mounted filesystem "in use"; `add` refuses the system disk even with `--force` | T |
| `tvbox` was installed as a *copy* in `/usr/local/bin`, so it could not find `lib.sh` and every `tvbox ...` command (and the netwatch timer) failed | installed as a symlink; the CLI also falls back to `/opt/tvbox/scripts` and fails with a clear message | T |
| `rand()` (`tr \| head` under `pipefail`) exits 141 | rewritten without the pipe | T |
| `10-base.sh` asked for `mesa-va-drivers`, which no longer exists on 26.04 (merged into `mesa-libgallium`): the whole `apt` call failed and `vainfo`/`libva2` were never installed | optional packages are installed one by one and skipped with a warning | S |
| `dnsutils`, `unzip`, `binutils` were used by `tvbox doctor` / ingest but never installed (doctor's DNS check always failed; OOXML/ODF text extraction silently returned nothing) | added to the base package list | S |
| Backup aborted when any source path was missing or one file was unreadable (restic exit 3) | only existing paths are passed; exit 3 is a warning (the snapshot is written) | T |
| Wizard overwrote a seed's `COMPOSE_PROFILES` / `TVBOX_DESKTOP` with its built-in defaults in unattended mode; CRLF seeds corrupted values | seed answers win when unattended; CR stripped | T |
| `ollama/ollama:cuda` does not exist (the default image already has CUDA) | pinned `ollama/ollama:0.40.2`; `scripts/check-images.py` + weekly CI now verify every pinned tag | T/online |
| First boot downloaded `bootstrap.sh` from `master` even when the repo on the installer stick was newer/older | one-stick builder ships a `git bundle`; first boot clones it (pinned commit, GitHub optional) | T |
| Installer rebooted with the stick still plugged in (re-entering the installer on most firmware) | `shutdown: poweroff` | S |
| yt-dlp from apt is months old (YouTube breaks weekly) | upstream binary in `/usr/local/bin` + weekly self-update timer | H |

New, all with tests: weekly backup **restore test** (`backups/verify.sh`), daily **SMART** check, laptop **battery charge cap**,
optional **Paperless-ngx** profile, **one-stick USB builder**, image-existence check.

## Still not verifiable off-box (added to the list above)
7. `build-usb.sh` output booting on the real box (UEFI entry, `/cdrom` as the live medium, seed discovery) and the
   Subiquity `late-commands` that copy `seed/` and `tv-box/` from `/cdrom`.
8. Paperless-ngx 3.x first start with the environment given in `docker/cloud/compose.yml`.
9. `battery-care.sh` on the actual chassis (needs the kernel's `charge_control_*_threshold`).
10. Plasma 6 Wayland autologin through SDDM (`/etc/sddm.conf.d/autologin.conf`) on 26.04.

## Third pass: first real install attempt (2026-10-10)
Found from photos of the installer crash screen on the T14s:
- **Media checksum failed.** `build-usb.sh` patched `boot/grub/grub.cfg` but left the old sum in the ISO's `md5sum.txt`;
  the installer's integrity check flagged the stick. Now `md5sum.txt` is updated on every build (also by `--seed-only`, which
  repairs an already-built stick), with a test that `md5sum -c md5sum.txt` passes on the result.
- **"Problem applying the network configuration" (`network_fail`).** The seed's custom `network:` block (glob `match` for `en*` and
  `wl*` + Wi-Fi) was applied to the live installer, which had three NICs (onboard, a USB ethernet dongle, Wi-Fi). Removed: the
  installer uses its default DHCP, and Wi-Fi is written to the target only. The exact netplan error was not visible in the photos, so
  this removes the likely cause rather than a proven one; if it still fails, the installer log (Help -> Enter shell ->
  `/var/log/installer/subiquity-server-debug.log`) has the real message.
- **Hardening.** `apt.fallback: offline-install` and the package list moved from the installer to the first-boot script.
