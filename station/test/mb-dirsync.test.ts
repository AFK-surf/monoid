// The sending side of station_task's directory sync, in the MoonBit program (station/mb src/reader/dirsync_source.mbt),
// compared with the TypeScript it replaced (test/dirsync-reference.ts) on the same directories: what each lists of
// them, and what each sends a target to bring a mirror up to date, request by request, the bytes after them unpacked.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { appendFileSync, chmodSync, mkdirSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { zstdDecompressSync } from "node:zlib";
import { describe, test } from "node:test";
import { Bulk } from "../src/jobs/dirsync.ts";
import type { Json } from "../src/store/store.ts";
import { git, pair, tempdir, until } from "./dirsync-pair.ts";
import { listLocal, syncDir } from "./dirsync-reference.ts";

type Pair = Awaited<ReturnType<typeof pair>>;

/// A listing with what was left out in one order (the TypeScript's came as its pool finished them).
const ordered = (l: Json) => ({ ...l, skipped: [...l.skipped].sort((a: Json, b: Json) => (a.path < b.path ? -1 : a.path > b.path ? 1 : a.why < b.why ? -1 : 1)) });

async function outcome(f: () => Promise<Json>): Promise<Json> {
  try {
    return { listed: ordered(await f()) };
  } catch (e) {
    return { refused: (e as Error).message };
  }
}

/// What the program and the TypeScript list of `dir`, the same (or both refusing it); the program's.
async function listedAlike(p: Pair, dir: string, message?: RegExp): Promise<Json> {
  const [mb, ts] = [await outcome(() => p.a.remote.listLocal(dir)), await outcome(() => listLocal(dir))];
  if ("refused" in ts) {
    assert.ok("refused" in mb, `the program listed what the TypeScript refused (${ts.refused}): ${JSON.stringify(mb)}`);
    if (message) {
      assert.match(ts.refused, message);
      assert.match(mb.refused, message);
    }
    return mb;
  }
  assert.deepEqual(mb, ts);
  return mb.listed;
}

/// The sync requests a run sent its target, as compared: the sync's id and the packing aside, what each piece's bytes
/// are (unpacked, after the request or base64 in it).
function requests(p: Pair): Json[] {
  return p.state.sent
    .filter(({ request }) => /^sync\.(begin|manifest|base|put|commit)$/.test(request.method))
    .map(({ request, bytes }) => {
      const { id: _, data, ...rest } = request;
      const packed = bytes ?? (typeof data === "string" ? Buffer.from(data, "base64") : null);
      return packed === null ? rest : { ...rest, raw: zstdDecompressSync(packed).toString("hex") };
    });
}

/// The same sync's result, its time and how small the packing came aside (zlib's zstd and the shell's differ).
const synced = (s: Json) => {
  if (s === null) return null;
  const { ms: _, sent: { packed: __, ...sent }, ...rest } = s;
  return { ...rest, sent };
};

/// `dir` synced by the program (p, as a start does) and by the TypeScript (q, to its own target) for task `key`: the
/// same requests sent, the same result; the program's.
async function syncedAlike(p: Pair, q: Pair, key: string, dir: string): Promise<Json> {
  p.state.record = q.state.record = true;
  p.state.sent = [];
  q.state.sent = [];
  const ran = await p.run(key, dir, "true");
  await q.use("station_task", { key, action: "prepare", command: "true", dir });
  q.state.sent = [];
  const ts = await syncDir((method, more) => q.a.remote.ask(q.B, { workspace: "ws", session: "s1", key, method, ...more }), dir, () => 0, new Bulk());
  assert.deepEqual(requests(p), requests(q));
  assert.deepEqual(synced(ran.sync), synced(ts));
  return ran.sync;
}

