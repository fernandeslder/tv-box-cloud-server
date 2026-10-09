load helpers
setup() { mk_tmp; export DISKS_CONF="$T/disks.conf" HDD_ROOT="$T/hdd" LANDING_DIR="$T/landing" STORAGE_ROOT="$T/pool" TVBOX_ETC="$T/etc" ENV_FILE="$T/env"; : > "$ENV_FILE"; mkdir -p "$T/hdd" "$T/landing"; }
teardown() { rm -rf "$T"; }
@test "status reports an unplugged disk as OFFLINE and says uploads keep working" {
  printf 'ABCD-1234|data|data1\nEFGH-5678|backup|backup1\n' > "$DISKS_CONF"
  run "$REPO/scripts/disks.sh" status; [ "$status" -eq 0 ]
  [[ "$output" == *"data1"*"OFFLINE"* ]]; [[ "$output" == *"backup1"*"OFFLINE"* ]]; [[ "$output" == *"keep landing on the SSD"* ]]
}
@test "status with no disks tells you what to do" {
  run "$REPO/scripts/disks.sh" status; [[ "$output" == *"none registered"* ]]
}
@test "scan never offers the system disk" {
  run "$REPO/scripts/disks.sh" scan; [[ "$output" == *"SYSTEM"* ]]; ! [[ "$output" == *"blank"*"$(findmnt -n -o SOURCE / | sed 's#/dev/##;s#p\?[0-9]*$##')"* ]]
}
@test "add refuses without a role / a real block device" {
  run "$REPO/scripts/disks.sh" add /dev/null; [ "$status" -ne 0 ]
}
@test "adopt re-registers tvbox-labelled ext4 disks and ignores everything else" {
  mkdir -p "$T/bin"; cat > "$T/bin/lsblk" <<'F'
#!/bin/sh
printf 'sda1 tvbox-data1 AAAA-1111 ext4\nsdb1 tvbox-backup1 BBBB-2222 ext4\nsdc1 Photos CCCC-3333 ext4\nsdd1 tvbox-x DDDD-4444 ntfs\n'
F
  chmod +x "$T/bin/lsblk"
  # run the adopt function without the root-only CLI dispatch
  cp -r "$REPO/scripts" "$T/s"; sed '/^case "${1:-status}" in/,$d' "$REPO/scripts/disks.sh" > "$T/s/disks-lib.sh"
  PATH="$T/bin:$PATH" run bash -c ". '$T/s/disks-lib.sh'; adopt"
  [ "$status" -eq 0 ]
  grep -q '^AAAA-1111|data|data1$' "$DISKS_CONF"
  grep -q '^BBBB-2222|backup|backup1$' "$DISKS_CONF"
  ! grep -q CCCC "$DISKS_CONF"; ! grep -q DDDD "$DISKS_CONF"
  PATH="$T/bin:$PATH" run bash -c ". '$T/s/disks-lib.sh'; adopt"; [ "$(grep -c AAAA "$DISKS_CONF")" -eq 1 ]
}
@test "a btrfs-subvolume root ('/dev/nvme0n1p2[/@]') is still recognised as the system disk" {
  mkdir -p "$T/bin"
  cat > "$T/bin/findmnt" <<'F'
#!/bin/sh
echo '/dev/nvme0n1p2[/@]'
F
  cat > "$T/bin/lsblk" <<'F'
#!/bin/sh
case "$*" in
  *-srno*) printf 'nvme0n1p2 part\nnvme0n1 disk\n' ;;
  *-dnpo*) printf '/dev/nvme0n1 953.9G nvme SAMSUNG disk\n' ;;
  *) : ;;
esac
F
  chmod +x "$T/bin/findmnt" "$T/bin/lsblk"
  PATH="$T/bin:$PATH" run "$REPO/scripts/disks.sh" scan
  [[ "$output" == *"SYSTEM disk"* ]]
}
@test "add refuses the system disk even with --force" {
  mkdir -p "$T/bin"
  cat > "$T/bin/findmnt" <<'F'
#!/bin/sh
echo '/dev/loop0'
F
  cat > "$T/bin/lsblk" <<'F'
#!/bin/sh
printf 'loop0 loop\nloop0 disk\n'
F
  chmod +x "$T/bin/findmnt" "$T/bin/lsblk"
  # /dev/loop0 is a real block node on most systems; if absent the test degrades to the 'not a block device' refusal.
  PATH="$T/bin:$PATH" TVBOX_DRY_RUN=1 run "$REPO/scripts/disks.sh" add /dev/loop0 data --force --yes
  [ "$status" -ne 0 ]
}
