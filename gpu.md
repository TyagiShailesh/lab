# GPU

No discrete GPU installed yet. RTX 6000 Blackwell is pending.

## Current: Intel integrated (Arrow Lake UHD)

- VA-API hardware encode via `/dev/dri/renderD128`
- OpenVINO 2026.0.0 installed

## Planned: RTX 6000 Blackwell

- Slot: PCIEX16_1 (Gen5 x16, CPU-direct)
- 96 GB VRAM
- CUDA, NVENC (AV1/HEVC), LLM inference

### NVIDIA driver install

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
