# Arc — LLM Inference Engine

Origon platform service for GPU inference. Single binary, built on
platform crates, wrapping TensorRT-LLM and NIXL via FFI.

Arc owns model lifecycle, KV cache tiering, inference dispatch, and
cluster coordination (disaggregated prefill/decode, KV transfer).
It does not own transport, auth, observability, or process lifecycle —
those come from platform.

---

## Design Principles

- One binary, three roles: `unified` (lab), `prefill`, `decode`
- Zero external daemons (no NATS, no etcd, no Python)
- Platform crates for everything generic
- FFI boundary for GPU: TensorRT-LLM (inference) + NIXL (data movement)
- Local SSD for lab, noema for multi-node — same GDS path to GPU
- Long-lived sessions with KV cache preservation
- On-demand model loading, not resident multi-model
- gw stays dumb — routes by account lease + model availability, no KV awareness
- Arc peers coordinate directly via ORPC mesh

---

## Topology

### Lab (single GPU)

```
Clients
  │
  ▼
arc (role: unified)
  ├── H3 listener (external, OpenAI-compatible)
  ├── ORPC listener (internal)
  ├── TensorRT-LLM (FFI)
  ├── NIXL/GDS (FFI)
  └── local SSD (/cache/models)
```

One process. No gw needed. Arc serves clients directly.

### Production (multi-node)

```
Clients
  │
  ▼
gw (edge)
  │ routes by: account lease (session pinning)
  │            model availability (arc broadcasts)
  │ no KV awareness, no inference logic
  │
  ├── ORPC → arc-0 (role: prefill, GPU 0)
  ├── ORPC → arc-1 (role: prefill, GPU 1)
  ├── ORPC → arc-2 (role: decode, GPU 2)
  └── ORPC → arc-3 (role: decode, GPU 3)

Arc peer mesh (ORPC, direct node-to-node):
  arc-0 ◄──ORPC──► arc-2
  arc-0 ◄──ORPC──► arc-3
  arc-1 ◄──ORPC──► arc-2
  arc-1 ◄──ORPC──► arc-3
  │
  │ Prefill → Decode handoff:
  │   1. arc-0 processes prompt (compute-heavy)
  │   2. arc-0 transfers KV cache to arc-2 (NIXL RDMA)
  │   3. arc-2 generates tokens (memory-bound)
  │   4. arc-2 streams response → gw → client
  │
  └── ORPC → noema (engine storage, session state, RAG)
```

### Disaggregated Prefill/Decode

Prefill (processing the prompt) and decode (generating tokens) have
different GPU utilization profiles:

| Phase | Bottleneck | GPU Pattern |
|-------|-----------|-------------|
| Prefill | compute | high FLOPS, parallel across tokens |
| Decode | memory bandwidth | sequential, one token at a time |

Running them on separate GPU pools allows independent scaling and
hardware optimization:

- Prefill pool: fewer GPUs, high utilization
- Decode pool: more GPUs, each handling many concurrent sessions

In unified mode (lab), both phases run on the same GPU sequentially.

---

## Architecture

```
                        ┌──────────────────────────────────────┐
                        │             arc process               │
                        │                                       │
  H3 (external)  ──────▶  H3 handler ─┐                       │
  ORPC (internal) ──────▶  ORPC handler┤                       │
  ORPC (arc peers) ─────▶  peer handler┤                       │
                        │              ▼                       │
                        │   ┌─────────────────────┐            │
                        │   │   Request Router    │            │
                        │   │   (model dispatch)  │            │
                        │   └────────┬────────────┘            │
                        │            │                         │
                        │   ┌────────▼────────────┐            │
                        │   │  Session Manager    │            │
                        │   │  (KV cache tracking │            │
                        │   │   per conversation) │            │
                        │   └────────┬────────────┘            │
                        │            │                         │
                        │   ┌────────▼────────────┐            │
                        │   │  Model Manager      │            │
                        │   │  load / evict        │            │
                        │   │  engine discovery    │            │
                        │   └────────┬────────────┘            │
                        │            │                         │
                        │   ┌────────▼────────────┐            │
                        │   │  Inference Worker   │            │
                        │   │  prefill / decode   │            │
                        │   │  TensorRT-LLM (FFI) │            │
                        │   └────────┬────────────┘            │
                        │            │                         │
                        │   ┌────────▼────────────┐            │
                        │   │  Memory Manager     │            │
                        │   │  VRAM → RAM → SSD   │            │
                        │   │  NIXL/GDS (FFI)     │            │
                        │   └────────┬────────────┘            │
                        │            │                         │
                        │   ┌────────▼────────────┐            │
                        │   │  Cluster Manager    │  (multi-node only)
                        │   │  peer mesh          │            │
                        │   │  KV transfer        │            │
                        │   │  model broadcast    │            │
                        │   └─────────────────────┘            │
                        │                                       │
  SIGTERM/SIGHUP ──────▶  platform service-host                │
  GET /health    ◀──────  shared admin/control wiring           │
  GET /metrics   ◀──────                                       │
                        └──────────────────────────────────────┘
```

