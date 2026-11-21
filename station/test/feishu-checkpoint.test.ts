// A Feishu message not kept by the hub must remain in the reconnect window, even when newer messages succeed.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { FeishuSurface } from "../src/feishu/surface.ts";
import { FeishuThreads } from "../src/feishu/threads.ts";
import { FeishuClient } from "../src/feishu/web.ts";
import type { ChatEvent } from "../src/sessions/chat.ts";
import { given } from "./hub-fakes.ts";

const item = (id: string, at: number, chat = "oc_g") => ({ message_id: id, chat_id: chat, chat_type: "p2p", create_time: String(at), msg_type: "text", body: { content: JSON.stringify({ text: id }) }, sender: { id: "ou_ada", sender_type: "user" } });
const event = (id: string, at: number, chat = "oc_g") => ({ header: { event_type: "im.message.receive_v1" }, event: { sender: { sender_type: "user", sender_id: { open_id: "ou_ada" } }, message: { ...item(id, at, chat), message_type: "text", content: JSON.stringify({ text: id }) } } });
const kept = async (_event: ChatEvent) => {};

function fixture(since = 1000) {
  const dir = mkdtempSync(join(tmpdir(), "feishu-checkpoint-"));
  const threads = new FeishuThreads(join(dir, "threads.json"));
  threads.begin("fs", "oc_g", "om_root");
  if (since > 0) threads.heard("fs", "oc_g", since);
  const client = new FeishuClient("cli_test", "secret", "feishu");
  const items = [item("om_failed", 2000), item("om_later", 3000)];
  client.api = async (_method, path, _body, query) => {
    assert.equal(path, "/open-apis/im/v1/messages");
    assert.equal(query?.container_id_type, "chat");
    return { code: 0, data: { items: items.filter((i) => Number(i.create_time) >= Number(query!.start_time) * 1000), has_more: false } };
  };
  const surfaces: FeishuSurface[] = [];
  const surface = (book = threads) => {
    const s = new FeishuSurface({ connect: "fs", appId: "cli_test", appSecret: "secret", domain: "feishu", threads: book, client });
    surfaces.push(s);
    return s;
  };
  return { threads, client, surface, items, close: async () => { for (const s of surfaces) await s.stop(); await threads.written(); rmSync(dir, { recursive: true, force: true }); } };
}

test("Feishu: a failed message remains recoverable after a newer success and a restart", async () => {
  const r = fixture();
  try {
    const s = r.surface();
    await assert.rejects(s.take(event("om_failed", 2000), async () => { throw new Error("store unavailable"); }), /store unavailable/);
    await s.take(event("om_later", 3000), kept);
    await r.threads.written();
    const reopened = new FeishuThreads(r.threads.path);
    const recovered: string[] = [];
    await r.surface(reopened).catchUp(async (e) => { if (e.type === "message") recovered.push(e.message.ts); });
    assert.deepEqual(recovered, ["om_failed", "om_later"]);
    assert.deepEqual(reopened.conversations("fs"), [["oc_g", 3000]]);
    await reopened.written();
  } finally { await r.close(); }
});

test("Feishu: a newer concurrent success cannot checkpoint past an unfinished or failed message", async () => {
  const r = fixture();
  const entered = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
  try {
    const s = r.surface();
    const failed = assert.rejects(s.take(event("om_failed", 2000), async () => { entered.resolve(); await release.promise; throw new Error("store unavailable"); }), /store unavailable/);
    await given(entered.promise, "the earlier delivery starts");
    await s.take(event("om_later", 3000), kept);
    assert.ok(r.threads.conversations("fs")[0]![1] < 2000);
    release.resolve();
    await failed;
    assert.ok(r.threads.conversations("fs")[0]![1] < 2000);
    await s.take(event("om_failed", 2000), kept);
    assert.deepEqual(r.threads.conversations("fs"), [["oc_g", 3000]]);
  } finally { release.resolve(); await r.close(); }
});

for (const failure of ["request", "delivery"]) test(`Feishu: live success cannot advance a catch-up whose ${failure} fails`, async () => {
  const r = fixture();
  const reading = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
  try {
    const s = r.surface();
    const api = r.client.api.bind(r.client);
    r.client.api = async (...args) => { reading.resolve(); await release.promise; if (failure === "request") throw new Error("temporarily unavailable"); return api(...args); };
    const failed = assert.rejects(s.catchUp(async () => { throw new Error("temporarily unavailable"); }), /temporarily unavailable/);
    await given(reading.promise, "catch-up starts its request");
    await s.take(event("om_later", 3000), kept);
    release.resolve();
    await failed;
    r.client.api = api;
    const recovered: string[] = [];
    await s.catchUp(async (e) => { if (e.type === "message") recovered.push(e.message.ts); });
    assert.deepEqual(recovered, ["om_failed", "om_later"]);
    assert.deepEqual(r.threads.conversations("fs"), [["oc_g", 3000]]);
  } finally { release.resolve(); await r.close(); }
});

