package io.github.ghosthack.ffmpegffm;

import io.github.ghosthack.ffmpegffm.ffmpeg.FFmpeg;
import org.junit.jupiter.api.Test;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Exercises the swscale colourspace API: a BT.709 limited-range YUV420P frame of
 * solid patches is converted to BGRA once with a bare {@code sws_getContext} and
 * once after {@code sws_setColorspaceDetails(SWS_CS_ITU709)}.
 *
 * <p>The bare context decodes with swscale's default BT.601 matrix, so saturated
 * BT.709 content comes out colour-shifted; telling swscale the source matrix
 * restores the original RGB. Neutral grey is matrix-independent and must match
 * in both. Expected values are computed from the exact YUV bytes in the frame.
 */
class SwscaleColorspaceTest {

    private static final int PATCH = 16;
    /** Source RGB of each patch, 0..255. */
    private static final int[][] PATCH_RGB = {
            {220, 40, 40},   // red
            {40, 200, 60},   // green
            {40, 60, 210},   // blue
            {128, 128, 128}, // grey (matrix-independent)
            {224, 172, 140}, // skin tone
    };
    private static final String[] PATCH_NAMES = {"red", "green", "blue", "grey", "skin"};
    private static final int W = PATCH * PATCH_RGB.length;
    private static final int H = PATCH;
    /** Tolerance, per channel, for swscale's fixed-point/SIMD rounding. */
    private static final int TOL = 2;

    private static final double[] BT709 = {0.2126, 0.0722};
    private static final double[] BT601 = {0.299, 0.114};

    @Test
    void coefficientTablesDifferBetweenMatrices() {
        int[] t709 = coefficients(FFmpeg.SWS_CS_ITU709());
        int[] t601 = coefficients(FFmpeg.SWS_CS_ITU601());
        assertArrayEquals(t601, coefficients(FFmpeg.SWS_CS_DEFAULT()), "default is BT.601");
        assertNotEquals(t709[0], t601[0], "BT.709 and BT.601 Cr->R coefficients differ");
        // sws_getCoefficients indexes its table by AVColorSpace value, so a consumer
        // can pass AVFrame.colorspace straight through. Note the SWS_CS_* names are
        // not a 1:1 renumbering: SWS_CS_SMPTE170M is 5 while AVCOL_SPC_SMPTE170M is 6,
        // and both indices hold the BT.601 matrix.
        assertArrayEquals(t709, coefficients(FFmpeg.AVCOL_SPC_BT709()));
        assertArrayEquals(t601, coefficients(FFmpeg.AVCOL_SPC_BT470BG()));
        assertArrayEquals(t601, coefficients(FFmpeg.AVCOL_SPC_SMPTE170M()));
        assertArrayEquals(coefficients(FFmpeg.SWS_CS_SMPTE240M()), coefficients(FFmpeg.AVCOL_SPC_SMPTE240M()));
        assertArrayEquals(coefficients(FFmpeg.SWS_CS_BT2020()), coefficients(FFmpeg.AVCOL_SPC_BT2020_NCL()));
        // Unspecified falls back to BT.601: callers must pick their own default for HD.
        assertArrayEquals(t601, coefficients(FFmpeg.AVCOL_SPC_UNSPECIFIED()));
    }

    @Test
    void bt709SourceNeedsColorspaceDetails() {
        int[][] yuv = new int[PATCH_RGB.length][];
        int[][] want709 = new int[PATCH_RGB.length][];
        int[][] want601 = new int[PATCH_RGB.length][];
        for (int i = 0; i < PATCH_RGB.length; i++) {
            yuv[i] = encodeLimited(PATCH_RGB[i], BT709);
            want709[i] = decodeLimited(yuv[i], BT709);
            want601[i] = decodeLimited(yuv[i], BT601);
        }

        int[][] bare = convert(yuv, false);
        int[][] tagged = convert(yuv, true);

        StringBuilder report = new StringBuilder(
                "patch  Y,Cb,Cr      | expect709 RGB | bare RGB      | +709 RGB      | expect601 RGB\n");
        for (int i = 0; i < PATCH_RGB.length; i++) {
            report.append(String.format("%-6s %-12s | %-13s | %-13s | %-13s | %s%n", PATCH_NAMES[i],
                    triple(yuv[i]), triple(want709[i]), triple(bare[i]), triple(tagged[i]),
                    triple(want601[i])));
        }
        System.out.print(report);

        for (int i = 0; i < PATCH_RGB.length; i++) {
            assertClose(want709[i], tagged[i], PATCH_NAMES[i] + " with BT.709 set\n" + report);
            assertClose(want601[i], bare[i], PATCH_NAMES[i] + " with bare context (BT.601)\n" + report);
        }
        // Grey has Cb=Cr=128, so the matrix cannot affect it: proves range handling is equal.
        assertArrayEquals(bare[3], tagged[3], "grey identical in both paths");
        // The premise: for chroma-bearing patches the bare path is visibly wrong.
        int maxDelta = 0;
        for (int i = 0; i < PATCH_RGB.length; i++) {
            for (int c = 0; c < 3; c++) {
                maxDelta = Math.max(maxDelta, Math.abs(bare[i][c] - tagged[i][c]));
            }
        }
        assertTrue(maxDelta > 10, "bare vs BT.709 outputs differ materially, max delta " + maxDelta);
    }

