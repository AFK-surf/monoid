// The station's bounded walk (src/ops/walk.ts) and what walks with it: a workspace's size (sessions/footprint.ts),
// Codex's rollouts (read/machine.ts rolloutsIn); and the background work's wrapper (platform.backgrounded, the MoonBit
// builders' spawning in read/mb-reader.ts).
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { lstatSync, mkdirSync, mkdtempSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { type WalkEntry, walkBounded } from "../src/ops/walk.ts";
import { measuredUpTo } from "../src/sessions/footprint.ts";
import { measuredUpToReference } from "./footprint-reference.ts";
import { rolloutsIn } from "./reference/machine.ts";
import { WINDOWS, platform } from "../src/platform/index.ts";
import { backgroundedOn } from "../src/platform/unix.ts";
import { backgroundByDefault, mbSpawned } from "../src/read/mb-reader.ts";

const dirs: string[] = [];
after(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});
const fresh = () => {
  const dir = mkdtempSync(join(tmpdir(), "walk-"));
  dirs.push(dir);
  return dir;
};
/// `n` empty files in each of `dirs` directories under `root`.
function filled(root: string, dirCount: number, n: number) {
  for (let d = 0; d < dirCount; d++) {
    const sub = join(root, `d${d}`);
    mkdirSync(sub);
    for (let f = 0; f < n; f++) writeFileSync(join(sub, `f${f}`), "");
  }
}

test("a walk visits every entry breadth first, by its path relative to the root, and follows no link", async () => {
  const root = fresh();
  mkdirSync(join(root, "a", "b"), { recursive: true });
  writeFileSync(join(root, "a", "b", "deep.txt"), "x");
  writeFileSync(join(root, "top.txt"), "x");
  // A link back up: followed, it would never end.
  symlinkSync(root, join(root, "a", "loop"));
  const seen: WalkEntry[] = [];
  const walked = await walkBounded(root, (e) => void seen.push(e));
  assert.deepEqual(walked, { truncated: false, visited: 6, crossed: 0 });
  assert.deepEqual(seen.map((e) => [e.rel, e.depth]).sort(), [["", 0], ["a", 1], ["a/b", 2], ["a/b/deep.txt", 3], ["a/loop", 2], ["top.txt", 1]]);
  const loop = seen.find((e) => e.rel === "a/loop")!;
  assert.equal(loop.symlink, true);
  assert.equal(loop.directory, false);
  // Breadth first: nothing at depth 2 before all of depth 1.
  const depths = seen.map((e) => e.depth);
  assert.deepEqual(depths, [...depths].sort((x, y) => x - y));
});

test("a walk stops at its most entries, below its most depth, past its time and as it is aborted, saying why", async () => {
  const root = fresh();
  filled(root, 4, 250);
  const many = await walkBounded(root, () => {}, { maxEntries: 300 });
  assert.deepEqual(many, { truncated: true, reason: "entries", visited: 300, crossed: 0 });

  const deep = fresh();
  let at = deep;
  for (let i = 0; i < 40; i++) mkdirSync((at = join(at, "n")));
  let deepest = 0;
  const depth = await walkBounded(deep, (e) => void (deepest = Math.max(deepest, e.depth)), { maxDepth: 32 });
  assert.equal(depth.reason, "depth");
  assert.equal(depth.truncated, true);
  assert.equal(deepest, 32);

  // A clock of the test's: each look at it 10 ms on.
  let now = 0;
  const slow = await walkBounded(root, () => {}, { maxDurationMs: 100, now: () => (now += 10) });
  assert.equal(slow.reason, "duration");
  assert.ok(slow.visited < 20, `visited ${slow.visited}`);

  const stop = new AbortController();
  const aborted = await walkBounded(root, () => stop.abort(), { signal: stop.signal });
  assert.deepEqual(aborted, { truncated: true, reason: "aborted", visited: 1, crossed: 0 });
});

