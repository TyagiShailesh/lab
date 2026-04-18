# GPU

NVIDIA RTX PRO 2000 Blackwell + Intel Arrow Lake iGPU. Encode recipes and AI upscaling: [media.md](media.md).

---

## Slot layout

| Slot | Card | Mode | Bandwidth |
|---|---|---|---|
| PCIEX16_1 (CPU) | (empty) | PCIe 5.0 x8 | — |
| PCIEX16_2 (CPU) | NVIDIA RTX PRO 2000 Blackwell | PCIe 5.0 x8 | 16 GB/s (card is natively x8) |

x8 is not a practical limit — inference and rendering are compute-bound, not PCIe-bound. SSD model loading is bottlenecked by the Samsung 9100 Pro (~14 GB/s peak), well under the 16 GB/s x8 link.

---

## Intel integrated (Arrow Lake UHD)

- VA-API hardware encode via `/dev/dri/renderD128`
- OpenVINO 2026.0.0 installed
- Used for AV1/HEVC VA-API encode — see [media.md](media.md).

---

## NVIDIA RTX PRO 2000 Blackwell

Primary CUDA + NVENC card. 70 W, slot-powered, no PCIe power cable.

- Architecture: Blackwell (GB206), 5 nm
- CUDA cores: 4,352 / Tensor cores: 136 (Gen 5)
- VRAM: 16 GB GDDR7 (ECC), 128-bit, 288 GB/s
- Media: 1× NVENC 9th gen, 1× NVDEC 6th gen
- TDP: 70 W (slot-powered)
- PCIe: Gen5 x8 (native)

### Driver install

Install from NVIDIA's official CUDA repo (not Ubuntu's apt defaults):

```bash
# Latest CUDA repo setup: https://developer.nvidia.com/cuda-downloads
# Select: Linux → x86_64 → Ubuntu → 24.04 → deb (network)
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb
apt update
apt install -y cuda
# Verify:
nvidia-smi
nvcc --version
```

Kernel modules are built pre-compiled into the kernel tarball (open-gpu-kernel-modules pinned in [kernel/build-kernel.sh](kernel/build-kernel.sh)). Target must have `nvidia-dkms-open` removed — keep only userspace libs from `cuda` metapackage.

### GPUDirect Storage (GDS)

GPUDirect Storage via the cuFile API. Runs in **compat mode** — ACS on PCIe bridges (`00:01.0`, `00:06.0`) blocks native P2P DMA between NVMe and GPU, so data stages through CPU memory. Still faster than raw `read()` + `cudaMemcpy()` because cuFile optimizes the staging path.

Kernel module (`nvidia-fs.ko`) is pre-built in [kernel/build-kernel.sh](kernel/build-kernel.sh) (patched for kernel 6.18+ API). Kernel config enables `PCI_P2PDMA`, `ZONE_DEVICE`, `MEMORY_HOTPLUG`, `MEMORY_HOTREMOVE`, `DMABUF_MOVE_NOTIFY`. Embedded cmdline: `iommu=pt nvme.poll_queues=4`.

```bash
# Install GDS userspace (on target)
apt install nvidia-gds

# Load module
modprobe nvidia-fs

# Verify P2P support
/usr/local/cuda/gds/tools/gdscheck -p
```

| | |
|---|---|
| Kernel module | `nvidia-fs.ko` v2.28.2 ([NVIDIA/gds-nvidia-fs](https://github.com/NVIDIA/gds-nvidia-fs)) |
| Driver | 595.58.03 (open kernel modules) |
| CUDA | 13.2 |
| NVMe | Samsung 9100 Pro, M.2_1 Gen5 CPU-direct, IOMMU group 15 |
| GPU | RTX PRO 2000, PCIEX16_2 Gen5 CPU-direct, IOMMU group 16 |

### Use cases

| Workload | Stack |
|---|---|
| LLM inference | ollama (CUDA), vLLM (CUDA Docker) |
| Speech engines | Candle / CUDA |
| FFmpeg encode | NVENC 9th gen (AV1/HEVC/H.264) — see [media.md](media.md) |
| AI upscaling / denoising | VapourSynth + vs-mlrt (TensorRT) — see [media.md](media.md) |
| GPUDirect Storage | nvidia-fs + cuFile API |
