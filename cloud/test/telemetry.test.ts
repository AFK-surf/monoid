import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { harness } from "./harness.ts";
import { digest, randomSecret } from "../src/auth.ts";
import { TELEMETRY_BATCHES_PER_MINUTE as BATCHES_PER_MINUTE } from "../src/limits.ts";

type Harness = Awaited<ReturnType<typeof harness>>;
const hex = (bytes: ArrayBuffer) => Buffer.from(bytes).toString("hex");

async function key() {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const id = hex((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
  const sign = async (message: string) => hex(await crypto.subtle.sign("Ed25519", pair.privateKey, new TextEncoder().encode(message)));
  return { id, sign };
}

/** Google Cloud's Telemetry API as the tests see it: every request it got, and `until` one it got is so (what a Worker sends once its answer is out). */
function fakeGoogle(status = 200) {
  const got: { url: string; headers: Record<string, string>; body: any }[] = [];
  const waiting = new Set<() => void>();
  const answer = async (request: Request) => {
    got.push({ url: request.url, headers: Object.fromEntries(request.headers), body: JSON.parse(await request.text()) });
    for (const wake of waiting) wake();
    return new Response("{}", { status });
  };
  const until = async <T>(find: (g: typeof got) => T | undefined): Promise<T> => {
    for (;;) {
      const found = find(got);
      if (found !== undefined) return found;
      await new Promise<void>((resolve) => {
        const wake = () => (waiting.delete(wake), resolve());
        waiting.add(wake);
      });
    }
  };
  return { got, answer, until };
}

/** A batch as sent, without the network and the project still.fail cloud puts on its resources (tracing.ts networkOf, toGoogle). */
const sent = (body: any, key = "resourceSpans") => ({
  ...body,
  [key]: body[key].map((r: any) => ({ ...r, resource: { ...r.resource, attributes: r.resource.attributes.filter((a: any) => !a.key.startsWith("stillfail.net.") && a.key !== "gcp.project_id") } })),
});

/** The spans' trace ids, in the order Google got them. */
const traces = (got: { body: any }[]) => got.map((g) => g.body.resourceSpans[0].scopeSpans[0].spans[0].traceId);

const batch = (name = "chat.open", spans = 1) => JSON.stringify({
  resourceSpans: [{
    resource: { attributes: [{ key: "service.name", value: { stringValue: "ember-web" } }] },
    scopeSpans: [{ scope: { name: "stillfail-core" }, spans: Array.from({ length: spans }, () => ({ traceId: "4bf92f3577b34da6a3ce929d0e0e4736", spanId: "00f067aa0ba902b7", name, kind: 1, startTimeUnixNano: "1", endTimeUnixNano: "2" })) }],
  }],
});

const post = (h: Harness, body: string, headers: Record<string, string> = {}) =>
  h.fetch("/v1/telemetry/traces", { method: "POST", headers: { "content-type": "application/json", ...headers }, body });

async function enrolled(h: Harness) {
  const alice = h.as(await h.login("alice"));
  const workspace = ((await (await alice("POST", "/v1/workspaces", { name: "Home" })).json()) as any).id as string;
  const enrollment = (await (await alice("POST", `/v1/workspaces/${workspace}/enrollments`, { name: "willow" })).json()) as any;
  const station = await key();
  const response = await h.fetch("/v1/stations/enroll", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ token: enrollment.token, station: station.id, signature: await station.sign(`stillfail-station-enroll-v1:${h.origin}:${enrollment.token}:${station.id}`) }),
  });
  assert.equal(response.status, 200);
  return station;
}

/** A station's signed headers for `body`. */
async function signed(h: Harness, station: Awaited<ReturnType<typeof key>>, body: string, ts = h.now()) {
  const digest = createHash("sha256").update(body).digest("hex");
  return { "x-stillfail-station": station.id, "x-stillfail-ts": String(ts), "x-stillfail-signature": await station.sign(`stillfail-station-telemetry-v1:${h.origin}:${station.id}:${ts}:${digest}`) };
}

