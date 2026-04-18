# Storage

## bcachefs pool (`/store`)

**Full architecture, devices, systemd unit, kernel OOT module, and operational notes:** [bcachefs.md](bcachefs.md).

**At a glance:** four-device bcachefs — 2× Exos 14 TB (`hdd` label, `durability=1`, metadata + data truth) plus WD SN850X 2 TB and Samsung 9100 Pro 1 TB (`ssd` label, `durability=1`, journal + writeback cache). `data_replicas=2`, `metadata_replicas=2`; `data_allowed` keeps btree off SSDs and journal off HDDs. Mount via `bcachefs-store.service` (not fstab).

---

## Samba shares

| Share | Path | Notes |
|---|---|---|
| media | `/store/media` | force user: st, 0644/0755 masks |
| st | `/store/st` | force user: st, 0600/0700 masks |
| data | `/store/data` | force user: st, 0600/0700 masks |
| iris | `/var/iris` | force user: st, 0600/0700 masks, group st rw. Root-run service; local to boot SSD, not on bcachefs. |
| tm | `/store/tm` | Time Machine, 4 TB max |

Config: SMB3 minimum, macOS fruit/AAPL extensions enabled, NetBIOS disabled.

Mac mounts: `smb://lab.local/media` → `/Volumes/media`
Linux symlinks: `/Volumes/media` → `/store/media`, `/Volumes/st` → `/store/st`

Full `smb.conf` and service bring-up: [post-install.md](post-install.md).

---

## PostgreSQL

Separate doc: [postgres.md](postgres.md) (used by Mac DaVinci Resolve).
