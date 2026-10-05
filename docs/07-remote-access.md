# 07 — Remote access, SSH, and rebuilding from scratch

## SSH
Key-only SSH is enabled **only if your account already has an authorized key** (otherwise setup leaves password login on and tells you — it can never lock you out). Tailscale SSH (`tailscale up --ssh`) works with no keys at all. `ssh <user>@tvbox.local` on the LAN, or the tailnet name away from home.

## Rebuilding after a re-flash (human or agent)
```bash
curl -fsSL https://raw.githubusercontent.com/fernandeslder/tv-box-cloud-server/master/bootstrap.sh | sudo bash
```
Unattended: put pre-answers in `/opt/tvbox-seed.env` (same keys as `docker/.env.example`) and run with `TVBOX_NONINTERACTIVE=1`. Everything is idempotent — re-running is always safe. Your data survives on the USB disks; recovery = flash -> bootstrap -> plug the disks (setup adopts disks it labelled `tvbox-*`) -> `tvbox restore` for databases (see `08`).

## Contributing / publishing the repo
Secrets never live in the repo: `docker/.env`, `configs/router.conf`, `configs/router.managed.conf` and `docker/*/data/` are git-ignored (the test suite checks it). Before pushing anything public, run `git status` and `git diff --cached --stat`; **never `git add -A` blindly**.
