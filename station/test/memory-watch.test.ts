// The watch over the memory of what the agents run (jobs/memory.ts): what a unit is, who is told when, and that only a
// machine about to run out of memory has anything stopped (the largest, one at a time). The process table, the
// system's pressure and the signals are the test's; time is a TestClock.
import assert from "node:assert/strict";
import { after, test } from "node:test";
import { Effect, Exit, Scope } from "effect";
import { TestClock } from "effect/testing";
import type { Pressure } from "../src/jobs/admit.ts";
import { MemoryWatch, SETTLE_MS, STOP_GRACE_MS, type Unit, kmsgKill, limitOf, unitsOf } from "../src/jobs/memory.ts";
import type { ProcessInfo } from "../src/platform/index.ts";
import { fieldOrNull, parsePs, parseTopMem, pressureOfAvailable, pressureOfLevel, pressureOfSwap, swapUsedOf, swapoutsOf, worsePressure } from "../src/platform/text.ts";

const GiB = 1024 ** 3;
const p = (pid: number, ppid: number, pgid: number, gib: number, command = "node"): ProcessInfo => ({ pid, ppid, pgid, bytes: gib * GiB, command });

const scopes: Scope.Closeable[] = [];
after(async () => {
  for (const scope of scopes) await Effect.runPromise(Scope.close(scope, Exit.void)).catch(() => undefined);
});

test("a unit is a job's group and what it started, or one command a runtime started; the runtime itself is none", () => {
  const table = [
    p(1, 0, 1, 0, "launchd"),
    p(10, 1, 10, 0.2, "stillfail-station"),
    // A runner, its runtime (claude), two commands it runs: a shell running a build, and an MCP server.
    p(20, 1, 20, 0, "stillfail-runner"),
    p(21, 20, 20, 0.5, "claude"),
    p(22, 21, 22, 0.1, "/bin/zsh"),
    p(23, 22, 22, 3, "/usr/bin/zig"),
    p(24, 21, 24, 0.3, "mcp"),
    // A job: its shell, a server it started that left its parent behind (still in its group).
    p(30, 1, 30, 0.1, "sh"),
    p(31, 30, 30, 1, "cargo"),
    p(32, 1, 30, 2, "server"),
    // Someone else's.
    p(40, 1, 40, 9, "Xcode"),
  ];
  const units = unitsOf(table, [{ id: "job_1", session: "s1", pgid: 30, label: 'Job "build" (job_1)' }], [{ pid: 21, session: "s2" }], 10);
  assert.deepEqual(
    units.map((u) => [u.key, u.session, u.pids.sort((a, b) => a - b), Math.round((u.bytes / GiB) * 10) / 10]),
    [
      ["job:job_1", "s1", [30, 31, 32], 3.1],
      ["pid:22", "s2", [22, 23], 3.1],
      ["pid:24", "s2", [24], 0.3],
    ],
  );
  assert.equal(units[1]!.label, "command zig (pid 22)");
});

test("the swap says what the memory used leaves out (macOS)", () => {
  // 66 GiB swapped on a 64 GiB machine with pages still going out: critical; a quarter: high; swap kept from before while
  // nothing goes out says nothing.
  assert.equal(pressureOfSwap(66 * GiB, 64 * GiB, 5000), "critical");
  assert.equal(pressureOfSwap(20 * GiB, 64 * GiB, 5000), "high");
  assert.equal(pressureOfSwap(8 * GiB, 64 * GiB, 5000), "normal");
  assert.equal(pressureOfSwap(66 * GiB, 64 * GiB, 0), "normal");
  assert.equal(pressureOfSwap(66 * GiB, 64 * GiB, null), null);
  assert.equal(worsePressure("normal", "critical"), "critical");
  assert.equal(worsePressure("high", null), "high");
  assert.equal(swapoutsOf("Pages free: 1.\nSwapouts:                                  375142124.\n"), 375142124);
  assert.equal(swapUsedOf("total = 68608.00M  used = 66279.69M  free = 2328.31M  (encrypted)"), 69499292221);
});

