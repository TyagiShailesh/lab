# Thunderbolt Networking

## Hardware

Rear I/O USB-C ports (from ProArt Z890 manual p.30):

| Port | Controller | Domain | PCI | Bandwidth |
|---|---|---|---|---|
| Port 2 | Barlow Ridge | domain1 | `87:00.0` | 80 Gbps (TB5) |
| Port 10 | Meteor Lake PCH | domain0 | `00:0d.2` | 40 Gbps (TB4) |

## Driver

Using `thunderbolt_net` with a local page_pool RX patch at [kernel/tb-upstream/0001-net-thunderbolt-convert-Rx-path-to-page_pool.patch](kernel/tb-upstream/0001-net-thunderbolt-convert-Rx-path-to-page_pool.patch), applied during kernel build. Bumps ring size 256 → 1024 and replaces per-packet `dma_unmap_page` with page_pool recycling. Upstream submission workflow: [kernel/tb-upstream/](kernel/tb-upstream/).

## Performance (patched driver, TB5 port, iperf3)

| Direction | Throughput | Bottleneck |
|---|---|---|
| TX (lab→Mac) | ~41 Gbps / 5.1 GB/s | single core TX |
| RX (Mac→lab) | ~42 Gbps / 5.25 GB/s | single core NAPI poll |

Stock in-tree driver: RX ~20 Gbps — the patch roughly doubles it.

### Why single-core limited

The driver uses a single TX/RX DMA ring pair — one CPU core handles all packets. The Barlow Ridge NHI supports up to 1023 HopIDs and 16 MSI-X vectors, but:

- **Multi-TX ring**: feasible without protocol changes (~200 LOC), but TX is already fast enough
- **Multi-RX ring**: requires USB4NET protocol changes that would break macOS compatibility — not viable
- **RPS/busy-poll tuning**: tested, no improvement for single-flow RX (work happens in NAPI before RPS)

## Tuning (persistent via `thunderbolt-tune.service`)

```
IRQ pinning:  RX → P-core 0 (5 GHz), TX → P-core 1
RPS:          all 14 cores (3fff), 4096 flow entries
NAPI:         busy-poll (defer_hard_irqs=2, gro_flush_timeout=200000)
```

## Restoring the patched driver

```bash
git show b62fe82^:system/thunderbolt_net/main.c > main.c
git show b62fe82^:system/thunderbolt_net/trace.c > trace.c
git show b62fe82^:system/thunderbolt_net/trace.h > trace.h
git show b62fe82^:system/thunderbolt_net/Makefile > Makefile
```
