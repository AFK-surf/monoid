// The station's log, sent to still.fail: what is wrong between stations, or between a station and
// still.fail cloud, is found from our side without asking anyone for their log file. On unless the station's config
// turns it off (`telemetry.logs: false`), read for every batch so turning it off stops it at once. Each line goes
// scrubbed: no home directories, emails, things shaped like keys or tokens, or quoted text, and fields that can carry
// what people wrote (a notice's text, a job's or skill's name) not at all. Batched every few seconds as OpenTelemetry
// logs to the control plane (still.fail cloud's `/v1/telemetry/logs`, signed with the station's key; the cloud passes
// them on to Google Cloud). A batch that cannot get there waits for the next round: what goes wrong between a station and
// still.fail cloud is said most while the way there is broken (2026-11-03: a station's 43 minutes without a presence
// socket left no line of why). One the cloud refuses is dropped, and lines past what is kept waiting are counted, not
// kept.
import { Effect } from "effect";
import { wall } from "./fibers.ts";
import type { Level, Line } from "./log.ts";
import { scrubMessage } from "./telemetry.ts";

const EVERY_MS = 5_000;
/// Lines kept waiting at most (the oldest go first), and sent in one batch at most.
const MAX_WAITING = 5_000;
const MAX_BATCH = 500;
/// A value is cut past this.
const MAX_VALUE = 2_000;
/// How often a batch that could not be sent is said on stderr.
const SAY_FAILED_MS = 10 * 60_000;

/// Fields whose values are what people or agents wrote, never sent.
const WRITTEN = new Set(["text", "name", "title", "command", "args", "prompt", "body", "question", "content"]);
const SEVERITY: Record<Level, number> = { INFO: 9, WARN: 13, ERROR: 17 };
/// A workspace's id (its name is people's).
const WORKSPACE_ID = /^[0-9A-HJKMNP-TV-Z]{26}$/;

const EMAIL = /[^\s@"'`<>()=,;:]+@[^\s@"'`<>()=,;:]+\.[A-Za-z]{2,}/g;
/// A profile's id made of an email (alice-example-com).
const EMAIL_SLUG = /\b[\w.+]+-(?:[a-z0-9]+-)*(?:com|net|org|me|io|cn|dev|ai|co|app)\b/gi;
/// JWTs, API keys and tokens by their usual prefixes, AWS access keys.
const SECRET = /\beyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]*|\b(?:sk|pk|rk|ghp|gho|ghs|ghu|github_pat|xox[abpr]|glpat)[-_][\w-]{16,}|\bAKIA[0-9A-Z]{16}\b/g;

/// A piece of the log as it may leave the machine.
export function scrubText(text: string, home: string): string {
  const cut = text.length > MAX_VALUE ? `${text.slice(0, MAX_VALUE)}…` : text;
  return scrubMessage(cut.replace(SECRET, "<secret>").replace(EMAIL, "<email>").replace(EMAIL_SLUG, "<email>"), home);
}

function scrubValue(key: string, value: unknown, home: string): unknown {
  if (WRITTEN.has(key)) return "…";
  if (key === "workspace" && typeof value === "string" && !WORKSPACE_ID.test(value)) return "…";
  if (typeof value === "string") return scrubText(value, home);
  if (Array.isArray(value)) return value.map((v) => scrubValue("", v, home));
  if (value !== null && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, scrubValue(k, v, home)]));
  return value;
}

const attribute = (key: string, value: unknown) => ({
  key,
  value: typeof value === "number" && Number.isSafeInteger(value) ? { intValue: String(value) }
    : typeof value === "number" ? { doubleValue: value }
    : typeof value === "boolean" ? { boolValue: value }
    : { stringValue: typeof value === "string" ? value : JSON.stringify(value) ?? String(value) },
});

/// A trace's id as OpenTelemetry has it: 32 lowercase hex digits, not all zero.
const TRACE_ID = /^(?!0{32}$)[0-9a-f]{32}$/;

/// A line as an OpenTelemetry log record, scrubbed. A line of a trace (`trace`) carries its id as the record's own
/// `traceId` too, so its span's lines are found by it (`log.trace` stays).
export function record(line: Line, home: string) {
  const fields = Object.entries(line.fields).filter(([, v]) => v !== undefined);
  const trace = line.fields.trace;
  return {
    timeUnixNano: (BigInt(Math.round(line.ms)) * 1_000_000n).toString(),
    severityNumber: SEVERITY[line.level],
    severityText: line.level,
    body: { stringValue: scrubText(line.message, home) },
    attributes: [attribute("log.target", line.at), ...fields.map(([k, v]) => attribute(`log.${k}`, scrubValue(k, v, home)))],
    ...(typeof trace === "string" && TRACE_ID.test(trace) ? { traceId: trace } : {}),
  };
}