/// A repository with what Git tells apart: clean, changed, untracked and ignored files, a link inside and one leading
/// out, an executable, a file checked out with CRLF, a submodule, a nested repository, big and empty files, names that
/// sort otherwise by their bytes than by JavaScript's.
function repository(at: string): string {
  const repo = join(at, "repo");
  mkdirSync(join(repo, "src", "deep"), { recursive: true });
  writeFileSync(join(repo, ".gitignore"), "node_modules/\ndist/\n*.log\n");
  writeFileSync(join(repo, ".gitattributes"), "*.bat text eol=crlf\n");
  writeFileSync(join(repo, "src", "a.txt"), "alpha\n");
  writeFileSync(join(repo, "src", "deep", "b.txt"), "beta\n");
  writeFileSync(join(repo, "w.bat"), "@echo off\r\necho hi\r\n");
  writeFileSync(join(repo, "run.sh"), "#!/bin/sh\necho run\n");
  chmodSync(join(repo, "run.sh"), 0o755);
  writeFileSync(join(repo, "big.bin"), randomBytes(1536 * 1024 + 3));
  writeFileSync(join(repo, "empty"), "");
  for (const name of ["B", "a", "é", "😀", "～"]) writeFileSync(join(repo, name), `${name}\n`);
  symlinkSync("src/a.txt", join(repo, "inside"));
  symlinkSync("/etc/hosts", join(repo, "outside"));
  git(repo, "init", "-q");
  git(repo, "add", "-A");
  // a submodule as its index has it (a gitlink), its directory there
  mkdirSync(join(repo, "sub"));
  git(repo, "update-index", "--add", "--cacheinfo", `160000,${"1".repeat(40)},sub`);
  git(repo, "commit", "-q", "-m", "first");
  writeFileSync(join(repo, "src", "a.txt"), "alpha changed\n");
  writeFileSync(join(repo, "notes.txt"), "untracked\n");
  writeFileSync(join(repo, "run.log"), "ignored\n");
  mkdirSync(join(repo, "node_modules", "dep"), { recursive: true });
  writeFileSync(join(repo, "node_modules", "dep", "index.js"), "ignored\n");
  mkdirSync(join(repo, "nested"));
  git(join(repo, "nested"), "init", "-q");
  writeFileSync(join(repo, "nested", "x"), "x\n");
  return repo;
}

