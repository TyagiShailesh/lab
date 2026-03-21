# Hardware Upgrade Plan

## Current State

| Slot | Drive | Role | Status |
|---|---|---|---|
| M.2_1 (Gen5, CPU) | empty | — | — |
| M.2_2 (Gen4, chipset) | Samsung 990 Pro 2TB | boot (XFS) | done |
| M.2_3 (Gen4, chipset) | empty | — | — |
| M.2_4 (Gen4, chipset) | WD Black SN850X 2TB | bcachefs cache | done |
| PCIEX16_1 (Gen5, CPU) | empty | — | — |
| SATA | 2x Seagate Exos 14TB | bcachefs data (mirrored) | done |

## Target State

| Slot | Drive | Role |
|---|---|---|
| M.2_1 (Gen5, CPU) | Samsung 9100 Pro 4TB | `/cache` — LLM models + Resolve scratch |
| M.2_2 (Gen4, chipset) | Samsung 990 Pro 2TB | boot (no change) |
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
sudo mkdir -p /cache
echo '/dev/disk/by-id/<9100-pro-m2_1-id>  /cache  xfs  defaults,noatime  0  0' | sudo tee -a /etc/fstab
sudo mount /cache
sudo chown st:st /cache
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

### NVIDIA driver

```bash
sudo apt install -y linux-headers-$(uname -r) dkms
sudo apt install -y nvidia-driver-570  # or latest for Blackwell
sudo reboot
nvidia-smi  # verify: RTX 6000, 96GB VRAM
```

### Xorg headless display

```bash
sudo nvidia-xconfig --allow-empty-initial-configuration --use-display-device=None --virtual=1920x1080
sudo systemctl enable --now resolve-xorg.service
```

### Resolve config (one-time, via VNC)

```bash
vncserver :1 -localhost no -geometry 1920x1080
# Connect from Mac: vnc://lab:5901
DISPLAY=:1 /opt/resolve/bin/resolve
```

In Resolve on Linux:
- Preferences → Memory & GPU → CUDA, select RTX 6000
- Preferences → Media Storage → add `/Volumes/media/video`
- Preferences → Media Storage → cache: `/cache/resolve`
- Connect to PostgreSQL (192.168.1.10, user: resolve)
- Workspace → Remote Rendering → Enable

Kill VNC after:

```bash
vncserver -kill :1
```

### Enable render service

```bash
sudo systemctl enable --now resolve-render.service
```

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

## Post-upgrade performance

| Operation | Expected |
|---|---|
| SMB read/write (10GbE) | ~1,100 MB/s |
| SMB read/write (TB5) | ~4,000 MB/s |
| bcachefs read (SSD cache) | 6,000-14,000 MB/s |
| bcachefs write (SSD) | ~2,500 MB/s |
| bcachefs fsync (journal on SSD) | ~1,500 MB/s |
| LLM model load to VRAM | ~14,000 MB/s (Gen5 x4) |
| FFmpeg AV1 encode (NVENC) | realtime or faster at 4K |
