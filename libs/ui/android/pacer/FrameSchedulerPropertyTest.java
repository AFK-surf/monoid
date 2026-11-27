package dev.mbui;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;

/**
 * Deterministic randomized interleaving property tests for {@link FrameScheduler} / {@link FramePacer}.
 *
 * <p>Generates 5,000+ adversarial 30-60 step event sequences with a fixed seed, covering:
 * <ul>
 *   <li>Wall-clock {@code nanoTime()} leading/lagging Choreographer {@code vsyncNs} by 0..25 ms (120 Hz jitter)</li>
 *   <li>Same-{@code doFrame(T)} {@code CALLBACK_INPUT -> wantFrame()} followed by {@code CALLBACK_ANIMATION} at {@code T}</li>
 *   <li>Mixed legacy 2-arg {@code vsyncCame(t, shows)} and generation-tagged 3-arg {@code vsyncCame(t, shows, gen)}</li>
 *   <li>{@code frameNow()} with/without {@code deferredVsync}, {@code setImeMoving(true/false)}</li>
 *   <li>{@code scheduleWake} + {@code fireWake}, {@code wantFrame} / {@code wantPacedFrame} / {@code pictureFrame} / {@code wantImmediateFrame}</li>
 *   <li>{@code takeRender} + {@code begin}/{@code ended}, {@code resetContinuity}, {@code surfaceReset}</li>
 *   <li>Dropped, delayed, and out-of-order stale-generation Choreographer callbacks</li>
 * </ul>
 *
 * <p>Verifies universal liveness (0 deadlocks across all sequences) and safety invariants (no duplicate
 * app frame for the same vsync, stale generation never clears active slot, {@code activeVsyncGen == 0}
 * iff no valid callback is in flight).
 */
public final class FrameSchedulerPropertyTest {
    private static final long SEED = 0x5F3759DF12345678L;
    private static final int SEQUENCES = 5_000;
    private static final int BACKWARD_SEQUENCES = 2_000;
    private static final long PERIOD_120 = 8_333_333L;
    private static final long PERIOD_90 = 11_111_111L;
    private static final long PERIOD_60 = 16_666_667L;
    private static final long PERIOD_20 = 50_000_000L;

    static final class PostedVsync {
        final long gen;
        final boolean untagged;

        PostedVsync(long gen, boolean untagged) {
            this.gen = gen;
            this.untagged = untagged;
        }
    }

    static final class Harness implements FramePacer.Platform {
        final Random rng;
        long period;
        final FramePacer pacer;
        long vsyncNow;
        long wallSkewNs; // nanoTime() = vsyncNow + wallSkewNs (can lead or lag by -25ms..+25ms)
        boolean onMain = true;
        boolean typing;
        boolean glSettling;
        boolean pictureActive;
        boolean imeMoving;

        final ArrayDeque<Runnable> mainQueue = new ArrayDeque<>();
        final List<PostedVsync> inFlightVsyncs = new ArrayList<>();
        final List<PostedVsync> stalePool = new ArrayList<>();
        final List<FramePacer.WakeReq> wakes = new ArrayList<>();

        int renderRequests;
        int totalRenders;
        int appRenders;
        int pictureRenders;
        boolean renderPending;
        long lastRenderedAppVsyncNs = -1L;
        long lastRenderedAppToken = 0L;
        boolean immediateOverrideSinceLastApp;
        int duplicateAppVsyncViolations;
        int duplicateTokenViolations;
        int staleGenViolations;
        int invariantViolations;

        Harness(Random rng, long period) {
            this.rng = rng;
            this.period = period;
            this.vsyncNow = 100L * period;
            this.pacer = new FramePacer(this);
            this.pacer.framePeriod = period;
            this.pacer.topRate = (float) Math.round(1e9 / period);
        }

        @Override public long nanoTime() {
            return Math.max(1L, vsyncNow + wallSkewNs);
        }

        @Override public boolean onMain() {
            return onMain;
        }

        @Override public void postMain(Runnable r) {
            mainQueue.addLast(r);
        }

