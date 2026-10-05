# shellcheck shell=bash
REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
mk_tmp() { T="$(mktemp -d)"; export T; }
old() { touch -d "${2:-30 minutes ago}" "$1"; }   # old <file> [when]
