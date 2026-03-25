# GPU

No discrete GPU installed yet.

## Current: Intel integrated (Arrow Lake UHD)

- VA-API hardware encode via `/dev/dri/renderD128`
- OpenVINO 2026.0.0 installed

## Planned: AMD Radeon AI PRO R9700

Primary discrete GPU. ASRock Creator variant (blower, 4× DP 2.1a, vapor
chamber, multi-GPU airflow cutouts).

- Architecture: RDNA 4 (Navi 48), 4nm
- VRAM: 32 GB GDDR6 (ECC), 256-bit, 640 GB/s
- Compute: 48 TFLOPS FP32, 191 TFLOPS FP16 matrix, 1531 INT4 sparse TOPS
- Media: dual VCN 5.0 (2× AV1/HEVC/H.264 encode/decode, AV1 B-frame support)
- TDP: 300W, 1× 16-pin 12V-2x6
- PCIe: Gen5 x16
- Price: $1,299

### Driver stack

Already present on this machine:
- Kernel 6.19.9 — amdgpu + VCN 5.0 support merged in mainline
- Mesa 25.2.8 — VA-API encode/decode, RADV Vulkan Video for VCN 5.0

ROCm install (for ML inference):
```bash
# ROCm 6.4.1+ required. Follow AMD's official repo:
# https://rocm.docs.amd.com/projects/install-on-linux/en/latest/
apt install rocm
# Verify:
rocminfo
clinfo
```

Kernel parameters (add to GRUB):
```
iommu=pt amd_iommu=on amdgpu.runpm=0
```

### Use cases

| Workload | Stack |
|---|---|
| ML inference (speech-engine) | Burn (CubeCL → ROCm) |
| LLM inference (arqic) | vLLM (ROCm) |
| FFmpeg transcode | VA-API via Mesa (`/dev/dri/renderD129`) |
| DaVinci Resolve | OpenCL via ROCm (not officially supported on Linux — test needed) |

### Optional: RTX PRO 2000 Blackwell (Resolve fallback)

If Resolve does not work reliably on AMD/Linux, add an RTX PRO 2000
Blackwell ($730, 70W, slot-powered, no power cable) as a dedicated
Resolve card. 16 GB GDDR7, CUDA, 1× NVENC 9th gen.

```bash
apt install -y linux-headers-$(uname -r) dkms
apt install -y nvidia-driver-570
reboot
nvidia-smi  # verify: RTX PRO 2000, 16GB VRAM
```

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