test("what the machines say reads", () => {
  assert.equal(fieldOrNull("Anonymous pages: 0.\n", "Anonymous pages"), 0);
  assert.equal(fieldOrNull("Anonymous pages: 123.\n", "Anonymous pages"), 123);
  assert.equal(fieldOrNull("Anonymous pages: unknown\n", "Anonymous pages"), null);
  assert.equal(fieldOrNull("Pages wired down: 123.\n", "Anonymous pages"), null);
  assert.equal(pressureOfLevel("1\n"), "normal");
  // Level 1 still catches memory exhaustion when available RAM falls below 10% / 4% (e.g. 14 GiB macOS VM).
  assert.equal(pressureOfLevel("1", 4 * GiB, 14 * GiB), "normal");
  assert.equal(pressureOfLevel("1", 1 * GiB, 14 * GiB), "high");
  assert.equal(pressureOfLevel("1", 80 * 1024 ** 2, 14 * GiB), "critical");
  assert.equal(pressureOfLevel("2"), "high");
  // Warn with a quarter of the memory available is not pressure (#4355); with under a tenth it is.
  assert.equal(pressureOfLevel("2", 6, 24), "normal");
  assert.equal(pressureOfLevel("2", 2, 24), "high");
  assert.equal(pressureOfLevel("4", 20, 24), "critical");
  assert.equal(pressureOfLevel("4"), "critical");
  assert.equal(pressureOfLevel(""), null);
  assert.equal(pressureOfAvailable(50, 100), "normal");
  assert.equal(pressureOfAvailable(9, 100), "high");
  assert.equal(pressureOfAvailable(3, 100), "critical");
  assert.equal(pressureOfAvailable(1, 0), null);
  assert.equal(pressureOfAvailable(fieldOrNull("MemTotal: 100 kB\n", "MemAvailable"), 100), null);
  assert.equal(pressureOfAvailable(0, null), null);
  assert.equal(pressureOfAvailable(101, 100), null);
  assert.deepEqual(parsePs("  1     0     1  1024 /sbin/launchd\n99705 99451 99705 27 node a b\n"), [
    { pid: 1, ppid: 0, pgid: 1, bytes: 1024 * 1024, command: "/sbin/launchd" },
    { pid: 99705, ppid: 99451, pgid: 99705, bytes: 27 * 1024, command: "node a b" },
  ]);
  const top = parseTopMem("Processes: 699 total\nPID    MEM\n99705  27M\n95698  3056K\n95445  2873M+\n100 1.5G-\n7 12B\n");
  assert.deepEqual([...top], [[99705, 27 * 1024 ** 2], [95698, 3056 * 1024], [95445, 2873 * 1024 ** 2], [100, 1.5 * GiB], [7, 12]]);
});

type Rig = ReturnType<typeof rig>;

function rig() {
  const scope = Effect.runSync(Scope.make());
  scopes.push(scope);
  const clock = Effect.runSync(Scope.provide(TestClock.make(), scope));
  const state = { pressure: "normal" as Pressure, table: [] as ProcessInfo[], exact: [] as boolean[], cwds: 0, owners: 0 };
  const told: [string | null, string][] = [];
  const signals: [number, string][] = [];
  const stoppedJobs: string[] = [];
  const watch = new MemoryWatch({
    clock,
    pressure: async () => state.pressure,
    table: async (exact) => {
      state.exact.push(exact);
      return state.table;
    },
    totalBytes: () => 64 * GiB,
    cwds: async (pids) => { state.cwds++; return new Map(pids.map((pid) => [pid, `/sessions/s9/workspace/sub`])); },
    jobs: () => [{ id: "job_1", session: "remote:x", pgid: 30, label: 'Job "build" (job_1)' }],
    // A runtime of one session's, and one shared by sessions (codex's host).
    agents: async () => [{ pid: 21, session: "s2" }, { pid: 51, session: null }],
    sessionAt: (dir) => { state.owners++; return dir.startsWith("/sessions/s9/workspace") ? "s9" : null; },
    tell: (u: Unit, text) => void told.push([u.job ?? u.session, text]),
    stopJob: async (id) => void stoppedJobs.push(id),
    signal: (pid, signal) => void signals.push([pid, signal]),
    self: 10,
  });
  return { watch, clock, state, told, signals, stoppedJobs };
}

const tables = {
  /// A job of 3 GiB, a command of 9 GiB, a codex command of 1 GiB.
  some: (build = 9) => [
    p(21, 20, 20, 0.5, "claude"),
    p(22, 21, 22, 0.1, "zsh"),
    p(23, 22, 22, build, "zig"),
    p(30, 1, 30, 3, "sh"),
    p(51, 50, 50, 0.4, "codex"),
    p(52, 51, 52, 1, "pnpm"),
  ],
};

