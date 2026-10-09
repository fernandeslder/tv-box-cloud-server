#!/usr/bin/env bash
# 30-docker.sh — Docker CE + compose plugin, sane logging. Works on Ubuntu, Debian, Mint.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"; need_root
if ! have docker; then
  . /etc/os-release
  case "${ID_LIKE:-$ID} $ID" in *ubuntu*|*linuxmint*) dist=ubuntu; code="${UBUNTU_CODENAME:-$VERSION_CODENAME}" ;;
                                 *debian*) dist=debian; code="$VERSION_CODENAME" ;;
                                 *) die "unsupported distro $ID (need Ubuntu/Debian/Mint)" ;; esac
  # A brand-new release may not be in Docker's repo yet: fall back to the previous LTS codename.
  if ! curl -fsI -m 20 "https://download.docker.com/linux/$dist/dists/$code/Release" >/dev/null 2>&1; then
    fallback=noble; [ "$dist" = debian ] && fallback=bookworm
    warn "Docker has no repo for '$code' yet: using '$fallback'"
    code="$fallback"
  fi
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL -m 60 --retry 3 "https://download.docker.com/linux/$dist/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$dist $code stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq && apt_install docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin
else
  log "docker already present"
fi
if [ ! -f /etc/docker/daemon.json ]; then
  install -d /etc/docker
  printf '{\n  "log-driver": "local",\n  "log-opts": {"max-size": "10m", "max-file": "3"}\n}\n' > /etc/docker/daemon.json
fi
# Docker must start after the pool exists (containers bind-mount it).
install -Dm644 "$REPO_DIR/configs/systemd/docker-after-storage.conf" /etc/systemd/system/docker.service.d/tvbox-storage.conf
systemctl daemon-reload
systemctl enable --now docker >/dev/null 2>&1 || true
[ -n "$TVBOX_USER" ] && usermod -aG docker "$TVBOX_USER" || true
log "30-docker ok"
