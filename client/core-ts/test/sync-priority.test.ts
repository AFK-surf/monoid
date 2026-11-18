// How urgent each read of a station is, as it goes (scheduler.ts): what a UI opens raised while it is open and let go
// after; the background one at a time and only while nothing in a person's sight is asked or under way; what is idle
// (fill.ts) giving way at once; a station's history swept once a read, streamed a line a read (station's NDJSON) or
// read whole from a station from before that, what came before a cut kept.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Deferred, Effect } from "effect";
import type { Core } from "../src/core.ts";
import { HostError } from "../src/error.ts";
import { Priority } from "../src/sync/scheduler.ts";
import { HostWire, type StationWire } from "../src/station/wire.ts";
import type { FakeHost } from "../src/testing.ts";
import { READ_RETRY_MS } from "../src/station/sync.ts";
import { base, entries, started, threadView } from "./station-fixture.ts";
import { subscribe } from "./helpers.ts";

// deno-lint-ignore no-explicit-any
type J = any;
const ST = "ws/st";

/// A task that runs until let go of (`go`), and whether it began.
function held() {
  const gate = Deferred.makeUnsafe<void>();
  const state = { began: false };
  const work = Effect.andThen(Effect.sync(() => void (state.began = true)), Deferred.await(gate));
  return { work, state, go: () => Deferred.doneUnsafe(gate, Effect.void) };
}

/// The lane's tasks as the scheduler lists them, without the lane's name.
const pending = (core: Core, lane: string) => core.inner.scheduler.pending().filter((p) => p.startsWith(`${lane} ${lane} `)).map((p) => p.slice(2 * lane.length + 2));

test("what_a_ui_makes_urgent_is_raised_while_it_says_so_and_goes_back_after", async () => {
  const { host, core } = await started();
  const sched = core.inner.scheduler;
  const L = "ws/lane1";
  // The lane full of what a person waits on: what comes after waits.
  const full = [held(), held(), held(), held()];
  full.forEach((h, i) => sched.enqueue(L, `${L} asked/${i}`, Priority.asked, h.work));
  const ran: string[] = [];
  const task = (name: string) => Effect.sync(() => void ran.push(name));
  sched.enqueue(L, `${L} entries/7`, Priority.shown, task("7"));
  sched.enqueue(L, `${L} entries/8`, Priority.shown, task("8"));
  sched.enqueue(L, `${L} thread/7`, Priority.background, task("t7"));
  sched.enqueue(L, `${L} session/k1`, Priority.background, task("k1"));
  await host.settle();
  sched.prioritize("ui", `${L} entries/7`, Priority.focused);
  assert.ok(pending(core, L).includes("entries/7@20"));
  // Let go (the chat closed): back to what it was asked at, the next one opened ahead of it.
  sched.prioritize("ui", null);
  assert.ok(pending(core, L).includes("entries/7@10"));
  sched.prioritize("ui", `${L} entries/8`, Priority.focused);
  assert.ok(pending(core, L).includes("entries/8@20"));
  // Several at once (a chat's messages, its summary, its agent's session), all let go together.
  sched.prioritize("ui2", [`${L} entries/7`, `${L} thread/7`, `${L} session/k1`], Priority.focused);
  assert.deepEqual(["entries/7@20", "thread/7@20", "session/k1@20"].filter((p) => pending(core, L).includes(p)).length, 3);
  sched.prioritize("ui2", []);
  assert.deepEqual(["entries/7@10", "thread/7@0", "session/k1@0"].filter((p) => pending(core, L).includes(p)).length, 3);
  // A place in the room kept for the urgent: the one raised goes first.
  full[0]!.go();
  await host.settle();
  assert.deepEqual(ran, ["8"]);
  for (const h of full.slice(1)) h.go();
  await host.settle();
  assert.deepEqual(ran, ["8", "7", "t7", "k1"]);
  core.close();
});

