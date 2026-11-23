import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { allowed, keyId, type Release, type ReleaseIncludedRef } from "../../shared/release-signed.ts";
import { ConfigFile } from "../src/ops/config.ts";
import {
  conditionsMet,
  formatWaitCondition,
  needsIncluded,
  parseWaitSpec,
  readOverrideSoon,
  type ReleaseIncluded,
} from "../src/updates/override.ts";
import { Updates } from "../src/updates/updates.ts";
import { versionTools } from "../src/tools/version.ts";
import { routes as updateRoutes } from "../src/api/routes/updates.ts";
import { status as cliStatus } from "../src/cli.ts";
import { platform } from "../src/updates/versions.ts";
import { prepareReplace, setWaitConfig } from "../src/updates/replace.ts";

function makeKey() {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const raw = Buffer.from(publicKey.export({ format: "jwk" }).x as string, "base64url").toString("base64");
  const id = keyId(raw);
  const trusted = new Map([[id, raw]]);
  const signFeed = (words: Release, extra: Record<string, unknown> = {}) => {
    const bytes = Buffer.from(JSON.stringify(words));
    return {
      version: words.version,
      release: bytes.toString("base64"),
      signature: sign(null, bytes, privateKey).toString("base64"),
      key: id,
      ...extra,
    };
  };
  return { trusted, signFeed };
}

function makeIncluded(manifest: ReleaseIncluded): { ref: ReleaseIncludedRef; bytes: Buffer } {
  const bytes = Buffer.from(`${JSON.stringify(manifest)}\n`, "utf8");
  const sha256 = createHash("sha256").update(bytes).digest("hex");
  return {
    ref: { file: `station/included/${manifest.build}-${sha256.slice(0, 16)}.json`, sha256, size: bytes.length },
    bytes,
  };
}

test("override.ts: parseWaitSpec, formatWaitCondition, needsIncluded, and multi-condition AND matching", () => {
  assert.deepEqual(parseWaitSpec("pr:8270"), { kind: "pr", value: 8270 });
  assert.deepEqual(parseWaitSpec("#8270"), { kind: "pr", value: 8270 });
  assert.deepEqual(parseWaitSpec("fix:FB-123"), { kind: "fix", value: 123 });
  assert.deepEqual(parseWaitSpec("FB-123"), { kind: "fix", value: 123 });
  assert.deepEqual(parseWaitSpec("commit:ABCDEF123456"), { kind: "commit", value: "abcdef123456" });
  assert.deepEqual(parseWaitSpec("version:0.1.11125"), { kind: "version", value: "0.1.11125" });
  assert.deepEqual(parseWaitSpec("0.1.11125"), { kind: "version", value: "0.1.11125" });
  assert.deepEqual(parseWaitSpec("after:0.1.10884"), { kind: "after", value: "0.1.10884" });
  assert.throws(() => parseWaitSpec("bogus"));
  assert.throws(() => parseWaitSpec("commit:123456")); // too short

  assert.equal(formatWaitCondition({ kind: "pr", value: 8270 }), "#8270");
  assert.equal(formatWaitCondition({ kind: "fix", value: 123 }), "FB-123");
  assert.equal(formatWaitCondition({ kind: "commit", value: "abcdef1234567890" }), "commit abcdef123456");
  assert.equal(formatWaitCondition({ kind: "version", value: "0.1.11125" }), ">= 0.1.11125");
  assert.equal(formatWaitCondition({ kind: "after", value: "0.1.10884" }), "> 0.1.10884");

  assert.equal(needsIncluded([{ kind: "version", value: "0.1.100" }, { kind: "after", value: "0.1.99" }]), false);
  assert.equal(needsIncluded([{ kind: "pr", value: 8270 }]), true);
  assert.equal(needsIncluded([{ kind: "fix", value: 123 }]), true);
  assert.equal(needsIncluded([{ kind: "commit", value: "abcdef1" }]), true);

  const rel: Release = {
    kind: "stillfail-station-release",
    version: "0.1.11130",
    build: 11130,
    commit: "deadbeef1234567890abcdef1234567890abcdef",
    node: "",
    builds: {},
  };
  const inc: ReleaseIncluded = {
    build: 11130,
    commit: rel.commit,
    baseBuild: 11125,
    baseCommit: "1111111111111111111111111111111111111111",
    windowFromBuild: 8131,
    prs: [8270, 8271],
    fixes: [123],
    commits: ["deadbeef1234", "abcdef123456"],
  };

  // Empty wait never matches.
  assert.equal(conditionsMet([], rel, inc), false);
  // Multi-condition AND: all present -> true.
  assert.equal(
    conditionsMet(
      [
        parseWaitSpec("pr:8270"),
        parseWaitSpec("fix:FB-123"),
        parseWaitSpec("commit:abcdef12"),
        parseWaitSpec("version:0.1.11130"),
        parseWaitSpec("after:0.1.11129"),
      ],
      rel,
      inc,
    ),
    true,
  );
  // One condition missing -> false.
  assert.equal(conditionsMet([parseWaitSpec("pr:8270"), parseWaitSpec("pr:9999")], rel, inc), false);
  // Commit matched directly on release.commit even without included manifest.
  assert.equal(conditionsMet([parseWaitSpec("commit:deadbeef12")], rel, null), true);
  // Version/after boundaries.
  assert.equal(conditionsMet([parseWaitSpec("version:0.1.11131")], rel, null), false);
  assert.equal(conditionsMet([parseWaitSpec("after:0.1.11130")], rel, null), false);
});

