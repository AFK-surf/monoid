package dev.mbui;

import java.util.ArrayDeque;
import java.util.HashSet;
import java.util.Objects;
import java.util.Set;
import java.util.concurrent.CountDownLatch;

/**
 * How the app keeping itself current goes (Updates.java), as plain Java with no Android in it, so
 * {@code UpdatesQueueTest} runs it on any JVM.
 *
 * The app's threads (mbui-logic: {@link #state}, {@link #fetch}, {@link #apply}; the main thread: {@link #started},
 * {@link #stopped}, {@link #resumed}) never touch a file or the system's services (Binder): they read the
 * {@link Snapshot} as it is, change it at once to what the person should see next (downloading, waiting, allow,
 * installing), and hand the work to one serial daemon worker ({@code mbui-update-io}) that does it in order. A
 * download runs on a thread of its own ({@code mbui-update}), so the worker stays free for what the person does
 * meanwhile. Every file and system call is an {@link Ops} call, made only on the worker or the download's thread.
 *
 * {@link #stateLock} guards the state and the queue; nothing is read or written on disk, the network or Binder while
 * it is held. Every way a fetch ends (the build ready on disk already, waiting for a network that is not metered,
 * downloaded, failed, an exception) goes through {@link #finishOrHandoffLocked}, which hands over to the build asked
 * for meanwhile, so none is lost. Each task catches {@link Throwable}, so the worker never dies, and whoever waits
 * on one is let go in {@code finally}.
 */
final class UpdatesQueue {
    static final String IDLE = "idle", WAITING = "waiting", DOWNLOADING = "downloading", RETRYING = "retrying",
            READY = "ready", ALLOW = "allow", INSTALLING = "installing", FAILED = "failed";
    static final int NO_SESSION = -1;
    /** What the installer said of the app's own build ({@link #installStatus}). */
    static final int INSTALL_SUCCESS = 0, INSTALL_PENDING_USER = 1, INSTALL_ABORTED = 2, INSTALL_FAILURE = 3;

    /** How it goes, as the app reads it: one value, replaced whole. */
    static final class Snapshot {
        final String phase;
        final int percent;
        final String error;
        final String file;

        Snapshot(String phase, int percent, String error, String file) {
            this.phase = phase;
            this.percent = percent;
            this.error = error;
            this.file = file;
        }
    }

    /** A build asked for (`app.update`): its package, and the delta from this build ("" none; {@link #deltaSize} its size). */
    static final class Fetch {
        final String url;
        final String sha256;
        final long size;
        final String name;
        final String delta;
        final long deltaSize;
        final boolean now;

        Fetch(String url, String sha256, long size, String name, String delta, long deltaSize, boolean now) {
            this.url = url;
            this.sha256 = sha256;
            this.size = size;
            this.name = name;
            this.delta = delta == null ? "" : delta;
            this.deltaSize = deltaSize;
            this.now = now;
        }

        Fetch now(boolean n) {
            return n == now ? this : new Fetch(url, sha256, size, name, delta, deltaSize, n);
        }

        /** The file the bytes so far are kept in: the delta's where there is one. */
        String partName() {
            return name + (deltaSize > 0 ? ".delta.part" : ".part");
        }

        /** How far `have` bytes of the part are: of the delta's size where there is one; -1 not known. */
        int percentOf(long have) {
            long of = deltaSize > 0 ? deltaSize : size;
            return of > 0 && have >= 0 ? (int) (Math.min(have, of) * 100 / of) : -1;
        }
    }

    /** What an earlier run left: the build ready (its name, null none), what it asked for (null none), its part's bytes. */
    static final class Restored {
        final String ready;
        final Fetch asked;
        final long askedPart;

        Restored(String ready, Fetch asked, long askedPart) {
            this.ready = ready;
            this.asked = asked;
            this.askedPart = askedPart;
        }
    }

    /** Everything touching a file, the network or the system: called only on the worker or a download's thread. */
    interface Ops {
        /** This build's version code (PackageManager); <= 0 not known. */
        int versionCode(Object ctx);

