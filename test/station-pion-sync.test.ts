import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";
import {
  isPionStationSource,
  judge,
  nodeOnlyReasonsInMessage,
  parseChangedPaths,
  reasonRefused,
  requiresPionSync,
} from "../scripts/station-pion-sync.ts";

const SCRIPT = resolve(import.meta.dirname, "..", "scripts", "station-pion-sync.ts");

test("requiresPionSync targets live station/src TS files and exempts reader/heap/tests/docs", () => {
  assert.equal(requiresPionSync("station/src/vault/store.ts"), true);
  assert.equal(requiresPionSync("station/src/api/events.ts"), true);
  assert.equal(requiresPionSync("station/src/agents/agy.ts"), true);
  assert.equal(requiresPionSync("station/src/read/pool.ts"), false);
  assert.equal(requiresPionSync("station/src/ops/heap.ts"), false);
  assert.equal(requiresPionSync("station/src/vault/store.test.ts"), false);
  assert.equal(requiresPionSync("station/src/AGENTS.md"), false);
  assert.equal(requiresPionSync("pion/station-main/packages/station_vault/src/vault.pion"), false);
});

test("isPionStationSource requires .pion/.c/.h source files under pion/station-main/", () => {
  assert.equal(isPionStationSource("pion/station-main/packages/station_vault/src/vault.pion"), true);
  assert.equal(isPionStationSource("pion/station-main/packages/station_sys/c/station_sys.c"), true);
  assert.equal(isPionStationSource("pion/station-main/packages/station_sys/c/station_sys.h"), true);
  assert.equal(isPionStationSource("pion/station-main/AGENTS.md"), false);
  assert.equal(isPionStationSource("pion/station/packages/base/src/base.pion"), false);
});

test("parseChangedPaths ignores pure R100 renames and keeps modified renames/adds/mods", () => {
  const nul = [
    "M",
    "station/src/a.ts",
    "R100",
    "station/src/old.ts",
    "station/src/moved.ts",
    "R085",
    "station/src/x.ts",
    "station/src/y.ts",
    "A",
    "pion/station-main/packages/station_vault/src/v.pion",
    "",
  ].join("\0");
  assert.deepEqual(parseChangedPaths(nul), [
    "station/src/a.ts",
    "station/src/y.ts",
    "pion/station-main/packages/station_vault/src/v.pion",
  ]);
});