---

## Directory Layout

```
arc/
├── app/
│   ├── main.rs                 — binary entry point, config, runtime wiring
│   ├── arc_config.rs           — TOML config with hot-reload
│   └── shutdown.rs             — drain in-flight requests, flush KV cache
├── domain/
│   ├── model/
│   │   ├── manager.rs          — load, evict, discover engines
│   │   ├── registry.rs         — scan /cache/models/, watch for new engines
│   │   ├── source.rs           — ModelSource trait (local fs, noema)
│   │   └── engine.rs           — TensorRT-LLM engine handle, FP4 config
│   ├── session/
│   │   ├── manager.rs          — session lifecycle, idle timeout, eviction
│   │   ├── state.rs            — per-session KV cache location tracking
│   │   └── context.rs          — conversation history, token counting
│   ├── memory/
│   │   ├── manager.rs          — tiered allocator (VRAM → RAM → SSD)
│   │   ├── vram.rs             — GPU memory pool, block tracking
│   │   ├── host.rs             — CPU RAM pool
│   │   ├── disk.rs             — SSD pool, GDS read/write via NIXL
│   │   ├── rdma.rs             — cross-node KV transfer via NIXL RDMA
│   │   └── evictor.rs          — LRU eviction across tiers
│   ├── inference/
│   │   ├── worker.rs           — TensorRT-LLM FFI wrapper
│   │   ├── prefill.rs          — prompt processing phase
│   │   ├── decode.rs           — token generation phase
│   │   ├── tokenizer.rs        — tokenizer (per-model)
│   │   └── stream.rs           — token-by-token output iterator
│   └── cluster/
│       ├── role.rs             — Unified / Prefill / Decode
│       ├── mesh.rs             — peer discovery, ORPC connections
│       ├── handoff.rs          — prefill → decode KV handoff
│       ├── broadcast.rs        — model availability → gw
│       └── kv_transfer.rs      — NIXL RDMA block transfer between nodes
├── integrations/
│   ├── protocol/
│   │   ├── h3.rs               — OpenAI-compatible JSON API over H3
│   │   ├── orpc.rs             — ORPC method handlers
│   │   └── sse.rs              — SSE token streaming (H3)
│   ├── noema/
│   │   ├── engine_source.rs    — pull engines from noema (multi-node)
│   │   ├── session_store.rs    — persist conversation history
│   │   └── rag.rs              — knowledge graph + vector search queries
│   ├── gpu/
│   │   ├── trtllm.rs           — TensorRT-LLM C++ FFI bindings
│   │   ├── nixl.rs             — NIXL C FFI bindings (GDS + RDMA)
│   │   └── device.rs           — GPU device enumeration, VRAM capacity
│   └── quic/
│       └── server.rs           — platform QUIC transport wiring
├── control-plane/
│   └── observability/
│       ├── metrics.rs          — inference latency, TTFT, throughput, cache hit rate
│       └── readiness.rs        — ready when GPU initialized + at least one engine available
└── ffi/
    ├── trtllm_sys/             — raw C++ bindings (bindgen)
    │   ├── build.rs
    │   ├── wrapper.h
    │   └── lib.rs
    └── nixl_sys/               — raw C bindings (bindgen)
        ├── build.rs
        ├── wrapper.h
        └── lib.rs
```

---

## Thread Model

| Thread / Subsystem | Role |
|--------------------|------|
| platform QUIC driver | QUIC accept, connection I/O |
| arc request handlers | H3 + ORPC dispatch, request parsing |
| arc peer handlers | ORPC from other arc nodes (KV transfer, handoff) |
| inference worker | TensorRT-LLM forward pass (GPU-bound) |
| memory manager | async KV cache eviction, tier migration |
| engine watcher | inotify on /cache/models/, registers new engines |
| cluster heartbeat | periodic model broadcast to gw, peer health |
| shared signal waiters | SIGTERM/SIGHUP via platform service-host |
| shared admin/control | /health, /ready, /metrics |