        /** Whether the app may install apps (PackageManager.canRequestPackageInstalls). */
        boolean canInstall(Object ctx);

        /** Whether the network is metered (ConnectivityManager). */
        boolean metered(Object ctx);

        /** What an earlier run left (Updates.restore: the cache's old builds let go, the ready one and `asked` read). */
        Restored restore(Object ctx);

        /** The bytes so far of `name`'s part (the delta's where `delta`), 0 none. */
        long partBytes(Object ctx, String name, boolean delta);

        /** What is asked for kept (`asked`), for a job of a later run. */
        void keepAsked(Object ctx, Fetch f);

        /** What was asked for last; null none. */
        Fetch readAsked(Object ctx);

        /** The build downloaded and checked; throws for anything wrong. On the download's own thread. */
        void download(Object ctx, Fetch f) throws Exception;

        /** The job that downloads what is asked for once a network that is not metered comes. */
        void scheduleFetchJob(Object ctx);

        /** The job that puts the build ready in place once the app is out of sight a while. */
        void scheduleAway(Object ctx);

        void cancelAway(Object ctx);

        /** The system's page for the leave to install apps, opened (from the application's context, a new task). */
        void openUnknownSources(Object ctx);

        /** The newest build ready and newer than this one (its file's name); null none. */
        String readyFile(Object ctx);

        /** What the newer build says once in place ("" or null none: what was kept let go). */
        void keepSaid(Object ctx, String said);

        /** An installer session for the build made; its id. */
        int installCreate(Object ctx, String name) throws Exception;

        /** The build written into the session and committed. */
        void installCommit(Object ctx, int session, String name) throws Exception;

        /** Whether a sign-in waits in the browser (the build not put in place meanwhile). */
        boolean loginListening();

        /** In the newer build: what was kept for it let go, but `keep` (names and their parts); what it says (null none). */
        String replacedClean(Object ctx, Set<String> keep);

        /** The newer build's notification; takes `onDone` (called once) unless it throws. */
        void replacedNotice(Object ctx, String said, Runnable onDone);

        /** Told to the app: 0 working, 1 resting, -1 failed (Native.OUTSIDE_UPDATE). No file or Binder. */
        void changed(int state);

        /** `r` on a thread of its own. */
        void spawn(Runnable r, String name);

        /** Logged (a file: on the worker or a download's thread only). */
        void log(String s);
    }

    private enum Kind { WARM, RESTORE, FETCH, FETCH_ASKED, APPLY, RESUMED, CANCEL_AWAY, MAYBE_AWAY, AWAY_LONG, REPLACED }

    private static final class Task {
        final Kind kind;
        final Object ctx;
        final Fetch fetch;
        final String said;
        final String file;
        final Runnable onDone;
        final CountDownLatch done;
        Download download;

        Task(Kind kind, Object ctx, Fetch fetch, String said, String file, Runnable onDone, boolean awaitable) {
            this.kind = kind;
            this.ctx = ctx;
            this.fetch = fetch;
            this.said = said;
            this.file = file;
            this.onDone = onDone;
            this.done = awaitable ? new CountDownLatch(1) : null;
        }
    }

    /** A download under way: let go of once it ended and what follows was handed over. */
    static final class Download {
        final Fetch fetch;
        final CountDownLatch ended = new CountDownLatch(1);

        Download(Fetch fetch) {
            this.fetch = fetch;
        }
    }

    private final Ops ops;
    private final boolean autoStart;
    /** The state and the queue; never held over a file, the network or Binder. */
    private final Object stateLock = new Object();
    private final ArrayDeque<Task> queue = new ArrayDeque<>();
    private boolean workerStarted;
    private Thread workerThread;

    private volatile Snapshot snap = new Snapshot(IDLE, -1, "", "");
    private volatile Object ctx;
    private volatile boolean inSight;
    private volatile int cachedVersionCode;
    private volatile Boolean cachedCanInstall;
    private volatile Boolean cachedMetered;
    private long meteredGen;
    private volatile String cachedPartName;
    private volatile long cachedPartBytes;
    private volatile boolean restored;
    /** RESTORE (or WARM, which restores) queued once (written under stateLock). */
    private volatile boolean restoreQueued;

