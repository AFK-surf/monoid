// A request's bytes whose own source fails as they go (a file truncated, rewritten or deleted while it is read): the
// caller is told what failed, not that the other station answered nothing. Over the front (front.ts `FrontStream`),
// as over the memory mesh here, a stream reset gives a read waiting on it its end: the sender's reset, made as its
// source failed, would have its reader read "no answer" before the failure was known (mesh/peer.ts `call`), and a
// hand-over's first pass failed whole on a file its chat's agent was writing (drill 3b, 2026-11-15). A chat's files'
// pass (replica/sending.ts `sendGathered`, not `strict`) leaves such a file for the next gathering and goes on.
import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Cloud } from "../src/cloud/state.ts";
import { PEER_ALPN, PEER_BYTES_ALPN, peerCall, servePeer } from "../src/mesh/peer.ts";
import { type Bytes, bytesOf, withBytes } from "../src/mesh/bus.ts";
import type { Endpoint } from "../src/mesh/native.ts";
import { receiveFile, sendGathered } from "../src/replica/sending.ts";
import { given } from "./hub-fakes.ts";
import { memoryMesh } from "./memory-mesh.ts";

const cloudOf = (station: string, peers: string[]): any =>
  Object.assign(Object.create(Cloud.prototype), {
    state: { workspace: "ws", workspace_name: "ws", name: "", station, peers: peers.map((id) => ({ id })), revocations: [], joined: [] },
    lock: null,
    peersCurrent: true,
    relays: () => [],
  });

/// A station answering what it is asked with `handle`.
function serving(endpoint: Endpoint, peers: string[], handle: (request: any) => Promise<any>) {
  const remote: any = { handle: (_ws: string, _peer: string, request: any) => handle(request) };
  void (async () => {
    for (;;) {
      const conn = await endpoint.accept();
      if (!conn) return;
      void servePeer(conn, cloudOf(endpoint.id(), peers), remote).catch(() => {});
    }
  })();
}

