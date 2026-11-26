// What the station's main thread waits on as a message said is told on the event streams (services.ts `Events`: its
// entries named as the pages show them, read/views.ts `entryViews`), as it starts the MoonBit program again
// (read/mb-reader.ts `mbReaderBinary`), removes the copies a post's files were staged in (sessions/conversations.ts
// `staged`), runs a command another station sent (vault/incoming.ts) and lets go of the search index of before
// (search/search.ts `start`): none of node:fs's synchronous calls (station/AGENTS.md, the main thread waits on nothing).
// Every message said looked at config.json and a names book on the disk; every program started, at its binary.
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { after, test } from "node:test";
import { Events } from "../src/api/events.ts";
import { NAMES_FILE, REMOTE_FILE } from "../src/connects/keys.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { writePrivateSoon } from "../src/ops/files.ts";
import { mbReaderBinary, readerBinary } from "../src/read/mb-reader.ts";
import { KnownNames } from "../src/read/slack-known.ts";
import { makeStore } from "../src/read/store.ts";
import { apiOf, entryViews, spokenIn } from "../src/read/views.ts";
import { Search } from "../src/search/search.ts";
import { staged } from "../src/sessions/conversations.ts";
import { STILLFAIL_SURFACE } from "../src/store/rows.ts";
import { Store, newMessage } from "../src/store/store.ts";
import { Incoming } from "../src/vault/incoming.ts";
import { settle, testClock } from "./hub-fakes.ts";
import { syncCalls } from "./main-thread-sync.ts";

const dirs: string[] = [];
after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});
const scratch = (name: string) => {
  const dir = mkdtempSync(join(tmpdir(), `${name}-`));
  dirs.push(dir);
  return dir;
};

/// Until `listen` tells what `f` holds: told by its changes as the system says the file changed (in its own time, which
/// no test's turns of the loop measure), no clock.
const until = <A>(listen: (f: (a: A) => void) => () => void, f: (a: A) => boolean) =>
  new Promise<void>((resolve) => {
    const stop = listen((a) => {
      if (!f(a)) return;
      stop();
      resolve();
    });
  });

