package dev.mbui;

import java.util.ArrayDeque;
import java.util.Objects;

/**
 * Pure-Java asynchronous notification worker queue and permission cache state machine (no Android imports so
 * {@code NoticesQueueTest} runs deterministically on any JVM).
 *
 * All NotificationManager Binder IPC ({@code show}, {@code cancel}, {@code drive}, {@code readPermission}) runs on a
 * single daemon worker thread in strict FIFO order outside {@link #lock}. Every task is isolated from
 * {@link RuntimeException} so the worker never dies, and awaiters / {@code onDone} callbacks are completed exactly once
 * in {@code finally}.
 */
final class NoticesQueue {
    static final int PERM_UNKNOWN = 0;
    static final int PERM_GRANTED = 1;
    static final int PERM_DENIED = 2;
    static final int PERM_ASK = 3;
    static final int PERM_PENDING = 5;
    static final int DRIVE_TIMEOUT = -1;
    static final int DRIVE_ERROR = -2;

    interface Ops {
        boolean ensureChannel(Object ctx, String channel, boolean onlyIfMissing);

        void show(Object ctx, String tag, String title, String body, String opens);

        void cancel(Object ctx, String tag);

        int readPermission(Object ctx);

        void requestFrame();

        int drive(Object ctx, boolean tap, String words);
    }

    private enum Kind {
        SHOW,
        EXTERNAL_SHOW,
        CANCEL,
        DRIVE,
        REFRESH
    }

    private static final class Task {
        final Kind kind;
        final Object ctx;
        final String channel;
        final String tag;
        final String title;
        final String body;
        final String opens;
        final boolean tap;
        final String words;
        final Runnable onDone;
        final boolean awaitable;
        boolean done;
        boolean started;
        boolean timedOut;
        boolean cancelled;
        int result;

        Task(Kind kind, Object ctx, String channel, String tag, String title, String body, String opens,
             boolean tap, String words, Runnable onDone, boolean awaitable) {
            this.kind = kind;
            this.ctx = ctx;
            this.channel = channel;
            this.tag = tag;
            this.title = title;
            this.body = body;
            this.opens = opens;
            this.tap = tap;
            this.words = words;
            this.onDone = onDone;
            this.awaitable = awaitable;
        }
    }

    private static final Task REFRESH_TASK = new Task(Kind.REFRESH, null, null, null, null, null, null, false, null, null, false);

    private final Ops ops;
    private final boolean autoStart;
    private final Runnable onWorkerStart;
    private final Object lock = new Object();
    private final ArrayDeque<Task> queue = new ArrayDeque<>();
    private boolean workerStarted;
    private Task activeDrive;

    // Accessed only on the single worker thread (or inline test thread).
    private String lastChannelName;

    // Permission state machine (all guarded by lock).
    private int permState = PERM_PENDING;
    private long permGen;
    private int pendingAnswer = -1;
    private boolean refreshQueued;
    private boolean refreshInFlight;
    private boolean refreshAgain;
    private Object permCtx;

    NoticesQueue(Ops ops, boolean autoStart, Runnable onWorkerStart) {
        this.ops = Objects.requireNonNull(ops, "ops");
        this.autoStart = autoStart;
        this.onWorkerStart = onWorkerStart;
    }

    void bindContext(Object ctx) {
        synchronized (lock) {
            if (ctx != null) permCtx = ctx;
        }
    }

    int permissionState() {
        synchronized (lock) {
            return permState;
        }
    }

    int takeAnswer() {
        synchronized (lock) {
            int r = pendingAnswer;
            pendingAnswer = -1;
            return r;
        }
    }

    void requestRefresh(Object ctx, boolean markPending) {
        synchronized (lock) {
            if (ctx != null) permCtx = ctx;
            permGen++;
            if (markPending) permState = PERM_PENDING;
            scheduleRefreshLocked();
        }
    }

    void onResumeRefresh(Object ctx) {
        synchronized (lock) {
            if (ctx != null) permCtx = ctx;
            permGen++;
            if (pendingAnswer == -1) {
                permState = PERM_PENDING;
            }
            scheduleRefreshLocked();
        }
    }

