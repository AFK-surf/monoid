import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Admin } from "../src/api/admin.ts";
import { json } from "../src/api/request.ts";
import { RUNTIME_KINDS } from "../src/agents/runtime.ts";
import { Cloud, writeState } from "../src/cloud/state.ts";
import { ALPN, Reader, seenDevicesOf, serve, writeLine } from "../src/mesh/serve.ts";
import { HttpError } from "./reference/views.ts";
import { GrantKey } from "./fake-control-plane.ts";
import { memoryMesh } from "./memory-mesh.ts";

const WS = "01HZZZZZZZZZZZZZZZZZZZZZZZ";
const viewer = { sub: "u", email: "u@x", name: "U", role: "owner", workspace: WS, device: "d" };

test("a cancelled batch is not kept as a successful answer to the same key", async () => {
  const seen: (AbortSignal | undefined)[] = [];
  const readers = { data: "", names: new Map(), read: async (_op: string, _args: unknown, _lang: string, options: { signal?: AbortSignal }) => {
    seen.push(options.signal);
    return "{}";
  } };
  const admin = new Admin(readers as any);
  const aborted = new AbortController();
  aborted.abort();
  const request = { method: "POST", path: "/batch", query: [], headers: { "idempotency-key": "batch" }, body: Buffer.from('{"gets":["/threads/1/entries"]}'), viewer, lang: "en" as const };
  assert.equal((await admin.handle({ ...request, signal: aborted.signal })).status, 503);
  const next = new AbortController();
  assert.equal((await admin.handle({ ...request, signal: next.signal })).status, 200);
  assert.deepEqual(seen, [next.signal], "the retry reads and carries its own cancellation signal");
});

test("abandoning a batch stops its waiting pages and a keyed retry reads them again", async () => {
  let began!: () => void;
  const begun = new Promise<void>((resolve) => { began = resolve; });
  let calls = 0;
  const readers = { data: "", names: new Map(), read: async (_op: string, _args: unknown, _lang: string, options: { signal?: AbortSignal }) => {
    calls++;
    if (calls > 4) return "{}";
    if (calls === 4) began();
    return new Promise<string>((_resolve, reject) => options.signal!.addEventListener("abort", () => reject(new HttpError(503, "read cancelled")), { once: true }));
  } };
  const admin = new Admin(readers as any);
  const controller = new AbortController();
  const request = { method: "POST", path: "/batch", query: [], headers: { "idempotency-key": "pages" }, body: Buffer.from(JSON.stringify({ gets: Array.from({ length: 8 }, () => "/threads/1/entries") })), viewer, lang: "en" as const };
  const pending = admin.handle({ ...request, signal: controller.signal });
  await begun;
  controller.abort();
  assert.equal((await pending).status, 503);
  assert.equal(calls, 4, "the remaining pages were not started");
  assert.equal((await admin.handle({ ...request, signal: new AbortController().signal })).status, 200);
  assert.equal(calls, 12, "the retry reads every page");
});

for (const how of ["let go of", "abandoned by its device"] as const) test(`a batch given a line at a time gives each page as it is read, and once ${how} stops the read under way and starts none`, async () => {
  let calls = 0;
  let waiting: AbortSignal | undefined;
  let began!: () => void;
  const begun = new Promise<void>((resolve) => { began = resolve; });
  const readers = { data: "", names: new Map(), read: async (_op: string, _args: unknown, _lang: string, options: { signal?: AbortSignal; background?: boolean }) => {
    calls++;
    assert.equal(options.background, true);
    if (calls === 1) return '{"page":1}';
    waiting = options.signal;
    began();
    return new Promise<string>((_resolve, reject) => options.signal!.addEventListener("abort", () => reject(new HttpError(503, "read cancelled")), { once: true }));
  } };
  const admin = new Admin(readers as any);
  const device = new AbortController();
  const answer = await admin.handle({ method: "POST", path: "/batch", query: [], headers: { Accept: "application/x-ndjson", "idempotency-key": "lines" }, body: Buffer.from(JSON.stringify({ gets: Array.from({ length: 8 }, (_, i) => `/threads/${i + 1}/entries`) })), viewer, lang: "en", signal: device.signal });
  assert.equal(answer.status, 200);
  assert.equal(answer.headers["content-type"], "application/x-ndjson");
  assert.equal(answer.headers["cache-control"], "no-store");
  assert.ok(!Buffer.isBuffer(answer.body));
  const it = (answer.body as AsyncIterable<Buffer>)[Symbol.asyncIterator]();
  const first = await it.next();
  assert.equal(first.value!.toString(), '{"status":200,"body":{"page":1}}\n', "the first page, while the second is not read yet");
  const pending = it.next();
  await begun;
  assert.equal(waiting?.aborted, false);
  if (how === "let go of") await it.return!();
  else device.abort();
  assert.equal(waiting?.aborted, true);
  assert.deepEqual(await pending, { done: true, value: undefined });
  assert.deepEqual(await it.next(), { done: true, value: undefined });
  assert.equal(calls, 2, "the pages after the one under way were not started");
});