test("allowed: enforces overrideBaseBuild floor against cloud downgrade", () => {
  const relOld: Release = { kind: "stillfail-station-release", version: "0.1.109", build: 109, commit: "a".repeat(40), node: "", builds: {} };
  const relBase: Release = { kind: "stillfail-station-release", version: "0.1.110", build: 110, commit: "b".repeat(40), node: "", builds: {} };
  assert.equal(allowed(relOld, 115, "stable", "stable", 110), false);
  assert.equal(allowed(relBase, 115, "stable", "stable", 110), true);
  assert.equal(allowed(relOld, 115, "stable", "beta", 110), true);
});

test("Updates: override holds auto-update, triggers on PR+fix match, skips delta, exposes tool/route, and reconciles on official", async () => {
  const dir = mkdtempSync(join(tmpdir(), "updates-override-test-"));
  const data = join(dir, "data");
  const app = join(data, "app");
  mkdirSync(join(app, "bin"), { recursive: true });
  mkdirSync(join(data, "run"), { recursive: true });
  writeFileSync(join(app, "BUILD"), "11120\n");
  writeFileSync(join(app, "CHANNEL"), "beta\n");
  const ext = process.platform === "win32" ? "ps1" : "sh";
  writeFileSync(join(app, "bin", `install.en.${ext}`), "#!/bin/sh\nexit 0\n");
  writeFileSync(join(app, "bin", `install.zh.${ext}`), "#!/bin/sh\nexit 0\n");
  writeFileSync(
    join(app, "OVERRIDE"),
    JSON.stringify({
      baseVersion: "0.1.11120",
      baseBuild: 11120,
      baseCommit: "0".repeat(40),
      kind: "overlay",
      replacedAt: 1700000000000,
      note: "testing fix",
    }),
  );

  const { trusted, signFeed } = makeKey();
  const plat = platform()!;
  const inc11125 = makeIncluded({
    build: 11125,
    commit: "1".repeat(40),
    baseBuild: 11125,
    baseCommit: "1".repeat(40),
    windowFromBuild: 11000,
    prs: [8270],
    fixes: [123],
    commits: ["111111111111"],
  });
  const rel11125: Release = {
    kind: "stillfail-station-release",
    version: "0.1.11125",
    build: 11125,
    commit: "1".repeat(40),
    node: "",
    builds: {
      [plat]: { sha256: "a".repeat(64), size: 1000, nodeSha256: "0".repeat(64), rawSha256: "b".repeat(64), rawSize: 2000 },
    },
    included: inc11125.ref,
  };
  const feedBody = signFeed(rel11125, {
    deltas: { [plat]: [{ from: 11120, file: "station/archive/beta/11125.delta", sha256: "c".repeat(64), size: 100 }] },
  });

  let includedFetches = 0;
  let startedEnvs: Record<string, string>[] = [];
  const origFetch = globalThis.fetch;
  globalThis.fetch = (async (input: string | URL) => {
    const url = String(input);
    if (url.endsWith("/releases/station-beta.json")) {
      return new Response(JSON.stringify(feedBody), { status: 200, headers: { "content-type": "application/json" } });
    }
    if (url.endsWith(`/releases/${inc11125.ref.file}`)) {
      includedFetches++;
      return new Response(new Uint8Array(inc11125.bytes), { status: 200, headers: { "content-type": "application/json" } });
    }
    return new Response("not found", { status: 404 });
  }) as typeof fetch;

  const cfg = new ConfigFile(data);
  await cfg.updateSoon((raw) => {
    raw.autoUpdate = true;
    raw.updateChannel = "beta";
  });

  const updates = new Updates({
    app,
    data,
    config: cfg,
    origin: () => "https://fake.test",
    stationOnly: true,
    trusted,
    startInstaller: async (_script, _runDir, env) => {
      startedEnvs.push(env);
      return true;
    },
  });

  try {
    // 1. Overridden without autoUpdateWhen: does NOT auto-update, does NOT fetch included manifest.
    await updates.check();
    assert.equal(includedFetches, 0);
    assert.equal(startedEnvs.length, 0);
    const line1 = updates.get("en")[0]!;
    assert.equal(line1.overridden, true);
    assert.equal(line1.overrideBase, "0.1.11120");
    assert.equal(line1.overrideKind, "overlay");
    assert.equal(line1.overrideNote, "testing fix");
    assert.equal(line1.autoHeld, true);
    assert.equal(line1.updatable, true);

    // 2. station_version list reports override fields after the 8 core keys.
    const [tool] = versionTools(updates);
    const listed = JSON.parse(await tool!.run({} as any, { action: "list" }));
    assert.deepEqual(Object.keys(listed).slice(0, 8), ["version", "latest", "newer", "channel", "auto", "autoAfter", "earlier", "state"]);
    assert.equal(listed.overridden, true);
    assert.equal(listed.autoHeld, true);

    // 3. POST /updates/wait with unmet condition (#9999): fetches included once (cached), does NOT update.
    const waitRoute = updateRoutes({ updates }).find((r) => r.pattern.test("/updates/wait"))!;
    const resUnmet = await waitRoute.handle(
      {
        viewer: { role: "owner", email: "a@b.c", workspace: "w" },
        lang: "en",
        body: JSON.stringify({ wait: ["pr:9999"] }),
      } as any,
      [] as any,
    );
    assert.equal(resUnmet.status, 200);
    assert.equal(includedFetches, 1);
    assert.equal(startedEnvs.length, 0);
    assert.deepEqual(updates.get("en")[0]!.autoWhen, ["#9999"]);
    assert.equal(updates.get("en")[0]!.autoHeld, undefined);

    // 4. station_version wait with met conditions (#8270 + FB-123): uses cached included (still 1 fetch), triggers update, skips delta (no STILLFAIL_ARCHIVE)!
    const resMet = JSON.parse(await tool!.run({} as any, { action: "wait", until: ["pr:8270", "fix:FB-123"] }));
    assert.deepEqual(resMet.autoWhen, ["#8270", "FB-123"]);
    assert.equal(includedFetches, 1, "cached by sha256");
    for (let i = 0; i < 40 && startedEnvs.length === 0; i++) {
      await new Promise((r) => setTimeout(r, 25));
    }
    assert.equal(startedEnvs.length, 1, "auto-update triggered when wait conditions met");
    assert.equal(startedEnvs[0]!.STILLFAIL_ARCHIVE, undefined, "delta skipped for overridden station");

    // 5. Simulate returning to official release (remove OVERRIDE) and running check: autoUpdateWhen cleared & restoreAuto restored!
    rmSync(join(app, "OVERRIDE"));
    writeFileSync(join(app, "BUILD"), "11125\n");
    writeFileSync(join(data, "run", "update.exit"), "0\n");
    await updates.check();
    assert.equal(cfg.raw()?.autoUpdateWhen, undefined);
    assert.equal(cfg.raw()?.autoUpdate, true);
    assert.equal(updates.get("en")[0]!.overridden, undefined);
  } finally {
    await updates.close();
    globalThis.fetch = origFetch;
    rmSync(dir, { recursive: true, force: true });
  }
});