    // under stateLock
    private boolean fetchSeen;
    private String readyOnDisk;
    private boolean fetchQueued;
    private boolean downloadActive;
    private String activeFile;
    private boolean activeNow;
    private Fetch pendingFetch;
    private boolean applyQueued;
    private String nowSaid;
    private String installingFile;
    private int installingSessionId = NO_SESSION;

    UpdatesQueue(Ops ops, boolean autoStart) {
        this.ops = Objects.requireNonNull(ops, "ops");
        this.autoStart = autoStart;
    }

    // ---- the app's threads: no file, no Binder ----

    /** How it goes now; what an earlier run left is taken up once, on the worker (told by `changed` if it differs). */
    Snapshot state(Object c) {
        if (c != null && !restoreQueued) {
            synchronized (stateLock) {
                bindLocked(c);
                ensureRestoreQueuedLocked();
            }
        }
        return snap;
    }

    /** The app made (MainActivity.onCreate): what the app's threads read later read ahead on the worker. */
    void warmUp(Object c) {
        if (c == null) return;
        synchronized (stateLock) {
            bindLocked(c);
            enqueueLocked(new Task(Kind.WARM, c, null, null, null, null, false));
            restoreQueued = true;
        }
    }

    /** Pushed by the network watch (NetworkWatch.onCapabilitiesChanged): newer than any read made before it. */
    void onMeteredChanged(boolean metered) {
        synchronized (stateLock) {
            meteredGen++;
            cachedMetered = metered;
        }
    }

    /** The build `f` made ready (@hostapi.update_fetch). One ready or coming of that name: nothing more. */
    void fetch(Object c, Fetch f) {
        if (c == null) return;
        int tell;
        synchronized (stateLock) {
            bindLocked(c);
            ensureRestoreQueuedLocked();
            Snapshot s = snap;
            if (f.name.equals(s.file) && (s.phase.equals(READY) || s.phase.equals(ALLOW) || s.phase.equals(INSTALLING))) return;
            if (downloadActive || fetchQueued) {
                if (!f.name.equals(activeFile)) {
                    // (a newer build asked for while one is under way: taken up as that one ends)
                    pendingFetch = f;
                    return;
                }
                pendingFetch = null;
                if (!f.now || activeNow) return;
                // (asked for now: kept to, whatever the worker finds the network to be)
                activeNow = true;
                if (!s.phase.equals(WAITING)) return;
                snap = new Snapshot(DOWNLOADING, percentFromCache(f), "", f.name);
                tell = 0;
            } else {
                fetchSeen = true;
                fetchQueued = true;
                activeFile = f.name;
                activeNow = f.now;
                tell = publishOptimisticLocked(f) ? 1 : 0;
                enqueueLocked(new Task(Kind.FETCH, c, f, null, null, null, false));
            }
        }
        changed(tell);
    }

    /** The build ready put in place now (@hostapi.update_apply); `said` what the newer build says. */
    void apply(Object c, String said) {
        if (c == null) return;
        int tell;
        synchronized (stateLock) {
            bindLocked(c);
            ensureRestoreQueuedLocked();
            Snapshot s = snap;
            if (!s.phase.equals(READY) && !s.phase.equals(ALLOW)) return;
            boolean may = !Boolean.FALSE.equals(cachedCanInstall);
            snap = new Snapshot(may ? INSTALLING : ALLOW, s.percent, s.error, s.file);
            applyQueued = true;
            enqueueLocked(new Task(Kind.APPLY, c, null, said, s.file, null, false));
            tell = may ? 0 : 1;
        }
        changed(tell);
    }

    /** The app's window on the screen: a build ready stays out while it is. */
    void started(Object c) {
        inSight = true;
        if (c == null) return;
        synchronized (stateLock) {
            bindLocked(c);
            enqueueLocked(new Task(Kind.CANCEL_AWAY, c, null, null, null, null, false));
        }
    }

