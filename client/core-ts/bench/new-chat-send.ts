// A new chat sent with references to two chats, over two workspaces of real size (bench/ws-switch-seed.ts seeds them):
// the `@` menu asked letter by letter as it is typed (`chatSearch` with `elsewhere`, a subscription a letter), a chat
// picked, then Enter (`chat.outsideRefs`, then `composer.take`, `newChat.create`, `chat.send`). Each step: from what
// the app sent to its answer, and what the core's thread was busy with meanwhile (its CPU profile's functions by self
// time). What the app's composer and Home hold is held throughout.
//
//   STATIONS=up node bench/ws-switch-seed.ts <dir> 5
//   node bench/new-chat-send.ts <dir>
import { Session } from "node:inspector/promises";
import { Core } from "../src/core.ts";
import { NodeHost } from "../src/hosts/node.ts";
import { HostWire } from "../src/station/wire.ts";

// deno-lint-ignore no-explicit-any
type J = any;
const [, , dir] = process.argv;
if (!dir) throw new Error("usage: new-chat-send.ts <dir>");

const waiting = new Map<number, (m: J) => void>();
const values = new Map<number, J>();
const host = new NodeHost(dir, "http://127.0.0.1:9", false, (_client, json) => {
  const m = JSON.parse(json);
  if (typeof m.id !== "number") return;
  if ("value" in m) values.set(m.id, m.value);
  const w = waiting.get(m.id);
  if (w && ("ok" in m || "error" in m || "value" in m)) {
    waiting.delete(m.id);
    w(m);
  }
});
const core = await Core.create(host, { iroh: null, wire: () => new HostWire(host) });
const ui = core.connect();
let next = 100;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const answer = (id: number) => new Promise<J>((r) => waiting.set(id, r));
const sub = (topic: J) => {
  const id = next++;
  const p = answer(id);
  core.receive(ui, { kind: "subscribe", id, subscribe: topic, keyed: true });
  return { id, first: p };
};
const unsub = (id: number) => core.receive(ui, { kind: "unsubscribe", id });
const call = (name: string, params: J) => {
  const id = next++;
  const p = answer(id);
  core.receiveRaw(ui, { id, call: name, params });
  return p;
};

const prof = new Session();
prof.connect();
await prof.post("Profiler.enable");
await prof.post("Profiler.setSamplingInterval", { interval: 100 });
/// The functions the thread spent most of `profile` in, by self time.
function top(profile: J, n = 12): string[] {
  const self = new Map<string, number>();
  const dt = profile.timeDeltas as number[];
  const byId = new Map<number, J>(profile.nodes.map((x: J) => [x.id, x]));
  (profile.samples as number[]).forEach((id, i) => {
    const node = byId.get(id);
    const f = node.callFrame;
    const name = `${f.functionName || "(anon)"} ${String(f.url).split("/").slice(-2).join("/")}:${f.lineNumber + 1}`;
    self.set(name, (self.get(name) ?? 0) + (dt[i] ?? 0) / 1000);
  });
  return [...self].filter(([k]) => !k.startsWith("(idle)") && !k.startsWith("(program)") && !k.startsWith("(garbage")).sort((a, b) => b[1] - a[1]).slice(0, n).map(([k, ms]) => `${ms.toFixed(1)} ms  ${k}`);
}
async function step<T>(name: string, f: () => Promise<T>): Promise<T> {
  await prof.post("Profiler.start");
  const t0 = performance.now();
  const r = await f();
  const ms = performance.now() - t0;
  const { profile } = await prof.post("Profiler.stop");
  console.log(`\n== ${name}: ${ms.toFixed(1)} ms`);
  for (const l of top(profile)) console.log(`   ${l}`);
  return r;
}

// Home and a new chat in ws, as the wide frame lands on it
const held = [
  { topic: "prefs" },
  { topic: "accounts" },
  { topic: "workspaces" },
  { topic: "workspaceMarks" },
  { topic: "chats", scope: "ws", mine: false },
  { topic: "stations", scope: "ws" },
  { topic: "longJobs", scope: "ws" },
  { topic: "newChat", scope: "ws" },
  { topic: "composer", key: "new:ws" },
];
await call("chats.window", { scope: "ws", mine: false, rows: Number(process.env.WINDOW ?? 30) });
const subs = held.map(sub);
await Promise.all(subs.map((s) => s.first));
await sleep(3000);
const nc = values.get(subs[7]!.id);
const station: string = nc?.station?.station ?? "ws/maple";
const listed = values.get(subs[4]!.id);
const rows = (Array.isArray(listed) ? listed : Array.isArray(listed?.items) ? listed.items : Array.isArray(listed?.rows) ? listed.rows : []) as J[];
if (rows.length === 0) console.log(JSON.stringify(listed).slice(0, 400));
const title: string = String(rows.find((r: J) => typeof r?.title === "string" && r.title.length > 3)?.title ?? "发布");
const word = Array.from(title).slice(0, 3);
console.log(JSON.stringify({ station, title, rows: rows.length }));

// the `@` menu, a letter at a time, each held till the next (as a person types: TYPE_MS apart, the menu's value
// waited for)
const typeMs = Number(process.env.TYPE_MS ?? 150);
let menu = -1;
for (let i = 0; i <= word.length; i++) {
  const q = word.slice(0, i).join("");
  await step(`'@${q}' typed: chatSearch's first value`, async () => {
    core.receiveRaw(ui, { id: next++, call: "composer.text", params: { key: "new:ws", text: `@${q}` } });
    core.receiveRaw(ui, { id: next++, call: "ref.at", params: { text: `@${q}`, caret: q.length + 1 } });
    const s = sub({ topic: "chatSearch", scope: "ws", query: q, station, limit: 8, elsewhere: true });
    if (menu >= 0) unsub(menu);
    menu = s.id;
    await s.first;
  });
  await sleep(typeMs);
}
const words = `@[${title.slice(0, 24)}] 这俩为啥卡了几个小时`;
await step("picked, then Enter at once: chat.outsideRefs answered", async () => {
  const id = (await call("chat.ref", { station, id: rows[0]?.id ?? "x", title, base: "https://app.still.fail", into: "ws" })).ok;
  void id;
  unsub(menu);
  core.receiveRaw(ui, { id: next++, call: "composer.text", params: { key: "new:ws", text: words } });
  core.receiveRaw(ui, { id: next++, call: "ref.marks", params: { text: words } });
  core.receiveRaw(ui, { id: next++, call: "ref.words", params: { text: words } });
  return await call("chat.outsideRefs", { station, text: words });
});
const key = nc?.next ?? "new:bench";
await step("sent: composer.take, newChat.create, chat.send answered", async () => {
  core.receiveRaw(ui, { id: next++, call: "composer.starting", params: { key: "new:ws", starting: true } });
  const take = call("composer.take", { key: "new:ws", station });
  const made = call("newChat.create", { station, key });
  core.receiveRaw(ui, { id: next++, call: "composer.carry", params: { key: "new:ws", to: `${station}:${key}` } });
  core.receiveRaw(ui, { id: next++, call: "chat.window", params: { station, session: key, rows: 30 } });
  sub({ topic: "chat", station, session: key, compact: true });
  sub({ topic: "composer", key: `${station}:${key}` });
  sub({ topic: "chatRow", station, session: key });
  await Promise.all([take, made]);
  return await call("chat.send", { station, session: key, text: words, attachments: [], quotes: [] });
});
await step("after: the core at rest again (400 ms)", () => sleep(400));
await prof.post("Profiler.disable");
await core.close();
host.close();
process.exit(0);
