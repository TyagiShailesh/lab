# Storage

## bcachefs pool

- **Devices:** 2x HDD (data, mirrored) + 1x NVMe SSD (cache, durability 2)
- **Mount:** `/data` (primary), `/store` (bind)
- **Replication:** metadata 2, data 2
- **Compression:** none (foreground), zstd (background — applied during HDD migration)
- **Tiering:** writes land on SSD uncompressed at full NVMe speed (~2.5 GB/s), background-move to HDD with zstd; reads promote to SSD
  - `foreground_target: ssd`, `background_target: hdd`, `promote_target: ssd`, `metadata_target: ssd`
- **Capacity:** ~24 TB raw (14 TB usable after mirroring), 8.4 TB used

### Format command (reference)

```bash
bcachefs format \
  --label=hdd --durability=1 /dev/sda \
  --label=hdd --durability=1 /dev/sdb \
  --label=ssd --durability=2 /dev/nvme1n1 \
  --metadata_replicas=2 --data_replicas=2 \
  --compression=none --background_compression=zstd \
  --foreground_target=ssd --background_target=hdd \
  --promote_target=ssd --metadata_target=ssd
```

> SSD durability was originally 0, changed to 2 for full NVMe write speed.
> Durability is stored in the on-disk superblock — change live with:
> `echo 2 > /sys/fs/bcachefs/<uuid>/dev-2/durability`

### Mount command

```bash
mount -t bcachefs /dev/nvme1n1:/dev/sda:/dev/sdb -o version_upgrade=none /store
```

### Systemd service (`/etc/systemd/system/bcachefs-store.service`)

```ini
[Unit]
Description=Mount BcacheFS storage pool
Requires=dev-nvme1n1.device dev-sda.device dev-sdb.device systemd-modules-load.service
After=dev-nvme1n1.device dev-sda.device dev-sdb.device systemd-modules-load.service

[Service]
ExecStartPre=/sbin/modprobe bcachefs
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/sh -c 'mount -t bcachefs /dev/nvme1n1:/dev/sda:/dev/sdb -o version_upgrade=none /store'
ExecStop=/usr/bin/umount /store

[Install]
WantedBy=multi-user.target
```

---

## Samba shares

| Share | Path | Notes |
|---|---|---|
| media | `/store/media` | force user: st |
| st | `/store/st` | force user: st, 0600/0700 masks |
| data | `/store/data` | force user: st, 0600/0700 masks |
| tm | `/store/tm` | Time Machine, 4 TB max |

Config: SMB3 minimum, macOS fruit/AAPL extensions enabled, NetBIOS disabled.

Config file: `/etc/samba/smb.conf`

### Path mapping

Mac mounts shares individually. Linux has symlinks for Resolve path matching:

```
/Volumes/media → /store/media
/Volumes/st    → /store/st
```

Mac: `smb://lab.local/media` mounts at `/Volumes/media`

---

## PostgreSQL 18

Installed from official PGDG repo. Data on boot SSD.

```
Data:    /var/lib/postgresql/18/main/
Port:    5432
User:    resolve / resolve
Auth:    scram-sha-256 from 192.168.1.0/24
Backup:  /store/media/resolve/backup/ (nightly 3am, 30-day retention)
```
