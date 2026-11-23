// End-to-end client trace from sending a chat message (`chat.send` / `chatSendTo`) to the first live event or
// assistant reply for that session (`chat.send.e2e`). Measures station POST acknowledgement (`stillfail.ack_ms`) and
// total time to first live activity (`stillfail.first_live_ms`) without ever recording message text or user content.
import { Effect, type Fiber } from "effect";
import { laterSleep, type Runner } from "../runtime.ts";
import { Kind, type Span, type Tracer } from "../trace.ts";
import { stationId } from "./addr.ts";

/// Longest time we wait for the first live event after sending a message.
export const SEND_TRACE_TIMEOUT_MS = 30_000;

export type SendTraceOutcome = "live" | "failed" | "superseded" | "timeout";

export interface SendTraceHandle {
  /** Rebinds the trace to a new station after a cross-station chat move (`MOVED`). */
  bindStation(station: string): void;
  /** Binds a session key if it was not known at start time (e.g. pending chat creation). */
  bindSession(session: string): void;
  /** Binds a thread id if it was not known at start time. */
  bindThread(thread: number): void;
  /** Records the station POST acknowledgement duration. */
  acked(session?: string | null): void;
  /** Ends the trace as failed when the station POST fails. */
  failed(): void;
}

type Entry = {
  station: string;
  session: string | null;
  thread: number | null;
  readonly startedMs: number;
  readonly span: Span;
  readonly onEnd?: () => void;
  acked: boolean;
  ended: boolean;
  timer: Fiber.Fiber<void, never> | null;
};

export class SendTrace {
  readonly #tracer: Tracer;
  readonly #runner: Runner;
  readonly #now: () => number;
  readonly #reporting: () => boolean;
  readonly #bySession = new Map<string, Entry>();
  readonly #byThread = new Map<string, Entry>();
  readonly #active = new Set<Entry>();

  constructor(tracer: Tracer, runner: Runner, now: () => number, reporting: () => boolean) {
    this.#tracer = tracer;
    this.#runner = runner;
    this.#now = now;
    this.#reporting = reporting;
  }

