#!/bin/bash
# Build Intel + NVIDIA + AMD media stack from source
# gmmlib → libva → intel-media-driver → nv-codec-headers → ffmpeg
# Then symlink VA-API drivers to libva's search path
set -euo pipefail

JOBS=$(nproc)
BUILD="/tmp/media-build"
PREFIX="/usr/local"
DRI_DST="$PREFIX/lib/x86_64-linux-gnu/dri"

export PATH="/usr/local/cuda/bin:$PATH"

rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

echo "=== gmmlib 22.9.0 ==="
git clone --depth 1 --branch intel-gmmlib-22.9.0 https://github.com/intel/gmmlib.git
cmake -S gmmlib -B gmmlib/build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
ninja -C gmmlib/build -j"$JOBS"
ninja -C gmmlib/build install
ldconfig

echo "=== libva 2.23.0 ==="
git clone --depth 1 --branch 2.23.0 https://github.com/intel/libva.git
meson setup libva/build libva \
  --prefix="$PREFIX" --buildtype=release \
  -Dwith_x11=yes -Dwith_wayland=yes -Dwith_glx=yes
ninja -C libva/build -j"$JOBS"
ninja -C libva/build install
ldconfig

echo "=== intel-media-driver 25.4.6 ==="
git clone --depth 1 --branch intel-media-25.4.6 https://github.com/intel/media-driver.git
cmake -S media-driver -B media-driver/build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DLIBVA_INSTALL_PATH="$PREFIX" \
  -DGMMLIB_INSTALL_PATH="$PREFIX" \
  -DENABLE_NONFREE_KERNELS=ON \
  -DENABLE_PRODUCTION_KMD=ON \
  -DMEDIA_BUILD_FATAL_WARNINGS=OFF
ninja -C media-driver/build -j"$JOBS"
ninja -C media-driver/build install
ldconfig

echo "=== nv-codec-headers 13.0.19.0 ==="
git clone --depth 1 --branch n13.0.19.0 https://github.com/FFmpeg/nv-codec-headers.git
make -C nv-codec-headers PREFIX="$PREFIX" install

echo "=== ffmpeg (latest git) ==="
git clone --depth 1 https://git.ffmpeg.org/ffmpeg.git
cd ffmpeg
./configure \
  --prefix="$PREFIX" \
  --enable-gpl \
  --enable-nonfree \
  --enable-libx264 \
  --enable-libx265 \
  --enable-libfdk-aac \
  --enable-libopus \
  --enable-libvpx \
  --enable-libdav1d \
  --enable-libsvtav1 \
  --enable-libaom \
  --enable-libass \
  --enable-libfreetype \
  --enable-vaapi \
  --enable-nvenc \
  --enable-cuda-nvcc \
  --enable-ffnvcodec \
  --enable-cuvid \
  --enable-amf \
  --extra-cflags="-I/usr/local/cuda/include -I$PREFIX/include" \
  --extra-ldflags="-L/usr/local/cuda/lib64 -L$PREFIX/lib"
make -j"$JOBS"
make install
ldconfig
cd /

echo "=== symlink VA-API drivers ==="
mkdir -p "$DRI_DST"
# Intel (built from source)
ln -sf "$PREFIX/lib/dri/iHD_drv_video.so" "$DRI_DST/iHD_drv_video.so"
# AMD (system Mesa)
ln -sf /usr/lib/x86_64-linux-gnu/dri/radeonsi_drv_video.so "$DRI_DST/radeonsi_drv_video.so"

echo "=== cleanup ==="
rm -rf "$BUILD"

echo ""
echo "BUILD COMPLETE"
ffmpeg -version | head -1
echo ""
echo "VA-API drivers:"
for dev in /dev/dri/renderD*; do
  echo "  $dev: $(vainfo --display drm --device "$dev" 2>&1 | grep 'Driver version' || echo 'no VA-API')"
done
