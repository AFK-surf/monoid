package dev.mbui;

/**
 * The rate this surface's frames want of the display (Surface.setFrameRate), said as the system's own views say
 * theirs (a list flung, a view moved: Android 15's frame rate categories): the display's highest while the app
 * draws frame after frame (a motion, the hand moving what it holds), and from a finger going down (as the system's
 * touch boost: the motion it starts is not where the display goes over to it) until it lifts; nothing once a vsync
 * passes with none drawn and no finger on the screen. Withdrawn as a single vsync passed with none drawn while a
 * finger was down, it went down and up again within a gesture, wherever a vsync brought no touch (a finger slowing,
 * the touches' own rate a little off the display's), and each change of the display's rate can step what moves (OPPO
 * Find N6, 0.1.5814: scrolling stepped all along, its frames 1.3–2.7 ms).
 * A surface that says nothing is left at the rate the system picks for it from how often its buffers came: a phone
 * that does 120 Hz (an OPPO Find N6) kept the display at 60 for the app, every motion with half the frames its
 * own views' get. Said only while it moves: a rate said keeps the display at it for as long as the surface shows,
 * still or not.
 *
 * <p>All mutable voting state is owned by the drawing thread, with a single volatile mirror
 * ({@link #pacedActive}) readable lock-free by the GL thread. Interacts with {@link FrameScheduler}
 * solely through the explicit {@link Probe} callbacks (including {@code consumeExternalForLastVsync}).
 */
final class RateVoter {
    /** Read-only probe into scheduler/view state needed by refresh-rate policy. */
    interface Probe {
        boolean hasAppWanted();

        boolean isTouching();

        float topRate();

        boolean consumeExternalForLastVsync();
    }

    private final FramePacer.Platform p;
    private final Probe probe;

    /** The rate this surface says of the display now (drawing thread; 0 none: a new surface says nothing). */
    private float rateSaid;
    /** Whether the current rate vote is a low-rate paced vote (drawing thread). */
    private boolean pacedSaid;
    /** Read-only mirror of {@link #pacedSaid} for the GL thread to check without a data race. */
    private volatile boolean pacedActive;
    /** Surface generation counter: invalidates stale stillFor countdowns across surface recreation (drawing thread). */
    private int surfaceGen;
    /** The app's frames drawn (drawing thread): one drawn since a frame that asked for none is told by it. */
    private int drawn;
    /** The last frame drawn that moved something (drawing thread): a motion, the hand moving what it holds. */
    private int moved;
    /** The motion whose end is being counted down to saying no rate (drawing thread; -1 none). */
    private int stillFrom = -1;

    RateVoter(FramePacer.Platform p, Probe probe) {
        this.p = p;
        this.probe = probe;
    }

    private boolean nonPacedActive() {
        return p.glSettling() || p.pictureActive();
    }

    /** The rate the surface says of the display now (drawing thread; 0 none). */
    float rateSaid() {
        return rateSaid;
    }

    /** Whether the surface is currently holding a low-rate paced vote (readable from any thread). */
    boolean isPacedActive() {
        return pacedActive;
    }

    /** Applies the frame's display-rate vote and returns whether a low-rate paced vote is active. */
    boolean applyRate(boolean more, boolean later, boolean following, float paced, boolean externalDemand) {
        boolean ext = externalDemand || probe.consumeExternalForLastVsync();
        boolean touching = probe.isTouching();
        float topRate = probe.topRate();
        drawn++;
        if (paced > 0 && !more && !later && !touching && !p.typing() && !ext
                && !probe.hasAppWanted() && !nonPacedActive()) {
            moved = drawn;
            if (sayRate(paced)) {
                pacedSaid = true;
                pacedActive = true;
                // Dekker barrier recheck: if GL thread set nonPacedActive just as pacedActive became true, lift now.
                if (nonPacedActive()) recheckRate();
            }
        } else {
            boolean wasPaced = pacedSaid;
            if (wasPaced && paced == 0 && !more && !later && !touching && !p.typing()
                    && !ext && !nonPacedActive() && !probe.hasAppWanted()) {
                // Pure paced animation ended naturally (even with following==true on 50ms LTPO): drop directly to 0.
                if (!sayRate(false)) retryRelease(drawn, surfaceGen, 0);
            } else if (more || later || following || p.typing() || touching) {
                if (topRate > 0) {
                    if (sayRate(true)) {
                        moved = drawn;
                        if (!more && !later && !p.typing() && !touching && rateSaid != 0) stillAfter(moved);
                    }
                } else if (wasPaced) {
                    if (!sayRate(false)) retryRelease(drawn, surfaceGen, 0);
                }
            } else if (wasPaced || paced > 0) {
                if (topRate > 0) {
                    if (sayRate(true)) {
                        moved = drawn;
                        if (rateSaid != 0) stillAfter(moved);
                    }
                } else {
                    if (!sayRate(false)) retryRelease(drawn, surfaceGen, 0);
                }
            } else if (rateSaid != 0) {
                stillAfter(moved);
            }
        }
        return pacedActive;
    }

