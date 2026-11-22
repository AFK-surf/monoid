// F4a: POST /changed/shared, minimal per-station SQLite sidecar, cold-start restored/missed reconciliation,
// independent sharedChangesRefused flag, identity change baseline invalidation, mark revocation, 3-language
// re-projection, deletion, forgetStation cleanup, concurrent stream event replay, and crash atomicity.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Queue } from "effect";
import { Core } from "../src/core.ts";
import { reprojectChatRow, rowFor, sidecarOf } from "../src/chat-row.ts";
import { digest } from "../src/digest.ts";
import { SqlError } from "../src/host.ts";
import { setCurrent, tr } from "../src/i18n.ts";
import { OwnHeld, rowWords, sharedPlace } from "../src/station/rows-made.ts";
import { HostWire } from "../src/station/wire.ts";
import { work } from "../src/work.ts";
import { jsonResponse } from "../src/testing.ts";
import { run } from "./run.ts";
import { MARKS, base, started, stationLater, stationReplies, status } from "./station-fixture.ts";

const ST = "ws/st";

// deno-lint-ignore no-explicit-any
type J = any;

function sharedRow(id: string, thread: number, opts: {
  title?: string | null;
  text?: string;
  quotedOnly?: boolean;
  localAdmin?: boolean;
  lastSeq?: number;
  lastAuthor?: string;
  otherSeq?: number;
  cardSeq?: number;
  needSeq?: number;
  decisionSeq?: number;
  lastActiveAt?: number;
  mineOf?: J[];
  answeredBy?: J[];
} = {}): J {
  const lastSeq = opts.lastSeq ?? 5;
  const last: J = {
    seq: lastSeq,
    authorKind: "person",
    author: opts.localAdmin ? "local" : (opts.lastAuthor ?? "other@x"),
    authorName: opts.localAdmin ? null : "Other",
    text: opts.quotedOnly ? "" : (opts.text ?? `msg ${id}`),
    createdAt: opts.lastActiveAt ?? 1000,
    ...(opts.quotedOnly ? { quotedOnly: true } : {}),
  };
  return {
    id,
    session: id,
    thread,
    title: "",
    agents: [{ key: id, runtime: "claude", model: "claude-opus-4-6", effort: null, process: "cold", pending: 0, lastTurn: null }],
    last,
    unread: false,
    mine: false,
    lastActiveAt: opts.lastActiveAt ?? 1000,
    connect: null,
    origin: null,
    creator: { id: "a@x", name: "A", email: "a@x", via: "cloud" },
    people: [],
    named: { thread: { surface: "chat", title: opts.title ?? null, channel: null, threadTs: null }, firstText: null, channelName: null },
    said: { n: lastSeq, authorKind: last.authorKind, author: last.author, other: opts.otherSeq ?? lastSeq },
    mineOf: opts.mineOf ?? [{ id: "a@x", name: "A", email: "a@x", via: "cloud" }],
    answeredBy: opts.answeredBy ?? [],
    ...(opts.cardSeq !== undefined ? { card: { seq: opts.cardSeq, card: { type: "options", options: [] }, message: last, before: [] } } : {}),
    ...(opts.needSeq !== undefined ? { need: { seq: opts.needSeq, message: last, before: [] } } : {}),
    ...(opts.decisionSeq !== undefined ? { decision: { seq: opts.decisionSeq, message: last } } : {}),
  };
}

test("minimal sidecar schema stores no raw shared row, mineOf, or answeredBy and forgetStation cleans it up", async () => {
  const r1 = sharedRow("k1", 10, { quotedOnly: true, localAdmin: true, answeredBy: [{ seq: 1, by: { id: "a@x", email: "a@x" } }] });
  const answers: Record<string, unknown> = {
    ...base(),
    "GET /chats?marks=1": { ...MARKS, reads: { "10": 1 }, pins: { k1: 50 }, kept: [10], hidden: [10], muted: [10], dismissed: [] },
    "GET /chats?shared=1": [r1],
  };
  const s = await started(answers);
  try {
    await run(s.core.inner.data.written);
    const db = s.core.inner.data.of(ST)!;
    const cols = db.sql.all("PRAGMA table_info(shared_sidecar)").map((r) => String(r[1]));
    assert.deepEqual(cols, ["station", "id", "digest", "said", "named", "quoted_only", "local_admin"]);
    const scRows = db.sql.all("SELECT station, id, digest, said, named, quoted_only, local_admin FROM shared_sidecar WHERE station = ?", [ST]);
    assert.equal(scRows.length, 1);
    assert.equal(scRows[0]![1], "k1");
    assert.equal(scRows[0]![2], digest(r1));
    assert.equal(scRows[0]![5], 1);
    assert.equal(scRows[0]![6], 1);
    const serialized = JSON.stringify(scRows[0]);
    assert.ok(!serialized.includes("mineOf") && !serialized.includes("answeredBy"), "sidecar must not store mineOf or answeredBy");
    const meta = db.sharedMeta(ST);
    assert.equal(meta?.me, "a@x.com");
    assert.deepEqual(meta?.selves, []);

    db.forgetStation(ST);
    await run(db.written);
    assert.equal(db.sql.all("SELECT * FROM shared_sidecar WHERE station = ?", [ST]).length, 0);
    assert.equal(db.sql.all("SELECT * FROM shared_meta WHERE station = ?", [ST]).length, 0);
    assert.equal(db.sql.all("SELECT * FROM shared_mark WHERE station = ?", [ST]).length, 0);
  } finally {
    s.core.close();
  }
});

