load helpers
setup() {
  command -v xorriso >/dev/null || skip "xorriso needed to fake an ISO"
  command -v bsdtar >/dev/null || skip "bsdtar needed to inspect the ISO"
  mk_tmp
  export TVBOX_USB_ALLOW_ANY_DIR=1
  # The builder reads the stick's UUID with findmnt; a tmpdir is not a mounted
  # FAT32 stick, so answer its queries with a fake (findmnt is the real code path).
  mkdir -p "$T/bin"
  cat > "$T/bin/findmnt" <<'F'
#!/usr/bin/env bash
if [ "$1" = -n ] && [ "$2" = -o ]; then
  case "$3" in
    UUID) echo "1234-ABCD" ;;
    FSTYPE) echo vfat ;;
    SOURCE) echo /dev/fake-stick ;;
  esac
  exit 0
fi
exec /usr/bin/findmnt "$@"
F
  chmod +x "$T/bin/findmnt"
  export PATH="$T/bin:$PATH"
  # a stick that already boots something: a GRUB config + data the owner left on it
  mkdir -p "$T/stick/boot/grub" "$T/stick/OLD-USB-DATA"
  cat > "$T/stick/boot/grub/grub.cfg" <<'G'
set timeout=30

loadfont unicode

menuentry "Old installer entry" {
    linux /old/vmlinuz
    initrd /old/initrd
}
G
  echo keep > "$T/stick/OLD-USB-DATA/file.txt"
  ( cd "$T/stick" && find . -type f ! -name md5sum.txt -print0 | sort -z | xargs -0 md5sum ) > "$T/stick/md5sum.txt"
  # a fake CachyOS ISO with the real archiso layout
  mkdir -p "$T/iso/arch/boot/x86_64" "$T/iso/arch/boot/grub"
  echo k > "$T/iso/arch/boot/x86_64/vmlinuz-linux-cachyos"
  echo i > "$T/iso/arch/boot/x86_64/initramfs-linux-cachyos.img"
  echo u > "$T/iso/arch/boot/amd-ucode.img"
  echo g > "$T/iso/arch/boot/grub/grub.cfg"
  ( cd "$T/iso" && find . -type f ! -name md5sum.txt -print0 | sort -z | xargs -0 md5sum ) > "$T/iso/md5sum.txt"
  xorriso -as mkisofs -quiet -o "$T/cachyos.iso" "$T/iso" 2>/dev/null
  ( cd "$T" && sha256sum cachyos.iso ) > "$T/SHA256SUMS"
}
teardown() { rm -rf "$T"; }

build() { "$REPO/autoinstall/build-usb-arch.sh" --iso "$T/cachyos.iso" --target "$T/stick" --yes "$@"; }

@test "copies the ISO to cachyos/cachyos.iso and puts the loopback entry first" {
  run build; [ "$status" -eq 0 ]
  [ -f "$T/stick/cachyos/cachyos.iso" ]
  cmp "$T/cachyos.iso" "$T/stick/cachyos/cachyos.iso"
  g="$T/stick/boot/grub/grub.cfg"
  grep -q 'menuentry "CachyOS installer (TV box)"' "$g"
  [ "$(grep -n 'CachyOS installer (TV box)' "$g" | cut -d: -f1)" -lt "$(grep -n 'Old installer entry' "$g" | cut -d: -f1)" ]
  grep -qF 'loopback loop /cachyos/cachyos.iso' "$g"
  grep -qF 'linux (loop)/arch/boot/x86_64/vmlinuz-linux-cachyos img_dev=/dev/disk/by-uuid/1234-ABCD img_loop=/cachyos/cachyos.iso earlymodules=loop archisobasedir=arch' "$g"
  grep -qF 'initrd (loop)/arch/boot/amd-ucode.img (loop)/arch/boot/x86_64/initramfs-linux-cachyos.img' "$g"
  # every existing entry and file survives
  grep -q 'menuentry "Old installer entry"' "$g"
  grep -q '^set timeout=30' "$g"
  [ "$(cat "$T/stick/OLD-USB-DATA/file.txt")" = keep ]
}

@test "re-running is idempotent (one entry, one ISO, md5sum.txt stays valid)" {
  build "$@" >/dev/null; build "$@" >/dev/null
  [ "$(grep -c 'CachyOS installer (TV box)' "$T/stick/boot/grub/grub.cfg")" -eq 1 ]
  ( cd "$T/stick" && md5sum -c --quiet md5sum.txt )
}

@test "md5sum.txt is updated for the edited grub.cfg (and repaired by a re-run)" {
  build "$@" >/dev/null
  ( cd "$T/stick" && md5sum -c --quiet md5sum.txt )
  # a stick built before the fix: a stale (properly formatted, never-matching) sum for grub.cfg
  sed -i 's#^[0-9a-f]\{32\}  \./boot/grub/grub.cfg$#00000000000000000000000000000000  ./boot/grub/grub.cfg#' "$T/stick/md5sum.txt"
  if ( cd "$T/stick" && md5sum -c --quiet md5sum.txt ); then false; fi
  build "$@" >/dev/null
  ( cd "$T/stick" && md5sum -c --quiet md5sum.txt )
}

