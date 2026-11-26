package dev.mbui;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Deterministic unit tests for {@link UpdatesQueue} (plain Java, no Android).
 * Run: sh libs/ui/scripts/updatesqueue_test.sh
 */
public final class UpdatesQueueTest {
    private static int failures;
    private static final Object CTX = "ctx";

    private static void check(String what, boolean ok, String detail) {
        System.out.println((ok ? "ok   " : "FAIL ") + what + (detail.isEmpty() ? "" : ": " + detail));
        if (!ok) failures++;
    }

    private static UpdatesQueue.Fetch fetchOf(String name, boolean now) {
        return new UpdatesQueue.Fetch("https://x/" + name, "sha-" + name, 1000, name, "", 0, now);
    }

    private static String snap(UpdatesQueue q) {
        UpdatesQueue.Snapshot s = q.state(null);
        return s.phase + "/" + s.percent + "/" + s.file + (s.error.isEmpty() ? "" : "/" + s.error);
    }

    /** Every Ops call recorded with the thread it ran on; `changed` is the only one that is no file and no Binder. */
    private static class FakeOps implements UpdatesQueue.Ops {
        final List<String> log = Collections.synchronizedList(new ArrayList<>());
        final List<String> ioThreads = Collections.synchronizedList(new ArrayList<>());
        final List<Integer> told = Collections.synchronizedList(new ArrayList<>());
        final List<Runnable> spawned = Collections.synchronizedList(new ArrayList<>());
        final List<String> downloads = Collections.synchronizedList(new ArrayList<>());
        volatile boolean spawnThreads;
        volatile int versionCode = 42;
        volatile boolean canInstall = true;
        volatile boolean metered;
        volatile boolean listening;
        volatile UpdatesQueue.Restored restored = new UpdatesQueue.Restored(null, null, 0);
        volatile UpdatesQueue.Fetch asked;
        volatile long partBytes;
        volatile String ready = "A";
        volatile String said = null;
        volatile int session = 77;
        final AtomicReference<Throwable> restoreThrows = new AtomicReference<>();
        final CountDownLatch downloadEntered = new CountDownLatch(1);
        volatile RuntimeException keepAskedThrows;
        volatile RuntimeException canInstallThrows;
        volatile RuntimeException readyFileThrows;
        volatile RuntimeException scheduleFetchThrows;
        volatile RuntimeException cleanThrows;
        volatile RuntimeException noticeThrows;
        volatile Exception downloadThrows;
        volatile Runnable onMetered;
        volatile Runnable onRestore;
        volatile CountDownLatch downloadGate;
        volatile Set<String> lastKeep;

        private void io(String what) {
            ioThreads.add(Thread.currentThread().getName());
            log.add(what);
        }

        @Override public int versionCode(Object ctx) { io("versionCode"); return versionCode; }
        @Override
        public boolean canInstall(Object ctx) {
            io("canInstall");
            if (canInstallThrows != null) throw canInstallThrows;
            return canInstall;
        }

        @Override
        public boolean metered(Object ctx) {
            io("metered");
            Runnable r = onMetered;
            if (r != null) r.run();
            return metered;
        }

        @Override
        public UpdatesQueue.Restored restore(Object ctx) {
            io("restore");
            Runnable r = onRestore;
            if (r != null) r.run();
            Throwable t = restoreThrows.getAndSet(null);
            if (t instanceof Error) throw (Error) t;
            if (t instanceof RuntimeException) throw (RuntimeException) t;
            return restored;
        }

        @Override public long partBytes(Object ctx, String name, boolean delta) { io("partBytes:" + name); return partBytes; }

        @Override
        public void keepAsked(Object ctx, UpdatesQueue.Fetch f) {
            io("keepAsked:" + f.name);
            if (keepAskedThrows != null) throw keepAskedThrows;
        }

        @Override public UpdatesQueue.Fetch readAsked(Object ctx) { io("readAsked"); return asked; }

        @Override
        public void download(Object ctx, UpdatesQueue.Fetch f) throws Exception {
            io("download:" + f.name);
            downloads.add(f.name);
            downloadEntered.countDown();
            CountDownLatch g = downloadGate;
            if (g != null) g.await();
            if (downloadThrows != null) throw downloadThrows;
        }

