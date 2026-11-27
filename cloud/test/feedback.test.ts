import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { exportJWK, generateKeyPair, SignJWT } from "jose";
import { harness } from "./harness.ts";

type Harness = Awaited<ReturnType<typeof harness>>;
const hex = (bytes: ArrayBuffer) => Buffer.from(bytes).toString("hex");

async function key() {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const id = hex((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
  const sign = async (message: string) => hex(await crypto.subtle.sign("Ed25519", pair.privateKey, new TextEncoder().encode(message)));
  return { id, sign };
}
type Station = Awaited<ReturnType<typeof key>>;

/** Alice's workspace with a station in it. */
async function workspace(h: Harness) {
  const aliceTokens = await h.login("alice");
  const alice = h.as(aliceTokens);
  const id = ((await (await alice("POST", "/v1/workspaces", { name: "Home" })).json()) as any).id as string;
  const enrollment = (await (await alice("POST", `/v1/workspaces/${id}/enrollments`, { name: "willow" })).json()) as any;
  const station = await key();
  const response = await h.fetch("/v1/stations/enroll", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ token: enrollment.token, station: station.id, signature: await station.sign(`stillfail-station-enroll-v1:${h.origin}:${enrollment.token}:${station.id}`) }),
  });
  assert.equal(response.status, 200);
  return { id, station, aliceTokens };
}

/** Sends a report as the station, signed (with another tag, or as the test channel, when a test says). */
async function send(h: Harness, station: Station, report: unknown, options: { tag?: string; channel?: string; path?: string } = {}) {
  const body = JSON.stringify(report);
  const ts = h.now();
  const digest = createHash("sha256").update(body).digest("hex");
  const headers: Record<string, string> = {
    "content-type": "application/json",
    "x-stillfail-station": station.id,
    "x-stillfail-ts": String(ts),
    "x-stillfail-signature": await station.sign(`${options.tag ?? "stillfail-station-feedback-v1"}:${h.origin}:${station.id}:${ts}:${digest}`),
  };
  if (options.channel) headers["x-stillfail-channel"] = options.channel;
  return h.fetch(options.path ?? "/v1/feedback", { method: "POST", headers, body });
}

/** Asks which of the station's reports are fixed and out, saying those it told of. */
async function fixed(h: Harness, station: Station, told: string[] = []) {
  const response = await send(h, station, { told }, { path: "/v1/feedback/fixed", tag: "stillfail-station-feedback-fixed-v1" });
  assert.equal(response.status, 200);
  return ((await response.json()) as any).fixed as any[];
}

const report = (extra: Record<string, unknown> = {}) => ({
  key: "k1",
  title: "chat_post 发不出去",
  body: "chat_post 回了 500，消息没出现在 thread 里。",
  area: "station",
  reporter: "Ada, Slack #ops",
  context: { version: "0.1.1309", session: "chat:c-1", runtime: "claude" },
  logs: "ERROR chat_post: 500",
  ...extra,
});

test("a station's report is kept once, numbered, and listed in the console with where it came from", async () => {
  const h = await harness();
  try {
    const { id, station, aliceTokens } = await workspace(h);
    const first = await send(h, station, report());
    assert.equal(first.status, 201);
    const made = (await first.json()) as any;
    assert.equal(made.number, 1);
    assert.equal(made.duplicate, false);
    // Sent again (a retry): the same one.
    const again = await send(h, station, report());
    assert.equal(again.status, 200);
    assert.deepEqual(await again.json(), { ...made, duplicate: true });
    assert.equal(((await (await send(h, station, report({ key: "k2", area: "nonsense" }), { channel: "beta" })).json()) as any).number, 2);

    const admin = h.as(aliceTokens, "admin");
    const listed = (await (await admin("GET", "/v1/admin/feedback")).json()) as any;
    assert.deepEqual(listed.feedback.map((f: any) => [f.number, f.channel, f.area]), [[2, "beta", "unknown"], [1, "stable", "station"]]);
    const one = listed.feedback[1];
    assert.deepEqual(one.station, { id: station.id, name: "willow" });
    assert.deepEqual(one.workspace, { id, name: "Home" });
    assert.equal(one.account, null);
    assert.equal(one.title, "chat_post 发不出去");
    assert.equal(one.reporter, "Ada, Slack #ops");
    assert.deepEqual(one.context, report().context);
    // The console's list carries no logs, only whether there are any; the report's own read has them.
    assert.deepEqual([one.logs, one.has_logs, listed.feedback[0].has_logs], [null, true, true]);
    assert.equal(one.status, "new");
    const whole = (await (await admin("GET", `/v1/admin/feedback/${one.id}`)).json()) as any;
    assert.deepEqual([whole.item.id, whole.item.logs, whole.item.has_logs], [one.id, "ERROR chat_post: 500", true]);

    assert.equal((await admin("POST", `/v1/admin/feedback/${one.id}/status`, { status: "fixed" })).status, 200);
    assert.equal((await admin("POST", `/v1/admin/feedback/${one.id}/status`, { status: "gone" })).status, 400);
    assert.equal((await admin("POST", `/v1/admin/feedback/${"0".repeat(26)}/status`, { status: "fixed" })).status, 404);
    const after = (await (await admin("GET", "/v1/admin/feedback")).json()) as any;
    assert.equal(after.feedback[1].status, "fixed");
  } finally {
    await h.close();
  }
});

test("the feedback monitor reads the console's list with its token, and that token does nothing else", async () => {
  const h = await harness();
  try {
    const { station } = await workspace(h);
    assert.equal((await send(h, station, report())).status, 201);
    const list = (token: string, path = "/v1/admin/feedback/list") => h.fetch(path, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: "{}" });
    const listed = (await (await list(h.feedbackToken)).json()) as any;
    assert.deepEqual(listed.feedback.map((f: any) => [f.number, f.title, f.station?.name]), [[1, "chat_post 发不出去", "willow"]]);
    assert.equal((await list(h.adminToken)).status, 401, "not the admin token");
    assert.equal((await list("x".repeat(43))).status, 401);
    assert.equal((await list(h.feedbackToken, "/v1/admin/workspaces/list")).status, 401, "nothing else");
  } finally {
    await h.close();
  }
});

test("the feedback monitor marks where a report is with its token, as the console does", async () => {
  const h = await harness();
  try {
    const { station, aliceTokens } = await workspace(h);
    assert.equal((await send(h, station, report())).status, 201);
    const admin = h.as(aliceTokens, "admin");
    const id = ((await (await admin("GET", "/v1/admin/feedback")).json()) as any).feedback[0].id as string;
    const mark = (token: string, status: unknown, which = id) =>
      h.fetch(`/v1/admin/feedback/${which}/status`, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify({ status }) });
    const now = async () => ((await (await admin("GET", "/v1/admin/feedback")).json()) as any).feedback[0].status;

    assert.equal((await mark(h.feedbackToken, "triaged")).status, 200);
    assert.equal(await now(), "triaged");
    assert.equal((await mark(h.feedbackToken, "gone")).status, 400);
    assert.equal((await mark(h.feedbackToken, undefined)).status, 400);
    assert.equal((await mark(h.feedbackToken, "fixed", "0".repeat(26))).status, 404);
    assert.equal(await now(), "triaged");

    // Not the admin token's, nor a made-up one's: they fall to the console's sign-in, which they are not.
    assert.notEqual((await mark(h.adminToken, "wontfix")).status, 200, "not the admin token");
    assert.notEqual((await mark("x".repeat(43), "wontfix")).status, 200);
    assert.equal(await now(), "triaged");

    // The console's admin marks it as before.
    assert.equal((await admin("POST", `/v1/admin/feedback/${id}/status`, { status: "wontfix" })).status, 200);
    assert.equal(await now(), "wontfix");
  } finally {
    await h.close();
  }
});

test("reports signed wrong, not signed, by a station not enrolled, or without a title are refused", async () => {
  const h = await harness();
  try {
    const { station } = await workspace(h);
    assert.equal((await send(h, station, report(), { tag: "stillfail-station-notify-v1" })).status, 401, "a notice's signature");
    assert.equal((await send(h, await key(), report())).status, 401, "not enrolled");
    assert.equal((await h.fetch("/v1/feedback", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(report()) })).status, 401, "not signed");
    assert.equal((await send(h, station, report({ title: " " }))).status, 400);
    assert.equal((await send(h, station, report({ key: "no spaces allowed" }))).status, 400);
  } finally {
    await h.close();
  }
});

