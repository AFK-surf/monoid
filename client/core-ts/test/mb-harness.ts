// Line-delimited JSON-RPC client for the MoonBit test harness (`stillfail-reader-harness`, `--builder harness-*`).
// Zero `station/` imports: resolves the binary from STILLFAIL_MB_HARNESS or station/mb/_build/ and fails loudly if absent.
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { onFlush } from "../src/testing.ts";

const HOST_TARGET: Record<string, string> = {
  "darwin-arm64": "darwin-arm64",
  "linux-x64": "linux-x64",
  "linux-arm64": "linux-arm64",
  "win32-x64": "win32-x64.exe",
};

export function harnessBinary(): string {
  const fromEnv = process.env.STILLFAIL_MB_HARNESS;
  if (fromEnv && existsSync(fromEnv)) return fromEnv;
  const suffix = HOST_TARGET[`${process.platform}-${process.arch}`];
  const local = suffix
    ? fileURLToPath(new URL(`../../../station/mb/_build/stillfail-reader-harness-${suffix}`, import.meta.url))
    : undefined;
  if (local && existsSync(local)) return local;
  throw new Error(
    "stillfail-reader-harness binary not found; build it with `bash station/mb/build.sh --harness` or run via `node scripts/native.ts run reader-harness -- ...`",
  );
}

export interface HarnessClient {
  call<T = any>(op: string, params?: Record<string, unknown>): Promise<T>;
  close(): Promise<void>;
}

export function startHarness(builder: string): HarnessClient {
  const binary = harnessBinary();
  const shellDir = mkdtempSync(join(tmpdir(), "core-mb-harness-"));
  const child = spawn(binary, ["--builder", builder, "--shell-dir", shellDir], {
    stdio: ["pipe", "pipe", "pipe"],
  });

  let nextId = 1;
  let closed = false;
  let stderr = "";
  const pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void; done: Promise<void> }>();

  const failAll = (reason: string) => {
    const err = new Error(stderr.trim() ? `${reason}\nstderr:\n${stderr.trim()}` : reason);
    for (const p of pending.values()) p.reject(err);
    pending.clear();
  };

  const offFlush = onFlush(() => {
    if (pending.size === 0) return Promise.resolve(false);
    // Snapshot only currently in-flight RPCs so self-retriggering fibers cannot starve `flush()`.
    const inflight = [...pending.values()].map((p) => p.done);
    return Promise.all(inflight).then(() => true);
  });

  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk: string) => {
    if (stderr.length < 32_768) stderr += chunk;
  });

  const rl = createInterface({ input: child.stdout, crlfDelay: Infinity });
  rl.on("line", (line) => {
    if (!line) return;
    let msg: { id?: number; ok?: unknown; error?: string };
    try {
      msg = JSON.parse(line);
    } catch (e) {
      failAll(`harness (${builder}) emitted non-JSON line: ${line} (${e})`);
      return;
    }
    if (typeof msg.id !== "number") return;
    const slot = pending.get(msg.id);
    if (!slot) return;
    pending.delete(msg.id);
    if (typeof msg.error === "string") slot.reject(new Error(msg.error));
    else slot.resolve(msg.ok);
  });

  const exitPromise = new Promise<void>((resolve) => {
    child.on("error", (err) => {
      failAll(`harness (${builder}) spawn error: ${err.message}`);
      resolve();
    });
    child.on("close", (code, signal) => {
      if (pending.size > 0) {
        failAll(`harness (${builder}) exited unexpectedly (code=${code}, signal=${signal})`);
      }
      resolve();
    });
  });

  return {
    call<T = any>(op: string, params: Record<string, unknown> = {}): Promise<T> {
      if (closed) return Promise.reject(new Error(`harness (${builder}) already closed`));
      if (child.exitCode !== null || child.signalCode !== null) {
        return Promise.reject(
          new Error(
            `harness (${builder}) already exited (code=${child.exitCode}, signal=${child.signalCode})${stderr.trim() ? `\nstderr:\n${stderr.trim()}` : ""}`,
          ),
        );
      }
      const id = nextId++;
      let finish!: () => void;
      const done = new Promise<void>((r) => { finish = r; });
      return new Promise<T>((resolve, reject) => {
        pending.set(id, {
          resolve: (v) => { finish(); resolve(v); },
          reject: (e) => { finish(); reject(e); },
          done,
        });
        child.stdin.write(`${JSON.stringify({ ...params, id, op })}\n`, (err) => {
          if (err) {
            pending.delete(id);
            finish();
            reject(err);
          }
        });
      });
    },
    async close(): Promise<void> {
      if (closed) return;
      closed = true;
      offFlush();
      failAll(`harness (${builder}) closed`);
      try {
        rl.close();
        if (!child.stdin.destroyed) child.stdin.end();
        await exitPromise;
      } finally {
        rmSync(shellDir, { recursive: true, force: true });
      }
    },
  };
}