async function pair() {
  const mesh = memoryMesh();
  const bind = () => mesh.bind({ secretKey: randomBytes(32), alpns: [PEER_BYTES_ALPN, PEER_ALPN], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  const [source, target] = await Promise.all([bind(), bind()]);
  return { source, target };
}

const settled = <T>(p: Promise<T>) => p.then((v) => ({ v }), (e: Error) => ({ e }));
const sha = (b: Buffer) => createHash("sha256").update(b).digest("hex");

test("a request whose bytes' own source fails as they go is failed with that source's error, not as the other station answering nothing", async () => {
  const { source, target } = await pair();
  const dir = mkdtempSync(join(tmpdir(), "peer-source-"));
  serving(target, [source.id()], async (r) => {
    await receiveFile(dir, String(r.name), bytesOf(r)!);
    return { ok: true };
  });
  const call = peerCall(source, cloudOf(source.id(), [target.id()]), (id) => ({ id }), undefined, 60_000, { checkMs: 60_000 });
  try {
    // (a piece, then its file found shorter than it was: fileBytes's own words)
    async function* shrinking(): Bytes {
      yield Buffer.alloc(64 * 1024, 1);
      throw new Error("the file got shorter while it was sent");
    }
    const got = await given(settled(call(target.id(), "ws", withBytes({ method: "put", name: "0".repeat(64) }, shrinking()))), "the request failed");
    assert.ok("e" in got, "it failed");
    assert.match(got.e.message, /the file got shorter while it was sent/, `as its source failed, not as no answer: ${got.e.message}`);
    assert.deepEqual(readdirSync(dir), [], "nothing taken there");
  } finally {
    await Promise.all([source.close(), target.close()]);
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a chat's files' pass, not held, leaves a file truncated and rewritten as it goes, one rewritten larger, and one deleted after it was looked at, and goes on to the rest; held, it sends the first as it then is", async () => {
  const { source, target } = await pair();
  const here = mkdtempSync(join(tmpdir(), "pass-here-"));
  const there = mkdtempSync(join(tmpdir(), "pass-there-"));
  serving(target, [source.id()], async (r) => {
    await receiveFile(there, String(r.name), bytesOf(r)!);
    return { ok: true };
  });
  const call = peerCall(source, cloudOf(source.id(), [target.id()]), (id) => ({ id }), undefined, 60_000, { checkMs: 60_000 });
  try {
    const room = join(here, "sessions", "s", "workspace");
    mkdirSync(room, { recursive: true });
    const write = (name: string, b: Buffer) => (writeFileSync(join(room, name), b), b);
    const files = {
      first: write("a-first.md", Buffer.from("before the others\n")),
      shorter: write("b-shorter.bin", randomBytes(2 * 1024 * 1024 + 7)),
      larger: write("c-larger.bin", randomBytes(200_000)),
      gone: write("d-gone.bin", randomBytes(50_000)),
      last: write("e-last.md", Buffer.from("after the others\n")),
    };
    const list = (names: string[]) => names.map((n) => JSON.stringify({ hash: sha(readFileSync(join(room, n))), path: join(room, n), size: statSync(join(room, n)).size })).join("\n") + "\n";
    // (the gathering's lists and index, as carry.ts's program writes them)
    const gathered = (names: string[]) => {
      const at = join(here, `list-${randomBytes(4).toString("hex")}.jsonl`);
      const text = list(names);
      writeFileSync(at, text);
      const index = { v: 2, dataDir: here, sessions: [{ key: "s", at, list: sha(Buffer.from(text)), workspace: room }], gits: [], skipped: [], jobs: [], bundles: {}, files: names.length, bytes: 0 };
      const ix = join(here, `index-${randomBytes(4).toString("hex")}.json`);
      writeFileSync(ix, JSON.stringify(index));
      return { index: ix, files: names.length, bytes: 0, gits: 0, skipped: 0 };
    };
    const names = ["a-first.md", "b-shorter.bin", "c-larger.bin", "d-gone.bin", "e-last.md"];
    const g = gathered(names);
    // (what its chat's agent does to each as it is about to go: after the pass looked at it, before it is read)
    const asItGoes: Record<string, () => void> = {
      [join(room, "b-shorter.bin")]: () => void writeFileSync(join(room, "b-shorter.bin"), randomBytes(393_216)),
      [join(room, "c-larger.bin")]: () => void writeFileSync(join(room, "c-larger.bin"), randomBytes(300_000)),
      [join(room, "d-gone.bin")]: () => rmSync(join(room, "d-gone.bin")),
    };
    const sent: string[] = [];
    const to = {
      lacking: async (hashes: string[]) => ({ lacking: hashes }),
      put: async (hash: string, bytes: Bytes, path: string) => {
        asItGoes[path]?.();
        delete asItGoes[path];
        sent.push(path);
        return await call(target.id(), "ws", withBytes({ method: "put", name: hash }, bytes));
      },
      most: 100,
      stopping: () => false,
      total: () => {},
      done: () => {},
    };
    const first = await given(settled(sendGathered(g, to, false)), "the pass ended");
    assert.ok("v" in first, `the pass went on: ${"e" in first ? first.e.message : ""}`);
    assert.deepEqual(sent, names.map((n) => join(room, n)), "every file tried, in order");
    const took = new Set(readdirSync(there));
    assert.ok(took.has(sha(files.first)) && took.has(sha(files.last)), "the files before and after them taken there");
    for (const left of [files.shorter, files.larger, files.gone]) assert.ok(!took.has(sha(left)), "the three changed or gone left");
    // Held: gathered again, the rewritten file goes as it now is.
    const again = gathered(["b-shorter.bin"]);
    const held = await given(settled(sendGathered(again, { ...to, put: (hash: string, bytes: Bytes) => call(target.id(), "ws", withBytes({ method: "put", name: hash }, bytes)) }, true)), "the held pass ended");
    assert.ok("v" in held, `held, it went: ${"e" in held ? held.e.message : ""}`);
    assert.ok(readdirSync(there).includes(sha(readFileSync(join(room, "b-shorter.bin")))), "the shorter file as it now is, taken there");
  } finally {
    await Promise.all([source.close(), target.close()]);
    rmSync(here, { recursive: true, force: true });
    rmSync(there, { recursive: true, force: true });
  }
});


test("a request whose handler fails as its bytes come (its disk full) is answered with the handler's refusal, not a stream reset", async () => {
  const { source, target } = await pair();
  serving(target, [source.id()], async (r) => {
    // (a piece taken, then the write failing as a full disk fails it)
    let n = 0;
    for await (const _ of bytesOf(r)!) {
      if (++n === 2) throw Object.assign(new Error("ENOSPC: no space left on device, write"), { code: "ENOSPC" });
    }
    return { ok: true };
  });
  const call = peerCall(source, cloudOf(source.id(), [target.id()]), (id) => ({ id }), undefined, 60_000, { checkMs: 60_000 });
  try {
    // (more than the handler reads: what it does not read is stopped once its answer is through)
    async function* plenty(): Bytes {
      for (let i = 0; i < 64; i++) yield Buffer.alloc(64 * 1024, i);
    }
    const got = await given(settled(call(target.id(), "ws", withBytes({ method: "put", name: "0".repeat(64) }, plenty()))), "the request failed");
    assert.ok("e" in got, "it failed");
    assert.match(got.e.message, /ENOSPC: no space left on device/, `the handler's own words, not a reset: ${got.e.message}`);
  } finally {
    await Promise.all([source.close(), target.close()]);
  }
});
