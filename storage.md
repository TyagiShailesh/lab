# Storage

## bcachefs pool (`/nas`)

**Full architecture, devices, systemd unit, kernel OOT module, and operational notes:** [bcachefs.md](bcachefs.md).

**At a glance:** four-device bcachefs — 2× Exos 14 TB (`hdd` label, `durability=1`, metadata + data truth) plus WD SN850X 2 TB and Samsung 990 Pro 2 TB (`ssd` label, `durability=1`, journal + writeback cache). `data_replicas=2`, `metadata_replicas=2`; `data_allowed` keeps btree off SSDs and journal off HDDs. Mount via `nas.service` (not fstab).

---

## Samba shares

| Share | Path | Notes |
|---|---|---|
| media | `/nas/media` | force user: st, 0644/0755 masks |
| st | `/nas/st` | force user: st, 0600/0700 masks |
| data | `/nas/data` | force user: st, 0600/0700 masks |
| iris | `/var/iris` | force user: st, force group: iris. 2770 setgid; st added to iris group. Root-run service; local to boot SSD, not on bcachefs. |
| tm | `/nas/tm` | Time Machine, 4 TB max |

Config: SMB3 minimum, macOS fruit/AAPL extensions enabled, NetBIOS disabled. Samba's `vfs objects = catia fruit streams_xattr` requires `samba-vfs-modules` (Ubuntu's `samba` meta-package doesn't pull it).

Mac mounts: `smb://lab.local/media` → `/Volumes/media` (Samba advertises NetBIOS name `nas`; mDNS hostname is still `lab.local`).
Linux symlinks: `/Volumes/media` → `/nas/media`, `/Volumes/st` → `/nas/st`

