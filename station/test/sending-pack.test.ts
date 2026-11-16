// A chat's or a retired station's files sent a pack at a time, in zstd (replica/sending.ts `packBytes`, `receivePack`),
// where the other station says it takes them so: a request a file was 252k requests in a row for one chat (the drill
// of 2026-11-16, 182 s between a VM and its own host). A pack's file that changes or goes as it is read is called off
// and the rest go on in the same stream (not held), or fails it (held); one meeting no answer is sent again of what the
// other lacks then; a file larger than the machine's heap goes through it in pieces; and a station from before, either
// side, is sent a file a request as before. What is sent is awaited as it is, never by `given`: zstd's work is on
// libuv's threads, which `settle` does not see, so a slower machine "settled" before it was done (CI, 2026-11-16).
import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, truncateSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Worker } from "node:worker_threads";
import { Cloud } from "../src/cloud/state.ts";
import { PEER_ALPN, PEER_BYTES_ALPN, peerCall, servePeer } from "../src/mesh/peer.ts";
import { type Bytes, bytesOf, withBytes } from "../src/mesh/bus.ts";
import type { Endpoint } from "../src/mesh/native.ts";
import { AskAgain } from "../src/move/module.ts";
import { PACK_ENCODING, type PackEntry, type Sending, lackingIn, receiveFile, receivePack, sendGathered } from "../src/replica/sending.ts";
import { memoryMesh } from "./memory-mesh.ts";
import { A, B, WS, stillfailChat, world } from "./move-world.ts";

const cloudOf = (station: string, peers: string[]): any =>
  Object.assign(Object.create(Cloud.prototype), {
    state: { workspace: "ws", workspace_name: "ws", name: "", station, peers: peers.map((id) => ({ id })), revocations: [], joined: [] },
    lock: null,
    peersCurrent: true,
    relays: () => [],
  });

const sha = (b: Buffer) => createHash("sha256").update(b).digest("hex");
const settled = <T>(p: Promise<T>) => p.then((v) => ({ v }), (e: Error) => ({ e }));

