// Local station replacement helpers (`stillfail replace`): stages validated bundle/overlay directories,
// preserves the official baseline in OVERRIDE across consecutive replacements, updates `autoUpdateWhen`
// via SIGHUP (`wait-ask` / `wait-answer`) when running or directly in config.json when stopped, and
// reconciles config after `--revert`.
import { execFile } from "node:child_process";
import { cp, lstat, mkdir, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { Effect, Latch, Option } from "effect";
import { watch } from "node:fs";
import { basename, dirname } from "node:path";
import { ConfigFile } from "../ops/config.ts";
import { flag } from "../ops/files.ts";
import { wall } from "../ops/fibers.ts";
import { stationLang, tr } from "../ops/i18n.ts";
import { platform } from "../platform/index.ts";
import {
  type AutoUpdateWhen,
  type OverrideMeta,
  type WaitCondition,
  formatWaitCondition,
  parseAutoUpdateWhen,
  parseWaitSpec,
  readOverrideSoon,
  versionBuild,
} from "./override.ts";
import { WAIT_ANSWER, WAIT_ASK, writeWhole } from "./updates.ts";
import { stationVersionSoon } from "./versions.ts";

const execFileAsync = promisify(execFile);
const configPath = (data: string) => process.env.STILLFAIL_CONFIG || join(data, "config.json");

const alive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "EPERM";
  }
};

async function readJsonOrNull(path: string): Promise<any> {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch {
    return null;
  }
}

async function exists(path: string): Promise<boolean> {
  return lstat(path).then(() => true, () => false);
}

function multiFlag(args: string[], name: string): string[] {
  const out: string[] = [];
  for (let i = 0; i < args.length - 1; i++) {
    if (args[i] === name) out.push(args[i + 1]!);
  }
  return out;
}

function answerIn(path: string, waitMs: number): Effect.Effect<Option.Option<string>> {
  const read = Effect.promise(() => readFile(path, "utf8").catch(() => null));
  return Effect.scoped(
    Effect.gen(function* () {
      const changed = Latch.makeUnsafe(false);
      yield* Effect.acquireRelease(
        Effect.sync(() => {
          try {
            const watcher = watch(dirname(path), (_, name) => {
              if (name === null || name === basename(path)) changed.openUnsafe();
            });
            watcher.on("error", () => {});
            return watcher;
          } catch {
            return null;
          }
        }),
        (watcher) => Effect.sync(() => watcher?.close()),
      );
      for (;;) {
        changed.closeUnsafe();
        const text = yield* read;
        if (text !== null) return text;
        yield* Effect.raceFirst(Effect.sleep(100), changed.await);
      }
    }),
  ).pipe(Effect.timeoutOption(waitMs));
}

async function askRunningWait(
  data: string,
  wait: WaitCondition[] | null,
  waitMs: number,
  isStation: (pid: number) => boolean | Promise<boolean> = (pid) => platform.isLauncher(pid),
): Promise<boolean> {
  const run = join(data, "run");
  const said = await readJsonOrNull(join(run, "station.json"));
  const pid = Number.isSafeInteger(said?.pid) && said.pid > 0 ? (said.pid as number) : null;
  if (pid === null || said?.channel !== 1 || !alive(pid) || !(await isStation(pid))) return false;
  await mkdir(run, { recursive: true });
  const askPath = join(run, WAIT_ASK);
  const answer = join(run, WAIT_ANSWER);
  await rm(answer, { force: true });
  await writeWhole(askPath, `${JSON.stringify({ wait })}\n`);
  try {
    await platform.askLauncher(pid, "hup");
  } catch (e) {
    await rm(askPath, { force: true });
    throw new Error(tr(stationLang(), "station.cli.signalFailed", { pid, error: (e as Error).message }));
  }
  const text = Option.getOrNull(await Effect.runPromise(answerIn(answer, waitMs)));
  if (text !== null) {
    await rm(answer, { force: true });
    const t = text.trim();
    if (t.startsWith("ok")) return true;
    throw new Error(t.startsWith("error ") ? t.slice(6) : t);
  }
  // If wait-ask is still on disk after timeout, the running station is an older release that does not
  // handle wait-ask: clean up and fall back to writing config.json directly (ConfigFile.watch hot-reloads).
  if (await exists(askPath)) {
    await rm(askPath, { force: true });
    return false;
  }
  throw new Error(tr(stationLang(), "station.cli.noAnswer"));
}