    void onPermissionResult(Object ctx, boolean cancelled, boolean granted, boolean sdk33Plus) {
        synchronized (lock) {
            if (ctx != null) permCtx = ctx;
            permGen++;
            if (cancelled) {
                permState = PERM_PENDING;
                pendingAnswer = -1;
            } else {
                permState = granted ? PERM_GRANTED : (sdk33Plus ? PERM_ASK : PERM_DENIED);
                pendingAnswer = granted ? 1 : 0;
            }
            scheduleRefreshLocked();
        }
        try {
            ops.requestFrame();
        } catch (RuntimeException ignored) {
        }
    }

    void enqueueShow(Object ctx, String channel, String tag, String title, String body, String opens) {
        enqueue(new Task(Kind.SHOW, ctx, channel, tag, title, body, opens, false, null, null, false));
    }

    void enqueueExternalShow(Object ctx, String channel, String tag, String title, String body, String opens, Runnable onDone) {
        enqueue(new Task(Kind.EXTERNAL_SHOW, ctx, channel, tag, title, body, opens, false, null, onDone, false));
    }

    boolean showExternalAwait(Object ctx, String channel, String tag, String title, String body, String opens, long timeoutMs) {
        Task task = new Task(Kind.EXTERNAL_SHOW, ctx, channel, tag, title, body, opens, false, null, null, true);
        enqueue(task);
        return awaitTask(task, timeoutMs);
    }

    void enqueueCancel(Object ctx, String tag) {
        enqueue(new Task(Kind.CANCEL, ctx, null, tag, null, null, null, false, null, null, false));
    }

    int drive(Object ctx, boolean tap, String words, long timeoutMs) {
        Task task;
        synchronized (lock) {
            if (activeDrive != null) {
                if (tap && activeDrive.tap && Objects.equals(activeDrive.words, words)) {
                    if (activeDrive.done) {
                        int r = activeDrive.result;
                        activeDrive = null;
                        return r;
                    }
                    task = activeDrive;
                    task.timedOut = false;
                } else {
                    if (!activeDrive.done) return DRIVE_TIMEOUT;
                    activeDrive = null;
                    task = new Task(Kind.DRIVE, ctx, null, null, null, null, null, tap, words, null, true);
                    activeDrive = task;
                    enqueueLocked(task);
                }
            } else {
                task = new Task(Kind.DRIVE, ctx, null, null, null, null, null, tap, words, null, true);
                activeDrive = task;
                enqueueLocked(task);
            }
        }
        awaitTask(task, timeoutMs);
        synchronized (lock) {
            if (task.done) {
                int r = task.result;
                if (activeDrive == task) activeDrive = null;
                return r;
            }
            if (!task.started) {
                queue.remove(task);
                task.cancelled = true;
                if (activeDrive == task) activeDrive = null;
                return DRIVE_TIMEOUT;
            }
            task.timedOut = true;
            return DRIVE_TIMEOUT;
        }
    }

    /** Executes one queued task inline on the caller's thread (for deterministic unit tests with autoStart=false). */
    boolean stepOne() {
        Task task;
        synchronized (lock) {
            task = queue.pollFirst();
        }
        if (task == null) return false;
        runTask(task);
        return true;
    }

    /** Drains all currently queued tasks inline (for deterministic unit tests with autoStart=false). */
    int drainInline() {
        int n = 0;
        while (stepOne()) n++;
        return n;
    }

    private void enqueue(Task task) {
        synchronized (lock) {
            enqueueLocked(task);
        }
    }

    private void scheduleRefreshLocked() {
        if (refreshInFlight) {
            refreshAgain = true;
        } else if (!refreshQueued) {
            refreshQueued = true;
            enqueueLocked(REFRESH_TASK);
        }
    }

    private void enqueueLocked(Task task) {
        queue.addLast(task);
        if (autoStart && !workerStarted) {
            workerStarted = true;
            Thread t = new Thread(this::workerLoop, "mbui-notices");
            t.setDaemon(true);
            t.start();
        }
        lock.notifyAll();
    }

