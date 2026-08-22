# ffmpeg-ffm

Panama FFM (jextract) bindings for FFmpeg with bundled, from-source LGPL
natives. One Maven coordinate, batteries included — no user-installed FFmpeg,
no JNI.

| Artifact | Contents | License |
|---|---|---|
| `io.github.ghosthack:ffmpeg-ffm` | jextract-generated stubs + runtime loader (pure Java, JDK ≥ 22) | MIT |
| `io.github.ghosthack:ffmpeg-ffm-natives` (classifier `macos-arm64`, `windows-x64`, `linux-x64`) | FFmpeg 8.1.2 shared libraries, built from unmodified source, LGPL-only configuration | LGPL v2.1+ (see THIRD-PARTY.md) |

Status: decode plus packet-remux surface (demux + decode + swscale and curated
MP4/MOV, Matroska/WebM, AVI, Ogg, still-image, MP3, FLAC, and WAV muxers; no
encoders or network), curated to the API listed in `jextract/gen-bindings.sh`.
Platforms: macos-arm64, windows-x64, and linux-x64. AV1 decodes in software
via a statically linked dav1d (BSD-2) — FFmpeg has no native AV1 software
decoder, only a hwaccel shim. JPEG XL decodes via a statically linked libjxl
0.11 (BSD-3, with highway/brotli/skcms; since 0.3.0) — FFmpeg has only a JXL
parser natively.

**Software decode by design.** All decoding runs on the CPU (with full SIMD:
dav1d and FFmpeg ship hand-written NEON/AVX kernels selected at runtime). The
natives do compile the hardware-accel hooks (VideoToolbox on macOS,
D3D11VA/D3D12VA/DXVA2 on Windows), but the curated binding surface omits the
hw-device API (`av_hwdevice_ctx_create`, `get_format`, `av_hwframe_transfer_data`),
so nothing routes through them. Hardware decode would be a purely additive
binding release — regenerated stubs, byte-identical natives.

## Use

```xml
<dependency>
  <groupId>io.github.ghosthack</groupId>
  <artifactId>ffmpeg-ffm</artifactId>
  <version>8.1.2-0.3.7</version>
</dependency>
<dependency>
  <groupId>io.github.ghosthack</groupId>
  <artifactId>ffmpeg-ffm-natives</artifactId>
  <version>8.1.2-0.3.7</version>
  <classifier>macos-arm64</classifier> <!-- or windows-x64 / linux-x64 -->
  <scope>runtime</scope>
</dependency>
```

When using the module path, declare `requires ffmpeg.ffm;` and run with
`--enable-native-access=ffmpeg.ffm`. When using the class path, run with
`--enable-native-access=ALL-UNNAMED`. Then:

```java
import io.github.ghosthack.ffmpegffm.ffmpeg.FFmpeg;

int version = FFmpeg.avformat_version(); // natives extract + load on first use
```

`core/src/test/java/.../SmokeTest.java` is a complete open→decode→scale example.

### Decoder send/receive loop

Demuxers may return zero-sized packets (Ogg/Theora does this for duplicate
frames). Do not pass those packets to `avcodec_send_packet`: libavcodec treats
an empty packet like a decoder drain, so a later data packet can fail with
`EINVAL`. `DecoderSupport.hasPayload(packet)` distinguishes packets that are
safe to send.

The send/receive API also requires callers to retain and resend the same packet
when `avcodec_send_packet` returns `EAGAIN`; reading a replacement packet loses
input. Use `DecoderSupport.averrorEagain()` for the platform-specific native
error value. `ThreadedTheoraSmokeTest` is the complete buffered example,
including empty-packet filtering, packet retention, and final draining.

### Packet remuxing

The native bundle includes the MP4/MOV family (`mov`, `mp4`, `ipod`, `3gp`,
`3g2`), Matroska/WebM, AVI, Ogg, single-image (`image2`/`image2pipe`), APNG,
GIF, WebP, MP3, FLAC, and WAV muxers. The single-image muxers cover JPEG, PNG,
WebP, and JPEG XL packet output. Encoders remain disabled: callers create an
output context and streams, copy codec parameters, rescale packet timestamps,
and pass the original encoded packets to `av_interleaved_write_frame`.
`RemuxSmokeTest` verifies that the curated muxers are present and that
same-container remuxing preserves encoded packet payloads.

Muxer availability alone does not prove that remuxing removes metadata carried
inside an encoded packet or a format-required header. Applications must verify
that property per format rather than treating this bundle as a metadata policy.

The binding deliberately exposes raw libavformat policy rather than deciding
which container or stream metadata an application should retain. Callers own
that allowlist and should preserve presentation-critical stream parameters and
side data when constructing the output.

### Library resolution order

1. `-Dffmpegffm.libdir=<dir>` or `FFMPEG_FFM_LIBDIR` — use an existing FFmpeg
   install (also the LGPL relinking hook);
2. the bundled natives jar for the current platform, extracted once to
   `~/.cache/ffmpeg-ffm/<version>-<platform>/`;
3. libraries already loaded by the host application.

## Gotcha: generated indexed accessors

jextract 22 generates indexed array-field accessors (e.g.
`AVFrame.linesize(frame, 0)`) whose VarHandle is built from the field's own
layout, so they read relative to the **struct start**, not the field offset —
wrong for every array field not at offset 0. Use the field-slice form instead:

```java
int linesize0 = AVFrame.linesize(frame).getAtIndex(ValueLayout.JAVA_INT, 0);
```

## Building

Each platform's natives are built on that platform; stub generation runs once,
on macOS (layouts are portable across platforms for FFmpeg's public API).

macOS (arm64):

```sh
mkdir -p build/ffmpeg-8.1.2
curl -sfL https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n8.1.2.tar.gz \
  | tar xz --strip-components=1 -C build/ffmpeg-8.1.2
build-natives/macos-arm64.sh     # configure/make, stage dylibs + manifest
jextract/gen-bindings.sh         # regenerate stubs (needs tools/jextract-22, see tools/README.md)
mvn install                      # installs ffmpeg-ffm + natives:macos-arm64, runs smoke tests
```

Windows (x64), from an MSYS2 MINGW64 shell: see `build-natives/windows-x64.sh`
header for prerequisites, then the same flow with `windows-x64.sh`.

Staged natives (`natives/src/main/resources/natives/`) are build outputs and
not committed; the scripts verify every shipped library resolves its
dependencies only against the staged set and the OS.