export async function setWaitConfig(
  data: string,
  wait: WaitCondition[] | null,
  opts: { waitMs?: number; isStation?: (pid: number) => boolean | Promise<boolean>; app?: string; direct?: boolean } = {},
): Promise<void> {
  if (!opts.direct) {
    const asked = await askRunningWait(data, wait, opts.waitMs ?? 2_000, opts.isStation);
    if (asked) return;
  }
  const app = opts.app ?? join(data, "app");
  const override = await readOverrideSoon(app);
  const cfg = new ConfigFile(data);
  await cfg.updateSoon((raw) => {
    const existing = parseAutoUpdateWhen(raw);
    if (wait === null) {
      if (existing === null) return;
      delete raw.autoUpdateWhen;
      if (override === null && existing.restoreAuto) raw.autoUpdate = true;
      return;
    }
    const restoreAuto = existing !== null ? existing.restoreAuto : raw.autoUpdate === true;
    const next: AutoUpdateWhen = {
      wait,
      restoreAuto,
      ...(override !== null ? { forOverride: true } : {}),
      setAt: wall.now(),
    };
    raw.autoUpdate = false;
    raw.autoUpdateWhen = next;
  });
}

async function resolveBundleDir(source: string, scratch: string): Promise<string> {
  const abs = resolve(source);
  const st = await stat(abs).catch(() => null);
  if (st === null) throw new Error(`source not found: ${abs}`);
  if (st.isDirectory()) {
    const nested = join(abs, "stillfail");
    if (await exists(join(nested, "bin")) || await exists(join(nested, "station"))) return nested;
    return abs;
  }
  await mkdir(scratch, { recursive: true });
  if (/\.(tar\.gz|tgz)$/i.test(abs)) {
    await execFileAsync("tar", ["-xzf", abs, "-C", scratch]);
  } else if (/\.zip$/i.test(abs)) {
    if (platform.os === "windows") {
      await execFileAsync("powershell", ["-NoProfile", "-Command", `Expand-Archive -Path '${abs.replaceAll("'", "''")}' -DestinationPath '${scratch.replaceAll("'", "''")}' -Force`]);
    } else {
      await execFileAsync("unzip", ["-q", abs, "-d", scratch]);
    }
  } else {
    throw new Error(`unsupported bundle format: ${abs} (expected directory, .tar.gz, .tgz, or .zip)`);
  }
  const nested = join(scratch, "stillfail");
  return (await exists(nested)) ? nested : scratch;
}

async function validateBundle(dir: string): Promise<void> {
  const hasBin = (await exists(join(dir, "bin", "stillfail"))) || (await exists(join(dir, "bin", "stillfail.ps1")));
  const hasStation =
    (await exists(join(dir, "station", "main.js"))) ||
    (await exists(join(dir, "station", "stillfail-reader"))) ||
    (await exists(join(dir, "station", "stillfail-reader.exe")));
  if (!hasBin || !hasStation) {
    throw new Error(`invalid station bundle in ${dir} (missing bin/stillfail or station runtime)`);
  }
}

export async function prepareReplace(o: {
  app: string;
  data: string;
  stage: string;
  source?: string;
  dist?: string;
  main?: string;
  reader?: string;
  note?: string;
}): Promise<OverrideMeta> {
  const isOverlay = Boolean(o.dist || o.main || o.reader);
  if (o.source && isOverlay) throw new Error("cannot combine <source> bundle with --dist/--main/--reader overlay");
  if (!o.source && !isOverlay) throw new Error("give a bundle <source> or one of --dist, --main, --reader");

  const existingOverride = await readOverrideSoon(o.app);
  let baseVersion = existingOverride?.baseVersion ?? null;
  let baseBuild = existingOverride?.baseBuild ?? null;
  let baseCommit = existingOverride?.baseCommit ?? null;
  if (existingOverride === null) {
    baseVersion = (await stationVersionSoon(o.app)) ?? null;
    baseBuild = versionBuild(baseVersion);
    baseCommit = await readFile(join(o.app, "VERSION"), "utf8").then((t) => t.trim() || null, () => null);
  }

  await rm(o.stage, { recursive: true, force: true });
  let scratch: string | null = null;
  try {
    if (o.source) {
      scratch = join(tmpdir(), `stillfail-replace-extract-${process.pid}-${wall.now()}`);
      const bundleDir = await resolveBundleDir(o.source, scratch);
      await validateBundle(bundleDir);
      await cp(bundleDir, o.stage, { recursive: true, verbatimSymlinks: true });
      // Preserve CHANNEL and node link when the replacement bundle does not carry them.
      if (!(await exists(join(o.stage, "CHANNEL"))) && (await exists(join(o.app, "CHANNEL")))) {
        await cp(join(o.app, "CHANNEL"), join(o.stage, "CHANNEL"));
      }
      if ((await exists(join(o.stage, "NODE_VERSION"))) && !(await exists(join(o.stage, "node")))) {
        const nodeVer = (await readFile(join(o.stage, "NODE_VERSION"), "utf8")).trim();
        const nodeDir = join(o.data, "node", `v${nodeVer}`);
        if (nodeVer && (await exists(nodeDir))) {
          await symlink(nodeDir, join(o.stage, "node"));
        } else if (await exists(join(o.app, "node"))) {
          await cp(join(o.app, "node"), join(o.stage, "node"), { recursive: true, verbatimSymlinks: true });
        }
      }
    } else {
      if (!(await exists(o.app))) throw new Error(`installed app not found at ${o.app}`);
      await cp(o.app, o.stage, { recursive: true, verbatimSymlinks: true });
      await mkdir(join(o.stage, "station"), { recursive: true });
      if (o.dist) {
        const absDist = resolve(o.dist);
        if (!(await exists(absDist))) throw new Error(`--dist not found: ${absDist}`);
        await cp(absDist, join(o.stage, "station"), { recursive: true, force: true });
      }
      if (o.main) {
        const absMain = resolve(o.main);
        if (!(await exists(absMain))) throw new Error(`--main not found: ${absMain}`);
        await cp(absMain, join(o.stage, "station", "main.js"), { force: true });
      }
      if (o.reader) {
        const absReader = resolve(o.reader);
        if (!(await exists(absReader))) throw new Error(`--reader not found: ${absReader}`);
        const readerName = platform.os === "windows" ? "stillfail-reader.exe" : "stillfail-reader";
        await cp(absReader, join(o.stage, "station", readerName), { force: true });
      }
      await validateBundle(o.stage);
    }

    const meta: OverrideMeta = {
      baseVersion,
      baseBuild,
      baseCommit,
      kind: isOverlay ? "overlay" : "bundle",
      replacedAt: wall.now(),
      ...(o.note && o.note.trim() !== "" ? { note: o.note.trim() } : {}),
    };
    await writeFile(join(o.stage, "OVERRIDE"), `${JSON.stringify(meta, null, 2)}\n`);
    return meta;
  } finally {
    if (scratch !== null) await rm(scratch, { recursive: true, force: true }).catch(() => {});
  }
}

