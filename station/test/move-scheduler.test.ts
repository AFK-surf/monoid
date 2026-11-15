// The migration's scheduler (move/scheduler.ts) over modules of the test's own (move/module.ts): it only orders them.
// An item whose need is not there is refused naming it, and goes after it; withNeeds moves the needs first, in order;
// moving back is refused while something there needs it, naming that; an item moved away that cannot be had here stops
// what needs it here (kept across a start), and what stopped goes on as it comes back, or as it moves itself.
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { Item, ItemState, Module, Need } from "../src/move/module.ts";
import { type Selection, Scheduler } from "../src/move/scheduler.ts";
import { moveView } from "../src/move/routes.ts";
import { cloneLogin } from "../src/move/repos.ts";
import { given } from "./hub-fakes.ts";
import { setStationLang, stationLang, tr } from "../src/ops/i18n.ts";
import { hearLines } from "../src/ops/log.ts";
import { Refused } from "../src/mesh/bus.ts";
import { Said, sayOf } from "../src/move/module.ts";

// (the scheduler's words in English here, as this file reads them)
setStationLang("en");

type Json = any;

/// A module of the test's: its items, where each is, what it did in order (shared by the modules, `log`).
function fake(id: string, needs: string[], items: Omit<Item, "module">[], log: string[], o: { usable?: (id: string) => boolean; usableThere?: (id: string) => boolean; fails?: Set<string> } = {}): Module & { where: Map<string, string>; stopped: Map<string, Need> } {
  const where = new Map<string, string>(items.map((x) => [x.id, "here"]));
  const stopped = new Map<string, Need>();
  return {
    id, needs, where, stopped,
    async plan() {
      return items.map((x) => ({ ...x, module: id }));
    },
    async move(item, to) {
      if (o.fails?.has(item.id)) throw new Error(`${item.id} would not go`);
      log.push(`move ${id}/${item.id}`);
      where.set(item.id, to);
    },
    async back(item) {
      log.push(`back ${id}/${item.id}`);
      where.set(item.id, "here");
    },
    state(item): ItemState {
      return { state: where.get(item.id) === "here" ? "here" : "there" };
    },
    usableHere: o.usable === undefined ? undefined : (item) => o.usable!(item.id),
    usableThere: o.usableThere === undefined ? undefined : (item) => where.get(item.id) === "here" && o.usableThere!(item.id),
    async stop(item, waitsFor) {
      log.push(`stop ${id}/${item.id}`);
      stopped.set(item.id, waitsFor);
    },
    async resume(item) {
      log.push(`resume ${id}/${item.id}`);
      stopped.delete(item.id);
    },
  };
}

function world(o: { usable?: (id: string) => boolean; fails?: Set<string> } = {}) {
  const log: string[] = [];
  const accounts = fake("accounts", [], [{ id: "sub", label: "a subscription", needs: [] }, { id: "grok", label: "a Grok sign-in", needs: [] }], log, { usable: o.usable ?? ((x) => x === "sub") });
  const chats = fake("chats", ["accounts"], [
    { id: "c1", label: "chat one", needs: [{ module: "accounts", id: "sub" }] },
    { id: "c2", label: "chat two", needs: [{ module: "accounts", id: "grok" }] },
  ], log, { fails: o.fails });
  const jobs = fake("jobs", ["chats"], [{ id: "j1", label: "dev server", needs: [{ module: "chats", id: "c1" }] }], log);
  const data = mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "move-"));
  const make = () => new Scheduler({ data, modules: [accounts, chats, jobs] });
  return { log, accounts, chats, jobs, s: make(), make };
}

