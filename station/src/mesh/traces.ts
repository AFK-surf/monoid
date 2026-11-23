// The station's traces: the mesh's own spans (a request stream from accepted to fully
// answered; an event stream's to its head), under the caller's trace when it records one. Batched, sent at most every
// 3 s to the control plane (still.fail cloud's `/v1/telemetry/traces`, signed with the station's key; the cloud forwards
// them to Google Cloud; ControlPlane.traces). A batch that cannot be sent is tried once more at the next flush (unless
// the plane refused it with a 4xx), then dropped, said at most every 10 min. The config (telemetry.traces, read at
// start) turns them off (`false`) or keeps every span (`true`); unset, only a failed or slow span is kept (`tailOnly`).
import { randomBytes } from "node:crypto";
import { Clock, Effect, Exit, FiberSet, Scope } from "effect";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";

const EXPORT_MS = 3_000;
const MAX_BUFFER = 2_000;
const MAX_BATCH = 500;
/// The least time between two `traces dropped` lines (monotonic ns).
const DROP_WARN_NS = 600_000_000_000n;

/// A W3C trace context: the trace, the caller's span, whether it is recorded.
export type Parent = { trace: string; span: string; sampled: boolean };

/// `00-<trace>-<span>-<flags>`; anything else is no context.
export function parseParent(header: string | undefined): Parent | null {
  const parts = (header ?? "").trim().split("-");
  if (parts.length !== 4) return null;
  const [version, trace, span, flags] = parts as [string, string, string, string];
  if (version.length !== 2 || version === "ff" || flags.length !== 2 || !/^[0-9a-f]{2}$/i.test(flags)) return null;
  if (!/^[0-9a-f]{32}$/i.test(trace) || !/^[0-9a-f]{16}$/i.test(span) || /^0+$/.test(trace) || /^0+$/.test(span)) return null;
  return { trace: trace.toLowerCase(), span: span.toLowerCase(), sampled: (parseInt(flags, 16) & 1) === 1 };
}

export type Span = { parent: Parent; id: string; wallNs: bigint; started: bigint };

const IDS = ["sessions", "threads", "connects", "profiles", "logins", "workspaces", "stations", "members", "enrollments", "accounts"];

