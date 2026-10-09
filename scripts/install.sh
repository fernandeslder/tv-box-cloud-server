#!/usr/bin/env bash
# install.sh — the whole setup, start to finish. Idempotent: safe to re-run any time.
#   sudo ./setup.sh                 interactive (a few questions)
#   sudo ./setup.sh --yes           unattended (uses docker/.env or the seed file)
#   sudo ./setup.sh --reconfigure   ask everything again
#   sudo ./setup.sh --no-start      configure + install, but do not start containers
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need_root
START=1; WIZ=()
for a in "$@"; do case "$a" in --no-start) START=0 ;; --yes|--reconfigure) WIZ+=("$a") ;; esac; done
S="$REPO_DIR/scripts"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "Checking this machine"
have apt-get || die "this installer needs an apt-based OS (Ubuntu / Debian / Mint)"
[ "$(uname -m)" = x86_64 ] || warn "untested CPU architecture $(uname -m)"
curl -fsS -m 10 -o /dev/null https://download.docker.com >/dev/null 2>&1 || die "no internet access (needed to download packages)"
[ -n "$TVBOX_USER" ] && id "$TVBOX_USER" >/dev/null 2>&1 || die "cannot determine the owner account"
ok "owner account: $TVBOX_USER   repo: $REPO_DIR"
mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"; [ "$mem_mb" -ge 6000 ] || warn "only ${mem_mb}MB RAM: Immich + Nextcloud want 8GB+"
chown -R "$TVBOX_USER" "$REPO_DIR" 2>/dev/null || true

step "Your answers"
"$S/wizard.sh" "${WIZ[@]}"
chown "$TVBOX_USER" "$ENV_FILE"

step "Installing packages and system services"
"$S/10-base.sh"
"$S/20-desktop-htpc.sh"
"$S/30-docker.sh"

step "Storage (SSD cache + USB disks)"
"$S/40-storage.sh"

step "Network, firewall, Tailscale"
"$S/50-network-dns.sh"
"$S/60-tailscale-ssh.sh"

step "Generating configuration"
install -d "$TVBOX_ETC"
[ -f "$TVBOX_ETC/restic-password" ] || { openssl rand -base64 32 > "$TVBOX_ETC/restic-password"; chmod 600 "$TVBOX_ETC/restic-password"; }
"$S/render-config.sh"
ln -sf "$S/tvbox" /usr/local/bin/tvbox   # symlink: the CLI finds lib.sh next to the real file
mkdir -p "$REPO_DIR/docker/net/data" "$REPO_DIR/docker/cloud/data"
chown -R "$TVBOX_USER" "$REPO_DIR/docker/net/homepage" 2>/dev/null || true

POOL="$STORAGE_ROOT"
for ext in service timer; do
  sed -e "s#@REPO@#$REPO_DIR#g" -e "s#@USER@#$TVBOX_USER#g" -e "s#@POOL@#$POOL#g" "$REPO_DIR/configs/systemd/tvbox-netwatch.$ext" > "/etc/systemd/system/tvbox-netwatch.$ext"
done
systemctl daemon-reload
systemctl enable --now ai-queue.timer price-check.timer ingest.timer ingest.path backup.timer backup-verify.timer tvbox-smart.timer tvbox-battery.service tvbox-netwatch.timer >/dev/null 2>&1 || warn "could not enable some timers"

if [[ ",$(env_get COMPOSE_PROFILES)," == *,public,* ]]; then
  step "Public sharing (Cloudflare Tunnel)"
  "$S/cloudflare.sh" || warn "tunnel setup incomplete — see messages above"
  [ -n "$(env_get CF_TUNNEL_TOKEN)" ] || { warn "no tunnel token: public profile disabled for now"; env_set COMPOSE_PROFILES "$(env_get COMPOSE_PROFILES | sed 's/\bpublic\b//; s/,,/,/; s/^,//; s/,$//')"; }
fi

step "Checking the Docker configuration"
( cd "$REPO_DIR/docker" && docker compose config --quiet ) || die "docker compose config is invalid: see message above"

if [ "$START" -eq 1 ]; then
  step "Starting everything (first run downloads ~3GB and builds Caddy: be patient)"
  ( cd "$REPO_DIR/docker" && docker compose up -d --build --remove-orphans )
  step "Final wiring"
  "$S/post-install.sh" || warn "post-install had problems: re-run: sudo tvbox post-install"
fi

step "Saving your credentials"
CRED="$TVBOX_HOME/tvbox-credentials.txt"
DOMAIN="$(env_get DOMAIN)"
cat > "$CRED" <<CREDS
TV Box credentials — move these to a password manager, then delete this file.
Restic backup password is ALSO needed to restore: without it, backups are unreadable.

Owner (SMB/Windows share + Linux login): $TVBOX_USER / $(env_get SMB_PASSWORD)
Nextcloud admin:  https://files.$DOMAIN   $(env_get NEXTCLOUD_ADMIN_USER) / $(env_get NEXTCLOUD_ADMIN_PASSWORD)
Immich admin:     https://photos.$DOMAIN  $(env_get IMMICH_ADMIN_EMAIL) / $(env_get IMMICH_ADMIN_PASSWORD)
Pi-hole admin:    https://pihole.$DOMAIN  (password) $(env_get PIHOLE_PASS)
Restic password:  $(cat "$TVBOX_ETC/restic-password")
CREDS
chown "$TVBOX_USER" "$CRED"; chmod 600 "$CRED"

step "Done"
"$S/disks.sh" status || true
cat <<DONE

  Open on any device:   https://setup.$DOMAIN      (apps, QR codes, network drive)
  Your passwords:       $CRED
  Day-to-day command:   tvbox status | tvbox doctor | tvbox help

  Remaining one-time steps (only you can do these):
   1. Router: reserve $(env_get LAN_IP) for this box (DHCP reservation), then make the router hand out
      $(env_get LAN_IP) as DNS (or set DNS per device). Until then use http://$(env_get LAN_IP) names via your hosts file.
   2. Tailscale admin console: approve the subnet route $(env_get LAN_CIDR) and add Split DNS:
      $DOMAIN -> $(env_get LAN_IP). Then phones work everywhere.
DONE
[ -n "$(env_get CF_API_TOKEN)" ] || echo "   3. LAN-only mode: install the certificate from https://setup.$DOMAIN/root.crt on each device."
echo
