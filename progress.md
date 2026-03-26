# Progress

Current state and next steps for the lab server build-out.

---

## Hardware installed (2026-03-26)

| Component | Slot | Status |
|---|---|---|
| AMD Radeon AI PRO R9700 (32 GB) | PCIEX16_1 (CPU, x8 split) | **Working** — amdgpu loaded, ROCm 7.2.1, PyTorch ROCm 2.11, vLLM, Burn |
| NVIDIA RTX PRO 2000 Blackwell (16 GB) | PCIEX16_2 (CPU, x8 split) | **Working** — Driver 595.58.03, CUDA 13.2, vLLM, ollama |
| Samsung 9100 Pro 1TB | M.2_1 (Gen5, CPU) | **Working** — XFS, /cache, ~9.5 GB/s read |

## Benchmarks (2026-03-26)

### FFmpeg AV1 encode (4K60 HEVC 10-bit → AV1, 30 Mbps target)

| GPU | Encoder | FPS | Speed | Notes |
|---|---|---|---|---|
| NVIDIA RTX PRO 2000 | NVENC (custom FFmpeg) | 154 | 2.57x | Fastest single-stream |
| AMD R9700 | VA-API (Mesa) | 130 | 2.16x | VCN 5.0 HW, decode-limited |
| Intel iGPU | VA-API (Intel media) | 130 | 2.16x | Matches AMD |
| AMD R9700 | AMF (Vulkan/RADV) | 55 | 0.92x | Falls back to compute shaders, not VCN |

AMD VA-API decode engine at 100% is the bottleneck — encoder is idle waiting for frames.
AMF on Linux/RADV doesn't use VCN hardware encoder, falls back to shader compute.
Navi 48 has 1 VCN 5.0 engine (not 2 as some specs claimed).

### LLM inference (Mistral 7B)

| GPU | Engine | Model format | tok/s | Notes |
|---|---|---|---|---|
| NVIDIA RTX PRO 2000 | ollama (CUDA) | Q4_K_M GGUF | 62 | Best on NVIDIA — llama.cpp is lean |
| AMD R9700 | vLLM (ROCm, built from source) | FP16 | 35 | No FlashAttention for gfx1201, ROCM_ATTN fallback |
| NVIDIA RTX PRO 2000 | vLLM (CUDA Docker) | AWQ Q4 | 6.4 | Memory-starved on 16 GB |
| AMD R9700 | ollama (CPU fallback) | Q4_K_M GGUF | 15.5 | Ollama doesn't support RDNA 4 ROCm |

vLLM ROCm Docker images only support MI300X (gfx942). Built vLLM from source
with `VLLM_TARGET_DEVICE=rocm PYTORCH_ROCM_ARCH=gfx1201`. Required patching
`vllm/platforms/__init__.py` to disable CUDA plugin when ROCm PyTorch detected.

### Burn + CubeCL matmul (FP32, synchronized)

| Size | Time/iter | GFLOPS | % of 48 TFLOPS |
|---|---|---|---|
| 1024x1024 | 0.6 ms | 3,347 | 7% |
| 2048x2048 | 2.7 ms | 6,361 | 13% |
| 4096x4096 | 15.7 ms | 8,744 | 18% |

**Burn → CubeCL → HIP → R9700 works.** Required patching `cubecl-hip-sys`
to add ROCm 7.2 (HIP 53211) bindings — copied from 52802 (backwards compatible).
CubeCL generates its own matmul kernel, not rocBLAS — 18% of peak is expected
for a generic kernel. rocBLAS would get 35-40 TFLOPS. FP16 would be 4x faster.

## RDNA 4 Linux ecosystem status (2026-03-26)

| Tool | RDNA 4 support | Notes |
|---|---|---|
| amdgpu kernel driver | Yes | Mainline since 6.14 |
| Mesa VA-API | Yes | VCN 5.0 encode/decode |
| Mesa RADV Vulkan | Yes | Full Vulkan Video |
| ROCm 7.2.1 | Yes | gfx1201 supported |
| PyTorch ROCm | Yes | torch 2.11+rocm7.1 |
| vLLM Docker | No | MI300X only, gfx1201 KeyError |
| vLLM from source | Yes (patched) | Dual-platform conflict fix needed |
| ollama ROCm | No | Only CUDA backend detected |
| Burn/CubeCL | Yes (patched) | cubecl-hip-sys needs ROCm 7.2 bindings |
| AMF (proprietary) | Partial | Runtime works but uses compute shaders, not VCN |
| FlashAttention ROCm | No | Not available for gfx1201 |

## Driver stack

| Stack | Version | Location |
|---|---|---|
| CUDA toolkit | 13.2 | /usr/local/cuda |
| ROCm | 7.2.1 | /opt/rocm-7.2.1 |
| Mesa | 25.2.8 | system (VA-API, Vulkan) |
| PyTorch ROCm | 2.11.0+rocm7.1 | pip (system) |
| vLLM ROCm | 0.1.dev (from source) | pip (system) |
| AMF runtime | 25.20 | /opt/amf |
| FFmpeg (custom) | latest git | /usr/local/bin (VA-API + NVENC + AMF) |

## Boot config

| Item | Detail |
|---|---|
| EFI boot | PARTUUID-based, no device path dependency |
| bcachefs | by-id mount, stable across NVMe reordering |
| i915 | Blacklisted (Resolve needed NVIDIA as sole display GPU) |
| fstab | UUID/by-id only |

## Completed (2026-03-26)

- [x] Both GPUs working — nvidia-smi + rocminfo
- [x] All mounts stable (PARTUUID, by-id, UUID)
- [x] FFmpeg AV1 encode tested on all 3 GPUs
- [x] vLLM ROCm built from source, running on R9700 (35 tok/s Mistral 7B)
- [x] Burn + CubeCL + ROCm compiled and running on R9700 (8.7 TFLOPS matmul)
- [x] DaVinci Resolve removed (rendering stays on Mac)
- [x] Custom FFmpeg with VA-API + NVENC + AMF built

## Next TODO

- [ ] Burn port: add rocBLAS dispatch for matmul (3x perf gain)
- [ ] Burn port: test FP16 matmul (4x perf gain)
- [ ] Begin speech-engine Burn port (Whisper first)
- [ ] Run speech-engine on RTX PRO 2000 (Candle/CUDA) to verify baseline
- [ ] Upstream cubecl-hip-sys ROCm 7.2 bindings patch to tracel-ai/cubecl
- [ ] Upstream vLLM dual-platform fix
