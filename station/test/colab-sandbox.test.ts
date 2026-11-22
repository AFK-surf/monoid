// The Colab sandboxes' pool (assets/agents/colab-sandbox.mjs): PlaintextKeyring sync from native Profiles
// (`homes/<id>/colab-auth.json`), which VM a task gets, which account starts a new one, waiting when none can,
// and stopping idle ones. Colab itself is a stand-in here (its CLI's answers: READY, 412 past 3 VMs/GPU, 503 when
// Google has none); the clock is the test's.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, test } from "node:test";
// @ts-expect-error: a plain .mjs of the station's assets
import { KEEP_WARM_MS, PER_ACCOUNT, REFUSED_MS, acquire, cliHomeOf, reap, release, syncKeyring } from "../assets/agents/colab-sandbox.mjs";

type Account = { id: string; authFile: string };
type Call = { account: string; vm: string | null; args: string[] };

/// A stand-in Colab: each account holds VMs up to its limit (`limits`, else PER_ACCOUNT); `unavailable`: Google has
/// none of a GPU free. The clock moves only as the pool sleeps (or the test says).
function fakeColab(o: { limits?: Record<string, number>; unavailable?: string[]; serverEndpoints?: Record<string, string[]> } = {}) {
  let clock = 1_000_000;
  const held = new Map<string, { account: string; gpu: string }>();
  const calls: Call[] = [];
  const io = {
    now: () => clock,
    sleep: (ms: number) => { clock += ms; },
    alive: (pid: number) => pid === process.pid,
    colab: (account: Account, vm: string | null, args: string[]) => {
      calls.push({ account: account.id, vm, args });
      if (args[0] === "new") {
        const gpu = args[args.indexOf("--gpu") + 1]!;
        if (o.unavailable?.includes(gpu)) return { code: 1, out: "503 Server Error: Service Unavailable" };
        const mine = [...held.values()].filter((h) => h.account === account.id && h.gpu === gpu).length;
        if (mine >= (o.limits?.[account.id] ?? PER_ACCOUNT)) return { code: 1, out: "[colab] Allocation refused (precondition failed)." };
        held.set(vm!, { account: account.id, gpu });
        return { code: 0, out: `[colab] Creating session '${vm}'...\n[colab] Session READY.\n` };
      }
      if (args[0] === "stop") {
        held.delete(vm!);
        return { code: 0, out: "[colab] Session terminated.\n" };
      }
      if (args[0] === "sessions") {
        const eps = o.serverEndpoints?.[account.id] ?? [];
        if (eps.length === 0) return { code: 0, out: "[colab] No active sessions found on server.\n" };
        return { code: 0, out: eps.map((ep, i) => `[${i}] ${ep} | READY`).join("\n") + "\n" };
      }
      return { code: 1, out: "unknown" };
    },
  };
  return { io, held, calls, advance: (ms: number) => { clock += ms; } };
}

let pool = "";
let homesDir = "";

function makeAccounts(...ids: string[]): Account[] {
  return ids.map((id) => {
    const dir = join(homesDir, id);
    mkdirSync(dir, { recursive: true });
    const authFile = join(dir, "colab-auth.json");
    writeFileSync(authFile, JSON.stringify({ token: `tok-${id}`, refresh_token: `ref-${id}` }));
    return { id, authFile };
  });
}

const state = () => JSON.parse(readFileSync(join(pool, "state.json"), "utf8"));