test("a batch given a line at a time is said to a client from before as the whole batch is", async () => {
  const sessions = [{ key: "cc", runtime: "claude" }, { key: "hm", runtime: "hermes" }];
  const readers = { data: "", names: new Map(), read: async (op: string, args: any) => (op === "session" ? JSON.stringify({ session: sessions.find((s) => s.key === args.key) }) : "[]") };
  const admin = new Admin(readers as any);
  const ask = async (headers: Record<string, string>) => {
    const answer = await admin.handle({ method: "POST", path: "/batch", query: [], headers, body: Buffer.from('{"gets":["/sessions/cc","/sessions/hm","/nope"]}'), viewer, lang: "en" });
    if (Buffer.isBuffer(answer.body)) return JSON.parse(answer.body.toString()).answers;
    let text = "";
    for await (const chunk of answer.body) text += chunk.toString();
    return text.trimEnd().split("\n").map((l) => JSON.parse(l));
  };
  const lines = await ask({ accept: "application/x-ndjson" });
  assert.deepEqual(lines[0], { status: 200, body: { session: sessions[0] } });
  assert.equal(lines[1].status, 426, "a runtime it cannot read: told to update, as a GET of it is");
  assert.deepEqual(lines[2], { status: 400, body: { error: "not read in a batch: /nope" } });
  assert.deepEqual(lines, await ask({}), "each line as the whole batch's answer");
  const modern = await ask({ accept: "application/vnd.stillfail.batch-lines+json, application/json", "stillfail-runtimes": RUNTIME_KINDS.join(",") });
  assert.deepEqual(modern[1], { status: 200, body: { session: sessions[1] } });
  // Content-type negotiation echoes the matched streaming token, keeping old NDJSON and falling back to whole JSON.
  const vnd = await admin.handle({ method: "POST", path: "/batch", query: [], headers: { accept: "application/vnd.stillfail.batch-lines+json, application/json" }, body: Buffer.from('{"gets":["/sessions/cc"]}'), viewer, lang: "en" });
  assert.equal(vnd.headers["content-type"], "application/vnd.stillfail.batch-lines+json");
  assert.ok(!Buffer.isBuffer(vnd.body));
  const oldNdjson = await admin.handle({ method: "POST", path: "/batch", query: [], headers: { accept: "application/x-ndjson, application/json" }, body: Buffer.from('{"gets":["/sessions/cc"]}'), viewer, lang: "en" });
  assert.equal(oldNdjson.headers["content-type"], "application/x-ndjson");
  assert.ok(!Buffer.isBuffer(oldNdjson.body));
  const whole = await admin.handle({ method: "POST", path: "/batch", query: [], headers: { accept: "application/json" }, body: Buffer.from('{"gets":["/sessions/cc"]}'), viewer, lang: "en" });
  assert.equal(whole.headers["content-type"], "application/json");
  assert.ok(Buffer.isBuffer(whole.body));
});

for (const path of ["/batch", "/changed/sessions"]) test(`POST ${path} under a key it was asked with before is read again`, async () => {
  let reads = 0;
  const readers = { data: "", names: new Map(), read: async () => {
    reads++;
    return path === "/batch" ? `{"n":${reads}}` : `{"order":["s${reads}"],"rows":[]}`;
  } };
  const admin = new Admin(readers as any);
  const body = Buffer.from(path === "/batch" ? '{"gets":["/threads/1/entries"]}' : '{"held":{}}');
  const ask = async () => JSON.parse(((await admin.handle({ method: "POST", path, query: [], headers: { "idempotency-key": "same", "stillfail-runtimes": RUNTIME_KINDS.join(",") }, body, viewer, lang: "en" })).body as Buffer).toString());
  const first = await ask();
  const second = await ask();
  assert.equal(reads, 2, "read each time, never the answer kept under the key");
  assert.notDeepEqual(first, second);
  assert.equal((admin as any).slots.size, 0, "nothing kept under the key");
});

