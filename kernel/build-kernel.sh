#!/usr/bin/env bash
# Always update to latest stable kernel and bcachefs-tools before building.
# Kernel: https://www.kernel.org/ (latest stable)
# bcachefs: https://github.com/koverstreet/bcachefs-tools/tags (latest tag)
set -euo pipefail

cd "$(dirname "$0")"

src=https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.0.tar.xz
pkg=$(basename "$src" .tar.xz)
# kver is set later from the actual kernel KERNELRELEASE (see below).
# Don't use the tarball-name fallback — for a "linux-7.0" source,
# KERNELRELEASE is "7.0.0" (SUBLEVEL=0, EXTRAVERSION=""), so OOT modules
# must go in /usr/lib/modules/7.0.0/ to match stock `modules_install`.

# bcachefs out-of-tree module + tools (pinned tag — must match)
bcachefs_repo=https://github.com/koverstreet/bcachefs-tools.git
bcachefs_tag=v1.37.5

# NVIDIA open kernel modules (pinned version — must match userspace libs on target)
# https://github.com/NVIDIA/open-gpu-kernel-modules/tags
nvidia_repo=https://github.com/NVIDIA/open-gpu-kernel-modules.git
nvidia_tag=595.58.03

# NVIDIA GPUDirect Storage kernel module
# https://github.com/NVIDIA/gds-nvidia-fs/tags
nvidia_fs_repo=https://github.com/NVIDIA/gds-nvidia-fs.git
nvidia_fs_tag=v2.28.2

# Ensure cargo is in PATH (rustup installs to ~/.cargo/bin)
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# Directory layout: src/ = downloaded sources, build/ = build tree + staging
mkdir -p src build/kernel build/staging/boot build/staging/usr images

build=build/kernel
staging=build/staging

# --- Download sources (skip if already present) ---
if [ ! -f "$build/Makefile" ]; then
  echo "=== Downloading kernel source ==="
  wget --no-check-certificate -O- "$src" | tar -xJf - -C "$build" --strip-components=1

  # Apply out-of-tree patches. Kept inside the extract block so repeated
  # build-kernel.sh runs don't double-apply.
  for p in patches/*.patch; do
    [ -f "$p" ] || continue
    echo "=== Applying $p ==="
    patch -d "$build" -p1 < "$p"
  done
fi

if [ ! -d "src/bcachefs-tools" ]; then
  echo "=== Cloning bcachefs-tools ==="
  git clone --depth 1 --branch "$bcachefs_tag" "$bcachefs_repo" src/bcachefs-tools
fi

if [ ! -d "src/nvidia-open" ]; then
  echo "=== Cloning NVIDIA open kernel modules ==="
  git clone --depth 1 --branch "$nvidia_tag" "$nvidia_repo" src/nvidia-open
fi

if [ ! -d "src/nvidia-fs" ]; then
  echo "=== Cloning NVIDIA GDS (nvidia-fs) ==="
  git clone --depth 1 --branch "$nvidia_fs_tag" "$nvidia_fs_repo" src/nvidia-fs
fi

# --- Kernel build ---
cp config "$build/.config"

make -C "$build" ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- olddefconfig
# Enable visible Kconfig options that select hidden symbols needed by bcachefs OOT module:
# CRYPTO_LZ4 -> LZ4_COMPRESS, LZ4_DECOMPRESS; CRYPTO_LZ4HC -> LZ4HC_COMPRESS, LZ4_DECOMPRESS
# BLK_DEV_INTEGRITY -> CRC64
"$build"/scripts/config --file "$build/.config" \
  --enable CRYPTO_LZ4 --enable CRYPTO_LZ4HC --enable BLK_DEV_INTEGRITY \
  --enable TCP_CONG_ADVANCED --enable TCP_CONG_BBR --enable NET_SCH_FQ \
  --disable DRM_AMDGPU \
  --set-val HZ 1000 --enable HZ_1000 \
  --enable NO_HZ_FULL \
  --enable PREEMPT_DYNAMIC \
  --enable CC_OPTIMIZE_FOR_PERFORMANCE \
  --enable TRANSPARENT_HUGEPAGE \
  --set-val IOMMU_DEFAULT_DMA_LAZY y \
  --enable PERF_EVENTS_AMD_UNCORE \
  --enable CMDLINE_BOOL \
  --set-str CMDLINE "iommu=pt nvme.poll_queues=4" \
  --disable CMDLINE_OVERRIDE \
  --enable MEMORY_HOTPLUG --enable MEMORY_HOTREMOVE --enable ZONE_DEVICE \
  --enable PCI_P2PDMA \
  --enable DMABUF_MOVE_NOTIFY
make -C "$build" ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- olddefconfig

make -C "$build" ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- -j"$(nproc)" bzImage modules
make -C "$build" ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- INSTALL_MOD_PATH="$(pwd)/$staging"/usr modules_install

# Derive kver from the directory `modules_install` just created.
# This is the authoritative KERNELRELEASE — OOT modules below MUST land here.
kver=$(basename "$(ls -d "$staging"/usr/lib/modules/*/ | head -1)")
echo "=== kver=$kver ==="

