#!/bin/sh
# Build FFmpeg (LGPL, decode + curated remux, zero external deps) for windows-x64 and stage
# the DLLs into natives/src/main/resources/natives/windows-x64/.
#
# Run from an MSYS2 **MINGW64** shell on the Windows machine:
#   pacman -S --needed mingw-w64-x86_64-toolchain mingw-w64-x86_64-meson \
#     mingw-w64-x86_64-ninja mingw-w64-x86_64-cmake mingw-w64-x86_64-pkgconf \
#     make nasm diffutils
#   build-natives/windows-x64.sh [path-to-ffmpeg-source]   (default build/ffmpeg-8.1.2)
#
# Fetch the source first if needed:
#   mkdir -p build/ffmpeg-8.1.2 && curl -sfL https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n8.1.2.tar.gz \
#     | tar xz --strip-components=1 -C build/ffmpeg-8.1.2
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

# libjxl (BSD-3) + its deps highway (Apache-2) and brotli (MIT), all static,
# absorbed into avcodec-62.dll — see macos-arm64.sh. The C++ runtime stays the
# mingw shared libstdc++-6.dll, staged below like the other runtime DLLs.
BROTLI_VERSION=1.1.0
HWY_VERSION=1.2.0
LIBJXL_VERSION=0.11.1
BROTLI_SRC="$ROOT/build/brotli-$BROTLI_VERSION"
HWY_SRC="$ROOT/build/highway-$HWY_VERSION"
LIBJXL_SRC="$ROOT/build/libjxl-$LIBJXL_VERSION"
BROTLI_PREFIX="$ROOT/build/prefix-brotli-windows-x64"
HWY_PREFIX="$ROOT/build/prefix-hwy-windows-x64"
LIBJXL_PREFIX="$ROOT/build/prefix-libjxl-windows-x64"

if [ ! -d "$BROTLI_SRC" ]; then
  curl -sfL "https://github.com/google/brotli/archive/refs/tags/v$BROTLI_VERSION.tar.gz" \
    | tar xz -C "$ROOT/build"
fi
if [ ! -f "$BROTLI_PREFIX/lib/pkgconfig/libbrotlidec.pc" ]; then
  cmake -S "$BROTLI_SRC" -B "$BROTLI_SRC/build-windows-x64" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBROTLI_DISABLE_TESTS=ON \
    -DCMAKE_INSTALL_PREFIX="$BROTLI_PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
  cmake --build "$BROTLI_SRC/build-windows-x64" -j"$(nproc)" --target install
fi

if [ ! -d "$HWY_SRC" ]; then
  curl -sfL "https://github.com/google/highway/archive/refs/tags/$HWY_VERSION.tar.gz" \
    | tar xz -C "$ROOT/build"
fi
if [ ! -f "$HWY_PREFIX/lib/pkgconfig/libhwy.pc" ]; then
  cmake -S "$HWY_SRC" -B "$HWY_SRC/build-windows-x64" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_TESTING=OFF \
    -DHWY_ENABLE_TESTS=OFF -DHWY_ENABLE_EXAMPLES=OFF -DHWY_ENABLE_CONTRIB=OFF \
    -DCMAKE_INSTALL_PREFIX="$HWY_PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
  cmake --build "$HWY_SRC/build-windows-x64" -j"$(nproc)" --target install
fi

if [ ! -d "$LIBJXL_SRC" ]; then
  # --exclude tools/benchmark: those scripts are symlinks, which MSYS2 tar
  # cannot create without special privileges — and the build never uses them.
  curl -sfL "https://github.com/libjxl/libjxl/archive/refs/tags/v$LIBJXL_VERSION.tar.gz" \
    | tar xz -C "$ROOT/build" --exclude='*/tools/benchmark/*'
  ( cd "$LIBJXL_SRC" && ./deps.sh )   # fetches pinned third_party (skcms et al.)
fi
export PKG_CONFIG_PATH="$BROTLI_PREFIX/lib/pkgconfig:$HWY_PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
if [ ! -f "$LIBJXL_PREFIX/lib/pkgconfig/libjxl.pc" ]; then
  cmake -S "$LIBJXL_SRC" -B "$LIBJXL_SRC/build-windows-x64" -G Ninja \
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
  cmake --build "$LIBJXL_SRC/build-windows-x64" -j"$(nproc)" --target install
