# System

## OS

Ubuntu 24.04.4 LTS (Noble Numbat), XFS root on Samsung 990 Pro 2TB.

```
/dev/nvme0n1p1   1G    vfat   /boot/efi
/dev/nvme0n1p2   1.8T  xfs    /
```

fstab only has the EFI partition. Root is passed via kernel cmdline. bcachefs is mounted by systemd service.

```
/dev/nvme0n1p1 /boot/efi vfat defaults 0 0
```

### Philosophy

Minimal, no bloat. No snap, flatpak, desktop, GUI, telemetry, Ubuntu Pro. Root-only SSH access. Every running service has a clear purpose.

---

## Kernel

Custom-compiled, **not** from Ubuntu packages. EFISTUB boot — **no GRUB, no initramfs**.

| | |
|---|---|
| Running | 6.19.10 (`SMP PREEMPT_DYNAMIC`, built as root@nas) |
| Fallback | 6.19.9 |
| Boot | EFISTUB direct — UEFI firmware loads bzImage, no bootloader |
| cmdline | `root=PARTUUID=204dd2f7-381a-47a8-bc8d-c2dff520e914 rw` |
| Build pipeline | `system/` (this directory) |

### Boot sequence

```
UEFI firmware
  └── EFISTUB: \linux-6.19.10 on EFI partition
        └── cmdline: root=PARTUUID=204dd2f7-... rw
              └── Kernel boots directly (monolithic, no initramfs)
                    └── XFS root mounted (built-in)
                          └── systemd starts
                                └── bcachefs-store.service mounts /store
```

### EFI boot entries

```
Boot0005* Linux 6.19.10 → \linux-6.19.10  (current)
Boot0001* Linux 6.19.9  → \linux-6.19.9   (fallback)
```

Kernel images live directly on the EFI partition (`/boot/efi/`). Managed by `efibootmgr`.

### Key kernel config rules

- Root filesystem (XFS) must be built-in (`=y`), never a module — no initramfs to load it
- NVMe, SATA AHCI, EFI stub all built-in
- `CONFIG_TCP_CONG_BBR=y` + `CONFIG_NET_SCH_FQ=y` — BBR congestion control for 10GbE
- `CONFIG_MODULES=y` — optional subsystems as modules
- `CONFIG_IKCONFIG=y` + `CONFIG_IKCONFIG_PROC=y` — config at `/proc/config.gz`
- `CONFIG_PREEMPT_DYNAMIC=y` — runtime preemption switching
- No DKMS on target — out-of-tree modules are pre-built in the build pipeline

---

## bcachefs module

bcachefs is compiled as an **out-of-tree kernel module** — not in the kernel config.

The kernel taints on load:

```
bcachefs: loading out-of-tree module taints kernel.
```

| | |
|---|---|
| Module | `/usr/lib/modules/<kver>/kernel/fs/bcachefs/bcachefs.ko` |
| Version | Pinned tag from koverstreet/bcachefs-tools (see `build-kernel.sh`) |
| Autoload | `/etc/modules-load.d/bcachefs.conf` |
| Service load | `bcachefs-store.service` runs `modprobe bcachefs` before mount |
| Userspace tools | `/usr/local/sbin/bcachefs` (built from same repo) |

### How bcachefs is built

The module and tools are built inside `build-kernel.sh` as part of the kernel tarball:

1. Clone `koverstreet/bcachefs-tools` at pinned tag (see `build-kernel.sh`)
2. Build DKMS source, then compile module against the new kernel tree
3. Build `bcachefs` userspace binary
4. Package `bcachefs.ko` + `bcachefs` binary into the kernel tarball

The target system never needs a compiler or DKMS — everything is pre-built.

### NVIDIA open kernel modules

Pre-built from [NVIDIA/open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules) at a pinned tag matching the userspace driver version on target. Built with the kernel's own IBT/CET settings — **not** with DKMS's `CONFIG_X86_KERNEL_IBT=""` hack that disables IBT and produces crashy modules.

| | |
|---|---|
| Modules | `nvidia.ko`, `nvidia-modeset.ko`, `nvidia-drm.ko`, `nvidia-uvm.ko`, `nvidia-peermem.ko`, `nvidia-fs.ko` |
| Location | `/usr/lib/modules/<kver>/kernel/drivers/video/` |
| Firmware | `/usr/lib/firmware/nvidia/<version>/gsp_*.bin` |
| Version | Pinned tag in `build-kernel.sh` — must match `libnvidia-compute` etc. on target |

Target must have `nvidia-dkms-open` removed (only keep userspace libs from `cuda` metapackage).

### Build pipeline

All build scripts live in this directory (`system/`).