test("a signed-in account may report too; the console's list is the admin's only", async () => {
  const h = await harness();
  try {
    const bobTokens = await h.login("bob");
    const bob = h.as(bobTokens);
    assert.equal((await bob("POST", "/v1/feedback", report())).status, 201);
    assert.equal((await h.as(bobTokens, "admin")("GET", "/v1/admin/feedback")).status, 404, "not the admin");
    const alice = h.as(await h.login("alice"), "admin");
    const listed = (await (await alice("GET", "/v1/admin/feedback")).json()) as any;
    assert.equal(listed.feedback[0].account.email, "bob@example.test");
    assert.equal(listed.feedback[0].station, null);
  } finally {
    await h.close();
  }
});

test("a sender may send twenty reports a day", async () => {
  const h = await harness();
  try {
    const { station } = await workspace(h);
    for (let i = 0; i < 20; i++) assert.equal((await send(h, station, report({ key: `k${i}` }))).status, 201);
    assert.equal((await send(h, station, report({ key: "k20" }))).status, 429);
  } finally {
    await h.close();
  }
});

test("a report the changelog fixes is marked fixed, and its station told once the fix is out on its channel", async () => {
  const h = await harness();
  try {
    const { station, aliceTokens } = await workspace(h);
    await send(h, station, report({ context: { session: "chat:c-1", thread: "CHAT/1.1" } }));
    await send(h, station, report({ key: "k2", title: "安卓列表跳动" }));
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    // Nothing in the changelog yet: nothing fixed.
    assert.deepEqual(await fixed(h, station), []);
    await bucket.put("changelog.json", JSON.stringify([
      { version: 1340, commit: "b", at: 2, text: ["修复：安卓列表跳动"], fixes: [2], parts: ["android"] },
      { version: 1330, commit: "a", at: 1, text: ["修复：chat_post 发不出去"], fixes: [1], parts: ["station"] },
    ]));
    // Fixed, but no station release has it yet.
    assert.deepEqual(await fixed(h, station), []);
    const admin = h.as(aliceTokens, "admin");
    const listed = (await (await admin("GET", "/v1/admin/feedback")).json()) as any;
    assert.deepEqual(listed.feedback.map((f: any) => [f.number, f.status, f.fixed_in]), [[2, "fixed", 1340], [1, "fixed", 1330]]);

    await bucket.put("station.json", JSON.stringify({ version: "0.1.1335", build: 1335 }));
    await bucket.put("android/latest.json", JSON.stringify({ versionCode: 1339 }));
    const out = await fixed(h, station);
    assert.equal(out.length, 1);
    assert.equal(out[0].number, 1);
    assert.equal(out[0].version, 1330);
    assert.deepEqual(out[0].parts, ["station"]);
    assert.equal(out[0].released.station, 1335);
    assert.equal(out[0].session, "chat:c-1");
    assert.equal(out[0].thread, "CHAT/1.1");
    // Told: not again.
    assert.deepEqual(await fixed(h, station, [out[0].id]), []);
    await bucket.put("android/latest.json", JSON.stringify({ versionCode: 1341 }));
    assert.deepEqual((await fixed(h, station)).map((f) => f.number), [2]);

    // Another station does not hear of them; a beta release is not the stable one's.
    assert.equal((await send(h, station, { told: [] }, { path: "/v1/feedback/fixed" })).status, 401, "a report's signature");
  } finally {
    await h.close();
  }
});

test("a cloud whose bucket holds no station release reads it upstream (RELEASES_UPSTREAM), and tells of a station's fix once it is out there", async () => {
  // monoid's cloud: its bucket has the changelog and its own apps' builds, the station's releases are still.fail's.
  const h = await harness({ upstream: (file) => (file === "station-beta.json" ? { status: 200, body: JSON.stringify({ version: "0.1.1335", build: 1335 }) } : { status: 404 }) });
  try {
    const { station } = await workspace(h);
    await send(h, station, report(), { channel: "beta" });
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([{ version: 1330, commit: "a", at: 1, text: ["修复：chat_post 发不出去"], fixes: [1], parts: ["station"] }]));
    const beta = (await (await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } })).json()) as any;
    assert.equal(beta.released.station, 1335);
    const out = await fixed(h, station);
    assert.deepEqual(out.map((f) => [f.number, f.version, f.released.station]), [[1, 1330, 1335]]);
    // Nothing upstream for the stable channel: none out there.
    assert.equal(((await (await h.fetch("/v1/changelog")).json()) as any).released.station, null);
  } finally {
    await h.close();
  }
});

test("each desktop report waits for its platform, and a legacy report for both", async () => {
  const h = await harness();
  try {
    const { station } = await workspace(h);
    for (const [key, context] of Object.entries({ win: { desktopPlatform: "windows" }, mac: { desktopPlatform: "macos" }, old: { os: "windows" } })) {
      assert.equal((await send(h, station, report({ key, area: "desktop", context }))).status, 201);
    }
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([{ version: 1330, commit: "a", at: 1, text: ["fix"], fixes: [1, 2, 3], parts: ["desktop"] }]));
    await bucket.put("win/latest.json", JSON.stringify({ versionCode: 1335 }));
    await bucket.put("mac/latest.json", JSON.stringify({ versionCode: 1329 }));
    const first = await fixed(h, station);
    assert.deepEqual(first.map((f) => [f.number, f.released.desktop]), [[1, 1335]]);
    await bucket.put("mac/latest.json", JSON.stringify({ versionCode: 1340 }));
    const next = await fixed(h, station, [first[0].id]);
    assert.deepEqual(next.map((f) => [f.number, f.released.desktop]), [[2, 1340], [3, 1335]]);
  } finally {
    await h.close();
  }
});

test("the changelog is anyone's to read, with what each part has out on the host's channel", async () => {
  const h = await harness();
  try {
    const empty = (await (await h.fetch("/v1/changelog")).json()) as any;
    assert.deepEqual(empty, { entries: [], released: { station: null, android: null, desktop: null, macos: null, windows: null, web: null } });
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([{ version: 1340, commit: "b", at: 2, text: ["新功能：更新日志"], fixes: [], parts: ["web", "android"] }]));
    await bucket.put("web.json", JSON.stringify({ build: 1338 }));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1340 }));
    await bucket.put("mac/latest.json", JSON.stringify({ versionCode: 1300, file: "desktop/stillfail-0.1.1300-arm64-mac.zip" }));
    const stable = (await (await h.fetch("/v1/changelog")).json()) as any;
    assert.equal(stable.entries[0].text[0], "新功能：更新日志");
    assert.deepEqual(stable.released, { station: null, android: null, desktop: null, macos: 1300, windows: null, web: 1338 });
    const beta = (await (await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } })).json()) as any;
    assert.equal(beta.released.web, 1340);
  } finally {
    await h.close();
  }
});

test("a changelog whose read fails once is read again; failing twice, it is unavailable, not empty", async () => {
  const h = await harness();
  try {
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([{ version: 1340, commit: "b", at: 2, text: ["新功能：更新日志"], fixes: [], parts: ["web"] }]));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1340 }));
    const get = async () => {
      const answer = await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } });
      assert.equal(answer.status, 200);
      const { entries, released } = (await answer.json()) as any;
      return { entries: entries.length, web: released.web, cache: answer.headers.get("cache-control") };
    };
    // Six files read at once, each first read failing: each read again, the ones not there read once.
    await h.failBucket({ get: 6 });
    assert.deepEqual(await get(), { entries: 1, web: 1340, cache: "public, max-age=300" });
    assert.equal((await h.failBucket({ get: 12 })).length, 12);
    const unavailable = async (answer: Awaited<ReturnType<typeof h.fetch>>) => {
      assert.deepEqual([answer.status, answer.headers.get("retry-after"), answer.headers.get("cache-control")], [503, "5", "no-store"]);
      assert.deepEqual(await answer.json(), { error: "release_unavailable" });
    };
    await unavailable(await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } }));
    assert.equal((await h.failBucket()).length, 12);
    // Back: whole again, and what is not there is read once.
    assert.deepEqual(await get(), { entries: 1, web: 1340, cache: "public, max-age=300" });
    assert.equal((await h.failBucket({ get: 12 })).length, 6);
    // The stable channel's failing is not there being none: the test channel's is not read in its place.
    await unavailable(await h.fetch("/v1/changelog"));
    const calls = await h.failBucket();
    assert.equal(calls.filter((call) => call === "get changelog-stable.json").length, 2);
    assert.ok(!calls.includes("get changelog.json"), calls.join(", "));
  } finally {
    await h.close();
  }
  // Another cloud's releases answering a 5xx are unavailable too; its 404 is an answer.
  for (const [status, answered] of [[502, 503], [404, 200]] as const) {
    const other = await harness({ upstream: () => ({ status, body: "" }) });
    try {
      assert.equal((await other.fetch("/v1/changelog")).status, answered, `upstream ${status}`);
    } finally {
      await other.close();
    }
  }
});

