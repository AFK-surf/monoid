package dev.mbui;

/**
 * libmbui.so: the MoonBit app, its runtime and the C side of the host. What calls into MoonBit (start, frame, the
 * input, what it is told) runs on the app's thread (MBView's: the GL thread's with MBView.ONE); what draws, on the GL
 * thread.
 */
final class Native {
    static {
        System.loadLibrary("mbui");
    }

    static native void start();
    /** MoonBit on a thread of its own, the frames handed over to the GL thread (MBView, before start). */
    static native void twoThreads();
    /** Drawing set up in the GL context now current; whether one was set up before (its textures lost). */
    static native boolean surfaceCreated();
    static native void resize(int w, int h);
    /** A frame at `now`, the one before it `late` ms late to the screen (@hostapi.frame_late). */
    static native boolean frame(float w, float h, float scale, double now, double late);
    /** The last frame drawn again as it was presented, the native views' pictures as they are now (android_host.c). */
    static native void redraw();
    /** The frame the app made handed over (its thread, under MBView's lock): whether it made one. */
    static native boolean publish();
    /**
     * The frame handed over taken as the one kept (GL thread, under MBView's lock): to be drawn ({@code shown}), or only
     * read back (MBView.glSync: the next frame drawn whole); whether there was one.
     */
    static native boolean take(boolean shown);
    /** The frame handed over let go undrawn (under MBView's lock: made before the GL context it would be drawn in). */
    static native void dropPending();
    /** The frame taken drawn (GL thread). */
    static native void draw();
    /** What drawing holds beyond its frames given back (GL thread, its context current: MBView.trim). */
    static native void trim();
    /** What the app's thread waits for of the GL context done (GL thread: MBView.glSync). */
    static native void glSync();
    static native void pointer(int kind, float x, float y, double time);
    /** A touch screen's finger (kind 10 down, 11 moved, 12 up, 13 called off), by its pointer id, at its own time. */
    static native void touch(int kind, int id, float x, float y, double time);
    static native void key(int code, int mods);
    static native void text(int kind, String s, int a, int b);
    static native void back(int kind, float x, float progress, int edge);
    static native void appState(int state);
    /** Over another app (OverActivity) or not: what the app does not paint is left clear (android_host.c present). */
    static native void overOther(boolean on);
    /** The device slowed for its heat or not (MainActivity's thermal listener): glass drawn solid (android_host.c). */
    static native void thermal(boolean hot);
    /** Whether a screen reader is active (A11y): cached in C atomic so mb_host_a11y_on needs no JNI per frame. */
    static native void a11yEnabled(boolean enabled);
    /** A message for the app's next frame on `channel` (post.h's mb_post: any thread): its JSON's UTF-8. */
    static native void postBytes(String channel, byte[] json);
    /** A browser session's end (WebAuth): the URL it came back to, or why not (one of the two null). */
    static native void webAuthBack(String url, String error);

    /** `json` posted as UTF-8 (Java's own encoding of a String into JNI is modified UTF-8, which an emoji is not). */
    static void post(String channel, String json) {
        postBytes(channel, json.getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }
    static native int atlasTexture();

    static native int colourAtlasTexture();
    static native boolean snapshot(String path);
    /** Image `id` uploaded as `tex` (0: not decoded), GL thread: whether the app is to be told (imageTold). */
    static native boolean imageDone(int id, int tex);
    /** Image `id`'s upload told to the app (its thread). */
    static native void imageTold(int id, boolean ok, int w, int h, int ow, int oh);
    /** Every image's upload to be told again (the app's thread: a new context). */
    static native void imagesUntold();
    /** Image `id` freed: its texture let go (GL thread). */
    static native void imageGone(int id);
    /** What the host did for the app is done (android_host.c's mb_host_set_outside): on the app's thread. */
    static native void outside(int kind, int id, int state);

    // The kinds of what the host does for the app (src/ui/hostcall.mbt's outside_*, named as there).
    static final int OUTSIDE_IMAGE = 1, OUTSIDE_VIEW = 2, OUTSIDE_PICK = 3, OUTSIDE_GALLERY = 4, OUTSIDE_MARKS = 5,
            OUTSIDE_GRAB = 6, OUTSIDE_UPDATE = 7, OUTSIDE_CLIP = 9, OUTSIDE_NATIVE = 10, OUTSIDE_POSTED = 11,
            OUTSIDE_STREAMED = 12, OUTSIDE_STOOD = 13, OUTSIDE_AUTOFILL = 16;

    /** Something posted since (Host.posted, on the app's thread): the app told, or a frame asked for (android_host.c). */
    static native void posted();

    /** `outside` told on the app's thread, between frames, from any thread here (and a frame asked for). */
    static void tell(int kind, int id, int state) {
        MBView v = Host.view;
        if (v != null) v.toApp(() -> outside(kind, id, state));
        Host.requestFrame();
    }
    /** A run to a declared moment (MBView: Host.shotAt): the app's clock is its frames' (mb_host_now). */
    static native void ownClock();
    /** How many of the app's asks of the host are not answered yet, as its last frame said (mb_host_frame_awaiting). */
    static native int awaiting();
    /** The frame the next swap presents (GL thread), its timestamps kept from now on; -1 where the system says none. */
    static native long latencyFrame();
    /** What the system says of frame `id` (Latency): its GPU done, latched, composited, shown (ns); false: nothing. */
    static native int latencyTimes(long id, long[] out);
}
