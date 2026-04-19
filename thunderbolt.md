# Thunderbolt Networking

## Hardware

Rear I/O USB-C ports (from ProArt Z890 manual p.30):

| Port | Controller | Domain | PCI | Bandwidth |
|---|---|---|---|---|
| Port 2 | Barlow Ridge | domain1 | `87:00.0` | 80 Gbps (TB5) |
| Port 10 | Meteor Lake PCH | domain0 | `00:0d.2` | 40 Gbps (TB4) |

## Driver

Stock in-tree `thunderbolt_net`. No local patches, no out-of-tree module. `thunderbolt0` is bridged into `br0` alongside the 10 GbE and 2.5 GbE NICs.

## Performance (stock driver, TB5 port, iperf3, single flow)

| Direction | Throughput | Bottleneck |
|---|---|---|
| RX (Mac → lab) | ~20 Gbps | single-core NAPI poll on a single RX ring |
| TX (lab → Mac) | ~40 Gbps | single-core TX |

### Why single-core limited

The driver uses a single TX/RX DMA ring pair — one CPU core handles all packets. The Barlow Ridge NHI supports up to 1023 HopIDs and 16 MSI-X vectors, but:

- **Multi-TX ring**: feasible without protocol changes, but TX is already fast enough.
- **Multi-RX ring**: requires USB4NET protocol changes that would break macOS compatibility — not viable.
- **RPS / busy-poll tuning**: tested, no improvement for single-flow RX (work happens in NAPI before RPS can fan out).

20 Gbps RX is plenty for the actual workload (file serving and Time Machine backups at 10 GbE line rate).
