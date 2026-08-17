package io.github.ghosthack.ffmpegffm;

import io.github.ghosthack.ffmpegffm.ffmpeg.AVCodecParameters;
import io.github.ghosthack.ffmpegffm.ffmpeg.AVFormatContext;
import io.github.ghosthack.ffmpegffm.ffmpeg.AVPacket;
import io.github.ghosthack.ffmpegffm.ffmpeg.AVStream;
import io.github.ghosthack.ffmpegffm.ffmpeg.FFmpeg;
import org.junit.jupiter.api.Test;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Objects;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** End-to-end proof that the bundled muxers can stream-copy encoded packets. */
class RemuxSmokeTest {

    @Test
    void remuxesMp4WithoutChangingEncodedPackets() throws Exception {
        assertPacketPreservingRemux("/sample.mp4", ".mp4");
    }

    @Test
    void remuxesOggWithoutChangingEncodedPackets() throws Exception {
        assertPacketPreservingRemux("/sample-theora.ogv", ".ogv");
    }

    private void assertPacketPreservingRemux(String resource, String suffix) throws Exception {
        Path input = Files.createTempFile("ffmpeg-ffm-remux-input", suffix);
        Path output = Files.createTempFile("ffmpeg-ffm-remux-output", suffix);
        try (var in = Objects.requireNonNull(getClass().getResourceAsStream(resource))) {
            Files.copy(in, input, java.nio.file.StandardCopyOption.REPLACE_EXISTING);
        }
        FFmpeg.av_log_set_level(FFmpeg.AV_LOG_ERROR());
        try {
            List<String> before = packetDigests(input);
            remux(input, output);
            List<String> after = packetDigests(output);

            assertFalse(before.isEmpty(), "fixture contains encoded packets");
            assertEquals(before, after, "same-container remux preserves every packet payload");
            assertTrue(Files.size(output) > 0, "muxer wrote a non-empty output");
        } finally {
            Files.deleteIfExists(output);
            Files.deleteIfExists(input);
        }
    }

    @Test
    void exposesTheCuratedMuxerSet() {
        try (Arena arena = Arena.ofConfined()) {
            for (String name : List.of("mp4", "mov", "matroska", "webm", "avi", "ogg")) {
                assertNotEquals(MemorySegment.NULL,
                        FFmpeg.av_guess_format(arena.allocateFrom(name), MemorySegment.NULL,
                                MemorySegment.NULL),
                        name + " muxer is bundled");
            }
            assertEquals(MemorySegment.NULL,
                    FFmpeg.av_guess_format(arena.allocateFrom("not-a-real-muxer"),
                            MemorySegment.NULL, MemorySegment.NULL));
        }
    }