test("an item is refused while what it needs is not there, naming it, and goes once it is; withNeeds moves its needs first, in order", async () => {
  const { log, s } = world();
  const refused = await s.move("ws", "B", { module: "chats", item: "c1" });
  assert.deepEqual(refused.done, []);
  assert.equal(refused.refused.length, 1);
  assert.match(refused.refused[0]!.why, /needs account “a subscription” there first/);
  assert.deepEqual(log, [], "nothing moved");
  const first = await s.move("ws", "B", { module: "accounts", item: "sub" });
  assert.deepEqual(first.done, [{ module: "accounts", id: "sub" }]);
  const then = await s.move("ws", "B", { module: "chats", item: "c1", follow: ["jobs"] });
  assert.deepEqual(then.done.map((d) => `${d.module}/${d.id}`), ["chats/c1", "jobs/j1"], "its job follows it");
  // withNeeds: what it needs first, in order
  const w = world();
  const out = await w.s.move("ws", "B", { module: "jobs", item: "j1", withNeeds: true });
  assert.deepEqual(out.done.map((d) => `${d.module}/${d.id}`), ["accounts/sub", "chats/c1", "jobs/j1"]);
  assert.deepEqual(w.log, ["move accounts/sub", "stop jobs/j1", "move chats/c1", "move jobs/j1"], "its job stopped as its chat went, then moved");
});

test("a need that cannot go: what needs it is refused in that need's own words, one step further for what needs that, with arriveStopped the way left; one the other did not answer this turn leaves none; nothing moved", async () => {
  const log: string[] = [];
  const MINE = "this machine's own login cannot go to another station: sign in there with the login tool";
  const UNANSWERED = "the other station did not answer what it has of it (not reached): ask again";
  const accounts = fake("accounts", [], [{ id: "mine", label: "the machine's", needs: [], cannot: MINE }, { id: "asked", label: "a login", needs: [], cannot: UNANSWERED, again: true }], log);
  const chats = fake("chats", ["accounts"], [
    { id: "c1", label: "chat one", needs: [{ module: "accounts", id: "mine" }] },
    { id: "c2", label: "chat two", needs: [{ module: "accounts", id: "asked" }] },
  ], log);
  const jobs = fake("jobs", ["chats"], [{ id: "j1", label: "dev server", needs: [{ module: "chats", id: "c1" }] }], log);
  const s = new Scheduler({ data: mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "move-")), modules: [accounts, chats, jobs] });
  const why = (out: Json, id: string) => out.refused.find((r: Json) => r.item.id === id)?.why;
  const chat = `it needs account “the machine's” there, which cannot go: ${MINE}`;
  for (const withNeeds of [false, true]) {
    const one = await s.move("ws", "B", { module: "chats", item: "c1", withNeeds });
    assert.equal(why(one, "c1"), `${chat} (or let it go ahead and wait there for it)`, `withNeeds ${withNeeds}: the need's own words, never "move that first"`);
    const job = await s.move("ws", "B", { module: "jobs", item: "j1", withNeeds });
    assert.equal(why(job, "j1"), `it needs chat “chat one” there, which cannot go: ${chat} (or let it go ahead and wait there for it)`, `withNeeds ${withNeeds}: one step further`);
    const two = await s.move("ws", "B", { module: "chats", item: "c2", withNeeds, arriveStopped: true });
    assert.equal(why(two, "c2"), `it needs account “a login” there, which cannot go: ${UNANSWERED}`, `withNeeds ${withNeeds}: not answered: no way but asking again`);
  }
  assert.deepEqual(log, [], "nothing moved");
  const stopped = await s.move("ws", "B", { module: "chats", item: "c1", arriveStopped: true });
  assert.deepEqual(stopped.done, [{ module: "chats", id: "c1" }], "arriveStopped: it goes, to wait there");
  assert.deepEqual(log, ["stop jobs/j1", "move chats/c1"], "its job stopped as it goes (it needs its chat), as ever");
});

test("a need's module undeclared is refused as the plan is made", async () => {
  const log: string[] = [];
  const bad = fake("chats", [], [{ id: "c1", label: "c", needs: [{ module: "accounts", id: "sub" }] }], log);
  const acc = fake("accounts", [], [{ id: "sub", label: "s", needs: [] }], log);
  const s = new Scheduler({ data: mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "move-")), modules: [acc, bad] });
  await assert.rejects(s.plan("ws", "B"), /needs accounts sub, of a module it does not declare/);
});