    /** Converts the patch frame to BGRA and returns the RGB of each patch's centre pixel. */
    private static int[][] convert(int[][] yuv, boolean setBt709) {
        int strideY = align(W, 64);
        int strideC = align(W / 2, 64);
        int strideRgb = W * 4;
        try (Arena arena = Arena.ofConfined()) {
            int pad = FFmpeg.AV_INPUT_BUFFER_PADDING_SIZE();
            MemorySegment y = arena.allocate((long) strideY * H + pad, 64);
            MemorySegment u = arena.allocate((long) strideC * (H / 2) + pad, 64);
            MemorySegment v = arena.allocate((long) strideC * (H / 2) + pad, 64);
            for (int p = 0; p < yuv.length; p++) {
                for (int row = 0; row < H; row++) {
                    for (int col = p * PATCH; col < (p + 1) * PATCH; col++) {
                        y.set(ValueLayout.JAVA_BYTE, (long) row * strideY + col, (byte) yuv[p][0]);
                        if (row % 2 == 0 && col % 2 == 0) {
                            long off = (long) (row / 2) * strideC + col / 2;
                            u.set(ValueLayout.JAVA_BYTE, off, (byte) yuv[p][1]);
                            v.set(ValueLayout.JAVA_BYTE, off, (byte) yuv[p][2]);
                        }
                    }
                }
            }
            MemorySegment rgb = arena.allocate((long) strideRgb * H + pad, 64);

            MemorySegment src = arena.allocate(ValueLayout.ADDRESS, 4);
            src.setAtIndex(ValueLayout.ADDRESS, 0, y);
            src.setAtIndex(ValueLayout.ADDRESS, 1, u);
            src.setAtIndex(ValueLayout.ADDRESS, 2, v);
            MemorySegment srcStride = arena.allocateFrom(ValueLayout.JAVA_INT, strideY, strideC, strideC, 0);
            MemorySegment dst = arena.allocate(ValueLayout.ADDRESS, 4);
            dst.setAtIndex(ValueLayout.ADDRESS, 0, rgb);
            MemorySegment dstStride = arena.allocateFrom(ValueLayout.JAVA_INT, strideRgb, 0, 0, 0);

            MemorySegment sws = FFmpeg.sws_getContext(W, H, FFmpeg.AV_PIX_FMT_YUV420P(),
                    W, H, FFmpeg.AV_PIX_FMT_BGRA(), FFmpeg.SWS_BILINEAR(),
                    MemorySegment.NULL, MemorySegment.NULL, MemorySegment.NULL);
            assertNotEquals(MemorySegment.NULL, sws, "sws_getContext");
            try {
                if (setBt709) {
                    setSourceColorspace(arena, sws, FFmpeg.SWS_CS_ITU709(), false);
                }
                int rows = FFmpeg.sws_scale(sws, src, srcStride, 0, H, dst, dstStride);
                assertEquals(H, rows, "sws_scale output rows");
            } finally {
                FFmpeg.sws_freeContext(sws);
            }

            int[][] out = new int[yuv.length][];
            for (int p = 0; p < yuv.length; p++) {
                long off = (long) (H / 2) * strideRgb + (long) (p * PATCH + PATCH / 2) * 4;
                int b = Byte.toUnsignedInt(rgb.get(ValueLayout.JAVA_BYTE, off));
                int g = Byte.toUnsignedInt(rgb.get(ValueLayout.JAVA_BYTE, off + 1));
                int r = Byte.toUnsignedInt(rgb.get(ValueLayout.JAVA_BYTE, off + 2));
                int a = Byte.toUnsignedInt(rgb.get(ValueLayout.JAVA_BYTE, off + 3));
                assertEquals(255, a, "opaque alpha");
                out[p] = new int[]{r, g, b};
            }
            return out;
        }
    }

