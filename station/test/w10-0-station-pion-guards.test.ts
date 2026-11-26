import assert from "node:assert/strict";
import { execFileSync, spawnSync, type SpawnSyncReturns } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { inputsIn, inputsOf, key, tree } from "../../scripts/native.ts";
import { isRig } from "../src/cli.ts";

const root = fileURLToPath(new URL("../..", import.meta.url));
const HEX32 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

function parseWorkflowPaths(workflowPath: string, event: "push" | "pull_request"): string[] {
  const lines = readFileSync(workflowPath, "utf8").split("\n");
  const out: string[] = [];
  let inOn = false;
  let inEvent = false;
  let inPaths = false;
  for (const line of lines) {
    if (/^on:\s*$/.test(line)) {
      inOn = true;
      continue;
    }
    if (inOn && /^\S/.test(line)) break;
    if (!inOn) continue;
    if (new RegExp(`^  ${event}:\\s*$`).test(line)) {
      inEvent = true;
      continue;
    }
    if (inEvent && /^  \S/.test(line)) {
      inEvent = false;
      inPaths = false;
      continue;
    }
    if (!inEvent) continue;
    if (/^    paths:\s*$/.test(line)) {
      inPaths = true;
      continue;
    }
    if (inPaths && /^    \S/.test(line)) {
      inPaths = false;
      continue;
    }
    if (inPaths) {
      const m = /^      -\s*["']?([^"'\s#]+)["']?/.exec(line);
      if (m) out.push(m[1]!);
    }
  }
  return out;
}

function globMatch(pattern: string, filePath: string): boolean {
  let rx = "^";
  for (let i = 0; i < pattern.length; i++) {
    const ch = pattern[i]!;
    if (ch === "*" && pattern[i + 1] === "*") {
      if (pattern[i + 2] === "/") {
        rx += "(?:.*/)?";
        i += 2;
      } else {
        rx += ".*";
        i += 1;
      }
    } else if (ch === "*") {
      rx += "[^/]*";
    } else if (ch === "?") {
      rx += "[^/]";
    } else if ("\\.^$+{}()|[]".includes(ch)) {
      rx += "\\" + ch;
    } else {
      rx += ch;
    }
  }
  rx += "$";
  return new RegExp(rx).test(filePath);
}

function matchesAny(patterns: string[], filePath: string): boolean {
  return patterns.some((p) => globMatch(p, filePath));
}

type NativeTree = ReturnType<typeof tree>;

function treeHasFile(t: NativeTree, file: string): boolean {
  return t.staged.some(([p]) => p === file) || t.dirty.includes(file);
}

function keyWithMutatedTree(
  baseTree: NativeTree,
  part: string,
  target: "linux-x64" | "darwin-arm64",
  overrideFile?: [string, string],
): string {
  const staged: [string, string][] = baseTree.staged.map(([p, h]) =>
    overrideFile && p === overrideFile[0] ? [p, overrideFile[1]] : [p, h],
  );
  const hashes = new Map(baseTree.hashes);
  let dirty = [...baseTree.dirty];
  if (overrideFile) {
    const [file, hash] = overrideFile;
    if (!staged.some(([p]) => p === file)) staged.push([file, hash]);
    if (dirty.includes(file)) {
      dirty = dirty.filter((p) => p !== file);
      hashes.delete(file);
    }
  }
  const mutated: NativeTree = { root: baseTree.root, staged, dirty, hashes };
  return key(part, target, (paths) => {
    const got = inputsIn(mutated, paths);
    assert.ok(got, `${part}:${target}: inputsIn failed for ${paths.join(" ")}`);
    return got;
  });
}

function findLauncherBinary(): string | null {
  const candidates = [
    process.env.STILLFAIL_LAUNCHER,
    join(root, "station/native/launcher/target/debug/stillfail-station"),
    join(root, "station/native/launcher/target/release/stillfail-station"),
  ].filter((p): p is string => Boolean(p));
  for (const c of candidates) {
    if (existsSync(c)) return c;
  }
  return null;
}

