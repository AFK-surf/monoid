package dev.mbui;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** Plain-JVM unit tests for {@link RawPremul}. */
public final class RawPremulTest {
    private static void check(boolean cond, String msg) {
        if (!cond) throw new AssertionError(msg);
    }

    private static byte[] makeBuf(int w, int h, int payloadLen) {
        byte[] b = new byte[16 + payloadLen];
        byte[] magic = {'M', 'B', 'R', 'A', 'W', 'P', 'R', 'E'};
        System.arraycopy(magic, 0, b, 0, 8);
        ByteBuffer.wrap(b, 8, 8).order(ByteOrder.LITTLE_ENDIAN).putInt(w).putInt(h);
        return b;
    }

    public static void main(String[] args) {
        // Non-magic inputs
        check(!RawPremul.isRawPremul(null), "null");
        check(!RawPremul.isRawPremul(new byte[0]), "empty");
        check(!RawPremul.isRawPremul(new byte[]{(byte) 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a}), "png");
        check(!RawPremul.isRawPremul(new byte[]{'M', 'B', 'R', 'A', 'W', 'P', 'R'}), "short magic");

        // Valid payload
        byte[] ok = makeBuf(4, 2, 4 * 2 * 4);
        check(RawPremul.isRawPremul(ok), "valid magic");
        int[] dims = RawPremul.parseRawPremulHeader(ok);
        check(dims != null && dims[0] == 4 && dims[1] == 2, "valid dims");

        // Truncated header (< 16 bytes)
        byte[] truncHdr = {'M', 'B', 'R', 'A', 'W', 'P', 'R', 'E', 1, 0, 0};
        check(RawPremul.isRawPremul(truncHdr), "trunc hdr magic");
        check(RawPremul.parseRawPremulHeader(truncHdr) == null, "trunc hdr rejected");

        // Truncated pixel payload
        check(RawPremul.parseRawPremulHeader(makeBuf(2, 2, 12)) == null, "trunc pixels rejected");

        // Zero dimensions
        check(RawPremul.parseRawPremulHeader(makeBuf(0, 2, 0)) == null, "0 width rejected");
        check(RawPremul.parseRawPremulHeader(makeBuf(2, 0, 0)) == null, "0 height rejected");

        // Exceeds 16384 limit
        check(RawPremul.parseRawPremulHeader(makeBuf(16385, 1, 16385 * 4)) == null, ">16384 rejected");
        check(RawPremul.parseRawPremulHeader(makeBuf(1, 16385, 16385 * 4)) == null, ">16384 h rejected");

        // uint32 overflow (65536 * 65536 * 4 wraps to 0 in 32-bit math) & signed negative uint32
        check(RawPremul.parseRawPremulHeader(makeBuf(65536, 65536, 0)) == null, "uint32 overflow rejected");
        check(RawPremul.parseRawPremulHeader(makeBuf(-1, 1, 0)) == null, "negative uint32 rejected");

        // Trailing extra byte
        check(RawPremul.parseRawPremulHeader(makeBuf(1, 1, 5)) == null, "trailing byte rejected");

        // targetSize clamping & aspect preservation
        int[] s0 = RawPremul.targetSize(100, 300, 512);
        check(s0[0] == 100 && s0[1] == 300, "no upscale");
        int[] s1 = RawPremul.targetSize(1000, 3000, 512);
        check(s1[0] == 171 && s1[1] == 512, "portrait 512");
        int[] s2 = RawPremul.targetSize(4096, 2048, 2048);
        check(s2[0] == 2048 && s2[1] == 1024, "landscape 2048");
        int[] s3 = RawPremul.targetSize(1, 16000, 64);
        check(s3[0] == 1 && s3[1] == 64, "extreme aspect clamp");
        int[] s4 = RawPremul.targetSize(200, 100, 0);
        check(s4[0] == 200 && s4[1] == 100, "maxPx<=0 passthrough");

        System.out.println("RawPremulTest: OK");
    }
}
