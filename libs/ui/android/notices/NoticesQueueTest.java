package dev.mbui;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Deterministic unit tests for {@link NoticesQueue} (plain Java, no Android).
 * Run: sh libs/ui/scripts/noticesqueue_test.sh
 */
public final class NoticesQueueTest {
    private static int failures;

    private static void check(String what, boolean ok, String detail) {
        System.out.println((ok ? "ok   " : "FAIL ") + what + (detail.isEmpty() ? "" : ": " + detail));
        if (!ok) failures++;
    }

    private static void awaitUnbounded(CountDownLatch latch) {
        boolean interrupted = false;
        while (true) {
            try {
                latch.await();
                break;
            } catch (InterruptedException e) {
                interrupted = true;
            }
        }
        if (interrupted) Thread.currentThread().interrupt();
    }

    private static class FakeOps implements NoticesQueue.Ops {
        final List<String> log = Collections.synchronizedList(new ArrayList<>());
        volatile boolean ensureResult = true;
        volatile boolean throwOnEnsure;
        volatile boolean throwOnShow;
        volatile boolean throwOnCancel;
        volatile boolean throwOnRead;
        volatile boolean throwOnDrive;
        volatile int permValue = NoticesQueue.PERM_GRANTED;
        volatile int driveValue = 1;
        final AtomicInteger frameRequests = new AtomicInteger();
        volatile Runnable onShowHook;
        volatile Runnable onReadHook;
        volatile Runnable onDriveHook;

        @Override
        public boolean ensureChannel(Object ctx, String channel, boolean onlyIfMissing) {
            log.add("ensure:" + channel + ":" + onlyIfMissing);
            if (throwOnEnsure) throw new RuntimeException("ensure boom");
            return ensureResult;
        }

        @Override
        public void show(Object ctx, String tag, String title, String body, String opens) {
            log.add("show:" + tag + ":" + title);
            Runnable hook = onShowHook;
            if (hook != null) hook.run();
            if (throwOnShow) throw new RuntimeException("show boom");
        }

        @Override
        public void cancel(Object ctx, String tag) {
            log.add("cancel:" + tag);
            if (throwOnCancel) throw new RuntimeException("cancel boom");
        }

        @Override
        public int readPermission(Object ctx) {
            int v = permValue;
            boolean shouldThrow = throwOnRead;
            log.add("read:" + ctx + "=" + v);
            Runnable hook = onReadHook;
            if (hook != null) hook.run();
            if (shouldThrow) throw new RuntimeException("read boom");
            return v;
        }

        @Override
        public void requestFrame() {
            frameRequests.incrementAndGet();
            log.add("frame");
        }

        @Override
        public int drive(Object ctx, boolean tap, String words) {
            log.add("drive:" + tap + ":" + words);
            Runnable hook = onDriveHook;
            if (hook != null) hook.run();
            if (throwOnDrive) throw new RuntimeException("drive boom");
            return driveValue;
        }
    }

    /** 1. Strict FIFO ordering with in-flight show -> same-tag cancel -> external show -> cancel. */
    private static void fifoOrderingWithInFlightShowCase() throws Exception {
        FakeOps ops = new FakeOps();
        CountDownLatch showEntered = new CountDownLatch(1);
        CountDownLatch releaseShow = new CountDownLatch(1);
        AtomicBoolean firstShow = new AtomicBoolean(true);
        ops.onShowHook = () -> {
            if (firstShow.compareAndSet(true, false)) {
                showEntered.countDown();
                awaitUnbounded(releaseShow);
            }
        };
        AtomicBoolean workerStartedHookCalled = new AtomicBoolean();
        NoticesQueue q = new NoticesQueue(ops, true, () -> workerStartedHookCalled.set(true));
        Object ctx = "ctx";

        q.enqueueShow(ctx, "Messages", "chat1", "T1", "B1", "O1");
        boolean entered = showEntered.await(5, TimeUnit.SECONDS);
        if (!entered) {
            releaseShow.countDown();
            check("FIFO order across in-flight show -> cancel -> external show -> cancel -> drive", false, "show never entered");
            return;
        }
        q.enqueueCancel(ctx, "chat1");
        CountDownLatch extDone = new CountDownLatch(1);
        q.enqueueExternalShow(ctx, "Default", "chat1", "T2", "B2", "O2", extDone::countDown);
        q.enqueueCancel(ctx, "chat1");
        releaseShow.countDown();
        boolean done = extDone.await(5, TimeUnit.SECONDS);
        int driveRes = q.drive(ctx, false, "none", 5000L);

        List<String> expected = List.of(
                "ensure:Messages:false",
                "show:chat1:T1",
                "cancel:chat1",
                "ensure:Default:true",
                "show:chat1:T2",
                "cancel:chat1",
                "drive:false:none");
        check("FIFO order across in-flight show -> cancel -> external show -> cancel -> drive",
                done && workerStartedHookCalled.get() && driveRes == 1 && ops.log.equals(expected),
                "log=" + ops.log);
    }

