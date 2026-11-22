import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { checkStationParity, hasParityTrailer, isStationProdTs, NODE_ONLY_FILES } from "../scripts/station-parity.ts";

const scriptPath = join(import.meta.dirname, "..", "scripts", "station-parity.ts");

test("isStationProdTs identifies production station/src/*.ts and excludes tests and NODE_ONLY_FILES", () => {
  assert.equal(isStationProdTs("station/src/main.ts"), true);
  assert.equal(isStationProdTs("station/src/cli.ts"), true);
  assert.equal(isStationProdTs("station/src/sessions/hub.ts"), true);
  assert.equal(isStationProdTs("station/src/sessions/hub.test.ts"), false);
  assert.equal(isStationProdTs("station/AGENTS.md"), false);
  assert.equal(isStationProdTs("station/test/mb-station-contracts.test.ts"), false);
  assert.equal(isStationProdTs("station/mb/src/station_main/run.mbt"), false);
  for (const f of NODE_ONLY_FILES) {
    assert.equal(isStationProdTs(f), false, `${f} should be exempt`);
  }
});

test("hasParityTrailer requires a standalone line with a meaningful non-placeholder reason", () => {
  assert.equal(hasParityTrailer("fix(station): foo\n\nStation-parity: node-only (Effect fiber glue)\n"), true);
  assert.equal(hasParityTrailer("Station-parity: already in station/mb (#7968)"), true);
  assert.equal(hasParityTrailer("fix(station): foo\n\nStation-parity:\n"), false);
  assert.equal(hasParityTrailer("fix(station): foo\n\nStation-parity:   \t \n"), false);
  assert.equal(hasParityTrailer("fix(station): see Station-parity: node-only"), false);
  assert.equal(hasParityTrailer("fix(station): foo\n"), false);
  for (const vague of ["none", "n/a", "NA", "ok", "wip", "TODO", "tbd", "short", "12345"]) {
    assert.equal(hasParityTrailer(`fix(station): foo\n\nStation-parity: ${vague}\n`), false, `should reject "${vague}"`);
  }
  // One meaningful trailer among multiple commits passes even if an earlier commit had a placeholder
  assert.equal(
    hasParityTrailer("Station-parity: todo\n\nStation-parity: already in station/mb/src/session_hub\n"),
    true,
  );
});

test("checkStationParity enforces station/mb/ sync or Station-parity trailer", () => {
  // Production station/src/ only -> fail
  const fail = checkStationParity(["station/src/sessions/hub.ts"], "fix(station): change hub\n");
  assert.equal(fail.ok, false);
  assert.deepEqual(fail.prodTs, ["station/src/sessions/hub.ts"]);

  // main.ts and cli.ts are NOT exempt
  assert.equal(checkStationParity(["station/src/main.ts"], "fix(station): main").ok, false);
  assert.equal(checkStationParity(["station/src/cli.ts"], "fix(station): cli").ok, false);

  // With station/mb/ change -> pass
  const withMb = checkStationParity(
    ["station/src/sessions/hub.ts", "station/mb/src/station_main/live_p5_2_main.mbt"],
    "fix(station): sync both\n",
  );
  assert.equal(withMb.ok, true);
  assert.equal(withMb.hasMb, true);

  // With non-empty trailer -> pass
  const withTrailer = checkStationParity(
    ["station/src/sessions/hub.ts"],
    "fix(station): node fix\n\nStation-parity: already in station/mb/src/session_hub\n",
  );
  assert.equal(withTrailer.ok, true);
  assert.equal(withTrailer.hasTrailer, true);

  // With empty trailer -> fail
  assert.equal(
    checkStationParity(["station/src/sessions/hub.ts"], "fix(station): node fix\n\nStation-parity:   \n").ok,
    false,
  );

  // Only NODE_ONLY_FILES -> pass
  assert.equal(checkStationParity([...NODE_ONLY_FILES], "refactor(station): bridge cleanup\n").ok, true);

  // Only test files or AGENTS.md -> pass
  assert.equal(
    checkStationParity(["station/src/sessions/hub.test.ts", "station/AGENTS.md"], "docs(station): update rules\n").ok,
    true,
  );
});

