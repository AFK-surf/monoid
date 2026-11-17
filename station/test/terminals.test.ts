// The station's terminals (terminals/): a view's wire over a member's link in memory, with a fake runner on its link
// (what it is asked, what it says): the screen first and only output past it, who types and who looks, 接管, resizes
// only from the typing view, read-only members, workspaces kept apart, ending one. The runner's own side (a real
// pseudo-terminal, its screen) is native/runner's tests/pty.rs.
import assert from "node:assert/strict";
import { test } from "node:test";
import type { Viewer } from "../src/mesh/credential.ts";
import { frame } from "../src/mesh/screens.ts";
import type { Stream } from "../src/mesh/native.ts";
import { TerminalLink, type Wire, pastScreen } from "../src/terminals/link.ts";
import { KIND, MOST, TERMINAL_TYPE, Terminals, asked, controlOf, oscCwd, sizeOf } from "../src/terminals/terminals.ts";
import { given, settle } from "./hub-fakes.ts";

/// A runner as its link sees it: what it was sent, and what it says.
class FakeRunner {
  sent: any[] = [];
  #lines: ((m: any) => void)[] = [];
  #closes: (() => void)[] = [];
  readonly wire: Wire = {
    write: (line) => void this.sent.push(JSON.parse(line)),
    end: () => undefined,
    on: (event: "line" | "close", f: any) => void (event === "line" ? this.#lines.push(f) : this.#closes.push(f)),
  };
  #at = 0;
  say(m: any) {
    for (const f of this.#lines) f(m);
  }
  out(text: string) {
    const data = Buffer.from(text);
    this.say({ op: "out", stream: "out", at: this.#at, data: data.toString("base64") });
    this.#at += data.length;
  }
  get at() {
    return this.#at;
  }
  /// Answers the oldest `screen` asked with `text`, as of output's offset `at`.
  screen(text: string, at = this.#at) {
    this.say({ op: "screen", at, data: Buffer.from(text).toString("base64") });
  }
  ops(op: string) {
    return this.sent.filter((m) => m.op === op);
  }
}

/// A member's stream: what the client sends (its head line given apart), what it is answered.
class FakeStream implements Stream {
  written: Buffer[] = [];
  #in: (Buffer | null)[] = [];
  #wait: ((b: Buffer | null) => void) | null = null;
  finished = false;
  async read() {
    const next = this.#in.shift();
    if (next !== undefined) return next;
    return new Promise<Buffer | null>((resolve) => (this.#wait = resolve));
  }
  async write(bytes: Buffer) {
    this.written.push(bytes);
  }
  async finish() {
    this.finished = true;
  }
  async stopped() {
    return null;
  }
  async reset() {}
  send(b: Buffer | null) {
    if (this.#wait) {
      const w = this.#wait;
      this.#wait = null;
      w(b);
    } else this.#in.push(b);
  }
  /// The head line answered, then the frames.
  answered(): { head: any; frames: { kind: number; payload: Buffer }[] } {
    const all = Buffer.concat(this.written);
    const nl = all.indexOf(10);
    const head = JSON.parse(all.subarray(0, nl).toString());
    const frames: { kind: number; payload: Buffer }[] = [];
    let rest = all.subarray(nl + 1);
    while (rest.length >= 5) {
      const n = rest.readUInt32BE(1);
      frames.push({ kind: rest[0]!, payload: rest.subarray(5, 5 + n) });
      rest = rest.subarray(5 + n);
    }
    return { head, frames };
  }
  states() {
    return this.answered().frames.filter((f) => f.kind === KIND.state).map((f) => JSON.parse(f.payload.toString()));
  }
  shown() {
    return this.answered().frames.filter((f) => f.kind === KIND.screen || f.kind === KIND.out).map((f) => `${f.kind === KIND.screen ? "screen" : "out"}:${f.payload.toString()}`);
  }
}

const viewer = (name: string, over: Partial<Viewer> = {}): Viewer => ({ sub: name, email: `${name}@x`, name, role: "member", workspace: "w1", device: `${name}-device`, ...over });

function station() {
  const runners: FakeRunner[] = [];
  const gone: string[] = [];
  let changes = 0;
  let n = 0;
  const terminals = new Terminals({
    home: "/home/a",
    chatDir: (chat) => (chat === "c1" ? "/work/c1" : undefined),
    newId: () => `term-${++n}`,
    changed: () => void changes++,
    gone: (id) => void gone.push(id),
    async start() {
      const r = new FakeRunner();
      runners.push(r);
      return new TerminalLink(r.wire);
    },
  });
  return { terminals, runners, gone, changes: () => changes };
}

const head = (id: string, terminal: Record<string, unknown>) => ({ method: "POST", path: `/admin/api/terminals/${id}/view`, terminal });

test("a new terminal is given its screen first, then only what came after it", async () => {
  const { terminals, runners } = station();
  const s = new FakeStream();
  const done = terminals.answer(s, Buffer.alloc(0), head("new", { cols: 80, rows: 24, chat: "c1" }), viewer("ann"));
  await settle();
  const r = runners[0]!;
  // Output that came before the screen was answered: the screen has some of it.
  r.out("hello ");
  r.out("world");
  r.screen("[screen:hello]", 6);
  r.out("!");
  await settle();
  assert.equal(s.answered().head.status, 200);
  assert.equal(s.answered().head.headers["content-type"], TERMINAL_TYPE);
  assert.deepEqual(s.shown(), ["screen:[screen:hello]", "out:world", "out:!"]);
  // Opened in its chat's folder, at its size, typed into by the one who opened it.
  assert.deepEqual(terminals.list("w1").map((t) => [t.id, t.cwd, t.chat, t.by, t.typing]), [["term-1", "/work/c1", "c1", "ann", "ann"]]);
  assert.deepEqual(r.ops("resize").at(-1), { op: "resize", cols: 80, rows: 24 });
  // A watching view gets the resized screen, while the typing view that initiated resize keeps its local terminal (no destructive screen echo).
  const w = new FakeStream();
  const wd = terminals.answer(w, Buffer.alloc(0), head("term-1", { cols: 80, rows: 24, control: false }), viewer("bob"));
  await settle();
  r.screen("[screen:initial-bob]");
  await settle();
  const shownBeforeResize = s.shown().length;
  s.send(frame(KIND.input, Buffer.from("ls\r")));
  s.send(frame(KIND.resize, Buffer.from(JSON.stringify({ cols: 100, rows: 30 }))));
  await settle();
  assert.deepEqual(r.ops("write").map((m) => Buffer.from(m.data, "base64").toString()), ["ls\r"]);
  assert.deepEqual(r.ops("resize").at(-1), { op: "resize", cols: 100, rows: 30 });
  r.screen("[screen:resized]");
  await settle();
  assert.equal(s.shown().length, shownBeforeResize, "typing view is not echoed a screen snapshot on its own resize");
  assert.equal(w.shown().at(-1), "screen:[screen:resized]", "watching view receives resized screen snapshot");
  s.send(null);
  w.send(null);
  await given(Promise.all([done, wd]), "the views end with their streams");
  assert.ok(s.finished);
});

test("in-band KIND.control releases typing (只看) and takes over (接管) without reopening the stream", async () => {
  const { terminals, runners } = station();
  const a = new FakeStream();
  const ad = terminals.answer(a, Buffer.alloc(0), head("new", { cols: 80, rows: 24 }), viewer("ann"));
  await settle();
  const r = runners[0]!;
  r.screen("s1");
  await settle();
  const b = new FakeStream();
  const bd = terminals.answer(b, Buffer.alloc(0), head("term-1", { cols: 90, rows: 28, control: false }), viewer("bob"));
  await settle();
  r.screen("s2");
  await settle();
  assert.equal(a.states().at(-1).types, true);
  assert.equal(a.states().at(-1).inband, true);
  assert.equal(b.states().at(-1).types, false);

  // Ann steps back to 只看 in-band without closing stream `a`.
  a.send(frame(KIND.control, Buffer.from(JSON.stringify({ control: false }))));
  await settle();
  assert.equal(a.states().at(-1).types, false);
  assert.equal(a.states().at(-1).typing, null);
  assert.equal(terminals.list("w1")[0]!.typing, null);

  // Bob takes control in-band on stream `b` and resizes to 90x28; Ann gets the resized screen snapshot.
  b.send(frame(KIND.control, Buffer.from(JSON.stringify({ control: true, taken: true, cols: 90, rows: 28 }))));
  await settle();
  r.screen("s-90x28");
  await settle();
  assert.equal(b.states().at(-1).types, true);
  assert.equal(b.states().at(-1).cols, 90);
  assert.equal(b.states().at(-1).rows, 28);
  assert.equal(a.states().at(-1).types, false);
  assert.equal(a.states().at(-1).typing, "bob");
  assert.equal(a.shown().at(-1), "screen:s-90x28");
  assert.deepEqual(r.ops("resize").at(-1), { op: "resize", cols: 90, rows: 28 });

  a.send(null);
  b.send(null);
  await given(Promise.all([ad, bd]), "the views end");
});

test("one view types, the others look; 接管 takes it and the one before is told", async () => {
  const { terminals, runners } = station();
  const a = new FakeStream();
  const ad = terminals.answer(a, Buffer.alloc(0), head("new", { cols: 80, rows: 24 }), viewer("ann"));
  await settle();
  const r = runners[0]!;
  r.screen("s1");
  await settle();
  const b = new FakeStream();
  const bd = terminals.answer(b, Buffer.alloc(0), head("term-1", { cols: 60, rows: 20 }), viewer("bob"));
  await settle();
  r.screen("s2");
  await settle();
  // Bob asked to type but did not take it: he looks, and his size changes nothing.
  assert.equal(b.states().at(-1).types, false);
  assert.equal(b.states().at(-1).typing, "ann");
  assert.deepEqual(r.ops("resize").map((m) => m.cols), [80]);
  b.send(frame(KIND.input, Buffer.from("x")));
  await settle();
  assert.deepEqual(r.ops("write"), []);
  // 接管: Carol takes it; Ann is told she now looks, and her typing reaches nothing.
  const c = new FakeStream();
  const cd = terminals.answer(c, Buffer.alloc(0), head("term-1", { cols: 70, rows: 22, taken: true }), viewer("carol"));
  await settle();
  r.screen("s3");
  await settle();
  assert.equal(c.states().at(-1).types, true);
  assert.equal(a.states().at(-1).types, false);
  assert.equal(a.states().at(-1).typing, "carol");
  assert.deepEqual(r.ops("resize").at(-1), { op: "resize", cols: 70, rows: 22 });
  a.send(frame(KIND.input, Buffer.from("a")));
  c.send(frame(KIND.input, Buffer.from("c")));
  await settle();
  assert.deepEqual(r.ops("write").map((m) => Buffer.from(m.data, "base64").toString()), ["c"]);
  assert.deepEqual(terminals.list("w1")[0]!.looking.sort(), ["ann", "bob"]);
  for (const s of [a, b, c]) s.send(null);
  await given(Promise.all([ad, bd, cd]), "the views end");
});

test("a read-only member opens none and only looks", async () => {
  const { terminals, runners } = station();
  const v = viewer("vic", { role: "viewer" });
  const refused = new FakeStream();
  await terminals.answer(refused, Buffer.alloc(0), head("new", { cols: 80, rows: 24 }), v);
  assert.equal(refused.answered().head.status, 403);
  assert.equal(runners.length, 0);
  const a = new FakeStream();
  void terminals.answer(a, Buffer.alloc(0), head("new", { cols: 80, rows: 24 }), viewer("ann"));
  await settle();
  runners[0]!.screen("s");
  const s = new FakeStream();
  void terminals.answer(s, Buffer.alloc(0), head("term-1", { cols: 80, rows: 24, taken: true }), v);
  await settle();
  runners[0]!.screen("s");
  await settle();
  assert.equal(s.states().at(-1).types, false);
  s.send(frame(KIND.input, Buffer.from("rm -rf /\r")));
  await settle();
  assert.deepEqual(runners[0]!.ops("write"), []);
});

test("a workspace's terminals are its own", async () => {
  const { terminals, runners } = station();
  void terminals.answer(new FakeStream(), Buffer.alloc(0), head("new", { cols: 80, rows: 24 }), viewer("ann"));
  await settle();
  runners[0]!.screen("s");
  await settle();
  assert.equal(terminals.list("w2").length, 0);
  const other = new FakeStream();
  await terminals.answer(other, Buffer.alloc(0), head("term-1", { cols: 80, rows: 24 }), viewer("eve", { workspace: "w2" }));
  assert.equal(other.answered().head.status, 404);
  assert.equal(terminals.end("term-1", "eve", "w2"), false);
});

test("ending one kills its program; it leaves the list once it ended and none looks", async () => {
  const { terminals, runners, gone } = station();
  const a = new FakeStream();
  const ad = terminals.answer(a, Buffer.alloc(0), head("new", { cols: 80, rows: 24 }), viewer("ann"));
  await settle();
  const r = runners[0]!;
  r.screen("s");
  await settle();
  assert.equal(terminals.end("term-1", "bob", "w1"), true);
  assert.deepEqual(r.ops("signal"), [{ op: "signal", signal: "KILL", group: true }]);
  r.say({ op: "exit", code: null, signal: "KILL" });
  await settle();
  // The view still on it is told how it ended; it stays listed (ended) till that view goes.
  assert.deepEqual(a.states().at(-1).ended, { code: null, signal: "KILL" });
  assert.deepEqual(terminals.list("w1")[0]!.ended, { code: null, signal: "KILL" });
  a.send(null);
  await given(ad, "the view ends");
  assert.deepEqual(terminals.list("w1"), []);
  assert.deepEqual(gone, ["term-1"]);
});

test("a station keeps so many terminals at most", async () => {
  const { terminals, runners } = station();
  for (let i = 0; i < MOST; i++) void terminals.answer(new FakeStream(), Buffer.alloc(0), head("new", { cols: 80, rows: 24 }), viewer("ann"));
  await settle();
  assert.equal(runners.length, MOST);
  const s = new FakeStream();
  await terminals.answer(s, Buffer.alloc(0), head("new", { cols: 80, rows: 24 }), viewer("ann"));
  assert.equal(s.answered().head.status, 429);
});

test("what a view asks is checked", () => {
  assert.equal(asked({ cols: 0, rows: 24 }), null);
  assert.equal(asked({ cols: 80, rows: 9999 }), null);
  assert.deepEqual(asked({ cols: 80, rows: 24 }), { cols: 80, rows: 24, control: true, taken: false });
  assert.equal(sizeOf(Buffer.from("nope")), null);
  assert.deepEqual(sizeOf(Buffer.from('{"cols":10,"rows":5}')), { cols: 10, rows: 5 });
  assert.equal(controlOf(Buffer.from("nope")), null);
  assert.deepEqual(controlOf(Buffer.from('{"control":false}')), { control: false, taken: false });
  assert.deepEqual(controlOf(Buffer.from('{"control":true,"taken":true,"cols":120,"rows":40}')), { control: true, taken: true, cols: 120, rows: 40 });
  assert.equal(pastScreen({ at: 0, bytes: Buffer.from("abc") }, 3), null);
  assert.equal(pastScreen({ at: 0, bytes: Buffer.from("abcdef") }, 3)!.toString(), "def");
  assert.equal(pastScreen({ at: 5, bytes: Buffer.from("xy") }, 3)!.toString(), "xy");
});

test("shell OSC 7 and OSC 9;9 keep a terminal's folder live across chunks", async () => {
  assert.deepEqual(oscCwd("\x1b]7;file://mac.local/Users/ann/%E6%96%87%E6%A1%A3\x07$ "), { cwd: "/Users/ann/文档", tail: "" });
  assert.deepEqual(oscCwd('\x1b]9;9;"C:\\Users\\ann\\proj"\x1b\\PS> '), { cwd: "C:\\Users\\ann\\proj", tail: "" });
  const half = oscCwd("out\x1b]7;file:///Users/ann/wo");
  assert.equal(half.cwd, null);
  assert.equal(half.tail, "\x1b]7;file:///Users/ann/wo");
  assert.deepEqual(oscCwd(half.tail + "rk\x07$ "), { cwd: "/Users/ann/work", tail: "" });

  const { terminals, runners } = station();
  const a = new FakeStream();
  const ad = terminals.answer(a, Buffer.alloc(0), head("new", { cols: 80, rows: 24 }), viewer("ann"));
  await settle();
  const r = runners[0]!;
  r.screen("s");
  await settle();
  r.out("\x1b]7;file://host/Users/ann/monoid");
  await settle();
  r.out("/apps/mbui\x07$ ");
  await settle();
  assert.equal(terminals.list("w1")[0]!.cwd, "/Users/ann/monoid/apps/mbui");
  assert.equal(a.states().at(-1).cwd, "/Users/ann/monoid/apps/mbui");
  a.send(null);
  await given(ad, "the view ends");
});
