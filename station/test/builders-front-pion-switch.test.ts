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
import {
  mbReaderBinary,
  pionBinary,
  probePionSupportedModes,
  resetReaderSelectionStateForTest,
  resolveReaderSelection,
} from "../src/read/mb-reader.ts";
import { READER_MODES, readerModeEnvKey, resolveReaderEngine } from "../src/read/reader-select.ts";

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

  // 2. Unreachable target: hold probe port while forward binds so kernel cannot assign targetPort to forward,
  //    then release probe, connect c1 -> closed cleanly, then bring up target on targetPort -> forwards cleanly!
  const probe = createServer();
  await new Promise<void>((r) => probe.listen(0, "127.0.0.1", r));
  const targetPort = (probe.address() as AddressInfo).port;
  const fwdDead = await spawnForward(bin, ["--listen-port", "0", "--to", String(targetPort)]);
  await new Promise<void>((r) => probe.close(() => r()));
  let recovered: ReturnType<typeof createServer> | null = null;
  try {
    // Verify client genuinely connected to forwarder before being closed due to unreachable target.
    const c1 = connect(fwdDead.port, "127.0.0.1");
    await new Promise<void>((resolve, reject) => c1.once("connect", resolve).once("error", reject));
    const got1 = await readAllSocket(c1).catch(() => Buffer.alloc(0));
    assert.equal(got1.length, 0);
    assert.equal(fwdDead.child.exitCode, null, "unreachable target must not exit forward");

    // Bring up target on the exact same port and verify subsequent connection forwards cleanly.
    recovered = createServer({ allowHalfOpen: true }, (s) => {
      void readAllSocket(s).then((got) => s.end(Buffer.concat([Buffer.from("up:"), got])));
    });
    await new Promise<void>((r) => recovered!.listen(targetPort, "127.0.0.1", r));
    const got2 = await new Promise<Buffer>((resolve, reject) => {
      const c2 = connect(fwdDead.port, "127.0.0.1", () => c2.end(Buffer.from("again")));
      readAllSocket(c2).then(resolve, reject);
    });
    assert.equal(got2.toString(), "up:again");
  } finally {
    await fwdDead.stop();
    if (recovered) await new Promise<void>((r) => recovered!.close(() => r()));
  }

  // 3. Inherited `--listen-fd`
  const fdTarget = createServer({ allowHalfOpen: true }, (s) => {
    void readAllSocket(s).then((got) => s.end(Buffer.concat([Buffer.from("fd:"), got])));
  });
  await new Promise<void>((r) => fdTarget.listen(0, "127.0.0.1", r));
  const fdTargetPort = (fdTarget.address() as AddressInfo).port;
  const inherited = createServer();
  await new Promise<void>((r) => inherited.listen(0, "127.0.0.1", r));
  const inheritedPort = (inherited.address() as AddressInfo).port;
  const rawFd = (inherited as unknown as { _handle?: { fd?: number } })._handle?.fd;
  assert.ok(typeof rawFd === "number" && rawFd >= 0, "expected POSIX listening fd");
  const fwdFd = await spawnForward(bin, ["--listen-fd", "3", "--to", String(fdTargetPort)], rawFd);
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
    await new Promise<void>((r) => fdTarget.close(() => r()));
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

    // 2. Lone-surrogate `close` line MUST be dropped (first reply MUST be the following `route`, id=2) + wrong-key refusal
    const ctlRaw = connect(fA.socket);
    await new Promise<void>((resolve, reject) => ctlRaw.once("connect", resolve).once("error", reject));
    const rawLines: string[] = [];
    let rawLineBuf = "";
    const waitRawLines = (count: number) =>
      new Promise<string[]>((resolve) => {
        const check = () => {
          if (rawLines.length >= count) resolve(rawLines.slice(0, count));
        };
        ctlRaw.on("data", (chunk: Buffer) => {
          rawLineBuf += chunk.toString();
          for (let at = rawLineBuf.indexOf("\n"); at >= 0; at = rawLineBuf.indexOf("\n")) {
            rawLines.push(rawLineBuf.slice(0, at));
            rawLineBuf = rawLineBuf.slice(at + 1);
          }
          check();
        });
        check();
      });
    const firstTwoP = waitRawLines(2);
    ctlRaw.write(
      `{"id":999,"op":"close","bad":"\\uD800"}\n{"id":2,"op":"route","front":[],"routes":[],"alpn":null}\n${JSON.stringify({
        id: 1,
        op: "bind",
        streams: "/nonexistent/streams.sock",
        key: keyForeign.toString("hex"),
        options: { alpns: [ALPN_MAIN.toString("hex")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" },
      })}\n`,
    );
    const [firstLine, secondLine] = await firstTwoP;
    const firstReply = JSON.parse(firstLine!) as { id?: number; ok?: unknown };
    assert.equal(firstReply.id, 2, `lone-surrogate close must be dropped; first reply was ${firstLine}`);
    assert.equal(firstReply.ok, null);
    const refused = JSON.parse(secondLine!) as { id?: number; error?: string };
    assert.equal(refused.id, 1);
    assert.match(String(refused.error), /another station's key/);
    ctlRaw.destroy();

    // Dialer on fB connects with ALPN_EXTRA, verifying original endpoint is still alive after wrong-key refusal
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

      await ep2.close();
      await outConn.closed();
      await ep1.close();
    } finally {
      await new Promise<void>((r) => routeServer.close(() => r()));
    }

    // 3. `part` via real control socket disconnect (EOF, NOT protocol `close`):
    //    (a) clientA owns a live conn AND has an unclaimed `coming` conn queued;
    //    (b) clientB is already bound earlier;
    //    (c) destroying clientA's control socket closes clientA's owned conn AND redistributes unclaimed `coming` conn to clientB!
    const holder = await withFront({} as Mesh, fA.socket).bind(baseOpts);
    const rawA = await openControl(fA.socket);
    const bindRawA = (await (async () => {
      rawA.conn.write(
        `${JSON.stringify({
          id: 1,
          op: "bind",
          streams: "/nonexistent/raw-a.sock",
          key: keyA.toString("hex"),
          options: { alpns: [ALPN_MAIN.toString("hex")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" },
        })}\n`,
      );
      return await rawA.answer(1);
    })()) as { ok: { id: string; sockets: string[] } };
    assert.equal(bindRawA.ok.id, holder.id());
    // Dial 2 connections: rawA accepts the first (now owned), leaves the second unclaimed in `coming`.
    rawA.conn.write(`${JSON.stringify({ id: 2, op: "accept" })}\n`);
    const ownedByA = await dialer.connect(addrOf(holder), ALPN_MAIN);
    const acceptedByA = await rawA.answer(2);
    assert.ok(acceptedByA.ok);
    const unclaimedOnA = await dialer.connect(addrOf(holder), ALPN_MAIN);
    const holderAccepting = holder.accept();
    // Abruptly destroy rawA's control socket (EOF triggers `part` without protocol `close`).
    rawA.conn.destroy();
    // Owned conn closes; unclaimed conn is redistributed to `holder`!
    await ownedByA.closed();
    const redistributed = (await holderAccepting)!;
    assert.equal(redistributed.remoteId(), dialer.id());
    unclaimedOnA.close(0, "");
    await redistributed.closed();

    // 4. Same-key different-identity rebind (dscp: 10):
    //    keep a live conn on old endpoint, verify old endpoint closes it on rebind, new endpoint has same id + new sockets + accepts new handshake!
    const oldConn = await dialer.connect(addrOf(holder), ALPN_MAIN);
    const oldAccepted = (await holder.accept())!;
    assert.equal(oldAccepted.remoteId(), dialer.id());
    const rebind1 = await withFront({} as Mesh, fA.socket).bind({ ...baseOpts, dscp: 10 });
    assert.equal(rebind1.id(), holder.id(), "same key rebind preserves endpointId");
    assert.notEqual(rebind1.sockets().join(), holder.sockets().join(), "dscp change binds a new endpoint");
    assert.equal(fA.child.exitCode, null, "front stays alive after non-fixed-port rebind");
    await oldConn.closed();
    // Verify numeric `dscp: 10.0` via raw control socket reuses the exact same endpoint (no extra rebind!)
    const ctlNum = await openControl(fA.socket);
    ctlNum.conn.write(
      `{"id":1,"op":"bind","streams":"/nonexistent/s.sock","key":${JSON.stringify(keyA.toString("hex"))},"options":{"alpns":[${JSON.stringify(ALPN_MAIN.toString("hex"))}],"relayUrls":[],"discovery":false,"bindAddr":"127.0.0.1:0","dscp":10.0}}\n`,
    );
    const numRes = (await ctlNum.answer(1)) as { ok?: { id: string; sockets: string[] } };
    assert.deepEqual(numRes.ok?.sockets, rebind1.sockets(), "dscp: 10.0 must match dscp: 10 without rebinding");
    ctlNum.conn.destroy();
    const rebindAccept = rebind1.accept();
    const rebindDial = await dialer.connect(addrOf(rebind1), ALPN_MAIN);
    assert.equal((await rebindAccept)!.remoteId(), dialer.id());
    rebindDial.close(0, "");
    await holder.close();

    // 5. `fixed_port` rebind: bind fixed UDP port with live conn, rebind same key + fixed port with dscp: 20, verify old closes & new accepts on same port!
    const udpRes = createSocket("udp4");
    await new Promise<void>((r) => udpRes.bind(0, "127.0.0.1", r));
    const fixedAddr = `127.0.0.1:${udpRes.address().port}`;
    await new Promise<void>((r) => udpRes.close(r));
    const fixed1 = await withFront({} as Mesh, fA.socket).bind({ ...baseOpts, bindAddr: fixedAddr, dscp: 10 });
    assert.ok(fixed1.sockets().includes(fixedAddr));
    const fixedOldAcc = fixed1.accept();
    const fixedOldDial = await dialer.connect(addrOf(fixed1), ALPN_MAIN);
    assert.equal((await fixedOldAcc)!.remoteId(), dialer.id());
    const fixed2 = await withFront({} as Mesh, fA.socket).bind({ ...baseOpts, bindAddr: fixedAddr, dscp: 20 });
    assert.equal(fixed2.id(), fixed1.id(), "fixed_port rebind preserves endpointId");
    assert.ok(fixed2.sockets().includes(fixedAddr));
    assert.equal(fA.child.exitCode, null, "front stays alive after fixed_port rebind");
    await fixedOldDial.closed();
    const fixedNewAcc = fixed2.accept();
    const fixedNewDial = await dialer.connect(addrOf(fixed2), ALPN_MAIN);
    assert.equal((await fixedNewAcc)!.remoteId(), dialer.id());
    fixedNewDial.close(0, "");

    // 6. `giveUp` on in-flight connect (cancel via fetch.cancel; assert non-empty cancellation error)
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
      await assert.rejects(connectP, /cancel/i);
      const relays = await frontClient.ask("relayStatus");
      assert.ok(Array.isArray(relays));
    } finally {
      await frontClient.ask("close").catch(() => {});
      frontClient.close();
    }

    // 6b. Non-safe-integer JS number parity (`1e20`/`2e20` vs expanded integer strings):
    //     both MB and Pion echo `100000000000000000000` on `route(id: 1e20)` and match `connect(id: 2e20)` with `giveUp(of: 200000000000000000000)`.
    const bigCtl = connect(fA.socket);
    await new Promise<void>((resolve, reject) => bigCtl.once("connect", resolve).once("error", reject));
    try {
      const bigLines: string[] = [];
      let bigBuf = "";
      const waiters: Array<() => void> = [];
      bigCtl.on("data", (chunk: Buffer) => {
        bigBuf += chunk.toString();
        for (let at = bigBuf.indexOf("\n"); at >= 0; at = bigBuf.indexOf("\n")) {
          bigLines.push(bigBuf.slice(0, at));
          bigBuf = bigBuf.slice(at + 1);
        }
        while (waiters.length > 0) waiters.shift()!();
      });
      const waitCount = async (n: number) => {
        while (bigLines.length < n) await new Promise<void>((r) => waiters.push(r));
      };
      bigCtl.write(
        `{"id":1e20,"op":"route","front":[],"routes":[],"alpn":null}\n{"id":2e20,"op":"connect","alpn":${JSON.stringify(ALPN_MAIN.toString("hex"))},"addr":{"id":${JSON.stringify(dialer.id())},"ips":["127.0.0.1:1"]}}\n{"id":2,"op":"giveUp","of":200000000000000000000}\n`,
      );
      await waitCount(3);
      const routeReplyLine = bigLines.find((l) => l.includes("100000000000000000000"));
      assert.ok(
        routeReplyLine,
        `route id 1e20 must serialize as 100000000000000000000, got: ${JSON.stringify(bigLines)}`,
      );
      const connectCancelLine = bigLines.find((l) => l.includes("200000000000000000000"));
      assert.ok(connectCancelLine, `expected connect reply with 200000000000000000000 in ${JSON.stringify(bigLines)}`);
      assert.match(String(JSON.parse(connectCancelLine).error ?? ""), /cancel/i);
    } finally {
      bigCtl.destroy();
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

test("W7-A dual-engine forward parity: MB vs Pion (pipe, half-close, unreachable->recovered target, --listen-fd)", { timeout: 60_000 }, async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;
  await runForwardParity(bins.mb);
  await runForwardParity(bins.pion);
});

