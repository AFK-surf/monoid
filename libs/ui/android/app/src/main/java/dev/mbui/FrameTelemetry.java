package dev.mbui;

/**
 * Pure frame-timing continuity, GL work measurement, and ADPF hint observer.
 *
 * <p>Holds no scheduling locks and cannot block or suppress {@link FrameScheduler} liveness: any
 * continuity break or clock jump affects only reported timestamps, {@code late}, {@code following},
 * and ADPF targets.
 */
final class FrameTelemetry {
    /** Monotonic continuity boundary counter (incremented on pause/resume/surface destroy). */
    private volatile long continuityGen;
    /** Minimum valid vsync timestamp (ns) after resume; older timestamps are treated as 0. */
    private volatile long minValidVsyncNs;

    // Drawing-thread frame-history state.
    private long seenContinuityGen;
    private double lastFrame;
    // the frame before's vsync (0: none, or it had none), and whether it asked for this one (askAhead: the vsync after
    // its own, or where its work went past that one, the first after its work)
    private long lastVsync;
    private boolean askedAtEnd;

    long continuityGen() {
        return continuityGen;
    }

    long lastVsync() {
        return lastVsync;
    }

    /** Advances continuity boundary on pause/resume/surface destruction. */
    void advanceContinuity(long nowNs) {
        continuityGen++;
        if (nowNs > 0L && nowNs > minValidVsyncNs) {
            minValidVsyncNs = nowNs;
        }
    }

    /** Records whether the just-ended app frame asked for another frame. */
    void noteFrameEnded(boolean askedMore) {
        askedAtEnd = askedMore;
    }

    /** Clears {@code askedAtEnd} after a picture-only redraw when no app frame is pending. */
    void clearAskedAtEnd() {
        askedAtEnd = false;
    }

    /**
     * Computes frame timestamp, lateness, and continuity for the app frame beginning now on the
     * drawing thread, invoking {@code onAskAhead} if the previous frame asked for this one.
     *
     * <p>The vsync after the frame beginning now is asked for before its work (drawing thread),
     * where the frame before asked for this one (a motion going on): a frame asked for only as it
     * ended had the first vsync after its work, so one whose work went past the display's frame
     * left a refresh with no new frame, what moved standing still for one and then stepping two
     * (an OPPO Find N6's inner screen, its frames 6–16 ms at 120 Hz). Asked ahead, the vsync comes
     * while the frame is drawn; one that ends after it draws the next at once, for that vsync and
     * shown at its refresh (showAt), as the system's own frames are asked for in the vsync before
     * theirs: a frame over the display's frame costs nothing where the next is lighter.
     */
    FramePacer.Begun begin(long[] at, long began, boolean externalDemand, long gen,
                           long framePeriodNs, Runnable onAskAhead) {
        if (seenContinuityGen != gen) {
            seenContinuityGen = gen;
            lastVsync = 0L;
            askedAtEnd = false;
        }
        // (the frame before asked for this one: the one after it asked for now, before this one's work: askAhead)
        if (askedAtEnd && onAskAhead != null) onAskAhead.run();
        // the vsync's time; a frame the system asked for (a resize) has none, and time never goes back
        long v = at[0];
        long minV = minValidVsyncNs;
        if (v != 0L && minV != 0L && v < minV) v = 0L;
        double now = v != 0L ? v / 1e6 : began / 1e6;
        if (now < lastFrame) now = lastFrame;
        lastFrame = now;
        // how late the frame before reached the screen (@hostapi.frame_late): the display's frames that passed past the one
        // after it without a frame, on the vsyncs' grid (its work over the display's frame and drawn on for the vsync it
        // asked ahead, shown at that vsync's refresh: none passed, it was in time; past that one too, this one's vsync is
        // the first after its work); 0 where it did not ask for this one (its vsync perhaps one during that work), or
        // either has no vsync. (Counted from when its work ended, a frame drawn on at once for the vsync asked ahead was
        // said late by a frame it was not: a page let go as the finger lifts, its slide held a frame and its first step
        // shown twice.)
        double late = 0;
        if (v != 0L && lastVsync != 0L && askedAtEnd) {
            long frames = Math.round((double) (v - lastVsync) / framePeriodNs);
            if (frames > 1) late = (frames - 1) * framePeriodNs / 1e6;
        }
        // drawn at the vsync after the frame before's: the hand moving what it holds, a frame each vsync
        boolean following = v > lastVsync && lastVsync != 0L && v - lastVsync < framePeriodNs * 3L / 2L;
        lastVsync = v;
        return new FramePacer.Begun(v, v != 0L ? at[1] : 0L, now, late, following, externalDemand);
    }

    /** Valid thread CPU delta in ns, or -1 if either sample is unavailable or moved backwards. */
    static long cpuDeltaNanos(long cpuStartNs, long cpuEndNs) {
        return (cpuStartNs >= 0L && cpuEndNs >= cpuStartNs) ? (cpuEndNs - cpuStartNs) : -1L;
    }

