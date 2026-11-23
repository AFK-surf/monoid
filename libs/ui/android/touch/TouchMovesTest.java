package dev.mbui;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;

/**
 * Coalescing and ordering of Android ACTION_MOVE batches (TouchMoves): single batch with history, 20 consecutive moves
 * coalesced into one queued runnable, strict ordering across MOVE -> UP -> DOWN -> MOVE boundaries, fresh bucket after
 * drain, and multi-touch pointer ordering with 14/11 markers. Plain Java, no Android. Run: scripts/touchmoves_test.sh.
 */
public final class TouchMovesTest {
    private static int failed;

    private static void check(boolean ok, String what) {
        if (ok) return;
        failed++;
        StackTraceElement at = new Throwable().getStackTrace()[1];
        System.err.println("TouchMovesTest.java:" + at.getLineNumber() + ": failed: " + what);
    }

    private static String fmt(int kind, int id, float x, float y, double t) {
        return kind + ":" + id + "@" + (int) x + "," + (int) y + "@" + (int) t;
    }

    /** Single batch with historical samples emits 14 for all historical samples and 11 for the final sample. */
    static void singleBatchWithHistory() {
        TouchMoves tm = new TouchMoves();
        List<String> log = new ArrayList<>();
        TouchMoves.Bucket b = tm.enqueue(
                new int[] {7},
                new float[] {10f, 20f, 30f},
                new float[] {5f, 6f, 7f},
                new double[] {100.0, 104.0, 108.0},
                1,
                2);
        check(b != null, "first batch opens a bucket");
        tm.drain(b, (k, id, x, y, t) -> log.add(fmt(k, id, x, y, t)));
        check(log.equals(List.of("14:7@10,5@100", "14:7@20,6@104", "11:7@30,7@108")),
                "single batch history + current: " + log);
    }

    /** 20 consecutive MOVE events enqueue only 1 runnable and emit 19 kind-14 samples followed by 1 kind-11 sample. */
    static void twentyMovesCoalesce() {
        TouchMoves tm = new TouchMoves();
        ArrayDeque<Runnable> q = new ArrayDeque<>();
        List<String> log = new ArrayList<>();
        for (int i = 0; i < 20; i++) {
            TouchMoves.Bucket b = tm.enqueue(
                    new int[] {0},
                    new float[] {i * 10f},
                    new float[] {50f},
                    new double[] {1000.0 + i * 8.0},
                    1,
                    0);
            if (b != null) {
                q.add(() -> tm.drain(b, (k, id, x, y, t) -> log.add(fmt(k, id, x, y, t))));
            }
        }
        check(q.size() == 1, "20 moves should schedule exactly 1 runnable, got " + q.size());
        q.poll().run();
        check(log.size() == 20, "all 20 samples preserved, got " + log.size());
        for (int i = 0; i < 19; i++) {
            check(log.get(i).startsWith("14:0@" + (i * 10) + ",50@" + (1000 + i * 8)),
                    "sample " + i + " should be kind 14: " + log.get(i));
        }
        check(log.get(19).equals("11:0@190,50@1152"), "last sample should be kind 11: " + log.get(19));
    }

