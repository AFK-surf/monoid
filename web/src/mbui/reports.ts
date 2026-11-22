// Web host side of apps/mbui/src/stillfail/reports.mbt (`globalThis.__mbreports`): sends `ui_hang`,
// `ui_hang_summary`, `bar_switch`, and handled exceptions (`CoreFailed`, `UiFault`) to still.fail's
// PostHog project via `/batch/`.
//
// Strictly gated to builds given a PostHog key (`__STILLFAIL_POSTHOG__`) running on still.fail's own
// origins (`OWN_ORIGINS`): development, tests, and self-hosted origins answer `hello` 0 and send nothing.
// The settings toggle 「发送使用统计和错误报告」 is persisted in `localStorage` (`stillfail:reporting`)
// and drives both this reporter and the core's `UseCounts` via `reporting_host` (`counts_told`).

/// still.fail's own clouds: events from any other origin are never sent.
export const OWN_ORIGINS = ["https://app.still.fail", "https://app.youdid.wtf"];

export type ReportSink = { host: string; key: string };

declare const __STILLFAIL_POSTHOG__: { host?: unknown; key?: unknown } | undefined;

/// The PostHog project injected into this build by `web/vite.config.ts`, if any.
export function builtSink(): ReportSink | null {
  const said = typeof __STILLFAIL_POSTHOG__ === "undefined" ? undefined : __STILLFAIL_POSTHOG__;
  if (!said || typeof said.host !== "string" || typeof said.key !== "string" || said.key === "") return null;
  return { host: said.host.replace(/\/+$/, ""), key: said.key };
}

/// Lightweight OS normalization from `navigator.userAgent` (aligned with native `$os` values).
export function detectOs(ua: string): string {
  if (/iPhone|iPad|iPod/i.test(ua)) return "iOS";
  if (/Android/i.test(ua)) return "Android";
  if (/Mac OS X|Macintosh/i.test(ua)) return "macOS";
  if (/Windows/i.test(ua)) return "Windows";
  if (/Linux/i.test(ua)) return "Linux";
  return "Unknown";
}

const REPORTING_KEY = "stillfail:reporting";
const ACCOUNT_KEY = "stillfail:reports_account";
const ANONYMOUS_ID = "web-anonymous";
export const BAR_BATCH_SIZE = 10;
export const BAR_BATCH_MS = 30_000;

export type ReportsStorage = Pick<Storage, "getItem" | "setItem">;

export interface WebReportsOptions {
  sink: ReportSink | null;
  origin: string;
  release: string;
  os: string;
  storage?: ReportsStorage | null;
  now?: () => number;
  uuid?: () => string;
  send?: (url: string, body: string, keepalive: boolean) => void;
  schedule?: (fn: () => void, ms: number) => unknown;
  cancel?: (handle: unknown) => void;
}

type PostHogEvent = {
  event: string;
  distinct_id: string;
  uuid: string;
  timestamp: string;
  properties: Record<string, unknown>;
};

function makeUuid(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  const bytes = new Uint8Array(16);
  if (typeof crypto !== "undefined" && typeof crypto.getRandomValues === "function") {
    crypto.getRandomValues(bytes);
  } else {
    for (let i = 0; i < 16; i++) bytes[i] = Math.floor(Math.random() * 256);
  }
  bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x40;
  bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80;
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function defaultSend(url: string, body: string, keepalive: boolean): void {
  if (keepalive && typeof navigator !== "undefined" && typeof navigator.sendBeacon === "function") {
    try {
      if (navigator.sendBeacon(url, new Blob([body], { type: "text/plain" }))) return;
    } catch {
      // fall through to fetch
    }
  }
  if (typeof fetch !== "function") return;
  void fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body,
    keepalive,
  }).catch(() => undefined);
}

function safeGet(storage: ReportsStorage | null, key: string): string | null {
  if (!storage) return null;
  try {
    return storage.getItem(key);
  } catch {
    return null;
  }
}

function safeSet(storage: ReportsStorage | null, key: string, value: string): void {
  if (!storage) return;
  try {
    storage.setItem(key, value);
  } catch {
    // private browsing / quota exceeded
  }
}

function parseJsonObject(raw: string): Record<string, unknown> | null {
  try {
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return null;
    return parsed as Record<string, unknown>;
  } catch {
    return null;
  }
}

export class WebReports {
  readonly #sink: ReportSink | null;
  readonly #origin: string;
  readonly #release: string;
  readonly #os: string;
  readonly #storage: ReportsStorage | null;
  readonly #now: () => number;
  readonly #uuid: () => string;
  readonly #send: (url: string, body: string, keepalive: boolean) => void;
  readonly #schedule: (fn: () => void, ms: number) => unknown;
  readonly #cancel: (handle: unknown) => void;

  #reporting: boolean;
  #account: string | null;
  #queued: PostHogEvent[] = [];
  #timer: unknown = null;