  #sessionKey(station: string, session: string): string {
    return `${station}\u0000s:${session}`;
  }

  #threadKey(station: string, thread: number): string {
    return `${station}\u0000t:${thread}`;
  }

  #detach(entry: Entry): void {
    this.#active.delete(entry);
    if (entry.session !== null) {
      const sk = this.#sessionKey(entry.station, entry.session);
      if (this.#bySession.get(sk) === entry) this.#bySession.delete(sk);
    }
    if (entry.thread !== null) {
      const tk = this.#threadKey(entry.station, entry.thread);
      if (this.#byThread.get(tk) === entry) this.#byThread.delete(tk);
    }
    if (entry.timer !== null) {
      const f = entry.timer;
      entry.timer = null;
      this.#runner.interrupt(f);
    }
  }

  #finish(entry: Entry, outcome: SendTraceOutcome, error = false): void {
    if (entry.ended) return;
    entry.ended = true;
    this.#detach(entry);
    if (outcome === "live") {
      entry.span.set("stillfail.first_live_ms", Math.max(0, Math.round(this.#now() - entry.startedMs)));
    }
    entry.span.set("stillfail.outcome", outcome);
    if (error) entry.span.fail();
    entry.span.end();
    entry.onEnd?.();
  }

  /// Starts tracking a new outgoing message; supersedes any in-flight trace for the same session or thread.
  start(station: string, target: { session?: string | null; thread?: number | null; onEnd?: () => void }): SendTraceHandle | null {
    if (!this.#reporting()) return null;
    const session = typeof target.session === "string" && target.session !== "" ? target.session : null;
    const thread = typeof target.thread === "number" ? target.thread : null;

    // Supersede any previous active trace for this same session or thread.
    if (session !== null) {
      const prev = this.#bySession.get(this.#sessionKey(station, session));
      if (prev) this.#finish(prev, "superseded");
    }
    if (thread !== null) {
      const prev = this.#byThread.get(this.#threadKey(station, thread));
      if (prev) this.#finish(prev, "superseded");
    }

    const span = this.#tracer.root("chat.send.e2e", Kind.Internal);
    span.set("stillfail.station", stationId(station));

    const entry: Entry = {
      station,
      session,
      thread,
      startedMs: this.#now(),
      span,
      onEnd: target.onEnd,
      acked: false,
      ended: false,
      timer: null,
    };
    this.#active.add(entry);
    if (session !== null) this.#bySession.set(this.#sessionKey(station, session), entry);
    if (thread !== null) this.#byThread.set(this.#threadKey(station, thread), entry);

    entry.timer = this.#runner.fork(
      laterSleep(SEND_TRACE_TIMEOUT_MS).pipe( // timer: timeout deadline for chat.send.e2e trace
        Effect.andThen(
          Effect.sync(() => {
            entry.timer = null;
            this.#finish(entry, "timeout");
          }),
        ),
      ),
    );

    const self = this;
    return {
      bindStation(nextStation: string) {
        if (entry.ended || !nextStation || entry.station === nextStation) return;
        if (entry.session !== null) {
          const oldSk = self.#sessionKey(entry.station, entry.session);
          if (self.#bySession.get(oldSk) === entry) self.#bySession.delete(oldSk);
        }
        if (entry.thread !== null) {
          const oldTk = self.#threadKey(entry.station, entry.thread);
          if (self.#byThread.get(oldTk) === entry) self.#byThread.delete(oldTk);
        }
        entry.station = nextStation;
        entry.span.set("stillfail.station", stationId(nextStation));
        if (entry.session !== null) {
          const newSk = self.#sessionKey(nextStation, entry.session);
          const prev = self.#bySession.get(newSk);
          if (prev && prev !== entry) self.#finish(prev, "superseded");
          self.#bySession.set(newSk, entry);
        }
        if (entry.thread !== null) {
          const newTk = self.#threadKey(nextStation, entry.thread);
          const prev = self.#byThread.get(newTk);
          if (prev && prev !== entry) self.#finish(prev, "superseded");
          self.#byThread.set(newTk, entry);
        }
      },
      bindSession(s: string) {
        if (entry.ended || !s || entry.session === s) return;
        const prev = self.#bySession.get(self.#sessionKey(entry.station, s));
        if (prev && prev !== entry) self.#finish(prev, "superseded");
        if (entry.session !== null) {
          const oldKey = self.#sessionKey(entry.station, entry.session);
          if (self.#bySession.get(oldKey) === entry) self.#bySession.delete(oldKey);
        }
        entry.session = s;
        self.#bySession.set(self.#sessionKey(entry.station, s), entry);
      },
      bindThread(t: number) {
        if (entry.ended || entry.thread === t) return;
        const prev = self.#byThread.get(self.#threadKey(entry.station, t));
        if (prev && prev !== entry) self.#finish(prev, "superseded");
        if (entry.thread !== null) {
          const oldKey = self.#threadKey(entry.station, entry.thread);
          if (self.#byThread.get(oldKey) === entry) self.#byThread.delete(oldKey);
        }
        entry.thread = t;
        self.#byThread.set(self.#threadKey(entry.station, t), entry);
      },
      acked(s?: string | null) {
        if (entry.ended || entry.acked) return;
        entry.acked = true;
        if (typeof s === "string" && s !== "") this.bindSession(s);
        entry.span.set("stillfail.ack_ms", Math.max(0, Math.round(self.#now() - entry.startedMs)));
      },
      failed() {
        self.#finish(entry, "failed", true);
      },
    };
  }

  /// Called when a live event arrives for `(station, session)`.
  onLive(station: string, session: string): void {
    const entry = this.#bySession.get(this.#sessionKey(station, session));
    if (entry) this.#finish(entry, "live");
  }

  /// Called when an assistant reply entry arrives on `(station, thread)`.
  onThreadReply(station: string, thread: number): void {
    const entry = this.#byThread.get(this.#threadKey(station, thread));
    if (entry) this.#finish(entry, "live");
  }

  /// Cancels all pending timers and releases active traces on core shutdown.
  close(): void {
    for (const entry of [...this.#active]) {
      if (entry.ended) continue;
      entry.ended = true;
      this.#detach(entry);
      entry.onEnd?.();
    }
  }
}
