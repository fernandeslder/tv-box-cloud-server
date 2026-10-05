load helpers
@test "config files are data: command substitution is not executed" {
  mk_tmp; printf 'FOO=$(touch %s/pwned)\nBAR="two words"\nlower=ignored\n# c\nBAZ=1 # trailing\n' "$T" > "$T/c"
  . "$REPO/scripts/conf-load.sh"; load_conf "$T/c"
  [ ! -e "$T/pwned" ]; [ "$BAR" = "two words" ]; [ "$BAZ" = 1 ]; [ -z "${lower:-}" ]
  rm -rf "$T"
}