test("nodeOnlyReasonsInMessage enforces strict case-sensitive trailer block parsing", () => {
  // Valid trailer in final paragraph (with git comment stripped)
  assert.deepEqual(
    nodeOnlyReasonsInMessage(
      "fix(station): work around Node 22 leak\n\nBody text.\n\nNode-Station-Only: Node 22 EventEmitter listener cap workaround\n# comment\n",
    ),
    ["Node-Station-Only: Node 22 EventEmitter listener cap workaround".replace(/^Node-Station-Only: /, "")],
  );
  // Valid trailer before git commit -v scissors line + verbose diff
  assert.deepEqual(
    nodeOnlyReasonsInMessage(
      "fix(station): verbose commit\n\nNode-Station-Only: Node-only V8 heap snapshot API with no Pion equivalent\n# ------------------------ >8 ------------------------\ndiff --git a/station/src/a.ts b/station/src/a.ts\n+export const x = 1;\n",
    ),
    ["Node-only V8 heap snapshot API with no Pion equivalent"],
  );
  // Valid trailer alongside git cherry-pick -x provenance line
  assert.deepEqual(
    nodeOnlyReasonsInMessage(
      "fix(station): cherry picked fix\n\nNode-Station-Only: Node 22 EventEmitter listener cap workaround\n(cherry picked from commit 0123456789abcdef0123456789abcdef01234567)\n",
    ),
    ["Node 22 EventEmitter listener cap workaround"],
  );
  // Indented, quoted, wrong case, or mid-body lines must NOT be accepted as trailers
  assert.deepEqual(
    nodeOnlyReasonsInMessage("fix(station): x\n\n  Node-Station-Only: indented fake trailer"),
    [],
  );
  assert.deepEqual(
    nodeOnlyReasonsInMessage("fix(station): x\n\n> Node-Station-Only: quoted fake trailer"),
    [],
  );
  assert.deepEqual(
    nodeOnlyReasonsInMessage("fix(station): x\n\nnode-station-only: lowercase wrong key name"),
    [],
  );
  assert.deepEqual(
    nodeOnlyReasonsInMessage(
      "fix(station): x\n\nNode-Station-Only: mid-body prose\n\nActual final paragraph is prose.",
    ),
    [],
  );
  assert.deepEqual(
    nodeOnlyReasonsInMessage(
      "fix(station): x\n\nSome prose line\nNode-Station-Only: mixed with prose in same paragraph",
    ),
    [],
  );
  // GitHub single-commit squash with `---------` + `Co-authored-by:` footer
  assert.deepEqual(
    nodeOnlyReasonsInMessage(
      "fix(station): shutdown cleanup (#9142)\n\nBody.\n\nNode-Station-Only: Node Effect fiber teardown has no Pion counterpart\n\n---------\n\nCo-authored-by: Bot <bot@example.com>\n",
    ),
    ["Node Effect fiber teardown has no Pion counterpart"],
  );
  // GitHub multi-commit squash (`* <subject>` sections + `---------` + `Co-authored-by:`)
  assert.deepEqual(
    nodeOnlyReasonsInMessage(
      [
        "fix(station): shutdown cleanup (#9142)",
        "",
        "* fix(station): first commit",
        "",
        "Details.",
        "",
        "Node-Station-Only: Node Effect acquireUseRelease cleanup for MbBackfill",
        "",
        "* docs: update comment only",
        "",
        "No trailer on the second commit.",
        "",
        "---------",
        "",
        "Co-authored-by: Bot <bot@example.com>",
        "",
      ].join("\n"),
    ),
    ["Node Effect acquireUseRelease cleanup for MbBackfill"],
  );
  // Non-squash commit with `* ` bullets and mid-body fake trailer must still be rejected
  assert.deepEqual(
    nodeOnlyReasonsInMessage(
      "fix(station): x\n\n* bullet 1\n\nNode-Station-Only: mid-body fake trailer\n\n* bullet 2\n\nProse ending.\n",
    ),
    [],
  );
  // Squash commit with mid-body fake trailer followed by prose inside a `* ` section must still be rejected
  assert.deepEqual(
    nodeOnlyReasonsInMessage(
      "fix(station): x (#9142)\n\n* fix(station): c1\n\nNode-Station-Only: mid-body fake trailer\n\nTrailing prose in c1.\n\n---------\n\nCo-authored-by: Bot <bot@example.com>\n",
    ),
    [],
  );
});

test("judge allows synced changes, exempt paths, and explicit trailers; refuses drift and vague reasons", () => {
  assert.equal(judge(["station/src/vault/store.ts"], ["feat(vault): add join"]).ok, false);
  assert.equal(judge(["station/src/vault/store.ts", "pion/station-main/AGENTS.md"], ["feat(vault): add join"]).ok, false);
  assert.equal(
    judge(["station/src/vault/store.ts", "pion/station-main/packages/station_vault/src/vault.pion"], ["feat(vault): add join"]).ok,
    true,
  );
  assert.equal(judge(["station/src/read/pool.ts", "station/src/ops/heap.ts"], ["perf(station): reader pool"]).ok, true);

  const vague = judge(["station/src/api/events.ts"], ["perf(station): events\n\nNode-Station-Only: later we will port this"]);
  assert.equal(vague.ok, false);
  assert.equal(vague.refusedReasons.length, 1);

  const short = judge(["station/src/api/events.ts"], ["fix(station): node\n\nNode-Station-Only: node fix"]);
  assert.equal(short.ok, false);
  assert.equal(short.refusedReasons.length, 1);

  const valid = judge(
    ["station/src/api/events.ts"],
    ["fix(station): work around Node 22 EventEmitter leak\n\nNode-Station-Only: Node 22 EventEmitter listener cap workaround, no Pion equivalent"],
  );
  assert.equal(valid.ok, true);
  assert.match(valid.exemptedBy ?? "", /EventEmitter/);
  assert.equal(reasonRefused("Node 22 timer unref fix"), undefined);
  assert.equal(reasonRefused("Node-only V8 heap snapshot API with no Pion equivalent"), undefined);
});

