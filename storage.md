# Storage

## At a glance

Two-tier hybrid on `/nas`. **HDDs are the truth, NVMes are pure write-back cache.** XFS on top of bcache.

| Layer | Devices | Role |
|---|---|---|
| HDD truth | 2× Seagate Exos 14 TB → `mdadm` RAID1 → `/dev/md0` | Durable storage; survives 1-disk loss; ~12.7 TB usable |
| NVMe cache | WD SN850X 2 TB + Samsung 990 Pro 2 TB → **`mdadm` RAID1** → `/dev/md1` | Hot cache; **1.86 TB** mirrored; **single NVMe failure: no FS impact** (cache survives on the other drive) |
| LVM | `vg_nas` over `md0` only | `nas_data` (bcache backing) + `xfs_log` (XFS external journal) |
| **bcache** | `/dev/md1` cache + `/dev/vg_nas/nas_data` backing → `/dev/bcache0` | **writeback** mode, 4 MiB buckets, `sequential_cutoff=0` (cache absorbs all I/O), ~0.5 GiB RAM |
| Filesystem | XFS on `/dev/bcache0`, log on `/dev/vg_nas/xfs_log` | Journal on HDD; replays on power-loss with cache intact |

```
sda  ─┐
sdb  ─┤── mdadm RAID1 ── md0 ── vg_nas ─┬── nas_data (bcache backing) ─┐
                                        │                              ├── /dev/bcache0 ── XFS ── /nas
                                        └── xfs_log (XFS journal)      │            (writeback)
                                                                       │
nvme1n1 ─┐                                                             │
nvme2n1 ─┤── mdadm RAID1 ── md1 ─────────────── (bcache cache device) ─┘
                  (mirrored — single NVMe failure tolerated)
```

Mount: `nas.service` (systemd unit, not fstab — see §Mount).

## Measured speeds (kernel 7.0.5, bucket 4M, sequential_cutoff=0, RAID1 cache)

| Workload | Throughput |
|---|---|
| `dd 4 GB direct, bs=4M` | **2.6 GB/s** |
| `dd 8 GB direct, bs=4M` | 2.7 GB/s |
| `dd 16 GB direct, bs=4M` | 2.8 GB/s |
| `dd 32 GB direct, bs=4M` | 2.8 GB/s — still SSD-rate, no throttle |
| `dd 4 × 8 GB parallel direct` | ~890 MB/s per stream → ~3.5 GB/s aggregate |
| `dd 4 GB read, cold cache` | 7.1 GB/s (page-cache + cache assisted) |
| Sustained writes after cache fills (~1.8 TB) | ~150 MB/s (HDD drain rate) |

The cache absorbs writes at ~2.7 GB/s sustained — bounded by single-NVMe write speed because RAID1 mirrors every write to both drives. That's ~20× HDD speed and well above what SMB single-channel can deliver. We chose RAID1 over RAID0 for the **safety guarantee that a single NVMe failure cannot corrupt the FS**.

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

# RAID — both arrays mirrored (md0 = HDD truth, md1 = NVMe cache mirror)
mdadm --create /dev/md0 --level=1 --raid-devices=2 --metadata=1.2 \
      --bitmap=internal --assume-clean --run /dev/sda /dev/sdb
mdadm --create /dev/md1 --level=1 --raid-devices=2 --metadata=1.2 \
      --bitmap=internal --assume-clean --run /dev/nvme1n1 /dev/nvme2n1
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

### Replace a failed NVMe (md1 RAID1)

Single NVMe failure: the array goes degraded but bcache continues from the surviving drive. **No data loss, no FS impact.**

```sh
# Optional but recommended: confirm the failed drive
cat /proc/mdstat
mdadm --detail /dev/md1

# Replace the failed drive physically, then re-add to the mirror
wipefs -a /dev/<new-nvme>
mdadm --add /dev/md1 /dev/<new-nvme>
# auto-resync; watch via:
cat /proc/mdstat
```

### Recover from total cache loss (both NVMes failed)

This is the unlikely case where both NVMes failed simultaneously with dirty data. **Per `bcache.rst`, expect filesystem corruption.** The recovery is lossy:

```sh
# 1. Force-run backing without cache (lossy — FS will be inconsistent)
echo 1 > /sys/block/<backing>/bcache/running

# 2. CRITICAL: do NOT mount yet. Run xfs_repair first.
xfs_repair -n -l /dev/vg_nas/xfs_log /dev/bcache0    # dry-run, expect errors
xfs_repair -l /dev/vg_nas/xfs_log /dev/bcache0       # commit repair

# 3. Rebuild md1 from new NVMes, recreate cache, re-attach to backing
mdadm --stop /dev/md1
mdadm --create /dev/md1 --level=1 --raid-devices=2 --metadata=1.2 \
      --bitmap=internal --assume-clean --run /dev/<nvme-1> /dev/<nvme-2>
make-bcache --writeback --discard --bucket 4M -C /dev/md1
echo <new_cache_set_uuid> > /sys/block/bcache0/bcache/attach

# 4. Mount and inspect what survived
mount -o logdev=/dev/vg_nas/xfs_log,noatime /dev/bcache0 /nas
ls /nas/lost+found  # repair-relocated files end up here
```

Files that had data fully migrated to HDD: intact. Files with metadata-only-in-cache writes: likely in `lost+found` with inode-numbered names. Restore what you can; replace what you can't.

---

## Failure modes

| Failure | Effect | Recovery |
|---|---|---|
| 1 HDD dies | RAID1 degraded; FS keeps running | `mdadm --replace`; auto-resync |
| **1 NVMe dies** | **md1 RAID1 degraded; cache continues serving from surviving drive. No FS impact, no dirty data loss.** | replace failed NVMe, `mdadm --add`, auto-resync |
| Both NVMes die | bcache cache lost; if dirty data was in flight, **expect FS corruption per `bcache.rst`** ("don't expect the filesystem to be recoverable - massive filesystem corruption"). The XFS external log on HDD does *not* save you — it replays metadata against a data device whose recent writes were trapped in the dead cache. | force-run backing → `xfs_repair -n` (dry) → `xfs_repair` → mount; expect file/folder loss + lost+found content |
| Both HDDs die | catastrophic — no truth | restore from backup |
| Power loss with cache intact | dirty data preserved on cache; bcache journal + XFS log replay produce consistent FS on next mount | nothing to do; mount as normal |
| Cache device hot-removed (mid-operation) | `stop_when_cache_set_failed=auto` halts /dev/bcache0; if dirty, FS may need repair | replace, re-create cache, re-attach; run `xfs_repair` first |

Bit-rot is **not detected** by this stack — there's no per-block checksum. Mitigation: periodic `sha256sum -c` against tree manifests of important paths (Photos, source code, models). Schedule monthly.

### Why single NVMe failure is safe

Writeback mode means file *data* and XFS *metadata* both route through bcache. If the cache device dies with dirty blocks (writes that haven't drained to HDD yet), you don't just lose those file bytes — you lose XFS metadata that may reference unrelated parts of the filesystem (per `Documentation/admin-guide/bcache.rst` line 121: *"don't expect the filesystem to be recoverable"*). The XFS journal on a separate LV survives, but it replays metadata operations against the data device's stale state and cannot reconstruct lost cache content.

RAID1 of the NVMe cache pool fixes this for single-NVMe failure: when one drive dies, mdraid serves the cache from the surviving drive, bcache keeps running, no dirty data is lost. Two simultaneous NVMe failures is the only path to the corruption case above — rare with proper SMART monitoring + drive replacement.

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