test("moving back is refused while something there needs it, naming it; asked for all, the dependents go back first", async () => {
  const { log, s } = world();
  await s.move("ws", "B", { module: "jobs", item: "j1", withNeeds: true });
  const refused = await s.back("ws", "B", { module: "accounts", item: "sub" });
  assert.deepEqual(refused.done, []);
  assert.match(refused.refused[0]!.why, /chat “chat one” there needs it: move that back first/);
  log.length = 0;
  const all = await s.back("ws", "B", { module: "accounts", item: "sub", withNeeds: true });
  assert.deepEqual(all.done.map((d) => `${d.module}/${d.id}`), ["jobs/j1", "chats/c1", "accounts/sub"]);
  // (the job comes back first, stopped as its chat is still there, and goes on as its chat comes)
  assert.deepEqual(log, ["back jobs/j1", "back chats/c1", "resume jobs/j1", "back accounts/sub"]);
});

test("an item moved away that cannot be had here stops what needs it here, before it goes; started again it is still stopped; it goes on as the item comes back, or as it moves itself", async () => {
  const { log, chats, s, make } = world();
  const plan = await s.plan("ws", "B");
  assert.deepEqual(plan.items.find((x) => x.id === "grok")!.wouldStop, [{ module: "chats", id: "c2" }], "the plan says what it would stop");
  assert.deepEqual(plan.items.find((x) => x.id === "sub")!.wouldStop, [], "one borrowed here stops nothing");
  const out = await s.move("ws", "B", { module: "accounts", item: "grok" });
  assert.deepEqual(out.stopped, [{ item: { module: "chats", id: "c2" }, waitsFor: { module: "accounts", id: "grok" } }]);
  assert.deepEqual(log, ["stop chats/c2", "move accounts/grok"], "stopped before its need went");
  assert.equal((await s.plan("ws", "B")).items.find((x) => x.id === "c2")!.state, "stopped");
  assert.deepEqual((await s.plan("ws", "B")).items.find((x) => x.id === "c2")!.waitsFor, { module: "accounts", id: "grok", label: "a Grok sign-in", at: "B" }, "what it waits for, and the station that is on");
  // started again: still stopped (held again)
  const again = make();
  chats.stopped.clear();
  await again.start();
  assert.deepEqual(chats.stopped.get("c2"), { module: "accounts", id: "grok", label: "a Grok sign-in", at: "B" });
  assert.equal((await again.plan("ws", "B")).items.find((x) => x.id === "c2")!.state, "stopped");
  // back: it goes on here
  log.length = 0;
  const back = await again.back("ws", "B", { module: "accounts", item: "grok" });
  assert.deepEqual(back.resumed, [{ module: "chats", id: "c2" }]);
  assert.deepEqual(log, ["back accounts/grok", "resume chats/c2"]);
  assert.equal((await again.plan("ws", "B")).items.find((x) => x.id === "c2")!.state, "here");
  // moved again, then the chat moves itself: no longer stopped, nothing resumed here
  await again.move("ws", "B", { module: "accounts", item: "grok" });
  log.length = 0;
  const moved = await again.move("ws", "B", { module: "chats", item: "c2" });
  assert.deepEqual(moved.done, [{ module: "chats", id: "c2" }]);
  assert.deepEqual(again.stopped(), []);
  assert.deepEqual(log, ["move chats/c2"]);
});

test("a whole move: everything in its needs' order, what cannot move listed with why and what needs it with it, a failure stops only what needs it and is said; all of it back after", async () => {
  const w = world({ fails: new Set(["c2"]) });
  const out = await w.s.move("ws", "B", { all: true });
  // (grok, which stops c2 here, goes as late as it can, c2 right after it; c2 failing, c1 and its job go on)
  assert.deepEqual(out.done.map((d) => `${d.module}/${d.id}`), ["accounts/sub", "accounts/grok", "chats/c1", "jobs/j1"]);
  assert.equal(out.failed?.item.id, "c2");
  assert.deepEqual((out.failures ?? []).map((f) => f.item.id), ["c2"]);
  // (a module's error as it came: logged, said in the station's words)
  assert.equal(out.failed!.error, tr(stationLang(), "station.move.why.failedHere"));
  assert.ok(!out.failed!.error.includes("would not go"));
  assert.deepEqual(w.log, ["move accounts/sub", "stop chats/c2", "move accounts/grok", "stop jobs/j1", "move chats/c1", "move jobs/j1"], "what needs what goes stopped first (c1's job before c1, going right after it); the failure stops nothing that does not need it");
  // (a whole station, the failure fixed, then all of it back)
  const ok = world();
  const all = await ok.s.move("ws", "B", { all: true });
  assert.equal(all.failed, null);
  assert.deepEqual(all.done.map((d) => d.id).sort(), ["c1", "c2", "grok", "j1", "sub"]);
  assert.ok((await ok.s.plan("ws", "B")).items.every((x) => x.state === "there"));
  const back = await ok.s.back("ws", "B", { all: true });
  assert.equal(back.failed, null);
  assert.deepEqual(back.refused, []);
  assert.ok((await ok.s.plan("ws", "B")).items.every((x) => x.state === "here"));
  assert.deepEqual(ok.s.stopped(), []);
});

