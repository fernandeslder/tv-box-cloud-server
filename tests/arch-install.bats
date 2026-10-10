load helpers

setup() {
  mk_tmp
  mkdir -p "$T/lib" "$T/bin" "$T/in"
  # Tiny stand-ins for the real autoinstall/arch/* libs (other workers).
  # The entrypoint finds them through TVBOX_ARCH_LIB_DIR.
  cat > "$T/lib/disk.sh" <<'F'
arch_disk_prepare() { echo "STUB arch_disk_prepare $* TVBOX_CONFIRM_WIPE=${TVBOX_CONFIRM_WIPE:-unset}"; }
F
  cat > "$T/lib/packages.sh" <<'F'
arch_enable_cachyos_repos() { echo "STUB arch_enable_cachyos_repos"; }
arch_base_packages() { printf '%s\n' base base-devel linux linux-firmware; }
F
  printf '#!/bin/sh\necho "STUB chroot.sh ran"\n' > "$T/lib/chroot.sh"
  chmod +x "$T/lib/chroot.sh"
  cat > "$T/in/hash" <<'F'
$6$rounds=50000$salt$SECRETHASHBODY
F
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEKEY tvbox\n' > "$T/in/key.pub"
  printf 'fake git bundle\n' > "$T/in/tvbox.bundle"
  printf 'TVBOX_DESKTOP=yes\n' > "$T/in/seed.env"
}

teardown() { rm -rf "$T"; }

# The target disk is a plain internal NVMe; the live system runs from /dev/sda.
fake_lsblk() {
  mkdir -p "$T/bin"
  cat > "$T/bin/lsblk" <<'F'
#!/bin/sh
case "$*" in
  *RM,TRAN*) case "$*" in *sdb*) echo "1 usb";; *) echo "0 nvme";; esac ;;
  *NAME,TYPE*) echo "/dev/sda disk" ;;
  *) : ;;
esac
F
  cat > "$T/bin/findmnt" <<'F'
#!/bin/sh
echo /dev/sda2
F
  chmod +x "$T/bin/lsblk" "$T/bin/findmnt"
}

# Dry-run the entrypoint with the arguments every run needs.
do_install() {
  TVBOX_ARCH_LIB_DIR="$T/lib" TVBOX_DRY_RUN=1 PATH="$T/bin:$PATH" \
    run "$REPO/autoinstall/arch-install.sh" \
      --disk /dev/nvme0n1 --confirm-wipe /dev/nvme0n1 \
      --password-hash-file "$T/in/hash" --ssh-key-file "$T/in/key.pub" "$@"
}

@test "dry-run prints the ordered install sequence" {
  fake_lsblk
  do_install --user tvbox --hostname tvbox --timezone America/Moncton --keyboard us \
    --domain lder.fyi --wifi-ssid homewifi \
    --bundle "$T/in/tvbox.bundle" --env-file "$T/in/seed.env"
  [ "$status" -eq 0 ]
  pos() { printf '%s\n' "$output" | grep -n -m1 -- "$1" | cut -d: -f1; }
  [ "$(pos 'STUB arch_enable_cachyos_repos')" -lt "$(pos 'STUB arch_disk_prepare')" ]
  [ "$(pos 'STUB arch_disk_prepare')" -lt "$(pos 'pacstrap')" ]
  [ "$(pos 'pacstrap')" -lt "$(pos 'genfstab')" ]
  [ "$(pos 'genfstab')" -lt "$(pos 'tvbox.bundle')" ]
  [ "$(pos 'tvbox.bundle')" -lt "$(pos 'tvbox-seed.env')" ]
  [ "$(pos 'tvbox-seed.env')" -lt "$(pos 'install -m 0755')" ]
  [ "$(pos 'install -m 0755')" -lt "$(pos 'arch-chroot')" ]
  [ "$(pos 'arch-chroot')" -lt "$(pos 'umount')" ]
  [[ "$output" == *"STUB arch_disk_prepare /dev/nvme0n1 /mnt TVBOX_CONFIRM_WIPE=/dev/nvme0n1"* ]]
  [[ "$output" == *"DRY: pacstrap -K /mnt base base-devel linux linux-firmware"* ]]
  [[ "$output" == *"DRY: bash -c genfstab -U /mnt > /mnt/etc/fstab"* ]]
  [[ "$output" == *"DRY: install -m 0644 $T/in/tvbox.bundle /mnt/opt/tvbox.bundle"* ]]
  [[ "$output" == *"DRY: install -m 0600 $T/in/seed.env /mnt/opt/tvbox-seed.env"* ]]
  [[ "$output" == *"DRY: install -m 0755 $T/lib/chroot.sh /mnt/root/chroot.sh"* ]]
  [[ "$output" == *"DRY: arch-chroot /mnt /root/chroot.sh"* ]]
  [[ "$output" == *"DRY: umount -R /mnt"* ]]
  [[ "$output" == *"remove the live USB and reboot"* ]]
}