test("reprojectChatRow matches rowFor across 3 languages and revokes all derived marks", () => {
  const shared = sharedRow("k1", 10, { title: null, quotedOnly: true, localAdmin: true, lastSeq: 5, cardSeq: 3, needSeq: 4, decisionSeq: 5 });
  const sc = sidecarOf(shared, digest(shared));
  const ownFull = new OwnHeld({ kept: [10], hidden: [10], muted: [10], pins: { k1: 123 }, selves: [], dismissed: ["10:3", "10:4", "10:5"], reads: { "10": 1 } }, "a@x");
  const ownRevoked = new OwnHeld({ kept: [], hidden: [], muted: [], pins: {}, selves: [], dismissed: [], reads: { "10": 5 } }, "a@x");

  const wordsFor = (l: "zh" | "en") => ({
    untitled: tr(l, "core-views.new_chat"),
    directMessage: tr(l, "core-views.direct_message"),
    quotedOnly: tr(l, "station.chat.quotedOnly"),
    admin: tr(l, "station.author.admin"),
  });
  const wordSets = [
    ["zh", wordsFor("zh")],
    ["en", wordsFor("en")],
    ["ja", { untitled: "新しいチャット", directMessage: "ダイレクトメッセージ", quotedOnly: "メッセージを引用", admin: "管理者" }],
  ] as const;
  try {
    setCurrent("zh");
    const initial = rowFor(shared, ownFull, wordsFor("zh"));
    assert.equal(initial.pinned, 123);
    assert.equal(initial.hidden, true);
    assert.equal(initial.muted, true);
    assert.equal(initial.archiveReminderDismissed, true);
    assert.equal(initial.unread, true);
    assert.equal(initial.card.dismissed, true);
    assert.equal(initial.need.dismissed, true);
    assert.equal(initial.decision.dismissed, true);

    let currentRow = initial;
    for (const [lang, w] of wordSets) {
      const expected = rowFor(shared, ownRevoked, w);
      currentRow = reprojectChatRow(currentRow, sc, ownRevoked, w);
      assert.deepEqual(currentRow, expected, `reprojectChatRow matches rowFor in ${lang}`);
      assert.equal(currentRow.pinned, null);
      assert.equal(currentRow.hidden, false);
      assert.equal(currentRow.muted, false);
      assert.equal(currentRow.archiveReminderDismissed, false);
      assert.equal(currentRow.unread, false);
      assert.equal("dismissed" in currentRow.card, false);
      assert.equal("dismissed" in currentRow.need, false);
      assert.equal("dismissed" in currentRow.decision, false);
    }
  } finally {
    setCurrent("zh");
  }
});

test("cold-start restored reconciles via marks=1&own=1 + POST /changed/shared, while in-process resume adds zero extra requests", async () => {
  const r1 = sharedRow("k1", 10, { title: "One", lastActiveAt: 2000 });
  const r2 = sharedRow("k2", 11, { title: "Two", lastActiveAt: 1000 });
  const answers: Record<string, unknown> = {
    ...base(),
    "GET /chats?marks=1": { ...MARKS, reads: { "10": 5, "11": 5 } },
    "GET /chats?shared=1": [r1, r2],
  };
  const s = await started(answers);
  let cold: Core | undefined;
  try {
    // Establish heard cursor on stream.
    Queue.offerUnsafe(s.streams.at(-1)!.queue, new TextEncoder().encode("id: abcdef.1\nevent: overview\ndata: {}\n\n"));
    await s.host.settle();
    await run(s.core.inner.data.written);
    assert.equal(s.core.inner.data.record("heard", ST), "abcdef.1");

    // In-process resumed stream (restored: false): drop stream, let it resume -> zero marks/shared requests!
    s.gate.resumes = true;
    const beforeInProc = s.host.requests.length;
    Queue.offerUnsafe(s.streams.at(-1)!.queue, null);
    await s.host.time.pass(5_000, 100);
    const inProcReqs = s.host.requests.slice(beforeInProc).map((r) => `${r.method} ${r.url.replace("https://stillfail.test/admin/api", "")}`);
    assert.ok(!inProcReqs.some((r) => r.includes("/chats?marks=1") || r.includes("/chats?shared=1") || r.includes("/changed/shared")), `in-process resume must add zero chat/shared requests, got: ${JSON.stringify(inProcReqs)}`);

    // Cold start with restored cursor: update r2 and drop r1 on station.
    const r2Updated = sharedRow("k2", 11, { title: "Two Updated", lastActiveAt: 3000 });
    answers["GET /chats?shared=1"] = [r2Updated];
    s.core.close();
    await s.host.settle();
    const beforeCold = s.host.requests.length;
    cold = await Core.create(s.host, { clock: s.host.time.clock, sample: 0, wire: () => new HostWire(s.host) });
    await s.host.time.pass(1_000, 50);
    await run(cold.inner.data.written);

    const coldReqs = s.host.requests.slice(beforeCold).map((r) => `${r.method} ${r.url.replace("https://stillfail.test/admin/api", "")}`);
    assert.ok(coldReqs.includes("GET /chats?marks=1&own=1"), `cold start must fetch marks=1&own=1: ${JSON.stringify(coldReqs)}`);
    assert.ok(coldReqs.includes("POST /changed/shared"), `cold start must use POST /changed/shared: ${JSON.stringify(coldReqs)}`);
    assert.ok(!coldReqs.includes("GET /chats?shared=1"), `cold start must NOT fetch whole shared when delta succeeds: ${JSON.stringify(coldReqs)}`);

    const rows = cold.inner.data.get({ topic: "chatRows", station: ST }) as J[];
    assert.deepEqual(rows.map((r) => [r.id, r.title]), [["k2", "Two Updated"]]);
    assert.equal(cold.inner.data.of(ST)!.sharedDigests(ST).size, 1);
  } finally {
    cold?.close();
    s.core.close();
  }
});

