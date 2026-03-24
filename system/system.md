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
| Running | 6.19.6 (`SMP PREEMPT_DYNAMIC`, built as root@nas) |
| Fallback | 6.16.4 |
| Boot | EFISTUB direct — UEFI firmware loads bzImage, no bootloader |
| cmdline | `root=/dev/nvme0n1p2 rw` |
| Build pipeline | `system/` (this directory) |

### Boot sequence

```
UEFI firmware
  └── EFISTUB: \linux-6.19.6 on EFI partition
        └── cmdline: root=/dev/nvme0n1p2 rw
              └── Kernel boots directly (monolithic, no initramfs)
                    └── XFS root mounted (built-in)
                          └── systemd starts
                                └── bcachefs-store.service mounts /store
```

### EFI boot entries

```
Boot0001* Linux 6.19.6  → \linux-6.19.6   (current)
Boot0000* Linux         → \linux-6.16.4   (fallback)
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

bcachefs is compiled as an **out-of-tree kernel module** — not in the kernel config. It was built-in (`CONFIG_BCACHEFS_FS=y`) in 6.16.4, but moved out-of-tree in 6.19.6 for better version control.

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

1. Clone `koverstreet/bcachefs-tools` at pinned tag (v1.36.1)
2. Build DKMS source, then compile module against the new kernel tree
3. Build `bcachefs` userspace binary
4. Package `bcachefs.ko` + `bcachefs` binary into the kernel tarball

The target system never needs a compiler or DKMS — everything is pre-built.

### Build pipeline

All build scripts live in this directory (`system/`).

```
build-kernel.sh     → downloads kernel source, builds bzImage + modules + bcachefs OOT, creates .tar.zst
install-kernel.sh   → extracts tarball to target disk, creates EFI boot entry, runs depmod
build-rootfs.sh     → builds Ubuntu 24.04 minimal rootfs tarball (base image)
install-rootfs.sh   → wipes disk, partitions, installs rootfs (DESTRUCTIVE)
config              → kernel .config (back up before modifying)
```

#### Build kernel

```bash
# 1. Edit config if needed (back it up first)
# 2. Build kernel + bcachefs module + tools
./build-kernel.sh          # → linux-6.19.6.tar.zst

# 3. Install to target disk
./install-kernel.sh linux-6.19.6.tar.zst /dev/nvme0n1
```

#### Build rootfs (fresh install only)

```bash
# 1. Build Ubuntu 24.04 minimal rootfs
./build-rootfs.sh   # → images/ubuntu-24.04-amd64.tar.zst

# 2. Partition disk and install rootfs (DESTRUCTIVE — wipes disk)
./install-rootfs.sh images/ubuntu-24.04-amd64.tar.zst /dev/nvme0n1

# 3. Install kernel on top
./install-kernel.sh linux-6.19.6.tar.zst /dev/nvme0n1
```

`build-kernel.sh` enables `CRYPTO_LZ4`, `CRYPTO_LZ4HC`, `BLK_DEV_INTEGRITY` (bcachefs deps) and `TCP_CONG_BBR`, `NET_SCH_FQ` (BBR) in the config, then builds the kernel, bcachefs module, and userspace tools into a single tarball. Always update to the latest stable kernel and bcachefs-tools tag before building.

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

Patched `thunderbolt_net` driver with page_pool RX and 1024-entry ring (source in `thunderbolt_net/`). Built as out-of-tree module alongside bcachefs in `build-kernel.sh`.

Rear I/O USB-C ports (from manual p.30):
- **Port 2** — Thunderbolt 5 (Barlow Ridge, domain1, PCI `87:00.0`) — 80 Gbps
- **Port 10** — Thunderbolt 4 (Meteor Lake PCH, domain0, PCI `00:0d.2`) — 40 Gbps

Measured throughput (iperf3, TB5 port, Mac connected):
- **TX (lab→Mac):** ~41 Gbps (single stream), ~40 Gbps (8 streams)
- **RX (Mac→lab):** ~29 Gbps (single stream)

The ~40 Gbps cap is a **driver limitation**, not hardware. The driver uses a single TX/RX DMA ring pair on one CPU core. The Barlow Ridge NHI supports up to 1023 HopIDs and has 16 MSI-X vectors — multi-queue is possible but requires a significant driver rewrite (multi-ring + USB4NET protocol negotiation changes). Not worth pursuing since 40 Gbps (~5 GB/s) exceeds storage throughput (SSD writes at 2.5 GB/s).

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

```
sda         12.7T  bcachefs  /store     ST14000NM000J-2TX103      sata
sdb         12.7T  bcachefs             ST14000NM001G-2KJ103      sata
nvme0n1      1.8T                       Samsung SSD 990 PRO 2TB   nvme
├─nvme0n1p1    1G  vfat      /boot/efi
└─nvme0n1p2  1.8T  xfs       /
nvme1n1      1.8T  bcachefs             WD_BLACK SN850X HS 2000GB nvme
```