    /** 2. Deterministic zero-wait external show timeout (autoStart=false, timeoutMs=0) + cancel order + onDone once on success & exception. */
    private static void externalShowTimeoutAndOnDoneCase() {
        FakeOps ops = new FakeOps();
        NoticesQueue q = new NoticesQueue(ops, false, null);
        Object ctx = "ctx";

        q.enqueueShow(ctx, "Msg", "blocker", "B", "B", "");
        boolean timedOut = !q.showExternalAwait(ctx, "消息", "ext1", "Ext", "Body", "", 0L);
        q.enqueueCancel(ctx, "ext1");
        int drained = q.drainInline();

        long extShows = ops.log.stream().filter(s -> s.equals("show:ext1:Ext")).count();
        int extIdx = ops.log.indexOf("show:ext1:Ext");
        int cancelIdx = ops.log.indexOf("cancel:ext1");

        FakeOps inlineOps = new FakeOps();
        NoticesQueue iq = new NoticesQueue(inlineOps, false, null);
        AtomicInteger okCount = new AtomicInteger();
        iq.enqueueExternalShow(ctx, "消息", "t1", "A", "B", "", okCount::incrementAndGet);
        AtomicInteger errCount = new AtomicInteger();
        iq.enqueueExternalShow(ctx, "消息", "t2", "A", "B", "", () -> {
            errCount.incrementAndGet();
            throw new RuntimeException("onDone boom");
        });
        iq.enqueueCancel(ctx, "after-boom");
        iq.stepOne();
        inlineOps.throwOnShow = true;
        iq.stepOne();
        inlineOps.throwOnShow = false;
        iq.stepOne();

        check("external show deterministic 0ms timeout does not duplicate and preserves cancel order; onDone runs once on success & exception",
                timedOut && drained == 3 && extShows == 1 && extIdx >= 0 && cancelIdx > extIdx
                        && okCount.get() == 1 && errCount.get() == 1
                        && inlineOps.log.contains("cancel:after-boom"),
                "timedOut=" + timedOut + ", drained=" + drained + ", extShows=" + extShows
                        + ", okCount=" + okCount.get() + ", errCount=" + errCount.get());
    }

    /** 3. Channel cache: external onlyIfMissing never pollutes lastChannelName; rename works; failure/exception retries. */
    private static void channelCacheCase() {
        FakeOps ops = new FakeOps();
        NoticesQueue q = new NoticesQueue(ops, false, null);
        Object ctx = "ctx";

        q.enqueueExternalShow(ctx, "消息", "t0", "Ext", "B", "", null);
        q.drainInline();
        q.enqueueShow(ctx, "消息", "t1", "Fg1", "B", "");
        q.drainInline();
        q.enqueueShow(ctx, "消息", "t2", "Fg2", "B", "");
        q.drainInline();
        q.enqueueShow(ctx, "Messages", "t3", "Fg3", "B", "");
        q.drainInline();
        q.enqueueExternalShow(ctx, "消息", "t4", "Ext2", "B", "", null);
        q.drainInline();
        q.enqueueShow(ctx, "Messages", "t5", "Fg4", "B", "");
        q.drainInline();

        ops.ensureResult = false;
        q.enqueueShow(ctx, "Deutsch", "t6", "Fg5", "B", "");
        q.drainInline();
        ops.ensureResult = true;
        q.enqueueShow(ctx, "Deutsch", "t7", "Fg6", "B", "");
        q.drainInline();

        ops.throwOnEnsure = true;
        q.enqueueShow(ctx, "日本語", "t8", "Fg7", "B", "");
        q.drainInline();
        ops.throwOnEnsure = false;
        q.enqueueShow(ctx, "日本語", "t9", "Fg8", "B", "");
        q.drainInline();

        List<String> ensures = new ArrayList<>();
        for (String s : ops.log) if (s.startsWith("ensure:")) ensures.add(s);
        List<String> expected = List.of(
                "ensure:消息:true",
                "ensure:消息:false",
                "ensure:Messages:false",
                "ensure:消息:true",
                "ensure:Deutsch:false",
                "ensure:Deutsch:false",
                "ensure:日本語:false",
                "ensure:日本語:false");
        check("channel cache isolates external onlyIfMissing, updates on rename, and retries on false/exception",
                ensures.equals(expected), "ensures=" + ensures);
    }

