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
  ln -s . "$T/iso/ubuntu"; ln -s casper "$T/iso/stable"   # FAT32 cannot hold symlinks
  echo k > "$T/iso/casper/vmlinuz"; echo i > "$T/iso/casper/initrd"; echo e > "$T/iso/EFI/BOOT/BOOTX64.EFI"
  # like the real ISO: md5sum.txt lists every regular file (symlinks are not in it)
  ( cd "$T/iso" && find . -type f ! -name md5sum.txt -print0 | sort -z | xargs -0 md5sum > md5sum.txt )
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
@test "ISO symlinks are left out (FAT32 has none) and everything else is unpacked" {
  run build; [ "$status" -eq 0 ]
  [ ! -e "$T/stick/ubuntu" ]; [ ! -L "$T/stick/stable" ]; [ -f "$T/stick/EFI/BOOT/BOOTX64.EFI" ]
}
@test "a shallow clone is refused with a clear message (a bundle needs full history)" {
  git clone -q --depth 1 "file://$REPO" "$T/shallow"
  run "$T/shallow/autoinstall/build-usb.sh" --iso "$T/fake.iso" --target "$T/stick" --ssh-key-file "$T/k.pub" --password-hash-file "$T/hash" --yes
  [ "$status" -ne 0 ]; [[ "$output" == *"shallow clone"* ]]
}

@test "md5sum.txt matches the stick after the grub.cfg edit (installer integrity check passes)" {
  build >/dev/null
  ( cd "$T/stick" && md5sum -c --quiet md5sum.txt )
  # re-running (also --seed-only, which repairs a stick built before the fix) keeps it valid
  build >/dev/null
  ( cd "$T/stick" && md5sum -c --quiet md5sum.txt )
  # simulate a stick made before the fix: stale sum for grub.cfg, then --seed-only repairs it
  sed -i 's#^[0-9a-f]\{32\}  \./boot/grub/grub.cfg$#00000000000000000000000000000000  ./boot/grub/grub.cfg#' "$T/stick/md5sum.txt"
  ! ( cd "$T/stick" && md5sum -c --quiet md5sum.txt ) 2>/dev/null
  run "$REPO/autoinstall/build-usb.sh" --seed-only --target "$T/stick" --ssh-key-file "$T/k.pub" \
        --password-hash-file "$T/hash" --user tvbox --yes
  [ "$status" -eq 0 ]
  ( cd "$T/stick" && md5sum -c --quiet md5sum.txt )
}
@test "the installer gets no custom network block, an offline fallback, and no packages list" {
  TVBOX_WIFI_PASS=x build --wifi-ssid BELL134 >/dev/null
  u="$T/stick/seed/user-data"
  ! grep -qE '^  network:' "$u"
  ! grep -qE '^  packages:' "$u"
  grep -qE '^  apt:' "$u"; grep -q 'fallback: offline-install' "$u"
  # git/curl/avahi come from the first-boot script instead
  grep -q 'apt-get install -y -qq git curl ca-certificates avahi-daemon libnss-mdns' "$u"
}
@test "wi-fi goes to the installed system only: real interface name, mode 600, valid netplan" {
  python3 -c 'import yaml' 2>/dev/null || skip "PyYAML needed"
  TVBOX_WIFI_PASS="p'a\$s w0rd" build --wifi-ssid "My 'Net" >/dev/null
  cat > "$T/extract.py" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
cmds = [c for c in d["autoinstall"]["late-commands"] if isinstance(c, str) and "60-tvbox-wifi" in c]
assert len(cmds) == 1, cmds
open(sys.argv[2], "w").write(cmds[0])
PY
  python3 -I "$T/extract.py" "$T/stick/seed/user-data" "$T/wifi.sh"
  mkdir -p "$T/sys/class/net/enp2s0f0" "$T/sys/class/net/wlp3s0/wireless" "$T/target/etc"
  sed -i "s#/sys/class/net#$T/sys/class/net#g; s#/target#$T/target#g" "$T/wifi.sh"
  run sh "$T/wifi.sh"; [ "$status" -eq 0 ]
  f="$T/target/etc/netplan/60-tvbox-wifi.yaml"
  [ "$(stat -c %a "$f")" = 600 ]
  cat > "$T/check.py" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
w = d["network"]["wifis"]["wlp3s0"]
assert w["dhcp4"] is True and w["optional"] is True
ap = w["access-points"]
assert list(ap) == ["My 'Net"], ap
assert ap["My 'Net"]["password"] == "p'a$s w0rd", ap
assert "match" not in w
PY
  python3 -I "$T/check.py" "$f"
}
@test "without --wifi-ssid nothing about Wi-Fi is active in the seed" {
  build >/dev/null
  run bash -c "grep -v '^[[:space:]]*#' '$T/stick/seed/user-data' | grep -c '60-tvbox-wifi'"
  [ "$output" = 0 ]
}
