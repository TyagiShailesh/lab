# Storage

`/nas` is a **bcachefs hybrid pool** — HDD durable tier + NVMe write-back cache. Single filesystem, no mdadm, no LVM, no bcache layer.

## At a glance

| Layer | Devices | Role |
|---|---|---|
| HDD tier | 2× Seagate Exos 14 TB (`/dev/sda`, `/dev/sdb`) | `durability=1` each, `data_allowed=journal,btree,user`. Holds the durable replicas + all metadata. |
| NVMe cache | Samsung 990 PRO 2 TB (`/dev/nvme1n1`) + WD SN850X 2 TB (`/dev/nvme2n1`) | `durability=1` (counts toward `data_replicas`), **`data_allowed=user` only** — kernel-enforced lockdown so btree/journal can never land here. |
| Filesystem | bcachefs v1.38.2 (kernel OOT module) | `foreground_target=ssd, background_target=hdd, promote_target=ssd, metadata_target=hdd, data_replicas=2, metadata_replicas=2, compression=none` |

```
sda  ─┐
sdb  ─┤── HDD label "hdd", durability=1, all data types ──┐
                                                          │
                                                          ├─► bcachefs /nas
                                                          │     foreground→ssd, mover→hdd, metadata→hdd
nvme1n1 ─┐                                                │
nvme2n1 ─┤── NVMe label "ssd", durability=1, USER ONLY ───┘
```

Mount: `nas.service` calls `bcachefs mount UUID=… /nas` (not fstab — see §Mount).

---

## Why this exact config — empirically tested 2026-05-08

We tried multiple configs on this hardware and benchmarked each with `dd if=/dev/zero of=/nas/test bs=1M count=102400 conv=fdatasync` (100 GB sequential, no compression):