test("what moved only for an item that then did not go is brought back in the same turn, and the outcome says so", async () => {
  const w = world({ fails: new Set(["c2"]) });
  const out = await w.s.move("ws", "B", { module: "chats", item: "c2", withNeeds: true });
  assert.deepEqual((out.failures ?? []).map((f) => f.item.id), ["c2"]);
  assert.deepEqual(out.returned, [{ module: "accounts", id: "grok" }]);
  assert.deepEqual(out.done, []);
  assert.deepEqual(w.log, ["stop chats/c2", "move accounts/grok", "back accounts/grok", "resume chats/c2"]);
  assert.equal((await w.s.plan("ws", "B")).items.find((x) => x.id === "grok")!.state, "here");
  assert.deepEqual(w.s.stopped(), []);
});

test("modules may need each other; items may not: a chain of items needing each other round cannot move, named, and the plan still shows the rest", async () => {
  const log: string[] = [];
  const chats = fake("chats", ["connects"], [{ id: "c1", label: "c", needs: [{ module: "connects", id: "k1" }] }], log);
  const connects = fake("connects", ["chats"], [{ id: "k1", label: "k", needs: [{ module: "chats", id: "c1" }] }, { id: "k2", label: "k2", needs: [] }], log);
  const s = new Scheduler({ data: mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "move-")), modules: [chats, connects] });
  const plan = await given(s.plan("ws", "B"), "the plan answers");
  const chain = /need each other, so none can go first: chat “c” → connect “k” → chat “c”|connect “k” → chat “c” → connect “k”/;
  assert.match(plan.items.find((x) => x.id === "c1")!.cannot ?? "", chain);
  assert.match(plan.items.find((x) => x.id === "k1")!.cannot ?? "", chain);
  assert.equal(plan.items.find((x) => x.id === "k2")!.cannot, undefined, "the rest planned as ever");
  const out = await given(s.move("ws", "B", { module: "chats", item: "c1", withNeeds: true }), "the move answers");
  assert.equal(out.done.length, 0);
  assert.match(out.refused[0]?.why ?? "", chain);
  // (the modules' needs alone, a cycle of their own, are fine)
  const ok = new Scheduler({ data: mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "move-")), modules: [fake("chats", ["connects"], [], log), fake("connects", ["chats"], [{ id: "k2", label: "k2", needs: [] }], log)] });
  assert.equal((await ok.plan("ws", "B")).items.length, 1);
});

test("an item stopped waiting goes on as what it waits for is told come here (move.arrived), whatever this station's own look at its plan finds", async () => {
  const log: string[] = [];
  // (the account it waits for is in no plan here: a look as the station starts or hears from another lets nothing go)
  const accounts = fake("accounts", [], [], log);
  const chats = fake("chats", ["accounts"], [{ id: "c1", label: "c", needs: [{ module: "accounts", id: "sub" }] }], log);
  const s = new Scheduler({ data: mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "move-")), modules: [accounts, chats] });
  await s.noteStopped({ module: "chats", id: "c1" }, { module: "accounts", id: "sub" }, "ws");
  assert.deepEqual(await s.settleStopped(), []);
  assert.deepEqual(s.stopped().map((x) => x.item.id), ["c1"]);
  assert.deepEqual(await s.arrived({ module: "accounts", id: "sub" }), [{ module: "chats", id: "c1" }]);
  assert.deepEqual(s.stopped(), [], "let go as it was told");
  assert.deepEqual(log, ["stop chats/c1", "resume chats/c1"]);
});