  constructor(options: WebReportsOptions) {
    this.#sink = options.sink;
    this.#origin = options.origin.replace(/\/+$/, "");
    this.#release = options.release;
    this.#os = options.os;
    this.#storage = options.storage ?? null;
    this.#now = options.now ?? (() => Date.now());
    this.#uuid = options.uuid ?? makeUuid;
    this.#send = options.send ?? defaultSend;
    this.#schedule = options.schedule ?? ((fn, ms) => setTimeout(fn, ms));
    this.#cancel = options.cancel ?? ((h) => clearTimeout(h as ReturnType<typeof setTimeout>));
    this.#reporting = safeGet(this.#storage, REPORTING_KEY) !== "0";
    const kept = safeGet(this.#storage, ACCOUNT_KEY);
    this.#account = kept && kept.length > 0 ? kept : null;
  }

  get enabled(): boolean {
    return this.#sink !== null && OWN_ORIGINS.includes(this.#origin);
  }

  get queuedCount(): number {
    return this.#queued.length;
  }

  tell(what: string, a: string, _b: string, n: number, _m: number): number {
    if (what === "hello" || what === "bar_switch_ready") {
      return this.enabled ? 1 : 0;
    }
    if (what === "reporting") {
      if (!this.enabled) return -1;
      return this.#reporting ? 1 : 0;
    }
    if (what === "set_reporting") {
      if (!this.enabled) return 0;
      this.#reporting = n !== 0;
      safeSet(this.#storage, REPORTING_KEY, this.#reporting ? "1" : "0");
      if (!this.#reporting) this.#dropQueue();
      return 0;
    }
    if (what === "signed_in") {
      if (!this.enabled || a === "") return 0;
      this.#account = a;
      safeSet(this.#storage, ACCOUNT_KEY, a);
      return 0;
    }
    if (what === "core_failed") {
      this.#sendException("CoreFailed", a, "core_failed");
      return 0;
    }
    if (what === "ui_fault") {
      this.#sendException("UiFault", a, "ui_fault");
      return 0;
    }
    if (what === "hang") {
      this.#sendJsonEvent("ui_hang", a, false);
      return 0;
    }
    if (what === "hang_summary") {
      this.#sendJsonEvent("ui_hang_summary", a, true);
      this.flush(true);
      return 0;
    }
    if (what === "bar_switch") {
      this.#enqueueBarSwitch(a);
      return 0;
    }
    return 0;
  }

  flush(keepalive = false): void {
    this.#clearTimer();
    if (!this.enabled || !this.#reporting || this.#queued.length === 0) {
      this.#queued = [];
      return;
    }
    const batch = this.#queued;
    this.#queued = [];
    this.#post(batch, keepalive);
  }

  #distinctId(): string {
    return this.#account ?? ANONYMOUS_ID;
  }

  #baseProperties(): Record<string, unknown> {
    return {
      app: "web",
      release: this.#release,
      $lib: "stillfail-web",
      $os: this.#os,
    };
  }

  #sendException(type: string, value: string, reason: string): void {
    if (!this.enabled || !this.#reporting) return;
    const event: PostHogEvent = {
      event: "$exception",
      distinct_id: this.#distinctId(),
      uuid: this.#uuid(),
      timestamp: new Date(this.#now()).toISOString(),
      properties: {
        ...this.#baseProperties(),
        reason,
        $exception_level: "error",
        $exception_list: [
          {
            type,
            value: value.length > 1000 ? value.slice(0, 1000) : value,
            mechanism: { handled: true, synthetic: false, type: "generic" },
          },
        ],
      },
    };
    this.#post([event], false);
  }

  #sendJsonEvent(name: string, rawJson: string, keepalive: boolean): void {
    if (!this.enabled || !this.#reporting) return;
    const payload = parseJsonObject(rawJson);
    if (!payload) return;
    const event: PostHogEvent = {
      event: name,
      distinct_id: this.#distinctId(),
      uuid: this.#uuid(),
      timestamp: new Date(this.#now()).toISOString(),
      properties: {
        ...this.#baseProperties(),
        ...payload,
      },
    };
    this.#post([event], keepalive);
  }

  #enqueueBarSwitch(rawJson: string): void {
    if (!this.enabled || !this.#reporting) return;
    const payload = parseJsonObject(rawJson);
    if (!payload) return;
    this.#queued.push({
      event: "bar_switch",
      distinct_id: this.#distinctId(),
      uuid: this.#uuid(),
      timestamp: new Date(this.#now()).toISOString(),
      properties: {
        ...this.#baseProperties(),
        ...payload,
      },
    });
    if (this.#queued.length >= BAR_BATCH_SIZE) {
      this.flush(false);
    } else if (this.#timer === null) {
      this.#timer = this.#schedule(() => {
        this.#timer = null;
        this.flush(false);
      }, BAR_BATCH_MS); // timer: a debounce of a burst
    }
  }

  #dropQueue(): void {
    this.#clearTimer();
    this.#queued = [];
  }

  #clearTimer(): void {
    if (this.#timer !== null) {
      this.#cancel(this.#timer);
      this.#timer = null;
    }
  }

  #post(batch: PostHogEvent[], keepalive: boolean): void {
    const sink = this.#sink;
    if (!sink || batch.length === 0) return;
    const body = JSON.stringify({ api_key: sink.key, batch });
    this.#send(`${sink.host}/batch/`, body, keepalive);
  }
}

/// Mounts `globalThis.__mbreports` for the mbui web app and flushes queued reports on tab hide/unload.
export function installWebReports(release: string): WebReports {
  let storage: ReportsStorage | null = null;
  try {
    storage = typeof localStorage === "undefined" ? null : localStorage;
  } catch {
    storage = null;
  }
  const reports = new WebReports({
    sink: builtSink(),
    origin: typeof location === "undefined" ? "" : location.origin,
    release,
    os: detectOs(typeof navigator === "undefined" ? "" : navigator.userAgent),
    storage,
  });
  (globalThis as { __mbreports?: { tell: WebReports["tell"] } }).__mbreports = {
    tell: (what, a, b, n, m) => reports.tell(what, a, b, n, m),
  };
  if (typeof addEventListener === "function") {
    addEventListener("pagehide", () => reports.flush(true));
  }
  if (typeof document !== "undefined" && typeof document.addEventListener === "function") {
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "hidden") reports.flush(true);
    });
  }
  return reports;
}