/// A path without its ids: a segment after a collection, or one that is no plain word, is `:id`.
export function route(path: string): string {
  let afterCollection = false;
  return path
    .split(/[?#]/)[0]!
    .split("/")
    .map((segment) => {
      const word = segment !== "" && segment.length <= 24 && /^[a-z0-9._-]+$/.test(segment) && /[a-z]/.test(segment);
      const id = segment !== "" && (afterCollection || !word);
      afterCollection = !id && IDS.includes(segment);
      return id ? ":id" : segment;
    })
    .join("/");
}

function attribute(key: string, value: unknown) {
  const v =
    typeof value === "boolean" ? { boolValue: value }
    : typeof value === "number" && Number.isInteger(value) ? { intValue: String(value) }
    : typeof value === "number" ? { doubleValue: value }
    : typeof value === "string" ? { stringValue: value }
    : { stringValue: JSON.stringify(value) };
  return { key, value: v };
}

export class Traces {
  readonly enabled: boolean;
  readonly spans: unknown[] = [];
  /// A flush is due (its wait is running).
  private armed = false;
  /// Only failed or slow spans are kept (`slowMs` or longer).
  readonly tailOnly: boolean;
  readonly slowMs: number;
  /// The batch at the head was put back after a failure: a second failure drops it.
  private retrying = false;
  /// When `traces dropped` was said last (monotonic ns).
  private droppedAt: bigint | null = null;
  private closed = false;
  /// Where batches go (set once the station is in still.fail cloud).
  private sink: ((spans: unknown[]) => Promise<void>) | null = null;
  /// Runs an effect as a fiber of these traces' (the wait before a flush): they end at `close`.
  private run: (effect: Effect.Effect<void>) => Promise<void>;
  private scope: Scope.Closeable;

  /// `clock`: the clock the batching wait runs on (a TestClock in tests); `tailOnly`: keep only a failed span or one
  /// that took `slowMs` (1 s) or longer.
  constructor(enabled: boolean, options: { clock?: Clock.Clock; tailOnly?: boolean; slowMs?: number } = {}) {
    this.enabled = enabled;
    this.tailOnly = options.tailOnly ?? false;
    this.slowMs = options.slowMs ?? 1_000;
    this.scope = Effect.runSync(Scope.make());
    const runtime = Scope.provide(FiberSet.makeRuntimePromise<never, void, never>(), this.scope);
    this.run = Effect.runSync(options.clock ? runtime.pipe(Effect.provideService(Clock.Clock, options.clock)) : runtime);
  }

  /// Stops batching: a flush still waiting is not made (its spans are dropped, as a batch that cannot be sent is).
  async close() {
    this.closed = true;
    await Effect.runPromise(Scope.close(this.scope, Exit.void));
  }

  /// A span under `parent`, when traces are on and the caller records this trace.
  start(parent: Parent | null): Span | null {
    if (!this.enabled || parent === null || !parent.sampled) return null;
    return { parent, id: randomBytes(8).toString("hex"), wallNs: BigInt(wall.now()) * 1_000_000n, started: process.hrtime.bigint() };
  }

  /// A root internal span when traces are on: `parent.span` is empty so OTLP omits `parentSpanId`.
  startRoot(): Span | null {
    if (!this.enabled) return null;
    return {
      parent: { trace: randomBytes(16).toString("hex"), span: "", sampled: true },
      id: randomBytes(8).toString("hex"),
      wallNs: BigInt(wall.now()) * 1_000_000n,
      started: process.hrtime.bigint(),
    };
  }

  /// The `traceparent` for what this span asks of others.
  static traceparent(span: Span): string {
    return `00-${span.parent.trace}-${span.id}-01`;
  }

  /// Ends `span` as an OTLP server span with these attributes (where `tailOnly`, a quick one that did not fail is not kept).
  end(span: Span, name: string, attributes: [string, unknown][], failed: boolean) {
    const end = span.wallNs + (process.hrtime.bigint() - span.started);
    if (this.tailOnly && !failed && end - span.wallNs < BigInt(this.slowMs) * 1_000_000n) return;
    this.record({
      traceId: span.parent.trace,
      spanId: span.id,
      parentSpanId: span.parent.span,
      name,
      kind: 2,
      startTimeUnixNano: String(span.wallNs),
      endTimeUnixNano: String(end),
      attributes: attributes.map(([k, v]) => attribute(k, v)),
      status: { code: failed ? 2 : 1 },
    });
  }

  /// Records an OTLP internal span (`kind: 1`) with explicit wall-clock start/end timestamps (ns).
  /// Omits `parentSpanId` when absent or empty so Cloud Trace classifies it as a root span.
  recordInternal(
    startWallNs: bigint,
    endWallNs: bigint,
    name: string,
    attributes: [string, unknown][],
    failed: boolean,
    opts?: { alwaysKeep?: boolean; slowMs?: number; traceId?: string; spanId?: string; parentSpanId?: string },
  ) {
    if (!this.enabled) return;
    const alwaysKeep = opts?.alwaysKeep ?? false;
    const thresholdMs = opts?.slowMs !== undefined && opts.slowMs >= 0 ? opts.slowMs : this.slowMs;
    if (this.tailOnly && !alwaysKeep && !failed && endWallNs - startWallNs < BigInt(thresholdMs) * 1_000_000n) return;
    const span: Record<string, unknown> = {
      traceId: opts?.traceId ?? randomBytes(16).toString("hex"),
      spanId: opts?.spanId ?? randomBytes(8).toString("hex"),
      ...(opts?.parentSpanId ? { parentSpanId: opts.parentSpanId } : {}),
      name,
      kind: 1,
      startTimeUnixNano: String(startWallNs),
      endTimeUnixNano: String(endWallNs),
      attributes: attributes.map(([k, v]) => attribute(k, v)),
      status: { code: failed ? 2 : 1 },
    };
    this.record(span);
  }

  /// Ends `span` as an OTLP internal span (`kind: 1`), omitting `parentSpanId` for root spans.
  endInternal(span: Span, name: string, attributes: [string, unknown][], failed: boolean, opts?: { alwaysKeep?: boolean; slowMs?: number }) {
    const end = span.wallNs + (process.hrtime.bigint() - span.started);
    this.recordInternal(span.wallNs, end, name, attributes, failed, {
      ...opts,
      traceId: span.parent.trace,
      spanId: span.id,
      parentSpanId: span.parent.span,
    });
  }

  private record(span: unknown) {
    if (!this.enabled) return;
    if (this.spans.length < MAX_BUFFER) this.spans.push(span);
    this.arm();
  }

  /// The next flush, EXPORT_MS from now, unless one is due already.
  private arm() {
    if (this.armed || this.closed) return;
    this.armed = true;
    void this.run(Effect.sleep(EXPORT_MS).pipe(Effect.andThen(Effect.promise(() => this.flush())))).catch(() => {});
  }

  private async flush() {
    this.armed = false;
    while (this.spans.length > 0) {
      const batch = this.spans.splice(0, MAX_BATCH);
      if (this.sink === null) continue;
      try {
        await this.sink(batch);
        this.retrying = false;
      } catch (error) {
        const message = (error as Error).message;
        // (a 4xx is the plane's refusal: sending it again is refused again)
        if (!this.retrying && !message.includes("answered 4")) {
          const kept = batch.concat(this.spans).slice(0, MAX_BUFFER);
          this.spans.length = 0;
          this.spans.push(...kept);
          this.retrying = true;
          break;
        }
        this.retrying = false;
        const now = process.hrtime.bigint();
        if (this.droppedAt === null || now - this.droppedAt >= DROP_WARN_NS) {
          this.droppedAt = now;
          log.warn("telemetry", "traces dropped", { error: message, count: batch.length });
        }
        break;
      }
    }
    if (this.spans.length > 0) this.arm();
  }

  /// Sends batches to `sink` (the control plane's).
  exportTo(sink: (spans: unknown[]) => Promise<void>) {
    this.sink = sink;
  }
}

/// A batch of the mesh's spans as OTLP JSON, of `station`; `resource`: what else describes it (`service.version`, …), an
/// empty key or value left out.
export function otlpBody(station: string, spans: unknown[], resource: [string, string][] = []): string {
  const described = resource.filter(([k, v]) => k !== "" && v !== "").map(([k, v]) => attribute(k, v));
  return JSON.stringify({
    resourceSpans: [
      {
        resource: { attributes: [attribute("service.name", "stillfail-mesh"), attribute("stillfail.station", station), ...described] },
        scopeSpans: [{ scope: { name: "stillfail-mesh" }, spans }],
      },
    ],
  });
}

/// Records an internal span payload emitted by the MoonBit `--sessions` program (`told("trace", [payload])`).
export function recordTracePayload(traces: Traces | null | undefined, payload: unknown): void {
  if (!traces || !traces.enabled || payload === null || typeof payload !== "object") return;
  const p = payload as Record<string, unknown>;
  const name = typeof p.name === "string" ? p.name : "";
  if (name === "") return;
  const startMs = typeof p.startMs === "number" && Number.isFinite(p.startMs) ? Math.trunc(p.startMs) : wall.now();
  const rawEndMs = typeof p.endMs === "number" && Number.isFinite(p.endMs) ? Math.trunc(p.endMs) : startMs;
  const endMs = rawEndMs < startMs ? startMs : rawEndMs;
  const attrs: [string, unknown][] = [];
  if (p.attributes !== null && typeof p.attributes === "object" && !Array.isArray(p.attributes)) {
    for (const [k, v] of Object.entries(p.attributes as Record<string, unknown>)) {
      if (v !== null && v !== undefined) attrs.push([k, v]);
    }
  }
  const failed = p.failed === true;
  const alwaysKeep = p.alwaysKeep === true;
  const slowMs = typeof p.slowMs === "number" && Number.isFinite(p.slowMs) ? Math.trunc(p.slowMs) : -1;
  traces.recordInternal(BigInt(startMs) * 1_000_000n, BigInt(endMs) * 1_000_000n, name, attrs, failed, { alwaysKeep, slowMs });
}
