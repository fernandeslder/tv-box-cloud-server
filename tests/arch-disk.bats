load helpers
setup() { mk_tmp; mkdir -p "$T/bin" "$T/mnt"; }
teardown() { rm -rf "$T"; }

# The safety checks must never look at the real test machine: fake the two
# probes they use (lsblk disk attributes, and the running root's source).
fake_probes() {
  cat > "$T/bin/lsblk" <<'F'
#!/bin/sh
case "$*" in
  *TYPE,RM,TRAN*) printf '%s %s %s\n' "${FAKE_KIND:-disk}" "${FAKE_RM:-0}" "${FAKE_TRAN:-sata}" ;;
  *NAME,TYPE*) printf '%s\n' "${FAKE_ROOT_CHAIN:-loop0 loop}" ;;
  *) : ;;
esac
F
  cat > "$T/bin/findmnt" <<'F'
#!/bin/sh
printf '%s\n' "${FAKE_ROOT_SRC:-/dev/loop0}"
F
  chmod +x "$T/bin/lsblk" "$T/bin/findmnt"
}
prepare() {  # prepare <dev> — dry-run with the wipe confirmed for <dev>
  PATH="$T/bin:$PATH" TVBOX_DRY_RUN=1 TVBOX_CONFIRM_WIPE="$1" \
    run bash -c ". '$REPO/autoinstall/arch/disk.sh'; arch_disk_prepare '$1' '$T/mnt'"
}

@test "arch_disk_prepare /dev/nvme0n1: GPT, 1 GiB EFI, btrfs subvolumes, zstd mounts" {
  fake_probes
  FAKE_TRAN=nvme prepare /dev/nvme0n1
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY: wipefs -a /dev/nvme0n1"* ]]
  [[ "$output" == *"DRY: sgdisk --zap-all /dev/nvme0n1"* ]]
  [[ "$output" == *"DRY: sgdisk --new=1:0:+1G --typecode=1:EF00 --change-name=1:EFI /dev/nvme0n1"* ]]
  [[ "$output" == *"DRY: sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:tvbox /dev/nvme0n1"* ]]
  [[ "$output" == *"DRY: mkfs.fat -F 32 -n EFI /dev/nvme0n1p1"* ]]
  [[ "$output" == *"DRY: mkfs.btrfs -L tvbox /dev/nvme0n1p2"* ]]
  [[ "$output" == *"DRY: mount -o noatime,compress=zstd:1,space_cache=v2 /dev/nvme0n1p2 $T/mnt"* ]]
  [[ "$output" == *"DRY: btrfs subvolume create $T/mnt/@"* ]]
  [[ "$output" == *"DRY: btrfs subvolume create $T/mnt/@home"* ]]
  [[ "$output" == *"DRY: btrfs subvolume create $T/mnt/@var-log"* ]]
  [[ "$output" == *"DRY: btrfs subvolume create $T/mnt/@snapshots"* ]]
  [[ "$output" == *"DRY: umount $T/mnt"* ]]
  [[ "$output" == *"DRY: mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@ /dev/nvme0n1p2 $T/mnt"* ]]
  [[ "$output" == *"DRY: mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@home /dev/nvme0n1p2 $T/mnt/home"* ]]
  [[ "$output" == *"DRY: mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@var-log /dev/nvme0n1p2 $T/mnt/var/log"* ]]
  [[ "$output" == *"DRY: mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@snapshots /dev/nvme0n1p2 $T/mnt/snapshots"* ]]
  [[ "$output" == *"DRY: mount /dev/nvme0n1p1 $T/mnt/boot"* ]]
}

@test "arch_disk_prepare /dev/sda: partitions without the nvme 'p'" {
  fake_probes
  FAKE_TRAN=sata prepare /dev/sda
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY: mkfs.fat -F 32 -n EFI /dev/sda1"* ]]
  [[ "$output" == *"DRY: mkfs.btrfs -L tvbox /dev/sda2"* ]]
  [[ "$output" == *"DRY: mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@ /dev/sda2 $T/mnt"* ]]
  [[ "$output" == *"DRY: mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@home /dev/sda2 $T/mnt/home"* ]]
  [[ "$output" == *"DRY: mount /dev/sda1 $T/mnt/boot"* ]]
  [[ "$output" != *"/dev/sdap"* ]]
  [[ "$output" != *"sda1p"* ]]
}