test("POST /changed/shared error handling: 404 no route sets sharedChangesRefused, 413 single whole fallback, 403 never degrades", async () => {
  const r1 = sharedRow("k1", 10, { title: "One" });
  const answers: Record<string, unknown> = {
    ...base(),
    "GET /chats?marks=1": { ...MARKS, reads: { "10": 5 } },
    "GET /chats?shared=1": [r1],
  };
  const s = await started(answers);
  try {
    await run(s.core.inner.data.written);
    const link = s.core.inner.stations.link(ST)!;
    assert.equal(link.sharedChangesRefused, null);

    // 1. 403 Forbidden: must NOT degrade to whole GET /chats?shared=1 and must NOT set sharedChangesRefused.
    let mode: "403" | "413" | "404" | "ok" = "403";
    stationReplies(s.host, (req) => {
      if (req.method === "POST" && req.url.endsWith("/admin/api/changed/shared")) {
        if (mode === "403") return status(403, { error: "forbidden" });
        if (mode === "413") return status(413, { error: "too large" });
        if (mode === "404") return status(404, { error: "no route POST /changed/shared" });
      }
      return undefined;
    });

    const reqsSince = (n: number) => s.host.requests.slice(n).map((r) => `${r.method} ${r.url.replace("https://stillfail.test/admin/api", "")}`);
    let mark = s.host.requests.length;
    s.core.inner.stations.snapshot(ST);
    await s.host.time.pass(1_000, 50);
    let reqs = reqsSince(mark);
    assert.ok(reqs.includes("POST /changed/shared"));
    assert.ok(!reqs.includes("GET /chats?shared=1"), "403 must never degrade to whole GET /chats?shared=1");
    assert.equal(link.sharedChangesRefused, null);

    // 2. 413 Payload Too Large: falls back to single whole GET /chats?shared=1, does NOT set sharedChangesRefused.
    mode = "413";
    mark = s.host.requests.length;
    s.core.inner.stations.snapshot(ST);
    await s.host.time.pass(1_000, 50);
    reqs = reqsSince(mark);
    assert.ok(reqs.includes("POST /changed/shared"));
    assert.ok(reqs.includes("GET /chats?shared=1"), "413 must fall back to single whole GET /chats?shared=1");
    assert.equal(link.sharedChangesRefused, null, "413 must NOT set sharedChangesRefused");

    // 3. 404 "no route ": sets sharedChangesRefused independently of changesRefused; next snapshot skips POST /changed/shared.
    mode = "404";
    mark = s.host.requests.length;
    s.core.inner.stations.snapshot(ST);
    await s.host.time.pass(1_000, 50);
    reqs = reqsSince(mark);
    assert.ok(reqs.includes("POST /changed/shared"));
    assert.ok(reqs.includes("GET /chats?shared=1"));
    assert.notEqual(link.sharedChangesRefused, null);
    assert.equal(link.changesRefused, null, "sharedChangesRefused is independent of changesRefused");

    mark = s.host.requests.length;
    s.core.inner.stations.snapshot(ST);
    await s.host.time.pass(1_000, 50);
    reqs = reqsSince(mark);
    assert.ok(!reqs.includes("POST /changed/shared"), "subsequent snapshot skips POST /changed/shared while refused");
    assert.ok(reqs.includes("GET /chats?shared=1"));
  } finally {
    s.core.close();
  }
});