test("an item may go to where what it needs is not (arriveStopped), and is told there what it waits for; back, what needs an item there comes first, arriving stopped", async () => {
  const { log, s } = world();
  const told: string[] = [];
  const arrived: string[] = [];
  const w2 = world();
  const s2 = new Scheduler({ data: mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "move-")), modules: [w2.accounts, w2.chats, w2.jobs], tellArrived: async (to, item) => void arrived.push(`${to}:${item.module}/${item.id}`) });
  const out = await s2.move("ws", "B", { module: "chats", item: "c2", arriveStopped: true });
  assert.deepEqual(out.done, [{ module: "chats", id: "c2" }]);
  assert.deepEqual(arrived, ["B:chats/c2"]);
  void told;
  void s;
  void log;
  // back: c2's account goes back after it; c2 arrives stopped, then goes on
  await s2.move("ws", "B", { module: "accounts", item: "grok" });
  w2.log.length = 0;
  const back = await s2.back("ws", "B", { module: "accounts", item: "grok", withNeeds: true });
  assert.deepEqual(back.done.map((d) => `${d.module}/${d.id}`), ["chats/c2", "accounts/grok"]);
  assert.deepEqual(back.stopped, [{ item: { module: "chats", id: "c2" }, waitsFor: { module: "accounts", id: "grok" } }]);
  assert.deepEqual(back.resumed, [{ module: "chats", id: "c2" }]);
});

test("back: what arrived stopped is let go by the turn as what it waits for comes, a look at the stopped heard meanwhile (the other station's requests as it comes) letting none of it go", async () => {
  const w = world();
  const s = new Scheduler({ data: mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "move-")), modules: [w.accounts, w.chats, w.jobs] });
  await s.move("ws", "B", { module: "chats", item: "c2", arriveStopped: true });
  await s.move("ws", "B", { module: "accounts", item: "grok" });
  // (the account, coming, is here before its move back ends: the station hears from the other meanwhile)
  const back0 = w.accounts.back.bind(w.accounts);
  const looked: Need[][] = [];
  w.accounts.back = async (item, from, opts) => {
    await back0(item, from, opts);
    looked.push(await s.settleStopped());
  };
  w.log.length = 0;
  const back = await s.back("ws", "B", { module: "accounts", item: "grok", withNeeds: true });
  assert.deepEqual(looked, [[]], "the look lets nothing of the turn's go");
  assert.deepEqual(back.done.map((d) => `${d.module}/${d.id}`), ["chats/c2", "accounts/grok"]);
  assert.deepEqual(back.resumed, [{ module: "chats", id: "c2" }], "the turn let it go");
  assert.equal(w.log.filter((l) => l === "resume chats/c2").length, 1, w.log.join(" | "));
  assert.deepEqual(s.stopped(), []);
});

test("all at once: an account that cannot be shared goes as late as it can, its chats right after it; what copies (repos) stops nothing", async () => {
  const log: string[] = [];
  const accounts = fake("accounts", [], [{ id: "X", label: "not shared", needs: [] }, { id: "Y", label: "shared", needs: [] }], log, { usable: (id) => id === "Y" });
  const repos = fake("repos", [], [{ id: "r1", label: "r1", needs: [] }, { id: "r2", label: "r2", needs: [] }], log, { usable: () => true });
  const chats = fake("chats", ["accounts", "repos"], [
    { id: "c1", label: "c1", needs: [{ module: "accounts", id: "X" }, { module: "repos", id: "r1" }] },
    { id: "c2", label: "c2", needs: [{ module: "accounts", id: "Y" }, { module: "repos", id: "r2" }] },
    { id: "c3", label: "c3", needs: [{ module: "accounts", id: "X" }] },
  ], log);
  const s = new Scheduler({ data: mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "move-")), modules: [accounts, repos, chats] });
  const plan = await s.plan("ws", "B");
  assert.deepEqual(plan.items.filter((x) => x.module === "repos").map((x) => x.wouldStop), [[], []], "a repository moved stops nothing");
  const out = await s.move("ws", "B", { all: true });
  assert.equal(out.failed, null);
  const moved = log.filter((l) => l.startsWith("move ")).map((l) => l.slice(5));
  const at = (x: string) => moved.indexOf(x);
  assert.ok(at("accounts/X") > at("repos/r1") && at("accounts/X") > at("repos/r2"), moved.join(", "));
  assert.ok(at("accounts/X") > at("accounts/Y") && at("accounts/X") > at("chats/c2"), `after what does not need it: ${moved.join(", ")}`);
  assert.deepEqual([at("chats/c1"), at("chats/c3")].sort(), [at("accounts/X") + 1, at("accounts/X") + 2], `its chats right after it: ${moved.join(", ")}`);
  assert.deepEqual(log.filter((l) => l.startsWith("stop ")), ["stop chats/c1", "stop chats/c3"], "only X stops anything");
});