    /** The app's window off the screen: a build ready put in place once it stays so a while. */
    void stopped(Object c) {
        inSight = false;
        if (c == null || !snap.phase.equals(READY)) return;
        synchronized (stateLock) {
            bindLocked(c);
            enqueueLocked(new Task(Kind.MAYBE_AWAY, c, null, null, null, null, false));
        }
    }

    /** The app back in front: where the leave to install apps was wanted, whether it is given now looked at on the worker. */
    void resumed(Object c) {
        if (c == null) return;
        synchronized (stateLock) {
            if (!needsResumeCheckLocked()) return;
            bindLocked(c);
            enqueueLocked(new Task(Kind.RESUMED, c, null, null, null, null, false));
        }
    }

    boolean needsResumeCheck() {
        synchronized (stateLock) {
            return needsResumeCheckLocked();
        }
    }

    private boolean needsResumeCheckLocked() {
        return snap.phase.equals(ALLOW) || applyQueued;
    }

    // ---- other threads: they wait, the worker works ----

    /** What was asked for downloaded (FETCH_JOB), waiting till it ends. Never on the worker. */
    void fetchAsked(Object c) throws InterruptedException {
        if (c == null) return;
        Task t = awaitTask(new Task(Kind.FETCH_ASKED, c, null, null, null, null, true));
        Download d = t.download;
        if (d != null) d.ended.await();
    }

    /** Out of sight a while (AWAY_JOB): the build ready put in place, waiting till it is handed over. Never on the worker. */
    void awayLong(Object c) throws InterruptedException {
        if (c == null) return;
        awaitTask(new Task(Kind.AWAY_LONG, c, null, null, null, null, true));
    }

    /** The newer build in place (MY_PACKAGE_REPLACED): `finish` (the broadcast's) called exactly once. */
    void replaced(Object c, Runnable finish) {
        synchronized (stateLock) {
            bindLocked(c);
            enqueueLocked(new Task(Kind.REPLACED, c, null, null, null, finish, false));
        }
    }

    /**
     * What the installer said of the app's own build (`session` its id, NO_SESSION not said): whether the system's
     * page asking the person to confirm should open now. The build stays the installer's while that page shows.
     */
    boolean installStatus(int session, int status, String message) {
        int tell = 2;
        synchronized (stateLock) {
            if (installingSessionId != NO_SESSION && session != NO_SESSION && session != installingSessionId) return false;
            String owned = installingFile;
            Snapshot s = snap;
            boolean sameFile = owned != null && s.file.equals(owned);
            switch (status) {
                case INSTALL_PENDING_USER:
                    // (if owned == null after a process restart, restore leaves READY so the person can tap install again)
                    if (inSight && sameFile) return true;
                    // (the system's page could not open from behind: ready again, for the person's word)
                    if (sameFile && s.phase.equals(INSTALLING)) {
                        snap = new Snapshot(READY, s.percent, s.error, s.file);
                        tell = 1;
                    }
                    releaseInstallLocked();
                    break;
                case INSTALL_ABORTED:
                    // the person said no to the system's page: ready again
                    if (sameFile && s.phase.equals(INSTALLING)) {
                        snap = new Snapshot(READY, s.percent, s.error, s.file);
                        tell = 1;
                    }
                    releaseInstallLocked();
                    break;
                case INSTALL_SUCCESS:
                    releaseInstallLocked();
                    break;
                default:
                    if (sameFile) {
                        snap = new Snapshot(FAILED, s.percent, message == null ? "install failed" : message, s.file);
                        tell = -1;
                    }
                    releaseInstallLocked();
                    break;
            }
        }
        if (tell != 2) changed(tell);
        return false;
    }

    // ---- a download's thread ----

    /** How far the download is (`phase` null: as it was). */
    void progress(String phase, int percent) {
        synchronized (stateLock) {
            Snapshot s = snap;
            snap = new Snapshot(phase == null ? s.phase : phase, percent, s.error, s.file);
        }
        changed(0);
    }

    int percent() {
        return snap.percent;
    }

    /** The build handed to the installer (its file's name), null none: never let go of meanwhile. */
    String installingFile() {
        synchronized (stateLock) {
            return installingFile;
        }
    }

