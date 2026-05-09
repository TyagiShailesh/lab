# Performance tuning

Everything we've done to push 10 GbE + NVMe-cached bcachefs to its actual limits, and the gotchas that silently undo it.

The measured ceiling we built toward:

| Path | Ceiling |
|---|---|
| Direct sequential write to `/nas` | **4.3 GB/s** |
| Local SMB loopback (`smbclient //127.0.0.1/...`) | 2.7 GB/s |
| Mac SMB single Finder copy, big files | ~575-1140 MB/s |
| Mac SMB 2 parallel Finder copies | ~650-780 MB/s aggregate |
| HDD mover sustained drain | ~250 MB/s mirrored |

When throughput is below these numbers, the failure is almost always **one of the things in this doc reverting to a default**. Start at §1.

---

## 1. CPU governor — the silent killer

**The single most impactful tuning on this box.** With governor stuck on `powersave`, cores idle at ~1 GHz and Mac SMB single-stream caps around **100 MB/s on a 10 GbE link** — looks identical to a samba/network/storage problem but is purely CPU-bound packet processing. Verified empirically on 2026-05-08: governor=powersave → 100 MB/s; flipped to `performance` → 1139 MB/s on the same workload.

Persistent unit, defined in [kernel/build-rootfs.sh](kernel/build-rootfs.sh):

