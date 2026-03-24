# Upgrade Plan

## Target State

| Slot | Drive | Role |
|---|---|---|
| M.2_1 (Gen5, CPU) | Samsung 9100 Pro 4TB | `/cache` — LLM models + Resolve scratch |
| M.2_2 (Gen4, chipset) | Samsung 990 Pro 2TB | Boot (no change) |
| M.2_3 (Gen4, chipset) | Samsung 9100 Pro 4TB | bcachefs cache |
| M.2_4 (Gen4, chipset) | WD Black SN850X 2TB | bcachefs cache |
| PCIEX16_1 (Gen5, CPU) | RTX 6000 Blackwell | GPU render + NVENC + LLM |
| SATA | 2x Seagate Exos 14TB | bcachefs data (no change) |

M.2_1 and PCIEX16_1 are both on CPU PCIe 5.0 lanes — LLM model loading at ~14 GB/s direct to GPU VRAM.

---

## BIOS Update (do first)

Current: **1901**. Latest: **3002** (2026-01-30).

1. Download from ASUS support (file already on NAS at `/store/data/asus/`)
2. Copy to USB drive (FAT32)
3. EZ Flash from BIOS (Del key at POST → Tool → EZ Flash)
4. Reboot, verify version

**Do before installing RTX 6000.**

---

## Phase 1: SSDs (when 9100 Pros arrive)

Power off. Install both drives:
- M.2_1 slot (Gen5, closest to CPU)
- M.2_3 slot (Gen4, chipset)

Boot and identify:

```bash
lsblk -o NAME,SIZE,MODEL,TRAN
```

### M.2_3 → bcachefs cache

```bash
bcachefs device add --label=ssd /store /dev/nvme<M2_3>
bcachefs fs usage /store
```

### M.2_1 → /cache

```bash
mkfs.xfs /dev/nvme<M2_1>
mkdir -p /cache
echo '/dev/disk/by-id/<9100-pro-m2_1-id>  /cache  xfs  defaults,noatime  0  0' >> /etc/fstab
mount /cache
chown st:st /cache
mkdir -p /cache/models /cache/resolve
```

### Verify

```bash
bcachefs fs usage /store    # 2 HDDs + 2 SSD cache (6TB total)
df -h /cache                # 4TB XFS
```

---

## Phase 2: RTX 6000

Power off. Install in PCIEX16_1. Connect power cables. Boot.

See [gpu.md](gpu.md) for NVIDIA driver and Xorg headless setup.
See [resolve.md](resolve.md) for Resolve config and render service.

---

## Phase 3: Verify

```bash
# Storage
bcachefs fs usage /store
df -h /cache
ls /Volumes/media/video

# GPU
nvidia-smi
ffmpeg -encoders 2>/dev/null | grep nvenc

# Services
systemctl status resolve-render.service
systemctl status postgresql
systemctl status resolve-xorg.service

# From Mac: render node should appear in Deliver → Render Queue
```

---

## Expected Post-upgrade Performance

| Operation | Expected |
|---|---|
| SMB read/write (10GbE) | ~1,100 MB/s |
| SMB read/write (TB5) | ~3,000 MB/s |
| bcachefs read (SSD cache) | 6,000–14,000 MB/s |
| bcachefs write (SSD) | ~2,500 MB/s |
| bcachefs fsync (journal on SSD) | ~1,500 MB/s |
| LLM model load to VRAM | ~14,000 MB/s (Gen5 x4) |
| FFmpeg AV1 encode (NVENC) | realtime or faster at 4K |