test("much memory is told to its agent, again when it doubles; nothing is stopped for it", async () => {
  const r = rig();
  r.state.table = tables.some();
  await r.watch.look();
  // The limit on 64 GiB is 8 GiB: the 9 GiB command is told, the 3 GiB job not.
  assert.equal(limitOf(64 * GiB), 8 * GiB);
  assert.deepEqual(r.told.map(([who]) => who), ["s2"]);
  assert.match(r.told[0]![1], /command zig \(pid 22\) on this station uses 9\.1 GiB/);
  await r.watch.look();
  assert.equal(r.told.length, 1, "told once");
  r.state.table = tables.some(19);
  await r.watch.look();
  assert.equal(r.told.length, 2, "again, as it doubled");
  assert.deepEqual(r.signals, []);
  assert.deepEqual(r.stoppedJobs, []);
  assert.deepEqual(r.state.exact, [false, false, false], "resident memory is enough while there is no pressure");
});

test("under pressure the largest few are told once, and still nothing is stopped", async () => {
  const r = rig();
  r.state.table = tables.some(4);
  r.state.pressure = "high";
  await r.watch.look();
  await r.watch.look();
  assert.deepEqual(r.told.map(([who]) => who), ["s2", "job_1", "s9"], "the codex command's session found by its directory");
  assert.match(r.told[0]![1], /memory is under pressure/);
  // (pnpm, 1 GiB, is under PAUSED_MIN: it runs on beside zig)
  assert.deepEqual(r.signals, []);
  assert.deepEqual(r.state.exact, [true, true], "read exactly under pressure");
  // Eased, and again under pressure: told again.
  r.state.pressure = "normal";
  await r.watch.look();
  r.state.pressure = "high";
  await r.watch.look();
  assert.equal(r.told.length, 6);
});

test("under pressure the agents' big commands queue: one runs, the rest wait paused and go on in their order once it eases", async () => {
  const r = rig();
  const saved: number[][] = [];
  const watch = new MemoryWatch({
    pressure: async () => r.state.pressure, table: async () => r.state.table, totalBytes: () => 64 * GiB,
    cwds: async () => new Map(), jobs: () => [], agents: async () => [{ pid: 21, session: "s2" }],
    sessionAt: () => null, tell: (u: Unit, text) => void r.told.push([u.session, text]),
    stopJob: async () => {}, signal: (pid, signal) => void r.signals.push([pid, signal]), self: 10,
    savePaused: async (pids) => void saved.push(pids),
  });
  const shell = (pid: number, gib: number, program: string) => [p(pid, 21, pid, 0.1, "zsh"), p(pid + 1, pid, pid, gib, program)];
  r.state.table = [p(21, 20, 20, 0.5, "claude"), ...shell(30, 6, "lean")];
  await watch.look();
  r.state.table.push(...shell(40, 5, "lean"), ...shell(50, 4, "cargo"), p(60, 21, 60, 1.5, "mcp-browser"));
  r.state.pressure = "high";
  await watch.look();
  assert.deepEqual(r.signals, [[40, "SIGSTOP"], [41, "SIGSTOP"], [50, "SIGSTOP"], [51, "SIGSTOP"]], "the earliest (pid 30) runs on");
  assert.deepEqual(saved.at(-1), [40, 41, 50, 51]);
  await watch.look();
  assert.equal(r.signals.length, 4, "paused once");
  // The pressure gone: one a look, earliest first.
  r.state.pressure = "normal";
  await watch.look();
  assert.deepEqual(r.signals.slice(4), [[40, "SIGCONT"], [41, "SIGCONT"]]);
  assert.match(r.told.at(-1)![1], /command lean \(pid 40\), paused while .* goes on now/);
  await watch.look();
  assert.deepEqual(r.signals.slice(6), [[50, "SIGCONT"], [51, "SIGCONT"]]);
  assert.deepEqual(saved.at(-1), []);
  // Paused again, then the station ends: nothing is left stopped behind it.
  r.state.pressure = "high";
  await watch.look();
  r.signals.length = 0;
  await watch.close();
  assert.deepEqual(r.signals, [[40, "SIGCONT"], [41, "SIGCONT"], [50, "SIGCONT"], [51, "SIGCONT"]]);
  assert.deepEqual(saved.at(-1), []);
});

