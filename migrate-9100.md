# Migration: boot drive 990 → 9100, rename `/store` → `/nas`

One-time migration executed 2026-04-18. Captures what ran, what's still pending at reboot, and how to roll back.

**Delete this file after the migration is fully complete** (9100 boot verified, 990 wiped and added to pool, all services running).

---

## Motivation

Earlier today the pool was reconfigured per [migrate-bcachefs.md](migrate-bcachefs.md) (durability=1 everywhere, `data_allowed` splits, `metadata_target=hdd`). That left two asymmetric SSDs in the pool: the 9100 Pro 1 TB (Gen5 CPU-direct) and the SN850X 2 TB (Gen4 chipset). Replicated writes on asymmetric SSDs are bounded by the slower partner, so the 9100's Gen5 bandwidth was wasted as a pool member.

Decision:

1. Remove the 9100 from the pool.
2. Put the 9100 at M.2_1 (Gen5 CPU — where it already sits physically) to serve as **boot + hot model cache**.
3. Move the OS from the 990 Pro 2 TB (M.2_2) to the 9100.
4. After a clean boot on the 9100, wipe the 990 and add it to the pool as a second `ssd`-label member.

Result: pool SSD tier becomes two identical 2 TB drives on the same PCIe Gen4 chipset path (SN850X + 990 Pro). Symmetric, balanced writes. 9100's Gen5 lane is used for model loading into GPU VRAM, not constrained by replica partner speed.

Also renaming the pool mount point `/store` → `/nas`, the systemd unit `bcachefs-store.service` → `nas.service`, and Samba's NetBIOS advertisement to `nas`. Hostname stays `lab`.

---

## Final target state

| Slot | Drive | Role | Filesystem | Mount |
|---|---|---|---|---|
| M.2_1 (Gen5, CPU) | Samsung 9100 Pro 1 TB | **Boot + model cache** | XFS | `/` |
| M.2_2 (Gen4, chipset) | Samsung 990 Pro 2 TB | **bcachefs SSD tier** (`ssd`, durability=1, `data_allowed=journal,user`) | bcachefs | `/nas` |
| M.2_4 (Gen4, chipset) | WD SN850X 2 TB | **bcachefs SSD tier** (same as above) | bcachefs | `/nas` |
| SATA 0, SATA 1 | 2× Seagate Exos 14 TB | **bcachefs HDD tier** (`hdd`, durability=1, `data_allowed=btree,user`) | bcachefs | `/nas` |

RTX PRO 2000 stays at PCIEX16_2.

---

## Executed phases (2026-04-18)

