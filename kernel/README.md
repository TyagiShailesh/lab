# Kernel build pipeline

Custom-compiled kernel + bcachefs + NVIDIA OOT modules. EFISTUB boot — **no GRUB, no initramfs**.

Topic docs:

- Architecture and hardware: [../hardware.md](../hardware.md)
- Networking, sysctl: [../network.md](../network.md)
- Storage stack (`/nas` bcachefs hybrid pool): [../storage.md](../storage.md)
- Performance tuning (CPU governor, NIC, sysctl, bcachefs flags): [../performance.md](../performance.md)
- NVIDIA driver details: [../gpu.md](../gpu.md)

---

## Running kernel

| | |
|---|---|
| Built | 7.0.5 (`SMP PREEMPT_DYNAMIC`) — see `build-kernel.sh` for the pinned tarball URL |
| Boot | EFISTUB direct — UEFI firmware loads `bzImage`, no bootloader |
| cmdline | `root=PARTUUID=e5647d0c-b88a-4f30-919e-736dc3e841e8 rw` |

### Boot sequence

```
UEFI firmware
  └── EFISTUB: \linux-<ver> on EFI partition (nvme0n1p1, the Samsung 9100 Pro)
        └── cmdline: root=PARTUUID=e5647d0c-... rw
              └── Kernel boots directly (monolithic, no initramfs)
                    └── XFS root mounted (built-in)
                          └── systemd starts
                                └── nas.service mounts /nas (bcachefs pool)
```

### EFI boot entries

EFI entries are created by `install-kernel.sh` via `efibootmgr`. Old kernel entries are kept on the EFI partition for rollback; they can be selected from the UEFI boot menu.

### Key kernel config rules

- Root filesystem (XFS) must be built-in (`=y`), never a module — no initramfs to load it.
- NVMe, SATA AHCI, EFI stub all built-in.
- bcachefs is loaded as an out-of-tree module at boot via `/etc/modules-load.d/bcachefs.conf` (and explicitly by `nas.service` before mount).
- `CONFIG_TCP_CONG_BBR=y` + `CONFIG_NET_SCH_FQ=y` — BBR congestion control for 10GbE.
- `CONFIG_CRYPTO_LZ4=y` + `CONFIG_CRYPTO_LZ4HC=y` + `CONFIG_BLK_DEV_INTEGRITY=y` — required by the bcachefs module build (selects `LZ4_COMPRESS`, `LZ4HC_COMPRESS`, `LZ4_DECOMPRESS`, `CRC64`).
- `CONFIG_RUST=y` — required by future bcachefs versions; current build needs `rustup` + `bindgen-cli` + `libclang-dev` on the host or it silently stays off.
- `CONFIG_MODULES=y` — optional subsystems as modules.
- `CONFIG_IKCONFIG=y` + `CONFIG_IKCONFIG_PROC=y` — config at `/proc/config.gz`.
- `CONFIG_PREEMPT_DYNAMIC=y` — runtime preemption switching.
- No DKMS on target — out-of-tree modules are pre-built in the build pipeline.

---

## Out-of-tree modules (pre-built into tarball)

### bcachefs

