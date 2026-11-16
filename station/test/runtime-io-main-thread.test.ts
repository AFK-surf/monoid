// What the station's main thread waits on as it runs a command with a grant (src/vault/run.ts `runWith`, its proxy's
// CA: src/vault/proxy.ts), makes a drive file's thumbnail (src/drive/thumbs.ts `thumbnail`, `kept`), answers the
// overview (src/api/overview.ts, the disk's room), hands its streams' events over to the next process and takes them up
// (src/api/events.ts `handOver`, `takeUp`), and finds, starts and ends the station's Chrome and keeps whose its tabs are
// (src/browser/chrome.ts, src/browser/owners.ts): none of node:fs's synchronous calls (station/AGENTS.md, the main
// thread waits on nothing). Each ran on every secret_run, drive preview, overview, update and tab opened or closed.
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, mkdirSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { Events } from "../src/api/events.ts";
import { overview } from "../src/api/overview.ts";
import { BrowserState, type Running, chromeHost, readState } from "../src/browser/chrome.ts";
import { Owners } from "../src/browser/owners.ts";
import { idOf, kept, thumbnail } from "../src/drive/thumbs.ts";
import { Store } from "../src/store/store.ts";
import type { Held } from "../src/vault/keeper.ts";
import { Proxy } from "../src/vault/proxy.ts";
import { runWith } from "../src/vault/run.ts";
import { settle, testClock } from "./hub-fakes.ts";
import { syncCalls } from "./main-thread-sync.ts";

const dirs: string[] = [];
after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});
function scratch(name: string): string {
  const dir = mkdtempSync(join(tmpdir(), `${name}-`));
  dirs.push(dir);
  return dir;
}

/// A grant held for a run: of `mode`, its secret `fields` of `kind`.
const held = (mode: string, kind: string, fields: Record<string, string>, hosts: string[] = []): Held =>
  ({ request: { id: `r_${mode}` }, grant: { mode, hosts }, secret: { kind, name: mode, fields }, uses: 0 }) as unknown as Held;

test("a command run with a grant, by its file, its SSH agent or the proxy, waits on no file", async () => {
  const dir = scratch("run-main-thread");
  const proxy = new Proxy(join(dir, "vault"), () => 0);
  const key = generateKeyPairSync("ed25519").privateKey.export({ format: "pem", type: "pkcs8" }).toString();
  const env = { PATH: process.env.PATH ?? "" };
  const ask = (command: string) => ({ command, cwd: dir, env: "GIVEN", timeoutMs: 60_000 });
  const ran: string[] = [];
  const calls = await syncCalls(async () => {
    const file = await runWith(held("file", "file", { content: Buffer.from("kept\n").toString("base64"), filename: "k.txt" }), ask('cat "$GIVEN"; echo "$GIVEN"'), proxy, env, () => {});
    ran.push(file.output);
    const ssh = await runWith(held("ssh", "ssh_key", { private_key: key }), ask('test -S "$SSH_AUTH_SOCK" && echo "$SSH_AUTH_SOCK"'), proxy, env, () => {});
    ran.push(ssh.output);
    // Two at once: the CA read or made once.
    const both = await Promise.all([1, 2].map(() => runWith(held("proxy", "token", { value: "t0ken" }, ["api.example.com"]), ask('echo "$HTTPS_PROXY" "$GIVEN"'), proxy, env, () => {})));
    ran.push(...both.map((r) => r.output));
  });
  proxy.close();
  assert.deepEqual(calls, []);
  const [file, ssh, ...proxied] = ran;
  // (What it printed of the file hidden, as a secret in the environment is.)
  assert.match(file!, /^[^\n]+\n(.*k\.txt)\n$/, "the file written for it, its path given");
  assert.ok(!file!.includes("kept"), file);
  const path = /\n(.*)\n$/.exec(file!)![1]!;
  await assert.rejects(stat(path), /ENOENT/, "and taken away after");
  assert.match(ssh!, /agent\.sock\n$/, "the agent's socket there while it ran");
  await assert.rejects(stat(ssh!.trim()), /ENOENT/, "and its directory taken away after");
  for (const p of proxied) assert.match(p, /^http:\/\/run:[^@]+@127\.0\.0\.1:\d+ stillfail-secret:r_proxy\n$/);
  assert.ok((await readFile(proxy.bundle, "utf8")).includes("-----BEGIN CERTIFICATE-----"), "the bundle a command trusts written");
  // Started again (another process), the CA is read, not made again.
  const ca = await readFile(join(dir, "vault", "ca.pem"), "utf8");
  const again = new Proxy(join(dir, "vault"), () => 0);
  assert.deepEqual(await syncCalls(async () => void (await again.start())), []);
  again.close();
  assert.equal(await readFile(join(dir, "vault", "ca.pem"), "utf8"), ca);
});

