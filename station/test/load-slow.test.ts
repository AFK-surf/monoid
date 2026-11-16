// How busy a station is, said within a moment however slow its machine's commands are (api/host.ts `sample`, jobs/
// load.ts `measure`): GPU commands of 1.5 s and a fresh look at the machine of over a second, on a busy machine, made
// station_list say `not measured within 1 s` (jobs/remote.ts LOAD_WAIT_MS). On the test's timers: each one armed is
// fired by the test, none by the machine's clock.
import assert from "node:assert/strict";
import { mock, test } from "node:test";
import { GPU_SAMPLE_MS, Host, INFO_WAIT_MS, STALE_MS, type hostInfo } from "../src/api/host.ts";
import { Gpus, type Run } from "../src/jobs/gpu.ts";
import { measure, summary } from "../src/jobs/load.ts";
import { wall } from "../src/ops/fibers.ts";

/// What station_list waits for a station's load (jobs/remote.ts LOAD_WAIT_MS, not imported: it brings the station).
const LOAD_WAIT_MS = 1000;

type Timer = { ms: number; f: () => void; live: boolean };

/// The wall's clock and timers, the test's: `fire(ms)` fires the timers of `ms` armed and not called off.
function testWall() {
  let clock = 1_000_000;
  const timers: Timer[] = [];
  const now = mock.method(wall, "now", () => clock);
  const after = mock.method(wall, "after", (ms: number, f: () => void) => {
    const t: Timer = { ms, f, live: true };
    timers.push(t);
    return () => { t.live = false; };
  });
  return {
    timers,
    armed: (ms: number) => timers.filter((t) => t.live && t.ms === ms).length,
    fire: (ms: number) => { for (const t of timers.filter((t) => t.live && t.ms === ms)) { t.live = false; t.f(); } },
    pass: (ms: number) => { clock += ms; },
    restore: () => { now.mock.restore(); after.mock.restore(); },
  };
}

/// Turns of the loop for what was set going to go as far as it can.
const settle = async () => { for (let i = 0; i < 5; i++) await new Promise<void>((resolve) => setImmediate(resolve)); };

/// A look at the machine, said at once or when the test lets it (`hold`).
function machine(w: ReturnType<typeof testWall>) {
  let looks = 0;
  let held: { resolve: () => void } | null = null;
  const read: typeof hostInfo = async () => {
    const look = ++looks;
    if (held !== null) await new Promise<void>((resolve) => { held!.resolve = resolve; });
    return {
      info: { hostname: "h", os: "macOS", arch: "arm64", cpus: 8, cpuModel: "Apple M2", cpuBusy: 0.5, loadAvg: [1, 2, 3], look,
        memory: { totalBytes: 16 * 1024 ** 3, usedBytes: 4 * 1024 ** 3 }, disk: { path: "/d", totalBytes: 100 * 1024 ** 3, freeBytes: 50 * 1024 ** 3 }, checkedAt: wall.now() },
      seen: null, needsTicks: false,
    };
  };
  return {
    read,
    looks: () => looks,
    hold: () => { held = { resolve: () => {} }; },
    let: () => { const h = held; held = null; h?.resolve(); },
  };
}