```ini
# /etc/systemd/system/cpu-performance.service
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Verify after **any kernel upgrade or fresh install** (the unit can go missing):

```bash
systemctl is-active cpu-performance.service           # → active
head -1 /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor   # → performance
grep MHz /proc/cpuinfo | sort -nrk4 | head -3         # cores at 4.4+ GHz under load
```

---

## 2. Kernel config (built-in, not runtime)

Set in [kernel/build-kernel.sh](kernel/build-kernel.sh) and baked into the monolithic kernel — no runtime equivalent.

| Option | Why |
|---|---|
| `HZ=1000`, `HZ_1000=y` | High-resolution timer — better latency on SMB, networking, scheduling |
| `NO_HZ_FULL=y` | Tickless mode on isolated CPUs; reduces noise on busy cores |
| `PREEMPT_DYNAMIC=y` | Runtime preemption switching; default `voluntary` works for our workload |
| `CC_OPTIMIZE_FOR_PERFORMANCE=y` | Whole-kernel `-O2`+ optimizations |
| `TRANSPARENT_HUGEPAGE=y` | Less TLB pressure for large heaps (NVIDIA workloads, large file caches) |
| `IOMMU_DEFAULT_DMA_LAZY=y` | Lower-overhead DMA mapping for NICs and NVMe |
| `TCP_CONG_BBR=y`, `NET_SCH_FQ=y` | BBR congestion control needs FQ qdisc; together they replace CUBIC for 10 GbE bulk transfer |
| `XFS_FS=y` | Root FS built-in (no initramfs to load it); also enables our root mount |
| `BLK_DEV_INTEGRITY=y` | Required by bcachefs's CRC64 |
| `CRYPTO_LZ4=y`, `CRYPTO_LZ4HC=y` | Required to build the bcachefs OOT module (selects `LZ4_COMPRESS`, `LZ4HC_COMPRESS`, `LZ4_DECOMPRESS`) |
| `RUST=y` | Future-required by bcachefs; current kernel needs `rustup` + `bindgen-cli` + `libclang-dev` to enable it |

**Disabled on purpose:** `CMDLINE_BOOL` (we pass cmdline via UEFI), `DRM_AMDGPU` (no AMD GPU), `MODULES_SIG_FORCE` (we sign nothing).

---

## 3. Network stack

### NIC tuning (Marvell AQtion 10GbE on `eno1`)

Persisted via `/etc/systemd/network/05-eno1-tune.link` so it survives reboot. Manual apply:

```bash
ethtool -G eno1 rx 8184 tx 8184      # max ring buffers
ethtool -K eno1 tso on gso on gro on # offloads on
ethtool -A eno1 rx on tx on          # flow control (autoneg)
```

Verify:

```bash
ethtool -g eno1 | head           # current ring sizes
ethtool -k eno1 | grep -E "tcp-segmentation|generic-segmentation|generic-receive"
```

### Bridge (br0) — jumbo frames

10 GbE wants jumbo. MTU 9000 across the chain (eno1, eno2, thunderbolt0, br0). Defined in `/etc/netplan/00-en.yaml` — see [network.md](network.md).

Verify negotiation actually succeeded across the wire:

```bash
ip link show br0 | grep mtu              # 9000
ss -ti dst 192.168.1.108 | grep pmtu     # pmtu:9000 on the SMB connection
```

### Sysctl (BBR + big TCP buffers)

In [kernel/build-rootfs.sh](kernel/build-rootfs.sh) → `/etc/sysctl.d/99-lab.conf`:

```conf
net.core.somaxconn = 262144
net.core.netdev_max_backlog = 30000
net.core.rmem_default = 262144
net.core.rmem_max = 268435456
net.core.wmem_default = 262144
net.core.wmem_max = 268435456
net.ipv4.tcp_rmem = 4096 262144 268435456
net.ipv4.tcp_wmem = 4096 262144 268435456
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
```

`tcp_slow_start_after_idle=0` matters for bursty SMB — without it every quiet pause makes BBR re-probe bandwidth and the next burst stalls.

Verify:

```bash
sysctl net.ipv4.tcp_congestion_control net.core.rmem_max net.ipv4.tcp_slow_start_after_idle
```

### IRQ distribution

`irqbalance` is enabled (in [kernel/build-rootfs.sh](kernel/build-rootfs.sh)) and spreads NIC MSI-X interrupts across cores. With 14 cores and 8 NIC queues this gives clean per-queue affinity automatically.

```bash
systemctl is-active irqbalance       # → active
grep eno1 /proc/interrupts           # IRQs distributed across CPU columns
```

---

## 4. Storage stack tuning

Full architecture in [storage.md](storage.md). Performance-relevant settings only:

### bcachefs (writeback hybrid)

The format-time flags that matter for throughput:

| Flag | Effect |
|---|---|
| SSDs `--durability=1` | Foreground writes ack from SSD at NVMe speed (~4 GB/s). Without this, writes are HDD-bound (~250 MB/s) — 18× slower. |
| SSDs `--data_allowed=user` | btree/journal physically blocked from SSDs; HDDs hold all metadata. Prevents wipe-disaster + simplifies reasoning. |
| `--foreground_target=ssd` | Foreground prefers SSDs; combined with durability=1 above, this is the writeback path. |
| `--background_target=hdd` | Mover migrates SSD→HDD continuously, marks SSD pointers as cached for LRU eviction. |
| `--data_replicas=2 --metadata_replicas=2` | Two durable copies always. With our durability config, foreground places both on SSDs; mover later transitions to HDDs. |
| `--compression=none` | Media is already codec-compressed. CPU spent compressing is CPU not spent serving SMB. |

Verified runtime characteristics (from §Failure modes in [storage.md](storage.md#failure-modes--empirically-tested-2026-05-08)):

- Eviction of cached SSD pointers under write pressure: **works** (cached column drops as new writes arrive).
- Single SSD PCI hot-remove: 0 hash failures, FS keeps writing.
- Both SSDs simultaneous loss: data on HDDs intact, only un-migrated in-flight bytes lost.
- `wipefs` on a live SSD with `data_allowed=user` lockdown: 0 hash failures (lockdown holds).

### I/O scheduler

Per-device defaults via udev rule in [kernel/build-rootfs.sh](kernel/build-rootfs.sh) → `/etc/udev/rules.d/60-ioscheduler.rules`:

```udev
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
```

`mq-deadline` keeps HDD seeks bounded; `none` (no scheduler) is right for NVMe — the device's own queue is faster than any kernel scheduler.

Verify:

```bash
for d in sda sdb nvme1n1 nvme2n1; do echo -n "$d: "; cat /sys/block/$d/queue/scheduler; done
```

### TRIM

NVMe full discard is auto-set per device at `bcachefs format` time (visible in `bcachefs show-super` as `Discard: 1`). Periodic `fstrim` is enabled via `fstrim.timer`:

```bash
systemctl is-enabled fstrim.timer    # → enabled
```

---

## 5. Memory / VM

[kernel/build-rootfs.sh](kernel/build-rootfs.sh) writes these to `/etc/sysctl.d/99-lab.conf`:

```conf
vm.swappiness = 1                    # don't swap unless forced
vm.dirty_ratio = 5                   # max 5% of RAM as dirty pages before writers block
vm.dirty_background_ratio = 2        # start writeback at 2% dirty
vm.dirty_expire_centisecs = 12000    # 120s before a dirty page is force-flushed
vm.dirty_writeback_centisecs = 1200  # writeback thread runs every 12s
vm.vfs_cache_pressure = 50           # keep dentry/inode cache around (helps cold metadata)
fs.file-max = 2097152
fs.nr_open = 2097152
```

For a 64 GB box, 5% of RAM is 3.2 GB — plenty of dirty buffer for SMB bursts without letting writeback fall too far behind.

---

## 6. Samba tuning

In [storage.md](storage.md#samba-shares). Performance-relevant excerpts:

```ini
[global]
   server min protocol = SMB3
   use sendfile = Yes               # zero-copy reads
   strict locking = No              # better single-writer perf
   min receivefile size = 16384     # use receivefile (zero-copy) for writes ≥ 16K
   fruit:aapl = yes                 # Apple SMB extensions (required for fruit:metadata, time machine)
   fruit:model = TimeCapsule8,119
   vfs objects = catia fruit streams_xattr