test("a need usable there though it is not there (an account the other station borrows): what needs it goes without it, never waiting or taken along; in a whole move it goes as its own item; the plan shows it here", async () => {
  const run = (sel: Selection) => {
    const log: string[] = [];
    const accounts = fake("accounts", [], [{ id: "sub", label: "lent there", needs: [] }], log, { usable: () => true, usableThere: (id) => id === "sub" });
    const chats = fake("chats", ["accounts"], [{ id: "c1", label: "chat one", needs: [{ module: "accounts", id: "sub" }] }], log);
    const s = new Scheduler({ data: mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "move-")), modules: [accounts, chats] });
    return { log, s, out: s.move("ws", "B", sel) };
  };
  const one = run({ module: "chats", item: "c1" });
  assert.deepEqual((await one.out).refused, [], "not refused for it");
  assert.deepEqual(one.log, ["move chats/c1"], "it went alone");
  assert.equal((await one.s.plan("ws", "B")).items.find((x) => x.id === "sub")!.state, "here", "the account as it stands: here");
  const back = await one.s.back("ws", "B", { module: "chats", item: "c1" });
  assert.deepEqual([back.done, back.stopped], [[{ module: "chats", id: "c1" }], []], "back, nothing to wait for");
  const needs = run({ module: "chats", item: "c1", withNeeds: true });
  assert.deepEqual((await needs.out).done, [{ module: "chats", id: "c1" }]);
  assert.deepEqual(needs.log, ["move chats/c1"], "not taken along for its sake");
  const mod = run({ module: "chats", all: true });
  assert.deepEqual((await mod.out).done, [{ module: "chats", id: "c1" }]);
  assert.deepEqual(mod.log, ["move chats/c1"], "a whole module of chats takes no account along");
  const all = run({ all: true });
  assert.equal((await all.out).failed, null);
  assert.deepEqual(all.log.sort(), ["move accounts/sub", "move chats/c1"], "in a whole move it goes as its own item");
});

test("a clone refused for want of a login says to sign in to that host on that station", () => {
  assert.equal(cloneLogin("fatal: could not read Username for 'https://github.com': terminal prompts disabled", "https://github.com/o/r.git", "Office-Host-2"),
    tr(stationLang(), "station.move.why.cloneLogin", { station: "Office-Host-2", url: "https://github.com/o/r.git", host: "github.com" }));
  assert.match(cloneLogin("git@gitlab.com: Permission denied (publickey).", "git@gitlab.com:o/r.git", "B") ?? "", /not signed in to gitlab\.com/);
  assert.equal(cloneLogin("fatal: destination path exists", "https://x/y", "B"), null);
});

