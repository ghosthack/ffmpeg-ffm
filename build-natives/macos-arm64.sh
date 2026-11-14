#!/bin/sh
# Build FFmpeg (LGPL, decode + curated remux, zero external deps) for macos-arm64 and stage
# the dylibs into natives/src/main/resources/natives/macos-arm64/.
#
# Usage: build-natives/macos-arm64.sh [path-to-ffmpeg-source]   (default build/ffmpeg-8.1.2)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/build/ffmpeg-8.1.2}"
PREFIX="$ROOT/build/prefix-macos-arm64"
DEST="$ROOT/natives/src/main/resources/natives/macos-arm64"
FFMPEG_VERSION="$(cat "$SRC/RELEASE")"

# Minimum macOS for every shipped binary, matching the published 0.3.7 dylibs
# (LC_BUILD_VERSION minos 14.0). Without it the floor is whatever the runner's
# Xcode defaults to, and a runner image change raises it silently. The env var
# reaches clang for meson (dav1d) and FFmpeg's configure, and seeds
# CMAKE_OSX_DEPLOYMENT_TARGET; the cmake builds also pass it explicitly. The
# gate after staging verifies the result, dependency archives included.
MACOS_MIN=14.0
export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"

# dav1d (BSD-2): FFmpeg has no native software AV1 decoder — its built-in
# `av1` codec is a hwaccel shim. Built static (meson) so libavcodec absorbs
# it: no extra shipped library, no manifest change, license stays LGPL v2.1+.
DAV1D_VERSION=1.5.1
DAV1D_SRC="$ROOT/build/dav1d-$DAV1D_VERSION"
DAV1D_PREFIX="$ROOT/build/prefix-dav1d-macos-arm64"
if [ ! -d "$DAV1D_SRC" ]; then
  curl -sfL "https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz" \
    | tar xJ -C "$ROOT/build"
fi
if [ ! -f "$DAV1D_PREFIX/lib/pkgconfig/dav1d.pc" ]; then
  meson setup "$DAV1D_SRC/build-macos-arm64" "$DAV1D_SRC" \
    --prefix="$DAV1D_PREFIX" --libdir=lib --buildtype=release \
    -Ddefault_library=static -Denable_tools=false -Denable_tests=false
  ninja -C "$DAV1D_SRC/build-macos-arm64" install
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
BROTLI_PREFIX="$ROOT/build/prefix-brotli-macos-arm64"
HWY_PREFIX="$ROOT/build/prefix-hwy-macos-arm64"
LIBJXL_PREFIX="$ROOT/build/prefix-libjxl-macos-arm64"

if [ ! -d "$BROTLI_SRC" ]; then
  curl -sfL "https://github.com/google/brotli/archive/refs/tags/v$BROTLI_VERSION.tar.gz" \
    | tar xz -C "$ROOT/build"
fi
if [ ! -f "$BROTLI_PREFIX/lib/pkgconfig/libbrotlidec.pc" ]; then
  cmake -S "$BROTLI_SRC" -B "$BROTLI_SRC/build-macos-arm64" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBROTLI_DISABLE_TESTS=ON \
    -DCMAKE_INSTALL_PREFIX="$BROTLI_PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
  cmake --build "$BROTLI_SRC/build-macos-arm64" -j"$(sysctl -n hw.ncpu)" --target install
fi

if [ ! -d "$HWY_SRC" ]; then
  curl -sfL "https://github.com/google/highway/archive/refs/tags/$HWY_VERSION.tar.gz" \
    | tar xz -C "$ROOT/build"
fi
if [ ! -f "$HWY_PREFIX/lib/pkgconfig/libhwy.pc" ]; then
  cmake -S "$HWY_SRC" -B "$HWY_SRC/build-macos-arm64" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_TESTING=OFF \
    -DHWY_ENABLE_TESTS=OFF -DHWY_ENABLE_EXAMPLES=OFF -DHWY_ENABLE_CONTRIB=OFF \
    -DCMAKE_INSTALL_PREFIX="$HWY_PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
  cmake --build "$HWY_SRC/build-macos-arm64" -j"$(sysctl -n hw.ncpu)" --target install
