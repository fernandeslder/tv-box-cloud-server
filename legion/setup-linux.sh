#!/usr/bin/env bash
# setup-linux.sh — one-command GPU worker setup for the Legion 7 on CachyOS/Arch
# (Ubuntu/Debian tolerated via apt). Idempotent: safe to re-run any time.
#
#   ./legion/setup-linux.sh                 # everything
#   ./legion/setup-linux.sh --no-models     # skip the ~10GB Ollama model pulls
#   TS_AUTHKEY=tskey-... ./legion/setup-linux.sh   # unattended Tailscale login
#   IMMICH_VERSION=v3.2.4 ./legion/setup-linux.sh  # must equal the TV box's version
#
# Does: Tailscale (hostname legion-linux) -> docker + NVIDIA container toolkit ->
# native Ollama (systemd override) -> firewall (tailnet + LAN only) -> models ->
# docker compose profiles photos+audio -> health table. Docs: docs/10-legion-ai-server.md
set -euo pipefail

HOSTNAME_TS="legion-linux"
PORTS=(11434 3003 9000)
MODELS=(qwen2.5:3b-instruct qwen2.5:7b-instruct moondream)
TAILNET_CIDR="100.64.0.0/10"
IMMICH_VERSION_DEFAULT="v3.2.4"
DO_MODELS=1

for arg in "$@"; do
  case "$arg" in
    --no-models) DO_MODELS=0 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="$REPO_DIR/docker/ml-laptop"