```

`use sendfile = Yes` is the big one for read throughput on 10 GbE — kernel splices the file straight from page cache to the socket without userspace copy.

### Mac SMB ceiling

macOS Finder's SMB client has a **2-parallel-copy limit per share**. We verified empirically: 2 parallel Finder copies aggregate to ~650-780 MB/s reliably; 3+ parallel destabilizes the macOS SMB stack and aborts 2 of 3 transfers with `-43` / "device disappeared" errors. macOS does not engage SMB multichannel against Samba.

If a copy aborts and `/Volumes/media` becomes unresponsive (`ls /Volumes/media: Operation not permitted`):

```bash
killall Finder                       # usually clears stale mount handles
sudo umount -f /Volumes/media        # if killall isn't enough
mount_smbfs //st@lab.local/media /Volumes/media
```

---

## 7. Mac-side throughput notes

The server can write at 4.3 GB/s; the bottleneck above ~575 MB/s is on the Mac side. Things that determine real-world rate:

- **Source disk read speed**. The SanDisk Extreme V2 over USB 3.2 reads at ~965 MB/s sustained for big files; an external HDD or fragmented volume tops out far below that.
- **File-size mix**. SMB has high per-file overhead (open + setattr + write + close + ack each). A folder of small files at 500 files/sec gives 50-150 MB/s regardless of network or storage. Large media files saturate the wire.
- **Parallel copies**. 2 max. See above.
- **macOS RAM cache**. Finder reads ahead aggressively; you'll see a fast burst from cache, then steady state at the source disk's actual read rate.

To measure source disk separately from the network:

```bash
# On Mac, cold read of an actual file (not /dev/zero — that's RAM, not disk)
purge
dd if=/Volumes/Media-SANDISK/<some-big-file> of=/dev/null bs=1m count=2000
```

---

## 8. Verification — full checklist

Run after any kernel upgrade or unexpected reboot:

```bash
# CPU
systemctl is-active cpu-performance.service
head -1 /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

# NIC
ethtool -g eno1 | grep -E "RX:|TX:" | head
ip link show br0 | grep mtu

# TCP
sysctl net.ipv4.tcp_congestion_control net.core.rmem_max

# Storage
systemctl is-active nas.service smbd nmbd
bcachefs fs usage -h /nas | head -8
for d in sda sdb nvme1n1 nvme2n1; do echo -n "$d sched: "; cat /sys/block/$d/queue/scheduler; done
for d in /dev/sda /dev/sdb /dev/nvme1n1 /dev/nvme2n1; do echo -n "$d SMART: "; smartctl -H $d | grep -E "PASSED|FAILED"; done

# Samba
testparm -s 2>/dev/null | grep -E "use sendfile|min protocol|fruit"

# Health
dmesg --level=err,warn --since "1 hour ago" | tail
```

---

## 9. Lessons learned (don't repeat these)

- **Always check `cpu-performance.service` before suspecting samba/network/storage.** A `powersave` governor masquerades as every other bottleneck.
- **`durability=0` on SSDs is *writethrough*, not writeback** — Kent's PoO calls it "essential for cache devices" but only if your goal is read-acceleration with HDD-bound writes. For burst-write workloads, use `durability=1` + `data_allowed=user`.
- **Per-device `bcachefs format` flags persist** — once you set `--durability=N`, subsequent devices on the same command line inherit it unless overridden. Always repeat the flag per device.
- **macOS Finder caps at 2 parallel SMB copies per share.** Don't go to 3 — Mac SMB stack breaks.
- **Blackmagic Disk Speed Test ≠ real read speed** — got 100 MB/s on a SanDisk that reads at 965 MB/s with `dd`. Test pattern matters.
- **`bcachefs format` requires libblkid 2.40.1+** — Ubuntu 24.04 ships 2.39.3, hence we pass `-f` to skip the FS-detection safety guard. Disks were already wiped manually so the guard is redundant.
