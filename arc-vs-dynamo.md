# Arc vs Dynamo — Architecture Comparison

Both serve LLMs using TensorRT-LLM + NIXL/GDS on NVIDIA GPUs.
Same inference engine, same GPU kernels, same memory tiering.
The difference is everything around the GPU.

---

## Stack Comparison

```
Dynamo                              Arc
──────────────────────              ──────────────────────
Client                              Client
  │                                   │
  ▼                                   ▼
Axum (Rust, HTTP/TCP)               QUIC/H3 (platform-transport-quic)
  │                                   │
  ▼                                   │ (same process)
NATS (Go, message broker)             │
  │                                   │
  ▼                                   │
etcd (Go, service discovery)          │
  │                                   │
  ▼                                   ▼
Python worker process               Inference worker (in-process, FFI)
  │                                   │
  ▼                                   ▼
TensorRT-LLM (C++ FFI)             TensorRT-LLM (C++ FFI)
NIXL/GDS                            NIXL/GDS
```

| | Dynamo | Arc |
|---|---|---|
| Language | Rust + Python + Go (NATS, etcd) | Rust only |
| Processes | 4 (frontend, NATS, etcd, worker) | 1 |
| HTTP server | Axum (TCP) | platform QUIC/H3 (io_uring) |
| RPC | NATS pub/sub + ZeroMQ | ORPC (QUIC-native, 8-byte header) |
| Service discovery | etcd (Go) | direct ORPC broadcast |
| Async runtime | Tokio | io_uring (platform runtime) |
| Token streaming | SSE over TCP | ORPC frames on QUIC stream |
| Multi-node coordination | NATS messages + etcd lookups | direct ORPC peer mesh |
| KV transfer | NIXL RDMA | NIXL RDMA (same) |
| Inference engine | TensorRT-LLM | TensorRT-LLM (same) |
| GDS model loading | NIXL | NIXL (same) |
| Garbage collection | Yes (Go in NATS/etcd) | No (Rust, deterministic) |
| Memory overhead | ~500 MB+ | ~20 MB |

---

## What's Identical

These components are the same in both architectures. No performance
difference regardless of stack choice:

| Component | Shared |
|---|---|
| GPU inference | TensorRT-LLM, same CUDA kernels |
| FP4 compute | Blackwell NVFP4, same precision |
| Model loading | NIXL GPUDirect Storage, same DMA path |
| KV cache tiering | VRAM → RAM → SSD, same block management |
| KV RDMA transfer | NIXL RDMA, same wire protocol |
| Token generation speed | GPU-bound, identical tok/s |

**GPU time is 95%+ of wall-clock for typical requests.** The
comparison below focuses on the remaining 5% — the overhead that the
serving stack adds around GPU compute.

---

## Request Path Latency

### Ingress (client → inference start)

```
Dynamo:
  TCP accept → Axum HTTP parse → JSON deserialize
  → NATS publish → NATS route → worker subscribe → pick up
  ≈ 200–500 µs

Arc:
  QUIC accept → ORPC frame parse (8 bytes)
  → direct in-process dispatch
  ≈ 50–100 µs

Saved: ~150–400 µs per request
```

### Token streaming (per token, back to client)

```
Dynamo:
  Worker → NATS publish → frontend subscribe
  → SSE frame → TCP write
  ≈ 50–100 µs per token

Arc:
  Worker → ORPC frame → same QUIC stream
  ≈ 5–10 µs per token

Saved: ~45–90 µs per token
```

### Prefill → decode handoff (multi-node)

```
Dynamo:
  Prefill worker → NATS "prefill complete"
  → Router reads NATS → etcd lookup for decode worker
  → NATS publish to decode worker → worker picks up
  → NIXL RDMA begins
  Coordination: ~1–2 ms before RDMA starts

Arc:
  Prefill → ORPC call directly to decode peer
  → NIXL RDMA begins
  Coordination: ~50–100 µs before RDMA starts

Saved: ~1–2 ms (10–20x faster coordination)
RDMA transfer time is identical after coordination.
```

### Service discovery / model availability

```
Dynamo:
  Worker → etcd write "model loaded"
  → etcd watch propagation → router updates
  ≈ 1–5 ms

Arc:
  Worker → ORPC ModelAdvertise → peers update
  ≈ 50 µs

Saved: ~1–5 ms
```

---

## End-to-End Impact by Workload

### Short completions (coding autocomplete, 30 tokens)

```
                        Dynamo          Arc
Ingress:                300 µs          75 µs
Prefill (GPU):        50,000 µs      50,000 µs    ← same
Decode (GPU, 30 tok): 375,000 µs     375,000 µs    ← same
Streaming overhead:     2,250 µs        240 µs
                      ─────────       ─────────
Total:               427,550 µs     425,315 µs

Overhead:              2,550 µs        315 µs
Overhead reduction:                     8x
End-to-end:                            ~0.5% faster
```

GPU dominates. Overhead difference is real but small in absolute terms.

### Long responses (1000+ tokens)

```
                        Dynamo          Arc
Streaming overhead:    75,000 µs       8,000 µs
GPU decode time:   12,500,000 µs  12,500,000 µs    ← same

67 ms saved out of 12.5 seconds.
End-to-end: ~0.5% faster
```