        @Override public void postVsync() {
            inFlightVsyncs.add(new PostedVsync(0L, true));
        }

        @Override public void postVsync(long gen) {
            // Mix tagged (3-arg) and legacy untagged (2-arg) delivery randomly to exercise both paths.
            boolean useLegacy = rng.nextInt(5) == 0;
            inFlightVsyncs.add(new PostedVsync(gen, useLegacy));
        }

        @Override public void atNextVsyncOnDrawing(Runnable r) {
            // RateVoter countdowns are non-blocking observers; no-op in scheduler property harness.
        }

        @Override public void requestRender() {
            renderRequests++;
            renderPending = true;
        }

        @Override public boolean setRate(float rate) {
            return true;
        }

        @Override public boolean typing() {
            return typing;
        }

        @Override public boolean glSettling() {
            return glSettling;
        }

        @Override public boolean pictureActive() {
            return pictureActive;
        }

        void drainMainQueue() {
            boolean prev = onMain;
            onMain = true;
            int guard = 0;
            while (!mainQueue.isEmpty() && guard++ < 64) {
                mainQueue.pollFirst().run();
            }
            onMain = prev;
        }

        long showsFor(long t) {
            // Exercise both API < 33 (shows == 0) and API 33+ (shows = t + 2 * period).
            return rng.nextInt(3) == 0 ? 0L : t + 2L * period;
        }

        void deliverNextVsync(boolean sameBeat) {
            if (!sameBeat) {
                vsyncNow += period;
            }
            if (inFlightVsyncs.isEmpty()) return;
            List<PostedVsync> batch = new ArrayList<>(inFlightVsyncs);
            inFlightVsyncs.clear();
            long t = vsyncNow;
            long shows = showsFor(t);
            boolean prev = onMain;
            onMain = true;
            for (PostedVsync pv : batch) {
                if (pv.untagged) {
                    pacer.vsyncCame(t, shows);
                } else {
                    pacer.vsyncCame(t, shows, pv.gen);
                    if (stalePool.size() < 16) stalePool.add(pv);
                }
            }
            onMain = prev;
        }

        void deliverBackwardVsync() {
            if (inFlightVsyncs.isEmpty()) return;
            List<PostedVsync> batch = new ArrayList<>(inFlightVsyncs);
            inFlightVsyncs.clear();
            long regressedT = Math.max(period, vsyncNow - (1L + rng.nextInt(4)) * period);
            long shows = showsFor(regressedT);
            boolean prev = onMain;
            onMain = true;
            for (PostedVsync pv : batch) {
                if (pv.untagged) {
                    pacer.vsyncCame(regressedT, shows);
                } else {
                    pacer.vsyncCame(regressedT, shows, pv.gen);
                    if (stalePool.size() < 16) stalePool.add(pv);
                }
            }
            onMain = prev;
            // A deliberately regressed timestamp is a backward clock jump rather than a same-beat duplicate.
            immediateOverrideSinceLastApp = true;
        }

        void deliverStaleCallback() {
            if (stalePool.isEmpty()) return;
            long activeBefore = pacer.scheduler.activeVsyncGen();
            PostedVsync pv = stalePool.get(rng.nextInt(stalePool.size()));
            if (pv.gen == 0L || pv.gen == activeBefore) return;
            int reqBefore = renderRequests;
            int postsBefore = inFlightVsyncs.size();
            boolean prev = onMain;
            onMain = true;
            long oldT = Math.max(period, vsyncNow - (1L + rng.nextInt(5)) * period);
            pacer.vsyncCame(oldT, oldT + 2L * period, pv.gen);
            onMain = prev;
            // Safety: a stale generation callback must NEVER clear activeVsyncGen or trigger render/postVsync.
            if (pacer.scheduler.activeVsyncGen() != activeBefore
                    || renderRequests != reqBefore
                    || inFlightVsyncs.size() != postsBefore) {
                staleGenViolations++;
            }
        }

