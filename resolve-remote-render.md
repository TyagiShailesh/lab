# DaVinci Resolve Remote Render — RTX 6000 Blackwell

Mac (editing) sends render jobs to Linux (lab, 192.168.1.10) with RTX 6000.
Resolve sends render instructions, not media — both machines need the same file paths and a shared PostgreSQL database.

**Requirements:** DaVinci Resolve Studio (same version, same plugins/LUTs/fonts on both machines).

---

## Hardware

**Motherboard:** ASUS ProArt Z890-CREATOR WIFI (BIOS 1901, latest 3002)
**CPU:** Intel Core Ultra 5 235 (Arrow Lake) — iGPU, NPU, OpenVINO 2026.0.0
**RAM:** 62 GB

| Slot | Drive | Role | Status |
|---|---|---|---|
| M.2_1 (Gen5 x4, CPU) | Samsung 9100 Pro 4TB | `/cache` — LLM models + Resolve scratch | pending |
| M.2_2 (Gen4 x4, chipset) | Samsung 990 Pro 2TB | boot (XFS) | done |
| M.2_3 (Gen4 x4, chipset) | Samsung 9100 Pro 4TB | bcachefs cache | pending |
| M.2_4 (Gen4 x4, chipset) | WD Black SN850X 2TB | bcachefs cache | done |
| PCIEX16_1 (Gen5 x16, CPU) | RTX 6000 Blackwell | GPU render + NVENC + LLM inference | pending |
| SATA | 2x Seagate Exos 14TB | bcachefs data (mirrored) | done |

**Storage:**

```
bcachefs /store (24TB raw, 2x replicated)
├── data:    sda + sdb (14TB mirrored HDDs)
├── cache:   nvme M.2_3 (9100 Pro 4TB, Gen4) [pending]
├── cache:   nvme M.2_4 (SN850X 2TB, Gen4) [done]
├── compression: lz4 (foreground) → zstd (background)
├── metadata_target: ssd (3x fsync improvement)
├── foreground_target: ssd
├── background_target: hdd
└── promote_target: ssd

/cache (CPU-attached Gen5, not in bcachefs) [pending]
└── nvme M.2_1 (9100 Pro 4TB, Gen5)
    ├── /cache/models    (LLM weights, disposable)
    └── /cache/resolve   (Resolve scratch)
```

**Network:**
- 10GbE (AQC113) — ~1,100 MB/s read/write (line rate)
- Thunderbolt 5 (Barlow Ridge) — ~5 GB/s
- Both bridged to br0 at 192.168.1.10, MTU 9000
- WireGuard VPN on UDP 51820

**Measured performance:**

| Test | Speed |
|---|---|
| SMB read (10GbE) | 1,100 MB/s |
| SMB write (10GbE) | 1,170 MB/s |
| Local bcachefs write (SSD, no fsync) | 2,500 MB/s |
| Local bcachefs write (SSD, fsync) | 1,500 MB/s |

---

## Completed Setup

### 1. Samba

Separate shares per use case. SMB3 minimum.

```
[media]  → /store/media     (video + resolve assets, st read/write)
[st]     → /store/st        (private, st only)
[data]   → /store/data      (LLM training/temp, st only)
[tm]     → /store/tm        (Time Machine)
```

Config: `/etc/samba/smb.conf`

### 2. Path Mapping

Mac mounts shares individually. Linux has symlinks for Resolve path matching:

```
/Volumes/media → /store/media
/Volumes/st    → /store/st
```

Mac: `smb://lab.local/media` mounts at `/Volumes/media`

### 3. bcachefs

- Mount: `/store` via `bcachefs-store.service`
- `metadata_target: ssd` — journal on SSD, fsync 528 → 1,500 MB/s
- SSD cache (durability 0): writes land on SSD first, replicate to HDDs in background
- Data safe on mirrored HDDs even if SSD dies

### 4. PostgreSQL 18

Installed from official PGDG repo. Data on boot SSD.

```
Data:    /var/lib/postgresql/18/main/
Port:    5432
User:    resolve / resolve
Auth:    scram-sha-256 from 192.168.1.0/24
Backup:  /store/media/resolve/backup/ (nightly 3am, 30-day retention)
```

### 5. Xorg + VNC

Xorg installed (no desktop environment). TigerVNC for one-time Resolve config.
Connect from Mac: `vnc://lab:5901` (password: resolve)

### 6. DaVinci Resolve Studio 20.3.2

Installed at `/opt/resolve`. Cannot launch until NVIDIA driver is installed.

### 7. Services

| Service | Status |
|---|---|
| bcachefs-store.service | enabled |
| postgresql | active |
| smbd | active |
| avahi-daemon | active (lab.local mDNS) |
| wg-quick@wg0 | active (VPN) |
| cpu-performance | enabled (performance governor) |

---

## Pending Setup (when hardware arrives)

See [upgrade.md](upgrade.md) for step-by-step instructions.

