// What a test's call made the station's main thread wait on: node:fs's and node:child_process's synchronous calls
// (src/ops/file-waits.ts) and node:zlib's (inflateSync of a PDF's stream or a PNG: a few MB took the thread). Each is
// put down by who made it; none is what station/AGENTS.md asks (the main thread waits on nothing).
import { syncBuiltinESMExports } from "node:module";
import zlib from "node:zlib";
import { timeFiles, timeProcesses } from "../src/ops/file-waits.ts";
import { WAITED_MS } from "../src/ops/waits.ts";

/// The synchronous calls `f` made while it ran, as `<module>.<call> <who>`.
export async function syncCalls(f: () => Promise<void>): Promise<string[]> {
  // (each call taken as long enough to be put down with who made it, however fast this machine's disk is)
  let at = 0;
  const files = timeFiles(() => (at += WAITED_MS));
  const processes = timeProcesses(() => (at += WAITED_MS));
  const inflated: string[] = [];
  const target = zlib as unknown as Record<string, unknown>;
  const kept = new Map<string, unknown>();
  for (const name of Object.keys(target)) {
    const original = target[name];
    if (!name.endsWith("Sync") || typeof original !== "function") continue;
    kept.set(name, original);
    target[name] = function (this: unknown, ...args: unknown[]) {
      inflated.push(`zlib.${name} ${new Error().stack?.split("\n")[2]?.trim() ?? ""}`);
      return (original as (...a: unknown[]) => unknown).apply(this, args);
    };
  }
  syncBuiltinESMExports();
  try {
    await f();
    const [byFile, byProcess] = [files.take(), processes.take()];
    return [...[...byFile.by].map(([k, w]) => `fs.${k} ×${w.calls}`), ...[...byProcess.by].map(([k, w]) => `child_process.${k} ×${w.calls}`), ...inflated];
  } finally {
    files.stop();
    processes.stop();
    for (const [name, original] of kept) target[name] = original;
    syncBuiltinESMExports();
  }
}
