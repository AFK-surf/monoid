// Renames that wait out a Windows lock that clears by itself (ops/files.ts `renameRetrying`), and the private writes
// that go through one.
import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { RENAME_BACKOFF, moveFile, renameRetrying, writePrivateSoon } from "../src/ops/files.ts";
import fsModule from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { healthOf, healthPath, writeHealth, type Health } from "../src/ops/health.ts";
import { mkdir } from "node:fs/promises";
import { patchUpkeepState, readUpkeepState, UPKEEP_STATE_FILE } from "../src/ops/upkeep-state.ts";

async function directory(t: TestContext): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-rename-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return dir;
}

const failing = (code: string) => Object.assign(new Error(code), { code });

test("renameRetrying waits out EPERM, EBUSY and EACCES, then renames", async (t) => {
  const dir = await directory(t);
  await writeFile(join(dir, "from"), "moved");
  const left = ["EPERM", "EBUSY", "EACCES"];
  const waits: number[] = [];
  await renameRetrying(join(dir, "from"), join(dir, "to"), {
    rename: async (from, to) => {
      const code = left.shift();
      if (code) throw failing(code);
      await rename(from, to);
    },
    wait: async (ms) => { waits.push(ms); },
  });
  assert.deepEqual(waits, [20, 40, 80]);
  assert.deepEqual(await readdir(dir), ["to"]);
  assert.equal(await readFile(join(dir, "to"), "utf8"), "moved");
});

test("renameRetrying throws any other error at once", async () => {
  const failure = failing("ENOENT");
  const waits: number[] = [];
  let attempts = 0;
  await assert.rejects(renameRetrying("a", "b", {
    rename: async () => { attempts++; throw failure; },
    wait: async (ms) => { waits.push(ms); },
  }), (error) => error === failure);
  assert.equal(attempts, 1);
  assert.deepEqual(waits, []);
});

test("renameRetrying throws the last error once the backoff is spent", async () => {
  const failures: Error[] = [];
  const waits: number[] = [];
  await assert.rejects(renameRetrying("a", "b", {
    rename: async () => {
      const failure = failing("EPERM");
      failures.push(failure);
      throw failure;
    },
    wait: async (ms) => { waits.push(ms); },
  }), (error) => error === failures.at(-1));
  assert.equal(failures.length, RENAME_BACKOFF.length + 1);
  assert.deepEqual(waits, [...RENAME_BACKOFF]);
});

test("renameRetrying follows the backoff it is given", async () => {
  const waits: number[] = [];
  let attempts = 0;
  await assert.rejects(renameRetrying("a", "b", {
    rename: async () => { attempts++; throw failing("EBUSY"); },
    wait: async (ms) => { waits.push(ms); },
    backoff: [5, 6],
  }));
  assert.equal(attempts, 3);
  assert.deepEqual(waits, [5, 6]);
});

test("writePrivateSoon writes through a passing EPERM, nothing left beside", async (t) => {
  const dir = await directory(t);
  const path = join(dir, "private.json");
  await writeFile(path, "before");
  let left = 2;
  const waits: number[] = [];
  await writePrivateSoon(path, "after", {
    rename: async (from, to) => {
      if (left-- > 0) throw failing("EPERM");
      await rename(from, to);
    },
    wait: async (ms) => { waits.push(ms); },
  });
  assert.deepEqual(waits, [20, 40]);
  assert.equal(await readFile(path, "utf8"), "after");
  assert.deepEqual(await readdir(dir), ["private.json"]);
});

test("writePrivateSoon keeps the file and removes what it wrote beside when EPERM stays", async (t) => {
  const dir = await directory(t);
  const path = join(dir, "private.json");
  await writeFile(path, "before");
  const waits: number[] = [];
  await assert.rejects(writePrivateSoon(path, "after", {
    rename: async () => { throw failing("EPERM"); },
    wait: async (ms) => { waits.push(ms); },
  }), { code: "EPERM" });
  assert.deepEqual(waits, [...RENAME_BACKOFF]);
  assert.equal(await readFile(path, "utf8"), "before");
  assert.deepEqual(await readdir(dir), ["private.json"]);
});