COMPOSE_FILE="$COMPOSE_DIR/compose.yml"

ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '! %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; }
step() { printf '\n== %s ==\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else
  have sudo || { fail "need root or sudo"; exit 1; }
  SUDO="sudo"
fi

[ -f "$COMPOSE_FILE" ] || { fail "compose file not found: $COMPOSE_FILE"; exit 1; }

if have pacman; then PM=pacman
elif have apt-get; then PM=apt
else fail "unsupported distro (need pacman or apt-get)"; exit 1; fi
ok "package manager: $PM; repo: $REPO_DIR"

APT_UPDATED=0
pkg_install() {  # pacman/apt package names are identical for every call site below
  if [ "$PM" = pacman ]; then
    $SUDO pacman -S --needed --noconfirm "$@"
  else
    if [ "$APT_UPDATED" -eq 0 ]; then $SUDO apt-get update -qq; APT_UPDATED=1; fi
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  fi
}

# ---------------------------------------------------------------- Tailscale
step "Tailscale"
if ! have tailscale; then
  if [ "$PM" = pacman ]; then pkg_install tailscale
  else curl -fsSL https://tailscale.com/install.sh | $SUDO sh; fi
fi
$SUDO systemctl enable --now tailscaled >/dev/null 2>&1 || true
TS_STATUS="$($SUDO tailscale status --json 2>/dev/null || true)"
if grep -q '"BackendState": *"Running"' <<<"$TS_STATUS"; then
  $SUDO tailscale set --hostname="$HOSTNAME_TS" >/dev/null 2>&1 || true
  ok "Tailscale already up; hostname ensured: $HOSTNAME_TS"
else
  if [ -n "${TS_AUTHKEY:-}" ]; then
    $SUDO tailscale up --hostname="$HOSTNAME_TS" --auth-key="$TS_AUTHKEY"
  else
    warn "no TS_AUTHKEY set: open the login URL below in a browser"
    $SUDO tailscale up --hostname="$HOSTNAME_TS"
  fi
  ok "Tailscale up as $HOSTNAME_TS"
fi

# ------------------------------------------------- NVIDIA + docker + toolkit
step "NVIDIA driver / Docker / container toolkit"
if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
  ok "NVIDIA driver: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -n1)"
else
  warn "nvidia-smi not working: install the NVIDIA driver (CachyOS: chwd -i pci-nvidia / nvidia-dkms), reboot, re-run"
fi

if ! have docker; then
  if [ "$PM" = pacman ]; then pkg_install docker docker-compose
  else pkg_install docker.io docker-compose-v2 || pkg_install docker.io docker-compose; fi
fi
if ! have nvidia-ctk; then
  if [ "$PM" = pacman ]; then
    pkg_install nvidia-container-toolkit
  else
    if [ ! -f /etc/apt/sources.list.d/nvidia-container-toolkit.list ]; then
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey |
        $SUDO gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
      curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' |
        $SUDO tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
      APT_UPDATED=0
    fi
    pkg_install nvidia-container-toolkit
  fi
fi
$SUDO systemctl enable --now docker >/dev/null 2>&1 || true
if ! grep -qs nvidia /etc/docker/daemon.json; then
  $SUDO nvidia-ctk runtime configure --runtime=docker >/dev/null
  $SUDO systemctl restart docker
  ok "Docker configured for NVIDIA runtime"
else
  ok "Docker already has the NVIDIA runtime"
fi
if have docker; then ok "docker: $(docker --version)"; else fail "docker missing"; exit 1; fi

if $SUDO docker compose version >/dev/null 2>&1; then DC=(docker compose)
elif have docker-compose; then DC=(docker-compose)
else fail "no docker compose (plugin or docker-compose) found"; exit 1; fi

# ------------------------------------------------------------------- Ollama
step "Ollama (native)"
if ! have ollama; then
  if [ "$PM" = pacman ]; then pkg_install ollama-cuda || curl -fsSL https://ollama.com/install.sh | $SUDO sh
  else curl -fsSL https://ollama.com/install.sh | $SUDO sh; fi
fi
OVERRIDE_DIR=/etc/systemd/system/ollama.service.d
OVERRIDE_WANT='[Service]
Environment="OLLAMA_HOST=0.0.0.0"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_KEEP_ALIVE=5m"'
OLLAMA_CHANGED=0
if [ "$($SUDO cat "$OVERRIDE_DIR/override.conf" 2>/dev/null || true)" != "$OVERRIDE_WANT" ]; then
  $SUDO mkdir -p "$OVERRIDE_DIR"
  printf '%s\n' "$OVERRIDE_WANT" | $SUDO tee "$OVERRIDE_DIR/override.conf" >/dev/null
  $SUDO systemctl daemon-reload
  OLLAMA_CHANGED=1
fi
$SUDO systemctl enable --now ollama >/dev/null 2>&1 || true
[ "$OLLAMA_CHANGED" -eq 1 ] && $SUDO systemctl restart ollama
ok "Ollama service enabled (OLLAMA_HOST=0.0.0.0, MAX_LOADED_MODELS=1, KEEP_ALIVE=5m)"

# ----------------------------------------------------------------- Firewall
step "Firewall (tailnet + LAN only)"
lan_cidr() {
  local dev
  dev="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  [ -n "$dev" ] && ip -4 route show dev "$dev" scope link 2>/dev/null | awk '$1 ~ /\// {print $1; exit}'
}
LAN="$(lan_cidr || true)"
SOURCES=("$TAILNET_CIDR")
[ -n "$LAN" ] && SOURCES+=("$LAN")

FW="none"
UFW_STATUS="$($SUDO ufw status 2>/dev/null || true)"
if have ufw && grep -q "Status: active" <<<"$UFW_STATUS"; then FW=ufw
elif have firewall-cmd && [ "$($SUDO systemctl is-active firewalld 2>/dev/null || true)" = active ]; then FW=firewalld
fi

case "$FW" in
  ufw)
    for src in "${SOURCES[@]}"; do
      for p in "${PORTS[@]}"; do
        $SUDO ufw allow from "$src" to any port "$p" proto tcp >/dev/null
      done
    done
    ok "ufw: ports ${PORTS[*]} open to ${SOURCES[*]}"
    ;;
  firewalld)
    for src in "${SOURCES[@]}"; do
      for p in "${PORTS[@]}"; do
        rule="rule family=\"ipv4\" source address=\"$src\" port port=\"$p\" protocol=\"tcp\" accept"
        $SUDO firewall-cmd --permanent --query-rich-rule="$rule" >/dev/null 2>&1 ||
          $SUDO firewall-cmd --permanent --add-rich-rule="$rule" >/dev/null
      done
    done
    $SUDO firewall-cmd --reload >/dev/null
    ok "firewalld: ports ${PORTS[*]} open to ${SOURCES[*]}"
    ;;
  *) warn "no active ufw/firewalld: skipping firewall (ports are NOT restricted by this script)" ;;
esac
[ -z "$LAN" ] && [ "$FW" != none ] && warn "could not detect LAN subnet: only the tailnet was allowed"

# Docker-published ports (3003/9000) bypass ufw/firewalld INPUT rules, so
# restrict them in DOCKER-USER too (re-evaluated at every boot).
if [ "$FW" != none ] && have iptables; then
  FWSCRIPT=/usr/local/sbin/legion-docker-fw.sh
  FWUNIT=/etc/systemd/system/legion-docker-fw.service
  $SUDO tee "$FWSCRIPT" >/dev/null <<EOF
#!/bin/sh
# Generated by legion/setup-linux.sh: limit Docker-published ports to tailnet + LAN.
LAN="\$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if(\$i=="dev"){print \$(i+1); exit}}')"
LAN="\$([ -n "\$LAN" ] && ip -4 route show dev "\$LAN" scope link | awk '\$1 ~ /\\// {print \$1; exit}')"
iptables -N LEGION-ML 2>/dev/null || iptables -F LEGION-ML
for src in 127.0.0.0/8 172.16.0.0/12 $TAILNET_CIDR \$LAN; do
  [ -n "\$src" ] && iptables -A LEGION-ML -s "\$src" -j RETURN