describe("Colab sandboxes' pool", () => {
  beforeEach(() => {
    pool = mkdtempSync(join(tmpdir(), "colab-pool-"));
    homesDir = mkdtempSync(join(tmpdir(), "colab-homes-"));
  });
  afterEach(() => {
    rmSync(pool, { recursive: true, force: true });
    rmSync(homesDir, { recursive: true, force: true });
  });

  test("syncKeyring seeds PlaintextKeyring from homes/<id>/colab-auth.json, skips when unchanged, and re-syncs on mtime or size change", () => {
    const [acct] = makeAccounts("p1");
    const runs: { cmd: string; args: string[]; home: string; backend: string }[] = [];
    const fakeRun = (cmd: string, args: string[], opts: { env: Record<string, string> }) => {
      runs.push({ cmd, args, home: opts.env.HOME ?? "", backend: opts.env.PYTHON_KEYRING_BACKEND ?? "" });
      return { status: 0, stdout: "", stderr: "" };
    };
    assert.equal(syncKeyring(pool, acct, { python: "/fake/python", run: fakeRun }), true);
    assert.equal(runs.length, 1);
    assert.equal(runs[0]!.cmd, "/fake/python");
    assert.equal(runs[0]!.args[2], acct.authFile);
    assert.equal(runs[0]!.home, cliHomeOf(pool, "p1"));
    assert.equal(runs[0]!.backend, "keyrings.alt.file.PlaintextKeyring");

    // Unchanged mtimeMs and size: no re-seed.
    assert.equal(syncKeyring(pool, acct, { python: "/fake/python", run: fakeRun }), false);
    assert.equal(runs.length, 1);

    // Size changes: re-seeds.
    writeFileSync(acct.authFile, JSON.stringify({ token: "tok-p1-longer", refresh_token: "ref-p1" }));
    assert.equal(syncKeyring(pool, acct, { python: "/fake/python", run: fakeRun }), true);
    assert.equal(runs.length, 2);

    // Same size, mtime changes: re-seeds.
    const future = new Date(Date.now() + 60_000);
    utimesSync(acct.authFile, future, future);
    assert.equal(syncKeyring(pool, acct, { python: "/fake/python", run: fakeRun }), true);
    assert.equal(runs.length, 3);
  });

  test("no account available: the task fails telling the user to add one in Settings → Profiles → Google Colab", () => {
    const { io } = fakeColab();
    assert.throws(() => acquire(pool, "G4", "s1", [], io), /Settings → Profiles.*Google Colab/);
  });

  test("a chat's next task gets the VM its last one left; another chat's task gets a VM of its own while that one is held", () => {
    const accts = makeAccounts("a");
    const { io, calls } = fakeColab();
    const first = acquire(pool, "G4", "s1", accts, io);
    assert.equal(first.account, "a");
    release(pool, first.vm, io);
    const again = acquire(pool, "G4", "s1", accts, io);
    assert.equal(again.vm, first.vm);
    const other = acquire(pool, "G4", "s2", accts, io);
    assert.notEqual(other.vm, first.vm);
    assert.equal(calls.filter((c) => c.args[0] === "new").length, 2);
  });

  test("a new VM goes to the account holding fewest; one at its limit (412) is passed over for REFUSED_MS", () => {
    const accts = makeAccounts("b", "a"); // unsorted input is sorted by id
    const { io, held } = fakeColab({ limits: { a: 1 } });
    const vms = [
      acquire(pool, "G4", "s1", accts, io),
      acquire(pool, "G4", "s2", accts, io),
      acquire(pool, "G4", "s3", accts, io),
    ];
    // a, b, then a again (fewest held): refused there (412), so b.
    assert.deepEqual(vms.map((v) => v.account), ["a", "b", "b"]);
    assert.deepEqual([...held.values()].map((h) => h.account).sort(), ["a", "b", "b"]);
    assert.ok(state().refused["a:G4"] > 0);
  });

  test("per-account 3 VM/GPU cap: 4th concurrent task waits and fails after waitMs, releasing its queue slot", () => {
    const accts = makeAccounts("a");
    const { io } = fakeColab();
    for (let i = 0; i < PER_ACCOUNT; i++) acquire(pool, "G4", `s${i}`, accts, io);
    assert.throws(() => acquire(pool, "G4", "s-wait", accts, io, 10 * 60_000), /no G4 VM came free in 10 minutes/);
    assert.deepEqual(state().queue, []);
  });

  test("Google has none of a GPU (503): the account is tried again after REFUSED_MS, not at once", () => {
    const accts = makeAccounts("a");
    const { io, calls } = fakeColab({ unavailable: ["H100"] });
    assert.throws(() => acquire(pool, "H100", "s1", accts, io, REFUSED_MS * 3), /no H100 VM came free/);
    const tries = calls.filter((c) => c.args[0] === "new").length;
    assert.ok(tries >= 3 && tries <= 4, `tried ${tries} times`);
  });

  test("a VM no task holds is stopped KEEP_WARM_MS after its last task; one held is not; gone VMs are forgotten", () => {
    const accts = makeAccounts("a");
    const fake = fakeColab({ serverEndpoints: { a: [] } });
    const held = acquire(pool, "G4", "s1", accts, fake.io);
    const free = acquire(pool, "G4", "s2", accts, fake.io);
    release(pool, free.vm, fake.io);
    // Write a vm record for another idle VM whose endpoint is gone from Colab server.
    const gone = acquire(pool, "L4", "s3", accts, fake.io);
    mkdirSync(join(pool, "vms"), { recursive: true });
    writeFileSync(join(pool, "vms", `${gone.vm}.json`), JSON.stringify({ [gone.vm]: { endpoint: "m-gone" } }));
    release(pool, gone.vm, fake.io);

    fake.advance(KEEP_WARM_MS - 1);
    assert.deepEqual(reap(pool, accts, fake.io), []);
    // `gone` was not idle past KEEP_WARM_MS yet, but server `sessions` didn't list `m-gone`, so it was forgotten.
    assert.equal(state().vms[gone.vm], undefined);

    fake.advance(2);
    assert.deepEqual(reap(pool, accts, fake.io), [free.vm]);
    assert.deepEqual([...fake.held.keys()].sort(), [gone.vm, held.vm].sort());
    assert.deepEqual(Object.keys(state().vms), [held.vm]);
  });
});