/** A device's events socket; `take`: the events since the last take (h.heard). */
async function listen(h: Harness, token: string) {
  const response = await h.fetch("/v1/events", { headers: { upgrade: "websocket", "sec-websocket-protocol": `stillfail-events, stillfail-token.${token}` } });
  assert.equal(response.status, 101);
  const ws = response.webSocket!;
  ws.accept();
  const got: any[] = [];
  ws.addEventListener("message", (event) => void (event.data === "pong" || got.push(JSON.parse(event.data as string))));
  return { ws, take: async () => (await h.heard(ws), got.splice(0)) };
}

/** The station's presence socket, its frames kept (the pongs aside). */
async function connect(h: Harness, station: Station) {
  const ts = h.now();
  const signature = await station.sign(`stillfail-station-connect-v1:${h.origin}:${station.id}:${ts}`);
  const response = await h.fetch("/v1/stations/connect", {
    headers: { upgrade: "websocket", "x-stillfail-station": station.id, "x-stillfail-ts": String(ts), "x-stillfail-signature": signature, "x-stillfail-version": "0.2.0" },
  });
  assert.equal(response.status, 101);
  const ws = response.webSocket!;
  const frames: any[] = [];
  ws.addEventListener("message", (event) => void (event.data === "pong" || frames.push(JSON.parse(event.data as string))));
  ws.accept();
  return { ws, frames, ping: () => h.heard(ws) };
}

/** The station joins another workspace of `owner`'s (a token it redeems as stations do). */
async function join(h: Harness, owner: ReturnType<Harness["as"]>, workspace: string, station: Station) {
  const made = (await (await owner("POST", `/v1/workspaces/${workspace}/enrollments`, { name: "lab box" })).json()) as any;
  const response = await h.fetch("/v1/stations/join", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ token: made.token, station: station.id, signature: await station.sign(`stillfail-station-enroll-v1:${h.origin}:${made.token}:${station.id}`), version: "0.5.0" }),
  });
  assert.equal(response.status, 200);
}

/** The team replies, as the console's admin or with the feedback monitor's token. */
const teamReply = (h: Harness, id: string, text: unknown, token = h.feedbackToken) =>
  h.fetch(`/v1/admin/feedback/${id}/reply`, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify({ text }) });

/** The reporter's agent answers a report, as its station. */
const answer = (h: Harness, station: Station, value: unknown) => send(h, station, value, { path: "/v1/feedback/reply", tag: "stillfail-station-feedback-reply-v1" });

test("the team's reply is shown to the members of the chat's workspace, told on their events, and never to the station", async () => {
  const h = await harness();
  try {
    const { id: home, station, aliceTokens } = await workspace(h);
    const alice = h.as(aliceTokens);
    const carolTokens = await h.login("carol");
    await send(h, station, report({ context: { session: "chat:c-1", thread: "CHAT/1.1", workspace: home } }));
    const admin = h.as(aliceTokens, "admin");
    const listed = async () => ((await (await admin("GET", "/v1/admin/feedback")).json()) as any).feedback[0];
    const fb = (await listed()).id as string;
    assert.deepEqual((await listed()).replies, []);
    assert.deepEqual(((await (await alice("GET", `/v1/workspaces/${home}/feedback`)).json()) as any).feedback, [], "none replied on yet");

    const socket = await connect(h, station);
    const events = await listen(h, aliceTokens.access_token);
    const carol = await listen(h, carolTokens.access_token);
    await events.take();
    const made = await admin("POST", `/v1/admin/feedback/${fb}/reply`, { text: "  能发一下出错时的日志吗？ " });
    assert.equal(made.status, 201);
    const reply = (await made.json()) as any;
    assert.equal(reply.delivery, "pending");
    await h.settled();
    // (alice opened the console: its list of reports is read again too)
    // (and its 操作记录, which the reply is noted in: told apart, in no order of its own)
    const told = (await events.take()).map((e) => JSON.stringify(e)).sort();
    assert.deepEqual(told, [{ type: "admin", lists: ["audit"] }, { type: "admin", lists: ["feedback"] }, { type: "feedback", workspace: home }].map((e) => JSON.stringify(e)));
    assert.deepEqual(await carol.take(), [], "not a member");
    await socket.ping();
    assert.ok(!socket.frames.some((f) => f.type === "feedback" || JSON.stringify(f).includes("日志")), "nothing to the station");
    assert.equal((await send(h, station, { told: [] }, { path: "/v1/feedback/replies", tag: "stillfail-station-feedback-replies-v1" })).status, 404, "no way for a station to read them");

    const kept = (await listed()).replies;
    assert.deepEqual(kept.map((r: any) => [r.from, r.by, r.text, r.created_at, r.delivery]), [["team", "alice@example.test", "能发一下出错时的日志吗？", h.now(), "pending"]]);
    assert.equal((await listed()).updated_at, h.now());

    // A member's app reads it, which marks it delivered.
    const shown = ((await (await alice("GET", `/v1/workspaces/${home}/feedback`)).json()) as any).feedback;
    assert.deepEqual(shown.map((f: any) => [f.number, f.title, f.station, f.session, f.thread]), [[1, "chat_post 发不出去", station.id, "chat:c-1", "CHAT/1.1"]]);
    assert.deepEqual(shown[0].replies.map((r: any) => [r.from, r.name, r.text]), [["team", "", "能发一下出错时的日志吗？"]], "the team's, not the admin's email");
    assert.equal((await listed()).replies[0].delivery, "delivered");
    assert.equal((await h.as(carolTokens)("GET", `/v1/workspaces/${home}/feedback`)).status, 404, "not to one outside it");

    // The monitor replies with its token; the console's token and a made-up one are not it.
    assert.equal((await teamReply(h, fb, "绕过：重开一次 chat。")).status, 201);
    assert.notEqual((await teamReply(h, fb, "x", h.adminToken)).status, 201);
    assert.notEqual((await teamReply(h, fb, "x", "x".repeat(43))).status, 201);
    assert.deepEqual((await listed()).replies.map((r: any) => r.by), ["alice@example.test", "feedback-monitor"]);
    assert.equal((await teamReply(h, fb, " ")).status, 400);
    assert.equal((await teamReply(h, "0".repeat(26), "hi")).status, 404);
    socket.ws.close(1000);
  } finally {
    await h.close();
  }
});

test("a report from a chat of a workspace the station joined is that workspace's, not the station's home's", async () => {
  const h = await harness();
  try {
    const { id: home, station, aliceTokens } = await workspace(h);
    const bobTokens = await h.login("bob");
    const bob = h.as(bobTokens);
    const lab = ((await (await bob("POST", "/v1/workspaces", { name: "Lab" })).json()) as any).id as string;
    await join(h, bob, lab, station);
    // As a station from before says it: no workspace in its context, its chat's in the link; the report is its home's.
    await send(h, station, report({ context: { session: "chat:c-9", thread: "CHAT/9.9", link: `${h.origin}/o/${lab}/${station.id}/chat%3Ac-9` } }));
    // As stations say it now: the chat's workspace in the context.
    await send(h, station, report({ key: "k2", context: { session: "chat:c-8", workspace: lab } }));
    const admin = h.as(aliceTokens, "admin");
    const all = ((await (await admin("GET", "/v1/admin/feedback")).json()) as any).feedback;
    assert.deepEqual(all.map((f: any) => f.workspace.id), [home, home], "the reports' own workspace: the station's home");
    const bobEvents = await listen(h, bobTokens.access_token);
    const aliceEvents = await listen(h, aliceTokens.access_token);
    await bobEvents.take();
    await aliceEvents.take();
    for (const f of all) assert.equal((await teamReply(h, f.id, `看看 FB-${f.number}`)).status, 201);
    await h.settled();
    assert.deepEqual(await bobEvents.take(), [{ type: "feedback", workspace: lab }, { type: "feedback", workspace: lab }]);
    // (alice hears only that the console's reports changed, as she opened it)
    const reports = JSON.stringify({ type: "admin", lists: ["feedback"] }), audit = JSON.stringify({ type: "admin", lists: ["audit"] });
    assert.deepEqual((await aliceEvents.take()).map((e) => JSON.stringify(e)).sort(), [audit, audit, reports, reports], "the home's members are not the chat's");
    const shown = ((await (await bob("GET", `/v1/workspaces/${lab}/feedback`)).json()) as any).feedback;
    assert.deepEqual(shown.map((f: any) => [f.number, f.session]), [[2, "chat:c-8"], [1, "chat:c-9"]]);
    assert.deepEqual(((await (await h.as(aliceTokens)("GET", `/v1/workspaces/${home}/feedback`)).json()) as any).feedback, []);
  } finally {
    await h.close();
  }
});