describe("the program's directory sync, as the TypeScript's", { concurrency: true }, () => {
  test("a repository: what Git names, each id the index's or its bytes', what is left out and why", async () => {
    const p = await pair();
    const repo = repository(tempdir());
    const listed = await listedAlike(p, repo);
    assert.equal(listed.git, true);
    assert.ok(listed.files.some((f: Json) => f.path === "w.bat" && f.indexed === true), "a clean file by its index's id");
    assert.deepEqual(listed.skipped.map((s: Json) => [s.path, s.why]), [["nested", "nested repository"], ["outside", "symbolic link leading out of the directory"], ["sub", "submodule"]]);
    // a file of the index gone, one made a directory, one in a conflict
    rmSync(join(repo, "empty"));
    rmSync(join(repo, "B"));
    mkdirSync(join(repo, "B"));
    writeFileSync(join(repo, "B", "in"), "in\n");
    await listedAlike(p, repo);
    // its folder, where Git says where it is; and one it ignores, walked
    const src = await listedAlike(p, join(repo, "src"));
    assert.equal(src.prefix, "src/");
    mkdirSync(join(repo, "dist", "x"), { recursive: true });
    writeFileSync(join(repo, "dist", "x", "out.js"), "built\n");
    assert.equal((await listedAlike(p, join(repo, "dist"))).git, false);
  });

  test("a conflict's file is hashed as it is on disk", async () => {
    const p = await pair();
    const repo = join(tempdir(), "conflict");
    mkdirSync(repo);
    git(repo, "init", "-q");
    writeFileSync(join(repo, "f"), "base\n");
    git(repo, "add", "-A");
    git(repo, "commit", "-q", "-m", "base");
    git(repo, "checkout", "-q", "-b", "other");
    writeFileSync(join(repo, "f"), "other\n");
    git(repo, "commit", "-q", "-am", "other");
    git(repo, "checkout", "-q", "main");
    writeFileSync(join(repo, "f"), "main\n");
    git(repo, "commit", "-q", "-am", "main");
    try {
      git(repo, "merge", "-q", "other");
    } catch {}
    const listed = await listedAlike(p, repo);
    assert.equal(listed.files.find((f: Json) => f.path === "f").indexed, undefined);
  });

  test("a directory outside Git: walked without dependencies, build output and .DS_Store, no link followed", async () => {
    const p = await pair();
    const dir = join(tempdir(), "plain");
    mkdirSync(join(dir, "src", "node_modules", "x"), { recursive: true });
    mkdirSync(join(dir, "a", "target"), { recursive: true });
    mkdirSync(join(dir, "real"));
    writeFileSync(join(dir, "src", "main.c"), "int main;\n");
    writeFileSync(join(dir, "src", "node_modules", "x", "i.js"), "no\n");
    writeFileSync(join(dir, "a", "target", "app"), "no\n");
    writeFileSync(join(dir, "a", ".DS_Store"), "no\n");
    writeFileSync(join(dir, "real", "r"), "r\n");
    writeFileSync(join(dir, "empty"), "");
    symlinkSync("real", join(dir, "to-dir"));
    symlinkSync("../../etc", join(dir, "a", "up"));
    execFileSync("mkfifo", [join(dir, "pipe")]);
    const listed = await listedAlike(p, dir);
    assert.deepEqual(listed.files.map((f: Json) => f.path), ["empty", "real/r", "src/main.c", "to-dir"]);
    assert.deepEqual(listed.skipped.map((s: Json) => s.why), ["symbolic link leading out of the directory", "not a regular file"]);
  });

  test("what cannot be listed whole is refused, by both", async () => {
    const p = await pair();
    const base = tempdir();
    await listedAlike(p, join(base, "none"), /ENOENT/);
    writeFileSync(join(base, "file"), "x");
    await listedAlike(p, join(base, "file"), /is not a directory/);
    let deep = join(base, "deep");
    for (let i = 0; i < 66; i++) deep = join(deep, "d");
    mkdirSync(deep, { recursive: true });
    writeFileSync(join(deep, "f"), "f");
    await listedAlike(p, join(base, "deep"), /is deeper than 64 directories/);
    // a folder that cannot be read: never a listing short of it (as root it reads, and both list it)
    const closed = join(base, "closed");
    mkdirSync(join(closed, "in"), { recursive: true });
    writeFileSync(join(closed, "in", "f"), "f");
    chmodSync(join(closed, "in"), 0o000);
    try {
      await listedAlike(p, closed);
    } finally {
      chmodSync(join(closed, "in"), 0o755);
    }
  });

  test("a repository synced, then changed: the same requests and pieces, the same result", async () => {
    const [p, q] = [await pair(), await pair()];
    const repo = repository(tempdir());
    const first = await syncedAlike(p, q, "k1", repo);
    assert.ok(first.sent.requests >= 1);
    // changed, removed, renamed and added; a big file in pieces over two requests
    writeFileSync(join(repo, "src", "deep", "b.txt"), "beta again\n");
    rmSync(join(repo, "notes.txt"));
    renameSync(join(repo, "run.sh"), join(repo, "go.sh"));
    writeFileSync(join(repo, "huge.bin"), randomBytes(17 * 1024 * 1024));
    const second = await syncedAlike(p, q, "k2", repo);
    assert.ok(second.sent.requests >= 2, `in two requests: ${second.sent.requests}`);
    assert.equal(second.removed, 2);
  });

  test("a directory outside Git synced, contents the mirror has not sent again", async () => {
    const [p, q] = [await pair(), await pair()];
    const dir = join(tempdir(), "plain");
    mkdirSync(join(dir, "src"), { recursive: true });
    writeFileSync(join(dir, "same-1"), "twins\n");
    writeFileSync(join(dir, "same-2"), "twins\n");
    writeFileSync(join(dir, "src", "big"), randomBytes(3 * 512 * 1024));
    await syncedAlike(p, q, "p1", dir);
    renameSync(join(dir, "same-2"), join(dir, "renamed"));
    const again = await syncedAlike(p, q, "p2", dir);
    assert.equal(again.sent.files, 0);
  });

  test("to a station from before, base64 in each request, in halves where one would not fit", async () => {
    const [p, q] = [await pair({ before: true }), await pair({ before: true })];
    const dir = join(tempdir(), "old");
    mkdirSync(dir);
    writeFileSync(join(dir, "big.bin"), randomBytes(3 * 1024 * 1024 + 17));
    for (let i = 0; i < 30; i++) writeFileSync(join(dir, `small-${i}`), randomBytes(40 * 1024));
    writeFileSync(join(dir, "text"), "a line\n".repeat(200_000));
    const s = await syncedAlike(p, q, "k1", dir);
    assert.ok(s.sent.requests >= 6, `in pieces: ${s.sent.requests}`);
    // the first with its bytes after it, which that transport did not send (NoBytes); then each base64 in its request
    const puts = p.state.sent.filter(({ request }) => request.method === "sync.put");
    assert.equal(puts.filter(({ bytes }) => bytes !== null).length, 1);
    assert.ok(puts.every(({ request, bytes }) => bytes !== null || request.data.length <= 720 * 1024));
  });

  // (`reference`: the TypeScript saw it too; a file grown or made a link it read as far as it was listed, or through
  // the link, and sent)
  for (const [what, size, change, reference] of [
    ["its bytes", 3 * 512 * 1024 + 1, (path: string) => writeFileSync(path, Buffer.alloc(3 * 512 * 1024 + 1, 7)), true],
    ["its size", 3 * 512 * 1024 + 1, (path: string) => writeFileSync(path, Buffer.alloc(100, 7)), true],
    ["gone", 3 * 512 * 1024 + 1, (path: string) => rmSync(path), true],
    ["grown at its end", 3 * 512 * 1024 + 1, (path: string) => appendFileSync(path, "more"), false],
    ["empty, then written", 0, (path: string) => writeFileSync(path, "now"), false],
    ["made a link leading out", 3 * 512 * 1024 + 1, (path: string) => { rmSync(path); symlinkSync("/etc/hosts", path); }, false],
  ] as const) {
    test(`a file that changed while it was synced (${what}) stops it, nothing started: start again`, async () => {
      const p = await pair();
      const dir = join(tempdir(), "changing");
      mkdirSync(dir);
      writeFileSync(join(dir, "a"), "a\n");
      writeFileSync(join(dir, "f.bin"), randomBytes(size));
      await p.use("station_task", { key: "k", action: "prepare", command: "true", dir });
      // listed already, asked what the mirror has: then changed
      p.state.hold.add("sync.base");
      const started = p.use("station_task", { key: "k", action: "start" }).then(() => null, (e: Error) => e.message);
      await until("it is listed", () => p.state.held.length === 1);
      change(join(dir, "f.bin"));
      p.release();
      assert.match((await started) ?? "", /f\.bin changed while syncing; start again/);
      assert.equal(p.b.store.listJobs(null).length, 0);
      if (!reference) return;
      // and so the TypeScript said
      const q = await pair();
      rmSync(join(dir, "f.bin"), { force: true });
      writeFileSync(join(dir, "f.bin"), randomBytes(size));
      await q.use("station_task", { key: "k", action: "prepare", command: "true", dir });
      let held = false;
      const ask = async (method: string, more: Json) => {
        if (method === "sync.base" && !held) {
          held = true;
          change(join(dir, "f.bin"));
        }
        return q.a.remote.ask(q.B, { workspace: "ws", session: "s1", key: "k", method, ...more });
      };
      await assert.rejects(syncDir(ask, dir, () => 0, new Bulk()), /f\.bin changed while syncing; start again/);
    });
  }

  test("a link that changed while it was synced stops it too", async () => {
    const p = await pair();
    const dir = join(tempdir(), "linked");
    mkdirSync(dir);
    writeFileSync(join(dir, "a"), "a\n");
    symlinkSync("a", join(dir, "l"));
    await p.use("station_task", { key: "k", action: "prepare", command: "true", dir });
    p.state.hold.add("sync.base");
    const started = p.use("station_task", { key: "k", action: "start" }).then(() => null, (e: Error) => e.message);
    await until("it is listed", () => p.state.held.length === 1);
    rmSync(join(dir, "l"));
    symlinkSync("b", join(dir, "l"));
    p.release();
    assert.match((await started) ?? "", /l changed while syncing; start again/);
  });
});