cp "$build"/arch/x86_64/boot/bzImage "$staging"/boot/$pkg
make -C "$build" ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- INSTALL_HDR_PATH="$(pwd)/$staging"/usr headers_install

# --- Kernel build dir for OOT module builds on target (Module.symvers + config + scripts) ---
kbuild="$staging/usr/src/linux-$kver"
mkdir -p "$kbuild"
cp "$build"/Module.symvers "$build"/.config "$build"/Makefile "$kbuild"/
cp -a "$build"/scripts "$kbuild"/
cp -a "$build"/include "$kbuild"/
cp -a "$build"/arch/x86/include "$kbuild"/arch/x86/include 2>/dev/null || true
mkdir -p "$kbuild"/arch/x86
cp "$build"/arch/x86/Makefile "$kbuild"/arch/x86/ 2>/dev/null || true

# --- bcachefs out-of-tree module ---
make -C src/bcachefs-tools install_dkms DESTDIR="$(pwd)/build/dkms-staging" PREFIX=/usr
dkms_src=$(echo build/dkms-staging/usr/src/bcachefs-*)

# Build the module against our kernel
make -C "$build" ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- -j"$(nproc)" \
  M="$(pwd)/$dkms_src" modules

# Install bcachefs.ko into staging
mod_dest="$staging/usr/lib/modules/$kver/kernel/fs/bcachefs"
mkdir -p "$mod_dest"
cp "$dkms_src"/src/fs/bcachefs/bcachefs.ko "$mod_dest"/

# --- bcachefs userspace tools ---
make -C src/bcachefs-tools -j"$(nproc)" bcachefs
mkdir -p "$staging/usr/local/sbin"
cp src/bcachefs-tools/bcachefs "$staging/usr/local/sbin/bcachefs"

# --- NVIDIA open kernel modules ---
# Patch nvidia-open for kernel 7.0: scripts/pahole-flags.sh was replaced by
# scripts/gen-btf.sh, so the Makefile's wildcard test wrongly injects an awk
# PAHOLE wrapper that gen-btf.sh mangles. Extend the test to match either.
# Upstream: NVIDIA/open-gpu-kernel-modules#1041
sed -i 's|$(wildcard $(KERNEL_SOURCES)/scripts/pahole-flags.sh)|$(or $(wildcard $(KERNEL_SOURCES)/scripts/pahole-flags.sh),$(wildcard $(KERNEL_SOURCES)/scripts/gen-btf.sh))|' \
  src/nvidia-open/kernel-open/Makefile
make -C src/nvidia-open KERNEL_UNAME="$kver" SYSSRC="$(pwd)/$build" SYSOUT="$(pwd)/$build" \
  -j"$(nproc)" modules