@test "refuses an ISO bigger than the FAT32 4 GiB single-file limit" {
  truncate -s 4294967296 "$T/big.iso"
  run build --iso "$T/big.iso"; [ "$status" -ne 0 ]
  [[ "$output" == *"FAT32"* ]]
  [[ "$output" == *"4 GiB"* ]]
  [ ! -e "$T/stick/cachyos" ]
}

@test "verifies the ISO against --sha256 before writing anything" {
  run build --sha256 0000000000000000000000000000000000000000000000000000000000000000
  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ ! -e "$T/stick/cachyos" ]
  run build --sha256 "$(sha256sum "$T/cachyos.iso" | cut -d' ' -f1)"; [ "$status" -eq 0 ]
  [ -f "$T/stick/cachyos/cachyos.iso" ]
}

@test "a tampered ISO is refused before anything is written (sums file next to it)" {
  echo x >> "$T/cachyos.iso"
  run build; [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ ! -e "$T/stick/cachyos" ]
}

@test "kernel, initramfs and microcode names are detected from the ISO" {
  mkdir -p "$T/iso2/arch/boot/x86_64"
  echo k > "$T/iso2/arch/boot/x86_64/vmlinuz-linux-cachyos-lts"
  echo i > "$T/iso2/arch/boot/x86_64/initramfs-linux-cachyos-lts.img"
  echo u > "$T/iso2/arch/boot/intel-ucode.img"
  xorriso -as mkisofs -quiet -o "$T/lts.iso" "$T/iso2" 2>/dev/null
  run "$REPO/autoinstall/build-usb-arch.sh" --iso "$T/lts.iso" --target "$T/stick" \
    --sha256 "$(sha256sum "$T/lts.iso" | cut -d' ' -f1)" --yes
  [ "$status" -eq 0 ]
  g="$T/stick/boot/grub/grub.cfg"
  grep -qF 'linux (loop)/arch/boot/x86_64/vmlinuz-linux-cachyos-lts img_dev=/dev/disk/by-uuid/1234-ABCD img_loop=/cachyos/cachyos.iso earlymodules=loop archisobasedir=arch' "$g"
  grep -qF 'initrd (loop)/arch/boot/intel-ucode.img (loop)/arch/boot/x86_64/initramfs-linux-cachyos-lts.img' "$g"
}

@test "TVBOX_DRY_RUN=1 prints every action and writes nothing" {
  cp "$T/stick/boot/grub/grub.cfg" "$T/grub.before"
  cp "$T/stick/md5sum.txt" "$T/md5.before"
  TVBOX_DRY_RUN=1 run build "$@"; [ "$status" -eq 0 ]
  [[ "$output" == *"DRY: mkdir"* ]]
  [[ "$output" == *"DRY: cp"* ]]
  [ ! -e "$T/stick/cachyos" ]
  cmp "$T/grub.before" "$T/stick/boot/grub/grub.cfg"
  cmp "$T/md5.before" "$T/stick/md5sum.txt"
}

@test "md5sum.txt is left alone when it is missing or does not list grub.cfg" {
  rm "$T/stick/md5sum.txt"
  build "$@" >/dev/null
  [ ! -e "$T/stick/md5sum.txt" ]
  printf '00000000000000000000000000000000  ./other/file\n' > "$T/stick/md5sum.txt"
  build "$@" >/dev/null
  [ "$(cat "$T/stick/md5sum.txt")" = '00000000000000000000000000000000  ./other/file' ]
}

@test "refuses a stick without an existing boot/grub/grub.cfg" {
  rm "$T/stick/boot/grub/grub.cfg"
  run build; [ "$status" -ne 0 ]
  [[ "$output" == *"grub.cfg"* ]]
  [ ! -e "$T/stick/cachyos" ]
}

@test "refuses a non-mounted target unless the test override is set" {
  unset TVBOX_USB_ALLOW_ANY_DIR
  run build; [ "$status" -ne 0 ]
  [[ "$output" == *"is not a mountpoint"* ]]
  [ ! -e "$T/stick/cachyos" ]
}

@test "refuses / as the target" {
  run build --target /; [ "$status" -ne 0 ]
  # as root the / check fires, as a normal user the writable check does
  [[ "$output" == *"refusing to use /"* || "$output" == *"not writable"* ]]
}

@test "asks before writing when --yes is not given" {
  run "$REPO/autoinstall/build-usb-arch.sh" --iso "$T/cachyos.iso" --target "$T/stick"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Continue"* ]]
  [ ! -e "$T/stick/cachyos" ]
}
