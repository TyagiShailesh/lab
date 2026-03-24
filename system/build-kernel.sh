#!/usr/bin/env bash
# Always update to latest stable kernel and bcachefs-tools before building.
# Kernel: https://www.kernel.org/ (latest stable)
# bcachefs: https://github.com/koverstreet/bcachefs-tools/tags (latest tag)
set -euo pipefail

src=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.19.9.tar.xz
pkg=$(basename "$src" .tar.xz)
kver=${pkg#linux-}

# bcachefs out-of-tree module + tools (pinned tag — must match)
bcachefs_repo=https://github.com/koverstreet/bcachefs-tools.git
bcachefs_tag=v1.37.3

build=$(mktemp -d); trap 'rm -rf "$build"' EXIT
staging="$build/staging"

# --- Kernel build ---
wget --no-check-certificate -O- "$src" | tar -xJf - -C "$build" --strip-components=1

cp config "$build/.config"

make -C "$build" ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- olddefconfig
# Enable visible Kconfig options that select hidden symbols needed by bcachefs OOT module:
# CRYPTO_LZ4 -> LZ4_COMPRESS, LZ4_DECOMPRESS; CRYPTO_LZ4HC -> LZ4HC_COMPRESS, LZ4_DECOMPRESS
# BLK_DEV_INTEGRITY -> CRC64
"$build"/scripts/config --file "$build/.config" \
  --enable CRYPTO_LZ4 --enable CRYPTO_LZ4HC --enable BLK_DEV_INTEGRITY \
  --enable TCP_CONG_ADVANCED --enable TCP_CONG_BBR --enable NET_SCH_FQ
make -C "$build" ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- olddefconfig

make -C "$build" ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- -j"$(nproc)" bzImage modules
make -C "$build" ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- INSTALL_MOD_PATH="$staging"/usr modules_install

mkdir -p "$staging/boot" "$staging/usr"

cp "$build"/arch/x86_64/boot/bzImage "$staging"/boot/$pkg
make -C "$build" ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- INSTALL_HDR_PATH="$staging"/usr headers_install

# --- bcachefs out-of-tree module ---
bcachefs_dir="$build/bcachefs-tools"
git clone --depth 1 --branch "$bcachefs_tag" "$bcachefs_repo" "$bcachefs_dir"

# Prepare DKMS source tree
make -C "$bcachefs_dir" install_dkms DESTDIR="$build/dkms-staging" PREFIX=/usr
dkms_src=$(echo "$build/dkms-staging/usr/src/bcachefs-"*)

# Build the module against our kernel
make -C "$build" ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- -j"$(nproc)" \
  M="$dkms_src" modules

# Install bcachefs.ko into staging
mod_dest="$staging/usr/lib/modules/$kver/kernel/fs/bcachefs"
mkdir -p "$mod_dest"
cp "$dkms_src"/src/fs/bcachefs/bcachefs.ko "$mod_dest"/

# --- bcachefs userspace tools ---
make -C "$bcachefs_dir" -j"$(nproc)" bcachefs
mkdir -p "$staging/usr/local/sbin"
cp "$bcachefs_dir/bcachefs" "$staging/usr/local/sbin/bcachefs"

# --- thunderbolt_net out-of-tree module (performance-patched) ---
tbnet_src="$(cd "$(dirname "$0")" && pwd)/thunderbolt_net"
if [ -d "$tbnet_src" ]; then
  make -C "$build" ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- -j"$(nproc)" \
    M="$tbnet_src" modules
  tbnet_dest="$staging/usr/lib/modules/$kver/kernel/drivers/net/thunderbolt"
  mkdir -p "$tbnet_dest"
  cp "$tbnet_src"/thunderbolt_net.ko "$tbnet_dest"/
fi

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
[ -f "$staging/usr/lib/modules/$kver/kernel/drivers/net/thunderbolt/thunderbolt_net.ko" ] && echo "OK: thunderbolt_net.ko" || { echo "FAIL: thunderbolt_net.ko missing"; fail=1; }
[ "$fail" -eq 1 ] && { echo "FATAL: verification failed"; exit 1; }

# --- Create tarball ---
mkdir -p images
tar -C "$staging" -I 'zstd --threads=0' -Scf "images/$pkg.tar.zst" .
du -sh "images/$pkg.tar.zst" && echo "Build complete. Output is images/$pkg.tar.zst"
