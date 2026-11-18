// The front (station/mb's `--builder mesh`) bound again by a Node that takes another set of protocols keeps its
// endpoint and takes the new set on it (`iroh.setAlpns`), never an endpoint of its own beside it: 2026-11-18, as
// 0.1.10002 (Node, six protocols) took over Office-Host-2 from 0.1.9996 (the MoonBit station, five), the front bound a
// second endpoint of the same key and the first, closing, refused every station that dialed it ("the server refused to
// accept a new connection") until the front was started again.
import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
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
  const dir = mkdtempSync(join(tmpdir(), `front-alpns-${name}-`));
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

const station = Buffer.from("stillfail/station/2");
const added = Buffer.from("stillfail/mesh-enrollment/1");

test("a Node that binds the front with another set of protocols is given the endpoint there, taking the new set", { skip, timeout: 60_000 }, async () => {
  const here = await front("here");
  const there = await front("there");
  const key = Buffer.alloc(32, 5);
  const options = { secretKey: key, relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" };
  // The Node before, then the next one beside it (a handover), with a protocol more.
  const before = await withFront({} as Mesh, here).bind({ ...options, alpns: [station] });
  const next = await withFront({} as Mesh, here).bind({ ...options, alpns: [station, added] });
  assert.equal(next.id(), before.id());
  assert.deepEqual(next.sockets(), before.sockets(), "the same endpoint, not one bound beside it");
  await before.close();
  // Another station dials the protocol only the next Node takes: let in, and given it.
  const dialer = await withFront({} as Mesh, there).bind({ secretKey: Buffer.alloc(32, 6), relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0", alpns: [] });
  const accepted = next.accept();
  const conn = await dialer.connect({ id: next.id(), ips: next.sockets() }, added);
  const taken = await accepted;
  assert.ok(taken !== null);
  assert.deepEqual(taken.alpn(), added);
  assert.equal(taken.remoteId(), dialer.id());
  conn.close(0, "");
  await dialer.close();
  await next.close();
});