export async function replaceStatusText(app: string, data: string): Promise<string> {
  const lang = stationLang();
  const say = (key: string, args?: Record<string, unknown>) => tr(lang, key, args);
  const override = await readOverrideSoon(app);
  const raw = (await readJsonOrNull(configPath(data))) ?? {};
  const when = parseAutoUpdateWhen(raw);
  const hasBackup = await exists(join(data, "app.before-replace"));
  const lines: string[] = [];
  if (override !== null) {
    lines.push(say("station.cli.status.override", { kind: override.kind, base: override.baseVersion ?? "?" }));
    if (override.note) lines.push(say("station.cli.status.overrideNote", { note: override.note }));
  } else {
    lines.push(say("station.cli.replace.none"));
  }
  if (when !== null && when.wait.length > 0) {
    lines.push(say("station.cli.status.autoWhen", { conditions: when.wait.map(formatWaitCondition).join(", ") }));
  } else if (override !== null || (when !== null && when.wait.length === 0)) {
    lines.push(say("station.cli.status.autoHeld"));
  }
  if (hasBackup) {
    lines.push(say("station.cli.replace.backup", { path: join(data, "app.before-replace") }));
  }
  return lines.join("\n");
}

export async function reconcileRevert(data: string): Promise<void> {
  const raw = (await readJsonOrNull(configPath(data))) ?? {};
  const when = parseAutoUpdateWhen(raw);
  if (when?.forOverride === true) {
    await setWaitConfig(data, null);
  }
}

export async function replaceSubcommand(args: string[], data: string): Promise<number> {
  try {
    if (args.includes("--replace-prepare")) {
      const app = flag(args, "--app") ?? join(data, "app");
      const stage = flag(args, "--stage");
      if (!stage) return 2;
      const meta = await prepareReplace({
        app,
        data,
        stage,
        source: flag(args, "--source"),
        dist: flag(args, "--dist"),
        main: flag(args, "--main"),
        reader: flag(args, "--reader"),
        note: flag(args, "--note"),
      });
      console.log(`kind=${meta.kind}`);
      if (meta.baseVersion) console.log(`baseVersion=${meta.baseVersion}`);
      return 0;
    }
    if (args.includes("--replace-wait")) {
      const clear = args.includes("--clear");
      const hold = args.includes("--hold");
      const direct = args.includes("--direct");
      const app = flag(args, "--app");
      const specs = multiFlag(args, "--until");
      if (clear && (specs.length > 0 || hold)) {
        throw new Error("--clear cannot be combined with --until or --hold");
      }
      if (clear) {
        await setWaitConfig(data, null, { direct, app });
      } else if (specs.length > 0) {
        await setWaitConfig(data, specs.map(parseWaitSpec), { direct, app });
      } else if (hold) {
        await setWaitConfig(data, [], { direct, app });
      } else {
        return 2;
      }
      return 0;
    }
    if (args.includes("--replace-status")) {
      const app = flag(args, "--app") ?? join(data, "app");
      console.log(await replaceStatusText(app, data));
      return 0;
    }
    if (args.includes("--replace-reconcile-revert")) {
      await reconcileRevert(data);
      return 0;
    }
    return 2;
  } catch (e) {
    console.error(`Error: ${(e as Error).message}`);
    return 1;
  }
}