test("CLI integration in a temporary git repository (HEAD index, base..head, base...head, base head)", () => {
  const dir = mkdtempSync(join(tmpdir(), "station-parity-test-"));
  const write = (rel: string, content: string) => {
    const p = join(dir, rel);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, content);
  };
  // Strip outer git hook env vars (GIT_DIR, GIT_INDEX_FILE, GIT_WORK_TREE, ...) so this test passes inside pre-commit.
  const baseEnv: NodeJS.ProcessEnv = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (!k.startsWith("GIT_")) baseEnv[k] = v;
  }
  const gitEnv: NodeJS.ProcessEnv = {
    ...baseEnv,
    GIT_AUTHOR_NAME: "Test",
    GIT_AUTHOR_EMAIL: "test@example.com",
    GIT_COMMITTER_NAME: "Test",
    GIT_COMMITTER_EMAIL: "test@example.com",
  };
  const git = (args: string[]) => execFileSync("git", args, { cwd: dir, encoding: "utf8", env: gitEnv });
  const run = (args: string[]) => spawnSync(process.execPath, [scriptPath, ...args], { cwd: dir, encoding: "utf8", env: baseEnv });

  try {
    git(["init", "-b", "main"]);
    write("README.md", "init\n");
    git(["add", "README.md"]);
    git(["commit", "-m", "chore: init"]);
    const preScriptBase = git(["rev-parse", "HEAD"]).trim();

    // 0. Historical guard: base predates scripts/station-parity.ts -> exit 0 even without trailer
    git(["checkout", "-b", "legacy"]);
    write("station/src/sessions/hub.ts", "export const legacy = 1;\n");
    git(["add", "station/src/sessions/hub.ts"]);
    git(["commit", "-m", "fix(station): legacy change before gate"]);
    const legacyHead = git(["rev-parse", "HEAD"]).trim();
    assert.equal(run([`${preScriptBase}..${legacyHead}`]).status, 0);
    assert.equal(run([`${preScriptBase}...${legacyHead}`]).status, 0);

    // Add scripts/station-parity.ts on main so subsequent range checks enforce the rule
    git(["checkout", "main"]);
    write("scripts/station-parity.ts", "// parity gate\n");
    git(["add", "scripts/station-parity.ts"]);
    git(["commit", "-m", "ci(station): add parity gate"]);
    const base = git(["rev-parse", "HEAD"]).trim();

    // 1. HEAD index <msg-file>: staged station/src/ without station/mb/ or trailer -> fail
    write("station/src/sessions/hub.ts", "export const x = 1;\n");
    git(["add", "station/src/sessions/hub.ts"]);
    const msgNoTrailer = join(dir, ".git", "MSG_NO_TRAILER");
    writeFileSync(msgNoTrailer, "fix(station): change hub\n");
    const r1 = run(["HEAD", "index", msgNoTrailer]);
    assert.equal(r1.status, 1, r1.stderr);
    assert.match(r1.stderr, /station\/src\/sessions\/hub\.ts/);

    // 2. HEAD index <msg-file>: with non-empty trailer -> pass
    const msgWithTrailer = join(dir, ".git", "MSG_WITH_TRAILER");
    writeFileSync(msgWithTrailer, "fix(station): change hub\n\nStation-parity: node-only test\n");
    const r2 = run(["HEAD", "index", msgWithTrailer]);
    assert.equal(r2.status, 0, r2.stderr);

    // 3. Commit without trailer on feature branch, test base..head, base...head, base head
    git(["checkout", "-b", "feat"]);
    git(["commit", "-m", "fix(station): change hub"]);
    const headNoParity = git(["rev-parse", "HEAD"]).trim();
    assert.equal(run([`${base}..${headNoParity}`]).status, 1);
    assert.equal(run([`main...${headNoParity}`]).status, 1);
    assert.equal(run([base, headNoParity]).status, 1);

    // 4. Add a commit with Station-parity trailer in the same range -> pass
    write("station/src/sessions/hub.ts", "export const x = 2;\n");
    git(["add", "station/src/sessions/hub.ts"]);
    git(["commit", "-m", "fix(station): explain parity\n\nStation-parity: already in station/mb"]);
    const headWithTrailer = git(["rev-parse", "HEAD"]).trim();
    assert.equal(run([`${base}..${headWithTrailer}`]).status, 0);
    assert.equal(run([`main...${headWithTrailer}`]).status, 0);

    // 5. Separate branch with station/mb/ updated alongside station/src/ -> pass
    git(["checkout", "-b", "feat-mb", "main"]);
    write("station/src/sessions/hub.ts", "export const y = 1;\n");
    write("station/mb/src/station_main/live_p5_2_main.mbt", "// synced\n");
    git(["add", "station/src/sessions/hub.ts", "station/mb/src/station_main/live_p5_2_main.mbt"]);
    assert.equal(run(["HEAD", "index", msgNoTrailer]).status, 0);
    git(["commit", "-m", "fix(station): sync both tracks"]);
    assert.equal(run(["main..HEAD"]).status, 0);
    assert.equal(run(["main...HEAD"]).status, 0);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
