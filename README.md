# Lab Server (192.168.1.10)

DaVinci Resolve render node + storage server.

## Hardware

```
ASUS ProArt Z890-CREATOR WIFI / Intel Core Ultra 5 235 (Arrow Lake)
64 GB RAM / Ubuntu 24.04 / Kernel 6.19.9

M.2_1 (Gen5, CPU)     → Samsung 9100 Pro 4TB  → /cache (Resolve scratch)      [pending]
M.2_2 (Gen4, chipset) → Samsung 990 Pro 2TB   → boot (XFS)                     [done]
M.2_3 (Gen4, chipset) → Samsung 9100 Pro 4TB  → bcachefs cache                 [pending]
M.2_4 (Gen4, chipset) → WD Black SN850X 2TB   → bcachefs cache                 [done]
PCIEX16_1 (Gen5, CPU) → RTX 6000 Blackwell    → GPU render + NVENC             [pending]
SATA                   → 2x Seagate Exos 14TB  → bcachefs data (mirrored)       [done]
10GbE (Marvell AQtion) → ~1,100 MB/s                                            [done]
2x TB5 + 1x TB4       → USB Type-C                                             [done]
```

## Storage Layout

```
/store/                        (bcachefs pool, 24TB raw, 2x replicated)
├── media/                     → [media] SMB share
│   ├── video/                   source footage
│   └── resolve/                 project media, proxies, gallery, backups
├── st/                        → [st] SMB share (private)
├── data/                      → [data] SMB share
└── tm/                        → [TM] SMB share (Time Machine)

/cache/                        (Gen5 SSD, CPU-attached) [pending]
└── resolve/                     Resolve scratch/cache
```

## Status

| Component | Status |
|---|---|
| Samba (media/st/data/TM shares, SMB3) | done |
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

## Services

| Service | Status |
|---|---|
| bcachefs-store.service | enabled |
| postgresql | active |
| smbd | active |
| avahi-daemon | active (lab.local mDNS) |
| wg-quick@wg0 | active (VPN) |
| cpu-performance | enabled (performance governor) |

## Docs

- [system/](system/) — OS, custom kernel, EFISTUB boot, bcachefs module, build scripts, kernel config
- [hardware.md](hardware.md) — board, CPU, RAM, slots, ports
- [storage.md](storage.md) — bcachefs, samba, PostgreSQL
- [gpu.md](gpu.md) — NVIDIA driver, Xorg headless, FFmpeg encode commands
- [resolve.md](resolve.md) — DaVinci Resolve setup, color management, remote render
- [upgrade-plan.md](upgrade-plan.md) — BIOS update, SSD + GPU install phases

## Arqic + Khor (moved)

Inference and storage specs are at `/data/code/ws/docs/`:
- `arqic-specs.md` — Arqic inference fabric
- `khor-cache-specs.md` — Khor Cache RDMA KV cache tier
- `arqic-khor-references.md` — technical references
