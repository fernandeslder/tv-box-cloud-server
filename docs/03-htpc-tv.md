# 03 — HTPC / TV Stack

Pattern: **Plasma desktop + Kodi 21 fullscreen as 10-foot home + standalone Flatpak apps** for what Kodi does badly.

## Install (Flatpak preferred — newer than apt)
```bash
flatpak install flathub org.xbmc.kodi com.moonlight_stream.Moonlight \
  com.stremio.Stremio rocks.shy.VacuumTube io.freetubeapp.FreeTube \
  com.github.KRTirtho.Spotube org.jellyfin.JellyfinDesktop
# IPTVnator: the Flathub id could not be confirmed (2026-10-10) -> find it with:  flatpak search iptv
sudo apt install -y hypnotix firefox mpv yt-dlp
```

## Per need
| Need | Pick | Notes |
|---|---|---|
| YouTube TV | **VacuumTube** (`rocks.shy.VacuumTube`) > Firefox `youtube.com/tv` | Skip Kodi YouTube addon unless you do the Google Cloud API-key + OAuth dance (quota/bot-check pain) |
| Twitch | Firefox + Kodi Twitch addon (anxdpanic) | Web + adblock is less fragile |
| Moonlight | **moonlight-qt** client; **Sunshine** on gaming PC | H.264/HEVC/AV1+HDR. Pair + Steam Big Picture as Sunshine app |
| Browser | Firefox (VA-API on AMD works OOTB) + uBlock + SponsorBlock | `mpv.conf: hwdec=vaapi vo=gpu` |
| IPTV | **IPTVnator** (M3U/Xtream/Stalker+EPG) > Hypnotix (`apt install hypnotix`) > Kodi IPTV Simple | Xtream provider needed for EPG/catchup |
| Stremio+Torrentio | Stremio v5 + `https://torrentio.strem.fun/manifest.json` + external mpv | Free path = plain P2P. Debrid services (RealDebrid/Torbox) are paid + proprietary — optional only, never required |
| Music | **Spotube** (open-source, no Premium needed) | Streams via YouTube sources; your own library lives in Navidrome (`docs/09`) |
| Local lib | Kodi + optional Jellyfin server in Docker | Jellyfin Desktop 2.0 = Qt6+mpv client |

`Torio` = **Torrentio** Stremio addon. No separate app.

## Kodi config
- Player > Videos: VA-API on, adjust refresh rate on start/stop.
- System > Audio: HDMI, passthrough on if AVR supports DTS/TrueHD else AC3 transcode.
- Services > Control: HTTP remote on (Kore app) + allow remote from other systems.

## Remotes — x86 has NO native HDMI-CEC
- Today, no dongle: **Kore** (Kodi) + **KDE Connect** (touchpad/keyboard) + Xbox/PS controller + $15 air-mouse for Stremio/browser.
- TV remote via HDMI: needs **Pulse-Eight USB-CEC (~$50)** + `libcec` + Kodi CEC peripheral setting. Cheap alt: FLIRC USB IR (~$25).
- Plasma Bigscreen (merged Plasma 6.7): watch, don't daily-drive — no Ubuntu package yet.

## Mesa note
Mesa 25 dropped VDPAU — use **VA-API everywhere**.

## One TV interface: Steam Big Picture (2026-10-10; replaces the Kodi-as-launcher attempt)
**Why not Kodi as the launcher:** on this box Kodi 21.3 (Ubuntu build) crashes in its native Wayland backend when an external app takes the
screen and gives it back (`wl_display_dispatch_pending: Invalid argument`, journald "Aborted (core dumped)"); forced onto X11
(`env -u WAYLAND_DISPLAY kodi`) it survives but logs "Failed to restart AudioEngine after return from external player" and loses audio.
Kodi is fine as a *player* (run it as its own app), not as the thing that launches the other apps.

**What is used instead:** Steam in Big Picture mode (Valve, updated weekly, controller/keyboard/mouse navigation), installed as the user Flatpak
`com.valvesoftware.Steam` (no i386 multiarch needed). Non-Steam shortcuts launch the host apps via
`flatpak-spawn --host flatpak run <app-id>` (the Steam Flatpak is given `--talk-name=org.freedesktop.Flatpak`).
`~/.config/autostart/tvbox-steam-bigpicture.desktop` starts it at login (`-tenfoot`); Plasma stays underneath as the fallback.
`configs/kodi/favourites.xml` is kept as a template if you want Kodi's tiles anyway.

### Apps in Steam Big Picture + "PC Games" streaming tile (2026-10-10)
`configs/steam/tv-apps.json` lists the tiles; `scripts/tv-steam-shortcuts.py` adds them to Steam as non-Steam shortcuts
(collection tag **TV Apps**; the streaming tiles also get **PC Games**) with artwork from `configs/steam/art/`.
Run it on the box after Steam has been started and signed in once, **with Steam closed**:
```bash
git -C /opt/tvbox pull --ff-only
python3 /opt/tvbox/scripts/tv-steam-shortcuts.py --dry-run   # what it would do
python3 /opt/tvbox/scripts/tv-steam-shortcuts.py             # write (backup: shortcuts.vdf.bak-tvbox)
```
- Games live on the PC. The **PC Games** tile runs `moonlight stream <pc> "Steam Big Picture"` (Sunshine on the PC, HEVC, hardware decode),
  so the PC's own Big Picture is what you browse for games; the box's library only holds the apps.
  **PC Games (Steam Link)** starts the Steam Link app instead. Edit `pc_host` and the Moonlight flags in the JSON (e.g. `--1080`).
- Pairing (once): `flatpak run com.moonlight_stream.Moonlight pair <pc-ip>` on the box, enter the printed PIN at https://localhost:47990 (PIN tab) on the PC.
