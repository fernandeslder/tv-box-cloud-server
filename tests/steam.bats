load helpers
setup() {
  mk_tmp
  export TVBOX_STEAM_RUNNING=0
  S="$T/Steam"; mkdir -p "$S/userdata/12345678/config"
  P="$REPO/scripts/tv-steam-shortcuts.py"
}
teardown() { rm -rf "$T"; }

# print "name|tags|exe|launch" for every shortcut in a shortcuts.vdf, using the script's own reader
show() {
  python3 -I - "$REPO/scripts/tv-steam-shortcuts.py" "$1" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("tv", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
tree = m.vdf_loads(open(sys.argv[2], "rb").read())
for k in sorted(tree["shortcuts"], key=int):
    e = tree["shortcuts"][k]
    print("%s|%s|%s|%s|%d" % (e["AppName"], ",".join(e["tags"][i] for i in sorted(e["tags"])), e["Exe"], e["LaunchOptions"], e["appid"] & 0xFFFFFFFF))
PY
}

@test "dry run lists every tile and writes nothing" {
  run "$P" --steam-dir "$S" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"10 tiles written"* ]]; [[ "$output" == *"YouTube"* ]]; [[ "$output" == *"PC Games"* ]]
  [ ! -e "$S/userdata/12345678/config/shortcuts.vdf" ]
}
@test "apply writes shortcuts.vdf that reads back, with host commands, tags and artwork" {
  run "$P" --steam-dir "$S"; [ "$status" -eq 0 ]
  f="$S/userdata/12345678/config/shortcuts.vdf"
  out=$(show "$f")
  [[ "$out" == *'YouTube|TV Apps|"/usr/bin/flatpak-spawn"|--host flatpak run rocks.shy.VacuumTube|'* ]]
  [[ "$out" == *'PC Games|TV Apps,PC Games|'* ]]
  [[ "$out" == *'stream 192.168.2.20 "Steam Big Picture" --4K --fps 60 --video-codec HEVC'* ]]
  # every id has the non-Steam high bit and its artwork next to it
  while IFS='|' read -r name tags exe launch id; do
    [ "$id" -ge 2147483648 ]
    [ -f "$S/userdata/12345678/config/grid/$id.png" ]; [ -f "$S/userdata/12345678/config/grid/${id}p.png" ]
  done <<< "$out"
}
@test "the file is valid for an independent VDF reader too" {
  python3 -c 'import vdf' 2>/dev/null || skip "python vdf module not installed"
  "$P" --steam-dir "$S" >/dev/null
  run python3 -I -c "
import vdf, sys
d = vdf.binary_loads(open(sys.argv[1], 'rb').read())
sc = d['shortcuts']
assert len(sc) == 10, len(sc)
assert sc['0']['AppName'] == 'YouTube' and sc['0']['tags']['0'] == 'TV Apps'
print('ok')" "$S/userdata/12345678/config/shortcuts.vdf"
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}
@test "running it again updates in place (no duplicates) and keeps a backup" {
  "$P" --steam-dir "$S" >/dev/null; "$P" --steam-dir "$S" >/dev/null
  f="$S/userdata/12345678/config/shortcuts.vdf"
  [ "$(show "$f" | wc -l)" -eq 10 ]
  [ -f "$f.bak-tvbox" ]
}
@test "shortcuts the user already added are kept" {
  python3 -I - "$REPO/scripts/tv-steam-shortcuts.py" "$S/userdata/12345678/config/shortcuts.vdf" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("tv", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
mine = m.build_entry({"name": "My Own Thing", "cmd": "true", "tags": []}, "")
open(sys.argv[2], "wb").write(m.vdf_dumps({"shortcuts": {"0": mine}}))
PY
  run "$P" --steam-dir "$S"; [ "$status" -eq 0 ]
  [[ "$output" == *"1 existing kept"* ]]
  show "$S/userdata/12345678/config/shortcuts.vdf" | grep -q '^My Own Thing|'
}
@test "refuses while Steam is running (it would overwrite the file on exit); --force overrides" {
  TVBOX_STEAM_RUNNING=1 run "$P" --steam-dir "$S"; [ "$status" -eq 3 ]; [[ "$output" == *"Steam is running"* ]]
  [ ! -e "$S/userdata/12345678/config/shortcuts.vdf" ]
  TVBOX_STEAM_RUNNING=1 run "$P" --steam-dir "$S" --force; [ "$status" -eq 0 ]
}
@test "says what to do when Steam has never been signed in" {
  rm -rf "$S/userdata"
  run "$P" --steam-dir "$S"; [ "$status" -eq 2 ]; [[ "$output" == *"start Steam once and sign in"* ]]
}
@test "every tile in the spec has its two artwork files and no leftover placeholders" {
  run python3 -I - "$REPO" <<'PY'
import json, os, re, sys
repo = sys.argv[1]; spec = json.load(open(repo + "/configs/steam/tv-apps.json"))
for a in spec["apps"]:
    for suffix in (".png", "_p.png"):
        assert os.path.exists("%s/configs/steam/art/%s%s" % (repo, a["art"], suffix)), (a["name"], suffix)
    left = re.findall(r"\{[a-z_]+\}", a["cmd"].replace("{pc_host}", ""))
    assert not left, (a["name"], left)
assert len({a["name"] for a in spec["apps"]}) == len(spec["apps"]), "duplicate tile names"
print("ok")
PY
  [ "$status" -eq 0 ]
}
