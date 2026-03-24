# Storage

## bcachefs pool

- **Devices:** 2x HDD (data, mirrored) + 1x NVMe SSD (cache, durability 2)
- **Mount:** `/store` (via `bcachefs-store.service`)
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

### Measured performance

| Test | Speed |
|---|---|
| Sequential read (SSD cache) | 3,393 MB/s |
| Sequential write (SSD) | 2,345 MB/s |
| Random 4K read IOPS | 102,000 |
| Random 4K write IOPS | 618,000 |
| HDD sequential read | 256 MB/s |
| HDD sequential write | 249 MB/s |

---

## Samba shares

| Share | Path | Notes |
|---|---|---|
| media | `/store/media` | force user: st, 0644/0755 masks |
| st | `/store/st` | force user: st, 0600/0700 masks |
| data | `/store/data` | force user: st, 0600/0700 masks |
| tm | `/store/tm` | Time Machine, 4 TB max |

Config: SMB3 minimum, macOS fruit/AAPL extensions enabled, NetBIOS disabled.

Mac mounts: `smb://lab.local/media` → `/Volumes/media`
Linux symlinks: `/Volumes/media` → `/store/media`, `/Volumes/st` → `/store/st`

Full smb.conf and service configs: [system/post-install.md](system/post-install.md)

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

Install and backup cron setup: [system/post-install.md](system/post-install.md)
