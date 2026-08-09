package io.github.ghosthack.ffmpegffm;

import io.github.ghosthack.ffmpegffm.ffmpeg.AVPacket;

import java.lang.foreign.MemorySegment;
import java.util.Locale;
import java.util.Objects;

/**
 * Small portability and policy helpers for FFmpeg's send/receive decoder API.
 * The generated bindings remain available when callers need exact raw access.
 */
public final class DecoderSupport {

    private static final int AVERROR_EAGAIN =
            System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("mac")
                    ? -35 : -11;

    private DecoderSupport() {}

    /** Returns {@code AVERROR(EAGAIN)} for the current supported platform. */
    public static int averrorEagain() {
        return AVERROR_EAGAIN;
    }

    /**
     * Returns whether a demuxed packet carries data suitable for
     * {@code avcodec_send_packet}. Empty Ogg packets are valid container data,
     * but libavcodec interprets a zero-sized packet as a decoder flush.
     */
    public static boolean hasPayload(MemorySegment packet) {
        Objects.requireNonNull(packet, "packet");
        return !packet.equals(MemorySegment.NULL) && AVPacket.size(packet) > 0;
    }
}
