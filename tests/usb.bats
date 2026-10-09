load helpers
setup() {
  command -v xorriso >/dev/null || skip "xorriso needed to fake an ISO"
  mk_tmp
  export TVBOX_USB_ALLOW_ANY_DIR=1
  mkdir -p "$T/iso/boot/grub" "$T/iso/casper" "$T/iso/EFI/BOOT" "$T/stick"
  cat > "$T/iso/boot/grub/grub.cfg" <<'G'
set timeout=30

loadfont unicode

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "Try or Install Ubuntu Server" {
    set gfxpayload=keep
    linux  /casper/vmlinuz  --- 
    initrd /casper/initrd
}
grub_platform
if [ "$grub_platform" = "efi" ]; then
menuentry 'Boot from next volume' {
    exit 1
}
menuentry 'UEFI Firmware Settings' {
    fwsetup
}
fi
G
  echo k > "$T/iso/casper/vmlinuz"; echo i > "$T/iso/casper/initrd"; echo e > "$T/iso/EFI/BOOT/BOOTX64.EFI"
  xorriso -as mkisofs -quiet -o "$T/fake.iso" "$T/iso" 2>/dev/null
  ( cd "$T" && sha256sum fake.iso > SHA256SUMS )
  ssh-keygen -q -t ed25519 -N '' -f "$T/k" -C test
  printf '%s\n' '$6$saltsalt$abcdefghijklmnopqrstuv' > "$T/hash"
  mkdir -p "$T/stick/OLD-USB-DATA"; echo keep > "$T/stick/OLD-USB-DATA/file.txt"
}
teardown() { rm -rf "$T"; }

build() { "$REPO/autoinstall/build-usb.sh" --iso "$T/fake.iso" --target "$T/stick" --ssh-key-file "$T/k.pub" \
            --password-hash-file "$T/hash" --user tvbox --timezone America/Moncton --domain lder.fyi --yes "$@"; }

@test "builds the one-stick layout and leaves existing files alone" {
  run build; [ "$status" -eq 0 ]
  [ -f "$T/stick/casper/vmlinuz" ]; [ -f "$T/stick/seed/user-data" ]; [ -f "$T/stick/seed/meta-data" ]
  [ -f "$T/stick/tv-box/tvbox.bundle" ]; [ -f "$T/stick/tv-box/FIRST-BOOT-CHECKLIST.txt" ]
  [ "$(cat "$T/stick/OLD-USB-DATA/file.txt")" = keep ]
}
@test "the new boot entry is first, default, and carries the autoinstall arguments" {
  build >/dev/null
  g="$T/stick/boot/grub/grub.cfg"
  grep -q 'menuentry "TV box: automated install' "$g"
  grep -qF 'autoinstall ds=nocloud\;s=/cdrom/seed/ ---' "$g"
  [ "$(grep -n 'TV box: automated install' "$g" | cut -d: -f1)" -lt "$(grep -n 'Try or Install Ubuntu Server' "$g" | cut -d: -f1)" ]
  grep -q '^set default=0' "$g"
  # the stock entries survive untouched
  grep -q 'menuentry "Try or Install Ubuntu Server"' "$g"; grep -q "menuentry 'UEFI Firmware Settings'" "$g"
}
@test "re-running is idempotent (no second boot entry)" {
  build >/dev/null; build >/dev/null
  [ "$(grep -c 'TV box: automated install' "$T/stick/boot/grub/grub.cfg")" -eq 1 ]
}
@test "the seed has no unfilled placeholders, key-only SSH, the timezone, and no secrets in the env" {
  build >/dev/null
  ! grep -v '^[[:space:]]*#' "$T/stick/seed/user-data" | grep -q '@@'
  grep -q "timezone: 'America/Moncton'" "$T/stick/seed/user-data"
  grep -q 'allow-pw: false' "$T/stick/seed/user-data"
  grep -q 'ssh-ed25519' "$T/stick/seed/user-data"
  grep -q '^DOMAIN=lder.fyi$' "$T/stick/seed/tvbox-seed.env"
  ! grep -v '^#' "$T/stick/seed/tvbox-seed.env" | grep -qiE 'token|password|authkey|api_key'
}
@test "the bundle clones and matches the recorded commit and checksum" {
  build >/dev/null
  ( cd "$T/stick/tv-box" && sha256sum -c tvbox.bundle.sha256 )
  git clone -q "$T/stick/tv-box/tvbox.bundle" "$T/clone"
  [ "$(git -C "$T/clone" rev-parse HEAD)" = "$(cat "$T/stick/tv-box/COMMIT")" ]
  [ -x "$T/clone/bootstrap.sh" ]
}
@test "a tampered ISO is refused before anything is written" {
  echo x >> "$T/fake.iso"
  run build; [ "$status" -ne 0 ]; [[ "$output" == *"checksum mismatch"* ]]
  [ ! -e "$T/stick/seed" ]
}
@test "refuses a non-FAT32 or non-mounted target unless the test override is set" {
  unset TVBOX_USB_ALLOW_ANY_DIR
  run build; [ "$status" -ne 0 ]
}
@test "wifi password never lands in the seed env, only in user-data" {
  TVBOX_WIFI_PASS='hunter2pass' build --wifi-ssid BELL134 >/dev/null
  grep -q "BELL134" "$T/stick/seed/user-data"
  ! grep -rq 'hunter2pass' "$T/stick/seed/tvbox-seed.env"
}
@test "two-stage build: ISO + boot entry first, seed later, without redoing the ISO" {
  run build --no-seed; [ "$status" -eq 0 ]
  [ -f "$T/stick/casper/vmlinuz" ]; [ ! -e "$T/stick/seed/user-data" ]; [ -f "$T/stick/tv-box/tvbox.bundle" ]
  rm -f "$T/fake.iso"   # --seed-only must not need the ISO at all
  run "$REPO/autoinstall/build-usb.sh" --seed-only --target "$T/stick" --ssh-key-file "$T/k.pub" \
        --password-hash-file "$T/hash" --user tvbox --yes
  [ "$status" -eq 0 ]; [ -f "$T/stick/seed/user-data" ]
  ( cd "$T/stick" && sha256sum -c tv-box/SHA256SUMS >/dev/null )
}
