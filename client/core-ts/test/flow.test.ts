// How fast a file comes to this device (flow.ts): what came over the window, per second, as it comes.
import assert from "node:assert/strict";
import { test } from "node:test";
import { FLOW_MIN_MS, FLOW_WINDOW_MS, Flow } from "../src/flow.ts";

test("how fast a file comes: what came over the window, per second; none said before it has come a while, nor after a gap as long as the window", () => {
  const f = new Flow();
  assert.equal(f.perSecond(0), 0, "nothing came");
  f.came(0, 1000);
  assert.equal(f.perSecond(FLOW_MIN_MS - 1), 0, "a first piece's burst is no speed");
  for (let at = 250; at <= 2000; at += 250) f.came(at, 1000);
  // nine lots of 1000 bytes in 2 s
  assert.equal(f.perSecond(2000), 4500);
  // what came before the window no longer counts
  for (let at = 2250; at <= 8000; at += 250) f.came(at, 500);
  assert.equal(f.perSecond(8000), ((FLOW_WINDOW_MS / 250) * 500 * 1000) / FLOW_WINDOW_MS);
  // nothing for as long as the window: none, and it is counted anew from what comes next
  assert.equal(f.perSecond(8000 + FLOW_WINDOW_MS), 0);
  f.came(20_000, 1000);
  assert.equal(f.perSecond(20_000 + FLOW_MIN_MS - 1), 0);
  // nothing that came is not counted
  f.came(20_100, 0);
  f.came(20_200, -5);
  assert.equal(f.perSecond(20_000 + FLOW_MIN_MS), 1000);
});