test("Feishu: a concurrent duplicate completing late cannot rewind newer accepted messages", async () => {
  const r = fixture();
  const entered = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
  let first: Promise<unknown> | undefined;
  try {
    const s = r.surface();
    first = s.take(event("om_duplicate", 2000), async () => { entered.resolve(); await release.promise; });
    await given(entered.promise, "the first delivery starts");
    await s.take(event("om_duplicate", 2000), kept);
    await s.take(event("om_later", 3000), kept);
    release.resolve();
    await first;
    assert.deepEqual(r.threads.conversations("fs"), [["oc_g", 3000]]);
  } finally { release.resolve(); await first; await r.close(); }
});

test("Feishu: reaching the catch-up page limit checkpoints only what was read, including its boundary", async () => {
  const r = fixture();
  try {
    const s = r.surface();
    let pages = 0;
    r.client.api = async () => {
      if (pages === 0) await s.take(event("om_live", 20_000), kept);
      const n = ++pages;
      return { code: 0, data: { items: [item(`om_page${n}`, 1000 + n * 1000)], has_more: true, page_token: String(n) } };
    };
    await s.catchUp(kept);
    assert.equal(pages, 10);
    assert.deepEqual(r.threads.conversations("fs"), [["oc_g", 10_999]], "the last millisecond can contain another message on the next page");
    r.client.api = async (_method, _path, _body, query) => {
      assert.equal(query?.start_time, "1", "a continuation keeps the original query with its opaque token");
      assert.equal(query?.page_token, "10");
      return { code: 0, data: { items: [item("om_page10", 11_000), item("om_boundary", 11_000), item("om_live", 20_000)], has_more: false } };
    };
    const recovered: string[] = [];
    await s.catchUp(async (e) => { if (e.type === "message") recovered.push(e.message.ts); });
    assert.deepEqual(recovered, ["om_page10", "om_boundary", "om_live"]);
    assert.deepEqual(r.threads.conversations("fs"), [["oc_g", 20_000]]);
  } finally { await r.close(); }
});

test("Feishu: all chats hold their catch-up position before the first chat's request", async () => {
  const r = fixture();
  try {
    r.threads.begin("fs", "oc_other", "om_root2");
    r.threads.heard("fs", "oc_other", 1000);
    const s = r.surface();
    r.client.api = async (_method, _path, _body, query) => {
      if (query?.container_id === "oc_g") {
        await s.take(event("om_live", 3000, "oc_other"), kept);
        throw new Error("first chat unavailable");
      }
      throw new Error("the second chat should not have been requested yet");
    };
    await assert.rejects(s.catchUp(kept), /first chat unavailable/);
    assert.deepEqual(r.threads.conversations("fs"), [["oc_g", 1000], ["oc_other", 1000]]);
    r.client.api = async (_method, _path, _body, query) => ({ code: 0, data: { items: query?.container_id === "oc_other" ? [item("om_away", 2000, "oc_other"), item("om_live", 3000, "oc_other")] : [], has_more: false } });
    const recovered: string[] = [];
    await s.catchUp(async (e) => { if (e.type === "message") recovered.push(e.message.ts); });
    assert.deepEqual(recovered, ["om_away", "om_live"]);
  } finally { await r.close(); }
});

test("Feishu: a failed older delivery rewinds the reconnect window, including equal timestamps", async () => {
  const r = fixture(3000);
  try {
    const s = r.surface();
    await assert.rejects(s.take(event("om_failed", 2000), async () => { throw new Error("store unavailable"); }), /store unavailable/);
    await s.take(event("om_same_time", 2000), kept);
    assert.ok(r.threads.conversations("fs")[0]![1] < 2000);
    await s.take(event("om_failed", 2000), kept);
    assert.deepEqual(r.threads.conversations("fs"), [["oc_g", 3000]]);
  } finally { await r.close(); }
});

test("Feishu: failure of the first timed delivery leaves a reconnect cursor", async () => {
  const r = fixture(0);
  try {
    const s = r.surface();
    await assert.rejects(s.take(event("om_failed", 2000), async () => { throw new Error("store unavailable"); }), /store unavailable/);
    const since = r.threads.conversations("fs")[0]![1];
    assert.ok(since > 0 && since < 2000);
    const recovered: string[] = [];
    await s.catchUp(async (e) => { if (e.type === "message") recovered.push(e.message.ts); });
    assert.deepEqual(recovered, ["om_failed", "om_later"]);
  } finally { await r.close(); }
});