/// Two stations on the memory mesh: `there` takes what it is sent into its directory, as a station of now (`pack`) or
/// of before, and says what each request carried.
async function stations(o: { packs: boolean }) {
  const mesh = memoryMesh();
  const bind = () => mesh.bind({ secretKey: randomBytes(32), alpns: [PEER_BYTES_ALPN, PEER_ALPN], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  const [source, target] = await Promise.all([bind(), bind()]);
  const here = mkdtempSync(join(tmpdir(), "pack-here-"));
  const there = mkdtempSync(join(tmpdir(), "pack-there-"));
  const heard: { method: string; pack: boolean; count: number }[] = [];
  serve(target, [source.id()], async (r) => {
    heard.push({ method: r.method, pack: r.pack === PACK_ENCODING, count: typeof r.count === "number" ? r.count : 1 });
    if (r.method === "lacking") return { lacking: await lackingIn(there, r.hashes), ...(o.packs ? { pack: PACK_ENCODING } : {}) };
    if (r.pack === PACK_ENCODING && o.packs) await receivePack(there, bytesOf(r)!, { strict: r.strict !== false, ...(typeof r.name === "string" ? { name: r.name } : {}), count: r.count });
    else await receiveFile(there, String(r.name), bytesOf(r)!);
    return { ok: true };
  });
  const call = peerCall(source, cloudOf(source.id(), [target.id()]), (id) => ({ id }), undefined, 60_000, { checkMs: 60_000 });
  /// What went over the mesh of the files' bytes (as compressed, for a pack).
  const wire = { bytes: 0 };
  async function* counted(bytes: Bytes): Bytes {
    for await (const piece of bytes) {
      wire.bytes += piece.length;
      yield piece;
    }
  }
  const took: PackEntry[] = [];
  const to = (more: Partial<Sending> = {}): Sending => ({
    lacking: (hashes) => call(target.id(), "ws", { method: "lacking", hashes }),
    put: (hash, bytes) => call(target.id(), "ws", withBytes({ method: "put", name: hash }, counted(bytes))),
    putPack: (entries, bytes, strict) => call(target.id(), "ws", withBytes({ method: "put", pack: PACK_ENCODING, strict, count: entries.length, ...(entries.length === 1 ? { name: entries[0]!.hash } : {}) }, counted(bytes))),
    took: (f) => void took.push(f),
    most: 1000,
    stopping: () => false,
    total: () => {},
    done: () => {},
    ...more,
  });
  return {
    here, there, heard, wire, took, to,
    close: async () => {
      await Promise.all([source.close(), target.close()]);
      rmSync(here, { recursive: true, force: true });
      rmSync(there, { recursive: true, force: true });
    },
  };
}

function serve(endpoint: Endpoint, peers: string[], handle: (request: any) => Promise<any>) {
  const remote: any = { handle: (_ws: string, _peer: string, request: any) => handle(request) };
  void (async () => {
    for (;;) {
      const conn = await endpoint.accept();
      if (!conn) return;
      void servePeer(conn, cloudOf(endpoint.id(), peers), remote).catch(() => {});
    }
  })();
}

/// A gathering of the files `names` of `room`, as carry.ts's program writes it: a session's list and the index.
function gathered(here: string, room: string, names: string[]) {
  const text = names.map((n) => JSON.stringify({ hash: sha(readFileSync(join(room, n))), path: join(room, n), size: statSync(join(room, n)).size })).join("\n") + "\n";
  const at = join(here, `list-${randomBytes(4).toString("hex")}.jsonl`);
  writeFileSync(at, text);
  const index = { v: 2, dataDir: here, sessions: [{ key: "s", at, list: sha(Buffer.from(text)), workspace: room }], gits: [], skipped: [], jobs: [], bundles: {}, files: names.length, bytes: 0 };
  const ix = join(here, `index-${randomBytes(4).toString("hex")}.json`);
  writeFileSync(ix, JSON.stringify(index));
  return { index: ix, files: names.length, bytes: 0, gits: 0, skipped: 0 };
}

const roomOf = (here: string) => {
  const room = join(here, "sessions", "s", "workspace");
  mkdirSync(room, { recursive: true });
  return room;
};
const tmpsIn = (dir: string) => readdirSync(dir).filter((n) => n.endsWith(".tmp"));

test("500 small files go in a pack, in zstd: one request where there were 500, a fraction of their bytes on the wire, each there byte for byte", async () => {
  const s = await stations({ packs: true });
  try {
    const room = roomOf(s.here);
    const names: string[] = [];
    let raw = 0;
    for (let i = 0; i < 500; i++) {
      const name = `notes-${String(i).padStart(3, "0")}.md`;
      const b = Buffer.from(`# Note ${i}\n\n` + `What the agent did in step ${i % 17}: read the file, ran the tests, wrote the change.\n`.repeat(20 + (i % 7)));
      writeFileSync(join(room, name), b);
      names.push(name);
      raw += b.length;
    }
    const got = await settled(sendGathered(gathered(s.here, room, names), s.to(), true));
    assert.ok("v" in got, `it went: ${"e" in got ? got.e.message : ""}`);
    const puts = s.heard.filter((h) => h.method === "put");
    // (the room's 500 in one pack, then the list in one of its own; the index alone, as a file)
    assert.deepEqual(puts.map((p) => [p.pack, p.count]), [[true, 500], [true, 1], [false, 1]], JSON.stringify(puts));
    assert.ok(s.wire.bytes < raw * 0.3, `compressed: ${s.wire.bytes} bytes on the wire of ${raw}`);
    for (const n of names) assert.deepEqual(readFileSync(join(s.there, sha(readFileSync(join(room, n))))), readFileSync(join(room, n)), n);
    assert.equal(s.took.filter((f) => f.path.startsWith(room)).length, 500, "each told there once");
    assert.deepEqual(tmpsIn(s.there), []);
  } finally {
    await s.close();
  }
});

test("a pack, not held, calls off a file truncated as it is read, one rewritten before it is read and one gone after it was asked of, and takes the files before and after in the same stream; held, a file changed or gone fails it", async () => {
  const s = await stations({ packs: true });
  try {
    const room = roomOf(s.here);
    const write = (name: string, b: Buffer) => (writeFileSync(join(room, name), b), b);
    const first = write("a-first.md", Buffer.from("before the others\n"));
    const shorter = write("b-shorter.bin", randomBytes(2 * 1024 * 1024 + 7));
    const rewritten = write("c-rewritten.bin", randomBytes(200_000));
    const gone = write("d-gone.bin", randomBytes(50_000));
    const last = write("e-last.md", Buffer.from("after the others\n"));
    const names = ["a-first.md", "b-shorter.bin", "c-rewritten.bin", "d-gone.bin", "e-last.md"];
    let packs = 0;
    const to = s.to({
      putPack: (entries, bytes, strict) => {
        packs++;
        // (as the pack is about to go: one rewritten at its size, one deleted; the large one cut short once its first
        // piece went, as its chat's agent writes it)
        writeFileSync(join(room, "c-rewritten.bin"), randomBytes(200_000));
        rmSync(join(room, "d-gone.bin"));
        async function* asItGoes(): Bytes {
          let pieces = 0;
          for await (const piece of bytes) {
            if (++pieces === 1) truncateSync(join(room, "b-shorter.bin"), 100_000);
            yield piece;
          }
        }
        return s.to().putPack!(entries, asItGoes(), strict);
      },
    });
    const pass = await settled(sendGathered(gathered(s.here, room, names), to, false));
    assert.ok("v" in pass, `the pass went on: ${"e" in pass ? pass.e.message : ""}`);
    assert.equal(packs, 1, "one pack: the five in one stream");
    const took = new Set(readdirSync(s.there));
    assert.ok(took.has(sha(first)) && took.has(sha(last)), "the files before and after them taken there");
    for (const left of [shorter, rewritten, gone]) assert.ok(!took.has(sha(left)), "the three changed or gone left");
    assert.deepEqual(tmpsIn(s.there), [], "nothing half written left there");
    assert.deepEqual(s.took.map((f) => f.path), [join(room, "a-first.md"), join(room, "e-last.md")], "only those taken told");
    // Held: gathered again, they go as they now are.
    const again = await settled(sendGathered(gathered(s.here, room, ["b-shorter.bin", "c-rewritten.bin"]), s.to(), true));
    assert.ok("v" in again, `held, it went: ${"e" in again ? again.e.message : ""}`);
    for (const n of ["b-shorter.bin", "c-rewritten.bin"]) assert.ok(existsSync(join(s.there, sha(readFileSync(join(room, n))))), `${n} as it now is, there`);
    // Held, one that changes as it is read, or goes, fails the pass in those words (the source's, not "no answer").
    write("f-changing.bin", randomBytes(100_000));
    write("g-going.bin", randomBytes(100_000));
    const changing = await settled(sendGathered(gathered(s.here, room, ["f-changing.bin"]), s.to({
      putPack: (entries, bytes, strict) => (writeFileSync(join(room, "f-changing.bin"), randomBytes(100_000)), s.to().putPack!(entries, bytes, strict)),
    }), true));
    assert.ok("e" in changing && /a file changed as it was sent: gathered again/.test(changing.e.message), `changed: ${"e" in changing ? changing.e.message : "it went"}`);
    const going = await settled(sendGathered(gathered(s.here, room, ["g-going.bin"]), s.to({
      putPack: (entries, bytes, strict) => (rmSync(join(room, "g-going.bin")), s.to().putPack!(entries, bytes, strict)),
    }), true));
    assert.ok("e" in going && /a file went as it was sent: gathered again/.test(going.e.message), `gone: ${"e" in going ? going.e.message : "it went"}`);
    assert.deepEqual(tmpsIn(s.there), []);
  } finally {
    await s.close();
  }
});

test("a pack meeting no answer halfway is sent again of only what the other lacks then: what it took before is not sent again, none is missing", async () => {
  const here = mkdtempSync(join(tmpdir(), "pack-here-"));
  const there = mkdtempSync(join(tmpdir(), "pack-there-"));
  try {
    const room = roomOf(here);
    const names: string[] = [];
    for (let i = 0; i < 8; i++) {
      names.push(`part-${i}.bin`);
      writeFileSync(join(room, `part-${i}.bin`), randomBytes(300 * 1024));
    }
    const packs: { entries: string[]; there: string[] }[] = [];
    const told: string[] = [];
    let done = 0;
    const to: Sending = {
      lacking: async (hashes) => ({ lacking: await lackingIn(there, hashes), pack: PACK_ENCODING }),
      // (the index, a file in memory, goes by itself)
      put: async (hash, bytes, path) => (assert.equal(path, "", "only the index a file a request"), await receiveFile(there, hash, bytes)),
      putPack: async (entries, bytes, strict) => {
        packs.push({ entries: entries.map((e) => e.hash), there: readdirSync(there) });
        if (packs.length > 1) return await receivePack(there, bytes, { strict, count: entries.length });
        // (the connection gone once a megabyte went: what came before taken there)
        async function* cut(): Bytes {
          let went = 0;
          for await (const piece of bytes) {
            if (went >= 1024 * 1024) throw new Error("the connection went");
            went += piece.length;
            yield piece;
          }
        }
        await receivePack(there, cut(), { strict, count: entries.length }).catch(() => {});
        throw new AskAgain("no answer");
      },
      took: (f) => void told.push(f.hash),
      most: 100,
      stopping: () => false,
      total: () => {},
      done: (n) => void (done += n),
    };
    await sendGathered(gathered(here, room, names), to, true);
    const hashes = names.map((n) => sha(readFileSync(join(room, n))));
    const before = packs[1]!.there.filter((h) => hashes.includes(h));
    assert.equal(packs[0]!.entries.length, 8, "the room's eight in one pack");
    assert.ok(before.length >= 2 && before.length < 8, `some of it taken before the connection went: ${before.length}`);
    assert.deepEqual(packs[1]!.entries, hashes.filter((h) => !before.includes(h)), "sent again: only what it lacked then, in order");
    for (const n of names) assert.deepEqual(readFileSync(join(there, sha(readFileSync(join(room, n))))), readFileSync(join(room, n)), n);
    assert.deepEqual([...told.filter((h) => hashes.includes(h))].sort(), [...hashes].sort(), "each told there once");
    assert.equal(done, names.reduce((n, f) => n + statSync(join(room, f)).size, 0), "each counted done once");
    assert.deepEqual(tmpsIn(there), []);
  } finally {
    rmSync(here, { recursive: true, force: true });
    rmSync(there, { recursive: true, force: true });
  }
});

test("a file of 40 MiB, past a pack's bytes, goes alone in pieces: packed and taken in a worker of a 32 MB heap, its memory not the file's size", async () => {
  const here = mkdtempSync(join(tmpdir(), "pack-large-"));
  try {
    const path = join(here, "large.bin");
    // (half that does not compress, half that inflates a thousandfold)
    const b = Buffer.concat([randomBytes(20 * 1024 * 1024), Buffer.alloc(20 * 1024 * 1024)]);
    writeFileSync(path, b);
    const entry = { hash: sha(b), path, size: b.length };
    const there = join(here, "there");
    const w = new Worker(new URL("./sending-pack-worker.ts", import.meta.url), { workerData: { entry, there }, resourceLimits: { maxOldGenerationSizeMb: 32 } });
    const got = await new Promise<{ heap: number; buffers: number; before: { heap: number; buffers: number }; sent: number; took: number }>((resolve, reject) => {
      w.once("message", resolve);
      w.once("error", reject);
      w.once("exit", (code) => code !== 0 && reject(new Error(`the worker ended ${code}`)));
    });
    await w.terminate();
    assert.equal(got.took, 1);
    assert.ok(readFileSync(join(there, entry.hash)).equals(b), "there byte for byte");
    assert.ok(got.sent < b.length * 0.6, `its zeros compressed: ${got.sent} of ${b.length}`);
    // (its buffers a few pieces of the stream and the compressors' windows, what is alive with the garbage collected
    // first: 2.1 MiB for this file, each run, measured 2026-11-17; uncollected, 8.4 to 16.1 by when V8 got to it. The
    // heap its modules', what it was before the file)
    const mib = (n: number) => `${(n / 1024 / 1024).toFixed(1)} MiB`;
    assert.ok(got.buffers < 16 * 1024 * 1024, `its buffers at most ${mib(got.buffers)} for a file of 40 MiB`);
    assert.ok(got.heap - got.before.heap < 8 * 1024 * 1024, `its heap grew ${mib(got.heap - got.before.heap)}`);
    assert.deepEqual(tmpsIn(there), []);
  } finally {
    rmSync(here, { recursive: true, force: true });
  }
});

test("a station from before, either side: one that says nothing of packs is sent a file a request, and a file's request is taken as before", async () => {
  // (sending: the other's `lacking` says no `pack`)
  const s = await stations({ packs: false });
  try {
    const room = roomOf(s.here);
    const names = ["a.md", "b.md", "c.md"];
    for (const n of names) writeFileSync(join(room, n), `${n}\n`);
    const got = await settled(sendGathered(gathered(s.here, room, names), s.to(), true));
    assert.ok("v" in got, `it went: ${"e" in got ? got.e.message : ""}`);
    assert.ok(s.heard.filter((h) => h.method === "put").every((h) => !h.pack), "no pack sent");
    assert.equal(s.heard.filter((h) => h.method === "put").length, 3 + 1 + 1, "a request each file, the list and the index");
    for (const n of names) assert.ok(existsSync(join(s.there, sha(readFileSync(join(room, n))))), n);
  } finally {
    await s.close();
  }
  // (a hand-over between stations of now, where one side is from before: the files' requests as before, the chat
  // there with its files)
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const room = a.rig.session(key).workspace;
  for (let i = 0; i < 5; i++) writeFileSync(join(room, `f${i}.md`), `file ${i}\n`);
  const puts: { pack: boolean; name: unknown }[] = [];
  w.tamper((to, r) => {
    if (to === B && r.method === "handover.put") puts.push({ pack: r.pack !== undefined, name: r.name });
    return r;
  });
  // (B from before: its `handover.lacking` says nothing of packs)
  b.answered = (r, answer) => (r.method === "handover.lacking" ? { ...answer, pack: undefined } : answer);
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  w.tamper(null);
  b.answered = undefined;
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.ok(puts.length > 5 && puts.every((p) => !p.pack && typeof p.name === "string"), `a file a request: ${JSON.stringify(puts)}`);
  for (let i = 0; i < 5; i++) assert.equal(readFileSync(join(b.rig.session(key).workspace, `f${i}.md`), "utf8"), `file ${i}\n`);
});