test("a reply cannot reach a report from an account, or one whose chat cannot be told: refused as undeliverable", async () => {
  const h = await harness();
  try {
    const { station } = await workspace(h);
    const bob = h.as(await h.login("bob"));
    assert.equal((await bob("POST", "/v1/feedback", report())).status, 201);
    // From before stations said their chat's workspace, its link cut away.
    await send(h, station, report({ key: "k2", context: { session: "chat:c-1" } }));
    const outside = ((await (await bob("POST", "/v1/workspaces", { name: "Elsewhere" })).json()) as any).id as string;
    // Naming a workspace the station is not in.
    await send(h, station, report({ key: "k3", context: { session: "chat:c-2", workspace: outside } }));
    const admin = h.as(await h.login("alice"), "admin");
    const all = ((await (await admin("GET", "/v1/admin/feedback")).json()) as any).feedback;
    const [k3, k2, account] = all;
    assert.equal(account.station, null);
    for (const [f, reason] of [[account, "no_station"], [k2, "no_chat"], [k3, "no_chat"]] as const) {
      const refused = await admin("POST", `/v1/admin/feedback/${f.id}/reply`, { text: "能再说说吗？" });
      assert.equal(refused.status, 409);
      assert.deepEqual(await refused.json(), { error: "undeliverable", reason });
    }
    assert.ok(((await (await admin("GET", "/v1/admin/feedback")).json()) as any).feedback.every((f: any) => f.replies.length === 0), "none kept");
  } finally {
    await h.close();
  }
});

test("the chat's people answer in the app, or their agent answers for them: kept with the team's replies, the report updated", async () => {
  const h = await harness();
  try {
    const { id: home, station, aliceTokens } = await workspace(h);
    const alice = h.as(aliceTokens);
    await send(h, station, report({ context: { session: "chat:c-1", thread: "CHAT/1.1", workspace: home } }));
    const admin = h.as(aliceTokens, "admin");
    const fb = ((await (await admin("GET", "/v1/admin/feedback")).json()) as any).feedback[0].id as string;
    assert.equal((await teamReply(h, fb, "能发一下日志吗？")).status, 201);

    const events = await listen(h, aliceTokens.access_token);
    await events.take();
    const mine = await alice("POST", `/v1/workspaces/${home}/feedback/${fb}/reply`, { text: " 昨天下午三点左右 " });
    assert.equal(mine.status, 200);
    assert.match(((await mine.json()) as any).id, /^[0-9A-Z]{26}$/);
    const answered = await answer(h, station, { number: 1, text: "日志：ERROR chat_post 500", session: "chat:c-1" });
    assert.equal(answered.status, 201);
    await h.settled();
    // (and, as alice opened the console, its list of reports read again after each)
    const admin_ = { type: "admin", lists: ["feedback"] };
    assert.deepEqual(await events.take(), [{ type: "feedback", workspace: home }, admin_, { type: "feedback", workspace: home }, admin_]);

    const one = ((await (await admin("GET", "/v1/admin/feedback")).json()) as any).feedback[0];
    assert.deepEqual(one.replies.map((r: any) => [r.from, r.by, r.text]), [
      ["team", "feedback-monitor", "能发一下日志吗？"],
      ["reporter", `account:${one.replies[1].by.slice("account:".length)}`, "昨天下午三点左右"],
      ["reporter", "session:chat:c-1", "日志：ERROR chat_post 500"],
    ]);
    assert.equal(one.updated_at, h.now());
    const listed = (await (await h.fetch("/v1/admin/feedback/list", { method: "POST", headers: { authorization: `Bearer ${h.feedbackToken}`, "content-type": "application/json" }, body: "{}" })).json()) as any;
    assert.equal(listed.feedback[0].replies.length, 3, "the monitor reads them too");
    const shown = ((await (await alice("GET", `/v1/workspaces/${home}/feedback`)).json()) as any).feedback[0];
    assert.deepEqual(shown.replies.map((r: any) => [r.from, r.name]), [["team", ""], ["person", "Name of alice"], ["agent", ""]]);

    assert.equal((await alice("POST", `/v1/workspaces/${home}/feedback/${fb}/reply`, { text: " " })).status, 400);
    const carol = h.as(await h.login("carol"));
    assert.equal((await carol("POST", `/v1/workspaces/${home}/feedback/${fb}/reply`, { text: "hi" })).status, 404, "not a member");
    assert.equal((await answer(h, station, { number: 2, text: "hi" })).status, 404, "no such report");
    assert.equal((await answer(h, station, { number: 1, text: " " })).status, 400);
    const { station: other } = await workspace(h);
    assert.equal((await answer(h, other, { number: 1, text: "hi" })).status, 404, "another station's report");
  } finally {
    await h.close();
  }
});

const later = (h: Harness, seconds: number) =>
  h.fetch("/__test/later", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ seconds }) });

test("GET /v1/changelog caches responses in ServiceStatus per channel and isolates beta from stable", async () => {
  const h = await harness({ changelogCacheSeconds: 30 });
  try {
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([{ version: 1340, commit: "b", at: 2, text: ["beta 更新"], fixes: [], parts: ["web"] }]));
    await bucket.put("changelog-stable.json", JSON.stringify([{ version: 1338, commit: "a", at: 1, text: ["stable 更新"], fixes: [], parts: ["web"] }]));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1340 }));
    await bucket.put("web.json", JSON.stringify({ build: 1338 }));

    // Cold beta request populates ServiceStatus cache.
    const beta1 = await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } });
    assert.equal(beta1.status, 200);
    assert.equal(beta1.headers.get("cache-control"), "public, max-age=300");
    assert.equal(beta1.headers.get("content-type"), "application/json");
    assert.equal(beta1.headers.get("referrer-policy"), "no-referrer");
    const beta1Body = (await beta1.json()) as any;
    assert.equal(beta1Body.entries[0].text[0], "beta 更新");
    assert.equal(beta1Body.released.web, 1340);

    // Even when R2 fails completely, cached beta response is served with 0 R2 gets.
    await h.failBucket({ get: 12 });
    const beta2 = await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } });
    assert.equal(beta2.status, 200);
    assert.equal(beta2.headers.get("cache-control"), "public, max-age=300");
    assert.equal(beta2.headers.get("content-type"), "application/json");
    assert.equal(beta2.headers.get("referrer-policy"), "no-referrer");
    assert.deepEqual(await beta2.json(), beta1Body);
    assert.deepEqual(await h.failBucket(), []);

    // Stable channel is cached separately and does not return beta data.
    const stable1 = await h.fetch("/v1/changelog");
    assert.equal(stable1.status, 200);
    const stable1Body = (await stable1.json()) as any;
    assert.equal(stable1Body.entries[0].text[0], "stable 更新");
    assert.equal(stable1Body.released.web, 1338);

    await h.failBucket({ get: 12 });
    const stable2 = await h.fetch("/v1/changelog");
    assert.equal(stable2.status, 200);
    assert.deepEqual(await stable2.json(), stable1Body);
    assert.deepEqual(await h.failBucket(), []);
  } finally {
    await h.close();
  }
});

test("POST /v1/feedback/fixed shares cached R2 files across stations in ServiceStatus", async () => {
  const h = await harness({ changelogCacheSeconds: 30 });
  try {
    const { station: s1 } = await workspace(h);
    const { station: s2 } = await workspace(h);
    await send(h, s1, report({ key: "s1-k1" }));
    await send(h, s2, report({ key: "s2-k1" }));
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([
      { version: 1330, commit: "a", at: 1, text: ["修复：chat_post 发不出去"], fixes: [1, 2], parts: ["station"] },
    ]));
    await bucket.put("station.json", JSON.stringify({ version: "0.1.1335", build: 1335 }));

    // First station warms changelog.json and all 5 stable feed keys (including missing 404s).
    const first = await fixed(h, s1);
    assert.deepEqual(first.map((f) => [f.number, f.released.station, f.released.android]), [[1, 1335, null]]);

    // Second station hits ServiceStatus cache with 0 R2 gets even if R2 is failing.
    await h.failBucket({ get: 12 });
    const second = await fixed(h, s2);
    assert.deepEqual(second.map((f) => [f.number, f.released.station, f.released.android]), [[2, 1335, null]]);
    assert.deepEqual(await h.failBucket(), []);
  } finally {
    await h.close();
  }
});