test("identity change (selves) discards sidecar baseline and fetches whole GET /chats?shared=1", async () => {
  const r1 = sharedRow("k1", 10, { title: "Mine via Slack", mineOf: [{ id: "slack:U1", via: "slack" }] });
  const answers: Record<string, unknown> = {
    ...base(),
    "GET /chats?marks=1": { ...MARKS, selves: [] },
    "GET /chats?shared=1": [r1],
  };
  const s = await started(answers);
  let cold: Core | undefined;
  try {
    await run(s.core.inner.data.written);
    const beforeRows = s.core.inner.data.get({ topic: "chatRows", station: ST }) as J[];
    assert.equal(beforeRows[0].mine, false);

    // Cold start where viewer's Slack selves now include U1 -> must discard baseline and fetch whole GET /chats?shared=1.
    answers["GET /chats?marks=1"] = { ...MARKS, selves: ["U1"] };
    s.core.close();
    await s.host.settle();
    const mark = s.host.requests.length;
    cold = await Core.create(s.host, { clock: s.host.time.clock, sample: 0, wire: () => new HostWire(s.host) });
    await s.host.time.pass(1_000, 50);
    await run(cold.inner.data.written);

    const reqs = s.host.requests.slice(mark).map((r) => `${r.method} ${r.url.replace("https://stillfail.test/admin/api", "")}`);
    assert.ok(reqs.includes("GET /chats?shared=1"), `selves change must trigger whole GET /chats?shared=1: ${JSON.stringify(reqs)}`);
    const afterRows = cold.inner.data.get({ topic: "chatRows", station: ST }) as J[];
    assert.equal(afterRows[0].mine, true);
  } finally {
    cold?.close();
    s.core.close();
  }
});

test("concurrent chat-shared and chat-shared-removed events replay over POST /changed/shared delta answer", async () => {
  const r1 = sharedRow("k1", 10, { title: "One" });
  const r2 = sharedRow("k2", 11, { title: "Two" });
  const answers: Record<string, unknown> = {
    ...base(),
    "GET /chats?marks=1": { ...MARKS },
    "GET /chats?shared=1": [r1, r2],
  };
  const s = await started(answers);
  try {
    await run(s.core.inner.data.written);
    const release = s.host.hold("/admin/api/changed/shared");
    s.core.inner.stations.snapshot(ST);
    await s.host.settle();
    // While POST /changed/shared is in flight, stream delivers newer r1 and removes r2.
    const r1New = sharedRow("k1", 10, { title: "One Live" });
    Queue.offerUnsafe(s.streams.at(-1)!.queue, new TextEncoder().encode(
      `event: chat-shared\ndata: ${JSON.stringify(r1New)}\n\nevent: chat-shared-removed\ndata: ${JSON.stringify({ id: "k2" })}\n\n`,
    ));
    await s.host.settle();
    release();
    await s.host.time.pass(1_000, 50);
    await run(s.core.inner.data.written);

    const rows = s.core.inner.data.get({ topic: "chatRows", station: ST }) as J[];
    assert.deepEqual(rows.map((r) => [r.id, r.title]), [["k1", "One Live"]]);
    assert.equal(s.core.inner.data.of(ST)!.sharedDigests(ST).get("k1"), digest(r1New));
    assert.equal(s.core.inner.data.of(ST)!.sharedDigests(ST).has("k2"), false);
  } finally {
    s.core.close();
  }
});

test("crash atomicity: rolling back a write transaction keeps chat, shared_sidecar, and shared_meta consistent", async () => {
  const r1 = sharedRow("k1", 10, { title: "One" });
  const answers: Record<string, unknown> = {
    ...base(),
    "GET /chats?marks=1": { ...MARKS },
    "GET /chats?shared=1": [r1],
  };
  const s = await started(answers);
  try {
    await run(s.core.inner.data.written);
    const db = s.core.inner.data.of(ST)!;
    const beforeDigest = db.sharedDigests(ST).get("k1");
    assert.equal(beforeDigest, digest(r1));

    // Inject a failure on shared_meta write inside the same transaction -> entire burst rolls back atomically.
    const origRun = db.sql.run.bind(db.sql);
    db.sql.run = (sql, params) => {
      if (sql.includes("INSERT OR REPLACE INTO shared_meta")) throw new SqlError("disk full", "full");
      return origRun(sql, params);
    };
    const r2 = sharedRow("k2", 11, { title: "Two" });
    db.applySharedChanged(
      ST,
      [{ row: rowFor(r2, new OwnHeld(MARKS, "a@x"), rowWords()), place: -1000, sidecar: sidecarOf(r2, digest(r2)) }],
      ["k1"],
      false,
      (row) => ({ row, place: sharedPlace(row) }),
      new OwnHeld({ ...MARKS, pins: { k2: 99 } }, "a@x"),
      Date.now(),
      { me: "a@x", selves: [], lang: "zh", hiddenKnown: true, mutedKnown: true, noRouteBuild: null },
    );
    await run(db.written);
    db.sql.run = origRun;

    // Neither chat nor shared_sidecar nor shared_meta nor shared_mark was partially modified.
    assert.equal(db.chat(ST, "k1")?.title, "One");
    assert.equal(db.chat(ST, "k2"), undefined);
    assert.equal(db.sharedDigests(ST).get("k1"), beforeDigest);
    assert.equal(db.sharedDigests(ST).has("k2"), false);
    assert.equal(db.sql.all("SELECT * FROM shared_mark WHERE station = ? AND k = 'k2'", [ST]).length, 0);
  } finally {
    s.core.close();
  }
});

