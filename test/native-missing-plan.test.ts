import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import {
  defaults, inputsByGit, inputsIn, key, missingWanted, pair, partNames, pathspec, targetsOf, tree,
} from "../scripts/native.ts";

// What plan's natives step (pipeline.yml) leans on: native.ts reads the checkout's keys off one git listing as git
// would per part, and one `missing` answers every list plan splits.

const root = fileURLToPath(new URL("..", import.meta.url));

test("every part's key off one listing of the checkout is git's own, file by file", () => {
  const listed = tree(root);
  const byGit = new Map<string, [string, string][]>();
  const git = (paths: string[]) => byGit.get(JSON.stringify(paths)) ?? byGit.set(JSON.stringify(paths), inputsByGit(paths)).get(JSON.stringify(paths))!;
  let parts = 0;
  for (const part of partNames()) for (const target of targetsOf(part)) {
    const ours = key(part, target as never, (paths) => {
      const off = inputsIn(listed, paths);
      assert.ok(off, `${part}:${target}: a pathspec the listing does not answer (${paths.join(" ")})`);
      assert.deepEqual(off, git(paths), `${part}:${target}`);
      return off;
    });
    assert.equal(ours, key(part, target as never, git), `${part}:${target}`);
    parts++;
  }
  assert.ok(parts > 40, `${parts} parts and targets`);
});