```
build-kernel.sh     → builds bzImage + modules + bcachefs + NVIDIA OOT + nvidia-fs (GDS), creates .tar.zst
install-kernel.sh   → extracts tarball to target, creates EFI boot entry (finds disk by PARTUUID)
build-rootfs.sh     → builds Ubuntu 24.04 minimal rootfs tarball (base image)
install-rootfs.sh   → wipes disk, partitions, installs rootfs (DESTRUCTIVE)
config              → kernel .config (back up before modifying)
src/                → downloaded sources (kernel, bcachefs-tools, nvidia-open) — gitignored
build/              → build tree + staging — gitignored
images/             → output tarballs — gitignored
```

#### Build kernel

```bash
# 1. Edit config if needed (back it up first)
# 2. Build kernel + bcachefs + NVIDIA modules + tools
./build-kernel.sh          # → images/linux-<version>.tar.zst

# 3. Install (run on target — finds boot disk by PARTUUID)
./install-kernel.sh images/linux-<version>.tar.zst
```

#### Build rootfs (fresh install only)

```bash
# 1. Build Ubuntu 24.04 minimal rootfs
./build-rootfs.sh   # → images/ubuntu-24.04-amd64.tar.zst

# 2. Partition disk and install rootfs (DESTRUCTIVE — wipes disk)
./install-rootfs.sh images/ubuntu-24.04-amd64.tar.zst /dev/nvme0n1

# 3. Install kernel on top
./install-kernel.sh images/linux-<version>.tar.zst
```

`build-kernel.sh` enables `CRYPTO_LZ4`, `CRYPTO_LZ4HC`, `BLK_DEV_INTEGRITY` (bcachefs deps) and `TCP_CONG_BBR`, `NET_SCH_FQ` (BBR) in the config, then builds the kernel, bcachefs module, NVIDIA open kernel modules, and userspace tools into a single tarball. Always update to the latest stable kernel, bcachefs-tools tag, and NVIDIA tag before building.

`install-kernel.sh` extracts to target, copies bzImage to EFI partition, creates/updates EFI boot entry via `efibootmgr`, and ensures `modules-load.d/bcachefs.conf` exists.

---

## Network

```
eno1 (Marvell AQtion 10GbE) ─┐
                               ├─ br0 (192.168.1.10/24, MTU 9000, STP off)
eno2 (Intel 2.5GbE)          ─┘
wg0 (10.0.0.1/30, UDP 51820)
```

Bridge managed by netplan → systemd-networkd. Static IP, jumbo frames.

### Thunderbolt networking

Standard in-tree `thunderbolt_net` driver. See [tb.md](tb.md) for hardware details, performance data, and tuning.

### WireGuard

```ini
[Interface]
Address = 10.0.0.1/30
ListenPort = 51820

[Peer]
AllowedIPs = 10.0.0.2/32
```

---

## Performance tuning

Sysctl config: `/etc/sysctl.d/99-lab.conf` (written by `build-rootfs.sh`).

Key settings: BBR congestion control, 256MB socket buffers, `vm.swappiness=1`, `vm.dirty_ratio=5`, `vm.vfs_cache_pressure=50`.

I/O schedulers via udev: `mq-deadline` for HDDs, `none` for NVMe. No swap.

---

## Services

| Service | Purpose |
|---|---|
| bcachefs-store | Mount bcachefs pool at `/store` |
| smbd / nmbd | Samba file sharing |
| postgresql | Resolve database |
| avahi-daemon | mDNS (lab.local) |
| wg-quick@wg0 | WireGuard VPN |
| cpu-performance | Set CPU governor to performance on boot |
| caddy | Web server |
| ollama | LLM inference server |
| chrony | NTP time sync |
| irqbalance | IRQ distribution across CPUs |
| lm-sensors | Hardware monitoring |
| fstrim.timer | Periodic SSD TRIM |

---

## Block devices

NVMe device numbering changes depending on which drives are installed.
All mount paths use stable identifiers (PARTUUID, UUID, or `/dev/disk/by-id/`).

```
sda         12.7T  bcachefs  /store     ST14000NM000J-2TX103      sata
sdb         12.7T  bcachefs             ST14000NM001G-2KJ103      sata
nvme?n1     931.5G xfs       /cache     Samsung SSD 9100 PRO 1TB  nvme  (M.2_1, Gen5 CPU)
nvme?n1      1.8T                       Samsung SSD 990 PRO 2TB   nvme  (M.2_2, Gen4 chipset)
├─p1           1G  vfat      /boot/efi
└─p2         1.8T  xfs       /
nvme?n1      1.8T  bcachefs             WD_BLACK SN850X HS 2000GB nvme  (M.2_4, Gen4 chipset)
```