test("interleaving: delta arriving before marks with changed selves waits and never publishes old Slack identity", async () => {
  const r1 = sharedRow("k1", 10, { title: "Slack Row", mineOf: [{ id: "slack:U1", via: "slack" }] });
  const r2 = sharedRow("k2", 11, { title: "New Row", mineOf: [{ id: "slack:U1", via: "slack" }] });
  const answers: Record<string, unknown> = {
    ...base(),
    "GET /chats?marks=1": { ...MARKS, selves: [] },
    "GET /chats?shared=1": [r1],
  };
  const s = await started(answers);
  try {
    await run(s.core.inner.data.written);
    assert.equal((s.core.inner.data.get({ topic: "chatRows", station: ST }) as J[])[0].mine, false);

    // Next snapshot: marks now has selves=["U1"], and shared adds r2. Hold marks so POST /changed/shared finishes FIRST.
    answers["GET /chats?marks=1"] = { ...MARKS, selves: ["U1"] };
    answers["GET /chats?shared=1"] = [r1, r2];
    const releaseMarks = s.host.hold("/admin/api/chats?marks=1&own=1");
    const mark = s.host.requests.length;
    s.core.inner.stations.snapshot(ST);
    await s.host.time.pass(200, 50);
    await run(s.core.inner.data.written);

    // While marks is still held, POST /changed/shared has returned, but r2 MUST NOT be published under old selves=[]!
    const midReqs = s.host.requests.slice(mark).map((r) => `${r.method} ${r.url.replace("https://stillfail.test/admin/api", "")}`);
    assert.ok(midReqs.includes("POST /changed/shared"), `delta finished while marks held: ${JSON.stringify(midReqs)}`);
    const midRows = s.core.inner.data.get({ topic: "chatRows", station: ST }) as J[];
    assert.deepEqual(midRows.map((r) => [r.id, r.mine]), [["k1", false]], "must not publish delta under unconfirmed old selves");

    // Release marks -> detects selves changed -> discards delta & baseline, fetches whole GET /chats?shared=1, publishes mine=true!
    releaseMarks();
    await s.host.time.pass(1_000, 50);
    await run(s.core.inner.data.written);
    const afterReqs = s.host.requests.slice(mark).map((r) => `${r.method} ${r.url.replace("https://stillfail.test/admin/api", "")}`);
    assert.ok(afterReqs.includes("GET /chats?shared=1"), `selves mismatch must refetch whole: ${JSON.stringify(afterReqs)}`);
    const afterRows = s.core.inner.data.get({ topic: "chatRows", station: ST }) as J[];
    assert.deepEqual(afterRows.map((r) => [r.id, r.mine]).sort(), [["k1", true], ["k2", true]]);
  } finally {
    s.core.close();
  }
});

test("interleaving: marks arriving before in-flight delta with changed selves discards delta and refetches whole", async () => {
  const r1 = sharedRow("k1", 10, { title: "Slack Row", mineOf: [{ id: "slack:U1", via: "slack" }] });
  const answers: Record<string, unknown> = {
    ...base(),
    "GET /chats?marks=1": { ...MARKS, selves: [] },
    "GET /chats?shared=1": [r1],
  };
  const s = await started(answers);
  try {
    await run(s.core.inner.data.written);
    answers["GET /chats?marks=1"] = { ...MARKS, selves: ["U1"] };
    const releaseDelta = s.host.hold("/admin/api/changed/shared");
    const mark = s.host.requests.length;
    s.core.inner.stations.snapshot(ST);
    await s.host.time.pass(200, 50);
    // marks already arrived with selves=["U1"]; now release the in-flight delta.
    releaseDelta();
    await s.host.time.pass(1_000, 50);
    await run(s.core.inner.data.written);
    const reqs = s.host.requests.slice(mark).map((r) => `${r.method} ${r.url.replace("https://stillfail.test/admin/api", "")}`);
    assert.ok(reqs.includes("GET /chats?shared=1"), `in-flight delta must be discarded when marks already changed selves: ${JSON.stringify(reqs)}`);
    assert.equal((s.core.inner.data.get({ topic: "chatRows", station: ST }) as J[])[0].mine, true);
  } finally {
    s.core.close();
  }
});

