// Two stations for the tests of station_task's `dir` (test/dirsync.test.ts, test/mb-dirsync.test.ts): a source and a
// target, the source's requests to the target over the real station transport (mesh/peer.ts) between endpoints connected
// in memory.
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { lstatSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after } from "node:test";
import { type Clock, type Duration, Effect, Exit, Scope } from "effect";
import { TestClock } from "effect/testing";
import { Cloud } from "../src/cloud/state.ts";
import { killGroups } from "./kill-groups.ts";
import { Jobs, type Machine } from "../src/jobs/jobs.ts";
import { type PeerCall, Refused, Remote } from "../src/jobs/remote.ts";
import { PEER_ALPN, PEER_BYTES_ALPN, peerCall, servePeer } from "../src/mesh/peer.ts";
import { bytesOf, withBytes } from "../src/mesh/bus.ts";
import { oneBytes } from "../src/mesh/files.ts";
import { type Json, Store } from "../src/store/store.ts";
import { remoteTools } from "../src/tools/remote.ts";
import { memoryMesh } from "./memory-mesh.ts";

const dirs: string[] = [];
const cleanup: (() => Promise<void> | void)[] = [];
after(async () => {
  for (const c of cleanup.reverse()) await c();
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

export function tempdir(): string {
  const d = mkdtempSync(join(tmpdir(), "dirsync-test-"));
  dirs.push(d);
  return d;
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/// Waits for what real I/O does (a process), looking every 5 ms. No deadline.
export async function until(_what: string, check: () => boolean) {
  while (!check()) await sleep(5);
}

export const FOREVER = "tail -f /dev/null";

/// `clean` asked again while it answers pending, as an agent is told to (a removal answers early, after
/// CLEAN_ANSWER_MS of the machine's time, while its lane is still busy: on a loaded CI runner it did, and the test
/// read `pending` as the clean let through). Its answer, or what it refused with.
export async function cleaned(use: (name: string, args: Json) => Promise<any>, mirror: string): Promise<any> {
  for (;;) {
    const answer = await use("station_task", { action: "clean", mirror });
    if (answer?.pending !== true) return answer;
  }
}

export function testClock() {
  const scope = Effect.runSync(Scope.make());
  cleanup.push(() => Effect.runPromise(Scope.close(scope, Exit.void)).catch(() => undefined));
  return Effect.runSync(Scope.provide(TestClock.make(), scope));
}

/// Moves `clock` on by `by` until `check` holds (no deadline).
export async function rounds(clock: ReturnType<typeof testClock>, by: Duration.Input, check: () => boolean) {
  while (!check()) {
    await Effect.runPromise(clock.adjust(by));
    await sleep(1);
  }
}

export const git = (dir: string, ...args: string[]) =>
  execFileSync("git", ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "init.defaultBranch=main", "-c", "core.autocrlf=false", ...args], { encoding: "utf8" });

export const cloudOf = (station: string, peers: string[]): any =>
  Object.assign(Object.create(Cloud.prototype), {
    state: { workspace: "ws", workspace_name: "ws", name: "", station, peers: peers.map((id) => ({ id })), revocations: [], joined: [] },
    lock: null,
    peersCurrent: true,
    relays: () => [],
  });

/// A machine with room for every task (jobs/admit.ts): its memory under no pressure.
export const idle: Machine = { pressure: async () => "normal" as const };

/// A source station A and a target B of workspace "ws", A's requests to B over the station transport (in memory). `old`:
/// B answers as a station from before directory sync would. `asked`: the methods A asked B, in order. `queue`: B's jobs
/// on a clock of their own (`queueClock`) and an idle machine, where a test starts a task beside one running (its queue
/// waits for room on that clock, not on the machine the test runs on). `before`: both speak the transport of before
/// 2026-10-29 only, files and contents going in chunks of base64.
export async function pair(options: { queue?: boolean; before?: boolean } = {}) {
  const clock = testClock();
  const queueClock = options.queue ? testClock() : undefined;
  const mesh = memoryMesh();
  const alpns = options.before ? [PEER_ALPN] : [PEER_BYTES_ALPN, PEER_ALPN];
  const bind = () => mesh.bind({ secretKey: randomBytes(32), alpns, relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  const [source, target] = await Promise.all([bind(), bind()]);
  cleanup.push(() => Promise.all([source.close(), target.close()]).then(() => undefined));
  /// What the target's disk has free (`disk.free`; plenty unless a test says otherwise).
  const disk = { free: () => 500 * 1024 ** 3 };
  const make = (dir: string, options: { clock?: Clock.Clock; diskFree?: (path: string) => number; jobsClock?: Clock.Clock; machine?: Machine } = {}) => {
    const store = Store.open(":memory:");
    const told: [string, string][] = [];
    const jobs = new Jobs({ store, data: dir, notify: () => {}, link: () => null, clock: options.jobsClock, machine: options.machine });
    const remote = new Remote({ data: dir, store, jobs, clock: options.clock, diskFree: options.diskFree, notify: (session, text) => void told.push([session, text]) });
    cleanup.push(async () => {
      await remote.close();
      await jobs.shutdown();
      await killGroups(store.listJobs(null).map((job) => job.pgid));
      store.close();
    });
    return { dir, store, jobs, remote, told };
  };
  const a = make(tempdir(), { clock });
  const b = make(tempdir(), { diskFree: () => disk.free(), ...(queueClock ? { jobsClock: queueClock, machine: idle } : {}) });
  const B = target.id();
  mkdirSync(join(a.dir, "mesh"), { recursive: true });
  writeFileSync(join(a.dir, "mesh", "cloud.json"), JSON.stringify({ workspace: "ws", station: source.id() }));
  const home = join(a.dir, "work");
  mkdirSync(home);
  a.store.insertSession({ key: "s1", connect: "ds", runtime: "claude", profile: "cc", workspace: home, token: "t1", createdBy: "ann", createdAt: Date.now(), lastActiveAt: Date.now() });
  const targetCloud = cloudOf(B, [source.id()]);
  void (async () => {
    for (;;) {
      const conn = await target.accept();
      if (!conn) return;
      void servePeer(conn, targetCloud, b.remote).catch(() => {});
    }
  })();
  const port = target.sockets()[0]!.split(":").at(-1);
  const call = peerCall(source, cloudOf(source.id(), [B]), (id) => ({ id, ips: [`127.0.0.1:${port}`] }));
  // B tells A of its tasks (`task.changed`) over the transport the other way.
  const sourceCloud = cloudOf(source.id(), [B]);
  void (async () => {
    for (;;) {
      const conn = await source.accept();
      if (!conn) return;
      void servePeer(conn, sourceCloud, a.remote).catch(() => {});
    }
  })();
  const sourcePort = source.sockets()[0]!.split(":").at(-1);
  b.remote.attach(peerCall(target, targetCloud, (id) => ({ id, ips: [`127.0.0.1:${sourcePort}`] })));
  /// `record`: each sync request to B kept in `sent`, with the bytes after it. `hold`: the methods held before they are
  /// asked, until `release`d. `bulk`/`most`: the bulk requests (contents,
  /// files' chunks) under way now, and the most there were at once.
  const state = { old: false, beforeSafe: false, failFileGet: false, asked: [] as string[], record: false, sent: [] as { request: Json; bytes: Buffer | null }[], hold: new Set<string>(), held: [] as (() => void)[], bulk: 0, most: 0 };
  const release = () => {
    state.hold.clear();
    for (const go of state.held.splice(0)) go();
  };
  const transport: PeerCall = async (to, workspace, request) => {
    if (to !== "") state.asked.push(request.method);
    if (state.record && to !== "" && /^sync\./.test(request.method)) {
      // (its bytes taken whole and sent on as they were)
      const bytes = bytesOf(request);
      let taken: Buffer | null = null;
      if (bytes !== null) {
        const pieces: Buffer[] = [];
        for await (const piece of bytes) pieces.push(piece);
        taken = Buffer.concat(pieces);
        request = withBytes({ ...request }, oneBytes(taken));
      }
      state.sent.push({ request: { ...request }, bytes: taken });
    }
    if (state.hold.has(request.method)) await new Promise<void>((go) => state.held.push(go));
    if (state.failFileGet && request.method === "file.get") throw new Refused("artifact temporarily unavailable");
    if (/^(sync\.put|file\.put|file\.get)$/.test(request.method)) {
      state.most = Math.max(state.most, ++state.bulk);
      try {
        return await call(to, workspace, request);
      } finally {
        state.bulk--;
      }
    }
    if (state.old && request.method === "describe") {
      const { sync: _, ...before } = await call(to, workspace, request);
      return before;
    }
    if (state.beforeSafe && request.method === "sync.begin") {
      const { safe: _, ...before } = await call(to, workspace, request);
      return before;
    }
    if (state.old && /^(sync\.|task\.files$)/.test(request.method)) throw new Refused(`unsupported peer method: ${request.method}`);
    return call(to, workspace, request);
  };
  a.remote.attach(transport);
  const tools = remoteTools(a.remote);
  const use = async (name: string, args: Json) => JSON.parse(await tools.find((t) => t.name === name)!.run("s1", { station: B, ...args }));
  /// Prepares and starts `key` (running `command` in `dir`), and waits for its process to end.
  const run = async (key: string, dir: string, command: string, more: Json = {}) => {
    const prepared = await use("station_task", { key, action: "prepare", command, dir, ...more });
    const started = await use("station_task", { key, action: "start" });
    await until("it ends", () => b.store.getJob(started.job.id)!.state !== "running");
    await until("its results are delivered", () => a.told.some(([, text]) => text.startsWith(`Remote task ${key} on `) && text.includes('"state":"exited"')));
    return { prepared, started, sync: started.sync };
  };
  const mirror = (name: string) => join(b.remote.room("ws", source.id(), "s1"), "work", name);
  return { a, b, A: source.id(), B, home, clock, queueClock, use, run, mirror, state, release, disk };
}

export const stamp = (path: string) => {
  const st = lstatSync(path);
  return [st.mtimeMs, st.ino, st.size];
};