        @Override
        public void scheduleFetchJob(Object ctx) {
            io("scheduleFetchJob");
            if (scheduleFetchThrows != null) throw scheduleFetchThrows;
        }
        @Override public void scheduleAway(Object ctx) { io("scheduleAway"); }
        @Override public void cancelAway(Object ctx) { io("cancelAway"); }
        @Override public void openUnknownSources(Object ctx) { io("openUnknownSources"); }
        @Override
        public String readyFile(Object ctx) {
            io("readyFile");
            if (readyFileThrows != null) throw readyFileThrows;
            return ready;
        }
        @Override public void keepSaid(Object ctx, String s) { io("keepSaid:" + s); }
        @Override public int installCreate(Object ctx, String name) { io("installCreate:" + name); return session; }
        @Override public void installCommit(Object ctx, int s, String name) { io("installCommit:" + s + ":" + name); }
        @Override public boolean loginListening() { io("loginListening"); return listening; }

        @Override
        public String replacedClean(Object ctx, Set<String> keep) {
            io("replacedClean");
            lastKeep = keep;
            if (cleanThrows != null) throw cleanThrows;
            return said;
        }

        @Override
        public void replacedNotice(Object ctx, String s, Runnable onDone) {
            io("replacedNotice:" + s);
            if (noticeThrows != null) throw noticeThrows;
            onDone.run();
        }

        @Override public void changed(int state) { told.add(state); }

        @Override
        public void spawn(Runnable r, String name) {
            io("spawn");
            if (spawnThreads) new Thread(r, name).start();
            else spawned.add(r);
        }

        @Override public void log(String s) { /* the log file: not counted, as the worker's */ }

        int count(String prefix) {
            int n = 0;
            synchronized (log) {
                for (String s : log) if (s.startsWith(prefix)) n++;
            }
            return n;
        }

        Runnable takeSpawned() {
            return spawned.isEmpty() ? null : spawned.remove(0);
        }
    }

    /** 1. The app's threads touch no file and no Binder: the worker frozen, every call returns from memory. */
    private static void frozenWorkerCase() {
        FakeOps ops = new FakeOps();
        UpdatesQueue q = new UpdatesQueue(ops, false);
        q.warmUp(CTX);
        q.state(CTX);
        q.fetch(CTX, fetchOf("A", false));
        q.fetch(CTX, fetchOf("B", true));
        q.apply(CTX, "said");
        q.started(CTX);
        q.stopped(CTX);
        q.resumed(CTX);
        q.onMeteredChanged(true);
        check("frozen worker: state/fetch/apply/started/stopped/resumed make no file or Binder call",
                ops.log.isEmpty() && ops.ioThreads.isEmpty(), "log=" + ops.log);
        check("frozen worker: frame-1 shows downloading (metering not known yet, the part not read: -1)",
                snap(q).equals("downloading/-1/A"), snap(q));

        // a second queue whose restore read A's part: B asked for meanwhile takes none of A's bytes
        FakeOps ops2 = new FakeOps();
        ops2.restored = new UpdatesQueue.Restored(null, fetchOf("A", false), 500);
        UpdatesQueue q2 = new UpdatesQueue(ops2, false);
        q2.warmUp(CTX);
        q2.drainInline();
        ops2.log.clear();
        q2.fetch(CTX, fetchOf("B", false));
        check("frozen worker: fetch(B) after A's part was read borrows none of A's bytes",
                snap(q2).equals("downloading/-1/B") && ops2.log.isEmpty(), snap(q2) + " log=" + ops2.log);
    }

