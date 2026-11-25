// The station's one program for its sessions (`--sessions`, MoonBit `stillfail-reader` by default or
// Pion `stillfail-pion` via `STILLFAIL_READER_SESSIONS` > `config.readers.sessions` > `STILLFAIL_READER_ENGINE`):
// the agents' output read (`mb-agents.ts` `AgentsHost`) and the sessions' actors (`sessions/mb-actor.ts`
// `ActorsProgram`) in one process, so what the one says the other can take in itself.
// Each part uses it (`use`) and lets it go (`release`); it ends once none uses it.
// What it says goes to the part it is of: the actors' lines say where the program stands (`active`), the
// agents' never.
import { resolve, sep } from "node:path";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import {
  MbProcess,
  type ResolvedReaderSelection,
  engineOfSelection,
  fallbackModeOf,
  mbReaderBinary,
  pionBinary,
  resolveReaderSelectionAsync,
  resolveReaderSelectionOrPending,
} from "../read/mb-reader.ts";
import {
  type ReaderSelectConfig,
  resolveReaderEngine,
} from "../read/reader-select.ts";
import { type TelemetryEngine, readerTelemetry } from "../read/reader-telemetry.ts";

type Json = any;

export type ProgramUser = {
  /// What the program said of this part.
  said(said: Json): void;
  /// The program ended (`code`), not asked to.
  exited(code: number): void;
  /// Of the actors (their lines), or of the agents.
  actors: boolean;
};

export type SessionsProgramOptions = {
  readonly config?: ReaderSelectConfig | (() => ReaderSelectConfig);
  readonly env?: Readonly<Record<string, string | undefined>>;
  readonly binary?: string | null;
  readonly pionImplemented?: boolean;
};

export type SessionsSpawnEvent = {
  readonly binary: string;
  readonly argv: readonly string[];
  readonly pid: number | null;
  readonly engine: TelemetryEngine;
  readonly ready: boolean;
  readonly fallback: boolean;
};

type SessionsSpawnObserver = (event: SessionsSpawnEvent) => void;

const dataReaderConfigs = new Map<string, () => ReaderSelectConfig>();
let spawnObserverForTest: SessionsSpawnObserver | null = null;

/// Register the live `ReaderSelectConfig` getter for `data` so synchronous `--sessions` entrypoints
/// (`SessionsProgram.of`, `ActorsProgram.open`, `AgentsHost.where`) share `ReaderConfig.layer`.
export function registerSessionsReaderConfig(data: string, get: () => ReaderSelectConfig): () => void {
  const key = resolve(data);
  dataReaderConfigs.set(key, get);
  return () => {
    if (dataReaderConfigs.get(key) === get) dataReaderConfigs.delete(key);
  };
}

export function sessionsReaderConfigFor(data: string): (() => ReaderSelectConfig) | undefined {
  return dataReaderConfigs.get(resolve(data));
}

/// Test-only spawn/ready observer for verifying exact `(binary, argv, pid, engine, ready, fallback)`.
export function setSessionsSpawnObserverForTest(observer: SessionsSpawnObserver | null): void {
  spawnObserverForTest = observer;
}

function readConfigOption(
  data: string | undefined,
  options?: SessionsProgramOptions,
): ReaderSelectConfig | (() => ReaderSelectConfig) | undefined {
  if (options?.config !== undefined) return options.config;
  if (data !== undefined) return sessionsReaderConfigFor(data);
  return undefined;
}

function materializeConfig(
  cfg: ReaderSelectConfig | (() => ReaderSelectConfig) | undefined,
): ReaderSelectConfig {
  return typeof cfg === "function" ? cfg() : cfg;
}

function isPionSessionsRequired(env?: Readonly<Record<string, string | undefined>>): boolean {
  return (env ?? process.env).STILLFAIL_REQUIRE_PION_SESSIONS === "1";
}

function assertRequiredPionSelection(resolved: ResolvedReaderSelection, env?: Readonly<Record<string, string | undefined>>): void {
  if (!isPionSessionsRequired(env)) return;
  if (resolved.engine !== "pion" || resolved.selection.fallback) {
    const reason = resolved.selection.reason ?? `resolved=${resolved.engine}`;
    throw new Error(
      `STILLFAIL_REQUIRE_PION_SESSIONS=1 requires Pion for --sessions, but selection resolved to "${resolved.engine}" (${reason})`,
    );
  }
}