    private boolean awaitTask(Task task, long timeoutMs) {
        long deadline = System.nanoTime() + Math.max(0L, timeoutMs) * 1_000_000L;
        synchronized (lock) {
            while (!task.done) {
                long remNs = deadline - System.nanoTime();
                if (remNs <= 0L) return false;
                long ms = remNs / 1_000_000L;
                int ns = (int) (remNs % 1_000_000L);
                try {
                    lock.wait(ms, ns);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return false;
                }
            }
            return true;
        }
    }

    private void workerLoop() {
        if (onWorkerStart != null) {
            try {
                onWorkerStart.run();
            } catch (RuntimeException ignored) {
            }
        }
        while (true) {
            Task task;
            synchronized (lock) {
                while (queue.isEmpty()) {
                    try {
                        lock.wait();
                    } catch (InterruptedException ignored) {
                    }
                }
                task = queue.pollFirst();
            }
            runTask(task);
        }
    }

    private void runTask(Task task) {
        if (task.kind == Kind.REFRESH) {
            runRefresh();
            return;
        }
        if (task.kind == Kind.DRIVE) {
            synchronized (lock) {
                if (task.cancelled) return;
                task.started = true;
            }
        }
        int driveResult = task.kind == Kind.DRIVE ? DRIVE_ERROR : 0;
        try {
            switch (task.kind) {
                case SHOW:
                    if (task.channel != null && !task.channel.equals(lastChannelName)) {
                        if (ops.ensureChannel(task.ctx, task.channel, false)) {
                            lastChannelName = task.channel;
                        }
                    }
                    ops.show(task.ctx, task.tag, task.title, task.body, task.opens);
                    break;
                case EXTERNAL_SHOW:
                    ops.ensureChannel(task.ctx, task.channel, true);
                    ops.show(task.ctx, task.tag, task.title, task.body, task.opens);
                    break;
                case CANCEL:
                    ops.cancel(task.ctx, task.tag);
                    break;
                case DRIVE:
                    driveResult = ops.drive(task.ctx, task.tap, task.words);
                    break;
                default:
                    break;
            }
        } catch (RuntimeException ignored) {
        } finally {
            if (task.awaitable || task.kind == Kind.DRIVE) {
                synchronized (lock) {
                    if (task.awaitable) {
                        task.result = driveResult;
                        task.done = true;
                    }
                    if (task.kind == Kind.DRIVE && activeDrive == task) {
                        if (task.timedOut && !(task.tap && driveResult == 1)) {
                            activeDrive = null;
                        }
                    }
                    lock.notifyAll();
                }
            }
            if (task.onDone != null) {
                try {
                    task.onDone.run();
                } catch (RuntimeException ignored) {
                }
            }
        }
    }

    private void runRefresh() {
        long gen;
        Object c;
        synchronized (lock) {
            refreshQueued = false;
            refreshInFlight = true;
            refreshAgain = false;
            gen = permGen;
            c = permCtx;
        }
        int got;
        if (c == null) {
            got = PERM_UNKNOWN;
        } else {
            try {
                got = ops.readPermission(c);
            } catch (RuntimeException e) {
                got = PERM_UNKNOWN;
            }
            if (got <= 0) got = PERM_UNKNOWN;
        }
        boolean changed = false;
        synchronized (lock) {
            refreshInFlight = false;
            if (gen == permGen) {
                if (got != PERM_UNKNOWN) {
                    if (got != permState) {
                        permState = got;
                        changed = true;
                    }
                    if (pendingAnswer != -1) {
                        pendingAnswer = (got == PERM_GRANTED ? 1 : 0);
                    }
                } else if (permState == PERM_PENDING) {
                    permState = PERM_UNKNOWN;
                    changed = true;
                }
            }
            if (refreshAgain) {
                refreshAgain = false;
                if (!refreshQueued) {
                    refreshQueued = true;
                    queue.addLast(REFRESH_TASK);
                    lock.notifyAll();
                }
            }
        }
        if (changed) {
            try {
                ops.requestFrame();
            } catch (RuntimeException ignored) {
            }
        }
    }
}
