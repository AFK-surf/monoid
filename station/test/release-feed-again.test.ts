import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { FEED_AGAIN_MS, type Applier, type Plan, readFeed, takeDelta } from "../src/updates/release.ts";

const FEED = { version: "0.1.9300" };

/// A feed whose reads answer as `said` says in turn: a status, or "broken" for a connection that failed on the way.
function served(said: (number | "broken")[]) {
  const asked: string[] = [];
  const request = async (url: string) => {
    asked.push(url);
    const now = said.shift() ?? 200;
    if (now === "broken") throw new TypeError("fetch failed");
    return new Response(now === 200 ? JSON.stringify(FEED) : "no", { status: now });
  };
  return { asked, request: request as unknown as typeof fetch };
}

function pauses() {
  const waited: number[] = [];
  return { waited, wait: async (ms: number) => void waited.push(ms) };
}

test("a feed read broken on the way, or by a gateway, is read again after each pause", async () => {
  const feed = served(["broken", 503, "broken"]);
  const p = pauses();
  assert.deepEqual(await readFeed("beta", "https://releases.test", 15_000, feed.request, p.wait), FEED);
  assert.deepEqual(p.waited, FEED_AGAIN_MS);
  assert.equal(feed.asked.length, 4);
  assert.equal(feed.asked[0], "https://releases.test/releases/station-beta.json");
});

test("a feed read broken every time fails as it was, after three more", async () => {
  const feed = served(["broken", 502, 504, "broken", 200]);
  const p = pauses();
  await assert.rejects(readFeed("beta", "https://releases.test", 15_000, feed.request, p.wait), /fetch failed/);
  assert.deepEqual(p.waited, FEED_AGAIN_MS);
  assert.equal(feed.asked.length, 4);
});

test("a refusal is not asked again", async () => {
  for (const status of [404, 403, 500]) {
    const feed = served([status]);
    const p = pauses();
    await assert.rejects(readFeed("stable", "https://releases.test", 15_000, feed.request, p.wait), new RegExp(`station.json: ${status}`));
    assert.deepEqual(p.waited, []);
    assert.equal(feed.asked.length, 1);
  }
});

test("without a way to wait, a broken read fails at once (the station's own reads)", async () => {
  const feed = served(["broken"]);
  await assert.rejects(readFeed("beta", "https://releases.test", 15_000, feed.request), /fetch failed/);
  assert.equal(feed.asked.length, 1);
});

// A delta's download (takeDelta), tried again as the feed's read is.

const sha = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");
const DELTA = Buffer.from("the delta's bytes, ".repeat(400));
const RAW = Buffer.from("the release's raw archive");
const URL_OF = "https://releases.test/releases/station/archive/beta/1310-x.from-1300-y.delta";

/// How the delta is answered, in turn: a status, "broken" for a connection that failed before an answer, "cut" for a
/// body broken off half way (undici's TypeError "terminated"), "short" for one that ended short with no length said,
/// "long" for one longer than the feed says, "other" for bytes of the feed's size not hashing to its sha256.
type Said = 200 | number | "broken" | "cut" | "short" | "long" | "other";

function deltaServed(said: Said[]) {
  const asked: string[] = [];
  const request = async (url: string) => {
    asked.push(url);
    const now = said.shift() ?? 200;
    if (now === "broken") throw new TypeError("fetch failed");
    if (now === "cut") {
      return new Response(new ReadableStream({ start(c) { c.enqueue(DELTA.subarray(0, DELTA.length >> 1)); c.error(new TypeError("terminated")); } }), { status: 200 });
    }
    if (now === "short") return new Response(DELTA.subarray(0, DELTA.length - 10), { status: 200 });
    if (now === "long") return new Response(Buffer.concat([DELTA, Buffer.from("more")]), { status: 200 });
    if (now === "other") return new Response(Buffer.from(DELTA).fill(0x41, 0, 1), { status: 200 });
    if (now !== 200) return new Response("no", { status: now });
    return new Response(DELTA, { status: 200, headers: { "content-length": String(DELTA.length) } });
  };
  return { asked, request: request as unknown as typeof fetch };
}

/// A plan whose delta is DELTA, making RAW; temporary files in a directory of the test's own.
function deltaPlan(t: { after: (f: () => unknown) => void }) {
  const tmp = mkdtempSync(join(tmpdir(), "delta-again-"));
  const before = { TMPDIR: process.env.TMPDIR, TEMP: process.env.TEMP, TMP: process.env.TMP };
  Object.assign(process.env, { TMPDIR: tmp, TEMP: tmp, TMP: tmp });
  t.after(() => {
    for (const [k, v] of Object.entries(before)) v === undefined ? delete process.env[k] : (process.env[k] = v);
    rmSync(tmp, { recursive: true, force: true });
  });
  const plan = {
    delta: { from: 1300, url: URL_OF, sha256: sha(DELTA), size: DELTA.length, rawSha256: sha(RAW), rawSize: RAW.length },
  } as unknown as Plan;
  const applied: Buffer[] = [];
  const apply: Applier = async (_app, delta, out) => {
    applied.push(readFileSync(delta));
    writeFileSync(out, RAW);
  };
  return { tmp, plan, applied, apply };
}

