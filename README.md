# Lab Server (192.168.1.10)

Storage server + NVIDIA compute box (CUDA, NVENC, GDS).

ASUS ProArt Z890-CREATOR WIFI / Intel Core Ultra 5 235 (Arrow Lake) / 64 GB RAM / Ubuntu 24.04 / Kernel 6.19.10

## Status

| Component | Status |
|---|---|
| bcachefs pool ([bcachefs.md](bcachefs.md)) | done (one-time migration: [migrate-bcachefs.md](migrate-bcachefs.md)) |
| Samba (media, st, data, iris, tm — SMB3) | done |
| PostgreSQL 18 (PGDG, nightly backup) | done |
| Mac DaVinci Resolve → PostgreSQL | done |
| WireGuard (UDP 51820) | done |
| Avahi / mDNS (lab.local) | done |
| NVIDIA RTX PRO 2000 Blackwell | done |
| NVIDIA driver + CUDA + GDS | done |
| OpenVINO 2026.0.0 | done |
| Thunderbolt networking | done (in-tree); upstream page_pool RX port: [thunderbolt-upstream.md](thunderbolt-upstream.md) |

## Docs

- [hardware.md](hardware.md) — board, CPU, RAM, slots, drives, BIOS
- [network.md](network.md) — br0, 10GbE, Thunderbolt, WireGuard, sysctl
- [storage.md](storage.md) — Samba shares + storage overview
- [bcachefs.md](bcachefs.md) — pool architecture, devices, systemd, kernel module
- [postgres.md](postgres.md) — PostgreSQL 18 + backup cron
- [gpu.md](gpu.md) — NVIDIA RTX PRO 2000: driver, CUDA, GDS
- [media.md](media.md) — FFmpeg recipes + AI upscaling
- [thunderbolt.md](thunderbolt.md) — Thunderbolt runbook
- [thunderbolt-upstream.md](thunderbolt-upstream.md) — page_pool RX upstream work
- [post-install.md](post-install.md) — OS bring-up runbook
- [migrate-bcachefs.md](migrate-bcachefs.md) — one-time pool migration (delete after run)
- [kernel/](kernel/) — custom kernel build pipeline (scripts + config + patches)
- [scripts/](scripts/) — runnable tools (FFmpeg encoders, media stack builder)

## Arqic + Khor (moved)

Inference and storage specs are at `/data/code/ws/docs/`:
- `arqic-specs.md` — Arqic inference fabric
- `khor-cache-specs.md` — Khor Cache RDMA KV cache tier
- `arqic-khor-references.md` — technical references
