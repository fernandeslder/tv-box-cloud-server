load helpers
setup() {
  mk_tmp; export POOL_ROOT="$T/pool" AI_QUEUE_DIR="$T/pool/.ai-queue" INGEST_SETTLE_MIN=0
  mkdir -p "$T/inbox"
  # make Tier-0 deterministic: docker missing => scan-secrets exits 2 (UNSCANNED)
  export PATH="$T/bin:$PATH"; mkdir -p "$T/bin"; printf '#!/bin/sh\nexit 127\n' > "$T/bin/docker"; chmod +x "$T/bin/docker"
  hash -r
}
teardown() { rm -rf "$T"; }
mkf() { printf '%s' "$2" > "$T/inbox/$1"; old "$T/inbox/$1" "10 minutes ago"; }
@test "sorts by type and queues for AI" {
  mkf pic.jpg x; mkf song.mp3 y; mkf clip.mp4 z; mkf blob.xyz w
  run "$REPO/scripts/ingest.sh" "$T/inbox"; [ "$status" -eq 0 ]
  [ -f "$T/pool/Photos/pic.jpg" ]; [ -f "$T/pool/Music/song.mp3" ]; [ -f "$T/pool/Videos/clip.mp4" ]; [ -f "$T/pool/Other/blob.xyz" ]
  [ -f "$T/pool/.ai-queue/pic.jpg.pending" ]
}
@test "documents are sorted and a transcript is extracted" {
  mkf note.txt "buy milk and eggs"
  run "$REPO/scripts/ingest.sh" "$T/inbox"; [ -f "$T/pool/Documents/note.txt" ]
  grep -q milk "$T/pool/.ai-queue/note.txt.transcript"
}
@test "ID-like filenames go to private/ for ANY file type (stage-0 everywhere)" {
  mkf passport.jpg x; mkf "Bank Statement.pdf" "not really a pdf"
  run "$REPO/scripts/ingest.sh" "$T/inbox"
  [ -f "$T/pool/private/IDs/passport.jpg" ]
}
@test "files still being written are left alone" {
  printf data > "$T/inbox/fresh.jpg"
  INGEST_SETTLE_MIN=5 run "$REPO/scripts/ingest.sh" "$T/inbox"; [ -f "$T/inbox/fresh.jpg" ]
}
@test "sync-client temp files are ignored" {
  mkf upload.part x; run "$REPO/scripts/ingest.sh" "$T/inbox"; [ -f "$T/inbox/upload.part" ]
}
@test "nested upload folders are drained and removed" {
  mkdir -p "$T/inbox/2026/10"; printf x > "$T/inbox/2026/10/p.png"; old "$T/inbox/2026/10/p.png" "10 minutes ago"; old "$T/inbox/2026/10" "10 minutes ago"; old "$T/inbox/2026" "10 minutes ago"
  run "$REPO/scripts/ingest.sh" "$T/inbox"; [ -f "$T/pool/Photos/p.png" ]; [ ! -d "$T/inbox/2026" ]
}
@test "docx text is extracted (not OCR'd)" {
  d="$(mktemp -d)"; mkdir -p "$d/word"; echo '<w:t>quarterly budget</w:t>' > "$d/word/document.xml"; (cd "$d" && zip -qr "$T/inbox/r.docx" word); old "$T/inbox/r.docx" "10 minutes ago"
  run "$REPO/scripts/ingest.sh" "$T/inbox"; grep -q budget "$T/pool/.ai-queue/r.docx.transcript"; rm -rf "$d"
}
@test "a second concurrent run exits quietly" {
  mkdir -p "$T/pool/.ai-queue"; exec 8>"$T/pool/.ai-queue/.ingest.lock"; flock -n 8
  run "$REPO/scripts/ingest.sh" "$T/inbox"; [[ "$output" == *"already running"* ]]
}