    /** 4. Deterministic drive timeout semantics (interrupt-driven, zero wall-clock race): all 4 scenarios. */
    private static void driveFifoTimeoutAndErrorCase() throws Exception {
        // (1) Queued timeout (not yet started): removed from queue, ops.drive NEVER runs, notification stays intact.
        AtomicInteger queuedTaps = new AtomicInteger();
        FakeOps qOps = new FakeOps() {
            @Override
            public int drive(Object ctx, boolean tap, String words) {
                super.drive(ctx, tap, words);
                if (tap) queuedTaps.incrementAndGet();
                return 1;
            }
        };
        NoticesQueue qq = new NoticesQueue(qOps, false, null);
        Object ctx = "ctx";
        qq.enqueueShow(ctx, "Msg", "c1", "hello", "World", "");
        int queuedTimeout = qq.drive(ctx, true, "hello", 0L);
        int drainedAfterCancel = qq.drainInline();
        boolean sc1 = queuedTimeout == NoticesQueue.DRIVE_TIMEOUT
                && drainedAfterCancel == 1 && queuedTaps.get() == 0;

        // Shared live worker for scenarios (2), (3), (4).
        java.util.Set<String> activeNotices = Collections.synchronizedSet(new java.util.HashSet<>());
        AtomicInteger deliveredTaps = new AtomicInteger();
        FakeOps liveOps = new FakeOps() {
            @Override
            public void show(Object c, String tag, String title, String body, String opens) {
                activeNotices.add(title);
                super.show(c, tag, title, body, opens);
            }

            @Override
            public int drive(Object c, boolean tap, String words) {
                log.add("drive:" + tap + ":" + words);
                boolean presentBeforeHook = activeNotices.contains(words);
                Runnable hook = onDriveHook;
                if (hook != null) hook.run();
                if (throwOnDrive) throw new RuntimeException("drive boom");
                if (tap) {
                    if (!activeNotices.remove(words)) return 0;
                    deliveredTaps.incrementAndGet();
                    return 1;
                }
                return presentBeforeHook ? 1 : 0;
            }
        };
        NoticesQueue liveQ = new NoticesQueue(liveOps, true, null);

        // (2a) In-flight tap=true timeout -> retry while STILL in-flight attaches to activeDrive and receives 1 once.
        activeNotices.add("hello");
        CountDownLatch ent2a = new CountDownLatch(1);
        CountDownLatch rel2a = new CountDownLatch(1);
        CountDownLatch t1Done = new CountDownLatch(1);
        liveOps.onDriveHook = () -> {
            ent2a.countDown();
            awaitUnbounded(rel2a);
        };
        AtomicInteger t1Res = new AtomicInteger(-99);
        Thread t1 = new Thread(() -> {
            t1Res.set(liveQ.drive(ctx, true, "hello", 5000L));
            t1Done.countDown();
        });
        t1.start();
        if (!ent2a.await(5, TimeUnit.SECONDS)) {
            rel2a.countDown();
            check("drive 4 scenarios", false, "2a never entered");
            return;
        }
        t1.interrupt();
        boolean t1TimedOut = t1Done.await(5, TimeUnit.SECONDS) && t1Res.get() == NoticesQueue.DRIVE_TIMEOUT;
        // Different query while in-flight is rejected immediately with DRIVE_TIMEOUT.
        int diffBlocked = liveQ.drive(ctx, false, "other", 0L);
        // Same (tap=true, "hello") attaches while worker is still blocked.
        CountDownLatch t2Done = new CountDownLatch(1);
        AtomicInteger t2Res = new AtomicInteger(-99);
        Thread t2 = new Thread(() -> {
            t2Res.set(liveQ.drive(ctx, true, "hello", 5000L));
            t2Done.countDown();
        });
        t2.start();
        long waitEnd = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        while (t2.getState() != Thread.State.TIMED_WAITING && System.nanoTime() < waitEnd) {
            Thread.yield();
        }
        liveOps.onDriveHook = null;
        rel2a.countDown();
        boolean t2Claimed = t2Done.await(5, TimeUnit.SECONDS) && t2Res.get() == 1;
        boolean sc2a = t1TimedOut && diffBlocked == NoticesQueue.DRIVE_TIMEOUT
                && t2Claimed && deliveredTaps.get() == 1 && !activeNotices.contains("hello");

        // (2b) In-flight tap=true timeout -> worker completes FIRST -> next frame retry immediately claims 1 (then 0).
        activeNotices.add("world");
        CountDownLatch ent2b = new CountDownLatch(1);
        CountDownLatch rel2b = new CountDownLatch(1);
        CountDownLatch t3Done = new CountDownLatch(1);
        liveOps.onDriveHook = () -> {
            ent2b.countDown();
            awaitUnbounded(rel2b);
        };
        AtomicInteger t3Res = new AtomicInteger(-99);
        Thread t3 = new Thread(() -> {
            t3Res.set(liveQ.drive(ctx, true, "world", 5000L));
            t3Done.countDown();
        });
        t3.start();
        if (!ent2b.await(5, TimeUnit.SECONDS)) {
            rel2b.countDown();
            check("drive 4 scenarios", false, "2b never entered");
            return;
        }
        t3.interrupt();
        boolean t3TimedOut = t3Done.await(5, TimeUnit.SECONDS) && t3Res.get() == NoticesQueue.DRIVE_TIMEOUT;
        liveOps.onDriveHook = null;
        CountDownLatch sync2b = new CountDownLatch(1);
        liveQ.enqueueExternalShow(ctx, "Msg", "sync-2b", "sync-2b", "B", "", sync2b::countDown);
        rel2b.countDown();
        boolean synced2b = sync2b.await(5, TimeUnit.SECONDS);
        int claimed2b = liveQ.drive(ctx, true, "world", 5000L);
        int after2b = liveQ.drive(ctx, true, "world", 5000L);
        boolean sc2b = t3TimedOut && synced2b && claimed2b == 1 && deliveredTaps.get() == 2 && after2b == 0;

        // (3) In-flight tap=true timeout with RuntimeException (DRIVE_ERROR) or 0 return:
        //     clears activeDrive so retrying the EXACT SAME (tap=true, words) executes a fresh query.
        CountDownLatch ent3e = new CountDownLatch(1);
        CountDownLatch rel3e = new CountDownLatch(1);
        CountDownLatch tErrDone = new CountDownLatch(1);
        liveOps.throwOnDrive = true;
        liveOps.onDriveHook = () -> {
            ent3e.countDown();
            awaitUnbounded(rel3e);
        };
        AtomicInteger tErrRes = new AtomicInteger(-99);
        Thread tErr = new Thread(() -> {
            tErrRes.set(liveQ.drive(ctx, true, "boom", 5000L));
            tErrDone.countDown();
        });
        tErr.start();
        if (!ent3e.await(5, TimeUnit.SECONDS)) {
            rel3e.countDown();
            check("drive 4 scenarios", false, "3e never entered");
            return;
        }
        tErr.interrupt();
        boolean tErrTimedOut = tErrDone.await(5, TimeUnit.SECONDS) && tErrRes.get() == NoticesQueue.DRIVE_TIMEOUT;
        liveOps.onDriveHook = null;
        CountDownLatch sync3e = new CountDownLatch(1);
        liveQ.enqueueExternalShow(ctx, "Msg", "sync-3e", "sync-3e", "B", "", sync3e::countDown);
        rel3e.countDown();
        boolean synced3e = sync3e.await(5, TimeUnit.SECONDS);
        liveOps.throwOnDrive = false;
        activeNotices.add("boom");
        int retrySameBoom = liveQ.drive(ctx, true, "boom", 5000L);

        // Same check for 0 return on in-flight tap=true timeout.
        CountDownLatch ent3z = new CountDownLatch(1);
        CountDownLatch rel3z = new CountDownLatch(1);
        CountDownLatch tZeroDone = new CountDownLatch(1);
        liveOps.onDriveHook = () -> {
            ent3z.countDown();
            awaitUnbounded(rel3z);
        };
        AtomicInteger tZeroRes = new AtomicInteger(-99);
        Thread tZero = new Thread(() -> {
            tZeroRes.set(liveQ.drive(ctx, true, "miss", 5000L));
            tZeroDone.countDown();
        });
        tZero.start();
        if (!ent3z.await(5, TimeUnit.SECONDS)) {
            rel3z.countDown();
            check("drive 4 scenarios", false, "3z never entered");
            return;
        }
        tZero.interrupt();
        boolean tZeroTimedOut = tZeroDone.await(5, TimeUnit.SECONDS) && tZeroRes.get() == NoticesQueue.DRIVE_TIMEOUT;
        liveOps.onDriveHook = null;
        CountDownLatch sync3z = new CountDownLatch(1);
        liveQ.enqueueExternalShow(ctx, "Msg", "sync-3z", "sync-3z", "B", "", sync3z::countDown);
        rel3z.countDown();
        boolean synced3z = sync3z.await(5, TimeUnit.SECONDS);
        activeNotices.add("miss");
        int retrySameMiss = liveQ.drive(ctx, true, "miss", 5000L);
        liveOps.throwOnDrive = true;
        int directErr = liveQ.drive(ctx, false, "boom2", 5000L);
        liveOps.throwOnDrive = false;
        boolean sc3 = tErrTimedOut && synced3e && retrySameBoom == 1
                && tZeroTimedOut && synced3z && retrySameMiss == 1
                && directErr == NoticesQueue.DRIVE_ERROR;

        // (4) Astra R3 #1: tap=false (nonotice) in-flight timeout + interleaved show("A") MUST NOT reuse stale 0.
        CountDownLatch ent4 = new CountDownLatch(1);
        CountDownLatch rel4 = new CountDownLatch(1);
        CountDownLatch tReadDone = new CountDownLatch(1);
        liveOps.onDriveHook = () -> {
            ent4.countDown();
            awaitUnbounded(rel4);
        };
        AtomicInteger tReadRes = new AtomicInteger(-99);
        Thread tRead = new Thread(() -> {
            tReadRes.set(liveQ.drive(ctx, false, "A", 5000L));
            tReadDone.countDown();
        });
        tRead.start();
        if (!ent4.await(5, TimeUnit.SECONDS)) {
            rel4.countDown();
            check("drive 4 scenarios", false, "4 never entered");
            return;
        }
        tRead.interrupt();
        boolean tReadTimedOut = tReadDone.await(5, TimeUnit.SECONDS) && tReadRes.get() == NoticesQueue.DRIVE_TIMEOUT;
        // Interleave show("A") while old read-only drive(false, "A") (which already saw absent=0) is still in-flight.
        liveQ.enqueueShow(ctx, "Msg", "tagA", "A", "body", "");
        // Retrying drive(false, "A") with non-zero timeout while old read-only drive is in-flight MUST return
        // DRIVE_TIMEOUT immediately (never attach to the old snapshot and receive stale 0!).
        AtomicInteger retryRes = new AtomicInteger(-99);
        CountDownLatch retryDone = new CountDownLatch(1);
        Thread tRetry = new Thread(() -> {
            retryRes.set(liveQ.drive(ctx, false, "A", 5000L));
            retryDone.countDown();
        });
        tRetry.start();
        long retryWaitEnd = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        while (retryDone.getCount() > 0 && tRetry.getState() != Thread.State.TIMED_WAITING
                && System.nanoTime() < retryWaitEnd) {
            Thread.yield();
        }
        liveOps.onDriveHook = null;
        CountDownLatch sync4 = new CountDownLatch(1);
        liveQ.enqueueExternalShow(ctx, "Msg", "sync-4", "sync-4", "B", "", sync4::countDown);
        rel4.countDown();
        boolean retryFinished = retryDone.await(5, TimeUnit.SECONDS);
        boolean synced4 = sync4.await(5, TimeUnit.SECONDS);
        // Fresh drive(false, "A") runs AFTER show("A") and returns 1 (so nonotice / kind 14 returns 0, never false-pass).
        int readAfterShow = liveQ.drive(ctx, false, "A", 5000L);
        boolean sc4 = tReadTimedOut && retryFinished && retryRes.get() == NoticesQueue.DRIVE_TIMEOUT
                && synced4 && readAfterShow == 1;

        check("drive queued cancel, in-flight tap attach/claim, same-word 0/error recovery, and nonotice no-stale-reuse",
                sc1 && sc2a && sc2b && sc3 && sc4,
                "sc1=" + sc1 + ", sc2a=" + sc2a + ", sc2b=" + sc2b + ", sc3=" + sc3 + ", sc4=" + sc4);
    }

