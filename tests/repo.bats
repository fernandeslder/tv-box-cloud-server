load helpers
@test "no script or unit hardcodes the old 'htpc' user" {
  ! grep -rIl --exclude-dir=.git --exclude-dir=docs --exclude=repo.bats -e '/home/htpc' -e 'User=htpc' "$REPO"
}
@test "every shell script passes shellcheck" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"
  cd "$REPO"; mapfile -t f < <(git ls-files '*.sh' 'scripts/tvbox' 'clients/*.command' 'legion/*.sh' 'autoinstall/*.sh'; ls setup.sh bootstrap.sh)
  run shellcheck -x "${f[@]}"; [ "$status" -eq 0 ] || { echo "$output"; false; }
}
@test "every shell script is executable" {
  cd "$REPO"; for f in setup.sh bootstrap.sh scripts/*.sh scripts/tvbox backups/*.sh; do [ -x "$f" ] || { echo "not executable: $f"; false; }; done
}
@test "systemd templates only use known placeholders" {
  ! grep -ohE '@[A-Z_]+@' "$REPO"/configs/systemd/* | sort -u | grep -vE '^@(REPO|USER|POOL)@$'
}
@test "secrets files are git-ignored" {
  cd "$REPO"; for f in docker/.env configs/router.conf configs/router.managed.conf docker/ml-laptop/.env docker/net/data/x; do git check-ignore -q "$f" || { echo "$f not ignored"; false; }; done
}
@test "all scripts bash -n" { cd "$REPO"; for f in scripts/*.sh scripts/tvbox backups/*.sh setup.sh bootstrap.sh; do bash -n "$f"; done; }
@test "desktop: a Plasma session file is installed and SDDM is told to use Wayland + KWin (no Xorg here)" {
  grep -q 'apt_install plasma-desktop plasma-session-wayland' "$REPO/scripts/20-desktop-htpc.sh"
  grep -q 'DisplayServer=wayland' "$REPO/scripts/20-desktop-htpc.sh"
  grep -q 'CompositorCommand=kwin_wayland' "$REPO/scripts/20-desktop-htpc.sh"
  grep -q 'Session=plasma.desktop' "$REPO/scripts/20-desktop-htpc.sh"
}
@test "boot does not wait for NICs that are unplugged" {
  grep -q -- '--any' "$REPO/configs/systemd/networkd-wait-any.conf"
  grep -q 'networkd-wait-any.conf' "$REPO/scripts/50-network-dns.sh"
}
