# Connect any device in under a minute

The server shares two folders over SMB (server name `tvbox`, also `tvbox.local`, or its LAN IP):

| Share | What it is |
|---|---|
| **Uploads** | The inbox. Drop files here; they are sorted automatically. |
| **Cloud** | Your whole sorted library: Photos, Documents, Music, Videos, Recordings, Other, private. |

Log in with your **username + SMB password**. Replace `<domain>` below with your server's domain
(`TVBOX_DOMAIN`). If you only ever use LAN addresses you can skip the certificate steps.

## Windows
Double-click **`connect-windows.bat`**. Enter your login; `U:` = Uploads, `Z:` = Cloud (they reconnect after reboot).
With certificate: `connect-windows.bat -Domain <domain> -InstallCert`
(Server by IP: `-Server 192.168.1.50`.)

## Mac
Double-click **`connect-mac.command`** (first time: right-click > Open). Finder asks for the password — tick *Remember in keychain*.
With certificate and auto-reconnect: `./connect-mac.command -d <domain> -c -l`

## Linux
```bash
./connect-linux.sh                      # desktop: mounts via GVFS (file manager > Network)
./connect-linux.sh -d <domain> -c       # also install the root certificate (asks for sudo)
./connect-linux.sh -f                   # no desktop: writes ~/.config/tvbox-smb.cred (600) + prints the fstab recipe
```
Options: `-H <host-or-IP>`, `-u <user>`. Defaults come from `TVBOX_HOST` (else `tvbox.local`) and `TVBOX_DOMAIN`.

## Android
- Files: install **Material Files** or **Solid Explorer**, add an SMB server `tvbox` (or the IP), user + password.
- Certificate: download `https://setup.<domain>/root.crt` in the browser (accept the warning once) >
  *Settings > Security > Encryption & credentials > Install a certificate > CA certificate*.

## iPhone / iPad
- Files: *Files* app > `...` > **Connect to Server** > `smb://tvbox.local` (or `smb://<IP>`) > Registered User.
- Certificate: open `https://setup.<domain>/root.crt` in **Safari** > Allow > *Settings > Profile Downloaded > Install*.
  Then **Settings > General > About > Certificate Trust Settings** > switch the root on. (Both steps are required.)

## Phone apps
- **Immich** (photos): server URL `https://photos.<domain>` > log in > *Backup* > pick albums > enable.
- **Nextcloud** (files): server URL `https://files.<domain>` > log in.
  - **Auto-upload:** Nextcloud app > *Settings > Auto upload* (Android) / *Settings > Auto Upload* (iOS) >
    set the target folder to **`Uploads`** so new files get sorted automatically.

## Troubleshooting

| Problem | Fix |
|---|---|
| Cannot see `tvbox` | Use the server's LAN IP instead (`smb://192.168.x.x`, `-Server` / `-H` option). Make sure you are on the home Wi-Fi/LAN. |
| Browser/app says certificate is not trusted | Install `root.crt` (see above) and restart the browser/app. |
| "Access denied" / wrong password | Use the **SMB** password (can differ from the web login). Windows: `net use * /delete`, then re-run. |
| Windows: "multiple connections with different credentials" | Same fix: `net use * /delete`, run the script again. |
| Mac: nothing opens | Right-click the `.command` file > Open; check *System Settings > Privacy & Security*. |
| Linux: `gio mount` fails | Install `gvfs-backends`, or use `-f` for the fstab recipe (`cifs-utils`). |
| `setup.<domain>` not found | Your device is not using the server's Pi-hole DNS; connect to the home network or Tailscale. |
| Files dropped in Uploads vanish | They were sorted: look in `Cloud` (Photos, Documents, ...). |

Security note: `root.crt` lets this server vouch for HTTPS sites on your devices. Install it only from your own server, and compare the fingerprint the scripts print with the one on the server.
