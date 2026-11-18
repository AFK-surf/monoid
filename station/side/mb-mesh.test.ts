// The station's endpoint kept by the MoonBit front (station/mb's src/front/mesh.mbt, station/src/mesh/front.ts) against
// the addon's own: the same scenario run on each, a device's endpoint (the addon's) dialing the station, and what each
// side saw compared, step for step: who connected and on what, a stream's bytes both ways, its end, a reset and its
// code, what a stream's end is acknowledged with, a stream one way, why a connection went. Then what only the front
// does: a second Node binding takes the connections that come from then on, the first keeps its own, and closing its
// endpoint closes only those. And a front that ended, another started in its place: the Node links to it again, bound
// as before, and takes what comes. Real processes and sockets: the side run's.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createSocket } from "node:dgram";
import { closeSync, constants, existsSync, mkdtempSync, openSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { MbProcess, mbReaderBinary } from "../src/read/mb-reader.ts";
import { Front, Incoming, withFront } from "../src/mesh/front.ts";
import { createServer } from "node:net";
import { hearLines } from "../src/ops/log.ts";
import { wall } from "../src/ops/fibers.ts";
import type { Socket } from "node:net";
import { type Connection, type Endpoint, type Mesh, type Stream, loadMesh } from "../src/mesh/native.ts";
import type { MeshDescriptor } from "../src/mesh/endpoint.ts";

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program is not built here (station/mb/build.sh)" : false;
const ALPN = Buffer.from("stillfail/test/1");

/// The front, listening at a socket of its own; what stops it.
async function front(at?: string): Promise<{ socket: string; stop: () => Promise<number> }> {
  const dir = at ?? mkdtempSync(join(tmpdir(), "mbm-"));
  const socket = join(dir, "front.sock");
  const p = new MbProcess(binary!, ["--builder", "mesh", "--socket", socket, "--shell-dir", join(dir, "shell")]);
  await new Promise<void>((resolve, reject) => {
    p.once("message", (m: { listening?: string }) => (m.listening === socket ? resolve() : reject(new Error(JSON.stringify(m)))));
    p.once("exit", (code: number) => reject(new Error(`ended (${code})`)));
  });
  return { socket, stop: () => p.terminate() };
}

async function readAll(s: Stream): Promise<Buffer> {
  const parts: Buffer[] = [];
  for (let b = await s.read(); b !== null; b = await s.read()) parts.push(b);
  return Buffer.concat(parts);
}

const bindOn = (mesh: Mesh, key: Buffer) => mesh.bind({ secretKey: key, alpns: [ALPN], relayUrls: [], discovery: false });
const addrOf = (e: Endpoint) => ({ id: e.id(), ips: e.sockets().filter((s) => s.startsWith("0.0.0.0") || /^\d/.test(s)).map((s) => s.replace(/^0\.0\.0\.0/, "127.0.0.1")) });

/// What a station's endpoint and a device's see of one exchange: the same on the addon and on the front.
async function scenario(station: Endpoint, device: Endpoint): Promise<unknown[]> {
  const seen: unknown[] = [];
  const accepted = station.accept();
  const theirs = await device.connect(addrOf(station), ALPN);
  const conn = (await accepted)!;
  seen.push({ remote: conn.remoteId() === device.id(), alpn: conn.alpn().toString(), closed: conn.isClosed() });

  // a stream the device opens: a megabyte there, the same backwards and a word back, each end as it comes
  const sent = randomBytes(1 << 20);
  const opened = await theirs.openBi();
  const writing = opened.write(sent).then(() => opened.finish());
  const s = (await conn.acceptBi())!;
  const got = await readAll(s);
  await writing;
  seen.push({ got: got.equals(sent) });
  await s.write(Buffer.concat([Buffer.from(got).reverse(), Buffer.from("|done")]));
  await s.finish();
  const back = await readAll(opened);
  seen.push({ back: back.equals(Buffer.concat([Buffer.from(sent).reverse(), Buffer.from("|done")])), ackd: await s.stopped() });

  // a stream the station opens, reset by it: the device's read fails, its write is told the code
  const mine = await conn.openBi();
  await mine.write(Buffer.from("hello"));
  const theirStream = (await theirs.acceptBi())!;
  seen.push({ first: (await theirStream.read())?.toString() });
  await mine.reset(7);
  seen.push({ readAfterReset: await mine.read() });
  seen.push({ theirRead: await theirStream.read().then((b) => `bytes ${b?.length}`, (e: Error) => `failed: ${e.message}`) });

  // the device stops reading one: the station's stopped says the code
  const told = await conn.openBi();
  await told.write(Buffer.from("x"));
  const stopping = (await theirs.acceptBi())!;
  await stopping.read();
  await stopping.reset(9);
  seen.push({ stopped: await told.stopped() });

  // a stream one way
  const uni = await (conn as Connection & { openUni(): Promise<{ write(b: Buffer): Promise<void>; finish(): Promise<void>; stopped(): Promise<number | null> }> }).openUni();
  await uni.write(Buffer.from("one way"));
  await uni.finish();

  // the device closes the connection: why, on the station's side
  theirs.close(3, "bye");
  seen.push({ closed: await conn.closed(), isClosed: conn.isClosed() });
  seen.push({ acceptAfter: await conn.acceptBi() });
  return seen;
}

test("the front's endpoint is seen as the addon's, step for step", { skip }, async () => {
  const addon = loadMesh();
  const f = await front();
  try {
    const runs: unknown[][] = [];
    for (const mesh of [addon, withFront(addon, f.socket)]) {
      const station = await bindOn(mesh, randomBytes(32));
      const device = await bindOn(addon, randomBytes(32));
      try {
        runs.push(await scenario(station, device));
      } finally {
        await device.close();
        await station.close();
      }
    }
    assert.deepEqual(runs[1], runs[0]);
  } finally {
    await f.stop();
  }
});

test("a Node binding again takes what comes from then on; the first keeps its own until it closes", { skip, timeout: 30_000 }, async () => {
  const addon = loadMesh();
  const f = await front();
  const key = randomBytes(32);
  const endpoints: Endpoint[] = [];
  const bind = async (mesh: Mesh, secret: Buffer) => {
    const endpoint = await bindOn(mesh, secret);
    endpoints.push(endpoint);
    return endpoint;
  };
  try {
    await wall.within(25_000, (async () => {
      const first = await bind(withFront(addon, f.socket), key);
      const device = await bind(addon, randomBytes(32));
      const one = first.accept();
      const dialedOne = await device.connect(addrOf(first), ALPN);
      const conn1 = (await one)!;
      assert.equal(conn1.remoteId(), device.id());

      // Only the resident front can forward between these two non-transit endpoints.
      // Neither device has the other's neighbor address or any root address lookup.
      const device2 = await bind(addon, randomBytes(32));
      const scope = randomBytes(32).toString("hex");
      const scoped = [device, first, device2];
      const descriptors: MeshDescriptor[] = [];
      for (const [i, endpoint] of scoped.entries()) {
        assert.ok(endpoint.meshConfigure);
        descriptors.push(await endpoint.meshConfigure({ scope, transit: i === 1, peers: [], relayUrls: [] }));
      }
      const reachable = (descriptor: MeshDescriptor, yes: boolean): MeshDescriptor => {
        const address = descriptor.address as { id: string; addrs: { Ip?: string }[] };
        const port = address.addrs.find(a => a.Ip && !a.Ip.startsWith("["))?.Ip?.split(":").at(-1);
        assert.ok(port, "the scoped neighbor has an IPv4 socket");
        return { ...descriptor, address: { id: address.id, addrs: yes ? [{ Ip: `127.0.0.1:${port}` }] : [] } };
      };
      const configurations = scoped.map((_, i) => ({ scope, transit: i === 1, relayUrls: [],
        peers: descriptors.flatMap((d, j) => i === j ? [] : [reachable(d, i === 1 || j === 1)]),
      }));
      for (const [i, endpoint] of scoped.entries()) await endpoint.meshConfigure!(configurations[i]!);
      const overlayAccepted = device2.accept();
      const overlay = await device.connect({ id: device2.id(), meshScope: scope }, ALPN);
      const overlayPeer = (await overlayAccepted)!;
      assert.equal(overlay.remoteId(), device2.id(), "inner QUIC authenticates the target root");
      assert.equal(overlayPeer.remoteId(), device.id(), "the target sees the source root, not the front");
      const opened = await overlay.openBi();
      await opened.write(Buffer.from("scoped"));
      const received = (await overlayPeer.acceptBi())!;
      const readExact = async (stream: Stream, size: number): Promise<Buffer> => {
        const chunks: Buffer[] = [];
        let length = 0;
        while (length < size) {
          const chunk = await stream.read();
          assert.ok(chunk, "the existing overlay stream has not ended");
          chunks.push(chunk);
          length += chunk.length;
        }
        assert.equal(length, size);
        return Buffer.concat(chunks);
      };
      assert.equal((await readExact(received, 6)).toString(), "scoped");
      const exchange = async (stage: string) => {
        const bytes = randomBytes(1 << 16);
        await opened.write(bytes);
        assert.deepEqual(await readExact(received, bytes.length), bytes, `${stage}: forward`);
        const back = Buffer.from(bytes).reverse();
        await received.write(back);
        assert.deepEqual(await readExact(opened, back.length), back, `${stage}: reverse`);
        assert.equal(overlay.isClosed(), false);
        assert.equal(overlayPeer.isClosed(), false);
        const path = overlay.paths!().find(p => p.selected);
        assert.ok(path && path.txPackets > 0, `${stage}: the overlay carries packets`);
        assert.ok(path.ip == null, "no direct root path bypasses the front");
        assert.ok(path.relay == null, "the root path is the scoped custom transport");
      };
      await exchange("before handover");

      // the next Node: the same endpoint (its id and where it listens), the next connection its own
      const second = await bind(withFront(addon, f.socket), key);
      assert.equal(second.id(), first.id());
      assert.deepEqual(second.sockets(), first.sockets());
      await exchange("after the second Node binds");
      assert.ok(second.meshListen);
      let off = () => {};
      const kept = await new Promise<MeshDescriptor>(resolve => {
        off = second.meshListen!(scopes => {
          const found = scopes.find(s => s.scope === scope);
          if (found) resolve(found.descriptor);
        });
      });
      off();
      assert.deepEqual(kept.binding, descriptors[1]!.binding, "the front retains the scoped identity across ownership");
      await second.meshConfigure!(configurations[1]!);
      await exchange("after the new Node reconciles the scope");
      const two = second.accept();
      const dialedTwo = await device2.connect(addrOf(second), ALPN);
      const conn2 = (await two)!;
      assert.equal(conn2.remoteId(), device2.id());

      // the first's connection still carries; closing the first's endpoint closes it alone
      const s = await dialedOne.openBi();
      await s.write(Buffer.from("still here"));
      await s.finish();
      assert.equal((await readAll((await conn1.acceptBi())!)).toString(), "still here");
      await first.close();
      await dialedOne.closed();
      assert.equal(dialedTwo.isClosed(), false);
      const t = await dialedTwo.openBi();
      await t.write(Buffer.from("on the second"));
      await t.finish();
      assert.equal((await readAll((await conn2.acceptBi())!)).toString(), "on the second");
      await exchange("after the old Node closes");
      await opened.finish();
      assert.equal(await received.read(), null);
      await received.finish();
      assert.equal(await opened.read(), null);
      console.log(JSON.stringify({ scopedHandover: true, source: overlayPeer.remoteId(), target: overlay.remoteId(),
        transit: second.id(), stages: 4, bytesEachDirection: 4 * (1 << 16), sameStream: true }));
      await second.meshRemove!(scope);
    })(), "the resident front's scoped stream did not survive Node handover");
  } finally {
    try { await Promise.all(endpoints.map(endpoint => endpoint.close())); }
    finally { await f.stop(); }
  }
});

test("a front can bind a fixed port after an older endpoint releases it", { skip }, async () => {
  const addon = loadMesh();
  const f = await front();
  const old = createSocket("udp4");
  await new Promise<void>((resolve) => old.bind(0, "127.0.0.1", resolve));
  let oldClosed = false;
  try {
    const addr = `127.0.0.1:${old.address().port}`;
    const options = { secretKey: randomBytes(32), alpns: [ALPN], relayUrls: [], discovery: false, bindAddr: addr };
    const bind = () => withFront(addon, f.socket).bind(options);
    await assert.rejects(bind());
    await new Promise<void>((resolve) => old.close(resolve));
    oldClosed = true;
    const station = await bind();
    const device = await bindOn(addon, randomBytes(32));
    try {
      assert.ok(station.sockets().includes(addr));
      const accepting = station.accept();
      const connection = await device.connect(addrOf(station), ALPN);
      assert.equal((await accepting)!.remoteId(), device.id());
      connection.close(0, "");
    } finally {
      await device.close();
      await station.close();
    }
  } finally {
    if (!oldClosed) await new Promise<void>((resolve) => old.close(resolve));
    await f.stop();
  }
});

test("the front rebinds its fixed port when the previous endpoint has open streams", { skip }, async () => {
  const addon = loadMesh();
  const f = await front();
  const reservation = createSocket("udp4");
  await new Promise<void>((resolve) => reservation.bind(0, "127.0.0.1", resolve));
  const address = `127.0.0.1:${reservation.address().port}`;
  await new Promise<void>((resolve) => reservation.close(resolve));
  const key = randomBytes(32);
  const options = { secretKey: key, alpns: [ALPN], relayUrls: [], discovery: false, bindAddr: address };
  const mesh = withFront(addon, f.socket);
  const first = await mesh.bind(options);
  const device = await bindOn(addon, randomBytes(32));
  let second: Endpoint | undefined;
  try {
    const accepting = first.accept();
    const outgoing = await device.connect(addrOf(first), ALPN);
    const incoming = (await accepting)!;
    for (let i = 0; i < 10; i++) {
      const opened = await outgoing.openBi();
      await opened.write(Buffer.from("x"));
      const received = (await incoming.acceptBi())!;
      assert.equal((await received.read())?.toString(), "x");
    }

    // A changed bind replaces the old endpoint. Its still-open streams must not retain the fixed port.
    second = await mesh.bind({ ...options, alpns: [ALPN, Buffer.from("stillfail/test/2")] });
    assert.ok(second.sockets().includes(address));
    const next = second.accept();
    const dialed = await device.connect(addrOf(second), ALPN);
    assert.equal((await next)!.remoteId(), device.id());
    dialed.close(0, "");
  } finally {
    await second?.close();
    await device.close();
    await first.close();
    await f.stop();
  }
});

test("a front's send-only stream stays writable after its read side closes", { skip }, async () => {
  const addon = loadMesh();
  const f = await front();
  const station = await bindOn(withFront(addon, f.socket), randomBytes(32));
  const device = await bindOn(addon, randomBytes(32));
  try {
    const accepting = station.accept();
    const theirs = await device.connect(addrOf(station), ALPN);
    const conn = (await accepting)!;
    const uni = await (conn as Connection & { openUni(): Promise<Stream> }).openUni();
    // The front has no incoming half for this stream. Wait for that EOF before writing.
    await assert.rejects(uni.read(), /the stream's way to the front ended/);
    await uni.write(Buffer.from("one way"));
    await uni.finish();
    theirs.close(0, "");
  } finally {
    await device.close();
    await station.close();
    await f.stop();
  }
});

test("a front that ended, another in its place: the Node links to it again and takes what comes", { skip }, async () => {
  const addon = loadMesh();
  const dir = mkdtempSync(join(tmpdir(), "mbm-"));
  let f = await front(dir);
  const key = randomBytes(32);
  const station = await bindOn(withFront(addon, f.socket), key);
  const id = station.id();
  const device = await bindOn(addon, randomBytes(32));
  try {
    const accepting = station.accept();
    // told as it links again (its log's line)
    const linked = new Promise<void>((resolve) => hearLines((l) => void (l.message === "linked to the front again" && resolve())));
    await f.stop();
    f = await front(dir);
    await linked;
    const dialed = await device.connect(addrOf(station), ALPN);
    const conn = (await accepting)!;
    assert.equal(conn.remoteId(), device.id());
    dialed.close(0, "");
    assert.equal(station.id(), id);
  } finally {
    await device.close();
    await station.close();
    await f.stop();
  }
});

test("a front whose stdout nobody reads lives on: a write to a pipe gone fails, SIGPIPE ends nothing", { skip }, async () => {
  // Its stdout a FIFO whose one reader closed before it started: the line it says as it listens is written where
  // nobody reads, on every system (a stream's Unix socket, below, is SO_NOSIGPIPE on macOS by tokio's mio).
  const dir = mkdtempSync(join(tmpdir(), "mbm-"));
  const fifo = join(dir, "out");
  spawnSync("mkfifo", [fifo]);
  const reader = openSync(fifo, constants.O_RDONLY | constants.O_NONBLOCK);
  const out = openSync(fifo, constants.O_WRONLY);
  closeSync(reader);
  const socket = join(dir, "front.sock");
  const child = spawn(binary!, ["--builder", "mesh", "--socket", socket, "--shell-dir", join(dir, "shell")], { stdio: ["pipe", out, "inherit"] });
  closeSync(out);
  let ended: string | null = null;
  const end = new Promise<string>((resolve) => child.on("exit", (code, signal) => resolve((ended = signal ?? `exit ${code}`))));
  // It listens and then says so: a while of real time for both.
  for (let i = 0; i < 100 && !existsSync(socket) && ended === null; i++) await new Promise((resolve) => setTimeout(resolve, 50));
  await Promise.race([end, new Promise((resolve) => setTimeout(resolve, 1000))]);
  try {
    assert.equal(ended, null, "the front lives on");
    const station = await bindOn(withFront(loadMesh(), socket), randomBytes(32));
    assert.equal(typeof station.id(), "string", "and serves");
    await station.close();
  } finally {
    child.kill("SIGTERM");
    await end;
  }
});

test("a stream whose Node end closed first is written to: only that stream goes, the front lives on (no SIGPIPE)", { skip }, async () => {
  // The front as the launcher starts it, its end (a signal's name, or its exit code) seen here.
  const dir = mkdtempSync(join(tmpdir(), "mbm-"));
  const socket = join(dir, "front.sock");
  const child = spawn(binary!, ["--builder", "mesh", "--socket", socket, "--shell-dir", join(dir, "shell")], { stdio: ["pipe", "pipe", "inherit"] });
  let ended: string | null = null;
  const end = new Promise<string>((resolve) => child.on("exit", (code, signal) => resolve((ended = signal ?? `exit ${code}`))));
  await new Promise<void>((resolve, reject) => {
    let line = "";
    child.stdout!.on("data", (b: Buffer) => {
      line += b.toString();
      if (line.includes("\n")) (JSON.parse(line.split("\n")[0]!).listening === socket ? resolve() : reject(new Error(line)));
    });
    void end.then((how) => reject(new Error(`the front ended before it listened (${how})`)));
  });
  // Each socket the front hands this process a stream on, as it comes (what FrontStream keeps to itself).
  const handed: Socket[] = [];
  const give = Incoming.prototype.give;
  Incoming.prototype.give = function (this: Incoming, came: Parameters<typeof give>[0]) {
    handed.push(came.socket);
    return give.call(this, came);
  };
  const addon = loadMesh();
  const station = await bindOn(withFront(addon, socket), randomBytes(32));
  const device = await bindOn(addon, randomBytes(32));
  try {
    const accepting = station.accept();
    const theirs = await device.connect(addrOf(station), ALPN);
    const conn = (await accepting)!;
    const other = await theirs.openBi();
    await other.write(Buffer.from("other"));
    const otherHere = (await conn.acceptBi())!;
    assert.equal((await otherHere.read())?.toString(), "other");

    const doomed = await theirs.openBi();
    await doomed.write(Buffer.from("first"));
    const doomedHere = (await conn.acceptBi())!;
    assert.equal((await doomedHere.read())?.toString(), "first");
    // Node's end of it closed, the front not told (as a Node that ended does): the next bytes the device sends on it
    // the front writes to a socket nobody reads.
    const nodeEnd = handed.at(-1)!;
    await new Promise<void>((resolve) => { nodeEnd.once("close", () => resolve()); nodeEnd.destroy(); });
    // (Linux's case: on macOS the shell's Unix sockets are SO_NOSIGPIPE, so this passes there with or without the fix.)
  // Nothing tells the device when the front took them (its write fails, and the stream's way to Node is let go
    // only on the device's side), so a while of real time: SIGPIPE, where it is not ignored, ends it within it.
    for (let i = 0; i < 8; i++) await doomed.write(randomBytes(1 << 16)).catch(() => {});
    await Promise.race([end, new Promise((resolve) => setTimeout(resolve, 2000))]);
    assert.equal(ended, null, "the front lives on");
    assert.equal(await conn.answers?.(5000), true, "and answers");

    // the stream beside it, and one opened after, carry on
    await other.write(Buffer.from(" still"));
    await other.finish();
    assert.equal((await readAll(otherHere)).toString(), " still");
    const after = await theirs.openBi();
    await after.write(Buffer.from("after"));
    await after.finish();
    assert.equal((await readAll((await conn.acceptBi())!)).toString(), "after");
    assert.equal(ended, null, "the front lives on");
    theirs.close(0, "");
  } finally {
    Incoming.prototype.give = give;
    await device.close();
    await station.close();
    child.kill("SIGTERM");
    await end;
  }
});

test("a Node binding again with other relays and another congestion controller takes the endpoint as it is: the connections on it stay", { skip }, async () => {
  const addon = loadMesh();
  const f = await front();
  const key = randomBytes(32);
  const options = { secretKey: key, alpns: [ALPN], relayUrls: [] as string[], discovery: false };
  const first = await withFront(addon, f.socket).bind(options);
  const device = await bindOn(addon, randomBytes(32));
  let second: Endpoint | undefined;
  try {
    const accepting = first.accept();
    const theirs = await device.connect(addrOf(first), ALPN);
    const conn = (await accepting)!;
    // (the next Node of a handover binds with what the station has now: a relay the cloud added meanwhile, the
    // congestion controller changed in its settings)
    second = await withFront(addon, f.socket).bind({ ...options, relayUrls: ["http://127.0.0.1:9/"], congestion: "bbr" });
    assert.equal(second.id(), first.id());
    assert.deepEqual(second.sockets(), first.sockets(), "the same endpoint, not one bound anew");
    // The first Node's connection lives on, both ways.
    const opened = await theirs.openBi();
    await opened.write(Buffer.from("still here"));
    await opened.finish();
    const s = (await conn.acceptBi())!;
    assert.equal((await readAll(s)).toString(), "still here");
    assert.equal(conn.isClosed(), false);
    // And the second Node takes what comes from then on, with the relays named last; bound with none again, none.
    const next = second.accept();
    const again = await device.connect(addrOf(second), ALPN);
    assert.equal((await next)!.remoteId(), device.id());
    again.close(0, "");
    const third = await withFront(addon, f.socket).bind(options);
    assert.equal(third.id(), first.id());
    assert.deepEqual(third.sockets(), first.sockets());
    await third.close();
    theirs.close(0, "");
  } finally {
    await device.close();
    await second?.close();
    await first.close();
    await f.stop();
  }
});

test("a connection whose end its Node was told is let go at the front: nothing of it is kept", { skip }, async () => {
  const addon = loadMesh();
  const f = await front();
  const node = await Front.open(f.socket);
  const device = await bindOn(addon, randomBytes(32));
  try {
    const said = await node.ask("bind", { streams: node.streamsPath, key: randomBytes(32).toString("hex"), options: { alpns: [ALPN.toString("hex")], relayUrls: [], discovery: false } });
    const accepting = node.ask("accept");
    const theirs = await device.connect({ id: said.id, ips: (said.sockets as string[]).filter((s) => /^\d/.test(s)).map((s) => s.replace(/^0\.0\.0\.0/, "127.0.0.1")) }, ALPN);
    const seen = await accepting;
    assert.equal(seen.remote, device.id());
    // (as front.ts's FrontConnection asks it of each connection, and asks nothing more of it once told)
    const closed = node.ask("conn.closed", { conn: seen.conn });
    theirs.close(5, "bye");
    assert.equal((await closed).reason, "bye");
    await assert.rejects(node.ask("conn.seen", { conn: seen.conn }), /no handle/, "let go at the shell, not kept as gone");
    // A close asked after (the Node's own, crossing the end) is answered as before.
    assert.deepEqual(await node.ask("conn.close", { conn: seen.conn, code: 0, reason: "" }), {});
  } finally {
    await node.ask("close").catch(() => {});
    node.close();
    await device.close();
    await f.stop();
  }
});

test("a connection that came before its Node said its routes goes by them once that Node takes it", { skip }, async () => {
  const addon = loadMesh();
  const f = await front();
  const key = randomBytes(32);
  const dir = mkdtempSync(join(tmpdir(), "mbm-"));
  // what a route's program would be (served.ts): the request handed it, its head line first
  const routedAt = join(dir, "routed.sock");
  let routed!: (b: Buffer) => void;
  const routedGot = new Promise<Buffer>((resolve) => (routed = resolve));
  const server = createServer((c) => {
    const parts: Buffer[] = [];
    c.on("data", (b: Buffer) => {
      parts.push(b);
      if (Buffer.concat(parts).includes("/routed")) routed(Buffer.concat(parts));
    });
  });
  await new Promise<void>((resolve) => server.listen(routedAt, resolve));
  const options = { secretKey: key, alpns: [ALPN], relayUrls: [] as string[], discovery: false };
  const device = await bindOn(addon, randomBytes(32));
  // The Node before, gone: what comes waits for the next.
  const before = await withFront(addon, f.socket).bind(options);
  const addr = addrOf(before);
  await before.close();
  let station: Endpoint | undefined;
  try {
    const theirs = await device.connect(addr, ALPN);
    // The next binds (given what waited) and only then says its routes (mesh.ts: once its programs listen).
    station = await withFront(addon, f.socket).bind(options);
    assert.equal(await station.route!(ALPN, [routedAt], ["GET /routed"]), true);
    const conn = (await station.accept())!;
    assert.equal(conn.remoteId(), device.id());
    // its first stream the Node's, as always; the next a routed request
    const first = await theirs.openBi();
    await first.write(Buffer.from("hello"));
    const asked = await theirs.openBi();
    await asked.write(Buffer.from(`${JSON.stringify({ method: "GET", path: "/routed" })}\n`));
    assert.equal((await (await conn.acceptBi())!.read())?.toString(), "hello");
    const where = await Promise.race([
      routedGot.then(() => "routed"),
      conn.acceptBi().then((s) => (s === null ? "ended" : "given the Node")),
    ]);
    assert.equal(where, "routed");
    theirs.close(0, "");
  } finally {
    server.close();
    await device.close();
    await station?.close();
    await f.stop();
  }
});

test("a bind is reconciled with the relays on the endpoint as a Node changed them, not as the last bind named them", { skip }, async () => {
  const f = await front();
  const node = await Front.open(f.socket);
  const [R1, R2, R3] = ["http://127.0.0.1:9/", "http://127.0.0.1:10/", "http://127.0.0.1:11/"];
  const key = randomBytes(32).toString("hex");
  const bind = (relayUrls: string[]) => node.ask("bind", { streams: node.streamsPath, key, options: { alpns: [ALPN.toString("hex")], relayUrls, discovery: false } });
  // What the front changes of the endpoint's relays as a Node binds: its log's lines.
  const changed: string[] = [];
  let last!: () => void;
  const lastSaid = new Promise<void>((resolve) => (last = resolve));
  hearLines((l) => {
    const m = /^mesh: relay (\S+) (added|removed) as a Node bound$/.exec(String((l.fields as { line?: string } | undefined)?.line ?? ""));
    if (m) changed.push(`${m[2]} ${m[1]}`);
    if (m?.[2] === "removed" && m[1] === R1) last();
  });
  try {
    const said = await bind([R1, R2]);
    // A Node takes R2 off (the cloud no longer names it); by the next handover the cloud names it again: given back.
    await node.ask("removeRelay", { args: { url: R2 } });
    assert.equal((await bind([R1, R2])).id, said.id);
    // A Node puts R3 in; the next bind does not name it: it goes.
    await node.ask("insertRelay", { args: { url: R3 } });
    assert.equal((await bind([R1, R2])).id, said.id);
    // The same relays again: nothing to change.
    assert.equal((await bind([R1, R2])).id, said.id);
    // R1 no longer named: what is said last (its log's lines come on the program's stderr, apart from its answers, in
    // the order it changed them)
    assert.equal((await bind([R2])).id, said.id);
    await lastSaid;
    assert.deepEqual(changed, [`added ${R2}`, `removed ${R3}`, `removed ${R1}`]);
  } finally {
    hearLines(null);
    await node.ask("close").catch(() => {});
    node.close();
    await f.stop();
  }
});
