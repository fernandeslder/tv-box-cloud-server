load helpers
setup() {
  mk_tmp
  export ENV_FILE="$T/env" POWER_SUPPLY_DIR="$T/ps"; : > "$ENV_FILE"
  mkdir -p "$T/ps/BAT0" "$T/ps/AC"
  echo 100 > "$T/ps/BAT0/charge_control_end_threshold"; echo 96 > "$T/ps/BAT0/charge_control_start_threshold"
}
teardown() { rm -rf "$T"; }

@test "caps the charge at 80% (start 75%) by default" {
  run "$REPO/scripts/battery-care.sh"; [ "$status" -eq 0 ]
  [ "$(cat "$T/ps/BAT0/charge_control_end_threshold")" = 80 ]
  [ "$(cat "$T/ps/BAT0/charge_control_start_threshold")" = 75 ]
}
@test "BATTERY_MAX_CHARGE=100 restores full charging" {
  BATTERY_MAX_CHARGE=60 "$REPO/scripts/battery-care.sh" >/dev/null
  BATTERY_MAX_CHARGE=100 run "$REPO/scripts/battery-care.sh"; [ "$status" -eq 0 ]
  [ "$(cat "$T/ps/BAT0/charge_control_end_threshold")" = 100 ]
}
@test "rejects silly limits and does nothing without a controllable battery" {
  BATTERY_MAX_CHARGE=10 run "$REPO/scripts/battery-care.sh"; [ "$status" -eq 2 ]
  rm -rf "$T/ps/BAT0"
  run "$REPO/scripts/battery-care.sh"; [ "$status" -eq 0 ]; [[ "$output" == *"nothing to do"* ]]
}
