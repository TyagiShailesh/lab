# Storage

`/nas` is a **bcachefs hybrid pool** — HDD truth tier + NVMe write-back cache. Single filesystem, no mdadm, no LVM, no bcache layer.

## At a glance

| Layer | Devices | Role |
|---|---|---|
| HDD truth | 2× Seagate Exos 14 TB (`/dev/sda`, `/dev/sdb`) | `durability=1` each, `data_allowed=journal,btree,user`. With `data_replicas=2` + `metadata_replicas=2`, both replicas of every byte and every btree node land here. |
| NVMe cache | Samsung 990 PRO 2 TB (`/dev/nvme1n1`) + WD SN850X 2 TB (`/dev/nvme2n1`) | `durability=0`, **`data_allowed=user` only**. Pure write-back cache. Wipeable at any time without structural risk. |
| Filesystem | bcachefs v1.38.2 (kernel OOT module) | `foreground_target=ssd, background_target=hdd, promote_target=ssd, metadata_target=hdd` |

```
sda  ─┐
sdb  ─┤── HDD label "hdd", durability=1, all data types ─┐
                                                         │
                                                         ├─► bcachefs /nas
                                                         │     (writeback to ssd, drain to hdd)
nvme1n1 ─┐                                               │
nvme2n1 ─┤── NVMe label "ssd", durability=0, user only ──┘
```

Mount: `nas.service` calls `bcachefs mount UUID=… /nas` (not fstab — see §Mount).

---

## Why this stack — and the lessons that shaped it

Cited from **Kent Overstreet's Principles of Operation** (`bcachefs.org/bcachefs-principles-of-operation.pdf`) and the upstream `bcachefs-tools` git tree.

**Three hard rules from PoO + the failure mode we lived through (2026-05-08):**

1. **Cache devices must be `durability=0`.** PoO §2.2.4.1: *"To use the SSDs as a pure write cache (data evictable once on HDD), set `durability=0` on the SSD devices."* PoO §8.5.4: *"The `durability=0` setting is essential for cache devices: it ensures bcachefs does not count cached copies toward the replica count, so losing the cache device never causes data loss."*
   - Why this matters: with `durability=1` on cache devices, the allocator counts cache copies as a replica. Wiping the cache device then becomes a structural-corruption event — exactly the v1.37.5 incident that cost a 30-minute `scan_for_btree_nodes` recovery + 3.8 TB orphaned to `lost+found`.

2. **`data_allowed=user` on cache devices is the hard gate.** PoO §8.5.7: *"The `data_allowed` member field restricts which data types a device can hold: journal, btree, or user data."* Setting `data_allowed=user` on the SSDs means the kernel **physically refuses** to place btree or journal blocks there — regardless of `metadata_target` drift, regardless of operator error. Combined with `metadata_target=hdd`, btree is locked onto durable storage. Wiping the cache cannot damage the FS.

3. **Two NVMes raw, not mdraid underneath.** PoO §8.5 treats devices individually; the read path tracks per-device latency to direct reads to the fastest replica. Layering bcachefs on mdraid for a `durability=0` cache is wasted — bcachefs already doesn't replicate cached copies, and mirroring at the block layer halves cache capacity for no benefit.

**Why bcachefs over bcache+XFS or ZFS:**

- **Bit-rot detection** — per-extent CRC32C/xxhash checksums by default; scrub-on-read self-heals from a good replica. PoO §2.2.1.
- **Write-back cache that just works** — PoO §8.5.4 describes the canonical writeback triple (`foreground_target=ssd, background_target=hdd, promote_target=ssd`) as the documented design. dm-cache's smq doesn't promote sequential writes; dm-writecache caps block_size at PAGE_SIZE (4 KiB on x86) so 3.6 TB cache won't fit in 64 GB RAM.
- **Single filesystem** — no mdadm + LVM + dm-cache + XFS layer cake. One bcachefs `format`, one mount, one set of stats, one `bcachefs fs usage`.

**Trade-offs accepted:**

- *In-transit data loss* if both NVMes die simultaneously **before** background migration completes. Bounded by SSD residency time. Mac source still has the bytes if you don't delete-on-the-Mac until verified.
- *Sustained-write throttling* once cache fills (~3.6 TB usable) — drops to HDD migration rate (~150 MB/s mirrored).
- *No mainline kernel as of Linux 6.18* — bcachefs ships as a DKMS / out-of-tree module. Our kernel build pipeline pins `bcachefs-tools v1.38.2` and compiles `bcachefs.ko` against the in-house monolithic kernel (see [kernel/build-kernel.sh](kernel/build-kernel.sh)).

