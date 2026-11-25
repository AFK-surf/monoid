// On a cellular network (`client.network {cellular: true}`), on phone devices (`client.device` with phone app), or for
// workspaces not currently focused (`client.focus`), station `/events` streams carry `spare=1` and `open=<key>` for
// sessions whose `live` topic is in use (except while `stationRates` is in use). Unopened sessions' transcripts (unless
// actively read, e.g. via `$slack-said`) are neither written from live events nor fetched on summary growth until opened
// or until returning to a full stream.
import assert from "node:assert/strict";
import { test } from "node:test";
import { observe } from "../src/reactive.ts";
import { apply, call, subscribe, v } from "./helpers.ts";
import { base, session, started, stationReplies, status } from "./station-fixture.ts";

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

// A session's steps keep coming while its transcript is not taken here (spared on cellular while its stream follows
// every session, as with stationRates in use; or let go for room). What is held stays where it was, so the steps that
// ended were never let go: its history, opened, showed a column of 正在思考… under 已到会话开头 and none of its entries.
test("steps_ended_while_a_transcript_is_not_taken_are_let_go_and_its_history_shows_them_only_once_it_holds_where_they_go_on_from", async () => {
  const answers = threeSessions();
  let reads = 0;
  let answering = false;
  const s = await started(answers, 0, undefined, (f) => {
    f.gate.marks = true;
    f.gate.resumes = true;
    stationReplies(f.host, (req) => {
      const path = req.url.replace("https://stillfail.test/admin/api", "");
      if (!path.startsWith("/sessions/k2/timeline")) return undefined;
      // Its reads fail till it answers: it is read again while shown.
      reads++;
      if (!answering) return status(502, { error: "坏了" });
      return { start: 0, end: 22, entries: Array.from({ length: 22 }, (_, i) => ({ kind: "step", text: `k2-${i}` })) };
    });
  });
  const ui = s.core.connect();
  const k2 = { topic: "live", station: S, key: "k2" };
  const view = () => s.core.inner.stations.link(S)?.lives.get("k2");
  const live = () => (s.core.inner.stationTopics.compute(k2) as any).ok;
  try {
    await s.host.time.pass(500, 10);
    call(s.core, ui, 1, "client.network", { cellular: true });
    // stationRates: its stream follows every session, k2's steps too, while k2's transcript is spared.
    subscribe(s.core, ui, 12, { topic: "stationRates", station: S });
    await s.host.time.pass(500, 10);
    assert.ok(!s.streams.at(-1)!.path.includes("spare=1"), s.streams.at(-1)!.path);
    const push = (m: unknown) => s.push("live", { key: "k2", ...(m as object) });
    push({ type: "timeline", start: 1, entries: [], usage: {} });
    push({ type: "steps", steps: [], phase: null });
    // Ten model calls, each thinking and then a call, as the station tells them; their entries are not taken here.
    for (let i = 0; i < 10; i++) {
      push({ type: "step", event: { kind: "start", id: `said:${i}/thinking`, step: "thinking" } });
      push({ type: "step", event: { kind: "end", id: `said:${i}/thinking` } });
      push({ type: "step", event: { kind: "start", id: `call:${i}`, step: "tool", tool: "Bash", input: "ls" } });
      push({ type: "step", event: { kind: "end", id: `call:${i}` } });
      push({ type: "timeline", start: 1 + 2 * i, entries: [{ kind: "step", text: `t${i}` }, { kind: "step", text: `c${i}` }], usage: {} });
    }
    push({ type: "step", event: { kind: "start", id: "said:10/thinking", step: "thinking" } });
    push({ type: "step", event: { kind: "phase", phase: "requesting" } });
    await s.host.time.pass(500, 10);
    assert.ok((s.core.inner.data.logSpan("transcript", S, "k2")?.max ?? 0) < 1, "its entries are not taken while spared");
    assert.deepEqual(view()?.steps.map((st: any) => st.id), ["said:10/thinking"], "what ended is let go: its entries come with the read that shows them");

    // Opened, its latest entries' read fails: what is held is behind where the steps go on from, so none is shown, and
    // nothing says it is all there is.
    subscribe(s.core, ui, 13, k2);
    await s.host.time.pass(200, 10);
    let x = live();
    assert.ok(reads >= 1);
    assert.deepEqual([x.loaded, x.steps, x.failed], [false, [], "坏了"]);
    assert.ok(x.timeline.length < 2, "none of what came while spared is held");
    assert.equal(x.phase, null, "nothing goes on from nothing held");

    // Read again: what is held reaches where its stream said it goes, and the step in flight goes on after it.
    answering = true;
    await s.host.time.pass(60_000, 500);
    x = live();
    assert.equal(x.loaded, true);
    assert.equal(x.timeline.length, 22);
    assert.deepEqual(x.steps.map((st: any) => st.id), ["said:10/thinking"]);
  } finally {
    s.core.close();
  }
});