test("interleaving: late POST /changed/shared arriving after station disconnect / workspace removal is discarded", async () => {
  const r1 = sharedRow("k1", 10, { title: "One" });
  const r2 = sharedRow("k2", 11, { title: "Late" });
  const answers: Record<string, unknown> = {
    ...base(),
    "GET /chats?marks=1": { ...MARKS },
    "GET /chats?shared=1": [r1],
  };
  const s = await started(answers);
  try {
    await run(s.core.inner.data.written);
    answers["GET /chats?shared=1"] = [r1, r2];
    const releaseDelta = s.host.hold("/admin/api/changed/shared");
    s.core.inner.stations.snapshot(ST);
    await s.host.settle();
    // Drop the workspace (simulating disconnect / workspace switch away) while POST /changed/shared is in flight.
    s.core.inner.data.dropWorkspace("ws");
    s.core.inner.stations.reconcile();
    await run(s.core.inner.data.written);
    releaseDelta();
    await s.host.time.pass(500, 50);
    await run(s.core.inner.data.written);
    // Late delta must not have written r2 or resurrected sidecar/meta.
    assert.equal(s.core.inner.stations.link(ST), undefined);
    assert.equal(s.core.inner.data.chat(ST, "k2"), undefined);
  } finally {
    s.core.close();
  }
});

test("keyed mark diff: quiet cold start reads 0 chat rows, and 1 mark change re-projects only that 1 row by index", async () => {
  const rows = Array.from({ length: 12 }, (_, i) => sharedRow(`k${i}`, 100 + i, { title: `Chat ${i}`, lastSeq: 5, lastActiveAt: 1000 + i }));
  const answers: Record<string, unknown> = {
    ...base(),
    "GET /chats?marks=1": { ...MARKS, reads: Object.fromEntries(rows.map((_, i) => [String(100 + i), 1])) },
    "GET /chats?shared=1": rows,
  };
  const s = await started(answers);
  let cold1: Core | undefined;
  let cold2: Core | undefined;
  try {
    // Perform a single-row read event before closing to verify single-row mark updates keep shared_mark in sync.
    Queue.offerUnsafe(s.streams.at(-1)!.queue, new TextEncoder().encode(`event: read\ndata: ${JSON.stringify({ thread: 100, n: 5 })}\n\n`));
    await s.host.settle();
    await run(s.core.inner.data.written);
    answers["GET /chats?marks=1"] = { ...MARKS, reads: { ...Object.fromEntries(rows.map((_, i) => [String(100 + i), 1])), "100": 5 } };
    s.core.close();
    await s.host.settle();

    // Cold start #1: 0 changed shared rows, 0 mark diffs -> ZERO chat rows re-projected!
    work.rowJson = 0;
    work.chatRowsMade = 0;
    cold1 = await Core.create(s.host, { clock: s.host.time.clock, sample: 0, wire: () => new HostWire(s.host) });
    await s.host.time.pass(1_000, 50);
    await run(cold1.inner.data.written);
    const quietRowJson = work.rowJson;
    assert.equal(work.chatRowsMade, 0, "quiet cold start must re-project 0 chat rows");
    cold1.close();
    await s.host.settle();

    // Cold start #2: only thread 103's read mark changed while offline -> ONLY 1 extra row read & 1 chat row re-projected!
    answers["GET /chats?marks=1"] = { ...MARKS, reads: { ...Object.fromEntries(rows.map((_, i) => [String(100 + i), 1])), "100": 5, "103": 5 } };
    work.rowJson = 0;
    work.chatRowsMade = 0;
    cold2 = await Core.create(s.host, { clock: s.host.time.clock, sample: 0, wire: () => new HostWire(s.host) });
    await s.host.time.pass(1_000, 50);
    await run(cold2.inner.data.written);
    assert.equal(work.rowJson - quietRowJson, 1, "1 changed mark must read only 1 chat row by index");
    assert.equal(work.chatRowsMade, 1, "1 changed mark must re-project only 1 chat row");
    assert.equal((cold2.inner.data.chat(ST, "k3") as J)?.unread, false);
    assert.equal((cold2.inner.data.chat(ST, "k4") as J)?.unread, true);
  } finally {
    cold2?.close();
    cold1?.close();
    s.core.close();
  }
});

