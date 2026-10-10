#!/usr/bin/env python3
"""Put the TV-app tiles (and the "PC Games" streaming tile) into Steam as non-Steam shortcuts.

Run it ON THE BOX, after Steam has been started once and signed in (that creates the account's
userdata folder), with Steam CLOSED (Steam rewrites shortcuts.vdf on exit and would undo the change):

    python3 /opt/tvbox/scripts/tv-steam-shortcuts.py            # apply
    python3 /opt/tvbox/scripts/tv-steam-shortcuts.py --dry-run  # show what it would do

What it does
  * reads configs/steam/tv-apps.json (names, host commands, tags, artwork slug)
  * adds/updates those entries in <steam>/userdata/<id>/config/shortcuts.vdf, keeps every other entry,
    and writes a shortcuts.vdf.bak-tvbox backup first
  * copies the artwork from configs/steam/art/ to <steam>/userdata/<id>/config/grid/ under the
    shortcut's app id (<id>.png wide capsule, <id>p.png portrait capsule)
  * every command goes through `flatpak-spawn --host` because the Steam Flatpak is sandboxed

Idempotent: running it again updates the same entries instead of adding duplicates.
"""
import argparse
import json
import os
import shutil
import struct
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_SPEC = os.path.join(REPO, "configs", "steam", "tv-apps.json")
DEFAULT_ART = os.path.join(REPO, "configs", "steam", "art")
FLATPAK_STEAM = os.path.expanduser("~/.var/app/com.valvesoftware.Steam/.local/share/Steam")
SPAWN = "/usr/bin/flatpak-spawn"


# ---- binary VDF (the format of shortcuts.vdf) -------------------------------------------------
def vdf_loads(data):
    pos = 0

    def cstr():
        nonlocal pos
        end = data.index(b"\x00", pos)
        s = data[pos:end].decode("utf-8", "replace")
        pos = end + 1
        return s

    def parse_map():
        nonlocal pos
        out = {}
        while pos < len(data):
            t = data[pos]
            pos += 1
            if t == 8:
                return out
            key = cstr()
            if t == 0:
                out[key] = parse_map()
            elif t == 1:
                out[key] = cstr()
            elif t == 2:
                out[key] = struct.unpack_from("<i", data, pos)[0]
                pos += 4
            else:
                raise ValueError("unsupported VDF type %d at byte %d" % (t, pos - 1))
        return out

    return parse_map()


def vdf_dumps(root):
    out = bytearray()

    def write_map(m):
        for k, v in m.items():
            if isinstance(v, dict):
                out.append(0)
                out.extend(k.encode() + b"\x00")
                write_map(v)
                out.append(8)
            elif isinstance(v, int):
                out.append(2)
                out.extend(k.encode() + b"\x00")
                out.extend(struct.pack("<i", ((v + 2**31) % 2**32) - 2**31))
            else:
                out.append(1)
                out.extend(k.encode() + b"\x00" + str(v).encode() + b"\x00")

    write_map(root)
    out.append(8)
    return bytes(out)


# ---- shortcuts ---------------------------------------------------------------------------------
def shortcut_appid(exe_quoted, name):
    """Steam's id for a non-Steam shortcut (also the artwork file name)."""
    return (zlib.crc32((exe_quoted + name).encode("utf-8")) & 0xFFFFFFFF) | 0x80000000


def build_entry(app, pc_host):
    exe = '"%s"' % SPAWN
    cmd = app["cmd"].replace("{pc_host}", pc_host)
    return {
        "appid": shortcut_appid(exe, app["name"]),
        "AppName": app["name"],
        "Exe": exe,
        "StartDir": '"%s/"' % os.path.dirname(SPAWN),
        "icon": "",
        "ShortcutPath": "",
        "LaunchOptions": "--host " + cmd,
        "IsHidden": 0,
        "AllowDesktopConfig": 1,
        "AllowOverlay": 1,
        "OpenVR": 0,
        "Devkit": 0,
        "DevkitGameID": "",
        "DevkitOverrideAppID": 0,
        "LastPlayTime": 0,
        "FlatpakAppID": "",
        "tags": {str(i): t for i, t in enumerate(app.get("tags", []))},
    }


def entry_name(entry):
    for k, v in entry.items():
        if k.lower() == "appname":
            return v
    return None


def merge(existing, wanted):
    """existing: list of entry dicts (kept in order); wanted: entries to add or replace by name."""
    by_name = {e["AppName"]: e for e in wanted}
    out = []
    seen = set()
    for e in existing:
        n = entry_name(e)
        if n in by_name:
            out.append(by_name[n])
            seen.add(n)
        else:
            out.append(e)
    for e in wanted:
        if e["AppName"] not in seen:
            out.append(e)
    return out