test("a message said is told with its authors' names from memory: Slack, Feishu and still.fail chats, the names books, other stations' connects and the config changed", async () => {
  const data = scratch("events-said");
  const config0 = { connects: [{ id: "team", slack: { botName: "Helper", team: { id: "T1", name: "Team" } } }, { id: "fs", kind: "feishu", feishu: { tenant: { name: "Co" } } }] };
  writeFileSync(join(data, "config.json"), JSON.stringify(config0));
  writeFileSync(join(data, NAMES_FILE.slack), JSON.stringify({ "u:T1:U1": { person: { name: "Una", picture: "https://p/u.png" } } }));
  writeFileSync(join(data, NAMES_FILE.feishu), JSON.stringify({ "u:fs:ou_1": { person: { name: "Fei" } } }));
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  // As services.ts makes them: config.json watched, the names books held, the entries made over the store's connection.
  const config = new ConfigFile(data);
  config.watch();
  const known = new KnownNames(data, () => config.raw());
  const view = Object.assign(makeStore(store.db, data), { names: new Map([["p@x", "Pat"]]) });
  const events = new Events({
    readers: { read: async (op: string) => { if (op === "sharedOf") return JSON.stringify({ rows: [], scope: null }); throw new Error("nothing read"); } } as any,
    said: (thread, entries, lang) => spokenIn(lang, () => entryViews(apiOf(view, config.raw(), known), thread, entries)),
    subscribe: (listener) => store.subscribe(listener),
    host: async () => ({ cpu: 1 }),
    jobLog: () => null,
    logNow: async () => null,
    sessionExists: () => true,
    clock: testClock().clock,
  });
  events.follow({ overview: async () => ({ running: 0 }) });
  const session = (key: string, connect: string) =>
    store.insertSession({ key, connect, runtime: "claude", profile: "cc", workspace: "/w", token: key, createdAt: 1, lastActiveAt: 1 } as Parameters<Store["insertSession"]>[0]);
  session("s1", "team");
  session("s2", "fs");
  session("s3", "far");
  session("a1", "ember");
  const slack = store.openThread("slack", "C1", "1.0", null, null).id;
  store.joinThread(slack, "s1", "team");
  const feishu = store.openThread("feishu", "oc_1", "2.0", null, null).id;
  store.joinThread(feishu, "s2", "fs");
  const far = store.openThread("slack", "C9", "3.0", null, null).id;
  store.joinThread(far, "s3", "far");
  const own = store.openThread(STILLFAIL_SURFACE, "CHAT", "c", null, null).id;
  store.joinThread(own, "a1", "ember");

  const answer = await events.open({ sub: "a", email: "a@x", name: "a", role: "member", workspace: "w", device: "d" }, "zh", false, [], []);
  const body = (answer.body as AsyncIterable<Buffer>)[Symbol.asyncIterator]();
  const told: { thread: number; names: (string | null)[]; pictures: (string | undefined)[] }[] = [];
  const pump = (async () => {
    for (;;) {
      const next = await body.next();
      if (next.done) return;
      const m = /event: thread\ndata: (.*)\n\n$/.exec(next.value.toString());
      if (m === null) continue;
      const said = JSON.parse(m[1]!) as { id: number; entries: { authorName: string | null; authorPicture?: string }[] };
      told.push({ thread: said.id, names: said.entries.map((e) => e.authorName), pictures: said.entries.map((e) => e.authorPicture) });
    }
  })();
  let ts = 0;
  const say = (thread: number, kind: "person" | "agent", author: string) => {
    store.insertMessage({ ...newMessage(thread, String(++ts), kind, author, `said ${ts}`), at: 1000 + ts } as ReturnType<typeof newMessage>);
  };
  const lastOf = (thread: number) => told.findLast((t) => t.thread === thread);
  await settle();

  const first = await syncCalls(async () => {
    say(slack, "person", "U1");
    say(slack, "agent", "s1");
    say(feishu, "person", "ou_1");
    say(own, "person", "p@x");
    say(far, "person", "U9");
    await settle();
  });
  assert.deepEqual(first, []);
  assert.deepEqual(told.map((t) => [t.thread, t.names]), [[slack, ["Una"]], [slack, ["Helper"]], [feishu, ["Fei"]], [own, ["Pat"]], [far, [null]]]);
  assert.equal(told[0]!.pictures[0], "https://p/u.png");

  // The books and other stations' connects changed as the station writes them (a temporary renamed into place, which
  // macOS's FSEvents may name after either): taken in off the main thread as the system says so.
  const changed = await syncCalls(async () => {
    const slackRead = until<string>((f) => known.listen(f), () => known.person("team", "U1")?.name === "Una Two");
    await writePrivateSoon(join(data, NAMES_FILE.slack), JSON.stringify({ "u:T1:U1": { person: { name: "Una Two" } }, "u:T2:U9": { person: { name: "Nine" } } }));
    await slackRead;
    const remoteRead = until<string>((f) => known.listen(f), () => known.teams().has("far"));
    await writePrivateSoon(join(data, REMOTE_FILE), JSON.stringify({ far: { described: { kind: "slack", team: "T2", identity: { team: "Far" } } } }));
    await remoteRead;
    say(slack, "person", "U1");
    say(far, "person", "U9");
    await settle();
  });
  assert.deepEqual(changed, []);
  assert.deepEqual(lastOf(slack)!.names, ["Una Two"]);
  assert.deepEqual(lastOf(far)!.names, ["Nine"]);

  // config.json changed (read again by ConfigFile itself as its watch says so: ops/config.ts, its own): the next
  // message is named by it with nothing more read.
  const configRead = until<unknown>((f) => config.listen(f), (raw: any) => raw?.connects?.[0]?.slack?.botName === "Helper Two");
  await writeFile(join(data, "config.json"), JSON.stringify({ ...config0, connects: [{ ...config0.connects[0], slack: { botName: "Helper Two", team: { id: "T1", name: "Team" } } }, config0.connects[1]] }));
  await configRead;
  const afterConfig = await syncCalls(async () => {
    say(slack, "agent", "s1");
    await settle();
  });
  assert.deepEqual(afterConfig, []);
  assert.deepEqual(lastOf(slack)!.names, ["Helper Two"]);

  // A book gone: none of its names known.
  const gone = until<string>((f) => known.listen(f), () => Object.keys(known.book("feishu")).length === 0);
  rmSync(join(data, NAMES_FILE.feishu));
  await gone;
  say(feishu, "person", "ou_1");
  await settle();
  assert.deepEqual(lastOf(feishu)!.names, [null]);

  await body.return?.();
  await pump;
  known.close();
  config.unwatch();
  store.close();
});