test("what a command left running after its shell ended stays its session's, and under pressure it is stopped first", async () => {
  const r = rig();
  const watch = new MemoryWatch({
    clock: r.clock,
    pressure: async () => r.state.pressure, table: async () => r.state.table, totalBytes: () => 64 * GiB,
    cwds: async () => new Map(), jobs: () => [], agents: async () => [{ pid: 21, session: "s2" }],
    sessionAt: () => null, tell: (u: Unit, text) => void r.told.push([u.session, text]),
    stopJob: async () => {}, signal: (pid, signal) => void r.signals.push([pid, signal]), self: 10,
  });
  // lake runs lean under the agent's shell; the shell and lake end, lean is left to the system (its parent 1).
  r.state.table = [p(21, 20, 20, 0.5, "claude"), p(30, 21, 30, 0.1, "zsh"), p(31, 30, 30, 0.1, "lake"), p(32, 31, 30, 9, "lean")];
  await watch.look();
  r.state.table = [p(21, 20, 20, 0.5, "claude"), p(32, 1, 30, 9, "lean"), p(33, 32, 30, 1, "lean"), p(60, 1, 60, 8, "Xcode")];
  await watch.look();
  assert.deepEqual(r.signals, [], "nothing stopped while there is room");
  // A pid taken again by another program is not it.
  const units = unitsOf(r.state.table, [], [{ pid: 21, session: "s2" }], 10, new Map([[32, { session: "s2", command: "lean", label: "x" }], [60, { session: "s2", command: "lean", label: "x" }]]));
  assert.deepEqual(units.map((u) => [u.key, u.session, u.pids.sort((a, b) => a - b), u.orphan]), [["orphan:32", "s2", [32, 33], true]]);
  r.state.pressure = "high";
  const look = watch.look();
  await new Promise((resolve) => setTimeout(resolve, 1));
  await stopping(r, look);
  assert.deepEqual(r.signals, [[32, "SIGTERM"], [33, "SIGTERM"], [32, "SIGKILL"], [33, "SIGKILL"]]);
  assert.ok(r.told.some(([who, text]) => who === "s2" && /stopped your command lean \(pid 32, left running after its shell ended\)/.test(text)));
  await watch.close();
});

test("commands in the same directory share its owner lookup within one memory check", async () => {
  const told: string[] = [];
  let reads = 0;
  const watch = new MemoryWatch({
    pressure: async () => "normal",
    table: async () => [p(51, 50, 50, 0, "codex"), p(52, 51, 52, 3, "one"), p(53, 51, 53, 3, "two")],
    totalBytes: () => 8 * GiB,
    cwds: async (pids) => new Map(pids.map((pid) => [pid, "/session/workspace/sub"])),
    jobs: () => [], agents: async () => [{ pid: 51, session: null }],
    sessionAt: () => { reads++; return "s1"; },
    tell: (unit) => { if (unit.session !== null) told.push(unit.session); },
    stopJob: async () => {}, signal: () => {}, self: 10,
  });
  try {
    await watch.look();
    assert.deepEqual(told, ["s1", "s1"]);
    assert.equal(reads, 1);
  } finally { await watch.close(); }
});

test("a command needs no directory lookup until its agent needs a notice", async () => {
  const state = { pressure: "normal" as Pressure, bytes: 1 * GiB, cwds: 0, owners: 0 };
  const told: string[] = [];
  const watch = new MemoryWatch({
    pressure: async () => state.pressure,
    table: async () => [p(51, 50, 50, 0, "codex"), { ...p(52, 51, 52, 0, "build"), bytes: state.bytes }],
    totalBytes: () => 8 * GiB,
    cwds: async (pids) => { state.cwds++; return new Map(pids.map((pid) => [pid, "/session/workspace"])); },
    jobs: () => [], agents: async () => [{ pid: 51, session: null }],
    sessionAt: () => { state.owners++; return "s1"; },
    tell: (unit) => { if (unit.session !== null) told.push(unit.session); },
    stopJob: async () => {}, signal: () => {}, self: 10,
  });
  try {
    await watch.look();
    assert.deepEqual([state.cwds, state.owners], [0, 0]);
    state.pressure = "high";
    await watch.look();
    assert.deepEqual(told, ["s1"]);
    assert.deepEqual([state.cwds, state.owners], [1, 1]);
    await watch.look();
    assert.deepEqual([state.cwds, state.owners], [1, 1], "already told at this pressure");
    state.bytes = 3 * GiB;
    await watch.look();
    assert.deepEqual(told, ["s1", "s1"]);
    assert.deepEqual([state.cwds, state.owners], [2, 2]);
  } finally { await watch.close(); }
});

