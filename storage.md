# Storage

## At a glance

Two-tier hybrid on `/nas`. **HDDs are the truth, NVMes are pure write-back cache.** XFS on top of bcache.

| Layer | Devices | Role |
|---|---|---|
| HDD truth | 2× Seagate Exos 14 TB → `mdadm` RAID1 → `/dev/md0` | Durable storage; survives 1-disk loss; ~12.7 TB usable |
| NVMe cache | WD SN850X 2 TB + Samsung 990 Pro 2 TB → `mdadm` RAID0 → `/dev/md1` | Hot cache; 3.6 TB; **single NVMe failure loses dirty data — accepted because we keep source until verified** |
| LVM | `vg_nas` over `md0` only | `nas_data` (bcache backing) + `xfs_log` (XFS external journal) |
| **bcache** | `/dev/md1` cache + `/dev/vg_nas/nas_data` backing → `/dev/bcache0` | **writeback** mode, 4 MiB buckets, `sequential_cutoff=0` (cache absorbs all I/O), ~1 GiB RAM for full 3.6 TB cache |
| Filesystem | XFS on `/dev/bcache0`, log on `/dev/vg_nas/xfs_log` | Journal on HDD survives total cache loss |

```
sda  ─┐
sdb  ─┤── mdadm RAID1 ── md0 ── vg_nas ─┬── nas_data (bcache backing) ─┐
                                        │                              ├── /dev/bcache0 ── XFS ── /nas
                                        └── xfs_log (XFS journal)      │            (writeback)
                                                                       │
nvme1n1 ─┐                                                             │
nvme2n1 ─┤── mdadm RAID0 ── md1 ─────────────── (bcache cache device) ─┘
```

Mount: `nas.service` (systemd unit, not fstab — see §Mount).

## Measured speeds (kernel 7.0.5, bucket 4M, sequential_cutoff=0)

| Workload | Throughput |
|---|---|
| `dd 4 GB direct, bs=4M` | **5.2 GB/s** |
| `dd 8 GB direct, bs=4M` | 5.4 GB/s |
| `dd 16 GB direct, bs=4M` | 5.1 GB/s |
| `dd 32 GB direct, bs=4M` | 5.1 GB/s — still SSD-rate, no throttle |
| `dd 4 × 8 GB parallel direct` | 3.1 GB/s per stream → **12.4 GB/s aggregate** |
| `dd 4 GB read, cold cache` | 8.5 GB/s (page-cache assisted) |
| Sustained writes after cache fills (~3.5 TB) | ~150 MB/s (HDD drain rate) |

This saturates the NVMe RAID0 (~6 GB/s ceiling per `dd` on raw `/dev/md1`) for single-stream, and exceeds it for parallel — chipset DMI Gen4 x8 (~16 GB/s shared) is the next limit.

---

## Why this stack — and the design changes that got us here

This `/nas` was previously bcachefs (single-FS hybrid). After bcachefs's `device evacuate` stalled in v1.37.5 and a wipe-while-btree-on-cache forced a 30-min `scan_for_btree_nodes` recovery + 3.8 TB of orphaned files (2026-05-08), we switched to a stack of mainline-since-2013 components, each doing one thing well.

We tried three cache designs in this session:

1. **dm-cache writeback** — `smq` policy is hot-spot-driven; sequential streams went straight to HDD (108 MB/s sustained). Even with `sequential_threshold=0`, the setting is *silently ignored* per `lvmcache(7)` ("mq is now an alias for smq, the listed mq tunables have no effect"). Wrong tool.
2. **dm-writecache** — caches every write per kernel doc, but `block_size ≤ PAGE_SIZE` (4 KiB on x86) is a hard kernel constraint. At 4 K, full 3.6 TB cachevol needs ~73 GiB metadata > 62 GiB RAM → OOM. Smaller cachevol (~2 TB) works but loses 1.6 TB of cache space.
3. **bcache** — different metadata model (B-tree, bucket-based). Buckets are 512 KiB to 8 MiB, vs dm-writecache's 4 KiB cap. Full 3.6 TB cache costs ~1 GiB RAM. Settled here.

What bcache buys vs the others:
- **Configurable bucket size** — 4 MiB is appropriate for media files; metadata cost is ~70× lower than dm-writecache.
- **`sequential_cutoff` tunable** — set to 0 to disable bypass, so all writes (including big sequential SMB copies) are absorbed by the cache. Per `Documentation/admin-guide/bcache.rst`: *"Some workloads (e.g. sequential video) work better with this set to 0."*
- **Caches reads too** (unlike dm-writecache), with adaptive LRU promotion.
- **Cache device is a pure cache** — losing both NVMes only loses dirty (not-yet-flushed) data; `bcache stop` cleanly detaches.

