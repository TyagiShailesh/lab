# LLM Inference — RTX 6000 Blackwell

Single RTX 6000 (96 GB VRAM) serving multiple LLMs on-demand with Dynamo + TensorRT-LLM.

---

## Architecture

```
Client (coding agent, API, etc.)
  │
  │  POST /v1/chat/completions
  │  {"model": "nemotron-3-super-120b", "messages": [...]}
  │
  ▼
┌─────────────────────────────────┐
│         Dynamo Frontend         │  HTTP API (lab:8000)
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│        Model Manager            │
│                                 │
│   model in VRAM? → run          │
│   model on SSD?  → load (3-4s) │
│                   → evict prev  │
│                   → run         │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│     TensorRT-LLM Worker        │
│     RTX 6000 (96 GB VRAM)      │
│                                 │
│   Model weights + KV cache     │
│              │                  │
│         KV overflow?            │
│              ▼                  │
│   ┌───────────────────────┐    │
│   │        KVBM           │    │
│   │  VRAM   ~36 GB  fast  │    │
│   │  RAM    128 GB  32GB/s│    │
│   │  SSD      4 TB  14GB/s│    │
│   └───────────────────────┘    │
└──────────────┬──────────────────┘
               │
               ▼
         Response stream
```

## Data Paths

```
/cache/models/ (9100 Pro, M.2_1, Gen5 x4)
      │
      │ GPUDirect Storage (14 GB/s)
      │ SSD → GPU VRAM, CPU bypassed
      │ Both on CPU PCIe lanes, no chipset hop
      ▼
┌──────────┐  PCIe 5.0 x16 (32 GB/s)  ┌───────────┐
│   CPU    │◄─────────────────────────►│ RTX 6000  │
│  RAM     │                           │ 96GB VRAM │
│  128 GB  │                           │           │
└──────────┘                           └───────────┘
```

GPUDirect Storage (GDS) loads model weights directly from NVMe to GPU VRAM — one DMA transfer, no CPU memory copy. NIXL (inside Dynamo) handles this automatically.

## Models

All pre-compiled as TensorRT-LLM engines, stored on `/cache/models/`:

| Model | Total | Active | FP4 Size | Load Time | Use |
|---|---|---|---|---|---|
| Nemotron 3 Super 120B | 120B | 12B | ~60 GB | ~4.3s | agentic reasoning, native FP4 trained |
| GPT-OSS 120B | 117B | 5.1B | ~58 GB | ~4.1s | general reasoning, coding, STEM |
| Qwen3-Coder-Next 80B | 80B | 3B | ~40 GB | ~2.9s | coding |
| Qwen 3.5 27B | 27B | 27B | ~14 GB | ~1.0s | general, fast |

On-demand loading: first request to a model pays 3-4s cold start. Subsequent requests are instant. Model evicted when another is requested.

One endpoint, model selection per request:

```json
{"model": "nemotron-3-super-120b", "messages": [...]}
{"model": "qwen3-coder-next", "messages": [...]}
```

## Why TensorRT-LLM (not vLLM)

- **Native FP4** on Blackwell — Nemotron 3 Super was trained in NVFP4
- **Compiled engines** — optimized CUDA kernels for RTX 6000, faster inference
- **GDS integration** via NIXL — direct SSD → GPU model loading
- **KVBM** — tiered KV cache across VRAM/RAM/SSD

Tradeoff: each model requires one-time engine compilation (minutes to hours). New models can't be loaded directly from HuggingFace — must be compiled first.

## KV Cache Budget

With a ~60 GB model loaded (largest), ~36 GB VRAM remains for KV cache:

| Tier | Capacity | Bandwidth | Latency |
|---|---|---|---|
| VRAM | ~36 GB | ~2,000 GB/s | nanoseconds |
| CPU RAM | 128 GB | ~32 GB/s | microseconds |
| SSD (9100 Pro) | 4 TB | ~14 GB/s (GDS) | tens of microseconds |

Multi-user KV cache sharing (with ~36 GB VRAM pool):

| Concurrent users | Context per user (FP8 KV) |
|---|---|
| 4 | ~150K tokens |
| 8 | ~75K tokens |
| 16 | ~37K tokens |

When VRAM KV cache is full, KVBM spills to RAM then SSD automatically. With 128 GB RAM + 4 TB SSD, hundreds of concurrent sessions are possible with graceful latency degradation.

## Key Components

| Component | Role |
|---|---|
| **Dynamo** | Orchestration, request routing, model lifecycle |
| **TensorRT-LLM** | Inference engine, FP4 compute on Blackwell |
| **KVBM** | KV cache management across VRAM/RAM/SSD |
| **NIXL** | Low-latency data transfer, GDS plugin |
| **GPUDirect Storage** | Direct SSD → GPU DMA, bypasses CPU |

## Setup (when RTX 6000 arrives)

```bash
# Install GDS
sudo apt install -y nvidia-gds

# Install Dynamo
pip install ai-dynamo

# Install TensorRT-LLM
pip install tensorrt-llm

# Compile model engines (one-time per model)
trtllm-build --model nemotron-3-super-120b \
  --dtype fp4 \
  --output /cache/models/nemotron-3-super-120b.engine

# Start serving
dynamo serve --backend tensorrt-llm \
  --model-dir /cache/models/ \
  --port 8000
```

Exact commands will depend on versions available at install time. Check official docs:
- [Dynamo](https://github.com/ai-dynamo/dynamo)
- [TensorRT-LLM](https://github.com/NVIDIA/TensorRT-LLM)
- [NVIDIA GDS](https://docs.nvidia.com/gpudirect-storage/)

## Model Notes

**Nemotron 3 Super 120B** — hybrid Mamba-2 + MoE + Attention. Native 1M context. Trained in NVFP4 from scratch (not post-quantized). Multi-Token Prediction for faster generation. Apache 2.0.

**GPT-OSS 120B** — OpenAI's open-weight model. 5.1B active (MoE). Fits single 80GB GPU. Near o4-mini reasoning quality. Apache 2.0.

**Qwen3-Coder-Next 80B** — 3B active. Outperforms 10x larger models on coding benchmarks. Hybrid DeltaNet + attention (low KV cache). Apache 2.0.

**Qwen 3.5 27B** — Dense (not MoE). Fast, good quality general model. Fits easily with room for large KV cache.
