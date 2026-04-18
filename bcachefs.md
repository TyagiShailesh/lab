# bcachefs on lab (192.168.1.10)

Single reference for how `/nas` is built, mounted, and maintained. **Samba paths and light summary:** [storage.md](storage.md). **Kernel build pipeline:** [kernel/README.md](kernel/README.md), [kernel/build-kernel.sh](kernel/build-kernel.sh). **Historical migrations:** [migrate-bcachefs.md](migrate-bcachefs.md) (SSD-split + data_allowed redesign).

---

## 1. Design goal

> **SSDs give hot-path speed. HDDs hold the truth.**

- Foreground writes and hot reads hit the SSD tier at NVMe latency.
- The authoritative copies of **user data** and **all metadata (btree)** live on the HDD tier.
- SSDs carry only the **journal** and **user data** (as writeback cache) — never btree.
- Losing both SSDs costs at most the last few seconds of un-flushed journal. btree and reconciled data survive on the HDDs.
- Losing one HDD leaves the other HDD holding a full copy of data + btree.

Hardware is final — this is the single intended layout, not a "plan."

---

## 2. Role in the stack

| Path | Role |
|------|------|
| `/nas` | Bulk storage: media, user data, Time Machine, backups, model files, firmware archives |
| `/var/iris` | Iris service working dir. Local to boot SSD (9100); not on bcachefs. |

All Samba shares live under `/nas` except `iris`, which is served from `/var/iris` ([storage.md](storage.md)).

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
   │ (label:   │  + journal   │ (label:     │  cache    │  (background  │
   │  ssd)     │  + user data │  hdd)       │  back to  │  moves,       │
   │ no btree  │  (writeback) │ btree+user  │  SSD      │  replication) │
   └───────────┘              └─────────────┘           └───────────────┘
```

- Foreground writes: `foreground_target=ssd`.
- Reconcile to durable tier: `background_target=hdd`.
- Promote hot reads: `promote_target=ssd`.
- Metadata preference: `metadata_target=hdd` (forced — see §4).
- Compression: `compression=none` foreground, `background_compression=zstd` on HDD migration.
- Replication: `data_replicas=2`, `metadata_replicas=2`, each copy on a distinct device.

Official docs: [bcachefs.org — Caching](https://bcachefs.org/Caching/), [Principles of Operation (PDF)](https://bcachefs.org/bcachefs-principles-of-operation.pdf).

---

## 4. Core decisions

### 4.1 Durability 1 on every device

All four pool members are `durability=1`. One physical copy counts as one replica. With `data_replicas=2` and `metadata_replicas=2` this means two copies on two distinct devices — no device "double-counts."

### 4.2 `data_allowed` splits journal from btree

This is the mechanism that enforces the design goal:

| Device label | `data_allowed` | Effect |
|---|---|---|
| `ssd` (SN850X, 9100 Pro) | `journal,user` | No btree on SSDs. Journal + user-data writeback cache only. |
| `hdd` (Exos ×2) | `btree,user` | No journal on HDDs. Btree + reconciled user data. |

Consequence: `metadata_replicas=2` places both btree copies on HDDs (the only devices that allow btree). Journal replicas land on SSDs (the only devices that allow journal). `fsync` stays at NVMe latency; metadata integrity survives full SSD loss.

### 4.3 What happens on device loss

| Failure | Journal | Btree | User data | Recovery |
|---|---|---|---|---|
| 1 SSD | 1 copy remaining on other SSD | untouched on HDDs | 1 cached copy remaining on other SSD, reconciled copies on HDDs | replace SSD, `bcachefs device remove` old, `device add` new |
| Both SSDs | lost (recent un-flushed writes) | untouched on HDDs | reconciled copies on HDDs; lose un-reconciled dirty data | rebuild SSDs, mount reports journal-replay gap |
| 1 HDD | untouched on SSDs | 1 copy remaining on other HDD | 1 copy remaining on other HDD | replace HDD, reconcile repopulates |
| Both HDDs | on SSDs, fine short-term | lost | only cached copies on SSDs | catastrophic; restore from backup |

This is why backups still matter — a dual-HDD failure loses btree.

### 4.4 Writeback semantics

Per [bcachefs.org — Caching](https://bcachefs.org/Caching/) §2.2.4.1 + manual §8.5.4: with `foreground_target=ssd`, writes complete when enough replicas are durable. Because all four devices are `durability=1` and `data_replicas=2`, writes ack after **two SSD copies** land (both SSDs in the pool). Reconcile then moves copies to HDDs in the background and the SSD copies become cache (LRU-evictable).

---

## 5. Devices

Kernel names (`sda`, `nvme2n1`) **change across reboots**. Always use **`/dev/disk/by-id/...`** in scripts, systemd units, and documentation.

| Role | Model | Size | Label | `durability` | `data_allowed` | Stable by-id |
|------|-------|------|-------|---|---|---|
| Data (HDD) | Seagate Exos ST14000NM000J | 14 TB | `hdd` | 1 | `btree,user` | `ata-ST14000NM000J-2TX103_ZR900CTB` |
| Data (HDD) | Seagate Exos ST14000NM001G | 14 TB | `hdd` | 1 | `btree,user` | `ata-ST14000NM001G-2KJ103_ZLW212GF` |
| Cache (NVMe) | WD_BLACK SN850X HS | 2 TB | `ssd` | 1 | `journal,user` | `nvme-WD_BLACK_SN850X_HS_2000GB_24364L800813` |
| Cache (NVMe) | Samsung 990 Pro | 2 TB | `ssd` | 1 | `journal,user` | `nvme-Samsung_SSD_990_PRO_2TB_S7KHNU0Y517886B` |

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

**Target unit (by-id, all four members):**

```ini
[Unit]
Description=NAS storage pool
# Prefer Wants= over Requires= so a missing disk does not block the entire boot.
After=systemd-modules-load.service

