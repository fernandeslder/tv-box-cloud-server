# 01 — Flash Guide: from blank box to running services

You do this once (~1 hour, mostly waiting). While it runs, follow `docs/10-legion-ai-server.md` on the Legion 7.

**What you need:** an 8GB+ USB stick, another computer, ethernet cable, `ubuntu-26.04.1-live-server-amd64.iso` (any newer 26.04.x point release is fine; 24.04.x also works).
Keep the HDDs **disconnected** during the install so they can't be partitioned by mistake.

## Option A — one-stick zero-touch (recommended)
`autoinstall/build-usb.sh` turns a **FAT32 stick you already use** into the installer **without reformatting it**: it unpacks the Ubuntu ISO onto the stick, adds a boot entry "TV box: automated install", writes the autoinstall seed to `seed/` and a pinned copy of this repo to `tv-box/`. Your own files stay where they are.
```bash
# 1. a key for the box (private half stays on your PC) and a password hash (typed at the prompt, never stored in clear)
ssh-keygen -t ed25519 -f ~/.ssh/tvbox_ed25519 -C tvbox
mkdir -p ~/.config/tvbox && mkpasswd -m sha-512 > ~/.config/tvbox/password-hash      # whois package; or: openssl passwd -6
# 2. mount the stick read-write (FAT32), then build
TVBOX_WIFI_PASS='...' autoinstall/build-usb.sh --iso ubuntu-26.04.1-live-server-amd64.iso --target /mnt/usb \
    --ssh-key-file ~/.ssh/tvbox_ed25519.pub --password-hash-file ~/.config/tvbox/password-hash \
    --user tvbox --wifi-ssid 'MyWifi' --domain example.org
```
It verifies the ISO against `SHA256SUMS` (next to the ISO), refuses anything that is not a mounted FAT32 filesystem, and can be re-run (the boot entry is added once). `--no-seed` / `--seed-only` split the slow ISO unpack from the seed so a password can be added later.
No API tokens go on the stick: the first boot installs in local-CA mode and you paste tokens once with `sudo tvbox setup --reconfigure`.

3. Plug the stick + ethernet into the box, boot it (`F12` on Lenovo, UEFI), pick **TV box: automated install**.
4. **Confirm the disk** (NVMe only) — the one required click. The box **powers off** when the OS is installed: unplug the stick, press power.
5. First boot runs the setup by itself (20-40 min). Follow it: `ssh tvbox@tvbox.local` then `tail -f /var/log/tvbox-firstboot.log`. The checklist is also on the stick: `tv-box/FIRST-BOOT-CHECKLIST.txt`.

Boot options, other seed routes and troubleshooting: `autoinstall/README.md`.

## Option B — manual installer (screen by screen)
Boot the USB (UEFI entry) → `Try or Install Ubuntu Server`, then:
- **Language / keyboard / network:** defaults; DHCP is fine.
- **Storage:** "use entire disk" on the **238GB NVMe only** (LVM optional). Triple-check no HDD is selected.
- **Profile:** hostname `tvbox`, your username, a strong password.
- **SSH:** install OpenSSH server = **yes**; import/paste your `~/.ssh/id_ed25519.pub`.
- **Snaps:** select none.
- **Confirm** the destructive action and wait for the install to finish.
- **Reboot** and remove the USB when asked.
- **Connect:** `ssh <user>@tvbox.local` (or the IP from your router) and continue below.

## Option C — CachyOS (Arch)
Same one-stick idea, but the OS install is scripted instead of subiquity.

1. `autoinstall/build-usb-arch.sh --iso cachyos-*-x86_64.iso --target /mnt/usb [--sha256 HEX] [--yes]` copies the ISO onto the mounted FAT32 stick as `cachyos/cachyos.iso` (loopback-booted, never extracted) and puts a GRUB entry **"CachyOS installer (TV box)"** first in `boot/grub/grub.cfg`. The stick keeps its filesystem and files; the ISO is checksum-verified, the kernel/initramfs/microcode paths are detected inside the ISO, and the stick must already have `boot/grub/grub.cfg` (one FAT32 file cannot exceed 4 GiB).
2. Boot the stick (`F12`, UEFI), pick the CachyOS entry, then SSH into the live ISO **as root** and run `arch-install.sh` from a clone of this repo (it needs its `arch/` helpers next to it):
```bash
TVBOX_WIFI_PASS='...' arch-install.sh --disk /dev/nvme0n1 --confirm-wipe /dev/nvme0n1 \
    --password-hash-file ~/.config/tvbox/password-hash --ssh-key-file ~/.ssh/tvbox_ed25519.pub \
    --user tvbox --wifi-ssid 'MyWifi' [--bundle tvbox.bundle] [--env-file tvbox-seed.env] [--dry-run]
```
   Nothing touches a disk unless `--confirm-wipe` names the same device as `--disk`; removable/USB disks and the live system's own disk are refused. It writes GPT + a 1 GiB EFI partition + btrfs (subvolumes `@`, `@home`, `@var-log`, `@snapshots`), pacstraps the base with `linux-cachyos` and `amd-ucode`, and configures the chroot: hostname, user (wheel, key-only SSH), timezone, keymap, Wi-Fi and systemd-boot. `--dry-run` prints every command; the password hash and Wi-Fi password travel in variables, never on a command line.
3. First boot runs `bootstrap.sh` exactly like the Ubuntu path (`tvbox-firstboot.service`, same log and done-marker). The desktop is Plasma Bigscreen by default — set `TVBOX_SESSION=plasma` for the plain Plasma session; Steam (native), Sunshine and Moonlight install as optional extras.

## Run the setup
```bash
sudo apt update && sudo apt install -y git curl   # only if missing
curl -fsSL https://raw.githubusercontent.com/fernandeslder/tv-box-cloud-server/master/bootstrap.sh | sudo bash
```
This clones the repo to `/opt/tvbox` and starts the wizard (20-40 min, mostly downloads). It asks a few questions (domain, TV desktop, extras), **generates every password**, offers to format any blank USB disks (you type `ERASE` once), and ends by printing the address to open on your phone. Re-run safely any time: `cd /opt/tvbox && sudo ./setup.sh` (`--reconfigure` to be asked again).

**Unattended** (autoinstall, or `TVBOX_NONINTERACTIVE=1`): answers come from `/opt/tvbox-seed.env` (same keys as `docker/.env.example`, e.g. `DOMAIN`, `CF_API_TOKEN`, `TVBOX_DISKS=/dev/sdb:data,/dev/sdc:backup`). Without a `TVBOX_DISKS` line the installer never formats anything: it runs SSD-only and you add disks later with `sudo tvbox disks add /dev/sdX data`.

Human steps that always remain: confirm the install disk, approve the Tailscale subnet route + Split DNS, reserve the box's IP in the router and point the router's DNS at it (`docs/05`, `docs/08`).

## OS choice
**Ubuntu Server 26.04.1 LTS is recommended**: supported to 2031, current kernel/Mesa for the Ryzen iGPU, and Docker, Plasma 6, Kodi 21 and mergerfs are all packaged. Ubuntu 24.04 LTS, Debian 13 and Linux Mint 22 also work with the same setup (autoinstall is Ubuntu-only; use Option B there), and **CachyOS** (Arch) has its own scripted autoinstall (Option C). Never an immutable/image-based OS: the scripts expect a normal, changeable package-managed system.

## If you ever re-flash
Data survives on the USB disks. Recovery = install the OS, run the setup again (disks labelled `tvbox-*` are re-adopted automatically, not reformatted), then `tvbox restore databases` (`docs/08`).