---

## Roles

```toml
# Lab — single GPU, does everything
[arc]
role = "unified"

# Production — prefill node
[arc]
role = "prefill"
decode_peers = ["orpc://arc-2:8005", "orpc://arc-3:8005"]

# Production — decode node
[arc]
role = "decode"
prefill_peers = ["orpc://arc-0:8005", "orpc://arc-1:8005"]
```

| Role | Prefill | Decode | Direct client H3 | Peer ORPC |
|------|---------|--------|-------------------|-----------|
| `unified` | yes | yes | yes | no |
| `prefill` | yes | no | no (via gw) | yes |
| `decode` | no | yes | no (via gw) | yes |

In unified mode, the cluster module is compiled out (`#[cfg(feature = "cluster")]`).
Zero overhead for lab use.

---

## API Surface

### H3 — OpenAI-Compatible (external clients)

```
POST /v1/chat/completions
POST /v1/completions
GET  /v1/models
```

#### Chat Completion

```json
// Request
{
  "model": "nemotron-3-super-120b",
  "messages": [
    {"role": "system", "content": "You are a coding assistant."},
    {"role": "user", "content": "Write a Rust HTTP server."}
  ],
  "stream": true,
  "session_id": "uuid",
  "max_tokens": 4096,
  "temperature": 0.7
}

// Response (streamed, SSE)
data: {"choices": [{"delta": {"content": "```rust\n"}}]}
data: {"choices": [{"delta": {"content": "use std::net::TcpListener;"}}]}
...
data: [DONE]
```

`session_id` is an extension to the OpenAI spec. If provided, arc
preserves KV cache between requests in the same session. If omitted,
each request is independent.

#### List Models

```json
// GET /v1/models
{
  "data": [
    {"id": "nemotron-3-super-120b", "ready": false, "size_bytes": 64424509440},
    {"id": "qwen3-coder-next", "ready": true, "size_bytes": 42949672960}
  ]
}
```

`ready: true` means the engine is loaded in VRAM. `ready: false` means
it's on disk, cold start required.

### ORPC — Internal (gw → arc)

| Method ID | Name | Description |
|-----------|------|-------------|
| 0x01 | `Infer` | Chat completion (ORPC framing, token streaming) |
| 0x02 | `ListModels` | Available models and load status |
| 0x03 | `LoadModel` | Pre-load a model into VRAM |
| 0x04 | `EvictModel` | Unload a model from VRAM |
| 0x05 | `SessionStatus` | KV cache state for a session |
| 0x06 | `DropSession` | Evict session KV cache |

ORPC responses for `Infer` stream tokens as ORPC frames on the same
QUIC stream — no SSE needed, native backpressure.

### ORPC — Peer (arc ↔ arc, cluster feature only)

| Method ID | Name | Description |
|-----------|------|-------------|
| 0x10 | `PrefillComplete` | prefill node → decode node: KV ready |
| 0x11 | `TransferKv` | initiate NIXL RDMA block transfer |
| 0x12 | `TransferKvAck` | confirm blocks received |
| 0x13 | `ModelAdvertise` | broadcast loaded model to peers |
| 0x14 | `Heartbeat` | peer liveness |

---

## Prefill/Decode Handoff (cluster)

```
Client → gw → arc-0 (prefill)
                │
                │ 1. Tokenize prompt
                │ 2. TensorRT-LLM prefill pass (GPU, compute-heavy)
                │ 3. KV cache generated for all prompt tokens
                │
                │ ORPC: PrefillComplete → arc-2 (decode)
                │ NIXL: RDMA transfer KV blocks → arc-2 GPU/RAM
                │
                │ 4. arc-0 is free for next prefill request
                │
                └──► arc-2 (decode)
                       │
                       │ 5. Receives KV cache via RDMA
                       │ 6. TensorRT-LLM decode loop (memory-bound)
                       │ 7. Streams tokens → gw → client
                       │
                       │ 8. Session KV cache stays on arc-2
                       │    for follow-up requests
                       │    (gw pins via account lease)
