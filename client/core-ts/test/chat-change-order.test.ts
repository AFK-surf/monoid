import assert from "node:assert/strict";
import { test } from "node:test";
import { Deferred, Effect } from "effect";
import { HostWire } from "../src/station/wire.ts";
import { apply, call, subscribe, v } from "./helpers.ts";
import { base, chatsOf, started, stationReplies, status, threadView } from "./station-fixture.ts";

test("successive chat renames reach the station in the order chosen", async () => {
  const first = Deferred.makeUnsafe<void>();
  let delay = true;
  let title = "Original";
  const writes: string[] = [];
  const { host, core } = await started({ ...base(), "GET /threads": [{ ...threadView(7, 3), title }] }, 0, (host) => {
    const wire = new HostWire(host);
    return {
      request: (station, head, body) => Effect.suspend(() => {
        if (head.method === "PUT" && head.path.endsWith("/threads/7/title") && delay) {
          delay = false;
          // A slow request has not reached the station; a later stream can otherwise overtake it.
          return Effect.andThen(Deferred.await(first), wire.request(station, head, body));
        }
        return wire.request(station, head, body);
      }),
    };
  });
  stationReplies(host, (req) => {
    const path = req.url.replace("https://stillfail.test/admin/api", "");
    if (req.method === "PUT" && path === "/threads/7/title") {
      title = JSON.parse(new TextDecoder().decode(req.body!)).title;
      writes.push(title);
      return { ...threadView(7, 3), title };
    }
    if (req.method === "GET" && path === "/threads") return [{ ...threadView(7, 3), title }];
    return undefined;
  });
  const ui = core.connect();
  const values = new Map<number, unknown>();
  subscribe(core, ui, 1, { topic: "chats", scope: "ws" });
  const rowTitle = () => v(values, 1).days.flatMap((d: { items: { title: string }[] }) => d.items)[0].title;
  try {
    await host.settle();
    call(core, ui, 2, "chat.rename", { station: "ws/st", session: "k1", thread: 7, title: "First" });
    await host.settle();
    apply(host, values);
    assert.equal(rowTitle(), "First", "the first rename is visible while its request is delayed");
    call(core, ui, 3, "chat.rename", { station: "ws/st", session: "k1", thread: 7, title: "Latest" });
    await host.settle();
    apply(host, values);
    assert.equal(rowTitle(), "Latest", "the second rename is visible without waiting for the first");
    Deferred.doneUnsafe(first, Effect.void);
    await host.settle();
    apply(host, values);
    assert.equal(title, "Latest", "the station must retain the last title the person chose");
    assert.deepEqual(writes, ["First", "Latest"]);
    assert.equal(rowTitle(), "Latest");
  } finally {
    Deferred.doneUnsafe(first, Effect.void);
    core.close();
  }
});

async function rig(refuseFirst = false) {
  const titles = new Map([[7, "Original"], [8, "Other"]]);
  const writes: string[] = [];
  const rows = () => [...titles].map(([thread, title]) => ({ id: `k${thread - 6}`, session: `k${thread - 6}`, thread, title }));
  const { host, core } = await started({ ...base(), ...chatsOf(rows()) });
  stationReplies(host, (req) => {
    const path = req.url.replace("https://stillfail.test/admin/api", "");
    const match = /^\/threads\/(\d+)\/(title|muted)$/.exec(path);
    if (req.method === "PUT" && match) {
      const n = Number(match[1]);
      const body = JSON.parse(new TextDecoder().decode(req.body!));
      writes.push(`${n}/${match[2]}/${body[match[2]!]}`);
      if (body.title === "First" && refuseFirst) return status(400, { error: "refused" });
      if (match[2] === "muted") return { ok: true, muted: body.muted };
      titles.set(n, body.title);
      return { ...threadView(n, 3), title: body.title, sessions: [{ thread: n, session: `k${n - 6}`, connect: "ember", joinedAt: 1 }] };
    }
    const listed = chatsOf(rows());
    if (req.method === "GET" && `GET ${path}` in listed) return listed[`GET ${path}`];
    return undefined;
  });
  const ui = core.connect();
  const values = new Map<number, unknown>();
  const answers = new Map<number, { ok?: unknown; error?: unknown }>();
  subscribe(core, ui, 1, { topic: "chats", scope: "ws" });
  const flush = async () => {
    await host.settle();
    for (const [, message] of host.emitted) {
      const m = message as { id: number; ok?: unknown; error?: unknown };
      if ("ok" in m || "error" in m) answers.set(m.id, m);
    }
    apply(host, values);
  };
  await flush();
  return {
    host, core, titles, writes, answers, flush,
    rename: (id: number, thread: number, title: string) => call(core, ui, id, "chat.rename", { station: "ws/st", session: `k${thread - 6}`, thread, title }),
    mute: (id: number, muted: boolean) => call(core, ui, id, "chat.mute", { station: "ws/st", thread: 7, muted }),
    row: (thread: number) => v(values, 1).days.flatMap((d: { items: { thread: number; title: string }[] }) => d.items).find((r: { thread: number }) => r.thread === thread),
  };
}