test("stillfail replace CLI: overlay, consecutive baseline preservation, handoff failure rollback, --revert, --wait, and status", async () => {
  if (process.platform === "win32") return; // POSIX shell script test
  const dir = mkdtempSync(join(tmpdir(), "stillfail-replace-cli-"));
  const data = join(dir, "data");
  const app = join(data, "app");
  const root = join(import.meta.dirname, "..", "..");
  const binSrc = join(root, "bin", "stillfail");
  const mainEntry = join(root, "station", "src", "main.ts");
  try {
    mkdirSync(join(app, "bin"), { recursive: true });
    mkdirSync(join(app, "station"), { recursive: true });
    mkdirSync(join(data, "run"), { recursive: true });
    writeFileSync(join(app, "bin", "stillfail"), readFileSync(binSrc));
    chmodSync(join(app, "bin", "stillfail"), 0o755);
    writeFileSync(join(app, "BUILD"), "11120\n");
    writeFileSync(join(app, "VERSION"), "origcommit123456\n");
    writeFileSync(join(app, "CHANNEL"), "beta\n");
    writeFileSync(join(app, "station", "main.js"), "// original\n");
    writeFileSync(join(data, "config.json"), JSON.stringify({ autoUpdate: true, language: "en" }));

    // Wrapper executable acting as STILLFAIL_STATION_BIN that delegates `update` to `node station/src/main.ts`.
    const fakeBin = join(dir, "fake-station-bin");
    writeFileSync(fakeBin, `#!/bin/sh\nexec "${process.execPath}" "${mainEntry}" "$@"\n`);
    chmodSync(fakeBin, 0o755);

    const env = {
      ...process.env,
      STILLFAIL_DATA: data,
      STILLFAIL_STATION_BIN: fakeBin,
    };

    // 1. Overlay replace #1 with --main and --until-pr.
    const patch1 = join(dir, "patch1.js");
    writeFileSync(patch1, "// patch1\n");
    execFileSync("sh", [join(app, "bin", "stillfail"), "replace", "--main", patch1, "--until-pr", "8270", "--note", "hotfix 1"], { env });
    assert.equal(readFileSync(join(app, "station", "main.js"), "utf8"), "// patch1\n");
    assert.ok(existsSync(join(data, "app.before-replace")), "official backup saved");
    const ov1 = await readOverrideSoon(app);
    assert.equal(ov1?.baseVersion, "0.1.11120");
    assert.equal(ov1?.baseBuild, 11120);
    assert.equal(ov1?.kind, "overlay");
    assert.equal(ov1?.note, "hotfix 1");
    const cfg1 = JSON.parse(readFileSync(join(data, "config.json"), "utf8"));
    assert.equal(cfg1.autoUpdate, false);
    assert.equal(cfg1.autoUpdateWhen.restoreAuto, true);
    assert.equal(cfg1.autoUpdateWhen.forOverride, true);
    assert.deepEqual(cfg1.autoUpdateWhen.wait, [{ kind: "pr", value: 8270 }]);

    // Check `cliStatus` mentions override & wait (matches either en or zh depending on host stationLang()).
    const stText = cliStatus(data);
    assert.match(stText, /(?:Local override: overlay \(base 0\.1\.11120\)|本地替换：overlay（官方基线 0\.1\.11120）)/);
    assert.match(stText, /(?:Auto-update: waiting for #8270|自动更新：等待 #8270)/);

    // 2. Consecutive bundle replace #2: preserves original baseVersion 0.1.11120 and app.before-replace!
    const bundle2 = join(dir, "bundle2");
    mkdirSync(join(bundle2, "bin"), { recursive: true });
    mkdirSync(join(bundle2, "station"), { recursive: true });
    writeFileSync(join(bundle2, "bin", "stillfail"), readFileSync(binSrc));
    chmodSync(join(bundle2, "bin", "stillfail"), 0o755);
    writeFileSync(join(bundle2, "BUILD"), "11121\n");
    writeFileSync(join(bundle2, "station", "main.js"), "// bundle2\n");
    execFileSync("sh", [join(app, "bin", "stillfail"), "replace", bundle2, "--note", "bundle 2"], { env });
    assert.equal(readFileSync(join(app, "station", "main.js"), "utf8"), "// bundle2\n");
    const ov2 = await readOverrideSoon(app);
    assert.equal(ov2?.baseVersion, "0.1.11120", "preserves first official baseline");
    assert.equal(ov2?.kind, "bundle");
    assert.equal(readFileSync(join(data, "app.before-replace", "station", "main.js"), "utf8"), "// original\n", "backup untouched");

    // 3. Handoff failure automatically rolls back!
    const sleeper = spawn(process.execPath, ["-e", "process.on('SIGUSR2', () => { require('fs').writeFileSync(process.argv[1], 'crash'); }); setInterval(() => {}, 1000);", join(data, "run", "handoff-failed")], { stdio: "ignore" });
    try {
      writeFileSync(join(data, "run", "station.json"), JSON.stringify({ pid: sleeper.pid, startedAt: 1000, handoff: 1 }));
      const patch3 = join(dir, "patch3.js");
      writeFileSync(patch3, "// broken-patch\n");
      let failed = false;
      try {
        execFileSync("sh", [join(app, "bin", "stillfail"), "replace", "--main", patch3], {
          env: { ...env, STILLFAIL_REPLACE_ALLOW_PID: "1", STILLFAIL_REPLACE_WAIT: "5", STILLFAIL_REPLACE_POLL: "0.1" },
          stdio: "pipe",
        });
      } catch {
        failed = true;
      }
      assert.equal(failed, true, "replace fails when handoff fails");
      assert.equal(readFileSync(join(app, "station", "main.js"), "utf8"), "// bundle2\n", "rolled back to previous build");
    } finally {
      sleeper.kill("SIGKILL");
      rmSync(join(data, "run", "station.json"), { force: true });
      rmSync(join(data, "run", "handoff-failed"), { force: true });
    }

    // 4. --wait updates conditions without replacing files, supports --hold, and rejects bare --wait with exit 2.
    execFileSync("sh", [join(app, "bin", "stillfail"), "replace", "--wait", "--until-fix", "FB-555"], { env });
    const cfgWait = JSON.parse(readFileSync(join(data, "config.json"), "utf8"));
    assert.deepEqual(cfgWait.autoUpdateWhen.wait, [{ kind: "fix", value: 555 }]);

    execFileSync("sh", [join(app, "bin", "stillfail"), "replace", "--wait", "--hold"], { env });
    const cfgHold = JSON.parse(readFileSync(join(data, "config.json"), "utf8"));
    assert.deepEqual(cfgHold.autoUpdateWhen.wait, []);

    let bareWaitCode: number | null = null;
    try {
      execFileSync("sh", [join(app, "bin", "stillfail"), "replace", "--wait"], { env, stdio: "pipe" });
    } catch (e: any) {
      bareWaitCode = e?.status ?? null;
    }
    assert.equal(bareWaitCode, 2, "bare --wait exits 2 with usage");

    // 5. --revert restores official backup and reconciles forOverride wait state.
    execFileSync("sh", [join(app, "bin", "stillfail"), "replace", "--revert"], { env });
    assert.equal(readFileSync(join(app, "station", "main.js"), "utf8"), "// original\n");
    assert.equal(existsSync(join(app, "OVERRIDE")), false);
    assert.equal(existsSync(join(data, "app.before-replace")), false);
    const cfgReverted = JSON.parse(readFileSync(join(data, "config.json"), "utf8"));
    assert.equal(cfgReverted.autoUpdateWhen, undefined);
    assert.equal(cfgReverted.autoUpdate, true);

    // 6. First-replace handoff failure cleans up newly created app.before-replace and restores config.json.
    const sleeperFirst = spawn(
      process.execPath,
      ["-e", "process.on('SIGUSR2', () => { require('fs').writeFileSync(process.argv[1], 'crash'); }); setInterval(() => {}, 1000);", join(data, "run", "handoff-failed")],
      { stdio: "ignore" },
    );
    try {
      writeFileSync(join(data, "run", "station.json"), JSON.stringify({ pid: sleeperFirst.pid, startedAt: 2000, handoff: 1 }));
      const patchBad = join(dir, "patch-first-bad.js");
      writeFileSync(patchBad, "// first-bad\n");
      let firstFailed = false;
      try {
        execFileSync("sh", [join(app, "bin", "stillfail"), "replace", "--main", patchBad, "--until-pr", "9001"], {
          env: { ...env, STILLFAIL_REPLACE_ALLOW_PID: "1", STILLFAIL_REPLACE_WAIT: "5", STILLFAIL_REPLACE_POLL: "0.1" },
          stdio: "pipe",
        });
      } catch {
        firstFailed = true;
      }
      assert.equal(firstFailed, true, "first replace fails when handoff fails");
      assert.equal(readFileSync(join(app, "station", "main.js"), "utf8"), "// original\n", "rolled back to official build");
      assert.equal(existsSync(join(app, "OVERRIDE")), false, "no OVERRIDE left after rollback");
      assert.equal(existsSync(join(data, "app.before-replace")), false, "no orphan app.before-replace left on first-replace failure");
      const cfgAfterFirstFail = JSON.parse(readFileSync(join(data, "config.json"), "utf8"));
      assert.equal(cfgAfterFirstFail.autoUpdate, true, "autoUpdate restored on handoff failure");
      assert.equal(cfgAfterFirstFail.autoUpdateWhen, undefined, "autoUpdateWhen rolled back on handoff failure");
    } finally {
      sleeperFirst.kill("SIGKILL");
      rmSync(join(data, "run", "station.json"), { force: true });
      rmSync(join(data, "run", "handoff-failed"), { force: true });
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("setWaitConfig falls back to config.json when older running station ignores wait-ask", async () => {
  if (process.platform === "win32") return;
  const dir = mkdtempSync(join(tmpdir(), "replace-old-station-"));
  const data = join(dir, "data");
  const app = join(data, "app");
  const run = join(data, "run");
  mkdirSync(app, { recursive: true });
  mkdirSync(run, { recursive: true });
  writeFileSync(join(data, "config.json"), JSON.stringify({ autoUpdate: true }));
  // Old station ignores SIGHUP wait-ask (leaves wait-ask on disk and writes no wait-answer).
  const oldProc = spawn(process.execPath, ["-e", "process.on('SIGHUP', () => {}); setInterval(() => {}, 1000);"], { stdio: "ignore" });
  try {
    writeFileSync(join(run, "station.json"), JSON.stringify({ pid: oldProc.pid, channel: 1 }));
    await setWaitConfig(data, [parseWaitSpec("pr:4242")], { waitMs: 250, isStation: () => true });
    assert.equal(existsSync(join(run, "wait-ask")), false, "stale wait-ask cleaned up");
    const raw = JSON.parse(readFileSync(join(data, "config.json"), "utf8"));
    assert.equal(raw.autoUpdate, false);
    assert.deepEqual(raw.autoUpdateWhen.wait, [{ kind: "pr", value: 4242 }]);
  } finally {
    oldProc.kill("SIGKILL");
    rmSync(dir, { recursive: true, force: true });
  }
});

test("Updates.setAuto while overridden refuses enabling and clears restoreAuto on disable", async () => {
  const dir = mkdtempSync(join(tmpdir(), "updates-override-setauto-"));
  const data = join(dir, "data");
  const app = join(data, "app");
  mkdirSync(join(app, "bin"), { recursive: true });
  mkdirSync(join(data, "run"), { recursive: true });
  writeFileSync(join(app, "BUILD"), "11120\n");
  writeFileSync(join(app, "CHANNEL"), "beta\n");
  writeFileSync(
    join(app, "OVERRIDE"),
    JSON.stringify({ baseVersion: "0.1.11120", baseBuild: 11120, baseCommit: null, kind: "overlay", replacedAt: 1700000000000 }),
  );
  const cfg = new ConfigFile(data);
  await cfg.updateSoon((raw) => {
    raw.autoUpdate = false;
    raw.autoUpdateWhen = { wait: [{ kind: "pr", value: 8270 }], restoreAuto: true, forOverride: true };
  });
  const updates = new Updates({
    app,
    data,
    config: cfg,
    origin: () => "https://fake.test",
    stationOnly: true,
  });
  try {
    await assert.rejects(() => updates.setAuto(true, "en"), /local override/i);
    assert.equal(cfg.raw()?.autoUpdate, false, "autoUpdate stays false when enabling is refused");

    await updates.setAuto(false, "en");
    const aw = (cfg.raw() as any)?.autoUpdateWhen;
    assert.equal(aw?.restoreAuto, false, "setAuto(false) clears restoreAuto on autoUpdateWhen");
  } finally {
    await updates.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("prepareReplace and setWaitConfig helpers work directly", async () => {
  const dir = mkdtempSync(join(tmpdir(), "replace-helper-test-"));
  const data = join(dir, "data");
  const app = join(data, "app");
  const stage = join(dir, "stage");
  try {
    mkdirSync(join(app, "bin"), { recursive: true });
    mkdirSync(join(app, "station"), { recursive: true });
    writeFileSync(join(app, "bin", "stillfail"), "#!/bin/sh\n");
    writeFileSync(join(app, "station", "main.js"), "// old\n");
    writeFileSync(join(app, "BUILD"), "500\n");
    const patched = join(dir, "new.js");
    writeFileSync(patched, "// new\n");
    const meta = await prepareReplace({ app, data, stage, main: patched, note: "unit" });
    assert.equal(meta.kind, "overlay");
    assert.equal(meta.baseVersion, "0.1.500");
    assert.equal(readFileSync(join(stage, "station", "main.js"), "utf8"), "// new\n");

    await setWaitConfig(data, [parseWaitSpec("pr:1234")], { app: stage });
    const raw = JSON.parse(readFileSync(join(data, "config.json"), "utf8"));
    assert.equal(raw.autoUpdateWhen.forOverride, true);
    assert.deepEqual(raw.autoUpdateWhen.wait, [{ kind: "pr", value: 1234 }]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
