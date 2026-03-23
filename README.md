# Lab Server (192.168.1.10)

DaVinci Resolve render node + storage server.

## Hardware

```
ASUS ProArt Z890-CREATOR WIFI / Intel Core Ultra 5 235 (Arrow Lake)
62 GB RAM / Ubuntu 24.04 / Kernel 6.19.6

M.2_1 (Gen5, CPU)     → Samsung 9100 Pro 4TB  → /cache (Resolve scratch)      [pending]
M.2_2 (Gen4, chipset) → Samsung 990 Pro 2TB   → boot (XFS)                     [done]
M.2_3 (Gen4, chipset) → Samsung 9100 Pro 4TB  → bcachefs cache                 [pending]
M.2_4 (Gen4, chipset) → WD Black SN850X 2TB   → bcachefs cache                 [done]
PCIEX16_1 (Gen5, CPU) → RTX 6000 Blackwell    → GPU render + NVENC             [pending]
SATA                   → 2x Seagate Exos 14TB  → bcachefs data (mirrored)       [done]
10GbE (AQC113)         → ~1,100 MB/s                                            [done]
TB5 (Barlow Ridge)     → ~5 GB/s                                                [done]
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
| bcachefs tuning (metadata_target=ssd) | done |
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

- [resolve-remote-render.md](resolve-remote-render.md) — Resolve remote render setup
- [lab-hardware.md](lab-hardware.md) — hardware upgrade plan (BIOS, SSDs, RTX 6000)

## Arqic + Khor (moved)

Inference and storage specs are at `/data/code/ws/docs/`:
- `arqic-specs.md` — Arqic inference fabric
- `khor-cache-specs.md` — Khor Cache RDMA KV cache tier
- `arqic-khor-references.md` — technical references