@test "the minimal flow needs no bundle, env file, Wi-Fi or domain" {
  fake_lsblk
  do_install
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY: pacstrap"* ]]
  [[ "$output" == *"DRY: arch-chroot /mnt /root/chroot.sh"* ]]
  [[ "$output" == *"DRY: umount -R /mnt"* ]]
  [[ "$output" != *tvbox.bundle* ]]
  [[ "$output" != *tvbox-seed.env* ]]
}

@test "the password hash and the Wi-Fi password never appear in the output" {
  fake_lsblk
  TVBOX_WIFI_PASS='wifipass-NEVER-PRINT' do_install --wifi-ssid homewifi
  [ "$status" -eq 0 ]
  [[ "$output" != *SECRETHASHBODY* ]]
  [[ "$output" != *wifipass-NEVER-PRINT* ]]
  [[ "$output" != *"\$6\$"* ]]
}

@test "a missing --disk is an error" {
  TVBOX_ARCH_LIB_DIR="$T/lib" TVBOX_DRY_RUN=1 \
    run "$REPO/autoinstall/arch-install.sh" --confirm-wipe /dev/nvme0n1
  [ "$status" -ne 0 ]
  [[ "$output" == *"--disk is required"* ]]
}

@test "a missing --confirm-wipe is refused" {
  TVBOX_ARCH_LIB_DIR="$T/lib" TVBOX_DRY_RUN=1 \
    run "$REPO/autoinstall/arch-install.sh" --disk /dev/nvme0n1 \
      --password-hash-file "$T/in/hash" --ssh-key-file "$T/in/key.pub"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--confirm-wipe"* ]]
}

@test "a --confirm-wipe that does not match --disk is refused" {
  TVBOX_ARCH_LIB_DIR="$T/lib" TVBOX_DRY_RUN=1 \
    run "$REPO/autoinstall/arch-install.sh" --disk /dev/nvme0n1 --confirm-wipe /dev/sda \
      --password-hash-file "$T/in/hash" --ssh-key-file "$T/in/key.pub"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not --disk"* ]]
}

@test 'a hash that is not a $6$ sha-512 crypt hash is refused' {
  printf 'plaintext-password\n' > "$T/in/badhash"
  TVBOX_ARCH_LIB_DIR="$T/lib" TVBOX_DRY_RUN=1 \
    run "$REPO/autoinstall/arch-install.sh" --disk /dev/nvme0n1 --confirm-wipe /dev/nvme0n1 \
      --password-hash-file "$T/in/badhash" --ssh-key-file "$T/in/key.pub"
  [ "$status" -ne 0 ]
  [[ "$output" == *"\$6\$"* ]]
}

@test "unreadable input files are refused" {
  TVBOX_ARCH_LIB_DIR="$T/lib" TVBOX_DRY_RUN=1 \
    run "$REPO/autoinstall/arch-install.sh" --disk /dev/nvme0n1 --confirm-wipe /dev/nvme0n1 \
      --password-hash-file "$T/in/nope" --ssh-key-file "$T/in/key.pub"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot read the password hash file"* ]]
  TVBOX_ARCH_LIB_DIR="$T/lib" TVBOX_DRY_RUN=1 \
    run "$REPO/autoinstall/arch-install.sh" --disk /dev/nvme0n1 --confirm-wipe /dev/nvme0n1 \
      --password-hash-file "$T/in/hash" --ssh-key-file "$T/in/nope.pub"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot read the SSH key file"* ]]
}