| Config | Sequential write | What actually happened |
|---|---|---|
| **Current**: SSDs `durability=1` + `data_allowed=user`, `data_replicas=2` | **4300 MB/s** | Foreground writes 2 SSD copies (one per device, both durability=1). Replicas satisfied at SSD speed. Mover migrates to HDDs and flips SSD pointers to `cached=true`, freeing them for eviction. |
| Pure cache (Kent's "writethrough"): SSDs `durability=0`, `data_replicas=2` | 245 MB/s | SSD copies don't count toward replicas, so allocator must place 2 durable copies on HDDs **synchronously** during foreground write. Foreground waits for HDD-mirrored writes. SSDs receive a side cache copy in parallel but don't accelerate writes. |
| Reduced redundancy: SSDs `durability=0`, `data_replicas=1` | 479 MB/s | Same HDD-bound foreground, but only 1 HDD copy per write (allocator stripes across both HDDs). 2× the durability=2 case but still HDD-bound, and only 1 durable copy means a single HDD failure loses half the data. |

**Mechanism, source-verified** ([bcachefs-tools v1.38.2](kernel/build/dkms-staging/usr/src/bcachefs-v1.38.2/src/fs/bcachefs/)):

- `alloc/foreground.c:767` — replica accounting: `req->nr_effective += durability`. A `durability=0` device contributes **zero** to `nr_effective`. The allocator loop only exits once `nr_effective ≥ nr_replicas`, so foreground writes with `durability=0` SSDs **must** allocate enough HDD buckets to satisfy the replica count. The closure in `data/write.c` waits on all bios (HDD included) before ack.
- `alloc/foreground.c:1681` — per-type filter: `dev_may_alloc = ... && (ca->mi.data_allowed & BIT(req->data_type))`. With `data_allowed=user` on the SSDs, **btree and journal allocations physically cannot select an SSD device** — the filter returns false at allocation time, regardless of `metadata_target`.
- `alloc/replicas.c:942` — capacity math: `nr_have[i] += data_allowed & BIT(i) ? durability : 0`. With our config, `nr_have[user] = 4` (2 SSDs + 2 HDDs), `nr_have[btree] = nr_have[journal] = 2` (HDDs only). All requirements satisfied without SSDs participating in metadata.

**The wipe-disaster lockdown still holds.** This is the lesson from the 2026-05-08 v1.37.5 incident where `wipefs` on an SSD caused a 30-min `scan_for_btree_nodes` recovery + 3.8 TB orphaned to `lost+found`. With `data_allowed=user`, no btree node or journal entry can ever land on an SSD — verified empirically (§Failure modes below): wiped one SSD, then both, FS continued serving all data with zero hash failures.

---

## What we ruled out, and why

- **Pure cache (`durability=0` SSDs)**: Kent's PoO §8.5.4 calls this "essential for cache devices" — and it is, *if your goal is read-acceleration only*. For write-heavy initial loads (your 2.87 TB seed), it's 18× slower (245 vs 4300 MB/s direct).
- **`data_replicas=1`**: doubles small-IOPS over `data_replicas=2` mirroring (1 HDD write per byte instead of 2) but gives only 1 durable copy. Single HDD failure = data loss for files that landed on it. Not acceptable for media archive.
- **No `data_allowed=user` lockdown**: would let btree/journal land on SSDs whenever the allocator preferred. Re-introduces the wipe-disaster failure mode. Verified mitigation by force-wiping an SSD with the lockdown in place — FS unaffected.
- **`compression=zstd`**: media is already codec-compressed; gains negligible storage savings while burning CPU on every byte. We tested it — `dd if=/dev/zero` looked artificially fast (1.77 GB used for 100 GB written) because zeros compress 56:1 at zstd-default; real data wouldn't. CPU cost not justified.
- **`metadata_target=ssd`**: tempting for fast metadata operations, but with our `metadata_replicas=2` and `data_allowed=user` lockdown, metadata can only land on HDDs anyway. The flag would be a no-op.
- **`encrypted`**: not needed for this LAN-only lab; would add CPU per byte.
- **Erasure coding**: PoO §6.1 explicitly marks it "DO NOT USE YET".

---

## What we accept as trade-offs

- **In-flight write window**: with `durability=1` SSDs and `data_replicas=2`, fresh foreground writes are "2 SSD copies, 0 HDD copies" until the background mover migrates. If both SSDs die *within* that window (typically seconds for moderate write rates, mover keeps up at HDD throughput), the un-migrated bytes are lost. The Mac source still has them until you choose to delete from the Mac. Over a multi-day window this collapses to "data is on HDDs."
- **Sustained-write throttling once cache fills**: foreground at SSD speed only as long as the mover is keeping up with the in-flight backlog. If sustained ingress > mover drain rate (~250 MB/s mirrored to HDDs), SSDs accumulate un-migrated *durable* data which **cannot be evicted** until the mover converts pointers to `cached`. Foreground then throttles to mover throughput. Verified with the empirical eviction test (cached column dropped 800M → 174M → 94M as new writes pressured a small test pool, while durable buckets stayed pinned).
- **No mainline kernel as of Linux 6.18** — bcachefs ships as a DKMS / out-of-tree module. The kernel build pipeline pins `bcachefs-tools v1.38.2` and compiles `bcachefs.ko` against the in-house monolithic kernel (see [kernel/build-kernel.sh](kernel/build-kernel.sh)).

---

## Build (one-time, destructive)

Wipes `sda`, `sdb`, `nvme1n1`, `nvme2n1`. Boot drive `nvme0n1` untouched.

```sh
# Pre-flight
systemctl stop smbd nmbd nas.service

# Wipe
wipefs -a /dev/sda /dev/sdb /dev/nvme1n1 /dev/nvme2n1
blkdiscard /dev/nvme1n1
blkdiscard /dev/nvme2n1   # NVMe full TRIM (one device per command — bcachefs / blkdiscard quirk)

# Format — every flag has a Kent citation, see §Why this exact config.
# `-f` overrides the libblkid >= 2.40.1 check (Ubuntu 24.04 ships 2.39.3).
# Discard is auto-set per-device at format time (visible in show-super); not a format flag in v1.38.2.
bcachefs format -f \
  --label=hdd.exos1   --durability=1 --data_allowed=journal,btree,user  /dev/sda \
  --label=hdd.exos2   --durability=1 --data_allowed=journal,btree,user  /dev/sdb \
  --label=ssd.990pro  --durability=1 --data_allowed=user                /dev/nvme1n1 \
  --label=ssd.sn850x  --durability=1 --data_allowed=user                /dev/nvme2n1 \
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

**Per-device durability flags must repeat per device** — bcachefs's argument parser keeps the last `--durability` value as the default for subsequent devices, so omitting it on later devices accidentally inherits the previous value. We hit this once during today's reformatting.

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

# Verify HDDs hold the durable copies; SSDs should be empty or `cached` only
bcachefs fs usage /nas
```

`bcachefs fs usage` reports a `cached:` line — when that's the dominant column on SSDs and `Pending reconcile: 0`, every byte exists durably on the HDDs.

### Pre-wipe / pre-replace checklist for cache devices

Routine that prevents the v1.37.5 incident from recurring:

```sh
# 1. Inspect what data types are physically on the device
bcachefs show-super /dev/<dev> | grep -E 'Label:|Data allowed:|Durability:|Has data:'
# Expected for a healthy cache device: Data allowed: user, Durability: 1, Has data: user
# If "Has data" includes journal or btree: STOP. Lockdown drifted.

# 2. Live device usage
bcachefs fs usage /nas | grep <dev>

# 3. Evacuate
bcachefs device evacuate /dev/<dev>

# 4. Wait for reconcile to fully complete
bcachefs reconcile wait

# 5. Confirm zero
bcachefs fs usage /nas | grep <dev>

# 6. Remove from FS
bcachefs device remove /dev/<dev>

# 7. NOW safe to wipe
wipefs -a /dev/<dev>
blkdiscard /dev/<dev>

# 8. Re-add (or add a replacement)
bcachefs device add --label=ssd.sn850x --durability=1 --data_allowed=user /dev/<new-dev>
```

That said: today's empirical tests confirmed that even *without* this checklist, `data_allowed=user` makes a careless `wipefs` survivable — the FS kept serving and accepting writes with **0 hash failures** after we wiped one SSD, then both. The checklist is the disciplined path; the lockdown is the safety net for when discipline lapses.

### Inspect FS state

```sh
bcachefs fs usage -h /nas              # capacity + replication + per-device usage
bcachefs show-super /dev/sda           # superblock, members, options
bcachefs reconcile status /nas         # pending reconcile work
```

### Replace a failed HDD

```sh
bcachefs device set-state ro /dev/<dev>      # take read-only first if it's still online
bcachefs device evacuate /dev/<dev>          # migrate the singletons elsewhere
bcachefs device remove /dev/<dev>
# physically replace
bcachefs device add --label=hdd.exosN --durability=1 --data_allowed=journal,btree,user /dev/<new-dev>
```

`set-state failed` is **not** a valid value in v1.38.2 — only `rw, ro, evacuating, spare`. Use `evacuating` to start a graceful drain.

---

## Failure modes — empirically tested 2026-05-08

| Failure | Tested via | Effect | Outcome |
|---|---|---|---|
| 1 SSD vanishes mid-operation | PCI hot-remove (`echo 1 > /sys/bus/pci/devices/.../remove`) | FS keeps reading + writing; `bcachefs fs usage` shows `dev-N` placeholder name | **0 hash failures** on 1001 test files; new writes succeed; PCI rescan + `bcachefs device online` re-binds it cleanly |
| Both SSDs vanish simultaneously | PCI hot-remove of both | FS continues serving from HDDs; foreground writes route to HDDs (degraded mode) | All durable data intact; only un-migrated in-flight bytes were lost (4 of 1006 test files written *while* SSDs were gone) |
| `wipefs` on a live SSD member | `wipefs -a /tmp/loop.img` after detaching loop | FS kept serving; bcachefs detects superblock mismatch but uses HDD replicas | **0 hash failures** on test set; wipe-disaster scenario fully prevented by `data_allowed=user` lockdown |
| `wipefs` on both SSDs | Both loop-device images wiped | FS kept serving; HDD-only writeback path activated | All data readable, new writes accepted in HDD-only mode |
| Read-promote on cold file | Force-evict cached SSD copies, drop page cache, read 200 MB file | Cold read served from HDDs, then bcachefs proactively promoted the data to SSD | `cached` column grew **+190 MB** after the cold read — promotion path verified |
| 1 HDD fails | not tested live | FS degrades; data still on the other HDD | replace HDD, `bcachefs device add`, reconcile fills it |
| Both HDDs die | not tested live | catastrophic — durable tier gone | restore from backup |
| Power loss with cache holding dirty data | not tested live | bcachefs journal replay produces a consistent FS on next mount | `recovering from clean shutdown, journal seq …` (clean-replay path) |

Bit-rot is detected at extent CRC level (default crc32c) and self-healed from the other replica during read or scrub.

---

## Performance characteristics — measured today

### Direct (no network)

| Workload | Throughput |
|---|---|
| Sequential write 100 GB (`dd /dev/zero` fdatasync) | **4.3 GB/s** |
| Sequential write 500 GB (mover competes for SSD bandwidth) | 1.8 GB/s |
| Sequential read (cold cache, from HDD) | 2.9 GB/s |
| smbclient localhost loopback write 100 GB | 2.7 GB/s |

### Mac → server SMB

| Configuration | Sustained throughput |
|---|---|
| Single Finder copy, big files | ~575 MB/s |
| Single Finder copy, real-data dd test | 1139 MB/s (200 GB sequential, big-file case) |
| 2 parallel Finder copies | ~650 MB/s aggregate |
| 3 parallel Finder copies | **breaks** — Mac SMB client fails 2 of 3 with `-43`/"device disappeared" |

### Critical: CPU governor must be `performance`

Without it (governor stuck on `powersave` after a kernel upgrade), Mac SMB single-stream caps around **100 MB/s** on a 10 GbE link — looks identical to a samba/network/storage problem but isn't. Verify after any kernel work:

```sh
systemctl is-active cpu-performance.service           # → active
head -1 /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor   # → performance
```

The unit is created by [kernel/build-rootfs.sh](kernel/build-rootfs.sh) on fresh installs but is easy to lose — check first when SMB throughput regresses. See [network.md](network.md#performance--cpu-governor-must-be-performance) for the full picture.

### When the mover can't keep up

For a sustained workload faster than mover throughput (~250-500 MB/s combined HDD writes), SSDs fill with un-migrated durable data. Foreground throttles to mover rate and stays there until the backlog drains. Math for our hardware:

- Mover effective drain (user data, mirrored to 2 HDDs): ~250 MB/s
- SSD physical capacity for durable data: ~3.6 TB total (one replica per SSD)
- Time to fill at sustained 1 GB/s ingress: ~80 minutes before throttle
- For Mac SMB single-stream (~575 MB/s) the SSDs never fill in practice

---

## What we deliberately don't tune

bcachefs's defaults are workload-tuned by the maintainer. Per PoO §6 option reference:

- `compression=none` is the right call for media (already compressed) and Time Machine bands. CPU spent on compression is CPU not spent serving SMB.
- `journal_flush_disabled` is **dangerous** ("data loss is expected on any unclean shutdown"). Default off.
- `degraded=very` is **dangerous** ("creates splitbrain risk"). Default off.
- `casefold` is empty-directory-only; macOS Finder side handles case insensitivity via Samba `case sensitive = no`. Default off.
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

**Mac SMB ceiling**: cap concurrent Finder copies to **2** per share. macOS multiplexes more transfers onto the existing 2 SMB sessions, and 3+ Finder copies destabilize the Mac SMB client (we hit `-43` and "device disappeared" errors with 3 copies). If a copy aborts, `killall Finder` clears stale mount handles; force-unmount + remount via `smb://lab.local/media` to re-establish.
