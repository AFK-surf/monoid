// What the station's main thread waits on as it lends phones and screens, answers the device tools, runs as the
// machine's administrator, keeps the model catalog and a rig's grants: nothing of node:fs's synchronous calls
// (station/AGENTS.md, the main thread waits on nothing) but what each reads once before the station serves. A display's
// jar was looked at for its size, a grant's adb server's directory made and taken away, a device tool's paths followed
// and the runtimes' logins read, a simulator's folders made, every GET /overview of a Windows station read two files
// and a change of how it runs copied and wrote five, the catalog and the grants written there.
import assert from "node:assert/strict";
import type { ChildProcess } from "node:child_process";
import { createHash, generateKeyPairSync, sign as nodeSign } from "node:crypto";
import { EventEmitter } from "node:events";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, mock, test } from "node:test";
import { type GrantBody, type Kind, latest, signedBytes } from "../../client/core-ts/src/rig-form.ts";
import { PhoneDisplays } from "../src/adb/displays.ts";
import { adbPath } from "../src/adb/link.ts";
import { GrantServers, type Server } from "../src/adb/servers.ts";
import { type Entry, entryHash, signedBytes as entryBytes } from "../../shared/lock.ts";
import { DeviceTools } from "../src/device/tools.ts";
import { Elevation } from "../src/elevation/elevation.ts";
import { ModelCatalog } from "../src/models/module.ts";
import { Fibers } from "../src/ops/fibers.ts";
import { platform, WINDOWS } from "../src/platform/index.ts";
import { RigGrants } from "../src/rig/grants.ts";
import { SimDebug } from "../src/screens/sim-debug.ts";
import { Effect } from "effect";
import { testClock } from "./hub-fakes.ts";
import { syncCalls } from "./main-thread-sync.ts";

const dirs: string[] = [];
after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});
const made = (name: string) => {
  const d = realpathSync(mkdtempSync(join(tmpdir(), `${name}-`)));
  dirs.push(d);
  return d;
};

test("a chat's display on a phone: its program looked at for its size off the thread", { skip: process.platform === "win32" }, async () => {
  const dir = made("main-thread-display");
  const phone = net.createServer((s) => (s.write(Buffer.from([0])), s.on("error", () => {})));
  await new Promise<void>((r) => phone.listen(0, "127.0.0.1", () => r()));
  const port = (phone.address() as net.AddressInfo).port;
  const adb = join(dir, "adb");
  writeFileSync(adb, `#!/bin/sh
case "$*" in
  *"forward tcp:0"*) echo ${port} ;;
  *ro.build.version.sdk*) echo 34 ;;
  *"wm size"*) echo 'Physical size: 1080x2400' ;;
  *"wm density"*) echo 'Physical density: 420' ;;
  *app_process*) echo '[server] INFO: New display: 1080x2400/420 (id=2)'; exec sleep 60 ;;
esac
`);
  chmodSync(adb, 0o755);
  const displays = new PhoneDisplays({ adb: () => adb, file: adb, usedAt: () => Date.now(), changed: () => {}, idleMs: 60_000 });
  try {
    let shown: unknown = null;
    assert.deepEqual(await syncCalls(async () => void (shown = await displays.open("g1", "p@x", "修登录页", 41000, "127.0.0.1:37001"))), []);
    assert.equal((shown as { id: number } | null)?.id, 2);
    await displays.close("g1");
  } finally {
    displays.closeAll();
    phone.close();
  }
});

test("the machine's adb, asked for as each phone is offered: looked for on the thread only before the station serves", async () => {
  adbPath();
  assert.deepEqual(await syncCalls(async () => {
    // (each looked for again off the thread, for the next ask)
    for (let i = 0; i < 3; i++) adbPath();
  }), []);
});

test("a grant's adb server: its directory made and taken away off the thread", { skip: process.platform === "win32" }, async () => {
  const dir = made("main-thread-adb-servers");
  const adb = join(dir, "adb");
  // A server on the socket its environment names (behind the grant's door), until it is ended.
  writeFileSync(adb, `#!${process.execPath}\nrequire("node:net").createServer((c) => c.destroy()).listen(process.env.ADB_SERVER_SOCKET.slice("localfilesystem:".length));\n`, { mode: 0o755 });
  const servers = new GrantServers(() => adb, join(dir, "adb-servers.json"), async () => null);
  const started: Server[] = [];
  try {
    let gone: Promise<unknown> = Promise.resolve();
    assert.deepEqual(await syncCalls(async () => {
      const s = await servers.ensure("g1");
      assert.ok(s !== null, "started");
      started.push(s);
      gone = new Promise((resolve) => s.child.once("exit", resolve));
      await servers.close();
      await gone;
      await servers.written();
    }), []);
  } finally {
    for (const s of started) s.child.kill("SIGKILL");
  }
});

