#!/usr/bin/env bash
# lib.sh — shared helpers. Source it; never run it.
# Everything is user- and path-agnostic: no fixed username, no fixed checkout location.
set -euo pipefail

TVBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$TVBOX_LIB_DIR/.." && pwd)}"
ENV_FILE="${ENV_FILE:-$REPO_DIR/docker/.env}"
TVBOX_ETC="${TVBOX_ETC:-/etc/tvbox}"
TVBOX_STATE="${TVBOX_STATE:-/var/lib/tvbox}"   # spend ledger, last-backup/last-verify stamps, smart-status
LOG="${TVBOX_LOG:-/var/log/tvbox-install.log}"

_c() { [ -t 2 ] && printf '\033[%sm' "$1" >&2 || true; }
log() {
  local line; line="$(printf '[%s] %s' "$(date -Is)" "$*")"
  printf '%s\n' "$line"
  { printf '%s\n' "$line" >> "$LOG"; } 2>/dev/null || true
}
ok()   { _c 32; printf '  ✓ %s\n' "$*" >&2; _c 0; }
warn() { _c 33; printf '  ! %s\n' "$*" >&2; _c 0; }
die()  { _c 31; printf '  ✗ %s\n' "$*" >&2; _c 0; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || [ -n "${TVBOX_TEST_NOROOT:-}" ] || die "run with sudo: sudo $0 $*"; }
apt_install() { DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; }
have() { command -v "$1" >/dev/null 2>&1; }

# The human who owns the box: whoever ran sudo, else the first normal user.
detect_user() {
  local u="${TVBOX_USER:-${SUDO_USER:-}}"
  if [ -z "$u" ] || [ "$u" = root ]; then
    u="$(getent passwd | awk -F: '$3>=1000 && $3<60000 && $7 !~ /nologin|false/ {print $1; exit}')"
  fi
  [ -n "$u" ] || die "cannot work out which user owns this box; run: sudo TVBOX_USER=<name> $0"
  printf '%s' "$u"
}
TVBOX_USER="${TVBOX_USER:-$(detect_user 2>/dev/null || true)}"
# shellcheck disable=SC2034
TVBOX_HOME="$(getent passwd "$TVBOX_USER" 2>/dev/null | cut -d: -f6 || true)"

# Read one KEY from the env file without eval/source (values stay data, never code).
env_get() {  # env_get KEY [default]
  local v
  v="$(grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  v="${v%%[[:space:]]#*}"          # inline comment
  v="${v%"${v##*[![:space:]]}"}"   # trailing blanks
  v="${v%\"}"; v="${v#\"}"
  printf '%s' "${v:-${2:-}}"
}
# Insert or update KEY=VALUE in the env file (keeps file mode).
env_set() {  # env_set KEY VALUE
  local k="$1" v="$2" tmp
  [ -f "$ENV_FILE" ] || install -m 600 /dev/null "$ENV_FILE"
  tmp="$(mktemp)"
  grep -vE "^$k=" "$ENV_FILE" > "$tmp" || true
  printf '%s=%s\n' "$k" "$v" >> "$tmp"
  cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
}
# No `tr | head` pipe: under pipefail tr dies of SIGPIPE (status 141) and set -e kills the caller.
rand() {  # rand [length]
  local n="${1:-24}" out=""
  while [ "${#out}" -lt "$n" ]; do out+="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"; done
  printf '%s' "${out:0:n}"
}

# Render a template: replaces @KEY@ with values from the environment.
render() {  # render <template> <dest> KEY...
  local src="$1" dst="$2"; shift 2
  local content k
  content="$(cat "$src")"
  for k in "$@"; do content="${content//@$k@/${!k:-}}"; done
  printf '%s\n' "$content" > "$dst"
}

# Default storage layout (override in docker/.env).
# shellcheck disable=SC2034
STORAGE_ROOT="$(env_get STORAGE_ROOT /mnt/pool)"
CACHE_ROOT="$(env_get CACHE_ROOT /mnt/cache)"
HDD_ROOT="${HDD_ROOT:-/mnt/hdd}"
LANDING_DIR="${LANDING_DIR:-$CACHE_ROOT/landing}"
DISKS_CONF="${DISKS_CONF:-$TVBOX_ETC/disks.conf}"

# Mountpoint of the first healthy (sentinel-verified) disk with the given role, or nothing.
disk_mp_for_role() {  # disk_mp_for_role data|backup
  local uuid role label cand
  [ -f "$DISKS_CONF" ] || return 0
  while IFS='|' read -r uuid role label; do
    [ "$role" = "$1" ] || continue
    cand="$HDD_ROOT/$label"
    if mountpoint -q "$cand" 2>/dev/null && [ "$(timeout 5 cat "$cand/.tvbox-disk" 2>/dev/null || true)" = "$uuid" ]; then
      printf '%s' "$cand"; return 0
    fi
  done < <(grep -vE '^\s*(#|$)' "$DISKS_CONF")
}