test("the_background_goes_one_at_a_time_and_never_beside_what_a_person_sees", async () => {
  const { host, core } = await started();
  const sched = core.inner.scheduler;
  const L = "ws/lane2";
  const [b1, b2, shown] = [held(), held(), held()];
  sched.enqueue(L, `${L} b1`, Priority.background, b1.work);
  sched.enqueue(L, `${L} b2`, Priority.background, b2.work);
  await host.settle();
  assert.deepEqual([b1.state.began, b2.state.began], [true, false], "one at a time");
  // What is shown goes at once beside the one gone, and what a person waits on or has open too.
  sched.enqueue(L, `${L} shown`, Priority.shown, shown.work);
  const asked = held();
  const focused = held();
  sched.enqueue(L, `${L} asked`, Priority.asked, asked.work);
  sched.enqueue(L, `${L} focused`, Priority.focused, focused.work);
  await host.settle();
  assert.deepEqual([shown.state.began, asked.state.began, focused.state.began], [true, true, true]);
  // The one gone ends: the next waits while anything more urgent is under way.
  b1.go();
  asked.go();
  focused.go();
  await host.settle();
  assert.equal(b2.state.began, false);
  shown.go();
  await host.settle();
  assert.equal(b2.state.began, true);
  b2.go();
  await host.settle();
  // A request in a person's sight that is no task (a message sent, a file opened): the background waits for it too.
  const end = sched.foregroundBegin(L);
  const b3 = held();
  sched.enqueue(L, `${L} b3`, Priority.background, b3.work);
  await host.settle();
  assert.equal(b3.state.began, false);
  end();
  end();
  await host.settle();
  assert.equal(b3.state.began, true);
  b3.go();
  await host.settle();
  core.close();
});

test("what_is_idle_goes_alone_and_gives_way_to_anything_more_urgent", async () => {
  const { host, core } = await started();
  const sched = core.inner.scheduler;
  const L = "ws/lane3";
  let gaveWay = 0;
  const idle = held();
  const work = Effect.andThen(Effect.raceFirst(idle.work, Effect.andThen(sched.preempted(L), Effect.sync(() => void gaveWay++))), Effect.void);
  const bg = held();
  sched.enqueue(L, `${L} bg`, Priority.background, bg.work);
  sched.enqueue(L, `${L} idle`, Priority.idle, work);
  await host.settle();
  assert.equal(idle.state.began, false, "not beside the background");
  bg.go();
  await host.settle();
  assert.equal(idle.state.began, true);
  assert.equal(gaveWay, 0, "the background asked nothing of it");
  // A read in the background that no one waits on but is more urgent than the background (a quiet read of a list shown)
  sched.enqueue(L, `${L} shown`, Priority.shown, Effect.void);
  await host.settle();
  assert.equal(gaveWay, 1);
  // A request in a person's sight gives way at once too.
  const again = held();
  let second = 0;
  sched.enqueue(L, `${L} idle`, Priority.idle, Effect.raceFirst(again.work, Effect.andThen(sched.preempted(L), Effect.sync(() => void second++))));
  await host.settle();
  assert.equal(again.state.began, true);
  const end = sched.foregroundBegin(L);
  await host.settle();
  assert.equal(second, 1);
  end();
  core.close();
});

test("a_steps_detail_and_a_cards_lists_are_not_held_up_by_a_history_batch_in_the_background", async () => {
  const answers: J = { ...base(), "GET /sessions/k1/timeline?from=0&to=1&whole=1": { start: 0, entries: [] } };
  const { host, core } = await started(answers, 0, undefined, (s) => s.host.hold("/admin/api/batch"));
  const sync = core.inner.stations;
  assert.equal(host.requests.filter((r) => r.url.endsWith("/admin/api/batch")).length, 1, "a batch hangs");
  let done = false;
  void Effect.runPromise(Effect.ensuring(Effect.ignore(sync.detail(ST, "k1", 0, 1)), Effect.sync(() => void (done = true))));
  await host.settle();
  assert.equal(done, true, "the step's detail, asked by a person: at once");
  // A login's card and a job's: the lists they show raised to what is open while shown.
  const sched = core.inner.scheduler;
  const full = [held(), held(), held(), held()];
  full.forEach((h, i) => sched.enqueue(ST, `${ST} hold/${i}`, Priority.asked, h.work));
  sched.enqueue(ST, `${ST} machineLogins`, Priority.background, Effect.void);
  sched.enqueue(ST, `${ST} jobs`, Priority.background, Effect.void);
  const ui = core.connect();
  subscribe(core, ui, 1, { topic: "machineLogin", station: ST, id: "l1" });
  subscribe(core, ui, 2, { topic: "job", station: ST, id: "j1" });
  await host.settle();
  assert.ok(pending(core, ST).includes("machineLogins@20"), pending(core, ST).join(", "));
  assert.ok(pending(core, ST).includes("jobs@20"), pending(core, ST).join(", "));
  core.receive(ui, { kind: "unsubscribe", id: 2, unsubscribe: true });
  await host.time.pass(60_000);
  full.forEach((h) => h.go());
  await host.settle();
  core.close();
});