test("the device tools: a path followed to see whether it is the station's own, and the runtimes' logins, off the thread", async () => {
  const home = made("main-thread-device-tools");
  mkdirSync(join(home, "data"));
  writeFileSync(join(home, "notes.txt"), "x");
  const tools = new DeviceTools({ home, env: { PATH: join(home, "bin"), HOME: home }, protect: () => [join(home, "data")] });
  const run = (op: string, args: Record<string, unknown>) =>
    Effect.runPromise(Effect.match(tools.run(op, args, {}, "read"), { onFailure: (e) => ({ refused: e.code }), onSuccess: () => ({ refused: null }) }));
  let said: unknown[] = [];
  assert.deepEqual(await syncCalls(async () => {
    said = [await run("fs.stat", { path: "notes.txt" }), await run("fs.stat", { path: "data/x" }), await run("runtime.probe", {})];
  }), []);
  assert.deepEqual(said, [{ refused: null }, { refused: "forbidden" }, { refused: null }]);
  tools.close();
});

test("the device tools' exec and process.start find their shell off the thread", { skip: WINDOWS && "a POSIX command" }, async () => {
  const home = made("main-thread-device-shell");
  const tools = new DeviceTools({ home, env: { PATH: process.env.PATH, HOME: home } });
  const run = (op: string, args: Record<string, unknown>) => Effect.runPromise(tools.run(op, args, {}, "full")) as Promise<Record<string, unknown>>;
  // What finds the shell on the station's thread is for what runs before it serves (on Windows it looks on disk).
  const shell = mock.method(platform, "posixShell", () => {
    throw new Error("the shell found on the main thread");
  });
  let ran: Record<string, unknown> = {};
  let started: Record<string, unknown> = {};
  try {
    assert.deepEqual(await syncCalls(async () => {
      ran = await run("exec", { command: "echo hi" });
      started = await run("process.start", { command: "echo there" });
    }), []);
  } finally {
    shell.mock.restore();
    tools.close();
  }
  assert.equal(shell.mock.callCount(), 0);
  assert.equal(ran.exit_code, 0);
  assert.equal(ran.stdout, "hi\n");
  assert.equal(started.process_id, "p1");
});

test("a simulator's install folder named and an app in it installed: its folders made off the thread", async () => {
  const debug = new SimDebug("simctl", "U", async (file, args) => (file === "plutil" ? JSON.stringify({ CFBundleIdentifier: "fail.still.demo" }) : (void args, "")), async () => new Uint8Array(), () => ({ stop: () => {} }));
  let folder = "";
  assert.deepEqual(await syncCalls(async () => {
    folder = debug.installFolder();
    // (no app in it: nothing installed, the file let go of)
    assert.equal(await debug.install(join(folder, "none.ipa")), null);
  }), []);
  assert.match(folder, /stillfail-sim-install$/);
});

/// A Windows station's data as install.ps1 leaves it, its Elevation on a clock the test moves.
async function elevation() {
  const data = made("main-thread-elevation");
  const app = join(data, "app");
  mkdirSync(join(app, "mesh", "target", "release"), { recursive: true });
  writeFileSync(join(app, "mesh", "target", "release", "stillfail-station-w.exe"), "");
  mkdirSync(join(data, "run"));
  writeFileSync(join(data, "windows.json"), JSON.stringify({ task: "apart" }));
  let now = 1_000_000;
  const timers: { at: number; f: () => void }[] = [];
  const ran: (ChildProcess & EventEmitter)[] = [];
  const e = new Elevation({
    data, app, now: () => now, changed: () => {},
    after: (ms, f) => {
      const t = { at: now + ms, f };
      timers.push(t);
      return () => void timers.splice(timers.indexOf(t), 1);
    },
    probe: async () => ({ elevated: false, admin: true }),
    run: () => {
      const child = new EventEmitter() as ChildProcess & EventEmitter;
      (child as any).kill = () => true;
      ran.push(child);
      return child;
    },
  });
  await e.start();
  const pass = (ms: number) => {
    now += ms;
    for (const t of timers.filter((t) => t.at <= now)) (timers.splice(timers.indexOf(t), 1), t.f());
  };
  return { e, data, ran, pass };
}