test("marks 503 retries with backoff and unlocks staged delta + concurrent events; 403 never reuses old identity", async () => {
  const r1 = sharedRow("k1", 10, { title: "One", mineOf: [{ id: "slack:U1", via: "slack" }] });
  const r2 = sharedRow("k2", 11, { title: "Two" });
  const answers: Record<string, unknown> = {
    ...base(),
    "GET /chats?marks=1": { ...MARKS, selves: [] },
    "GET /chats?shared=1": [r1],
  };
  const s = await started(answers);
  try {
    await run(s.core.inner.data.written);
    // 1. 503 once on marks=1&own=1, then succeeds on retry; meanwhile delta and live chat-shared arrive.
    let marksMode: "503" | "403" | "ok" = "503";
    stationReplies(s.host, (req) => {
      if (req.method === "GET" && req.url.includes("/admin/api/chats?marks=1")) {
        if (marksMode === "503") { marksMode = "ok"; return status(503, { error: "busy" }); }
        if (marksMode === "403") return status(403, { error: "revoked" });
      }
      return undefined;
    });
    answers["GET /chats?shared=1"] = [r1, r2];
    s.core.inner.stations.snapshot(ST);
    await s.host.time.pass(500, 50);
    // Live event arrives while marks is waiting to retry.
    const r2Live = sharedRow("k2", 11, { title: "Two Live" });
    Queue.offerUnsafe(s.streams.at(-1)!.queue, new TextEncoder().encode(`event: chat-shared\ndata: ${JSON.stringify(r2Live)}\n\n`));
    // Advance past READ_RETRY_MS (2000ms) -> marks retry succeeds, unlocks marksPending, publishes r2Live!
    await s.host.time.pass(3_000, 100);
    await run(s.core.inner.data.written);
    assert.equal((s.core.inner.data.chat(ST, "k2") as J)?.title, "Two Live");

    // 2. 403 on marks=1&own=1: must discard staged delta and NEVER publish under old identity.
    marksMode = "403";
    const r3 = sharedRow("k3", 12, { title: "Secret" });
    answers["GET /chats?shared=1"] = [r1, r2Live, r3];
    s.core.inner.stations.snapshot(ST);
    await s.host.time.pass(5_000, 100);
    await run(s.core.inner.data.written);
    assert.equal(s.core.inner.data.chat(ST, "k3"), undefined, "403 marks must not commit staged delta under old identity");
  } finally {
    s.core.close();
  }
});

test("build-keyed no-route cache skips POST /changed/shared on same old build and re-probes after station upgrade", async () => {
  const r1 = sharedRow("k1", 10, { title: "One" });
  const answers: Record<string, unknown> = {
    ...base(),
    "GET /chats?marks=1": { ...MARKS },
    "GET /chats?shared=1": [r1],
  };
  const s = await started(answers);
  let coldSame: Core | undefined;
  let coldUpgraded: Core | undefined;
  try {
    // Old station build 0.1.9000 returns 404 "no route POST /changed/shared".
    s.gate.build = "0.1.9000";
    s.changes.on = false;
    await run(s.core.inner.data.written);
    s.core.inner.stations.link(ST)!.build = "0.1.9000";
    s.core.inner.stations.snapshot(ST);
    await s.host.time.pass(500, 50);
    await run(s.core.inner.data.written);
    assert.equal(s.core.inner.data.sharedMeta(ST)?.noRouteBuild, "0.1.9000");

    // Cold start against the SAME build 0.1.9000 -> skips POST /changed/shared directly!
    s.core.close();
    await s.host.settle();
    let mark = s.host.requests.length;
    coldSame = await Core.create(s.host, { clock: s.host.time.clock, sample: 0, wire: () => new HostWire(s.host) });
    await s.host.time.pass(1_000, 50);
    await run(coldSame.inner.data.written);
    const sameReqs = s.host.requests.slice(mark).map((r) => `${r.method} ${r.url.replace("https://stillfail.test/admin/api", "")}`);
    assert.ok(!sameReqs.includes("POST /changed/shared"), `same old build must skip POST /changed/shared: ${JSON.stringify(sameReqs)}`);
    assert.ok(sameReqs.includes("GET /chats?shared=1"));
    coldSame.close();
    await s.host.settle();

    // Station upgrades to 0.1.9999 with POST /changed/shared enabled -> re-probes and succeeds!
    s.gate.build = "0.1.9999";
    s.changes.on = true;
    mark = s.host.requests.length;
    coldUpgraded = await Core.create(s.host, { clock: s.host.time.clock, sample: 0, wire: () => new HostWire(s.host) });
    await s.host.time.pass(1_000, 50);
    await run(coldUpgraded.inner.data.written);
    const upgReqs = s.host.requests.slice(mark).map((r) => `${r.method} ${r.url.replace("https://stillfail.test/admin/api", "")}`);
    assert.ok(upgReqs.includes("POST /changed/shared"), `upgraded build must re-probe POST /changed/shared: ${JSON.stringify(upgReqs)}`);
    assert.equal(coldUpgraded.inner.data.sharedMeta(ST)?.noRouteBuild, null);
  } finally {
    coldUpgraded?.close();
    coldSame?.close();
    s.core.close();
  }
});