| | |
|---|---|
| Module | `/usr/lib/modules/<kver>/kernel/fs/bcachefs/bcachefs.ko` |
| Version | Pinned tag from [koverstreet/bcachefs-tools](https://github.com/koverstreet/bcachefs-tools) (see `build-kernel.sh`) |
| Autoload | `/etc/modules-load.d/bcachefs.conf` |
| Service load | `nas.service` runs `modprobe bcachefs` before mount |
| Userspace tools | `/usr/local/sbin/bcachefs` (built from same repo) |

Taint on load: `bcachefs: loading out-of-tree module taints kernel.`

Build steps inside `build-kernel.sh`:

1. Clone `koverstreet/bcachefs-tools` at the pinned tag (currently `v1.38.2`).
2. Build the DKMS source tree, compile `bcachefs.ko` against the new kernel tree.
3. Build the `bcachefs` userspace binary.
4. Package `bcachefs.ko` + binary into the kernel tarball.

The target system never needs a compiler or DKMS — everything is pre-built.

### NVIDIA open kernel modules

Pre-built from [NVIDIA/open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules) at a pinned tag matching the userspace driver version. Built with the kernel's own IBT/CET settings — **not** with DKMS's `CONFIG_X86_KERNEL_IBT=""` hack that disables IBT and produces crashy modules.

| | |
|---|---|
| Modules | `nvidia.ko`, `nvidia-modeset.ko`, `nvidia-drm.ko`, `nvidia-uvm.ko`, `nvidia-peermem.ko` |
| Location | `/usr/lib/modules/<kver>/kernel/drivers/video/` |
| Firmware | `/usr/lib/firmware/nvidia/<version>/gsp_*.bin` |
| Version | Pinned tag in `build-kernel.sh` — must match `libnvidia-compute` etc. on target |

Target must have `nvidia-dkms-open` removed (only keep userspace libs from `cuda` metapackage).

---

## Build pipeline

All build scripts live in this directory.

```
build-kernel.sh     → builds bzImage + modules + bcachefs OOT + NVIDIA OOT, creates .tar.zst
install-kernel.sh   → extracts tarball to target, creates EFI boot entry (finds disk by PARTUUID)
build-rootfs.sh     → builds Ubuntu 24.04 minimal rootfs tarball
install-rootfs.sh   → wipes disk, partitions, installs rootfs (DESTRUCTIVE)
config              → kernel .config (back up before modifying)
src/                → downloaded sources (kernel, bcachefs-tools, nvidia-open) — gitignored
build/              → build tree + staging — gitignored
images/             → output tarballs — gitignored
```

### Build kernel

```bash
# 1. Edit build-kernel.sh if you want to bump the kernel/bcachefs/NVIDIA pin
# 2. Build kernel + bcachefs + NVIDIA modules
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

`build-kernel.sh` enables BBR networking (`TCP_CONG_BBR`, `NET_SCH_FQ`), the bcachefs build dependencies (`CRYPTO_LZ4/LZ4HC`, `BLK_DEV_INTEGRITY`), XFS for root, and `RUST`, then builds the kernel, the bcachefs OOT module + userspace tools, and the NVIDIA open modules into a single tarball. Always update to the latest stable kernel and bcachefs/NVIDIA tags before building.

`install-kernel.sh` extracts to target, copies `bzImage` to EFI partition, writes `/etc/modules-load.d/bcachefs.conf`, and creates/updates the EFI boot entry via `efibootmgr`.

---

## Services running on target

| Service | Purpose | Ref |
|---|---|---|
| `nas` | Mount `/nas` (bcachefs hybrid pool) | [../storage.md](../storage.md) |
| `smbd` / `nmbd` | Samba file sharing | [../storage.md](../storage.md) |
| `avahi-daemon` | mDNS (lab.local) | — |
| `wg-quick@wg0` | WireGuard VPN | [../network.md](../network.md) |
| `caddy` | Web server | — |
| `ollama` | LLM inference | — |
| `chrony` | NTP time sync | — |
| `irqbalance` | IRQ distribution across CPUs | — |
| `lm-sensors` | Hardware monitoring | — |
| `fstrim.timer` | Periodic SSD TRIM | — |

---

## OS

Ubuntu 24.04.4 LTS (Noble Numbat), XFS root on Samsung 9100 Pro 1 TB.

```
/dev/nvme0n1p1   1G      vfat   /boot/efi
/dev/nvme0n1p2   930 GiB xfs    /
```

`fstab` only has the EFI partition. Root is passed via kernel cmdline. `/nas` is mounted by `nas.service` — see [../storage.md](../storage.md#mount).

### Philosophy

Minimal, no bloat. No snap, flatpak, desktop, GUI, telemetry, Ubuntu Pro. Root-only SSH. Every running service has a clear purpose.
