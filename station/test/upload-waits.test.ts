// Files that come up to the station and go between stations make its main thread wait on no synchronous call of
// node:fs (station/AGENTS.md, the main thread waits on nothing): an upload of 50 MB, an upload in parts of up to 1 GiB,
// a message taking its pictures and films, and a file another station's session reads or sends along, each of which
// held every device and agent behind it as long as the disk took; so do an agent's post with a picture and a film
// (chat_post's files) and those a person shared in Slack or Feishu, fetched and measured as they come. Counted as main-thread-waits.test.ts counts them.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { after, test } from "node:test";
import { Admin } from "../src/api/admin.ts";
import { savePart } from "../src/api/routes/hub.ts";
import type { Request } from "../src/api/request.ts";
import { Jobs } from "../src/jobs/jobs.ts";
import { timeFiles } from "../src/ops/file-waits.ts";
import { WAITED_MS } from "../src/ops/waits.ts";
import { loadMesh } from "../src/mesh/native.ts";
import { Readers } from "../src/read/pool.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { Hub, sessionKey } from "../src/sessions/hub.ts";
import { shownFacts, shownFactsSoon } from "./reference/image-size.ts";
import { InternalChat } from "../src/sessions/internal.ts";
import { attach } from "../src/sessions/conversations.ts";
import type { ChatSurface } from "../src/sessions/chat.ts";
import { claim, fetchAttachments, fileForPeer, putForPeer, sendable, sendAlong } from "../src/sessions/peer-files.ts";
import { Store } from "../src/store/store.ts";
import { exif, film, jpeg } from "../../client/core-ts/test/media-bytes.ts";
import { FakeDriver, Rig, say, settle } from "./hub-fakes.ts";

// Each call takes WAITED_MS by this clock: every one is put down with who made it.
let at = 0;
const files = timeFiles(() => (at += WAITED_MS));
after(() => files.stop());

/// The synchronous calls of node:fs `work` made on this thread, by who made them.
async function waited<T>(work: () => Promise<T>): Promise<{ value: T; calls: number; by: string[] }> {
  files.take();
  const value = await work();
  const w = files.take();
  return { value, calls: w.calls, by: [...w.by.keys()] };
}

const viewer = { sub: "u", email: "a@x", name: "A", role: "member", workspace: "w", device: "d" };

function rig() {
  const data = mkdtempSync(join(tmpdir(), "uw-"));
  const config = hubConfig({ profiles: [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["opus"] }] }, data);
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const claude = new FakeDriver("claude");
  const hub = new Hub({ config: () => config, store, chats: () => undefined, drivers: [claude], mcpUrl: "http://127.0.0.1:1/mcp", internal: new InternalChat(), runners: () => [] });
  const jobs = new Jobs({ store, data, notify: () => {}, link: () => null });
  hub.setJobs(jobs);
  const readers = new Readers(data, 1);
  readers.processes = () => hub.processes();
  const admin = new Admin(readers, { store, agents: { hub, jobs } as any });
  const ask = async (method: string, path: string, body?: unknown, query: [string, string][] = []) => {
    const raw = Buffer.isBuffer(body) ? body : Buffer.from(body === undefined ? "" : typeof body === "string" ? body : JSON.stringify(body));
    const r: Request = { method, path, query, headers: {}, body: raw, viewer, lang: "en" };
    const a = await admin.handle(r);
    return [a.status, JSON.parse(String(a.body))] as const;
  };
  const close = async () => {
    await hub.shutdown();
    await jobs.shutdown();
    readers.close();
    store.close();
    rmSync(data, { recursive: true, force: true });
  };
  return { data, store, ask, close };
}

test("a film's and a picture's facts read off the main thread are those read on it", async () => {
  const dir = mkdtempSync(join(tmpdir(), "uw-facts-"));
  const shown: [string, Uint8Array][] = [
    ["clip.mp4", film(1920, 1080, { ms: 12_500, frames: 375 })],
    ["recording.mp4", film(1140, 2616, { at: "end", turn: 90, ms: 61_000, frames: 1830 })],
    ["with-sound.mp4", film(640, 360, { sound: true, large: true })],
    ["photo.jpg", jpeg(4032, 3024, exif(6, true, 70_000))],
    ["notes.txt", new TextEncoder().encode("plain text")],
  ];
  for (const [name, bytes] of shown) writeFileSync(join(dir, name), bytes);
  for (const [name] of shown) {
    const path = join(dir, name);
    const soon = await waited(() => shownFactsSoon(path));
    assert.deepEqual(soon.value, shownFacts(path), name);
    assert.deepEqual(soon.by, [], name);
  }
  assert.equal(await shownFactsSoon(join(dir, "missing.mp4")), null);
  rmSync(dir, { recursive: true, force: true });
});