test("a signed-in client's spans go on to Google Cloud as still.fail cloud's service account, filed under its project", async () => {
  const google = fakeGoogle();
  const h = await harness({ telemetry: google.answer });
  try {
    const tokens = await h.login("alice");
    const body = batch();
    const response = await post(h, body, { authorization: `Bearer ${tokens.access_token}` });
    assert.equal(response.status, 202);
    assert.equal(google.got.length, 1);
    assert.equal(google.got[0]!.url, "https://telemetry.googleapis.com/v1/traces");
    assert.equal(google.got[0]!.headers.authorization, "Bearer test-telemetry-token");
    assert.deepEqual(google.got[0]!.body.resourceSpans[0].resource.attributes.filter((a: any) => a.key === "gcp.project_id"), [{ key: "gcp.project_id", value: { stringValue: "stillfail-test" } }]);
    assert.deepEqual(sent(google.got[0]!.body), JSON.parse(body));

    // Nobody, or a token that is no good: nothing goes on.
    assert.equal((await post(h, body)).status, 401);
    assert.equal((await post(h, body, { authorization: "Bearer nope" })).status, 401);
    // Not OTLP, or too much of it.
    assert.equal((await post(h, "[]", { authorization: `Bearer ${tokens.access_token}` })).status, 400);
    assert.equal((await post(h, batch("x", 1001), { authorization: `Bearer ${tokens.access_token}` })).status, 413);
    assert.equal(google.got.length, 1);
  } finally {
    await h.close();
  }
});

