package io.github.ghosthack.ffmpegffm;

import io.github.ghosthack.ffmpegffm.ffmpeg.AVPacket;
import org.junit.jupiter.api.Test;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class DecoderSupportTest {

    @Test
    void distinguishesPayloadFromFlushLikePackets() {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment packet = arena.allocate(AVPacket.layout());
            assertFalse(DecoderSupport.hasPayload(packet));
            AVPacket.size(packet, 42);
            assertTrue(DecoderSupport.hasPayload(packet));
            assertFalse(DecoderSupport.hasPayload(MemorySegment.NULL));
        }
    }

    @Test
    void rejectsJavaNullPacket() {
        assertThrows(NullPointerException.class,
                () -> DecoderSupport.hasPayload(null));
    }
}
