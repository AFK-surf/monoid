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
     */
    FramePacer.Begun begin(long[] at, long began, boolean externalDemand, long gen,
                           long framePeriodNs, Runnable onAskAhead) {
        if (seenContinuityGen != gen) {
            seenContinuityGen = gen;
            lastVsync = 0L;
            askedAtEnd = false;
        }
        if (askedAtEnd && onAskAhead != null) onAskAhead.run();
        long v = at[0];
        long minV = minValidVsyncNs;
        if (v != 0L && minV != 0L && v < minV) v = 0L;
        double now = v != 0L ? v / 1e6 : began / 1e6;
        if (now < lastFrame) now = lastFrame;
        lastFrame = now;
        double late = 0;
        if (v != 0L && lastVsync != 0L && askedAtEnd) {
            long frames = Math.round((double) (v - lastVsync) / framePeriodNs);
            if (frames > 1) late = (frames - 1) * framePeriodNs / 1e6;
        }
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
