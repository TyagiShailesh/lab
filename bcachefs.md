# bcachefs on lab (192.168.1.10)

Single reference for how `/nas` is built, mounted, and maintained. **Samba paths and light summary:** [storage.md](storage.md). **Kernel build pipeline:** [kernel/README.md](kernel/README.md), [kernel/build-kernel.sh](kernel/build-kernel.sh).

---

## 1. Design goal

> **SSDs give hot-path speed. HDDs hold the truth.**

- Foreground writes and hot reads hit the SSD tier at NVMe latency.
- The authoritative copies of **user data** and **all metadata (journal + btree)** live on the HDD tier.
- SSDs carry **only user data** as writeback cache — never journal, never btree.
- Losing both SSDs costs only the in-transit user data (extents written to SSD but not yet migrated to HDDs). Journal and btree survive entirely on the HDDs, so the FS itself stays mountable.
- Losing one HDD leaves the other HDD holding a full copy of data + btree + journal.
- The cache tier is **safely wipeable at any time** — `data_allowed=user` is the hard gate enforcing this. See pre-wipe checklist in [storage.md](storage.md#cache-tier-design).

Hardware is final — this is the single intended layout, not a "plan."

---

## 2. Role in the stack

| Path | Role |
|------|------|
| `/nas` | Bulk storage: media, user data, Time Machine, backups, model files, firmware archives |
| `/var/iris` | Iris service working dir. Local to boot SSD (9100); not on bcachefs. |

All Samba shares live under `/nas` except `iris`, which is served from `/var/iris/clips` ([storage.md](storage.md)).

bcachefs is **not** in the mainline kernel tree for this lab; it ships as an **out-of-tree module** built from [koverstreet/bcachefs-tools](https://github.com/koverstreet/bcachefs-tools) pinned to the same tag as the userspace `bcachefs` binary ([kernel/build-kernel.sh](kernel/build-kernel.sh)).

---

## 3. Architecture

```
                ┌───────────────────────────────────────────┐
                │  bcachefs single filesystem (/nas)        │
                └───────────────────────────────────────────┘
                                    │
         ┌──────────────────────────┼──────────────────────────┐
         │                          │                          │
   ┌─────▼─────┐              ┌──────▼──────┐           ┌───────▼───────┐
   │ SSD tier  │  foreground  │  HDD tier   │  promote  │  reconcile    │
   │ (label:   │  user-data   │ (label:     │  cache    │  (background  │
   │  ssd)     │  writes only │  hdd)       │  back to  │  moves SSD →  │
   │ user only │  ack at      │ journal +   │  SSD      │  HDD; SSD     │
   │ no journal│  NVMe speed  │ btree +     │           │  pointer      │
   │ no btree  │              │ user truth  │           │  dropped)     │
   └───────────┘              └─────────────┘           └───────────────┘
```

- Foreground writes: `foreground_target=ssd`. Single SSD bucket per write satisfies replicas (`durability=2`).
- Reconcile to durable tier: `background_target=hdd`. Migrates and **drops the SSD pointer** after move.
- Promote hot reads: `promote_target=ssd`.
- Metadata preference: `metadata_target=hdd` (combined with `data_allowed=user` on SSDs as the hard gate — see §4).
- Compression: `compression=none` foreground, `background_compression=zstd` on HDD migration.
- Replication: `data_replicas=2`, `metadata_replicas=2`, each durable copy on a distinct HDD.

Official docs: [bcachefs.org — Caching](https://bcachefs.org/Caching/), [Principles of Operation (PDF)](https://bcachefs.org/bcachefs-principles-of-operation.pdf).

---

## 4. Core decisions

### 4.1 Per-device durability

| Label | `durability` | Effect on `data_replicas=2` |
|---|---|---|
| `hdd` | 1 | A single HDD bucket = 1 replica. Two HDDs needed to satisfy. |
| `ssd` | 2 | A single SSD bucket = 2 replicas. One SSD bucket alone satisfies. |

The SSD `durability=2` claim is dishonest in the literal sense (one NVMe is one physical copy, not two), but it's how bcachefs expresses **"this device is the one-and-done foreground target"**. The allocator (`alloc/foreground.c:add_new_bucket`) stops adding pointers once `nr_effective ≥ nr_replicas`, so foreground writes ack at single-NVMe speed without an HDD pointer in the synchronous path. Background reconcile then materializes the real 2× HDD copies.

We accept the in-transit loss window (SSDs die before `background_target=hdd` migration completes → those bytes are gone). See trade-offs in [storage.md](storage.md#cache-tier-design).

### 4.2 `data_allowed` is the hard gate

This is what actually enforces the design goal — `metadata_target` and `foreground_target` are *preferences*, but `data_allowed` is *enforcement* at the device level. The kernel refuses to place excluded data types on a device regardless of FS-level options.

| Device label | `data_allowed` | Effect |
|---|---|---|
| `ssd` (SN850X, 990 Pro) | `user` | No journal, no btree on SSDs. User-data writeback cache only. |
| `hdd` (Exos ×2) | `journal,btree,user` | All data types — journal and btree truth, plus reconciled user data. |

Consequence: `metadata_replicas=2` places both btree copies on HDDs (the only devices that allow btree). Journal replicas also land on HDDs only. SSDs can be wiped at any time without breaking metadata or losing the FS — only un-migrated user data is at risk.

**Lesson from 2026-05-08:** the previous design had `data_allowed=journal,user` on SSDs. Btree leaked onto SSDs anyway (visible in `show-super` as `Has data: btree`) — apparently older btree placement persisted across `metadata_target` changes. Wiping the SSDs without first draining metadata broke topology and forced a 30-minute `scan_for_btree_nodes` recovery + ~3.8 TB of user files relocated to `/nas/lost+found/`. **Always verify `Has data` before destruction** — see pre-wipe checklist in [storage.md](storage.md#cache-tier-design).

### 4.3 What happens on device loss

| Failure | Journal | Btree | User data | Recovery |
|---|---|---|---|---|
| 1 SSD | untouched on HDDs | untouched on HDDs | in-transit on lost SSD = gone; migrated copies on HDDs intact | replace SSD, `bcachefs device remove -f -F` old, `device add` new |
| **Both SSDs** | **untouched on HDDs** | **untouched on HDDs** | only in-transit data lost (extents written but not yet migrated) | replace SSDs, `device remove -f -F` × 2, `device add` × 2; FS stays mountable throughout |
| 1 HDD | 1 copy remaining on other HDD | 1 copy remaining on other HDD | 1 copy remaining on other HDD; SSD cache copies still hot | replace HDD, reconcile repopulates |
| Both HDDs | lost | lost | catastrophic | restore from backup |

**Backups still matter — a dual-HDD failure loses everything that wasn't on the SSDs.** SSD-only failures are now fully tolerated.

### 4.4 Writeback semantics

Per [bcachefs.org — Caching](https://bcachefs.org/Caching/) §2.2.4.1 + manual §8.5.4 + source confirmation in `alloc/foreground.c:add_new_bucket` + `data/reconcile/trigger.c`: with `foreground_target=ssd` and SSD `durability=2`, foreground writes ack after **one SSD copy** lands (`nr_effective += durability` → 2 ≥ data_replicas → done). The reconcile pass then walks each extent and, for any pointer not on `background_target`, schedules a *move* (not copy) to a `background_target` device — the SSD pointer is **dropped** after migration. Promote on read repopulates SSD cache via `promote_target=ssd` independently.

End state for any quiesced extent: 2× durable copies on HDDs, 0× or 1× cache copy on an SSD depending on read activity. **fsync** stays at HDD latency because journal is on HDDs (the trade we accepted to make the cache tier safely wipeable).

---

## 5. Devices

Kernel names (`sda`, `nvme2n1`) **change across reboots**. Always use **`/dev/disk/by-id/...`** in scripts, systemd units, and documentation.

| Role | Model | Size | Label | `durability` | `data_allowed` | Stable by-id |
|------|-------|------|-------|---|---|---|
| Data (HDD) | Seagate Exos ST14000NM000J | 14 TB | `hdd` | 1 | `journal,btree,user` | `ata-ST14000NM000J-2TX103_ZR900CTB` |
| Data (HDD) | Seagate Exos ST14000NM001G | 14 TB | `hdd` | 1 | `journal,btree,user` | `ata-ST14000NM001G-2KJ103_ZLW212GF` |
| Cache (NVMe) | WD_BLACK SN850X HS | 2 TB | `ssd` | 2 | `user` | `nvme-WD_BLACK_SN850X_HS_2000GB_24364L800813` |
| Cache (NVMe) | Samsung 990 Pro | 2 TB | `ssd` | 2 | `user` | `nvme-Samsung_SSD_990_PRO_2TB_S7KHNU0Y517886B` |

Both SSDs live on the chipset Gen4 path (M.2_2 + M.2_4), symmetric — replicated writes are not bounded by the slower partner. The 9100 Pro on M.2_1 (Gen5 CPU-direct) is deliberately **outside** the pool: it's the boot drive + hot model cache for inference workloads; using it as a pool member capped its Gen5 bandwidth at the slower SSD's Gen4 speed.

---

## 6. Filesystem identity

- **Filesystem UUID** (mount, identify): get with `bcachefs show-super /dev/disk/by-id/<member>` → `External UUID` / filesystem id.
- **Members** are tracked by **per-device UUIDs** in the superblock, not by `sda`/`nvme2n1`. As long as the block device appears (any name), bcachefs assembles the pool.

**Recommended mount:** `UUID=<fs-uuid> /nas bcachefs ...` so adding/removing devices does not require editing device lists. Colon-separated device lists still work for discovery.

---

## 7. Boot and systemd (not fstab)

Root filesystem may use kernel cmdline; **bcachefs is not in `/etc/fstab`** on this machine. Mount is handled by:

| Item | Location |
|------|----------|
| Unit | `/etc/systemd/system/nas.service` |
| Enable | `systemctl enable nas.service` |
| Wants | `multi-user.target` |

**Live unit (UUID mount via bcachefs userspace helper):**

```ini
[Unit]
Description=Mount NAS storage pool
# Wants= (not Requires=) so a missing disk doesn't hang boot.
# Device discovery by filesystem UUID — independent of sda/nvmeN enumeration.
After=systemd-modules-load.service

[Service]
ExecStartPre=/sbin/modprobe bcachefs
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/bcachefs mount -o version_upgrade=none UUID=034fb932-bf25-48ef-a477-e4b971a7230e /nas
ExecStop=/usr/bin/umount /nas

[Install]
WantedBy=multi-user.target
```

Why `/usr/local/sbin/bcachefs mount` and not `/usr/bin/mount -t bcachefs UUID=…`: `mount(8)` doesn't invoke the userspace scanner that locates pool members by filesystem UUID, so the kernel only sees one device and refuses with `insufficient_devices_to_start`. `bcachefs mount` does the userspace scan first, then mounts.

**Avoid** `Requires=dev-sda.device dev-sdb.device`: if enumeration swaps, those units never become active and boot can hang.

**Stop / start:**

```bash
systemctl stop nas    # umount /nas
systemctl start nas   # modprobe + mount
```

---

## 8. Kernel module and userspace (build)

Pinned versions live in **[kernel/build-kernel.sh](kernel/build-kernel.sh)** (e.g. `bcachefs_tag=v1.37.5`, kernel `linux-7.x` tarball).

| Artifact | Typical path on target |
|----------|-------------------------|
| Kernel module | `/usr/lib/modules/<kver>/kernel/fs/bcachefs/bcachefs.ko` |
| Userspace | `/usr/local/sbin/bcachefs` |
| Autoload | `/etc/modules-load.d/bcachefs.conf` (optional; service also `modprobe`s) |

Build steps (summary):

1. Build kernel + `modules_install` to staging.
2. `make -C src/bcachefs-tools install_dkms` → compile OOT module against that kernel's `Module.symvers`.
3. Copy `bcachefs.ko` into staging `kernel/fs/bcachefs/`.
4. Build `bcachefs` binary from same tree; package into tarball (`images/linux-*.tar.zst`).

Kernel `.config` enables dependencies used by bcachefs (e.g. `CRYPTO_LZ4`, `CRYPTO_LZ4HC`, `BLK_DEV_INTEGRITY`) — see `build-kernel.sh` `scripts/config` block.

**Rust:** upstream bcachefs is moving toward requiring `CONFIG_RUST` in the kernel. `kernel/build-kernel.sh` enables `CONFIG_RUST` via `scripts/config` and relies on `RUST_IS_AVAILABLE` to turn it on once the host has `rustc` + `rust-src` + `bindgen-cli` + `libclang-dev`.

---

## 9. Operations cheat sheet

```bash
# Pool usage and replication breakdown
bcachefs fs usage -h /nas
bcachefs fs usage -h -a /nas          # all accounting: btree, devices, compression, etc.

# Superblock / options
bcachefs show-super /dev/disk/by-id/<member>

# Per-device options (durability, data_allowed, state) live in the superblock;
# inspect with show-super and change with set-option (verify exact flags in your
# tool version via `bcachefs device --help` / `bcachefs set-option --help`).

# Rebalance / reconcile progress (name varies with version)
bcachefs fs usage -h -a /nas          # look at dirty / cached / reconciled accounting
```

---

## 10. Verify the running config matches this doc

After any change to devices, replication, or `data_allowed`, confirm:

```bash
# Members, labels, per-device durability and data_allowed
bcachefs show-super /dev/disk/by-id/ata-ST14000NM000J-2TX103_ZR900CTB \
  | grep -E 'Device:|Label:|Durability:|Allowed|UUID'

# Filesystem-wide targets and replicas
bcachefs show-super /dev/disk/by-id/ata-ST14000NM000J-2TX103_ZR900CTB \
  | grep -E 'replicas|target|compression'

# Live accounting — btree should sit on hdd devices only, journal on ssd only
bcachefs fs usage -h -a /nas
```

Expected:

- `data_replicas 2`, `metadata_replicas 2`
- `foreground_target ssd`, `background_target hdd`, `promote_target ssd`, `metadata_target hdd`
- Each HDD: `durability 1`, `data_allowed journal,btree,user`
- Each SSD: `durability 2`, `data_allowed user` (no journal, no btree)
- `bcachefs fs usage -a` shows btree and journal bytes only on HDD devices; SSD `Has data` should be `user` (or `user,cached`) only.

---

## 11. Related docs in this repo

| File | Contents |
|------|----------|
| [storage.md](storage.md) | Samba shares, short pool note |
| [kernel/README.md](kernel/README.md) | Full kernel/bcachefs/NVIDIA build narrative |
| [kernel/build-kernel.sh](kernel/build-kernel.sh) | Pinned tags, staging layout, verification |
| [hardware.md](hardware.md) | Physical slot mapping |