    /** 5. Deterministic zero-thread permission race (autoStart=false): R1 captures GRANTED, invalidated by onResumeRefresh, discarded by gen == permGen; R2 writes DENIED. */
    private static void permInFlightInvalidatedByResumeCase() {
        FakeOps ops = new FakeOps();
        NoticesQueue q = new NoticesQueue(ops, false, null);
        Object ctx = "ctx";
        AtomicInteger readCalls = new AtomicInteger();

        ops.permValue = NoticesQueue.PERM_GRANTED;
        ops.onReadHook = () -> {
            if (readCalls.incrementAndGet() == 1) {
                // FakeOps.readPermission already captured v = PERM_GRANTED before invoking this hook.
                // Simulate onResumeRefresh arriving while R1 is in flight with user having revoked permission.
                ops.permValue = NoticesQueue.PERM_DENIED;
                q.onResumeRefresh(ctx);
            }
        };

        q.requestRefresh(ctx, false);
        // Step 1 executes R1: captured PERM_GRANTED must be discarded by gen == permGen, and refreshAgain queues R2.
        boolean ranR1 = q.stepOne();
        boolean r1Discarded = q.permissionState() == NoticesQueue.PERM_PENDING && ops.frameRequests.get() == 0;
        // Step 2 executes R2: reads PERM_DENIED, updates permState, and calls requestFrame().
        boolean ranR2 = q.stepOne();
        boolean queueEmpty = !q.stepOne();

        check("in-flight R1 (captured GRANTED) invalidated by onResumeRefresh is discarded; R2 writes DENIED and requests frame",
                ranR1 && r1Discarded && ranR2 && queueEmpty
                        && q.permissionState() == NoticesQueue.PERM_DENIED
                        && readCalls.get() == 2 && ops.frameRequests.get() == 1,
                "r1Discarded=" + r1Discarded + ", state=" + q.permissionState()
                        + ", reads=" + readCalls.get() + ", frames=" + ops.frameRequests.get());
    }

