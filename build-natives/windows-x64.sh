#!/bin/sh
# Build FFmpeg (LGPL, decode-only, zero external deps) for windows-x64 and stage
# the DLLs into natives/src/main/resources/natives/windows-x64/.
#
# Run from an MSYS2 **MINGW64** shell on the Windows machine:
#   pacman -S --needed mingw-w64-x86_64-toolchain mingw-w64-x86_64-meson \
#     mingw-w64-x86_64-ninja mingw-w64-x86_64-pkgconf make nasm diffutils
#   build-natives/windows-x64.sh [path-to-ffmpeg-source]   (default build/ffmpeg-8.1.2)
#
# Fetch the source first if needed:
#   mkdir -p build && curl -sfL https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz | tar xJ -C build
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/build/ffmpeg-8.1.2}"
PREFIX="$ROOT/build/prefix-windows-x64"
DEST="$ROOT/natives/src/main/resources/natives/windows-x64"
FFMPEG_VERSION="$(cat "$SRC/RELEASE")"

# dav1d (BSD-2) static, absorbed into avcodec-62.dll — see macos-arm64.sh.
DAV1D_VERSION=1.5.1
DAV1D_SRC="$ROOT/build/dav1d-$DAV1D_VERSION"
DAV1D_PREFIX="$ROOT/build/prefix-dav1d-windows-x64"
if [ ! -d "$DAV1D_SRC" ]; then
  curl -sfL "https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz" \
    | tar xJ -C "$ROOT/build"
fi
if [ ! -f "$DAV1D_PREFIX/lib/pkgconfig/dav1d.pc" ]; then
  meson setup "$DAV1D_SRC/build-windows-x64" "$DAV1D_SRC" \
    --prefix="$DAV1D_PREFIX" --libdir=lib --buildtype=release \
    -Ddefault_library=static -Denable_tools=false -Denable_tests=false
  ninja -C "$DAV1D_SRC/build-windows-x64" install
fi
export PKG_CONFIG_PATH="$DAV1D_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# Same feature set as macos-arm64.sh, minus the Apple toolboxes. The Windows
# hwaccel glue (d3d11va/dxva2) is header-only and stays enabled by default.
CONFIGURE_FLAGS="--enable-shared --disable-static \
  --disable-programs --disable-doc --disable-debug \
  --disable-avdevice --disable-avfilter \
  --disable-encoders --disable-muxers --disable-network \
  --disable-xlib --disable-libxcb --disable-sdl2 \
  --enable-libdav1d"

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  cd "$SRC"
  ./configure --prefix="$PREFIX" $CONFIGURE_FLAGS
  make -j"$(nproc)"
  make install
fi

rm -rf "$DEST"
mkdir -p "$DEST"

# Dependency order: each DLL must find the ones before it already loaded
# (the Windows loader matches already-loaded modules by name).
: > "$DEST/manifest.txt"

# The mingw runtime + support DLLs the libav DLLs link against must ship too,
# first: Windows has no system iconv/zlib, unlike macOS's /usr/lib.
# iconv/zlib/lzma/bz2 are OS libraries on macOS (/usr/lib) but not on Windows;
# staging them keeps the two platforms' FFmpeg feature sets identical.
for runtime in libwinpthread-1.dll libgcc_s_seh-1.dll libiconv-2.dll zlib1.dll liblzma-5.dll libbz2-1.dll; do
  if [ -f "/mingw64/bin/$runtime" ]; then
    cp "/mingw64/bin/$runtime" "$DEST/$runtime"
    echo "$runtime" >> "$DEST/manifest.txt"
  fi
done

for stem in avutil swresample avcodec avformat swscale; do
  dll="$(ls "$PREFIX/bin/$stem"-*.dll)"
  base="$(basename "$dll")"                   # e.g. avutil-60.dll
  cp "$dll" "$DEST/$base"
  echo "$base" >> "$DEST/manifest.txt"
done

# No import may resolve outside: our own DLLs, the staged runtime, or Windows itself.
ALLOWED='avutil|swresample|avcodec|avformat|swscale|libwinpthread|libgcc_s_seh|libiconv|zlib1|liblzma|libbz2|KERNEL32|USER32|ADVAPI32|SHELL32|ole32|OLEAUT32|SHLWAPI|bcrypt|msvcrt|ntdll|api-ms-'
for f in "$DEST"/*.dll; do
  if objdump -p "$f" | awk '/DLL Name:/{print $3}' | grep -viE "^($ALLOWED)"; then
    echo "ERROR: $f imports from unexpected DLLs (above)"; exit 1
  fi
done

cp "$SRC/COPYING.LGPLv2.1" "$DEST/COPYING.LGPLv2.1"
cp "$DAV1D_SRC/COPYING" "$DEST/COPYING.dav1d"
{
  echo "FFmpeg $FFMPEG_VERSION (windows-x64), built from unmodified source with MSYS2 mingw-w64"
  echo "Source: https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
  echo "License: LGPL v2.1+ (see COPYING.LGPLv2.1; no --enable-gpl/--enable-version3/--enable-nonfree)"
  echo "Statically linked: dav1d $DAV1D_VERSION (BSD-2-Clause, see COPYING.dav1d)"
  echo "  Source: https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz"
  echo "configure: $CONFIGURE_FLAGS"
} > "$DEST/BUILD-INFO.txt"

echo "Staged $(ls "$DEST" | wc -l) files into $DEST"
echo "Now run 'mvn install' at the repo root to install the windows-x64 classifier jar."
