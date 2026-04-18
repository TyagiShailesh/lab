# Lab Server (192.168.1.10)

Storage server + NVIDIA compute box (CUDA, NVENC, GDS).

ASUS ProArt Z890-CREATOR WIFI / Intel Core Ultra 5 235 (Arrow Lake) / 64 GB RAM / Ubuntu 24.04 / Kernel 7.0.0

## Docs

- [hardware.md](hardware.md) — board, CPU, RAM, slots, drives, BIOS
- [network.md](network.md) — br0, 10GbE, Thunderbolt, WireGuard, sysctl
- [storage.md](storage.md) — Samba shares + storage overview
- [bcachefs.md](bcachefs.md) — pool architecture, devices, systemd, kernel module
- [gpu.md](gpu.md) — NVIDIA RTX PRO 2000: driver, CUDA, GDS
- [media.md](media.md) — FFmpeg recipes + AI upscaling
- [thunderbolt.md](thunderbolt.md) — Thunderbolt runbook
- [tb-upstream.md](tb-upstream.md) — how to submit the thunderbolt_net page_pool patch upstream
- [kernel/](kernel/) — custom kernel build pipeline (scripts + config + patches)
- [scripts/](scripts/) — runnable tools (FFmpeg encoders, media stack builder)

## Arqic + Khor (moved)

Inference and storage specs are at `/data/code/ws/docs/`:
- `arqic-specs.md` — Arqic inference fabric
- `khor-cache-specs.md` — Khor Cache RDMA KV cache tier
- `arqic-khor-references.md` — technical references