1. BIOS update (1901 → 3002) — manual, USB required
2. Samsung 9100 Pro 4TB x2 — bcachefs cache + /cache
3. RTX 6000 Blackwell — NVIDIA driver, Xorg headless, Resolve config, render service

---

## Mac Resolve Config

### Working Folders

| Setting | Path |
|---|---|
| Project media location | `/Volumes/media/resolve` |
| Proxy generation location | `/Volumes/media/resolve/ProxyMedia` |
| Cache files location | `/Users/st/DaVinci/CacheClip` |
| Gallery stills location | `/Volumes/media/resolve/.gallery` |

### Color Management (Studio Display XDR, 2000 nits peak)

| Setting | Value |
|---|---|
| Color science | DaVinci YRGB Color Managed |
| Input color space | Canon Cinema Gamut / Canon Log 3 (R5C) |
| Timeline color space | DaVinci WG/Intermediate |
| Working luminance | 2000 nits |
| Output color space | Rec.709 (Scene) for SDR, P3-D65 ST.2084 for HDR |
| Limit output gamut | P3-D65 |
| Input/Output DRT | DaVinci |

HDR and SDR delivery from the same timeline — override output color space per render job in the Deliver page.

---

## Remote Render Workflow

1. Open project on Mac → Deliver page
2. Set output format
3. Add job to Render Queue
4. Select the Linux render node
5. Start render

Mac stays responsive. All effects (NR, color, Fusion, ResolveFX) render on the RTX 6000.

---

## FFmpeg

### Linux — AV1 (Intel VA-API)

```bash
ffmpeg -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 \
  -i input.mov \
  -vf 'format=nv12,hwupload' \
  -c:v av1_vaapi \
  -profile:v main \
  -b:v 0 -qp 22 \
  -g 120 \
  -c:a copy output.mp4
```

### Linux — AV1 VBR (best quality per size)

```bash
ffmpeg -vaapi_device /dev/dri/renderD128 \
  -i input.mov \
  -vf 'format=p010le,hwupload' \
  -c:v av1_vaapi -rc_mode VBR \
  -b:v 15M -maxrate 17M -bufsize 30M \
  -g 240 -bf 4 -tiles 2x2 -tile_groups 2 \
  -c:a copy output.mp4
```

### Linux — HEVC (Apple compatible)

```bash
ffmpeg -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 \
  -i input.mov \
  -vf 'format=nv12,hwupload' \
  -c:v hevc_vaapi -tag:v hvc1 -b:v 20M \
  -c:a copy output.mp4
```

### Linux — HEVC VBR 10-bit

```bash
ffmpeg -vaapi_device /dev/dri/renderD128 \
  -i input.mov \
  -vf 'format=p010le,hwupload' \
  -c:v hevc_vaapi -tag:v hvc1 -rc_mode VBR \
  -b:v 20M -maxrate 25M -bufsize 40M \
  -g 120 -bf 4 \
  -c:a copy output.mp4
```

### Linux — AV1 NVENC (when RTX 6000 arrives)

```bash
ffmpeg -hwaccel cuda -i input.mov \
  -c:v av1_nvenc -preset p7 -tune hq -multipass fullres -cq 22 \
  -c:a copy output.mp4
```

### Mac — HEVC (VideoToolbox)

```bash
ffmpeg -i input.mov \
  -c:v hevc_videotoolbox -q:v 50 -tag:v hvc1 \
  output.mp4
```

### Mac — HEVC 720p

```bash
ffmpeg -i input.mov \
  -vf scale=1280:720 \
  -c:v hevc_videotoolbox -q:v 25 -tag:v hvc1 \
  output.mp4
```

### Mac — Batch convert

```bash
mkdir -p converted && for f in *.MP4; do
  ffmpeg -i "$f" \
    -c:v hevc_videotoolbox -q:v 50 -tag:v hvc1 \
    -c:a aac -b:a 128k \
    "converted/${f%.MP4}.mp4"
done
```

### Mac — Audio (noise reduction)

```bash
ffmpeg -i input.WAV \
  -c:a aac -b:a 64k -ar 48000 -ac 2 \
  -af afftdn \
  output.m4a
```

### AV1 quality guide

| qp | Use |
|---|---|
| 18 | overkill, huge files |
| 20 | near-transparent, archiving |
| 22-24 | sweet spot for most content |
| 28 | good for sharing/web |

FFmpeg cannot decode Canon Cinema RAW Light (.CRM). Use Resolve to render CRM to ProRes/HEVC first, then FFmpeg for re-encoding.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Render node not visible | Same network? Same DB? Restart Resolve on both |
| Media offline on render node | Path mismatch — check `/Volumes/media` symlink |
| Resolve won't start on Linux | DISPLAY=:1 set? Xorg running? NVIDIA driver loaded? |
| glib errors on Ubuntu | Move Resolve's bundled glib to `/opt/resolve/libs/disabled/` |
| SSD thermal throttling | Ensure M.2 heatsinks installed |
