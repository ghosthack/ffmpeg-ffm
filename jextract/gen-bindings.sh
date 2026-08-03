#!/bin/sh
# Generate the FFmpeg FFM stubs from the headers of the from-source build, then
# re-point the generated SYMBOL_LOOKUP at the runtime loader (FfmpegLibs).
#
# Run once, on macOS, after build-natives/macos-arm64.sh. The generated struct
# layouts are platform-portable for FFmpeg's public API (verified: the mac- and
# windows-generated trees in the parent project are byte-identical modulo
# package name), so a single generation serves every platform.
#
# Prereq: tools/jextract-22 (see tools/README.md for the download URL).
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JX="$ROOT/tools/jextract-22/bin/jextract"
PREFIX="$ROOT/build/prefix-macos-arm64"
OUT="$ROOT/core/src/main/java"
PKG="io.github.ghosthack.ffmpegffm.ffmpeg"
SDK=$(xcrun --show-sdk-path)

[ -x "$JX" ] || { echo "jextract not found at $JX"; exit 1; }
[ -d "$PREFIX/include" ] || { echo "run build-natives/macos-arm64.sh first"; exit 1; }

GEN_DIR="$OUT/$(echo "$PKG" | tr . /)"
rm -rf "$GEN_DIR"

# Same curated surface as the parent project's proven bindings (FFmpeg 8 shape,
# incl. AVChannelLayout). The -l paths only seed the generated SYMBOL_LOOKUP,
# which is replaced below — the loader owns library resolution at runtime.
"$JX" --output "$OUT" -t "$PKG" \
  --header-class-name FFmpeg \
  -I "$SDK/usr/include" \
  -I "$PREFIX/include" \
  -l ":$PREFIX/lib/libavutil.dylib" \
  -l ":$PREFIX/lib/libavformat.dylib" \
  -l ":$PREFIX/lib/libavcodec.dylib" \
  -l ":$PREFIX/lib/libswscale.dylib" \
  --include-function avformat_version \
  --include-function avformat_open_input \
  --include-function avformat_find_stream_info \
  --include-function avformat_close_input \
  --include-function av_find_best_stream \
  --include-function av_read_frame \
  --include-function av_seek_frame \
  --include-function avcodec_alloc_context3 \
  --include-function avcodec_parameters_to_context \
  --include-function avcodec_open2 \
  --include-function av_opt_set_int \
  --include-function av_opt_set \
  --include-function avcodec_free_context \
  --include-function avcodec_send_packet \
  --include-function avcodec_receive_frame \
  --include-function avcodec_find_decoder \
  --include-function avcodec_get_name \
  --include-function av_packet_alloc \
  --include-function av_packet_free \
  --include-function av_packet_unref \
  --include-function av_frame_alloc \
  --include-function av_frame_free \
  --include-function av_frame_unref \
  --include-function av_frame_get_side_data \
  --include-function av_strerror \
  --include-function av_log_set_level \
  --include-function av_get_pix_fmt_name \
  --include-function av_dict_get \
  --include-function av_dict_count \
  --include-function av_buffer_ref \
  --include-function av_buffer_unref \
  --include-function av_hwdevice_ctx_create \
  --include-function av_hwframe_transfer_data \
  --include-function avcodec_get_hw_config \
  --include-function sws_getContext \
  --include-function sws_scale \
  --include-function sws_freeContext \
  --include-struct AVFormatContext \
  --include-struct AVInputFormat \
  --include-struct AVStream \
  --include-struct AVCodecParameters \
  --include-struct AVCodecContext \
  --include-struct AVCodec \
  --include-struct AVFrame \
  --include-struct AVPacket \
  --include-struct AVFrameSideData \
  --include-struct AVRational \
  --include-struct AVIOInterruptCB \
  --include-struct AVProbeData \
  --include-struct AVDictionaryEntry \
  --include-struct AVChannelLayout \
  --include-struct AVStreamGroup \
  --include-struct AVStreamGroupTileGrid \
  --include-struct AVCodecHWConfig \
  --include-typedef AVMediaType \
  --include-typedef AVPixelFormat \
  --include-typedef AVCodecID \
  --include-typedef AVChannelOrder \
  --include-typedef AVHWDeviceType \
  --include-typedef AVFrameSideDataType \
  --include-typedef AVStreamGroupParamsType \
  --include-constant AVMEDIA_TYPE_UNKNOWN \
  --include-constant AVMEDIA_TYPE_VIDEO \
  --include-constant AVMEDIA_TYPE_AUDIO \
  --include-constant AVMEDIA_TYPE_SUBTITLE \
  --include-constant AV_PIX_FMT_BGRA \
  --include-constant SWS_BILINEAR \
  --include-constant SWS_AREA \
  --include-constant AV_NOPTS_VALUE \
  --include-constant AV_TIME_BASE \
  --include-constant AVERROR_EOF \
  --include-constant AV_DISPOSITION_ATTACHED_PIC \
  --include-constant AV_LOG_ERROR \
  --include-constant AV_LOG_QUIET \
  --include-constant AV_DICT_IGNORE_SUFFIX \
  --include-constant AV_STREAM_GROUP_PARAMS_TILE_GRID \
  --include-constant AV_HWDEVICE_TYPE_VIDEOTOOLBOX \
  --include-constant AV_HWDEVICE_TYPE_D3D11VA \
  --include-constant AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX \
  --include-constant AV_PIX_FMT_NONE \
  --include-constant AV_CODEC_ID_JPEGXL \
  --include-constant AV_PIX_FMT_RGB48LE \
  --include-constant AV_PIX_FMT_RGBA64LE \
  --include-constant AV_PIX_FMT_GRAY16LE \
  --include-constant AV_INPUT_BUFFER_PADDING_SIZE \
  --include-constant AV_FRAME_DATA_ICC_PROFILE \
  "$ROOT/jextract/ffmpeg_api.h"

# Replace the baked absolute-path lookup chain with the runtime loader.
perl -0777 -pi -e \
  's/static final SymbolLookup SYMBOL_LOOKUP = .*?;/static final SymbolLookup SYMBOL_LOOKUP = io.github.ghosthack.ffmpegffm.FfmpegLibs.lookup();/s' \
  "$GEN_DIR/FFmpeg.java"

if grep -rn "$PREFIX" "$GEN_DIR" >/dev/null; then
  echo "ERROR: build-prefix paths survived in generated stubs"; exit 1
fi
grep -q "FfmpegLibs.lookup()" "$GEN_DIR/FFmpeg.java" || { echo "ERROR: lookup patch did not apply"; exit 1; }

echo "Generated $(ls "$GEN_DIR" | wc -l | tr -d ' ') files into $GEN_DIR"
