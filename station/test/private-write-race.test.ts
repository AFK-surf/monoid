// `writePrivateSoon` written many times at once to one file (two sessions opening one profile write its sign-in at
// once): each through a name of its own beside it, so none's rename finds the other's gone (ENOENT), the file is one of
// them whole, and nothing is left beside it. One that fails leaves nothing beside either.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { writePrivate, writePrivateSoon } from "../src/ops/files.ts";

test("writes of one file at once each land whole, none failing, nothing left beside", async () => {
  const dir = mkdtempSync(join(tmpdir(), "private-race-"));
  try {
    const file = join(dir, "token");
    const sent = Array.from({ length: 20 }, (_, i) => JSON.stringify({ n: i, pad: "x".repeat(4096 + i) }));
    const outcomes = await Promise.allSettled(sent.map((d) => writePrivateSoon(file, d)));
    assert.deepEqual(outcomes.filter((o) => o.status === "rejected"), []);
    assert.ok(sent.includes(readFileSync(file, "utf8")), "the file is one of the writes, whole");
    assert.deepEqual(readdirSync(dir), ["token"]);
    if (process.platform !== "win32") assert.equal(statSync(file).mode & 0o777, 0o600);
    writePrivate(file, "sync");
    writePrivate(file, "sync again");
    assert.equal(readFileSync(file, "utf8"), "sync again");
    assert.deepEqual(readdirSync(dir), ["token"]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a write whose rename fails leaves nothing beside", { skip: process.platform === "win32" && "a directory is renamed over on Windows differently" }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "private-fail-"));
  try {
    const file = join(dir, "taken");
    mkdirSync(join(file, "inside"), { recursive: true });
    await assert.rejects(writePrivateSoon(file, "data"));
    assert.deepEqual(readdirSync(dir), ["taken"]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