test("controlled interleavings: marks->read->delta, whole marks vs queued write, and interrupted transaction reopen all match station unread", async () => {
  const rows = [
    sharedRow("k1", 10, { title: "One", lastSeq: 5, lastActiveAt: 2000 }),
    sharedRow("k2", 11, { title: "Two", lastSeq: 5, lastActiveAt: 1000 }),
  ];
  const answers: Record<string, unknown> = {
    ...base(),
    "GET /chats?marks=1": { ...MARKS, reads: { "10": 1, "11": 1 } },
    "GET /chats?shared=1": rows,
  };
  const s = await started(answers);
  let cold1: Core | undefined;
  let cold2: Core | undefined;
  let cold3: Core | undefined;
  try {
    assert.equal((s.core.inner.data.chat(ST, "k1") as J)?.unread, true);
    assert.equal((s.core.inner.data.chat(ST, "k2") as J)?.unread, true);

    // 1. Controlled interleaving: marks arrives first -> read event arrives -> POST /changed/shared delta (0 changed rows) arrives.
    s.core.close();
    await s.host.settle();
    let releaseDelta: (() => void) | undefined;
    stationLater(s.host, (req) => {
      if (req.url.endsWith("/changed/shared")) {
        return new Promise((resolve) => {
          releaseDelta = () => resolve(jsonResponse(200, { order: ["k1", "k2"], rows: [] }));
        });
      }
      return undefined;
    });
    cold1 = await Core.create(s.host, { clock: s.host.time.clock, sample: 0, wire: () => new HostWire(s.host) });
    await s.host.time.pass(300, 50);
    assert.ok(releaseDelta, "POST /changed/shared should be held while marks already arrived");
    // Read event for thread 10 arrives BEFORE delta resolves!
    Queue.offerUnsafe(s.streams.at(-1)!.queue, new TextEncoder().encode(`event: read\ndata: ${JSON.stringify({ thread: 10, n: 5 })}\n\n`));
    await s.host.settle();
    releaseDelta();
    await s.host.time.pass(500, 50);
    await run(cold1.inner.data.written);
    assert.equal((cold1.inner.data.chat(ST, "k1") as J)?.unread, false, "marks->read->delta must merge rowsWanted and mark k1 read");
    assert.equal((cold1.inner.data.chat(ST, "k2") as J)?.unread, true);

    // 2. Controlled interleaving: whole marks in-flight while a read event for thread 11 arrives.
    let releaseWholeMarks: (() => void) | undefined;
    let heldWhole = false;
    stationLater(s.host, (req) => {
      if (!heldWhole && req.url.endsWith("/chats?marks=1&own=1")) {
        heldWhole = true;
        return new Promise((resolve) => {
          releaseWholeMarks = () => resolve(jsonResponse(200, { ...MARKS, reads: { "10": 5, "11": 1 } }));
        });
      }
      return undefined;
    });
    cold1.inner.stations.snapshot(ST);
    await s.host.time.pass(200, 50);
    assert.ok(releaseWholeMarks, "whole marks should be held");
    Queue.offerUnsafe(s.streams.at(-1)!.queue, new TextEncoder().encode(`event: read\ndata: ${JSON.stringify({ thread: 11, n: 5 })}\n\n`));
    await s.host.settle();
    releaseWholeMarks();
    await s.host.time.pass(500, 50);
    await run(cold1.inner.data.written);
    assert.equal((cold1.inner.data.chat(ST, "k2") as J)?.unread, false, "whole marks + concurrent read event must keep k2 read");

    // 3. Interrupted transaction reopen: station marks thread 10 read=5 & 11 read=5, but reset baseline to unread=true
    //    and abort the single-row putSharedBatch write on read event so neither chat nor shared_mark commits; on reopen,
    //    diffAndSyncMarks must still see the diff and update sidebar unread to false matching station!
    answers["GET /chats?marks=1"] = { ...MARKS, reads: { "10": 1, "11": 1 } };
    cold1.close();
    await s.host.settle();
    cold2 = await Core.create(s.host, { clock: s.host.time.clock, sample: 0, wire: () => new HostWire(s.host) });
    await s.host.time.pass(800, 50);
    await run(cold2.inner.data.written);
    assert.equal((cold2.inner.data.chat(ST, "k1") as J)?.unread, true);
    // Simulate an interrupted write: station now has read=5 for thread 10, but client's local single-row commit aborts.
    answers["GET /chats?marks=1"] = { ...MARKS, reads: { "10": 5, "11": 1 } };
    const origPutBatch = cold2.inner.data.putSharedBatch.bind(cold2.inner.data);
    cold2.inner.data.putSharedBatch = () => { throw new Error("simulated crash before commit"); };
    try {
      Queue.offerUnsafe(s.streams.at(-1)!.queue, new TextEncoder().encode(`event: read\ndata: ${JSON.stringify({ thread: 10, n: 5 })}\n\n`));
      await s.host.time.pass(300, 50);
    } catch {
      // expected simulated crash
    } finally {
      cold2.inner.data.putSharedBatch = origPutBatch;
    }
    // Reopen fresh Core against the same SQLite DB: shared_mark must NOT have advanced ahead of chat!
    cold2.close();
    await s.host.settle();
    cold3 = await Core.create(s.host, { clock: s.host.time.clock, sample: 0, wire: () => new HostWire(s.host) });
    await s.host.time.pass(800, 50);
    await run(cold3.inner.data.written);
    assert.equal((cold3.inner.data.chat(ST, "k1") as J)?.unread, false, "reopen after interrupted tx must re-project k1 to match station");
    assert.equal((cold3.inner.data.chat(ST, "k2") as J)?.unread, true);
  } finally {
    cold3?.close();
    cold2?.close();
    cold1?.close();
    s.core.close();
  }
});