test("POST /v1/releases/out invalidates cached changelog and feeds immediately", async () => {
  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const jwk = { ...(await exportJWK(publicKey)), kid: "actions", alg: "RS256", use: "sig" };
  const h = await harness({
    changelogCacheSeconds: 30,
    statusRepoId: "42",
    push: () => ({ status: 200, body: JSON.stringify({ keys: [jwk] }) }),
  });
  try {
    const { station } = await workspace(h);
    await send(h, station, report({ key: "release-k1" }), { channel: "beta" });
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([{ version: 1340, commit: "a", at: 1, text: ["旧版本"], fixes: [], parts: ["station"] }]));
    await bucket.put("station-beta.json", JSON.stringify({ build: 1340 }));

    // Warm both /v1/changelog and /v1/feedback/fixed caches.
    const before = (await (await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } })).json()) as any;
    assert.equal(before.entries[0].text[0], "旧版本");
    assert.equal(before.released.station, 1340);
    assert.deepEqual(await fixed(h, station), []);

    // Upload new release files while cache is still hot.
    await bucket.put("changelog.json", JSON.stringify([
      { version: 1341, commit: "b", at: 2, text: ["新版本"], fixes: [1], parts: ["station"] },
    ]));
    await bucket.put("station-beta.json", JSON.stringify({ build: 1341 }));

    // Still cached before /v1/releases/out (both response cache and fixes cache).
    const stillOld = (await (await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } })).json()) as any;
    assert.equal(stillOld.entries[0].text[0], "旧版本");
    assert.deepEqual(await fixed(h, station), []);

    // Release notification invalidates ServiceStatus cache before waking clients/stations.
    const oidcToken = await new SignJWT({
      repository: "o/r",
      repository_id: "42",
      workflow_ref: "o/r/.github/workflows/pipeline.yml@refs/heads/main",
    })
      .setProtectedHeader({ alg: "RS256", kid: "actions" })
      .setIssuer("https://token.actions.githubusercontent.com")
      .setAudience(h.origin)
      .setIssuedAt()
      .setExpirationTime("10 years")
      .sign(privateKey);
    const told = await h.fetch("/v1/releases/out", { method: "POST", headers: { authorization: `Bearer ${oidcToken}` } });
    assert.equal(told.status, 200);

    // Immediately sees the new changelog and fixed release on both endpoints.
    const after = (await (await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } })).json()) as any;
    assert.equal(after.entries[0].text[0], "新版本");
    assert.equal(after.released.station, 1341);
    const out = await fixed(h, station);
    assert.deepEqual(out.map((f) => [f.number, f.version, f.released.station]), [[1, 1341, 1341]]);
  } finally {
    await h.close();
  }
});

test("concurrent GET /v1/changelog requests coalesce via single-flight to one R2 read round", async () => {
  const h = await harness({ changelogCacheSeconds: 30 });
  try {
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([{ version: 1340, commit: "b", at: 2, text: ["并发合并"], fixes: [], parts: ["web"] }]));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1340 }));

    await h.failBucket({});
    const responses = await Promise.all(
      Array.from({ length: 10 }, () => h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } })),
    );
    const bodies = await Promise.all(
      responses.map(async (r) => {
        assert.equal(r.status, 200);
        return r.json();
      }),
    );
    for (const body of bodies) assert.deepEqual(body, bodies[0]);
    const calls = await h.failBucket();
    assert.equal(calls.length, 6, `expected 1 round of 6 R2 gets, got ${calls.length}: ${calls.join(", ")}`);
  } finally {
    await h.close();
  }
});

test("response cache inherits the earliest underlying file expiry (no 2x TTL stacking)", async () => {
  const h = await harness({ changelogCacheSeconds: 30 });
  try {
    const { station } = await workspace(h);
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([{ version: 1340, commit: "a", at: 1, text: ["v1"], fixes: [], parts: ["web"] }]));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1340 }));

    // t=0: fixedFor warms changelog.json (expires at t=30).
    assert.deepEqual(await fixed(h, station), []);

    // t=20: GET /v1/changelog warms response cache using changelog.json (expires at t=30) + feeds (expire at t=50).
    assert.equal((await later(h, 20)).status, 200);
    const at20 = (await (await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } })).json()) as any;
    assert.equal(at20.entries[0].text[0], "v1");

    // Update R2, advance to t=35 (> 30, < 50): response cache must already be expired.
    await bucket.put("changelog.json", JSON.stringify([{ version: 1341, commit: "b", at: 2, text: ["v2"], fixes: [], parts: ["web"] }]));
    assert.equal((await later(h, 15)).status, 200);
    const at35 = (await (await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } })).json()) as any;
    assert.equal(at35.entries[0].text[0], "v2");
  } finally {
    await h.close();
  }
});

test("ServiceStatus cache never caches R2 failures or non-404 4xx, and caches 404 missing files as null", async () => {
  const h = await harness({ changelogCacheSeconds: 30 });
  try {
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([{ version: 1340, commit: "b", at: 2, text: ["新功能"], fixes: [], parts: ["web"] }]));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1340 }));

    // All R2 reads fail -> 503 release_unavailable, never cached.
    await h.failBucket({ get: 12 });
    const failedResp = await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } });
    assert.equal(failedResp.status, 503);
    assert.deepEqual(await failedResp.json(), { error: "release_unavailable" });

    // Once R2 recovers, immediate retry succeeds with 200 and caches missing feeds as null.
    await h.failBucket();
    const okResp = await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } });
    assert.equal(okResp.status, 200);
    const body = (await okResp.json()) as any;
    assert.equal(body.entries.length, 1);
    assert.deepEqual(body.released, { station: null, android: null, desktop: null, macos: null, windows: null, web: 1340 });

    // Missing files cached during the 200 response are served as null with 0 R2 calls via fixedFor too.
    const { station } = await workspace(h);
    await send(h, station, report({ key: "beta-missing" }), { channel: "beta" });
    await h.failBucket({ get: 12 });
    assert.deepEqual(await fixed(h, station), []);
    assert.deepEqual(await h.failBucket(), []);
  } finally {
    await h.close();
  }

  // Upstream non-404 4xx (e.g. 429) must NOT be negatively cached.
  let upstreamCalls = 0;
  const h429 = await harness({
    changelogCacheSeconds: 30,
    upstream: (file) => {
      if (file === "station-beta.json") {
        upstreamCalls++;
        return upstreamCalls === 1 ? { status: 429, body: "" } : { status: 200, body: JSON.stringify({ build: 1350 }) };
      }
      return { status: 404 };
    },
  });
  try {
    const first = (await (await h429.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } })).json()) as any;
    assert.equal(first.released.station, null);
    const second = (await (await h429.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } })).json()) as any;
    assert.equal(second.released.station, 1350);
    assert.equal(upstreamCalls, 2);
  } finally {
    await h429.close();
  }
});