test("a walk asked to follow links goes into each real directory once: a link back up, or two to one, ends there", async () => {
  const root = fresh();
  mkdirSync(join(root, "a", "b"), { recursive: true });
  writeFileSync(join(root, "a", "b", "deep.txt"), "x");
  const outside = fresh();
  writeFileSync(join(outside, "there.txt"), "x");
  symlinkSync(root, join(root, "a", "loop"));
  symlinkSync(outside, join(root, "out"));
  symlinkSync(outside, join(root, "a", "out-again"));
  symlinkSync(join(root, "nowhere"), join(root, "broken"));
  const seen: WalkEntry[] = [];
  const errors: string[] = [];
  const walked = await walkBounded(root, (e) => void seen.push(e), { followLinks: true, sameDevice: false, onError: (_p, _e, op) => void errors.push(op) });
  assert.equal(walked.truncated, false);
  assert.deepEqual(seen.map((e) => e.rel).sort(), ["", "a", "a/b", "a/b/deep.txt", "a/loop", "a/out-again", "broken", "out", "out/there.txt"]);
  const by = (rel: string) => seen.find((e) => e.rel === rel)!;
  // A link says it is one, and what it names by its target; one naming nothing is neither.
  assert.deepEqual([by("out").symlink, by("out").directory], [true, true]);
  assert.deepEqual([by("a/loop").directory, by("broken").directory, by("broken").file], [true, false, false]);
  assert.deepEqual(errors, ["stat"]);
  // Bounded as ever: its entries.
  assert.equal((await walkBounded(root, () => {}, { followLinks: true, maxEntries: 3 })).reason, "entries");
});

test("a visit skips a directory or stops the walk", async () => {
  const root = fresh();
  filled(root, 3, 2);
  const seen: string[] = [];
  const skipped = await walkBounded(root, (e) => {
    seen.push(e.rel);
    return e.name === "d1" ? "skip" : undefined;
  });
  assert.equal(skipped.truncated, false);
  assert.ok(seen.includes("d1") && !seen.some((r) => r.startsWith("d1/")));
  const stopped = await walkBounded(root, (e) => (e.depth === 2 ? "stop" : undefined));
  assert.equal(stopped.reason, "stopped");
});

test("a walk does not go into a directory on another file system than its root's", { skip: WINDOWS && "no other file systems at / to cross into" }, async () => {
  // The root's own directories that are other file systems (/dev, /proc, /sys, a /Volumes disk…), as lstat says.
  const rootDev = lstatSync("/").dev;
  const others = readdirSync("/", { withFileTypes: true }).filter((d) => {
    try {
      return d.isDirectory() && lstatSync(join("/", d.name)).dev !== rootDev;
    } catch {
      return false;
    }
  }).map((d) => d.name).sort();
  const crossed: string[] = [];
  const walked = await walkBounded("/", () => {}, { maxDepth: 1, onCrossed: (e) => crossed.push(e.name) });
  assert.deepEqual(crossed.sort(), others);
  assert.equal(walked.crossed, others.length);
  const all = await walkBounded("/", () => {}, { maxDepth: 1, sameDevice: false });
  assert.equal(all.crossed, 0);
});

test("a workspace's size is a lower bound, quickly, past the walk's budget, and a link loop ends", async () => {
  const root = fresh();
  filled(root, 5, 200);
  symlinkSync(root, join(root, "d0", "loop"));
  const whole = await measuredUpTo(root, Number.MAX_SAFE_INTEGER);
  assert.equal(whole.complete, true);
  const short = await measuredUpTo(root, Number.MAX_SAFE_INTEGER, undefined, { maxEntries: 100 });
  assert.equal(short.complete, false);
  assert.equal(short.truncated, true);
  assert.ok(short.bytes <= whole.bytes);
  // Out of time: on the tests' clock, in the walk the program is held to (test/mb-footprint.test.ts), whose own clock is
  // the machine's.
  let now = 0;
  const slow = await measuredUpToReference(root, Number.MAX_SAFE_INTEGER, undefined, { maxDurationMs: 50, now: () => (now += 10) });
  assert.deepEqual([slow.complete, slow.truncated, slow.reason], [false, true, "duration"]);
  // Over its limit it stops as before, not a truncation of the walk's.
  writeFileSync(join(root, "big"), Buffer.alloc(64 * 1024, 1));
  const over = await measuredUpTo(root, 1);
  assert.deepEqual([over.complete, over.truncated], [false, undefined]);
  const stop = new AbortController();
  stop.abort();
  await assert.rejects(measuredUpTo(root, 1, stop.signal));
});

