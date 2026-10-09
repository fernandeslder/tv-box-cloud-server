# Rendered by scripts/render-config.sh — edit the template, not /etc/samba/smb.conf.
[global]
   server string = TV Box
   netbios name = @NETBIOS@
   workgroup = WORKGROUP
   server role = standalone server
   security = user
   map to guest = never
   # Private ranges only (Tailscale subnet routing arrives from the LAN side).
   hosts allow = 127.0.0.1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10
   hosts deny = 0.0.0.0/0
   server min protocol = SMB2
   smb encrypt = desired
   disable netbios = yes
   # Fast on gigabit, friendly to mergerfs.
   use sendfile = yes
   aio read size = 1
   aio write size = 1
   # macOS (Finder, Time-Machine-free) compatibility
   vfs objects = fruit streams_xattr
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:nfs_aces = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes
   log file = /var/log/samba/log.%m
   max log size = 1000

[Uploads]
   comment = Drop files here: they are sorted automatically
   path = @POOL@/inbox
   valid users = @USER@
   read only = no
   browseable = yes
   force user = @USER@
   force group = www-data
   create mask = 0664
   directory mask = 2775

[Cloud]
   comment = Everything: Photos, Documents, Music, Videos, Recordings, private
   path = @POOL@
   valid users = @USER@
   read only = no
   browseable = yes
   force user = @USER@
   force group = www-data
   create mask = 0664
   directory mask = 2775
   veto files = /.ai-queue/immich/nextcloud-data/backups-staging/lost+found/
   delete veto files = no

[Paperless]
   comment = Drop scans and PDFs here: Paperless-ngx OCRs and files them (optional profile)
   path = @POOL@/paperless/consume
   valid users = @USER@
   read only = no
   browseable = yes
   force user = @USER@
   force group = www-data
   create mask = 0664
   directory mask = 2775
