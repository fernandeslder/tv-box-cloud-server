#!/usr/bin/env bash
# conf-load.sh — load KEY=VALUE files as DATA, never as code (no source/eval).
# Only UPPER_CASE keys; surrounding single/double quotes stripped; $(...) and `...` stay literal.
load_conf() {  # load_conf <file>
  local f="$1" line k v
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    [[ "$k" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
    v="${v%%[[:space:]]#*}"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    export "$k=$v"
  done < "$f"
}
