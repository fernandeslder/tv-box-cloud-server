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

## One TV interface: Kodi + the FTV skin + app tiles (set up 2026-10-10)
Goal: a smart-TV-style home (left menu, poster rows, app tiles) instead of a desktop. Kodi stays the home screen; the apps open on top of it and
closing one drops you back to Kodi.
- **Skin:** `fTV` ("a skin based on the Fire TV UI", official Kodi 21 repo): Kodi > Settings > Interface > Skin > Skin > Get more > fTV. It pulls
  its helpers (skinshortcuts, skinvariables, TMDb Helper, ...) by itself. Arctic Horizon 2 is archived and not in the official repo.
- **App tiles:** `~/.kodi/userdata/favourites.xml` holds `System.Exec("flatpak run <app-id>")` entries (template: `configs/kodi/favourites.xml`;
  tile pictures go in `~/.kodi/userdata/tvbox-tiles/` and are referenced as `special://masterprofile/tvbox-tiles/<name>.png`). They show under
  *Favourites* in fTV and can be added to the home screen from the skin's menu editor.
- **Autostart:** `~/.config/autostart/tvbox-kodi.desktop` (`kodi -fs`) starts Kodi fullscreen at login; Plasma stays underneath as the fallback.
- **Not an exact copy of the r/kodi concept picture:** that is a mock-up (hero banner, rounded game tiles, weather card). fTV gives the same
  layout idea; the rest would need a custom skin.
