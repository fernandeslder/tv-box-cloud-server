#!/usr/bin/env bash
# Build the autoinstall seed (user-data + meta-data [+ tvbox-seed.env]) and, if a
# tool is available, a seed.iso with volume label CIDATA. Never prints the password.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=$HERE/seed
ISO=$HERE/seed.iso
USERNAME_=""
KEY_FILE=""
WIFI_SSID=""
PASS_HASH=""
ENV_FILE=""
KEYBOARD="us"
TIMEZONE=""
PASS_HASH_FILE=""
BUILD_ISO=1

usage() {
  cat <<USAGE
Usage: $0 [options]   (anything not given is asked interactively)
  --user NAME            login user on the box
  --ssh-key-file FILE    public key(s), e.g. ~/.ssh/id_ed25519.pub (required: SSH is key-only)
  --wifi-ssid SSID       enable Wi-Fi; password asked, or set TVBOX_WIFI_PASS
  --password-hash-file F file whose first line is a sha-512 hash (e.g. from: mkpasswd -m sha-512 > F)
  --timezone ZONE        IANA zone, e.g. America/Moncton (default: this computer's zone)
  --password-hash HASH   ready-made sha-512 hash; otherwise the password is asked
                         (or set TVBOX_PASSWORD) and hashed locally
  --env-file FILE        pre-filled docker/.env, copied to the seed as tvbox-seed.env
  --keyboard LAYOUT      keyboard layout (default: us)
  --out DIR              output dir (default: $OUT)
  --no-iso               do not build seed.iso
  -h, --help
USAGE
}

die() { echo "error: $*" >&2; exit 1; }
need_arg() { [ "$#" -ge 2 ] || die "option $1 needs a value"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --user) need_arg "$@"; USERNAME_=$2; shift 2 ;;
    --ssh-key-file) need_arg "$@"; KEY_FILE=$2; shift 2 ;;
    --wifi-ssid) need_arg "$@"; WIFI_SSID=$2; shift 2 ;;
    --password-hash) need_arg "$@"; PASS_HASH=$2; shift 2 ;;
    --password-hash-file) need_arg "$@"; PASS_HASH_FILE=$2; shift 2 ;;
    --timezone) need_arg "$@"; TIMEZONE=$2; shift 2 ;;
    --env-file) need_arg "$@"; ENV_FILE=$2; shift 2 ;;
    --keyboard) need_arg "$@"; KEYBOARD=$2; shift 2 ;;
    --out) need_arg "$@"; OUT=$2; shift 2 ;;
    --no-iso) BUILD_ISO=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

interactive() { [ -t 0 ]; }

if [ -z "$USERNAME_" ]; then
  interactive || die "--user is required when not running on a terminal"
  read -r -p "Username on the box [tvbox]: " USERNAME_
  USERNAME_=${USERNAME_:-tvbox}
