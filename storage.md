# Storage

## bcachefs pool (`/nas`)

**Full architecture, devices, systemd unit, kernel OOT module, and operational notes:** [bcachefs.md](bcachefs.md).

**At a glance:** four-device bcachefs — 2× Exos 14 TB (`hdd` label, `durability=1`, metadata + data truth) plus WD SN850X 2 TB and Samsung 990 Pro 2 TB (`ssd` label, `durability=1`, journal + writeback cache). `data_replicas=2`, `metadata_replicas=2`; `data_allowed` keeps btree off SSDs and journal off HDDs. Mount via `nas.service` (not fstab).

---

## Samba shares

| Share | Path | Access | Notes |
|---|---|---|---|
| media | `/nas/media` | `st`, `laksh` | `force user = st`, `force group = st` — laksh writes land as `st:st` on disk |
| st | `/nas/st` | `st` | |
| data | `/nas/data` | `st` | |
| iris | `/var/iris/clips` | `st` | `st` is in the `iris` group; dir is `st:iris 2770` (setgid) so iris-service-written clips inherit group `iris` and st can delete via group write. The iris service runs locally and writes to `/var/iris/`; only `clips/` is exposed to SMB. |
| tm | `/nas/tm` | `st` | Time Machine, 4 TB cap (`fruit:time machine max size = 4000G`) |

Share roots are owned `st:st` (or `st:iris` for iris). Writers running outside Samba (root, systemd units, containers) should `sudo -u st` or set `User=st` in their unit — otherwise they create files st can't manage via SMB.

Users are POSIX accounts (`tdbsam` backend requires `getpwnam()` to resolve). SMB-only users get a stub Linux account: `useradd -M -s /usr/sbin/nologin <name>` then `smbpasswd -a <name>`. Currently `st` (full) and `laksh` (media only).

Config: SMB3 minimum, macOS fruit/AAPL extensions, NetBIOS disabled, `access based share enum = yes` (each user sees only the shares they can connect to in enumeration). Samba's `vfs objects = catia fruit streams_xattr` requires `samba-vfs-modules` (Ubuntu's `samba` meta-package doesn't pull it).

Mac mounts: `smb://lab.local/media` → `/Volumes/media` (Samba advertises NetBIOS name `nas`; mDNS hostname is still `lab.local`).
Linux symlinks: `/Volumes/media` → `/nas/media`, `/Volumes/st` → `/nas/st`

