# 07 — Remote Access + Agent Reinstall Flow

## SSH
- OpenSSH on host, key-only, Tailscale + LAN. Hardening snippet in `configs/ssh/10-hardening.conf` (PasswordAuthentication no, etc.).
- `tailscale up --ssh --accept-dns`. SSH via `ssh htpc@tvbox` (LAN) or `ssh htpc@<tailnet-ip>` (remote).

## Agent flow (OpenCode over SSH)
After any re-flash, from another machine with OpenCode installed:
```bash
# agent SSIs in and runs the same 4 commands a human would:
git clone https://github.com/<you>/tv-box-cloud-server.git ~/tv-box-cloud-server
cd ~/tv-box-cloud-server
cp docker/.env.example docker/.env   # fill UUIDs/passwords (agent asks you once)
sudo ./scripts/install.sh
cd docker && docker compose up -d
```
- `install.sh` is idempotent: every `NN-*.sh` checks state first (`command -v docker`, `grep -q DNSStubListener`, `mountpoint -q /mnt/pool`). Safe to re-run.
- No secrets in repo — `STORAGE_DISK1_UUID`, `PIHOLE_PASSWORD`, etc. come from `docker/.env` or env vars.
- Verify gate: `./scripts/90-verify.sh` (`vainfo`, `docker compose config`, `dig`, `mergerfs`, `tailscale status`).

## Push this repo to GitHub
```bash
cd ~/tv-box-cloud-server
git add -A && git commit -m "plan: tv box + cloud server"
gh repo create tv-box-cloud-server --public --source=. --push
# or: git remote add origin git@github.com:<you>/tv-box-cloud-server.git && git push -u origin master
```
Then future agents just `git clone` it after a flash.
