load helpers

setup() {
  mk_tmp
  export TVBOX_DRY_RUN=1
  export TVBOX_ROOT="$T/root"
  export TVBOX_HOSTNAME=tvbox
  export TVBOX_USER=tvbox
  export TVBOX_PASS_HASH="\$6\$saltsalt\$abcdefghijklmnopqrstuv"
  export TVBOX_SSH_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIfake tvbox@pc'
  export TVBOX_TZ=America/Moncton
  export TVBOX_KBD=us
  export TVBOX_DOMAIN=example.org
}

teardown() { rm -rf "$T"; }

cfg() { "$REPO/autoinstall/arch/chroot.sh"; }

@test "writes the sshd drop-in, sudoers, loader entries and firstboot unit" {
  run cfg
  [ "$status" -eq 0 ]
  [ -x "$REPO/autoinstall/arch/chroot.sh" ]
  r="$T/root"
  grep -q '^PasswordAuthentication no' "$r/etc/ssh/sshd_config.d/10-tvbox.conf"
  grep -q '^PermitRootLogin no' "$r/etc/ssh/sshd_config.d/10-tvbox.conf"
  [ "$(cat "$r/etc/sudoers.d/10-wheel")" = '%wheel ALL=(ALL:ALL) ALL' ]
  [ "$(stat -c %a "$r/etc/sudoers.d/10-wheel")" = 440 ]
  grep -q '^default tvbox' "$r/boot/loader/loader.conf"
  grep -q '^timeout 3' "$r/boot/loader/loader.conf"
  e="$r/boot/loader/entries/tvbox.conf"
  grep -q '^linux   /vmlinuz-linux-cachyos' "$e"
  grep -q '^initrd  /amd-ucode.img' "$e"
  grep -q '^initrd  /initramfs-linux-cachyos.img' "$e"
  grep -q '^options root=LABEL=tvbox rootflags=subvol=@ rw' "$e"
  f="$r/boot/loader/entries/tvbox-fallback.conf"
  grep -q '^initrd  /initramfs-linux-cachyos-fallback.img' "$f"
  grep -q '^options root=LABEL=tvbox rootflags=subvol=@ rw' "$f"
  u="$r/etc/systemd/system/tvbox-firstboot.service"
  grep -q '^Wants=network-online.target' "$u"
  grep -q '^After=network-online.target' "$u"
  grep -q '^ConditionPathExists=!/var/lib/tvbox-firstboot.done' "$u"
  grep -q '^ExecStart=/usr/local/sbin/tvbox-firstboot.sh' "$u"
}

@test "dry-run prints the system commands instead of running them" {
  run cfg
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] ln -sf /usr/share/zoneinfo/America/Moncton"* ]]
  [[ "$output" == *"[dry-run] hwclock --systohc"* ]]
  [[ "$output" == *"[dry-run] locale-gen"* ]]
  [[ "$output" == *"[dry-run] useradd -m -G wheel,video,input,audio,render tvbox"* ]]
  [[ "$output" == *"[dry-run] chpasswd -e"* ]]
  [[ "$output" == *"[dry-run] chown -R tvbox:tvbox"* ]]
  [[ "$output" == *"[dry-run] systemctl enable NetworkManager sshd avahi-daemon systemd-timesyncd fstrim.timer"* ]]
  [[ "$output" == *"[dry-run] bootctl install"* ]]
  [[ "$output" == *"[dry-run] mkinitcpio -P"* ]]
  [ ! -e "$T/root/etc/localtime" ]
}

@test "hostname, hosts, keymap and locale" {
  run cfg
  [ "$status" -eq 0 ]
  r="$T/root"
  [ "$(cat "$r/etc/hostname")" = tvbox ]
  grep -q '^127.0.1.1 tvbox.example.org tvbox$' "$r/etc/hosts"
  grep -q '^KEYMAP=us$' "$r/etc/vconsole.conf"
  grep -q '^LANG=en_US.UTF-8$' "$r/etc/locale.conf"
  grep -q '^en_US.UTF-8 UTF-8$' "$r/etc/locale.gen"
}

