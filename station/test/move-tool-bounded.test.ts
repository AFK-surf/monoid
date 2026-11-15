// What station_move answers of a plan is bounded whatever the station's size (tools/move.ts): a station of 2,456 chats
// answered its whole plan, 1 MB, which an agent could not use and another station's answer could not carry (a line past
// mesh/peer.ts MAX_MESSAGE, "head too large"). By default a summary (each module's counts, what cannot move grouped by
// why with a few examples, what moving an item alone would stop, what is lent and what is stopped here, grouped);
// a module's items a page at a time; one item by its id.
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { Item, ItemState, Module } from "../src/move/module.ts";
import { Scheduler } from "../src/move/scheduler.ts";
import { MoveAsks, outcomeOf, outcomeWords, PAGE, PAGE_MOST } from "../src/tools/move.ts";

/// A module of `items`, each here, one stopping what needs it (a chat's `stop`).
function fake(id: string, needs: string[], items: Omit<Item, "module">[], stops = false): Module {
  return {
    id, needs,
    async plan() {
      return items.map((x) => ({ ...x, module: id }));
    },
    async move() {},
    async back() {},
    state(): ItemState {
      return { state: "here" };
    },
    ...(stops ? { async stop() {} } : {}),
  };
}

/// The tool's answers on a station of `n` chats: each on one of two logins, every tenth one that cannot move (for one of
/// two reasons, or `unique`: each in words of its own, as a chat's room is named in why), a Slack connect for all, a job
/// for every fifth.
async function answers(n: number, unique = false) {
  const chats = Array.from({ length: n }, (_, i) => ({ id: `chat:c-${String(i).padStart(6, "0")}`, label: `a chat about thing ${i}`, needs: [{ module: "accounts", id: i % 2 === 0 ? "share:sh-a" : "own:grok@A" }], ...(i % 10 === 0 ? { cannot: unique ? `its workspace /elsewhere/project-${i} is not this station's own: its files would not go` : i % 20 === 0 ? "its workspace is not this station's own: its files would not go" : "it has a copy going on there apart" } : {}) }));
  const modules = [
    fake("accounts", [], [{ id: "share:sh-a", label: "Claude Max", needs: [] }, { id: "own:grok@A", label: "Grok", needs: [] }]),
    fake("chats", ["accounts"], chats, true),
    fake("connects", ["chats"], [{ id: "slack@A", label: "Slack", needs: chats.map((c) => ({ module: "chats", id: c.id })) }]),
    fake("jobs", ["chats"], chats.filter((_, i) => i % 5 === 0).map((c) => ({ id: `${c.id}#dev`, label: "dev (npm run dev)", needs: [{ module: "chats", id: c.id }] }))),
  ];
  const data = mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "move-tool-"));
  const scheduler = new Scheduler({ data, modules });
  const asks = new MoveAsks({
    data, scheduler, here: () => "A", wsOf: () => "ws", roster: () => [{ id: "A", name: "A" }, { id: "B", name: "B" }],
    cards: { post: async () => null }, notify: () => {},
  } as never);
  const ask = async (args: Record<string, unknown>) => asks.toolIn("ws", "chat:c-000000", { to: "B", ...args });
  return { ask, chats };
}

test("station_move plan and status answer a summary of the same size with 30 chats as with 3,000; a module's items a page at a time; one item by its id", async () => {
  const bytes = async (n: number) => {
    const { ask } = await answers(n);
    const plan = JSON.stringify(await ask({ action: "plan" }));
    const status = JSON.stringify(await ask({ action: "status" }));
    return { plan: plan.length, status: status.length, text: plan };
  };
  const few = await bytes(30);
  const many = await bytes(3_000);
  // (the counts' digits aside: 30 against 3,000 is a few bytes more, each of a dozen counts)
  assert.ok(many.plan - few.plan < 200 && many.status - few.status < 200, `the summary grows with the chats: ${few.plan} → ${many.plan} bytes (plan), ${few.status} → ${many.status} (status)`);
  // (and each in words of its own: a few groups said, how many more)
  const unique = JSON.stringify(await (await answers(3_000, true)).ask({ action: "plan" })).length;
  assert.ok(unique < 16_000, `bounded: ${unique} bytes`);
  const { ask, chats } = await answers(3_000);
  const summary = (await ask({ action: "plan" })).summary;
  assert.deepEqual(summary.modules.chats, { here: 3_000, there: 0, moving: 0, stopped: 0, failed: 0, cannot: 300 });
  assert.deepEqual(summary.cannot.map((g: { why: string; count: number; examples: string[] }) => [g.why, g.count, g.examples.length]), [["chats: its workspace is not this station's own: its files would not go", 150, 3], ["chats: it has a copy going on there apart", 150, 3]]);
  // (a connect needs every chat: a chat's move stops not it, its threads routed; a login's move stops its chats)
  assert.equal(summary.wouldStop.length, 2, JSON.stringify(summary.wouldStop));
  // A module's items, a page at a time: the next page from where the last ended; at most PAGE_MOST, whatever asked.
  const first = await ask({ action: "plan", module: "chats", limit: 10 });
  assert.deepEqual([first.total, first.items.length, first.more], [3_000, 10, chats[9]!.id]);
  const next = await ask({ action: "plan", module: "chats", after: first.more, limit: 10 });
  assert.equal(next.items[0].item, chats[10]!.id);
  assert.equal((await ask({ action: "plan", module: "chats", limit: 100_000 })).items.length, PAGE_MOST);
  // One item by its id.
  assert.equal((await ask({ action: "plan", module: "chats", item: chats[7]!.id })).item.label, chats[7]!.label);
  await assert.rejects(ask({ action: "plan", module: "nope" }), /no module nope/);
});

test("a turn's outcome as the tool answers it: each list's first page and its count, whatever the turn's size", async () => {
  const outcome = (n: number) => {
    const xs = Array.from({ length: n }, (_, i) => ({ module: "chats", id: `chat:c-${String(i).padStart(6, "0")}` }));
    return { done: xs, refused: xs.map((item) => ({ item, why: `its workspace is elsewhere ${"x".repeat(200)}` })), stopped: [], resumed: xs, failed: null, failures: xs.map((item) => ({ item, error: "e".repeat(500) })), returned: xs };
  };
  const few = JSON.stringify(outcomeOf(outcome(PAGE)));
  const many = outcomeOf(outcome(3_000)) as Record<string, unknown[]> & { counts: Record<string, number> };
  assert.equal(JSON.stringify(many).length - few.length < 100, true, `${few.length} → ${JSON.stringify(many).length}`);
  assert.deepEqual(many.counts, { done: 3_000, refused: 3_000, stopped: 0, resumed: 3_000, failures: 3_000, returned: 3_000, lent: 0 });
  assert.equal(many.done.length, PAGE);
  assert.equal(many.failed, null);
  const words = outcomeWords(outcome(3_000), "moved to", "B");
  assert.ok(words.length - outcomeWords(outcome(PAGE), "moved to", "B").length < 100, words.slice(0, 300));
  assert.match(words, /Moved to B \(3000\): .* and 2980 more\./);
});
