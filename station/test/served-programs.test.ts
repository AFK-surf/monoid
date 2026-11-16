// The programs that answer a device's served reads (mesh/served.ts), as this process keeps them: each numbers the
// messages it claims from 0, so a claim is settled by the program that made it alone, and one that ends settles all it
// had; one that ends is taken off the routes at once and put back as the next one listens, started again at once where
// it had run a while and a second later where it ends as it starts. The programs are the test's, and so is the time.
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { SERVED_STEADY_MS, Served, type ServingProcess } from "../src/mesh/served.ts";

/// A program as the test plays it: what it is told, and what it says.
class Program extends EventEmitter implements ServingProcess {
  told: any[] = [];
  readonly path: string;
  constructor(args: string[]) {
    super();
    this.path = args[args.indexOf("--serve") + 1]!;
  }
  postMessage(m: unknown) { this.told.push(m); }
  async terminate() { this.emit("exit", 0); return 0; }
  say(m: unknown) { this.emit("message", m); }
  /// It listens, as the program says once it does.
  listen() { this.say({ listening: this.path }); }
}

function served() {
  const programs: Program[] = [];
  let now = 1_000_000;
  const due: { at: number; f: () => void }[] = [];
  const routes: string[][] = [];
  const settled: { by: string; answer: unknown }[] = [];
  const s = new Served("stillfail-reader", mkdtempSync(join(tmpdir(), "served-")), async () => ({ status: 200, headers: {}, body: Buffer.alloc(0) }), () => {}, undefined, {
    spawn: (_binary, args) => {
      const p = new Program(args);
      programs.push(p);
      return p;
    },
    now: () => now,
    after: (ms, f) => {
      due.push({ at: now + ms, f });
      return () => {};
    },
  });
  s.onRoutes = (paths) => void routes.push(paths);
  let claims = 0;
  s.says = {
    claim: async (_viewer, path) => {
      const by = `${path}#${claims++}`;
      return { ts: by, settle: (answer) => void settled.push({ by, answer }) };
    },
    said: () => {},
  };
  const pass = (ms: number) => {
    now += ms;
    for (const d of due.splice(0).sort((a, b) => a.at - b.at)) {
      if (d.at <= now) d.f();
      else due.push(d);
    }
  };
  return { s, programs, routes, settled, pass };
}

/// Turns of the loop for what was set going to come back.
const turns = async () => {
  for (let i = 0; i < 5; i++) await new Promise<void>((r) => setImmediate(r));
};

test("two programs each claim their message 0: each is settled by its own, and those of one that ends with nothing", async () => {
  const { s, programs, settled } = served();
  const started = s.start();
  for (const p of programs) p.listen();
  await started;
  s.viewer(7, { email: "ada@x.com" });
  const [a, b] = programs as [Program, Program];
  a.say({ claim: 0, conn: 7, path: "/a", key: "k-a" });
  b.say({ claim: 0, conn: 7, path: "/b", key: "k-b" });
  await turns();
  assert.deepEqual(a.told.filter((m) => m.claimed !== undefined), [{ claimed: 0, ts: "/a#0" }]);
  assert.deepEqual(b.told.filter((m) => m.claimed !== undefined), [{ claimed: 0, ts: "/b#1" }]);
  // the first program wrote its message: its claim settled, the other's still waits
  a.say({ said: null, of: 0, answer: { status: 200, headers: {}, text: "ok" } });
  assert.deepEqual(settled.map((x) => x.by), ["/a#0"]);
  // the second ends before it says: its claim is let go, not left waiting
  b.emit("exit", 1);
  assert.deepEqual(settled.map((x) => [x.by, x.answer]), [["/a#0", settled[0]!.answer], ["/b#1", null]]);
  // and what it says no more does not settle the first's again
  b.say({ said: null, of: 0 });
  assert.equal(settled.length, 2);
  await s.close();
});

test("a claim answered after its program ended is let go at once", async () => {
  const { s, programs, settled } = served();
  const started = s.start();
  for (const p of programs) p.listen();
  await started;
  s.viewer(7, { email: "ada@x.com" });
  const a = programs[0]!;
  a.say({ claim: 0, conn: 7, path: "/a", key: "k" });
  a.emit("exit", 1);
  await turns();
  assert.deepEqual(settled.map((x) => [x.by, x.answer]), [["/a#0", null]]);
  await s.close();
});

test("a program that ends after running a while is off the routes at once, started again at once, and on them once it listens", async () => {
  const { s, programs, routes, pass } = served();
  const started = s.start();
  for (const p of programs) p.listen();
  const paths = await started;
  assert.deepEqual(routes, [], "routed by the station as it starts (mesh.ts), not told");
  pass(SERVED_STEADY_MS);
  programs[0]!.emit("exit", 1);
  assert.deepEqual(routes, [[paths[1]]]);
  assert.equal(programs.length, 3, "started again with no wait");
  assert.equal(programs[2]!.path, paths[0], "on the socket its connections' streams go to");
  programs[2]!.listen();
  assert.deepEqual(routes, [[paths[1]], paths]);
  await s.close();
});

test("a program that ends as it starts is started again a second later, and its routes come back as it listens", async () => {
  const { s, programs, routes, pass } = served();
  const started = s.start();
  for (const p of programs) p.listen();
  const paths = await started;
  pass(SERVED_STEADY_MS - 1);
  programs[1]!.emit("exit", 1);
  assert.deepEqual(routes, [[paths[0]]]);
  assert.equal(programs.length, 2);
  pass(999);
  assert.equal(programs.length, 2);
  pass(1);
  assert.equal(programs.length, 3);
  // both gone a moment: no route left, every request this process's
  programs[0]!.emit("exit", 1);
  assert.deepEqual(routes.at(-1), []);
  programs[2]!.listen();
  assert.deepEqual(routes.at(-1), [paths[1]]);
  await s.close();
});

test("one program listening and the other ended as it started: the start gives the one, and the other joins it as it listens", async () => {
  const { s, programs, routes, pass } = served();
  const started = s.start();
  programs[0]!.listen();
  programs[1]!.emit("exit", 1);
  assert.deepEqual(await started, [programs[0]!.path]);
  assert.deepEqual(routes, []);
  pass(1_000);
  programs[2]!.listen();
  assert.deepEqual(routes, [[programs[0]!.path, programs[2]!.path]]);
  await s.close();
});

test("a program that neither listens nor ends in time is ended, and started again; the start gives the one listening", async () => {
  const { s, programs, routes, pass } = served();
  const started = s.start();
  programs[0]!.listen();
  let ended = false;
  programs[1]!.on("exit", () => (ended = true));
  pass(15_000);
  assert.deepEqual(await started, [programs[0]!.path]);
  assert.equal(ended, true, "the one that hung is ended");
  assert.deepEqual(routes, [[programs[0]!.path]]);
  assert.equal(programs.length, 3);
  programs[2]!.listen();
  assert.deepEqual(routes.at(-1), [programs[0]!.path, programs[2]!.path]);
  await s.close();
});

test("none listening in time fails the start: this process answers every request till one listens", async () => {
  const { s, programs, routes, pass } = served();
  const started = s.start();
  programs[0]!.emit("exit", 1);
  programs[1]!.emit("exit", 1);
  await assert.rejects(started, /no serving program listens/);
  pass(1_000);
  programs[2]!.listen();
  assert.deepEqual(routes.at(-1), [programs[2]!.path]);
  await s.close();
});