    /** 6. Permission result calibration (both takeAnswer orders), resume preservation, cancelled dialog, and transient read failure. */
    private static void permResultCalibrationAndCancelCase() {
        FakeOps ops = new FakeOps();
        NoticesQueue q = new NoticesQueue(ops, false, null);
        Object ctx = "ctx";

        q.enqueueShow(ctx, "Msg", "t1", "A", "B", "");
        q.requestRefresh(ctx, true);
        q.onPermissionResult(ctx, false, true, true);
        boolean immediateGranted = q.permissionState() == NoticesQueue.PERM_GRANTED;
        q.onResumeRefresh(ctx);
        boolean preservedOnResume = q.permissionState() == NoticesQueue.PERM_GRANTED;
        ops.permValue = NoticesQueue.PERM_ASK;
        q.drainInline();
        boolean oemCalibratedState = q.permissionState() == NoticesQueue.PERM_ASK;
        int oemCalibratedAns = q.takeAnswer();
        int oemCalibratedAns2 = q.takeAnswer();

        ops.permValue = NoticesQueue.PERM_GRANTED;
        q.onPermissionResult(ctx, false, false, true);
        q.drainInline();
        boolean refuseCalibrated = q.permissionState() == NoticesQueue.PERM_GRANTED && q.takeAnswer() == 1;

        ops.permValue = NoticesQueue.PERM_ASK;
        q.onPermissionResult(ctx, false, true, true);
        int framesBeforeOem2 = ops.frameRequests.get();
        int earlyAns = q.takeAnswer();
        q.drainInline();
        boolean lateOemUpdated = earlyAns == 1 && q.permissionState() == NoticesQueue.PERM_ASK
                && ops.frameRequests.get() == framesBeforeOem2 + 1 && q.takeAnswer() == -1;

        ops.permValue = NoticesQueue.PERM_GRANTED;
        q.onPermissionResult(ctx, true, false, true);
        boolean cancelPendingNoFakeAns = q.permissionState() == NoticesQueue.PERM_PENDING && q.takeAnswer() == -1;
        q.drainInline();
        boolean cancelRestoredGranted = q.permissionState() == NoticesQueue.PERM_GRANTED && q.takeAnswer() == -1;

        q.onPermissionResult(ctx, false, true, true);
        ops.throwOnRead = true;
        q.drainInline();
        ops.throwOnRead = false;
        boolean transientPreserved = q.permissionState() == NoticesQueue.PERM_GRANTED && q.takeAnswer() == 1;

        check("onPermissionResult calibration (both orders), resume preservation, cancelled no-fake-refusal, and transient failure safety",
                immediateGranted && preservedOnResume && oemCalibratedState && oemCalibratedAns == 0 && oemCalibratedAns2 == -1
                        && refuseCalibrated && lateOemUpdated
                        && cancelPendingNoFakeAns && cancelRestoredGranted && transientPreserved,
                "oemAns=" + oemCalibratedAns + ", refuseCal=" + refuseCalibrated + ", lateOem=" + lateOemUpdated
                        + ", cancelNoFake=" + cancelPendingNoFakeAns + ", cancelRestored=" + cancelRestoredGranted
                        + ", transient=" + transientPreserved);
    }