fi
export PKG_CONFIG_PATH="$LIBJXL_PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"

# Same feature set as macos-arm64.sh, minus the Apple toolboxes. The Windows
# hwaccel glue (d3d11va/dxva2) is header-only and stays enabled by default.
# --pkg-config-flags=--static: pull Libs.private so the static libjxl closure
# (hwy, brotli) resolves while FFmpeg itself stays shared. -lstdc++ resolves
# to the staged libstdc++-6.dll (FFmpeg links with cc, not c++).
CONFIGURE_FLAGS="--enable-shared --disable-static \
  --disable-programs --disable-doc --disable-debug \
  --disable-avdevice --disable-avfilter \
  --disable-encoders --disable-muxers \
  --enable-muxer=mov,mp4,ipod,3gp,3g2,matroska,webm,avi,ogg \
  --disable-network \
  --disable-xlib --disable-libxcb --disable-sdl2 \
  --enable-libdav1d --enable-libjxl \
  --pkg-config-flags=--static"

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  cd "$SRC"
  ./configure --prefix="$PREFIX" $CONFIGURE_FLAGS --extra-libs='-lstdc++'
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
for runtime in libwinpthread-1.dll libgcc_s_seh-1.dll libstdc++-6.dll libiconv-2.dll zlib1.dll liblzma-5.dll libbz2-1.dll; do
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
ALLOWED='avutil|swresample|avcodec|avformat|swscale|libwinpthread|libgcc_s_seh|libstdc\+\+|libiconv|zlib1|liblzma|libbz2|KERNEL32|USER32|ADVAPI32|SHELL32|ole32|OLEAUT32|SHLWAPI|bcrypt|msvcrt|ntdll|api-ms-'
for f in "$DEST"/*.dll; do
  if objdump -p "$f" | awk '/DLL Name:/{print $3}' | grep -viE "^($ALLOWED)"; then
    echo "ERROR: $f imports from unexpected DLLs (above)"; exit 1
  fi
done

cp "$SRC/COPYING.LGPLv2.1" "$DEST/COPYING.LGPLv2.1"
cp "$DAV1D_SRC/COPYING" "$DEST/COPYING.dav1d"
cp "$LIBJXL_SRC/LICENSE" "$DEST/LICENSE.libjxl"
cp "$HWY_SRC/LICENSE" "$DEST/LICENSE.highway"
cp "$BROTLI_SRC/LICENSE" "$DEST/LICENSE.brotli"
cp "$LIBJXL_SRC/third_party/skcms/LICENSE" "$DEST/LICENSE.skcms"
{
  echo "FFmpeg $FFMPEG_VERSION (windows-x64), built from unmodified source with MSYS2 mingw-w64"
  echo "Source: https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n$FFMPEG_VERSION.tar.gz"
  echo "License: LGPL v2.1+ (see COPYING.LGPLv2.1; no --enable-gpl/--enable-version3/--enable-nonfree)"
  echo "Statically linked: dav1d $DAV1D_VERSION (BSD-2-Clause, see COPYING.dav1d)"
  echo "  Source: https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz"
  echo "Statically linked: libjxl $LIBJXL_VERSION (BSD-3-Clause, see LICENSE.libjxl)"
  echo "  Source: https://github.com/libjxl/libjxl/archive/refs/tags/v$LIBJXL_VERSION.tar.gz"
  echo "  with highway $HWY_VERSION (Apache-2.0, see LICENSE.highway),"
  echo "  brotli $BROTLI_VERSION (MIT, see LICENSE.brotli), skcms (BSD-3-Clause, see LICENSE.skcms)"
  echo "configure: $CONFIGURE_FLAGS --extra-libs='-lstdc++'"
} > "$DEST/BUILD-INFO.txt"

echo "Staged $(ls "$DEST" | wc -l) files into $DEST"
echo "Now run 'mvn install' at the repo root to install the windows-x64 classifier jar."