        void runTakeRender(boolean simulateFrameBody) {
            if (!renderPending && rng.nextBoolean()) return;
            renderPending = false;
            FramePacer.Taken tk = pacer.takeRender();
            if (!tk.app && !tk.pictured) return;
            totalRenders++;
            if (tk.app) {
                appRenders++;
                if (tk.dispatchToken <= 0L || tk.dispatchToken <= lastRenderedAppToken) {
                    duplicateTokenViolations++;
                }
                lastRenderedAppToken = tk.dispatchToken;
                long v = tk.vsyncAt[0];
                if (v != 0L && !immediateOverrideSinceLastApp && v == lastRenderedAppVsyncNs) {
                    duplicateAppVsyncViolations++;
                }
                lastRenderedAppVsyncNs = v;
                immediateOverrideSinceLastApp = false;
                if (simulateFrameBody) {
                    FramePacer.Begun b = pacer.begin(tk.vsyncAt, nanoTime(), tk.external, tk.continuityGen);
                    pacer.clearWake();
                    boolean more = rng.nextInt(5) == 0;
                    float paced = (!more && rng.nextInt(4) == 0) ? 20f : 0f;
                    pacer.ended(more, false, b.following, paced, b.externalDemand);
                }
            } else {
                pictureRenders++;
                pacer.redrawn();
            }
        }

        /** Verifies structural liveness & slot-ownership invariants after mainQueue is drained. */
        void checkStructuralInvariant() {
            if (!mainQueue.isEmpty()) return;
            FrameScheduler s = pacer.scheduler;
            if (s.hasUndispatchedDemand() && s.activeVsyncGen() == 0L && !s.hasDeferredVsync() && !renderPending) {
                invariantViolations++;
            }
            // Safety: activeVsyncGen != 0 (and not deferred) iff a matching in-flight callback exists.
            long activeGen = s.activeVsyncGen();
            boolean hasMatchingInFlight = false;
            for (PostedVsync pv : inFlightVsyncs) {
                if (activeGen != 0L && pv.gen == activeGen) {
                    hasMatchingInFlight = true;
                    break;
                }
            }
            if (activeGen != 0L && !s.hasDeferredVsync() && !hasMatchingInFlight) {
                invariantViolations++;
            }
        }

        /**
         * Settles the scheduler over a bounded number of vsync ticks without dropping callbacks,
         * returning how many new renders occurred.
         */
        int settle(int maxTicks) {
            int before = totalRenders;
            for (int tick = 0; tick < maxTicks; tick++) {
                drainMainQueue();
                if (renderPending) {
                    runTakeRender(false);
                }
                if (totalRenders > before && !pacer.scheduler.hasUndispatchedDemand()) {
                    break;
                }
                deliverNextVsync(false);
                drainMainQueue();
                if (renderPending) {
                    runTakeRender(false);
                }
            }
            return totalRenders - before;
        }
    }

