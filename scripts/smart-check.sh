#!/usr/bin/env bash
# smart-check.sh — SMART health of every registered USB disk and the SSD cache.
#   Writes one line per disk to $SMART_STATUS_FILE (label|device|PASSED|FAILED|UNKNOWN|temp-or-?|note)
#   and raises a notification on FAILED or growing bad sectors. Run daily by tvbox-smart.timer.
# USB-SATA bridges often need `-d sat`: tried automatically when plain auto-detect says "Unknown USB bridge".
# Test hooks: SMARTCTL, SMART_STATUS_FILE, DISKS_CONF, HDD_ROOT.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SMARTCTL="${SMARTCTL:-smartctl}"
OUT="${SMART_STATUS_FILE:-$TVBOX_STATE/smart-status}"
NOTIFY="$(dirname "${BASH_SOURCE[0]}")/notify.sh"
if [ "${PKG_FAMILY:-debian}" = arch ]; then
  have "$SMARTCTL" || { echo "smart-check: smartctl missing (pacman -S --needed smartmontools)" >&2; exit 0; }
else
  have "$SMARTCTL" || { echo "smart-check: smartctl missing (apt install smartmontools)" >&2; exit 0; }
fi

parent_disk() {  # parent_disk <mountpoint> -> /dev/<disk> of the filesystem mounted there
  local src d
  src="$(findmnt -n -o SOURCE -T "$1" 2>/dev/null || true)"; src="${src%%\[*}"
  [ -n "$src" ] || return 0
  d="$(lsblk -srno NAME,TYPE "$src" 2>/dev/null | awk '$2=="disk"{print $1; exit}')"
  [ -n "$d" ] && printf '/dev/%s' "$d"
}

check_one() {  # check_one <label> <device>  -> prints the status line
  local label="$1" dev="$2" out health="UNKNOWN" temp="?" note="" args=("-d" "auto") pend=0 realloc=0
  out="$("$SMARTCTL" -H -A "$dev" 2>&1 || true)"
  if grep -qiE 'unknown usb bridge|please specify device type' <<<"$out"; then
    out="$("$SMARTCTL" -H -A -d sat "$dev" 2>&1 || true)"; args=("-d" "sat")
  fi
  if grep -qiE 'PASSED|overall-health.*: OK|SMART Health Status: OK' <<<"$out"; then health=PASSED
  elif grep -qiE 'FAILED' <<<"$out"; then health=FAILED
  elif grep -qiE 'Unavailable|not supported|Unsupported' <<<"$out"; then note="no SMART on this bridge"; fi
  temp="$(awk '/Temperature_Celsius|Airflow_Temperature|^Temperature:/ {for(i=NF;i>0;i--) if($i ~ /^[0-9]+$/){print $i; exit}}' <<<"$out" | head -n1)"
  pend="$(awk '/Current_Pending_Sector/ {print $NF; exit}' <<<"$out")"; realloc="$(awk '/Reallocated_Sector_Ct/ {print $NF; exit}' <<<"$out")"
  if [ "${pend:-0}" -gt 0 ] 2>/dev/null; then note="$pend pending sectors"; fi
  if [ "${realloc:-0}" -gt 0 ] 2>/dev/null; then note="${note:+$note, }$realloc reallocated sectors"; fi
  printf '%s|%s|%s|%s|%s|%s\n' "$label" "$dev" "$health" "${temp:-?}" "${args[*]}" "$note"
}

mkdir -p "$(dirname "$OUT")"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
rc=0

check_dev() {  # check_dev <label> <mountpoint-or-empty> [device]
  local label="$1" mp="$2" dev="${3:-}" line health note
  [ -n "$dev" ] || dev="$(parent_disk "$mp")"
  [ -n "$dev" ] || { printf '%s|?|UNKNOWN|?|?|device not found\n' "$label" >> "$tmp"; return 0; }
  line="$(check_one "$label" "$dev")"; printf '%s\n' "$line" >> "$tmp"
  health="$(cut -d'|' -f3 <<<"$line")"; note="$(cut -d'|' -f6 <<<"$line")"
  case "$health" in
    FAILED) "$NOTIFY" error "SMART says disk '$label' ($dev) is FAILING: back it up and replace it" || true; rc=1 ;;
    *) [ -z "$note" ] || "$NOTIFY" warn "disk '$label' ($dev): $note" || true ;;
  esac
}

if [ -f "$DISKS_CONF" ]; then
  while IFS='|' read -r _ _ label; do
    mp="$HDD_ROOT/$label"
    mountpoint -q "$mp" 2>/dev/null || continue
    check_dev "$label" "$mp"
  done < <(grep -vE '^\s*(#|$)' "$DISKS_CONF")
fi
cache_dev="$(parent_disk "$CACHE_ROOT")"
[ -z "$cache_dev" ] || check_dev ssd-cache "$CACHE_ROOT" "$cache_dev"

cat "$tmp" > "$OUT"
cat "$OUT"
exit "$rc"
