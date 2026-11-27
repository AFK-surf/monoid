package dev.mbui;

import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Which vsync the app's next frame is drawn for, and what rate the surface says of the display (MBView's, kept apart
 * from Android so a test can run it: FramePacerTest, on its own clock and threads). MBView hands it the system's
 * vsyncs, the frames' work and the hand; it asks MBView's Platform for a vsync, a frame made and a rate said. Its
 * threads are MBView's: the main thread's (vsyncs, the hand), the drawing thread's (the app's thread, which makes the
 * frames, the GL thread drawing each it hands over; the GL thread itself with MBView.ONE: frames, the rate), any (a
 * frame wanted).
 *
 * <p>Thin facade wiring {@link FrameScheduler} (pure vsync/wake scheduling state machine),
 * {@link RateVoter} (display refresh-rate voting), and {@link FrameTelemetry} (frame continuity,
 * GL timing, and ADPF hints) behind the stable package-private API used by {@link MBView} and tests.
 */
final class FramePacer {
    /** What the pacer asks of the system (MBView's; the test's own). */
    interface Platform {
        /** The system's clock (ns), the vsyncs'. */
        long nanoTime();

        /** Whether this is the main thread. */
        boolean onMain();

        /** {@code r} run on the main thread, after what is there now. */
        void postMain(Runnable r);

        /** The next vsync asked for (main thread): {@link #vsyncCame} told at it. */
        void postVsync();

        /**
         * The next vsync asked for (main thread), tagged with generation {@code gen}:
         * {@link #vsyncCame(long, long, long)} told with the same {@code gen} when it arrives so each posted callback
         * clears only its own in-flight slot.
         */
        default void postVsync(long gen) {
            postVsync();
        }

        /** {@code r} run on the drawing thread once the next vsync has come (asked on the main thread). */
        void atNextVsyncOnDrawing(Runnable r);

        /** A frame made on the drawing thread, as soon as it can (MBView.makeFrame; GLSurfaceView's requestRender with ONE). */
        void requestRender();

        /** The surface says the display's rate {@code rate} (0: nothing); false where it cannot be said. */
        boolean setRate(float rate);

        /** Whether the app's field is being typed into (the focus, or the soft keyboard up over it). */
        boolean typing();

        /** Whether GL adaptive glass is currently settling and needs high refresh. */
        default boolean glSettling() {
            return false;
        }

        /** Whether a native view's picture recently redrew and needs high refresh. */
        default boolean pictureActive() {
            return false;
        }
    }

    /** Timed wake request: merges same-deadline requests in place under scheduler lock while preserving external demand. */
    static final class WakeReq {
        final long gen;
        final double at;
        volatile boolean pacedOnly;

        WakeReq(long gen, double at, boolean pacedOnly) {
            this.gen = gen;
            this.at = at;
            this.pacedOnly = pacedOnly;
        }

        boolean isPacedOnly() {
            return pacedOnly;
        }
    }

    /** Atomic snapshot of frame demand and vsync timeline taken by the drawing thread. */
    static final class Taken {
        final boolean app, pictured, external, picturedPaced;
        final long[] vsyncAt;
        final long continuityGen;

        Taken(boolean app, boolean pictured, boolean external, boolean picturedPaced, long[] vsyncAt, long continuityGen) {
            this.app = app;
            this.pictured = pictured;
            this.external = external;
            this.picturedPaced = picturedPaced;
            this.vsyncAt = vsyncAt;
            this.continuityGen = continuityGen;
        }
    }

    /** A frame of the app's begun (drawing thread): the time it is built for, how late it is, whether it follows. */
    static final class Begun {
        /** its vsync (0: none) and when it is shown (0: not said) */
        final long vsync, shows;
        /** the time it is built for (ms) and how late the frame before reached the screen (ms: @hostapi.frame_late) */
        final double now, late;
        /** drawn at the vsync after the frame before's: the hand moving what it holds, a frame each vsync */
        final boolean following;
        /** whether an external (non-paced) frame request triggered this frame */
        final boolean externalDemand;

