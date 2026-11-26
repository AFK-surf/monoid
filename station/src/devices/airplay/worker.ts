// Lazy single-process NDJSON JSON-RPC adapter for station/assets/devices/airplay-worker.py.
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { fileURLToPath } from "node:url";
import { wall } from "../../ops/fibers.ts";
import { log } from "../../ops/log.ts";
import { detectAirPlayEnv, installAirPlayEnv } from "./install.ts";
import {
  AirPlayError,
  type AirPlayAdapter,
  type AirPlayCandidate,
  type AirPlayControlAction,
  type AirPlayCredentials,
  type AirPlayEnvStatus,
  type AirPlayPairFinishResult,
  type AirPlayPairStartResult,
  type AirPlayProtocol,
} from "./types.ts";

const IDLE_MS = 5 * 60_000;
const RPC_TIMEOUT_MS = 30_000;
const STREAM_AUDIO_TIMEOUT_MS = 10 * 60_000;

/// Beside the source in development, beside the station's main.js in its release.
export function airplayWorkerScript(): string {
  return fileURLToPath(import.meta.url.endsWith(".ts") ? new URL("../../../assets/devices/airplay-worker.py", import.meta.url) : new URL("./airplay-worker.py", import.meta.url));
}

type Pending = {
  resolve: (value: unknown) => void;
  reject: (err: Error) => void;
  stopTimeout: () => void;
};

export type PyAtvAdapterOptions = {
  dataDir: string;
  python?: string;
  script?: string;
  idleMs?: number;
  env?: NodeJS.ProcessEnv;
  detectEnv?: (dataDir: string) => Promise<AirPlayEnvStatus>;
};

export class PyAtvAdapter implements AirPlayAdapter {
  readonly #dataDir: string;
  readonly #overridePython: string | null;
  readonly #script: string;
  readonly #idleMs: number;
  readonly #env: NodeJS.ProcessEnv | undefined;
  readonly #detectEnv: (dataDir: string) => Promise<AirPlayEnvStatus>;
  #child: ChildProcessWithoutNullStreams | null = null;
  #starting: Promise<ChildProcessWithoutNullStreams> | null = null;
  #generation = 0;
  #buffer = "";
  #nextId = 1;
  #pending = new Map<number, Pending>();
  #activePairings = 0;
  #stopIdle: (() => void) | null = null;
  #closed = false;

  constructor(opts: PyAtvAdapterOptions) {
    this.#dataDir = opts.dataDir;
    this.#overridePython = opts.python ?? null;
    this.#script = opts.script ?? airplayWorkerScript();
    this.#idleMs = opts.idleMs ?? IDLE_MS;
    this.#env = opts.env;
    this.#detectEnv = opts.detectEnv ?? detectAirPlayEnv;
  }

  async envStatus(): Promise<AirPlayEnvStatus> {
    if (this.#overridePython !== null) {
      try {
        const res = await this.#call<{ ok: boolean; pyatvVersion: string }>("ping", {}, RPC_TIMEOUT_MS);
        return { ready: res.ok === true, python: this.#overridePython, pyatvVersion: res.pyatvVersion ?? null };
      } catch (err) {
        return {
          ready: false,
          python: this.#overridePython,
          pyatvVersion: null,
          error: (err as Error).message,
        };
      }
    }
    return this.#detectEnv(this.#dataDir);
  }

  async installEnv(): Promise<{ ok: true; pyatvVersion: string; python: string }> {
    await this.#stopChild();
    return installAirPlayEnv(this.#dataDir);
  }

  async scan(opts?: { timeoutMs?: number; host?: string }): Promise<AirPlayCandidate[]> {
    const timeoutMs = opts?.timeoutMs ?? 4000;
    return this.#call<AirPlayCandidate[]>(
      "scan",
      { timeoutMs, ...(opts?.host ? { host: opts.host } : {}) },
      Math.max(RPC_TIMEOUT_MS, timeoutMs + 10_000),
    );
  }

  async pairStart(params: { identifier: string; address?: string; protocol: AirPlayProtocol }): Promise<AirPlayPairStartResult> {
    const res = await this.#call<AirPlayPairStartResult>("pair_start", params, RPC_TIMEOUT_MS);
    this.#activePairings++;
    this.#cancelIdle();
    return res;
  }

  async pairFinish(params: { pairToken: string; pin?: string }): Promise<AirPlayPairFinishResult> {
    try {
      return await this.#call<AirPlayPairFinishResult>("pair_finish", params, RPC_TIMEOUT_MS);
    } finally {
      this.#activePairings = Math.max(0, this.#activePairings - 1);
      this.#scheduleIdle();
    }
  }

  async pairCancel(params: { pairToken: string }): Promise<void> {
    try {
      await this.#call("pair_cancel", params, RPC_TIMEOUT_MS);
    } finally {
      this.#activePairings = Math.max(0, this.#activePairings - 1);
      this.#scheduleIdle();
    }
  }

  async control(params: {
    identifier: string;
    address?: string;
    credentials?: AirPlayCredentials;
    action: AirPlayControlAction;
    args?: Record<string, unknown>;
  }): Promise<unknown> {
    const timeoutMs = params.action === "stream_audio" ? STREAM_AUDIO_TIMEOUT_MS : RPC_TIMEOUT_MS;
    return this.#call("control", params, timeoutMs);
  }

  async close(): Promise<void> {
    this.#closed = true;
    await this.#stopChild();
  }

  #cancelIdle(): void {
    this.#stopIdle?.();
    this.#stopIdle = null;
  }

