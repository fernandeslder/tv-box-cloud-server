#!/usr/bin/env bash
# notify.sh <level> <message> — one place every script reports problems.
# Always appends to /var/log/tvbox-alerts.log; pushes to NTFY_URL (docker/.env) when set.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
level="${1:?usage: notify.sh <info|warn|error> <message>}"; shift
msg="$*"
{ printf '%s [%s] %s\n' "$(date -Is)" "$level" "$msg" >> "${TVBOX_ALERT_LOG:-/var/log/tvbox-alerts.log}"; } 2>/dev/null || true
url="$(env_get NTFY_URL)"
if [ -n "$url" ]; then
  curl -fsS -m 10 -H "Title: tvbox $level" -H "Priority: $([ "$level" = error ] && echo high || echo default)" -d "$msg" "$url" >/dev/null 2>&1 || true
fi
printf '%s: %s\n' "$level" "$msg" >&2
