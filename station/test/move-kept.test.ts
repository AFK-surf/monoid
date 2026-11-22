import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { KeptMap, KeptSet, replaceFile } from "../src/move/kept.ts";

async function directory(t: TestContext): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-move-kept-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return dir;
}

test("KeptSet persists the final state after concurrent adds and deletes", async (t) => {
  const dir = await directory(t);
  const path = join(dir, "set.json");
  const before = Array.from({ length: 10 }, (_, i) => `old-${i}`);
  const after = Array.from({ length: 10 }, (_, i) => `new-${i}`);
  await writeFile(path, JSON.stringify(before));
  const kept = new KeptSet(path);

  const adds = after.map((id) => kept.add(id));
  await Promise.resolve();
  const deletes = before.map((id) => kept.delete(id));
  await Promise.all([...adds, ...deletes]);

  assert.deepEqual(kept.values(), after);
  assert.deepEqual(JSON.parse(await readFile(path, "utf8")), kept.values());
  assert.deepEqual(await readdir(dir), ["set.json"]);
});

test("KeptMap persists the final state after concurrent sets and deletes", async (t) => {
  const dir = await directory(t);
  const path = join(dir, "map.json");
  const before = Array.from({ length: 10 }, (_, i) => [`old-${i}`, i] as const);
  const after = Array.from({ length: 10 }, (_, i) => [`new-${i}`, i] as const);
  await writeFile(path, JSON.stringify(Object.fromEntries(before)));
  const kept = new KeptMap<number>(path);

  const sets = after.map(([key, value]) => kept.set(key, value));
  await Promise.resolve();
  const deletes = before.map(([key]) => kept.delete(key));
  await Promise.all([...sets, ...deletes]);

  assert.deepEqual(kept.entries(), after);
  assert.deepEqual(JSON.parse(await readFile(path, "utf8")), Object.fromEntries(kept.entries()));
  assert.deepEqual(await readdir(dir), ["map.json"]);
});

test("replaceFile retries transient rename errors and replaces the file", async (t) => {
  const dir = await directory(t);
  const path = join(dir, "kept.json");
  await writeFile(path, "before");
  const waits: number[] = [];
  const failures = ["EPERM", "EBUSY", "EACCES"];
  await replaceFile(path, "after", {
    rename: async (from, to) => {
      const code = failures.shift();
      if (code !== undefined) throw Object.assign(new Error(code), { code });
      await rename(from, to);
    },
    wait: async (ms) => { waits.push(ms); },
  });

  assert.deepEqual(waits, [20, 40, 80]);
  assert.equal(await readFile(path, "utf8"), "after");
  assert.deepEqual(await readdir(dir), ["kept.json"]);
});

for (const { code, backoff } of [
  { code: "EPERM", backoff: [20, 40, 80, 160] },
  { code: "ENOSPC", backoff: [] },
]) {
  test(`replaceFile preserves the file and cleans up after ${code}`, async (t) => {
    const dir = await directory(t);
    const path = join(dir, "kept.json");
    await writeFile(path, "before");
    const failure = Object.assign(new Error(code), { code });
    const waits: number[] = [];
    let attempts = 0;
    await assert.rejects(replaceFile(path, "after", {
      rename: async () => {
        attempts++;
        throw failure;
      },
      wait: async (ms) => { waits.push(ms); },
    }), (error) => error === failure);

    assert.equal(attempts, backoff.length + 1);
    assert.deepEqual(waits, backoff);
    assert.equal(await readFile(path, "utf8"), "before");
    assert.deepEqual(await readdir(dir), ["kept.json"]);
  });
}