/// Whether a batch was refused by the control plane (an answer other than too many, or its own trouble): sending it
/// again would be refused again. Anything else (no answer, the network) is worth another try.
function refused(error: unknown): boolean {
  const status = (error as { status?: unknown })?.status;
  return typeof status === "number" && status >= 400 && status < 500 && status !== 429;
}

export type LogExportOptions = {
  /// Read for every batch.
  enabled: () => boolean;
  /// The station's id from its enrollment; null before it is enrolled (nothing is sent then).
  station: () => string | null;
  version: () => string;
  home?: string;
  /// What each batch says the station runs on and is (main.ts gives them, each left out where not given): the system
  /// as Node names it, the CPU's architecture, the engine (nodejs, moonbit) and the station's role (station, or rig:
  /// one that only runs tasks).
  os?: string;
  arch?: string;
  runtime?: string;
  role?: string;
};

export class LogExport {
  private options: LogExportOptions | null = null;
  private home = process.env.HOME ?? "";
  private waiting: Line[] = [];
  private dropped = 0;
  private send: ((body: string) => Promise<unknown>) | null = null;
  private sending: Promise<void> | null = null;
  private stop: (() => void) | null = null;
  private saidFailed = 0;
  private closed = false;

  configure(options: LogExportOptions) {
    this.options = options;
    this.home = options.home ?? this.home;
    this.stop ??= wall.every(EVERY_MS, () => void this.flush());
  }

  /// How a batch goes (the control plane's, once the station has one).
  sendWith(send: (body: string) => Promise<unknown>) {
    this.send = send;
  }

  add(line: Line) {
    if (this.closed || this.options === null || !this.options.enabled()) return;
    this.waiting.push(line);
    this.trim();
  }

  /// Past what is kept waiting, the oldest INFO lines go first (a warning or an error says what went wrong), the oldest
  /// of the rest only once none is left.
  private trim() {
    let over = this.waiting.length - MAX_WAITING;
    if (over <= 0) return;
    this.dropped += over;
    const kept: Line[] = [];
    for (const line of this.waiting) {
      if (over > 0 && line.level === "INFO") over--;
      else kept.push(line);
    }
    this.waiting = over > 0 ? kept.slice(over) : kept;
  }

  /// The batch of `lines` as it is sent.
  body(lines: Line[], station: string, dropped = 0): string {
    const records = lines.map((l) => record(l, this.home));
    if (dropped > 0) records.push(record({ ms: wall.now(), level: "WARN", at: "telemetry", message: "log lines dropped before they could be sent", fields: { dropped } }, this.home));
    const o = this.options;
    const described = [["os.type", o?.os], ["host.arch", o?.arch], ["process.runtime.name", o?.runtime], ["stillfail.role", o?.role]] as const;
    const resource = [
      attribute("service.name", "stillfail-station"), attribute("service.version", o?.version() ?? ""), attribute("stillfail.station", station),
      ...described.flatMap(([k, v]) => (v === undefined ? [] : [attribute(k, v)])),
    ];
    return JSON.stringify({ resourceLogs: [{ resource: { attributes: resource }, scopeLogs: [{ scope: { name: "stillfail-station" }, logRecords: records }] }] });
  }

  /// Sends what waits, a batch at a time.
  flush(): Promise<void> {
    this.sending ??= this.sendAll().finally(() => (this.sending = null));
    return this.sending;
  }

  private async sendAll() {
    while (this.waiting.length > 0) {
      const options = this.options;
      const send = this.send;
      const station = options?.station() ?? null;
      if (options === null || !options.enabled()) {
        this.waiting = [];
        this.dropped = 0;
        return;
      }
      if (send === null || station === null) return;
      const lines = this.waiting.splice(0, MAX_BATCH);
      const dropped = this.dropped;
      this.dropped = 0;
      try {
        await send(this.body(lines, station, dropped));
      } catch (error) {
        // Not there: sent again next round, first, as far as what is kept waiting goes (the oldest go).
        if (!refused(error)) {
          this.waiting.unshift(...lines);
          this.dropped += dropped;
          this.trim();
        }
        // Not through the log: that would send itself.
        if (wall.now() - this.saidFailed > SAY_FAILED_MS) {
          this.saidFailed = wall.now();
          process.stderr.write(`${new Date(wall.now()).toISOString()}  WARN telemetry: the station's log not sent error=${(error as Error).message}\n`);
        }
        return;
      }
    }
  }

  /// Sends what waits (at most 5 s), then nothing more.
  async shutdown() {
    this.stop?.();
    this.closed = true;
    const sent = this.flush();
    await Effect.runPromise(Effect.timeoutOption(Effect.promise(() => sent), "5 seconds"));
  }
}

/// The station's: configured as it starts (main.ts), sent through its control plane once the mesh is up (mesh.ts).
export const stationLog = new LogExport();
