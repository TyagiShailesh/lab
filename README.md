# Lab Server (192.168.1.10)

DaVinci Resolve render node + storage server.

ASUS ProArt Z890-CREATOR WIFI / Intel Core Ultra 5 235 (Arrow Lake) / 64 GB RAM / Ubuntu 24.04 / Kernel 6.19.9

## Status

| Component | Status |
|---|---|
| Samba (media/st/data/iris/TM shares, SMB3) | done |
| bcachefs tuning (SSD durability 2, no foreground compression, zstd at rest) | done |
| PostgreSQL 18 (PGDG, nightly backup) | done |
| Mac Resolve → PostgreSQL | done |
| Xorg + VNC (TigerVNC) | done |
| DaVinci Resolve Studio 20.3.2 | done |
| OpenVINO 2026.0.0 | done |
| WireGuard (UDP 51820) | done |
| Avahi/mDNS (lab.local) | done |
| Samsung 9100 Pro 4TB x2 | pending (hardware) |
| RTX 6000 Blackwell | pending (hardware) |
| NVIDIA driver + headless config | pending (needs GPU) |
| Resolve render node service | pending (needs GPU) |

## Docs

- [system/](system/) — OS, custom kernel, build scripts, post-install config, disaster recovery
- [hardware.md](hardware.md) — board, CPU, RAM, slots, ports, BIOS
- [storage.md](storage.md) — bcachefs pool, samba shares
- [gpu.md](gpu.md) — NVIDIA driver, Xorg headless, FFmpeg encode commands
- [resolve.md](resolve.md) — DaVinci Resolve setup, color management, remote render
- [upgrade-plan.md](upgrade-plan.md) — BIOS update, SSD + GPU install phases

## Arqic + Khor (moved)

Inference and storage specs are at `/data/code/ws/docs/`:
- `arqic-specs.md` — Arqic inference fabric
- `khor-cache-specs.md` — Khor Cache RDMA KV cache tier
- `arqic-khor-references.md` — technical references
