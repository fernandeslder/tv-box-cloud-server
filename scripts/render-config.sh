#!/usr/bin/env bash
# render-config.sh — turn docker/.env into every generated config. Idempotent, safe to re-run.
#   Caddy TLS snippet, router.conf (AI keys), Samba config, phone onboarding page (+QR codes).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DOMAIN="$(env_get DOMAIN home.lan)"; LAN_IP="$(env_get LAN_IP)"; TLS_MODE="$(env_get TLS_MODE internal)"
HOST="$(env_get TVBOX_HOSTNAME tvbox)"
DATA="${TVBOX_DATA_DIR:-$REPO_DIR/docker/net/data}"
mkdir -p "$DATA/setup" "$DATA/caddy-data" "$DATA/caddy-config"

# --- Caddy TLS ---------------------------------------------------------------
if [ "$TLS_MODE" = cloudflare ]; then
  printf 'tls {\n\tdns cloudflare {env.CF_API_TOKEN}\n\tresolvers 1.1.1.1\n}\n' > "$DATA/caddy-tls.caddy"
else
  printf 'tls internal\n' > "$DATA/caddy-tls.caddy"
fi

# --- router.conf (AI + external model keys live here, mode 600) ----------------
RC="$REPO_DIR/configs/router.conf"
[ -f "$RC" ] || { install -m 600 "$REPO_DIR/configs/router.conf.example" "$RC"; }
chmod 600 "$RC"
key="$(env_get COMMAND_CODE_API_KEY)"
if [ -n "$key" ]; then
  tmp="$(mktemp)"; grep -vE '^COMMAND_CODE_API_KEY=' "$RC" > "$tmp" || true
  printf 'COMMAND_CODE_API_KEY=%s\n' "$key" >> "$tmp"; cat "$tmp" > "$RC"; rm -f "$tmp"
fi
[ -n "${TVBOX_USER:-}" ] && chown "$TVBOX_USER" "$RC" 2>/dev/null || true

# --- Samba (root only; skipped when not root, e.g. in tests) ------------------
if [ "$(id -u)" -eq 0 ] && have smbd; then
  NETBIOS="$(echo "$HOST" | tr '[:lower:]' '[:upper:]' | cut -c1-15)"; POOL="$STORAGE_ROOT"; USER_="$TVBOX_USER"
  sed -e "s#@NETBIOS@#$NETBIOS#g" -e "s#@POOL@#$POOL#g" -e "s#@USER@#$USER_#g" \
    "$REPO_DIR/configs/samba/smb.conf.tpl" > /etc/samba/smb.conf
  testparm -s /etc/samba/smb.conf >/dev/null 2>&1 || warn "smb.conf failed testparm"
  if id "$TVBOX_USER" >/dev/null 2>&1 && [ -n "$(env_get SMB_PASSWORD)" ]; then
    printf '%s\n%s\n' "$(env_get SMB_PASSWORD)" "$(env_get SMB_PASSWORD)" | smbpasswd -a -s "$TVBOX_USER" >/dev/null
  fi
  systemctl enable --now smbd avahi-daemon >/dev/null 2>&1 || true
  systemctl restart smbd 2>/dev/null || true
  systemctl enable --now wsdd2 >/dev/null 2>&1 || systemctl enable --now wsdd >/dev/null 2>&1 || true
fi

# --- onboarding page ----------------------------------------------------------
SETUP="$DATA/setup"
qr() {  # qr <text> <file>
  if have qrencode; then qrencode -t SVG -m 1 -s 6 -o "$SETUP/$2" "$1" 2>/dev/null || true; fi
}
qr "https://photos.$DOMAIN" qr-photos.svg
qr "https://files.$DOMAIN" qr-files.svg
qr "https://setup.$DOMAIN" qr-setup.svg
qr "https://tailscale.com/download" qr-tailscale.svg
cp -r "$REPO_DIR/clients" "$SETUP/" 2>/dev/null || true
OWNER="${TVBOX_USER:-owner}"
if [ "$TLS_MODE" = internal ]; then
  CERT_SECTION='<section><h2>2. Trust the certificate (once per device)</h2><p>This box uses its own certificate authority. <a href="/root.crt">Download root.crt</a>, then: <b>iPhone</b> open it &rarr; Settings &rarr; Profile Downloaded &rarr; Install, then Settings &rarr; General &rarr; About &rarr; Certificate Trust Settings &rarr; enable. <b>Android</b> Settings &rarr; Security &rarr; Install a certificate &rarr; CA certificate. <b>Windows/Mac/Linux</b>: run the helper in <a href="clients/">clients/</a>.</p></section>'
else
  CERT_SECTION='<section><h2>2. Certificates</h2><p>Nothing to install &mdash; this box uses a trusted public certificate.</p></section>'
fi
cat > "$SETUP/index.html" <<HTML
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Set up your devices &mdash; ${HOST}</title>
<style>
 body{font:16px/1.5 system-ui,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem;background:#0f1419;color:#e6e6e6}
 h1{margin-bottom:.2rem} section{background:#1a212b;border-radius:12px;padding:1rem 1.2rem;margin:1rem 0}
 a{color:#7cc4ff} code{background:#0b0f14;padding:.1rem .4rem;border-radius:4px} .qr{display:flex;gap:1.5rem;flex-wrap:wrap}
 .qr figure{margin:0;text-align:center} .qr img{width:140px;background:#fff;border-radius:8px;padding:4px}
</style></head><body>
<h1>Set up your devices</h1><p>Username: <b>${OWNER}</b> (password: ask the person who installed the box).</p>
<section><h2>1. Phone apps</h2>
<p><b>Photos &mdash; Immich</b> (auto-backs-up your camera roll). Server URL: <code>https://photos.${DOMAIN}</code><br>
<b>Files &mdash; Nextcloud</b> (documents, sync, sharing). Server URL: <code>https://files.${DOMAIN}</code> &mdash; in the app, set auto-upload to the <i>Uploads</i> folder and it files itself.</p>
<div class="qr"><figure><img src="qr-photos.svg" alt="photos"><figcaption>Immich server</figcaption></figure>
<figure><img src="qr-files.svg" alt="files"><figcaption>Nextcloud server</figcaption></figure></div>
<p>Get the apps: <a href="https://immich.app/docs/features/mobile-app">Immich</a> &middot; <a href="https://nextcloud.com/install/#install-clients">Nextcloud</a></p></section>
${CERT_SECTION}
<section><h2>3. Network drive on your computer</h2>
<p>Windows: <code>\\\\${HOST}\\Cloud</code> &nbsp; Mac/Linux: <code>smb://${HOST}.local/Cloud</code> &nbsp; (<code>smb://${LAN_IP}/Cloud</code> if the name does not resolve)<br>
<i>Uploads</i> = drop files here and they sort themselves. <i>Cloud</i> = everything.<br>
One-click helpers: <a href="clients/">clients/</a> (Windows, Mac, Linux).</p></section>
<section><h2>4. Away from home</h2>
<p>Install <a href="https://tailscale.com/download">Tailscale</a>, sign in to the same account as this box, and everything above works exactly as it does at home.</p>
<div class="qr"><figure><img src="qr-tailscale.svg" alt="tailscale"><figcaption>Tailscale</figcaption></figure>
<figure><img src="qr-setup.svg" alt="this page"><figcaption>This page</figcaption></figure></div></section>
</body></html>
HTML
ok "configs rendered (domain=$DOMAIN tls=$TLS_MODE)"