```

Unified mode skips steps 3-5 — prefill and decode happen sequentially
on the same GPU.

---

## Model Manager

### Engine Discovery

On startup and on inotify event, scan `engine_dir` for directories
matching the pattern:

```
/cache/models/
├── nemotron-3-super-120b/
│   ├── engine.trt           — compiled TensorRT-LLM engine
│   ├── config.json          — model config (layers, heads, vocab, etc.)
│   └── tokenizer/           — tokenizer files
├── qwen3-coder-next/
│   └── ...
└── gpt-oss-120b/
    └── ...
```

Each directory with a valid `engine.trt` + `config.json` is registered
as an available model. Name derived from directory name.

### Model Lifecycle

```
                    ┌──────────┐
                    │  ON_DISK │  engine on SSD, not loaded
                    └────┬─────┘
                         │ load request (first inference or explicit)
                         ▼
                    ┌──────────┐
     GDS transfer   │ LOADING  │  SSD → VRAM via NIXL
     14 GB/s        └────┬─────┘
                         │ engine ready
                         ▼
                    ┌──────────┐
                    │  ACTIVE  │  serving inference requests
                    └────┬─────┘
                         │ another model requested (single-GPU)
                         │ or explicit evict
                         ▼
                    ┌──────────┐
                    │ EVICTING │  flush active sessions' KV to disk
                    └────┬─────┘
                         │ VRAM freed
                         ▼
                    ┌──────────┐
                    │  ON_DISK │
                    └──────────┘
```

### Model Source

```rust
trait ModelSource: Send + Sync {
    /// List available engines.
    fn list(&self) -> Vec<EngineInfo>;

    /// Path to engine file. Used by NIXL/GDS for DMA to GPU.
    fn engine_path(&self, model: &str) -> PathBuf;
}

/// Lab: raw files on local XFS.
struct LocalSource {
    dir: PathBuf,  // /cache/models
}

/// Production: pull from noema, cache locally.
struct NoemaSource {
    orpc_endpoint: QuicAddr,   // noema ORPC
    local_cache: PathBuf,      // /cache/models (local SSD)
}
```

`NoemaSource` checks local cache first. If engine is not present,
pulls from noema via ORPC, writes to local SSD, then loads via GDS.
Subsequent loads hit local cache (14 GB/s, no network).

---

## Session Manager

### Session State

```rust
struct Session {
    id: Uuid,
    model: String,
    created_at: Instant,
    last_active: Instant,
    token_count: u64,
    kv_cache: KvCacheHandle,
    conversation: Vec<Message>,
    node_id: NodeId,            // which arc node owns this session
}
```

### KV Cache Preservation

When a model is evicted but sessions exist:

1. Active sessions' KV cache blocks are flushed to SSD via NIXL
2. Session metadata (token count, conversation) persisted to noema
3. When the model is reloaded for that session, KV cache is restored
   from SSD via GDS — no recomputation

When a session is idle beyond `session_idle_timeout`:

1. KV cache evicted from VRAM (moved to RAM, then SSD if needed)
2. Session metadata stays in memory
3. Next request triggers KV cache recall from lower tier

### Session Eviction Order

LRU by `last_active`. Sessions with larger KV cache are preferred
for eviction to lower tiers (more VRAM freed per eviction).

---

## Memory Manager

### Tiers

```
┌─────────────────────────────────────────────────────┐
│ Tier 0: VRAM                                        │
│   Capacity: 96 GB total, ~36 GB after model weights │
│   Bandwidth: ~2,000 GB/s                            │
│   Managed by: TensorRT-LLM internal allocator       │
│   Eviction: LRU sessions → Tier 1                   │
├─────────────────────────────────────────────────────┤
│ Tier 1: CPU RAM                                     │
│   Capacity: configurable (default: 64 GB of 128 GB) │
│   Bandwidth: ~32 GB/s (PCIe 5.0 x16)               │
│   Managed by: arc host allocator (huge pages)       │
│   Eviction: LRU → Tier 2                            │
├─────────────────────────────────────────────────────┤
│ Tier 2: SSD                                         │
│   Capacity: configurable (default: 500 GB of 4 TB)  │
│   Bandwidth: ~14 GB/s (GDS, PCIe 5.0 x4)           │
│   Managed by: arc disk allocator                    │
│   Eviction: LRU → drop (session must recompute)    │
├─────────────────────────────────────────────────────┤
│ Tier 3: Remote (cluster only)                       │
│   Capacity: peer VRAM/RAM                            │
│   Bandwidth: RDMA via NIXL (network-dependent)      │
│   Used for: prefill → decode KV handoff             │
│   Not used for: general spill (too slow)            │
└─────────────────────────────────────────────────────┘
```

### Block Management

KV cache is divided into fixed-size blocks (e.g., 256 KB). Each block
tracks:

```rust
struct KvBlock {
    id: u64,
    session_id: Uuid,
    layer_range: Range<u32>,
    token_range: Range<u64>,
    tier: Tier,
    location: Location,        // local or remote NodeId
    last_accessed: Instant,
    size_bytes: u64,
}
```

Migration between tiers is async and non-blocking to inference.
NIXL handles all data movement:

- VRAM → RAM: CUDA memcpy (async)
- VRAM → SSD: GDS write (async, CPU bypassed)
- SSD → VRAM: GDS read (async, CPU bypassed)
- RAM → VRAM: CUDA memcpy (async)
- Node → Node: NIXL RDMA (async, cluster only)

---

## Cluster Manager (feature: cluster)

### Peer Mesh

On startup, each arc node connects to configured peers via ORPC.
No central registry — peers are listed in config.

```toml
[arc.cluster]
node_id = "arc-0"
peers = ["orpc://arc-1:8005", "orpc://arc-2:8005", "orpc://arc-3:8005"]
```

Connections are persistent QUIC sessions. Heartbeat every 5s.
Failed peer is marked unavailable — no requests routed to it.

### Model Broadcast

When a model is loaded or evicted, arc broadcasts `ModelAdvertise`
to all peers. gw learns model availability through its existing ORPC
connections to arc nodes (same `ListModels` method, polled or pushed).

### KV Transfer Protocol

Used for prefill → decode handoff:

```
arc-0 (prefill)                    arc-2 (decode)
  │                                  │
  │ ORPC: PrefillComplete            │
  │   session_id, block_ids,         │
  │   total_size                     │
  ├─────────────────────────────────►│
  │                                  │
  │ NIXL: RDMA write                 │
  │   KV blocks → arc-2 RAM         │
  │   (zero-copy, kernel bypass)     │
  ├──────────────────────────────────►
  │                                  │
  │                    ORPC: TransferKvAck
  │◄─────────────────────────────────┤
  │                                  │
  │ arc-0 frees local KV blocks      │ arc-2 loads to VRAM
  │ arc-0 ready for next prefill     │ arc-2 starts decode loop
