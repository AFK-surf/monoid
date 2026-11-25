package dev.mbui;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Process;
import android.provider.Settings;
import android.service.notification.StatusBarNotification;

import java.util.concurrent.atomic.AtomicBoolean;

/**
 * The system's notifications (src/hostapi/notify.mbt), as still.fail's Android app shows them (its app/Notices.kt
 * Notifier): one channel ("messages", named as the app says), one notification per tag (the same id for all, the tag
 * telling them apart: a newer one for a chat replaces the older), tapped it opens MainActivity with what it was shown
 * with ({@link #OPENS}), which the app reads once ({@link #text} 0). POST_NOTIFICATIONS is asked for from the activity
 * (Android 13 on); its answer comes back through {@link MainActivity#onRequestPermissionsResult}. A push service is
 * the app's own (an app linking Firebase Cloud Messaging: still.fail's Push.java): it hands this the device's token
 * ({@link #token}) and each push delivered while the app runs ({@link #pushed}); with none, no token and no push.
 *
 * All NotificationManager Binder IPC runs asynchronously on {@link NoticesQueue}'s single background worker thread;
 * {@link #state}(0) reads the cached permission state without blocking the app thread.
 */
public final class Notices {
    private static final String CHANNEL = "messages";
    /** Every notification has this id; its tag tells them apart. */
    private static final int ID = 1;
    /** The extra a notification's tap carries: what it opens, as the app gave it. */
    static final String OPENS = "dev.mbui.NOTICE_OPENS";
    /** The request code of the permission's ask. */
    static final int ASK = 7101;

    /** A notification tapped, not read by the app yet ("" none). */
    static volatile String opened = "";

    /** Process-wide application context, retained across Activity recreation. */
    private static volatile Context appCtx;
    private static final AtomicBoolean blockReceiverRegistered = new AtomicBoolean();

