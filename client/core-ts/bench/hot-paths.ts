// What the paths test/hot-paths.test.ts holds took, to compare with a core from before (run it on both):
// - a chat list of 6 stations of 300 chats, a window of 50, its links catching up in 14 batches (station/sync.ts
//   `#catching`, as a phone came back to the network: 14 in a minute, 2026-11-18);
// - a chat of 500 entries, 20 of them its people's and the rest its agents' long replies, its outline first made.
//
//   node bench/hot-paths.ts
import { performance } from "node:perf_hooks";
import { holdLanguage } from "../src/i18n.ts";
import { link, rows, setup, ui, workspace } from "../test/views-rig.ts";

holdLanguage();
// deno-lint-ignore no-explicit-any
type J = any;

const RUNS = Number(process.env.RUNS ?? 5);
const agent = (key: string): J => ({ key, connect: "c1", profile: "p1", runtime: "claude", model: "opus", effort: null, process: "cold", pending: 0, lastTurn: null });
function row(station: string, i: number, at: number): J {
  const id = `${station.split("/")[1]}-${i}`;
  return { id, session: id, thread: i + 1, title: `${id} 的标题`, agents: [agent(id)], last: null, unread: false, mine: false, lastActiveAt: Math.trunc(at), connect: null, origin: null };
}
const workspaceOf = (ids: string[], nowS: number): J => ({ id: "ws", stations: ids.map((id) => ({ id, name: id, last_seen: Math.trunc(nowS), version: "0.4.0" })) });
const median = (xs: number[]) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)]!;

async function catching(): Promise<number> {
  const ids = ["a", "b", "c", "d", "e", "f"];
  const t = setup();
  const u = ui();
  const now = t.host.nowMs();
  t.set(workspace(), workspaceOf(ids, t.nowS()));
  ids.forEach((id, s) => {
    t.store.watch(link(`ws/${id}`), () => {});
    t.set(link(`ws/${id}`), { state: "online" });
    t.set(rows(`ws/${id}`), Array.from({ length: 300 }, (_, i) => row(`ws/${id}`, i, now - (i * ids.length + s) * 60_000)));
  });
  t.window({ topic: "chats", scope: "ws" }, 50);
  t.subscribe(1, { topic: "chats", scope: "ws" });
  await t.read(u, 1);
  // (the time the list's view takes to be made again, each time the store asks it: Router.compute)
  let took = 0;
  const compute = t.router.compute.bind(t.router);
  t.router.compute = (topic) => {
    const started = performance.now();
    try {
      return compute(topic);
    } finally {
      if (topic.topic === "chats") took += performance.now() - started;
    }
  };
  for (let behind = 140; behind > 0; behind -= 10) {
    t.set(link("ws/a"), { state: "online", catching: behind });
    await t.read(u, 1);
  }
  return took;
}

async function outline(): Promise<{ ms: number; chars: number }> {
  const t = setup({ all: true });
  const u = ui();
  const st = "ws/st";
  t.set(workspace(), workspaceOf(["st"], t.nowS()));
  t.set(link(st), { state: "online" });
  const at = Date.UTC(2026, 0, 5, 9, 30);
  const long = `## 改了什么\n\n${"这一段说的是列表为什么跳了一下，以及怎么改的：先量，再改，最后对比前后。".repeat(40)}\n\n\`\`\`ts\nconst x = 1;\n\`\`\``;
  const entries: [number, J][] = [];
  for (let n = 1; n <= 500; n++) {
    const person = n % 25 === 1;
    entries.push([n, { thread: 7, n, kind: "message", ts: `${n}.0`, authorKind: person ? "person" : "agent", author: person ? "a@x.com" : "k1", authorName: null, text: person ? `第 ${n} 句` : long, at: at + n * 60_000 }]);
  }
  t.data.putItems("entry", st, "7", entries);
  const db = t.data.of(st) as J;
  let chars = 0;
  const all = db.sql.all.bind(db.sql);
  db.sql.all = (q: string, p?: J) => {
    const out = all(q, p);
    for (const r of out) for (const c of r) if (typeof c === "string") chars += c.length;
    return out;
  };
  const started = performance.now();
  t.subscribe(1, { topic: "chatOutline", station: st, thread: 7 });
  await t.read(u, 1);
  return { ms: performance.now() - started, chars };
}

const c: number[] = [];
const o: { ms: number; chars: number }[] = [];
for (let i = 0; i < RUNS; i++) {
  c.push(await catching());
  o.push(await outline());
}
console.log(`14 batches of a link catching up (6 stations of 300 chats, a window of 50), the list made again: median ${median(c).toFixed(1)} ms in all (${c.map((x) => x.toFixed(1)).join(", ")})`);
console.log(`a chat of 500 entries, its outline first made: median ${median(o.map((x) => x.ms)).toFixed(1)} ms, ${o[0]!.chars} characters read of SQLite`);
