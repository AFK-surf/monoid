import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { inputsIn, key, tree } from "../../scripts/native.ts";

const root = fileURLToPath(new URL("../..", import.meta.url));

function parsePushPaths(workflowPath: string): string[] {
  const lines = readFileSync(workflowPath, "utf8").split("\n");
  const out: string[] = [];
  let inOn = false;
  let inPush = false;
  let inPaths = false;
  for (const line of lines) {
    if (/^on:\s*$/.test(line)) {
      inOn = true;
      continue;
    }
    if (inOn && /^\S/.test(line)) break;
    if (!inOn) continue;
    if (/^  push:\s*$/.test(line)) {
      inPush = true;
      continue;
    }
    if (inPush && /^  \S/.test(line)) {
      inPush = false;
      inPaths = false;
      continue;
    }
    if (!inPush) continue;
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
  // Translate GitHub Actions path glob (`**`, `*`, `?`) to RegExp.
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

test("W10-0 cache-key isolation and pion-station-main.yml paths dispatch (4 checks)", () => {
  const workflowPaths = parsePushPaths(join(root, ".github/workflows/pion-station-main.yml"));
  assert.ok(workflowPaths.length > 0, "pion-station-main.yml must declare on.push.paths");

  const baseTree = tree(root);
  const target = "linux-x64" as const;
  const baseReader = keyWithMutatedTree(baseTree, "pion-reader", target);
  const baseStation = keyWithMutatedTree(baseTree, "station-pion", target);

  // (1) Editing zh/station.json, en/station.json, or brand.ts changes station-pion only,
  //     keeps pion-reader unchanged, and matches pion-station-main.yml paths.
  for (const file of [
    "client/i18n/catalog/zh/station.json",
    "client/i18n/catalog/en/station.json",
    "client/i18n/brand.ts",
  ]) {
    assert.ok(treeHasFile(baseTree, file), `expected ${file} in checkout`);
    assert.ok(matchesAny(workflowPaths, file), `${file} must match pion-station-main.yml paths`);
    const nextReader = keyWithMutatedTree(baseTree, "pion-reader", target, [file, "deadbeef00000000000000000000000000000000"]);
    const nextStation = keyWithMutatedTree(baseTree, "station-pion", target, [file, "deadbeef00000000000000000000000000000000"]);
    assert.equal(nextReader, baseReader, `editing ${file} must NOT change pion-reader key`);
    assert.notEqual(nextStation, baseStation, `editing ${file} MUST change station-pion key`);
  }

  // (2) client/shell/** matches pion-station-main.yml paths.
  assert.ok(matchesAny(workflowPaths, "client/shell/src/net.rs"), "client/shell/** must match pion-station-main.yml paths");

  // (3) Editing pion/station-main/ changes station-pion only, keeps pion-reader unchanged,
  //     and matches pion-station-main.yml paths.
  const mainFile = "pion/station-main/packages/station_main/src/main.pion";
  assert.ok(treeHasFile(baseTree, mainFile), `expected ${mainFile} in checkout`);
  assert.ok(matchesAny(workflowPaths, mainFile), `${mainFile} must match pion-station-main.yml paths`);
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
  assert.ok(matchesAny(workflowPaths, sharedFile), `${sharedFile} must match pion-station-main.yml paths`);
  {
    const nextReader = keyWithMutatedTree(baseTree, "pion-reader", target, [sharedFile, "feedface00000000000000000000000000000000"]);
    const nextStation = keyWithMutatedTree(baseTree, "station-pion", target, [sharedFile, "feedface00000000000000000000000000000000"]);
    assert.notEqual(nextReader, baseReader, "editing shared sql_db MUST change pion-reader key");
    assert.notEqual(nextStation, baseStation, "editing shared sql_db MUST change station-pion key");
  }
});

test("scripts/check.sh Pion static guards reject negative mutations and accept clean code", { skip: process.platform === "win32" }, (t) => {
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

  // Minimal isolated git repo containing check.sh, mesh-base.ts, and stubs for unrelated top-level steps.
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

  // Clean code passes.
  const clean = runCheckOn("pub fn ok() -> Int { 42 }\n");
  assert.equal(clean.status, 0, `expected clean code to pass:\n${clean.stdout}\n${clean.stderr}`);

  // 1. Unmarked timer fails; marked with `timer:` passes.
  const badTimer = runCheckOn("pub fn poll() -> Unit { Effect::repeat(100) }\n");
  assert.notEqual(badTimer.status, 0, "unmarked timer must fail check.sh");
  assert.match(badTimer.stdout + badTimer.stderr, /no polling timers without timer:/);

  const goodTimer = runCheckOn("pub fn poll() -> Unit { Effect::repeat(100) // timer: heartbeat\n}\n");
  assert.equal(goodTimer.status, 0, `marked timer should pass:\n${goodTimer.stdout}\n${goodTimer.stderr}`);

  // 2. proc.run fails; unmarked shell_sync fails; marked sync: passes.
  const badProcRun = runCheckOn('pub fn run_it() -> String { "proc.run" }\n');
  assert.notEqual(badProcRun.status, 0, "proc.run must fail check.sh");
  assert.match(badProcRun.stdout + badProcRun.stderr, /no proc\.run on main loop/);

  const badSync = runCheckOn("pub fn blocking() -> Unit { shell_sync(\"fs.meta\", \"{}\") }\n");
  assert.notEqual(badSync.status, 0, "unmarked shell_sync must fail check.sh");
  assert.match(badSync.stdout + badSync.stderr, /no unmarked blocking shell sync calls/);

  const goodSync = runCheckOn("pub fn blocking() -> Unit { shell_sync(\"fs.meta\", \"{}\") // sync: startup\n}\n");
  assert.equal(goodSync.status, 0, `marked sync should pass:\n${goodSync.stdout}\n${goodSync.stderr}`);

  // 3. Raw SQLite transaction SQL fails.
  const badSql = runCheckOn('pub fn bad_tx() -> String { "BEGIN IMMEDIATE" }\n');
  assert.notEqual(badSql.status, 0, "raw BEGIN IMMEDIATE must fail check.sh");
  assert.match(badSql.stdout + badSql.stderr, /no raw SQLite transaction SQL/);

  // 4. Non-local listener fails; loopback 127.0.0.1 passes; tunnel name fails.
  const badListen = runCheckOn('pub fn serve() -> Unit { tcp_listen("0.0.0.0:4760") }\n');
  assert.notEqual(badListen.status, 0, "non-local listener must fail check.sh");
  assert.match(badListen.stdout + badListen.stderr, /listeners on this machine only/);

  const goodListen = runCheckOn('pub fn serve() -> Unit { tcp_listen("127.0.0.1:4760") }\n');
  assert.equal(goodListen.status, 0, `127.0.0.1 listener should pass:\n${goodListen.stdout}\n${goodListen.stderr}`);

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

  // Clean mesh_wire passes (even with still.fail in a comment).
  put("pion/station-main/packages/mesh_wire/pion.toml", "[package]\nname = \"mesh_wire\"\n[dependencies]\nbase_codec = { workspace = true }\n");
  put("pion/station-main/packages/mesh_wire/src/wire.pion", '// comment mentioning still.fail is allowed\nimport "base_codec"\npub fn ok() -> Int { 1 }\n');
  assert.equal(runMeshBase().status, 0, "clean mesh_wire should pass mesh-base.ts");

  // Importing a station-domain package fails.
  put("pion/station-main/packages/mesh_wire/src/wire.pion", 'import "station_cloud"\npub fn bad() -> Int { 1 }\n');
  const badImport = runMeshBase();
  assert.notEqual(badImport.status, 0, "mesh_wire importing station_cloud must fail");
  assert.match(badImport.stdout, /imports station_cloud/);

  // Mentioning still.fail in code fails.
  put("pion/station-main/packages/mesh_wire/src/wire.pion", 'import "base_codec"\npub fn bad() -> String { "stillfail" }\n');
  const badName = runMeshBase();
  assert.notEqual(badName.status, 0, "mesh_wire mentioning stillfail in code must fail");
  assert.match(badName.stdout, /says still\.fail's name/);
});