fi
[[ $USERNAME_ =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid username: $USERNAME_"

if [ -z "$KEY_FILE" ]; then
  interactive || die "--ssh-key-file is required when not running on a terminal"
  read -r -e -p "SSH public key file [$HOME/.ssh/id_ed25519.pub]: " KEY_FILE
  KEY_FILE=${KEY_FILE:-$HOME/.ssh/id_ed25519.pub}
fi
[ -r "$KEY_FILE" ] || die "cannot read SSH key file: $KEY_FILE (create one with: ssh-keygen -t ed25519)"

# YAML single-quote escaping
q() { printf '%s' "${1//\'/\'\'}"; }

KEYS=""
while IFS= read -r line; do
  [[ $line =~ ^(ssh-|ecdsa-|sk-) ]] || continue
  KEYS+="$(q "$line")"$'\n'
done < "$KEY_FILE"
KEYS=${KEYS%$'\n'}
[ -n "$KEYS" ] || die "no public key found in $KEY_FILE (must be the .pub file, not the private key)"

hash_password() {
  if command -v mkpasswd >/dev/null 2>&1; then
    mkpasswd -m sha-512 -s
  elif command -v openssl >/dev/null 2>&1; then
    openssl passwd -6 -stdin
  elif python3 -W ignore -c 'import crypt' >/dev/null 2>&1; then
    python3 -W ignore -c 'import crypt, sys; print(crypt.crypt(sys.stdin.readline().rstrip("\n"), crypt.mksalt(crypt.METHOD_SHA512)))'
  else
    return 1
  fi
}

if [ -z "$PASS_HASH" ] && [ -n "$PASS_HASH_FILE" ]; then
  [ -r "$PASS_HASH_FILE" ] || die "cannot read password hash file: $PASS_HASH_FILE"
  PASS_HASH=$(head -n1 "$PASS_HASH_FILE" | tr -d '\r\n')
fi
if [ -z "$TIMEZONE" ]; then
  TIMEZONE=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  [ -n "$TIMEZONE" ] || TIMEZONE=$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##' || true)
  [ -n "$TIMEZONE" ] || TIMEZONE=UTC
fi
[[ $TIMEZONE =~ ^[A-Za-z0-9_+/-]+$ ]] || die "invalid timezone: $TIMEZONE"
if [ -z "$PASS_HASH" ]; then
  PW=${TVBOX_PASSWORD:-}
  if [ -z "$PW" ]; then
    interactive || die "set --password-hash or TVBOX_PASSWORD when not on a terminal"
    read -r -s -p "Password for $USERNAME_ (console login / sudo): " PW; echo
    read -r -s -p "Repeat password: " PW2; echo
    [ "$PW" = "$PW2" ] || die "passwords do not match"
  fi
  [ -n "$PW" ] || die "empty password"
  PASS_HASH=$(printf '%s\n' "$PW" | hash_password) || die "need mkpasswd (apt install whois), openssl or python3 to hash the password"
  unset PW PW2
fi
[[ $PASS_HASH =~ ^\$[0-9a-z]+\$ ]] || die "password hash does not look like a crypt hash (\$6\$...)"

WIFI_PASS=""
if [ -z "$WIFI_SSID" ] && interactive; then
  read -r -p "Wi-Fi SSID (empty = ethernet only): " WIFI_SSID
fi
if [ -n "$WIFI_SSID" ]; then
  WIFI_PASS=${TVBOX_WIFI_PASS:-}
  if [ -z "$WIFI_PASS" ]; then
    interactive || die "set TVBOX_WIFI_PASS when not on a terminal"
    read -r -s -p "Wi-Fi password: " WIFI_PASS; echo
  fi
fi

[ -z "$ENV_FILE" ] || [ -r "$ENV_FILE" ] || die "cannot read env file: $ENV_FILE"

mkdir -p "$OUT"
chmod 700 "$OUT"
rm -f "$OUT/user-data" "$OUT/meta-data" "$OUT/tvbox-seed.env"

V_USERNAME=$(q "$USERNAME_") V_HASH=$(q "$PASS_HASH") V_KEYS=$KEYS V_KBD=$(q "$KEYBOARD") V_TZ=$(q "$TIMEZONE") \
V_WSSID=$(q "$WIFI_SSID") V_WPASS=$(q "$WIFI_PASS") V_WIFI=$([ -n "$WIFI_SSID" ] && echo 1 || echo 0) \
awk '
function rep(s, key, val,   i, o) {
  o = ""
  while ((i = index(s, key)) > 0) { o = o substr(s, 1, i - 1) val; s = substr(s, i + length(key)) }
  return o s
}
{
  line = $0
  if (ENVIRON["V_WIFI"] == "1") {
    if (substr(line, 1, 4) == "#W# ") line = substr(line, 5)
    line = rep(line, "@@WIFI_SSID@@", ENVIRON["V_WSSID"])
    line = rep(line, "@@WIFI_PASS@@", ENVIRON["V_WPASS"])
  }
  line = rep(line, "@@USERNAME@@", ENVIRON["V_USERNAME"])
  line = rep(line, "@@PASSWORD_HASH@@", ENVIRON["V_HASH"])
  line = rep(line, "@@KEYBOARD@@", ENVIRON["V_KBD"])
  line = rep(line, "@@TIMEZONE@@", ENVIRON["V_TZ"])
  if (index(line, "@@SSH_KEY@@") > 0) {
    n = split(ENVIRON["V_KEYS"], k, "\n")
    for (j = 1; j <= n; j++) print rep(line, "@@SSH_KEY@@", k[j])
    next
  }
  print line
}' "$HERE/user-data" > "$OUT/user-data"

cp "$HERE/meta-data" "$OUT/meta-data"
FILES=(user-data meta-data)
if [ -n "$ENV_FILE" ]; then
  install -m 600 "$ENV_FILE" "$OUT/tvbox-seed.env"
  FILES+=(tvbox-seed.env)
fi
chmod 600 "$OUT"/*

if grep -v '^[[:space:]]*#' "$OUT/user-data" | grep -q '@@'; then
  die "unfilled placeholders left in $OUT/user-data"
fi

echo "Seed written to: $OUT (${FILES[*]})"

if [ "$BUILD_ISO" = 1 ]; then
  rm -f "$ISO"
  if command -v genisoimage >/dev/null 2>&1; then
    (cd "$OUT" && genisoimage -quiet -output "$ISO" -volid CIDATA -joliet -rock "${FILES[@]}")
  elif command -v xorriso >/dev/null 2>&1; then
    (cd "$OUT" && xorriso -as genisoimage -quiet -output "$ISO" -volid CIDATA -joliet -rock "${FILES[@]}")
  elif command -v cloud-localds >/dev/null 2>&1; then
    cloud-localds "$ISO" "$OUT/user-data" "$OUT/meta-data"
    [ -z "$ENV_FILE" ] || echo "warning: cloud-localds cannot add tvbox-seed.env to the ISO; use the USB-folder route instead" >&2
  else
    echo "No ISO tool found (apt install genisoimage). The folder alone is enough: copy its files to a FAT32 USB stick labelled CIDATA." >&2
    BUILD_ISO=0
  fi
  if [ "$BUILD_ISO" = 1 ]; then
    chmod 600 "$ISO"
    echo "Seed ISO written to: $ISO (volume label CIDATA)"
  fi
fi

echo "These files contain your password hash${ENV_FILE:+ and secrets}: keep the seed private. Next steps: see $HERE/README.md"
