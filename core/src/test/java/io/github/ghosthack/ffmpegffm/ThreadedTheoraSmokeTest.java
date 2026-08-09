package io.github.ghosthack.ffmpegffm;

import io.github.ghosthack.ffmpegffm.ffmpeg.AVCodecContext;
import io.github.ghosthack.ffmpegffm.ffmpeg.AVCodecParameters;
import io.github.ghosthack.ffmpegffm.ffmpeg.AVFormatContext;
import io.github.ghosthack.ffmpegffm.ffmpeg.AVFrame;
import io.github.ghosthack.ffmpegffm.ffmpeg.AVPacket;
import io.github.ghosthack.ffmpegffm.ffmpeg.AVStream;
import io.github.ghosthack.ffmpegffm.ffmpeg.FFmpeg;
import org.junit.jupiter.api.Test;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Objects;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Exercises buffered frame-thread decoding rather than the one-frame fast
 * path. The fixture is generated from FFmpeg's solid-color source; its static
 * duplicate frames deliberately produce zero-sized Ogg packets.
 */
class ThreadedTheoraSmokeTest {

    @Test
    void decodesTenTheoraFramesWithSafeAutomaticThreads() throws Exception {
        Path fixture = Files.createTempFile("ffmpeg-ffm-theora", ".ogv");
        try (var in = Objects.requireNonNull(
                getClass().getResourceAsStream("/sample-theora.ogv"))) {
            Files.copy(in, fixture, java.nio.file.StandardCopyOption.REPLACE_EXISTING);
        }
        try {
            DecodeResult result = decodeFrames(fixture, 10);
            assertEquals(10, result.frames());
            assertTrue(result.emptyPackets() > 0,
                    "fixture exercises valid empty Ogg packets");
        } finally {
            Files.deleteIfExists(fixture);
        }
    }

    private static DecodeResult decodeFrames(Path fixture, int wantedFrames) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment formatPtr = arena.allocate(ValueLayout.ADDRESS);
            check(FFmpeg.avformat_open_input(formatPtr, arena.allocateFrom(fixture.toString()),
                    MemorySegment.NULL, MemorySegment.NULL), "avformat_open_input");
            MemorySegment format = formatPtr.get(ValueLayout.ADDRESS, 0)
                    .reinterpret(AVFormatContext.layout().byteSize());
            try {
                check(FFmpeg.avformat_find_stream_info(format, MemorySegment.NULL),
                        "avformat_find_stream_info");
                int streamIndex = FFmpeg.av_find_best_stream(format, FFmpeg.AVMEDIA_TYPE_VIDEO(),
                        -1, -1, MemorySegment.NULL, 0);
                assertTrue(streamIndex >= 0, "video stream present");

                MemorySegment streams = AVFormatContext.streams(format)
                        .reinterpret((streamIndex + 1L) * ValueLayout.ADDRESS.byteSize());
                MemorySegment stream = streams.getAtIndex(ValueLayout.ADDRESS, streamIndex)
                        .reinterpret(AVStream.layout().byteSize());
                MemorySegment parameters = AVStream.codecpar(stream)
                        .reinterpret(AVCodecParameters.layout().byteSize());
                MemorySegment decoder = FFmpeg.avcodec_find_decoder(
                        AVCodecParameters.codec_id(parameters));
                assertNotEquals(MemorySegment.NULL, decoder, "Theora decoder available");

                MemorySegment codec = FFmpeg.avcodec_alloc_context3(decoder)
                        .reinterpret(AVCodecContext.layout().byteSize());
                MemorySegment codecPtr = arena.allocate(ValueLayout.ADDRESS);
                codecPtr.set(ValueLayout.ADDRESS, 0, codec);
                try {
                    check(FFmpeg.avcodec_parameters_to_context(codec, parameters),
                            "avcodec_parameters_to_context");
                    AVCodecContext.pkt_timebase(codec, AVStream.time_base(stream));
                    AVCodecContext.thread_count(codec, 0); // automatic threading
                    check(FFmpeg.avcodec_open2(codec, decoder, MemorySegment.NULL),
                            "avcodec_open2");
                    assertTrue(AVCodecContext.thread_count(codec) > 1,
                            "Theora fixture exercises threaded decode");
                    return decodePackets(arena, format, codec, streamIndex, wantedFrames);
                } finally {
                    FFmpeg.avcodec_free_context(codecPtr);
                }
            } finally {
                FFmpeg.avformat_close_input(formatPtr);
            }
        }
    }

    private static DecodeResult decodePackets(Arena arena, MemorySegment format,
                                              MemorySegment codec, int streamIndex,
                                              int wantedFrames) {
        MemorySegment packet = FFmpeg.av_packet_alloc()
                .reinterpret(AVPacket.layout().byteSize());
        MemorySegment frame = FFmpeg.av_frame_alloc()
                .reinterpret(AVFrame.layout().byteSize());
        MemorySegment packetPtr = arena.allocate(ValueLayout.ADDRESS);
        MemorySegment framePtr = arena.allocate(ValueLayout.ADDRESS);
        packetPtr.set(ValueLayout.ADDRESS, 0, packet);
        framePtr.set(ValueLayout.ADDRESS, 0, frame);
        boolean pending = false;
        boolean draining = false;
        int decoded = 0;
        int emptyPackets = 0;
        try {
            while (decoded < wantedFrames) {
                int receive = FFmpeg.avcodec_receive_frame(codec, frame);
                if (receive == 0) {
                    decoded++;
                    continue;
                }
                if (receive == FFmpeg.AVERROR_EOF()) break;
                assertEquals(DecoderSupport.averrorEagain(), receive, "receive_frame");
                assertTrue(!draining, "draining decoder returned EAGAIN");

                if (pending) {
                    int send = FFmpeg.avcodec_send_packet(codec, packet);
                    if (send == 0) {
                        pending = false;
                        FFmpeg.av_packet_unref(packet);
                    } else {
                        assertEquals(DecoderSupport.averrorEagain(), send,
                                "resend pending packet");
                    }
                    continue;
                }

                int read;
                while (true) {
                    read = FFmpeg.av_read_frame(format, packet);
                    if (read < 0) break;
                    if (AVPacket.stream_index(packet) == streamIndex
                            && DecoderSupport.hasPayload(packet)) break;
                    if (AVPacket.stream_index(packet) == streamIndex) emptyPackets++;
                    FFmpeg.av_packet_unref(packet);
                }
                if (read < 0) {
                    check(FFmpeg.avcodec_send_packet(codec, MemorySegment.NULL),
                            "send drain packet");
                    draining = true;
                    continue;
                }

                int send = FFmpeg.avcodec_send_packet(codec, packet);
                if (send == 0) {
                    FFmpeg.av_packet_unref(packet);
                } else if (send == DecoderSupport.averrorEagain()) {
                    pending = true;
                } else {
                    check(send, "avcodec_send_packet");
                }
            }
            return new DecodeResult(decoded, emptyPackets);
        } finally {
            FFmpeg.av_frame_free(framePtr);
            FFmpeg.av_packet_free(packetPtr);
        }
    }

    private static void check(int error, String operation) {
        assertTrue(error >= 0, operation + " failed: " + error);
    }

    private record DecodeResult(int frames, int emptyPackets) {}
}