fi

if [ ! -d "$LIBJXL_SRC" ]; then
  curl -sfL "https://github.com/libjxl/libjxl/archive/refs/tags/v$LIBJXL_VERSION.tar.gz" \
    | tar xz -C "$ROOT/build"
  ( cd "$LIBJXL_SRC" && ./deps.sh )   # fetches pinned third_party (skcms et al.)
fi
export PKG_CONFIG_PATH="$BROTLI_PREFIX/lib/pkgconfig:$HWY_PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
if [ ! -f "$LIBJXL_PREFIX/lib/pkgconfig/libjxl.pc" ]; then
  cmake -S "$LIBJXL_SRC" -B "$LIBJXL_SRC/build-macos-arm64" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_TESTING=OFF \
    -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF \
    -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF \
    -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SJPEG=OFF \
    -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_JPEGLI=OFF \
    -DJPEGXL_ENABLE_DEVTOOLS=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF \
    -DJPEGXL_ENABLE_FUZZERS=OFF \
    -DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_FORCE_SYSTEM_HWY=ON \
    -DCMAKE_INSTALL_PREFIX="$LIBJXL_PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
  cmake --build "$LIBJXL_SRC/build-macos-arm64" -j"$(sysctl -n hw.ncpu)" --target install
fi
export PKG_CONFIG_PATH="$LIBJXL_PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
# The C++ runtime on macOS is /usr/lib/libc++ (passes the linkage gate); strip
# any -lstdc++ the .pc files might advertise and link -lc++ explicitly.
sed -i '' 's/-lstdc++//g' "$LIBJXL_PREFIX"/lib/pkgconfig/*.pc

# --disable-autodetect: configure enables nothing just because the runner
# happens to have it installed; the external libraries are exactly the ones
# enabled here. zlib, bzlib (libavformat links /usr/lib/libbz2) and iconv were
# previously autodetected. appkit/avfoundation/coreimage/metal/securetransport
# drop out: they only serve avdevice, avfilter and TLS, all disabled.
# --pkg-config-flags=--static: pull Libs.private so the static libjxl closure
# (hwy, brotli) resolves while FFmpeg itself stays shared.
CONFIGURE_FLAGS="--enable-shared --disable-static \
  --disable-autodetect --enable-zlib --enable-bzlib --enable-iconv \
  --disable-programs --disable-doc --disable-debug \
  --disable-avdevice --disable-avfilter \
  --disable-encoders --disable-muxers \
  --enable-muxer=mov,mp4,ipod,tgp,tg2,matroska,webm,avi,ogg,image2,image2pipe,apng,gif,webp,mp3,flac,wav \
  --disable-network \
  --disable-xlib --disable-libxcb --disable-sdl2 \
  --disable-lzma \
  --enable-videotoolbox --enable-audiotoolbox \
  --enable-libdav1d --enable-libjxl \
  --pkg-config-flags=--static"

cd "$SRC"
# --install-name-dir='@loader_path': inter-library references resolve relative to
# the directory the referencing dylib was extracted to — no rpath needed in the JVM.
./configure --prefix="$PREFIX" $CONFIGURE_FLAGS --install-name-dir='@loader_path' \
  --extra-libs='-lc++' \
  --extra-cflags="-mmacosx-version-min=$MACOS_MIN" --extra-ldflags="-mmacosx-version-min=$MACOS_MIN"
make -j"$(sysctl -n hw.ncpu)"
make install

rm -rf "$DEST"
mkdir -p "$DEST"

# Dependency order matters: each lib must find the ones before it already loadable.
LIBS="libavutil libswresample libavcodec libavformat libswscale"
: > "$DEST/manifest.txt"
for lib in $LIBS; do
  dylib="$PREFIX/lib/$lib.dylib"
  install_name="$(otool -D "$dylib" | tail -1)"
  base="$(basename "$install_name")"          # e.g. libavutil.60.dylib
  cp "$(cd "$PREFIX/lib" && readlink -f "$lib.dylib")" "$DEST/$base"
  chmod 644 "$DEST/$base"
  echo "$base" >> "$DEST/manifest.txt"
done

# No dependency outside @loader_path + OS frameworks may survive.
for f in "$DEST"/*.dylib; do
  if otool -L "$f" | tail -n +2 | grep -vE '@loader_path/|/usr/lib/|/System/Library/'; then
    echo "ERROR: $f has non-relocatable dependencies (above)"; exit 1
  fi
done

# Minimum-macOS gate: every staged dylib must carry exactly MACOS_MIN, and no
# object in the statically absorbed dependency archives may require newer
# (a stale or mis-targeted dependency build would otherwise slip through, as
# the final link stamps the dylib with the link target regardless).
minos_of() { otool -l "$1" | awk '/LC_BUILD_VERSION/ {b=1} b && $1=="minos" {print $2; b=0}' | sort -uV; }
for f in "$DEST"/*.dylib; do
  got="$(minos_of "$f")"
  [ "$got" = "$MACOS_MIN" ] || { echo "ERROR: $f minos '$got', want $MACOS_MIN"; exit 1; }
done
for a in "$DAV1D_PREFIX"/lib/*.a "$BROTLI_PREFIX"/lib/*.a "$HWY_PREFIX"/lib/*.a "$LIBJXL_PREFIX"/lib/*.a; do
  top="$(minos_of "$a" | tail -1)"
  if [ -n "$top" ] && [ "$(printf '%s\n%s\n' "$top" "$MACOS_MIN" | sort -V | tail -1)" != "$MACOS_MIN" ]; then
    echo "ERROR: $a contains objects with minos $top > $MACOS_MIN (stale dependency build? remove its prefix)"; exit 1
  fi
done

cp "$SRC/COPYING.LGPLv2.1" "$DEST/COPYING.LGPLv2.1"
cp "$DAV1D_SRC/COPYING" "$DEST/COPYING.dav1d"
cp "$LIBJXL_SRC/LICENSE" "$DEST/LICENSE.libjxl"
cp "$HWY_SRC/LICENSE" "$DEST/LICENSE.highway"
cp "$BROTLI_SRC/LICENSE" "$DEST/LICENSE.brotli"
cp "$LIBJXL_SRC/third_party/skcms/LICENSE" "$DEST/LICENSE.skcms"
{
  echo "FFmpeg $FFMPEG_VERSION (macos-arm64), built from unmodified source"
  echo "Source: https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n$FFMPEG_VERSION.tar.gz"
  echo "License: LGPL v2.1+ (see COPYING.LGPLv2.1; no --enable-gpl/--enable-version3/--enable-nonfree)"
  echo "Statically linked: dav1d $DAV1D_VERSION (BSD-2-Clause, see COPYING.dav1d)"
  echo "  Source: https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz"
  echo "Statically linked: libjxl $LIBJXL_VERSION (BSD-3-Clause, see LICENSE.libjxl)"
  echo "  Source: https://github.com/libjxl/libjxl/archive/refs/tags/v$LIBJXL_VERSION.tar.gz"
  echo "  with highway $HWY_VERSION (Apache-2.0, see LICENSE.highway),"
  echo "  brotli $BROTLI_VERSION (MIT, see LICENSE.brotli), skcms (BSD-3-Clause, see LICENSE.skcms)"
  echo "configure: $CONFIGURE_FLAGS --install-name-dir='@loader_path' --extra-libs='-lc++' --extra-cflags/ldflags='-mmacosx-version-min=$MACOS_MIN'"
  echo "Minimum macOS: $MACOS_MIN"
} > "$DEST/BUILD-INFO.txt"

echo "Staged $(ls "$DEST" | wc -l | tr -d ' ') files into $DEST"