test("a delta's download broken on the way, by a gateway or half way through is downloaded again after each pause", async (t) => {
  const c = deltaPlan(t);
  const served = deltaServed(["broken", 503, "cut"]);
  const p = pauses();
  const handed = await takeDelta(c.plan, { app: "/app", apply: c.apply, signal: new AbortController().signal, request: served.request, wait: p.wait });
  assert.equal(handed.STILLFAIL_RELEASE_SHA256, sha(RAW));
  assert.ok(handed.STILLFAIL_ARCHIVE && readFileSync(handed.STILLFAIL_ARCHIVE).equals(RAW));
  assert.deepEqual(p.waited, FEED_AGAIN_MS);
  assert.deepEqual(served.asked, [URL_OF, URL_OF, URL_OF, URL_OF]);
  // Applied once, to the whole delta: nothing of a broken try left in it.
  assert.equal(c.applied.length, 1);
  assert.ok(c.applied[0]!.equals(DELTA));
});

test("a delta that ended short of its size is downloaded again", async (t) => {
  const c = deltaPlan(t);
  const served = deltaServed(["short"]);
  const p = pauses();
  const handed = await takeDelta(c.plan, { app: "/app", apply: c.apply, signal: new AbortController().signal, request: served.request, wait: p.wait });
  assert.equal(handed.STILLFAIL_RELEASE_SHA256, sha(RAW));
  assert.deepEqual(p.waited, [FEED_AGAIN_MS[0]]);
  assert.equal(served.asked.length, 2);
  assert.ok(c.applied[0]!.equals(DELTA));
});

test("a delta refused, longer than the feed says or not hashing to its sha256 is not downloaded again", async (t) => {
  for (const said of [404, 403, 500, "long", "other"] as const) {
    await t.test(String(said), async (t) => {
      const c = deltaPlan(t);
      const served = deltaServed([said]);
      const p = pauses();
      assert.deepEqual(await takeDelta(c.plan, { app: "/app", apply: c.apply, signal: new AbortController().signal, request: served.request, wait: p.wait }), {});
      assert.deepEqual(p.waited, []);
      assert.equal(served.asked.length, 1);
      assert.equal(c.applied.length, 0);
      assert.deepEqual(readdirSync(c.tmp), [], "nothing left of it");
    });
  }
});

test("a delta of another length than the feed says is not downloaded again", async (t) => {
  const c = deltaPlan(t);
  (c.plan.delta as { size: number }).size = DELTA.length + 1;
  const served = deltaServed([200]);
  const p = pauses();
  assert.deepEqual(await takeDelta(c.plan, { app: "/app", apply: c.apply, signal: new AbortController().signal, request: served.request, wait: p.wait }), {});
  assert.deepEqual(p.waited, []);
  assert.equal(served.asked.length, 1);
});

test("a delta's download broken every time leaves nothing, and the installer downloads the whole release", async (t) => {
  const c = deltaPlan(t);
  const served = deltaServed(["broken", "cut", 502, 504, 200]);
  const p = pauses();
  assert.deepEqual(await takeDelta(c.plan, { app: "/app", apply: c.apply, signal: new AbortController().signal, request: served.request, wait: p.wait }), {});
  assert.deepEqual(p.waited, FEED_AGAIN_MS);
  assert.equal(served.asked.length, 4);
  assert.equal(c.applied.length, 0);
  assert.deepEqual(readdirSync(c.tmp), [], "nothing left of it");
});

test("a delta's download is not tried again past the caller's deadline, nor without a way to wait", async (t) => {
  const c = deltaPlan(t);
  const over = new AbortController();
  over.abort(new DOMException("timed out", "TimeoutError"));
  const late = deltaServed(["broken"]);
  const p = pauses();
  assert.deepEqual(await takeDelta(c.plan, { app: "/app", apply: c.apply, signal: over.signal, request: late.request, wait: p.wait }), {});
  assert.equal(late.asked.length, 1);
  assert.deepEqual(p.waited, []);
  const once = deltaServed(["broken"]);
  assert.deepEqual(await takeDelta(c.plan, { app: "/app", apply: c.apply, signal: new AbortController().signal, request: once.request }), {});
  assert.equal(once.asked.length, 1);
  assert.deepEqual(readdirSync(c.tmp), []);
});
