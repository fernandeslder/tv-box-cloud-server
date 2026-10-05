# 02 — OS postinstall (what the installer does for you)

`sudo ./setup.sh` runs these idempotent steps; each can be run alone:

| Script | Does |
|---|---|
| `10-base.sh` | packages (restic, rclone, mergerfs, samba, avahi, tesseract…), no-sleep/lid-ignore for a laptop chassis, hostname |
| `20-desktop-htpc.sh` | Plasma + SDDM + Kodi + Firefox + mpv, autologin for **your** account (skipped when headless) |
| `30-docker.sh` | Docker CE + compose (Ubuntu/Debian/Mint), log rotation, "start after storage" ordering |
| `40-storage.sh` | SSD cache + USB disks + pool + folder skeleton + units (see `04`) |
| `50-network-dns.sh` | frees :53 (resolved stub off), ufw (private LAN + Tailscale) |
| `60-tailscale-ssh.sh` | Tailscale + LAN subnet router, key-only SSH *if a key exists* |

Trade-off to know: the TV desktop auto-logs in as your account, and your account is in the `docker` group (root-equivalent). That is the convenience-first choice for a living-room box. For a stricter box answer "no TV" in the wizard (headless) and keep the account locked down.

Verify: `tvbox doctor`.
