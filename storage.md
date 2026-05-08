# Storage

## At a glance

Two-tier hybrid on `/nas`. **HDDs are the truth, NVMes are pure cache.** XFS on top.

| Layer | Devices | Role |
|---|---|---|
| HDD truth | 2× Seagate Exos 14 TB → `mdadm` RAID1 → `/dev/md0` | Durable storage; survives 1-disk loss; ~12.7 TB usable |
| NVMe cache | WD SN850X 2 TB + Samsung 990 Pro 2 TB → `mdadm` RAID0 → `/dev/md1` | Hot cache; ~3.6 TB; **single NVMe failure loses dirty data — accepted because we keep source until we verify NAS-side flush** |
| LVM | VG `vg_nas` over `md0` + `md1` | `nas_data` (cached LV, the FS), `xfs_log` (external journal pinned to `md0`) |
| Cache attach | `lvconvert --type cache --cachevol nas_cache --cachemode writeback` | dm-cache writeback: writes ack on NVMe, async-flush to HDD |
| Filesystem | XFS on `/dev/vg_nas/nas_data`, log on `/dev/vg_nas/xfs_log` | Journal on HDD survives total cache loss, FS recovers cleanly |

```
sda  ─┐
sdb  ─┤── mdadm RAID1 ── md0 ──┐
                               ├── vg_nas ─┐
nvme1n1 ─┐                     │           ├── nas_data (XFS data, cached)  ── /nas
nvme2n1 ─┤── mdadm RAID0 ── md1 ─┘         │      ↑
                                           │      │ writeback cache
                                           │      ▼ (async flush)
                                           ├── nas_cache (NVMe-only LV, dm-cache vol)
                                           │
                                           └── xfs_log  (HDD-only LV, XFS external journal)
```

Mount: `nas.service` (systemd unit, not fstab — see §Mount).

---

## Why this stack

After bcachefs's `device evacuate` stalled in v1.37.5 and a wipe-while-btree-on-cache caused a 30 min `scan_for_btree_nodes` recovery + 3 TB of orphaned data on 2026-05-08, we switched to a stack of mainline-kernel-since-2014 components, each doing one thing well:

- **mdadm + RAID1** — boring, proven, well-understood mirror. `mdadm --replace` is the canonical disk-swap path. Single-HDD failure tolerated; resync from the survivor when replaced.
- **mdadm + RAID0 on NVMes** — doubles cache capacity (3.6 TB vs 1.8 TB single device) and doubles raw bandwidth. Single-NVMe failure loses the cache pool; **acceptable trade because the source is still on the writing host until the operator confirms the cache has flushed to HDD** (see §Operations / cache flush).
- **LVM dm-cache (writeback)** — the kernel's writeback cache layer. Per `Documentation/admin-guide/device-mapper/cache.rst`: writes hit the cache, ack, then drain to backing in the background. Cache device removable online via `lvconvert --uncache` if you need to swap NVMes.
- **XFS with external log on HDD** — the journal lives on `xfs_log` (an LV pinned to `md0`), *not* in the cached LV. Total cache loss leaves a coherent journal on HDD; XFS replays cleanly. This is the analog of `data_allowed=user` from the old bcachefs setup — the *enforcement* that metadata never lives on cache.

What we give up vs the alternatives, honestly:

- vs **ZFS mirror + special vdev** — no end-to-end checksums, no scrub-based bit-rot detection. Mitigation: monthly file-level integrity check (e.g., `sha256sum -c`) on tree manifests of important paths.
- vs **bcachefs** — no native filesystem-level cache integration; one more layer to reason about. Mitigation: each layer has a 10+ year track record and well-defined recovery commands.

What we keep:

- True writeback cache: foreground writes ack at NVMe speed.
- Read cache: hot blocks promoted to NVMe automatically by dm-cache.
- HDD truth: every byte on HDD is mirrored across both Exos drives.
- Cache safely wipeable: any NVMe operation (replace, swap, wipe, resize) cannot break the FS, because the journal and metadata live on HDD.

---

## Build (one-time, destructive)

The complete formatting sequence. **Wipes sda, sdb, nvme1n1, nvme2n1.** System drive `nvme0n1` is untouched.

```sh
# Pre-flight: stop everything that touches /nas
systemctl stop smbd nmbd nas.service

# Wipe any prior FS signatures on the four data drives
wipefs -a /dev/sda /dev/sdb /dev/nvme1n1 /dev/nvme2n1
blkdiscard /dev/nvme1n1 /dev/nvme2n1   # SSDs only, full TRIM

# RAID1 across HDDs (truth tier)
mdadm --create /dev/md0 --level=1 --raid-devices=2 \
      --metadata=1.2 --bitmap=internal \
      /dev/sda /dev/sdb

# RAID0 across NVMes (cache tier)
mdadm --create /dev/md1 --level=0 --raid-devices=2 \
      --metadata=1.2 \
      /dev/nvme1n1 /dev/nvme2n1

# Persist mdadm config so arrays assemble at boot
mdadm --detail --scan >> /etc/mdadm/mdadm.conf
update-initramfs -u

# LVM
pvcreate /dev/md0 /dev/md1
vgcreate vg_nas /dev/md0 /dev/md1

# Pinned-to-HDD external journal (small, separate LV on md0 only)
lvcreate -n xfs_log -L 2G vg_nas /dev/md0

# Backing LV (XFS data) on HDDs
lvcreate -n nas_data -l 95%FREE vg_nas /dev/md0

# Cache vol on NVMes
lvcreate -n nas_cache -l 95%FREE vg_nas /dev/md1

# Attach cache (writeback). 'cachevol' style is the modern simpler form.
lvconvert --yes --type cache \
          --cachevol vg_nas/nas_cache \
          --cachemode writeback \
          vg_nas/nas_data

# Format: XFS data on the cached LV, journal on the HDD-only LV
mkfs.xfs -f -l logdev=/dev/vg_nas/xfs_log /dev/vg_nas/nas_data

# Mount
mkdir -p /nas
mount -o logdev=/dev/vg_nas/xfs_log,noatime /dev/vg_nas/nas_data /nas

# Share roots + ownership
mkdir -p /nas/media /nas/st /nas/data /nas/tm
chown st:st /nas/media /nas/st /nas/data /nas/tm
chmod 755 /nas/{media,st,data,tm}

# Bring services back
systemctl start smbd nmbd
```

