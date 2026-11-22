package dev.mbui;

import java.util.ArrayList;

/**
 * Coalesces back-to-back ACTION_MOVE batches queued from Android's UI thread before the app's logic thread drains
 * them, so a burst of moves cannot pile up into a FIFO backlog while keeping every sample (with kind 14 for all but
 * the very last sample, which uses kind 11) and strict ordering across non-move boundary events (seal).
 * Plain Java, no Android: android/touch/TouchMovesTest.java runs it on a plain JVM (scripts/touchmoves_test.sh).
 */
final class TouchMoves {
    interface Sink {
        void touch(int kind, int id, float x, float y, double t);
    }

    private static final class Batch {
        final int[] ids;
        final float[] xs, ys;
        final double[] ts;
        final int n, h;

        Batch(int[] ids, float[] xs, float[] ys, double[] ts, int n, int h) {
            this.ids = ids;
            this.xs = xs;
            this.ys = ys;
            this.ts = ts;
            this.n = n;
            this.h = h;
        }
    }

    static final class Bucket {
        final ArrayList<Batch> batches = new ArrayList<>();
    }

    private Bucket openBucket;

    /**
     * Appends a move batch to the currently open bucket if one is waiting in the logic queue (returning null: no new
     * runnable needed), or opens a new bucket (returning it so MBView posts one drain runnable).
     */
    synchronized Bucket enqueue(int[] ids, float[] xs, float[] ys, double[] ts, int n, int h) {
        if (n <= 0 || h < 0) return null;
        Batch b = new Batch(ids, xs, ys, ts, n, h);
        if (openBucket != null) {
            openBucket.batches.add(b);
            return null;
        }
        Bucket bucket = new Bucket();
        bucket.batches.add(b);
        openBucket = bucket;
        return bucket;
    }

    /**
     * Closes the open bucket so any subsequent move opens a fresh bucket after a non-move boundary event
     * (DOWN, POINTER_DOWN, UP, POINTER_UP, CANCEL).
     */
    synchronized void seal() {
        openBucket = null;
    }

    /**
     * Drains all coalesced batches in {@code bucket} on the logic thread, emitting every sample in chronological
     * order with kind 14 except the final sample of the final batch, which emits kind 11.
     */
    void drain(Bucket bucket, Sink sink) {
        ArrayList<Batch> batches;
        synchronized (this) {
            if (openBucket == bucket) {
                openBucket = null;
            }
            batches = new ArrayList<>(bucket.batches);
            bucket.batches.clear();
        }
        int lastBatch = batches.size() - 1;
        for (int bi = 0; bi <= lastBatch; bi++) {
            Batch b = batches.get(bi);
            int stride = b.h + 1;
            for (int k = 0; k <= b.h; k++) {
                for (int p = 0; p < b.n; p++) {
                    int kind = (bi == lastBatch && k == b.h && p == b.n - 1) ? 11 : 14;
                    sink.touch(kind, b.ids[p], b.xs[p * stride + k], b.ys[p * stride + k], b.ts[k]);
                }
            }
        }
    }
}
