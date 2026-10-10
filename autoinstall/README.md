# Zero-touch install (Ubuntu Server 26.04 LTS autoinstall; CachyOS/Arch route below)

Goal: boot the installer USB, confirm **one** screen (the disk), walk away. The box installs the OS,
powers off, and on first boot sets everything up by itself from the repo bundle that sits on the stick.

Files here:
- `build-usb.sh` — makes an existing FAT32 stick bootable **without reformatting it** (recommended).
- `make-seed.sh` — fills the autoinstall template (`user-data`) and builds `seed/` (used by `build-usb.sh`; also runnable alone).
- `user-data` — the autoinstall template (placeholders filled by `make-seed.sh`).
- `meta-data` — required by cloud-init, intentionally trivial.
- `build-usb-arch.sh` — CachyOS (Arch) stick builder: loopback-boots the ISO on an existing FAT32/GRUB stick.
- `arch-install.sh` — scripted CachyOS install; run as root from the live ISO over SSH.
- `arch/` — helpers it sources: `disk.sh`, `packages.sh`, `chroot.sh`.

## What a human still has to do (honest list)
1. Build the stick (below) — the password is typed by you, only its hash is stored.
2. **Confirm the disk** at the storage screen. This is deliberate: a wrong guess wipes a disk.
3. Paste API tokens once after first boot (no secrets are put on the stick): `sudo tvbox setup --reconfigure`.
4. **`tailscale up`** needs you to approve the device in your browser (login link in the log / on SSH).
5. Connect the HDDs *after* the install: `sudo tvbox disks scan`, `sudo tvbox disks add /dev/sdX data|backup`.

## One-stick route (build-usb.sh)
The stick keeps its FAT32 filesystem and every file already on it. Layout afterwards:

```
<stick>/  EFI/ boot/ casper/ .disk/ pool/ dists/ ...   Ubuntu Server ISO contents (UEFI boot)
          seed/      user-data, meta-data, tvbox-seed.env      read by the installer (nocloud)
          tv-box/    tvbox.bundle (+ .sha256, COMMIT), legion/, clients/, docs/, FIRST-BOOT-CHECKLIST.txt
          <your own files and folders, untouched>
```

```bash
ssh-keygen -t ed25519 -f ~/.ssh/tvbox_ed25519 -C tvbox                     # once; private half never leaves the PC
mkpasswd -m sha-512 > ~/.config/tvbox/password-hash                         # prompts for the password (package: whois)
TVBOX_WIFI_PASS='...' ./autoinstall/build-usb.sh \
    --iso ~/Downloads/ubuntu-26.04.1-live-server-amd64.iso --target /mnt/usb \
    --ssh-key-file ~/.ssh/tvbox_ed25519.pub --password-hash-file ~/.config/tvbox/password-hash \
    --user tvbox --wifi-ssid 'MyWifi' --domain example.org
```

What it does, in order — and refuses to do anything if a check fails:
1. verifies the ISO against `SHA256SUMS` in the same folder, the target is a **mounted vfat** filesystem (never `/`, never a system path), and there is space;
2. writes `seed/` (calls `make-seed.sh`; SSH is key-only; password hash, timezone, optional Wi-Fi);
3. unpacks the ISO onto the stick (`bsdtar`, `xorriso` or `7z`);
4. inserts a first, default menu entry **"TV box: automated install"** into `boot/grub/grub.cfg` (`autoinstall ds=nocloud\;s=/cdrom/seed/`), keeping every stock entry below it;
5. writes `tv-box/`: a `git bundle` of this repo at the current commit (+ checksum), helper folders and the checklist.

Re-running is safe (the boot entry is added once). `--no-seed` does 1/3/4/5 without a seed; `--seed-only` rewrites just `seed/` and `tv-box/` later (fast, no ISO needed).

