// A watched transcript followed by the live view (mb/src/reader/live.mbt `read_soon`), each read of what it gained done
// by the readers (read/pool.ts `tailRead`: the MoonBit program's, and the reference's) or by the live view's reader of
// its own (none given): the same entries at the same places as a whole read of it (test/reference/tail.ts
// `ChainTail`), read after read, as a Claude Code transcript is written a piece at a time (a line cut in two), a chain
// goes on into a Codex transcript, one is written anew shorter, one is put away compressed, and one taken up from where
// another's reading stood.
import assert from "node:assert/strict";
import { appendFileSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { zstdCompressSync } from "node:zlib";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Readers } from "../src/read/pool.ts";
import { ChainTail, type TranscriptRef } from "./reference/tail.ts";
import type { TimelineEntry } from "../src/read/transcript.ts";
import { LiveHub, type TailRead } from "../src/sessions/live.ts";
import { Store } from "../src/store/store.ts";
import { readersOf } from "./reference.ts";

const binary = mbReaderBinary();
const at = "2026-11-14T00:00:00Z";
const said = (text: string, id: string) => `${JSON.stringify({ type: "assistant", timestamp: at, message: { id, content: [{ type: "text", text }] } })}\n`;
const call = (id: string, name: string, input: object) => `${JSON.stringify({ type: "assistant", timestamp: at, message: { id, content: [{ type: "tool_use", id, name, input }] } })}\n`;
const answer = (id: string, content: string) => `${JSON.stringify({ type: "user", timestamp: at, message: { role: "user", content: [{ type: "tool_result", tool_use_id: id, content }] } })}\n`;
const person = (text: string) => `${JSON.stringify({ type: "user", timestamp: at, message: { role: "user", content: text } })}\n`;
const item = (payload: object) => `${JSON.stringify({ type: "response_item", timestamp: at, payload })}\n`;

function claudeLines(n: number, tag: string): string[] {
  const out: string[] = [];
  for (let i = 0; i < n; i++) {
    const k = i % 5;
    if (k === 0) out.push(call(`${tag}c${i}`, "Bash", { command: `echo ${"x".repeat(i % 300)}`, description: `Step ${i}` }));
    else if (k === 1) out.push(answer(`${tag}c${i - 1}`, `out ${i} ${"y".repeat((i * 31) % 900)}`));
    else if (k === 2) out.push(person(`please ${i} 中文 ${"é".repeat(i % 40)}`));
    else if (k === 3) out.push("not json\n", "\n");
    else out.push(said(`${i} ${"s".repeat((i * 37) % 1200)}`, `${tag}m${i}`));
  }
  return out;
}

const codexLines = (n: number) => [
  `${JSON.stringify({ type: "session_meta", timestamp: at, payload: { id: "x" } })}\n`,
  ...Array.from({ length: n }, (_, i) => [
    item({ type: "message", role: "assistant", content: [{ type: "output_text", text: `codex ${i}` }] }),
    item({ type: "function_call", name: "shell", call_id: `f${i}`, arguments: JSON.stringify({ command: ["ls", `${i}`] }) }),
    item({ type: "function_call_output", call_id: `f${i}`, output: `a b ${i}` }),
  ]).flat(),
];

/// A live view following `paths()`, read by `reading` (none: here): the entries it was told, put together.
function follow(paths: () => TranscriptRef[], reading: TailRead | null) {
  const hub = new LiveHub(() => ({ runtime: "claude", paths: paths(), current: true }));
  hub.tailRead = reading;
  const told: TimelineEntry[] = [];
  hub.subscribe("s", 0, null, (m) => {
    if (m.type !== "timeline") return;
    told.length = Math.min(told.length, m.start);
    told.push(...m.entries);
  });
  return { hub, told };
}

test("a watched transcript is read by the readers as it was read here, read after read", async (t) => {
  const data = mkdtempSync(join(tmpdir(), "read-tail-"));
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  t.after(() => { store.close(); rmSync(data, { recursive: true, force: true }); });
  const open: Readers[] = [];
  t.after(() => Promise.all(open.map((r) => r.close())));
  const reading = (mb: boolean): TailRead => {
    const r = readersOf(data, mb ? binary : null);
    open.push(r);
    return async (runtime, state) => JSON.parse(await r.read("tailRead", { runtime, state }, "zh", { told: true }));
  };
  const ways: (TailRead | null)[] = [null, reading(false), ...(binary !== null ? [reading(true)] : [])];

  const a = join(data, "a.jsonl"), b = join(data, "b.jsonl"), z = join(data, "z.jsonl");
  writeFileSync(a, "");
  let paths: TranscriptRef[] = [a];
  const lines = claudeLines(60, "a");
  const whole = new ChainTail("claude", [a], null, true);
  const views = ways.map((w) => follow(() => paths, w));
  t.after(() => Promise.all(views.map((v) => v.hub.close())));
  for (const v of views) await v.hub.idle();
  const step = async (label: string) => {
    await whole.readSoon();
    for (const [i, v] of views.entries()) {
      await v.hub.turnEnded("s");
      assert.deepEqual(v.told, whole.entries, `${label} (way ${i})`);
    }
  };
  // Written a few lines at a time, the last of each cut in two.
  for (let i = 0; i < lines.length; i += 7) {
    const piece = lines.slice(i, i + 7).join("");
    const cut = Math.floor(piece.length * 0.6);
    appendFileSync(a, piece.slice(0, cut));
    await step(`a to ${i} (cut)`);
    appendFileSync(a, piece.slice(cut));
    await step(`a to ${i}`);
  }
  await step("nothing new");
  // On into a Codex transcript of the same session.
  writeFileSync(b, codexLines(3).join(""));
  paths = [a, { path: b, runtime: "codex" }];
  assert.equal(whole.extend(paths), true);
  for (const v of views) v.hub.moved("s");
  await step("chain");
  appendFileSync(b, codexLines(4).slice(1).join(""));
  await step("chain grows");
  // The earlier one gains a line (rare: its runtime session is over): read again from there.
  appendFileSync(a, said("late", "late"));
  await step("an earlier one grows");
  // Written anew, shorter.
  writeFileSync(a, claudeLines(6, "r").join(""));
  await step("written anew");
  // Taken up from where the reading stood (the next station process): it reads on as it would have.
  const carried = await views[0]!.hub.carried();
  appendFileSync(a, claudeLines(9, "u").join(""));
  await whole.readSoon();
  for (const [i, w] of ways.entries()) {
    const next = follow(() => paths, w);
    next.hub.takeTails(JSON.parse(JSON.stringify(carried.tails)));
    await next.hub.idle();
    await next.hub.turnEnded("s");
    assert.deepEqual(next.told, whole.entries, `taken up, way ${i}`);
    await next.hub.close();
  }
  // One put away compressed, read whole.
  const zl = claudeLines(30, "z").join("");
  writeFileSync(`${z}.zst`, zstdCompressSync(Buffer.from(zl)));
  const packed = new ChainTail("claude", [z], null, true);
  await packed.readSoon();
  for (const [i, w] of ways.entries()) {
    const v = follow(() => [z], w);
    await v.hub.idle();
    await v.hub.turnEnded("s");
    assert.deepEqual(v.told, packed.entries, `compressed, way ${i}`);
    await v.hub.close();
  }
});