/// Reads of the items' properties a scheduler makes (each `needs` array's, each item's once it is planned), counted
/// through a Proxy: what its lookups cost, whatever the machine.
function countedWorld(n: number) {
  const reads = { n: 0 };
  const counted = <T extends object>(x: T): T => new Proxy(x, { get: (t, p, r) => (reads.n++, Reflect.get(t, p, r)) });
  const log: string[] = [];
  const k = Math.max(1, Math.floor(n / 10));
  const accounts = fake("accounts", [], Array.from({ length: k }, (_, i) => ({ id: `a${i}`, label: `a${i}`, needs: counted([] as Need[]) })), log, { usable: () => false });
  const chats = fake("chats", ["accounts"], Array.from({ length: n }, (_, i) => ({ id: `c${i}`, label: `c${i}`, needs: counted([{ module: "accounts", id: `a${i % k}` }]) })), log);
  const jobs = fake("jobs", ["chats"], Array.from({ length: k }, (_, i) => ({ id: `j${i}`, label: `j${i}`, needs: counted([{ module: "chats", id: `c${i}` }]) })), log);
  const s = new Scheduler({ data: mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "move-")), modules: [accounts, chats, jobs] });
  // (a turn's plan as the scheduler makes it, each item read through the count)
  const plan = s.plan.bind(s);
  const turns = { on: false };
  (s as Json).plan = async (ws: string, to: string) => {
    const p = await plan(ws, to);
    return turns.on ? { ...p, items: p.items.map(counted) } : p;
  };
  return { s, reads, turns, plan };
}

test("the scheduler's own work grows as the items do: a plan, a whole move and a whole move back read each item a bounded number of times, at N and 3N items", async () => {
  const at = async (n: number) => {
    const { s, reads, turns, plan } = countedWorld(n);
    reads.n = 0;
    const p = await plan("ws", "B");
    const planned = reads.n;
    reads.n = 0;
    moveView(p, ["accounts", "chats", "jobs"], s.stopped());
    const view = reads.n;
    turns.on = true;
    reads.n = 0;
    const out = await s.move("ws", "B", { all: true });
    const moved = reads.n;
    assert.equal(out.failed, null);
    reads.n = 0;
    await s.back("ws", "B", { all: true });
    const back = reads.n;
    return { items: p.items.length, planned, view, moved, back };
  };
  const one = await at(300);
  const three = await at(900);
  // (linear: the counts at 3N are about three times those at N; one that went as the square would be nine times)
  for (const k of ["planned", "view", "moved", "back"] as const) {
    assert.ok(three[k] <= 3.5 * one[k] + 50, `${k}: ${one[k]} reads for ${one.items} items, ${three[k]} for ${three.items}: at most 3.5 times as many`);
  }
});

test("a chat asked to move with what it needs, one of which would stop other chats here as it went, is refused with that need, saying what it would stop and what to do", async () => {
  const log: string[] = [];
  const accounts = fake("accounts", [], [{ id: "solo", label: "a login of this machine's", needs: [] }], log, { usable: () => false });
  const chats = fake("chats", ["accounts"], [
    { id: "c1", label: "chat one", needs: [{ module: "accounts", id: "solo" }] },
    { id: "c2", label: "chat two", needs: [{ module: "accounts", id: "solo" }] },
  ], log);
  const s = new Scheduler({ data: mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "move-")), modules: [accounts, chats] });
  const out = await s.move("ws", "B", { module: "chats", item: "c1", withNeeds: true });
  assert.deepEqual(out.done, [], "nothing moved");
  assert.deepEqual(log, [], "nothing stopped");
  const why = Object.fromEntries(out.refused.map((r) => [`${r.item.module} ${r.item.id}`, r.why]));
  assert.match(why["chats c1"] ?? "", /it needs account “a login of this machine's”, whose move would stop chat “chat two” here: move it on its own/);
  assert.match(why["accounts solo"] ?? "", /moving it would stop chat “chat two” here/);
  // (the two asked together: nothing else stops, so the login goes with them)
  const both = await s.move("ws", "B", { module: "chats", withNeeds: true });
  assert.deepEqual(both.done.map((d) => d.id).sort(), ["c1", "c2", "solo"]);
});

