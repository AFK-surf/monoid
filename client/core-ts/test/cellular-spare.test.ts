// On a cellular network (`client.network {cellular: true}`), station `/events` streams carry `spare=1` and `open=<key>`
// for sessions whose `live` topic is in use (except while `stationRates` is in use). Unopened sessions' transcripts are
// neither written from live events nor fetched on summary growth until opened or until leaving cellular.
import assert from "node:assert/strict";
import { test } from "node:test";
import { apply, call, subscribe, v } from "./helpers.ts";
import { base, session, started, stationReplies } from "./station-fixture.ts";

const S = "ws/st";

function threeSessions() {
  const b = base();
  const s1 = { ...session("k1"), transcriptLength: 1 };
  const s2 = { ...session("k2"), transcriptLength: 1 };
  const s3 = { ...session("k3"), transcriptLength: 1 };
  b["GET /sessions"] = [s1, s2, s3];
  b["GET /sessions/k1"] = { session: s1, threads: [], turns: [], jobs: [] };
  b["GET /sessions/k2"] = { session: s2, threads: [], turns: [], jobs: [] };
  b["GET /sessions/k3"] = { session: s3, threads: [], turns: [], jobs: [] };
  b["GET /sessions/k1/timeline?before=1000000000000000&limit=200&brief=1"] = { start: 0, end: 1, entries: [{ kind: "step", text: "k1-0" }] };
  b["GET /sessions/k2/timeline?before=1000000000000000&limit=200&brief=1"] = { start: 0, end: 1, entries: [{ kind: "step", text: "k2-0" }] };
  b["GET /sessions/k3/timeline?before=1000000000000000&limit=200&brief=1"] = { start: 0, end: 1, entries: [{ kind: "step", text: "k3-0" }] };
  return b;
}

test("cellular network spares unopened live streams, skips unopened transcript writes/reads, catches up on open and on Wi-Fi return, and yields to stationRates", async () => {
  const answers = threeSessions();
  const timelineGets: string[] = [];
  const s = await started(answers, 0, undefined, (f) => {
    f.gate.marks = true;
    f.gate.resumes = true;
    stationReplies(f.host, (req) => {
      const path = req.url.replace("https://stillfail.test/admin/api", "");
      if (path.includes("/timeline")) timelineGets.push(path);
      if (path.startsWith("/sessions/k2/timeline") && path.includes("after=0")) {
        return { start: 1, end: 3, entries: [{ kind: "step", text: "k2-1" }, { kind: "step", text: "k2-2" }] };
      }
      if (path.startsWith("/sessions/k3/timeline") && path.includes("after=0")) {
        return { start: 1, end: 3, entries: [{ kind: "step", text: "k3-1" }, { kind: "step", text: "k3-2" }] };
      }
      return undefined;
    });
  });
  const ui = s.core.connect();
  const values = new Map();
  try {
    // Initial full stream has no spare=1
    assert.ok(!s.streams.at(-1)!.path.includes("spare=1"), s.streams.at(-1)!.path);
    await s.host.time.pass(500, 10);
    timelineGets.length = 0;

    // (a) client.network {cellular: true} -> stream replaced with spare=1 (no open=)
    call(s.core, ui, 1, "client.network", { cellular: true });
    await s.host.time.pass(500, 10);
    const sparedEmpty = s.streams.at(-1)!.path;
    assert.ok(sparedEmpty.includes("spare=1"), sparedEmpty);
    assert.ok(!sparedEmpty.includes("open="), sparedEmpty);

    // Opening k1's live topic replaces stream with spare=1&open=k1
    subscribe(s.core, ui, 10, { topic: "live", station: S, key: "k1" });
    await s.host.time.pass(500, 10);
    const sparedK1 = s.streams.at(-1)!.path;
    assert.ok(sparedK1.includes("spare=1"), sparedK1);
    assert.ok(sparedK1.includes("open=k1"), sparedK1);

    // (b) While sparing, unopened k2 timeline event is NOT written to DB
    s.push("live", { key: "k2", type: "timeline", start: 1, entries: [{ kind: "step", text: "k2-live-dropped" }] });
    await s.host.time.pass(500, 10);
    assert.equal(s.core.inner.data.logSpan("transcript", S, "k2")?.max, 0, "unopened k2 timeline not persisted while sparing");

    // Summary transcriptLength growth for unopened k2 and k3 does NOT trigger timeline fetches
    s.push("session", { ...session("k2"), transcriptLength: 3 });
    s.push("session", { ...session("k3"), transcriptLength: 3 });
    await s.host.time.pass(1_000, 20);
    assert.deepEqual(
      timelineGets.filter((p) => p.includes("/k2/") || p.includes("/k3/")),
      [],
      "summary growth must not fetch unopened transcripts while sparing",
    );

    // (c) Opening k2 while sparing fetches its missing transcript and updates stream open=k1&open=k2
    subscribe(s.core, ui, 11, { topic: "live", station: S, key: "k2" });
    await s.host.time.pass(1_000, 20);
    const sparedK1K2 = s.streams.at(-1)!.path;
    assert.ok(sparedK1K2.includes("spare=1") && sparedK1K2.includes("open=k1") && sparedK1K2.includes("open=k2"), sparedK1K2);
    assert.equal(s.core.inner.data.logSpan("transcript", S, "k2")?.max, 2, "opening k2 while sparing fetches missing transcript");

    // (e) Subscribing to stationRates while sparing disables spare=1; unsubscribing re-enables it
    subscribe(s.core, ui, 12, { topic: "stationRates", station: S });
    await s.host.time.pass(500, 10);
    assert.ok(!s.streams.at(-1)!.path.includes("spare=1"), `stationRates disables spare: ${s.streams.at(-1)!.path}`);
    s.core.receive(ui, { kind: "unsubscribe", id: 12, unsubscribe: true });
    await s.host.time.pass(500, 10);
    assert.ok(s.streams.at(-1)!.path.includes("spare=1"), `stopping stationRates restores spare: ${s.streams.at(-1)!.path}`);

    // Confirm k3 is still behind (max 0) before leaving cellular
    assert.equal(s.core.inner.data.logSpan("transcript", S, "k3")?.max, 0);

    // (d) Leaving cellular ({cellular: false}) restores full stream and sweeps lagging k3 transcript
    call(s.core, ui, 2, "client.network", { cellular: false });
    await s.host.time.pass(2_000, 40);
    assert.ok(!s.streams.at(-1)!.path.includes("spare=1"), `cellular:false restores full stream: ${s.streams.at(-1)!.path}`);
    assert.equal(s.core.inner.data.logSpan("transcript", S, "k3")?.max, 2, "leaving cellular catches up lagging transcript k3");
    apply(s.host, values);
    assert.ok(v(values, 11) !== undefined);
  } finally {
    s.core.close();
  }
});