for (const count of [2, 501]) test(`Feishu: an unavailable failed message does not trap later history in its first ${count > 500 ? "ten pages" : "window"}`, async () => {
  const r = fixture();
  try {
    const s = r.surface();
    await assert.rejects(s.take(event("deleted", 2000), async () => { throw new Error("hub failed"); }), /hub failed/);
    await s.take(event("live", 3000), kept);
    const history = Array.from({ length: count }, (_, n) => item(`history_${n}`, 4000 + n * 1000));
    r.client.api = async (_method, _path, _body, query) => {
      const all = history.filter((m) => +m.create_time >= +query!.start_time! * 1000);
      const from = Number(query?.page_token ?? 0);
      const items = all.slice(from, from + 50);
      const more = from + items.length < all.length;
      return { code: 0, data: { items, has_more: more, ...(more ? { page_token: String(from + items.length) } : {}) } };
    };
    const recovered = new Set<string>();
    for (let n = 0; n < 3; n++) await s.catchUp(async (e) => { if (e.type === "message") recovered.add(e.message.ts); });
    assert.equal(recovered.size, count, "every later message is reachable across bounded runs");
    assert.ok(r.threads.conversations("fs")[0]![1] < 2000, "absence from history does not claim the failed message was kept");
    await s.take(event("deleted", 2000), kept);
  } finally { await r.close(); }
});

test("Feishu: one concurrent catch-up cannot release another connection's unread history", async () => {
  const r = fixture();
  const firstEntered = Promise.withResolvers<void>(), firstRelease = Promise.withResolvers<void>();
  const secondEntered = Promise.withResolvers<void>(), secondRelease = Promise.withResolvers<void>();
  let first: Promise<void> | undefined, second: Promise<unknown> | undefined;
  try {
    const s = r.surface();
    let asks = 0;
    r.client.api = async () => {
      const n = ++asks;
      if (n === 1) {
        firstEntered.resolve(); await firstRelease.promise;
        return { code: 0, data: { items: [item("old", 2000)], has_more: false } };
      }
      if (n === 2) return { code: 0, data: { items: [item("old", 2000)], has_more: true, page_token: "next" } };
      secondEntered.resolve(); await secondRelease.promise;
      throw new Error("new connection's next page failed");
    };
    first = s.catchUp(kept);
    await given(firstEntered.promise, "the first connection starts its history read");
    second = assert.rejects(s.catchUp(kept), /next page failed/);
    await given(secondEntered.promise, "the second connection requests its next page");
    firstRelease.resolve(); await first;
    await s.take(event("live", 4000), kept);
    secondRelease.resolve(); await second;
    assert.ok(r.threads.conversations("fs")[0]![1] < 3000);
    r.client.api = async (_method, _path, _body, query) => ({ code: 0, data: { items: [item("old", 2000), item("missed", 3000), item("live", 4000)].filter((m) => +m.create_time >= +query!.start_time! * 1000), has_more: false } });
    const recovered: string[] = [];
    await s.catchUp(async (e) => { if (e.type === "message") recovered.push(e.message.ts); });
    assert.ok(recovered.includes("missed"));
    assert.deepEqual(r.threads.conversations("fs"), [["oc_g", 4000]], "the retry retires the failed run's hold");
  } finally {
    firstRelease.resolve(); secondRelease.resolve();
    await Promise.allSettled([first, second]); await r.close();
  }
});

for (const failure of ["request", "delivery"]) test(`Feishu: a continuation ${failure} failure retries unread history`, async () => {
  const r = fixture();
  try {
    const s = r.surface();
    await assert.rejects(s.take(event("deleted", 2000), async () => { throw new Error("hub failed"); }), /hub failed/);
    const history = Array.from({ length: 502 }, (_, n) => item(`history_${n}`, 4000 + n * 1000));
    let rejectToken = false;
    const requested: string[] = [];
    r.client.api = async (_method, _path, _body, query) => {
      const token = String(query?.page_token ?? "");
      requested.push(token);
      if (rejectToken && token !== "") { rejectToken = false; throw new Error("page token expired"); }
      const from = Number(token);
      const items = history.slice(from, from + 50);
      const more = from + items.length < history.length;
      return { code: 0, data: { items, has_more: more, ...(more ? { page_token: String(from + items.length) } : {}) } };
    };
    await s.catchUp(kept);
    rejectToken = failure === "request";
    await assert.rejects(s.catchUp(async () => { throw new Error("hub unavailable"); }), failure === "request" ? /token expired/ : /hub unavailable/);
    assert.equal(requested.at(-1), "500", "the bounded run resumes beyond its first 500 messages");
    const recovered: string[] = [];
    const before = requested.length;
    for (let n = 0; n < 2; n++) await s.catchUp(async (e) => { if (e.type === "message") recovered.push(e.message.ts); });
    assert.equal(requested[before], failure === "request" ? "" : "500", "an invalid remote token restarts safely; a failed delivery retries the same page");
    assert.ok(recovered.includes("history_500") && recovered.includes("history_501"));
  } finally { await r.close(); }
});