test("a drive file's thumbnail made again once the file is newer waits on no file", async () => {
  const dir = scratch("thumbs-main-thread");
  const thumbs = join(dir, "thumbs");
  mkdirSync(thumbs);
  const image = join(dir, "a.png");
  const old = join(thumbs, `${idOf(image)}.jpg`);
  writeFileSync(old, "old");
  utimesSync(old, 1, 1);
  const made: string[] = [];
  const codecs = {
    thumbnail: async (from: string, to: string) => (made.push(from), { path: join(to, `${idOf(from)}.jpg`), type: "image/jpeg" }),
    thumbhash: async () => null,
  };
  let gone: unknown;
  const calls = await syncCalls(async () => {
    await thumbnail(image, thumbs, codecs, 5_000);
    gone = await kept(thumbs, idOf(image));
    assert.equal(await kept(thumbs, idOf(join(dir, "none.png"))), null);
  });
  assert.deepEqual(calls, []);
  assert.deepEqual(made, [image]);
  assert.equal(gone, null, "the one of what it was taken away");
});

test("the overview's disk room waits on no file", async () => {
  const was = process.env.STILLFAIL_TEST_HOST;
  delete process.env.STILLFAIL_TEST_HOST;
  const store = Store.open(":memory:");
  try {
    const dataDir = scratch("overview-main-thread");
    const hub: any = { processes: () => [], config: () => ({ dataDir }) };
    const viewer = { sub: "s", email: "person@example.test", name: "P", role: "member", workspace: "mine", device: "d", home: false };
    let seen: any;
    const calls = await syncCalls(async () => void (seen = await overview({ store, hub, cloud: { state: null } as any, config: () => ({ connects: [] }) }, viewer, "en")));
    assert.deepEqual(calls, []);
    assert.ok(seen.disk.totalBytes > 0 && seen.disk.freeBytes >= 0, JSON.stringify(seen.disk));
  } finally {
    store.close();
    if (was !== undefined) process.env.STILLFAIL_TEST_HOST = was;
  }
});

/// A station process's events, handing over in `file`.
function events(file: string, clock: ReturnType<typeof testClock>["clock"], gone: Promise<void> = Promise.resolve()) {
  return new Events({
    readers: { read: async () => { throw new Error("nothing read"); } } as any,
    said: (_thread, entries) => entries.map((e) => ({ n: e.n, text: "hi" })),
    subscribe: () => () => {},
    host: async () => ({ cpu: 1 }),
    jobLog: () => null,
    logNow: async () => null,
    sessionExists: () => true,
    clock,
    handover: { file, previous: { pid: process.pid, gone } },
  });
}

test("what is told handed over to the next process and taken up there waits on no file", async () => {
  const time = testClock();
  const file = join(scratch("events-main-thread"), "run", "events.json");
  const before = events(file, time.clock);
  before.follow({ overview: async () => ({ running: 0 }) });
  await settle();
  const answer = await before.open({ sub: "a", email: "a@x", name: "a", role: "member", workspace: "w", device: "d" }, "zh", false, [], []);
  const body = (answer.body as AsyncIterable<Buffer>)[Symbol.asyncIterator]();
  await body.next();
  const gone = Promise.withResolvers<void>();
  let next: Events | null = null;
  const calls = await syncCalls(async () => {
    await before.handOver();
    assert.ok((await stat(file)).isFile(), "handed over");
    next = events(file, time.clock, gone.promise);
    gone.resolve();
    await settle();
    // Answered once taken up, from what was handed over.
    await next.open({ sub: "a", email: "a@x", name: "a", role: "member", workspace: "w", device: "d" }, "zh", false, [], []);
  });
  await body.return?.();
  assert.deepEqual(calls, []);
  await assert.rejects(stat(file), /ENOENT/, "taken up, and taken away");
});

test("the station's Chrome found, started and ended, and whose its tabs are, wait on no file", async () => {
  const dir = scratch("chrome-main-thread");
  // A port nothing answers on: what Chrome said of itself there is stale.
  const port = await new Promise<number>((resolve) => {
    const s = createServer().listen(0, "127.0.0.1", () => {
      const p = (s.address() as { port: number }).port;
      s.close(() => resolve(p));
    });
  });
  mkdirSync(join(dir, "profile"), { recursive: true });
  const host = chromeHost({ dir, binary: join(dir, "no-chrome"), headless: true });
  const running: Running = { pid: null, started: null, port, ws: `ws://127.0.0.1:${port}/devtools/browser/x`, binary: "x", headless: true, userAgent: "" };
  await new BrowserState(dir).change((s) => ({ ...s, running, port, lastUse: 7 }));
  writeFileSync(join(dir, "profile", "DevToolsActivePort"), `${port}\n/devtools/browser/x\n`);
  let found: unknown;
  let failed: unknown;
  const calls = await syncCalls(async () => {
    found = await host.find();
    await host.kill(running);
    // A program that is not there: it ends as it starts.
    failed = await host.launch().catch((e: Error) => e.message);
    const owners = new Owners(dir);
    await owners.ready();
    owners.set("A", "chat-1");
    owners.set("B", "chat-2");
    owners.drop("B");
    await owners.written();
  });
  assert.deepEqual(calls, []);
  assert.equal(found, null, "nothing answers where it said it is");
  assert.match(String(failed), /ended as it started/);
  const state = await readState(dir);
  assert.equal(state.running, undefined, "its record taken away as it was ended");
  assert.equal(state.lastUse, 7, "the rest kept");
  await assert.rejects(stat(join(dir, "profile", "DevToolsActivePort")), /ENOENT/);
  const owners = new Owners(dir);
  await owners.ready();
  assert.equal(owners.of("A"), "chat-1");
  assert.equal(owners.of("B"), undefined);
});
