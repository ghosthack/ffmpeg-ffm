#!/bin/sh
# Build FFmpeg (LGPL, decode + curated remux, zero external deps) for linux-x64 and stage
# the .so files into natives/src/main/resources/natives/linux-x64/.
#
# Run on an x86-64 Linux machine (gcc, make, meson, ninja, nasm, patchelf):
#   build-natives/linux-x64.sh [path-to-ffmpeg-source]   (default build/ffmpeg-8.1.2)
#
# Fetch the source first if needed:
#   mkdir -p build/ffmpeg-8.1.2 && curl -sfL https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n8.1.2.tar.gz \
#     | tar xz --strip-components=1 -C build/ffmpeg-8.1.2
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/build/ffmpeg-8.1.2}"
PREFIX="$ROOT/build/prefix-linux-x64"
DEST="$ROOT/natives/src/main/resources/natives/linux-x64"
FFMPEG_VERSION="$(cat "$SRC/RELEASE")"

# dav1d (BSD-2) static, absorbed into libavcodec.so — see macos-arm64.sh.
DAV1D_VERSION=1.5.1
DAV1D_SRC="$ROOT/build/dav1d-$DAV1D_VERSION"
DAV1D_PREFIX="$ROOT/build/prefix-dav1d-linux-x64"
if [ ! -d "$DAV1D_SRC" ]; then
  curl -sfL "https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz" \
    | tar xJ -C "$ROOT/build"
fi
if [ ! -f "$DAV1D_PREFIX/lib/pkgconfig/dav1d.pc" ]; then
  meson setup "$DAV1D_SRC/build-linux-x64" "$DAV1D_SRC" \
    --prefix="$DAV1D_PREFIX" --libdir=lib --buildtype=release \
    -Ddefault_library=static -Denable_tools=false -Denable_tests=false
  ninja -C "$DAV1D_SRC/build-linux-x64" install
fi
export PKG_CONFIG_PATH="$DAV1D_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# libjxl (BSD-3) + its deps highway (Apache-2) and brotli (MIT), all static and
# PIC so libavcodec absorbs them — FFmpeg has a native JXL parser but decode is
# the external-libjxl wrapper codec. Same pattern as dav1d: no extra shipped
# library, no manifest change. skcms (BSD-3) is bundled into libjxl via deps.sh.
BROTLI_VERSION=1.1.0
HWY_VERSION=1.2.0
LIBJXL_VERSION=0.11.1
BROTLI_SRC="$ROOT/build/brotli-$BROTLI_VERSION"
HWY_SRC="$ROOT/build/highway-$HWY_VERSION"
LIBJXL_SRC="$ROOT/build/libjxl-$LIBJXL_VERSION"
BROTLI_PREFIX="$ROOT/build/prefix-brotli-linux-x64"
HWY_PREFIX="$ROOT/build/prefix-hwy-linux-x64"
LIBJXL_PREFIX="$ROOT/build/prefix-libjxl-linux-x64"

if [ ! -d "$BROTLI_SRC" ]; then
  curl -sfL "https://github.com/google/brotli/archive/refs/tags/v$BROTLI_VERSION.tar.gz" \
    | tar xz -C "$ROOT/build"
fi
if [ ! -f "$BROTLI_PREFIX/lib/pkgconfig/libbrotlidec.pc" ]; then
  cmake -S "$BROTLI_SRC" -B "$BROTLI_SRC/build-linux-x64" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBROTLI_DISABLE_TESTS=ON \
    -DCMAKE_INSTALL_PREFIX="$BROTLI_PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
  cmake --build "$BROTLI_SRC/build-linux-x64" -j"$(nproc)" --target install
fi

if [ ! -d "$HWY_SRC" ]; then
  curl -sfL "https://github.com/google/highway/archive/refs/tags/$HWY_VERSION.tar.gz" \
    | tar xz -C "$ROOT/build"
fi
if [ ! -f "$HWY_PREFIX/lib/pkgconfig/libhwy.pc" ]; then
  cmake -S "$HWY_SRC" -B "$HWY_SRC/build-linux-x64" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_TESTING=OFF \
    -DHWY_ENABLE_TESTS=OFF -DHWY_ENABLE_EXAMPLES=OFF -DHWY_ENABLE_CONTRIB=OFF \
    -DCMAKE_INSTALL_PREFIX="$HWY_PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
  cmake --build "$HWY_SRC/build-linux-x64" -j"$(nproc)" --target install
fi

if [ ! -d "$LIBJXL_SRC" ]; then
  curl -sfL "https://github.com/libjxl/libjxl/archive/refs/tags/v$LIBJXL_VERSION.tar.gz" \
    | tar xz -C "$ROOT/build"
  ( cd "$LIBJXL_SRC" && ./deps.sh )   # fetches pinned third_party (skcms et al.)
fi
export PKG_CONFIG_PATH="$BROTLI_PREFIX/lib/pkgconfig:$HWY_PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
if [ ! -f "$LIBJXL_PREFIX/lib/pkgconfig/libjxl.pc" ]; then
  cmake -S "$LIBJXL_SRC" -B "$LIBJXL_SRC/build-linux-x64" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_TESTING=OFF \
    -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF \
    -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF \
    -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SJPEG=OFF \
    -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_JPEGLI=OFF \
    -DJPEGXL_ENABLE_DEVTOOLS=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF \
    -DJPEGXL_ENABLE_FUZZERS=OFF \
    -DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_FORCE_SYSTEM_HWY=ON \
    -DCMAKE_INSTALL_PREFIX="$LIBJXL_PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
  cmake --build "$LIBJXL_SRC/build-linux-x64" -j"$(nproc)" --target install
