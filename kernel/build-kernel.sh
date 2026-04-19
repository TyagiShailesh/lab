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

# Ensure cargo is in PATH (rustup installs to ~/.cargo/bin)
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# For CONFIG_RUST=y (required by bcachefs in future kernels): host toolchain needs
# rustc + rust-src + bindgen-cli + libclang-dev. Kconfig's RUST_IS_AVAILABLE
# auto-detects; if any piece is missing, CONFIG_RUST silently stays off.
#   rustup default stable && rustup component add rust-src
#   cargo install --locked bindgen-cli
#   apt install -y libclang-dev

# Directory layout: src/ = downloaded sources, build/ = build tree + staging
mkdir -p src build/kernel build/staging/boot build/staging/usr images

build=build/kernel
staging=build/staging

# --- Download sources (skip if already present) ---
if [ ! -f "$build/Makefile" ]; then
  echo "=== Downloading kernel source ==="
  wget --no-check-certificate -O- "$src" | tar -xJf - -C "$build" --strip-components=1
fi

if [ ! -d "src/bcachefs-tools" ]; then
  echo "=== Cloning bcachefs-tools ==="
  git clone --depth 1 --branch "$bcachefs_tag" "$bcachefs_repo" src/bcachefs-tools
fi

if [ ! -d "src/nvidia-open" ]; then
  echo "=== Cloning NVIDIA open kernel modules ==="
  git clone --depth 1 --branch "$nvidia_tag" "$nvidia_repo" src/nvidia-open
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
  --disable CMDLINE_BOOL \
  --enable RUST
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
[ "$fail" -eq 1 ] && { echo "FATAL: verification failed"; exit 1; }

# --- Create tarball ---
tar -C "$staging" -I 'zstd --threads=0' -Scf "images/$pkg.tar.zst" .
du -sh "images/$pkg.tar.zst" && echo "Build complete. Output is images/$pkg.tar.zst"