test("W10-0 cache-key isolation and pion-station-main.yml paths dispatch (4 checks + exhaustive native inputs)", () => {
  const pushPaths = parseWorkflowPaths(join(root, ".github/workflows/pion-station-main.yml"), "push");
  const prPaths = parseWorkflowPaths(join(root, ".github/workflows/pion-station-main.yml"), "pull_request");
  assert.ok(pushPaths.length > 0, "pion-station-main.yml must declare on.push.paths");
  assert.equal(prPaths.length, 0, "pion-station-main.yml must not declare on.pull_request (use push only like pion-station.yml)");

  const baseTree = tree(root);
  const target = "linux-x64" as const;
  const baseReader = keyWithMutatedTree(baseTree, "pion-reader", target);
  const baseStation = keyWithMutatedTree(baseTree, "station-pion", target);

  // Exhaustive check: EVERY real file in `station-pion` and `shell-station` native inputs
  // MUST match `pion-station-main.yml`'s `on.push.paths`.
  for (const part of ["station-pion", "shell-station"] as const) {
    const entries = inputsIn(baseTree, inputsOf(part));
    assert.ok(entries && entries.length > 0, `expected non-empty inputs for ${part}`);
    for (const [file] of entries) {
      assert.ok(matchesAny(pushPaths, file), `${part} input '${file}' is NOT covered by pion-station-main.yml on.push.paths`);
    }
  }

  // (1) Editing zh/station.json, en/station.json, or brand.ts changes station-pion only,
  //     keeps pion-reader unchanged, and matches pion-station-main.yml paths.
  for (const file of [
    "client/i18n/catalog/zh/station.json",
    "client/i18n/catalog/en/station.json",
    "client/i18n/brand.ts",
  ]) {
    assert.ok(treeHasFile(baseTree, file), `expected ${file} in checkout`);
    assert.ok(matchesAny(pushPaths, file), `${file} must match pion-station-main.yml paths`);
    const nextReader = keyWithMutatedTree(baseTree, "pion-reader", target, [file, "deadbeef00000000000000000000000000000000"]);
    const nextStation = keyWithMutatedTree(baseTree, "station-pion", target, [file, "deadbeef00000000000000000000000000000000"]);
    assert.equal(nextReader, baseReader, `editing ${file} must NOT change pion-reader key`);
    assert.notEqual(nextStation, baseStation, `editing ${file} MUST change station-pion key`);
  }

  // (2) client/shell/**, client/Cargo.lock, libs/mesh-transport/** match pion-station-main.yml paths.
  for (const file of ["client/shell/src/net.rs", "client/Cargo.lock", "libs/mesh-transport/src/lib.rs"]) {
    assert.ok(matchesAny(pushPaths, file), `${file} must match pion-station-main.yml paths`);
  }

  // (3) Editing pion/station-main/ changes station-pion only, keeps pion-reader unchanged,
  //     and matches pion-station-main.yml paths.
  const mainFile = "pion/station-main/packages/station_main/src/main.pion";
  assert.ok(treeHasFile(baseTree, mainFile), `expected ${mainFile} in checkout`);
  assert.ok(matchesAny(pushPaths, mainFile), `${mainFile} must match pion-station-main.yml paths`);
  {
    const nextReader = keyWithMutatedTree(baseTree, "pion-reader", target, [mainFile, "cafebabe00000000000000000000000000000000"]);
    const nextStation = keyWithMutatedTree(baseTree, "station-pion", target, [mainFile, "cafebabe00000000000000000000000000000000"]);
    assert.equal(nextReader, baseReader, "editing pion/station-main/ must NOT change pion-reader key");
    assert.notEqual(nextStation, baseStation, "editing pion/station-main/ MUST change station-pion key");
  }

  // (4) Editing shared pion/station/packages/sql_db changes BOTH pion-reader and station-pion keys,
  //     and matches pion-station-main.yml paths.
  const sharedFile = "pion/station/packages/sql_db/src/sql_db.pion";
  assert.ok(treeHasFile(baseTree, sharedFile), `expected ${sharedFile} in checkout`);
  assert.ok(matchesAny(pushPaths, sharedFile), `${sharedFile} must match pion-station-main.yml paths`);
  {
    const nextReader = keyWithMutatedTree(baseTree, "pion-reader", target, [sharedFile, "feedface00000000000000000000000000000000"]);
    const nextStation = keyWithMutatedTree(baseTree, "station-pion", target, [sharedFile, "feedface00000000000000000000000000000000"]);
    assert.notEqual(nextReader, baseReader, "editing shared sql_db MUST change pion-reader key");
    assert.notEqual(nextStation, baseStation, "editing shared sql_db MUST change station-pion key");
  }
});