[Service]
ExecStartPre=/sbin/modprobe bcachefs
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/mount -t bcachefs \
  /dev/disk/by-id/ata-ST14000NM000J-2TX103_ZR900CTB:\
/dev/disk/by-id/ata-ST14000NM001G-2KJ103_ZLW212GF:\
/dev/disk/by-id/nvme-WD_BLACK_SN850X_HS_2000GB_24364L800813:\
/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S7KHNU0Y517886B \
  -o version_upgrade=none /nas
ExecStop=/usr/bin/umount /nas

[Install]
WantedBy=multi-user.target
```

**Avoid** `Requires=dev-sda.device dev-sdb.device`: if enumeration swaps, those units never become active and boot can hang. Use **by-id** `.device` units or **filesystem UUID** mount.

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
- Each HDD: `durability 1`, `data_allowed btree,user`
- Each SSD: `durability 1`, `data_allowed journal,user`
- `bcachefs fs usage -a` shows btree bytes only on HDD devices, journal bytes only on SSD devices.

---

## 11. Related docs in this repo

| File | Contents |
|------|----------|
| [storage.md](storage.md) | Samba shares, PostgreSQL backup path, short pool note |
| [migrate-bcachefs.md](migrate-bcachefs.md) | **One-time** migration from legacy single-SSD pool to the layout in this doc |
| [kernel/README.md](kernel/README.md) | Full kernel/bcachefs/NVIDIA build narrative |
| [kernel/build-kernel.sh](kernel/build-kernel.sh) | Pinned tags, staging layout, verification |
| [post-install.md](post-install.md) | Steady-state install steps (post-migration) |
| [hardware.md](hardware.md) | Physical slot mapping |

---

## 12. Changelog

| Date | Note |
|------|------|
| 2026-04-18 | Executed the pool redesign from [migrate-bcachefs.md](migrate-bcachefs.md): 9100 Pro added as second SSD; HDDs `data_allowed=btree,user` (metadata truth), SSDs `data_allowed=journal,user` (hot-path + fsync), all devices `durability=1`, SN850X dropped 2→1. `/cache` decommissioned — iris → `/var/iris`, models → `/store/models`. |
| 2026-04-18 | Plan change: 9100 Pro removed from pool (Gen5 lane wasted as replicated-pool member bounded by SN850X); 9100 reassigned to be the new boot drive + models cache. 990 Pro 2 TB will replace it in the pool once the OS is on the 9100. Pool is temporarily 3 devices (2× HDD + SN850X). `/store` → `/nas` rename follows. |
| 2026-04-18 | Migration complete: OS built on 9100 (kernel 7.0, XFS root), 990 Pro wiped and added to pool as second `ssd` member (dev 4), `/store` → `/nas`, `bcachefs-store.service` → `nas.service`. Pool is now 4 symmetric devices: 2× Exos HDD + 990 + SN850X (both SSDs on Gen4 chipset path). |
| 2026-04 | Replaced `ssd-swap.md` with this doc. |

When you change replication, devices, `data_allowed`, or the unit file, add a one-line entry here.
