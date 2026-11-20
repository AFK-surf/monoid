// Two Nodes binding a fresh front side by side (FB-36): 2026-11-18, as AFK-东京服务器 restarted, the launcher's new
// Node bound the new front while the old Node's link, gone with the old front, linked to it again (front.ts `#watch`).
// The front answers each ask apart, and both binds found no endpoint bound yet: each bound one of the station's key,
// the second taking the first's place without closing it. Hours later the relay held the one the front had in place
// inactive (SameEndpointIdConnected): devices still came in on the one left over, but every dial of this station's
// timed out, the other station's answers going to the endpoint that had not dialed. The front binds one ask at a time
// (mesh.mbt `bind_lock`), so the second is given the first's endpoint.
import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { connect, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { withFront } from "../src/mesh/front.ts";
import type { Mesh } from "../src/mesh/native.ts";
import { mbReaderBinary } from "../src/read/mb-reader.ts";

const binary = mbReaderBinary();
const skip = binary === null ? "the station's MoonBit program is not built here" : false;

const dirs: string[] = [];
const children: ChildProcess[] = [];
after(() => {
  for (const c of children) c.kill("SIGKILL");
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

/// A front of its own, listening on its socket.
async function front(name: string): Promise<string> {
  const dir = mkdtempSync(join(tmpdir(), `front-race-${name}-`));
  dirs.push(dir);
  const socket = join(dir, "front.sock");
  const child = spawn(binary!, ["--builder", "mesh", "--socket", socket, "--shell-dir", join(dir, "shell")], { stdio: ["pipe", "pipe", "inherit"] });
  children.push(child);
  await new Promise<void>((resolve, reject) => {
    let out = "";
    child.stdout!.on("data", (b) => {
      out += b;
      if (out.includes("listening")) resolve();
    });
    child.once("exit", (code) => reject(new Error(`the front ended (${code}) before it listened`)));
  });
  return socket;
}

/// A socket of a Node's to the front, asked by hand: each answer by its ask's id.
async function link(socket: string): Promise<{ conn: Socket; answer: (id: number) => Promise<Record<string, unknown>> }> {
  const conn = connect(socket);
  await new Promise<void>((resolve, reject) => conn.once("connect", resolve).once("error", reject));
  const answers = new Map<number, Record<string, unknown>>();
  const waiting = new Map<number, (a: Record<string, unknown>) => void>();
  let buf = "";
  conn.on("data", (b) => {
    buf += b;
    for (let at = buf.indexOf("\n"); at >= 0; at = buf.indexOf("\n")) {
      const said = JSON.parse(buf.slice(0, at)) as Record<string, unknown> & { id: number };
      buf = buf.slice(at + 1);
      const w = waiting.get(said.id);
      if (w) w(said);
      else answers.set(said.id, said);
    }
  });
  const answer = (id: number) => answers.has(id) ? Promise.resolve(answers.get(id)!) : new Promise<Record<string, unknown>>((r) => waiting.set(id, r));
  return { conn, answer };
}

const station = Buffer.from("stillfail/station/2");
const added = Buffer.from("stillfail/mesh-enrollment/1");
const hex = (b: Buffer) => b.toString("hex");
const asked = (key: Buffer, alpns: Buffer[]) => ({ streams: "/nonexistent/streams.sock", key: hex(key), options: { alpns: alpns.map(hex), relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" } });

test("two binds of a fresh front at once are given one endpoint, not one each", { skip, timeout: 60_000 }, async () => {
  // Both asks in one write: the front reads them together and starts both before either is bound, every time.
  const here = await front("once");
  const key = Buffer.alloc(32, 7);
  const { conn, answer } = await link(here);
  conn.write(`${JSON.stringify({ id: 1, op: "bind", ...asked(key, [station]) })}\n${JSON.stringify({ id: 2, op: "bind", ...asked(key, [station, added]) })}\n`);
  const [one, two] = await Promise.all([answer(1), answer(2)]);
  assert.ok(one.ok && two.ok, `both bound: ${JSON.stringify([one, two])}`);
  assert.deepEqual(two.ok, one.ok, "the same endpoint, not a second of the same key beside it");
  conn.destroy();
});

test("of two Nodes binding a fresh front side by side, the one left takes and makes connections", { skip, timeout: 60_000 }, async () => {
  const here = await front("here");
  const there = await front("there");
  const key = Buffer.alloc(32, 5);
  const options = { secretKey: key, relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0", alpns: [station, added] };
  // The next Node and the Node before linking again, at once.
  const [first, second] = await Promise.all([withFront({} as Mesh, here).bind(options), withFront({} as Mesh, here).bind(options)]);
  assert.equal(second.id(), first.id());
  assert.deepEqual(second.sockets(), first.sockets(), "the same endpoint, not one bound beside it");
  // The Node before goes, as in a handover.
  await first.close();
  const dialer = await withFront({} as Mesh, there).bind({ secretKey: Buffer.alloc(32, 6), relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0", alpns: [station] });
  for (const alpn of [added, station]) {
    const accepted = second.accept();
    const conn = await dialer.connect({ id: second.id(), ips: second.sockets() }, alpn);
    const taken = await accepted;
    assert.ok(taken !== null);
    assert.deepEqual(taken.alpn(), alpn);
    assert.equal(taken.remoteId(), dialer.id());
    conn.close(0, "");
  }
  // And it dials out on the endpoint it has.
  const coming = dialer.accept();
  const out = await second.connect({ id: dialer.id(), ips: dialer.sockets() }, station);
  const came = await coming;
  assert.ok(came !== null);
  assert.equal(came.remoteId(), second.id());
  out.close(0, "");
  await dialer.close();
  await second.close();
});

test("a Node gone while its bind waits takes nothing from the one that stays", { skip, timeout: 60_000 }, async () => {
  const here = await front("gone");
  const there = await front("gone-there");
  const key = Buffer.alloc(32, 8);
  const options = { secretKey: key, relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0", alpns: [station] };
  // The Node that goes asks first and ends its socket in the same write; the one that stays binds beside it.
  const { conn } = await link(here);
  conn.end(`${JSON.stringify({ id: 1, op: "bind", ...asked(key, [station]) })}\n`);
  const stays = await withFront({} as Mesh, here).bind(options);
  const dialer = await withFront({} as Mesh, there).bind({ secretKey: Buffer.alloc(32, 9), relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0", alpns: [] });
  const accepted = stays.accept();
  const made = await dialer.connect({ id: stays.id(), ips: stays.sockets() }, station);
  const taken = await accepted;
  assert.ok(taken !== null, "given to the Node that stays");
  assert.equal(taken.remoteId(), dialer.id());
  made.close(0, "");
  await dialer.close();
  await stays.close();
});

// The front ends once the endpoint bound gives no more connections (mesh.mbt `accepting`), for the launcher to start
// another; the endpoint let go as one of the same key bound otherwise (here its DSCP) is bound in its place ends its
// accepting too, and must not end the front: the new one is the endpoint bound before the old one is let go.
test("an endpoint let go for one bound otherwise in its place leaves the front running, taking connections", { skip, timeout: 60_000 }, async () => {
  const here = await front("rebind");
  const child = children.at(-1)!;
  const there = await front("rebind-there");
  const options = (fill: number) => ({ secretKey: Buffer.alloc(32, fill), relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0", alpns: [station] });
  const first = await withFront({} as Mesh, here).bind(options(10));
  const second = await withFront({} as Mesh, here).bind({ ...options(10), dscp: 10 });
  assert.notEqual(second.sockets().join(), first.sockets().join(), "bound anew, the first let go");
  const dialer = await withFront({} as Mesh, there).bind({ ...options(12), alpns: [] });
  const accepted = second.accept();
  const made = await dialer.connect({ id: second.id(), ips: second.sockets() }, station);
  const taken = await accepted;
  assert.ok(taken !== null, "the endpoint bound in its place takes connections");
  assert.equal(taken.remoteId(), dialer.id());
  // (the first endpoint let go as the second was bound: its accepting ended with it, the second's taking connections)
  assert.equal(child.exitCode, null, "the front still runs");
  assert.equal(child.signalCode, null);
  made.close(0, "");
  await dialer.close();
  await second.close();
  await first.close();
});

// A front is its station's: a process of another key that found its socket (a test an agent ran, which inherited
// STILLFAIL_MESH_FRONT) is refused, and the station's endpoint stays bound, taking connections.
test("a bind with another key is refused, the endpoint bound kept and taking connections", { skip, timeout: 60_000 }, async () => {
  const here = await front("rekey");
  const child = children.at(-1)!;
  const there = await front("rekey-there");
  const options = (fill: number) => ({ secretKey: Buffer.alloc(32, fill), relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0", alpns: [station] });
  const held = await withFront({} as Mesh, here).bind(options(10));
  const { conn, answer } = await link(here);
  conn.write(JSON.stringify({ id: 1, op: "bind", ...asked(Buffer.alloc(32, 11), [station]) }) + "\n");
  const refused = await answer(1);
  assert.match(String(refused.error), /another station's key/);
  conn.destroy();
  const dialer = await withFront({} as Mesh, there).bind({ ...options(12), alpns: [] });
  const accepted = held.accept();
  const made = await dialer.connect({ id: held.id(), ips: held.sockets() }, station);
  const taken = await accepted;
  assert.ok(taken !== null, "the station's endpoint still takes connections");
  assert.equal(taken.remoteId(), dialer.id());
  assert.equal(child.exitCode, null, "the front still runs");
  made.close(0, "");
  await dialer.close();
  await held.close();
});