@test "unknown options are refused" {
  TVBOX_ARCH_LIB_DIR="$T/lib" TVBOX_DRY_RUN=1 \
    run "$REPO/autoinstall/arch-install.sh" --disk /dev/nvme0n1 --bogus yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "removable/USB disks are refused" {
  fake_lsblk
  TVBOX_ARCH_LIB_DIR="$T/lib" TVBOX_DRY_RUN=1 PATH="$T/bin:$PATH" \
    run "$REPO/autoinstall/arch-install.sh" --disk /dev/sdb --confirm-wipe /dev/sdb \
      --password-hash-file "$T/in/hash" --ssh-key-file "$T/in/key.pub"
  [ "$status" -ne 0 ]
  [[ "$output" == *"removable"* || "$output" == *"USB"* ]]
}

@test "the disk the running live system sits on is refused" {
  mkdir -p "$T/bin"
  cat > "$T/bin/lsblk" <<'F'
#!/bin/sh
case "$*" in
  *RM,TRAN*) echo "0 nvme" ;;
  *NAME,TYPE*) echo "/dev/nvme0n1 disk" ;;
esac
F
  cat > "$T/bin/findmnt" <<'F'
#!/bin/sh
echo /dev/nvme0n1p2
F
  chmod +x "$T/bin/lsblk" "$T/bin/findmnt"
  TVBOX_ARCH_LIB_DIR="$T/lib" TVBOX_DRY_RUN=1 PATH="$T/bin:$PATH" \
    run "$REPO/autoinstall/arch-install.sh" --disk /dev/nvme0n1 --confirm-wipe /dev/nvme0n1 \
      --password-hash-file "$T/in/hash" --ssh-key-file "$T/in/key.pub"
  [ "$status" -ne 0 ]
  [[ "$output" == *"running live system"* ]]
}

@test "missing arch libraries give a clear error" {
  fake_lsblk
  mkdir -p "$T/empty"
  TVBOX_ARCH_LIB_DIR="$T/empty" TVBOX_DRY_RUN=1 PATH="$T/bin:$PATH" \
    run "$REPO/autoinstall/arch-install.sh" --disk /dev/nvme0n1 --confirm-wipe /dev/nvme0n1 \
      --password-hash-file "$T/in/hash" --ssh-key-file "$T/in/key.pub"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing $T/empty/disk.sh"* ]]
}

@test "--dry-run (the FLAG, no env) really runs nothing: sourced libs must not reset it" {
  mk_tmp
  mkdir -p "$T/bin"
  # any real execution of these would leave a marker
  for c in curl tar wipefs sgdisk mkfs.fat mkfs.btrfs mount umount pacstrap genfstab arch-chroot partprobe udevadm btrfs; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/EXECUTED"\n' "$c" "$T" > "$T/bin/$c"; chmod +x "$T/bin/$c"
  done
  # a whole, non-removable, non-USB nvme disk that is not the root disk
  cat > "$T/bin/lsblk" <<'F'
#!/bin/sh
case "$*" in *TYPE,RM,TRAN*) echo "disk 0 nvme" ;; *RM,TRAN*) echo "0 nvme" ;; *NAME,TYPE*) echo "sdz disk" ;; *) exit 0 ;; esac
F
  printf '#!/bin/sh\necho /dev/sdz1\n' > "$T/bin/findmnt"; chmod +x "$T/bin/lsblk" "$T/bin/findmnt"
  printf '%s\n' '$6$saltsalt$abcdefghijklmnopqrstuvwxyz' > "$T/hash"
  ssh-keygen -q -t ed25519 -N '' -f "$T/k" -C t
  PATH="$T/bin:$PATH" run bash "$REPO/autoinstall/arch-install.sh" --dry-run --disk /dev/nvme0n1 --confirm-wipe /dev/nvme0n1 \
      --password-hash-file "$T/hash" --ssh-key-file "$T/k.pub"
  [ "$status" -eq 0 ]
  [ ! -e "$T/EXECUTED" ] || { cat "$T/EXECUTED"; false; }
  [[ "$output" == *"DRY: "* ]]
}
