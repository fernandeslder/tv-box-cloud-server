#!/usr/bin/env bash
# setup.sh — the one command. Re-runs itself with sudo when needed.
#   ./setup.sh [--yes] [--reconfigure] [--no-start]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || { echo "run as root (sudo not installed)"; exit 1; }
  exec sudo -E TVBOX_USER="${SUDO_USER:-$(id -un)}" "$here/setup.sh" "$@"
fi
exec "$here/scripts/install.sh" "$@"