    /**
     * The consumer pattern: read the context's current details, replace only the
     * source matrix and range, write them back, and verify the read-back.
     */
    private static void setSourceColorspace(Arena arena, MemorySegment sws, int swsCs, boolean fullRange) {
        MemorySegment invTablePtr = arena.allocate(ValueLayout.ADDRESS);
        MemorySegment srcRange = arena.allocate(ValueLayout.JAVA_INT);
        MemorySegment tablePtr = arena.allocate(ValueLayout.ADDRESS);
        MemorySegment dstRange = arena.allocate(ValueLayout.JAVA_INT);
        MemorySegment brightness = arena.allocate(ValueLayout.JAVA_INT);
        MemorySegment contrast = arena.allocate(ValueLayout.JAVA_INT);
        MemorySegment saturation = arena.allocate(ValueLayout.JAVA_INT);
        assertTrue(FFmpeg.sws_getColorspaceDetails(sws, invTablePtr, srcRange, tablePtr, dstRange,
                brightness, contrast, saturation) >= 0, "sws_getColorspaceDetails");
        assertEquals(0, srcRange.get(ValueLayout.JAVA_INT, 0), "yuv420p defaults to limited range");

        MemorySegment invTable = FFmpeg.sws_getCoefficients(swsCs);
        int ret = FFmpeg.sws_setColorspaceDetails(sws, invTable, fullRange ? 1 : 0,
                tablePtr.get(ValueLayout.ADDRESS, 0), dstRange.get(ValueLayout.JAVA_INT, 0),
                brightness.get(ValueLayout.JAVA_INT, 0), contrast.get(ValueLayout.JAVA_INT, 0),
                saturation.get(ValueLayout.JAVA_INT, 0));
        assertTrue(ret >= 0, "sws_setColorspaceDetails failed: " + ret);

        assertTrue(FFmpeg.sws_getColorspaceDetails(sws, invTablePtr, srcRange, tablePtr, dstRange,
                brightness, contrast, saturation) >= 0, "sws_getColorspaceDetails after set");
        int[] readBack = invTablePtr.get(ValueLayout.ADDRESS, 0).reinterpret(16)
                .toArray(ValueLayout.JAVA_INT);
        assertArrayEquals(coefficients(swsCs), readBack, "inv_table read-back");
        assertEquals(fullRange ? 1 : 0, srcRange.get(ValueLayout.JAVA_INT, 0), "srcRange read-back");
    }

    private static int[] coefficients(int swsCs) {
        return FFmpeg.sws_getCoefficients(swsCs).reinterpret(16).toArray(ValueLayout.JAVA_INT);
    }

    /** RGB (0..255) -> limited-range Y'CbCr bytes with the given (Kr, Kb). */
    private static int[] encodeLimited(int[] rgb, double[] k) {
        double kr = k[0], kb = k[1], kg = 1 - kr - kb;
        double r = rgb[0] / 255.0, g = rgb[1] / 255.0, b = rgb[2] / 255.0;
        double yy = kr * r + kg * g + kb * b;
        double cb = (b - yy) / (2 * (1 - kb));
        double cr = (r - yy) / (2 * (1 - kr));
        return new int[]{clamp8(Math.round(16 + 219 * yy)), clamp8(Math.round(128 + 224 * cb)),
                clamp8(Math.round(128 + 224 * cr))};
    }

    /** Limited-range Y'CbCr bytes -> RGB (0..255, clamped) with the given (Kr, Kb). */
    private static int[] decodeLimited(int[] yuv, double[] k) {
        double kr = k[0], kb = k[1], kg = 1 - kr - kb;
        double yy = (yuv[0] - 16) / 219.0;
        double cb = (yuv[1] - 128) / 224.0;
        double cr = (yuv[2] - 128) / 224.0;
        double r = yy + 2 * (1 - kr) * cr;
        double b = yy + 2 * (1 - kb) * cb;
        double g = (yy - kr * r - kb * b) / kg;
        return new int[]{clamp8(Math.round(r * 255)), clamp8(Math.round(g * 255)), clamp8(Math.round(b * 255))};
    }

    private static void assertClose(int[] want, int[] got, String what) {
        for (int c = 0; c < 3; c++) {
            assertTrue(Math.abs(want[c] - got[c]) <= TOL,
                    what + ": channel " + "RGB".charAt(c) + " want " + want[c] + " got " + got[c]);
        }
    }

    private static int clamp8(long v) {
        return (int) Math.max(0, Math.min(255, v));
    }

    private static int align(int v, int a) {
        return (v + a - 1) / a * a;
    }

    private static String triple(int[] t) {
        return t[0] + "," + t[1] + "," + t[2];
    }
}