    private static void runSequence(int seqIdx, Random rng, boolean allowBackwardVsync) {
        long[] periods = {PERIOD_120, PERIOD_90, PERIOD_60, PERIOD_20};
        long period = periods[rng.nextInt(periods.length)];
        Harness h = new Harness(rng, period);
        int steps = 30 + rng.nextInt(31); // 30..60 steps

        for (int step = 0; step < steps; step++) {
            // Random wall-clock jitter: -25ms .. +25ms relative to Choreographer vsyncNow
            h.wallSkewNs = (rng.nextInt(51) - 25) * 1_000_000L;
            h.onMain = rng.nextInt(4) != 0; // 75% main thread, 25% background/app thread
            // Randomly switch display refresh rate mid-sequence (120/90/60/20 Hz LTPO transitions)
            if (rng.nextInt(12) == 0) {
                h.period = periods[rng.nextInt(periods.length)];
                h.pacer.framePeriod = h.period;
                h.pacer.topRate = (float) Math.round(1e9 / h.period);
            }

            int op = rng.nextInt(allowBackwardVsync ? 18 : 17);
            switch (op) {
                case 0: // wantFrame
                    h.pacer.wantFrame();
                    break;
                case 1: // wantPacedFrame
                    h.pacer.wantPacedFrame();
                    break;
                case 2: // pictureFrame
                    h.pacer.pictureFrame();
                    break;
                case 3: // wantImmediateFrame (caller immediately requests render)
                    h.pacer.wantImmediateFrame();
                    h.immediateOverrideSinceLastApp = true;
                    h.requestRender();
                    break;
                case 4: // frameNow (with or without deferredVsync)
                    h.onMain = true;
                    h.immediateOverrideSinceLastApp = true;
                    h.pacer.frameNow();
                    break;
                case 5: // setImeMoving toggle
                    h.onMain = true;
                    h.imeMoving = !h.imeMoving;
                    h.pacer.setImeMoving(h.imeMoving);
                    break;
                case 6: // scheduleWake
                    double offsetMs = (rng.nextInt(4) - 1) * (h.period / 1e6);
                    FramePacer.WakeReq req = h.pacer.scheduleWake(h.vsyncNow / 1e6 + offsetMs, rng.nextBoolean());
                    if (req != null && h.wakes.size() < 16) h.wakes.add(req);
                    break;
                case 7: // fireWake
                    if (!h.wakes.isEmpty()) {
                        h.onMain = true;
                        FramePacer.WakeReq w = h.wakes.get(rng.nextInt(h.wakes.size()));
                        int res = h.pacer.fireWake(w, h.vsyncNow, h.showsFor(h.vsyncNow));
                        if (res == 0 || res == 2) h.wakes.remove(w);
                    }
                    break;
                case 8: // Same-doFrame CALLBACK_INPUT -> wantFrame() immediately followed by CALLBACK_ANIMATION at T
                    h.onMain = true;
                    h.pacer.wantFrame();
                    h.drainMainQueue();
                    h.deliverNextVsync(true);
                    break;
                case 9: // Normal next vsync delivery
                    h.drainMainQueue();
                    h.deliverNextVsync(false);
                    break;
                case 10: // takeRender + frame body
                    h.runTakeRender(true);
                    break;
                case 11: // resetContinuity (with 0L or positive wall time) + optional dropped pre-reset callbacks
                    h.onMain = true;
                    if (rng.nextBoolean()) {
                        // Simulate pre-pause callbacks lost in Choreographer before resetContinuity
                        for (PostedVsync pv : h.inFlightVsyncs) {
                            if (pv.gen != 0L && h.stalePool.size() < 16) h.stalePool.add(pv);
                        }
                        h.inFlightVsyncs.clear();
                    }
                    long resetNow = rng.nextBoolean() ? 0L : h.nanoTime();
                    h.pacer.resetContinuity(resetNow);
                    h.immediateOverrideSinceLastApp = true;
                    break;
                case 12: // surfaceReset
                    h.pacer.surfaceReset();
                    break;
                case 13: // Deliver stale/out-of-order old-generation callback
                    h.deliverStaleCallback();
                    break;
                case 14: // Drain main queue (runs postMain -> postVsync / flushDeferredVsync)
                    h.drainMainQueue();
                    break;
                case 15: // Direct untagged 2-arg vsyncCame(t, shows) at current vsync (same-beat legacy duplicate)
                    h.onMain = true;
                    h.pacer.vsyncCame(h.vsyncNow, h.showsFor(h.vsyncNow));
                    break;
                case 16: // frameNow interleaved with immediate same-beat vsyncCame(vsyncNow)
                    h.onMain = true;
                    h.immediateOverrideSinceLastApp = true;
                    h.pacer.frameNow();
                    h.drainMainQueue();
                    h.deliverNextVsync(true);
                    break;
                case 17: // Active/untagged delivery with regressed (out-of-order/backward) timestamp
                    h.drainMainQueue();
                    h.deliverBackwardVsync();
                    break;
                default:
                    break;
            }

            if (step % 4 == 0) {
                h.drainMainQueue();
                h.checkStructuralInvariant();
            }
        }

        // End of sequence: exit IME animation if active, drain main queue, and verify Universal Liveness.
        h.onMain = true;
        if (h.imeMoving) {
            h.imeMoving = false;
            h.pacer.setImeMoving(false);
        }
        h.wallSkewNs = 0L;
        h.drainMainQueue();
        h.checkStructuralInvariant();

        // Phase 1 liveness: drain any existing demand first so Phase 2 starts from an idle state.
        h.settle(8);
        h.drainMainQueue();
        h.checkStructuralInvariant();
        if (h.pacer.appWanted.get() || h.pacer.picturesOnly.get()) {
            throw new AssertionError("PHASE 1 STUCK DEMAND in sequence " + seqIdx
                    + " (appWanted=" + h.pacer.appWanted.get()
                    + ", picturesOnly=" + h.pacer.picturesOnly.get() + ")");
        }

        // Phase 2 liveness: inject a fresh demand (wantFrame / wantPacedFrame / pictureFrame) and strictly
        // assert the matching render kind (app vs picture) occurs within bounded ticks and clears demand.
        int appBefore = h.appRenders;
        int picBefore = h.pictureRenders;
        int demandKind = rng.nextInt(3);
        if (demandKind == 0) h.pacer.wantFrame();
        else if (demandKind == 1) h.pacer.wantPacedFrame();
        else h.pacer.pictureFrame();

        h.settle(8);
        h.drainMainQueue();
        boolean kindRendered = (demandKind == 2) ? (h.pictureRenders > picBefore) : (h.appRenders > appBefore);
        boolean demandCleared = !h.pacer.appWanted.get() && !h.pacer.picturesOnly.get();
        if (!kindRendered || !demandCleared) {
            throw new AssertionError("DEADLOCK in sequence " + seqIdx + " (demandKind=" + demandKind
                    + ", kindRendered=" + kindRendered + ", demandCleared=" + demandCleared
                    + ", activeVsyncGen=" + h.pacer.scheduler.activeVsyncGen()
                    + ", hasDeferred=" + h.pacer.scheduler.hasDeferredVsync()
                    + ", hasUndispatched=" + h.pacer.scheduler.hasUndispatchedDemand()
                    + ", inFlight=" + h.inFlightVsyncs.size() + ")");
        }
        if (h.duplicateTokenViolations > 0) {
            throw new AssertionError("SAFETY VIOLATION (non-monotonic dispatchToken) in sequence " + seqIdx
                    + ": count=" + h.duplicateTokenViolations);
        }
        if (!allowBackwardVsync && h.duplicateAppVsyncViolations > 0) {
            throw new AssertionError("SAFETY VIOLATION (duplicate app vsync) in sequence " + seqIdx
                    + ": count=" + h.duplicateAppVsyncViolations);
        }
        if (h.staleGenViolations > 0) {
            throw new AssertionError("SAFETY VIOLATION (stale gen cleared active slot) in sequence " + seqIdx
                    + ": count=" + h.staleGenViolations);
        }
        if (h.invariantViolations > 0) {
            throw new AssertionError("LIVENESS INVARIANT VIOLATION in sequence " + seqIdx
                    + ": count=" + h.invariantViolations);
        }
    }

    public static void main(String[] args) {
        Random rng = new Random(SEED);
        long t0 = System.nanoTime();
        for (int i = 0; i < SEQUENCES; i++) {
            runSequence(i, rng, false);
        }
        for (int i = 0; i < BACKWARD_SEQUENCES; i++) {
            runSequence(SEQUENCES + i, rng, true);
        }
        double ms = (System.nanoTime() - t0) / 1e6;
        int total = SEQUENCES + BACKWARD_SEQUENCES;
        System.out.printf("ok   FrameSchedulerPropertyTest: %d/%d sequences passed (%d monotonic/same-beat + %d backward/out-of-order, 0 deadlocks, 0 safety violations, %.1f ms)%n",
                total, total, SEQUENCES, BACKWARD_SEQUENCES, ms);
    }
}