test("the MoonBit program, once found, is not looked for again; another STILLFAIL_MB_READER is", async () => {
  const was = process.env.STILLFAIL_MB_READER;
  const dir = scratch("mb-binary");
  const [one, two] = [join(dir, "one"), join(dir, "two")];
  writeFileSync(one, "");
  writeFileSync(two, "");
  chmodSync(one, 0o755);
  chmodSync(two, 0o755);
  try {
    process.env.STILLFAIL_MB_READER = one;
    assert.equal(mbReaderBinary(), one);
    const calls = await syncCalls(async () => {
      for (let i = 0; i < 5; i++) assert.equal(mbReaderBinary(), one);
      assert.equal(readerBinary(), one);
    });
    assert.deepEqual(calls, []);
    process.env.STILLFAIL_MB_READER = two;
    assert.equal(mbReaderBinary(), two, "another looked for");
  } finally {
    if (was === undefined) delete process.env.STILLFAIL_MB_READER;
    else process.env.STILLFAIL_MB_READER = was;
  }
});

test("a post's staged copies removed, a command another station sent given its directory, and the search index of before let go, wait on no file", async () => {
  const dir = scratch("staged-incoming-search");
  // A post's file in a folder macOS protects, copied into the session's uploads (conversations.ts `staged`).
  const workspace = join(dir, "workspace");
  const hub: any = {
    store: { getSession: (key: string) => (key === "s" ? { key, workspace } : null) },
    places: {
      file: async (path: string, into: string) => {
        const copy = join(into, "staged-1", basename(path));
        await mkdir(dirname(copy), { recursive: true });
        await writeFile(copy, "x");
        return copy;
      },
    },
  };
  const ran: string[] = [];
  // A command another station sent (vault/incoming.ts), its directory made before it is refused for want of its secret.
  const work = join(dir, "work");
  const incoming = new Incoming({ proxy: {} as any, now: () => 0, workOf: () => work, ask: async () => ({}) });
  for (const f of ["search.db", "search.db-wal", "search.db-shm"]) writeFileSync(join(dir, f), "an index of before");
  const search = new Search({ data: dir, reference: () => ({ post: () => {}, on: () => {}, terminate: async () => {} }) as any });
  const calls = await syncCalls(async () => {
    const { args, done } = await staged(hub, "s", { files: ["/protected/a.txt"] }, false);
    ran.push(...(args.files as string[]));
    await done();
    await assert.rejects(incoming.heard("peer", "w", { method: "vault.run", id: `x_${"0".repeat(26)}`, session: "s", command: "true", under: "a/b" }), /mode, grant and secret are required/);
    await search.start();
  });
  assert.deepEqual(calls, []);
  assert.deepEqual(ran, [join(workspace, "uploads", "staged-1", "a.txt")]);
  assert.equal(existsSync(join(workspace, "uploads", "staged-1")), false, "the copies removed");
  assert.equal(existsSync(join(work, "a", "b")), true, "the command's directory made");
  for (const f of ["search.db", "search.db-wal", "search.db-shm"]) assert.equal(existsSync(join(dir, f)), false, `${f} let go`);
  await search.stop();
});
