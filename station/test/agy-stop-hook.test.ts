// The Stop hook Antigravity CLI runs when an execution loop terminates (assets/agents/agy-stop-hook.mjs;
// agents/agy.ts installs it in --gemini-dir/config/hooks.json): writes `{ fullyIdle, at }` per conversationId under
// STILLFAIL_AGY_STATE_DIR so the station knows whether an idle `agy acp` process still has background work running,
// without a subagent's Stop hook overwriting its parent's state. Always answers `{}` so it never blocks stopping.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { after, test } from "node:test";
import { AGY_STOP_COMMAND, AGY_STOP_HOOK } from "../src/agents/agy.ts";

const root = mkdtempSync(join(tmpdir(), "agy-stop-hook-"));
after(() => rmSync(root, { recursive: true, force: true }));

function runHook(input: unknown, stateDir?: string) {
  const env = { ...process.env };
  if (stateDir === undefined) delete env.STILLFAIL_AGY_STATE_DIR;
  else env.STILLFAIL_AGY_STATE_DIR = stateDir;
  const shell = process.platform === "win32" ? ["cmd", ["/c", AGY_STOP_COMMAND]] as const : ["sh", ["-c", AGY_STOP_COMMAND]] as const;
  const ran = spawnSync(shell[0], shell[1], { input: typeof input === "string" ? input : JSON.stringify(input), env });
  return { status: ran.status, out: ran.stdout.toString().trim(), err: ran.stderr.toString() };
}

test("AGY_STOP_HOOK exists and is copied into dist/ by station build", () => {
  assert.equal(basename(AGY_STOP_HOOK), "agy-stop-hook.mjs");
  assert.ok(existsSync(AGY_STOP_HOOK), AGY_STOP_HOOK);
  const build: string = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")).scripts.build;
  const copied = build.split("&&").map((step) => step.trim().split(/\s+/)).find((words) => words[0] === "cp" && words.at(-1) === "dist/" && words[1] !== "-R") ?? [];
  assert.ok(copied.includes("assets/agents/agy-stop-hook.mjs"), `agy-stop-hook.mjs missing from build: ${copied.join(" ")}`);
});

test("records fullyIdle per conversationId without letting a subagent overwrite its parent", () => {
  const stateDir = join(root, "per-conv");
  const parent = "11111111-1111-4111-8111-111111111111";
  const child = "22222222-2222-4222-8222-222222222222";

  assert.deepEqual(runHook({ conversationId: parent, hookEventName: "Stop", fullyIdle: false, terminationReason: "NO_TOOL_CALL" }, stateDir), { status: 0, out: "{}", err: "" });
  const parentState = JSON.parse(readFileSync(join(stateDir, `${parent}.json`), "utf8"));
  assert.equal(parentState.fullyIdle, false);
  assert.equal(typeof parentState.at, "number");

  // Subagent stopping with fullyIdle: true writes its own file and leaves the parent's holding state intact.
  assert.deepEqual(runHook({ conversationId: child, hookEventName: "Stop", fullyIdle: true, terminationReason: "NO_TOOL_CALL" }, stateDir), { status: 0, out: "{}", err: "" });
  assert.equal(JSON.parse(readFileSync(join(stateDir, `${parent}.json`), "utf8")).fullyIdle, false);
  assert.equal(JSON.parse(readFileSync(join(stateDir, `${child}.json`), "utf8")).fullyIdle, true);

  // Parent's later Stop with fullyIdle: true flips its own state to idle.
  assert.deepEqual(runHook({ conversationId: parent, hookEventName: "Stop", fullyIdle: true, terminationReason: "NO_TOOL_CALL" }, stateDir), { status: 0, out: "{}", err: "" });
  assert.equal(JSON.parse(readFileSync(join(stateDir, `${parent}.json`), "utf8")).fullyIdle, true);
});

test("ignores unset STILLFAIL_AGY_STATE_DIR, malformed payloads, non-Stop events, missing fullyIdle, and unsafe ids", () => {
  const stateDir = join(root, "ignored");
  assert.deepEqual(runHook({ conversationId: "abc", hookEventName: "Stop", fullyIdle: false }), { status: 0, out: "{}", err: "" });
  for (const input of [
    "",
    "not-json",
    "null",
    { conversationId: "abc", hookEventName: "PostToolUse", fullyIdle: false },
    { conversationId: "abc", hookEventName: "Stop" },
    { conversationId: "abc", hookEventName: "Stop", fullyIdle: "false" },
    { conversationId: "../escape", hookEventName: "Stop", fullyIdle: false },
    { conversationId: "", hookEventName: "Stop", fullyIdle: false },
  ]) {
    assert.deepEqual(runHook(input, stateDir), { status: 0, out: "{}", err: "" }, JSON.stringify(input));
  }
  assert.equal(existsSync(stateDir) ? readdirSync(stateDir).length : 0, 0);
});
