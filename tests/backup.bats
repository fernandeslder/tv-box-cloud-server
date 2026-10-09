load helpers
setup() {
  command -v restic >/dev/null || skip "restic not installed"
  mk_tmp
  export TVBOX_TEST_NOROOT=1 ENV_FILE="$T/env" TVBOX_ETC="$T/etc" TVBOX_STATE="$T/state" HDD_ROOT="$T/hdd" DISKS_CONF="$T/disks.conf"
  export RESTIC_REPO="$T/bk/restic" RESTIC_PASSWORD_FILE="$T/etc/restic-password"
  mkdir -p "$T/etc" "$T/pool/Documents" "$T/pool/Photos" "$T/cache"
  printf 'STORAGE_ROOT=%s\nCACHE_ROOT=%s\nBACKUP_INCLUDE="Documents Photos"\n' "$T/pool" "$T/cache" > "$ENV_FILE"
  echo secretpw > "$RESTIC_PASSWORD_FILE"
  for i in 1 2 3 4 5; do head -c 2000 /dev/urandom > "$T/pool/Documents/doc$i.bin"; done
  echo photo > "$T/pool/Photos/a.jpg"
  mkdir -p "$T/cache/db-dumps"; echo "select 1;" | gzip > "$T/cache/db-dumps/immich.sql.gz"
  # backup.sh would run `docker compose`: harmless here (no stack), it just skips the dumps.
}
teardown() { rm -rf "$T"; }

@test "backup creates a snapshot and a last-backup stamp" {
  run "$REPO/backups/backup.sh"; [ "$status" -eq 0 ]
  [ -f "$T/state/last-backup" ]
  run restic -r "$RESTIC_REPO" snapshots --json; [ "$status" -eq 0 ]; [[ "$output" == *'"tags":["nightly"]'* ]]
}
@test "verify passes on a healthy backup and stamps last-verify" {
  "$REPO/backups/backup.sh" >/dev/null
  run "$REPO/backups/verify.sh"; [ "$status" -eq 0 ]; [[ "$output" == *"byte-identical"* ]]
  [ -f "$T/state/last-verify" ]
}
@test "verify detects a file that no longer matches its snapshot copy" {
  "$REPO/backups/backup.sh" >/dev/null
  # Make the live file differ but keep it older than the snapshot, so it must be compared.
  for f in "$T"/pool/Documents/*.bin; do echo tamper >> "$f"; touch -d "2 hours ago" "$f"; done
  VERIFY_SAMPLE=50 run "$REPO/backups/verify.sh"; [ "$status" -ne 0 ]
  [[ "$output" == *"did not restore identically"* ]]
}
@test "verify fails loudly when there is no backup repo" {
  run "$REPO/backups/verify.sh"; [ "$status" -ne 0 ]
}
@test "verify rejects a corrupt database dump" {
  "$REPO/backups/backup.sh" >/dev/null
  echo "not gzip" > "$T/cache/db-dumps/immich.sql.gz"
  "$REPO/backups/backup.sh" >/dev/null
  run "$REPO/backups/verify.sh"; [ "$status" -ne 0 ]; [[ "$output" == *"corrupt"* ]]
}
