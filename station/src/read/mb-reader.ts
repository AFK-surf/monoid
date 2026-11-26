// The station's reader in MoonBit (station/mb, src/reader): a process of its own, asked and answering a line of JSON
// each way on its stdin and stdout. The pool (read/pool.ts) gives it every read and the store's checkpoints (`--data`);
// with `--builder` it is a builder of old state, asked by read/requested-builder.ts or, for a backfill the station
// drives itself, through `MbBackfill`. It is built for every system a station runs on, so there is no reader or builder
// in TypeScript to fall back to: those it replaced are the tests' only (test/reference-worker.ts, test/workers/).
import { type ChildProcess, spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { accessSync, constants, statSync } from "node:fs";
import { delimiter, join, resolve, sep } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { wall } from "../ops/fibers.ts";
import type { Lang } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { isBackgroundWrapperExecFailure, isBackgroundWrapperStderrLine, platform } from "../platform/index.ts";
import { giveBackfill, takeBackfill } from "../store/backfill.ts";
import {
  type PionBinaryStamp,
  type PionBreakerContext,
  type PionCircuitBreaker,
  pionBinaryStamp,
  pionBinaryStampAsync,
  pionCircuitBreaker,
  pionStampKey,
} from "./pion-breaker.ts";
import {
  type DefaultPolicyTable,
  type InstalledChannel,
  READER_MODES,
  type ReaderEngine,
  type ReaderMode,
  type ReaderSelectConfig,
  type ReaderSelection,
  resolveReaderEngine,
} from "./reader-select.ts";
import { type TelemetryEngine, classifyProgram, readerTelemetry } from "./reader-telemetry.ts";

/// A read asked of a reader (main.mbt `answer`).
export type Ask = { id: number; op: string; args: any; lang: Lang; names: [string, string][]; processes: [string, string][]; clientKeys: [string, string][]; catalog?: Record<string, unknown> };
/// A read's answer. `body`: the text as its bytes, as the program gives it (`Said`).
export type Answer = { id: number; text?: string; body?: Buffer; status?: number; error?: string; prepareUpJobs?: string; prepareWorkspaceUpJobs?: boolean };
/// Said once, as a reader is ready: how long it took from its first line (its code read in) to its store opened.
export type Ready = { ready: { loadedMs: number; openedMs: number } };

/// The program: STILLFAIL_MB_READER, else beside the station's code in a release, else where `moon build` puts it in
/// a checkout (station/mb/build.sh, for the Mac). None: not built here. Found once for each STILLFAIL_MB_READER (a
/// test may set its own): a builder, a measure and the agents' program each started asking it, every time a look at
/// the disk on the main thread. Not found is looked for again, as a checkout may build it while the station runs.
const foundBinary = new Map<string, string>();
let mbReaderBinaryOverrideForTest: (() => string | null) | undefined;

/// Test-only override for `mbReaderBinary()` so Pion-only cold-start tests stay deterministic
/// even on developer machines that have a built `station/mb/_build/stillfail-reader-*`.
export function setMbReaderBinaryOverrideForTest(fn?: () => string | null): void {
  mbReaderBinaryOverrideForTest = fn;
  foundBinary.clear();
}

export function invalidateMbReaderBinaryCache(): void {
  foundBinary.clear();
}

export function invalidatePionBinaryCache(): void {
  foundPionBinary.clear();
  pionBinaryMissUntil = 0;
}

function resolveBareCommandInPath(cmd: string): string | null {
  const pathEnv = process.env.PATH;
  if (!pathEnv) return null;
  for (const dir of pathEnv.split(delimiter)) {
    if (dir === "") continue;
    const candidate = join(dir, cmd);
    if (isExecutableFile(candidate)) return candidate;
    const withExe = platform.exe(cmd);
    if (withExe !== cmd) {
      const exeCandidate = join(dir, withExe);
      if (isExecutableFile(exeCandidate)) return exeCandidate;
    }
  }
  return null;
}

export function mbReaderBinary(): string | null {
  if (mbReaderBinaryOverrideForTest !== undefined) return mbReaderBinaryOverrideForTest();
  const explicitRaw = process.env.STILLFAIL_MB_READER?.trim();
  const envKey = explicitRaw ?? "";
  // Cache hit returns directly with zero hot-path stat/access; ENOENT/EACCES on spawn invalidates the cache.
  const had = foundBinary.get(envKey);
  if (had !== undefined) return had;
  if (explicitRaw !== undefined && explicitRaw !== "") {
    const hasPathSyntax = explicitRaw.includes("/") || explicitRaw.includes("\\") || explicitRaw.startsWith(".");
    const resolved = hasPathSyntax ? resolve(explicitRaw) : resolveBareCommandInPath(explicitRaw);
    if (resolved === null || (hasPathSyntax && !isExecutableFile(resolved))) return null;
    foundBinary.set(envKey, resolved);
    return resolved;
  }
  const candidates = [
    fileURLToPath(new URL(`./${platform.exe("stillfail-reader")}`, import.meta.url)),
    // (from the source only: bundled, this is main.js, beside which the release puts the program)
    import.meta.url.endsWith(".ts") ? fileURLToPath(new URL("../../mb/_build/stillfail-reader-darwin-arm64", import.meta.url)) : undefined,
  ];
  const found = candidates.find((p) => p !== undefined && p !== "" && isExecutableFile(p)) ?? null;
  if (found !== null) foundBinary.set(envKey, found);
  return found;
}

/// The program, which every station has (`mbReaderBinary`); where it is not built (a checkout that has not), what needs
/// it fails saying so.
export function readerBinary(): string {
  const binary = mbReaderBinary();
  if (binary === null) throw new Error("the station's MoonBit program (stillfail-reader) is not built here (station/mb/build.sh, or STILLFAIL_MB_READER)");
  return binary;
}

function isExecutableFile(path: string): boolean {
  try {
    if (!statSync(path).isFile()) return false; // sync: startup/explicit binary resolution, cached on success
    if (platform.os !== "windows") accessSync(path, constants.X_OK); // sync: startup/explicit binary resolution, cached on success
    return true;
  } catch {
    return false;
  }
}

const foundPionBinary = new Map<string, string | null>();
/// Cooldown before re-checking disk when non-explicit `pionBinary()` lookup missed (avoids repeated `statSync`
/// on hot paths while still discovering binaries installed or built while the station is running).
const PION_BINARY_MISS_COOLDOWN_MS = 30_000;
let pionBinaryMissUntil = 0;

/// The Pion reader/builder binary (`stillfail-pion`):
/// 1. Explicit `STILLFAIL_PION_READER` env override (resolved via `path.resolve`; if set and non-empty,
///    only that path is accepted and its lookup result — found or missing — is cached by resolved path)
/// 2. Bundled beside `stillfail-reader` (`stillfail-pion` / `stillfail-pion.exe`)
/// 3. Checkout dev build (`pion/station/_build/stillfail-pion-<host>`)
export function pionBinary(): string | null {
  const explicitRaw = process.env.STILLFAIL_PION_READER?.trim();
  if (explicitRaw !== undefined && explicitRaw !== "") {
    const resolved = resolve(explicitRaw);
    const cacheKey = `explicit:${resolved}`;
    const had = foundPionBinary.get(cacheKey);
    if (had !== undefined && had !== null) return had;
    if (!isExecutableFile(resolved)) return null;
    foundPionBinary.set(cacheKey, resolved);
    return resolved;
  }
  const had = foundPionBinary.get("");
  if (had !== undefined && had !== null) return had;
  if (had === null && wall.now() < pionBinaryMissUntil) return null;
  const hostBuild = import.meta.url.endsWith(".ts") && platform.buildOs !== null
    ? fileURLToPath(new URL(`../../../pion/station/_build/${platform.exe(`stillfail-pion-${platform.buildOs}-${process.arch}`)}`, import.meta.url))
    : undefined;
  const candidates = [
    fileURLToPath(new URL(`./${platform.exe("stillfail-pion")}`, import.meta.url)),
    hostBuild,
  ];
  const found = candidates.find((p) => p !== undefined && p !== "" && isExecutableFile(p)) ?? null;
  foundPionBinary.set("", found);
  pionBinaryMissUntil = found === null ? wall.now() + PION_BINARY_MISS_COOLDOWN_MS : 0;
  return found;
}

/// The three baseline modes supported without a `--version` probe.
/// This assumes any `stillfail-pion` binary on disk is no older than the three-baseline-complete release baseline
/// (commit `ab0bba7835` and later, predating Wave 5 first bundling `stillfail-pion` with stations).
export const PION_BASELINE_MODES: ReadonlySet<ReaderMode> = new Set<ReaderMode>(["footprint", "packed", "memory"]);

/// Cooldown before retrying a failed or timed-out `--version` probe (transient load should not lock out Pion forever).
const PION_PROBE_RETRY_COOLDOWN_MS = 30_000;
/// Maximum stdout bytes accepted from `stillfail-pion --version` (matches `front.rs` `PROBE_STDOUT_LIMIT`).
const PION_PROBE_STDOUT_LIMIT = 64 * 1024;

const probedPionModes = new Map<string, ReadonlySet<string>>();
const probingPionModes = new Map<string, Promise<ReadonlySet<string> | null>>();
const failedPionProbeUntil = new Map<string, number>();
const warnedReaderFallbacks = new Set<string>();
type PionProbeRunner = (binaryPath: string) => Promise<ReadonlySet<string> | null>;
type PionProbeSpawner = (binaryPath: string, args: string[]) => ChildProcess;
let customPionProbeRunner: PionProbeRunner | null = null;
let customPionProbeSpawner: PionProbeSpawner | null = null;

/// Override the `--version` probe runner in tests (allows deterministic pending/fail/release control).
export function setPionProbeRunnerForTest(runner: PionProbeRunner | null): void {
  customPionProbeRunner = runner;
}

/// Override the underlying `spawn` call used by `--version` probing in tests (e.g. EMFILE simulation).
export function setPionProbeSpawnerForTest(spawner: PionProbeSpawner | null): void {
  customPionProbeSpawner = spawner;
}

/// Parse supported modes from `stillfail-pion --version` output (`modes:a,b,c`).
/// Older binaries that omit `modes:` are treated as supporting only the 3 baseline modes.
export function parsePionVersionModes(stdout: string): ReadonlySet<string> {
  const modes = new Set<string>(PION_BASELINE_MODES);
  const match = /(?:^|\s)modes:([a-z0-9_,-]+)(?=\s|$)/i.exec(stdout);
  if (match?.[1]) {
    for (const part of match[1].split(",")) {
      const m = part.trim().toLowerCase();
      if (m !== "") modes.add(m);
    }
  }
  return modes;
}

export type PionProbeStatus =
  | { readonly state: "ready"; readonly modes: ReadonlySet<string> }
  | { readonly state: "cooldown" }
  | { readonly state: "pending"; readonly promise: Promise<ReadonlySet<string> | null> };

function pionProbeCacheKey(binaryPath: string, precomputedStamp?: PionBinaryStamp | null): string {
  const stamp = precomputedStamp !== undefined ? precomputedStamp : pionBinaryStamp(binaryPath);
  return stamp !== null ? pionStampKey(stamp) : resolve(binaryPath);
}

/// Non-blocking capability probe status for `binaryPath`, keyed by `(path, binaryStamp)` so replacing
/// a binary at the same path always re-probes and late probes for an old stamp never overwrite a new one.
/// Explicitly distinguishes `ready`, `cooldown`, and `pending`.
export function pionSupportedModesStatus(binaryPath: string, precomputedStamp?: PionBinaryStamp | null): PionProbeStatus {
  const resolvedPath = resolve(binaryPath);
  const cacheKey = pionProbeCacheKey(resolvedPath, precomputedStamp);
  const cached = probedPionModes.get(cacheKey);
  if (cached !== undefined) return { state: "ready", modes: cached };
  const retryAfter = failedPionProbeUntil.get(cacheKey);
  if (retryAfter !== undefined && wall.now() < retryAfter) return { state: "cooldown" };
  let pending = probingPionModes.get(cacheKey);
  if (pending === undefined) {
    let settled = false;
    pending = new Promise<ReadonlySet<string> | null>((resolveProbe) => {
      const finish = (supported: ReadonlySet<string> | null) => {
        if (settled) return;
        settled = true;
        probingPionModes.delete(cacheKey);
        if (supported !== null) {
          failedPionProbeUntil.delete(cacheKey);
          probedPionModes.set(cacheKey, supported);
        } else {
          failedPionProbeUntil.set(cacheKey, wall.now() + PION_PROBE_RETRY_COOLDOWN_MS);
        }
        resolveProbe(supported);
      };
      if (customPionProbeRunner !== null) {
        Promise.resolve(customPionProbeRunner(resolvedPath)).then(
          (res) => finish(res),
          () => finish(null),
        );
        return;
      }
      let stopTimer: (() => void) | null = null;
      let stopDrainTimer: (() => void) | null = null;
      let checkImm: NodeJS.Immediate | null = null;
      const clearTimers = () => {
        if (stopTimer !== null) {
          stopTimer();
          stopTimer = null;
        }
        if (stopDrainTimer !== null) {
          stopDrainTimer();
          stopDrainTimer = null;
        }
        if (checkImm !== null) {
          clearImmediate(checkImm);
          checkImm = null;
        }
      };
      try {
        const child = customPionProbeSpawner !== null
          ? customPionProbeSpawner(resolvedPath, ["--version"])
          : spawn(resolvedPath, ["--version"], { stdio: ["ignore", "pipe", "ignore"], windowsHide: true });
        // Register error listener immediately after spawn so EMFILE/ENFILE never becomes an uncaughtException
        // even when `child.stdout` is null (W9-A5b audit fix).
        child.once("error", () => {
          clearTimers();
          finish(null);
        });
        if (!child.stdout) {
          clearTimers();
          finish(null);
          return;
        }
        let stdout = "";
        let stdoutBytes = 0;
        let timedOut = false;
        const abortProbe = () => {
          timedOut = true;
          clearTimers();
          child.stdout?.destroy();
          if (child.exitCode === null && child.signalCode === null) {
            try {
              child.kill("SIGKILL");
            } catch {}
          }
          finish(null);
        };
        child.stdout.setEncoding("utf8");
        child.stdout.on("data", (chunk: string) => {
          if (settled) return;
          stdoutBytes += Buffer.byteLength(chunk, "utf8");
          if (stdoutBytes > PION_PROBE_STDOUT_LIMIT) {
            abortProbe();
            return;
          }
          stdout += chunk;
        });
        // timer: a timeout or deadline for the --version capability probe
        stopTimer = wall.after(3_000, () => {
          // Defer past one libuv poll turn (`setImmediate` runs in the check phase after I/O + SIGCHLD)
          // so a child that already exited during a synchronous main-thread stall gets reaped first.
          // If it has exited but `close` has not fired yet (stdout EOF pending or grandchild holding stdout),
          // allow a brief 100ms drain grace before destroying stdout and settling as `null`.
          checkImm = setImmediate(() => {
            checkImm = null;
            if (settled) return;
            if (child.exitCode === null && child.signalCode === null) {
              abortProbe();
            } else {
              // timer: a brief drain deadline when the child exited but stdout has not closed yet
              stopDrainTimer = wall.after(100, () => {
                stopDrainTimer = null;
                if (!settled) abortProbe();
              });
            }
          });
        });
        child.once("close", (code, signal) => {
          clearTimers();
          if (timedOut || code !== 0 || signal !== null || stdout.trim() === "") {
            finish(null);
          } else {
            finish(parsePionVersionModes(stdout));
          }
        });
      } catch {
        clearTimers();
        finish(null);
      }
    });
    if (!settled) probingPionModes.set(cacheKey, pending);
  }
  return { state: "pending", promise: pending };
}

/// Non-blocking asynchronous capability probe for `binaryPath` (`execFile(binaryPath, ["--version"], { timeout: 3000, killSignal: "SIGKILL" })`).
/// Returns the cached set of supported mode names once a clean exit-0 probe succeeds, or `null` while probing or during
/// a transient-failure retry cooldown. Never called on default `mb` or for the 3 baseline modes (`footprint`, `packed`, `memory`).
export function pionSupportedModes(binaryPath: string, precomputedStamp?: PionBinaryStamp | null): ReadonlySet<string> | null {
  const st = pionSupportedModesStatus(binaryPath, precomputedStamp);
  return st.state === "ready" ? st.modes : null;
}

/// Await the non-blocking `--version` capability probe for `binaryPath` (starts one if not yet cached).
/// Returns the probed supported mode set, or `null` if the probe failed or timed out.
export function probePionSupportedModes(binaryPath: string, precomputedStamp?: PionBinaryStamp | null): Promise<ReadonlySet<string> | null> {
  const st = pionSupportedModesStatus(binaryPath, precomputedStamp);
  if (st.state === "ready") return Promise.resolve(st.modes);
  if (st.state === "cooldown") return Promise.resolve(null);
  return st.promise;
}

/// Clear cached binary lookups, `--version` capability probes, retry cooldowns, breaker state, and deduped fallback warnings (tests only).
export function resetReaderSelectionStateForTest(): void {
  foundBinary.clear();
  mbReaderBinaryOverrideForTest = undefined;
  foundPionBinary.clear();
  pionBinaryMissUntil = 0;
  probedPionModes.clear();
  probingPionModes.clear();
  failedPionProbeUntil.clear();
  warnedReaderFallbacks.clear();
  customPionProbeRunner = null;
  customPionProbeSpawner = null;
  pionCircuitBreaker.resetForTest();
}

export type ResolveReaderSelectionOptions = {
  /// Explicit binary override; always wins and skips engine selection and `pionBinary()` probing.
  readonly binary?: string | null;
  /// Live `config.json` `readers` snapshot or getter.
  readonly config?: ReaderSelectConfig | (() => ReaderSelectConfig);
  /// Environment variables (defaults to `process.env`).
  readonly env?: Readonly<Record<string, string | undefined>>;
  /// Log component tag for deduplicated fallback warnings (defaults to `"readers"`).
  readonly logAt?: string;
  /// Optional override for `READER_MODES[mode].pionImplemented` (tests verifying binary capability probes).
  readonly pionImplemented?: boolean;
  /// Installed release channel override (from `<app>/CHANNEL`, never `config.updateChannel`).
  readonly installedChannel?: InstalledChannel | string | null;
  /// Canonical target override (defaults to `currentReaderTarget()`).
  readonly target?: string | null;
  /// Policy table override (defaults to `PION_DEFAULT_TARGETS_BY_CHANNEL`; injectable in tests).
  readonly defaultTargetsByChannel?: DefaultPolicyTable;
  /// Per-station circuit breaker override (defaults to `config.breaker` or fallback singleton).
  readonly breaker?: PionCircuitBreaker | null;
};

export type ResolvedReaderSelection = {
  readonly engine: ReaderEngine;
  readonly primaryBinary: string;
  readonly pionBinary: string | null;
  readonly selection: ReaderSelection;
  readonly pionStamp?: PionBinaryStamp | null;
  readonly breaker?: PionCircuitBreaker;
};

function warnReaderFallbackOnce(logAt: string, selection: ReaderSelection): void {
  if (!selection.fallback) return;
  const isWildcardInvalid =
    selection.reason === "invalid-value" && selection.detail?.includes('config.readers["*"]') === true;
  const dedupKey = isWildcardInvalid
    ? "*:config:invalid-value"
    : `${selection.mode}:${selection.source}:${selection.reason ?? "unknown"}`;
  if (warnedReaderFallbacks.has(dedupKey)) return;
  warnedReaderFallbacks.add(dedupKey);
  log.warn(logAt, "reader engine fallback", {
    mode: isWildcardInvalid ? "*" : selection.mode,
    engine: selection.engine,
    requested: selection.requested,
    source: selection.source,
    reason: selection.reason,
    detail: selection.detail,
  });
}

function warnBreakerNoMbOnce(logAt: string, mode: ReaderMode, pionBin: string): void {
  const dedupKey = `${mode}:default:pion-circuit-breaker-no-mb`;
  if (warnedReaderFallbacks.has(dedupKey)) return;
  warnedReaderFallbacks.add(dedupKey);
  log.warn(logAt, "pion default circuit breaker demoted mode but no MB binary is available; staying on pion", {
    mode,
    path: pionBin,
  });
}

/// Telemetry engine of the primary binary returned by `resolveReaderSelection`.
/// Returns `undefined` for explicit binary overrides so `MbProcess` classifies the explicit path itself.
export function engineOfSelection(resolved: ResolvedReaderSelection): TelemetryEngine | undefined {
  if (resolved.selection.source === "explicit") return undefined;
  return resolved.engine === "pion" ? "pion" : "mb";
}

/// Circuit-breaker attribution context for a default-selected Pion spawn.
/// Strictly returns `undefined` for explicit config/env/explicit/shadow spawns.
export function breakerOfSelection(resolved: ResolvedReaderSelection): PionBreakerContext | undefined {
  if (
    resolved.engine === "pion" &&
    resolved.selection.source === "default" &&
    resolved.pionStamp != null &&
    resolved.breaker !== undefined
  ) {
    return {
      breaker: resolved.breaker,
      source: "default",
      mode: resolved.selection.mode,
      stamp: resolved.pionStamp,
    };
  }
  return undefined;
}

/// Return the fallback telemetry mode when `selection` fell back from `"pion"` or `"shadow"` to `"mb"`.
/// Transient `pion-probe-pending` is excluded so an unready capability probe is never miscounted as a real fallback.
export function fallbackModeOf(selection: ReaderSelection, modeOverride?: string): string | undefined {
  if (
    selection.fallback &&
    selection.reason !== "pion-probe-pending" &&
    (selection.requested === "pion" || selection.requested === "shadow")
  ) {
    return modeOverride ?? selection.mode;
  }
  return undefined;
}

/// Record a fallback counter ONLY when an actual MB process is spawned after requesting `"pion"` or `"shadow"`.
export function recordFallbackSpawn(selection: ReaderSelection, modeOverride?: string): void {
  const mode = fallbackModeOf(selection, modeOverride);
  if (mode !== undefined) readerTelemetry.recordFallback(mode);
}

/// Infer `"pion"` without extra disk I/O when `binary` matches `STILLFAIL_PION_READER` or the cached `pionBinary()`.
function isKnownPionBinary(binary: string): boolean {
  const target = resolve(binary);
  const explicitRaw = process.env.STILLFAIL_PION_READER?.trim();
  if (explicitRaw !== undefined && explicitRaw !== "") {
    if (target === resolve(explicitRaw)) return true;
  }
  const cached = foundPionBinary.get("");
  return cached !== undefined && cached !== null && target === resolve(cached);
}

/// Unified reader/builder binary & engine selector for single-engine and `shadow` modes.
///
/// Invariants:
/// - Explicit `options.binary` always takes precedence without probing `pionBinary()`.
/// - Default `"mb"` never calls `pionBinary()` (zero main-thread `statSync`, zero `--version` spawn).
/// - Unimplemented Pion modes (`pionImplemented === false`) fall back to `"mb"` before touching disk.
/// - Non-baseline Pion modes check `pionSupportedModes(pionBin)` asynchronously: while the first
///   `--version` probe is in flight they safely run `"mb"`, and once probed either switch to `"pion"`
///   or permanently fall back to `"mb"` for that binary path with a deduped `pion-binary-unsupported-mode` warn.
type PrecomputedPionStamp =
  | { readonly kind: "stamp"; readonly path: string; readonly stamp: PionBinaryStamp | null }
  | { readonly kind: "exhausted" };

function resolveReaderSelectionInternal(
  mode: ReaderMode,
  options: ResolveReaderSelectionOptions,
  precomputedConfig?: ReaderSelectConfig,
  precomputedStamp?: PrecomputedPionStamp,
): ResolvedReaderSelection {
  if (options.binary != null) {
    return {
      engine: "mb",
      primaryBinary: options.binary,
      pionBinary: null,
      selection: {
        mode,
        engine: "mb",
        requested: null,
        rawRequested: null,
        source: "explicit",
        fallback: false,
      },
    };
  }
  const logAt = options.logAt ?? "readers";
  const config = precomputedConfig !== undefined
    ? precomputedConfig
    : (typeof options.config === "function" ? options.config() : options.config);
  const breaker = options.breaker !== undefined ? options.breaker : (config?.breaker ?? pionCircuitBreaker);
  const policyOpts = {
    installedChannel: options.installedChannel,
    target: options.target,
    defaultTargetsByChannel: options.defaultTargetsByChannel,
  };
  const probe = resolveReaderEngine(mode, {
    config,
    env: options.env,
    hasPionBinary: true,
    pionImplemented: options.pionImplemented,
    ...policyOpts,
  });
  if (probe.engine === "mb") {
    warnReaderFallbackOnce(logAt, probe);
    return { engine: "mb", primaryBinary: readerBinary(), pionBinary: null, selection: probe };
  }
  let pionBin = pionBinary();
  let stamp: PionBinaryStamp | null = null;
  if (pionBin !== null) {
    if (precomputedStamp?.kind === "exhausted") {
      pionBin = null;
    } else if (precomputedStamp !== undefined && precomputedStamp.path === resolve(pionBin)) {
      stamp = precomputedStamp.stamp;
      if (stamp === null) pionBin = null;
    } else {
      stamp = pionBinaryStamp(pionBin);
      if (stamp === null) {
        // Cached Pion binary disappeared or became unreadable on disk: invalidate and re-probe once.
        invalidatePionBinaryCache();
        pionBin = pionBinary();
        stamp = pionBin !== null ? pionBinaryStamp(pionBin) : null;
        if (stamp === null) pionBin = null;
      }
    }
  }
  if (pionBin === null) {
    const selection = resolveReaderEngine(mode, {
      config,
      env: options.env,
      hasPionBinary: false,
      pionImplemented: options.pionImplemented,
      ...policyOpts,
    });
    warnReaderFallbackOnce(logAt, selection);
    return { engine: "mb", primaryBinary: readerBinary(), pionBinary: null, selection };
  }
  if (probe.source === "default" && breaker !== null && breaker.isDemoted(mode, stamp)) {
    const mbBin = mbReaderBinary();
    if (mbBin !== null) {
      const selection: ReaderSelection = {
        ...probe,
        engine: "mb",
        fallback: true,
        reason: "pion-circuit-breaker",
        detail: `mode "${mode}" defaulted to "pion" but is demoted by crash circuit breaker; falling back to "mb"`,
      };
      warnReaderFallbackOnce(logAt, selection);
      return { engine: "mb", primaryBinary: mbBin, pionBinary: null, selection };
    }
    warnBreakerNoMbOnce(logAt, mode, pionBin);
  }
  if (!PION_BASELINE_MODES.has(mode)) {
    const status = pionSupportedModesStatus(pionBin, stamp);
    if (status.state === "cooldown") {
      const selection: ReaderSelection = {
        ...probe,
        engine: "mb",
        fallback: true,
        reason: "pion-probe-failed",
        detail: `mode "${mode}" requested "${probe.requested}" from ${probe.source} but Pion capability probe failed; falling back to "mb"`,
      };
      warnReaderFallbackOnce(logAt, selection);
      return { engine: "mb", primaryBinary: readerBinary(), pionBinary: null, selection };
    }
    if (status.state === "pending") {
      return {
        engine: "mb",
        primaryBinary: readerBinary(),
        pionBinary: pionBin,
        selection: { ...probe, engine: "mb", fallback: true, reason: "pion-probe-pending" },
      };
    }
    const supported = status.modes;
    if (!supported.has(mode)) {
      const selection = resolveReaderEngine(mode, {
        config,
        env: options.env,
        hasPionBinary: true,
        pionImplemented: options.pionImplemented,
        pionModeSupported: false,
        ...policyOpts,
      });
      warnReaderFallbackOnce(logAt, selection);
      return { engine: "mb", primaryBinary: readerBinary(), pionBinary: null, selection };
    }
  }
  if (probe.engine === "pion") {
    return {
      engine: "pion",
      primaryBinary: pionBin,
      pionBinary: pionBin,
      selection: probe,
      pionStamp: stamp,
      ...(breaker !== null ? { breaker } : {}),
    };
  }
  return { engine: "shadow", primaryBinary: readerBinary(), pionBinary: pionBin, selection: probe, pionStamp: stamp };
}

export function resolveReaderSelection(
  mode: ReaderMode,
  options: ResolveReaderSelectionOptions = {},
): ResolvedReaderSelection {
  return resolveReaderSelectionInternal(mode, options);
}

export type PendingOrResolvedSelection =
  | { readonly pending: true; readonly pionBinary: string; readonly pionStamp: PionBinaryStamp | null }
  | ({ readonly pending: false } & ResolvedReaderSelection);

/// Synchronous fast-path selection that returns `{ pending: true, pionBinary }` when a Pion
/// capability probe has not completed yet — WITHOUT calling `readerBinary()` (so Pion-only
/// hosts without `stillfail-reader` on disk can cold-start cleanly through `resolveReaderSelectionAsync`).
export function resolveReaderSelectionOrPending(
  mode: ReaderMode,
  options: ResolveReaderSelectionOptions = {},
  precomputedStamp?: PrecomputedPionStamp,
): PendingOrResolvedSelection {
  if (options.binary != null) {
    return { pending: false, ...resolveReaderSelectionInternal(mode, options) };
  }
  const config = typeof options.config === "function" ? options.config() : options.config;
  const breaker = options.breaker !== undefined ? options.breaker : (config?.breaker ?? pionCircuitBreaker);
  const probe = resolveReaderEngine(mode, {
    config,
    env: options.env,
    hasPionBinary: true,
    pionImplemented: options.pionImplemented,
    installedChannel: options.installedChannel,
    target: options.target,
    defaultTargetsByChannel: options.defaultTargetsByChannel,
  });
  let preStamp: PrecomputedPionStamp | undefined = precomputedStamp;
  if (probe.engine !== "mb" && !PION_BASELINE_MODES.has(mode)) {
    let pionBin = pionBinary();
    if (pionBin !== null) {
      let stamp: PionBinaryStamp | null;
      const resolvedPath = resolve(pionBin);
      if (preStamp?.kind === "exhausted") {
        stamp = null;
        pionBin = null;
      } else if (preStamp !== undefined && preStamp.path === resolvedPath) {
        stamp = preStamp.stamp;
        if (stamp === null) pionBin = null;
      } else {
        stamp = pionBinaryStamp(pionBin);
        if (stamp === null) {
          invalidatePionBinaryCache();
          pionBin = pionBinary();
          stamp = pionBin !== null ? pionBinaryStamp(pionBin) : null;
          if (stamp === null) pionBin = null;
        }
        preStamp = { kind: "stamp", path: pionBin !== null ? resolve(pionBin) : resolvedPath, stamp };
      }
      if (pionBin !== null) {
        if (probe.source === "default" && breaker !== null && breaker.isDemoted(mode, stamp) && mbReaderBinary() !== null) {
          return { pending: false, ...resolveReaderSelectionInternal(mode, options, config, preStamp) };
        }
        if (pionSupportedModesStatus(pionBin, stamp).state === "pending") {
          return { pending: true, pionBinary: pionBin, pionStamp: stamp };
        }
      }
    }
  }
  return { pending: false, ...resolveReaderSelectionInternal(mode, options, config, preStamp) };
}

async function awaitWithAbort<T>(promise: Promise<T>, signal?: AbortSignal): Promise<T> {
  if (signal === undefined) return await promise;
  if (signal.aborted) throw new Error("called off");
  const value = await new Promise<T>((resolveWait, rejectWait) => {
    if (signal.aborted) return rejectWait(new Error("called off"));
    const onAbort = () => rejectWait(new Error("called off"));
    signal.addEventListener("abort", onAbort, { once: true });
    promise.then(
      (v) => {
        signal.removeEventListener("abort", onAbort);
        resolveWait(v);
      },
      (err) => {
        signal.removeEventListener("abort", onAbort);
        rejectWait(err);
      },
    );
  });
  if (signal.aborted) throw new Error("called off");
  return value;
}

async function resolvePionStampAsyncForSelection(
  mode: ReaderMode,
  options: ResolveReaderSelectionOptions,
  config: ReaderSelectConfig | undefined,
  signal?: AbortSignal,
): Promise<PrecomputedPionStamp | undefined> {
  if (options.binary != null) return undefined;
  const probe = resolveReaderEngine(mode, {
    config,
    env: options.env,
    hasPionBinary: true,
    pionImplemented: options.pionImplemented,
    installedChannel: options.installedChannel,
    target: options.target,
    defaultTargetsByChannel: options.defaultTargetsByChannel,
  });
  if (probe.engine === "mb") return undefined;
  for (let attempt = 0; attempt < 3; attempt++) {
    const pionBin = pionBinary();
    if (pionBin === null) return undefined;
    const resolvedPath = resolve(pionBin);
    const stamp = await awaitWithAbort(pionBinaryStampAsync(pionBin), signal);
    if (stamp === null) {
      invalidatePionBinaryCache();
      const nextBin = pionBinary();
      if (nextBin === null) return { kind: "stamp", path: resolvedPath, stamp: null };
      const nextPath = resolve(nextBin);
      if (nextPath !== resolvedPath) continue;
      const retryStamp = await awaitWithAbort(pionBinaryStampAsync(nextBin), signal);
      const afterRetry = pionBinary();
      if (afterRetry !== null && resolve(afterRetry) !== nextPath) continue;
      return { kind: "stamp", path: nextPath, stamp: retryStamp };
    }
    const afterBin = pionBinary();
    if (afterBin !== null && resolve(afterBin) !== resolvedPath) continue;
    return { kind: "stamp", path: resolvedPath, stamp };
  }
  return { kind: "exhausted" };
}

/// Await-capable reader selection:
/// - Synchronous fast path for explicit binary, `mb` intent, baseline modes, cached Pion, or cooldown failures.
/// - Only when the Pion capability probe is pending does it await the shared `probePionSupportedModes(pionBin)` promise,
///   without eagerly requiring `stillfail-reader` on disk.
/// - If the Pion binary at the same path is replaced mid-probe (A -> B), loops up to 3 rounds to await B's probe
///   instead of falling back prematurely to MB.
/// - When `signal` is supplied, aborting rejects immediately with `"called off"` without cancelling the shared probe,
///   cleans up its listener, and re-checks `signal.aborted` after await.
export async function resolveReaderSelectionAsync(
  mode: ReaderMode,
  options: ResolveReaderSelectionOptions = {},
  signal?: AbortSignal,
): Promise<ResolvedReaderSelection> {
  if (signal?.aborted) throw new Error("called off");
  if (options.binary != null) {
    return resolveReaderSelectionInternal(mode, options);
  }
  for (let round = 0; round < 3; round++) {
    const initialConfig = typeof options.config === "function" ? options.config() : options.config;
    const preStamp = await resolvePionStampAsyncForSelection(mode, options, initialConfig, signal);
    if (signal?.aborted) throw new Error("called off");
    // Re-read live config after async stat so an in-flight hot rollback to "mb" takes effect immediately.
    const freshConfig = typeof options.config === "function" ? options.config() : options.config;
    const freshOptions: ResolveReaderSelectionOptions =
      freshConfig === options.config ? options : { ...options, config: freshConfig };
    const freshProbe = resolveReaderEngine(mode, {
      config: freshConfig,
      env: options.env,
      hasPionBinary: true,
      pionImplemented: options.pionImplemented,
      installedChannel: options.installedChannel,
      target: options.target,
      defaultTargetsByChannel: options.defaultTargetsByChannel,
    });
    if (freshProbe.engine === "mb") {
      return resolveReaderSelectionInternal(mode, freshOptions, freshConfig);
    }
    if (preStamp?.kind === "stamp") {
      const curBin = pionBinary();
      if (curBin !== null && resolve(curBin) !== preStamp.path) {
        continue;
      }
    } else if (preStamp === undefined && pionBinary() !== null) {
      continue;
    }
    const sync = resolveReaderSelectionOrPending(mode, freshOptions, preStamp);
    if (!sync.pending) {
      return sync;
    }
    const probePromise = probePionSupportedModes(sync.pionBinary, sync.pionStamp).catch(() => null);
    await awaitWithAbort(probePromise, signal);
    if (signal?.aborted) throw new Error("called off");
  }
  const finalConfig = typeof options.config === "function" ? options.config() : options.config;
  const finalStamp = await resolvePionStampAsyncForSelection(mode, options, finalConfig, signal);
  if (signal?.aborted) throw new Error("called off");
  const postFinalConfig = typeof options.config === "function" ? options.config() : options.config;
  const postFinalOptions: ResolveReaderSelectionOptions =
    postFinalConfig === options.config ? options : { ...options, config: postFinalConfig };
  const postFinalProbe = resolveReaderEngine(mode, {
    config: postFinalConfig,
    env: options.env,
    hasPionBinary: true,
    pionImplemented: options.pionImplemented,
    installedChannel: options.installedChannel,
    target: options.target,
    defaultTargetsByChannel: options.defaultTargetsByChannel,
  });
  if (postFinalProbe.engine === "mb") {
    return resolveReaderSelectionInternal(mode, postFinalOptions, postFinalConfig);
  }
  const curFinalBin = pionBinary();
  const safeFinalStamp: PrecomputedPionStamp | undefined =
    finalStamp?.kind === "stamp" && curFinalBin !== null && resolve(curFinalBin) !== finalStamp.path
      ? { kind: "exhausted" }
      : (finalStamp === undefined && curFinalBin !== null ? { kind: "exhausted" } : finalStamp);
  return resolveReaderSelectionInternal(mode, postFinalOptions, postFinalConfig, safeFinalStamp);
}

/// Pre-warm the Pion `--version` capability probe during `ReaderConfig.layer` startup ONLY when
/// env/config requests `pion` for at least one implemented, non-baseline, non-restore mode.
/// Zero probes on default `mb`, baseline-only configs, or unimplemented modes.
export async function warmPionProbeForConfig(
  config: ReaderSelectConfig,
  env: Readonly<Record<string, string | undefined>> = process.env,
  policyOpts?: {
    readonly installedChannel?: InstalledChannel | string | null;
    readonly target?: string | null;
    readonly defaultTargetsByChannel?: DefaultPolicyTable;
  },
): Promise<void> {
  let needsProbe = false;
  for (const mode of Object.keys(READER_MODES) as ReaderMode[]) {
    if (mode === "replica-restore" || PION_BASELINE_MODES.has(mode)) continue;
    if (!READER_MODES[mode].pionImplemented) continue;
    const intent = resolveReaderEngine(mode, { config, env, hasPionBinary: true, ...policyOpts });
    if (intent.engine === "pion" || intent.engine === "shadow") {
      needsProbe = true;
      break;
    }
  }
  if (!needsProbe) return;
  const pionBin = pionBinary();
  if (pionBin === null) return;
  const stamp = await pionBinaryStampAsync(pionBin);
  await probePionSupportedModes(pionBin, stamp);
}

/// Shared options for background and on-demand reader builders.
export type BackfillOptions = {
  previousGone?: Promise<void>;
  priority?: SharedArrayBuffer;
  readers?: () => ReaderSelectConfig;
};

/// What the pool asks of a reader: the program's process, or what a test gives in its place (test/reference.ts).
export interface ReaderLike {
  on(event: "message", f: (answer: Answer | Ready) => void): this;
  on(event: "error", f: (error: Error) => void): this;
  on(event: "exit", f: (code: number) => void): this;
  postMessage(ask: Ask): void;
  terminate(): Promise<number>;
  getHeapStatistics(): Promise<{ used_heap_size: number }>;
}

/// What a program says on its stdout: a line of JSON at a time, each told whole as it ends; a line that says `bytes` has
/// that many bytes after it, its body, told with it as `body` as they are (the reader's answer: main.mbt `say_answer`),
/// never decoded or unescaped here. A line is ended by its `\n` alone (readline also took U+2028 and U+2029 for ends).
export class Said {
  #carry: Buffer[] = [];
  #size = 0;
  /// The head waiting for its body, and how many bytes of it are still to come.
  #head: Record<string, unknown> | null = null;
  #wanted = 0;
  readonly #tell: (said: unknown) => void;
  constructor(tell: (said: unknown) => void) { this.#tell = tell; }

  push(bytes: Buffer) {
    let at = 0;
    while (at < bytes.length) {
      if (this.#head !== null) {
        const take = Math.min(this.#wanted - this.#size, bytes.length - at);
        this.#carry.push(bytes.subarray(at, at + take));
        this.#size += take;
        at += take;
        if (this.#size < this.#wanted) return;
        const head = this.#head;
        const body = this.#carry.length === 1 ? this.#carry[0]! : Buffer.concat(this.#carry, this.#size);
        this.#head = null;
        this.#carry = [];
        this.#size = 0;
        this.#tell({ ...head, body });
        continue;
      }
      const end = bytes.indexOf(10, at);
      if (end < 0) {
        this.#carry.push(bytes.subarray(at));
        this.#size += bytes.length - at;
        return;
      }
      this.#carry.push(bytes.subarray(at, end));
      const line = (this.#carry.length === 1 ? this.#carry[0]! : Buffer.concat(this.#carry)).toString();
      this.#carry = [];
      this.#size = 0;
      at = end + 1;
      if (line === "") continue;
      let head: unknown;
      try { head = JSON.parse(line); }
      catch {
        log.warn("readers", "a MoonBit program said what is not JSON", { line: line.slice(0, 200) });
        continue;
      }
      const wanted = (head as { bytes?: unknown } | null)?.bytes;
      if (typeof wanted === "number" && Number.isInteger(wanted) && wanted >= 0) {
        const { bytes: _, ...rest } = head as Record<string, unknown>;
        this.#head = rest;
        this.#wanted = wanted;
        if (wanted === 0) {
          this.#head = null;
          this.#tell({ ...rest, body: Buffer.alloc(0) });
        }
        continue;
      }
      this.#tell(head);
    }
  }
}

/// The builders nobody waits on: what the station drives itself, a batch at a time (MbBackfill's kinds), the export
/// of the chats' copies, and a directory's size measured on disk (sessions/footprint.ts). Every other builder answers a request as it is asked (a search, the vault's uses, the usage
/// page, a live session found, the outflow's chats), or holds the backfill permit for its batch as a read waits on it
/// (read/requested-builder.ts), or is waited on by a person (a restore, the mesh's): under PRIO_DARWIN_BG's throttled IO
/// on a busy Mac each would take many times as long, holding up the person or the permit.
const BACKGROUND_BUILDERS = new Set(["replica-export", "footprint", "session-backfill", "post-blocks", "session-counts", "usage-counter", "usage-retire", "signin-save"]);

/// Whether the program with `args` is the station's background work by default: a builder of BACKGROUND_BUILDERS
/// (`--builder <kind>`). The readers that answer devices as they ask (`--data`, `--serve`, `--sessions`) are not.
export function backgroundByDefault(args: readonly string[]): boolean {
  const at = args.indexOf("--builder");
  return at >= 0 && BACKGROUND_BUILDERS.has(args[at + 1] ?? "");
}

/// What is spawned for the program `binary` with `args`: under platform.backgrounded when it is background work
/// (`background`, else backgroundByDefault), so the builders scanning the database and the disk on their own yield the
/// CPU and the disk to the station's foreground and the agents'; as it is otherwise.
export function mbSpawned(binary: string, args: string[], options: { background?: boolean } = {}): [string, string[]] {
  return (options.background ?? backgroundByDefault(args)) ? platform.backgrounded(binary, args) : [binary, args];
}

/// The most of what is written to a program's stdin that it has not read yet, which Node keeps: a program that stopped
/// reading (stuck in a query, hung) past it is ended, its users told by its exit (a reader started again, a read
/// failed), not let grow the station's memory with every ask given it meanwhile. The program's own queue of stdin is
/// bounded too (mb/src/host/host.c STDIN_MOST): past it the rest waits in the pipe, then here.
export const STDIN_MOST = 64 * 1024 * 1024;
/// Unread past this, it is said once (and not ended): from then to STDIN_MOST, what it read of what it was given tells
/// whether it stopped reading (next to nothing) or is given more than it reads.
export const STDIN_BEHIND = 8 * 1024 * 1024;

/// A program's process that runs, as the station's watch over its own memory counts them (ops/self-memory.ts).
export type LiveProgram = { pid: number; binary: string; args: readonly string[]; background: boolean; startedAt: number; engine?: TelemetryEngine; mode?: string };

/// The program's process, a line of JSON each way: told its lines as "message"s, its end as "exit".
export class MbProcess extends EventEmitter {
  /// Every program's process this station runs, until its end.
  static readonly #live = new Map<MbProcess, LiveProgram>();
  /// Those running now, by their pids, arguments and since when.
  static live(): ReadonlyArray<LiveProgram> { return [...MbProcess.#live.values()]; }

  readonly engine: TelemetryEngine;
  readonly mode: string;
  readonly #child: ChildProcess;

  get pid(): number | null {
    return this.#child.pid ?? null;
  }
  readonly #args: readonly string[];
  readonly #stdinMost: number;
  readonly #wrapped: boolean;
  readonly #spawnFallbackMode: string | undefined;
  readonly #breaker: PionBreakerContext | null;
  #spawned = false;
  #pendingWrappedSpawn = false;
  #pendingStderrCount = 0;
  #sawStdout = false;
  readonly #wrapperStderr: string[] = [];
  #exited = false;
  #stalled = false;
  #intentionalStop = false;
  /// All written to its stdin, and where it stood when it was last found behind (STDIN_BEHIND, `postLine`).
  #written = 0;
  #behind: { at: number; written: number; unread: number } | null = null;

  #commitWrappedSpawn(): void {
    if (!this.#pendingWrappedSpawn) return;
    this.#pendingWrappedSpawn = false;
    this.#wrapperStderr.length = 0;
    readerTelemetry.recordSpawn(this.engine, this.mode);
    if (this.#spawnFallbackMode !== undefined) readerTelemetry.recordFallback(this.#spawnFallbackMode);
    for (let i = 0; i < this.#pendingStderrCount; i++) {
      readerTelemetry.recordStderr(this.engine, this.mode);
    }
    this.#pendingStderrCount = 0;
  }

  /// `options.background`: whether it runs as the system's background work (mbSpawned), else as its args say;
  /// `stdinMost`: STDIN_MOST but in tests; `engine`/`mode`: explicit telemetry identity when known at spawn;
  /// `fallbackMode`: when set, records one fallback once the OS child actually emits `"spawn"` (for wrapped
  /// background spawns, deferred until target execution is confirmed).
  constructor(binary: string, args: string[], options: { background?: boolean; stdinMost?: number; engine?: TelemetryEngine; mode?: string; fallbackMode?: string; breaker?: PionBreakerContext } = {}) {
    super();
    const identity = classifyProgram(binary, args);
    this.engine = options.engine ?? (isKnownPionBinary(binary) ? "pion" : identity.engine);
    this.mode = options.mode ?? identity.mode;
    this.#breaker = options.breaker ?? null;
    const background = options.background ?? backgroundByDefault(args);
    const [command, given] = mbSpawned(binary, args, { background });
    this.#wrapped = command !== binary;
    this.#spawnFallbackMode = options.fallbackMode;
    this.#args = args;
    this.#stdinMost = options.stdinMost ?? STDIN_MOST;
    this.#child = spawn(command, given, { stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
    // Its failure to start (ENFILE, EMFILE, ENOENT) is told on the next tick, with no pid and none of its streams: heard
    // before anything here could throw, else told to none and the station's process ends (D80).
    this.#child.on("error", (error) => {
      const code = (error as NodeJS.ErrnoException | null)?.code;
      if (code === "ENOENT" || code === "EACCES") {
        if (this.engine === "pion") invalidatePionBinaryCache();
        else invalidateMbReaderBinaryCache();
      }
      if (this.#child.pid === undefined) MbProcess.#live.delete(this);
      this.emit("error", error);
    });
    // Its end once its output is read whole (`close`: after `exit` and its streams' ends): what it said last, then that it
    // ended. On `exit` a line it wrote just before could still be on its way, its answer taken for none.
    this.#child.on("close", (code, signal) => {
      this.#exited = true;
      MbProcess.#live.delete(this);
      if (
        this.#spawned &&
        this.#wrapped &&
        this.#pendingWrappedSpawn &&
        !this.#sawStdout &&
        !this.#intentionalStop &&
        isBackgroundWrapperExecFailure(command, code, signal, this.#wrapperStderr)
      ) {
        if (this.engine === "pion") invalidatePionBinaryCache();
        else invalidateMbReaderBinaryCache();
        this.#pendingWrappedSpawn = false;
        this.#pendingStderrCount = 0;
        this.#wrapperStderr.length = 0;
      } else {
        if (this.#wrapped && (code === 127 || code === 126 || code === 66)) {
          if (this.engine === "pion") invalidatePionBinaryCache();
          else invalidateMbReaderBinaryCache();
        }
        this.#commitWrappedSpawn();
        if (this.#spawned && !this.#intentionalStop && !this.#stalled && (code !== 0 || signal !== null)) {
          readerTelemetry.recordUnexpectedExit(this.engine, this.mode);
          if (this.#breaker !== null) {
            this.#breaker.breaker.recordUnexpectedExit(this.#breaker.mode, this.#breaker.stamp, this.#breaker.source, wall.now());
          }
        }
      }
      this.emit("exit", code ?? (signal !== null ? 1 : 0));
    });
    this.#child.once("spawn", () => {
      this.#spawned = true;
      if (this.#wrapped) {
        this.#pendingWrappedSpawn = true;
      } else {
        readerTelemetry.recordSpawn(this.engine, this.mode);
        if (this.#spawnFallbackMode !== undefined) readerTelemetry.recordFallback(this.#spawnFallbackMode);
      }
    });
    if (this.#child.pid !== undefined) MbProcess.#live.set(this, { pid: this.#child.pid, binary, args, background, startedAt: wall.now(), engine: this.engine, mode: this.mode });
    const said = new Said((answer) => this.emit("message", answer));
    this.#child.stdout?.on("data", (bytes: Buffer) => {
      if (bytes.length > 0 && !this.#sawStdout) {
        this.#sawStdout = true;
        this.#wrapperStderr.length = 0;
        this.#commitWrappedSpawn();
      }
      said.push(bytes);
    });
    if (this.#child.stderr) createInterface({ input: this.#child.stderr }).on("line", (line) => {
      if (this.#wrapped && this.#pendingWrappedSpawn && !this.#sawStdout && isBackgroundWrapperStderrLine(command, line)) {
        this.#pendingStderrCount++;
        if (this.#wrapperStderr.length < 8) this.#wrapperStderr.push(line);
      } else {
        this.#commitWrappedSpawn();
        readerTelemetry.recordStderr(this.engine, this.mode);
      }
      log.warn("readers", "a MoonBit reader said", { line, engine: this.engine, mode: this.mode });
    });
    // (a failed write is the process gone, told by its exit)
    this.#child.stdin?.on("error", () => {});
    // All it was given read, with nothing written meanwhile: no longer behind (else the next time it is would be told
    // from where it stood before).
    this.#child.stdin?.on("drain", () => void (this.#behind = null));
  }

  /// (a bigint said as its digits)
  /// One that has left more than its `stdinMost` unread is ended (STDIN_MOST), what is posted after dropped.
  postMessage(message: unknown) {
    if (this.#stalled || this.#exited) return;
    this.postLine(JSON.stringify(message, (_, v) => typeof v === "bigint" ? v.toString() : v));
  }

  /// Write an already-serialized JSON line to stdin, sharing `postMessage`'s backpressure and `SIGKILL` guard.
  postLine(line: string) {
    if (this.#stalled || this.#exited) return;
    // (none: it never started, its end told on the next tick)
    const stdin = this.#child.stdin;
    if (!stdin) return;
    stdin.write(`${line}\n`);
    this.#written += line.length + 1;
    const unread = stdin.writableLength;
    if (unread > STDIN_BEHIND && this.#behind === null) {
      this.#behind = { at: wall.now(), written: this.#written, unread };
      log.warn("readers", "a MoonBit program is behind what it is asked", { engine: this.engine, mode: this.mode, args: this.#args.slice(0, 6), pid: this.#child.pid ?? null, unreadBytes: unread });
    } else if (unread <= STDIN_BEHIND / 2) this.#behind = null;
    if (unread <= this.#stdinMost) return;
    this.#stalled = true;
    readerTelemetry.recordStall(this.engine, this.mode);
    // Since it was found behind: how long, and what it read of what it was given (next to nothing, it stopped reading).
    const behind = this.#behind;
    const since = behind === null ? {} : { behindMs: wall.now() - behind.at, readBytes: this.#written - behind.written - (unread - behind.unread) };
    log.error("readers", "a MoonBit program stopped reading what it is asked; ending it", { engine: this.engine, mode: this.mode, args: this.#args.slice(0, 6), pid: this.#child.pid ?? null, unreadBytes: unread, ...since });
    this.#child.kill("SIGKILL");
  }

  /// Whether the station's process waits on it to end: not for one that lives as long as what uses it, while that has
  /// nothing asked of it.
  ref(on: boolean) {
    if (on) this.#child.ref();
    else this.#child.unref();
    for (const stream of [this.#child.stdin, this.#child.stdout, this.#child.stderr]) {
      const s = stream as unknown as { ref?(): void; unref?(): void } | null;
      if (on) s?.ref?.();
      else s?.unref?.();
    }
  }

  /// Ends it now, not waiting for its end (the station's process is ending).
  kill() {
    this.#intentionalStop = true;
    if (!this.#exited) this.#child.kill("SIGKILL");
  }

  terminate(): Promise<number> {
    this.#intentionalStop = true;
    if (this.#exited) return Promise.resolve(this.#child.exitCode ?? 1);
    this.ref(true);
    return new Promise((resolve) => {
      this.#child.once("close", (code) => {
        this.ref(false);
        resolve(code ?? 1);
      });
      this.#child.kill();
    });
  }

  /// No JS heap: the memory log counts V8's; its resident memory is counted from MbProcess.live (ops/self-memory.ts).
  getHeapStatistics(): Promise<{ used_heap_size: number }> {
    return Promise.resolve({ used_heap_size: 0 });
  }
}

/// The reader, started on the station's data directory `data`.
/// Captures the one-shot `ready` handshake at spawn so both `ReaderPool` and direct callers (`OwnReader`) record
/// cold-start latency without double-counting.
export class MbReader extends MbProcess implements ReaderLike {
  constructor(binary: string, data: string, options?: { engine?: TelemetryEngine; fallbackMode?: string; breaker?: PionBreakerContext }) {
    super(binary, ["--data", data, "--sep", sep], options);
    const startedAt = wall.now();
    let readyRecorded = false;
    this.on("message", (msg: unknown) => {
      if (readyRecorded || msg === null || typeof msg !== "object" || !("ready" in msg)) return;
      readyRecorded = true;
      const ready = (msg as { ready?: unknown }).ready;
      const r = ready !== null && typeof ready === "object" ? (ready as Record<string, unknown>) : null;
      const loadedMs = typeof r?.loadedMs === "number" && Number.isFinite(r.loadedMs) ? r.loadedMs : undefined;
      const openedMs = typeof r?.openedMs === "number" && Number.isFinite(r.openedMs) ? r.openedMs : undefined;
      readerTelemetry.recordReady(this.engine, this.mode, wall.now() - startedAt, loadedMs, openedMs);
    });
  }
  override postMessage(ask: Ask) { super.postMessage(ask); }
}

/// What stands for a MoonBit backfill in the permit: never a thread's.
let nextOwner = 0x60000000;

export type MbBackfillSelection = {
  readonly mode: ReaderMode;
  readonly options: ResolveReaderSelectionOptions;
};

/// A backfill the station drives itself, by the MoonBit/Pion builder `args`: each message asks for a batch, answered
/// `{done, error?}` (`threadId`: its owner in the permit, which its user releases on its exit). It knows nothing of the backfill permit,
/// which this takes for each batch and gives back when it is answered; a batch the permit is not had for, and one that
/// did not finish everything, are answered after a pause (`pauseMs`).
export class MbBackfill extends EventEmitter {
  readonly threadId = nextOwner++;
  #process: MbProcess | null = null;
  readonly #args: string[];
  readonly #priority: Int32Array | null;
  readonly #pauseMs: number;
  #holding = false;
  #exited = false;
  #askedAt = 0;
  #pendingMessages: unknown[] = [];
  #probeAbort: AbortController | null = null;

  constructor(binary: string | ResolvedReaderSelection | MbBackfillSelection, args: string[], priority: SharedArrayBuffer | undefined, pauseMs: number) {
    super();
    this.#args = args;
    this.#priority = priority instanceof SharedArrayBuffer ? new Int32Array(priority) : null;
    this.#pauseMs = pauseMs;
    if (typeof binary === "object" && "mode" in binary && "options" in binary) {
      const sync = resolveReaderSelectionOrPending(binary.mode, binary.options);
      if (!sync.pending) {
        this.#spawn(sync);
      } else {
        const abort = new AbortController();
        this.#probeAbort = abort;
        resolveReaderSelectionAsync(binary.mode, binary.options, abort.signal).then((resolved) => {
          if (this.#probeAbort === abort) this.#probeAbort = null;
          if (this.#exited) return;
          this.#spawn(resolved);
          const queued = this.#pendingMessages.splice(0);
          for (const msg of queued) {
            this.#process?.postMessage(msg);
          }
        }).catch((error: unknown) => {
          if (this.#probeAbort === abort) this.#probeAbort = null;
          if (this.#exited) return;
          this.#pendingMessages.length = 0;
          this.#give();
          this.#exited = true;
          if (this.#process !== null) {
            const proc = this.#process;
            this.#process = null;
            proc.kill();
          }
          const err = error instanceof Error ? error : new Error(String(error));
          if (this.listenerCount("error") > 0) this.emit("error", err);
          else log.warn("readers", "backfill process failed to start after probe", { mode: binary.mode, error: err.message });
          this.emit("exit", 1);
        });
      }
    } else {
      this.#spawn(binary);
    }
  }

  #spawn(binary: string | ResolvedReaderSelection) {
    // (a backfill is the station's own, nobody waiting on it: the system's background work, whatever its kind)
    const bin = typeof binary === "string" ? binary : binary.primaryBinary;
    const opts = typeof binary === "string"
      ? { background: true }
      : { background: true, engine: engineOfSelection(binary), fallbackMode: fallbackModeOf(binary.selection), breaker: breakerOfSelection(binary) };
    const proc = new MbProcess(bin, this.#args, opts);
    this.#process = proc;
    proc.on("message", (result: { done: boolean; error?: string }) => {
      if (this.#askedAt > 0) {
        readerTelemetry.recordCall(proc.engine, proc.mode, wall.now() - this.#askedAt, !result.error);
        this.#askedAt = 0;
      }
      this.#give();
      if (!result.done && !result.error) this.#later(result);
      else this.emit("message", result);
    });
    proc.on("error", (error) => {
      if (this.listenerCount("error") > 0) this.emit("error", error);
      else log.warn("readers", "backfill process error", { engine: proc.engine, mode: proc.mode, error: error.message });
    });
    proc.on("exit", (code) => {
      if (this.#askedAt > 0) {
        readerTelemetry.recordCall(proc.engine, proc.mode, wall.now() - this.#askedAt, false);
        this.#askedAt = 0;
      }
      this.#give();
      if (this.#exited) return;
      this.#exited = true;
      this.emit("exit", code);
    });
  }

  #give() {
    if (this.#holding) { this.#holding = false; giveBackfill(this.#priority, this.threadId); }
  }

  #later(result: { done: boolean }) {
    wall.after(this.#pauseMs, () => { if (!this.#exited) this.emit("message", result); });
  }

  postMessage(message: unknown) {
    // (one ended gives back nothing it took after: its end, which gives it back, is behind it)
    if (this.#exited) return;
    if (!takeBackfill(this.#priority, this.threadId)) return void this.#later({ done: false });
    this.#holding = true;
    this.#askedAt = wall.now();
    if (this.#process === null) {
      this.#pendingMessages.push(message);
      return;
    }
    this.#process.postMessage(message);
  }

  /// (a process keeps the station's event loop no more than the backfill it is)
  unref() {}

  terminate(): Promise<number> {
    if (this.#probeAbort !== null) {
      const abort = this.#probeAbort;
      this.#probeAbort = null;
      this.#exited = true;
      this.#pendingMessages.length = 0;
      this.#give();
      abort.abort();
      this.emit("exit", 0);
      return Promise.resolve(0);
    }
    return this.#process !== null ? this.#process.terminate() : Promise.resolve(0);
  }
}
