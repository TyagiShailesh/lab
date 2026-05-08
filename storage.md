# Storage

## bcachefs pool (`/nas`)

**Full architecture, devices, systemd unit, kernel OOT module, and operational notes:** [bcachefs.md](bcachefs.md).

**At a glance:** four-device bcachefs — 2× Exos 14 TB (`hdd` label, `durability=1`, all metadata + data truth) plus WD SN850X 2 TB and Samsung 990 Pro 2 TB (`ssd` label, `durability=2`, `data_allowed=user` only — pure write-back cache). `data_replicas=2`, `metadata_replicas=2`. Mount via `nas.service` (not fstab).

---

## Cache tier design

**Intent.** SSDs are pure write-back cache + read-promote target. All durable data and *all* metadata live on HDDs. Losing both SSDs simultaneously costs only the small in-transit window (extents written to SSD but not yet migrated); the FS itself stays mountable because journal and btree never land on SSDs.

**Per-device:**
- HDDs (`hdd`): `durability=1`, `data_allowed=journal,btree,user`, `rotational=1` — truth tier.
- SSDs (`ssd`): `durability=2`, `data_allowed=user` only, `rotational=0`, `discard=1` — cache tier. The `data_allowed` bitmap is the hard gate: the kernel refuses to place excluded data types regardless of FS-level options.

**FS-level:** `metadata_target=hdd`, `foreground_target=ssd`, `background_target=hdd`, `promote_target=ssd`.

**Why `durability=2` per SSD.** With `data_replicas=2`, one SSD bucket alone satisfies the replica requirement (`alloc/foreground.c:add_new_bucket` — allocator stops once `nr_effective ≥ nr_replicas`). Foreground writes ack at single-NVMe speed; no HDD pointer is added at write time. The dishonest `durability=2` claim is the trade we accept — `background_target=hdd` migrates each pointer to the real 2× HDD copies asynchronously (`data/reconcile/trigger.c` — any pointer not on `background_target` is flagged `ptrs_moving`, then *moved* and the SSD pointer dropped).

**Why `data_allowed=user` only on SSDs.** Lesson from 2026-05-08: btree leaked onto SSDs (visible in `show-super` as `Has data: btree`) even with `metadata_target=hdd` set, and wiping SSDs without first draining metadata broke topology and forced a full `scan_for_btree_nodes` recovery. Locking the device's `data_allowed` to `user` is the only way to guarantee btree/journal never live on cache devices, so SSDs can be wiped/swapped at any time without metadata risk.

**Pre-wipe / pre-remove checklist for cache devices.** Even with `data_allowed=user` enforced, **always verify before destruction:**
1. `bcachefs show-super /dev/<ssd> | grep -A1 'Device <N>:' -A20 | grep 'Has data'` — must show `user,cached` only. If it includes `btree` or `journal`, **stop**: data_allowed wasn't locked down, or the device was added before the rule existed.
2. If `Has data` includes anything beyond `user,cached`: lock `data_allowed=user` on the device (`bcachefs set-fs-option`), wait for rebalance to drain btree/journal off (verify by re-reading `Has data`), *then* wipe.
3. The reverse — wiping first and discovering broken btree topology after — is unrecoverable for any extent whose btree node had its only durable pointer on the wiped device. Files affected return I/O errors permanently. Don't ask how I learned this.

**Trade-offs accepted:**
- *In-transit data loss* if both SSDs die before background migration completes (short window, bounded by SSD residency).
- *Sustained-write throttling* once cache fills (~3 TB usable). Bursts ride at SSD speed; multi-hour writes bottleneck on HDD migration rate.
- *Higher fsync latency* than journal-on-SSD (journal commits hit HDDs). Irrelevant for media/file workloads; would matter for database-style sync writes.

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

