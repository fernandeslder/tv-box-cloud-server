load helpers
@test "artist/album names cannot escape the Music folder" {
  mk_tmp; export POOL_ROOT="$T/pool"; mkdir -p "$T/pool"
  # exercise the sanitiser in isolation (same function body as sort-music.sh)
  eval "$(sed -n '/^# shellcheck disable=SC1003$/,/^}$/p' "$REPO/scripts/sort-music.sh" | tail -n +2)"
  [ "$(clean '../../etc')" = "__etc" ] || [ "$(clean '../../etc')" = ".._.._etc" ] || [[ "$(clean '../../etc')" != */* ]]
  [[ "$(clean '/abs/path')" != */* ]]
  [ "$(clean '..')" = "Unknown Artist" ]
  [ "$(clean '   ')" = "Unknown Artist" ]
  rm -rf "$T"
}