fi
export PKG_CONFIG_PATH="$LIBJXL_PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
# The C++ runtime must not leak into the shipped .so as a dynamic dep: strip
# any -lstdc++ the .pc files advertise and link it statically via configure.
sed -i 's/-lstdc++//g' "$LIBJXL_PREFIX"/lib/pkgconfig/*.pc

# Same feature set as macos-arm64.sh, minus the Apple toolboxes. vaapi/vdpau
# explicitly off: they would add libva/libvdpau runtime deps, breaking the
# zero-external-deps guarantee (Linux hw decode is a future, deliberate step).
# --pkg-config-flags=--static: pull Libs.private so the static libjxl closure
# (hwy, brotli) resolves while FFmpeg itself stays shared.
CONFIGURE_FLAGS="--enable-shared --disable-static \
  --disable-programs --disable-doc --disable-debug \
  --disable-avdevice --disable-avfilter \
  --disable-encoders --disable-muxers \
  --enable-muxer=mov,mp4,ipod,tgp,tg2,matroska,webm,avi,ogg,image2,image2pipe,apng,gif,webp,mp3,flac,wav \
  --disable-network \
  --disable-xlib --disable-libxcb --disable-sdl2 \
  --disable-vaapi --disable-vdpau \
  --enable-libdav1d --enable-libjxl \
  --pkg-config-flags=--static"

cd "$SRC"
# -l:libstdc++.a + -static-libgcc: the C++ runtime libjxl needs links static —
# neither libstdc++.so.6 nor libgcc_s.so.1 may appear as a runtime dep.
./configure --prefix="$PREFIX" $CONFIGURE_FLAGS \
  --extra-libs='-l:libstdc++.a' --extra-ldflags='-static-libgcc'
make -j"$(nproc)"
make install

rm -rf "$DEST"
mkdir -p "$DEST"

# Dependency order matters: each lib must find the ones before it already loadable.
LIBS="libavutil libswresample libavcodec libavformat libswscale"
: > "$DEST/manifest.txt"
for lib in $LIBS; do
  so="$(readlink -f "$PREFIX/lib/$lib.so")"
  base="$(patchelf --print-soname "$so")"      # e.g. libavutil.so.60
  cp "$so" "$DEST/$base"
  chmod 644 "$DEST/$base"
  # $ORIGIN: inter-library references resolve relative to the directory the
  # referencing .so was extracted to — no ld.so.conf or LD_LIBRARY_PATH needed.
  patchelf --set-rpath '$ORIGIN' "$DEST/$base"
  echo "$base" >> "$DEST/manifest.txt"
done

# No dependency outside the staged set + base system may survive (zlib feeds
# the deflate decoders, PNG et al., and is Priority: required on Debian/Ubuntu
# — the macOS build likewise takes it from /usr/lib).
for f in "$DEST"/*.so.*; do
  if readelf -d "$f" | awk '/NEEDED/ {print $NF}' | tr -d '[]' \
      | grep -vE '^(libav|libsw)' \
      | grep -vE '^(libc|libm|libpthread|libdl|librt|libz)\.so|^ld-linux'; then
    echo "ERROR: $f has non-relocatable dependencies (above)"; exit 1
  fi
done

cp "$SRC/COPYING.LGPLv2.1" "$DEST/COPYING.LGPLv2.1"
cp "$DAV1D_SRC/COPYING" "$DEST/COPYING.dav1d"
cp "$LIBJXL_SRC/LICENSE" "$DEST/LICENSE.libjxl"
cp "$HWY_SRC/LICENSE" "$DEST/LICENSE.highway"
cp "$BROTLI_SRC/LICENSE" "$DEST/LICENSE.brotli"
cp "$LIBJXL_SRC/third_party/skcms/LICENSE" "$DEST/LICENSE.skcms"
{
  echo "FFmpeg $FFMPEG_VERSION (linux-x64), built from unmodified source"
  echo "Source: https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n$FFMPEG_VERSION.tar.gz"
  echo "License: LGPL v2.1+ (see COPYING.LGPLv2.1; no --enable-gpl/--enable-version3/--enable-nonfree)"
  echo "Statically linked: dav1d $DAV1D_VERSION (BSD-2-Clause, see COPYING.dav1d)"
  echo "  Source: https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz"
  echo "Statically linked: libjxl $LIBJXL_VERSION (BSD-3-Clause, see LICENSE.libjxl)"
  echo "  Source: https://github.com/libjxl/libjxl/archive/refs/tags/v$LIBJXL_VERSION.tar.gz"
  echo "  with highway $HWY_VERSION (Apache-2.0, see LICENSE.highway),"
  echo "  brotli $BROTLI_VERSION (MIT, see LICENSE.brotli), skcms (BSD-3-Clause, see LICENSE.skcms)"
  echo "configure: $CONFIGURE_FLAGS --extra-libs='-l:libstdc++.a' --extra-ldflags='-static-libgcc'"
} > "$DEST/BUILD-INFO.txt"

echo "Staged $(ls "$DEST" | wc -l | tr -d ' ') files into $DEST"
