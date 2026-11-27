package dev.mbui;

import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Pure Android frame-scheduling state machine with single-lock ownership and zero timestamp-based
 * control flow for vsync slot ownership.
 *
 * <p>Constructive liveness invariant (fail-open): whenever undispatched demand exists
 * ({@code (appWanted && !appDispatched) || picturesOnly}), at least one of the following holds once
 * the lock is released: (1) an active Choreographer callback generation ({@code activeVsyncGen != 0})
 * is in flight, (2) a deferred IME flush ({@code deferredVsync}) is queued on the main thread, or
 * (3) {@link FramePacer.Platform#requestRender()} is invoked immediately outside the lock.
 *
 * <p>No {@link FramePacer.Platform} callback is ever invoked while holding {@link #lock}.
 */
final class FrameScheduler {
    interface PeriodSource {
        long framePeriodNs();
    }

    interface ContinuitySource {
        long continuityGen();
    }

    private static final long ACT_NONE = 0L;
    private static final long ACT_RENDER = -1L;
    private static final long ACT_FLUSH = -2L;

    private final FramePacer.Platform p;
    private final PeriodSource periodSource;
    private final ContinuitySource continuitySource;

    /** Single lock guarding all scheduling, IME deferral, and timed-wake state. */
    private final Object lock = new Object();

    /** Frame demand flags (exposed through FramePacer for MBView/tests). */
    final AtomicBoolean appWanted = new AtomicBoolean();
    final AtomicBoolean picturesOnly = new AtomicBoolean();
    final AtomicBoolean externalWanted = new AtomicBoolean();

    /** External demand arriving for an already-dispatched vsync, consumed at that frame's ended(). */
    private long externalForVsync;

    /**
     * The vsync the next frame is drawn for and when the system is to show it (ns; 0: not said).
     * Written under {@link #lock}; volatile for lock-free reads by {@link #vsyncAt()}.
     */
    private volatile long[] vsyncAt = {0L, 0L};

    /**
     * A vsync asked for ahead arrived with no pending demand: the next frame wanted within one
     * display period is drawn immediately for it.
     */
    private boolean ahead;
    /** Whether the current vsyncAt has been dispatched for an app frame (prevents stealing T+1's appWanted). */
    private boolean appDispatched;
    /** Whether a pending picture-only redraw originated while a low-rate paced vote was active. */
    private boolean picturedFromPaced;

    /** Monotonic generation counter for posted Choreographer callbacks (> 0). */
    private long nextVsyncGen;
    /** Generation of the sole in-flight Choreographer callback, or 0 when none is in flight. */
    private long activeVsyncGen;
    /** Last vsync timestamp dispatched for an app frame (used only for same-vsync deduplication). */
    private long lastAppDispatchedVsyncNs;
    /** Wall-clock timestamp of the most recent {@link #frameNow()} dispatch. */
    private long lastFrameNowAt;

    // Main-thread state for coalescing CALLBACK_ANIMATION (vsyncCame) with CALLBACK_INSETS_ANIMATION (frameNow).
    private boolean imeMoving;
    private boolean deferredVsync;
    private boolean deferredFromVsync;
    private boolean deferredWakeApp;
    private boolean deferredWakeExternal;
    private long deferredVsyncT;
    private long deferredVsyncShows;
    private long deferredVsyncGen;

    // Timed wake state (previously guarded by a separate wakeLock; unified under lock).
    private long wakeGen;
    private FramePacer.WakeReq wakeReq;

    FrameScheduler(FramePacer.Platform p, PeriodSource periodSource, ContinuitySource continuitySource) {
        this.p = p;
        this.periodSource = periodSource;
        this.continuitySource = continuitySource;
    }

    /** The vsync the frame beginning now is for (its time, when it is shown; 0: not said). */
    long[] vsyncAt() {
        return vsyncAt;
    }

    /** Schedules or upgrades a timed wake; returns the new request to post, or null if an earlier/same one stands. */
    FramePacer.WakeReq scheduleWake(double at, boolean pacedOnly) {
        synchronized (lock) {
            if (wakeReq != null) {
                if (wakeReq.at < at) return null;
                if (wakeReq.at == at) {
                    if (!pacedOnly) wakeReq.pacedOnly = false;
                    return null;
                }
            }
            FramePacer.WakeReq next = new FramePacer.WakeReq(++wakeGen, at, pacedOnly);
            wakeReq = next;
            return next;
        }
    }

    /** Clears any pending timed wake (called as a new app frame begins). */
    void clearWake() {
        synchronized (lock) {
            wakeReq = null;
        }
    }

    /** Whether {@code req} is still the active scheduled wake. */
    boolean isWakeCurrent(FramePacer.WakeReq req) {
        synchronized (lock) {
            return req != null && wakeReq == req;
        }
    }

    /** Consumes external demand recorded for {@code vsyncNs} if it matches. */
    boolean consumeExternalForVsync(long vsyncNs) {
        if (vsyncNs == 0L) return false;
        synchronized (lock) {
            if (externalForVsync == vsyncNs) {
                externalForVsync = 0L;
                return true;
            }
            return false;
        }
    }

    /**
     * Resets scheduling state across pause/resume or surface destruction.
     * Unconditionally invalidates any in-flight vsync generation, preserves pending demand
     * (including deferredWakeApp), invokes {@code onContinuityReset} atomically under {@link #lock},
     * and re-arms a fresh vsync whenever demand remains.
     */
    void resetContinuity(Runnable onContinuityReset) {
        long postGen = 0L;
        synchronized (lock) {
            if (deferredWakeApp) {
                if (deferredWakeExternal) externalWanted.set(true);
                appWanted.set(true);
            }
            vsyncAt = new long[] {0L, 0L};
            ahead = false;
            appDispatched = false;
            deferredVsync = false;
            deferredFromVsync = false;
            deferredVsyncGen = 0L;
            deferredWakeApp = false;
            deferredWakeExternal = false;
            activeVsyncGen = 0L;
            if (onContinuityReset != null) onContinuityReset.run();
            if (appWanted.get() || picturesOnly.get()) {
                postGen = claimPostVsyncLocked();
            }
        }
        if (postGen != 0L) postVsyncOutOfLock(postGen);
    }

    /** Atomically consumes pending frame flags, reads vsyncAt, and claims vsyncAt[0] when building an app frame. */
    FramePacer.Taken takeRender() {
        synchronized (lock) {
            boolean app = appDispatched && appWanted.getAndSet(false);
            if (app) {
                appDispatched = false;
                ahead = false;
            }
            boolean pictured = picturesOnly.getAndSet(false);
            boolean picturedPaced = pictured && picturedFromPaced;
            if (pictured) picturedFromPaced = false;
            boolean external = app && externalWanted.getAndSet(false);
            long[] at = vsyncAt;
            long gen = continuitySource.continuityGen();
            if (app && at[0] != 0L) lastAppDispatchedVsyncNs = at[0];
            return new FramePacer.Taken(app, pictured, external, picturedPaced, at, gen);
        }
    }

    /** Marks an immediate app frame without waiting for the next vsync (e.g. mid-frame imeBottom change). */
    void wantImmediateFrame() {
        synchronized (lock) {
            appWanted.set(true);
            appDispatched = true;
        }
    }

    /** Delivers a due timed wake directly on the current Choreographer vsync (main thread). */
    void wakeFrameNow(long vsyncNs, long shows, boolean pacedOnly) {
        long act;
        synchronized (lock) {
            act = wakeFrameNowLocked(vsyncNs, shows, pacedOnly);
        }
        finishAction(act);
    }

    /**
     * Evaluates a scheduled wake at Choreographer {@code doFrame(vsyncNs)} / {@code onVsync(vsyncNs, shows)}:
     * 0 = stale/replaced, 1 = not yet due (re-post next vsync), 2 = delivered on this vsync.
     */
    int fireWake(FramePacer.WakeReq req, long vsyncNs, long shows) {
        long act;
        synchronized (lock) {
            if (req == null || wakeReq != req) return 0;
            if (vsyncNs / 1e6 < req.at) return 1;
            wakeReq = null;
            act = wakeFrameNowLocked(vsyncNs, shows, req.pacedOnly);
        }
        finishAction(act);
        return 2;
    }

    /** Whether the soft keyboard's inset animation is under way (main thread). */
    void setImeMoving(boolean moving) {
        long act = ACT_NONE;
        synchronized (lock) {
            imeMoving = moving;
            if (moving) {
                act = claimPostVsyncLocked();
            } else if (deferredVsync) {
                act = flushDeferredVsyncLocked();
            }
        }
        finishAction(act);
    }

    /** Generation-tagged {@code vsyncCame} paired with {@link FramePacer.Platform#postVsync(long)}. */
    void vsyncCame(long t, long shows, long gen) {
        long act;
        synchronized (lock) {
            if (gen != 0L && gen != activeVsyncGen) {
                return;
            }
            if (shows != 0L && vsyncAt[0] == t && vsyncAt[1] == 0L) {
                vsyncAt = new long[] {t, shows};
            }
            if (lastFrameNowAt != 0L && t <= lastFrameNowAt && lastFrameNowAt - t < periodSource.framePeriodNs() / 2L) {
                act = handleDuplicateVsyncLocked(gen);
            } else if (imeMoving) {
                deferredVsyncT = t;
                deferredVsyncShows = shows;
                deferredVsync = true;
                deferredFromVsync = true;
                deferredVsyncGen = gen;
                act = ACT_FLUSH;
            } else {
                act = dispatchVsyncLocked(t, shows, true, gen);
            }
        }
        finishAction(act);
    }

    /** Requests the next vsync ahead of time while the current frame is still being built. */
    void askAhead() {
        long postGen;
        synchronized (lock) {
            ahead = false;
            postGen = claimPostVsyncLocked();
        }
        if (postGen != 0L) p.postMain(() -> p.postVsync(postGen));
    }

    /** A frame wanted (from any thread): drawn immediately for a fresh kept vsync, or at the next vsync. */
    void ask(boolean forApp, boolean isExternal, boolean fromPaced) {
        long now = p.nanoTime();
        long act = ACT_NONE;
        synchronized (lock) {
            if (forApp) {
                if (isExternal) externalWanted.set(true);
                appWanted.set(true);
            } else {
                picturesOnly.set(true);
                if (fromPaced) picturedFromPaced = true;
            }
            boolean alreadyPendingForT = false;
            if (ahead) {
                ahead = false;
                if (now - vsyncAt[0] < periodSource.framePeriodNs()) {
                    long t = vsyncAt[0];
                    if (forApp && t != 0L && lastAppDispatchedVsyncNs == t) {
                        if (appDispatched) alreadyPendingForT = true;
                    } else {
                        if (forApp) {
                            if (t != 0L) lastAppDispatchedVsyncNs = t;
                            appDispatched = true;
                        }
                        act = ACT_RENDER;
                    }
                }
            }
            if (!alreadyPendingForT && act == ACT_NONE) {
                act = claimPostVsyncLocked();
            }
        }
        finishAction(act);
    }

    /** Clears the ahead slot when a frame finishes without requesting another frame. */
    void clearAhead() {
        synchronized (lock) {
            ahead = false;
        }
    }

    /** A frame now, at the vsync being drawn (main thread, within a Choreographer frame: the keyboard's motion). */
    void frameNow() {
        long now = p.nanoTime();
        long postGen = 0L;
        synchronized (lock) {
            externalWanted.set(true);
            appWanted.set(true);
            appDispatched = true;
            ahead = false;
            lastFrameNowAt = now;
            long dt = deferredVsync ? deferredVsyncT : now;
            if (dt != 0L) lastAppDispatchedVsyncNs = dt;
            if (deferredVsync) {
                boolean fromVsync = deferredFromVsync;
                long defGen = deferredVsyncGen;
                deferredVsync = false;
                deferredFromVsync = false;
                deferredVsyncGen = 0L;
                deferredWakeApp = false;
                deferredWakeExternal = false;
                vsyncAt = new long[] {deferredVsyncT, deferredVsyncShows};
                if (fromVsync) clearActiveVsyncLocked(defGen);
            } else {
                vsyncAt = new long[] {now, 0L};
            }
            if (imeMoving) {
                postGen = claimPostVsyncLocked();
            }
        }
        p.requestRender();
        if (postGen != 0L) postVsyncOutOfLock(postGen);
    }

    // ---- locked state-machine helpers ----

    private long claimPostVsyncLocked() {
        if (activeVsyncGen != 0L) return ACT_NONE;
        long gen = ++nextVsyncGen;
        activeVsyncGen = gen;
        return gen;
    }

    /**
     * Releases the active in-flight Choreographer slot.
     * Tagged callbacks ({@code gen != 0L}) release only their own generation; untagged legacy
     * 2-arg callbacks ({@code gen == 0L}) fail open and release unconditionally without any
     * timestamp comparison.
     */
    private void clearActiveVsyncLocked(long gen) {
        if (gen == 0L || gen == activeVsyncGen) {
            activeVsyncGen = 0L;
        }
    }

    /** Handles a duplicate vsync callback for an already-dispatched vsync (inside lock). */
    private long handleDuplicateVsyncLocked(long gen) {
        clearActiveVsyncLocked(gen);
        boolean app = appWanted.get();
        if (app && !appDispatched) {
            return claimPostVsyncLocked();
        }
        if (!app && picturesOnly.get()) {
            return ACT_RENDER;
        }
        if (gen != 0L && imeMoving) {
            return claimPostVsyncLocked();
        }
        return ACT_NONE;
    }

    private long wakeFrameNowLocked(long vsyncNs, long shows, boolean pacedOnly) {
        if (vsyncNs != 0L && lastAppDispatchedVsyncNs == vsyncNs) {
            if (!pacedOnly) externalForVsync = vsyncNs;
            return ACT_NONE;
        }
        if (imeMoving) {
            deferredWakeApp = true;
            if (!pacedOnly) deferredWakeExternal = true;
            ahead = false;
            if (!deferredVsync) {
                deferredVsyncT = vsyncNs;
                deferredVsyncShows = shows;
                deferredVsync = true;
                deferredFromVsync = false;
                deferredVsyncGen = 0L;
                return ACT_FLUSH;
            }
            if (deferredVsyncShows == 0L && shows != 0L) {
                deferredVsyncShows = shows;
            }
            return ACT_NONE;
        }
        if (!pacedOnly) externalWanted.set(true);
        appWanted.set(true);
        appDispatched = true;
        ahead = false;
        if (vsyncNs != 0L) lastAppDispatchedVsyncNs = vsyncNs;
        lastFrameNowAt = vsyncNs;
        if (deferredVsync) {
            boolean fromVsync = deferredFromVsync;
            long defGen = deferredVsyncGen;
            deferredVsync = false;
            deferredFromVsync = false;
            deferredVsyncGen = 0L;
            deferredWakeApp = false;
            deferredWakeExternal = false;
            vsyncAt = new long[] {deferredVsyncT, deferredVsyncShows};
            if (fromVsync) clearActiveVsyncLocked(defGen);
        } else {
            long s = shows != 0L ? shows : (vsyncAt[0] == vsyncNs ? vsyncAt[1] : 0L);
            vsyncAt = new long[] {vsyncNs, s};
        }
        return ACT_RENDER;
    }

    private long dispatchVsyncLocked(long t, long shows, boolean fromVsync, long gen) {
        vsyncAt = new long[] {t, shows};
        boolean app = appWanted.get();
        if (t != 0L && lastAppDispatchedVsyncNs == t) {
            if (fromVsync) {
                return handleDuplicateVsyncLocked(gen);
            }
            return (!app && picturesOnly.get()) ? ACT_RENDER : ACT_NONE;
        }
        if (app || picturesOnly.get()) {
            ahead = false;
            if (fromVsync) clearActiveVsyncLocked(gen);
            if (app) {
                if (t != 0L) lastAppDispatchedVsyncNs = t;
                appDispatched = true;
            }
            return ACT_RENDER;
        }
        ahead = true;
        if (fromVsync) clearActiveVsyncLocked(gen);
        // Defensive re-check if appWanted was set directly outside lock before wantFrame().
        boolean app2 = appWanted.get();
        if ((app2 || picturesOnly.get()) && ahead) {
            ahead = false;
            if (app2) {
                if (t != 0L) lastAppDispatchedVsyncNs = t;
                appDispatched = true;
            }
            return ACT_RENDER;
        }
        return ACT_NONE;
    }

    private long flushDeferredVsyncLocked() {
        if (!deferredVsync) return ACT_NONE;
        boolean fromVsync = deferredFromVsync;
        long defGen = deferredVsyncGen;
        deferredVsync = false;
        deferredFromVsync = false;
        deferredVsyncGen = 0L;
        long t = deferredVsyncT;
        long shows = deferredVsyncShows;
        vsyncAt = new long[] {t, shows};
        if (deferredWakeApp) {
            if (deferredWakeExternal) externalWanted.set(true);
            appWanted.set(true);
            deferredWakeApp = false;
            deferredWakeExternal = false;
        }
        return dispatchVsyncLocked(t, shows, fromVsync, defGen);
    }

    private void flushDeferredVsync() {
        long act;
        synchronized (lock) {
            act = flushDeferredVsyncLocked();
        }
        finishAction(act);
    }

    private void finishAction(long act) {
        if (act == ACT_RENDER) {
            p.requestRender();
        } else if (act == ACT_FLUSH) {
            p.postMain(this::flushDeferredVsync);
        } else if (act > 0L) {
            postVsyncOutOfLock(act);
        }
    }

    private void postVsyncOutOfLock(long gen) {
        if (gen == 0L) return;
        if (p.onMain()) p.postVsync(gen);
        else p.postMain(() -> p.postVsync(gen));
    }

    // ---- package-private state inspection for property tests ----

    long activeVsyncGen() {
        synchronized (lock) {
            return activeVsyncGen;
        }
    }

    boolean hasDeferredVsync() {
        synchronized (lock) {
            return deferredVsync;
        }
    }

    boolean isAppDispatched() {
        synchronized (lock) {
            return appDispatched;
        }
    }

    boolean hasUndispatchedDemand() {
        synchronized (lock) {
            return (appWanted.get() && !appDispatched) || picturesOnly.get();
        }
    }
}
