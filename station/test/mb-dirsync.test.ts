// The sending side of station_task's directory sync, in the MoonBit program (station/mb src/reader/dirsync_source.mbt),
// compared with the TypeScript it replaced (test/dirsync-reference.ts) on the same directories: what each lists of
// them, and what each sends a target to bring a mirror up to date, request by request, the bytes after them unpacked.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { appendFileSync, chmodSync, existsSync, lstatSync, mkdirSync, readFileSync, readlinkSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { zstdDecompressSync } from "node:zlib";
import { describe, test } from "node:test";
import { Bulk } from "../src/jobs/dirsync.ts";
import type { Json } from "../src/store/store.ts";
import { git, pair, tempdir, until } from "./dirsync-pair.ts";
import { commitPages, listLocal, submoduleUrl, syncDir } from "./dirsync-reference.ts";

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
    assert.deepEqual(listed.skipped.map((s: Json) => [s.path, s.why]), [["nested", "nested repository"], ["outside", "symbolic link leading out of the directory"], ["sub", "submodule with no URL in .gitmodules"]]);
    assert.deepEqual(listed.submodules, []);
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

  test("a link synced, then pointed elsewhere, made a file, removed: the mirror follows, the link itself replaced or let go", async () => {
    const p = await pair();
    const dir = join(tempdir(), "relinked");
    mkdirSync(dir);
    writeFileSync(join(dir, "a"), "a\n");
    writeFileSync(join(dir, "b"), "b\n");
    symlinkSync("a", join(dir, "l"));
    await p.run("k1", dir, "true");
    const mirror = p.mirror("relinked");
    assert.equal(readlinkSync(join(mirror, "l")), "a");
    // pointed elsewhere
    rmSync(join(dir, "l"));
    symlinkSync("b", join(dir, "l"));
    await p.run("k2", dir, "true");
    assert.equal(readlinkSync(join(mirror, "l")), "b");
    assert.equal(readFileSync(join(mirror, "a"), "utf8"), "a\n", "what the link named before is untouched");
    // made a file
    rmSync(join(dir, "l"));
    writeFileSync(join(dir, "l"), "now a file\n");
    symlinkSync("a", join(dir, "l2"));
    await p.run("k3", dir, "true");
    assert.ok(!lstatSync(join(mirror, "l")).isSymbolicLink());
    assert.equal(readFileSync(join(mirror, "l"), "utf8"), "now a file\n");
    assert.equal(readFileSync(join(mirror, "a"), "utf8"), "a\n");
    assert.equal(readlinkSync(join(mirror, "l2")), "a");
    // removed: gone from the disk too, what it named kept
    rmSync(join(dir, "l2"));
    const removed = await p.run("k4", dir, "true");
    assert.equal(removed.sync.removed, 1);
    assert.ok(!existsSync(join(mirror, "l2")) && lstatSync(join(mirror, "l2"), { throwIfNoEntry: false }) === undefined);
    assert.equal(readFileSync(join(mirror, "a"), "utf8"), "a\n");
  });

  test("a link to a folder in the mirror is never written or removed through", async () => {
    const p = await pair();
    const dir = join(tempdir(), "escaping");
    mkdirSync(join(dir, "escape"), { recursive: true });
    writeFileSync(join(dir, "escape", "pwn.txt"), "one\n");
    writeFileSync(join(dir, "fresh.txt"), "fresh\n");
    await p.run("k1", dir, "true");
    // a task made the synced folder a link leading out
    const outside = tempdir();
    writeFileSync(join(outside, "pwn.txt"), "outside\n");
    const mirror = p.mirror("escaping");
    rmSync(join(mirror, "escape"), { recursive: true });
    symlinkSync(outside, join(mirror, "escape"));
    // a new file under it: refused
    writeFileSync(join(dir, "escape", "new.txt"), "new\n");
    await p.use("station_task", { key: "k2", action: "prepare", command: "true", dir });
    const added = await p.use("station_task", { key: "k2", action: "start" }).then(() => null, (e: Error) => e.message);
    assert.match(added ?? "", /sync conflict at escape\/new\.txt: an existing remote path would be overwritten/);
    assert.ok(!existsSync(join(outside, "new.txt")));
    // the synced file changed: a conflict (what is there is not what was synced), not written through
    rmSync(join(dir, "escape", "new.txt"));
    writeFileSync(join(dir, "escape", "pwn.txt"), "two\n");
    await p.use("station_task", { key: "k3", action: "prepare", command: "true", dir });
    const changed = await p.use("station_task", { key: "k3", action: "start" }).then(() => null, (e: Error) => e.message);
    assert.match(changed ?? "", /sync conflict at escape\/pwn\.txt/);
    assert.equal(readFileSync(join(outside, "pwn.txt"), "utf8"), "outside\n");
    // the synced file removed: a conflict too, nothing removed through the link
    rmSync(join(dir, "escape"), { recursive: true });
    await p.use("station_task", { key: "k4", action: "prepare", command: "true", dir });
    const removed = await p.use("station_task", { key: "k4", action: "start" }).then(() => null, (e: Error) => e.message);
    assert.match(removed ?? "", /sync conflict at escape\/pwn\.txt: the remote file changed before removal/);
    assert.equal(readFileSync(join(outside, "pwn.txt"), "utf8"), "outside\n");
  });

  test("a submodule's URL relative to its superproject's, as Git takes it", () => {
    for (const [url, base, want] of [
      ["https://h/o/x.git", "", "https://h/o/x.git"],
      ["../x.git", "https://github.com/o/super.git", "https://github.com/o/x.git"],
      ["./x", "https://h/o/super/", "https://h/o/super/x"],
      ["../../p/x", "git@h:o/super", "git@h:p/x"],
      ["../x", "git@h:super", "git@h:x"],
      ["../x", "", ""],
    ]) assert.equal(submoduleUrl(url!, base!), want, `${url} against ${base}`);
  });

  /// A repository to be a submodule: `lib.txt` saying `text`, committed; its commit.
  const commitIn = (repo: string, text: string): string => {
    if (!existsSync(repo)) {
      mkdirSync(repo, { recursive: true });
      git(repo, "init", "-q");
    }
    writeFileSync(join(repo, "lib.txt"), text);
    git(repo, "add", "-A");
    git(repo, "commit", "-q", "-m", text);
    return git(repo, "rev-parse", "HEAD").trim();
  };
  /// `path` made a submodule of `repo` at `id` (its gitlink and .gitmodules), committed.
  const linkIn = (repo: string, path: string, id: string, url: string) => {
    appendFileSync(join(repo, ".gitmodules"), `[submodule "${path}"]\n\tpath = ${path}\n\turl = ${url}\n`);
    git(repo, "add", ".gitmodules");
    git(repo, "update-index", "--add", "--cacheinfo", `160000,${id},${path}`);
    git(repo, "commit", "-q", "-m", `link ${path}`);
  };

  test("a repository's submodules: each by its path, the commit checked out there else the index's, and its URL", async () => {
    const p = await pair();
    const base = tempdir();
    const up = join(base, "up");
    const first = commitIn(up, "one\n");
    const second = commitIn(up, "two\n");
    const repo = join(base, "super");
    mkdirSync(repo);
    git(repo, "init", "-q");
    writeFileSync(join(repo, "a.txt"), "a\n");
    git(repo, "add", "-A");
    git(repo, "commit", "-q", "-m", "first");
    git(repo, "remote", "add", "origin", "https://example.invalid/acme/super.git");
    linkIn(repo, "libs/up", first, up);
    linkIn(repo, "libs/rel", first, "../rel.git");
    linkIn(repo, "libs/none", first, "");
    // libs/up checked out here at its second commit, not staged: built at it there too
    git(base, "clone", "-q", up, join(repo, "libs", "up"));
    const listed = await listedAlike(p, repo);
    assert.deepEqual(listed.submodules, [
      { path: "libs/rel", id: first, url: "https://example.invalid/acme/rel.git" },
      { path: "libs/up", id: second, url: up },
    ]);
    assert.deepEqual(listed.skipped, [{ path: "libs/none", why: "submodule with no URL in .gitmodules" }]);
    assert.ok(!listed.files.some((f: Json) => f.path.startsWith("libs/")), "none of a submodule's files");
    // From a folder of it, its paths from there.
    mkdirSync(join(repo, "libs", "x"));
    writeFileSync(join(repo, "libs", "x", "f"), "f\n");
    // (not `add -A`: it would take out the gitlinks with no directory here)
    git(repo, "add", "libs/x");
    git(repo, "commit", "-q", "-m", "x");
    const libs = await listedAlike(p, join(repo, "libs"));
    assert.deepEqual(libs.submodules.map((s: Json) => s.path), ["rel", "up"]);
  });

  test("a mirror's submodules checked out before its task runs: fetched once, kept with what tasks built in them, never in its changes; gone with the submodule", async () => {
    const [p, q] = [await pair(), await pair()];
    const base = tempdir();
    const up = join(base, "up");
    const v1 = commitIn(up, "lib one\n");
    // one this station's shared clones have (`<data>/repos/<owner>/<name>`): its URL never reached
    const cached = join(p.b.dir, "repos", "acme", "cached");
    const c1 = commitIn(cached, "cached one\n");
    const repo = join(base, "super");
    mkdirSync(repo);
    git(repo, "init", "-q");
    writeFileSync(join(repo, "a.txt"), "a\n");
    git(repo, "add", "-A");
    git(repo, "commit", "-q", "-m", "first");
    linkIn(repo, "libs/up", v1, up);
    linkIn(repo, "libs/cached", c1, "https://example.invalid/acme/cached.git");
    // the program sends what the TypeScript did, the submodules with the plan's last part
    const synced = await syncedAlike(p, q, "s0", repo);
    assert.equal(synced.submodules, 2);
    const commit = p.state.sent.filter(({ request }) => request.method === "sync.commit").at(-1)!.request;
    assert.deepEqual(commit.submodules, [["libs/cached", c1, "https://example.invalid/acme/cached.git"], ["libs/up", v1, up]]);
    const logOf = (job: Json) => readFileSync(p.b.store.getJob(job.id)!.log, "utf8");
    const resultOf = (key: string) => {
      const told = p.a.told.find(([, text]) => text.startsWith(`Remote task ${key} on `))![1];
      return JSON.parse(told.slice(told.indexOf("{")));
    };
    // (s0's own task checked them out already)
    const one = await p.run("s1", repo, "cat libs/up/lib.txt libs/cached/lib.txt > seen.txt && echo built > libs/up/out && echo more >> a.txt");
    assert.equal(p.b.store.getJob(one.started.job.id)!.exitCode, 0, logOf(one.started.job));
    assert.doesNotMatch(logOf(one.started.job), /checked out/, "at its commit already: nothing done");
    assert.equal(readFileSync(join(p.mirror("super"), "seen.txt"), "utf8"), "lib one\ncached one\n");
    assert.deepEqual(resultOf("s1").back.changed.files, ["a.txt"]);
    // moved on: fetched and checked out over it, what a task built there kept
    const v2 = commitIn(up, "lib two\n");
    git(repo, "update-index", "--cacheinfo", `160000,${v2},libs/up`);
    git(repo, "commit", "-q", "-m", "up two");
    const two = await p.run("s2", repo, "cat libs/up/lib.txt > seen.txt");
    assert.match(logOf(two.started.job), new RegExp(`still\\.fail: submodule libs/up checked out at ${v2}`));
    assert.doesNotMatch(logOf(two.started.job), /libs\/cached/);
    assert.equal(readFileSync(join(p.mirror("super"), "seen.txt"), "utf8"), "lib two\n");
    assert.equal(readFileSync(join(p.mirror("super"), "libs", "up", "out"), "utf8"), "built\n");
    assert.deepEqual(resultOf("s2").back.changed.files, ["a.txt"]);
    // one that cannot be fetched: said, and the task runs
    const v3 = "3".repeat(40);
    git(repo, "update-index", "--cacheinfo", `160000,${v3},libs/up`);
    git(repo, "commit", "-q", "-m", "up gone");
    const three = await p.run("s3", repo, "echo ran");
    assert.equal(p.b.store.getJob(three.started.job.id)!.exitCode, 0);
    assert.match(logOf(three.started.job), new RegExp(`still\\.fail: submodule libs/up could not be fetched at ${v3}[^\\n]*\\n(.*\\n)*ran\\n`));
    // the submodule taken out: its checkout goes, a file synced in its place
    git(repo, "rm", "-q", "--cached", "libs/up");
    writeFileSync(join(repo, ".gitmodules"), `[submodule "libs/cached"]\n\tpath = libs/cached\n\turl = https://example.invalid/acme/cached.git\n`);
    mkdirSync(join(repo, "libs", "up"), { recursive: true });
    writeFileSync(join(repo, "libs", "up", "lib.txt"), "vendored\n");
    git(repo, "add", "-A");
    git(repo, "commit", "-q", "-m", "vendored");
    const four = await p.run("s4", repo, "cat libs/up/lib.txt > seen.txt");
    assert.equal(p.b.store.getJob(four.started.job.id)!.exitCode, 0, logOf(four.started.job));
    assert.equal(readFileSync(join(p.mirror("super"), "seen.txt"), "utf8"), "vendored\n");
    assert.ok(!existsSync(join(p.mirror("super"), "libs", "up", ".git")));
    assert.ok(!existsSync(join(p.mirror("super"), "libs", "up", "out")));
  });

  test("regular file and symlink sharing the same hash stay 0-diff with reference and never cross-reuse", async () => {
    const [p, q] = [await pair(), await pair()];
    const dir = join(tempdir(), "kind-reuse-parity");
    mkdirSync(dir);
    writeFileSync(join(dir, "t.txt"), "hello\n");
    writeFileSync(join(dir, "f"), "t.txt");
    await syncedAlike(p, q, "kr1", dir);
    symlinkSync("t.txt", join(dir, "l"));
    writeFileSync(join(dir, "x"), "t.txt");
    chmodSync(join(dir, "x"), 0o755);
    const s2 = await syncedAlike(p, q, "kr2", dir);
    assert.equal(s2.sent.files, 1, "symlink must be sent even though regular file has same hash; exec file reuses regular file");
    assert.ok(lstatSync(join(p.mirror("kind-reuse-parity"), "l")).isSymbolicLink());
    assert.equal(readlinkSync(join(p.mirror("kind-reuse-parity"), "l")), "t.txt");
    assert.ok((lstatSync(join(p.mirror("kind-reuse-parity"), "x")).mode & 0o100) !== 0);
  });

  test("commitPages enforces UTF-8 byte budget across multi-byte paths, remove, final, and submodules", () => {
    const h = "1".repeat(40);
    const id = "0123456789abcdef";
    const budget = 300;
    const set: [string, string, string][] = [
      ["目录/文件一😀.txt", h, "100644"],
      ["目录/\"引号\"\\转义😀.txt", h, "100755"],
      ["目录/文件三😀.txt", h, "120000"],
    ];
    const remove = ["旧目录/删除一😀.txt", "旧目录/删除二😀.txt", "旧目录/删除三😀.txt", "旧目录/删除四😀.txt"];
    const subs = [
      { path: "vendor/sub-a", id: h, url: "https://example.invalid/org/sub-a.git" },
      { path: "vendor/sub-b", id: h, url: "https://example.invalid/org/sub-b.git" },
    ];
    const pages = commitPages(id, set, remove, subs, budget);
    assert.ok(pages.length >= 3);
    for (let i = 0; i < pages.length; i++) {
      assert.ok(Buffer.byteLength(JSON.stringify(pages[i])) <= budget, `page ${i} exceeds ${budget}`);
      assert.equal(pages[i]!.final, i === pages.length - 1);
      if (i < pages.length - 1) assert.equal(pages[i]!.submodules, undefined);
      else assert.equal(pages[i]!.submodules?.length, 2);
    }
    // Single item larger than budget goes alone without looping
    const giant: [string, string, string][] = [[`超长路径_${"汉".repeat(80)}.txt`, h, "100644"], ["small.txt", h, "100644"]];
    const gpages = commitPages(id, giant, [], [], 160);
    assert.equal(gpages.length, 2);
    assert.deepEqual(gpages[0]!.set, [giant[0]]);
    assert.deepEqual(gpages[1]!.set, [giant[1]]);
    assert.ok(Buffer.byteLength(JSON.stringify(gpages[1])) <= 160);
  });

  test("multi-page UTF-8 sync.commit stays strictly within 512 KiB per page and matches reference 0-diff", async () => {
    const [p, q] = [await pair(), await pair()];
    const dir = join(tempdir(), "utf8-pages");
    mkdirSync(dir);
    // 2600 files with 207-byte multi-byte UTF-8 names (~280 B/entry in set, ~210 B/entry in remove) -> >512 KiB (>1 page each)
    const pad = "中文目录测试😀".repeat(9);
    for (let i = 0; i < 2600; i++) {
      writeFileSync(join(dir, `${pad}-${i}.txt`), "x");
    }
    await syncedAlike(p, q, "up1", dir);
    const commits1 = p.state.sent.filter(({ request }) => request.method === "sync.commit");
    assert.ok(commits1.length >= 2, `expected multi-page commit, got ${commits1.length}`);
    for (const { request } of commits1) {
      const { workspace: _w, session: _s, key: _k, method: _m, ...payload } = request;
      assert.ok(Buffer.byteLength(JSON.stringify(payload)) <= 512 * 1024);
    }
    // Remove all of them -> multi-page remove commit also stays within 512 KiB
    for (let i = 0; i < 2600; i++) rmSync(join(dir, `${pad}-${i}.txt`));
    writeFileSync(join(dir, "keep.txt"), "k");
    await syncedAlike(p, q, "up2", dir);
    const commits2 = p.state.sent.filter(({ request }) => request.method === "sync.commit");
    assert.ok(commits2.length >= 2, `expected multi-page remove commit, got ${commits2.length}`);
    for (const { request } of commits2) {
      const { workspace: _w, session: _s, key: _k, method: _m, ...payload } = request;
      assert.ok(Buffer.byteLength(JSON.stringify(payload)) <= 512 * 1024);
    }
  });
});
