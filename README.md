# DaVinci Resolve Render Farm

Mac + Linux render farm for DaVinci Resolve Studio.

## Machines

| Machine | Hostname | Role |
|---|---|---|
| Mac | — | Editing, grading (Apple Studio Display XDR) |
| Linux | `lab` (192.168.1.10) | Render node, storage, LLM inference |

## Hardware (lab)

```
ASUS ProArt Z890-CREATOR WIFI / Intel Core Ultra 5 235 (Arrow Lake)
62 GB RAM / Ubuntu 24.04 / Kernel 6.19.6

M.2_1 (Gen5, CPU)     → Samsung 9100 Pro 4TB  → /cache (LLM models + Resolve scratch)  [pending]
M.2_2 (Gen4, chipset) → Samsung 990 Pro 2TB   → boot (XFS)                              [done]
M.2_3 (Gen4, chipset) → Samsung 9100 Pro 4TB  → bcachefs cache                          [pending]
M.2_4 (Gen4, chipset) → WD Black SN850X 2TB   → bcachefs cache                          [done]
PCIEX16_1 (Gen5, CPU) → RTX 6000 Blackwell    → GPU render + NVENC + LLM inference      [pending]
SATA                   → 2x Seagate Exos 14TB  → bcachefs data (mirrored)                [done]
10GbE (AQC113)         → ~1,100 MB/s                                                     [done]
TB5 (Barlow Ridge)     → ~5 GB/s                                                         [done]
```

## Storage Layout

```
/store/                        (bcachefs pool, 24TB raw, 2x replicated)
├── media/                     → [media] SMB share
│   ├── video/                   source footage
│   └── resolve/                 project media, proxies, gallery, backups
│       ├── .gallery/
│       ├── backup/              nightly PostgreSQL dumps (30-day retention)
│       ├── Music/
│       └── ProxyMedia/
├── st/                        → [st] SMB share (private)
├── data/                      → [data] SMB share (LLM training, temp)
├── tm/                        → [TM] SMB share (Time Machine)
└── code/                        dev projects (moves to /cache SSD later)

/cache/                        (Gen5 SSD, CPU-attached, not bcachefs) [pending]
├── models/                      LLM weights (disposable)
└── resolve/                     Resolve scratch/cache
```

## Mac Mounts

| Share | Mac Path | Purpose |
|---|---|---|
| `smb://lab.local/media` | `/Volumes/media` | video + resolve assets |
| `smb://lab.local/st` | `/Volumes/st` | private files |
| `smb://lab.local/data` | `/Volumes/data` | LLM training, temp |
| `smb://lab.local/TM` | (auto) | Time Machine |

## Resolve Paths (Mac)

| Setting | Path |
|---|---|
| Project media location | `/Volumes/media/resolve` |
| Proxy generation location | `/Volumes/media/resolve/ProxyMedia` |
| Cache files location | `/Users/st/DaVinci/CacheClip` |
| Gallery stills location | `/Volumes/media/resolve/.gallery` |

## How It Works

```
Mac (edit/grade on XDR)
  ↕ PostgreSQL (project data)
  ↕ SMB [media] share (10GbE or TB5)
Linux (headless render node)
  → RTX 6000 renders timeline (CUDA + NVENC)
  → reads source from /store/media/video (local disk, no network)
  → writes output to /store/media/video
Mac sees finished file at /Volumes/media/video/
```

## Status

| Component | Status |
|---|---|
| Samba (media/st/data/TM shares, SMB3) | done |
| Path mapping (symlinks on Linux) | done |
| bcachefs tuning (metadata_target=ssd) | done |
| PostgreSQL 18 (PGDG, nightly backup) | done |
| Mac Resolve → PostgreSQL | done |
| Xorg + VNC (TigerVNC) | done |
| DaVinci Resolve Studio 20.3.2 | done |
| OpenVINO 2026.0.0 | done |
| WireGuard (UDP 51820) | done |
| Avahi/mDNS (lab.local) | done |
| CPU governor (performance) | done |
| BIOS update (1901 → 3002) | pending (manual) |
| Samsung 9100 Pro 4TB x2 | pending (hardware) |
| RTX 6000 Blackwell | pending (hardware) |
| NVIDIA driver + headless config | pending (needs GPU) |
| Resolve render node service | pending (needs GPU) |

## Files

- [rtx.md](rtx.md) — full setup guide (Resolve, storage, FFmpeg, color management)
- [upgrade.md](upgrade.md) — hardware upgrade plan (BIOS, SSDs, RTX 6000)
- [arc.md](arc.md) — Arc inference engine spec (Origon platform, TensorRT-LLM, NIXL/GDS)
- [arc-vs-dynamo.md](arc-vs-dynamo.md) — Arc vs Dynamo architecture comparison and performance analysis
- [llm.md](llm.md) — LLM research notes (Dynamo, models, benchmarks)
