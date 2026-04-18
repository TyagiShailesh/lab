# Media Pipeline

FFmpeg encode recipes and AI upscaling/denoising stack. Hardware context: [gpu.md](gpu.md) (NVIDIA RTX PRO 2000 Blackwell + Intel Arrow Lake iGPU). Runnable scripts in [scripts/](scripts/).

---

## FFmpeg — Linux

### AV1 (Intel VA-API)

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

### AV1 VBR (best quality per size)

```bash
ffmpeg -vaapi_device /dev/dri/renderD128 \
  -i input.mov \
  -vf 'format=p010le,hwupload' \
  -c:v av1_vaapi -rc_mode VBR \
  -b:v 15M -maxrate 17M -bufsize 30M \
  -g 240 -bf 4 -tiles 2x2 -tile_groups 2 \
  -c:a copy output.mp4
```

### AV1 NVENC (RTX PRO 2000)

```bash
ffmpeg -hwaccel cuda -i input.mov \
  -c:v av1_nvenc -preset p7 -tune hq -multipass fullres -cq 22 \
  -c:a copy output.mp4
```

### HEVC 10-bit (Apple compatible)

```bash
ffmpeg -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 \
  -i input.mov \
  -vf 'format=nv12,hwupload' \
  -c:v hevc_vaapi -tag:v hvc1 -b:v 20M \
  -c:a copy output.mp4
```

### HEVC VBR 10-bit

```bash
ffmpeg -vaapi_device /dev/dri/renderD128 \
  -i input.mov \
  -vf 'format=p010le,hwupload' \
  -c:v hevc_vaapi -tag:v hvc1 -rc_mode VBR \
  -b:v 20M -maxrate 25M -bufsize 40M \
  -g 120 -bf 4 \
  -c:a copy output.mp4
```

---

## FFmpeg — Mac

### HEVC (VideoToolbox)

```bash
ffmpeg -i input.mov \
  -c:v hevc_videotoolbox -q:v 50 -tag:v hvc1 \
  output.mp4
```

### HEVC 720p

```bash
ffmpeg -i input.mov \
  -vf scale=1280:720 \
  -c:v hevc_videotoolbox -q:v 25 -tag:v hvc1 \
  output.mp4
```

### Batch convert

```bash
mkdir -p converted && for f in *.MP4; do
  ffmpeg -i "$f" \
    -c:v hevc_videotoolbox -q:v 50 -tag:v hvc1 \
    -c:a aac -b:a 128k \
    "converted/${f%.MP4}.mp4"
done
```

### Audio (noise reduction)

```bash
ffmpeg -i input.WAV \
  -c:a aac -b:a 64k -ar 48000 -ac 2 \
  -af afftdn \
  output.m4a
```

---

## AV1 quality guide

| qp | Use |
|---|---|
| 18 | overkill, huge files |
| 20 | near-transparent, archiving |
| 22-24 | sweet spot for most content |
| 28 | good for sharing/web |

FFmpeg cannot decode Canon Cinema RAW Light (.CRM) directly.

---

## AI Upscaling & Denoising (RTX PRO 2000 Blackwell)

**VapourSynth + vs-mlrt (TensorRT)** — best quality at maximum speed.

### Components

- **VapourSynth** — frameserver, pipes to ffmpeg
- **vs-mlrt** ([github.com/AmusementClub/vs-mlrt](https://github.com/AmusementClub/vs-mlrt)) — runs ONNX/TensorRT models in VapourSynth
- **vs-realesrgan** ([github.com/HolyWu/vs-realesrgan](https://github.com/HolyWu/vs-realesrgan)) — Real-ESRGAN wrapper

### Models

| Task | Model | Quality | Speed (est 1080p→4K) |
|------|-------|---------|---------------------|
| Upscale | Real-ESRGAN x4plus | Best general | 5–10 fps (TRT) |
| Upscale anime | Real-CUGAN | Best for animation | 5–8 fps |
| Denoise | SCUNet | Best blind denoiser | 3–6 fps |
| Denoise (fast) | NAFNet | Good, 2× faster | 8–15 fps |

### Alternatives

- **Video2X** ([github.com/k4yt3x/video2x](https://github.com/k4yt3x/video2x)) — simpler CLI, wraps Real-ESRGAN
- **chaiNNer** ([github.com/chaiNNer-org/chaiNNer](https://github.com/chaiNNer-org/chaiNNer)) — node GUI, chain denoise+upscale, TensorRT

### Install plan

1. `pip install vapoursynth`
2. Install vs-mlrt with TensorRT backend
3. Convert Real-ESRGAN model to TensorRT FP16 engine for Blackwell
4. Pipeline: VapourSynth (upscale) → pipe → ffmpeg (AV1 encode on Intel or NVIDIA)

### Notes

- TensorRT gives 2–3× speedup over raw PyTorch on the same GPU.
- Blackwell FP8 tensor cores may give further gains if models support quantization.
- For combined denoise+upscale: run SCUNet first, then Real-ESRGAN.
- Avoid waifu2x — abandoned, superseded by Real-ESRGAN.