@test "TVBOX_CONFIRM_WIPE accepts the device with or without the /dev/ prefix" {
  fake_probes
  FAKE_TRAN=nvme PATH="$T/bin:$PATH" TVBOX_DRY_RUN=1 TVBOX_CONFIRM_WIPE=nvme0n1 \
    run bash -c ". '$REPO/autoinstall/arch/disk.sh'; arch_disk_prepare /dev/nvme0n1 '$T/mnt'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY: mkfs.btrfs -L tvbox /dev/nvme0n1p2"* ]]
}

@test "arch_disk_prepare refuses without TVBOX_CONFIRM_WIPE" {
  fake_probes
  PATH="$T/bin:$PATH" TVBOX_DRY_RUN=1 \
    run bash -c ". '$REPO/autoinstall/arch/disk.sh'; arch_disk_prepare /dev/nvme0n1 '$T/mnt'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"TVBOX_CONFIRM_WIPE"* ]]
  [[ "$output" != *"DRY:"* ]]
}

@test "arch_disk_prepare refuses when TVBOX_CONFIRM_WIPE names a different device" {
  fake_probes
  PATH="$T/bin:$PATH" TVBOX_DRY_RUN=1 TVBOX_CONFIRM_WIPE=/dev/sdb \
    run bash -c ". '$REPO/autoinstall/arch/disk.sh'; arch_disk_prepare /dev/nvme0n1 '$T/mnt'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"different device"* ]]
  [[ "$output" != *"DRY:"* ]]
}

@test "arch_disk_prepare refuses a USB disk (TRAN=usb)" {
  fake_probes
  FAKE_TRAN=usb prepare /dev/sdb
  [ "$status" -ne 0 ]
  [[ "$output" == *"USB disk"* ]]
  [[ "$output" != *"DRY:"* ]]
}

@test "arch_disk_prepare refuses a removable disk (RM=1)" {
  fake_probes
  FAKE_RM=1 prepare /dev/sdb
  [ "$status" -ne 0 ]
  [[ "$output" == *"removable"* ]]
  [[ "$output" != *"DRY:"* ]]
}

@test "arch_disk_prepare refuses the disk holding the running live system" {
  fake_probes
  FAKE_ROOT_SRC='/dev/sda2[/@]' FAKE_ROOT_CHAIN=$'sda2 part\nsda disk' prepare /dev/sda
  [ "$status" -ne 0 ]
  [[ "$output" == *"running live system"* ]]
  [[ "$output" != *"DRY:"* ]]
}

@test "a disk held by an active LVM volume group / mounted partition is released before wiping" {
  mk_tmp; mkdir -p "$T/bin"
  cat > "$T/bin/lsblk" <<'F'
#!/bin/sh
case "$*" in
  *TYPE,RM,TRAN*) echo "disk 0 nvme" ;;
  *-lnpo*NAME*)   printf '/dev/nvme0n1\n/dev/nvme0n1p1\n/dev/nvme0n1p3\n' ;;
  *-srno*)        echo "sdz disk" ;;
  *) exit 0 ;;
esac
F
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/findmnt"
  printf '#!/bin/sh\n[ "$4" = /dev/nvme0n1p3 ] && echo "  ubuntu-vg"\nexit 0\n' > "$T/bin/pvs"
  chmod +x "$T/bin/lsblk" "$T/bin/findmnt" "$T/bin/pvs"
  PATH="$T/bin:$PATH" TVBOX_DRY_RUN=1 TVBOX_CONFIRM_WIPE=/dev/nvme0n1 \
    run bash -c ". '$REPO/autoinstall/arch/disk.sh'; arch_disk_prepare /dev/nvme0n1 /mnt"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  a="$(echo "$output" | grep -n 'DRY: vgchange -an ubuntu-vg' | head -1 | cut -d: -f1)"
  b="$(echo "$output" | grep -n 'DRY: wipefs -a' | head -1 | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
  [[ "$output" == *"DRY: umount -R /dev/nvme0n1p1"* ]]
}