// A device's ways through the relays are compared network by network (mesh.speed): its spans carry the carrier and the
// province Cloudflare saw them come from, never the address; what the sender said of its network itself is not kept.
test("a client's spans carry the network they came from", async () => {
  const google = fakeGoogle();
  const h = await harness({ telemetry: google.answer });
  try {
    const tokens = await h.login("alice");
    const claimed = JSON.parse(batch("mesh.speed"));
    claimed.resourceSpans[0].resource.attributes.push({ key: "stillfail.net.org", value: { stringValue: "said by the sender" } });
    const response = await h.fetch("/v1/telemetry/traces", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${tokens.access_token}` },
      body: JSON.stringify(claimed),
      cf: { asn: 9808, asOrganization: "China Mobile", country: "CN", region: "Hunan", city: "Hengyang" },
    } as RequestInit);
    assert.equal(response.status, 202);
    const attributes = Object.fromEntries(google.got[0]!.body.resourceSpans[0].resource.attributes.map((a: any) => [a.key, Object.values(a.value)[0]]));
    assert.equal(attributes["service.name"], "ember-web");
    assert.equal(attributes["stillfail.net.asn"], "9808");
    assert.equal(attributes["stillfail.net.org"], "China Mobile");
    assert.equal(attributes["stillfail.net.country"], "CN");
    assert.equal(attributes["stillfail.net.region"], "Hunan");
    assert.equal(attributes["stillfail.net.city"], "Hengyang");
    assert.equal(google.got[0]!.body.resourceSpans[0].resource.attributes.filter((a: any) => a.key === "stillfail.net.org").length, 1);
    assert.equal(google.got[0]!.body.resourceSpans[0].scopeSpans[0].spans[0].name, "mesh.speed");
  } finally {
    await h.close();
  }
});

// Which carrier and province a station is reached through decides how its ways do (2026-10-30: a few stations slow on
// every relay pulled the devices' connects up): its log lines carry the network it sent them from, as spans do.
test("a station's log carries the network it came from", async () => {
  const google = fakeGoogle();
  const h = await harness({ telemetry: google.answer });
  try {
    const station = await enrolled(h);
    const body = JSON.stringify({ resourceLogs: [{ resource: { attributes: [{ key: "service.name", value: { stringValue: "stillfail-station" } }] }, scopeLogs: [{ scope: { name: "stillfail-station" }, logRecords: [{ timeUnixNano: "1", severityText: "INFO", body: { stringValue: "client connected" } }] }] }] });
    const response = await h.fetch("/v1/telemetry/logs", {
      method: "POST",
      headers: { "content-type": "application/json", ...(await signed(h, station, body)) },
      body,
      cf: { asn: 4134, asOrganization: "Chinanet", country: "CN", region: "Guangdong", city: "Shenzhen" },
    } as RequestInit);
    assert.equal(response.status, 202);
    const attributes = Object.fromEntries(google.got[0]!.body.resourceLogs[0].resource.attributes.map((a: any) => [a.key, Object.values(a.value)[0]]));
    assert.deepEqual(attributes, {
      "service.name": "stillfail-station", "gcp.project_id": "stillfail-test", "stillfail.net.asn": "4134", "stillfail.net.org": "Chinanet",
      "stillfail.net.country": "CN", "stillfail.net.region": "Guangdong", "stillfail.net.city": "Shenzhen",
    });
  } finally {
    await h.close();
  }
});

test("a station's spans are signed with its key, over the body", async () => {
  const google = fakeGoogle();
  const h = await harness({ telemetry: google.answer });
  try {
    const station = await enrolled(h);
    const body = batch("GET /admin/api/threads");
    assert.equal((await post(h, body, await signed(h, station, body))).status, 202);
    assert.equal(google.got.length, 1);
    // Another body under the same signature, an old signature, or a key that is not enrolled: refused.
    assert.equal((await post(h, batch("forged"), await signed(h, station, body))).status, 401);
    assert.equal((await post(h, body, await signed(h, station, body, h.now() - 600))).status, 401);
    const stranger = await key();
    assert.equal((await post(h, body, await signed(h, stranger, body))).status, 401);
    assert.equal(google.got.length, 1);
  } finally {
    await h.close();
  }
});

test("a station's log goes on to Cloud Logging, signed with its key; a member's account cannot send one", async () => {
  const urls: string[] = [];
  const google = fakeGoogle();
  const h = await harness({ telemetry: (request) => (urls.push(request.url), google.answer(request)) });
  try {
    const station = await enrolled(h);
    const body = JSON.stringify({ resourceLogs: [{ resource: { attributes: [] }, scopeLogs: [{ scope: { name: "stillfail-station" }, logRecords: [{ timeUnixNano: "1", severityText: "WARN", body: { stringValue: "no presence socket" } }] }] }] });
    const logs = (b: string, headers: Record<string, string>) => h.fetch("/v1/telemetry/logs", { method: "POST", headers: { "content-type": "application/json", ...headers }, body: b });
    assert.equal((await logs(body, await signed(h, station, body))).status, 202);
    assert.deepEqual(urls, ["https://telemetry.googleapis.com/v1/logs"]);
    assert.deepEqual(sent(google.got[0]!.body, "resourceLogs"), JSON.parse(body));
    // Spans are no log, a forged body is refused, and an account is no station.
    const spans = batch();
    assert.equal((await logs(spans, await signed(h, station, spans))).status, 400);
    assert.equal((await logs(batch("x"), await signed(h, station, body))).status, 401);
    const alice = await h.login("alice");
    assert.equal((await logs(body, { authorization: `Bearer ${alice.access_token}` })).status, 401);
    assert.equal(google.got.length, 1);
  } finally {
    await h.close();
  }
});

test("a signed-in client's spans use up none of its account's requests a minute, and a token not good is refused", async () => {
  // (they have their own budget, by sender: a person's devices sending theirs had the account system refuse the rest)
  const google = fakeGoogle();
  const h = await harness({ telemetry: google.answer });
  try {
    const tokens = await h.login("alice");
    const alice = h.as(tokens);
    for (let i = 0; i < 100; i++) assert.equal((await alice("GET", "/v1/me")).status, 200);
    for (let i = 0; i < 30; i++) assert.equal((await post(h, batch(), { authorization: `Bearer ${tokens.access_token}` })).status, 202);
    assert.equal((await alice("GET", "/v1/me")).status, 200, "the account's own still answered");
    assert.equal((await post(h, batch(), { authorization: "Bearer not-a-token" })).status, 401);
  } finally {
    await h.close();
  }
});

test("each sender has its own budget a minute", async () => {
  const google = fakeGoogle();
  const h = await harness({ telemetry: google.answer });
  try {
    const alice = await h.login("alice");
    const bob = await h.login("bob");
    const body = batch();
    for (let i = 0; i < BATCHES_PER_MINUTE; i++) assert.equal((await post(h, body, { authorization: `Bearer ${alice.access_token}` })).status, 202);
    const refused = await post(h, body, { authorization: `Bearer ${alice.access_token}` });
    assert.equal(refused.status, 429);
    assert.equal(refused.headers.get("retry-after"), "60");
    assert.equal((await post(h, body, { authorization: `Bearer ${bob.access_token}` })).status, 202);
    assert.equal(google.got.length, BATCHES_PER_MINUTE + 1);
  } finally {
    await h.close();
  }
});

test("without Google Cloud's account, or when Google fails, a batch is refused and not retried", async () => {
  const off = await harness();
  try {
    const tokens = await off.login("alice");
    assert.equal((await post(off, batch(), { authorization: `Bearer ${tokens.access_token}` })).status, 503);
  } finally {
    await off.close();
  }
  const google = fakeGoogle(500);
  const h = await harness({ telemetry: google.answer });
  try {
    const tokens = await h.login("alice");
    assert.equal((await post(h, batch(), { authorization: `Bearer ${tokens.access_token}` })).status, 502);
    assert.equal(google.got.length, 1);
  } finally {
    await h.close();
  }
});

test("a call in a recorded trace is a span of still.fail cloud's, without ids", async () => {
  const google = fakeGoogle();
  const h = await harness({ telemetry: google.answer });
  try {
    const alice = await h.login("alice");
    const workspace = ((await (await h.as(alice)("POST", "/v1/workspaces", { name: "Home" })).json()) as any).id as string;
    const trace = "4bf92f3577b34da6a3ce929d0e0e4736";
    const call = (traceparent?: string) => h.fetch(`/v1/workspaces/${workspace}`, { headers: { authorization: `Bearer ${alice.access_token}`, ...(traceparent ? { traceparent } : {}) } });
    assert.equal((await call(`00-${trace}-00f067aa0ba902b7-01`)).status, 200);
    await google.until((got) => got[0]);
    assert.equal(google.got.length, 1);
    const resource = google.got[0]!.body.resourceSpans[0];
    assert.deepEqual(resource.resource.attributes, [{ key: "service.name", value: { stringValue: "stillfail-cloud" } }, { key: "gcp.project_id", value: { stringValue: "stillfail-test" } }]);
    const span = resource.scopeSpans[0].spans[0];
    assert.equal(span.traceId, trace);
    assert.equal(span.parentSpanId, "00f067aa0ba902b7");
    assert.equal(span.name, "GET /v1/workspaces/:id");
    assert.ok(BigInt(span.endTimeUnixNano) >= BigInt(span.startTimeUnixNano));
    assert.deepEqual(span.attributes.find((a: any) => a.key === "http.response.status_code"), { key: "http.response.status_code", value: { intValue: "200" } });
    assert.ok(!JSON.stringify(span).includes(workspace));

    // Not recorded by the caller, or no trace: no span. (One more recorded call after them: its span is the next.)
    await call(`00-${trace}-00f067aa0ba902b7-00`);
    await call();
    const next = "5ce0e9a56015fec5aadfa328ae398115";
    assert.equal((await call(`00-${next}-00f067aa0ba902b7-01`)).status, 200);
    await google.until((got) => traces(got).find((t) => t === next));
    assert.deepEqual(traces(google.got), [trace, next]);
  } finally {
    await h.close();
  }
});

test("a traced refresh's span says what became of the session, and the answer carries no notes", async () => {
  const google = fakeGoogle();
  const h = await harness({ telemetry: google.answer });
  try {
    const alice = await h.login("alice");
    let n = 0;
    const refresh = async (token: string) => {
      const trace = (++n).toString(16).padStart(32, "a");
      const response = await h.fetch("/v1/auth/refresh", {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json", traceparent: `00-${trace}-00f067aa0ba902b7-01` },
        body: JSON.stringify({ request_id: `01J00000000000000000000${String(n).padStart(3, "0")}` }),
      });
      assert.equal(response.headers.get("x-stillfail-span"), null);
      const body = (await response.json()) as any;
      const span = await google.until((got) => got.map((g) => g.body.resourceSpans[0].scopeSpans[0].spans[0]).find((s: any) => s.traceId === trace));
      const notes = Object.fromEntries(span.attributes.map((a: any) => [a.key, a.value.stringValue ?? Number(a.value.intValue)]));
      return { status: response.status, body, notes };
    };
    const first = await refresh(alice.refresh_token);
    assert.equal(first.status, 200);
    assert.equal(first.notes["stillfail.auth.outcome"], "rotated");
    assert.equal(first.notes["stillfail.account"], alice.subject);
    assert.equal(first.notes["stillfail.session"], alice.session_id);
    assert.deepEqual([first.notes["stillfail.auth.presented_generation"], first.notes["stillfail.auth.generation"]], [0, 1]);

    const again = await refresh(alice.refresh_token);
    assert.equal(again.notes["stillfail.auth.outcome"], "retried");
    assert.equal(typeof again.notes["stillfail.auth.rotated_ago"], "number");

    const second = await refresh(first.body.refresh_token);
    assert.equal(second.notes["stillfail.auth.outcome"], "rotated");
    // The first credential again, past the one retry the session keeps: reuse, and the session is gone.
    const reused = await refresh(alice.refresh_token);
    assert.equal(reused.status, 401);
    assert.deepEqual([reused.notes["stillfail.auth.outcome"], reused.notes["stillfail.auth.presented_generation"], reused.notes["stillfail.auth.generation"]], ["reused", 0, 2]);
    const gone = await refresh(second.body.refresh_token);
    assert.equal(gone.status, 401);
    assert.equal(gone.notes["stillfail.auth.outcome"], "no_session");
    assert.equal(gone.notes["stillfail.auth.gone"], "reused");

    const forged = await refresh(`${alice.refresh_token.split(".").slice(0, 2).join(".")}.forged`);
    assert.equal(forged.status, 401);
    assert.equal(forged.notes["stillfail.auth.outcome"], "invalid_token");
    assert.equal(forged.notes["stillfail.account"], alice.subject);
  } finally {
    await h.close();
  }
});

test("an answer of still.fail cloud's own failing (5xx) is a log line of stillfail-cloud, its route without ids, never telemetry's own", async () => {
  const google = fakeGoogle(500);
  const h = await harness({ telemetry: google.answer });
  try {
    const tokens = await h.login("alice");
    // (telemetry's own 502, Google refusing: not logged through it)
    assert.equal((await post(h, batch(), { authorization: `Bearer ${tokens.access_token}` })).status, 502);
    // A browser's subscription with no VAPID key here: 503.
    const pair = (await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"])) as CryptoKeyPair;
    const b64url = (b: ArrayBuffer | Uint8Array) => Buffer.from(b instanceof Uint8Array ? b : new Uint8Array(b)).toString("base64url");
    const p256dh = b64url((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
    const auth = b64url(crypto.getRandomValues(new Uint8Array(16)));
    const response = await h.fetch("/v1/push", {
      method: "POST",
      headers: { authorization: `Bearer ${tokens.access_token}`, "content-type": "application/json" },
      body: JSON.stringify({ kind: "web", endpoint: "https://push.example/send/secret-subscription", keys: { p256dh, auth } }),
    });
    assert.equal(response.status, 503);
    const line = await google.until((got) => got.find((g) => g.url === "https://telemetry.googleapis.com/v1/logs"));
    const logs = google.got.filter((g) => g.url === "https://telemetry.googleapis.com/v1/logs");
    assert.equal(logs.length, 1, "only the push's 503 was logged");
    const resource = line.body.resourceLogs[0];
    assert.deepEqual(resource.resource.attributes.find((a: any) => a.key === "service.name"), { key: "service.name", value: { stringValue: "stillfail-cloud" } });
    const record = resource.scopeLogs[0].logRecords[0];
    assert.equal(record.severityNumber, 17);
    assert.equal(record.severityText, "ERROR");
    assert.equal(record.body.stringValue, "worker returned 5xx");
    assert.deepEqual(Object.fromEntries(record.attributes.map((a: any) => [a.key, a.value.stringValue ?? a.value.intValue])), {
      "log.target": "http",
      "log.method": "POST",
      "log.path": "/v1/push",
      "log.status": "503",
    });
    assert.ok(!JSON.stringify(line.body).includes("secret-subscription"));
  } finally {
    await h.close();
  }
});

/** Every span of still.fail cloud's own Google got so far, and every log line, each with its attributes read out. */
const read = (a: any[]) => Object.fromEntries(a.map((x: any) => [x.key, x.value.stringValue ?? x.value.boolValue ?? (x.value.intValue !== undefined ? Number(x.value.intValue) : x.value.doubleValue)]));
const ownSpans = (got: { url: string; body: any }[], name: string) => got.filter((g) => g.url.endsWith("/v1/traces")).flatMap((g) => g.body.resourceSpans[0].scopeSpans[0].spans).filter((s: any) => s.name === name).map((s: any) => ({ ...s, at: read(s.attributes) }));
const ownLines = (got: { url: string; body: any }[], message: string) => got.filter((g) => g.url.endsWith("/v1/logs")).flatMap((g) => g.body.resourceLogs[0].scopeLogs[0].logRecords).filter((r: any) => r.body.stringValue === message).map((r: any) => ({ ...r, at: read(r.attributes) }));
const later = (h: Harness, seconds: number) => h.fetch("/__test/later", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ seconds }) });

// The hourly models' catalog (src/models.ts) is the task made slow or failing here: models.dev is outside, answered by `push`.
test("each scheduled task is a trace of its own: done, slow (a WARN line too) or failed (an ERROR line)", async () => {
  const google = fakeGoogle();
  let models: "ok" | "slow" | "fail" = "ok";
  let h: Harness;
  h = await harness({
    telemetry: google.answer,
    push: async (request) => {
      if (!request.url.startsWith("https://models.dev/")) return { status: 200 };
      if (models === "fail") return { status: 500 };
      // (the task takes 11 s of the cloud's clock: it is put forward while the task waits for models.dev)
      if (models === "slow" && request.url.endsWith("/models.json")) await later(h, 11);
      return { status: 200, body: "{}" };
    },
  });
  try {
    const api = (await h.mf.getWorker("api")) as unknown as { scheduled(options: { cron: string; scheduledTime: Date }): Promise<{ outcome: string }> };
    const cron = async () => assert.equal((await api.scheduled({ cron: "* * * * *", scheduledTime: new Date(Date.UTC(2026, 0, 1, 0, 7)) })).outcome, "ok");
    const ofModels = (n: number) => google.until((got) => {
      const spans = ownSpans(got, "cloud.cron").filter((s) => s.at["stillfail.cron.task"] === "checkModels");
      return spans.length >= n ? spans : undefined;
    });

    await cron();
    const [done] = await ofModels(1);
    assert.equal(done.kind, 1);
    assert.equal(done.parentSpanId, undefined);
    assert.match(done.traceId, /^[0-9a-f]{32}$/);
    assert.match(done.spanId, /^[0-9a-f]{16}$/);
    assert.deepEqual(done.at, { "stillfail.cron.task": "checkModels", "stillfail.cron.ok": true });
    assert.deepEqual(done.status, { code: 1 });
    // Every task of the minute is one.
    await google.until((got) => (["sampleOwnRelay", "checkServices"].every((t) => ownSpans(got, "cloud.cron").some((s) => s.at["stillfail.cron.task"] === t)) ? true : undefined));
    assert.deepEqual(ownLines(google.got, "slow cron task"), []);

    models = "slow";
    await cron();
    const slow = (await ofModels(2))[1]!;
    assert.ok(BigInt(slow.endTimeUnixNano) - BigInt(slow.startTimeUnixNano) >= 11_000_000_000n);
    assert.equal(slow.at["stillfail.cron.ok"], true);
    const warned = await google.until((got) => ownLines(got, "slow cron task").find((l) => l.at["log.task"] === "checkModels"));
    assert.equal(warned.severityText, "WARN");
    assert.ok(warned.at["log.ms"] >= 11_000);

    models = "fail";
    await cron();
    const failed = (await ofModels(3))[2]!;
    assert.equal(failed.at["stillfail.cron.ok"], false);
    assert.deepEqual(failed.status, { code: 2 });
    const line = await google.until((got) => ownLines(got, "checkModels failed")[0]);
    assert.equal(line.severityText, "ERROR");
    assert.equal(line.at["log.target"], "cron");
    assert.equal(line.at["log.task"], "checkModels");
    assert.match(line.at["log.error"], /models\.dev/);
    assert.equal(typeof line.at["log.ms"], "number");
  } finally {
    await h.close();
  }
});

test("a call nobody traced is a trace of its own when slow, refused for its rate or failing, its route without ids or query", async () => {
  const google = fakeGoogle();
  let models: "fail" | "slow" = "fail";
  let h: Harness;
  h = await harness({
    telemetry: google.answer,
    push: async (request) => {
      if (!request.url.startsWith("https://models.dev/")) return { status: 200 };
      if (models === "fail") return { status: 500 };
      if (request.url.endsWith("/models.json")) await later(h, 2);
      return { status: 200, body: "{}" };
    },
  });
  try {
    const alice = h.as(await h.login("alice"));
    // Quick and answered: nothing.
    assert.equal((await alice("GET", "/v1/me")).status, 200);

    // Failing: models.dev down is a 502 of the cloud's.
    assert.equal((await h.fetch("/v1/models")).status, 502);
    const [failed] = await google.until((got) => (ownSpans(got, "cloud.http").length >= 1 ? ownSpans(got, "cloud.http") : undefined));
    assert.equal(failed.kind, 2);
    assert.equal(failed.parentSpanId, undefined);
    assert.deepEqual(failed.status, { code: 2 });
    assert.deepEqual(failed.at, { "http.request.method": "GET", "http.route": "/v1/models", "http.response.status_code": 502, "stillfail.sampled_reason": "5xx" });

    // Slow: 2 s of the cloud's clock waiting for models.dev.
    models = "slow";
    assert.equal((await h.fetch("/v1/models")).status, 200);
    const slow = (await google.until((got) => (ownSpans(got, "cloud.http").length >= 2 ? ownSpans(got, "cloud.http") : undefined)))[1]!;
    assert.deepEqual(slow.at, { "http.request.method": "GET", "http.route": "/v1/models", "http.response.status_code": 200, "stillfail.sampled_reason": "slow" });
    assert.deepEqual(slow.status, { code: 1 });
    assert.ok(BigInt(slow.endTimeUnixNano) - BigInt(slow.startTimeUnixNano) >= 2_000_000_000n);

    // Refused for its rate: the eleventh sign-in from an address in a minute.
    const start = async () => {
      const query = new URLSearchParams({ state: randomSecret(), redirect_uri: "http://127.0.0.1:32145/oauth/callback", code_challenge: await digest(randomSecret()), code_challenge_method: "S256" });
      return (await h.fetch("/v1/auth/google/start?" + query, { redirect: "manual", headers: { "cf-connecting-ip": "10.9.0.1" } })).status;
    };
    for (let i = 0; i < 10; i++) assert.notEqual(await start(), 429);
    assert.equal(await start(), 429);
    const limited = (await google.until((got) => (ownSpans(got, "cloud.http").length >= 3 ? ownSpans(got, "cloud.http") : undefined)))[2]!;
    assert.deepEqual(limited.at, { "http.request.method": "GET", "http.route": "/v1/auth/google/start", "http.response.status_code": 429, "stillfail.sampled_reason": "429" });
    assert.deepEqual(limited.status, { code: 1 });
    const line = await google.until((got) => ownLines(got, "rate limited")[0]);
    assert.equal(line.severityText, "WARN");
    assert.deepEqual(line.at, { "log.target": "http", "log.method": "GET", "log.path": "/v1/auth/google/start", "log.status": 429, "log.ms": 0 });
    // The quick 200 and the sign-ins let through were none of them; nothing of a query, an address or a token.
    assert.equal(ownSpans(google.got, "cloud.http").length, 3);
    const all = JSON.stringify(google.got.map((g) => g.body));
    assert.ok(!all.includes("10.9.0.1") && !all.includes("code_challenge") && !all.includes("127.0.0.1"));
  } finally {
    await h.close();
  }
});

test("a socket's opening refused or slow is a trace of its own (a refusal a WARN line too), never with its token, key or signature", async () => {
  const google = fakeGoogle();
  const h = await harness({ telemetry: google.answer });
  try {
    const tokens = await h.login("alice");
    const upgrades = (n: number) => google.until((got) => (ownSpans(got, "cloud.ws.upgrade").length >= n ? ownSpans(got, "cloud.ws.upgrade") : undefined));
    const events = () => h.fetch("/v1/events", { headers: { upgrade: "websocket", "sec-websocket-protocol": `stillfail-events, stillfail-token.${tokens.access_token}` } });

    // Opened at once: nothing.
    const quick = await events();
    assert.equal(quick.status, 101);
    quick.webSocket!.accept();
    quick.webSocket!.close();

    // Not a socket's opening at all: 426.
    assert.equal((await h.fetch("/v1/events")).status, 426);
    const [plain] = await upgrades(1);
    assert.equal(plain.kind, 2);
    assert.equal(plain.parentSpanId, undefined);
    assert.deepEqual(plain.at, { "http.route": "/v1/events", "http.response.status_code": 426, "stillfail.ws.ok": false, "stillfail.sampled_reason": "rejected" });

    // A station's opening signed wrong: 401.
    const station = await key();
    const ts = h.now();
    const forged = await station.sign(`stillfail-station-connect-v1:${h.origin}:${station.id}:${ts - 1}`);
    assert.equal((await h.fetch("/v1/stations/connect", { headers: { upgrade: "websocket", "x-stillfail-station": station.id, "x-stillfail-ts": String(ts), "x-stillfail-signature": forged } })).status, 401);
    const refused = (await upgrades(2))[1]!;
    assert.deepEqual(refused.at, { "http.route": "/v1/stations/connect", "http.response.status_code": 401, "stillfail.ws.ok": false, "stillfail.sampled_reason": "rejected" });
    const lines = await google.until((got) => (ownLines(got, "websocket upgrade rejected").length >= 2 ? ownLines(got, "websocket upgrade rejected") : undefined));
    assert.deepEqual(lines.map((l) => [l.severityText, l.at["log.target"], l.at["log.path"], l.at["log.status"]]).sort(), [["WARN", "ws", "/v1/events", 426], ["WARN", "ws", "/v1/stations/connect", 401]]);

    // Opened, but only after 2 s of the cloud's clock: its account's object answers late.
    const account = await h.object("ACCOUNTS", tokens.subject);
    await account.holdOpening();
    const opening = events();
    await account.openingHeld();
    await later(h, 2);
    await account.letOpen();
    const late = await opening;
    assert.equal(late.status, 101);
    late.webSocket!.accept();
    late.webSocket!.close();
    const slow = (await upgrades(3))[2]!;
    assert.deepEqual(slow.at, { "http.route": "/v1/events", "http.response.status_code": 101, "stillfail.ws.ok": true, "stillfail.sampled_reason": "slow" });
    assert.deepEqual(slow.status, { code: 1 });
    assert.ok(BigInt(slow.endTimeUnixNano) - BigInt(slow.startTimeUnixNano) >= 2_000_000_000n);

    assert.equal(ownSpans(google.got, "cloud.ws.upgrade").length, 3, "the quick opening was none");
    const all = JSON.stringify(google.got.map((g) => g.body));
    for (const secret of [tokens.access_token, station.id, forged, tokens.subject]) assert.ok(!all.includes(secret));
  } finally {
    await h.close();
  }
});

test("telemetry's own calls refused, failing or slow are never a trace or a line through it", async () => {
  const google = fakeGoogle(500);
  const h = await harness({ telemetry: google.answer });
  try {
    const tokens = await h.login("alice");
    // Google refusing: 502; then the sender's budget spent: 429.
    assert.equal((await post(h, batch(), { authorization: `Bearer ${tokens.access_token}` })).status, 502);
    for (let i = 1; i < BATCHES_PER_MINUTE; i++) await post(h, batch(), { authorization: `Bearer ${tokens.access_token}` });
    assert.equal((await post(h, batch(), { authorization: `Bearer ${tokens.access_token}` })).status, 429);
    // One more call that is a trace of its own, after them: its span is the first of the cloud's.
    assert.equal((await h.fetch("/v1/events")).status, 426);
    await google.until((got) => ownSpans(got, "cloud.ws.upgrade")[0]);
    assert.deepEqual(ownSpans(google.got, "cloud.http"), []);
    assert.deepEqual(ownLines(google.got, "rate limited"), []);
    assert.deepEqual(ownLines(google.got, "worker returned 5xx"), []);
  } finally {
    await h.close();
  }
});
