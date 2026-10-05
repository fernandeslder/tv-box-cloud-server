load helpers
setup() { mk_tmp; export POOL_ROOT="$T/pool"; mkdir -p "$T/in" "$T/dest"; }
teardown() { rm -rf "$T"; }
@test "moves into an empty destination" {
  echo a > "$T/in/x.txt"; run "$REPO/scripts/safe-move.sh" "$T/in/x.txt" "$T/dest"
  [ "$status" -eq 0 ]; [ "$(cat "$T/dest/x.txt")" = a ]; [ ! -e "$T/in/x.txt" ]
}
@test "same content goes to duplicates/, never overwrites" {
  echo a > "$T/dest/x.txt"; echo a > "$T/in/x.txt"
  run "$REPO/scripts/safe-move.sh" "$T/in/x.txt" "$T/dest"
  [[ "$output" == "$T/pool/duplicates/"* ]]; [ -f "$output" ]
}
@test "different content keeps both as 'name (1).ext'" {
  echo a > "$T/dest/x.txt"; echo b > "$T/in/x.txt"
  run "$REPO/scripts/safe-move.sh" "$T/in/x.txt" "$T/dest"
  [ "$output" = "$T/dest/x (1).txt" ]; [ "$(cat "$T/dest/x.txt")" = a ]; [ "$(cat "$T/dest/x (1).txt")" = b ]
}
