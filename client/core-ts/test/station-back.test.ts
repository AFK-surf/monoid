// What a station's link says of the app coming back (station/back.ts): whether its stream had to be opened again, and
// how long until the first event of the station's log.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect } from "effect";
import { BACK_AWAY_MS, BACK_WATCH_MS } from "../src/station/back.ts";
import { parseJson } from "../src/util.ts";
import { STREAM_AWAY_MS, Wake } from "../src/wake.ts";
import { EXPORT_MS } from "../src/trace.ts";
import { started } from "./station-fixture.ts";

type Attr = { key: string; value: { stringValue?: string; intValue?: string; boolValue?: boolean } };
type Exported = { name: string; attributes: Attr[] };

async function fixture() {
  const s = await started(undefined, 1, undefined, (f) => {
    f.gate.marks = true;
    f.gate.resumes = true;
  });
  const bodies: unknown[] = [];
  s.core.inner.tracer.setExport((b) => Effect.sync(() => void bodies.push(parseJson(b))));
  await s.host.time.pass(1_000, 50);
  const backs = async () => {
    await s.host.time.pass(EXPORT_MS + 20, 100);
    const spans = bodies.flatMap((b) => (b as { resourceSpans: { scopeSpans: { spans: Exported[] }[] }[] }).resourceSpans.flatMap((r) => r.scopeSpans.flatMap((x) => x.spans)));
    return spans.filter((x) => x.name === "station.back").map((x) => {
      const out: Record<string, string | number | boolean> = {};
      for (const a of x.attributes) if (a.key.startsWith("stillfail.back.")) out[a.key.slice("stillfail.back.".length)] = a.value.stringValue ?? a.value.boolValue ?? Number(a.value.intValue);
      return out;
    });
  };
  const wake = (away: number) => s.core.inner.wakes.wake(new Wake(s.host.nowMs(), away, false, false));
  return { s, wake, backs };
}

test("a_stream_that_held_while_the_app_was_away_says_when_its_first_event_came", async () => {
  const { s, wake, backs } = await fixture();
  try {
    wake(10_000);
    await s.host.time.pass(400, 50);
    s.push("overview", {}, "abcdef.50");
    await s.host.time.pass(100, 50);
    const [back] = await backs();
    assert.equal(back!.stream_open, true);
    assert.equal(back!.away_ms, 10_000);
    assert.equal(back!.end, "event");
    assert.equal(back!.opened_ms, undefined);
    assert.ok((back!.event_ms as number) >= 400 && (back!.event_ms as number) < 600, `${back!.event_ms}`);
  } finally {
    s.core.close();
  }
});

test("a_stream_gone_while_the_app_was_away_says_it_was_opened_again_and_went_on", async () => {
  const { s, wake, backs } = await fixture();
  try {
    s.push("overview", {}, "abcdef.40");
    // (nothing heard for as long as a stream is taken for gone at a return: STREAM_AWAY_MS)
    await s.host.time.pass(STREAM_AWAY_MS + 1_000, 500);
    const n = s.streams.length;
    wake(40_000);
    await s.host.time.pass(500, 50);
    assert.equal(s.streams.length, n + 1);
    s.push("overview", {}, "abcdef.41");
    await s.host.time.pass(100, 50);
    const [back] = await backs();
    assert.equal(back!.resumed, true);
    assert.equal(back!.end, "event");
    assert.ok((back!.opened_ms as number) <= (back!.event_ms as number));
  } finally {
    s.core.close();
  }
});

test("a_return_with_no_event_ends_quiet_and_a_short_one_is_not_followed", async () => {
  const { s, wake, backs } = await fixture();
  try {
    wake(BACK_AWAY_MS - 1);
    await s.host.time.pass(100, 50);
    assert.deepEqual(await backs(), []);
    wake(BACK_AWAY_MS);
    await s.host.time.pass(BACK_WATCH_MS + 100, 100);
    const all = await backs();
    assert.equal(all.length, 1);
    assert.equal(all[0]!.end, "quiet");
    assert.equal(all[0]!.event_ms, undefined);
  } finally {
    s.core.close();
  }
});

test("a_return_before_the_last_is_over_ends_it", async () => {
  const { s, wake, backs } = await fixture();
  try {
    wake(10_000);
    await s.host.time.pass(100, 50);
    wake(10_000);
    await s.host.time.pass(100, 50);
    s.push("overview", {}, "abcdef.60");
    await s.host.time.pass(100, 50);
    assert.deepEqual((await backs()).map((b) => b.end).sort(), ["again", "event"]);
  } finally {
    s.core.close();
  }
});