---

## Build (one-time, destructive)

Wipes `sda`, `sdb`, `nvme1n1`, `nvme2n1`. Boot drive `nvme0n1` untouched.

```sh
# Pre-flight
systemctl stop smbd nmbd nas.service

# Wipe
wipefs -a /dev/sda /dev/sdb /dev/nvme1n1 /dev/nvme2n1
blkdiscard /dev/nvme1n1 /dev/nvme2n1   # NVMe full TRIM

# Format — every flag has a Kent citation, see §Why this stack.
# `-f` overrides the libblkid >= 2.40.1 check (Ubuntu 24.04 ships 2.39.3).
# Discard is auto-set per-device at format time (visible in show-super); not a format flag in v1.38.2.
bcachefs format -f \
  --label=hdd.exos1   --durability=1 --data_allowed=journal,btree,user  /dev/sda \
  --label=hdd.exos2   --durability=1 --data_allowed=journal,btree,user  /dev/sdb \
  --label=ssd.990pro  --durability=0 --data_allowed=user                /dev/nvme1n1 \
  --label=ssd.sn850x  --durability=0 --data_allowed=user                /dev/nvme2n1 \
  --foreground_target=ssd \
  --background_target=hdd \
  --promote_target=ssd \
  --metadata_target=hdd \
  --data_replicas=2 \
  --metadata_replicas=2 \
  --compression=none

# Mount
mkdir -p /nas
modprobe bcachefs
bcachefs mount -o noatime UUID=$(bcachefs show-super /dev/sda | awk '/^External UUID:/{print $3}') /nas

# Share roots
mkdir -p /nas/media /nas/st /nas/data /nas/tm
chown st:st /nas/media /nas/st /nas/data /nas/tm
chmod 755 /nas/{media,st,data,tm}

# Bring services back
systemctl start smbd nmbd
```

The format command is the entire stack definition. There is no LVM, no dm-cache, no separate journal device — bcachefs handles all of it from `--label` and `--foreground_target` onward.

---

## Mount

`nas.service` is the entry point. The kernel module loads via `/etc/modules-load.d/bcachefs.conf`; udev settles all four devices; bcachefs assembles the FS from the superblock UUID.

```ini
# /etc/systemd/system/nas.service
[Unit]
Description=Mount NAS storage pool (bcachefs hybrid: HDD truth + NVMe writeback)
After=systemd-modules-load.service local-fs-pre.target
Wants=local-fs-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/modprobe bcachefs
ExecStart=/usr/local/sbin/bcachefs mount -o noatime UUID=<fs-uuid> /nas
ExecStop=/usr/bin/umount /nas

[Install]
WantedBy=multi-user.target
```

`noatime` is a standard mount-time flag honored by bcachefs's VFS layer. The on-disk format upgrade behavior is a *superblock* option (`version_upgrade`) — set via `bcachefs set-fs-option -o version_upgrade=none /nas` post-mount if you want to pin the on-disk format and refuse silent upgrades. Default is `compatible` (auto-upgrades only safe features).

---

## Operations

### Drain cache before deleting source on the writing host

Before deleting the Mac-side copy after a big upload:

```sh
# Force background migration to finish
bcachefs reconcile wait    # blocks until reconcile passes complete

# Verify cache devices have only 'cached' data, no dirty user blocks
bcachefs fs usage /nas | grep -E 'ssd|nvme'
```

Once `cached` is the only non-zero column for the SSDs, every byte exists on the HDDs.

### Pre-wipe / pre-replace checklist for cache devices

This is the routine that prevents the 2026-05-08 incident from recurring:

```sh
# 1. Inspect what data types are physically on the device
bcachefs show-super /dev/<dev> | grep -E 'state|data_allowed|durability|Has data'
# Expected for a healthy cache device: data_allowed=user, durability=0, "Has data: user,cached"
# If "Has data" includes journal or btree: STOP. The data_allowed lockdown drifted.

# 2. Live device usage
bcachefs fs usage /nas | grep <dev>

# 3. Evacuate (v1.38+ Rust path, version-checked, prints next command on completion)
bcachefs device evacuate /dev/<dev>

# 4. Wait for reconcile to fully complete
bcachefs reconcile wait

# 5. Confirm zero
bcachefs fs usage /nas | grep <dev>     # expect zero user/btree/journal sectors

# 6. Remove from FS
bcachefs device remove /dev/<dev>

# 7. NOW safe to wipe
wipefs -a /dev/<dev>
blkdiscard /dev/<dev>

# 8. Re-add (or add a replacement)
bcachefs device add --label=ssd.sn850x --durability=0 --data_allowed=user /dev/<new-dev>
```