Negligible for single requests.

### High concurrency (where it matters)

| Concurrent requests | Dynamo P99 TTFT | Arc P99 TTFT | Improvement |
|---|---|---|---|
| 1 | ~52 ms | ~50 ms | ~4% |
| 10 | ~58 ms | ~51 ms | ~12% |
| 50 | ~85 ms | ~53 ms | ~38% |
| 100 | ~150 ms+ | ~58 ms | ~60%+ |

Why the gap grows:

- **NATS** is a single broker — all messages funnel through one Go process.
  Under load, queue depth grows, GC pauses add jitter.
- **etcd** writes contend — service discovery updates compete with reads.
- **Cross-process IPC** adds context switches per request.
- **Arc** has none of these — direct dispatch, no broker, no GC, no IPC.

P99 is the metric that matters for user experience. The worst request
defines perceived quality.

---

## Multi-Node Handoff

Total time for prefill → decode transfer of 1 GB KV cache:

```
Dynamo:
  Coordination:  1,500 µs  (NATS + etcd)
  RDMA transfer: 5,000 µs  (NIXL, ~200 GB/s InfiniBand)
  Total:         6,500 µs

Arc:
  Coordination:     75 µs  (single ORPC call)
  RDMA transfer: 5,000 µs  (NIXL, same)
  Total:         5,075 µs

22% faster total handoff.
```

For smaller KV transfers (short prompts), coordination is a larger
fraction:

```
100 MB KV cache:
  Dynamo: 1,500 µs + 500 µs = 2,000 µs
  Arc:       75 µs + 500 µs =   575 µs

71% faster.
```

---

## Resource Overhead

### Memory

```
Dynamo:
  NATS server:     ~100 MB
  etcd:            ~200 MB
  Python worker:   ~200 MB+ (Python runtime + PyTorch)
  Axum frontend:    ~30 MB
  Total:           ~530 MB

Arc:
  Single binary:    ~20 MB
  Total:            ~20 MB

Saved: ~510 MB → available for KV cache
```

510 MB is ~13,000 additional KV cache blocks at 256 KB each. That's
approximately 25K extra tokens of context capacity that Dynamo wastes
on infrastructure.

### CPU

```
Dynamo:
  4 processes competing for cores
  Go GC in NATS + etcd (stop-the-world pauses)
  Python GIL in worker
  Cross-process context switches per request

Arc:
  1 process
  No GC (Rust)
  No GIL
  Zero IPC
```

On a system where GPU is the bottleneck, CPU overhead is less
important — but it matters when the CPU is also handling network I/O,
KV cache migration, and RDMA setup. Less CPU waste means more
headroom for memory management tasks.

---

## Operational Complexity

| Concern | Dynamo | Arc |
|---|---|---|
| Deployment | 4 binaries, coordinated startup | 1 binary |
| Monitoring | 4 process health checks | 1 health check |
| Debugging | distributed traces across processes | single-process logs |
| Failure modes | NATS down = all inference stops | no single point of failure beyond GPU |
| Configuration | NATS config + etcd config + worker config + frontend config | one TOML file |
| Upgrades | coordinate 4 component versions | one binary version |
| Log correlation | trace IDs across processes | single process, trivial |

### Failure analysis

```
Dynamo — NATS crashes:
  All inference stops. No requests reach workers.
  Frontend is alive, returns errors.
  etcd is alive, thinks workers are healthy.
  Split-brain between what etcd reports and what's actually working.

Arc — no equivalent failure mode:
  Process is up = inference works.
  Process is down = nothing works.
  Binary state. Simple to monitor, simple to recover.
```

---

## Where Dynamo Wins

| Advantage | Details |
|---|---|
| **Exists today** | Production-ready, battle-tested at NVIDIA |
| **Ecosystem** | Integrates with NVIDIA's full stack (Triton, NeMo, NIM) |
| **Python flexibility** | Easy to add custom pre/post-processing in Python |
| **Community** | Active development, issues, documentation |
| **Multi-GPU scheduling** | Planner component for SLA-driven autoscaling |

Arc is a spec. Dynamo is running in production. The engineering
effort to build Arc is months of work. Dynamo gives you KVBM + GDS
today.

---

## Recommendation

| Scenario | Use |
|---|---|
| Lab (1 GPU, get started now) | Dynamo — it works today |
| Lab (1 GPU, after Arc is built) | Arc unified mode |
| Production (multi-GPU, < 50 QPS) | Either — overhead difference is noise |
| Production (multi-GPU, > 50 QPS) | Arc — P99 advantage compounds |
| Production (latency-sensitive, coding agents) | Arc — deterministic, no GC jitter |

### Migration path

```
Phase 1: Dynamo on lab (today, when RTX 6000 arrives)
  → validates models, GDS, KV tiering
  → learn what works, what doesn't

Phase 2: Build Arc unified mode
  → replace Dynamo with single binary
  → same TensorRT-LLM engines, same /cache/models/
  → validate parity: same tok/s, same quality

Phase 3: Arc cluster mode
  → add prefill/decode split, peer mesh, RDMA handoff
  → deploy to multi-GPU production cluster
```

No need to choose upfront. Start with Dynamo, build Arc alongside,
switch when Arc matches Dynamo's functionality.
