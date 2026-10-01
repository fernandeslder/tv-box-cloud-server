#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh; need_root
if ! have docker; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL -m 60 --retry 3 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update && apt_install docker-ce docker-ce-cli containerd.io docker-compose-plugin
  usermod -aG docker htpc || true
else
  log "docker already present, skipping"
fi
log "30-docker ok"