test("uploads, uploads in parts and a message taking a picture and a film wait on no synchronous file call", async () => {
  const r = rig();
  try {
    const [, made] = await r.ask("POST", "/sessions", { runtime: "claude" });
    const id = made.thread.id;
    const workspace = r.store.getSession(made.key)!.workspace;
    // (the mesh's addon, the pictures' codecs, loaded once: a station has it loaded before it serves)
    loadMesh();
    assert.equal((await r.ask("POST", `/threads/${id}/messages`, { text: "first" }))[0], 200);
    // (its turn going, so what is timed is the requests, not an agent's process started beside them: agents/*)
    await settle();
    const sha = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");
    const part = (pid: string, offset: number, body: Uint8Array, size: number, extra: [string, string][] = []) =>
      r.ask("POST", "/uploads/parts", Buffer.from(body), [["id", pid], ["name", "clip.mp4"], ["size", String(size)], ["offset", String(offset)], ...extra]);
    const clip = film(1920, 1080, { ms: 12_500, frames: 375, large: true });
    const photo = jpeg(1140, 2616);
    const half = Math.floor(clip.length / 2);
    const { value, calls, by } = await waited(async () => {
      const [upStatus, up] = await r.ask("POST", "/uploads", Buffer.from(photo), [["name", "photo.jpg"]]);
      // In parts: one, asked again (its answer lost), the next asked twice at once, then whole.
      const first = await part("clipclip01", 0, clip.subarray(0, half), clip.length);
      const again = await part("clipclip01", 0, clip.subarray(0, half), clip.length);
      const [one, two] = await Promise.all([part("clipclip01", half, clip.subarray(half), clip.length), part("clipclip01", half, clip.subarray(half), clip.length)]);
      // Sent again by its content: copied from where it is, none of it coming.
      const cloned = await part("clipclip02", 0, new Uint8Array(0), clip.length, [["sha256", sha(clip)]]);
      const [sent, said] = await r.ask("POST", `/threads/${id}/messages`, { text: "look", attachments: [{ path: up.path, name: "photo.jpg" }, { path: two[1].file.path, name: "clip.mp4" }] });
      return { upStatus, up, first, again, one, two, cloned, sent, said };
    });
    assert.deepEqual(by, [], "no synchronous call of node:fs");
    assert.equal(calls, 0);
    assert.equal(value.upStatus, 200);
    assert.deepEqual(value.first, [200, { have: half }]);
    assert.deepEqual(value.again, [200, { have: half }]);
    // The two asked at once took their turns: one put it together, the other was given the same file.
    assert.deepEqual(value.one, value.two);
    assert.equal(value.two[1].have, clip.length);
    assert.equal(value.cloned[1].have, clip.length);
    assert.notEqual(value.cloned[1].file.path, value.two[1].file.path);
    assert.ok(Buffer.from(readFileSync(value.cloned[1].file.path)).equals(Buffer.from(clip)));
    assert.equal(value.sent, 200);
    const message = r.store.messagesBefore(id, null, 10).find((m) => m.n === value.said.n)!;
    const uploads = join(workspace, "uploads");
    assert.deepEqual(message.attachments, [
      { name: "photo.jpg", path: join(uploads, basename(value.up.path)), size: 0, width: 1140, height: 2616 },
      { name: "clip.mp4", path: join(uploads, basename(value.two[1].file.path)), size: 0, width: 1920, height: 1080, duration: 12_500, frames: 375 },
    ]);
    assert.ok(Buffer.from(readFileSync(message.attachments[1]!.path)).equals(Buffer.from(clip)));
    assert.ok(!existsSync(join(r.data, "uploads", ".part-clipclip01")));
  } finally {
    await settle();
    await r.close();
  }
});