test("the earlier rename's answer does not roll back the later local title", async () => {
  const r = await rig();
  const first = r.host.hold("/threads/7/title");
  let second = () => {};
  try {
    r.rename(2, 7, "First");
    await r.flush();
    second = r.host.hold("/threads/7/title");
    r.rename(3, 7, "Latest");
    await r.flush();
    assert.equal(r.row(7).title, "Latest");
    first();
    await r.flush();
    assert.ok(r.answers.has(2));
    assert.ok(!r.answers.has(3), "the later answer is still held");
    assert.equal(r.row(7).title, "Latest", "the first answer cannot replace the newer choice");
    second();
    await r.flush();
    assert.equal(r.row(7).title, "Latest");
    assert.equal(r.titles.get(7), "Latest");
  } finally {
    first();
    second();
    r.core.close();
  }
});

test("a failed rename releases the next choice without rolling it back", async () => {
  const r = await rig(true);
  const first = r.host.hold("/threads/7/title");
  try {
    r.rename(2, 7, "First");
    await r.flush();
    r.rename(3, 7, "Latest");
    await r.flush();
    assert.equal(r.row(7).title, "Latest");
    first();
    await r.flush();
    assert.ok(r.answers.get(2)?.error);
    assert.ok(r.answers.get(3)?.ok);
    assert.equal(r.titles.get(7), "Latest");
    assert.equal(r.row(7).title, "Latest");
    assert.deepEqual(r.writes, ["7/title/First", "7/title/Latest"]);
  } finally {
    first();
    r.core.close();
  }
});

test("a pending title write does not delay another chat or a different field", async () => {
  const r = await rig();
  const first = r.host.hold("/threads/7/title");
  try {
    r.rename(2, 7, "First");
    await r.flush();
    r.rename(3, 8, "Other latest");
    r.mute(4, true);
    await r.flush();
    assert.ok(!r.answers.has(2));
    assert.ok(r.answers.get(3)?.ok);
    assert.ok(r.answers.get(4)?.ok);
    assert.equal(r.titles.get(8), "Other latest");
    assert.equal(r.row(8).title, "Other latest");
    assert.deepEqual(r.answers.get(4)?.ok, { ok: true, muted: true });
    assert.deepEqual(r.writes, ["7/title/First", "8/title/Other latest", "7/muted/true"]);
  } finally {
    first();
    r.core.close();
  }
});

test("pin and unpin keep their order even though they use different HTTP methods", async () => {
  const first = Deferred.makeUnsafe<void>();
  let delay = true;
  let pinned = false;
  const writes: string[] = [];
  const { host, core } = await started(base(), 0, (host) => {
    const wire = new HostWire(host);
    return {
      request: (station, head, body) => Effect.suspend(() => {
        if (head.method === "PUT" && head.path.endsWith("/sessions/k1/pin") && delay) {
          delay = false;
          return Effect.andThen(Deferred.await(first), wire.request(station, head, body));
        }
        return wire.request(station, head, body);
      }),
    };
  });
  stationReplies(host, (req) => {
    if (!req.url.endsWith("/sessions/k1/pin")) return undefined;
    writes.push(req.method);
    pinned = req.method === "PUT";
    return { ok: true };
  });
  const ui = core.connect();
  const values = new Map<number, unknown>();
  subscribe(core, ui, 1, { topic: "chats", scope: "ws" });
  const pin = (id: number, on: boolean) => call(core, ui, id, "chat.pin", { station: "ws/st", session: "k1", pinned: on });
  try {
    pin(2, true);
    await host.settle();
    apply(host, values);
    assert.equal(v(values, 1).days[0].items[0].pinned, true);
    pin(3, false);
    await host.settle();
    apply(host, values);
    assert.equal(v(values, 1).days[0].items[0].pinned, false);
    Deferred.doneUnsafe(first, Effect.void);
    await host.settle();
    assert.equal(pinned, false, "the final unpin must remain on the station");
    assert.deepEqual(writes, ["PUT", "DELETE"]);
  } finally {
    Deferred.doneUnsafe(first, Effect.void);
    core.close();
  }
});
