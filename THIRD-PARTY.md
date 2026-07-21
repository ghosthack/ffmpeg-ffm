# Third-party notices

## FFmpeg

The `ffmpeg-ffm-natives` classifier jars contain shared libraries built from
**unmodified FFmpeg source** (https://ffmpeg.org), licensed under the
**GNU Lesser General Public License v2.1 or later**.

- No `--enable-gpl`, `--enable-version3`, or `--enable-nonfree` components are
  included; the exact configure line ships in each jar's `BUILD-INFO.txt`.
- The license text ships in each jar as `COPYING.LGPLv2.1`.
- Corresponding source: `https://ffmpeg.org/releases/ffmpeg-<version>.tar.xz`
  (version recorded in `BUILD-INFO.txt`).
- The libraries are dynamically loaded and user-replaceable: point
  `FFMPEG_FFM_LIBDIR` (or `-Dffmpegffm.libdir`) at any directory containing a
  compatible FFmpeg build to substitute your own copies, satisfying LGPL §6
  relinking.

## dav1d

`libavcodec` statically links **dav1d** (https://code.videolan.org/videolan/dav1d),
the VideoLAN AV1 software decoder, licensed **BSD-2-Clause** — FFmpeg itself has
no native software AV1 decoder. The license text ships in each jar as
`COPYING.dav1d`; the exact version and source URL are in `BUILD-INFO.txt`.
BSD-2 static linking imposes no copyleft: the combined library remains
LGPL v2.1+.

The binding code itself (`ffmpeg-ffm`) contains no FFmpeg source and is MIT
licensed (see LICENSE).