    boolean inSight() {
        return inSight;
    }

    int cachedVersionCode() {
        return cachedVersionCode;
    }

    void cacheVersionCode(int v) {
        if (v > 0) cachedVersionCode = v;
    }

    // ---- tests ----

    /** One queued task run on the caller's thread (autoStart false). */
    boolean stepOne() {
        Task t;
        synchronized (stateLock) {
            t = queue.pollFirst();
        }
        if (t == null) return false;
        runTask(t);
        return true;
    }

    int drainInline() {
        int n = 0;
        while (stepOne()) n++;
        return n;
    }

    int queued() {
        synchronized (stateLock) {
            return queue.size();
        }
    }

    // ---- the worker ----

    private void bindLocked(Object c) {
        if (c != null) ctx = c;
    }

    private void ensureRestoreQueuedLocked() {
        if (restoreQueued || ctx == null) return;
        restoreQueued = true;
        enqueueLocked(new Task(Kind.RESTORE, ctx, null, null, null, null, false));
    }

    private void enqueueLocked(Task t) {
        queue.addLast(t);
        if (autoStart && !workerStarted) {
            workerStarted = true;
            Thread w = new Thread(this::workerLoop, "mbui-update-io");
            w.setDaemon(true);
            workerThread = w;
            w.start();
        }
        stateLock.notifyAll();
    }

    private Task awaitTask(Task t) throws InterruptedException {
        synchronized (stateLock) {
            if (Thread.currentThread() == workerThread) throw new IllegalStateException("awaited on the update worker");
            bindLocked(t.ctx);
            enqueueLocked(t);
        }
        t.done.await();
        return t;
    }

    private void workerLoop() {
        while (true) {
            Task t;
            synchronized (stateLock) {
                while (queue.isEmpty()) {
                    try {
                        stateLock.wait();
                    } catch (InterruptedException ignored) {
                        // (a daemon for the process: nothing stops it)
                    }
                }
                t = queue.pollFirst();
            }
            runTask(t);
        }
    }

    private void runTask(Task t) {
        try {
            switch (t.kind) {
                case WARM: runWarm(t.ctx); break;
                case RESTORE: restoreIfNeeded(t.ctx); break;
                case FETCH: runFetch(t.ctx, t.fetch); break;
                case FETCH_ASKED: t.download = runFetchAsked(t.ctx); break;
                case APPLY: runApply(t.ctx, t.said, t.file); break;
                case RESUMED: runResumed(t.ctx); break;
                case CANCEL_AWAY: ops.cancelAway(t.ctx); break;
                case MAYBE_AWAY:
                    if (!inSight && snap.phase.equals(READY)) ops.scheduleAway(t.ctx);
                    break;
                case AWAY_LONG: runAwayLong(t.ctx); break;
                case REPLACED: runReplaced(t.ctx, t.onDone); break;
                default: break;
            }
        } catch (Throwable e) {
            safeLog("update: " + t.kind + " failed: " + e);
            if (t.kind == Kind.FETCH) fetchFailed(t.fetch, e);
            if (t.kind == Kind.APPLY) {
                boolean failedApply = false;
                synchronized (stateLock) {
                    applyQueued = false;
                    Snapshot s = snap;
                    if (t.file != null && !t.file.equals(installingFile) && s.phase.equals(INSTALLING) && s.file.equals(t.file)) {
                        snap = new Snapshot(FAILED, s.percent, why(e), s.file);
                        failedApply = true;
                    }
                }
                if (failedApply) changed(-1);
            }
        } finally {
            if (t.done != null) t.done.countDown();
        }
    }

    private void runWarm(Object c) {
        long gen;
        synchronized (stateLock) {
            gen = meteredGen;
        }
        try {
            cacheVersionCode(ops.versionCode(c));
        } catch (Throwable e) {
            safeLog("update: version code not read: " + e);
        }
        try {
            cachedCanInstall = ops.canInstall(c);
        } catch (Throwable e) {
            safeLog("update: whether the app may install apps not read: " + e);
        }
        try {
            boolean m = ops.metered(c);
            synchronized (stateLock) {
                if (gen == meteredGen) cachedMetered = m;
            }
        } catch (Throwable e) {
            safeLog("update: whether the network is metered not read: " + e);
        }
        restoreIfNeeded(c);
    }

