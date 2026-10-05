#!/usr/bin/env bash
# Double-click me on a Mac to connect to the home server.
# Usage: ./connect-mac.command [-H host] [-d domain] [-u user] [-c] [-l]
#   -H host    server name or LAN IP (default: $TVBOX_HOST or tvbox.local)
#   -d domain  your server domain (default: $TVBOX_DOMAIN)
#   -u user    SMB username (default: asks)
#   -c         install the HTTPS root certificate into your login keychain
#   -l         also reconnect the shares automatically at login
set -euo pipefail

HOST="${TVBOX_HOST:-tvbox.local}"
DOMAIN="${TVBOX_DOMAIN:-}"
USER_NAME=""
INSTALL_CERT=0
LOGIN_ITEMS=0

ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }

while getopts "H:d:u:clh" opt; do
  case "$opt" in
    H) HOST="$OPTARG" ;;
    d) DOMAIN="$OPTARG" ;;
    u) USER_NAME="$OPTARG" ;;
    c) INSTALL_CERT=1 ;;
    l) LOGIN_ITEMS=1 ;;
    *) sed -n '2,8p' "$0"; exit 2 ;;
  esac
done

read -r -p "Server name or IP [${HOST}]: " reply || true
HOST="${reply:-$HOST}"
if [ -z "$USER_NAME" ]; then
  read -r -p "Username: " USER_NAME
fi
[ -n "$USER_NAME" ] || { fail "Username is required."; exit 1; }

if [ -z "$DOMAIN" ]; then
  read -r -p "Server domain for HTTPS certificate (blank to skip): " DOMAIN || true
  [ -z "$DOMAIN" ] || INSTALL_CERT=1
fi

# Finder asks for the password itself (tick "Remember this password in my keychain"),
# so it never appears in a command line or shell history.
for share in Uploads Cloud; do
  if open "smb://${USER_NAME}@${HOST}/${share}"; then
    ok "Opening ${share} in Finder... enter your SMB password and tick 'Remember in keychain'."
  else
    fail "Could not open smb://${HOST}/${share}. Try the server's LAN IP instead."
  fi
  sleep 2
done

if [ "$LOGIN_ITEMS" -eq 1 ]; then
  for share in Uploads Cloud; do
    osascript - "smb://${USER_NAME}@${HOST}/${share}" "TVBox ${share}" <<'OSA' >/dev/null || warn "Could not add login item for ${share}."
on run argv
  tell application "System Events"
    make login item at end with properties {path:(item 1 of argv), name:(item 2 of argv), hidden:false}
  end tell
end run
OSA
  done
  ok "Shares will reconnect at login."
fi

if [ "$INSTALL_CERT" -eq 1 ] && [ -n "$DOMAIN" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  # -k only for this bootstrap download; we cannot trust the CA before we have it.
  if curl -fsSk -o "$tmp/root.crt" "https://setup.${DOMAIN}/root.crt"; then
    openssl x509 -in "$tmp/root.crt" -noout -subject -fingerprint -sha256 || true
    warn "macOS will ask for your login password to trust this certificate."
    if security add-trusted-cert -d -r trustRoot -k "$HOME/Library/Keychains/login.keychain-db" "$tmp/root.crt"; then
      ok "Root certificate trusted. Restart your browser."
    else
      fail "Certificate install failed or was cancelled."
    fi
  else
    fail "Could not download https://setup.${DOMAIN}/root.crt (is DNS pointing at the server?)"
  fi
fi

ok "Done. Uploads = drop files to auto-sort. Cloud = your sorted library."
