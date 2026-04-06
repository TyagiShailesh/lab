# GPU

## Slot Layout

Both GPUs in CPU-direct slots (PCIe 5.0 x8/x8 split mode). 3-slot spacing
on the ProArt Z890 — both dual-slot cards fit with airflow gap between them.

| Slot | Card | Mode | Bandwidth |
|---|---|---|---|
| PCIEX16_1 (CPU) | AMD Radeon AI PRO R9700 | PCIe 5.0 x8 | 16 GB/s |
| PCIEX16_2 (CPU) | NVIDIA RTX PRO 2000 Blackwell | PCIe 5.0 x8 | 16 GB/s (card is natively x8) |

x8 split loses no practical performance — inference and rendering are
GPU-compute-bound, not PCIe-bound. SSD model loading is bottlenecked by the
Samsung 9100 at 14.5 GB/s, well under the 16 GB/s x8 link.

## Intel integrated (Arrow Lake UHD)

- VA-API hardware encode via `/dev/dri/renderD128`
- OpenVINO 2026.0.0 installed

## AMD Radeon AI PRO R9700

Primary GPU — ML inference, LLM serving, FFmpeg transcode. ASRock Creator
variant (blower, 4× DP 2.1a, vapor chamber, multi-GPU airflow cutouts).

- Architecture: RDNA 4 (Navi 48), 4nm
- VRAM: 32 GB GDDR6 (ECC), 256-bit, 640 GB/s
- Compute: 48 TFLOPS FP32, 191 TFLOPS FP16 matrix, 1531 INT4 sparse TOPS
- Media: dual VCN 5.0 (2× AV1/HEVC/H.264 encode/decode, AV1 B-frame support)
- TDP: 300W, 1× 16-pin 12V-2x6
- PCIe: Gen5 x8 (in split mode)
- Price: $1,299

### Driver stack

- Kernel: amdgpu built as module (mainline, RDNA 4 supported)
- Mesa: VA-API encode/decode, RADV Vulkan Video for VCN 5.0

ROCm install (for ML inference):
```bash
# Follow latest instructions at:
# https://rocm.docs.amd.com/projects/install-on-linux/en/latest/
apt install rocm
# Verify:
rocminfo
clinfo
```

Kernel parameters (`iommu=pt` already on cmdline for NVMe/GDS):
```
amdgpu.runpm=0
```

### Use cases

| Workload | Stack |
|---|---|
| ML inference (speech-engine) | Burn (CubeCL → ROCm) |
| LLM inference (arqic) | vLLM (ROCm) |
| FFmpeg transcode | VA-API via Mesa |
| DaVinci Resolve | OpenCL via ROCm (not officially supported on Linux — test first) |

## NVIDIA RTX PRO 2000 Blackwell

Dedicated Resolve / CUDA card. 70W, slot-powered, no power cable.

- Architecture: Blackwell (GB206), 5nm
- CUDA cores: 4,352 / Tensor cores: 136 (Gen 5)
- VRAM: 16 GB GDDR7 (ECC), 128-bit, 288 GB/s
- Media: 1× NVENC 9th gen, 1× NVDEC 6th gen
- TDP: 70W (slot-powered, no external cable)
- PCIe: Gen5 x8 (native)
- Price: $730

### Driver install

Install from NVIDIA's official CUDA repo (not Ubuntu's apt defaults):
```bash
# Latest CUDA repo setup: https://developer.nvidia.com/cuda-downloads
# Select: Linux → x86_64 → Ubuntu → 24.04 → deb (network)
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb
apt update
apt install -y cuda
# Verify:
nvidia-smi
nvcc --version
```

### GPUDirect Storage (GDS)

PCIe peer-to-peer DMA between Samsung 9100 Pro NVMe and RTX PRO 2000, bypassing CPU bounce buffers. Both devices are on CPU-direct PCIe 5.0 lanes (same root complex).

Kernel module (`nvidia-fs.ko`) is pre-built in `system/build-kernel.sh`. Kernel config enables `PCI_P2PDMA`, `ZONE_DEVICE`, `MEMORY_HOTPLUG`, `DMABUF_MOVE_NOTIFY`. Cmdline requires `iommu=pt`.

```bash
# Install GDS userspace (on target)
apt install nvidia-gds

# Load module
modprobe nvidia-fs

# Verify P2P support
/usr/local/cuda/gds/tools/gdscheck -p
```

| | |
|---|---|
| Kernel module | `nvidia-fs.ko` v2.28.2 ([NVIDIA/gds-nvidia-fs](https://github.com/NVIDIA/gds-nvidia-fs)) |
| Driver | 595.58.03 (open kernel modules) |
| CUDA | 13.2 |
| NVMe | Samsung 9100 Pro, M.2\_1 Gen5 CPU-direct, IOMMU group 15 |
| GPU | RTX PRO 2000, PCIEX16\_2 Gen5 CPU-direct, IOMMU group 16 |

### Use cases

| Workload | Stack |
|---|---|
| DaVinci Resolve | CUDA (officially supported on Linux) |
| Speech-engine (Candle, until Burn port) | CUDA |
| FFmpeg occasional encode | NVENC 9th gen (AV1/HEVC/H.264) |
| GDS (NVMe→GPU direct) | nvidia-fs + cuFile API |

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

### Linux — AV1 (AMD VA-API, R9700 VCN 5.0)

Same `av1_vaapi` encoder, different render device. VCN 5.0 adds AV1
B-frame support (`-bf 4`) for better compression.

```bash
ffmpeg -vaapi_device /dev/dri/renderD129 \
  -i input.mov \
  -vf 'format=p010le,hwupload' \
  -c:v av1_vaapi -rc_mode VBR \
  -b:v 15M -maxrate 17M -bufsize 30M \
  -g 240 -bf 4 -tiles 2x2 -tile_groups 2 \
  -c:a copy output.mp4
```

### Linux — AV1 NVENC (if RTX PRO 2000 installed)

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