// savePart itself, as the route calls it once a request is in: what comes before it there (the staged uploads swept)
// waits on the disk, so the order requests reach it in is the machine's, not the order they were sent in.
test("parts of one upload asked at once are added in turn, each once; other uploads' alongside", async () => {
  const dir = mkdtempSync(join(tmpdir(), "uw-parts-"));
  try {
    const body = Buffer.from("0123456789");
    const part = (id: string, offset: number, end: number) => savePart(body.subarray(offset, end), dir, { id, name: "n.txt", size: 10, offset }, "en");
    const answers = await Promise.all([part("sameid0001", 0, 4), part("sameid0001", 0, 4), part("sameid0001", 2, 7), part("otherid001", 0, 10), part("sameid0001", 4, 10)]);
    assert.deepEqual(answers.slice(0, 3), [{ have: 4 }, { have: 4 }, { have: 7 }]);
    assert.equal(readFileSync(answers[3]!.file!.path, "utf8"), "0123456789");
    assert.equal(readFileSync(answers[4]!.file!.path, "utf8"), "0123456789");
    // The same content named by its digest as it came in parts: sent again, copied.
    const sha = createHash("sha256").update(body).digest("hex");
    const again = await savePart(Buffer.alloc(0), dir, { id: "sameid0002", name: "n.txt", size: 10, offset: 0, sha256: sha }, "en");
    assert.equal(readFileSync(again.file!.path, "utf8"), "0123456789");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a file sent along to another station's session and one read from a chat there wait on no synchronous file call", async () => {
  const r = new Rig({ link: true });
  const [a, b] = [say("<@UBOT> draw it"), say("<@UBOT> look at it")];
  await r.accept(a);
  await r.accept(b);
  await settle();
  const [keyA, keyB] = [sessionKey("cl", "C1", a.threadTs), sessionKey("cl", "C1", b.threadTs)];
  const clip = film(640, 360, { ms: 4000, frames: 120 });
  writeFileSync(join(r.session(keyB).workspace, "clip.mp4"), clip);
  mkdirSync(join(r.session(keyB).workspace, "notes"), { recursive: true });
  writeFileSync(join(r.session(keyB).workspace, "notes", "a.txt"), "seen it");
  // Station "far" is this one again, answering as it would over the transport.
  const call = async (_station: string, request: any) => (request.method === "session.put" ? putForPeer(r.hub, "near", request) : fileForPeer(r.hub, request));
  const { value, by } = await waited(async () => {
    const along = await sendable(r.hub, keyB, ["clip.mp4", "notes/a.txt"]);
    const sent = await sendAlong(call, "far", keyB, keyA, along);
    const claimed = await claim(r.hub, "near", keyB, keyA, sent);
    const listed = claimed.map((f) => ({ path: f.path, name: f.name, size: f.size }));
    const fetched = await fetchAttachments(r.hub, keyB, call, "far", keyA, listed, []);
    // Read again: what is here already is not fetched again.
    const again = await fetchAttachments(r.hub, keyB, call, "far", keyA, listed, []);
    const chunk = await fileForPeer(r.hub, { chat: keyA, path: claimed[1]!.path, offset: 0 });
    return { along, claimed, fetched, again, chunk };
  });
  assert.deepEqual(by, [], "no synchronous call of node:fs");
  assert.deepEqual(value.along.map((f) => [f.name, f.size]), [["clip.mp4", clip.length], ["a.txt", 7]]);
  assert.deepEqual(value.claimed.map((f) => [f.name, f.size, f.width, f.height, f.duration, f.frames]), [["clip.mp4", clip.length, 640, 360, 4000, 120], ["a.txt", 7, undefined, undefined, undefined, undefined]]);
  const here = join(r.session(keyB).workspace, "uploads", "far");
  assert.deepEqual(value.fetched.left, []);
  assert.deepEqual([...value.fetched.here.values()], value.claimed.map((f) => join(here, basename(f.path))));
  assert.deepEqual(value.again.here, value.fetched.here);
  assert.ok(readFileSync(value.fetched.here.get(value.claimed[0]!.path)!).equals(Buffer.from(clip)));
  assert.deepEqual([Buffer.from(value.chunk.data, "base64").toString(), value.chunk.size, value.chunk.eof], ["seen it", 7, true]);
  await assert.rejects(sendable(r.hub, keyB, ["missing.txt"]), /no such file/);
  await assert.rejects(sendable(r.hub, keyB, ["notes"]), /not a file/);
  await assert.rejects(claim(r.hub, "near", keyB, keyA, [{ id: "nope", name: "x.txt" }]), /did not all arrive/);
  await r.close();
});

test("an agent's post with a picture and a film, and those shared in Slack, wait on no synchronous file call", async () => {
  const r = new Rig();
  const m = say("<@UBOT> draw it");
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  const workspace = r.session(key).workspace;
  const clip = film(1920, 1080, { ms: 12_500, frames: 375, large: true });
  const photo = jpeg(1140, 2616);
  writeFileSync(join(workspace, "pose.jpg"), photo);
  writeFileSync(join(workspace, "take.mp4"), clip);
  const shared = new Map([["F1", photo], ["F2", clip]]);
  const chat = { download: async (f: { id: string }) => shared.get(f.id)! } as unknown as ChatSurface;
  const { value, by, calls } = await waited(async () => {
    const posted = await attach(r.hub, key, ["pose.jpg", join(workspace, "take.mp4")]);
    const fetched = await r.hub.fetched(chat, key, "look", [
      { id: "F1", name: "photo.jpg", size: photo.length, url: null },
      { id: "F2", name: "clip.mp4", size: clip.length, url: null },
    ]);
    return { posted, fetched };
  });
  assert.deepEqual(by, [], "no synchronous call of node:fs");
  assert.equal(calls, 0);
  const shown = (a: { name: string; size: number; width?: number; height?: number; duration?: number; frames?: number }) => [a.name, a.size, a.width, a.height, a.duration, a.frames];
  const want = [["pose.jpg", photo.length, 1140, 2616, undefined, undefined], ["take.mp4", clip.length, 1920, 1080, 12_500, 375]];
  assert.deepEqual(value.posted.map(shown), want);
  assert.deepEqual(value.fetched.attachments.map(shown), [["photo.jpg", ...want[0]!.slice(1)], ["clip.mp4", ...want[1]!.slice(1)]]);
  for (const a of [...value.posted, ...value.fetched.attachments]) assert.ok(Buffer.from(readFileSync(a.path)).equals(Buffer.from(a.name.endsWith(".mp4") ? clip : photo)));
  assert.equal(value.fetched.text, "look");
  await r.close();
});
