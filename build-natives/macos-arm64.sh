#!/bin/sh
# Build FFmpeg (LGPL, decode-only, zero external deps) for macos-arm64 and stage
# the dylibs into natives/src/main/resources/natives/macos-arm64/.
#
# Usage: build-natives/macos-arm64.sh [path-to-ffmpeg-source]   (default build/ffmpeg-8.1.2)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/build/ffmpeg-8.1.2}"
PREFIX="$ROOT/build/prefix-macos-arm64"
DEST="$ROOT/natives/src/main/resources/natives/macos-arm64"
FFMPEG_VERSION="$(cat "$SRC/RELEASE")"

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

CONFIGURE_FLAGS="--enable-shared --disable-static \
  --disable-programs --disable-doc --disable-debug \
  --disable-avdevice --disable-avfilter \
  --disable-encoders --disable-muxers --disable-network \
  --disable-xlib --disable-libxcb --disable-sdl2 \
  --enable-videotoolbox --enable-audiotoolbox \
  --enable-libdav1d"

cd "$SRC"
# --install-name-dir='@loader_path': inter-library references resolve relative to
# the directory the referencing dylib was extracted to — no rpath needed in the JVM.
./configure --prefix="$PREFIX" $CONFIGURE_FLAGS --install-name-dir='@loader_path'
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

cp "$SRC/COPYING.LGPLv2.1" "$DEST/COPYING.LGPLv2.1"
cp "$DAV1D_SRC/COPYING" "$DEST/COPYING.dav1d"
{
  echo "FFmpeg $FFMPEG_VERSION (macos-arm64), built from unmodified source"
  echo "Source: https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
  echo "License: LGPL v2.1+ (see COPYING.LGPLv2.1; no --enable-gpl/--enable-version3/--enable-nonfree)"
  echo "Statically linked: dav1d $DAV1D_VERSION (BSD-2-Clause, see COPYING.dav1d)"
  echo "  Source: https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz"
  echo "configure: $CONFIGURE_FLAGS --install-name-dir='@loader_path'"
} > "$DEST/BUILD-INFO.txt"

echo "Staged $(ls "$DEST" | wc -l | tr -d ' ') files into $DEST"
