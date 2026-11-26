package dev.mbui;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.ColorSpace;
import android.graphics.ImageDecoder;
import android.graphics.Matrix;
import android.media.ExifInterface;
import android.opengl.GLES30;
import android.opengl.GLUtils;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.ByteBuffer;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Images: read and decoded on background threads straight to the size asked
 * for, EXIF orientation applied, then uploaded on the GL thread as
 * premultiplied RGBA textures the C renderer draws. Local/in-memory decodes,
 * gallery thumbnails (content://) and remote fetches run on separate pools so a
 * burst of gallery thumbnails or slow URLs never starves an image just picked.
 */
final class Images {
    private static java.util.concurrent.ThreadFactory bgFactory(String prefix) {
        java.util.concurrent.atomic.AtomicInteger n = new java.util.concurrent.atomic.AtomicInteger();
        return r -> {
            Thread t = new Thread(() -> {
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND);
                r.run();
            }, prefix + "-" + n.incrementAndGet());
            t.setDaemon(true);
            return t;
        };
    }

    // local files and bytes already in memory (picked previews, icons, marks)
    static final ExecutorService pool = Executors.newFixedThreadPool(3, bgFactory("mbui-img"));
    // content:// URIs (gallery thumbnails and video stills: MediaProvider IPC)
    static final ExecutorService thumbs = Executors.newFixedThreadPool(2, bgFactory("mbui-thumb"));
    // http(s):// fetches, kept off local decodes when the network stalls
    static final ExecutorService remote = Executors.newFixedThreadPool(2, bgFactory("mbui-remote"));

    static final class Req {
        final String src;
        final byte[] data;
        final int maxPx;
        /** How to make it again if not by decoding (a PDF's page, Pdfs.java). */
        final Runnable redo;

        Req(String src, byte[] data, int maxPx) {
            this(src, data, maxPx, null);
        }

        Req(String src, byte[] data, int maxPx, Runnable redo) {
            this.src = src;
            this.data = data;
            this.maxPx = maxPx;
            this.redo = redo;
        }
    }

    // what each live image was loaded from, to decode it again if the GL
    // context (and with it every texture) is lost; written on the app's thread,
    // checked by workers so freed requests skip work
    static final ConcurrentHashMap<Integer, Req> live = new ConcurrentHashMap<>();

    static ExecutorService poolFor(Req r) {
        if (r.data != null) return pool;
        if (r.src.startsWith("content://")) return thumbs;
        if (r.src.startsWith("http://") || r.src.startsWith("https://")) return remote;
        return pool;
    }

    static void submit(int id, Req r) {
        poolFor(r).execute(() -> decode(id, r));
    }

    static void load(int id, String src, byte[] data, int maxPx) {
        Req r = new Req(src, data, maxPx);
        live.put(id, r);
        submit(id, r);
    }

    // mbui-render (android_host.c mb_render_init_offscreen): its main holds the GL thread while it waits for its
    // images, so their uploads are kept here and done when it asks (pump), on that thread
    static volatile boolean held;
    static final ConcurrentLinkedQueue<Runnable> heldUploads = new ConcurrentLinkedQueue<>();

    static void hold() {
        held = true;
    }

    static void pump() {
        for (Runnable r; (r = heldUploads.poll()) != null; ) r.run();
    }

    /** {@code r} on the GL thread (MBView.toRender), or kept for mbui-render's pump. */
    static void toRender(Runnable r) {
        if (held) {
            heldUploads.add(r);
            return;
        }
        MBView.toRender(r);
    }

    /**
     * Image `id` freed (the app's thread): its texture let go on the GL thread once a frame made after this is on the
     * screen (the frame kept till then may be drawn again, and draws it: MBView.toRetire).
     */
    static void free(int id) {
        live.remove(id);
        MBView.toRetire(() -> Native.imageGone(id));
    }

    static void reload() {
        for (Map.Entry<Integer, Req> e : live.entrySet()) {
            int id = e.getKey();
            Req r = e.getValue();
            if (r.redo != null) r.redo.run();
            else submit(id, r);
        }
    }

    static Bitmap decodeSource(ImageDecoder.Source src, int maxPx, int[] orig) throws IOException {
        Bitmap b = ImageDecoder.decodeBitmap(src, (d, info, s) -> {
            int w = info.getSize().getWidth(), h = info.getSize().getHeight();
            orig[0] = w;
            orig[1] = h;
            double k = Math.min(1.0, maxPx / (double) Math.max(w, h));
            if (k < 1) {
                d.setTargetSize(Math.max(1, (int) Math.round(w * k)),
                        Math.max(1, (int) Math.round(h * k)));
            }
            d.setAllocator(ImageDecoder.ALLOCATOR_SOFTWARE);
            d.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB));
        });
        if (b.getConfig() != Bitmap.Config.ARGB_8888) {
            Bitmap c = b.copy(Bitmap.Config.ARGB_8888, false);
            b.recycle();
            b = c;
        }
        return b;
    }

    /**
     * The long side a decode is asked for held to the largest texture the GL context takes (GL_MAX_TEXTURE_SIZE, read as
     * drawing is set up: an older GPU's 4096 refuses a picture of 8192): 4096 while that is not known yet.
     */
    static int cappedMaxPx(int maxPx) {
        int most = NativeViews.textureMost;
        if (most <= 0) most = 4096;
        return maxPx > 0 ? Math.min(maxPx, most) : most;
    }

    static void decode(int id, Req r) {
        if (live.get(id) != r) return;
        long t0 = System.nanoTime();
        int maxPx = cappedMaxPx(r.maxPx);
        int[] orig = new int[2];
        Bitmap b = null;
        try {
            byte[] data = r.data;
            if (RawPremul.isRawPremul(data)) {
                final byte[] rawData = data;
                int[] dims = RawPremul.parseRawPremulHeader(rawData);
                if (dims == null) {
                    toRender(() -> {
                        if (!live.containsKey(id)) return;
                        finishUpload(id, 0, 0, 0, 0, 0);
                    });
                    return;
                }
                int w = dims[0], h = dims[1];
                if (Math.max(w, h) <= maxPx) {
                    toRender(() -> uploadRawPremul(id, rawData, w, h, w, h));
                    return;
                }
                int[] sz = RawPremul.targetSize(w, h, maxPx);
                Bitmap src = null;
                Bitmap scaled = null;
                try {
                    src = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
                    src.copyPixelsFromBuffer(ByteBuffer.wrap(rawData, RawPremul.HEADER_BYTES, w * h * 4));
                    scaled = Bitmap.createScaledBitmap(src, sz[0], sz[1], true);
                } finally {
                    if (src != null && src != scaled) src.recycle();
                }
                final Bitmap outBmp = scaled;
                toRender(() -> upload(id, outBmp, w, h));
                return;
            }
            if (data == null && r.src.startsWith("content://")) {
                android.content.ContentResolver cr = Host.activity.getContentResolver();
                android.net.Uri uri = android.net.Uri.parse(r.src);
                // a photo or video of the gallery (Gallery.java), or a file held by its address (Picks.java):
                // its thumbnail first (a video's still, a photo's cached preview), else the image itself
                try {
                    Bitmap t = cr.loadThumbnail(uri, new android.util.Size(maxPx, maxPx), null);
                    orig[0] = t.getWidth();
                    orig[1] = t.getHeight();
                    b = t.getConfig() == Bitmap.Config.ARGB_8888 ? t : t.copy(Bitmap.Config.ARGB_8888, false);
                    if (b != t) t.recycle();
                } catch (Exception thumbErr) {
                    b = decodeSource(ImageDecoder.createSource(cr, uri), maxPx, orig);
                }
            } else {
                if (data == null && (r.src.startsWith("http://") || r.src.startsWith("https://"))) {
                    data = fetch(r.src);
                    if (live.get(id) != r) return;
                }
                String path = r.src.startsWith("file://") ? r.src.substring(7) : r.src;
                try {
                    // minSdk is 30, so ImageDecoder is always there; BitmapFactory
                    // is the second try for what it can't read
                    b = decodeSource(data != null
                            ? ImageDecoder.createSource(ByteBuffer.wrap(data))
                            : ImageDecoder.createSource(new File(path)), maxPx, orig);
                } catch (IOException e) {
                    b = withFactory(data, path, maxPx, orig);
                    if (b == null) throw e;
                    if (b.getConfig() != Bitmap.Config.ARGB_8888) {
                        Bitmap c = b.copy(Bitmap.Config.ARGB_8888, false);
                        b.recycle();
                        b = c;
                    }
                }
            }
        } catch (Throwable e) {
            Host.log("image " + r.src + ": " + e);
            b = null;
        }
        if (Host.bench != 0 && b != null) {
            Host.log("image " + orig[0] + "x" + orig[1] + " -> " + b.getWidth() + "x" + b.getHeight()
                    + " in " + (System.nanoTime() - t0) / 1000000 + " ms: " + r.src);
        }
        Bitmap bmp = b;
        toRender(() -> upload(id, bmp, orig[0], orig[1]));
    }

    /** Older decoders: a power-of-two subsample, then scaled and turned. */
    static Bitmap withFactory(byte[] data, String path, int maxPx, int[] orig) throws IOException {
        BitmapFactory.Options o = new BitmapFactory.Options();
        o.inJustDecodeBounds = true;
        if (data != null) BitmapFactory.decodeByteArray(data, 0, data.length, o);
        else BitmapFactory.decodeFile(path, o);
        int w = o.outWidth, h = o.outHeight;
        if (w <= 0 || h <= 0) return null;
        o.inJustDecodeBounds = false;
        o.inSampleSize = 1;
        while (Math.max(w, h) / (o.inSampleSize * 2) >= maxPx) o.inSampleSize *= 2;
        Bitmap b = data != null ? BitmapFactory.decodeByteArray(data, 0, data.length, o)
                : BitmapFactory.decodeFile(path, o);
        if (b == null) return null;
        ExifInterface ex = data != null ? new ExifInterface(new ByteArrayInputStream(data))
                : new ExifInterface(path);
        int turn = ex.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL);
        float k = (float) Math.min(1.0, maxPx / (double) Math.max(b.getWidth(), b.getHeight()));
        Matrix m = new Matrix();
        m.setScale(k, k);
        switch (turn) {
            case ExifInterface.ORIENTATION_FLIP_HORIZONTAL: m.postScale(-1, 1); break;
            case ExifInterface.ORIENTATION_ROTATE_180: m.postRotate(180); break;
            case ExifInterface.ORIENTATION_FLIP_VERTICAL: m.postScale(1, -1); break;
            case ExifInterface.ORIENTATION_TRANSPOSE: m.postRotate(90); m.postScale(-1, 1); break;
            case ExifInterface.ORIENTATION_ROTATE_90: m.postRotate(90); break;
            case ExifInterface.ORIENTATION_TRANSVERSE: m.postRotate(-90); m.postScale(-1, 1); break;
            case ExifInterface.ORIENTATION_ROTATE_270: m.postRotate(-90); break;
        }
        boolean swap = turn >= ExifInterface.ORIENTATION_TRANSPOSE;
        orig[0] = swap ? h : w;
        orig[1] = swap ? w : h;
        if (m.isIdentity()) return b;
        Bitmap t = Bitmap.createBitmap(b, 0, 0, b.getWidth(), b.getHeight(), m, true);
        if (t != b) b.recycle();
        return t;
    }

    static byte[] fetch(String url) throws IOException {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(15_000);
        c.setReadTimeout(30_000);
        try (InputStream in = c.getInputStream()) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[64 * 1024];
            for (int n; (n = in.read(buf)) > 0; ) out.write(buf, 0, n);
            return out.toByteArray();
        } finally {
            c.disconnect();
        }
    }

    // ---- GL thread ----

    static void finishUpload(int id, int tex, int w, int h, int ow, int oh) {
        // the app told on its thread (with both on this one, at once: mbui-render's main waits here for its images)
        boolean ok = tex != 0;
        if (!Native.imageDone(id, tex)) return;
        if (MBView.ONE) Native.imageTold(id, ok, w, h, ow, oh);
        else MBView.onApp(() -> Native.imageTold(id, ok, w, h, ow, oh));
    }

    static void uploadRawPremul(int id, byte[] data, int w, int h, int ow, int oh) {
        if (!live.containsKey(id)) return;
        NativeViews.textureMostRead();
        int most = NativeViews.textureMost;
        if (most > 0 && (w > most || h > most)) {
            Bitmap bmp = null;
            try {
                bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
                bmp.copyPixelsFromBuffer(ByteBuffer.wrap(data, RawPremul.HEADER_BYTES, w * h * 4));
            } catch (Throwable e) {
                Host.log("image raw premul fallback: " + e);
                if (bmp != null) bmp.recycle();
                bmp = null;
            }
            upload(id, bmp, ow, oh);
            return;
        }
        int[] t = {0};
        try {
            for (int i = 0; i < 8 && GLES30.glGetError() != GLES30.GL_NO_ERROR; i++) {}
            GLES30.glGenTextures(1, t, 0);
            if (t[0] != 0) {
                GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, t[0]);
                GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR);
                GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR);
                GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE);
                GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE);
                GLES30.glPixelStorei(GLES30.GL_UNPACK_ALIGNMENT, 4);
                GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8, w, h, 0,
                        GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE,
                        ByteBuffer.wrap(data, RawPremul.HEADER_BYTES, w * h * 4));
                if (GLES30.glGetError() != GLES30.GL_NO_ERROR) {
                    GLES30.glDeleteTextures(1, t, 0);
                    t[0] = 0;
                }
            }
        } catch (Throwable e) {
            Host.log("image raw premul upload: " + e);
            if (t[0] != 0) {
                try { GLES30.glDeleteTextures(1, t, 0); } catch (Throwable ignored) {}
                t[0] = 0;
            }
        } finally {
            finishUpload(id, t[0], t[0] != 0 ? w : 0, t[0] != 0 ? h : 0, ow, oh);
        }
    }

    static void upload(int id, Bitmap b, int ow, int oh) {
        if (!live.containsKey(id)) {  // freed meanwhile
            if (b != null) b.recycle();
            return;
        }
        int[] t = {0};
        int w = 0, h = 0;
        try {
            // (no larger than the GL context takes: a thumbnail larger than asked, or decoded before that was known)
            NativeViews.textureMostRead();
            int most = NativeViews.textureMost;
            if (b != null && most > 0 && (b.getWidth() > most || b.getHeight() > most)) {
                double k = most / (double) Math.max(b.getWidth(), b.getHeight());
                int nw = Math.max(1, Math.min(most, (int) Math.round(b.getWidth() * k)));
                int nh = Math.max(1, Math.min(most, (int) Math.round(b.getHeight() * k)));
                Bitmap s = Bitmap.createScaledBitmap(b, nw, nh, true);
                if (s != b) b.recycle();
                b = s;
            }
            if (b != null) {
                w = b.getWidth();
                h = b.getHeight();
                for (int i = 0; i < 8 && GLES30.glGetError() != GLES30.GL_NO_ERROR; i++) {}
                GLES30.glGenTextures(1, t, 0);
                if (t[0] != 0) {
                    GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, t[0]);
                    GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR);
                    GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR);
                    GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE);
                    GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE);
                    // Bitmaps are premultiplied, and uploaded as they are
                    GLUtils.texImage2D(GLES30.GL_TEXTURE_2D, 0, b, 0);
                    if (GLES30.glGetError() != GLES30.GL_NO_ERROR) {
                        GLES30.glDeleteTextures(1, t, 0);
                        t[0] = 0;
                    }
                }
            }
        } catch (Throwable e) {
            Host.log("image upload: " + e);
            if (t[0] != 0) {
                try { GLES30.glDeleteTextures(1, t, 0); } catch (Throwable ignored) {}
                t[0] = 0;
            }
        } finally {
            if (b != null) b.recycle();
            finishUpload(id, t[0], t[0] != 0 ? w : 0, t[0] != 0 ? h : 0, ow, oh);
        }
    }
}
