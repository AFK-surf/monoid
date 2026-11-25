import { build } from "esbuild";
import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

/**
 * The tests' three Workers (test/harness.ts), bundled as Cloudflare would run them. Every harness used to bundle all
 * three again, one after the other: some 260 harnesses in a run, each half a second of bundling on Linux (the
 * API's, most of it). A process bundles each once (`workerScripts` keeps them), and `pnpm test` (test/run.ts) bundles
 * them once for all its files, which read them from STILLFAIL_CLOUD_TEST_BUNDLES (`writeBundles`). What is bundled differs
 * only by the clock (`clock: "real"`, test/dev.ts), which the run's bundles are not made for.
 */
export const WORKERS = { static: "static-worker.ts", relay: "relay-worker.ts", api: "worker.ts" } as const;
export type WorkerScripts = Record<keyof typeof WORKERS, string>;

/**
 * still.fail cloud's time in the tests (src/auth.ts `clock`), in ms: one fixed moment, so what a test sees never
 * depends on the hour it runs at (a minute's budget turning over halfway, say). Ahead of any real one, so the alarms
 * set from it (a login limit's day, a session's end) never go off during a test.
 */
export const NOW_MS = Date.UTC(2030, 0, 1, 12, 0, 30);

/** The variable test/run.ts names its bundles' directory in. */
export const BUNDLES_ENV = "STILLFAIL_CLOUD_TEST_BUNDLES";

const bundle = async (entry: string, nowMs: number | null) => (await build({
  entryPoints: [fileURLToPath(new URL(entry, import.meta.url))],
  bundle: true,
  write: false,
  format: "esm",
  platform: "node",
  banner: {
    js: 'import { createRequire } from "node:module"; const require = createRequire("file:///worker.js");',
  },
  external: ["cloudflare:workers", "cloudflare:sockets", "node:*"],
  define: { TEST_NOW_MS: nowMs === null ? "null" : String(nowMs) },
  conditions: ["workerd", "worker", "browser"],
})).outputFiles[0].text;

const bundleAll = async (nowMs: number | null): Promise<WorkerScripts> => {
  const [stat, relay, api] = await Promise.all([bundle(WORKERS.static, nowMs), bundle(WORKERS.relay, nowMs), bundle(WORKERS.api, nowMs)]);
  return { static: stat, relay, api };
};

const fileOf = (dir: string, name: string, nowMs: number | null) => `${dir}/${name}.${nowMs ?? "real"}.js`;

/** Writes the three bundles for the tests' clock to `dir`, for test/run.ts. */
export async function writeBundles(dir: string): Promise<void> {
  const scripts = await bundleAll(NOW_MS);
  await Promise.all(Object.entries(scripts).map(([name, text]) => writeFile(fileOf(dir, name, NOW_MS), text)));
}

const kept = new Map<number | null, Promise<WorkerScripts>>();

/** The three Workers' scripts for a clock (`null`: the machine's), read from the run's bundles or bundled once here. */
export function workerScripts(nowMs: number | null): Promise<WorkerScripts> {
  let scripts = kept.get(nowMs);
  if (!scripts) {
    const dir = process.env[BUNDLES_ENV];
    scripts = dir && nowMs !== null
      ? Promise.all(Object.keys(WORKERS).map((name) => readFile(fileOf(dir, name, nowMs), "utf8"))).then(([stat, relay, api]) => ({ static: stat!, relay: relay!, api: api! }))
      : bundleAll(nowMs);
    // A failed bundle is not kept: the next harness says why again.
    scripts.catch(() => kept.delete(nowMs));
    kept.set(nowMs, scripts);
  }
  return scripts;
}
