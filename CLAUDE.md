# Project Rules

## Server: lab (192.168.1.10)

- **Always install from official upstream repositories**, not Ubuntu/apt defaults. Ubuntu packages are often months or years behind. Find the project's official repo (e.g., PGDG for PostgreSQL, Intel repos for OpenVINO, NVIDIA repos for drivers) and install from there.
- SSH access: `ssh 192.168.1.10` (root)
- bcachefs pool mounted at `/store`
- Samba shares: media, st, data, tm
- Docs: system/ (kernel build + config), hardware.md, storage.md, gpu.md, resolve.md, upgrade-plan.md

## Arqic + Khor Specs (at /data/code/ws/docs/)

- **arqic-specs.md** — Arqic inference fabric (arqic-router + arqic-engine)
- **khor-cache-specs.md** — Khor Cache RDMA KV cache tier
- **arqic-khor-references.md** — Technical references (Dynamo, NIXL, TRT-LLM, STX/CMX)
- **Always consult arqic-khor-references.md** before implementing features that interact with external APIs
- gw lives at `/data/code/ws/gw`. Arqic treats gw as an external platform component.
