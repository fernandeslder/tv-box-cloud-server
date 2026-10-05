load helpers
setup() {
  mk_tmp
  export LANDING_DIR="$T/landing" HDD_ROOT="$T/hdd" DISKS_CONF="$T/disks.conf" MOVER_LOCK="$T/lock" TVBOX_ETC="$T/etc" ENV_FILE="$T/env"
  mkdir -p "$LANDING_DIR" "$HDD_ROOT/data1"; : > "$ENV_FILE"
  export MOVER_TARGET="$HDD_ROOT/data1"
  export MOVER_MIN_AGE_MIN=5 MOVER_KEEP_DAYS=3 MOVER_HIGH_PCT=101 MOVER_LOW_PCT=0
}
teardown() { rm -rf "$T"; }

@test "keeps fresh files and files inside the keep window" {
  mkdir -p "$LANDING_DIR/Photos"; echo a > "$LANDING_DIR/Photos/new.jpg"
  echo b > "$LANDING_DIR/Photos/recent.jpg"; old "$LANDING_DIR/Photos/recent.jpg" "1 day ago"
  run "$REPO/scripts/mover.sh"; [ "$status" -eq 0 ]
  [ -f "$LANDING_DIR/Photos/new.jpg" ]; [ -f "$LANDING_DIR/Photos/recent.jpg" ]
}
@test "moves files older than the keep window, verifies, removes the SSD copy" {
  mkdir -p "$LANDING_DIR/Documents/sub"; echo hello > "$LANDING_DIR/Documents/sub/old.txt"; old "$LANDING_DIR/Documents/sub/old.txt" "5 days ago"
  run "$REPO/scripts/mover.sh"; [ "$status" -eq 0 ]
  [ ! -e "$LANDING_DIR/Documents/sub/old.txt" ]
  [ "$(cat "$HDD_ROOT/data1/Documents/sub/old.txt")" = hello ]
  [ ! -e "$HDD_ROOT/data1/Documents/sub/old.txt.tvbox-part" ]
}
@test "empty directories are left in place (inbox must survive)" {
  mkdir -p "$LANDING_DIR/inbox"; echo x > "$LANDING_DIR/inbox/f"; old "$LANDING_DIR/inbox/f" "5 days ago"
  run "$REPO/scripts/mover.sh"; [ -d "$LANDING_DIR/inbox" ]
}
@test "high-water mark drains even recent (but settled) files" {
  echo x > "$LANDING_DIR/f1"; old "$LANDING_DIR/f1" "10 minutes ago"
  echo y > "$LANDING_DIR/fresh"
  MOVER_HIGH_PCT=0 run "$REPO/scripts/mover.sh"; [ "$status" -eq 0 ]
  [ -f "$HDD_ROOT/data1/f1" ]; [ ! -e "$LANDING_DIR/f1" ]; [ -f "$LANDING_DIR/fresh" ]
}
@test "no healthy data disk: nothing moves, exit 0 (files stay on SSD)" {
  unset MOVER_TARGET
  echo x > "$LANDING_DIR/f"; old "$LANDING_DIR/f" "5 days ago"
  run "$REPO/scripts/mover.sh"; [ "$status" -eq 0 ]; [[ "$output" == *"no healthy data disk"* ]]
  [ -f "$LANDING_DIR/f" ]
}
@test "disk with the wrong sentinel is never used" {
  unset MOVER_TARGET
  mkdir -p "$HDD_ROOT/data1"; echo "WRONG" > "$HDD_ROOT/data1/.tvbox-disk"
  printf 'GOOD-UUID|data|data1\n' > "$DISKS_CONF"
  echo x > "$LANDING_DIR/f"; old "$LANDING_DIR/f" "5 days ago"
  run "$REPO/scripts/mover.sh"; [ -f "$LANDING_DIR/f" ]
}
@test "preserves file contents byte for byte" {
  head -c 200000 /dev/urandom > "$LANDING_DIR/blob.bin"; sum="$(sha256sum < "$LANDING_DIR/blob.bin")"; old "$LANDING_DIR/blob.bin" "5 days ago"
  run "$REPO/scripts/mover.sh"; [ "$(sha256sum < "$HDD_ROOT/data1/blob.bin")" = "$sum" ]
}