@test "the user's SSH key is the only authorized key (mode 600)" {
  run cfg
  [ "$status" -eq 0 ]
  a="$T/root/home/tvbox/.ssh/authorized_keys"
  [ "$(cat "$a")" = "$TVBOX_SSH_KEY" ]
  [ "$(stat -c %a "$a")" = 600 ]
  [ "$(stat -c %a "$T/root/home/tvbox/.ssh")" = 700 ]
}

@test "Wi-Fi keyfile (mode 600) only when TVBOX_WIFI_SSID is set" {
  run cfg
  [ "$status" -eq 0 ]
  [ ! -e "$T/root/etc/NetworkManager/system-connections" ]
  export TVBOX_WIFI_SSID=BELL134
  export TVBOX_WIFI_PASS='hunter2'
  run cfg
  [ "$status" -eq 0 ]
  w="$T/root/etc/NetworkManager/system-connections/BELL134.nmconnection"
  [ "$(stat -c %a "$w")" = 600 ]
  grep -q '^id=BELL134$' "$w"
  grep -q '^type=802-11-wireless$' "$w"
  grep -q '^ssid=BELL134$' "$w"
  grep -q '^mode=infrastructure$' "$w"
  grep -q '^key-mgmt=wpa-psk$' "$w"
  grep -q '^psk=hunter2$' "$w"
  grep -q '^uuid=[0-9a-f-]\{36\}$' "$w"
}

@test "firstboot script: bundle first, GitHub fallback, env, marker" {
  run cfg
  [ "$status" -eq 0 ]
  s="$T/root/usr/local/sbin/tvbox-firstboot.sh"
  [ -x "$s" ]
  grep -q '^SEED_ENV=/opt/tvbox-seed.env$' "$s"
  grep -q '^BUNDLE=/opt/tvbox.bundle$' "$s"
  grep -q '^MARKER=/var/lib/tvbox-firstboot.done$' "$s"
  grep -qF 'BOOTSTRAP_URL=https://raw.githubusercontent.com/fernandeslder/tv-box-cloud-server/master/bootstrap.sh' "$s"
  grep -q 'export TVBOX_NONINTERACTIVE=1' "$s"
  grep -q "export TVBOX_ENV_FILE=\"\$SEED_ENV\"" "$s"
  grep -q "touch \"\$MARKER\"" "$s"
  grep -q 'systemctl disable tvbox-firstboot.service' "$s"
  grep -q "git clone -q \"\$BUNDLE\" \"\$tmp/repo\"" "$s"
}

@test "fails with a clear message when a required variable is missing" {
  for v in TVBOX_HOSTNAME TVBOX_USER TVBOX_PASS_HASH TVBOX_SSH_KEY; do
    unset "$v"
    run cfg
    [ "$status" -ne 0 ]
    [[ "$output" == *"chroot.sh: error: $v is required"* ]]
    export "$v"=placeholder
  done
}

@test "without TVBOX_DRY_RUN the system commands really run (fake binaries)" {
  bin="$T/bin"
  mkdir -p "$bin"
  for c in ln hwclock locale-gen useradd chpasswd systemctl bootctl mkinitcpio chown; do
    cat > "$bin/$c" <<EOF
#!/bin/sh
echo "$c \$@" >> "$T/calls.log"
EOF
    chmod +x "$bin/$c"
  done
  export PATH="$bin:$PATH"
  unset TVBOX_DRY_RUN
  run cfg
  [ "$status" -eq 0 ]
  log="$T/calls.log"
  grep -q '^ln -sf /usr/share/zoneinfo/America/Moncton' "$log"
  grep -q '^hwclock --systohc' "$log"
  grep -q '^locale-gen' "$log"
  grep -q '^useradd -m -G wheel,video,input,audio,render tvbox' "$log"
  grep -q '^chpasswd -e' "$log"
  grep -q '^chown -R tvbox:tvbox' "$log"
  grep -q '^systemctl enable NetworkManager sshd avahi-daemon systemd-timesyncd fstrim.timer' "$log"
  grep -q '^bootctl install' "$log"
  grep -q '^mkinitcpio -P' "$log"
  grep -q '^systemctl enable tvbox-firstboot.service' "$log"
}
