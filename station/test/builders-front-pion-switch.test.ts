// Wave 7 Sub-Wave 7.1 (`W7-A`) dual-engine MB vs Pion E2E parity suite for `--builder forward` and `--builder mesh`.
// Zero `setTimeout` sleeps: 100% event/Promise driven.
// Asserts `realpathSync(mbBin) !== realpathSync(pionBin)` and `--version` advertises `forward` and `mesh`.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createSocket } from "node:dgram";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { type AddressInfo, connect, createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { Front, withFront } from "../src/mesh/front.ts";
import type { Endpoint, Mesh, Stream } from "../src/mesh/native.ts";
import { mbReaderBinary, pionBinary } from "../src/read/mb-reader.ts";

function resolveDualBinaries(t: { skip: (msg: string) => void }): { mb: string; pion: string } | null {
  const realMb = mbReaderBinary();
  const explicitPion = process.env.STILLFAIL_PION_READER?.trim();
  const requireDual = process.env.STILLFAIL_REQUIRE_DUAL_READER === "1";
  const realPion = pionBinary();

  if (realMb === null) {
    if (process.env.CI || requireDual) assert.fail("stillfail-reader binary is required in CI");
    t.skip("stillfail-reader not built here");
    return null;
  }
  if (explicitPion || requireDual) {
    assert.ok(realPion !== null, `STILLFAIL_PION_READER is required (${explicitPion ?? "unset"}) but resolved to null`);
  } else if (realPion === null) {
    t.skip("STILLFAIL_PION_READER / built stillfail-pion binary not present in this environment");
    return null;
  }
  assert.notEqual(realpathSync(realMb), realpathSync(realPion), "MB and Pion binaries must be distinct files");
  const ver = execFileSync(realPion, ["--version"], { encoding: "utf8" });
  assert.match(ver, /modes:[^\n]*\bforward\b/, `Pion --version must advertise forward: ${ver}`);
  assert.match(ver, /modes:[^\n]*\bmesh\b/, `Pion --version must advertise mesh: ${ver}`);
  return { mb: realMb, pion: realPion };
}

const dirs: string[] = [];
const children: ChildProcess[] = [];

after(() => {
  for (const c of children) c.kill("SIGKILL");
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

function readAllSocket(s: Socket): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const parts: Buffer[] = [];
    s.on("data", (d) => parts.push(d));
    s.on("end", () => resolve(Buffer.concat(parts)));
    s.on("error", reject);
  });
}

async function readAllStream(s: Stream): Promise<Buffer> {
  const parts: Buffer[] = [];
  for (let b = await s.read(); b !== null; b = await s.read()) parts.push(b);
  return Buffer.concat(parts);
}

async function stopChild(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
  child.kill("SIGTERM");
  await exited;
}

async function spawnForward(
  bin: string,
  args: string[],
  extraFd?: number,
): Promise<{ child: ChildProcess; port: number; stop: () => Promise<void> }> {
  const dir = mkdtempSync(join(tmpdir(), "w7-front-fwd-"));
  dirs.push(dir);
  const fullArgs = ["--builder", "forward", ...args, "--shell-dir", join(dir, "shell")];
  const stdio: ("pipe" | "inherit" | number)[] = extraFd === undefined
    ? ["pipe", "pipe", "inherit"]
    : ["pipe", "pipe", "inherit", extraFd];
  const child = spawn(bin, fullArgs, { stdio });
  children.push(child);
  const port = await new Promise<number>((resolve, reject) => {
    let buf = "";
    child.stdout!.on("data", (chunk: Buffer) => {
      buf += chunk.toString();
      const nl = buf.indexOf("\n");
      if (nl >= 0) {
        const line = buf.slice(0, nl);
        try {
          const parsed = JSON.parse(line) as { listening?: number };
          if (typeof parsed.listening === "number") resolve(parsed.listening);
          else reject(new Error(`unexpected listening line: ${line}`));
        } catch (e) {
          reject(e);
        }
      }
    });
    child.once("exit", (code, sig) => reject(new Error(`forward exited (${code ?? sig}) before listening`)));
  });
  return { child, port, stop: () => stopChild(child) };
}