    private void cacheMetered(boolean m, long gen) {
        synchronized (stateLock) {
            if (gen == meteredGen) cachedMetered = m;
        }
    }

    private void restoreIfNeeded(Object c) {
        if (restored) return;
        Restored r = ops.restore(c);
        boolean tell = false;
        synchronized (stateLock) {
            if (restored) return;
            restored = true;
            if (r == null) return;
            readyOnDisk = r.ready;
            if (r.asked != null) {
                cachedPartName = r.asked.partName();
                cachedPartBytes = r.askedPart;
            }
            // (a build asked for meanwhile is what the app wants now: what was left only where nothing was)
            if (!fetchSeen && snap.phase.equals(IDLE)) {
                if (r.ready != null) {
                    snap = new Snapshot(READY, -1, "", r.ready);
                    tell = true;
                } else if (r.asked != null) {
                    snap = new Snapshot(WAITING, -1, "", r.asked.name);
                    tell = true;
                }
            }
        }
        if (tell) changed(1);
    }

    private void runFetch(Object c, Fetch f) {
        restoreIfNeeded(c);
        ops.keepAsked(c, f);
        boolean early;
        boolean nowAtRead;
        long gen;
        synchronized (stateLock) {
            early = f.name.equals(readyOnDisk);
            nowAtRead = activeNow;
            gen = meteredGen;
        }
        if (early) {
            boolean handed;
            synchronized (stateLock) {
                readyOnDisk = null;
                snap = new Snapshot(READY, -1, "", f.name);
                handed = finishOrHandoffLocked(READY, f.name);
            }
            ops.log("update: " + f.name + " ready already");
            changed(handed ? 0 : 1);
            return;
        }
        boolean metered = false;
        if (!nowAtRead) {
            metered = ops.metered(c);
            cacheMetered(metered, gen);
        }
        long have = ops.partBytes(c, f.name, f.deltaSize > 0);
        Download d = null;
        boolean handed = false;
        synchronized (stateLock) {
            cachedPartName = f.partName();
            cachedPartBytes = have;
            boolean meteredNow = !nowAtRead && (gen == meteredGen ? metered : Boolean.TRUE.equals(cachedMetered));
            // (asked for now meanwhile: the person's word kept, whatever the network)
            if (meteredNow && !activeNow) {
                snap = new Snapshot(WAITING, -1, "", f.name);
                handed = finishOrHandoffLocked(WAITING, null);
            } else {
                d = startDownloadLocked(f.now(activeNow || f.now), have);
            }
        }
        if (d == null) {
            if (handed) {
                changed(0);
                return;
            }
            ops.log("update: " + f.name + " waits for a network that is not metered");
            try {
                ops.scheduleFetchJob(c);
            } catch (Throwable e) {
                safeLog("update: fetch job not scheduled: " + e);
            }
            changed(1);
            return;
        }
        spawnDownload(c, d);
    }

    /** FETCH ended by an exception before its download began: failed, handed over. */
    private void fetchFailed(Fetch f, Throwable e) {
        boolean handed;
        synchronized (stateLock) {
            if (!fetchQueued || downloadActive || !f.name.equals(activeFile)) return;
            Snapshot s = snap;
            snap = new Snapshot(FAILED, s.percent, why(e), f.name);
            handed = finishOrHandoffLocked(FAILED, null);
        }
        changed(handed ? 0 : -1);
    }

    private Download startDownloadLocked(Fetch f, long have) {
        fetchQueued = false;
        downloadActive = true;
        activeFile = f.name;
        readyOnDisk = null;
        snap = new Snapshot(DOWNLOADING, f.percentOf(have), "", f.name);
        return new Download(f);
    }

    private void spawnDownload(Object c, Download d) {
        changed(0);
        try {
            ops.spawn(() -> runDownload(c, d), "mbui-update");
        } catch (Throwable e) {
            safeLog("update: the download's thread not started: " + e);
            endDownload(c, d, FAILED, why(e));
        }
    }

