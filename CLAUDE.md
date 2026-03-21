# Project Rules

## Server: lab (192.168.1.10)

- **Always install from official upstream repositories**, not Ubuntu/apt defaults. Ubuntu packages are often months or years behind. Find the project's official repo (e.g., PGDG for PostgreSQL, Intel repos for OpenVINO, NVIDIA repos for drivers) and install from there.
- SSH access: `ssh 192.168.1.10` (root)
- bcachefs pool mounted at `/store`
- Samba shares: media, st, data, tm
- Docs: rtx.md (Resolve), upgrade.md (hardware), llm.md (LLM inference)
