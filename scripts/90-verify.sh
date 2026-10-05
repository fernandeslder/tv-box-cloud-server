#!/usr/bin/env bash
# 90-verify.sh — kept for muscle memory: the real checks live in `tvbox doctor`.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tvbox" doctor "$@"
