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
