# Project Rules

## Server: lab (192.168.1.10)

- **Always install from official upstream repositories**, not Ubuntu/apt defaults. Ubuntu packages are often months or years behind. Find the project's official repo (e.g., PGDG for PostgreSQL, Intel repos for OpenVINO, NVIDIA repos for drivers) and install from there.
- SSH access: `ssh 192.168.1.10` (root)
- bcachefs pool mounted at `/nas`
- Samba shares: media, st, data, iris, tm
- Docs: [README.md](README.md) has the full index. Key files: [bcachefs.md](bcachefs.md) (pool architecture + mount + module), [hardware.md](hardware.md), [network.md](network.md), [storage.md](storage.md), [postgres.md](postgres.md), [gpu.md](gpu.md), [media.md](media.md), [thunderbolt.md](thunderbolt.md) + [thunderbolt-upstream.md](thunderbolt-upstream.md), [post-install.md](post-install.md), [migrate-bcachefs.md](migrate-bcachefs.md). Kernel build pipeline: [kernel/](kernel/). Runnable tools: [scripts/](scripts/).

## Arqic + Khor Specs (at /data/code/ws/docs/)

- **arqic-specs.md** — Arqic inference fabric (arqic-router + arqic-engine)
- **khor-cache-specs.md** — Khor Cache RDMA KV cache tier
- **arqic-khor-references.md** — Technical references (Dynamo, NIXL, TRT-LLM, STX/CMX)
- **Always consult arqic-khor-references.md** before implementing features that interact with external APIs
- gw lives at `/data/code/ws/gw`. Arqic treats gw as an external platform component.