### Phase 1 — Preserve bundle
- `pg_dumpall` skipped (clean-install decision — PostgreSQL starts fresh).
- `tar` of:
  - `/etc/iris/` (toml, fullchain, privkey)
  - `/etc/systemd/system/{iris,bcachefs-store,xr-engine}.service`
  - `/etc/samba/smb.conf` and `/var/lib/samba/private/`
  - `/etc/netplan/`, `/etc/wireguard/wg0.conf`
  - `/etc/hostname`, `/etc/hosts`
  - `/etc/ssh/ssh_host_*_key*` (so clients don't MITM-warn)
  - `/root/.ssh/`, `/root/.bashrc`, `/root/.profile`, `/root/.claude/`
- Saved to `/store/data/backup/preserve-2026-04-18.tar.zst` (119 MB).
- `/root/ws/` (213 G workspace) saved separately: `/store/data/backup/ws-2026-04-18.tar.zst` (42 G compressed).

### Phase 2 — Remove 9100 from pool
- `bcachefs device evacuate` of dev 3 (nvme0n1 / 9100 Pro).
- The evacuate move-worker is I/O-clock-throttled; real user I/O (the preserve tar) advanced the clock enough to drain all but ~256 K.
- `bcachefs device remove -f` to finalise. Pool went from 4 devices → 3 (2× HDD + SN850X).

### Phase 3 — Build kernel 7.0 tarball
- `kernel/build-kernel.sh` already produced `images/linux-7.0.tar.zst` earlier.
- Bug found: `kver` is derived from tarball name (`linux-7.0` → `kver=7.0`) but the kernel's actual `KERNELRELEASE` is `7.0.0`. Stock modules install to `/usr/lib/modules/7.0.0/`, but OOT bcachefs/nvidia modules were placed at `/usr/lib/modules/7.0/`. At boot, `uname -r = 7.0.0` so `modprobe` wouldn't find them.
- **Worked around** by merging the trees and re-running `depmod` offline: `images/linux-7.0-fixed.tar.zst`.
- **Permanent fix** to `build-kernel.sh` in this same commit — derive `kver` from the stock `modules_install` output directory.

### Phase 4 — Build rootfs
- `kernel/build-rootfs.sh` produced `images/ubuntu-24.04-amd64.tar.zst` (182 MB).
- Ubuntu 24.04.4 LTS (Noble) minimal cloud image + packages (ssh, chrony, samba, avahi, wireguard-tools, rsync, xfsprogs, efibootmgr, irqbalance, cpufrequtils, fio).

### Phase 5 — Partition + install on 9100
- `wipefs -a` on 9100 (cleared leftover bcachefs signature).
- GPT: p1 ESP fat32 1 GiB, p2 XFS rest (930 GiB).
- `mkfs.vfat`, `mkfs.xfs -L nas-root` (12-char limit).
- Mounted p2 at `/mnt/newroot`, p1 at `/mnt/newroot/boot/efi`.
- Extracted rootfs tarball, then the fixed kernel tarball.
- Copied `/boot/linux-7.0` (bzImage) to `/boot/efi/linux-7.0`.

### Phase 6 — Apply preserve bundle + rewrites
- Extracted preserve bundle into the new rootfs.
- Renamed `bcachefs-store.service` → `nas.service`; `sed` replaced `/store` → `/nas` and `BcacheFS storage pool` → `NAS storage pool`.
- `smb.conf`: `/store/*` → `/nas/*`; injected `netbios name = nas` in `[global]`.
- Created `/nas` mount directory on the new rootfs.
- Wrote minimal `/etc/fstab` — only EFI partition; root comes via kernel cmdline `root=PARTUUID=…`.
- Disabled non-essential services on first boot: `smb`, `nmb`, `samba-ad-dc`, `nas`, `iris`, `xr-engine`, `wg-quick@wg0`, `unattended-upgrades`, `apport`, `pollinate`, `lxd-installer.socket`, `secureboot-db`. Left enabled: ssh, systemd-networkd, systemd-resolved, chrony, avahi-daemon, cpu-performance, irqbalance, smartd, smartmontools, lm-sensors.

### Phase 7 — Extract `/root/ws` (213 G workspace)
- Extracted `ws-2026-04-18.tar.zst` into `/mnt/newroot/root/ws/` (142 G on disk after XFS + extraction).
- 9100 root usage: 162 G / 931 G. 770 G free for models cache.

### Phase 7b — depmod + EFI entry
- `chroot /mnt/newroot depmod -a 7.0.0` — confirmed `bcachefs` in `modules.dep`.
- `efibootmgr -c -d /dev/nvme0n1 -p 1 -L "Linux 7.0" -l '\linux-7.0' -u "root=PARTUUID=<9100-p2-partuuid> rw iommu=pt nvme.poll_queues=4"` — created `Boot0006*`.
- New `BootOrder`: `0006, 0001, 0000, 0002, 0003, 0004, 0005` — Linux 7.0 first, Linux 6.19.10 on the 990 stays as fallback.
- Unmounted 9100. 990 untouched.

### Phase 7c — Hardware unchanged
- Drive slots stayed put (no physical swap). 9100 at M.2_1, 990 at M.2_2, SN850X at M.2_4.
- RTX PRO 2000 at PCIEX16_2.

---

## Pending — do after reboot

### Phase 8 — Reboot and verify
On next reboot the firmware picks `Boot0006* Linux 7.0` from the 9100.

Smoke test:
```bash
uname -r                       # expect 7.0.0
cat /etc/hostname              # expect lab
modprobe bcachefs              # expect no error
lsmod | grep bcachefs          # expect bcachefs loaded
lsmod | grep nvidia            # (only after loading nvidia)
systemctl --failed             # expect none (or only things we intentionally disabled)
ip addr show br0               # expect 192.168.1.10/24
ls /root/ws | head             # workspace preserved
ls /etc/iris                   # iris config preserved
```

Then bring up the pool + Samba + iris manually:
```bash
systemctl start nas            # mounts pool at /nas via the renamed unit
mountpoint /nas                # expect: mountpoint
bcachefs fs usage -h /nas      # 3 devices (not 4 — 990 joins in Phase 9)
systemctl start smb nmb        # Samba; advertise name = nas
systemctl start iris           # cameras re-pair (new HomeKit identity)
systemctl start wg-quick@wg0   # WireGuard peer
```

If any check fails, do not proceed to Phase 9 — roll back (see bottom).

### Phase 9 — Wipe 990 and add to pool
```bash
DEV=/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S7KHNU0Y517886B   # (verify actual serial)
wipefs -a "$DEV"
bcachefs device add --label=ssd --durability=1 /nas "$DEV"
# Apply data_allowed=journal,user on the new device (offline step — see migrate-bcachefs.md Phase 8)
```

Note: `bcachefs set-fs-option --data_allowed=journal,user` on a mounted filesystem is a silent no-op with our tool version. Either unmount briefly to apply, or accept the default `journal,btree,user` on the new device — `metadata_target=hdd` will steer btree to HDDs regardless.

### Phase 10 — Services back up, cleanup
- Enable what should auto-start:
  ```bash
  systemctl enable nas smb nmb iris wg-quick@wg0 avahi-daemon
  ```
- Delete old EFI entries pointing at 990 kernels, if you're happy never rolling back: `efibootmgr -b 0000 -B && efibootmgr -b 0001 -B`. Until then, keep them for emergency recovery.
- Remove the migration bundles after a week of clean operation:
  `rm /store/data/backup/{preserve,ws}-2026-04-18.tar.zst` — wait, `/store` is now `/nas`; the bundles are on the pool which is mounted at `/nas`.
- Delete this file (`migrate-9100.md`).

---

## Rollback

**Before reboot:** nothing to roll back on 990. Delete `Boot0006` with `efibootmgr -b 0006 -B`, set BootOrder back to `0001,0000,…`.

**At reboot / if 9100 won't boot:** at POST press F8 or F12, pick `Linux 6.19.10` (Boot0001 on 990). 990 still has its kernel, rootfs, `/etc`, services, PostgreSQL data, everything. Then from userspace:
```bash
efibootmgr -o 0001,0000,0006,0002,0003,0004,0005   # put 990 first again
```

**After reboot succeeded but before Phase 9:** same — 990 is still intact. Reboot back to Boot0001 if anything's wrong on 9100.

**After Phase 9 (990 wiped and in pool):** no quick rollback — 990's OS is gone. Recovery means reinstalling an OS somewhere. Don't run Phase 9 until the 9100 boot has been verified under a realistic workload.

---

## What's not carried over (by design)

- PostgreSQL data — `resolve/nas` DB starts empty. Mac DaVinci Resolve projects gone; media on the pool is intact.
- `/var/iris` — HomeKit pairings regenerate; cameras need to be re-paired once.
- iris/xr-engine binaries — rebuild from source in `/root/ws/`.
- Ollama, Caddy, nvidia-gds userspace, custom FFmpeg — fresh install via [post-install.md](post-install.md).
- Most Ubuntu default services (unattended-upgrades, apport, pollinate, LXD) — disabled on purpose.
- Old 6.19.10 kernel on the 990 — intentionally kept on the 990's EFI as a fallback boot entry.
