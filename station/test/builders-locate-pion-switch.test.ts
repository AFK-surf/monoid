import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, sep } from "node:path";
import { test } from "node:test";
import {
  MbProcess,
  mbReaderBinary,
  pionBinary,
  probePionSupportedModes,
  resetReaderSelectionStateForTest,
  resolveReaderSelection,
} from "../src/read/mb-reader.ts";
import { LiveLocator } from "../src/sessions/live-locator.ts";
import { Store } from "../src/store/store.ts";

function resolveDualBinaries(t: { skip: (msg: string) => void }): { mb: string; pion: string } | null {
  const realMb = mbReaderBinary();
  const explicitPion = process.env.STILLFAIL_PION_READER?.trim();
  const realPion = pionBinary();

  if (realMb === null) {
    if (process.env.CI) assert.fail("stillfail-reader binary is required in CI");
    t.skip("stillfail-reader not built here");
    return null;
  }
  if (explicitPion) {
    assert.ok(realPion !== null, `STILLFAIL_PION_READER is set (${explicitPion}) but resolved to null`);
  } else if (realPion === null) {
    t.skip("STILLFAIL_PION_READER / built stillfail-pion binary not present in this environment");
    return null;
  }
  assert.notEqual(realpathSync(realMb), realpathSync(realPion), "MB and Pion binaries must be distinct files");
  const ver = execFileSync(realPion, ["--version"], { encoding: "utf8" });
  assert.match(ver, /modes:[^\n]*live-locator/, `Pion --version must advertise live-locator: ${ver}`);
  return { mb: realMb, pion: realPion };
}

function makeFixture() {
  const dir = mkdtempSync(join(tmpdir(), "w6-locate-switch-"));
  const dbPath = join(dir, "stillfail.db");
  const store = Store.open(dbPath);
  const wsA = join(dir, "wsA");
  const wsB = join(dir, "wsB");
  mkdirSync(wsA, { recursive: true });
  mkdirSync(wsB, { recursive: true });
  const profHome = join(dir, "home");
  mkdirSync(join(profHome, "projects"), { recursive: true });

  // Session A: claude with transcript under shared transcripts/claude/<project>/<id>.jsonl
  store.insertSession({
    key: "ses-a",
    connect: "ember",
    runtime: "claude",
    profile: "p1",
    workspace: wsA,
    token: "tok-a",
    createdAt: 100,
    lastActiveAt: 100,
    ws: "mine",
  });
  store.setRuntimeSessionId("ses-a", "rt-a1");
  store.db.prepare("INSERT INTO runtime_sessions (session_key, id, runtime, profile, at) VALUES (?, ?, ?, ?, ?)").run("ses-a", "rt-a0", "claude", "p1", 50);
  store.db.prepare("INSERT INTO runtime_sessions (session_key, id, runtime, profile, at) VALUES (?, ?, ?, ?, ?)").run("ses-a", "rt-a1", "claude", "p1", 100);

  const projA = wsA.replace(/[^a-zA-Z0-9]/g, "-");
  const sharedClaudeA = join(dir, "transcripts", "claude", projA);
  mkdirSync(sharedClaudeA, { recursive: true });
  writeFileSync(join(sharedClaudeA, "rt-a0.jsonl"), "{\"type\":\"a0\"}\n");
  writeFileSync(join(sharedClaudeA, "rt-a1.jsonl"), "{\"type\":\"a1\"}\n");

  // Session B: agy with transcript under shared transcripts/agy/<id>.jsonl
  store.insertSession({
    key: "ses-b",
    connect: "ember",
    runtime: "agy",
    profile: "p1",
    workspace: wsB,
    token: "tok-b",
    createdAt: 200,
    lastActiveAt: 200,
    ws: "mine",
  });
  store.setRuntimeSessionId("ses-b", "rt-b1");
  const sharedAgy = join(dir, "transcripts", "agy");
  mkdirSync(sharedAgy, { recursive: true });
  writeFileSync(join(sharedAgy, "rt-b1.jsonl"), "{\"type\":\"b1\"}\n");

  return { dir, dbPath, store, profHome, wsA, wsB };
}

