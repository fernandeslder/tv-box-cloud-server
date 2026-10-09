load helpers
@test "every pinned container image exists in its registry (online; TVBOX_ONLINE_TESTS=1)" {
  [ -n "${TVBOX_ONLINE_TESTS:-}" ] || skip "online test: set TVBOX_ONLINE_TESTS=1"
  command -v docker >/dev/null || skip "no docker"
  run "$REPO/scripts/check-images.py"; echo "$output"; [ "$status" -eq 0 ]
}
@test "check-images --list names the stack's images offline" {
  command -v docker >/dev/null || skip "no docker"
  run "$REPO/scripts/check-images.py" --list; [ "$status" -eq 0 ]
  [[ "$output" == *"pihole/pihole:"* ]]; [[ "$output" == *"paperless-ngx:"* ]]; [[ "$output" == *"trufflesecurity/trufflehog:"* ]]
}