test("one part's key asks git of its own paths alone, and is the one off a listing of the checkout", (t) => {
  const listed = tree(root);
  const dir = mkdtempSync(join(tmpdir(), "native-one-key-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const calls = join(dir, "calls"), git = execFileSync("which", ["git"], { encoding: "utf8" }).trim();
  writeFileSync(join(dir, "git"), `#!/bin/sh\nprintf '%s ' "$@" >> "${calls}"; echo >> "${calls}"\nexec "${git}" "$@"\n`);
  chmodSync(join(dir, "git"), 0o755);
  for (const [part, target] of [["shell-apple", "ios-arm64"], ["reader", "darwin-arm64"]] as const) {
    const ours = key(part, target);
    assert.equal(ours, key(part, target, inputsByGit), `${part}:${target}`);
    assert.equal(ours, key(part, target, (paths) => inputsIn(listed, paths)!), `${part}:${target}`);
    rmSync(calls, { force: true });
    const run = spawnSync(process.execPath, [join(root, "scripts/native.ts"), "key", part, target],
      { cwd: root, encoding: "utf8", env: { ...process.env, PATH: `${dir}:${process.env.PATH}` } });
    assert.equal(run.status, 0, run.stderr);
    assert.equal(run.stdout.trim(), ours, `${part}:${target}`);
    const lists = readFileSync(calls, "utf8").split("\n").filter((c) => c.startsWith("ls-files "));
    assert.ok(lists.length >= 2, lists.join("\n"));
    for (const c of lists) assert.match(c, / -- \S/, c);
  }
});

test("a listing with changed, new, deleted, staged and ignored files is what git lists of each pathspec", (t) => {
  const dir = mkdtempSync(join(tmpdir(), "native-inputs-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const g = (...args: string[]) => execFileSync("git", args, { cwd: dir, encoding: "utf8" });
  const put = (path: string, text: string) => { mkdirSync(dirname(join(dir, path)), { recursive: true }); writeFileSync(join(dir, path), text); };
  g("init", "-q");
  g("config", "user.email", "t@example.com"); g("config", "user.name", "t"); g("config", "commit.gpgsign", "false");
  for (const f of ["a.txt", "src/lib.mbt", "src/lib_test.mbt", "src/sub/x_wbtest.mbt", "src/sub/pkg.generated.mbti",
    "src/sub/keep.rs", "src/tests/t.rs", "src/examples/e.rs", "src2/other.txt", "tool/run.mjs", "tool/run.test.mjs",
    "tool/deep/run.test.mjs", "gone.txt", "src/gone.mbt", ".gitignore"]) put(f, f === ".gitignore" ? "*.log\nbuild/\n" : `${f}\n`);
  g("add", "-A"); g("commit", "-qm", "one");
  put("src/lib.mbt", "changed\n");
  put("src/new.mbt", "new\n");
  put("src/new_test.mbt", "new test\n");
  put("src/sub/deeper/fresh.rs", "fresh\n");
  put("src/debug.log", "ignored\n");
  put("src/build/out.o", "ignored\n");
  put("src2/staged.txt", "staged\n"); g("add", "src2/staged.txt");
  put("src2/staged.txt", "staged, then changed\n");
  rmSync(join(dir, "gone.txt")); rmSync(join(dir, "src/gone.mbt"));
  const listed = tree(dir);
  const specs = [
    ["src"], ["src2"], ["a.txt", "gone.txt"], ["src", "src2", "tool", "a.txt"], ["nothing/here"], ["src/sub"],
    ["src", ":(exclude,glob)**/*_test.mbt", ":(exclude,glob)**/*_wbtest.mbt", ":(exclude,glob)**/pkg.generated.mbti"],
    ["src", ":(exclude,glob)src/**/*.rs"], ["tool", ":(exclude,glob)tool/*test.mjs"], ["src/lib.mbt"], ["sr"],
  ];
  for (const paths of specs) assert.deepEqual(inputsIn(listed, paths), inputsByGit(paths, dir), paths.join(" "));
  // (what it does not answer as git does goes to git)
  for (const paths of [["."], ["src/"], ["src/*.mbt"], [":(glob)src"], [":!src"], ["./src"], [""], [":(exclude,glob)src/[ab].mbt", "src"],
    [":(exclude,glob)**/*_test.mbt"]]) assert.equal(pathspec(paths), null, paths.join(" "));
});

const BRANCH = Object.fromEntries([...readFileSync(join(root, ".github/workflows/pipeline.yml"), "utf8")
  .matchAll(/^ {2}(BRANCH_[A-Z_]+): (.+)$/gm)].map((m) => [m[1]!, m[2]!.trim().split(/\s+/)]));

test("plan splits one missing by what its lists name, as each list asked alone did", () => {
  // Apple's are the darwin-* and ios-* targets, which plan's step tells apart by name; shell-station:linux-x64,
  // which it asks after on main, is one of --linux's.
  const mac = defaults(false, true, false), linux = defaults(false, false, true);
  assert.ok(mac.length > 0 && mac.every(([, t]) => /^(darwin|ios)-/.test(t)), JSON.stringify(mac));
  assert.ok(linux.length > 0 && linux.every(([, t]) => !/^(darwin|ios)-/.test(t)), JSON.stringify(linux));
  assert.ok(linux.some(([p, t]) => p === "shell-station" && t === "linux-x64"));
  assert.deepEqual(missingWanted(["--linux", "--mac"]).map(String).sort(), [...mac, ...linux].map(String).sort());
  // The BRANCH_ lists say each part:target as missing answers it.
  assert.deepEqual(Object.keys(BRANCH).sort(), ["BRANCH_HARNESS", "BRANCH_MAC_NATIVES", "BRANCH_MAC_READER", "BRANCH_NATIVES", "BRANCH_WIN_READER"]);
  for (const list of Object.values(BRANCH)) for (const a of list) assert.equal(pair(a.split(":")).join(":"), a);
  // One flag alone, parts alone, or neither: what missing took before.
  for (const [w, m, l] of [[true, false, false], [false, true, false], [false, false, true]] as const) {
    assert.deepEqual(missingWanted([w ? "--windows" : m ? "--mac" : "--linux"]), defaults(w, m, l));
  }
  assert.deepEqual(missingWanted([]), defaults(false, false, false));
  assert.deepEqual(missingWanted(BRANCH.BRANCH_NATIVES!), BRANCH.BRANCH_NATIVES!.map((a) => pair(a.split(":"))));
  assert.deepEqual(missingWanted(["reader:linux-x64", "--linux", "reader:linux-x64"]).filter(([p, t]) => p === "reader" && t === "linux-x64").length, 1);
});

test("one missing for every list plan asks lists the release once and answers each part that both lack", (t) => {
  const dir = mkdtempSync(join(tmpdir(), "native-missing-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const requests = join(dir, "requests"), preload = join(dir, "preload.mjs");
  // (the release has every part's asset but two, and the store none of those but one of them)
  const lacking = ["mesh-darwin-arm64-", "reader-linux-x64-", "shell-station-linux-x64-"];
  writeFileSync(preload, `
    import { appendFileSync } from 'node:fs';
    const lacking = ${JSON.stringify(lacking)};
    globalThis.fetch = async (at, init = {}) => {
      const url = new URL(at);
      const name = url.pathname.split('/').at(-1);
      appendFileSync(${JSON.stringify(requests)}, url.hostname + ' ' + url.pathname + '\\n');
      if (url.hostname === 'app.still.fail') return new Response(lacking.some((l) => name.startsWith(l)) ? '' : 'a', { status: lacking.some((l) => name.startsWith(l)) ? 404 : 206 });
      if (url.hostname === 'api.github.com' && url.pathname.endsWith('/releases/tags/native-artifacts')) return Response.json({ assets: [] });
      throw new Error('unexpected request ' + at);
    };
  `);
  const missing = (...args: string[]) => {
    rmSync(requests, { force: true });
    const run = spawnSync(process.execPath, ["--import", preload, join(root, "scripts/native.ts"), "missing", ...args], {
      cwd: root, encoding: "utf8", env: { ...process.env, STILLFAIL_NATIVE_RETRY_MS: "0", STILLFAIL_DIRECT_DNS: "",
        STILLFAIL_NATIVE_STORE: "https://app.still.fail/releases/natives", STILLFAIL_NATIVE_REPO: "AFK-surf/monoid",
        STILLFAIL_NATIVE_RELEASE: "native-artifacts", STILLFAIL_NATIVE_GITHUB: "https://github.com",
        STILLFAIL_NATIVE_GITHUB_API: "https://api.github.com", GH_TOKEN: "native-test-token", GITHUB_TOKEN: "" },
    });
    assert.equal(run.status, 0, run.stderr);
    const asked = readFileSync(requests, "utf8").split("\n").filter(Boolean);
    assert.equal(asked.filter((r) => r.startsWith("api.github.com ")).length, 1, asked.join("\n"));
    return run.stdout.split("\n").filter(Boolean);
  };
  // main's: --linux and --mac at once, Apple's first
  assert.deepEqual(missing("--linux", "--mac"), ["mesh:darwin-arm64", "reader:linux-x64", "shell-station:linux-x64"]);
  assert.deepEqual(missing("--mac"), ["mesh:darwin-arm64"]);
  assert.deepEqual(missing("--linux"), ["reader:linux-x64", "shell-station:linux-x64"]);
  // a branch's: every list and the runners' shell-station, each once
  const want = [...BRANCH.BRANCH_NATIVES!, ...BRANCH.BRANCH_WIN_READER!, ...BRANCH.BRANCH_HARNESS!, ...BRANCH.BRANCH_MAC_NATIVES!,
    ...BRANCH.BRANCH_MAC_READER!, "shell-station:linux-x64", "shell-station:win32-x64", "reader:linux-x64"];
  assert.deepEqual(missing(...want), ["shell-station:linux-x64", "reader:linux-x64", "mesh:darwin-arm64"]);
});

test("plan.sh triggers station on pion-reader production inputs and ignores its tests and docs", { skip: process.platform === "win32" }, () => {
  const cases: [string, boolean][] = [
    ["pion/station/TOOLCHAIN", true],
    ["pion/station/pion.toml", true],
    ["pion/station/pion.lock", true],
    ["pion/station/scripts/build.sh", true],
    ["pion/station/scripts/ensure-pionc.sh", true],
    ["pion/station/packages/smoke/src/main.pion", true],
    ["pion/station/packages/readops_core/src/selftest.pion", true],
    ["pion/base/packages/base_codec/src/lib.pion", true],
    ["pion/station/packages/readops_chats/src/readops_chats_test.pion", false],
    ["pion/station/packages/host_shim/native/host_shim_test.c", false],
    ["pion/base/packages/base_codec/src/lib_test.pion", false],
    ["pion/station/AGENTS.md", false],
    ["pion/station/README.md", false],
  ];
  const script = `PLAN_SOURCE=1; . scripts/plan.sh; range=
while IFS= read -r changed; do decide; echo "$changed $station"; done`;
  const out = execFileSync("bash", ["-c", script], {
    cwd: root,
    input: cases.map(([p]) => p).join("\n") + "\n",
    encoding: "utf8",
  }).trim().split("\n");
  for (const [i, [path, expected]] of cases.entries()) {
    assert.equal(out[i], `${path} ${expected}`, path);
  }
});