The two non-obvious steps are (1) — confirming `data_allowed=user` actually held — and (4) — `reconcile wait` blocks until evacuated data has fully migrated; without it, step 7 is the same race that bit us.

### Inspect FS state

```sh
bcachefs fs usage -h /nas              # capacity + replication + per-device usage
bcachefs show-super /dev/sda           # superblock, members, options
bcachefs reconcile status              # any pending reconcile work
```

### Replace a failed HDD

`bcachefs device set-state failed /dev/<dev>` then `bcachefs device evacuate /dev/<dev>` to migrate any singletons; replace, `bcachefs device add --label=hdd.exosN --durability=1 …`.

---

## Failure modes

| Failure | Effect | Recovery |
|---|---|---|
| 1 HDD dies | FS keeps running degraded; data still on the other HDD | replace HDD, `bcachefs device add`, reconcile fills it |
| 1 NVMe dies | Cache layer degrades; **`durability=0` means no replica accounting impact** — only dirty data on that drive (not yet migrated) is lost | replace, re-add as `durability=0` `data_allowed=user`; cache repopulates organically |
| Both NVMes die | Lose only un-migrated dirty data; FS itself unaffected because btree/journal live on HDDs (`data_allowed=user` lockdown) | replace both, re-add, resume |
| Both HDDs die | catastrophic — durable tier gone | restore from backup |
| Power loss with cache intact | bcachefs journal replay produces a consistent FS | nothing to do |
| Cache device wiped while holding btree | recovery via `scan_for_btree_nodes`; lost+found relocation | **prevented at format time** by `data_allowed=user` — kernel refuses to place btree on cache |

Bit-rot is detected at extent CRC level and self-healed from the other replica during read or scrub.

---

## Why we don't tune most things

bcachefs's defaults are workload-tuned by the maintainer. Per PoO §6 option reference:

- `compression=none` is the right call for media (already compressed) and Time Machine bands (also compressed). CPU spent on compression is CPU not spent serving SMB.
- `journal_flush_disabled` is **dangerous** ("data loss is expected on any unclean shutdown"). Default off.
- `degraded=very` is **dangerous** ("creates splitbrain risk"). Default off.
- `casefold` is empty-directory-only and the macOS Finder side already handles case insensitivity via Samba `case sensitive = no`. Default off.
- Erasure coding is explicitly marked "DO NOT USE YET" in PoO §6.1.

The only knobs we set explicitly are the `--label`, `--durability`, `--data_allowed`, and `*_target` flags above. Everything else stays at Kent's defaults.

---

## Samba shares

| Share | Path | Access | Notes |
|---|---|---|---|
| media | `/nas/media` | `st`, `laksh` | `force user = st`, `force group = st` |
| st | `/nas/st` | `st` | |
| data | `/nas/data` | `st` | |
| iris | `/var/iris/clips` | `st` | `st` is in the `iris` group; dir is `st:iris 2770` (setgid) so iris-service-written clips inherit group `iris` and st can delete via group write. Iris service runs locally and writes to `/var/iris/`; only `clips/` is exposed to SMB. |
| tm | `/nas/tm` | `st` | Time Machine, 4 TB cap (`fruit:time machine max size = 4000G`) |

Share roots are owned `st:st` (or `st:iris` for iris). Writers running outside Samba (root, systemd units, containers) should `sudo -u st` or set `User=st` in their unit — otherwise they create files st can't manage via SMB.

Users are POSIX accounts (`tdbsam` backend requires `getpwnam()` to resolve). SMB-only users get a stub Linux account: `useradd -M -s /usr/sbin/nologin <name>` then `smbpasswd -a <name>`. Currently `st` (full) and `laksh` (media only).

Config: SMB3 minimum, macOS fruit/AAPL extensions, NetBIOS disabled, `access based share enum = yes` (each user sees only the shares they can connect to in enumeration). Samba's `vfs objects = catia fruit streams_xattr` requires `samba-vfs-modules` (Ubuntu's `samba` meta-package doesn't pull it).

Mac mounts: `smb://lab.local/media` → `/Volumes/media`. Linux symlinks: `/Volumes/media` → `/nas/media`, `/Volumes/st` → `/nas/st`.