After verification, persist via the `nas.service` mount unit (see below).

---

## Mount

Old `nas.service` was a `bcachefs mount` wrapper. The replacement is a normal mount. Either `/etc/fstab` or a systemd unit; we use a unit to keep the boot dependency on `multi-user.target` and avoid hanging boot if a drive is missing.

```ini
# /etc/systemd/system/nas.service
[Unit]
Description=Mount NAS storage pool (XFS over LVM cache over mdraid)
After=systemd-modules-load.service local-fs-pre.target
Wants=local-fs-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/mdadm --assemble --scan
ExecStartPre=/sbin/vgchange -ay vg_nas
ExecStart=/usr/bin/mount -o logdev=/dev/vg_nas/xfs_log,noatime /dev/vg_nas/nas_data /nas
ExecStop=/usr/bin/umount /nas

[Install]
WantedBy=multi-user.target
```

Equivalent fstab entry, if preferred:

```
/dev/vg_nas/nas_data  /nas  xfs  defaults,noatime,logdev=/dev/vg_nas/xfs_log  0  2
```

---

## Operations

### Drain cache before deleting source on the writing host

The point of using a writeback cache safely. Workflow on the lab box after a big copy:

```sh
sync                                                       # flush page cache to dm-cache
dmsetup message vg_nas-nas_data 0 cleaner 1                # tell dm-cache to flush all dirty
# poll until dirty hits 0
while :; do
  dirty=$(lvs --noheadings -o cache_dirty_blocks vg_nas/nas_data | tr -d ' ')
  echo "dirty: $dirty"
  [ "$dirty" = "0" ] && break
  sleep 5
done
echo "safe to delete source on the Mac"
```

Once `cache_dirty_blocks=0`, every byte exists on the HDD mirror and the source can be deleted.

### Inspect cache state

```sh
lvs -o name,cache_mode,cache_settings,cache_used_blocks,cache_dirty_blocks,cache_total_blocks vg_nas/nas_data
```

`cache_used_blocks` is total cache occupancy (clean + dirty). `cache_dirty_blocks` is the at-risk subset.

### Replace a failed HDD

```sh
mdadm --manage /dev/md0 --replace /dev/<failed-id> --with /dev/<new-id>
# resync runs in the background; check with:
cat /proc/mdstat
```

### Replace a failed NVMe

RAID0 of the cache pool means a single NVMe failure takes the cache offline. The FS keeps working — dm-cache transitions to direct-HDD mode for blocks not in the (now-gone) cache. **Any dirty blocks at the moment of failure are lost** (consistent with the trade we explicitly accepted). Recovery sequence:

```sh
# 1. Detach cache from the data LV (so LVM stops trying to use the dead md1)
lvconvert --uncache vg_nas/nas_data

# 2. Stop and rebuild md1 with the surviving + new NVMe
mdadm --stop /dev/md1
wipefs -a /dev/<new-nvme>
mdadm --create /dev/md1 --level=0 --raid-devices=2 --metadata=1.2 \
      /dev/<surviving-nvme> /dev/<new-nvme>

# 3. Recreate cache vol and re-attach
lvcreate -n nas_cache -l 95%FREE vg_nas /dev/md1
lvconvert --yes --type cache --cachevol vg_nas/nas_cache --cachemode writeback vg_nas/nas_data
```

### Resize the cache

```sh
lvconvert --uncache vg_nas/nas_data
lvresize -L <new-size> vg_nas/nas_cache
lvconvert --yes --type cache --cachevol vg_nas/nas_cache --cachemode writeback vg_nas/nas_data
```

---

## Failure modes

| Failure | Effect | Recovery |
|---|---|---|
| 1 HDD dies | RAID1 degraded; FS keeps running at half write throughput | `mdadm --replace`; auto-resync |
| 1 NVMe dies | RAID0 cache pool fails; dm-cache enters passthrough; **dirty blocks lost** | uncache → rebuild md1 → re-attach cache |
| Both NVMes die | same as above (cache gone, dirty lost) | same as above |
| Both HDDs die | catastrophic — no truth | restore from backup |
| Power loss with dirty cache | dirty blocks pre-flush are lost | XFS replays journal from `xfs_log` (on HDD); FS itself is consistent |
| Cache device hot-removed | dm-cache halts, FS suspends until LVM responds | `lvconvert --uncache` (force), then proceed as failed-NVMe recovery |

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