test("a write and its keyed answer finish even if its caller stops waiting", async () => {
  const seen: (AbortSignal | undefined)[] = [];
  const readers = { data: "", names: new Map(), read: async (_op: string, _args: unknown, _lang: string, options: { signal?: AbortSignal }) => {
    seen.push(options.signal);
    return "{}";
  } };
  const admin = new Admin(readers as any);
  let writes = 0;
  (admin as any).routes.push({ method: "POST", pattern: /^\/test-write$/, handle: async (r: unknown) => {
    writes++;
    await (admin as any).tools.read(r, "thread", {});
    return json(200, "{}");
  } });
  const controller = new AbortController();
  controller.abort();
  const request = { method: "POST", path: "/test-write", query: [], headers: { "idempotency-key": "write" }, body: Buffer.alloc(0), viewer, lang: "en" as const, signal: controller.signal };
  assert.equal((await admin.handle(request)).status, 200);
  assert.equal((await admin.handle(request)).status, 200);
  assert.equal(writes, 1);
  assert.deepEqual(seen, [undefined]);
});

for (const batch of [false, true]) test(`a device abandoning ${batch ? "a batch" : "a read"} cancels its pending reader`, async (t) => {
  const mesh = memoryMesh();
  const bind = () => mesh.bind({ secretKey: randomBytes(32), alpns: [ALPN], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  const [at, device] = await Promise.all([bind(), bind()]);
  const data = mkdtempSync(join(tmpdir(), "mesh-reader-cancel-"));
  const grant = new GrantKey("k1");
  writeState(data, { origin: "o", station: at.id(), workspace: WS, workspace_name: "Team", name: "s0", relay_url: "", relay_urls: [], grant_keys: { keys: [grant.jwk] }, peers: [], revocations: [] });
  const cloud = new Cloud(data);
  let begin!: (signal: AbortSignal | undefined) => void;
  const begun = new Promise<AbortSignal | undefined>((resolve) => { begin = resolve; });
  let release!: () => void;
  const released = new Promise<void>((resolve) => { release = resolve; });
  const readers = { data, names: new Map(), read: async (_op: string, _args: unknown, _lang: string, options: { signal?: AbortSignal }) => {
    begin(options.signal);
    await released;
    return "{}";
  } };
  const admin = new Admin(readers as any);
  // what serves each connection is awaited before its data goes: a batch's handler still read and wrote it as the
  // directory was removed (ENOTEMPTY)
  const served: Promise<unknown>[] = [];
  const loop = (async () => {
    for (;;) {
      const conn = await at.accept();
      if (!conn) return;
      served.push(serve({ cloud, admin, up: () => true }, conn).catch(() => {}));
    }
  })();
  t.after(async () => {
    release();
    await Promise.all([at.close(), device.close()]);
    await loop;
    await Promise.allSettled(served);
    cloud.close();
    await seenDevicesOf(cloud).written();
    rmSync(data, { recursive: true, force: true });
  });
  const conn = await device.connect({ id: at.id() }, ALPN);
  const now = Math.floor(Date.now() / 1000);
  const credential = grant.credential({ typ: "stillfail-member+jwt" }, { iss: "stillfail-cloud", sub: "usr_a", email: "a@x", name: "a", ws: WS, role: "owner", device: device.id(), sid: "s", iat: now, exp: now + 3600 });
  const first = await conn.openBi();
  await writeLine(first, { credential, protocol: 2 });
  assert.equal((await new Reader(first).line()).ok, true);
  const stream = await conn.openBi();
  await writeLine(stream, { method: batch ? "POST" : "GET", path: batch ? "/admin/api/batch" : "/admin/api/chats", headers: {} });
  if (batch) await stream.write(Buffer.from('{"gets":["/threads/1/entries"]}'));
  await stream.finish();
  const signal = await begun;
  await stream.reset(0);
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(signal?.aborted, true);
});