test("ServiceStatus RPC errors fall back to direct R2 reads and never block /v1/releases/out broadcasts", async () => {
  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const jwk = { ...(await exportJWK(publicKey)), kid: "actions", alg: "RS256", use: "sig" };
  const h = await harness({
    changelogCacheSeconds: 30,
    statusRepoId: "42",
    push: () => ({ status: 200, body: JSON.stringify({ keys: [jwk] }) }),
  });
  try {
    const { station, aliceTokens } = await workspace(h);
    await send(h, station, report({ key: "fallback-k1" }), { channel: "beta" });
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([
      { version: 1345, commit: "c", at: 3, text: ["回退直读"], fixes: [1], parts: ["station"] },
    ]));
    await bucket.put("station-beta.json", JSON.stringify({ build: 1345 }));

    const events = await listen(h, aliceTokens.access_token);
    await events.take();

    // Force ServiceStatus RPCs to throw (overloaded DO).
    const armed = await h.fetch("/__test/lose-status", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ times: 10, overloaded: true }),
    });
    assert.equal(armed.status, 200);

    // GET /v1/changelog falls back to direct R2 read -> 200.
    const changelogResp = await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } });
    assert.equal(changelogResp.status, 200);
    const changelogBody = (await changelogResp.json()) as any;
    assert.equal(changelogBody.entries[0].text[0], "回退直读");
    assert.equal(changelogBody.released.station, 1345);

    // POST /v1/feedback/fixed falls back to direct R2 read -> returns fixed report.
    const out = await fixed(h, station);
    assert.deepEqual(out.map((f) => [f.number, f.version, f.released.station]), [[1, 1345, 1345]]);

    // Admin feedback list (api.ts markFixed -> changelogFixes) also falls back to direct R2 read.
    const admin = h.as(aliceTokens, "admin");
    const listed = (await (await admin("GET", "/v1/admin/feedback")).json()) as any;
    assert.deepEqual(listed.feedback.map((f: any) => [f.number, f.status, f.fixed_in]), [[1, "fixed", 1345]]);

    // POST /v1/releases/out catches invalidateChangelog() error, still returns 200 and broadcasts release.
    const oidcToken = await new SignJWT({
      repository: "o/r",
      repository_id: "42",
      workflow_ref: "o/r/.github/workflows/pipeline.yml@refs/heads/main",
    })
      .setProtectedHeader({ alg: "RS256", kid: "actions" })
      .setIssuer("https://token.actions.githubusercontent.com")
      .setAudience(h.origin)
      .setIssuedAt()
      .setExpirationTime("10 years")
      .sign(privateKey);
    // Clearing and both channels' prewarm all failing: still 200 and the broadcast.
    await h.fetch("/__test/lose-status", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ times: 3, overloaded: true }) });
    const told = await h.fetch("/v1/releases/out", { method: "POST", headers: { authorization: `Bearer ${oidcToken}` } });
    assert.equal(told.status, 200);
    assert.deepEqual(await events.take(), [{ type: "release" }]);
    // (all three were asked and failed: ServiceStatus answers again after them)
    await h.fetch("/__test/changelog-stats");
    assert.equal((await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } })).status, 200);
    assert.equal(((await (await h.fetch("/__test/changelog-stats")).json()) as any).calls, 1);
    events.ws.close(1000);
  } finally {
    await h.close();
  }
});

test("concurrent POST /v1/feedback/fixed coalesces changelog.json read via single-flight and reuses cached fixes", async () => {
  const h = await harness({ changelogCacheSeconds: 30 });
  try {
    const stations = await Promise.all(Array.from({ length: 5 }, () => workspace(h)));
    for (let i = 0; i < stations.length; i++) {
      assert.equal((await send(h, stations[i]!.station, report({ key: `sf-${i}` }), { channel: "beta" })).status, 201);
    }
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([
      { version: 1350, commit: "d", at: 4, text: ["并发修复"], fixes: [1, 2, 3, 4, 5], parts: ["station"] },
    ]));
    await bucket.put("station-beta.json", JSON.stringify({ build: 1350 }));

    await h.failBucket({});
    const results = await Promise.all(stations.map(({ station }) => fixed(h, station)));
    for (let i = 0; i < results.length; i++) {
      assert.deepEqual(results[i]!.map((f) => [f.number, f.version, f.released.station]), [[i + 1, 1350, 1350]]);
    }
    const calls = await h.failBucket();
    assert.equal(
      calls.filter((c) => c === "get changelog.json").length,
      1,
      `expected single-flight to read changelog.json once, got: ${calls.join(", ")}`,
    );

    // Subsequent calls (including acknowledging told ids in the batched Directory RPC) hit #fixesCache with 0 R2 gets.
    await h.failBucket({ get: 12 });
    const afterTold = await Promise.all(
      stations.map(({ station }, i) => fixed(h, station, [results[i]![0].id])),
    );
    for (const list of afterTold) assert.deepEqual(list, []);
    assert.deepEqual(await h.failBucket(), []);
  } finally {
    await h.close();
  }
});

test("GET /v1/changelog returns ETag, honors If-None-Match (exact, weak, list, *), and rotates after /v1/releases/out", async () => {
  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const jwk = { ...(await exportJWK(publicKey)), kid: "actions", alg: "RS256", use: "sig" };
  const h = await harness({
    changelogCacheSeconds: 30,
    statusRepoId: "42",
    push: () => ({ status: 200, body: JSON.stringify({ keys: [jwk] }) }),
  });
  try {
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([{ version: 1360, commit: "e", at: 5, text: ["etag v1"], fixes: [], parts: ["web"] }]));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1360 }));

    const first = await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } });
    assert.equal(first.status, 200);
    const etag1 = first.headers.get("etag");
    assert.ok(etag1 && /^"[0-9a-f]{16}"$/.test(etag1), `expected strong 16-hex ETag, got ${etag1}`);
    assert.equal(((await first.json()) as any).entries[0].text[0], "etag v1");

    // Matching If-None-Match variants return 304 with empty body.
    for (const headerValue of [etag1, `W/${etag1}`, `"0000000000000000", W/${etag1}`, "*"]) {
      const res = await h.fetch("/v1/changelog", {
        headers: { "x-stillfail-channel": "beta", "if-none-match": headerValue },
      });
      assert.equal(res.status, 304, `expected 304 for If-None-Match: ${headerValue}`);
      assert.equal(res.headers.get("etag"), etag1);
      assert.equal(res.headers.get("cache-control"), "public, max-age=300");
      assert.equal(res.headers.get("referrer-policy"), "no-referrer");
      assert.equal(await res.text(), "");
    }

    // Non-matching If-None-Match returns 200 with full body.
    const mismatch = await h.fetch("/v1/changelog", {
      headers: { "x-stillfail-channel": "beta", "if-none-match": '"0000000000000000"' },
    });
    assert.equal(mismatch.status, 200);
    assert.equal(mismatch.headers.get("etag"), etag1);
    assert.equal(((await mismatch.json()) as any).entries[0].text[0], "etag v1");

    // Update R2 and invalidate via /v1/releases/out; old ETag must return 200 with new ETag and new body.
    await bucket.put("changelog.json", JSON.stringify([{ version: 1361, commit: "f", at: 6, text: ["etag v2"], fixes: [], parts: ["web"] }]));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1361 }));
    const oidcToken = await new SignJWT({
      repository: "o/r",
      repository_id: "42",
      workflow_ref: "o/r/.github/workflows/pipeline.yml@refs/heads/main",
    })
      .setProtectedHeader({ alg: "RS256", kid: "actions" })
      .setIssuer("https://token.actions.githubusercontent.com")
      .setAudience(h.origin)
      .setIssuedAt()
      .setExpirationTime("10 years")
      .sign(privateKey);
    assert.equal((await h.fetch("/v1/releases/out", { method: "POST", headers: { authorization: `Bearer ${oidcToken}` } })).status, 200);

    const after = await h.fetch("/v1/changelog", {
      headers: { "x-stillfail-channel": "beta", "if-none-match": etag1 },
    });
    assert.equal(after.status, 200);
    const etag2 = after.headers.get("etag");
    assert.ok(etag2 && /^"[0-9a-f]{16}"$/.test(etag2) && etag2 !== etag1, `expected new ETag, got ${etag2}`);
    assert.equal(((await after.json()) as any).entries[0].text[0], "etag v2");
  } finally {
    await h.close();
  }
});

test("edge isolate cache avoids re-transmitting changelog body over DO RPC on hot hits and updates after /v1/releases/out", async () => {
  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const jwk = { ...(await exportJWK(publicKey)), kid: "actions", alg: "RS256", use: "sig" };
  const h = await harness({
    changelogCacheSeconds: 30,
    statusRepoId: "42",
    push: () => ({ status: 200, body: JSON.stringify({ keys: [jwk] }) }),
  });
  try {
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([{ version: 1370, commit: "g", at: 7, text: ["edge v1"], fixes: [], parts: ["web"] }]));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1370 }));

    // Reset stats and warm both DO and edge isolate cache.
    await h.fetch("/__test/changelog-stats");
    const warm = await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } });
    assert.equal(warm.status, 200);
    const warmBody = (await warm.json()) as any;
    assert.equal(warmBody.entries[0].text[0], "edge v1");
    assert.deepEqual(await (await h.fetch("/__test/changelog-stats")).json(), { calls: 1, notModified: 0, full: 1 });

    // Hot hit without client If-None-Match: edge sends its cached ETag, DO replies notModified: true, client still receives 200 full body with 0 R2 gets.
    await h.failBucket({ get: 12 });
    const hot = await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } });
    assert.equal(hot.status, 200);
    assert.equal(hot.headers.get("etag"), warm.headers.get("etag"));
    assert.deepEqual(await hot.json(), warmBody);
    assert.deepEqual(await h.failBucket(), []);
    assert.deepEqual(await (await h.fetch("/__test/changelog-stats")).json(), { calls: 1, notModified: 1, full: 0 });

    // After /v1/releases/out invalidation, DO returns full new body and edge isolate immediately serves new content.
    await bucket.put("changelog.json", JSON.stringify([{ version: 1371, commit: "h", at: 8, text: ["edge v2"], fixes: [], parts: ["web"] }]));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1371 }));
    const oidcToken = await new SignJWT({
      repository: "o/r",
      repository_id: "42",
      workflow_ref: "o/r/.github/workflows/pipeline.yml@refs/heads/main",
    })
      .setProtectedHeader({ alg: "RS256", kid: "actions" })
      .setIssuer("https://token.actions.githubusercontent.com")
      .setAudience(h.origin)
      .setIssuedAt()
      .setExpirationTime("10 years")
      .sign(privateKey);
    assert.equal((await h.fetch("/v1/releases/out", { method: "POST", headers: { authorization: `Bearer ${oidcToken}` } })).status, 200);

    const refreshed = await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } });
    assert.equal(refreshed.status, 200);
    assert.notEqual(refreshed.headers.get("etag"), warm.headers.get("etag"));
    assert.equal(((await refreshed.json()) as any).entries[0].text[0], "edge v2");
    assert.deepEqual(await (await h.fetch("/__test/changelog-stats")).json(), { calls: 1, notModified: 0, full: 1 });
  } finally {
    await h.close();
  }
});