test("a Windows station's overview reads no file, and a change of how it runs and its look at the elevated side are off the thread", async () => {
  const s = await elevation();
  assert.deepEqual(await syncCalls(async () => {
    for (let i = 0; i < 3; i++) assert.equal(s.e.view(true).on, false);
    await s.e.change(true);
    assert.equal(s.e.view(true).step, "asking");
    s.ran[0]!.emit("exit", 0);
    // The elevated side says how it goes, in its file: read as it is looked at.
    await s.e.settled();
    await writeFile(join(s.data, "run", "elevation.json"), JSON.stringify({ want: true, at: 1, step: "applying" }));
    await writeFile(join(s.data, "windows.json"), JSON.stringify({ task: "apart", admin: true }));
    s.pass(1000);
    await s.e.settled();
    assert.equal(s.e.view(true).step, "applying");
    assert.equal(s.e.view(true).on, true);
    s.pass(60_000);
    await s.e.settled();
    assert.equal(s.e.view(true).failed, "error");
    await s.e.stop();
  }), []);
  assert.equal(JSON.parse(readFileSync(join(s.data, "run", "elevation.json"), "utf8")).failed, "error", "written");
});

test("a refused prompt: what the elevated side may have said read, how it failed written, off the thread", async () => {
  const s = await elevation();
  assert.deepEqual(await syncCalls(async () => {
    await s.e.change(true);
    await assert.rejects(s.e.change(false), { key: "busy" });
    s.ran[0]!.emit("exit", 4);
    await s.e.settled();
    assert.equal(s.e.view(true).failed, "declined");
  }), []);
});

test("the model catalog the cloud sent: written off the thread", async () => {
  const dir = made("main-thread-models");
  const file = join(dir, "model-catalog.json");
  const get = async () => new Response(JSON.stringify({ models: {} }), { status: 200, headers: { etag: '"1"' } });
  const catalog = new ModelCatalog(file, () => "https://cloud.test", () => 0, get);
  assert.deepEqual(await syncCalls(async () => {
    await catalog.refresh();
    await catalog.written();
  }), []);
  assert.equal(JSON.parse(readFileSync(file, "utf8")).etag, '"1"');
});

const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest();

function ed() {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const hex = (publicKey.export({ format: "der", type: "spki" }) as Buffer).subarray(-32).toString("hex");
  return { hex, id: `ed25519:${hex}`, sign: (bytes: Uint8Array) => nodeSign(null, bytes, privateKey).toString("hex") };
}

test("a rig's grants given and taken back: kept in memory at once, written off the thread", async () => {
  const [WS, RIG, STATION] = ["01WORKSPACE", "aa".repeat(32), "bb".repeat(32)];
  const key = ed();
  const genesis = { v: 1, ws: "person:pat", seq: 0, prev: null, at: 1000, kind: "genesis", body: { sub: "pat", device: { key: key.id, id: ed().hex, label: "first" } } } as Omit<Entry, "sig">;
  const chain = [{ ...genesis, sig: { key: key.id, alg: "Ed25519", sig: key.sign(entryBytes(entryHash(genesis as Entry))) } } as Entry];
  const says = <B>(kind: Kind, body: B) => ({ body, sig: { key: key.id, sig: key.sign(signedBytes(kind, body, sha256)) } });
  const time = testClock();
  await time.adjust(1_800_000_000_000);
  const fibers = new Fibers("rig-main-thread", time.clock);
  const dir = made("main-thread-rig");
  const make = () => new RigGrants({
    path: join(dir, "grants.json"),
    self: () => ({ id: RIG, workspace: WS, owner: "pat", person: entryHash(chain[0]!) }),
    busy: () => false, stop: () => {}, running: () => [], ended: () => {}, changed: () => {}, fibers,
  });
  try {
    const rig = make();
    const at = Math.floor(fibers.now() / 1000);
    const timeout = { kind: "idle" as const, seconds: 3600 };
    const grant = says("grant", { v: 1, sub: "pat", ws: WS, rig: RIG, station: STATION, session: "s1", chat: "CHAT/s1", request: "r1", title: "chat s1", by: "lee@example.com", timeout, at, exp: latest(at, timeout) } as GrantBody);
    assert.deepEqual(await syncCalls(async () => {
      rig.grant(STATION, grant, chain);
      assert.equal(rig.refusal(WS, STATION, "s1"), null, "in force at once");
      await rig.written();
      rig.revoke(says("revoke", { v: 1 as const, sub: "pat", ws: WS, rig: RIG, request: "r1", at }));
      assert.match(rig.refusal(WS, STATION, "s1")!, /no grant/);
      await rig.close();
      await rig.written();
    }), []);
    // Read again as the next station starts: taken back.
    const again = make();
    assert.match(again.refusal(WS, STATION, "s1")!, /no grant/);
    assert.deepEqual(Object.keys(JSON.parse(readFileSync(join(dir, "grants.json"), "utf8")).revoked), ["r1"]);
    await again.close();
  } finally {
    await fibers.close();
  }
});