What we give up vs ZFS:
- No end-to-end checksums or scrub-based bit-rot detection. Mitigation: schedule monthly `sha256sum -c` against tree manifests of important paths. Not a replacement, but a sanity net.

---

## Build (one-time, destructive)

Wipes `sda`, `sdb`, `nvme1n1`, `nvme2n1`. System drive `nvme0n1` untouched.

```sh
# Pre-flight
systemctl stop smbd nmbd nas.service

# Wipe
wipefs -a /dev/sda /dev/sdb /dev/nvme1n1 /dev/nvme2n1
blkdiscard /dev/nvme1n1 /dev/nvme2n1   # full TRIM, NVMe only

# RAID
mdadm --create /dev/md0 --level=1 --raid-devices=2 --metadata=1.2 \
      --bitmap=internal --assume-clean --run /dev/sda /dev/sdb
mdadm --create /dev/md1 --level=0 --raid-devices=2 --metadata=1.2 --run \
      /dev/nvme1n1 /dev/nvme2n1
mdadm --detail --scan > /etc/mdadm/mdadm.conf

# LVM (md0 only — md1 is bcache cache, not an LVM PV)
pvcreate -ff -y /dev/md0
vgcreate vg_nas /dev/md0
lvcreate -y -n xfs_log  -L 2G   vg_nas /dev/md0   # external XFS journal, HDD-only
lvcreate -y -n nas_data -l 95%FREE vg_nas /dev/md0   # bcache backing

# bcache (writeback, 4 MiB buckets)
apt install -y bcache-tools
make-bcache --writeback --discard --bucket 4M \
            -B /dev/vg_nas/nas_data -C /dev/md1
udevadm settle

# Tunables (cache_mode is in superblock; sequential_cutoff is sysfs-only — re-applied at boot by nas.service)
echo writeback > /sys/block/bcache0/bcache/cache_mode
echo 0         > /sys/block/bcache0/bcache/sequential_cutoff

# XFS — data on /dev/bcache0, log on the HDD-only LV
mkfs.xfs -f -l logdev=/dev/vg_nas/xfs_log,size=512m -L nas /dev/bcache0
mkdir -p /nas
mount -o logdev=/dev/vg_nas/xfs_log,noatime /dev/bcache0 /nas

# Share roots
mkdir -p /nas/media /nas/st /nas/data /nas/tm
chown st:st /nas/media /nas/st /nas/data /nas/tm
chmod 755 /nas/{media,st,data,tm}

# Services
systemctl start smbd nmbd
```

---

## Mount

`nas.service` is the entry point. udev auto-registers bcache when md1 + the nas_data LV both come up at boot.

```ini
# /etc/systemd/system/nas.service
[Unit]
Description=Mount NAS storage pool (XFS over bcache writeback over mdraid)
After=systemd-modules-load.service local-fs-pre.target
Wants=local-fs-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/sbin/mdadm --assemble --scan
ExecStartPre=-/sbin/vgchange -ay vg_nas
# Wait for udev to surface /dev/bcache0
ExecStartPre=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do [ -b /dev/bcache0 ] && exit 0; sleep 1; done; echo /dev/bcache0 not found; exit 1'
# sequential_cutoff is sysfs-only and resets to default each boot
ExecStartPre=/bin/sh -c 'echo writeback > /sys/block/bcache0/bcache/cache_mode; echo 0 > /sys/block/bcache0/bcache/sequential_cutoff'
ExecStart=/usr/bin/mount -o logdev=/dev/vg_nas/xfs_log,noatime /dev/bcache0 /nas
ExecStop=/usr/bin/umount /nas

[Install]
WantedBy=multi-user.target
```

---

## Operations

### Drain cache before deleting source on the writing host

Workflow that makes the writeback risk operational, not theoretical:

```sh
sync                                                # flush page cache
echo 1 > /sys/block/bcache0/bcache/writeback_running   # already on; harmless
echo 0 > /sys/block/bcache0/bcache/writeback_percent   # drain to 0% dirty target
# poll until dirty_data hits 0
while :; do
  dirty=$(awk '{print $1}' /sys/block/bcache0/bcache/dirty_data)
  echo "dirty bytes: $dirty"
  [ "$dirty" -le 1024 ] && break
  sleep 5
done
echo 10 > /sys/block/bcache0/bcache/writeback_percent  # restore default
```