async function spawnMesh(
  bin: string,
  label: string,
): Promise<{ child: ChildProcess; socket: string; streams: number; stop: () => Promise<void> }> {
  const dir = mkdtempSync(join(tmpdir(), `w7-front-mesh-${label}-`));
  dirs.push(dir);
  const socket = join(dir, "front.sock");
  const child = spawn(
    bin,
    ["--builder", "mesh", "--socket", socket, "--shell-dir", join(dir, "shell")],
    { stdio: ["pipe", "pipe", "inherit"] },
  );
  children.push(child);
  const info = await new Promise<{ listening: string; streams: number }>((resolve, reject) => {
    let buf = "";
    child.stdout!.on("data", (chunk: Buffer) => {
      buf += chunk.toString();
      const nl = buf.indexOf("\n");
      if (nl >= 0) {
        const line = buf.slice(0, nl);
        try {
          const parsed = JSON.parse(line) as { listening?: string; streams?: number };
          if (parsed.listening === socket && typeof parsed.streams === "number") {
            resolve({ listening: parsed.listening, streams: parsed.streams });
          } else {
            reject(new Error(`unexpected mesh listening line: ${line}`));
          }
        } catch (e) {
          reject(e);
        }
      }
    });
    child.once("exit", (code, sig) => reject(new Error(`mesh exited (${code ?? sig}) before listening`)));
  });
  return { child, socket, streams: info.streams, stop: () => stopChild(child) };
}

async function openControl(socket: string): Promise<{
  conn: Socket;
  answer: (id: number) => Promise<Record<string, unknown>>;
}> {
  const conn = connect(socket);
  await new Promise<void>((resolve, reject) => conn.once("connect", resolve).once("error", reject));
  const answers = new Map<number, Record<string, unknown>>();
  const waiting = new Map<number, (a: Record<string, unknown>) => void>();
  let buf = "";
  conn.on("data", (b: Buffer) => {
    buf += b.toString();
    for (let at = buf.indexOf("\n"); at >= 0; at = buf.indexOf("\n")) {
      const said = JSON.parse(buf.slice(0, at)) as Record<string, unknown> & { id: number };
      buf = buf.slice(at + 1);
      const w = waiting.get(said.id);
      if (w) {
        waiting.delete(said.id);
        w(said);
      } else {
        answers.set(said.id, said);
      }
    }
  });
  const answer = (id: number) =>
    answers.has(id)
      ? Promise.resolve(answers.get(id)!)
      : new Promise<Record<string, unknown>>((r) => waiting.set(id, r));
  return { conn, answer };
}

const ALPN_MAIN = Buffer.from("stillfail/w7-front-test/1");
const ALPN_EXTRA = Buffer.from("stillfail/w7-front-test/2");

const addrOf = (e: Endpoint) => ({
  id: e.id(),
  ips: e.sockets().filter((s) => /^\d/.test(s)).map((s) => s.replace(/^0\.0\.0\.0/, "127.0.0.1")),
});

async function runForwardParity(bin: string) {
  // 1. Bidirectional TCP forwarding with half-close + stdin EOF ignored (forward does not exit on stdin EOF)
  const echo = createServer({ allowHalfOpen: true }, (s) => {
    void readAllSocket(s).then((got) => s.end(Buffer.concat([Buffer.from(got).reverse(), Buffer.from("|ok")])));
  });
  await new Promise<void>((r) => echo.listen(0, "127.0.0.1", r));
  const echoPort = (echo.address() as AddressInfo).port;
  const fwd = await spawnForward(bin, ["--listen-port", "0", "--to", String(echoPort)]);
  try {
    // Closing stdin must NOT terminate forward.
    fwd.child.stdin!.end();
    const payloads = [Buffer.from("hello-half-close"), randomBytes(64 * 1024)];
    const results = await Promise.all(
      payloads.map(
        (p) =>
          new Promise<Buffer>((resolve, reject) => {
            const c = connect(fwd.port, "127.0.0.1", () => c.end(p));
            readAllSocket(c).then(resolve, reject);
          }),
      ),
    );
    for (let i = 0; i < payloads.length; i++) {
      const want = Buffer.concat([Buffer.from(payloads[i]!).reverse(), Buffer.from("|ok")]);
      assert.ok(results[i]!.equals(want), `payload ${i} mismatch`);
    }
    assert.equal(fwd.child.exitCode, null, "forward stays alive after stdin EOF");
  } finally {
    await fwd.stop();
    await new Promise<void>((r) => echo.close(() => r()));
  }

  // 2. Unreachable target closes ONLY that client; a subsequent connection when target is unreachable also closes cleanly
  const dead = createServer();
  await new Promise<void>((r) => dead.listen(0, "127.0.0.1", r));
  const deadPort = (dead.address() as AddressInfo).port;
  await new Promise<void>((r) => dead.close(() => r()));
  const fwdDead = await spawnForward(bin, ["--listen-port", "0", "--to", String(deadPort)]);
  try {
    for (let i = 0; i < 2; i++) {
      const c = connect(fwdDead.port, "127.0.0.1");
      const got = await readAllSocket(c).catch(() => Buffer.alloc(0));
      assert.equal(got.length, 0);
    }
    assert.equal(fwdDead.child.exitCode, null, "unreachable target must not exit forward");
  } finally {
    await fwdDead.stop();
  }

  // 3. Inherited `--listen-fd`
  const target = createServer({ allowHalfOpen: true }, (s) => {
    void readAllSocket(s).then((got) => s.end(Buffer.concat([Buffer.from("fd:"), got])));
  });
  await new Promise<void>((r) => target.listen(0, "127.0.0.1", r));
  const targetPort = (target.address() as AddressInfo).port;
  const inherited = createServer();
  await new Promise<void>((r) => inherited.listen(0, "127.0.0.1", r));
  const inheritedPort = (inherited.address() as AddressInfo).port;
  const rawFd = (inherited as unknown as { _handle?: { fd?: number } })._handle?.fd;
  assert.ok(typeof rawFd === "number" && rawFd >= 0, "expected POSIX listening fd");
  const fwdFd = await spawnForward(bin, ["--listen-fd", "3", "--to", String(targetPort)], rawFd);
  // Stop Node from accepting on the same socket so the child owns all accepts.
  await new Promise<void>((r) => inherited.close(() => r()));
  try {
    assert.equal(fwdFd.port, inheritedPort);
    const got = await new Promise<Buffer>((resolve, reject) => {
      const c = connect(fwdFd.port, "127.0.0.1", () => c.end(Buffer.from("ping")));
      readAllSocket(c).then(resolve, reject);
    });
    assert.equal(got.toString(), "fd:ping");
  } finally {
    await fwdFd.stop();
    await new Promise<void>((r) => target.close(() => r()));
  }
}

