// What of the agents' home the memory's sync watches (src/share/memory.ts `memoryFollowed`, src/ops/follow.ts): its
// skills and joined workspaces' skills, a directory a watch, never a repository, a cache or what a program made beside a
// skill's files; at most so many; and a watch the system will not make (out of inotify watches) tried again after a
// while, not at every frame of the cloud's. #6206 watched the whole home with Node's recursive watch, which on Linux
// lists all of it on the main thread with a watch a directory, and did it again at each frame once past the limit.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Clock, Duration, Effect, Exit, Scope } from "effect";
import { TestClock } from "effect/testing";
import { Cloud } from "../src/cloud/state.ts";
import { FollowedTree, type Watch } from "../src/ops/follow.ts";
import { MemorySync, RETRY_MS, memoryFollowed } from "../src/share/memory.ts";

const ME = "a".repeat(64);

/// A home as agents leave it: the memory and skills beside a clone, a skill's node_modules and .git, a joined
/// workspace's skills and something else of its.
function home(): string {
  const root = mkdtempSync(join(tmpdir(), "memory-follow-"));
  const dir = (rel: string) => mkdirSync(join(root, rel), { recursive: true });
  const file = (rel: string, text = "x\n") => writeFileSync(join(root, rel), text);
  file("MEMORY.md");
  file("presets.json", "{}");
  for (let i = 0; i < 300; i++) dir(`repos/big/src/m${i}`);
  dir("skills/a/scripts");
  file("skills/a/SKILL.md");
  for (let i = 0; i < 300; i++) dir(`skills/a/node_modules/p${i}/lib`);
  dir("skills/a/.git/objects/00");
  dir("skills/a/__pycache__");
  dir("skills/stillfail-chats");
  dir("workspaces/W1/skills/b/lib");
  dir("workspaces/W1/junk/deep");
  file("workspaces/W1/MEMORY.md");
  dir("workspaces/not a workspace/skills");
  return root;
}

/// A watch that only counts: each directory asked for, none of its events.
function counted(failFrom = Infinity) {
  const asked: string[] = [];
  const watch: Watch = (dir) => {
    asked.push(dir);
    if (asked.length >= failFrom) throw Object.assign(new Error("ENOSPC: System limit for number of file watchers reached"), { code: "ENOSPC" });
    return { close() {}, on() {} };
  };
  return { asked, watch };
}

test("only the memory's directories are watched: not a clone, a skill's node_modules or .git, a built-in skill", async () => {
  const root = home();
  const { watch } = counted();
  const tree = new FollowedTree({ root, into: memoryFollowed, most: 1000, changed: () => {}, watch });
  const r = await tree.scan();
  assert.deepEqual(r, {});
  assert.deepEqual(tree.watched().sort(), ["", "skills", "skills/a", "skills/a/scripts", "workspaces", "workspaces/W1", "workspaces/W1/skills", "workspaces/W1/skills/b", "workspaces/W1/skills/b/lib"]);
  tree.close();
});

test("no more directories are watched than `most`, and the scan says so", async () => {
  const root = mkdtempSync(join(tmpdir(), "memory-follow-"));
  for (let i = 0; i < 50; i++) mkdirSync(join(root, `skills/s${i}/sub`), { recursive: true });
  const { asked, watch } = counted();
  const tree = new FollowedTree({ root, into: memoryFollowed, most: 20, changed: () => {}, watch });
  const r = await tree.scan();
  assert.equal(r.over, true);
  assert.equal(tree.watched().length, 20);
  assert.equal(asked.length, 20);
  tree.close();
});

test("a directory made, then gone: watched, then let go; a change is told by where it is", async () => {
  const root = home();
  const told: string[] = [];
  const events = new Map<string, (name: string | null) => void>();
  let closed = 0;
  const watch: Watch = (dir, changed) => {
    events.set(dir, changed);
    return { close: () => void closed++, on() {} };
  };
  const tree = new FollowedTree({ root, into: memoryFollowed, most: 1000, changed: (rel) => told.push(rel), watch });
  await tree.scan();
  mkdirSync(join(root, "skills/c/refs"), { recursive: true });
  await tree.scan();
  assert.ok(tree.watched().includes("skills/c/refs"));
  events.get(join(root, "skills/c/refs"))!("x.md");
  events.get(root)!("MEMORY.md");
  assert.deepEqual(told, ["skills/c/refs/x.md", "MEMORY.md"]);
  const { rmSync } = await import("node:fs");
  rmSync(join(root, "skills/c"), { recursive: true });
  await tree.scan();
  assert.equal(tree.watched().includes("skills/c"), false);
  assert.equal(closed, 2);
  tree.close();
});

/// A TestClock that says when a wait on it begins (`asleep(ms)`: the next wait begun is there, and is of `ms`).
function testClock() {
  const scope = Effect.runSync(Scope.make());
  const clockTest = Effect.runSync(Scope.provide(TestClock.make(), scope));
  const begun: number[] = [];
  let heard: (() => void) | null = null;
  const clock: Clock.Clock = {
    ...clockTest,
    sleep: (d) =>
      Effect.suspend(() => {
        begun.push(Duration.toMillis(d));
        heard?.();
        return clockTest.sleep(d);
      }),
  };
  let seen = 0;
  const asleep = async (ms: number) => {
    while (seen === begun.length) await new Promise<void>((r) => (heard = r));
    heard = null;
    assert.equal(begun[seen++], ms, "the wait begun");
    for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
  };
  const adjust = (ms: number) => Effect.runPromise(clockTest.adjust(ms));
  const close = () => Effect.runPromise(Scope.close(scope, Exit.void));
  return { clock, asleep, adjust, close };
}

test("out of inotify watches: tried again after a while, twice as long each time, not at each frame of the cloud's", async () => {
  const root = home();
  const time = testClock();
  let heard: (() => void) | null = null;
  const cloud = Object.defineProperties(Object.create(Cloud.prototype), Object.getOwnPropertyDescriptors({
    peersCurrent: true,
    lock: null,
    get state() {
      return { station: ME, name: "ccvm", workspace: "w", workspace_name: "w", peers: [{ id: ME, name: "ccvm" }], revocations: [], joined: [] } as any;
    },
    listen(f: () => void) {
      heard = f;
      return () => {};
    },
  })) as Cloud;
  // the system makes two watches, then no more
  const { asked, watch } = counted(3);
  const sync = new MemorySync({ data: mkdtempSync(join(tmpdir(), "memory-data-")), cloud, ask: async () => ({}), agentHome: () => root, clock: time.clock, watch });
  sync.start();
  // A scan's first watch (the home's) is asked as it begins.
  assert.equal(asked.length, 1);
  await time.asleep(RETRY_MS);
  const after = asked.length;
  assert.equal(after, 3);
  // The cloud's frames start no scan of their own.
  for (let i = 0; i < 100; i++) heard!();
  assert.equal(asked.length, after);
  await time.adjust(RETRY_MS);
  await time.asleep(RETRY_MS * 2);
  assert.ok(asked.length > after, "tried again once the wait passed");
  await sync.stop();
  await time.close();
});