nvidia_dest="$staging/usr/lib/modules/$kver/kernel/drivers/video"
mkdir -p "$nvidia_dest"
for mod in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem; do
  cp "src/nvidia-open/kernel-open/$mod.ko" "$nvidia_dest"/
done

# --- NVIDIA GPUDirect Storage (nvidia-fs) kernel module ---
# nvidia-fs needs nv-p2p.h from NVIDIA source + nvidia_p2p_* symbols from built modules
nvidia_p2p_dir="$(pwd)/src/nvidia-open/kernel-open/nvidia"
# Build nv.symvers from the just-built nvidia.ko
grep "nvidia_p2p_" src/nvidia-open/kernel-open/Module.symvers > src/nvidia-fs/src/nv.symvers
# Patch nvidia-fs for kernel 6.18+ API changes:
#   1. __vm_flags removed — read via vma->vm_flags (it's a read-only access)
#   2. blk_dma_iter.iter is now blk_map_iter, not req_iterator (function sigs + usage)
#   3. page->flags is memdesc_flags_t{.f} not unsigned long — use .f for %lx format
sed -i 's/ACCESS_PRIVATE(vma, __vm_flags)/vma->vm_flags/' src/nvidia-fs/src/nvfs-mmap.c
sed -i 's/struct req_iterator/struct blk_map_iter/g' src/nvidia-fs/src/nvfs-dma.c
sed -i 's/->flags)/->flags.f)/g; s/\->flags$/->flags.f/' src/nvidia-fs/src/nvfs-mmap.c
make -C src/nvidia-fs/src KDIR="$(pwd)/$build" NVIDIA_SRC_DIR="$nvidia_p2p_dir" -j"$(nproc)" module
cp src/nvidia-fs/src/nvidia-fs.ko "$nvidia_dest"/

# NVIDIA GSP firmware ships with the userspace driver package (apt install cuda).
# Already at /lib/firmware/nvidia/<version>/gsp_*.bin on target — not in open-gpu-kernel-modules repo.

# --- Finalize modules ---
find "$staging"/usr/lib/modules -name "build" -type l -delete
find "$staging"/usr/lib/modules -name "source" -type l -delete

depmod -b "$staging/usr" "$kver"

# --- Verification ---
echo "=== Tarball contents verification ==="
fail=0
[ -f "$staging/boot/$pkg" ] && echo "OK: /boot/$pkg" || { echo "FAIL: /boot/$pkg missing"; fail=1; }
[ -f "$mod_dest/bcachefs.ko" ] && echo "OK: bcachefs.ko" || { echo "FAIL: bcachefs.ko missing"; fail=1; }
[ -f "$staging/usr/lib/modules/$kver/modules.dep" ] && echo "OK: modules.dep" || { echo "FAIL: modules.dep missing"; fail=1; }
[ -f "$staging/usr/local/sbin/bcachefs" ] && echo "OK: /usr/local/sbin/bcachefs" || { echo "FAIL: bcachefs tools missing"; fail=1; }
grep -q bcachefs "$staging/usr/lib/modules/$kver/modules.dep" && echo "OK: bcachefs in modules.dep" || { echo "FAIL: bcachefs not in modules.dep"; fail=1; }
[ -f "$nvidia_dest/nvidia.ko" ] && echo "OK: nvidia.ko" || { echo "FAIL: nvidia.ko missing"; fail=1; }
[ -f "$nvidia_dest/nvidia-drm.ko" ] && echo "OK: nvidia-drm.ko" || { echo "FAIL: nvidia-drm.ko missing"; fail=1; }
[ -f "$nvidia_dest/nvidia-fs.ko" ] && echo "OK: nvidia-fs.ko (GDS)" || { echo "FAIL: nvidia-fs.ko missing"; fail=1; }
[ "$fail" -eq 1 ] && { echo "FATAL: verification failed"; exit 1; }

# --- Create tarball ---
tar -C "$staging" -I 'zstd --threads=0' -Scf "images/$pkg.tar.zst" .
du -sh "images/$pkg.tar.zst" && echo "Build complete. Output is images/$pkg.tar.zst"
