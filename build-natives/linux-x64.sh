#!/bin/sh
# Build FFmpeg (LGPL, decode-only, zero external deps) for linux-x64 and stage
# the .so files into natives/src/main/resources/natives/linux-x64/.
#
# Run on an x86-64 Linux machine (gcc, make, meson, ninja, nasm, patchelf):
#   build-natives/linux-x64.sh [path-to-ffmpeg-source]   (default build/ffmpeg-8.1.2)
#
# Fetch the source first if needed:
#   mkdir -p build && curl -sfL https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz | tar xJ -C build
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

# Same feature set as macos-arm64.sh, minus the Apple toolboxes. vaapi/vdpau
# explicitly off: they would add libva/libvdpau runtime deps, breaking the
# zero-external-deps guarantee (Linux hw decode is a future, deliberate step).
CONFIGURE_FLAGS="--enable-shared --disable-static \
  --disable-programs --disable-doc --disable-debug \
  --disable-avdevice --disable-avfilter \
  --disable-encoders --disable-muxers --disable-network \
  --disable-xlib --disable-libxcb --disable-sdl2 \
  --disable-vaapi --disable-vdpau \
  --enable-libdav1d"

cd "$SRC"
./configure --prefix="$PREFIX" $CONFIGURE_FLAGS
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
{
  echo "FFmpeg $FFMPEG_VERSION (linux-x64), built from unmodified source"
  echo "Source: https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
  echo "License: LGPL v2.1+ (see COPYING.LGPLv2.1; no --enable-gpl/--enable-version3/--enable-nonfree)"
  echo "Statically linked: dav1d $DAV1D_VERSION (BSD-2-Clause, see COPYING.dav1d)"
  echo "  Source: https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz"
  echo "configure: $CONFIGURE_FLAGS"
} > "$DEST/BUILD-INFO.txt"

echo "Staged $(ls "$DEST" | wc -l | tr -d ' ') files into $DEST"