test("TS isRig and Rust launcher data::is_rig + strict corrupt-config CLI agree 1:1 on shared on-disk fixtures", { skip: process.platform === "win32" }, (t) => {
  const launcher = findLauncherBinary();
  if (!launcher) {
    t.skip("stillfail-station launcher binary not built yet (set STILLFAIL_LAUNCHER or cargo build launcher)");
    return;
  }

  const dir = mkdtempSync(join(tmpdir(), "w10-0-isrig-parity-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));

  const app = join(dir, "app");
  mkdirSync(join(app, "station"), { recursive: true });
  writeFileSync(join(app, "station/main.js"), "");

  // Fake stillfail-station-pion advertising ONLY roles:rig.
  // When selected by `run`, it writes a marker file and asks its launcher (PPID) to stop via SIGTERM.
  const marker = join(dir, "pion-selected");
  const fakePion = join(dir, "fake-station-pion");
  writeFileSync(
    fakePion,
    `#!/bin/sh
if [ "$1" = "--version" ]; then
  echo 'stillfail-station-pion 0.1.0 roles:rig commands:'
  exit 0
fi
printf '%s\\n' "selected" > "${marker}"
kill -TERM "$PPID" 2>/dev/null || true
exit 0
`,
  );
  chmodSync(fakePion, 0o755);

  const fixtures: { name: string; cloudJson: string | null; expectedRig: boolean }[] = [
    { name: "empty data dir", cloudJson: null, expectedRig: false },
    {
      name: "valid home rig",
      cloudJson: JSON.stringify({ workspace: "ws-1", rig: { owner: "u1", person: HEX32 } }),
      expectedRig: true,
    },
    {
      name: "rig missing person (HEX32)",
      cloudJson: JSON.stringify({ workspace: "ws-1", rig: { owner: "u1" } }),
      expectedRig: false,
    },
    {
      name: "valid home rig + malformed joined [{}]",
      cloudJson: JSON.stringify({ workspace: "ws-1", rig: { owner: "u1", person: HEX32 }, joined: [{}] }),
      expectedRig: true,
    },
    {
      name: "valid home rig + removed_at: null",
      cloudJson: JSON.stringify({ workspace: "ws-1", rig: { owner: "u1", person: HEX32 }, removed_at: null }),
      expectedRig: false,
    },
    {
      name: "valid home rig + mixed full joined workspace",
      cloudJson: JSON.stringify({ workspace: "ws-1", rig: { owner: "u1", person: HEX32 }, joined: [{ workspace: "ws-2" }] }),
      expectedRig: false,
    },
  ];

  for (const [idx, fx] of fixtures.entries()) {
    const data = join(dir, `data-${idx}`);
    mkdirSync(join(data, "mesh"), { recursive: true });
    if (fx.cloudJson !== null) writeFileSync(join(data, "mesh/cloud.json"), fx.cloudJson);
    rmSync(marker, { force: true });

    const tsResult = isRig(data);
    assert.equal(tsResult, fx.expectedRig, `TS isRig mismatch on fixture '${fx.name}'`);

    const run: SpawnSyncReturns<string> = spawnSync(launcher, ["run", "--app", app, "--data", data, "--port", "0"], {
      encoding: "utf8",
      timeout: 10000,
      env: {
        ...process.env,
        STILLFAIL_STATION_ENGINE: "pion",
        STILLFAIL_STATION_ENGINE_STRICT: "1",
        STILLFAIL_STATION_PION: fakePion,
      },
    });
    const rustSelectedRig = existsSync(marker);
    assert.equal(
      rustSelectedRig,
      tsResult,
      `Rust launcher vs TS isRig mismatch on fixture '${fx.name}' (status=${run.status}, stderr=${run.stderr})`,
    );
    if (!tsResult) {
      assert.notEqual(run.status, 0, `strict mode must exit non-zero for whole fixture '${fx.name}'`);
      assert.match(run.stderr, /required role 'whole'/, `fixture '${fx.name}' stderr: ${run.stderr}`);
    }
  }

  // Corrupt / explicit-null / non-object config.json + STILLFAIL_STATION_ENGINE_STRICT=1 running CLI `status`
  // MUST exit non-zero and MUST NOT invoke the Node stand-in.
  const nodeMarker = join(dir, "node-invoked");
  const fakeNode = join(dir, "fake-node");
  writeFileSync(fakeNode, `#!/bin/sh\necho invoked > "${nodeMarker}"\nexit 0\n`);
  chmodSync(fakeNode, 0o755);

  for (const [idx, badCfg] of [
    { label: "corrupt JSON", body: "{corrupt json", secret: null },
    { label: "explicit empty engine", body: JSON.stringify({ engine: "" }), secret: null },
    { label: "explicit whitespace engine", body: JSON.stringify({ engine: "   " }), secret: null },
    { label: "explicit null engine", body: JSON.stringify({ engine: null }), secret: null },
    { label: "non-string engine array (redacted)", body: JSON.stringify({ engine: ["sentinel-engine-secret"] }), secret: "sentinel-engine-secret" },
    { label: "non-object top-level array (redacted)", body: JSON.stringify(["sentinel-root-secret"]), secret: "sentinel-root-secret" },
  ].entries()) {
    const badData = join(dir, `bad-cfg-${idx}`);
    mkdirSync(badData, { recursive: true });
    writeFileSync(join(badData, "config.json"), badCfg.body);
    rmSync(nodeMarker, { force: true });

    const cliRun: SpawnSyncReturns<string> = spawnSync(launcher, ["status", "--app", app, "--data", badData], {
      encoding: "utf8",
      timeout: 10000,
      env: {
        ...process.env,
        STILLFAIL_STATION_ENGINE: "",
        STILLFAIL_STATION_ENGINE_STRICT: "1",
        STILLFAIL_NODE: fakeNode,
      },
    });
    assert.notEqual(cliRun.status, 0, `${badCfg.label} in strict mode must exit non-zero`);
    assert.match(cliRun.stderr, /could not read engine from config\.json/, `${badCfg.label} stderr: ${cliRun.stderr}`);
    if (badCfg.secret) {
      assert.equal(cliRun.stderr.includes(badCfg.secret), false, `${badCfg.label} must not echo config contents in stderr: ${cliRun.stderr}`);
    }
    assert.equal(existsSync(nodeMarker), false, `Node stand-in must NEVER be invoked for ${badCfg.label} in strict mode`);
  }
});

test("scripts/check.sh Pion static guards reject negative mutations and allow comments/prose/triggers", { skip: process.platform === "win32" }, (t) => {
  const dir = mkdtempSync(join(tmpdir(), "w10-0-pion-guards-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));

  const put = (rel: string, content: string) => {
    const abs = join(dir, rel);
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, content);
  };
  const copy = (rel: string) => {
    const abs = join(dir, rel);
    mkdirSync(dirname(abs), { recursive: true });
    copyFileSync(join(root, rel), abs);
  };

  copy("scripts/check.sh");
  copy("scripts/mesh-base.ts");
  put("scripts/agents-paths.ts", "process.exit(0);\n");
  put("scripts/features-check.ts", "process.exit(0);\n");
  put("pion/station-main/packages/station_main/src/main.pion", "pub fn ok() -> Int { 1 }\n");

  const git = (...args: string[]) => execFileSync("git", args, { cwd: dir, encoding: "utf8" });
  git("init", "-q");
  git("config", "user.email", "test@example.com");
  git("config", "user.name", "test");
  git("config", "commit.gpgsign", "false");
  git("add", "-A");
  git("commit", "-qm", "base");

  const runCheckOn = (code: string) => {
    put("pion/station-main/packages/station_main/src/main.pion", code);
    git("add", "pion/station-main/packages/station_main/src/main.pion");
    return spawnSync("sh", ["scripts/check.sh", "commit"], {
      cwd: dir,
      encoding: "utf8",
      env: { ...process.env, STILLFAIL_CHECK_PART: "ts" },
    });
  };

  // Clean code including comments mentioning proc.run / shell_call_wait() / tcp_listen() / COMMIT,
  // plus prose SQL error strings, SELECT 'COMMIT' AS label, and CREATE TRIGGER ... BEGIN ... END.
  const cleanCode = `
// Mentioning "proc.run", shell_call_wait(), tcp_listen("0.0.0.0:80"), and BEGIN IMMEDIATE in comments is fine.
/* Multi-line block comment with:
   effect::sleep_k(rt, 1000, k)
   "COMMIT"
   cloudflared
*/
pub fn ok() -> Array[String] {
  [
    "could not commit: busy",
    "after ROLLBACK: retry",
    "BEGIN processing the input file",
    "COMMIT failed: disk full",
    "SELECT 'COMMIT' AS label",
    "CREATE TRIGGER tr_a AFTER INSERT ON t BEGIN UPDATE t SET x = 1; END",
  ]
}
pub fn local_only() -> Unit {
  unix_listen("/tmp/station.sock")
  tcp_listen_fd(3)
  tcp_listen("127.0.0.1:4760")
  tcp_listen(
    "127.0.0.1:4760"
  )
  shell_call("tcp.listen", "{ \\"fd\\": 3 }")
  shell_call(
    "tcp.listen",
    "{ \\"fd\\": 3 }"
  )
  shell_call(
    "udp.bind",
    "{ \\"addr\\": \\"127.0.0.1\\" }"
  )
  mux.call_async_raw(tok, "tcp.listen", base_codec::json_stringify(args), None)
}
`;
  const clean = runCheckOn(cleanCode);
  assert.equal(clean.status, 0, `expected clean code/comments/triggers/prose/multiline-loopback to pass:\n${clean.stdout}\n${clean.stderr}`);

  // 1. Real effect::sleep_k without timer: fails; marked with `// timer:` on preceding or same line passes.
  const badTimer = runCheckOn("pub fn poll() -> Unit {\n  effect::sleep_k(rt, 5000, k)\n}\n");
  assert.notEqual(badTimer.status, 0, "unmarked effect::sleep_k must fail check.sh");
  assert.match(badTimer.stdout + badTimer.stderr, /no polling timers without timer:/);

  const goodTimerPrevLine = runCheckOn("pub fn poll() -> Unit {\n  // timer: heartbeat\n  effect::sleep_k(rt, 5000, k)\n}\n");
  assert.equal(goodTimerPrevLine.status, 0, `preceding-line timer: should pass:\n${goodTimerPrevLine.stdout}\n${goodTimerPrevLine.stderr}`);

  // 2. proc.run fails; unmarked shell_call_wait fails; marked sync: passes.
  const badProcRun = runCheckOn('pub fn run_it() -> String { "proc.run" }\n');
  assert.notEqual(badProcRun.status, 0, "proc.run must fail check.sh");
  assert.match(badProcRun.stdout + badProcRun.stderr, /no proc\.run on main loop/);

  const badSync = runCheckOn('pub fn blocking() -> Unit { shell_call_wait("fs.meta", "{}") }\n');
  assert.notEqual(badSync.status, 0, "unmarked shell_call_wait must fail check.sh");
  assert.match(badSync.stdout + badSync.stderr, /no unmarked blocking shell sync calls/);

  const goodSync = runCheckOn('pub fn blocking() -> Unit {\n  // sync: startup\n  shell_call_wait("fs.meta", "{}")\n}\n');
  assert.equal(goodSync.status, 0, `marked sync should pass:\n${goodSync.stdout}\n${goodSync.stderr}`);

  // 3. Raw SQLite transaction SQL (case-insensitive full statement) fails.
  for (const tx of ['"BEGIN IMMEDIATE"', '"begin immediate"', '"END"', '"END TRANSACTION"', '"SAVEPOINT sp1"']) {
    const badSql = runCheckOn(`pub fn bad_tx() -> String { ${tx} }\n`);
    assert.notEqual(badSql.status, 0, `raw SQL ${tx} must fail check.sh`);
    assert.match(badSql.stdout + badSql.stderr, /no raw SQLite transaction SQL/);
  }

  // 4. Non-local listener with incidental `opts.path` OR `0.0.0.0` alongside `127.0.0.1` MUST be rejected!
  const badListenWithPath = runCheckOn("pub fn serve() -> Unit { tcp_listen(cfg.host, cfg.port, opts.path) }\n");
  assert.notEqual(badListenWithPath.status, 0, "tcp_listen(cfg.host, cfg.port, opts.path) must fail check.sh");
  assert.match(badListenWithPath.stdout + badListenWithPath.stderr, /listeners on this machine only/);

  const badDualHost = runCheckOn('pub fn serve() -> Unit { tcp_listen(host_of("0.0.0.0", "127.0.0.1")) }\n');
  assert.notEqual(badDualHost.status, 0, "tcp_listen containing 0.0.0.0 alongside 127.0.0.1 must fail check.sh");
  assert.match(badDualHost.stdout + badDualHost.stderr, /listeners on this machine only/);

  const badMultilineHost = runCheckOn('pub fn serve() -> Unit {\n  shell_call(\n    "tcp.listen",\n    "{ \\"host\\": \\"0.0.0.0\\" }"\n  )\n}\n');
  assert.notEqual(badMultilineHost.status, 0, "multi-line tcp.listen with explicit host 0.0.0.0 must fail check.sh");
  assert.match(badMultilineHost.stdout + badMultilineHost.stderr, /listeners on this machine only/);

  const badDynamicUdp = runCheckOn("pub fn probe() -> Unit {\n  // listen: comments must NOT bypass local-only bind\n  udp_bind(cfg.addr, 0)\n}\n");
  assert.notEqual(badDynamicUdp.status, 0, "dynamic udp_bind(cfg.addr, 0) must fail even with a comment");
  assert.match(badDynamicUdp.stdout + badDynamicUdp.stderr, /listeners on this machine only/);

  const badTunnel = runCheckOn('pub fn tunnel() -> String { "cloudflared" }\n');
  assert.notEqual(badTunnel.status, 0, "tunnel name must fail check.sh");
  assert.match(badTunnel.stdout + badTunnel.stderr, /no tunnel into a station/);
});

test("scripts/mesh-base.ts enforces Pion mesh_{wire,door,accept} isolation when present", (t) => {
  const dir = mkdtempSync(join(tmpdir(), "w10-0-mesh-base-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));

  const copy = (rel: string) => {
    const abs = join(dir, rel);
    mkdirSync(dirname(abs), { recursive: true });
    copyFileSync(join(root, rel), abs);
  };
  const put = (rel: string, content: string) => {
    const abs = join(dir, rel);
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, content);
  };

  copy("scripts/mesh-base.ts");
  for (const rel of [
    "station/src/mesh/wire.ts",
    "station/src/mesh/door.ts",
    "station/src/mesh/accept.ts",
    "station/src/mesh/reply-watch.ts",
    "station/src/mesh/endpoint.ts",
    "station/src/mesh/compress.ts",
    "station/src/mesh/storms.ts",
    "station/src/mesh/superseded.ts",
    "station/src/mesh/lan.ts",
    "station/src/mesh/settings.ts",
    "station/src/api/event-log.ts",
    "station/src/ops/log.ts",
    "station/src/ops/fibers.ts",
  ]) {
    copy(rel);
  }

  const runMeshBase = () => spawnSync(process.execPath, [join(dir, "scripts/mesh-base.ts")], { cwd: dir, encoding: "utf8" });

  put("pion/station-main/packages/mesh_wire/pion.toml", "[package]\nname = \"mesh_wire\"\n[dependencies]\nbase_codec = { workspace = true }\n");
  put("pion/station-main/packages/mesh_wire/src/wire.pion", '// comment mentioning still.fail is allowed\nimport "base_codec"\npub fn ok() -> Int { 1 }\n');
  assert.equal(runMeshBase().status, 0, "clean mesh_wire should pass mesh-base.ts");

  put("pion/station-main/packages/mesh_wire/src/wire.pion", 'import "station_cloud"\npub fn bad() -> Int { 1 }\n');
  const badImport = runMeshBase();
  assert.notEqual(badImport.status, 0, "mesh_wire importing station_cloud must fail");
  assert.match(badImport.stdout, /imports station_cloud/);

  put("pion/station-main/packages/mesh_wire/src/wire.pion", 'import "base_codec"\npub fn bad() -> String { "stillfail" }\n');
  const badName = runMeshBase();
  assert.notEqual(badName.status, 0, "mesh_wire mentioning stillfail in code must fail");
  assert.match(badName.stdout, /says still\.fail's name/);
});