        Begun(long vsync, long shows, double now, double late, boolean following, boolean externalDemand) {
            this.vsync = vsync;
            this.shows = shows;
            this.now = now;
            this.late = late;
            this.following = following;
            this.externalDemand = externalDemand;
        }
    }

    /** Dual GL timing reading: ADPF/work duration alongside raw wall time and measurement flags. */
    static final class GlTiming {
        final long workNs;
        final long rawWallNs;
        final boolean paced;
        final boolean swapMeasured;

        GlTiming(long workNs, long rawWallNs, boolean paced, boolean swapMeasured) {
            this.workNs = workNs;
            this.rawWallNs = rawWallNs;
            this.paced = paced;
            this.swapMeasured = swapMeasured;
        }
    }

    /** Minimal ADPF hint session interface (plain Java, no Android dependency). */
    interface AdpfSession extends FrameTelemetry.AdpfSession {
    }

    /** Unified ADPF target/boost policy state (drawing thread). */
    static final class AdpfState extends FrameTelemetry.AdpfController {
    }

    /**
     * The display's frame (ns), read as the view is shown and as the display changes its rate, and since Android 13 from
     * each vsync's timelines (main thread).
     */
    volatile long framePeriod = 16_666_667L;
    /** The display's highest rate at its size now (MBView's readFramePeriod). */
    volatile float topRate;
    /** Whether a finger is on the screen (main thread writes it, from its touches). */
    volatile boolean touching;

    final FrameTelemetry telemetry;
    final FrameScheduler scheduler;
    final RateVoter rateVoter;

    // Aliased to scheduler's demand flags for MBView and existing test compatibility.
    final AtomicBoolean appWanted;
    final AtomicBoolean picturesOnly;
    final AtomicBoolean externalWanted;

    FramePacer(Platform p) {
        this.telemetry = new FrameTelemetry();
        this.scheduler = new FrameScheduler(p, () -> this.framePeriod, this.telemetry::continuityGen);
        this.rateVoter = new RateVoter(p, new RateVoter.Probe() {
            @Override public boolean hasAppWanted() { return scheduler.appWanted.get(); }

            @Override public boolean isTouching() { return touching; }

            @Override public float topRate() { return topRate; }

            @Override public boolean consumeExternalForLastVsync() {
                return scheduler.consumeExternalForVsync(telemetry.lastVsync());
            }
        });
        this.appWanted = scheduler.appWanted;
        this.picturesOnly = scheduler.picturesOnly;
        this.externalWanted = scheduler.externalWanted;
    }

    // ---- scheduling delegation ----

    WakeReq scheduleWake(double at, boolean pacedOnly) {
        return scheduler.scheduleWake(at, pacedOnly);
    }

    void clearWake() {
        scheduler.clearWake();
    }

    boolean isWakeCurrent(WakeReq req) {
        return scheduler.isWakeCurrent(req);
    }

    void resetContinuity(long nowNs) {
        scheduler.resetContinuity(() -> telemetry.advanceContinuity(nowNs));
    }

    Taken takeRender() {
        return scheduler.takeRender();
    }

    void wantImmediateFrame() {
        scheduler.wantImmediateFrame();
    }

    void wakeFrameNow(long vsyncNs, long shows, boolean pacedOnly) {
        scheduler.wakeFrameNow(vsyncNs, shows, pacedOnly);
    }

    int fireWake(WakeReq req, long vsyncNs) {
        return scheduler.fireWake(req, vsyncNs, 0L);
    }

    int fireWake(WakeReq req, long vsyncNs, long shows) {
        return scheduler.fireWake(req, vsyncNs, shows);
    }

    void setImeMoving(boolean moving) {
        scheduler.setImeMoving(moving);
    }

    long[] vsyncAt() {
        return scheduler.vsyncAt();
    }

    /**
     * A vsync asked for came (main thread), at {@code t}, its frame shown at {@code shows} (vsyncAt): drawn for, where a
     * frame is wanted; where only the frame drawing now asked for it ahead (askAhead), kept for that frame to take as it
     * ends (ask), should it want one.
     */
    void vsyncCame(long t, long shows) {
        scheduler.vsyncCame(t, shows, 0L);
    }