class MessageQueue {
  #items: any[] = [];
  #waiters: ((v: any) => void)[] = [];
  push(v: any) {
    const w = this.#waiters.shift();
    if (w) w(v);
    else this.#items.push(v);
  }
  next(): Promise<any> {
    if (this.#items.length > 0) return Promise.resolve(this.#items.shift());
    return new Promise((resolve) => this.#waiters.push(resolve));
  }
}

test("live-locator Pion protocol: interleaved A/B ACK, accepted:false retry, cancel A while B finishes, unknown cancel, error phase, snapshot isolation", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;
  const { mb, pion } = bins;
  const fx = makeFixture();
  const proc = new MbProcess(pion, ["--builder", "live-locator", "--db", fx.dbPath, "--data", fx.dir, "--sep", sep]);
  const q = new MessageQueue();
  proc.on("message", (m: any) => q.push(m));
  try {
    const profiles = [{ id: "p1", home: fx.profHome }];

    // 1. Interleaved A (id=1) and B (id=2): answer B before A, test accepted:false retry on A
    proc.postMessage({ type: "locate", id: 1, key: "ses-a", profiles });
    proc.postMessage({ type: "locate", id: 2, key: "ses-b", profiles });
    // Duplicate in-flight locate for id=1 must be ignored
    proc.postMessage({ type: "locate", id: 1, key: "ses-a", profiles });

    const h1 = await q.next();
    const h2 = await q.next();
    assert.equal(h1.type, "hints");
    assert.equal(h1.id, 1);
    assert.equal(h2.type, "hints");
    assert.equal(h2.id, 2);

    // Reply B first -> B gets batch, accepts, finishes done while A is still waiting on hints!
    proc.postMessage({ type: "hints", id: 2, hints: { elsewhere: [], rollouts: [], said: [] } });
    const bBatch = await q.next();
    assert.equal(bBatch.type, "batch");
    assert.equal(bBatch.id, 2);
    assert.equal(bBatch.current, true);
    assert.equal(bBatch.paths.length, 1);
    proc.postMessage({ type: "accepted", id: 2, accepted: true });
    const bDone = await q.next();
    assert.equal(bDone.type, "done");
    assert.equal(bDone.id, 2);
    assert.equal(bDone.runtime, "agy");
    assert.equal(bDone.current, true);
    assert.equal(typeof bDone.identity?.tokenHash, "string");
    assert.equal(bDone.identity.tokenHash.length, 64);

    // Reply A hints -> batch -> reject with accepted:false -> must re-ask hints for same batch!
    proc.postMessage({ type: "hints", id: 1, hints: { elsewhere: [], rollouts: [], said: [] } });
    const aBatch1 = await q.next();
    assert.equal(aBatch1.type, "batch");
    assert.equal(aBatch1.id, 1);
    assert.equal(aBatch1.paths.length, 2);
    proc.postMessage({ type: "accepted", id: 1, accepted: false });
    const aReask = await q.next();
    assert.equal(aReask.type, "hints");
    assert.equal(aReask.id, 1);
    assert.deepEqual(aReask.sources, h1.sources);

    // Now accept A
    proc.postMessage({ type: "hints", id: 1, hints: { elsewhere: [], rollouts: [], said: [] } });
    const aBatch2 = await q.next();
    assert.equal(aBatch2.type, "batch");
    assert.equal(aBatch2.id, 1);
    proc.postMessage({ type: "accepted", id: 1, accepted: true });
    const aDone = await q.next();
    assert.equal(aDone.type, "done");
    assert.equal(aDone.id, 1);
    assert.equal(aDone.current, true);

    // 2. Unknown id cancel -> cancelled
    proc.postMessage({ type: "cancel", id: 999 });
    const unkCancel = await q.next();
    assert.deepEqual(unkCancel, { type: "cancelled", id: 999 });

    // 3. Cancel A (id=10) while B (id=11) completes; also mutate DB after snapshot release
    proc.postMessage({ type: "locate", id: 10, key: "ses-a", profiles });
    proc.postMessage({ type: "locate", id: 11, key: "ses-b", profiles });
    const h10 = await q.next();
    const h11 = await q.next();
    assert.equal(h10.id, 10);
    assert.equal(h11.id, 11);

    // Mutate DB while snapshot is already released (must not block WAL writer!)
    fx.store.db.prepare("INSERT INTO runtime_sessions (session_key, id, runtime, profile, at) VALUES (?, ?, ?, ?, ?)").run("ses-b", "rt-b2", "agy", "p1", 300);

    proc.postMessage({ type: "cancel", id: 10 });
    const c10 = await q.next();
    assert.deepEqual(c10, { type: "cancelled", id: 10 });

    proc.postMessage({ type: "hints", id: 11, hints: { elsewhere: [], rollouts: [], said: [] } });
    const b11 = await q.next();
    assert.equal(b11.id, 11);
    assert.equal(b11.paths.length, 1); // snapshot isolated from rt-b2 inserted after snapshot
    proc.postMessage({ type: "accepted", id: 11, accepted: true });
    const d11 = await q.next();
    assert.equal(d11.type, "done");
    assert.equal(d11.id, 11);

    // 4. Wrong phase error removes only that id and returns exact error message
    proc.postMessage({ type: "locate", id: 20, key: "ses-b", profiles });
    await q.next(); // hints
    proc.postMessage({ type: "accepted", id: 20, accepted: true }); // wrong phase!
    const err20 = await q.next();
    assert.equal(err20.type, "error");
    assert.equal(err20.id, 20);
    assert.equal(err20.error, "expected transcript location hints");

    // 5. Parity vs MB on same DB state
    const runLocator = async (bin: string) => {
      const loc = new LiveLocator(fx.dir, (k) => fx.store.getSession(k), () => profiles, undefined, undefined, undefined);
      // Use direct MbProcess parity check
      await loc.close();
      const p = new MbProcess(bin, ["--builder", "live-locator", "--db", fx.dbPath, "--data", fx.dir, "--sep", sep]);
      const mq = new MessageQueue();
      p.on("message", (m: any) => mq.push(m));
      try {
        p.postMessage({ type: "locate", id: 1, key: "ses-a", profiles });
        const out: any[] = [];
        for (;;) {
          const msg = await mq.next();
          out.push(msg);
          if (msg.type === "hints") p.postMessage({ type: "hints", id: 1, hints: { elsewhere: [], rollouts: [], said: [] } });
          else if (msg.type === "batch") p.postMessage({ type: "accepted", id: 1, accepted: true });
          else break;
        }
        return out;
      } finally {
        await p.terminate();
      }
    };
    const [mbOut, pionOut] = await Promise.all([runLocator(mb), runLocator(pion)]);
    assert.deepEqual(pionOut, mbOut, "Pion live-locator wire output must match MB 0-diff");
  } finally {
    await proc.terminate();
    fx.store.close();
    rmSync(fx.dir, { recursive: true, force: true });
  }
});

test("production LiveLocator switches cleanly between MB and Pion via ReaderConfig and rejects shadow", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;
  const { mb, pion } = bins;
  resetReaderSelectionStateForTest();
  const fx = makeFixture();
  let modeCfg: "mb" | "pion" | "shadow" = "mb";
  const profiles = [{ id: "p1", home: fx.profHome }];
  const locator = new LiveLocator(
    fx.dir,
    (k) => fx.store.getSession(k),
    () => profiles,
    undefined,
    undefined,
    () => ({ readers: { "live-locator": modeCfg } }),
  );
  try {
    // Default / mb
    assert.equal(resolveReaderSelection("live-locator", { config: { readers: { "live-locator": "mb" } } }).primaryBinary, mb);
    const resMb = await locator.locate("ses-a");
    assert.ok(resMb !== null && resMb.paths.length === 2);
    assert.equal(locator.trimIdle(), 1);

    // Shadow forbidden -> falls back to mb
    const shadowSel = resolveReaderSelection("live-locator", { config: { readers: { "live-locator": "shadow" } } });
    assert.equal(shadowSel.engine, "mb");
    assert.equal(shadowSel.selection.reason, "shadow-forbidden");

    // Hot-reload to pion -> first lookup awaits probe and spawns real Pion binary
    modeCfg = "pion";
    const resPion = await locator.locate("ses-a");
    assert.deepEqual(resPion, resMb);
    const modes = await probePionSupportedModes(pion);
    assert.ok(modes?.has("live-locator"));
    assert.equal(resolveReaderSelection("live-locator", { config: { readers: { "live-locator": "pion" } } }).primaryBinary, pion);
  } finally {
    await locator.close();
    fx.store.close();
    rmSync(fx.dir, { recursive: true, force: true });
    resetReaderSelectionStateForTest();
  }
});
