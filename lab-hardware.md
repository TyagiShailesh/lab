# Lab Server Hardware

## System Specs

| Component | Detail |
|---|---|
| Motherboard | ASUS ProArt Z890-CREATOR WIFI (Rev 1.xx) |
| CPU | Intel Core Ultra 5 235 (Arrow Lake, 14C/14T, 3.6 GHz base / 4.8 GHz boost) |
| RAM | 64 GB DDR5-5600 (2x 32 GB Micron CP32G64C40U5B, slots A1+B1, 2 slots empty) |
| GPU | None (Intel integrated, Arrow Lake UHD) |
| NPU | Intel Arrow Lake NPU |
| Network | Aquantia AQC113 10GbE + Intel I226-V 2.5GbE, bridged as br0 (192.168.1.10/24) |
| Thunderbolt | 2x Thunderbolt 4 (Barlow Ridge 80G) via USB4 |
| WireGuard | wg0 (10.0.0.1/30) |
| Kernel | 6.19.6 (PREEMPT_DYNAMIC) |
| OS | Ubuntu (XFS root) |

## Storage Layout (Current)

| Slot | Drive | Model | Size | Role | Filesystem | Mount |
|---|---|---|---|---|---|---|
| M.2_2 (Gen4, chipset) | Samsung 990 Pro | Samsung SSD 990 PRO 2TB (S7KHNU0Y517886B) | 2 TB | Boot | XFS (root) + vfat (EFI) | `/` + `/boot/efi` |
| M.2_4 (Gen4, chipset) | WD Black SN850X | WD_BLACK SN850X HS 2000GB (24364L800813) | 2 TB | bcachefs cache (label: ssd) | bcachefs | `/data`, `/store` |
| SATA 0 | Seagate Exos | ST14000NM000J-2TX103 (label: hdd) | 14 TB | bcachefs data | bcachefs | `/data`, `/store` |
| SATA 1 | Seagate Exos | ST14000NM001G-2KJ103 (label: hdd) | 14 TB | bcachefs data | bcachefs | `/data`, `/store` |
| M.2_1 (Gen5, CPU) | — | — | — | Empty | — | — |
| M.2_3 (Gen4, chipset) | — | — | — | Empty | — | — |
| PCIEX16_1 (Gen5, CPU) | — | — | — | Empty | — | — |

### bcachefs pool

- **Devices:** 2x HDD (data, mirrored) + 1x NVMe SSD (cache, durability 2)
- **Mount:** `/data` (primary), `/store` (bind)
- **Replication:** metadata 2, data 2
- **Compression:** none (foreground), zstd (background — applied during HDD migration)
- **Tiering:** writes land on SSD uncompressed at full NVMe speed (~2.5 GB/s), background-move to HDD with zstd; reads promote to SSD
  - `foreground_target: ssd`, `background_target: hdd`, `promote_target: ssd`, `metadata_target: ssd`
- **Capacity:** ~24 TB raw (14 TB usable after mirroring), 8.4 TB used

### Samba shares

| Share | Path | Notes |
|---|---|---|
| media | `/store/media` | force user: st |
| st | `/store/st` | force user: st, 0600/0700 masks |
| data | `/store/data` | force user: st, 0600/0700 masks |
| tm | `/store/tm` | Time Machine, 4 TB max |

Config: SMB3 minimum, macOS fruit/AAPL extensions enabled, NetBIOS disabled.

---

## Target State (Upgrade Plan)

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

### NVIDIA driver

```bash
apt install -y linux-headers-$(uname -r) dkms
apt install -y nvidia-driver-570  # or latest for Blackwell
reboot
nvidia-smi  # verify: RTX 6000, 96GB VRAM
```

### Xorg headless display

```bash
nvidia-xconfig --allow-empty-initial-configuration --use-display-device=None --virtual=1920x1080
systemctl enable --now resolve-xorg.service
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
systemctl enable --now resolve-render.service
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
| SMB read/write (TB4) | ~3,000 MB/s |
| bcachefs read (SSD cache) | 6,000–14,000 MB/s |
| bcachefs write (SSD) | ~2,500 MB/s |
| bcachefs fsync (journal on SSD) | ~1,500 MB/s |
| LLM model load to VRAM | ~14,000 MB/s (Gen5 x4) |
| FFmpeg AV1 encode (NVENC) | realtime or faster at 4K |
