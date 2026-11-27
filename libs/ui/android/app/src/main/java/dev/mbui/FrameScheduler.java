package dev.mbui;

import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Pure Android frame-scheduling state machine with single-lock ownership where Choreographer vsync
 * slot ownership and release never depend on timestamps.
 *
 * <p>Production callbacks use the generation-tagged 3-arg path
 * ({@link FramePacer.Platform#postVsync(long)} -> {@link #vsyncCame(long, long, long)}), where each
 * callback releases only its own {@code activeVsyncGen} slot and stale generations are ignored.
 * Legacy untagged 2-arg {@code vsyncCame(t, shows)} ({@code gen == 0L}) fails open by releasing
 * the slot and re-arming whenever undispatched demand exists. Timestamps ({@link #lastFrameNowAt},
 * {@link #lastAppDispatchedVsyncNs}, and {@link #ahead} freshness) are used only for same-vsync
 * deduplication and prefetch expiry, never to refuse releasing a vsync slot.
 *
 * <p>Constructive liveness invariant (fail-open): whenever undispatched demand exists
 * ({@code (appWanted && !appDispatched) || picturesOnly}), at least one of the following holds once
 * {@link #lock} is released: (1) an active Choreographer callback generation
 * ({@code activeVsyncGen != 0}) is in flight, (2) a deferred IME flush ({@code deferredVsync}) is
 * queued on the main thread, or (3) {@link FramePacer.Platform#requestRender()} is invoked
 * immediately outside the lock.
 *
 * <p>No dispatching/re-entrant {@link FramePacer.Platform} callback ({@code requestRender},
 * {@code postVsync}, {@code postMain}, {@code setRate}) is ever invoked while holding {@link #lock};
 * only the side-effect-free monotonic clock {@link FramePacer.Platform#nanoTime()} is sampled
 * inside the lock.
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
     * The vsync the next frame is drawn for and when the system is to show it (ns, the system's clock; 0: not said): since
     * Android 13, the expected presentation of the vsync's preferred frame timeline (Choreographer.FrameData), the
     * refresh a frame of the system's own drawn for that vsync is shown at.
     * Written under {@link #lock}; volatile for lock-free reads by {@link #vsyncAt()}.
     */
    private volatile long[] vsyncAt = {0L, 0L};

    /**
     * A vsync asked for ahead came and no frame was drawn for it (vsyncCame): the next frame wanted is drawn at once,
     * for it, while it is the latest vsync (a frame later than that is the next vsync's).
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
    /**
     * Timestamp of the most recent immediate dispatch: wall-clock {@code nanoTime()} from
     * {@link #frameNow()} or {@code vsyncNs} from {@link #wakeFrameNow(long, long, boolean)}.
     */
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
            lastFrameNowAt = 0L;
            lastAppDispatchedVsyncNs = 0L;
            externalForVsync = 0L;
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
     * Evaluates a scheduled wake at Choreographer {@code doFrame(vsyncNs)} / {@code onVsync(vsyncNs, shows)} (main thread):
     * 0 = stale/replaced, 1 = not yet due (re-post next vsync), 2 = delivered on this vsync.
     * Fires strictly on the first vsync with {@code vsyncNs / 1e6 >= req.at}, avoiding early-tolerance or
     * predicted-period pre-arming that would render a wasted early frame near a boundary or across LTPO rate changes.
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

    /**
     * A vsync asked for came (main thread), at {@code t}, its frame shown at {@code shows} (vsyncAt): drawn for, where a
     * frame is wanted; where only the frame drawing now asked for it ahead (askAhead), kept for that frame to take as it
     * ends (ask), should it want one. Paired with {@link FramePacer.Platform#postVsync(long)} via {@code gen}.
     */
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
                long t = vsyncAt[0];
                long age = p.nanoTime() - t;
                if (age >= 0L && age < periodSource.framePeriodNs()) {
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

    /**
     * A frame now, at the vsync being drawn (main thread, within a Choreographer frame: the keyboard's motion), not the
     * next. (The frame's own vsync time is not public: now, a moment after it, never before a frame drawn; shown as soon
     * as it is drawn.)
     */
    void frameNow() {
        long postGen = 0L;
        synchronized (lock) {
            externalWanted.set(true);
            appWanted.set(true);
            appDispatched = true;
            ahead = false;
            long now = p.nanoTime();
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
        // (a frame wanted as this was kept: the one asking saw it not yet kept, and asked for another vsync, or none)
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

    // ---- package-private state inspection for tests ----

    boolean holdsLockForTest() {
        return Thread.holdsLock(lock);
    }

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