```

### Why Not Route KV Through gw?

KV cache blocks are large (MBs to GBs). Routing through gw would:
- Add a network hop and copy
- Consume gw bandwidth meant for client traffic
- Add latency to the critical prefill→decode path

Direct arc-to-arc RDMA is the only path that makes sense.

---

## Noema Integration

### Conversation Persistence

After each response, arc sends the conversation turn to noema:

```
arc → ORPC → noema
  PutObject: /arc/sessions/{session_id}/turn_{n}.json
```

If arc restarts or a session is fully evicted, conversation history
is recovered from noema. Arc rebuilds KV cache by replaying the
conversation through the model (slower than cache recall, but correct).

### RAG Context

Before inference, arc can optionally query noema for relevant context:

```
arc → ORPC → noema
  GraphQuery: entities related to current prompt
  VectorSearch: similar code snippets / past conversations
```

Injected as system context before the user's message. Configurable
per-model:

```toml
[arc.models.nemotron-3-super-120b]
rag_enabled = true
rag_max_tokens = 2048
rag_sources = ["graph", "vector"]
```

### Engine Distribution (multi-node)

```
GPU node joins cluster
  → checks local /cache/models/
  → missing engine?
  → pulls from noema via ORPC (QUIC, not HTTP)
  → writes to local SSD
  → subsequent loads are local (14 GB/s GDS)
```

---

## Configuration

```toml
[arc]
role = "unified"              # unified | prefill | decode
engine_dir = "/cache/models"
session_idle_timeout = "10m"
max_concurrent_sessions = 64

[arc.gpu]
device_id = 0

[arc.memory]
vram_kv_budget = "36G"
host_kv_budget = "64G"
disk_kv_budget = "500G"
block_size = "256K"
huge_pages = true

[arc.h3]
listen = "[::]:8000"
max_concurrent_streams = 256

[arc.orpc]
listen = "[::]:8005"

[arc.cluster]                   # only when role != unified
node_id = "arc-0"
peers = []
heartbeat_interval = "5s"
kv_transfer_timeout = "10s"

[arc.noema]
endpoint = "orpc://localhost:9005"
rag_enabled = true
persist_sessions = true

# Model-specific overrides
[arc.models.nemotron-3-super-120b]
priority = 1
max_context = 1048576
rag_enabled = true