    /**
     * GL thread work duration (ns): non-paced swaps keep full wall time (including real GPU backpressure);
     * paced swaps exclude intentional pacing sleep in eglSwapBuffers / lazy dequeueBuffer via thread CPU time,
     * falling back to pre-swap wall time if CPU time is unavailable.
     */
    static long glWorkNanos(long drawStartNs, long drawEndNs, long swapDoneNs, long cpuDeltaNs, boolean pacedSwap) {
        long wallNs = Math.max(0L, swapDoneNs - drawStartNs);
        if (!pacedSwap) return wallNs;
        if (cpuDeltaNs >= 0L) return Math.min(wallNs, cpuDeltaNs);
        return Math.min(wallNs, Math.max(0L, drawEndNs - drawStartNs));
    }

    /** Computes both GL work duration and raw wall duration from a single GL frame sample. */
    static FramePacer.GlTiming measureGl(long d0, long drawEnd, long swapEnd, long cpuDeltaNs,
                                         boolean paced, boolean swapMeasured) {
        long effectiveEnd = swapMeasured ? swapEnd : drawEnd;
        long rawWallNs = Math.max(0L, effectiveEnd - d0);
        long workNs = glWorkNanos(d0, drawEnd, effectiveEnd, cpuDeltaNs, paced);
        return new FramePacer.GlTiming(workNs, rawWallNs, paced, swapMeasured);
    }

    /** ADPF target work duration (70% of period), optionally clamped to the display's top refresh rate. */
    static long adpfTargetNanos(long framePeriodNs, float topRate, boolean clampToTop) {
        long period = framePeriodNs;
        if (clampToTop && topRate > 0f) {
            long topPeriod = (long) (1e9 / topRate);
            if (topPeriod > 0L && (period <= 0L || topPeriod < period)) period = topPeriod;
        }
        return period > 0L ? period * 7L / 10L : 0L;
    }

    /**
     * Whether {@code framePeriodNs} is still a stale low-rate paced timeline (20-30 Hz: 33-50 ms) rather than
     * a normal or system-capped interactive rate (e.g. 60 Hz = 16.67 ms on a 120 Hz panel).
     */
    static boolean isStalePacedPeriod(long framePeriodNs, float topRate) {
        if (topRate <= 0f || framePeriodNs <= 0L) return false;
        long threshold = Math.max(20_000_000L, (long) (1.75e9 / topRate));
        return framePeriodNs > threshold;
    }

    /** Minimal ADPF hint session interface (plain Java, no Android dependency). */
    interface AdpfSession {
        void updateTargetWorkDuration(long nanos);

        void reportActualWorkDuration(long nanos);
    }

    /**
     * Unified ADPF target/boost policy state (drawing thread), shared across touch boost, IME warmup,
     * resume, session creation, and per-frame work reporting.
     */
    static class AdpfController {
        boolean boostActive;
        long hintTarget;
        long lastFrameWorkedNs;

        void reset() {
            boostActive = false;
            hintTarget = 0L;
        }

        private void refreshBoost(long framePeriodNs, float topRate, boolean pacedActive, boolean touching, float rateSaid) {
            if (!boostActive) return;
            if (!isStalePacedPeriod(framePeriodNs, topRate)
                    || (!touching && (pacedActive || rateSaid == 0f))) {
                boostActive = false;
            }
        }

        long targetNanos(long framePeriodNs, float topRate, boolean pacedActive, boolean touching, float rateSaid) {
            refreshBoost(framePeriodNs, topRate, pacedActive, touching, rateSaid);
            return adpfTargetNanos(framePeriodNs, topRate, boostActive);
        }

        boolean onSessionCreated(long target, AdpfSession session) {
            hintTarget = target;
            if (session != null && target > 0L) {
                session.reportActualWorkDuration(target);
                return true;
            }
            return false;
        }

        boolean beginTouchBoost(boolean fromPaced, long nowNs, long framePeriodNs, float topRate) {
            if (fromPaced) {
                if (isStalePacedPeriod(framePeriodNs, topRate)) {
                    boostActive = true;
                }
                return true;
            }
            if (boostActive) return true;
            return lastFrameWorkedNs == 0L || nowNs - lastFrameWorkedNs >= 250_000_000L;
        }

        void wake(long framePeriodNs, float topRate, boolean pacedActive, boolean touching, float rateSaid,
                  boolean created, AdpfSession session) {
            long target = targetNanos(framePeriodNs, topRate, pacedActive, touching, rateSaid);
            if (session == null) return;
            if (target > 0L && target != hintTarget) {
                hintTarget = target;
                session.updateTargetWorkDuration(target);
            }
            if (!created && hintTarget > 0L) {
                session.reportActualWorkDuration(hintTarget);
            }
        }

        void frameWorked(long nanos, long gl, long nowNs, long framePeriodNs, float topRate,
                         boolean pacedActive, boolean touching, float rateSaid, AdpfSession session) {
            lastFrameWorkedNs = nowNs;
            long target = targetNanos(framePeriodNs, topRate, pacedActive, touching, rateSaid);
            if (session == null) return;
            if (target > 0L && target != hintTarget) {
                hintTarget = target;
                session.updateTargetWorkDuration(target);
            }
            long actual = Math.max(nanos, gl);
            if (actual > 0L) session.reportActualWorkDuration(actual);
        }
    }
}