async function stopping(r: Rig, look: Promise<unknown>) {
  // A command's stop waits STOP_GRACE_MS before the SIGKILL.
  for (let i = 0; i < 10 && r.signals.length > 0 && !r.signals.some(([, s]) => s === "SIGKILL"); i++) {
    await Effect.runPromise(r.clock.adjust(`${STOP_GRACE_MS} millis`));
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
  await look;
}

test("a shared command already told under pressure is named again when it must be stopped", async () => {
  const r = rig();
  r.state.table = tables.some(9);
  r.state.pressure = "critical";
  const first = r.watch.look();
  await new Promise((resolve) => setTimeout(resolve, 1));
  await stopping(r, first);
  assert.ok(r.told.some(([who, text]) => who === "s9" && /memory is under pressure/.test(text)));

  // The shared command remains while the first stop settles. It needs no owner read until the next stop.
  r.state.table = [p(51, 50, 50, 0.4, "codex"), p(52, 51, 52, 1, "pnpm")];
  r.signals.length = 0;
  const reads = [r.state.cwds, r.state.owners];
  await r.watch.look();
  assert.deepEqual([r.state.cwds, r.state.owners], reads);
  await Effect.runPromise(r.clock.adjust(`${SETTLE_MS} millis`));
  const second = r.watch.look();
  await new Promise((resolve) => setTimeout(resolve, 1));
  await stopping(r, second);
  assert.deepEqual([r.state.cwds, r.state.owners], reads.map((n) => n + 1));
  assert.deepEqual(r.signals, [[52, "SIGTERM"], [52, "SIGKILL"]]);
  assert.ok(r.told.some(([who, text]) => who === "s9" && /stopped your command pnpm/.test(text)));
});

test("about to run out, the largest is stopped and its agent told why; the next only after a while, if still so", async () => {
  const r = rig();
  r.state.table = tables.some(9);
  r.state.pressure = "critical";
  const first = r.watch.look();
  await new Promise((resolve) => setTimeout(resolve, 1));
  await stopping(r, first);
  assert.deepEqual(r.signals, [[22, "SIGTERM"], [23, "SIGTERM"], [22, "SIGKILL"], [23, "SIGKILL"]]);
  assert.ok(r.told.some(([who, text]) => who === "s2" && /about to run out of memory, so it stopped your command zig/.test(text)));
  // Still critical, the big command gone: the job is next, but not before SETTLE_MS.
  r.state.table = tables.some(0).filter((x) => x.pid !== 22 && x.pid !== 23);
  await r.watch.look();
  assert.deepEqual(r.stoppedJobs, []);
  await Effect.runPromise(r.clock.adjust(`${SETTLE_MS} millis`));
  await r.watch.look();
  assert.deepEqual(r.stoppedJobs, ["job_1"]);
  assert.ok(r.told.some(([who, text]) => who === "job_1" && /stopped your Job "build"/.test(text)));
});

test("the kernel's log says whom its OOM killer killed, and when", () => {
  assert.deepEqual(kmsgKill("3,8812,52194958134,-;Out of memory: Killed process 1190811 (chromium) total-vm:1518404136kB, anon-rss:122600kB, file-rss:128316kB, shmem-rss:4148kB, UID:1000 pgtables:2173kB oom_score_adj:300"),
    { usec: 52194958134, pid: 1190811, name: "chromium" });
  assert.deepEqual(kmsgKill("3,9001,77000000,-;Memory cgroup out of memory: Killed process 42 (cargo build) total-vm:10kB"), { usec: 77000000, pid: 42, name: "cargo build" });
  assert.equal(kmsgKill("6,8813,52194958200,-;oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),cpuset=/,task=chromium,pid=1190811,uid=1000"), null);
  assert.equal(kmsgKill("6,1,1,-;Linux version 6.12"), null);
});

test("a process the kernel kills for memory is told to the agent whose unit it was at the last look; one of nobody's only logged", async () => {
  const told: [string | null, string][] = [];
  let hear: ((kill: { pid: number; name: string }) => void) | null = null;
  const watch = new MemoryWatch({
    pressure: async () => "normal",
    // A runner's claude (21) running a shell (22) and the browser it started (23); a job (30, 31).
    table: async () => [p(20, 1, 20, 0, "stillfail-runner"), p(21, 20, 20, 0.5, "claude"), p(22, 21, 22, 0.1, "/bin/sh"), p(23, 22, 22, 0.4, "/usr/lib/chromium/chromium"),
      p(30, 1, 30, 0.1, "sh"), p(31, 30, 30, 0.2, "cargo")],
    totalBytes: () => 16 * GiB, freeBytes: () => 2 * GiB,
    cwds: async () => new Map(), sessionAt: () => null,
    jobs: () => [{ id: "job_1", session: "s1", pgid: 30, label: 'Job "build" (job_1)' }], agents: async () => [{ pid: 21, session: "s2" }],
    tell: (unit, text) => told.push([unit.session, text]),
    stopJob: async () => {}, signal: () => {}, self: 10,
    kills: (heard) => { hear = heard; return () => { hear = null; }; },
  });
  watch.start();
  try {
    await watch.look();
    await watch.killed({ pid: 23, name: "chromium" });
    await watch.killed({ pid: 31, name: "cargo" });
    await watch.killed({ pid: 999, name: "Xorg" });
    assert.equal(told.length, 2);
    assert.equal(told[0]![0], "s2");
    assert.match(told[0]![1], /the kernel killed chromium \(pid 23\), a process of your command chromium \(pid 22\)\. The machine had 2\.0 GiB free of 16\.0 GiB just after\./);
    assert.equal(told[1]![0], "s1");
    assert.match(told[1]![1], /killed cargo \(pid 31\), a process of your Job "build" \(job_1\)/);
    assert.notEqual(hear, null, "heard while it runs");
  } finally {
    await watch.close();
  }
  assert.equal(hear, null, "no longer heard once closed");
});

test("a kill heard just after a look that no longer saw its process is still its agent's; a shared runtime's command is found by a process of it still alive", async () => {
  const told: [string | null, string][] = [];
  let table = [p(50, 1, 50, 0, "stillfail-runner"), p(51, 50, 50, 0.5, "codex"), p(52, 51, 52, 0.1, "/bin/sh"), p(53, 52, 52, 0.4, "node")];
  const asked: number[][] = [];
  const watch = new MemoryWatch({
    pressure: async () => "normal",
    table: async () => table,
    totalBytes: () => 16 * GiB,
    cwds: async (pids) => { asked.push(pids); return new Map(pids.filter((pid) => table.some((x) => x.pid === pid)).map((pid) => [pid, "/w/s3"])); },
    sessionAt: (dir) => (dir === "/w/s3" ? "s3" : null),
    jobs: () => [], agents: async () => [{ pid: 51, session: null }],
    tell: (unit, text) => told.push([unit.session, text]),
    stopJob: async () => {}, signal: () => {}, self: 10,
  });
  try {
    await watch.look();
    // The shell (52), the command's first process, is killed; the look after it no longer sees it.
    table = table.filter((x) => x.pid !== 52);
    await watch.look();
    await watch.killed({ pid: 52, name: "sh" });
    assert.equal(told.length, 1);
    assert.equal(told[0]![0], "s3");
    assert.match(told[0]![1], /killed sh \(pid 52\)/);
    assert.deepEqual(asked.at(-1), [53], "its directory asked of the process still alive");
  } finally {
    await watch.close();
  }
});

test("each look puts what the agents run first for the kernel's OOM killer: their jobs' and commands' processes, never a runtime or the station", async () => {
  const first: number[][] = [];
  const watch = new MemoryWatch({
    pressure: async () => "normal",
    table: async () => [p(10, 1, 10, 0.5, "node"), p(20, 1, 20, 0, "stillfail-runner"), p(21, 20, 20, 0.5, "claude"), p(22, 21, 22, 0.1, "/bin/sh"), p(23, 22, 22, 2, "cargo"),
      p(30, 1, 30, 0.1, "sh"), p(31, 30, 30, 0.2, "server")],
    totalBytes: () => 16 * GiB, cwds: async () => new Map(), sessionAt: () => null,
    jobs: () => [{ id: "job_1", session: "s1", pgid: 30, label: "job" }], agents: async () => [{ pid: 21, session: "s2" }],
    tell: () => {}, stopJob: async () => {}, signal: () => {}, self: 10,
    killFirst: (pids) => first.push([...pids].sort((a, b) => a - b)),
  });
  try {
    await watch.look();
    assert.deepEqual(first, [[22, 23, 30, 31]]);
  } finally {
    await watch.close();
  }
});
