load helpers
setup() {
  mk_tmp
  export TVBOX_TEST_NOROOT=1 ENV_FILE="$T/env" TVBOX_STATE="$T/state" HDD_ROOT="$T/hdd" DISKS_CONF="$T/disks.conf"
  export SMART_STATUS_FILE="$T/state/smart-status" TVBOX_ALERT_LOG="$T/alerts.log"
  mkdir -p "$T/bin" "$T/hdd/data1" "$T/state"; : > "$ENV_FILE"
  printf 'AAAA|data|data1\n' > "$DISKS_CONF"
  # mock mountpoint/findmnt/lsblk so data1 looks mounted from /dev/sdz1 on disk sdz
  cat > "$T/bin/mountpoint" <<'F'
#!/bin/sh
[ "$2" = "$HDD_ROOT/data1" ] || [ "$1" = "-q" -a "$2" = "$HDD_ROOT/data1" ] && exit 0
exit 1
F
  cat > "$T/bin/findmnt" <<'F'
#!/bin/sh
echo /dev/sdz1
F
  cat > "$T/bin/lsblk" <<'F'
#!/bin/sh
printf 'sdz1 part\nsdz disk\n'
F
  chmod +x "$T/bin"/*
  export PATH="$T/bin:$PATH" CACHE_ROOT="$T/none"
}
teardown() { rm -rf "$T"; }

mock_smartctl() {  # mock_smartctl <body>
  printf '#!/bin/sh\ncat <<"EOF"\n%s\nEOF\n' "$1" > "$T/bin/smartctl"; chmod +x "$T/bin/smartctl"
}

@test "a healthy disk is recorded as PASSED with its temperature" {
  mock_smartctl 'SMART overall-health self-assessment test result: PASSED
194 Temperature_Celsius     0x0022   110   100   000    Old_age   Always       -       34'
  run "$REPO/scripts/smart-check.sh"; [ "$status" -eq 0 ]
  grep -q '^data1|/dev/sdz|PASSED|34|' "$SMART_STATUS_FILE"
}
@test "a failing disk exits 1 and raises an alert" {
  mock_smartctl 'SMART overall-health self-assessment test result: FAILED!'
  run "$REPO/scripts/smart-check.sh"; [ "$status" -eq 1 ]
  grep -q '|FAILED|' "$SMART_STATUS_FILE"; grep -q 'FAILING' "$TVBOX_ALERT_LOG"
}
@test "pending sectors warn but do not fail" {
  mock_smartctl 'SMART overall-health self-assessment test result: PASSED
197 Current_Pending_Sector  0x0032   100   100   000    Old_age   Always       -       8'
  run "$REPO/scripts/smart-check.sh"; [ "$status" -eq 0 ]
  grep -q '8 pending sectors' "$SMART_STATUS_FILE"; grep -q 'pending sectors' "$TVBOX_ALERT_LOG"
}
@test "a USB bridge without SMART is UNKNOWN, never FAILED" {
  mock_smartctl 'SMART support is: Unavailable - device lacks SMART capability.'
  run "$REPO/scripts/smart-check.sh"; [ "$status" -eq 0 ]
  grep -q '|UNKNOWN|' "$SMART_STATUS_FILE"
}
