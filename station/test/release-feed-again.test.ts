import assert from "node:assert/strict";
import { test } from "node:test";
import { FEED_AGAIN_MS, readFeed } from "../src/updates/release.ts";

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