test("a slow GPU command holds up neither the sample nor the load: the GPUs said last stand in, asked once a measure", async () => {
  const w = testWall();
  try {
    let ioreg: (() => void) | null = null;
    let asked = 0;
    const run: Run = async (file) => {
      if (file !== "ioreg") return undefined;
      asked++;
      // 1.5 s each, as GPU_WAIT_MS lets it (jobs/gpu.ts): answered when the test says
      await new Promise<void>((resolve) => (ioreg = resolve));
      return '"model" = "Apple M2"\n"gpu-core-count" = 10\n"Device Utilization %"=12';
    };
    const gpus = new Gpus({ run, os: "macos", arch: "arm64", now: () => wall.now() });
    const m = machine(w);
    const host = new Host("/d", gpus, m.read);
    const parts = { host, gpus, running: () => ({ remoteTasks: 0, jobs: 1, services: 0, turns: 2 }), relay: () => null };
    assert.ok(GPU_SAMPLE_MS < LOAD_WAIT_MS && INFO_WAIT_MS < LOAD_WAIT_MS);

    // The first: no GPU said yet, so none, at GPU_SAMPLE_MS; the rest of the machine as it is.
    const first = measure(parts);
    await settle();
    assert.equal(w.armed(GPU_SAMPLE_MS), 1);
    w.fire(GPU_SAMPLE_MS);
    const load = await first;
    assert.equal(load.gpus, null);
    assert.equal(load.cpus, 8);
    assert.equal(load.memory.availableBytes, 12 * 1024 ** 3);
    assert.equal(asked, 1, "the GPUs asked once, not again beside the sample");
    assert.ok(!summary(load).includes("unknown"), summary(load));

    // Its answer comes later, kept: the next measure says it.
    ioreg!();
    await settle();
    w.pass(11_000);
    const second = measure(parts);
    await settle();
    const again = await second;
    assert.deepEqual(again.gpus, [{ name: "Apple M2", cores: 10, busy: 0.12 }]);

    // The GPU command slow again past its ten seconds: what it said last, at once (read gives it while it asks).
    w.pass(11_000);
    const third = await measure(parts);
    assert.deepEqual(third.gpus, [{ name: "Apple M2", cores: 10, busy: 0.12 }]);
    assert.equal(asked, 2);
  } finally { w.restore(); }
});

test("a GPU reader that knows nothing yet and never answers: the GPUs said last, as cached() says them", async () => {
  const w = testWall();
  try {
    const m = machine(w);
    let reads = 0;
    const host = new Host("/d", { read: () => { reads++; return new Promise<never>(() => {}); }, cached: () => [{ name: "Known GPU" }] }, m.read);
    const sampled = host.sample("en");
    await settle();
    w.fire(GPU_SAMPLE_MS);
    const sample = await sampled;
    assert.deepEqual(sample.gpus, [{ name: "Known GPU" }]);
    assert.equal(sample.cpus, 8);
    assert.equal(reads, 1);
  } finally { w.restore(); }
});

test("a fresh look at a busy machine taking over a second: the one under a minute old meanwhile, the fresh one kept as it comes", async () => {
  const w = testWall();
  try {
    const m = machine(w);
    const host = new Host("/d", { read: async () => null }, m.read);
    // The first look is waited for, however long.
    m.hold();
    const cold = host.sample("en");
    await settle();
    assert.equal(w.armed(INFO_WAIT_MS), 0, "nothing to stand in for the first");
    m.let();
    assert.equal((await cold).look, 1);

    // 15 s on (past the ten seconds kept): a fresh look is slow, the last given at INFO_WAIT_MS.
    w.pass(15_000);
    m.hold();
    const busy = host.sample("en");
    await settle();
    assert.equal(w.armed(INFO_WAIT_MS), 1);
    w.fire(INFO_WAIT_MS);
    const stale = await busy;
    assert.equal(stale.look, 1);
    assert.equal(stale.cpus, 8);
    // Its load said in full, not `unknown`.
    const parts = { host, gpus: { read: async () => null }, running: () => ({ remoteTasks: 0, jobs: 0, services: 0, turns: 0 }), relay: () => null };
    // (another sample while the look is still slow: the last again, the same look under way)
    const measuring = measure(parts);
    await settle();
    w.fire(INFO_WAIT_MS);
    const load = await measuring;
    assert.equal(load.cpus, 8);
    assert.equal(m.looks(), 2, "one fresh look at a time");
    // The fresh look comes: kept, and given from then on.
    m.let();
    await settle();
    assert.equal((await host.sample("en")).look, 2);

    // Past STALE_MS with nothing newer: the fresh look is waited for again.
    w.pass(STALE_MS + 1);
    m.hold();
    const late = host.sample("en");
    await settle();
    assert.equal(w.armed(INFO_WAIT_MS), 0);
    m.let();
    assert.equal((await late).look, 3);
  } finally { w.restore(); }
});