    private void runDownload(Object c, Download d) {
        String result = READY, why = "";
        try {
            ops.download(c, d.fetch);
            safeLog("update: " + d.fetch.name + " ready");
        } catch (Throwable e) {
            result = FAILED;
            why = why(e);
            safeLog("update failed: " + why);
        }
        endDownload(c, d, result, why);
    }

    private void endDownload(Object c, Download d, String result, String why) {
        try {
            long have = -1;
            if (result.equals(FAILED)) {
                try {
                    have = ops.partBytes(c, d.fetch.name, d.fetch.deltaSize > 0);
                } catch (Throwable ignored) {
                    // (not known: the next try reads it)
                }
            }
            boolean handed;
            synchronized (stateLock) {
                if (have >= 0) {
                    cachedPartName = d.fetch.partName();
                    cachedPartBytes = have;
                }
                Snapshot s = snap;
                // Published only as another download can be accepted: the app may hand a newer build right away.
                snap = new Snapshot(result, s.percent, why, d.fetch.name);
                handed = finishOrHandoffLocked(result, result.equals(READY) ? d.fetch.name : null);
            }
            changed(handed ? 0 : result.equals(FAILED) ? -1 : 1);
        } finally {
            d.ended.countDown();
        }
    }

    /**
     * Every end of a fetch: what was under way let go, and the build asked for meanwhile taken up (unless it is the one
     * just made ready); else, ready while out of sight, the job that puts it in place. Whether it was handed over.
     */
    private boolean finishOrHandoffLocked(String result, String readyName) {
        fetchQueued = false;
        downloadActive = false;
        activeFile = null;
        activeNow = false;
        Fetch p = pendingFetch;
        pendingFetch = null;
        if (p != null && !(result.equals(READY) && p.name.equals(readyName))) {
            fetchSeen = true;
            fetchQueued = true;
            activeFile = p.name;
            activeNow = p.now;
            publishOptimisticLocked(p);
            enqueueLocked(new Task(Kind.FETCH, ctx, p, null, null, null, false));
            return true;
        }
        if (result.equals(READY) && !inSight && ctx != null) {
            enqueueLocked(new Task(Kind.MAYBE_AWAY, ctx, null, null, null, null, false));
        }
        return false;
    }

    /** What the person sees of `f` at once: waiting where the network is known metered, else downloading. Whether it waits. */
    private boolean publishOptimisticLocked(Fetch f) {
        boolean waits = !f.now && Boolean.TRUE.equals(cachedMetered);
        snap = waits ? new Snapshot(WAITING, -1, "", f.name) : new Snapshot(DOWNLOADING, percentFromCache(f), "", f.name);
        return waits;
    }

    /** How far `f` is from what was read of its own part ahead; -1 not read yet (the worker says it soon). */
    private int percentFromCache(Fetch f) {
        return restored && f.partName().equals(cachedPartName) ? f.percentOf(cachedPartBytes) : -1;
    }

    private Download runFetchAsked(Object c) {
        restoreIfNeeded(c);
        Fetch a = ops.readAsked(c);
        if (a == null) return null;
        long have = ops.partBytes(c, a.name, a.deltaSize > 0);
        Download d;
        synchronized (stateLock) {
            if (!snap.phase.equals(WAITING) || downloadActive || fetchQueued) return null;
            cachedPartName = a.partName();
            cachedPartBytes = have;
            activeNow = true;
            d = startDownloadLocked(a, have);
        }
        spawnDownload(c, d);
        return d;
    }

    private void runApply(Object c, String said, String file) {
        boolean may = ops.canInstall(c);
        cachedCanInstall = may;
        synchronized (stateLock) {
            applyQueued = false;
            Snapshot s = snap;
            if (!s.file.equals(file) || !(s.phase.equals(INSTALLING) || s.phase.equals(ALLOW) || s.phase.equals(READY))) return;
            if (!may) {
                snap = new Snapshot(ALLOW, s.percent, s.error, s.file);
                nowSaid = said;
            }
        }
        if (!may) {
            ops.log("update: the person's leave to install apps asked for");
            changed(1);
            ops.openUnknownSources(c);
            return;
        }
        put(c, said);
    }

