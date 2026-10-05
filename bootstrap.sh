#!/usr/bin/env bash
# bootstrap.sh — fresh machine -> running server in one line:
#   curl -fsSL https://raw.githubusercontent.com/fernandeslder/tv-box-cloud-server/master/bootstrap.sh | sudo bash
# Installs git, clones the repo to /opt/tvbox (owned by you), then runs ./setup.sh.
# Unattended: TVBOX_NONINTERACTIVE=1 (+ optional /opt/tvbox-seed.env pre-answers).
set -euo pipefail
REPO="${TVBOX_REPO:-https://github.com/fernandeslder/tv-box-cloud-server.git}"
DIR="${TVBOX_DIR:-/opt/tvbox}"
OWNER="${SUDO_USER:-${TVBOX_USER:-}}"
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
[ -n "$OWNER" ] && [ "$OWNER" != root ] || OWNER="$(getent passwd | awk -F: '$3>=1000 && $3<60000 && $7 !~ /nologin|false/ {print $1; exit}')"
[ -n "$OWNER" ] || { echo "no normal user account found"; exit 1; }
command -v git >/dev/null 2>&1 || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y git curl ca-certificates; }
if [ -d "$DIR/.git" ]; then git -C "$DIR" pull --ff-only; else git clone "$REPO" "$DIR"; fi
chown -R "$OWNER" "$DIR"
cd "$DIR"
if [ -n "${TVBOX_NONINTERACTIVE:-}" ]; then exec env TVBOX_USER="$OWNER" ./setup.sh --yes; fi
# `curl | bash` has no terminal on stdin: re-attach it so the wizard can ask questions.
exec env TVBOX_USER="$OWNER" ./setup.sh </dev/tty
