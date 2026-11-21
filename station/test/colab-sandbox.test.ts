// The Colab sandboxes' pool (assets/agents/colab-sandbox.mjs): which VM a task gets, which account starts a new one,
// waiting when none can, and stopping idle ones. Colab itself is a stand-in here (its CLI's answers, as measured
// 2026-11-21: READY, a 412 past an account's 3 of a GPU, a 503 when Google has none); the clock is the test's.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test } from "node:test";
// @ts-expect-error: a plain .mjs of the station's assets
import { KEEP_WARM_MS, PER_ACCOUNT, REFUSED_MS, acquire, reap, release } from "../assets/agents/colab-sandbox.mjs";

type Call = { account: string; vm: string | null; args: string[] };

/// A stand-in Colab: each account holds VMs up to its limit (`limits`, else PER_ACCOUNT); `unavailable`: Google has
/// none of a GPU free. The clock moves only as the pool sleeps (or the test says).
function fakeColab(o: { limits?: Record<string, number>; unavailable?: string[] } = {}) {
  let clock = 1_000_000;
  const held = new Map<string, { account: string; gpu: string }>();
  const calls: Call[] = [];
  const io = {
    now: () => clock,
    sleep: (ms: number) => { clock += ms; },
    alive: (pid: number) => pid === process.pid,
    colab: (account: string, vm: string | null, args: string[]) => {
      calls.push({ account, vm, args });
      if (args[0] === "new") {
        const gpu = args[args.indexOf("--gpu") + 1]!;
        if (o.unavailable?.includes(gpu)) return { code: 1, out: "503 Server Error: Service Unavailable" };
        const mine = [...held.values()].filter((h) => h.account === account && h.gpu === gpu).length;
        if (mine >= (o.limits?.[account] ?? PER_ACCOUNT)) return { code: 1, out: "[colab] Allocation refused (precondition failed)." };
        held.set(vm!, { account, gpu });
        return { code: 0, out: `[colab] Creating session '${vm}'...\n[colab] Session READY.\n` };
      }
      if (args[0] === "stop") {
        held.delete(vm!);
        return { code: 0, out: "[colab] Session terminated.\n" };
      }
      if (args[0] === "sessions") return { code: 0, out: "[colab] No active sessions found on server.\n" };
      return { code: 1, out: "unknown" };
    },
  };
  return { io, held, calls, advance: (ms: number) => { clock += ms; } };
}

let pool = "";
const accounts = (...names: string[]) => { for (const n of names) mkdirSync(join(pool, "accounts", n, "home"), { recursive: true }); };
const state = () => JSON.parse(readFileSync(join(pool, "state.json"), "utf8"));

describe("Colab sandboxes' pool", () => {
  beforeEach(() => { pool = mkdtempSync(join(tmpdir(), "colab-pool-")); });
  afterEach(() => rmSync(pool, { recursive: true, force: true }));

  test("no account signed in: the task fails saying how to sign one in", () => {
    const { io } = fakeColab();
    assert.throws(() => acquire(pool, "G4", "s1", io), /no Colab account is signed in.*station_list says how/);
  });

  test("a chat's next task gets the VM its last one left; another chat's task a VM of its own while that one is held", () => {
    accounts("a");
    const { io, calls } = fakeColab();
    const first = acquire(pool, "G4", "s1", io);
    assert.equal(first.account, "a");
    release(pool, first.vm, io);
    const again = acquire(pool, "G4", "s1", io);
    assert.equal(again.vm, first.vm);
    const other = acquire(pool, "G4", "s2", io);
    assert.notEqual(other.vm, first.vm);
    assert.equal(calls.filter((c) => c.args[0] === "new").length, 2);
  });

  test("a new VM goes to the account holding fewest; one at its limit (412) is passed over for REFUSED_MS", () => {
    accounts("a", "b");
    const { io, held } = fakeColab({ limits: { a: 1 } });
    const vms = [acquire(pool, "G4", "s1", io), acquire(pool, "G4", "s2", io), acquire(pool, "G4", "s3", io)];
    // a, b, then a again (fewest held): refused there, so b.
    assert.deepEqual(vms.map((v) => v.account), ["a", "b", "b"]);
    assert.deepEqual([...held.values()].map((h) => h.account).sort(), ["a", "b", "b"]);
    assert.ok(state().refused["a:G4"] > 0);
  });

  test("every account full: the task waits, and fails after its wait saying what to do", () => {
    accounts("a");
    const { io } = fakeColab({ limits: { a: 1 } });
    acquire(pool, "G4", "s1", io);
    assert.throws(() => acquire(pool, "G4", "s2", io, 10 * 60_000), /no G4 VM came free in 10 minutes.*sign in another account/);
    // Its place in line is given up.
    assert.deepEqual(state().queue, []);
  });

  test("Google has none of a GPU (503): the account is tried again after REFUSED_MS, not at once", () => {
    accounts("a");
    const { io, calls } = fakeColab({ unavailable: ["H100"] });
    assert.throws(() => acquire(pool, "H100", "s1", io, REFUSED_MS * 3), /no H100 VM came free/);
    const tries = calls.filter((c) => c.args[0] === "new").length;
    assert.ok(tries >= 3 && tries <= 4, `tried ${tries} times`);
  });

  test("a VM no task holds is stopped KEEP_WARM_MS after its last task; one held is not", () => {
    accounts("a");
    const fake = fakeColab();
    const held = acquire(pool, "G4", "s1", fake.io);
    const free = acquire(pool, "G4", "s2", fake.io);
    release(pool, free.vm, fake.io);
    fake.advance(KEEP_WARM_MS - 1);
    assert.deepEqual(reap(pool, fake.io), []);
    fake.advance(2);
    assert.deepEqual(reap(pool, fake.io), [free.vm]);
    assert.deepEqual([...fake.held.keys()], [held.vm]);
    assert.deepEqual(Object.keys(state().vms), [held.vm]);
  });
});