    private void runResumed(Object c) {
        if (!snap.phase.equals(ALLOW)) return;
        boolean may = ops.canInstall(c);
        cachedCanInstall = may;
        if (!may) return;
        String said;
        synchronized (stateLock) {
            Snapshot s = snap;
            if (!s.phase.equals(ALLOW)) return;
            snap = new Snapshot(READY, s.percent, s.error, s.file);
            said = nowSaid;
            nowSaid = null;
        }
        ops.log("update: the person's leave to install apps given");
        if (said != null) put(c, said);
        else changed(1);
    }

    private void runAwayLong(Object c) {
        restoreIfNeeded(c);
        if (inSight || !snap.phase.equals(READY)) return;
        if (ops.loginListening()) {
            ops.scheduleAway(c);
            return;
        }
        boolean may = ops.canInstall(c);
        cachedCanInstall = may;
        if (!may) {
            synchronized (stateLock) {
                Snapshot s = snap;
                if (!s.phase.equals(READY)) return;
                snap = new Snapshot(ALLOW, s.percent, s.error, s.file);
            }
            ops.log("update: ready, the person's leave to install apps wanted");
            changed(1);
            return;
        }
        // (looked at again just before: the app may have come back, a sign-in begun)
        if (inSight || !snap.phase.equals(READY)) return;
        if (ops.loginListening()) {
            ops.scheduleAway(c);
            return;
        }
        put(c, null);
    }

    /** The build ready handed to the installer (on the worker); `said` kept for the newer build's notification. */
    private void put(Object c, String said) {
        String name = ops.readyFile(c);
        if (name == null) {
            synchronized (stateLock) {
                snap = new Snapshot(IDLE, -1, "", "");
            }
            changed(1);
            return;
        }
        synchronized (stateLock) {
            Snapshot s = snap;
            snap = new Snapshot(INSTALLING, s.percent, s.error, name);
            installingFile = name;
            installingSessionId = NO_SESSION;
        }
        changed(0);
        try {
            ops.keepSaid(c, said);
            int id = ops.installCreate(c, name);
            synchronized (stateLock) {
                if (name.equals(installingFile)) installingSessionId = id;
            }
            ops.installCommit(c, id, name);
            ops.log("update: " + name + " handed to the system's installer");
        } catch (Throwable e) {
            String why = why(e);
            synchronized (stateLock) {
                Snapshot s = snap;
                snap = new Snapshot(FAILED, s.percent, why, s.file);
                releaseInstallLocked();
            }
            safeLog("update failed: " + why);
            changed(-1);
        }
    }

    private void releaseInstallLocked() {
        installingFile = null;
        installingSessionId = NO_SESSION;
    }

    private void runReplaced(Object c, Runnable finish) {
        boolean handedOff = false;
        try {
            Set<String> keep = new HashSet<>();
            synchronized (stateLock) {
                if (activeFile != null) keep.add(activeFile);
                if (pendingFetch != null) keep.add(pendingFetch.name);
                if (installingFile != null) keep.add(installingFile);
            }
            String said = ops.replacedClean(c, keep);
            if (said != null && !said.isEmpty()) {
                ops.replacedNotice(c, said, finish);
                handedOff = true;
            }
        } catch (Throwable e) {
            safeLog("update notice failed: " + e);
        } finally {
            if (!handedOff && finish != null) {
                try {
                    finish.run();
                } catch (Throwable ignored) {
                    // (the broadcast gone already)
                }
            }
        }
    }

    private void changed(int state) {
        try {
            ops.changed(state);
        } catch (Throwable ignored) {
            // (the app gone: it reads the state as it comes back)
        }
    }

    private void safeLog(String s) {
        try {
            ops.log(s);
        } catch (Throwable ignored) {
            // (no log file)
        }
    }

    private static String why(Throwable e) {
        return e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage();
    }
}
