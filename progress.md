# Progress

Current state and next steps for the lab server build-out.

---

## Hardware installed (2026-03-26)

| Component | Slot | Status |
|---|---|---|
| AMD Radeon AI PRO R9700 (32 GB) | PCIEX16_1 (CPU, x8 split) | **Working** — amdgpu loaded, renderD129, ROCm 7.2.1 |
| NVIDIA RTX PRO 2000 Blackwell (16 GB) | PCIEX16_2 (CPU, x8 split) | **Working** — nvidia-smi OK, Driver 595.58.03, CUDA 13.2, renderD130 |
| Samsung 9100 Pro 1TB | M.2_1 (Gen5, CPU) | **Working** — XFS, /cache, ~9.5 GB/s read |

## Current kernel: 6.19.10

- amdgpu=m — working, firmware loads from .bin.zst (FW_LOADER_COMPRESS_ZSTD=y)
- NVIDIA open kernel modules — building now (from open-gpu-kernel-modules tag 595.58.03)
- bcachefs OOT module — working
- thunderbolt_net — using in-tree driver (OOT module removed)

## NVIDIA driver status

Previous attempts to get NVIDIA working:
1. `apt install cuda` installed CUDA 13.2 toolkit + nvidia-dkms-open 595.58.03
2. DKMS failed: kernel 6.19.10 removed `del_timer_sync` (renamed to `timer_delete_sync`), DKMS conftest couldn't find it without Module.symvers
3. Built Module.symvers manually, DKMS compiled but `module_layout` CRC mismatch — DKMS built against downloaded kernel source, not the actual running kernel built by build-kernel.sh
4. Solution: build-kernel.sh now builds NVIDIA open kernel modules directly from source alongside the kernel, using the same build tree. No DKMS on target.

**Next:** kernel build running now. After it completes:
1. `./install-kernel.sh images/linux-6.19.10.tar.zst` — installs kernel + all modules + NVIDIA firmware
2. Remove nvidia-dkms-open package (keep only userspace libs from cuda metapackage)
3. Reboot
4. Verify: `nvidia-smi`, `rocminfo`, both GPUs in `/dev/dri/`

## Driver stack installed

| Stack | Version | Location |
|---|---|---|
| CUDA toolkit | 13.2 | /usr/local/cuda |
| ROCm | 7.2.1 | /opt/rocm-7.2.1 |
| Mesa | 25.2.8 | system (VA-API, Vulkan) |
| amdgpu firmware | upstream linux-firmware | /lib/firmware/amdgpu/ |

## Boot fixes applied

| Issue | Fix |
|---|---|
| NVMe device reordering on new drive insert | EFI boot entries use `root=PARTUUID=204dd2f7-...` instead of `/dev/nvme0n1p2` |
| bcachefs mount failure after NVMe shuffle | Service uses `/dev/disk/by-id/nvme-WD_BLACK_SN850X_HS_2000GB_24364L800813` instead of `/dev/nvme1n1` |
| fstab pointing to old device path | Fixed — only EFI partition by UUID |
| install-kernel.sh wrong disk | Auto-discovers boot disk by PARTUUID, no argument needed |

## Samsung 9100 Pro performance

Platform-limited by Arrow Lake root port MaxPayload 256B (device supports 512B).

| Test | Speed | Notes |
|---|---|---|
| Sequential read (fio, QD64, 1M, 8 threads) | 9.5 GB/s | Rated 14.7 GB/s — capped by 256B MPS |
| Sequential write (fio, QD64, 1M, 8 threads) | 10.6 GB/s | Close to rated 13.0 GB/s |
| PCIe link | Gen5 x4, 32 GT/s | Full speed negotiated |

## Storage layout

| Mount | Device | Filesystem | Purpose |
|---|---|---|---|
| `/` | Samsung 990 Pro 2TB (PARTUUID) | XFS | Root |
| `/boot/efi` | Samsung 990 Pro 2TB p1 (UUID) | vfat | EFI |
| `/store` | WD SN850X + 2x Seagate Exos (by-id) | bcachefs | Media, data |
| `/cache` | Samsung 9100 Pro 1TB (by-id) | XFS | Models, Resolve cache, vLLM |

## Strategic direction

Shifting from NVIDIA-only to dual-vendor AMD+NVIDIA:
- **R9700**: primary GPU for ML inference (Burn/ROCm), LLM serving (vLLM/ROCm), FFmpeg transcode (VA-API VCN 5.0)
- **RTX PRO 2000**: DaVinci Resolve (CUDA, officially supported), speech-engine on Candle/CUDA until Burn port
- **speech-engine**: porting from Candle to Burn (CubeCL) — see `/root/code/ws/speech-engine/docs/burn-port.md`
- **arqic**: adding AMD backend behind existing traits — see `/root/code/ws/arqic/docs/amd-backend.md`
- Lab (R9700) → DC (MI300X/MI350X) — same ROCm stack

## Completed (2026-03-26)

- [x] nvidia-smi works — RTX PRO 2000, Driver 595.58.03, CUDA 13.2
- [x] rocminfo shows R9700 (gfx1201)
- [x] renderD128 (R9700), renderD129 (RTX PRO 2000) — i915 blacklisted
- [x] Zero failed systemd services (removed TB tune/rps services)
- [x] All mounts stable (PARTUUID, by-id, UUID)
- [x] DaVinci Resolve Studio 20 running on NVIDIA CUDA via Xorg+x11vnc on :2 (port 5902)
- [x] Resolve sees both RTX PRO 2000 (CUDA) and R9700 (OpenCL) — CUDA primary

## Next TODO

- [ ] Test FFmpeg AV1 encode on R9700 VA-API
- [ ] Test vLLM on R9700 with small model
- [ ] Run speech-engine on RTX PRO 2000 (Candle/CUDA) to verify baseline before Burn port
- [ ] Begin Burn port of speech-engine (Whisper first)
