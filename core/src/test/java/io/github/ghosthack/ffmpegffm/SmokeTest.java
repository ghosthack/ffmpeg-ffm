package io.github.ghosthack.ffmpegffm;

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
 * End-to-end proof that the bundled natives extract, load, and decode: opens the
 * committed H.264 fixture, decodes the first video frame, and checks its content.
 */
class SmokeTest {

    @Test
    void bundledNativesReportExpectedVersion() {
        int version = FFmpeg.avformat_version();
        assertEquals(62, version >> 16, "avformat major for FFmpeg 8.x");
    }

    @Test
    void decodesFirstFrameOfFixture() throws Exception {
        Path fixture = Files.createTempFile("ffmpeg-ffm-sample", ".mp4");
        try (var in = Objects.requireNonNull(getClass().getResourceAsStream("/sample.mp4"))) {
            Files.copy(in, fixture, java.nio.file.StandardCopyOption.REPLACE_EXISTING);
        }
        FFmpeg.av_log_set_level(FFmpeg.AV_LOG_ERROR());

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment ctxPtr = arena.allocate(ValueLayout.ADDRESS);
            check(FFmpeg.avformat_open_input(ctxPtr, arena.allocateFrom(fixture.toString()),
                    MemorySegment.NULL, MemorySegment.NULL), "avformat_open_input");
            MemorySegment ctx = ctxPtr.get(ValueLayout.ADDRESS, 0)
                    .reinterpret(AVFormatContext.layout().byteSize());
            try {
                check(FFmpeg.avformat_find_stream_info(ctx, MemorySegment.NULL), "find_stream_info");
                int streamIdx = FFmpeg.av_find_best_stream(ctx, FFmpeg.AVMEDIA_TYPE_VIDEO(),
                        -1, -1, MemorySegment.NULL, 0);
                assertTrue(streamIdx >= 0, "video stream present");

                MemorySegment streams = AVFormatContext.streams(ctx)
                        .reinterpret((streamIdx + 1L) * ValueLayout.ADDRESS.byteSize());
                MemorySegment stream = streams.getAtIndex(ValueLayout.ADDRESS, streamIdx)
                        .reinterpret(AVStream.layout().byteSize());
                MemorySegment par = AVStream.codecpar(stream)
                        .reinterpret(AVCodecParameters.layout().byteSize());
                assertEquals(64, AVCodecParameters.width(par));
                assertEquals(64, AVCodecParameters.height(par));

                MemorySegment decoder = FFmpeg.avcodec_find_decoder(AVCodecParameters.codec_id(par));
                assertNotEquals(MemorySegment.NULL, decoder, "h264 decoder available");
                MemorySegment cctx = FFmpeg.avcodec_alloc_context3(decoder);
                MemorySegment cctxPtr = arena.allocate(ValueLayout.ADDRESS);
                cctxPtr.set(ValueLayout.ADDRESS, 0, cctx);
                try {
                    check(FFmpeg.avcodec_parameters_to_context(cctx, par), "parameters_to_context");
                    check(FFmpeg.avcodec_open2(cctx, decoder, MemorySegment.NULL), "avcodec_open2");

                    MemorySegment pkt = FFmpeg.av_packet_alloc().reinterpret(AVPacket.layout().byteSize());
                    MemorySegment frame = FFmpeg.av_frame_alloc().reinterpret(AVFrame.layout().byteSize());
                    MemorySegment pktPtr = arena.allocate(ValueLayout.ADDRESS);
                    MemorySegment framePtr = arena.allocate(ValueLayout.ADDRESS);
                    pktPtr.set(ValueLayout.ADDRESS, 0, pkt);
                    framePtr.set(ValueLayout.ADDRESS, 0, frame);
                    try {
                        boolean decoded = false;
                        while (!decoded && FFmpeg.av_read_frame(ctx, pkt) >= 0) {
                            if (AVPacket.stream_index(pkt) == streamIdx) {
                                check(FFmpeg.avcodec_send_packet(cctx, pkt), "send_packet");
                                decoded = FFmpeg.avcodec_receive_frame(cctx, frame) == 0;
                            }
                            FFmpeg.av_packet_unref(pkt);
                        }
                        assertTrue(decoded, "decoded a video frame");
                        assertEquals(64, AVFrame.width(frame));
                        assertEquals(64, AVFrame.height(frame));

                        // Read data/linesize via the field-slice accessors: the jextract-22
                        // indexed accessors resolve relative to the field layout, not the
                        // struct, so they misread any field that is not at offset 0.
                        int linesize0 = AVFrame.linesize(frame).getAtIndex(ValueLayout.JAVA_INT, 0);
                        MemorySegment data0 = AVFrame.data(frame).getAtIndex(ValueLayout.ADDRESS, 0);
                        assertTrue(linesize0 >= 64, "plausible luma stride: " + linesize0);
                        MemorySegment luma = data0.reinterpret((long) linesize0 * AVFrame.height(frame));
                        boolean hasContent = false;
                        for (long i = 0; i < luma.byteSize() && !hasContent; i++) {
                            hasContent = luma.get(ValueLayout.JAVA_BYTE, i) != 0;
                        }
                        assertTrue(hasContent, "decoded frame has non-zero luma content");

                        // swscale link check: create + free a scaler context.
                        MemorySegment sws = FFmpeg.sws_getContext(64, 64, AVFrame.format(frame),
                                64, 64, FFmpeg.AV_PIX_FMT_BGRA(), FFmpeg.SWS_BILINEAR(),
                                MemorySegment.NULL, MemorySegment.NULL, MemorySegment.NULL);
                        assertNotEquals(MemorySegment.NULL, sws, "sws context");
                        FFmpeg.sws_freeContext(sws);
                    } finally {
                        FFmpeg.av_frame_free(framePtr);
                        FFmpeg.av_packet_free(pktPtr);
                    }
                } finally {
                    FFmpeg.avcodec_free_context(cctxPtr);
                }
            } finally {
                FFmpeg.avformat_close_input(ctxPtr);
            }
        } finally {
            Files.deleteIfExists(fixture);
        }
    }

    private static void check(int err, String what) {
        assertTrue(err >= 0, what + " failed: " + err);
    }
}