test("a cold isolate serves the changelog this place keeps once ServiceStatus says its ETag is out, and never one /v1/releases/out made old", async () => {
  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const jwk = { ...(await exportJWK(publicKey)), kid: "actions", alg: "RS256", use: "sig" };
  const h = await harness({
    changelogCacheSeconds: 30,
    statusRepoId: "42",
    push: () => ({ status: 200, body: JSON.stringify({ keys: [jwk] }) }),
  });
  try {
    const beta = { "x-stillfail-channel": "beta" };
    const cold = () => h.fetch("/__test/cold-changelog", { method: "POST" });
    const stats = async () => (await (await h.fetch("/__test/changelog-stats")).json()) as { calls: number; notModified: number; full: number };
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([{ version: 1390, commit: "j", at: 10, text: ["pop v1"], fixes: [], parts: ["web"] }]));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1390 }));

    await stats();
    const warm = await h.fetch("/v1/changelog", { headers: beta });
    assert.equal(warm.status, 200);
    const etag1 = warm.headers.get("etag")!;
    const warmText = await warm.text();
    assert.deepEqual(await stats(), { calls: 1, notModified: 0, full: 1 });

    // A cold isolate: the body this place keeps, ServiceStatus only checking its ETag (no body over its RPC), no R2 read.
    await cold();
    await h.failBucket({ get: 12 });
    const popped = await h.fetch("/v1/changelog", { headers: beta });
    assert.equal(popped.status, 200);
    assert.equal(popped.headers.get("etag"), etag1);
    assert.equal(popped.headers.get("content-type"), "application/json");
    assert.equal(popped.headers.get("x-stillfail-changelog-etag"), null);
    assert.equal(await popped.text(), warmText);
    assert.deepEqual(await h.failBucket(), []);
    assert.deepEqual(await stats(), { calls: 1, notModified: 1, full: 0 });

    // A cold isolate asked with the client's own ETag: a 304, its kept body not read.
    await cold();
    const unchanged = await h.fetch("/v1/changelog", { headers: { ...beta, "if-none-match": etag1 } });
    assert.equal(unchanged.status, 304);
    assert.equal(unchanged.headers.get("etag"), etag1);
    assert.equal(await unchanged.text(), "");
    assert.deepEqual(await stats(), { calls: 1, notModified: 1, full: 0 });

    // Released: a cold isolate sends the new body at once, never the one this place kept, and keeps the new one.
    await bucket.put("changelog.json", JSON.stringify([{ version: 1391, commit: "k", at: 11, text: ["pop v2"], fixes: [], parts: ["web"] }]));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1391 }));
    const oidcToken = await new SignJWT({
      repository: "o/r",
      repository_id: "42",
      workflow_ref: "o/r/.github/workflows/pipeline.yml@refs/heads/main",
    })
      .setProtectedHeader({ alg: "RS256", kid: "actions" })
      .setIssuer("https://token.actions.githubusercontent.com")
      .setAudience(h.origin)
      .setIssuedAt()
      .setExpirationTime("10 years")
      .sign(privateKey);
    assert.equal((await h.fetch("/v1/releases/out", { method: "POST", headers: { authorization: `Bearer ${oidcToken}` } })).status, 200);
    await cold();
    const fresh = await h.fetch("/v1/changelog", { headers: { ...beta, "if-none-match": etag1 } });
    assert.equal(fresh.status, 200);
    const etag2 = fresh.headers.get("etag")!;
    assert.notEqual(etag2, etag1);
    assert.equal(((await fresh.json()) as any).entries[0].text[0], "pop v2");
    assert.deepEqual(await stats(), { calls: 1, notModified: 0, full: 1 });

    await cold();
    const again = await h.fetch("/v1/changelog", { headers: beta });
    assert.equal(again.status, 200);
    assert.equal(again.headers.get("etag"), etag2);
    assert.equal(((await again.json()) as any).entries[0].text[0], "pop v2");
    assert.deepEqual(await stats(), { calls: 1, notModified: 1, full: 0 });

    // The stable channel is kept apart: a cold isolate never serves it the beta's.
    await cold();
    const stable = await h.fetch("/v1/changelog");
    assert.equal(stable.status, 200);
    assert.notEqual(stable.headers.get("etag"), etag2);
    assert.deepEqual(await stats(), { calls: 1, notModified: 0, full: 1 });
  } finally {
    await h.close();
  }
});

test("this place keeps the changelog under the origin the request reached this Worker on, a guest's forwarded one too", async () => {
  const SECRET = "s".repeat(40);
  const h = await harness({ changelogCacheSeconds: 30, origin: "https://app.monoid.build", guests: [{ origin: "https://app.still.fail" }], forwardSecret: SECRET });
  try {
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([{ version: 1392, commit: "z", at: 12, text: ["zone"], fixes: [], parts: ["web"] }]));
    const pop = ((await h.mf.getCaches()) as unknown as { default: { match(url: string): Promise<Response | undefined> } }).default;
    const kept = (origin: string, channel: string) => pop.match(`${origin}/__internal/changelog-cache/${channel}?upstream=`);
    const guest = { "x-stillfail-forwarded-origin": "https://app.still.fail", "x-stillfail-forward-secret": SECRET, "x-stillfail-forwarded-for": "203.0.113.7" };
    const got = await h.fetch("/v1/changelog", { headers: { ...guest, "x-stillfail-channel": "beta" } });
    assert.equal(got.status, 200);
    const etag = got.headers.get("etag")!;
    await got.text();
    const here = await kept("https://app.monoid.build", "beta");
    assert.ok(here, "kept under this Worker's own zone");
    assert.equal(here.headers.get("x-stillfail-changelog-etag"), etag);
    await here.text();
    assert.equal(await kept("https://app.still.fail", "beta"), undefined, "never under the guest's origin, another zone");
    assert.equal(await pop.match(`https://changelog-cache.internal/beta?upstream=`), undefined);
  } finally {
    await h.close();
  }
});

test("POST /v1/releases/out builds both channels' changelogs before telling devices, so the herd it wakes reads none", async () => {
  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const jwk = { ...(await exportJWK(publicKey)), kid: "actions", alg: "RS256", use: "sig" };
  const h = await harness({
    changelogCacheSeconds: 30,
    statusRepoId: "42",
    push: () => ({ status: 200, body: JSON.stringify({ keys: [jwk] }) }),
  });
  try {
    const { aliceTokens } = await workspace(h);
    const beta = { "x-stillfail-channel": "beta" };
    const cold = () => h.fetch("/__test/cold-changelog", { method: "POST" });
    const stats = async () => (await (await h.fetch("/__test/changelog-stats")).json()) as { calls: number; notModified: number; full: number };
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([{ version: 1393, commit: "p", at: 13, text: ["warm v1"], fixes: [], parts: ["web"] }]));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1393 }));
    const old = await h.fetch("/v1/changelog", { headers: beta });
    const etag1 = old.headers.get("etag")!;
    await old.text();
    await (await h.fetch("/v1/changelog")).text();

    await bucket.put("changelog.json", JSON.stringify([{ version: 1394, commit: "q", at: 14, text: ["warm v2"], fixes: [], parts: ["web"] }]));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1394 }));
    const events = await listen(h, aliceTokens.access_token);
    await events.take();
    const oidcToken = await new SignJWT({
      repository: "o/r",
      repository_id: "42",
      workflow_ref: "o/r/.github/workflows/pipeline.yml@refs/heads/main",
    })
      .setProtectedHeader({ alg: "RS256", kid: "actions" })
      .setIssuer("https://token.actions.githubusercontent.com")
      .setAudience(h.origin)
      .setIssuedAt()
      .setExpirationTime("10 years")
      .sign(privateKey);
    await h.failBucket({});
    assert.equal((await h.fetch("/v1/releases/out", { method: "POST", headers: { authorization: `Bearer ${oidcToken}` } })).status, 200);
    assert.deepEqual(await events.take(), [{ type: "release" }]);
    // One round for both channels (the beta's six files, the stable's own changelog and five feeds; changelog.json shared).
    const built = await h.failBucket({ get: 12 });
    assert.equal(built.filter((c) => c === "get changelog.json").length, 1, built.join(", "));
    assert.equal(built.length, 12, built.join(", "));
    await stats();

    // Every device told asks at once from cold isolates, with the ETag it had: the new body, no R2 read.
    const herd = await Promise.all(
      Array.from({ length: 6 }, async (_, i) => {
        await cold();
        return h.fetch("/v1/changelog", { headers: i % 2 ? { "if-none-match": etag1 } : { ...beta, "if-none-match": etag1 } });
      }),
    );
    for (const r of herd) {
      assert.equal(r.status, 200);
      assert.equal(((await r.json()) as any).entries[0].text[0], "warm v2");
    }
    assert.deepEqual(await h.failBucket(), []);
    assert.equal((await stats()).calls, 6);
    events.ws.close(1000);
  } finally {
    await h.close();
  }
});