  #scheduleIdle(): void {
    this.#cancelIdle();
    if (this.#closed || this.#child === null || this.#pending.size > 0 || this.#activePairings > 0) return;
    // timer: shut down idle airplay worker subprocess after inactivity
    this.#stopIdle = wall.after(this.#idleMs, () => {
      this.#stopIdle = null;
      if (this.#pending.size === 0 && this.#activePairings === 0) {
        void this.#stopChild();
      }
    });
  }

  async #ensureChild(): Promise<ChildProcessWithoutNullStreams> {
    if (this.#closed) throw new AirPlayError("worker_closed", "AirPlay worker is closed");
    if (this.#child !== null && !this.#child.killed && this.#child.exitCode === null) {
      return this.#child;
    }
    if (this.#starting !== null) {
      return this.#starting;
    }
    const gen = this.#generation;
    const start = (async (): Promise<ChildProcessWithoutNullStreams> => {
      let python = this.#overridePython;
      if (python === null) {
        const env = await this.#detectEnv(this.#dataDir);
        if (!env.ready || env.python === null) {
          throw new AirPlayError("pyatv_missing", env.error ?? "pyatv is not installed on this station");
        }
        python = env.python;
      }
      if (this.#closed || this.#generation !== gen) {
        throw new AirPlayError("worker_stopped", "airplay worker stopped during startup");
      }
      const child = spawn(python, ["-u", this.#script], {
        stdio: ["pipe", "pipe", "pipe"],
        ...(this.#env ? { env: this.#env } : {}),
      });
      if (this.#closed || this.#generation !== gen) {
        try { child.stdin.end(); } catch {}
        try { child.kill("SIGTERM"); } catch {}
        throw new AirPlayError("worker_stopped", "airplay worker stopped during startup");
      }
      this.#child = child;
      this.#buffer = "";
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (chunk: string) => this.#onData(chunk));
      child.stderr.on("data", (chunk: Buffer) => {
        const msg = chunk.toString("utf8").trim();
        if (msg) log.warn("devices", "airplay worker stderr", { msg: msg.slice(0, 500) });
      });
      child.once("error", (err) => {
        this.#failAll(new AirPlayError("worker_spawn_failed", err.message));
        if (this.#child === child) this.#child = null;
      });
      child.once("exit", (code, signal) => {
        if (this.#child === child) this.#child = null;
        this.#cancelIdle();
        this.#activePairings = 0;
        this.#failAll(new AirPlayError("worker_exited", `airplay worker exited (code=${code}, signal=${signal})`));
      });
      return child;
    })().finally(() => {
      if (this.#starting === start) this.#starting = null;
    });
    this.#starting = start;
    return start;
  }

  #onData(chunk: string): void {
    this.#buffer += chunk;
    for (;;) {
      const nl = this.#buffer.indexOf("\n");
      if (nl === -1) break;
      const line = this.#buffer.slice(0, nl).trim();
      this.#buffer = this.#buffer.slice(nl + 1);
      if (!line) continue;
      let msg: { id?: unknown; ok?: boolean; result?: unknown; error?: { code?: string; message?: string } };
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      const id = typeof msg.id === "number" ? msg.id : -1;
      const p = this.#pending.get(id);
      if (p === undefined) continue;
      this.#pending.delete(id);
      p.stopTimeout();
      if (msg.ok === true) {
        p.resolve(msg.result);
      } else {
        p.reject(new AirPlayError(msg.error?.code ?? "worker_error", msg.error?.message ?? "airplay worker error"));
      }
      this.#scheduleIdle();
    }
  }

  #failAll(err: Error): void {
    for (const [, p] of this.#pending) {
      p.stopTimeout();
      p.reject(err);
    }
    this.#pending.clear();
  }

  async #call<T>(method: string, params: Record<string, unknown>, timeoutMs: number): Promise<T> {
    this.#cancelIdle();
    const child = await this.#ensureChild();
    const id = this.#nextId++;
    return new Promise<T>((resolve, reject) => {
      // timer: RPC request deadline for airplay worker call
      const stopTimeout = wall.after(timeoutMs, () => {
        if (!this.#pending.delete(id)) return;
        reject(new AirPlayError("timeout", `airplay ${method} timed out after ${Math.round(timeoutMs / 1000)}s`));
        this.#scheduleIdle();
      });
      this.#pending.set(id, {
        resolve: resolve as (v: unknown) => void,
        reject,
        stopTimeout,
      });
      const payload = `${JSON.stringify({ id, method, params })}\n`;
      child.stdin.write(payload, (err) => {
        if (err) {
          const p = this.#pending.get(id);
          if (p !== undefined) {
            this.#pending.delete(id);
            p.stopTimeout();
            p.reject(new AirPlayError("worker_write_failed", err.message));
          }
        }
      });
    });
  }

  async #stopChild(): Promise<void> {
    this.#generation++;
    this.#cancelIdle();
    const inflightStart = this.#starting;
    if (inflightStart !== null) {
      await inflightStart.catch(() => {});
    }
    const child = this.#child;
    this.#child = null;
    this.#activePairings = 0;
    this.#failAll(new AirPlayError("worker_stopped", "airplay worker stopped"));
    if (child === null) return;
    await new Promise<void>((resolve) => {
      let done = false;
      const finish = () => {
        if (done) return;
        done = true;
        stopKill();
        resolve();
      };
      // timer: force-kill airplay worker if it does not exit after stdin closes
      const stopKill = wall.after(2_000, () => {
        try {
          child.kill("SIGKILL");
        } catch {}
        finish();
      });
      child.once("exit", finish);
      try {
        child.stdin.end();
      } catch {}
      try {
        child.kill("SIGTERM");
      } catch {
        finish();
      }
    });
  }
}