/// Unified availability check replacing hard-coded `mbReaderBinary() === null`:
/// true if `stillfail-reader` is available OR `stillfail-pion` is available and enabled for `sessions`.
export function sessionsBinaryAvailable(
  data?: string,
  options?: SessionsProgramOptions,
): boolean {
  if (options?.binary != null) return true;
  if (mbReaderBinary() !== null) return true;
  const config = materializeConfig(readConfigOption(data, options));
  const intent = resolveReaderEngine("sessions", {
    config,
    env: options?.env,
    hasPionBinary: true,
    pionImplemented: options?.pionImplemented,
  });
  return intent.engine === "pion" && pionBinary() !== null;
}

export class SessionsProgram {
  readonly #data: string;
  readonly #args: string[];
  readonly #requirePion: boolean;
  readonly #env?: Readonly<Record<string, string | undefined>>;
  #proc: MbProcess | null = null;
  #pendingAbort: AbortController | null = null;
  #pendingMessages: Json[] = [];
  readonly #users = new Set<ProgramUser>();
  readonly #held = new Set<ProgramUser>();
  #ended = false;
  #readyRecorded = false;

  private constructor(
    data: string,
    initial: ResolvedReaderSelection | null,
    pendingOptions?: {
      readonly config?: ReaderSelectConfig | (() => ReaderSelectConfig);
      readonly env?: Readonly<Record<string, string | undefined>>;
      readonly binary?: string | null;
      readonly pionImplemented?: boolean;
    },
  ) {
    this.#data = data;
    this.#args = ["--sessions", "1", "--data", data, "--sep", sep];
    this.#env = pendingOptions?.env;
    this.#requirePion = isPionSessionsRequired(pendingOptions?.env);
    if (initial !== null) {
      this.#spawnResolved(initial);
    } else {
      const abort = new AbortController();
      this.#pendingAbort = abort;
      resolveReaderSelectionAsync(
        "sessions",
        {
          binary: pendingOptions?.binary,
          config: pendingOptions?.config,
          env: pendingOptions?.env,
          logAt: "sessions",
          pionImplemented: pendingOptions?.pionImplemented,
        },
        abort.signal,
      ).then(
        (resolved) => {
          this.#pendingAbort = null;
          if (this.#ended) return;
          if (this.#requirePion && (resolved.engine !== "pion" || resolved.selection.fallback)) {
            const reason = resolved.selection.reason ?? `resolved=${resolved.engine}`;
            log.error("sessions", "STILLFAIL_REQUIRE_PION_SESSIONS=1 refused non-pion --sessions selection", {
              engine: resolved.engine,
              reason,
            });
            this.#end();
            for (const user of [...this.#users]) user.exited(1);
            return;
          }
          this.#spawnResolved(resolved);
        },
        (error: unknown) => {
          this.#pendingAbort = null;
          if (this.#ended) return;
          const message = error instanceof Error ? error.message : String(error);
          log.warn("agents", "the sessions program failed before starting", { error: message });
          this.#end();
          for (const user of [...this.#users]) user.exited(1);
        },
      );
    }
  }

  #spawnResolved(resolved: ResolvedReaderSelection) {
    const startedAt = wall.now();
    const fallbackMode = fallbackModeOf(resolved.selection, "sessions");
    const proc = new MbProcess(resolved.primaryBinary, this.#args, {
      engine: engineOfSelection(resolved),
      mode: "sessions",
      fallbackMode,
    });
    this.#proc = proc;
    // (held on to by the station's process only while a part of it has something going: `hold`)
    proc.ref(this.#held.size > 0);
    spawnObserverForTest?.({
      binary: resolved.primaryBinary,
      argv: this.#args,
      pid: proc.pid,
      engine: proc.engine,
      ready: false,
      fallback: resolved.selection.fallback,
    });
    // One not started (ENFILE, EMFILE) or gone is told here, its end then by "exit": unheard, it ends the station (D80).
    proc.on("error", (error: Error) => log.warn("agents", "the sessions program failed", { error: error.message }));
    proc.on("message", (said: Json) => {
      if (said?.ready === true) {
        if (!this.#readyRecorded) {
          this.#readyRecorded = true;
          readerTelemetry.recordReady(proc.engine, proc.mode, wall.now() - startedAt);
          spawnObserverForTest?.({
            binary: resolved.primaryBinary,
            argv: this.#args,
            pid: proc.pid,
            engine: proc.engine,
            ready: true,
            fallback: resolved.selection.fallback,
          });
        }
        return;
      }
      const actors = said !== null && typeof said === "object" && "active" in said;
      for (const user of this.#users) if (user.actors === actors) user.said(said);
    });
    proc.on("exit", (code: number) => {
      const asked = this.#ended;
      this.#end();
      if (!asked) for (const user of [...this.#users]) user.exited(code);
    });
    if (this.#pendingMessages.length > 0) {
      const buffered = this.#pendingMessages;
      this.#pendingMessages = [];
      for (const msg of buffered) {
        if (!this.#ended) proc.postMessage(msg);
      }
    }
  }

  static readonly #shared = new Map<string, SessionsProgram>();

  /// The program of `data`'s sessions, where a binary is built (null: none here); started for its first user.
  /// `actors`: for a hub's actors, which one program holds one hub's of: a hub there while another's still runs
  /// (a test's station taken up in the same process) has one of its own.
  static of(data: string, actors = false, options?: SessionsProgramOptions): SessionsProgram | null {
    const requirePion = isPionSessionsRequired(options?.env);
    const config = readConfigOption(data, options);
    if (!requirePion && !sessionsBinaryAvailable(data, options)) return null;

    const existing = SessionsProgram.#shared.get(data);
    if (
      options === undefined &&
      existing !== undefined &&
      !existing.#ended &&
      !(actors && [...existing.#users].some((u) => u.actors))
    ) {
      return existing;
    }

    const resolveOpts = {
      binary: options?.binary,
      config,
      env: options?.env,
      logAt: "sessions",
      pionImplemented: options?.pionImplemented,
    };

    let selected: ReturnType<typeof resolveReaderSelectionOrPending>;
    try {
      selected = resolveReaderSelectionOrPending("sessions", resolveOpts);
    } catch (error) {
      if (requirePion) {
        const message = error instanceof Error ? error.message : String(error);
        throw new Error(`STILLFAIL_REQUIRE_PION_SESSIONS=1 requires Pion for --sessions: ${message}`);
      }
      throw error;
    }

    if (!selected.pending) {
      assertRequiredPionSelection(selected, options?.env);
    }

    const make = () =>
      selected.pending
        ? new SessionsProgram(data, null, resolveOpts)
        : new SessionsProgram(data, selected, { env: options?.env });

    if (options !== undefined) {
      return make();
    }
    if (existing !== undefined && !existing.#ended && actors && [...existing.#users].some((u) => u.actors)) {
      return make();
    }
    const program = make();
    SessionsProgram.#shared.set(data, program);
    return program;
  }

  use(user: ProgramUser) {
    this.#users.add(user);
  }

  /// `user` lets it go: it ends once none uses it.
  async release(user: ProgramUser) {
    this.#users.delete(user);
    this.hold(user, false);
    if (this.#users.size > 0 || this.#ended) return;
    this.#end();
    this.#pendingAbort?.abort();
    this.#pendingAbort = null;
    this.#pendingMessages = [];
    if (this.#proc !== null) {
      await this.#proc.terminate();
    }
  }

  post(message: Json) {
    if (this.#ended) return;
    if (this.#proc !== null) this.#proc.postMessage(message);
    else this.#pendingMessages.push(message);
  }

  /// Whether the station's process waits on it for `user`: while one of its parts has something going.
  hold(user: ProgramUser, on: boolean) {
    const was = this.#held.size > 0;
    if (on) this.#held.add(user);
    else this.#held.delete(user);
    const now = this.#held.size > 0;
    if (now !== was && !this.#ended && this.#proc !== null) this.#proc.ref(now);
  }

  /// Ends it at once (the station's process ends).
  kill() {
    if (this.#proc !== null) {
      this.#proc.kill();
      return;
    }
    if (this.#ended) return;
    this.#pendingAbort?.abort();
    this.#pendingAbort = null;
    this.#pendingMessages = [];
    this.#end();
    const users = [...this.#users];
    queueMicrotask(() => {
      for (const user of users) {
        if (this.#users.has(user)) user.exited(1);
      }
    });
  }

  get ended() {
    return this.#ended;
  }

  #end() {
    if (this.#ended) return;
    this.#ended = true;
    if (SessionsProgram.#shared.get(this.#data) === this) SessionsProgram.#shared.delete(this.#data);
  }
}