def steam_running():
    forced = os.environ.get("TVBOX_STEAM_RUNNING")
    if forced is not None:
        return forced == "1"
    try:
        ps = subprocess.run(["flatpak", "ps", "--columns=application"], capture_output=True, text=True, timeout=15)
        if "com.valvesoftware.Steam" in ps.stdout:
            return True
    except (OSError, subprocess.SubprocessError):
        pass
    return subprocess.run(["pgrep", "-x", "steam"], capture_output=True).returncode == 0


def find_config_dir(steam_dir, user):
    ud = os.path.join(steam_dir, "userdata")
    if not os.path.isdir(ud):
        return None, "Steam has not created %s yet: start Steam once and sign in, then close it and run this again." % ud
    users = sorted(d for d in os.listdir(ud) if d.isdigit() and d != "0")
    if user:
        users = [u for u in users if u == str(user)]
    if not users:
        return None, "no signed-in Steam account found under %s (sign in first)." % ud
    if len(users) > 1:
        users.sort(key=lambda u: os.path.getmtime(os.path.join(ud, u)), reverse=True)
        print("note: several accounts found, using the most recent: %s (use --user to pick)" % users[0], file=sys.stderr)
    return os.path.join(ud, users[0], "config"), None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--steam-dir", default=os.environ.get("TVBOX_STEAM_DIR", FLATPAK_STEAM))
    ap.add_argument("--user", help="Steam account folder (the number under userdata/)")
    ap.add_argument("--spec", default=DEFAULT_SPEC)
    ap.add_argument("--art", default=DEFAULT_ART)
    ap.add_argument("--pc-host", help="override pc_host from the spec")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true", help="write even if Steam looks like it is running")
    a = ap.parse_args(argv)

    spec = json.load(open(a.spec, encoding="utf-8"))
    pc_host = a.pc_host or spec.get("pc_host", "")
    wanted = [build_entry(app, pc_host) for app in spec["apps"]]

    cfg, err = find_config_dir(a.steam_dir, a.user)
    if err:
        print("error: " + err, file=sys.stderr)
        return 2
    if steam_running() and not a.force and not a.dry_run:
        print("error: Steam is running. Close it completely (Steam menu > Exit), then run this again: "
              "it rewrites shortcuts.vdf when it quits and would undo the change.", file=sys.stderr)
        return 3

    vdf_path = os.path.join(cfg, "shortcuts.vdf")
    existing = []
    if os.path.exists(vdf_path) and os.path.getsize(vdf_path) > 0:
        tree = vdf_loads(open(vdf_path, "rb").read())
        sc = next((v for k, v in tree.items() if k.lower() == "shortcuts"), {})
        existing = [sc[k] for k in sorted(sc, key=lambda x: int(x) if x.isdigit() else 0)]
    merged = merge(existing, wanted)
    kept = len(existing) - sum(1 for e in existing if entry_name(e) in {w["AppName"] for w in wanted})
    print("Steam account folder: %s" % cfg)
    print("shortcuts: %d existing kept, %d tiles written (%d total)" % (kept, len(wanted), len(merged)))
    for w in wanted:
        print("  - %-24s %s" % (w["AppName"], w["LaunchOptions"][:100]))

    if a.dry_run:
        print("(dry run: nothing written)")
        return 0

    if os.path.exists(vdf_path):
        shutil.copy2(vdf_path, vdf_path + ".bak-tvbox")
    os.makedirs(cfg, exist_ok=True)
    tree = {"shortcuts": {str(i): e for i, e in enumerate(merged)}}
    with open(vdf_path, "wb") as f:
        f.write(vdf_dumps(tree))

    grid = os.path.join(cfg, "grid")
    os.makedirs(grid, exist_ok=True)
    copied = 0
    for app, w in zip(spec["apps"], wanted):
        slug = app.get("art")
        appid = w["appid"] & 0xFFFFFFFF
        for src_name, dst_name in ((slug + ".png", "%d.png" % appid), (slug + "_p.png", "%dp.png" % appid)):
            src = os.path.join(a.art, src_name) if slug else None
            if src and os.path.exists(src):
                shutil.copy2(src, os.path.join(grid, dst_name))
                copied += 1
    print("artwork: %d images copied to %s" % (copied, grid))
    print("Done. Start Steam / Big Picture: the tiles are in Library > Non-Steam, collections 'TV Apps' and 'PC Games'.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
