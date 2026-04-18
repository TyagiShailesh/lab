# Kernel build pipeline

Custom-compiled kernel + bcachefs + NVIDIA OOT modules. EFISTUB boot — **no GRUB, no initramfs**.

Topic docs:

- Architecture and hardware: [../hardware.md](../hardware.md)
- Networking, sysctl: [../network.md](../network.md)
- bcachefs pool: [../bcachefs.md](../bcachefs.md)
- NVIDIA driver + GDS details: [../gpu.md](../gpu.md)
- OS bring-up runbook: [../post-install.md](../post-install.md)

---

## Running kernel

| | |
|---|---|
| Running | 6.19.10 (`SMP PREEMPT_DYNAMIC`) |
| Fallback | 6.19.9 |
| Boot | EFISTUB direct — UEFI firmware loads `bzImage`, no bootloader |
| cmdline | `root=PARTUUID=204dd2f7-381a-47a8-bc8d-c2dff520e914 rw` + embedded `iommu=pt nvme.poll_queues=4` via `CONFIG_CMDLINE` |

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

## Out-of-tree modules (pre-built into tarball)

### bcachefs

| | |
|---|---|
| Module | `/usr/lib/modules/<kver>/kernel/fs/bcachefs/bcachefs.ko` |
| Version | Pinned tag from [koverstreet/bcachefs-tools](https://github.com/koverstreet/bcachefs-tools) (see `build-kernel.sh`) |
| Autoload | `/etc/modules-load.d/bcachefs.conf` |
| Service load | `bcachefs-store.service` runs `modprobe bcachefs` before mount |
| Userspace tools | `/usr/local/sbin/bcachefs` (built from same repo) |

Taint on load: `bcachefs: loading out-of-tree module taints kernel.`

Build steps inside `build-kernel.sh`:

1. Clone `koverstreet/bcachefs-tools` at pinned tag
2. Build DKMS source, compile module against the new kernel tree
3. Build `bcachefs` userspace binary
4. Package `bcachefs.ko` + binary into the kernel tarball

The target system never needs a compiler or DKMS — everything is pre-built.

### NVIDIA open kernel modules

Pre-built from [NVIDIA/open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules) at a pinned tag matching the userspace driver version. Built with the kernel's own IBT/CET settings — **not** with DKMS's `CONFIG_X86_KERNEL_IBT=""` hack that disables IBT and produces crashy modules.

| | |
|---|---|
| Modules | `nvidia.ko`, `nvidia-modeset.ko`, `nvidia-drm.ko`, `nvidia-uvm.ko`, `nvidia-peermem.ko`, `nvidia-fs.ko` |
| Location | `/usr/lib/modules/<kver>/kernel/drivers/video/` |
| Firmware | `/usr/lib/firmware/nvidia/<version>/gsp_*.bin` |
| Version | Pinned tag in `build-kernel.sh` — must match `libnvidia-compute` etc. on target |

Target must have `nvidia-dkms-open` removed (only keep userspace libs from `cuda` metapackage).

### NVIDIA GPUDirect Storage (`nvidia-fs`)

Pre-built from [NVIDIA/gds-nvidia-fs](https://github.com/NVIDIA/gds-nvidia-fs) at a pinned tag. Source is patched in `build-kernel.sh` for kernel 6.18+ API changes (`vm_flags`, `blk_map_iter`, `memdesc_flags_t`). Full context in [../gpu.md](../gpu.md).

---

## Build pipeline

All build scripts and patches live in this directory.

```
build-kernel.sh     → builds bzImage + modules + bcachefs + NVIDIA OOT + nvidia-fs, creates .tar.zst
install-kernel.sh   → extracts tarball to target, creates EFI boot entry (finds disk by PARTUUID)
build-rootfs.sh     → builds Ubuntu 24.04 minimal rootfs tarball
install-rootfs.sh   → wipes disk, partitions, installs rootfs (DESTRUCTIVE)
config              → kernel .config (back up before modifying)
patches/            → kernel patches applied during build
src/                → downloaded sources (kernel, bcachefs-tools, nvidia-open, nvidia-fs) — gitignored
build/              → build tree + staging — gitignored
images/             → output tarballs — gitignored
```

### Build kernel

```bash
# 1. Edit config if needed (back it up first)
# 2. Build kernel + bcachefs + NVIDIA modules + tools
./build-kernel.sh          # → images/linux-<version>.tar.zst

# 3. Install (run on target — finds boot disk by PARTUUID)
./install-kernel.sh images/linux-<version>.tar.zst
```

### Build rootfs (fresh install only)

```bash
# 1. Build Ubuntu 24.04 minimal rootfs
./build-rootfs.sh   # → images/ubuntu-24.04-amd64.tar.zst

# 2. Partition disk and install rootfs (DESTRUCTIVE — wipes disk)
./install-rootfs.sh images/ubuntu-24.04-amd64.tar.zst /dev/nvme0n1

# 3. Install kernel on top
./install-kernel.sh images/linux-<version>.tar.zst
```

`build-kernel.sh` enables `CRYPTO_LZ4`, `CRYPTO_LZ4HC`, `BLK_DEV_INTEGRITY` (bcachefs deps) and `TCP_CONG_BBR`, `NET_SCH_FQ` (BBR) in the config, then builds the kernel, bcachefs module, NVIDIA open kernel modules, and userspace tools into a single tarball. Always update to the latest stable kernel, bcachefs-tools tag, and NVIDIA tag before building.

`install-kernel.sh` extracts to target, copies `bzImage` to EFI partition, creates/updates EFI boot entry via `efibootmgr`, and ensures `modules-load.d/bcachefs.conf` exists.

---

## Services running on target

| Service | Purpose | Ref |
|---|---|---|
| `bcachefs-store` | Mount bcachefs pool at `/store` | [../bcachefs.md](../bcachefs.md) |
| `smbd` / `nmbd` | Samba file sharing | [../storage.md](../storage.md) |
| `postgresql` | Mac DaVinci Resolve project DB | [../postgres.md](../postgres.md) |
| `avahi-daemon` | mDNS (lab.local) | — |
| `wg-quick@wg0` | WireGuard VPN | [../network.md](../network.md) |
| `cpu-performance` | CPU governor = performance on boot | — |
| `thunderbolt-tune` | TB IRQ / RPS / busy-poll | [../network.md](../network.md) |
| `caddy` | Web server | [../post-install.md](../post-install.md) |
| `ollama` | LLM inference | [../post-install.md](../post-install.md) |
| `chrony` | NTP time sync | — |
| `irqbalance` | IRQ distribution across CPUs | — |
| `lm-sensors` | Hardware monitoring | — |
| `fstrim.timer` | Periodic SSD TRIM | — |

---

## OS

Ubuntu 24.04.4 LTS (Noble Numbat), XFS root on Samsung 990 Pro 2 TB.

```
/dev/nvme0n1p1   1G    vfat   /boot/efi
/dev/nvme0n1p2   1.8T  xfs    /
```

`fstab` only has the EFI partition. Root is passed via kernel cmdline. bcachefs is mounted by systemd service — see [../bcachefs.md §7](../bcachefs.md#7-boot-and-systemd-not-fstab).

### Philosophy

Minimal, no bloat. No snap, flatpak, desktop, GUI, telemetry, Ubuntu Pro. Root-only SSH. Every running service has a clear purpose.