    private static final NoticesQueue QUEUE = new NoticesQueue(new NoticesQueue.Ops() {
        @Override
        public boolean ensureChannel(Object ctx, String channel, boolean onlyIfMissing) {
            NotificationManager m = manager((Context) ctx);
            if (m == null) return false;
            if (onlyIfMissing && m.getNotificationChannel(CHANNEL) != null) return true;
            m.createNotificationChannel(new NotificationChannel(CHANNEL, channel, NotificationManager.IMPORTANCE_HIGH));
            return true;
        }

        @Override
        public void show(Object ctx, String tag, String title, String body, String opens) {
            showDirect((Context) ctx, tag, title, body, opens);
        }

        @Override
        public void cancel(Object ctx, String tag) {
            NotificationManager m = manager((Context) ctx);
            if (m == null) return;
            try {
                for (StatusBarNotification s : m.getActiveNotifications()) {
                    if (tag.equals(s.getTag())) Host.log("NOTICE CANCEL " + tag);
                }
            } catch (RuntimeException ignored) {
            }
            m.cancel(tag, ID);
        }

        @Override
        public int readPermission(Object ctx) {
            NotificationManager m = manager((Context) ctx);
            if (m == null) return NoticesQueue.PERM_UNKNOWN;
            // as Notifier.permission: off, from Android 13 on it may not have been asked yet (the app knows)
            if (m.areNotificationsEnabled()) return NoticesQueue.PERM_GRANTED;
            return Build.VERSION.SDK_INT >= 33 ? NoticesQueue.PERM_ASK : NoticesQueue.PERM_DENIED;
        }

        @Override
        public void requestFrame() {
            Host.main.post(Host::requestFrame);
        }

        @Override
        public int drive(Object ctx, boolean tap, String words) {
            NotificationManager m = manager((Context) ctx);
            if (m == null) return NoticesQueue.DRIVE_ERROR;
            for (StatusBarNotification s : m.getActiveNotifications()) {
                Bundle x = s.getNotification().extras;
                CharSequence title = x.getCharSequence(Notification.EXTRA_TITLE);
                CharSequence body = x.getCharSequence(Notification.EXTRA_TEXT);
                boolean holds = (title != null && title.toString().contains(words)) || (body != null && body.toString().contains(words));
                if (!holds) continue;
                if (!tap) return 1;
                try {
                    s.getNotification().contentIntent.send();
                } catch (PendingIntent.CanceledException e) {
                    return 0;
                }
                m.cancel(s.getTag(), s.getId());
                return 1;
            }
            return 0;
        }
    }, true, () -> Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND));

    private static Context appContext() {
        Context c = appCtx;
        if (c != null) return c;
        MainActivity a = Host.activity;
        if (a != null) {
            c = a.getApplicationContext();
            appCtx = c;
        }
        return c;
    }

    private static NotificationManager manager(Context c) {
        return c.getSystemService(NotificationManager.class);
    }

    /** Process-once initialization (MainActivity.onCreate): binds app context, watches block-state broadcasts, and triggers initial async read. */
    static void init(Context c) {
        if (c == null) return;
        Context app = c.getApplicationContext();
        appCtx = app;
        QUEUE.bindContext(app);
        if (blockReceiverRegistered.compareAndSet(false, true)) {
            BroadcastReceiver receiver = new BroadcastReceiver() {
                @Override
                public void onReceive(Context context, Intent intent) {
                    QUEUE.requestRefresh(app, false);
                }
            };
            IntentFilter filter = new IntentFilter(NotificationManager.ACTION_APP_BLOCK_STATE_CHANGED);
            if (Build.VERSION.SDK_INT >= 33) {
                app.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED);
            } else {
                app.registerReceiver(receiver, filter);
            }
        }
        QUEUE.requestRefresh(app, false);
    }

    /** Activity resumed (MainActivity.onResume, before Host.tellAppState): refreshes cached permission asynchronously. */
    static void resumed(Context c) {
        if (c == null) return;
        Context app = c.getApplicationContext();
        appCtx = app;
        QUEUE.onResumeRefresh(app);
    }

    /** Shown in `channel` (made, or renamed, as it is shown), replacing any of the same tag (Notifier.show). */
    static void show(String channel, String tag, String title, String body, String opens) {
        Context c = appContext();
        if (c == null) return;
        QUEUE.enqueueShow(c, channel, tag, title, body, opens);
    }

    /**
     * Shown from outside the app's run (a push service with no activity up): the channel as the app last named it
     * (made with `channel` only if it never was), replacing any of the same tag; tapped, it opens the app with `opens`.
     */
    public static void show(Context c, String channel, String tag, String title, String body, String opens) {
        if (c == null) return;
        Context app = c.getApplicationContext();
        appCtx = app;
        if (!QUEUE.showExternalAwait(app, channel, tag, title, body, opens, 2000L)) {
            Host.log("NOTICE show timeout " + tag);
        }
    }

    /** Asynchronous external show (e.g. Updates.Replaced with goAsync), invoking {@code onDone} once in finally. */
    static void showAsync(Context c, String channel, String tag, String title, String body, String opens, Runnable onDone) {
        if (c == null) {
            if (onDone != null) onDone.run();
            return;
        }
        Context app = c.getApplicationContext();
        appCtx = app;
        QUEUE.enqueueExternalShow(app, channel, tag, title, body, opens, onDone);
    }

    private static void showDirect(Context c, String tag, String title, String body, String opens) {
        NotificationManager m = manager(c);
        if (m == null) return;
        Intent open = new Intent(c, MainActivity.class).putExtra(OPENS, opens)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        // one each tag (its extras alone would not tell two apart)
        PendingIntent tap = PendingIntent.getActivity(c, tag.hashCode(), open,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification n = new Notification.Builder(c, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setColor(c.getColor(R.color.mbui_notice))
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(new Notification.BigTextStyle().bigText(body))
                .setContentIntent(tap)
                .setAutoCancel(true)
                .setCategory(Notification.CATEGORY_MESSAGE)
                .build();
        m.notify(tag, ID, n);
        Host.log("NOTICE " + tag + "\t" + title + "\t" + body);
    }

    /** A chat opened: its notification goes (Notifier.cancel). */
    static void cancel(String tag) {
        Context c = appContext();
        if (c == null) return;
        QUEUE.enqueueCancel(c, tag);
    }

    /**
     * 0: what the system allows (1 granted, 2 denied, 3 off and maybe never asked, 5 pending async read); 1: ask (1 asked);
     * 2: the answer, once; 3: the system's page of the app's notifications opened (1), where they are allowed again once
     * refused; 4: the app's number shown on its icon: never (0), the launcher's dot is the system's, while a notification shows.
     */
    static int state(int what) {
        switch (what) {
            case 0:
                return QUEUE.permissionState();
            case 1: {
                MainActivity a = Host.activity;
                if (a == null || Build.VERSION.SDK_INT < 33
                        || a.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return 0;
                Host.main.post(() -> {
                    MainActivity target = (!a.isFinishing() && !a.isDestroyed()) ? a : Host.activity;
                    if (target == null || target.isFinishing() || target.isDestroyed()) {
                        QUEUE.requestRefresh(appContext(), false);
                        return;
                    }
                    target.requestPermissions(new String[] { Manifest.permission.POST_NOTIFICATIONS }, ASK);
                });
                return 1;
            }
            case 2:
                return QUEUE.takeAnswer();
            case 3: {
                MainActivity a = Host.activity;
                if (a == null) return 0;
                Intent i = new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, a.getPackageName());
                Host.main.post(() -> {
                    try {
                        a.startActivity(i);
                    } catch (android.content.ActivityNotFoundException e) {
                        // (a system without that page: the app's own)
                        a.startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                android.net.Uri.fromParts("package", a.getPackageName(), null)));
                    }
                });
                return 1;
            }
            default:
                return 0;
        }
    }

    /** The device's push token as the app's push service last gave it ("" none). */
    private static volatile String pushToken = "";

    /**
     * The device's push token, from the app's push service (its first, or a new one): the app is asked for a frame, so
     * it registers the token as it next looks ({@code push_token}).
     */
    public static void token(String token) {
        pushToken = token == null ? "" : token;
        // (called on the push service's thread)
        Host.main.post(Host::requestFrame);
    }

    /** 0: a notification tapped, once; 1: the push token ("" none); 2: the push service that knows it (FCM). */
    static String text(int what) {
        if (what == 1) return pushToken;
        if (what == 2) return pushToken.isEmpty() ? "" : "fcm";
        if (what != 0) return "";
        String o = opened;
        opened = "";
        return o;
    }

    /**
     * The activity started or brought back by a notification's tap: what it opens, kept for the app; or by a link (an
     * http(s) ACTION_VIEW the manifest takes: one of the app's links tapped in another app), posted to the app on its
     * system channel ({"link": url}: src/hostapi/system.mbt), so a run's tape has it. Each is taken off the intent once
     * told (as still.fail's MainActivity.handle sets an empty one).
     */
    static void from(Intent intent) {
        if (intent != null && Intent.ACTION_VIEW.equals(intent.getAction()) && intent.getData() != null
                && ("https".equals(intent.getData().getScheme()) || "http".equals(intent.getData().getScheme()))) {
            String link = intent.getData().toString();
            intent.setData(null);
            Host.log("LINK OPENED " + link);
            try {
                Native.post("system", new org.json.JSONObject().put("link", link).toString());
            } catch (org.json.JSONException ignored) {
            }
            return;
        }
        String o = intent != null ? intent.getStringExtra(OPENS) : null;
        if (o == null) return;
        intent.removeExtra(OPENS);
        opened = o;
        Host.log("NOTICE TAP " + o.replace('\n', ' '));
        Host.requestFrame();
    }

    /** The permission's answer (MainActivity.onRequestPermissionsResult). */
    static void answered(boolean cancelled, boolean granted) {
        QUEUE.onPermissionResult(appContext(), cancelled, granted, Build.VERSION.SDK_INT >= 33);
    }

    /**
     * A scripted run (src/ui/drive.mbt `notice`, `noticed`, `nonotice`): kind 6 taps a matching notification, kind 7
     * checks one exists, kind 14 confirms none exists (returns 0 on timeout/error/missing context so `nonotice` never
     * false-passes). Runs in FIFO order after all prior queued shows/cancels without throwing across JNI.
     */
    static int drive(int kind, String words) {
        Context c = appContext();
        if (c == null) return 0;
        int r = QUEUE.drive(c, kind == 6, words, 5000L);
        if (r < 0) {
            Host.log("NOTICE drive failed: " + r);
            return 0;
        }
        if (kind == 14) return r == 0 ? 1 : 0;
        return r == 1 ? 1 : 0;
    }
}