async function runMeshParity(bin: string, label: string) {
  const fA = await spawnMesh(bin, `${label}-a`);
  const fB = await spawnMesh(bin, `${label}-b`);
  assert.equal(fA.streams, 8);
  assert.equal(fB.streams, 8);
  const keyA = randomBytes(32);
  const keyB = randomBytes(32);
  const keyForeign = randomBytes(32);

  try {
    const baseOpts = { secretKey: keyA, relayUrls: [] as string[], discovery: false, bindAddr: "127.0.0.1:0", alpns: [ALPN_MAIN] };
    // 1. Bind + ALPN update in-place (same endpoint id & sockets)
    const ep1 = await withFront({} as Mesh, fA.socket).bind(baseOpts);
    const ep2 = await withFront({} as Mesh, fA.socket).bind({ ...baseOpts, alpns: [ALPN_MAIN, ALPN_EXTRA] });
    assert.equal(ep2.id(), ep1.id());
    assert.deepEqual(ep2.sockets(), ep1.sockets(), "ALPN update must keep same endpoint");

    // 2. Wrong-key refusal keeps live endpoint running
    const ctl = await openControl(fA.socket);
    ctl.conn.write(
      `${JSON.stringify({
        id: 1,
        op: "bind",
        streams: "/nonexistent/streams.sock",
        key: keyForeign.toString("hex"),
        options: { alpns: [ALPN_MAIN.toString("hex")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" },
      })}\n`,
    );
    const refused = await ctl.answer(1);
    assert.match(String(refused.error), /another station's key/);
    ctl.conn.destroy();

    // Dialer on fB connects with ALPN_EXTRA, tests conn.hand + istream.hand + kind-3 route skip
    const dialer = await withFront({} as Mesh, fB.socket).bind({
      secretKey: keyB,
      relayUrls: [],
      discovery: false,
      bindAddr: "127.0.0.1:0",
      alpns: [ALPN_MAIN],
    });
    const routeDir = mkdtempSync(join(tmpdir(), `w7-route-${label}-`));
    dirs.push(routeDir);
    const routedSock = join(routeDir, "routed.sock");
    let resolveRouted!: (b: Buffer) => void;
    const routedGot = new Promise<Buffer>((r) => (resolveRouted = r));
    const routeServer = createServer((c) => {
      const parts: Buffer[] = [];
      c.on("data", (b: Buffer) => {
        parts.push(b);
        const all = Buffer.concat(parts);
        if (all.includes("/w7-routed")) resolveRouted(all);
      });
    });
    await new Promise<void>((r) => routeServer.listen(routedSock, r));
    try {
      assert.equal(await ep2.route!(ALPN_EXTRA, [routedSock], ["GET /w7-routed"]), true);
      const accepting = ep2.accept();
      const outConn = await dialer.connect(addrOf(ep2), ALPN_EXTRA);
      const inConn = (await accepting)!;
      assert.equal(inConn.remoteId(), dialer.id());
      assert.deepEqual(inConn.alpn(), ALPN_EXTRA);

      // Stream 0 -> Node (kind 2); Stream 1 -> routed (kind 3 skip); Stream 2 -> Node (kind 2)
      const s0 = await outConn.openBi();
      await s0.write(Buffer.from("s0"));
      await s0.finish();
      const s1 = await outConn.openBi();
      await s1.write(Buffer.from(`${JSON.stringify({ method: "GET", path: "/w7-routed" })}\n`));
      const s2 = await outConn.openBi();
      await s2.write(Buffer.from("s2"));
      await s2.finish();

      const recv0 = (await inConn.acceptBi())!;
      assert.equal((await readAllStream(recv0)).toString(), "s0");
      await routedGot;
      const recv2 = (await inConn.acceptBi())!;
      assert.equal((await readAllStream(recv2)).toString(), "s2");

      // Station-opened stream via openBi (`istream.hand` 17-byte header kind 1)
      const stationStream = await inConn.openBi();
      await stationStream.write(Buffer.from("from-station"));
      await stationStream.finish();
      const peerRecv = (await outConn.acceptBi())!;
      assert.equal((await readAllStream(peerRecv)).toString(), "from-station");

      // 3. `part` disconnect cleanup: close ep2 -> outConn observes closed; ep1 already bound earlier
      await ep2.close();
      await outConn.closed();
      await ep1.close();
    } finally {
      await new Promise<void>((r) => routeServer.close(() => r()));
    }

    // 4. Same-key different-identity rebind (dscp: 10) -> new sockets, front stays alive
    const rebind1 = await withFront({} as Mesh, fA.socket).bind({ ...baseOpts, dscp: 10 });
    assert.equal(fA.child.exitCode, null, "front stays alive after non-fixed-port rebind");

    // 5. `fixed_port` rebind: bind fixed UDP port, then rebind same key + same fixed port with different identity (dscp: 20)
    const udpRes = createSocket("udp4");
    await new Promise<void>((r) => udpRes.bind(0, "127.0.0.1", r));
    const fixedAddr = `127.0.0.1:${udpRes.address().port}`;
    await new Promise<void>((r) => udpRes.close(r));
    const fixed1 = await withFront({} as Mesh, fA.socket).bind({ ...baseOpts, bindAddr: fixedAddr, dscp: 10 });
    assert.ok(fixed1.sockets().includes(fixedAddr));
    const fixed2 = await withFront({} as Mesh, fA.socket).bind({ ...baseOpts, bindAddr: fixedAddr, dscp: 20 });
    assert.ok(fixed2.sockets().includes(fixedAddr));
    assert.equal(fA.child.exitCode, null, "front stays alive after fixed_port rebind");

    // 6. `giveUp` on in-flight connect (cancel via fetch.cancel without breaking front)
    const frontClient = await Front.open(fA.socket);
    try {
      await frontClient.ask("bind", {
        streams: frontClient.streamsPath,
        key: keyA.toString("hex"),
        options: { alpns: [ALPN_MAIN.toString("hex")], relayUrls: [], discovery: false, bindAddr: fixedAddr, dscp: 20 },
      });
      let connectAskId = 0;
      const connectP = frontClient.ask(
        "connect",
        { alpn: ALPN_MAIN.toString("hex"), addr: { id: dialer.id(), ips: ["127.0.0.1:1"] } },
        (n) => {
          connectAskId = n;
        },
      );
      assert.ok(connectAskId > 0);
      await frontClient.ask("giveUp", { of: connectAskId });
      await assert.rejects(connectP);
      // Front still answers subsequent asks cleanly
      const relays = await frontClient.ask("relayStatus");
      assert.ok(Array.isArray(relays));
    } finally {
      await frontClient.ask("close").catch(() => {});
      frontClient.close();
    }

    await fixed2.close();
    await fixed1.close();
    await rebind1.close();
    await dialer.close();

    // 7. Stdin EOF exits mesh front with code 0
    const exitP = new Promise<number | null>((resolve) => fA.child.once("exit", (code) => resolve(code)));
    fA.child.stdin!.end();
    assert.equal(await exitP, 0, "mesh front must exit 0 on stdin EOF");
  } finally {
    await fA.stop();
    await fB.stop();
  }
}

test("W7-A dual-engine forward parity: MB vs Pion (pipe, half-close, unreachable target, --listen-fd)", { timeout: 60_000 }, async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;
  await runForwardParity(bins.mb);
  await runForwardParity(bins.pion);
});

test("W7-A dual-engine mesh parity: MB vs Pion (bind, ALPN, wrong-key, rebind, fixed_port, routing, giveUp, part, stdin EOF)", { timeout: 60_000 }, async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;
  await runMeshParity(bins.mb, "mb");
  await runMeshParity(bins.pion, "pion");
});