    /** 7. Block-state broadcast (markPending=false), first-read failure (5 -> 0), context retention, and worker exception resilience. */
    private static void broadcastFailureContextAndResilienceCase() {
        FakeOps ops = new FakeOps();
        NoticesQueue q = new NoticesQueue(ops, false, null);
        Object ctx = "ctx";

        boolean startsPending = q.permissionState() == NoticesQueue.PERM_PENDING;
        q.requestRefresh(null, false);
        q.drainInline();
        boolean nullCtxToUnknown = q.permissionState() == NoticesQueue.PERM_UNKNOWN && ops.frameRequests.get() == 1;

        q.bindContext(ctx);
        q.onResumeRefresh(ctx);
        ops.throwOnRead = true;
        q.drainInline();
        boolean throwToUnknown = q.permissionState() == NoticesQueue.PERM_UNKNOWN && ops.frameRequests.get() == 2;
        ops.throwOnRead = false;

        ops.permValue = NoticesQueue.PERM_GRANTED;
        q.requestRefresh(ctx, false);
        q.drainInline();
        int framesAfterChange = ops.frameRequests.get();
        q.requestRefresh(ctx, false);
        q.drainInline();
        int framesAfterSame = ops.frameRequests.get();

        q.bindContext(null);
        boolean retained = q.permissionState() == NoticesQueue.PERM_GRANTED;

        FakeOps liveOps = new FakeOps();
        liveOps.throwOnShow = true;
        liveOps.throwOnCancel = true;
        liveOps.throwOnDrive = true;
        NoticesQueue liveQ = new NoticesQueue(liveOps, true, null);
        liveQ.enqueueShow(ctx, "Msg", "e1", "T", "B", "");
        liveQ.enqueueCancel(ctx, "e1");
        int boomDrive = liveQ.drive(ctx, false, "x", 5000L);
        liveOps.throwOnShow = false;
        liveOps.throwOnCancel = false;
        liveOps.throwOnDrive = false;
        liveQ.enqueueShow(ctx, "Msg", "ok1", "Alive", "Body", "");
        int aliveDrive = liveQ.drive(ctx, false, "Alive", 5000L);

        check("broadcast dedup, first-read failure 5->0, context retention, and worker RuntimeException survival",
                startsPending && nullCtxToUnknown && throwToUnknown
                        && framesAfterChange == 3 && framesAfterSame == 3 && retained
                        && boomDrive == NoticesQueue.DRIVE_ERROR && aliveDrive == 1 && liveOps.log.contains("show:ok1:Alive"),
                "startsPending=" + startsPending + ", nullCtx=" + nullCtxToUnknown + ", throw=" + throwToUnknown
                        + ", frames=" + framesAfterChange + "/" + framesAfterSame + ", boom=" + boomDrive + ", alive=" + aliveDrive);
    }

    public static void main(String[] args) throws Exception {
        fifoOrderingWithInFlightShowCase();
        externalShowTimeoutAndOnDoneCase();
        channelCacheCase();
        driveFifoTimeoutAndErrorCase();
        permInFlightInvalidatedByResumeCase();
        permResultCalibrationAndCancelCase();
        broadcastFailureContextAndResilienceCase();
        if (failures > 0) {
            System.out.println(failures + " failed");
            System.exit(1);
        }
    }
}