test("W7-A dual-engine mesh parity: MB vs Pion (bind, ALPN, wrong-key, lone-surrogate, dscp 10.0, EOF part, rebind, fixed_port, routing, giveUp, stdin EOF)", { timeout: 60_000 }, async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;
  await runMeshParity(bins.mb, "mb");
  await runMeshParity(bins.pion, "pion");
});

test("READER_MODES mesh resolves to Pion with STILLFAIL_READER_MESH while forward remains unwired", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;
  resetReaderSelectionStateForTest();
  assert.equal(READER_MODES.forward.pionImplemented, false);
  assert.equal(READER_MODES.mesh.pionImplemented, true);
  assert.equal(readerModeEnvKey("forward"), "STILLFAIL_READER_FORWARD");
  assert.equal(readerModeEnvKey("mesh"), "STILLFAIL_READER_MESH");

  const supported = await probePionSupportedModes(bins.pion);
  assert.ok(supported !== null, "Pion --version capability probe must succeed");
  assert.equal(supported.has("forward"), true);
  assert.equal(supported.has("mesh"), true);

  // Default (no env or config) stays on MB.
  const defMesh = resolveReaderSelection("mesh", { config: undefined, env: {} });
  assert.equal(defMesh.engine, "mb");
  assert.equal(defMesh.primaryBinary, bins.mb);
  assert.equal(defMesh.selection.fallback, false);

  // forward has no production spawner so pionImplemented stays false (falls back to MB).
  const envForward = resolveReaderSelection("forward", {
    config: undefined,
    env: { STILLFAIL_READER_FORWARD: "pion" },
  });
  assert.equal(envForward.engine, "mb");
  assert.equal(envForward.primaryBinary, bins.mb);
  assert.equal(envForward.selection.fallback, true);
  assert.equal(envForward.selection.reason, "pion-mode-unimplemented");

  // Explicit STILLFAIL_READER_MESH selects Pion for mesh.
  const envMesh = resolveReaderSelection("mesh", {
    config: undefined,
    env: { STILLFAIL_READER_MESH: "pion" },
  });
  assert.equal(envMesh.engine, "pion");
  assert.equal(envMesh.primaryBinary, bins.pion);
  assert.equal(envMesh.selection.source, "env");
  assert.equal(envMesh.selection.fallback, false);

  // config.readers.mesh selects Pion, and STILLFAIL_READER_MESH=mb rolls back over config.
  const cfgMesh = resolveReaderSelection("mesh", {
    config: { readers: { mesh: "pion" } },
    env: {},
  });
  assert.equal(cfgMesh.engine, "pion");
  assert.equal(cfgMesh.primaryBinary, bins.pion);
  assert.equal(cfgMesh.selection.source, "config");

  const rollbackMesh = resolveReaderSelection("mesh", {
    config: { readers: { mesh: "pion" } },
    env: { STILLFAIL_READER_MESH: "mb" },
  });
  assert.equal(rollbackMesh.engine, "mb");
  assert.equal(rollbackMesh.primaryBinary, bins.mb);
  assert.equal(rollbackMesh.selection.source, "env");

  // Shadow remains forbidden for network-binding forward & mesh modes.
  for (const mode of ["forward", "mesh"] as const) {
    const shadow = resolveReaderEngine(mode, {
      config: { readers: { [mode]: "shadow" } },
      env: {},
      hasPionBinary: true,
    });
    assert.equal(shadow.engine, "mb");
    assert.equal(shadow.fallback, true);
    assert.equal(shadow.reason, "shadow-forbidden");
  }
});