    void vsyncCame(long t, long shows, long gen) {
        scheduler.vsyncCame(t, shows, gen);
    }

    void wantFrame() {
        scheduler.ask(true, true, false);
    }

    void wantPacedFrame() {
        scheduler.ask(true, false, false);
    }

    void pictureFrame() {
        pictureFrame(rateVoter.isPacedActive());
    }

    void pictureFrame(boolean fromPaced) {
        scheduler.ask(false, false, fromPaced);
    }

    void frameNow() {
        scheduler.frameNow();
    }

    void scheduleNext(boolean wantMore) {
        if (wantMore) wantFrame();
        else scheduler.clearAhead();
    }

    // ---- telemetry delegation ----

    void redrawn() {
        if (!scheduler.appWanted.get()) telemetry.clearAskedAtEnd();
    }

    Begun begin(long[] at, long began) {
        return begin(at, began, scheduler.externalWanted.getAndSet(false), telemetry.continuityGen());
    }

    Begun begin(long[] at, long began, boolean externalDemand) {
        return begin(at, began, externalDemand, telemetry.continuityGen());
    }

    Begun begin(long[] at, long began, boolean externalDemand, long gen) {
        return telemetry.begin(at, began, externalDemand, gen, framePeriod, scheduler::askAhead);
    }

    static long cpuDeltaNanos(long cpuStartNs, long cpuEndNs) {
        return FrameTelemetry.cpuDeltaNanos(cpuStartNs, cpuEndNs);
    }

    static long glWorkNanos(long drawStartNs, long drawEndNs, long swapDoneNs, long cpuDeltaNs, boolean pacedSwap) {
        return FrameTelemetry.glWorkNanos(drawStartNs, drawEndNs, swapDoneNs, cpuDeltaNs, pacedSwap);
    }

    static long adpfTargetNanos(long framePeriodNs, float topRate, boolean clampToTop) {
        return FrameTelemetry.adpfTargetNanos(framePeriodNs, topRate, clampToTop);
    }

    static boolean isStalePacedPeriod(long framePeriodNs, float topRate) {
        return FrameTelemetry.isStalePacedPeriod(framePeriodNs, topRate);
    }

    static GlTiming measureGl(long d0, long drawEnd, long swapEnd, long cpuDeltaNs, boolean paced, boolean swapMeasured) {
        return FrameTelemetry.measureGl(d0, drawEnd, swapEnd, cpuDeltaNs, paced, swapMeasured);
    }

    // ---- rate voting delegation ----

    /**
     * The app's frame ended (drawing thread): whether it asks for another ({@code more}, what it said; {@code later}, a
     * back said for a later vsync), whether it followed the one before (Begun's), and the rate what moves on by the
     * clock alone needs where the frame said one ({@code paced}, MBView.framesPaced: its next woken for, not asked for
     * here; 0 none): the rate said, the next asked for. Paced, what moves is said at its rate, the display free to
     * refresh as slowly; anything else moving, at the display's highest.
     */
    void ended(boolean more, boolean later, boolean following, float paced) {
        ended(more, later, following, paced, false);
    }

    void ended(boolean more, boolean later, boolean following, float paced, boolean externalDemand) {
        applyRate(more, later, following, paced, externalDemand);
        scheduleNext(more || later);
    }

    boolean applyRate(boolean more, boolean later, boolean following, float paced, boolean externalDemand) {
        telemetry.noteFrameEnded(more || later);
        return rateVoter.applyRate(more, later, following, paced, externalDemand);
    }

    float rateSaid() {
        return rateVoter.rateSaid();
    }

    boolean isPacedActive() {
        return rateVoter.isPacedActive();
    }

    boolean sayRate(boolean on) {
        return rateVoter.sayRate(on);
    }

    void recheckRate() {
        rateVoter.recheckRate();
    }

    void surfaceReset() {
        rateVoter.surfaceReset();
    }

    void typingChanged() {
        rateVoter.typingChanged();
    }
}