test("concurrent cold GET /v1/changelog with and without matching If-None-Match coalesces to 1 R2 round and serves 304 + 200", async () => {
  const h = await harness({ changelogCacheSeconds: 30 });
  try {
    const entries = [{ version: 1380, commit: "i", at: 9, text: ["并发 ETag"], fixes: [], parts: ["web"] }];
    const expectedBody = JSON.stringify({
      entries,
      released: { station: null, android: null, macos: null, windows: null, desktop: null, web: 1380 },
    });
    const expectedEtag = `"${createHash("sha256").update(expectedBody).digest("hex").slice(0, 16)}"`;
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify(entries));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1380 }));

    await h.failBucket({});
    const [condResp, fullResp] = await Promise.all([
      h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta", "if-none-match": expectedEtag } }),
      h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } }),
    ]);

    assert.equal(condResp.status, 304);
    assert.equal(condResp.headers.get("etag"), expectedEtag);
    assert.equal(await condResp.text(), "");

    assert.equal(fullResp.status, 200);
    assert.equal(fullResp.headers.get("etag"), expectedEtag);
    assert.equal(await fullResp.text(), expectedBody);

    const calls = await h.failBucket();
    assert.equal(calls.length, 6, `expected 1 round of 6 R2 gets, got ${calls.length}: ${calls.join(", ")}`);
  } finally {
    await h.close();
  }
});

test("GET /v1/changelog refreshes proactively in background after 75% TTL while preserving hard expiry", async () => {
  const h = await harness({ changelogCacheSeconds: 30 });
  try {
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([{ version: 1390, commit: "j", at: 10, text: ["swr v1"], fixes: [], parts: ["web"] }]));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1390 }));

    // t=0: warm cache (expiresAt=30s, refreshAt=22.5s).
    const at0 = await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } });
    assert.equal(at0.status, 200);
    assert.equal(((await at0.json()) as any).entries[0].text[0], "swr v1");

    // Update R2 to v2 and advance to t=23 (> 75% of 30s, < 30s hard expiry).
    await bucket.put("changelog.json", JSON.stringify([{ version: 1391, commit: "k", at: 11, text: ["swr v2"], fixes: [], parts: ["web"] }]));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1391 }));
    assert.equal((await later(h, 23)).status, 200);

    // Request at t=23 immediately returns cached v1 and kicks off background refresh.
    const at23 = await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } });
    assert.equal(at23.status, 200);
    assert.equal(((await at23.json()) as any).entries[0].text[0], "swr v1");

    // Wait deterministically for background refresh to complete.
    assert.equal((await h.fetch("/__test/status-settled")).status, 200);

    // Next request (still at t=23) reads refreshed v2 from cache with 0 R2 gets.
    await h.failBucket({ get: 12 });
    const afterBg = await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } });
    assert.equal(afterBg.status, 200);
    assert.notEqual(afterBg.headers.get("etag"), at0.headers.get("etag"));
    assert.equal(((await afterBg.json()) as any).entries[0].text[0], "swr v2");
    assert.deepEqual(await h.failBucket(), []);

    // Past 100% hard expiry (advance 31s -> t=54 > 53s), synchronously refreshes to v3.
    await bucket.put("changelog.json", JSON.stringify([{ version: 1392, commit: "l", at: 12, text: ["swr v3"], fixes: [], parts: ["web"] }]));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1392 }));
    assert.equal((await later(h, 31)).status, 200);
    const at54 = await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } });
    assert.equal(at54.status, 200);
    assert.equal(((await at54.json()) as any).entries[0].text[0], "swr v3");
  } finally {
    await h.close();
  }
});

test("background refresh R2 failure keeps unexpired cache, backs off retries, and refreshes synchronously after hard expiry", async () => {
  const h = await harness({ changelogCacheSeconds: 30 });
  try {
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([{ version: 1395, commit: "m", at: 13, text: ["backoff v1"], fixes: [], parts: ["web"] }]));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1395 }));

    // t=0: warm cache (expiresAt=30s, refreshAt=22.5s).
    const warm = await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } });
    assert.equal(warm.status, 200);
    assert.equal(warm.headers.get("vary"), "x-stillfail-channel");
    assert.equal(((await warm.json()) as any).entries[0].text[0], "backoff v1");

    // Advance to t=23 (> 75% TTL, < 30s hard expiry) and fail all R2 reads.
    assert.equal((await later(h, 23)).status, 200);
    await h.failBucket({ get: 20 });

    // First request at t=23 serves cached v1 immediately and triggers failing background refresh.
    const first = await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } });
    assert.equal(first.status, 200);
    assert.equal(((await first.json()) as any).entries[0].text[0], "backoff v1");
    assert.equal((await h.fetch("/__test/status-settled")).status, 200);
    const failedCalls = await h.failBucket({ get: 20 });
    assert.ok(failedCalls.length > 0, "expected background refresh to attempt R2 reads");

    // Subsequent request before backoff window (still at t=23 < 26.5s) serves v1 with 0 R2 calls.
    const second = await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } });
    assert.equal(second.status, 200);
    assert.equal(((await second.json()) as any).entries[0].text[0], "backoff v1");
    assert.equal((await h.fetch("/__test/status-settled")).status, 200);
    assert.deepEqual(await h.failBucket(), []);

    // Update R2 to v2 and advance past hard expiry (t=31 > 30s): synchronously refreshes to v2.
    await bucket.put("changelog.json", JSON.stringify([{ version: 1396, commit: "n", at: 14, text: ["backoff v2"], fixes: [], parts: ["web"] }]));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1396 }));
    assert.equal((await later(h, 8)).status, 200);
    const afterExpiry = await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } });
    assert.equal(afterExpiry.status, 200);
    assert.equal(((await afterExpiry.json()) as any).entries[0].text[0], "backoff v2");
  } finally {
    await h.close();
  }
});

test("GET /v1/changelog with ttl=0 direct R2 path returns strong ETag, Vary, and 304 on matching If-None-Match", async () => {
  const h = await harness({ changelogCacheSeconds: 0 });
  try {
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("changelog.json", JSON.stringify([{ version: 1398, commit: "o", at: 15, text: ["direct r2"], fixes: [], parts: ["web"] }]));
    await bucket.put("web-beta.json", JSON.stringify({ build: 1398 }));

    const first = await h.fetch("/v1/changelog", { headers: { "x-stillfail-channel": "beta" } });
    assert.equal(first.status, 200);
    const etag = first.headers.get("etag");
    assert.ok(etag && /^"[0-9a-f]{16}"$/.test(etag), `expected strong 16-hex ETag, got ${etag}`);
    assert.equal(first.headers.get("vary"), "x-stillfail-channel");
    assert.equal(((await first.json()) as any).entries[0].text[0], "direct r2");

    const notMod = await h.fetch("/v1/changelog", {
      headers: { "x-stillfail-channel": "beta", "if-none-match": etag },
    });
    assert.equal(notMod.status, 304);
    assert.equal(notMod.headers.get("etag"), etag);
    assert.equal(notMod.headers.get("vary"), "x-stillfail-channel");
    assert.equal(await notMod.text(), "");
  } finally {
    await h.close();
  }
});