    /** The surface says the display's highest rate, or nothing (drawing thread). */
    boolean sayRate(boolean on) {
        float topRate = probe.topRate();
        if (on && topRate <= 0) return false;
        if (sayRate(on ? topRate : 0)) {
            pacedSaid = false;
            pacedActive = false;
            return true;
        }
        return false;
    }

    /** The surface says the display's rate {@code rate} (drawing thread; 0 nothing). */
    private boolean sayRate(float rate) {
        if (rate == rateSaid) return true;
        if (p.setRate(rate)) {
            rateSaid = rate;
            return true;
        }
        return false;
    }

    /** Exits a low-rate paced vote immediately if non-paced work became active (drawing thread). */
    void recheckRate() {
        if (!pacedSaid || !nonPacedActive()) return;
        if (probe.topRate() > 0) {
            if (sayRate(true)) {
                moved = ++drawn;
                if (rateSaid != 0) stillAfter(moved);
            }
        } else {
            if (!sayRate(false)) retryRelease(drawn, surfaceGen, 0);
        }
    }

    /** Bounded retry when releasing a paced vote via setRate(0) fails transiently (drawing thread). */
    private void retryRelease(int at, int gen, int attempts) {
        if (attempts >= 3) return;
        p.atNextVsyncOnDrawing(() -> {
            if (gen != surfaceGen || drawn != at || probe.hasAppWanted()
                    || probe.isTouching() || p.typing() || rateSaid == 0) {
                return;
            }
            if (!sayRate(false)) retryRelease(at, gen, attempts + 1);
        });
    }

    /** Resets surface-bound rate state when the Surface is destroyed (drawing thread). */
    void surfaceReset() {
        surfaceGen++;
        rateSaid = 0;
        pacedSaid = false;
        pacedActive = false;
        stillFrom = -1;
    }

    /**
     * The motion that ended with frame {@code at} (drawing thread): no rate said once the display's highest rate's worth of
     * vsyncs (a second) passed with nothing moved since, none asked and no finger down. A frame drawn meanwhile that moves
     * nothing (a spinner's step, a page's words coming in) does not keep it. Said at once after the motion, the display
     * went down to the rate the system picks from how often frames came (a spinner stepping: 12-60 Hz on an OPPO Find
     * N6), and the next flick's first frames stepped up through it at 83, 17, 17, 17 ms before 8.3 (2026-11-04: 5-8
     * frames at the start of every swipe, the app's own work 2-5 ms each): a list is flicked again well within a second.
     */
    private void stillAfter(int at) {
        if (stillFrom == at) return;
        stillFrom = at;
        stillFor(at, surfaceGen, Math.max(1, Math.round(probe.topRate())), 0);
    }

    private void stillFor(int at, int gen, int left, int failRetries) {
        p.atNextVsyncOnDrawing(() -> {
            if (gen != surfaceGen) return;
            if (moved != at || probe.hasAppWanted() || probe.isTouching() || p.typing() || rateSaid == 0) {
                if (stillFrom == at) stillFrom = -1;
                return;
            }
            if (p.glSettling()) {
                stillFor(at, gen, Math.max(1, Math.round(probe.topRate())), 0);
                return;
            }
            if (left > 1) {
                stillFor(at, gen, left - 1, 0);
                return;
            }
            if (sayRate(false)) {
                stillFrom = -1;
            } else if (failRetries < 3) {
                stillFrom = at;
                stillFor(at, gen, 1, failRetries + 1);
            } else if (stillFrom == at) {
                stillFrom = -1;
            }
        });
    }

    /** The field's typing begun or ended (drawing thread): the rate said or let go from now. */
    void typingChanged() {
        if (p.typing()) sayRate(true);
        else if (rateSaid != 0) stillAfter(moved);
    }
}