test("a_stations_history_is_swept_once_its_lists_are_read", async () => {
  const { core } = await started();
  assert.equal(core.inner.stations.link(ST)!.historySweep, 1);
  core.close();
});

/// A station of `n` chats (threads 1 to n, each of `last` entries) beside its one session.
const manyChats = (n: number, last: number): J => {
  const answers: J = { ...base(), "GET /threads": Array.from({ length: n }, (_, i) => threadView(i + 1, last)) };
  for (let id = 1; id <= n; id++) answers[`GET /threads/${id}/entries?limit=50`] = { last, entries: entries(1, last).map((e) => ({ ...e, thread: id })) };
  return answers;
};
const batchGets = (host: FakeHost) => host.requests.filter((r) => r.method === "POST" && r.url.endsWith("/admin/api/batch")).map((r) => JSON.parse(new TextDecoder().decode(r.body!)).gets as string[]);

test("a_history_batch_from_a_station_from_before_streams_is_read_whole_all_the_same", async () => {
  const { host, core } = await started(manyChats(60, 3), 0, undefined, (s) => void (s.batches.ndjson = false));
  assert.deepEqual(batchGets(host).map((b) => b.length), [40, 21, 1]);
  for (const id of [1, 30, 60]) assert.deepEqual(core.inner.data.logNumbers("entry", ST, String(id)), [1, 2, 3]);
  assert.equal(core.inner.data.get({ topic: "session", station: ST, key: "k1" }) !== undefined, true);
  core.close();
});

test("a_history_batch_cut_as_it_streams_keeps_what_came_and_asks_only_the_rest_again", async () => {
  let cut = true;
  const lines: number[] = [];
  // The first batch's answer cut after its first two lines (its link went), each line a piece of its own.
  const wire = (host: FakeHost): StationWire => {
    const inner = new HostWire(host);
    return {
      request: (station, head, body) => {
        if (!head.path.endsWith("/batch") || !cut) return inner.request(station, head, body);
        cut = false;
        // (asked as it is, so that its lines can be cut apart here)
        const plain = { ...head, headers: head.headers.filter(([k]) => k.toLowerCase() !== "accept-encoding") };
        return Effect.map(inner.request(station, plain, body), (reply) => {
          let parts: Uint8Array[] | null = null;
          let at = 0;
          const take = Effect.gen(function* () {
            if (parts === null) {
              const whole = yield* reply.body.take;
              parts = new TextDecoder().decode(whole ?? new Uint8Array()).split("\n").filter((l) => l !== "").slice(0, 2).map((l) => new TextEncoder().encode(`${l}\n`));
            }
            if (at < parts.length) {
              lines.push(at);
              return parts[at++]!;
            }
            return yield* Effect.fail(new HostError("connection lost"));
          });
          return { ...reply, body: { take } };
        });
      },
    };
  };
  const { host, core } = await started(manyChats(5, 3), 0, wire, (s) => void (s.batches.ndjson = true));
  // (the first asks every thread with the session; asked again a little later, only what had not come)
  await host.time.pass(READ_RETRY_MS * 4);
  const asked = batchGets(host);
  assert.ok(asked.length >= 2, `${asked.length} batches`);
  const [first, second] = asked as [string[], string[]];
  assert.equal(first.length, 6);
  assert.deepEqual(second, first.slice(2), "what came before the cut is not asked again");
  for (const id of [1, 5]) assert.deepEqual(core.inner.data.logNumbers("entry", ST, String(id)), [1, 2, 3]);
  assert.deepEqual(lines, [0, 1]);
  core.close();
});

test("a_history_batch_asks_its_answer_streamed_and_carries_no_write_key", async () => {
  const { host, core } = await started(manyChats(3, 3));
  const r = host.requests.find((x) => x.method === "POST" && x.url.endsWith("/admin/api/batch"))!;
  const header = (k: string) => r.headers.find(([n]) => n.toLowerCase() === k)?.[1];
  assert.ok(header("accept")?.includes("application/x-ndjson"));
  assert.equal(header("idempotency-key"), undefined);
  for (const id of [1, 3]) assert.deepEqual(core.inner.data.logNumbers("entry", ST, String(id)), [1, 2, 3]);
  core.close();
});

