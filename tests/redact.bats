load helpers
r() { printf '%s' "$1" | "$REPO/scripts/redact.py"; }
@test "plain text passes through" { [ "$(r 'milk, eggs and a meeting on Tuesday')" = 'milk, eggs and a meeting on Tuesday' ]; }
@test "PEM private key blocks are removed" {
  out="$(r $'-----BEGIN RSA PRIVATE KEY-----\nMIIEabcDEF\n-----END RSA PRIVATE KEY-----\nafter')"
  [[ "$out" != *MIIE* ]]; [[ "$out" == *after* ]]
}
@test "provider key prefixes are removed" {
  out="$(r 'k1 AKIAIOSFODNN7EXAMPLE k2 ghp_abcdefghijklmnopqrstuvwxyz0123456789 k3 sk-abcdef1234567890ABCDEF')"
  [[ "$out" != *AKIA* && "$out" != *ghp_* && "$out" != *sk-abc* ]]
}
@test "password assignments and URL credentials are removed" {
  out="$(r 'password: hunter2 and https://bob:s3cret@example.com/x')"; [[ "$out" != *hunter2* && "$out" != *s3cret* ]]
}
@test "card-like digit runs are removed" { out="$(r 'card 4111 1111 1111 1111 ok')"; [[ "$out" != *4111* ]]; }
@test "high-entropy tokens are removed" { out="$(r 'blob Qm9vayBvZiBzZWNyZXRzIGFuZCB0aGluZ3MgZ29lcyBoZXJl end')"; [[ "$out" != *Qm9vayBv* ]]; }
@test "output is capped" { n="$(head -c 20000 /dev/zero | tr '\0' 'a' | sed 's/a/ab /g' | "$REPO/scripts/redact.py" 4000 | wc -c)"; [ "$n" -le 4000 ]; }
