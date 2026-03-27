# AI Video Upscaling & Denoising (NVIDIA RTX PRO 2000 Blackwell)

## Recommended Stack

**VapourSynth + vs-mlrt (TensorRT)** — best quality at maximum speed.

### Components
- **VapourSynth** — frameserver, pipes to ffmpeg
- **vs-mlrt** (github.com/AmusementClub/vs-mlrt) — runs ONNX/TensorRT models in VapourSynth
- **vs-realesrgan** (github.com/HolyWu/vs-realesrgan) — Real-ESRGAN wrapper for VapourSynth

### Models
| Task | Model | Quality | Speed (est 1080p→4K) |
|------|-------|---------|---------------------|
| Upscale | Real-ESRGAN x4plus | Best general | 5-10 fps (TRT) |
| Upscale anime | Real-CUGAN | Best for animation | 5-8 fps |
| Denoise | SCUNet | Best blind denoiser | 3-6 fps |
| Denoise (fast) | NAFNet | Good, 2x faster | 8-15 fps |

### Alternatives
- **Video2X** (github.com/k4yt3x/video2x) — simpler CLI, wraps Real-ESRGAN, good for quick jobs
- **chaiNNer** (github.com/chaiNNer-org/chaiNNer) — node GUI, chain denoise+upscale, TensorRT, hundreds of community models from OpenModelDB

### Install Plan
1. Install VapourSynth: `pip install vapoursynth`
2. Install vs-mlrt with TensorRT backend
3. Convert Real-ESRGAN model to TensorRT FP16 engine for Blackwell
4. Pipeline: VapourSynth (upscale) → pipe → ffmpeg (AV1 encode on Intel/NVIDIA)

### Notes
- TensorRT gives 2-3x speedup over raw PyTorch on same GPU
- Blackwell FP8 tensor cores may give further gains if models support quantization
- For combined denoise+upscale: run SCUNet first, then Real-ESRGAN
- Avoid waifu2x — abandoned, superseded by Real-ESRGAN in every metric
