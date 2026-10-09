#!/usr/bin/env bash
# battery-care.sh — laptop chassis on mains 24/7: cap the charge so the battery does not swell.
#   Sets charge_control_end_threshold (and start) on every battery that exposes it (ThinkPads do).
#   BATTERY_MAX_CHARGE in docker/.env: 60-100 (default 80); 100 or 0 = leave charging alone.
# No battery / no kernel support = silently nothing to do. Test hook: POWER_SUPPLY_DIR.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
max="${BATTERY_MAX_CHARGE:-$(env_get BATTERY_MAX_CHARGE 80)}"
[[ "$max" =~ ^[0-9]+$ ]] || { echo "battery-care: BATTERY_MAX_CHARGE must be a number" >&2; exit 2; }
if [ "$max" -eq 0 ] || [ "$max" -ge 100 ]; then max=100; fi
[ "$max" -ge 40 ] || { echo "battery-care: refusing a limit below 40%" >&2; exit 2; }
start=$((max - 5))
n=0
for b in "${POWER_SUPPLY_DIR:-/sys/class/power_supply}"/BAT*; do
  [ -e "$b" ] || continue
  end_f="$b/charge_control_end_threshold"; start_f="$b/charge_control_start_threshold"
  [ -w "$end_f" ] || continue
  # start must stay below end: lower start first when shrinking, raise end first when growing.
  if [ "$max" -eq 100 ]; then
    echo 100 > "$end_f" 2>/dev/null || true
    [ -w "$start_f" ] && echo 96 > "$start_f" 2>/dev/null || true
  else
    [ -w "$start_f" ] && echo "$start" > "$start_f" 2>/dev/null || true
    echo "$max" > "$end_f" 2>/dev/null || { warn "$(basename "$b"): could not set the charge limit"; continue; }
  fi
  ok "$(basename "$b"): charge limit $max%"; n=$((n + 1))
done
[ "$n" -gt 0 ] || echo "battery-care: no controllable battery (nothing to do)"
exit 0