test("phone devices enable spare=1 on Wi-Fi, keep open live sessions and slack-said reads, and yield to stationRates", async () => {
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
  try {
    // Desktop/unspecified starts full
    assert.ok(!s.streams.at(-1)!.path.includes("spare=1"), s.streams.at(-1)!.path);
    await s.host.time.pass(500, 10);
    timelineGets.length = 0;

    // Identifying as iOS enables spare=1 even on Wi-Fi
    call(s.core, ui, 1, "client.device", { app: "ios", model: "iPhone", build: "0.1.99" });
    await s.host.time.pass(500, 10);
    assert.ok(s.streams.at(-1)!.path.includes("spare=1"), `ios should spare on Wi-Fi: ${s.streams.at(-1)!.path}`);

    // Unopened k2 timeline event is dropped while sparing on phone
    s.push("live", { key: "k2", type: "timeline", start: 1, entries: [{ kind: "step", text: "k2-dropped" }] });
    s.push("session", { ...session("k2"), transcriptLength: 3 });
    await s.host.time.pass(1_000, 20);
    assert.equal(s.core.inner.data.logSpan("transcript", S, "k2")?.max, 0);
    assert.deepEqual(timelineGets.filter((p) => p.includes("/k2/")), []);

    // A transcript read by a Slack-said query (opened chat without live topic) is still kept current while sparing
    const stopObserve = observe(() => void s.core.inner.data.slackSaid(S, "k3"), () => {});
    try {
      s.push("session", { ...session("k3"), transcriptLength: 3 });
      await s.host.time.pass(1_000, 20);
      assert.equal(s.core.inner.data.logSpan("transcript", S, "k3")?.max, 2, "transcript read via $slack-said must not be dropped while sparing");
    } finally {
      stopObserve();
    }

    // Opening k2 live topic fetches missing transcript and passes open=k2
    subscribe(s.core, ui, 10, { topic: "live", station: S, key: "k2" });
    await s.host.time.pass(1_000, 20);
    assert.ok(s.streams.at(-1)!.path.includes("spare=1") && s.streams.at(-1)!.path.includes("open=k2"), s.streams.at(-1)!.path);
    assert.equal(s.core.inner.data.logSpan("transcript", S, "k2")?.max, 2);

    // stationRates still overrides spare=1
    subscribe(s.core, ui, 11, { topic: "stationRates", station: S });
    await s.host.time.pass(500, 10);
    assert.ok(!s.streams.at(-1)!.path.includes("spare=1"), s.streams.at(-1)!.path);
  } finally {
    s.core.close();
  }
});

test("non-current workspace stations spare live streams until workspace regains focus and then catch up transcripts", async () => {
  const answers = threeSessions();
  const timelineGets: string[] = [];
  const s = await started(answers, 0, undefined, (f) => {
    f.gate.marks = true;
    f.gate.resumes = true;
    stationReplies(f.host, (req) => {
      const path = req.url.replace("https://stillfail.test/admin/api", "");
      if (path.includes("/timeline")) timelineGets.push(path);
      if (path.startsWith("/sessions/k3/timeline") && path.includes("after=0")) {
        return { start: 1, end: 3, entries: [{ kind: "step", text: "k3-1" }, { kind: "step", text: "k3-2" }] };
      }
      return undefined;
    });
  });
  const ui = s.core.connect();
  try {
    call(s.core, ui, 1, "client.device", { app: "desktop", build: "0.1.99" });
    call(s.core, ui, 2, "client.focus", { visible: true, focused: true, workspace: "ws" });
    await s.host.time.pass(500, 10);
    assert.ok(!s.streams.at(-1)!.path.includes("spare=1"), `focused workspace must stay full: ${s.streams.at(-1)!.path}`);
    timelineGets.length = 0;

    // Switching focus to another workspace spares ws/st seamlessly
    call(s.core, ui, 3, "client.focus", { visible: true, focused: true, workspace: "other-ws" });
    await s.host.time.pass(500, 10);
    assert.ok(s.streams.at(-1)!.path.includes("spare=1"), `unfocused workspace must spare: ${s.streams.at(-1)!.path}`);

    // Unopened k3 transcript growth while unfocused is skipped
    s.push("live", { key: "k3", type: "timeline", start: 1, entries: [{ kind: "step", text: "k3-dropped" }] });
    s.push("session", { ...session("k3"), transcriptLength: 3 });
    await s.host.time.pass(1_000, 20);
    assert.equal(s.core.inner.data.logSpan("transcript", S, "k3")?.max, 0);
    assert.deepEqual(timelineGets.filter((p) => p.includes("/k3/")), []);

    // Switching focus back to ws restores full stream and sweeps lagging k3 transcript
    call(s.core, ui, 4, "client.focus", { visible: true, focused: true, workspace: "ws" });
    await s.host.time.pass(2_000, 40);
    assert.ok(!s.streams.at(-1)!.path.includes("spare=1"), `refocused workspace must restore full: ${s.streams.at(-1)!.path}`);
    assert.equal(s.core.inner.data.logSpan("transcript", S, "k3")?.max, 2, "refocusing workspace catches up lagging transcript k3");
  } finally {
    s.core.close();
  }
});
