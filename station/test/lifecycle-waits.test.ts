// Going on in a chat with a session the machine's own Claude Code or Codex kept, and deleting a chat, wait the main
// thread on no synchronous call of node:fs (station/AGENTS.md, the main thread waits on nothing): its transcript (up to
// hundreds of MB) was copied, read whole and parsed on it to count its entries, a Codex home's rollouts walked, and a
// deleted chat's directory removed there. Counted as main-thread-waits.test.ts counts them.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { after, test } from "node:test";
import { timeFiles } from "../src/ops/file-waits.ts";
import { WAITED_MS } from "../src/ops/waits.ts";
import { continueMachineSession, deleteSession } from "../src/sessions/lifecycle.ts";
import { Rig, settle } from "./hub-fakes.ts";
import { find } from "./reference/machine.ts";
import { readTimeline } from "./reference/transcript.ts";

let at = 0;
const files = timeFiles(() => (at += WAITED_MS));
after(() => files.stop());

/// The synchronous calls of node:fs `work` made on this thread, by who made them.
async function waited<T>(work: () => Promise<T>): Promise<{ value: T; by: string[] }> {
  files.take();
  const value = await work();
  return { value, by: [...files.take().by.keys()] };
}

/// Those the parts this holds to none made themselves: going on with a machine's session and deleting a chat (what
/// they ask of others, a place looked at, is those others').
const ours = (by: string[]) => by.filter((k) => /^\S+ (copyTranscript|continueMachineSession|deleteSession|forgetMarksSoon|LiveHub\.counted)\b/.test(k));

const lines = (records: object[]) => records.map((r) => JSON.stringify(r)).join("\n") + "\n";

test("a machine's Claude Code and Codex sessions go on in chats, and those chats are deleted, waiting the main thread on no synchronous call of node:fs", async () => {
  const r = new Rig();
  try {
    const root = join(r.dir, "machine");
    const project = join(root, "app");
    mkdirSync(project, { recursive: true });
    const roots = { claude: join(root, "claude", "projects"), codex: join(root, "codex", "sessions") };
    const claudeDir = join(roots.claude, "-app");
    mkdirSync(claudeDir, { recursive: true });
    const claudeId = "11111111-aaaa-bbbb-cccc-000000000001";
    writeFileSync(
      join(claudeDir, `${claudeId}.jsonl`),
      lines([
        { type: "user", cwd: project, timestamp: "2026-09-01T00:00:02.000Z", message: { content: "fix the build" } },
        { type: "assistant", cwd: project, timestamp: "2026-09-01T00:00:03.000Z", message: { content: [{ type: "tool_use", id: "t1", name: "Bash", input: { command: "make" } }] } },
        { type: "user", cwd: project, timestamp: "2026-09-01T00:00:04.000Z", message: { content: [{ type: "tool_result", tool_use_id: "t1", content: "ok" }] } },
        { type: "assistant", cwd: project, timestamp: "2026-09-01T00:00:06.000Z", message: { model: "claude-opus-5-5", content: [{ type: "text", text: "Fixed." }] } },
      ]),
    );
    const codexId = "22222222-aaaa-bbbb-cccc-000000000001";
    const codexDir = join(roots.codex, "2026/09/02");
    mkdirSync(codexDir, { recursive: true });
    const rollout = (when: string, records: object[]) => writeFileSync(join(codexDir, `rollout-${when}-${codexId}.jsonl`), lines(records));
    rollout("2026-09-02T00-00-00", [
      { type: "session_meta", payload: { id: codexId, cwd: project } },
      { type: "response_item", timestamp: "2026-09-02T00:00:01.000Z", payload: { type: "message", role: "user", content: [{ type: "input_text", text: "add a test" }] } },
      { type: "response_item", timestamp: "2026-09-02T00:00:03.000Z", payload: { type: "message", role: "assistant", content: [{ type: "output_text", text: "Added." }] } },
    ]);
    // (another file of the same thread, which goes with it)
    rollout("2026-09-02T01-00-00", [{ type: "session_meta", payload: { id: codexId, cwd: project } }]);

    for (const [runtime, id] of [["claude", claudeId], ["codex", codexId]] as const) {
      const found = find(roots, runtime, id)!;
      const going = await waited(() => continueMachineSession(r.hub, roots, found, "local"));
      assert.deepEqual(ours(going.by), [], `${runtime}: ${going.by.join(" | ")}`);
      const [key, thread] = going.value;
      // Its transcript copied whole, and its history linked at its last entry as counted off the main thread.
      const copy = join(r.dir, "transcripts", runtime, found.path.slice((runtime === "claude" ? roots.claude : roots.codex).length + 1));
      assert.deepEqual(readFileSync(copy), readFileSync(found.path));
      if (runtime === "codex") assert.ok(existsSync(join(r.dir, "transcripts/codex/2026/09/02", `rollout-2026-09-02T01-00-00-${codexId}.jsonl`)), "the thread's other file too");
      const last = readTimeline(runtime, found.path).length - 1;
      assert.ok(r.said(thread.id)[0]!.text.endsWith(`[查看之前的对话](?history=${key}&entry=${last})`), r.said(thread.id)[0]!.text);
      await settle();

      const workspace = r.session(key).workspace;
      const gone = await waited(() => deleteSession(r.hub, key));
      assert.deepEqual(ours(gone.by), [], `${runtime}: ${gone.by.join(" | ")}`);
      assert.equal(existsSync(workspace), false, "its workspace gone");
      assert.ok(existsSync(found.path), "the machine's transcript left as it was");
    }
  } finally {
    await r.close();
  }
});