    /** 1b. A real worker stuck in a read: the app's threads go on, nothing runs on them. */
    private static void blockedWorkerCase() throws Exception {
        FakeOps ops = new FakeOps();
        CountDownLatch inRestore = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        ops.onRestore = () -> {
            inRestore.countDown();
            try {
                release.await();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        };
        UpdatesQueue q = new UpdatesQueue(ops, true);
        q.warmUp(CTX);
        boolean entered = inRestore.await(5, TimeUnit.SECONDS);
        String me = Thread.currentThread().getName();
        long t0 = System.nanoTime();
        q.state(CTX);
        q.fetch(CTX, fetchOf("A", false));
        q.apply(CTX, "x");
        q.started(CTX);
        q.stopped(CTX);
        q.resumed(CTX);
        long ms = (System.nanoTime() - t0) / 1_000_000L;
        String afterCalls = snap(q);
        release.countDown();
        CountDownLatch quiet = new CountDownLatch(1);
        q.replaced(CTX, quiet::countDown);
        boolean drained = quiet.await(5, TimeUnit.SECONDS);
        boolean none = !ops.ioThreads.contains(me);
        boolean allWorker = true;
        synchronized (ops.ioThreads) {
            for (String t : ops.ioThreads) if (!t.equals("mbui-update-io")) allWorker = false;
        }
        check("blocked worker: calls return while the worker is stuck, every Ops call on mbui-update-io",
                entered && drained && none && allWorker && afterCalls.equals("downloading/-1/A"),
                "ms=" + ms + " threads=" + ops.ioThreads + " snap=" + afterCalls);
    }

    /** 2. What the person sees at frame 1: downloading at the part's percent, waiting, allow, installing. */
    private static void optimisticFrameOneCase() {
        FakeOps ops = new FakeOps();
        ops.restored = new UpdatesQueue.Restored(null, fetchOf("A", false), 400);
        ops.partBytes = 400;
        UpdatesQueue q = new UpdatesQueue(ops, false);
        q.warmUp(CTX);
        q.drainInline();
        String restoredSnap = snap(q);
        q.onMeteredChanged(false);
        ops.log.clear();
        q.fetch(CTX, fetchOf("A", true));
        String frame1 = snap(q);
        check("frame 1: resumed download shows the part's own percent (40), no file read",
                restoredSnap.equals("waiting/-1/A") && frame1.equals("downloading/40/A") && ops.log.isEmpty(),
                restoredSnap + " -> " + frame1 + " log=" + ops.log);
        q.drainInline();
        Runnable dl = ops.takeSpawned();
        check("frame 1: the worker's read agrees (40, downloading)", dl != null && snap(q).equals("downloading/40/A"), snap(q));

        FakeOps m = new FakeOps();
        UpdatesQueue qm = new UpdatesQueue(m, false);
        qm.warmUp(CTX);
        qm.drainInline();
        qm.onMeteredChanged(true);
        qm.fetch(CTX, fetchOf("C", false));
        check("frame 1: known metered and not asked for now: waiting", snap(qm).equals("waiting/-1/C"), snap(qm));

        // ready, then apply: installing where the app may install, allow where it may not
        FakeOps a = new FakeOps();
        a.restored = new UpdatesQueue.Restored("A", null, 0);
        a.canInstall = false;
        UpdatesQueue qa = new UpdatesQueue(a, false);
        qa.warmUp(CTX);
        qa.drainInline();
        a.log.clear();
        qa.apply(CTX, "hi");
        String allow = snap(qa);
        FakeOps b = new FakeOps();
        b.restored = new UpdatesQueue.Restored("A", null, 0);
        UpdatesQueue qb = new UpdatesQueue(b, false);
        qb.warmUp(CTX);
        qb.drainInline();
        b.log.clear();
        qb.apply(CTX, "hi");
        check("frame 1: apply shows allow / installing at once, no Binder",
                allow.equals("allow/-1/A") && snap(qb).equals("installing/-1/A") && a.log.isEmpty() && b.log.isEmpty(),
                allow + " " + snap(qb));
    }

    /** 3a. A downloading, B asked for meanwhile: B taken up as A is ready. */
    private static void handoffAfterDownloadCase() {
        FakeOps ops = new FakeOps();
        UpdatesQueue q = new UpdatesQueue(ops, false);
        q.warmUp(CTX);
        q.drainInline();
        q.started(CTX);
        q.drainInline();
        q.fetch(CTX, fetchOf("A", true));
        q.drainInline();
        Runnable a = ops.takeSpawned();
        q.fetch(CTX, fetchOf("B", true));
        String during = snap(q);
        a.run();
        String after = snap(q);
        q.drainInline();
        Runnable b = ops.takeSpawned();
        if (b != null) b.run();
        check("handoff: B asked for while A downloads is taken up as A is ready",
                during.equals("downloading/0/A") && after.equals("downloading/-1/B") && b != null
                        && ops.downloads.equals(List.of("A", "B")) && snap(q).equals("ready/0/B"),
                during + " -> " + after + " -> " + snap(q) + " downloads=" + ops.downloads);
    }

    /** 3b. A found ready on disk before its download (restore ran late), B asked for meanwhile: B not lost. */
    private static void handoffAfterEarlyReadyCase() {
        FakeOps ops = new FakeOps();
        ops.restored = new UpdatesQueue.Restored("A", null, 0);
        UpdatesQueue q = new UpdatesQueue(ops, false);
        q.started(CTX);
        q.fetch(CTX, fetchOf("A", true));
        q.fetch(CTX, fetchOf("B", true));
        q.drainInline();
        Runnable b = ops.takeSpawned();
        if (b != null) b.run();
        check("handoff: A ready on disk already still hands over to B",
                b != null && ops.downloads.equals(List.of("B")) && snap(q).equals("ready/0/B"),
                snap(q) + " downloads=" + ops.downloads + " log=" + ops.log);
    }

    /** 3c. A failed (and A's FETCH thrown) still hand over to B. */
    private static void handoffAfterFailureCase() {
        FakeOps ops = new FakeOps();
        UpdatesQueue q = new UpdatesQueue(ops, false);
        q.warmUp(CTX);
        q.drainInline();
        ops.keepAskedThrows = new RuntimeException("disk full");
        q.fetch(CTX, fetchOf("A", true));
        q.fetch(CTX, fetchOf("B", true));
        q.stepOne();
        String afterThrow = snap(q);
        ops.keepAskedThrows = null;
        q.drainInline();
        Runnable b = ops.takeSpawned();
        ops.downloadThrows = new java.io.IOException("cut");
        q.fetch(CTX, fetchOf("C", true));
        if (b != null) b.run();
        String afterFail = snap(q);
        q.drainInline();
        Runnable c = ops.takeSpawned();
        check("handoff: an exception in A's FETCH and B's failed download each hand over",
                afterThrow.equals("downloading/-1/B") && b != null && afterFail.equals("downloading/-1/C") && c != null,
                afterThrow + " " + afterFail);
    }

    /** 4. Cache said unmetered, the worker finds it metered, the person asks for now meanwhile: downloaded now. */
    private static void nowUpgradeCase() {
        for (boolean click : new boolean[]{false, true}) {
            FakeOps ops = new FakeOps();
            UpdatesQueue q = new UpdatesQueue(ops, false);
            q.warmUp(CTX);
            q.drainInline();
            q.onMeteredChanged(false);
            ops.metered = true;
            if (click) ops.onMetered = () -> q.fetch(CTX, fetchOf("A", true));
            q.fetch(CTX, fetchOf("A", false));
            String frame1 = snap(q);
            q.drainInline();
            boolean spawned = ops.takeSpawned() != null;
            int jobs = ops.count("scheduleFetchJob");
            if (click) {
                check("now upgrade: asked for now while the worker reads metering: downloads, no waiting",
                        frame1.equals("downloading/-1/A") && spawned && jobs == 0 && snap(q).equals("downloading/0/A"),
                        snap(q) + " jobs=" + jobs);
            } else {
                check("now upgrade: control: metered, not asked for now: waiting with its job",
                        !spawned && jobs == 1 && snap(q).equals("waiting/-1/A"), snap(q));
            }
        }
        // waiting shown already, then now: downloading at once and the worker keeps to it
        FakeOps ops = new FakeOps();
        UpdatesQueue q = new UpdatesQueue(ops, false);
        q.warmUp(CTX);
        q.drainInline();
        q.onMeteredChanged(true);
        ops.metered = true;
        q.fetch(CTX, fetchOf("A", false));
        String w = snap(q);
        q.fetch(CTX, fetchOf("A", true));
        String up = snap(q);
        q.drainInline();
        check("now upgrade: waiting at frame 1 becomes downloading at once, kept by the worker",
                w.equals("waiting/-1/A") && up.equals("downloading/-1/A") && ops.takeSpawned() != null
                        && ops.count("scheduleFetchJob") == 0, w + " -> " + up + " -> " + snap(q));
    }

    /** 5a. One ready of that name: nothing more. */
    private static void dedupCase() {
        FakeOps ops = new FakeOps();
        ops.restored = new UpdatesQueue.Restored("A", null, 0);
        UpdatesQueue q = new UpdatesQueue(ops, false);
        q.warmUp(CTX);
        q.drainInline();
        int told = ops.told.size();
        q.fetch(CTX, fetchOf("A", true));
        check("dedup: the build ready asked for again: nothing queued, nothing told",
                q.queued() == 0 && ops.told.size() == told && snap(q).equals("ready/-1/A"), snap(q));
        q.fetch(CTX, fetchOf("B", true));
        q.fetch(CTX, fetchOf("B", true));
        check("dedup: the same build asked twice while queued: one FETCH", q.queued() == 1, "queued=" + q.queued());
    }

    /** 5b. APPLY then RESUMED in that order; the leave given, put in place with what it says. */
    private static void applyThenResumedCase() {
        FakeOps ops = new FakeOps();
        ops.restored = new UpdatesQueue.Restored("A", null, 0);
        ops.canInstall = false;
        UpdatesQueue q = new UpdatesQueue(ops, false);
        q.warmUp(CTX);
        q.drainInline();
        ops.log.clear();
        q.apply(CTX, "hello");
        q.resumed(CTX);
        int queued = q.queued();
        q.drainInline();
        List<String> first = new ArrayList<>(ops.log);
        String allow = snap(q);
        ops.canInstall = true;
        ops.log.clear();
        q.resumed(CTX);
        q.drainInline();
        check("apply then resumed: APPLY asks for the leave, RESUMED after it finds none yet",
                queued == 2 && first.equals(List.of("canInstall", "openUnknownSources", "canInstall")) && allow.equals("allow/-1/A"),
                "queued=" + queued + " log=" + first + " " + allow);
        check("apply then resumed: the leave given, put in place with what it says",
                ops.log.equals(List.of("canInstall", "readyFile", "keepSaid:hello", "installCreate:A", "installCommit:77:A"))
                        && snap(q).equals("installing/-1/A") && "A".equals(q.installingFile()),
                "log=" + ops.log + " " + snap(q));
    }

    /** 5c. The build with the installer: kept from a download's cleanup, the session's answers only. */
    private static void installingOwnershipCase() {
        FakeOps ops = new FakeOps();
        ops.restored = new UpdatesQueue.Restored("A", null, 0);
        UpdatesQueue q = new UpdatesQueue(ops, false);
        q.warmUp(CTX);
        q.drainInline();
        q.started(CTX);
        q.apply(CTX, null);
        q.drainInline();
        boolean stale = q.installStatus(12, UpdatesQueue.INSTALL_FAILURE, "old");
        String afterStale = snap(q);
        boolean confirm = q.installStatus(77, UpdatesQueue.INSTALL_PENDING_USER, null);
        String owner = q.installingFile();
        q.installStatus(77, UpdatesQueue.INSTALL_ABORTED, null);
        check("installing: another session's answer ignored; the confirmation page keeps the build the installer's",
                !stale && afterStale.equals("installing/-1/A") && confirm && "A".equals(owner),
                afterStale + " owner=" + owner);
        check("installing: refused, ready again and let go", snap(q).equals("ready/-1/A") && q.installingFile() == null, snap(q));

        q.apply(CTX, null);
        q.drainInline();
        q.stopped(CTX);
        q.drainInline();
        boolean away = q.installStatus(77, UpdatesQueue.INSTALL_PENDING_USER, null);
        check("installing: the page wanted while away: ready again, let go",
                !away && snap(q).equals("ready/-1/A") && q.installingFile() == null, snap(q));

        q.apply(CTX, null);
        q.drainInline();
        q.installStatus(77, UpdatesQueue.INSTALL_FAILURE, "no space");
        check("installing: failed, said and let go", snap(q).equals("failed/-1/A/no space") && q.installingFile() == null, snap(q));
    }

    /** 5d. Replaced: the broadcast finished exactly once on every path; what is under way kept. */
    private static void replacedExactlyOnceCase() {
        String[] names = {"notice", "nothing said", "clean throws", "notice throws"};
        for (int i = 0; i < names.length; i++) {
            FakeOps ops = new FakeOps();
            ops.said = i == 1 ? null : "new";
            if (i == 2) ops.cleanThrows = new RuntimeException("io");
            if (i == 3) ops.noticeThrows = new RuntimeException("binder");
            UpdatesQueue q = new UpdatesQueue(ops, false);
            AtomicInteger finished = new AtomicInteger();
            q.replaced(CTX, finished::incrementAndGet);
            q.drainInline();
            check("replaced (" + names[i] + "): finish called exactly once", finished.get() == 1, "n=" + finished.get());
        }
        FakeOps ops = new FakeOps();
        UpdatesQueue q = new UpdatesQueue(ops, false);
        q.warmUp(CTX);
        q.drainInline();
        q.fetch(CTX, fetchOf("N", true));
        q.drainInline();
        AtomicInteger finished = new AtomicInteger();
        q.replaced(CTX, finished::incrementAndGet);
        q.drainInline();
        check("replaced: the build downloading is kept", ops.lastKeep != null && ops.lastKeep.contains("N") && finished.get() == 1,
                "keep=" + ops.lastKeep);
    }

    /** 5e. fetchAsked and awayLong wait till their work is done (on a job's thread, never the worker). */
    private static void awaitableCase() throws Exception {
        FakeOps ops = new FakeOps();
        ops.spawnThreads = true;
        ops.restored = new UpdatesQueue.Restored(null, fetchOf("A", false), 0);
        ops.asked = fetchOf("A", false);
        CountDownLatch gate = new CountDownLatch(1);
        ops.downloadGate = gate;
        UpdatesQueue q = new UpdatesQueue(ops, true);
        CountDownLatch jobDone = new CountDownLatch(1);
        AtomicReference<Throwable> err = new AtomicReference<>();
        Thread job = new Thread(() -> {
            try {
                q.fetchAsked(CTX);
            } catch (Throwable t) {
                err.set(t);
            }
            jobDone.countDown();
        }, "job");
        job.start();
        boolean entered = ops.downloadEntered.await(5, TimeUnit.SECONDS);
        // (the download held at its gate: the job cannot have ended)
        boolean earlyDone = jobDone.getCount() == 0;
        String during = snap(q);
        gate.countDown();
        boolean done = jobDone.await(5, TimeUnit.SECONDS);
        check("fetchAsked: the job's thread waits till the download is whole",
                entered && !earlyDone && done && err.get() == null && during.equals("downloading/0/A") && snap(q).equals("ready/0/A"),
                during + " -> " + snap(q));

        Thread away = new Thread(() -> {
            try {
                q.awayLong(CTX);
            } catch (InterruptedException e) {
                err.set(e);
            }
        }, "away");
        away.start();
        away.join(5000);
        check("awayLong: returns once the build is handed to the installer",
                !away.isAlive() && ops.count("installCommit") == 1 && snap(q).equals("installing/0/A"), snap(q));

        FakeOps o2 = new FakeOps();
        o2.listening = true;
        o2.restored = new UpdatesQueue.Restored("A", null, 0);
        UpdatesQueue q2 = new UpdatesQueue(o2, true);
        q2.awayLong(CTX);
        check("awayLong: a sign-in waits: later again, not put in place",
                o2.count("scheduleAway") == 1 && o2.count("installCreate") == 0, "log=" + o2.log);
    }

    /** 5f. A Throwable in a task kills no worker; the next task runs. */
    private static void throwableIsolationCase() throws Exception {
        FakeOps ops = new FakeOps();
        ops.restoreThrows.set(new Error("boom"));
        ops.listening = true;
        ops.restored = new UpdatesQueue.Restored("A", null, 0);
        UpdatesQueue q = new UpdatesQueue(ops, true);
        q.warmUp(CTX);
        q.awayLong(CTX);
        check("throwable isolation: the worker lives on after an Error and restores on the next task",
                ops.count("restore") == 2 && snap(q).equals("ready/-1/A") && ops.count("scheduleAway") == 1, "log=" + ops.log);
    }

    /** 5g. Late installStatus for A must not clobber newer download B; APPLY failure unsticks INSTALLING; metered race & scheduleFetchJob catch. */
    private static void reviewEdgeCases() {
        // 1. Pre-cached versionCode available synchronously before WARM runs with zero I/O.
        FakeOps ops0 = new FakeOps();
        UpdatesQueue q0 = new UpdatesQueue(ops0, false);
        q0.cacheVersionCode(12345);
        check("cold-start versionCode: pre-cached value readable with zero ops",
                q0.cachedVersionCode() == 12345 && ops0.log.isEmpty(), "v=" + q0.cachedVersionCode());

        // 2. A installing (session 77), then B starts downloading; late A installStatus (FAILURE / ABORTED / PENDING_USER)
        //    must release A's install ownership without clobbering B's DOWNLOADING snapshot.
        for (int status : new int[] { -1, UpdatesQueue.INSTALL_ABORTED, UpdatesQueue.INSTALL_PENDING_USER }) {
            FakeOps ops = new FakeOps();
            ops.restored = new UpdatesQueue.Restored("A", null, 0);
            ops.ready = "A";
            ops.session = 77;
            UpdatesQueue q = new UpdatesQueue(ops, false);
            q.warmUp(CTX);
            q.drainInline();
            q.started(CTX);
            q.apply(CTX, "msg");
            q.drainInline();
            q.fetch(CTX, fetchOf("B", true));
            q.drainInline();
            int toldBefore = ops.told.size();
            boolean openUi = q.installStatus(77, status, "late-A");
            check("late installStatus(" + status + ") for A does not clobber B downloading",
                    !openUi && snap(q).equals("downloading/0/B") && q.installingFile() == null && ops.told.size() == toldBefore,
                    "snap=" + snap(q) + " installing=" + q.installingFile() + " openUi=" + openUi);
        }

        // 3. APPLY exception in ops.canInstall or ops.readyFile unsticks INSTALLING -> FAILED + changed(-1).
        for (boolean inReadyFile : new boolean[] { false, true }) {
            FakeOps ops = new FakeOps();
            ops.restored = new UpdatesQueue.Restored("A", null, 0);
            if (inReadyFile) ops.readyFileThrows = new RuntimeException("disk-boom");
            else ops.canInstallThrows = new RuntimeException("binder-dead");
            UpdatesQueue q = new UpdatesQueue(ops, false);
            q.warmUp(CTX);
            q.drainInline();
            ops.told.clear();
            q.apply(CTX, "msg");
            q.drainInline();
            String expected = inReadyFile ? "failed/-1/A/disk-boom" : "failed/-1/A/binder-dead";
            check("APPLY throw in " + (inReadyFile ? "readyFile" : "canInstall") + " transitions INSTALLING -> FAILED",
                    snap(q).equals(expected) && ops.told.contains(-1), "snap=" + snap(q) + " told=" + ops.told);
            // Recoverable: subsequent fetch(now=true) is accepted after APPLY failure
            ops.canInstallThrows = null;
            ops.readyFileThrows = null;
            q.fetch(CTX, fetchOf("A", true));
            q.drainInline();
            check("APPLY failure is recoverable via retry fetch(" + inReadyFile + ")",
                    snap(q).equals("ready/0/A") || snap(q).equals("ready/-1/A"), snap(q));
        }

        // 3b. A still holds an installer session while B finishes downloading, then B's APPLY throws in
        //     canInstall or readyFile: B must transition to FAILED while A's session ownership stays intact,
        //     late A ABORTED must release A without clobbering B, and retrying B must succeed.
        for (boolean inReadyFile : new boolean[] { false, true }) {
            FakeOps ops = new FakeOps();
            ops.restored = new UpdatesQueue.Restored("A", null, 0);
            ops.ready = "A";
            ops.session = 77;
            UpdatesQueue q = new UpdatesQueue(ops, false);
            q.warmUp(CTX);
            q.drainInline();
            q.started(CTX);
            q.apply(CTX, "msg-A");
            q.drainInline();
            // B downloads to READY while A still owns installingFile="A"
            ops.ready = "B";
            q.fetch(CTX, fetchOf("B", true));
            q.drainInline();
            ops.spawned.remove(0).run();
            ops.told.clear();
            if (inReadyFile) ops.readyFileThrows = new RuntimeException("disk-boom-B");
            else ops.canInstallThrows = new RuntimeException("binder-dead-B");
            q.apply(CTX, "msg-B");
            q.drainInline();
            String expected = inReadyFile ? "failed/0/B/disk-boom-B" : "failed/0/B/binder-dead-B";
            check("A owns session + B APPLY throw in " + (inReadyFile ? "readyFile" : "canInstall") + " fails B & keeps A owner",
                    snap(q).equals(expected) && "A".equals(q.installingFile()) && ops.told.contains(-1),
                    "snap=" + snap(q) + " owner=" + q.installingFile() + " told=" + ops.told);
            // Late A ABORTED clears A's ownership without touching B's FAILED state
            q.installStatus(77, UpdatesQueue.INSTALL_ABORTED, "aborted-A");
            check("late A ABORTED releases A owner while preserving B FAILED (" + inReadyFile + ")",
                    snap(q).equals(expected) && q.installingFile() == null,
                    "snap=" + snap(q) + " owner=" + q.installingFile());
            // B can now be retried cleanly
            ops.canInstallThrows = null;
            ops.readyFileThrows = null;
            q.fetch(CTX, fetchOf("B", true));
            q.drainInline();
            if (!ops.spawned.isEmpty()) ops.spawned.remove(0).run();
            check("B retry after A ABORTED recovers (" + inReadyFile + ")",
                    snap(q).startsWith("ready/"), snap(q));
        }

        // 4. meteredGen changes mid-ops.metered(c) (switched to Wi-Fi): runFetch uses fresher cachedMetered=false.
        FakeOps opsM = new FakeOps();
        opsM.metered = true;
        UpdatesQueue qM = new UpdatesQueue(opsM, false);
        opsM.onMetered = () -> qM.onMeteredChanged(false);
        qM.fetch(CTX, fetchOf("M", false));
        qM.drainInline();
        check("meteredGen race mid-ops.metered uses fresher unmetered state and starts download",
                snap(qM).equals("downloading/0/M") && opsM.spawned.size() == 1, snap(qM));

        // 5. scheduleFetchJob throwing still notifies changed(1) so UI sees WAITING.
        FakeOps opsJ = new FakeOps();
        opsJ.metered = true;
        opsJ.scheduleFetchThrows = new IllegalStateException("too many jobs");
        UpdatesQueue qJ = new UpdatesQueue(opsJ, false);
        qJ.fetch(CTX, fetchOf("J", false));
        qJ.drainInline();
        check("scheduleFetchJob throw still delivers WAITING changed(1)",
                snap(qJ).equals("waiting/-1/J") && opsJ.told.contains(1), "snap=" + snap(qJ) + " told=" + opsJ.told);
    }

    public static void main(String[] args) throws Exception {
        frozenWorkerCase();
        blockedWorkerCase();
        optimisticFrameOneCase();
        handoffAfterDownloadCase();
        handoffAfterEarlyReadyCase();
        handoffAfterFailureCase();
        nowUpgradeCase();
        dedupCase();
        applyThenResumedCase();
        installingOwnershipCase();
        replacedExactlyOnceCase();
        awaitableCase();
        throwableIsolationCase();
        reviewEdgeCases();
        if (failures > 0) {
            System.out.println(failures + " failed");
            System.exit(1);
        }
        System.out.println("all passed");
    }
}