[arc.models.qwen3-coder-next]
priority = 2
max_context = 131072
rag_enabled = false
```

---

## Observability

### Metrics (Prometheus, via platform observe)

| Metric | Type | Description |
|--------|------|-------------|
| `arc_inference_total` | counter | total inference requests |
| `arc_ttft_seconds` | histogram | time to first token |
| `arc_tps` | gauge | tokens per second (current) |
| `arc_prefill_seconds` | histogram | prefill phase duration |
| `arc_decode_tps` | gauge | decode tokens per second |
| `arc_model_load_seconds` | histogram | engine load time from SSD |
| `arc_vram_used_bytes` | gauge | VRAM usage (weights + KV) |
| `arc_host_kv_bytes` | gauge | KV cache in CPU RAM |
| `arc_disk_kv_bytes` | gauge | KV cache on SSD |
| `arc_kv_tier_migrations` | counter | block migrations between tiers |
| `arc_kv_rdma_transfers` | counter | cross-node KV transfers (cluster) |
| `arc_kv_rdma_bytes` | counter | bytes transferred via RDMA |
| `arc_active_sessions` | gauge | sessions with KV cache in VRAM |
| `arc_warm_sessions` | gauge | sessions with KV cache in RAM/SSD |
| `arc_model_active` | gauge (labeled) | which model is loaded |
| `arc_gds_read_bytes` | counter | bytes read via GPUDirect Storage |
| `arc_gds_write_bytes` | counter | bytes written via GPUDirect Storage |
| `arc_peer_connected` | gauge (labeled) | peer mesh connectivity |
| `arc_handoff_total` | counter | prefill→decode handoffs (cluster) |
| `arc_handoff_seconds` | histogram | handoff latency (cluster) |

### Structured Logging (via platform observe)

```
level=info role=unified model=nemotron-3-super-120b event=load_start source=local
level=info role=unified model=nemotron-3-super-120b event=load_complete duration_ms=4200
level=info session=abc123 event=infer_start tokens_in=1024
level=info session=abc123 event=infer_complete tokens_out=512 ttft_ms=45 tps=87.3
level=warn event=kv_evict session=def456 tier=vram->ram blocks=128
level=info role=prefill session=ghi789 event=handoff_start target=arc-2 kv_size_mb=1240
level=info role=decode session=ghi789 event=handoff_received from=arc-0 kv_size_mb=1240
```

---

## Shutdown Sequence

1. Stop accepting new connections (platform service-host)
2. In cluster mode: broadcast shutdown to peers, stop accepting handoffs
3. Drain in-flight inference requests (finish current token generation)
4. Flush active session KV cache to SSD via NIXL
5. Persist session metadata to noema
6. Unload TensorRT-LLM engine
7. Release GPU resources
8. Exit

---

## Build

```bash
# Lab mode (no cluster, no noema)
cargo build --release --bin arc

# With noema integration
cargo build --release --bin arc --features noema

# Full production (cluster + noema)
cargo build --release --bin arc --features cluster,noema
```

Feature flags:

| Feature | Enables |
|---------|---------|
| `cluster` | peer mesh, prefill/decode roles, KV RDMA transfer |
| `noema` | engine pull, session persistence, RAG |
| (default) | unified mode, local SSD, H3 + ORPC |

---

## Dependencies

### Platform Crates

| Crate | Use |
|-------|-----|
| `runtime` | io_uring event loop |
| `observe` | metrics, tracing, OTel |
| `config` | TOML config, hot-reload |
| `crypto` | BLAKE3 (session ID hashing), HMAC |
| `auth` | JWT/Macaroon validation (if direct client access) |
| `health` | readiness probes |
| `admin` | /health, /ready, /metrics endpoints |
| `service-host` | process lifecycle, signal handling |
| `platform-transport-quic` | QUIC/H3 server |
| `platform-transport-http` | HTTP request/response contract |
| `platform-orpc` | ORPC framing |
| `platform-orpc-transport-quic` | ORPC over QUIC |
| `platform-orpc-runtime-server` | ORPC accept/drain loop |
| `platform-codec` | zstd compression |

### External (FFI only)

| Library | Use |
|---------|-----|
| `tensorrt-llm` | GPU inference (C++ FFI) |
| `nixl` | GDS + RDMA data movement (C FFI) |
| `cuda` | GPU device management |

No Python. No NATS. No etcd. No Tokio.