done
iptables -A LEGION-ML -j DROP
for p in 3003 9000; do
  iptables -C DOCKER-USER -p tcp -m conntrack --ctorigdstport "\$p" --ctdir ORIGINAL -j LEGION-ML 2>/dev/null ||
    iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport "\$p" --ctdir ORIGINAL -j LEGION-ML
done
EOF
  $SUDO chmod 755 "$FWSCRIPT"
  $SUDO tee "$FWUNIT" >/dev/null <<EOF
[Unit]
Description=Limit Docker-published Legion ML ports to tailnet + LAN
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$FWSCRIPT

[Install]
WantedBy=multi-user.target
EOF
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable legion-docker-fw.service >/dev/null 2>&1 || true
  # Applied after compose is up (DOCKER-USER chain exists once docker runs).
fi

# ------------------------------------------------------------------- Models
step "Ollama models"
wait_ollama() {
  local i
  for i in $(seq 1 30); do
    curl -sf -m 3 http://localhost:11434/api/tags >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}
if [ "$DO_MODELS" -eq 0 ]; then
  warn "--no-models: skipping model pulls"
elif ! wait_ollama; then
  fail "Ollama API not answering on :11434; skipping model pulls (check: journalctl -u ollama)"
else
  for m in "${MODELS[@]}"; do
    want="$m"; case "$m" in *:*) ;; *) want="$m:latest" ;; esac
    HAVE_MODELS="$(ollama list 2>/dev/null | awk 'NR>1{print $1}' || true)"
    if grep -qx "$want" <<<"$HAVE_MODELS"; then
      ok "model present: $m"
    else
      echo "… pulling $m"
      if ollama pull "$m"; then ok "pulled $m"; else fail "pull failed: $m"; fi
    fi
  done
fi

# ------------------------------------------------------------ Docker compose
step "Docker compose (profiles: photos + audio)"
ENV_FILE="$COMPOSE_DIR/.env"
if [ -n "${IMMICH_VERSION:-}" ]; then
  VER="$IMMICH_VERSION"
elif [ -f "$ENV_FILE" ] && grep -q '^IMMICH_VERSION=.' "$ENV_FILE"; then
  VER="$(grep '^IMMICH_VERSION=' "$ENV_FILE" | tail -n1 | cut -d= -f2-)"
else
  VER="$IMMICH_VERSION_DEFAULT"
  warn "IMMICH_VERSION not set: using $VER. It MUST match the TV box (docker/.env)"
fi
touch "$ENV_FILE"
if grep -q '^IMMICH_VERSION=' "$ENV_FILE"; then
  sed -i "s|^IMMICH_VERSION=.*|IMMICH_VERSION=$VER|" "$ENV_FILE"
else
  printf 'IMMICH_VERSION=%s\n' "$VER" >> "$ENV_FILE"
fi
ok "IMMICH_VERSION=$VER (saved in docker/ml-laptop/.env)"
if $SUDO "${DC[@]}" -f "$COMPOSE_FILE" --profile photos --profile audio up -d; then
  ok "compose up (immich-machine-learning :3003, whisper :9000)"
else
  fail "compose up failed (is the NVIDIA driver working? image pull ok?)"
fi
[ -f /usr/local/sbin/legion-docker-fw.sh ] && $SUDO systemctl restart legion-docker-fw.service &&
  ok "Docker-published ports restricted to tailnet + LAN"

# ------------------------------------------------------------- Health table
step "Health"
check() {  # name url tries
  local name="$1" url="$2" tries="${3:-1}" code i
  for i in $(seq 1 "$tries"); do
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" 2>/dev/null || true)"
    case "$code" in 2??|3??) printf '  ✓ %-18s %-40s HTTP %s\n' "$name" "$url" "$code"; return 0 ;; esac
    [ "$i" -lt "$tries" ] && sleep 5
  done
  printf '  ✗ %-18s %-40s %s\n' "$name" "$url" "${code:-no answer}"
  return 1
}
BAD=0
check "ollama"       http://localhost:11434/api/tags 3 || BAD=1
check "immich-ml"    http://localhost:3003/ping 12     || BAD=1
check "whisper"      http://localhost:9000/docs 12     || BAD=1
echo
if have tailscale; then echo "  tailscale ip: $(tailscale ip -4 2>/dev/null | head -n1)  name: $HOSTNAME_TS"; fi
if [ "$BAD" -eq 0 ]; then ok "all services healthy"
else warn "some services are not answering yet (first start downloads images/models; re-run to re-check)"; fi

cat <<EOF

NEXT STEP:
  In Immich admin (Administration → Settings → Machine Learning) set the URL to
  http://$HOSTNAME_TS:3003   (or set IMMICH_ML_URL=http://$HOSTNAME_TS:3003 on the TV box).
  Immich server on the TV box must run version $VER.
  Check from the TV box:  curl http://$HOSTNAME_TS:11434/api/tags
EOF