    /** MOVE -> UP -> DOWN -> MOVE never reorders: seal() isolates the second gesture's moves after UP and DOWN. */
    static void boundaryOrdering() {
        TouchMoves tm = new TouchMoves();
        ArrayDeque<Runnable> q = new ArrayDeque<>();
        List<String> log = new ArrayList<>();
        TouchMoves.Sink sink = (k, id, x, y, t) -> log.add(fmt(k, id, x, y, t));

        TouchMoves.Bucket b1 = tm.enqueue(new int[] {0}, new float[] {10f}, new float[] {0f}, new double[] {10.0}, 1, 0);
        if (b1 != null) q.add(() -> tm.drain(b1, sink));
        TouchMoves.Bucket b1b = tm.enqueue(new int[] {0}, new float[] {20f}, new float[] {0f}, new double[] {18.0}, 1, 0);
        check(b1b == null, "second move coalesces into b1");

        tm.seal();
        q.add(() -> sink.touch(12, 0, 20f, 0f, 22.0)); // UP
        tm.seal();
        q.add(() -> sink.touch(10, 0, 100f, 0f, 30.0)); // DOWN

        TouchMoves.Bucket b2 = tm.enqueue(new int[] {0}, new float[] {110f}, new float[] {0f}, new double[] {38.0}, 1, 0);
        check(b2 != null && b2 != b1, "move after seal opens new bucket");
        q.add(() -> tm.drain(b2, sink));

        check(q.size() == 4, "queue has [drain b1, UP, DOWN, drain b2], got " + q.size());
        while (!q.isEmpty()) q.poll().run();
        check(log.equals(List.of(
                "14:0@10,0@10",
                "11:0@20,0@18",
                "12:0@20,0@22",
                "10:0@100,0@30",
                "11:0@110,0@38")),
                "strict chronological order across boundaries: " + log);
    }

    /** After drain() completes, a new MOVE opens a fresh bucket. */
    static void newBucketAfterDrain() {
        TouchMoves tm = new TouchMoves();
        List<String> log = new ArrayList<>();
        TouchMoves.Sink sink = (k, id, x, y, t) -> log.add(fmt(k, id, x, y, t));

        TouchMoves.Bucket b1 = tm.enqueue(new int[] {1}, new float[] {5f}, new float[] {5f}, new double[] {1.0}, 1, 0);
        check(b1 != null, "b1 opened");
        tm.drain(b1, sink);

        TouchMoves.Bucket b2 = tm.enqueue(new int[] {1}, new float[] {15f}, new float[] {5f}, new double[] {9.0}, 1, 0);
        check(b2 != null && b2 != b1, "b2 opened after b1 drained");
        tm.drain(b2, sink);

        check(log.equals(List.of("11:1@5,5@1", "11:1@15,5@9")), "two independent drains: " + log);
    }

    /** Multi-touch with history and coalesced batches preserves (sample k, pointer p) order and single trailing 11. */
    static void multiTouchOrdering() {
        TouchMoves tm = new TouchMoves();
        List<String> log = new ArrayList<>();
        // Batch 1: 2 pointers (id 10, 20), h=1 (2 timestamps: 100, 105)
        TouchMoves.Bucket b1 = tm.enqueue(
                new int[] {10, 20},
                new float[] {1f, 2f, 101f, 102f},
                new float[] {10f, 20f, 110f, 120f},
                new double[] {100.0, 105.0},
                2,
                1);
        check(b1 != null, "batch 1 opens bucket");
        // Batch 2: 2 pointers (id 10, 20), h=0 (1 timestamp: 110)
        TouchMoves.Bucket b2 = tm.enqueue(
                new int[] {10, 20},
                new float[] {3f, 103f},
                new float[] {30f, 130f},
                new double[] {110.0},
                2,
                0);
        check(b2 == null, "batch 2 coalesces into batch 1's bucket");
        tm.drain(b1, (k, id, x, y, t) -> log.add(fmt(k, id, x, y, t)));
        check(log.equals(List.of(
                "14:10@1,10@100",
                "14:20@101,110@100",
                "14:10@2,20@105",
                "14:20@102,120@105",
                "14:10@3,30@110",
                "11:20@103,130@110")),
                "multi-touch order and 14/11 markers: " + log);
    }

    public static void main(String[] args) {
        singleBatchWithHistory();
        twentyMovesCoalesce();
        boundaryOrdering();
        newBucketAfterDrain();
        multiTouchOrdering();
        if (failed > 0) {
            System.err.println("TouchMovesTest: " + failed + " failed");
            System.exit(1);
        }
        System.out.println("TouchMovesTest: ok");
    }
}