test("Codex's rollouts are found at their depth, within their bounds, no link followed", () => {
  const root = fresh();
  const day = join(root, "2026", "11", "15");
  mkdirSync(day, { recursive: true });
  writeFileSync(join(day, "rollout-1-abc.jsonl"), "");
  writeFileSync(join(day, "other.jsonl"), "");
  symlinkSync(root, join(day, "loop"));
  const found: string[] = [];
  assert.equal(rolloutsIn(root, found), false);
  assert.deepEqual(found, [join(day, "rollout-1-abc.jsonl")]);
  const shallow: string[] = [];
  assert.equal(rolloutsIn(root, shallow, { depth: 2 }), true);
  assert.deepEqual(shallow, []);
  const few: string[] = [];
  assert.equal(rolloutsIn(root, few, { entries: 2 }), true);
  assert.deepEqual(rolloutsIn(join(root, "none"), []), false);
});

test("background work is wrapped so its CPU and disk yield: taskpolicy, ionice and nice, nice, or as it is", () => {
  assert.deepEqual(backgroundedOn({ kind: "taskpolicy" }, "/bin/x", ["-a"]), ["/usr/sbin/taskpolicy", ["-b", "/bin/x", "-a"]]);
  assert.deepEqual(backgroundedOn({ kind: "ionice", ionice: "/usr/bin/ionice", nice: "/usr/bin/nice" }, "/bin/x", ["-a"]),
    ["/usr/bin/ionice", ["-t", "-c2", "-n7", "/usr/bin/nice", "-n", "10", "/bin/x", "-a"]]);
  assert.deepEqual(backgroundedOn({ kind: "nice", nice: "/usr/bin/nice" }, "/bin/x", []), ["/usr/bin/nice", ["-n", "10", "/bin/x"]]);
  assert.deepEqual(backgroundedOn({ kind: "none" }, "/bin/x", ["-a"]), ["/bin/x", ["-a"]]);
});

test("only the builders nobody waits on run as background work, not those answering requests or the readers", () => {
  for (const kind of ["replica-export", "footprint", "session-backfill", "post-blocks", "session-counts", "usage-counter", "usage-retire", "signin-save"]) {
    assert.equal(backgroundByDefault(["--builder", kind, "--db", "x"]), true, kind);
  }
  for (const kind of ["search", "vault-uses", "usage-check", "live-locator", "outflow-chats", "session-list", "card-posts", "cc-index", "replica-restore", "mesh"]) {
    assert.equal(backgroundByDefault(["--builder", kind, "--db", "x"]), false, kind);
  }
  assert.equal(backgroundByDefault(["--data", "d", "--sep", "/"]), false);
  assert.equal(backgroundByDefault(["--data", "d", "--sep", "/", "--serve", "p"]), false);
  assert.equal(backgroundByDefault(["--sessions", "1", "--data", "d"]), false);
  assert.deepEqual(mbSpawned("/r", ["--data", "d"]), ["/r", ["--data", "d"]]);
  assert.deepEqual(mbSpawned("/r", ["--builder", "cc-index"]), ["/r", ["--builder", "cc-index"]]);
  assert.deepEqual(mbSpawned("/r", ["--builder", "replica-export"]), platform.backgrounded("/r", ["--builder", "replica-export"]));
  assert.deepEqual(mbSpawned("/r", ["--builder", "replica-export"], { background: false }), ["/r", ["--builder", "replica-export"]]);
  assert.deepEqual(mbSpawned("/r", ["--builder", "session-list"], { background: true }), platform.backgrounded("/r", ["--builder", "session-list"]));
});

test("a command started as background work keeps its pid, its stdin and stdout, and its exit code", async () => {
  const script = "process.stdout.write(process.pid + '\\n'); process.stdin.once('data', (b) => { process.stdout.write('got ' + b); process.exit(7); });";
  const [command, args] = platform.backgrounded(process.execPath, ["-e", script]);
  const child = spawn(command, args, { stdio: ["pipe", "pipe", "inherit"] });
  let out = "";
  child.stdout.setEncoding("utf8");
  const firstLine = new Promise<void>((resolve) => child.stdout.on("data", (s: string) => {
    out += s;
    if (out.includes("\n")) resolve();
  }));
  const exited = new Promise<number | null>((resolve) => child.on("close", (code) => resolve(code)));
  await firstLine;
  child.stdin.end("hello\n");
  const code = await exited;
  assert.equal(code, 7);
  const [pid, said] = out.split("\n");
  assert.equal(Number(pid), child.pid);
  assert.equal(said, "got hello");
});