test("CLI enforces PR-level semantics across multi-commit PRs, amend, merge from origin/main, renames, and deletions", () => {
  const dir = mkdtempSync(join(tmpdir(), "station-pion-sync-"));
  const cleanEnv: NodeJS.ProcessEnv = { ...process.env };
  for (const k of Object.keys(cleanEnv)) {
    if (k.startsWith("GIT_")) delete cleanEnv[k];
  }
  const git = (args: string[]) => execFileSync("git", args, { cwd: dir, env: cleanEnv, encoding: "utf8" });
  const runGuard = (args: string[], extraEnv?: Record<string, string>) => {
    try {
      execFileSync(process.execPath, [SCRIPT, ...args], {
        cwd: dir,
        env: { ...cleanEnv, ...extraEnv },
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      });
      return 0;
    } catch (e) {
      return (e as { status?: number }).status ?? 1;
    }
  };
  try {
    git(["init", "-q", "-b", "main"]);
    git(["config", "user.email", "test@example.com"]);
    git(["config", "user.name", "Test"]);
    mkdirSync(join(dir, "scripts"), { recursive: true });
    mkdirSync(join(dir, "station/src/vault"), { recursive: true });
    mkdirSync(join(dir, "pion/station-main/packages/station_vault/src"), { recursive: true });
    writeFileSync(join(dir, "scripts/station-pion-sync.ts"), "// marker\n");
    writeFileSync(join(dir, "station/src/vault/store.ts"), "export const v = 1;\n");
    writeFileSync(join(dir, "station/src/vault/rename-me.ts"), "export const stable = 42;\n");
    writeFileSync(join(dir, "station/src/vault/obsolete.ts"), "export const old = 1;\n");
    writeFileSync(join(dir, "pion/station-main/packages/station_vault/src/vault.pion"), "pub let v = 1\n");
    git(["add", "."]);
    git(["commit", "-q", "-m", "chore: initial"]);
    const mainSha = git(["rev-parse", "HEAD"]).trim();
    git(["update-ref", "refs/remotes/origin/main", mainSha]);

    const msgFile = join(dir, ".git", "COMMIT_EDITMSG");

    // 1. Unilateral staged station/src edit is refused (even if old bypass env var is set).
    git(["checkout", "-q", "-b", "feat/unilateral"]);
    writeFileSync(join(dir, "station/src/vault/store.ts"), "export const v = 2;\n");
    git(["add", "station/src/vault/store.ts"]);
    writeFileSync(msgFile, "feat(vault): unilateral node edit\n");
    assert.equal(runGuard(["HEAD", "index", msgFile]), 1);
    assert.equal(runGuard(["HEAD", "index", msgFile], { STILLFAIL_ALLOW_NODE_ONLY_STATION: "1" }), 1);

    // 2. Indented fake trailer in body is refused; valid trailer in trailer block passes
    //    (including git commit -v scissors line + diff and git cherry-pick -x provenance).
    writeFileSync(msgFile, "fix(vault): fake\n\n  Node-Station-Only: indented body text is not a trailer\n");
    assert.equal(runGuard(["HEAD", "index", msgFile]), 1);
    writeFileSync(
      msgFile,
      "fix(vault): verbose commit\n\nNode-Station-Only: Node-only V8 heap snapshot API with no Pion equivalent\n# ------------------------ >8 ------------------------\ndiff --git a/station/src/vault/store.ts b/station/src/vault/store.ts\n+export const v = 2;\n",
    );
    assert.equal(runGuard(["HEAD", "index", msgFile]), 0);
    writeFileSync(
      msgFile,
      "fix(vault): node only\n\nNode-Station-Only: Node crypto Buffer polyfill bug with no Pion counterpart\n(cherry picked from commit 0123456789abcdef0123456789abcdef01234567)\n",
    );
    assert.equal(runGuard(["HEAD", "index", msgFile]), 0);
    git(["commit", "-q", "-F", msgFile]);
    const exemptedTip = git(["rev-parse", "HEAD"]).trim();

    // 3. Scenario (b): Merging origin/main into a branch with an earlier valid Node-Station-Only trailer passes.
    git(["checkout", "-q", "main"]);
    writeFileSync(join(dir, "README.md"), "upstream change\n");
    git(["add", "README.md"]);
    git(["commit", "-q", "-m", "docs: upstream main"]);
    const newMainSha = git(["rev-parse", "HEAD"]).trim();
    git(["update-ref", "refs/remotes/origin/main", newMainSha]);

    git(["checkout", "-q", "feat/unilateral"]);
    git(["merge", "--no-commit", "--no-ff", "origin/main"]);
    writeFileSync(msgFile, "Merge remote-tracking branch 'origin/main' into feat/unilateral\n");
    assert.equal(runGuard(["HEAD", "index", msgFile]), 0);
    git(["merge", "--abort"]);
    assert.equal(runGuard([`${mainSha}..${exemptedTip}`]), 0);

    // 4. Scenarios (a) & (d): First commit syncs Pion, follow-up review commit touches only station/src ->
    //    BOTH commit-msg (HEAD index) AND incremental pre-push (remoteSha..HEAD) pass!
    git(["checkout", "-q", "-b", "feat/multi-commit", "origin/main"]);
    writeFileSync(join(dir, "pion/station-main/packages/station_vault/src/vault.pion"), "pub let v = 10\n");
    git(["add", "pion/station-main/packages/station_vault/src/vault.pion"]);
    git(["commit", "-q", "-m", "feat(pion): add vault feature"]);
    const afterPionSha = git(["rev-parse", "HEAD"]).trim();

    writeFileSync(join(dir, "station/src/vault/store.ts"), "export const v = 10;\n");
    git(["add", "station/src/vault/store.ts"]);
    writeFileSync(msgFile, "feat(station): wire matching ts change\n");
    assert.equal(runGuard(["HEAD", "index", msgFile]), 0);
    git(["commit", "-q", "-F", msgFile]);
    assert.equal(runGuard([`${afterPionSha}..HEAD`]), 0);

    // Follow-up review tweak touching only station/src (scenario a)
    const remoteSha = git(["rev-parse", "HEAD"]).trim();
    writeFileSync(join(dir, "station/src/vault/store.ts"), "export const v = 11;\n");
    git(["add", "station/src/vault/store.ts"]);
    writeFileSync(msgFile, "fix(station): address review nit\n");
    assert.equal(runGuard(["HEAD", "index", msgFile]), 0);
    git(["commit", "-q", "-F", msgFile]);
    assert.equal(runGuard([`${remoteSha}..HEAD`]), 0);

    // 5. Scenario (c): --amend adding a station tweak to a synced commit passes.
    git(["checkout", "-q", "-b", "feat/amend", "origin/main"]);
    writeFileSync(join(dir, "pion/station-main/packages/station_vault/src/vault.pion"), "pub let v = 20\n");
    writeFileSync(join(dir, "station/src/vault/store.ts"), "export const v = 20;\n");
    git(["add", "."]);
    git(["commit", "-q", "-m", "feat(vault): synced commit"]);
    writeFileSync(join(dir, "station/src/vault/store.ts"), "export const v = 21;\n");
    git(["add", "station/src/vault/store.ts"]);
    writeFileSync(msgFile, "feat(vault): synced commit (amended)\n");
    assert.equal(runGuard(["HEAD", "index", msgFile]), 0);
    git(["commit", "--amend", "-q", "-F", msgFile]);

    // 6. Scenario (e): Pure R100 rename and pure deletion pass without touching pion/station-main.
    git(["checkout", "-q", "-b", "feat/rename-delete", "origin/main"]);
    git(["mv", "station/src/vault/rename-me.ts", "station/src/vault/renamed.ts"]);
    git(["rm", "-q", "station/src/vault/obsolete.ts"]);
    writeFileSync(msgFile, "chore(station): rename and remove obsolete files\n");
    assert.equal(runGuard(["HEAD", "index", msgFile]), 0);
    git(["commit", "-q", "-F", msgFile]);
    assert.equal(runGuard([`${newMainSha}..HEAD`]), 0);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