test("a chat asked with what it needs: a login shared as it moves (usable here after) or one usable there already is never refused for what it would stop, and nothing here is stopped for it", async () => {
  const log: string[] = [];
  // (`shared`: usable here once it went; `borrowed`: here, and usable there as it is)
  const accounts = fake("accounts", [], [{ id: "shared", label: "a login shared as it moves", needs: [] }, { id: "borrowed", label: "a login the other borrows", needs: [] }], log, { usable: (id) => id === "shared", usableThere: (id) => id === "borrowed" });
  const chats = fake("chats", ["accounts"], [
    { id: "c1", label: "chat one", needs: [{ module: "accounts", id: "shared" }] },
    { id: "c2", label: "chat two", needs: [{ module: "accounts", id: "shared" }] },
    { id: "c3", label: "chat three", needs: [{ module: "accounts", id: "borrowed" }] },
    { id: "c4", label: "chat four", needs: [{ module: "accounts", id: "borrowed" }] },
  ], log);
  const s = new Scheduler({ data: mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "move-")), modules: [accounts, chats] });
  const one = await s.move("ws", "B", { module: "chats", item: "c1", withNeeds: true });
  assert.deepEqual(one.refused, [], "the login shared as it moves stops nothing: taken along");
  assert.deepEqual(one.done.map((d) => d.id), ["shared", "c1"]);
  const three = await s.move("ws", "B", { module: "chats", item: "c3", withNeeds: true });
  assert.deepEqual(three.refused, [], "the login usable there: not taken along, nothing refused");
  assert.deepEqual(three.done.map((d) => d.id), ["c3"]);
  assert.equal(accounts.where.get("borrowed"), "here");
  assert.deepEqual(s.stopped(), [], "nothing stopped for either");
  assert.deepEqual(log.filter((l) => l.startsWith("stop")), []);
});

test("an item's failure is said in the station's words: its own and the other station's as they are, an error as it came logged and worded by the catalog", () => {
  const lines: string[] = [];
  hearLines((l) => void lines.push(`${l.message} ${JSON.stringify(l.fields ?? {})}`));
  try {
    assert.equal(sayOf(new Said("its own words"), "chats/x"), "its own words");
    assert.equal(sayOf(new Refused("the other station's words"), "chats/x"), "the other station's words");
    assert.equal(lines.length, 0, `nothing logged of words said as they are: ${lines.join(" | ")}`);
    for (const cause of ["the other station answered nothing", "peer request timed out; execution may have happened — query the same task key", "the other station's connection was gone: the request got no answer from it (asked again, it is dialed anew)"])
      assert.equal(sayOf(new Error(cause), "chats/x"), tr(stationLang(), "station.move.why.unanswered"), cause);
    assert.equal(sayOf(new Error("EIO: i/o error, read"), "chats/x"), tr(stationLang(), "station.move.why.failedHere"));
    assert.ok(lines.some((l) => l.includes("EIO: i/o error, read") && l.includes("chats/x")), lines.join(" | "));
  } finally {
    hearLines(null);
  }
});

test("the plan says a move would stop only what the turn stops: an item of a module that stops nothing (a routed connect, its threads routed where the chat goes) is not said to be stopped", async () => {
  const log: string[] = [];
  const accounts = fake("accounts", [], [{ id: "sub", label: "a subscription", needs: [] }, { id: "grok", label: "a Grok sign-in", needs: [] }], log, { usable: (x) => x === "sub" });
  const chats = fake("chats", ["accounts"], [{ id: "c1", label: "chat one", needs: [{ module: "accounts", id: "grok" }] }], log);
  const connects = fake("connects", ["chats"], [{ id: "slack", label: "Slack", needs: [{ module: "chats", id: "c1" }] }], log);
  delete (connects as { stop?: unknown }).stop;
  const s = new Scheduler({ data: mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "move-")), modules: [accounts, chats, connects] });
  const plan = await s.plan("ws", "B");
  assert.deepEqual(plan.items.find((x) => x.id === "c1")!.wouldStop, [], "the chat's move stops not its connect");
  assert.deepEqual(plan.items.find((x) => x.id === "grok")!.wouldStop, [{ module: "chats", id: "c1" }], "its login's move stops the chat");
  // (and the turn does as the plan says: the login moved alone stops the chat, the chat moved stops nothing)
  const out = await s.move("ws", "B", { module: "accounts", item: "grok" });
  assert.deepEqual(out.stopped.map((x) => x.item.id), ["c1"]);
  const chat = await s.move("ws", "B", { module: "chats", item: "c1" });
  assert.deepEqual([chat.done.map((d) => d.id), chat.stopped], [["c1"], []]);
});
