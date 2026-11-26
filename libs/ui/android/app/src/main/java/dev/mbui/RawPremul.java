package dev.mbui;

/**
 * Pure Java helpers for the MBRAWPRE premultiplied RGBA8888 binary wire format.
 * Kept free of Android SDK dependencies so it can be compiled and tested directly on any JVM.
 */
final class RawPremul {
    static final int HEADER_BYTES = 16;
    static final int MAX_DIM = 16384;

    private RawPremul() {}

    static boolean isRawPremul(byte[] data) {
        return data != null && data.length >= 8
                && data[0] == 'M' && data[1] == 'B' && data[2] == 'R' && data[3] == 'A'
                && data[4] == 'W' && data[5] == 'P' && data[6] == 'R' && data[7] == 'E';
    }

    static int[] parseRawPremulHeader(byte[] data) {
        if (!isRawPremul(data) || data.length < HEADER_BYTES) return null;
        long w = (data[8] & 0xFFL) | ((data[9] & 0xFFL) << 8)
                | ((data[10] & 0xFFL) << 16) | ((data[11] & 0xFFL) << 24);
        long h = (data[12] & 0xFFL) | ((data[13] & 0xFFL) << 8)
                | ((data[14] & 0xFFL) << 16) | ((data[15] & 0xFFL) << 24);
        if (w <= 0 || h <= 0 || w > MAX_DIM || h > MAX_DIM) return null;
        if (w * h * 4L != (long) (data.length - HEADER_BYTES)) return null;
        return new int[]{(int) w, (int) h};
    }

    static int[] targetSize(int w, int h, int maxPx) {
        if (maxPx <= 0 || (w <= maxPx && h <= maxPx)) return new int[]{w, h};
        double k = (double) maxPx / (double) Math.max(w, h);
        int tw = Math.max(1, Math.min(maxPx, (int) Math.round(w * k)));
        int th = Math.max(1, Math.min(maxPx, (int) Math.round(h * k)));
        return new int[]{tw, th};
    }
}
