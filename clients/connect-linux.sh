#!/usr/bin/env bash
# Connect a Linux computer to the home server (SMB shares + optional root cert).
# Usage: ./connect-linux.sh [-H host] [-d domain] [-u user] [-c] [-f]
#   -H host    server name or LAN IP (default: $TVBOX_HOST or tvbox.local)
#   -d domain  your server domain, e.g. home.example.org (default: $TVBOX_DOMAIN)
#   -u user    SMB username (default: asks)
#   -c         install the HTTPS root certificate (needs -d / $TVBOX_DOMAIN)
#   -f         skip the desktop mount; write credentials file + print fstab recipe
set -euo pipefail

HOST="${TVBOX_HOST:-tvbox.local}"
DOMAIN="${TVBOX_DOMAIN:-}"
USER_NAME=""
INSTALL_CERT=0
FORCE_FSTAB=0

ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }

while getopts "H:d:u:cfh" opt; do
  case "$opt" in
    H) HOST="$OPTARG" ;;
    d) DOMAIN="$OPTARG" ;;
    u) USER_NAME="$OPTARG" ;;
    c) INSTALL_CERT=1 ;;
    f) FORCE_FSTAB=1 ;;
    *) sed -n '2,9p' "$0"; exit 2 ;;
  esac
done

read -r -p "Server name or IP [${HOST}]: " reply || true
HOST="${reply:-$HOST}"
if [ -z "$USER_NAME" ]; then
  read -r -p "Username: " USER_NAME
fi
[ -n "$USER_NAME" ] || { fail "Username is required."; exit 1; }

if command -v getent >/dev/null 2>&1 && ! getent hosts "$HOST" >/dev/null 2>&1; then
  warn "Cannot resolve '$HOST'. If this fails, re-run with the server's LAN IP (e.g. -H 192.168.1.50)."
fi

install_cert() {
  if [ -z "$DOMAIN" ]; then
    read -r -p "Server domain (e.g. home.example.org): " DOMAIN
  fi
  [ -n "$DOMAIN" ] || { fail "Domain is required to download the certificate."; return 1; }
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  # -k is needed only for this one download: we cannot trust the CA before we have it.
  if ! curl -fsSk -o "$tmp/root.crt" "https://setup.${DOMAIN}/root.crt"; then
    fail "Could not download https://setup.${DOMAIN}/root.crt (is DNS pointing at the server?)"
    return 1
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl x509 -in "$tmp/root.crt" -noout -subject -fingerprint -sha256 || {
      fail "Downloaded file is not a valid PEM certificate."; return 1; }
    warn "Compare this fingerprint with the one shown on the server before trusting it."
  fi

  if command -v update-ca-certificates >/dev/null 2>&1; then
    if sudo install -m 644 "$tmp/root.crt" /usr/local/share/ca-certificates/tvbox-root.crt \
       && sudo update-ca-certificates >/dev/null; then
      ok "Certificate installed system-wide."
    else
      warn "System-wide install failed (sudo needed)."
    fi
  else
    warn "update-ca-certificates not found. Fedora/Arch: sudo trust anchor $tmp/root.crt"
  fi

  if command -v certutil >/dev/null 2>&1; then
    local db n=0
    for db in "$HOME"/.mozilla/firefox/*.default* "$HOME"/snap/firefox/common/.mozilla/firefox/*.default* \
              "$HOME"/.pki/nssdb; do
      [ -d "$db" ] || continue
      if certutil -A -n "TVBox Root CA" -t "C,," -i "$tmp/root.crt" -d "sql:$db" 2>/dev/null; then
        n=$((n + 1))
      fi
    done
    if [ "$n" -gt 0 ]; then ok "Certificate added to $n browser profile(s). Restart the browser."; else warn "No Firefox/Chrome NSS profiles found."; fi
  else
    warn "certutil not found; Firefox keeps its own store (install libnss3-tools to automate, or import root.crt in Settings > Certificates)."
  fi
}

have_desktop() {
  { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; } && command -v gio >/dev/null 2>&1
}

mount_gvfs() {
  local pass share
  read -r -s -p "SMB password (hidden): " pass; echo
  for share in Uploads Cloud; do
    # gio reads user / workgroup / password from stdin; nothing goes into argv.
    if printf '%s\nWORKGROUP\n%s\n' "$USER_NAME" "$pass" | gio mount "smb://${HOST}/${share}" >/dev/null 2>&1; then
      ok "Mounted ${share} (open your file manager > Network, or smb://${HOST}/${share})"
    else
      fail "Could not mount ${share}. Try the server's IP with -H, or use -f for the fstab recipe."
    fi
  done
  pass=""
}

write_fstab_recipe() {
  local cred="$HOME/.config/tvbox-smb.cred" pass uid gid
  read -r -s -p "SMB password (hidden): " pass; echo
  mkdir -p "$HOME/.config"
  ( umask 077; printf 'username=%s\npassword=%s\n' "$USER_NAME" "$pass" > "$cred" )
  chmod 600 "$cred"
  pass=""
  ok "Credentials saved to $cred (mode 600)"
  uid="$(id -u)"; gid="$(id -g)"
  cat <<RECIPE

Run these once (needs sudo and the cifs-utils package):

  sudo apt install cifs-utils        # or: dnf/pacman equivalent
  sudo mkdir -p /mnt/tvbox/Uploads /mnt/tvbox/Cloud
  sudo tee -a /etc/fstab <<'FSTAB'
//${HOST}/Uploads /mnt/tvbox/Uploads cifs credentials=${cred},uid=${uid},gid=${gid},iocharset=utf8,vers=3.0,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=60 0 0
//${HOST}/Cloud   /mnt/tvbox/Cloud   cifs credentials=${cred},uid=${uid},gid=${gid},iocharset=utf8,vers=3.0,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=60 0 0
FSTAB
  sudo systemctl daemon-reload
  ls /mnt/tvbox/Cloud                # first access mounts it

RECIPE
}

if [ "$FORCE_FSTAB" -eq 0 ] && have_desktop; then
  mount_gvfs
else
  [ "$FORCE_FSTAB" -eq 1 ] || warn "No desktop session / gio found; preparing the fstab recipe instead."
  write_fstab_recipe
fi

if [ "$INSTALL_CERT" -eq 1 ]; then
  install_cert || true
fi

ok "Done. Uploads = drop files here to auto-sort. Cloud = your sorted library."