Download and verify the ISO (the signing key is Ubuntu's CD image key `8439 38DF 228D 22F7 B374 2BC0 D94A A3F0 EFE2 1092`):
```bash
B=https://releases.ubuntu.com/26.04.1; curl -fLO $B/ubuntu-26.04.1-live-server-amd64.iso -O $B/SHA256SUMS -O $B/SHA256SUMS.gpg
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 843938DF228D22F7B3742BC0D94AA3F0EFE21092
gpg --verify SHA256SUMS.gpg SHA256SUMS && sha256sum -c --ignore-missing SHA256SUMS
```

### Installing
1. Plug the stick and ethernet (+ HDMI + keyboard) into the box. **HDDs and other USB drives stay unplugged.**
2. Boot from the stick (`F12` on Lenovo, choose the UEFI entry) → **TV box: automated install**.
3. The installer runs unattended up to the **storage screen**: check that only the NVMe/SSD is offered, confirm, then answer the final "destructive action" prompt.
4. When the OS is installed the box **powers off** (so a plugged-in stick can't restart the installer). Unplug the stick, press power.
5. First boot installs the whole stack (see below).

## Two-stick route (still supported)
Seed on a second FAT32 stick labelled `CIDATA` (`./make-seed.sh` builds `seed/` + `seed.iso`; copy the files inside `seed/` to its root) next to a stock Ubuntu installer stick (Ventoy/Etcher/Rufus). Boot the stock entry and answer `yes` to "Continue with autoinstall?".

### Other routes
- **Kernel argument / HTTP:** on the installer GRUB menu press `e`, add to the `linux` line
  `autoinstall ds=nocloud-net\;s=http://<your-pc-ip>:8000/` (keep the backslash), `F10`. On your PC run
  `cd seed && python3 -m http.server 8000`. Neither `tvbox-seed.env` nor the repo bundle is picked up this way;
  first boot then downloads `bootstrap.sh` from GitHub (copy the env file later to `/opt/tvbox-seed.env`).

## What the install does
- Installs to the SSD/NVMe only (`layout: direct`, `match: {ssd: true}`): HDDs are rotational so they don't match,
  but a USB SSD would — keep USB drives unplugged. The screen is interactive so you always confirm.
- Hostname `tvbox`, your user, **SSH key-only login** (password login over SSH is off; the console still takes the password).
- Timezone from the seed (default: the PC that built it). Network during the install is the installer's own default (DHCP on `en*`/`eth*`);
  there is deliberately no custom `network:` block. Wi-Fi (if built with `--wifi-ssid`) is written only to the installed system
  (`/etc/netplan/60-tvbox-wifi.yaml`, mode 600, real interface name), so it cannot stop the install.
- `apt: fallback: offline-install`: if no mirror is reachable the OS installs from the ISO's own pool. `git curl avahi-daemon` are
  installed by the first-boot script, not by the installer, so the OS install itself needs no network.
- The ISO's `md5sum.txt` is updated for the patched `grub.cfg` (the installer verifies the medium and reports
  "install media checksum verification failed" otherwise).
- Copies `seed/tvbox-seed.env` → `/opt/tvbox-seed.env` (root-only, mode 600) and `tv-box/tvbox.bundle` → `/opt/tvbox.bundle` (checksum-verified).
- Installs `tvbox-firstboot.service`: after the first boot and network-up it clones `/opt/tvbox` **from the bundle** (pinned commit,
  works when GitHub is down; falls back to downloading `bootstrap.sh` from `master`), then runs it with `TVBOX_NONINTERACTIVE=1`
  and `TVBOX_ENV_FILE=/opt/tvbox-seed.env`. `bootstrap.sh` runs `setup.sh --yes`. Later, `tvbox update` follows GitHub.
- Marker `/var/lib/tvbox-firstboot.done` is written on success and the service disables itself. On failure it stays enabled
  and retries on the next boot.

## How long
OS install ~10–15 min (needs internet for updates/packages). First-boot setup ~20–40 min more (Plasma, Kodi, Docker images, Mesa).
The box may reboot during setup.

## Find the box and watch progress
```bash
ssh tvbox@tvbox.local            # your username; or find the IP in the router's DHCP list
tail -f /var/log/tvbox-firstboot.log
journalctl -u tvbox-firstboot -b # same service, journal view
ls /var/lib/tvbox-firstboot.done # exists = finished OK
sudo systemctl start tvbox-firstboot   # re-run after fixing a failure
```
`tvbox.local` needs mDNS (built into macOS/Linux/Windows 10+). If it doesn't resolve, use the IP from the router.

## CachyOS (Arch) route
For CachyOS there is no subiquity seed: the ISO is loopback-booted from the stick and the install itself is scripted.

**1. Build the stick** — an already-mounted FAT32 stick that has `boot/grub/grub.cfg` (a stick made by `build-usb.sh` keeps working):
```bash
autoinstall/build-usb-arch.sh --iso ~/Downloads/cachyos-*-x86_64.iso --target /mnt/usb   # [--sha256 HEX] [--yes]
```
It verifies the ISO (`--sha256`, or the `SHA256SUMS`/`SHA256` beside it), copies it to `cachyos/cachyos.iso` (loopback-booted, never extracted; FAT32 holds at most 4 GiB per file), detects the kernel/initramfs/microcode paths inside the ISO, and inserts a first GRUB entry **"CachyOS installer (TV box)"** into `boot/grub/grub.cfg`, keeping every existing entry and file. A stick carrying `md5sum.txt` gets it refreshed (the installer verifies the medium). Re-running is safe.

**2. Install** — boot the stick (`F12`, UEFI), SSH into the live ISO **as root**, and run `arch-install.sh` (from a clone of this repo; it needs its `arch/` helpers next to it):
```bash
TVBOX_WIFI_PASS='...' arch-install.sh --disk /dev/nvme0n1 --confirm-wipe /dev/nvme0n1 \
    --password-hash-file ~/.config/tvbox/password-hash --ssh-key-file ~/.ssh/tvbox_ed25519.pub \
    --user tvbox --wifi-ssid 'MyWifi' [--bundle tvbox.bundle] [--env-file tvbox-seed.env] [--dry-run]
```
Safety mirrors the Ubuntu route: nothing touches a disk unless `--confirm-wipe` names the very same device as `--disk`; removable/USB disks and the disk the running live system sits on are refused; `--dry-run` prints every command; the password hash (first line of the file, a `$6$` sha-512 crypt hash) and the Wi-Fi password travel in exported variables only — never on a command line.

What it does: enables the CachyOS repos, partitions the disk (GPT: 1 GiB EFI System Partition + btrfs labelled `tvbox` with subvolumes `@`, `@home`, `@var-log`, `@snapshots`, mounted `noatime,compress=zstd:1,space_cache=v2`), `pacstrap`s the base (`base`, `linux-cachyos` + headers, `amd-ucode`, `btrfs-progs`, `networkmanager`, `openssh`, `sudo`, `git`, `curl`, …; `nvidia-open-dkms` when `TVBOX_GPU=nvidia`), writes `fstab`, then runs `chroot.sh` inside `arch-chroot`: timezone/locale/keymap, hostname, the user (wheel, key-only SSH), the authorised key, Wi-Fi as a NetworkManager keyfile (mode 600), `systemd-boot` (entry `tvbox`, `root=LABEL=tvbox rootflags=subvol=@`), and a `tvbox-firstboot.service` that on first boot clones `/opt/tvbox` from the bundle (falling back to downloading `bootstrap.sh`) and runs it with `TVBOX_NONINTERACTIVE=1` — the same setup as the Ubuntu path, same `/var/log/tvbox-firstboot.log` and `/var/lib/tvbox-firstboot.done` marker. The desktop is Plasma Bigscreen (`plasma-bigscreen-wayland`; set `TVBOX_SESSION=plasma` to autologin into the plain Plasma desktop), with Steam (native, `[multilib]`), Sunshine and Moonlight among the optional packages. The repo's scripts are distro-aware (`PKG_FAMILY` = `debian`|`arch`), so `bootstrap.sh`/`setup.sh` run unchanged on the installed system.

## Not verified on real hardware
Written and unit-tested without a real install: `tests/usb.bats` builds a stick from a fake ISO that has the real
26.04.1 `grub.cfg` shape. Subiquity details (`match: {ssd: true}`, `late-commands`, `/cdrom` as the live medium
of an unpacked-ISO stick, Wi-Fi netplan) follow the Ubuntu docs and should be checked on the first real run
(a VM works: attach the stick as a USB disk, or `seed.iso` as a CD).
