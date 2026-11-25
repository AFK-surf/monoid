// How a person's agents are asked for progress (api/routes/progress.ts): kept by its person, the newer of two, and gone by
// for the sessions they started alone, at their interval and in their strength.
import assert from "node:assert/strict";
import { test } from "node:test";
import { routes } from "../src/api/routes/progress.ts";
import { sessionKey } from "../src/sessions/hub.ts";
import { Rig, message, settle } from "./hub-fakes.ts";

const viewer = { sub: "u1", email: "A@x.com", name: "A", role: "member", workspace: "w1", device: "d" };
const pref = (minutes: number, strength: string, rev = 1) => ({ minutes, strength, rev, at: 10 * rev });

test("a person's own is kept, the newer of two, and told to their devices once it changes", async () => {
  const r = new Rig();
  const told: string[] = [];
  const at = routes({ kept: r.store, told: (ws, sub) => void told.push(`${ws}/${sub}`) });
  const ask = async (method: string, body?: unknown, who = viewer) => {
    const a = await at.find((x) => x.method === method)!.handle({ method, path: "/progress", query: [], headers: {}, body: Buffer.from(body === undefined ? "" : JSON.stringify(body)), viewer: who } as never, [] as never);
    return { status: a.status, body: JSON.parse(String(a.body)) };
  };
  assert.deepEqual((await ask("GET")).body, { progress: null });
  assert.deepEqual((await ask("PUT", { progress: pref(30, "remind", 2) })).body, { progress: pref(30, "remind", 2) });
  // (an older one changes nothing and is answered the newer)
  assert.deepEqual((await ask("PUT", { progress: pref(5, "require", 1) })).body, { progress: pref(30, "remind", 2) });
  assert.deepEqual(told, ["w1/u1"]);
  assert.deepEqual((await ask("GET", undefined, { ...viewer, sub: "u2" })).body, { progress: null });
  assert.deepEqual((await ask("GET", undefined, { ...viewer, workspace: "w2" })).body, { progress: null });
  for (const bad of [null, pref(0, "require"), pref(2000, "require"), pref(10, "loud"), { ...pref(10, "require"), rev: 0 }]) assert.equal((await ask("PUT", { progress: bad })).status, 400);
  assert.equal((await ask("GET", undefined, { ...viewer, sub: "" })).status, 403);
  await r.close();
});

test("a session goes by who started it: by sub, else by the one person of that email, else the default", async () => {
  const r = new Rig();
  const s = r.store;
  const make = (key: string, createdBy: string, createdBySub: string | null, ws: string | null) =>
    s.insertSession({ key, connect: "cl", createdBy, createdBySub, runtime: "claude", profile: "p", workspace: "/w", token: key, createdAt: 1, lastActiveAt: 1, ws } as never);
  make("by-sub", "a@x.com", "u1", "w1");
  make("by-email", "a@X.com", null, "w1");
  make("home", "a@x.com", null, null);
  make("other", "b@x.com", "u2", "w1");
  make("elsewhere", "a@x.com", "u1", "w2");
  const of = (key: string) => (({ minutes, strength }) => [minutes, strength])(s.progressOf(key, "w1"));
  assert.deepEqual(of("by-sub"), [10, "require"]);
  s.putProgressPrefs("w1", "u1", "A@x.com", JSON.stringify(pref(30, "remind")));
  for (const key of ["by-sub", "by-email", "home"]) assert.deepEqual(of(key), [30, "remind"], key);
  for (const key of ["other", "elsewhere", "missing"]) assert.deepEqual(of(key), [10, "require"], key);
  // (two people of one email: neither's)
  s.putProgressPrefs("w1", "u9", "a@x.com", JSON.stringify(pref(5, "require")));
  assert.deepEqual(of("by-email"), [10, "require"]);
  assert.deepEqual(of("by-sub"), [30, "remind"]);
  const plan = s.db.prepare("EXPLAIN QUERY PLAN SELECT json FROM progress_prefs WHERE ws = ?1 AND email = ?2 LIMIT 2").all("w1", "a@x.com").map((x: any) => x.detail).join("\n");
  assert.ok(plan.includes("progress_prefs_by_email"), plan);
  await r.close();
});

test("a silent wait is told at its person's interval, in their strength, a change going from the next wake", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: Date.now() });
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const session = r.claude.last();
  let choice: { minutes: number; strength: "require" | "remind" } = { minutes: 20, strength: "remind" };
  r.store.progressOf = () => choice;
  const wake = async (minutes: number) => {
    await r.call(key, "chat_state", { kind: "waiting", seconds: 3600, for: "run" });
    session.complete();
    await settle();
    t.mock.timers.tick(minutes * 60_000);
    await r.hub.notify(key, "task ended");
    await settle();
    return session.prompts.at(-1)!;
  };
  assert.ok(!(await wake(12)).includes("You have not posted"), "not at the default ten");
  const told = await wake(9);
  assert.ok(told.includes("for 21 minutes. If there is progress"), told);
  assert.ok(!(await wake(12)).includes("You have not posted"), "not again within its interval");
  choice = { minutes: 5, strength: "require" };
  const asked = await wake(1);
  assert.ok(asked.includes("for 34 minutes. Before you wait again"), asked);
  await r.close();
});

test("a chat begun on a platform goes by the email the platform says its person has", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: Date.now() });
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const session = r.claude.last();
  const row = r.store.getSession(key)!;
  assert.match(row.createdBy!, /^slack:cl:/);
  let asked = 0;
  (r.chat as any).userEmail = async (user: string) => {
    asked++;
    return `slack:cl:${user}` === row.createdBy ? "A@x.com" : null;
  };
  r.store.putProgressPrefs(row.ws ?? r.hub.homeWorkspace() ?? "", "u1", "a@x.com", JSON.stringify(pref(30, "remind")));
  const wake = async (minutes: number) => {
    await r.call(key, "chat_state", { kind: "waiting", seconds: 3600, for: "run" });
    session.complete();
    await settle();
    t.mock.timers.tick(minutes * 60_000);
    await r.hub.notify(key, "task ended");
    await settle();
    return session.prompts.at(-1)!;
  };
  await wake(4);
  assert.equal(asked, 0, "nobody is looked up before any interval is over");
  assert.ok(!(await wake(21)).includes("You have not posted"));
  assert.ok((await wake(6)).includes("for 31 minutes. If there is progress"));
  assert.equal(asked, 1, "asked once");
  await r.close();
});

test("a platform that does not answer holds a wake for seconds at most, and the default goes", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: Date.now() });
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const session = r.claude.last();
  let looked = () => {};
  const asked = new Promise<void>((go) => (looked = go));
  (r.chat as any).userEmail = () => {
    looked();
    return new Promise(() => {});
  };
  await r.call(key, "chat_state", { kind: "waiting", seconds: 3600, for: "run" });
  session.complete();
  await settle();
  t.mock.timers.tick(12 * 60_000);
  await r.hub.notify(key, "task ended");
  // (asked by the program in its own time; its deadline is armed in the same turn it is asked)
  await asked;
  await new Promise((go) => setImmediate(go));
  t.mock.timers.tick(3_001);
  await settle();
  assert.ok(session.prompts.at(-1)!.includes("for 12 minutes. Before you wait again"), session.prompts.at(-1));
  await r.close();
});