After `dirty_data ≈ 0`, every byte exists durably on the HDD mirror. Safe to delete source on the Mac.

### Inspect cache state

```sh
cat /sys/block/bcache0/bcache/cache_mode
cat /sys/block/bcache0/bcache/sequential_cutoff
cat /sys/block/bcache0/bcache/dirty_data
cat /sys/fs/bcache/*/cache_available_percent
cat /sys/block/bcache0/bcache/stats_total/cache_hit_ratio
```

### Replace a failed HDD

```sh
mdadm --manage /dev/md0 --replace /dev/<failed-id> --with /dev/<new-id>
cat /proc/mdstat   # watch resync
```

### Replace a failed NVMe

RAID0 cache means a single NVMe failure takes the whole cache offline. Dirty blocks at the moment of failure are lost (the documented trade). Recovery:

```sh
# 1. Stop bcache cache set, then stop md1
echo 1 > /sys/fs/bcache/<cset_uuid>/stop
mdadm --stop /dev/md1

# 2. Replace failed NVMe physically; rebuild md1
wipefs -a /dev/<surviving-nvme> /dev/<new-nvme>
mdadm --create /dev/md1 --level=0 --raid-devices=2 --metadata=1.2 --run \
      /dev/<surviving-nvme> /dev/<new-nvme>

# 3. Re-create bcache cache set and attach to existing backing
make-bcache --writeback --discard --bucket 4M -C /dev/md1
echo <new_cache_set_uuid> > /sys/block/bcache0/bcache/attach
```

---

## Failure modes

| Failure | Effect | Recovery |
|---|---|---|
| 1 HDD dies | RAID1 degraded; FS keeps running at half write throughput | `mdadm --replace`; auto-resync |
| 1 NVMe dies | RAID0 cache pool fails → bcache transitions cache to error state; **dirty blocks lost** | rebuild md1 → re-create cache → re-attach |
| Both NVMes die | same as above | same as above |
| Both HDDs die | catastrophic — no truth | restore from backup |
| Power loss with dirty cache | dirty blocks pre-flush are lost | XFS replays journal from `xfs_log` (on HDD); FS is consistent |
| Cache device hot-removed | bcache halts the bcache0 device | re-create cache and re-attach |

Bit-rot is **not detected** by this stack — there's no per-block checksum. Mitigation: periodic `sha256sum -c` against tree manifests of important paths (Photos, source code, models). Schedule monthly.

---

## Samba shares

| Share | Path | Access | Notes |
|---|---|---|---|
| media | `/nas/media` | `st`, `laksh` | `force user = st`, `force group = st` — laksh writes land as `st:st` on disk |
| st | `/nas/st` | `st` | |
| data | `/nas/data` | `st` | |
| iris | `/var/iris/clips` | `st` | `st` is in the `iris` group; dir is `st:iris 2770` (setgid) so iris-service-written clips inherit group `iris` and st can delete via group write. Iris service runs locally and writes to `/var/iris/`; only `clips/` is exposed to SMB. |
| tm | `/nas/tm` | `st` | Time Machine, 4 TB cap (`fruit:time machine max size = 4000G`) |

Share roots are owned `st:st` (or `st:iris` for iris). Writers running outside Samba (root, systemd units, containers) should `sudo -u st` or set `User=st` in their unit — otherwise they create files st can't manage via SMB.

Users are POSIX accounts (`tdbsam` backend requires `getpwnam()` to resolve). SMB-only users get a stub Linux account: `useradd -M -s /usr/sbin/nologin <name>` then `smbpasswd -a <name>`. Currently `st` (full) and `laksh` (media only).

Config: SMB3 minimum, macOS fruit/AAPL extensions, NetBIOS disabled, `access based share enum = yes` (each user sees only the shares they can connect to in enumeration). Samba's `vfs objects = catia fruit streams_xattr` requires `samba-vfs-modules` (Ubuntu's `samba` meta-package doesn't pull it).

Mac mounts: `smb://lab.local/media` → `/Volumes/media` (Samba advertises NetBIOS name `nas`; mDNS hostname is still `lab.local`).
Linux symlinks: `/Volumes/media` → `/nas/media`, `/Volumes/st` → `/nas/st`