const health: Health = { pid: 4242, updatedAt: 1, heldMaxMs: 0, front: "direct", presenceOnline: true };

test("writeHealth waits out a lock on health.json, leaving no file of its own", async (t) => {
  const dir = await directory(t);
  await mkdir(join(dir, "run"));
  const left = ["EPERM", "EBUSY"];
  const waits: number[] = [];
  await writeHealth(dir, health, {
    rename: async (from, to) => {
      const code = left.shift();
      if (code) throw failing(code);
      await rename(from, to);
    },
    wait: async (ms) => { waits.push(ms); },
  });
  assert.deepEqual(waits, [20, 40]);
  assert.deepEqual(await readdir(join(dir, "run")), ["health.json"]);
  assert.deepEqual(healthOf(JSON.parse(await readFile(healthPath(dir), "utf8"))), health);
});

test("writeHealth throws a lock that outlasts the wait and removes its own file", async (t) => {
  const dir = await directory(t);
  await mkdir(join(dir, "run"));
  await assert.rejects(writeHealth(dir, health, {
    rename: async () => { throw failing("EPERM"); },
    wait: async () => {},
  }), (error) => (error as NodeJS.ErrnoException).code === "EPERM");
  assert.deepEqual(await readdir(join(dir, "run")), []);
});

test("patchUpkeepState waits out a lock on upkeep-state.json, and leaves no file of its own when one outlasts it", async (t) => {
  const dir = await directory(t);
  const left = ["EACCES", "EPERM"];
  const waits: number[] = [];
  assert.equal(await patchUpkeepState(dir, { lastOrphanRoomsAt: 5 }, {
    rename: async (from, to) => {
      const code = left.shift();
      if (code) throw failing(code);
      await rename(from, to);
    },
    wait: async (ms) => { waits.push(ms); },
  }), true);
  assert.deepEqual(waits, [20, 40]);
  assert.deepEqual(await readdir(dir), [UPKEEP_STATE_FILE]);
  assert.equal((await readUpkeepState(dir)).lastOrphanRoomsAt, 5);
  assert.equal(await patchUpkeepState(dir, { lastOrphanRoomsAt: 6 }, {
    rename: async () => { throw failing("EPERM"); },
    wait: async () => {},
  }), false);
  assert.deepEqual(await readdir(dir), [UPKEEP_STATE_FILE]);
  assert.equal((await readUpkeepState(dir)).lastOrphanRoomsAt, 5);
});

test("moveFile copies across disks (EXDEV), moved all the same where the disk will not take the file's times", async (t) => {
  const dir = await directory(t);
  await mkdir(join(dir, "a"));
  await mkdir(join(dir, "b"));
  await writeFile(join(dir, "a", "shot.png"), "png");
  const real = { rename: fsModule.promises.rename, utimes: fsModule.promises.utimes };
  fsModule.promises.rename = (async (from: any, to: any) => {
    if (String(from).startsWith(join(dir, "a"))) throw failing("EXDEV");
    return real.rename(from, to);
  }) as typeof real.rename;
  fsModule.promises.utimes = (async () => { throw failing("EPERM"); }) as typeof real.utimes;
  syncBuiltinESMExports();
  try {
    await moveFile(join(dir, "a", "shot.png"), join(dir, "b", "shot.png"));
  } finally {
    Object.assign(fsModule.promises, real);
    syncBuiltinESMExports();
  }
  assert.equal(await readFile(join(dir, "b", "shot.png"), "utf8"), "png");
  assert.deepEqual(await readdir(join(dir, "a")), []);
  assert.deepEqual(await readdir(join(dir, "b")), ["shot.png"]);
});