    private static void remux(Path input, Path output) throws Exception {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment inputPtr = addressSlot(arena);
            check(FFmpeg.avformat_open_input(inputPtr, arena.allocateFrom(input.toString()),
                    MemorySegment.NULL, MemorySegment.NULL), "avformat_open_input");
            MemorySegment inputContext = pointedStruct(inputPtr, AVFormatContext.layout().byteSize());

            MemorySegment outputPtr = addressSlot(arena);
            MemorySegment outputContext = MemorySegment.NULL;
            boolean outputIoOpen = false;
            try {
                check(FFmpeg.avformat_find_stream_info(inputContext, MemorySegment.NULL),
                        "avformat_find_stream_info");
                check(FFmpeg.avformat_alloc_output_context2(outputPtr, MemorySegment.NULL,
                                MemorySegment.NULL, arena.allocateFrom(output.toString())),
                        "avformat_alloc_output_context2");
                outputContext = pointedStruct(outputPtr, AVFormatContext.layout().byteSize());

                int streamCount = AVFormatContext.nb_streams(inputContext);
                assertTrue(streamCount > 0, "input has streams");
                for (int i = 0; i < streamCount; i++) {
                    MemorySegment sourceStream = stream(inputContext, i);
                    MemorySegment targetStreamPointer = FFmpeg.avformat_new_stream(
                            outputContext, MemorySegment.NULL);
                    assertNotEquals(MemorySegment.NULL, targetStreamPointer,
                            "created output stream " + i);
                    MemorySegment targetStream = targetStreamPointer
                            .reinterpret(AVStream.layout().byteSize());

                    MemorySegment sourceParameters = AVStream.codecpar(sourceStream)
                            .reinterpret(AVCodecParameters.layout().byteSize());
                    MemorySegment targetParameters = AVStream.codecpar(targetStream)
                            .reinterpret(AVCodecParameters.layout().byteSize());
                    check(FFmpeg.avcodec_parameters_copy(targetParameters, sourceParameters),
                            "avcodec_parameters_copy");
                    AVCodecParameters.codec_tag(targetParameters, 0);
                    AVStream.time_base(targetStream, AVStream.time_base(sourceStream));
                    AVStream.sample_aspect_ratio(targetStream,
                            AVStream.sample_aspect_ratio(sourceStream));
                    AVStream.avg_frame_rate(targetStream, AVStream.avg_frame_rate(sourceStream));
                    AVStream.r_frame_rate(targetStream, AVStream.r_frame_rate(sourceStream));
                    AVStream.disposition(targetStream, AVStream.disposition(sourceStream));
                }

                MemorySegment outputPbPtr = outputContext.asSlice(
                        AVFormatContext.pb$offset(), ValueLayout.ADDRESS.byteSize());
                check(FFmpeg.avio_open2(outputPbPtr, arena.allocateFrom(output.toString()),
                                FFmpeg.AVIO_FLAG_WRITE(), MemorySegment.NULL, MemorySegment.NULL),
                        "avio_open2");
                outputIoOpen = true;
                check(FFmpeg.avformat_write_header(outputContext, MemorySegment.NULL),
                        "avformat_write_header");

                MemorySegment packet = FFmpeg.av_packet_alloc()
                        .reinterpret(AVPacket.layout().byteSize());
                MemorySegment packetPtr = addressSlot(arena);
                packetPtr.set(ValueLayout.ADDRESS, 0, packet);
                try {
                    while (FFmpeg.av_read_frame(inputContext, packet) >= 0) {
                        int index = AVPacket.stream_index(packet);
                        if (index >= 0 && index < streamCount) {
                            MemorySegment sourceStream = stream(inputContext, index);
                            MemorySegment targetStream = stream(outputContext, index);
                            FFmpeg.av_packet_rescale_ts(packet, AVStream.time_base(sourceStream),
                                    AVStream.time_base(targetStream));
                            AVPacket.stream_index(packet, index);
                            AVPacket.pos(packet, -1);
                            check(FFmpeg.av_interleaved_write_frame(outputContext, packet),
                                    "av_interleaved_write_frame");
                        }
                        FFmpeg.av_packet_unref(packet);
                    }
                    check(FFmpeg.av_write_trailer(outputContext), "av_write_trailer");
                } finally {
                    FFmpeg.av_packet_free(packetPtr);
                }
            } finally {
                if (!outputContext.equals(MemorySegment.NULL)) {
                    if (outputIoOpen) {
                        FFmpeg.avio_closep(outputContext.asSlice(
                                AVFormatContext.pb$offset(), ValueLayout.ADDRESS.byteSize()));
                    }
                    FFmpeg.avformat_free_context(outputContext);
                }
                FFmpeg.avformat_close_input(inputPtr);
            }
        }
    }

    private static List<String> packetDigests(Path path) throws Exception {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment contextPtr = addressSlot(arena);
            check(FFmpeg.avformat_open_input(contextPtr, arena.allocateFrom(path.toString()),
                    MemorySegment.NULL, MemorySegment.NULL), "avformat_open_input");
            MemorySegment context = pointedStruct(contextPtr, AVFormatContext.layout().byteSize());
            try {
                check(FFmpeg.avformat_find_stream_info(context, MemorySegment.NULL),
                        "avformat_find_stream_info");
                MemorySegment packet = FFmpeg.av_packet_alloc()
                        .reinterpret(AVPacket.layout().byteSize());
                MemorySegment packetPtr = addressSlot(arena);
                packetPtr.set(ValueLayout.ADDRESS, 0, packet);
                List<String> digests = new ArrayList<>();
                try {
                    while (FFmpeg.av_read_frame(context, packet) >= 0) {
                        int size = AVPacket.size(packet);
                        if (size > 0) {
                            byte[] payload = AVPacket.data(packet).reinterpret(size)
                                    .toArray(ValueLayout.JAVA_BYTE);
                            String digest = HexFormat.of().formatHex(
                                    MessageDigest.getInstance("SHA-256").digest(payload));
                            digests.add(AVPacket.stream_index(packet) + ":" + digest);
                        }
                        FFmpeg.av_packet_unref(packet);
                    }
                } finally {
                    FFmpeg.av_packet_free(packetPtr);
                }
                return List.copyOf(digests);
            } finally {
                FFmpeg.avformat_close_input(contextPtr);
            }
        }
    }

    private static MemorySegment stream(MemorySegment context, int index) {
        MemorySegment streams = AVFormatContext.streams(context)
                .reinterpret((index + 1L) * ValueLayout.ADDRESS.byteSize());
        return streams.getAtIndex(ValueLayout.ADDRESS, index)
                .reinterpret(AVStream.layout().byteSize());
    }

    private static MemorySegment addressSlot(Arena arena) {
        MemorySegment slot = arena.allocate(ValueLayout.ADDRESS);
        slot.set(ValueLayout.ADDRESS, 0, MemorySegment.NULL);
        return slot;
    }

    private static MemorySegment pointedStruct(MemorySegment slot, long size) {
        MemorySegment pointer = slot.get(ValueLayout.ADDRESS, 0);
        assertNotEquals(MemorySegment.NULL, pointer);
        return pointer.reinterpret(size);
    }

    private static void check(int error, String operation) {
        assertTrue(error >= 0, operation + " failed: " + error);
    }
}
