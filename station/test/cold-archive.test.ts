// Cold storage's files, and the tar it writes and reads.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  linkSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readlinkSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import fsModule from "node:fs";
import { rename } from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { zstdDecompressSync } from "node:zlib";
import {
  emptyWorkspace,
  jsonlFilesSoon,
  lock,
  packFile,
  packFileIf,
  packWorkspace,
  packWorkspaceIf,
  packed,
  restoreFile,
  restoreWorkspace,
  withExtension,
  withLock,
  WORKSPACE_RENAME_BACKOFF,
  workspaceArchive,
  workspaceFile,
} from "../src/sessions/archive.ts";
import { storage } from "./reference/transcript-paths.ts";
import { measureRoom, measured, rebuildableSoon, safeToRemove } from "../src/sessions/footprint.ts";
import { rebuildableKind, roomOf } from "./footprint-reference.ts";
import { settle } from "./hub-fakes.ts";

const temp = () => realpathSync(mkdtempSync(join(tmpdir(), "cold-")));
const write = (path: string, bytes: string | Buffer) => {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, bytes);
};
const rejects = async (p: Promise<unknown>) => {
  try {
    await p;
  } catch {
    return true;
  }
  return false;
};

test("workspace round trip preserves edits, permissions, symlinks and attachments", async () => {
  const room = temp();
  const ws = join(room, "workspace");
  write(join(ws, "project/uncommitted.rs"), Buffer.alloc(100_000, "x"));
  write(join(ws, "script.sh"), "#!/bin/sh\ntrue\n");
  chmodSync(join(ws, "script.sh"), 0o751);
  write(join(ws, "uploads/evidence.txt"), "historical attachment");
  symlinkSync("project/uncommitted.rs", join(ws, "link"));
  const release = await lock(room);
  await packWorkspace(room);
  assert.ok(!existsSync(join(ws, "project/uncommitted.rs")));
  assert.ok(statSync(workspaceArchive(room)).size < 10_000);
  assert.deepEqual(await workspaceFile(room, "uploads/evidence.txt"), Buffer.from("historical attachment"));
  await packWorkspace(room); // An hourly retry must not replace the archive with the now-empty directory.
  write(join(ws, "uploads/new.txt"), "new attachment while archived");
  await restoreWorkspace(room);
  assert.deepEqual(readFileSync(join(ws, "project/uncommitted.rs")), Buffer.alloc(100_000, "x"));
  // Windows keeps no Unix modes.
  if (process.platform !== "win32") assert.equal(statSync(join(ws, "script.sh")).mode & 0o777, 0o751);
  // Windows keeps a link's target with its own separator.
  assert.equal(readlinkSync(join(ws, "link")), join("project", "uncommitted.rs"));
  assert.equal(readFileSync(join(ws, "uploads/new.txt"), "utf8"), "new attachment while archived");
  assert.ok(!existsSync(workspaceArchive(room)));
  await restoreWorkspace(room);
  release();
  assert.ok(existsSync(join(room, "archive.lock")), "the lock file is where the Rust's is");
  rmSync(room, { recursive: true });
});

test("links the machine refuses come back where the restored workspace ends up, not where it was made", { skip: process.platform !== "win32" && "only Windows refuses links" }, async () => {
  const room = temp();
  const ws = join(room, "workspace");
  write(join(ws, "project/main.rs"), "fn main() {}");
  symlinkSync("project", join(ws, "z-lib"), "dir");
  symlinkSync(join("project", "main.rs"), join(ws, "entry"));
  const release = await lock(room);
  await packWorkspace(room);
  // As Windows without the privilege (Developer Mode off): links refused, junctions made. (The tree is made by the
  // shell, `tar.unpack`, whose links this machine refuses or not as it does; what stands in is made here, by Node.)
  const real = fsModule.promises.symlink;
  fsModule.promises.symlink = (async (target: string, path: string, type?: string) => {
    if (type === "junction") return real(target, path, type);
    throw Object.assign(new Error("EPERM: operation not permitted, symlink"), { code: "EPERM" });
  }) as typeof real;
  syncBuiltinESMExports();
  try {
    await restoreWorkspace(room);
  } finally {
    fsModule.promises.symlink = real;
    syncBuiltinESMExports();
  }
  release();
  // (`z-lib` after `project`: packed before it, so a directory's link made before its directory is: still one.)
  // The directory's stand-in (a junction) leads into the workspace at its final path: the tree was made beside it
  // (workspace.restoring) and moved.
  assert.equal(realpathSync(join(ws, "z-lib")), realpathSync(join(ws, "project")));
  assert.equal(readFileSync(join(ws, "z-lib", "main.rs"), "utf8"), "fn main() {}");
  assert.equal(readFileSync(join(ws, "entry"), "utf8"), "fn main() {}");
  assert.ok(!existsSync(join(room, "workspace.restoring")));
  rmSync(room, { recursive: true });
});

test("transcript round trip and corruption keep the only good copy", async () => {
  const root = temp();
  const path = join(root, "history.jsonl");
  const text = '{"type":"user"}\n'.repeat(10_000);
  write(path, text);
  await packFile(path);
  assert.ok(!existsSync(path));
  assert.equal(storage(path), packed(path));
  assert.equal(zstdDecompressSync(readFileSync(packed(path))).toString(), text);
  assert.ok(existsSync(join(root, "history.jsonl.archive-lock")));
  await restoreFile(path);
  assert.equal(readFileSync(path, "utf8"), text);
  await packFile(path);
  writeFileSync(packed(path), "broken archive");
  assert.ok(await rejects(restoreFile(path)));
  assert.ok(!existsSync(path));
  assert.ok(existsSync(packed(path)));
  assert.ok(!existsSync(join(root, "history.jsonl.restoring")));
  rmSync(root, { recursive: true });
});

test("a cut-off transcript archive is refused, not restored short", async () => {
  const root = temp();
  const path = join(root, "history.jsonl");
  write(path, Array.from({ length: 20_000 }, (_, i) => `{"n":${i}}\n`).join(""));
  await packFile(path);
  const whole = readFileSync(packed(path));
  writeFileSync(packed(path), whole.subarray(0, whole.length - 7));
  assert.ok(await rejects(restoreFile(path)));
  assert.ok(!existsSync(path));
  rmSync(root, { recursive: true });
});

test("failed workspace restore preserves archive and new files", async () => {
  const room = temp();
  write(join(room, "workspace/source.rs"), "original");
  await packWorkspace(room);
  write(join(room, "workspace/new.txt"), "new");
  writeFileSync(workspaceArchive(room), "broken archive");
  assert.ok(await rejects(restoreWorkspace(room)));
  assert.equal(readFileSync(join(room, "workspace/new.txt"), "utf8"), "new");
  assert.ok(existsSync(workspaceArchive(room)));
  rmSync(room, { recursive: true });
});

test("interrupted workspace retirement can be restored", async () => {
  const room = temp();
  write(join(room, "workspace/source.rs"), "snapshot");
  await packWorkspace(room);
  write(join(room, "workspace.retiring/source.rs"), "latest surviving original");
  await restoreWorkspace(room);
  assert.equal(readFileSync(join(room, "workspace/source.rs"), "utf8"), "latest surviving original");
  rmSync(room, { recursive: true });
});

test("read-only directories (a Go module cache) are packed, restored over leftovers and emptied", { skip: process.platform === "win32" && "Windows keeps no Unix modes" }, async () => {
  const room = temp();
  const cache = join(room, "workspace/gopath/mod/example.com/m@v1.0.0");
  write(join(cache, ".github/workflows/build.yml"), "on: push");
  write(join(cache, "go.mod"), "module example.com/m");
  const readOnly = () => [join(cache, ".github/workflows"), join(cache, ".github"), cache].forEach((d) => chmodSync(d, 0o555));
  readOnly();
  await packWorkspace(room);
  assert.ok(existsSync(workspaceArchive(room)));
  assert.ok(!existsSync(join(room, "workspace.retiring")));
  // What a failed restore and a failed retirement left, read-only too: overlaid, then removed.
  const stale = join(room, "workspace.restoring/gopath/mod/example.com/m@v1.0.0");
  write(join(stale, ".github/workflows/build.yml"), "stale");
  chmodSync(join(stale, ".github/workflows"), 0o555);
  write(join(room, "workspace.retiring/gopath/mod/example.com/m@v1.0.0/go.mod"), "module example.com/m // edited");
  chmodSync(join(room, "workspace.retiring/gopath/mod/example.com/m@v1.0.0"), 0o555);
  await restoreWorkspace(room);
  assert.equal(readFileSync(join(cache, ".github/workflows/build.yml"), "utf8"), "on: push");
  assert.equal(readFileSync(join(cache, "go.mod"), "utf8"), "module example.com/m // edited");
  assert.equal(statSync(cache).mode & 0o777, 0o555);
  assert.equal(statSync(join(cache, ".github/workflows")).mode & 0o777, 0o555);
  for (const left of ["workspace.restoring", "workspace.retiring", "workspace.restored-old"]) assert.ok(!existsSync(join(room, left)), left);
  await packWorkspace(room);
  await emptyWorkspace(room);
  assert.ok(!existsSync(join(room, "workspace/gopath")));
  rmSync(room, { recursive: true });
});

test("archived git worktree survives prune and restores dirty files", async () => {
  const root = temp();
  const repo = join(root, "repo");
  mkdirSync(repo);
  const git = (dir: string, args: string[]) => execFileSync("git", ["-C", dir, ...args], { encoding: "utf8" });
  git(repo, ["init", "-q"]);
  write(join(repo, "source.rs"), "committed");
  git(repo, ["add", "."]);
  git(repo, ["-c", "user.name=test", "-c", "user.email=test@example.com", "commit", "-qm", "initial"]);
  const room = join(root, "chat");
  const ws = join(room, "workspace");
  mkdirSync(ws, { recursive: true });
  const worktree = join(ws, "project");
  git(repo, ["worktree", "add", "--detach", worktree]);
  write(join(worktree, "source.rs"), "uncommitted edit");
  const gitdir = readFileSync(join(worktree, ".git"), "utf8").trim().slice("gitdir: ".length);
  await packWorkspace(room);
  assert.ok(existsSync(join(gitdir, "locked")));
  assert.equal(readFileSync(join(gitdir, "locked"), "utf8"), `still.fail archived workspace: ${room}\n`);
  assert.deepEqual(JSON.parse(readFileSync(join(room, "workspace-locks.json"), "utf8")), [join(realpathSync(gitdir), "locked")]);
  git(repo, ["worktree", "prune", "--expire", "now"]);
  assert.ok(existsSync(gitdir));
  await restoreWorkspace(room);
  assert.ok(!existsSync(join(gitdir, "locked")));
  assert.ok(!existsSync(join(room, "workspace-locks.json")));
  assert.equal(readFileSync(join(worktree, "source.rs"), "utf8"), "uncommitted edit");
  assert.ok(git(worktree, ["status", "--porcelain"]).includes("source.rs"));
  rmSync(root, { recursive: true });
});

test("a worktree its repository no longer knows is packed with the rest, nothing locked for it", async () => {
  const room = temp();
  write(join(room, "workspace/source.rs"), "work");
  write(join(room, "workspace/project/.git"), `gitdir: ${join(room, "gone.git", "worktrees", "project")}\n`);
  write(join(room, "workspace/project/source.rs"), "the worktree's");
  await packWorkspaceIf(room, () => true);
  assert.ok(existsSync(workspaceArchive(room)));
  assert.ok(!existsSync(join(room, "workspace/source.rs")));
  assert.deepEqual(JSON.parse(readFileSync(join(room, "workspace-locks.json"), "utf8")), []);
  await restoreWorkspace(room);
  assert.equal(readFileSync(join(room, "workspace/project/source.rs"), "utf8"), "the worktree's");
  rmSync(room, { recursive: true });
});

test("becoming active before commit keeps originals and removes temporary archives", async () => {
  const room = temp();
  write(join(room, "workspace/source.rs"), "work");
  await packWorkspaceIf(room, () => false);
  assert.equal(readFileSync(join(room, "workspace/source.rs"), "utf8"), "work");
  assert.ok(!existsSync(workspaceArchive(room)));
  assert.ok(!existsSync(join(room, "workspace.tar.zst.writing")));
  const history = join(room, "history.jsonl");
  write(history, "history\n");
  await packFileIf(history, () => false);
  assert.equal(readFileSync(history, "utf8"), "history\n");
  assert.ok(!existsSync(packed(history)));
  assert.ok(!existsSync(join(room, "history.jsonl.zst.writing")));
  rmSync(room, { recursive: true });
});

/// A rename of the workspace aside that fails with EPERM the first `times` attempts (Windows: a handle kept a moment
/// after its process exits), every other rename as it is.
const lockedWorkspace = (room: string, times: number) => {
  const waits: number[] = [];
  let attempts = 0;
  return {
    waits,
    attempts: () => attempts,
    opts: {
      rename: async (from: string, to: string) => {
        if (from === join(room, "workspace") && to === join(room, "workspace.retiring") && attempts++ < times) {
          throw Object.assign(new Error("EPERM: operation not permitted, rename"), { code: "EPERM" });
        }
        await rename(from, to);
      },
      wait: async (ms: number) => { waits.push(ms); },
    },
  };
};

test("a workspace held a moment after its process exits is packed once the lock clears", async () => {
  const room = temp();
  write(join(room, "workspace/source.rs"), "work");
  const locked = lockedWorkspace(room, 3);
  await packWorkspaceIf(room, () => true, locked.opts);
  assert.deepEqual(locked.waits, [50, 100, 200]);
  assert.ok(existsSync(workspaceArchive(room)));
  assert.deepEqual(fsModule.readdirSync(join(room, "workspace")), []);
  assert.ok(!existsSync(join(room, "workspace.retiring")));
  await restoreWorkspace(room);
  assert.equal(readFileSync(join(room, "workspace/source.rs"), "utf8"), "work");
  rmSync(room, { recursive: true });
});

test("a workspace that stays held keeps its files and leaves no archive, and is packed once let go", async () => {
  const room = temp();
  write(join(room, "workspace/source.rs"), "work");
  const locked = lockedWorkspace(room, Infinity);
  await assert.rejects(packWorkspaceIf(room, () => true, locked.opts), { code: "EPERM" });
  assert.equal(locked.attempts(), WORKSPACE_RENAME_BACKOFF.length + 1);
  assert.deepEqual(locked.waits, [...WORKSPACE_RENAME_BACKOFF]);
  assert.equal(readFileSync(join(room, "workspace/source.rs"), "utf8"), "work");
  assert.ok(!existsSync(workspaceArchive(room)));
  assert.ok(!existsSync(join(room, "workspace-locks.json")));
  assert.ok(!existsSync(join(room, "workspace.tar.zst.writing")));
  assert.ok(!existsSync(join(room, "workspace.retiring")));
  await packWorkspaceIf(room, () => true);
  assert.ok(existsSync(workspaceArchive(room)));
  assert.ok(!existsSync(join(room, "workspace/source.rs")));
  await restoreWorkspace(room);
  assert.equal(readFileSync(join(room, "workspace/source.rs"), "utf8"), "work");
  rmSync(room, { recursive: true });
});

test("long names, long link targets, nested directories, empty files and hard links come back", async () => {
  const room = temp();
  const ws = join(room, "workspace");
  const deep = `${"d".repeat(60)}/${"e".repeat(60)}/${"名".repeat(40)}.txt`;
  write(join(ws, deep), "deep");
  write(join(ws, "empty"), "");
  mkdirSync(join(ws, "an/empty/dir"), { recursive: true });
  symlinkSync(`${"t".repeat(150)}/target`, join(ws, "far"));
  write(join(ws, "a"), "linked");
  linkSync(join(ws, "a"), join(ws, "b"));
  chmodSync(join(ws, "an"), 0o750);
  await packWorkspace(room);
  assert.deepEqual(await workspaceFile(room, deep), Buffer.from("deep"));
  assert.deepEqual(await workspaceFile(room, `./${deep}`), Buffer.from("deep"));
  assert.equal(await workspaceFile(room, "an"), null, "a directory is no file");
  assert.equal(await workspaceFile(room, "missing"), null);
  await restoreWorkspace(room);
  assert.equal(readFileSync(join(ws, deep), "utf8"), "deep");
  assert.equal(readFileSync(join(ws, "empty"), "utf8"), "");
  assert.ok(statSync(join(ws, "an/empty/dir")).isDirectory());
  if (process.platform !== "win32") assert.equal(statSync(join(ws, "an")).mode & 0o777, 0o750);
  assert.equal(readlinkSync(join(ws, "far")), join("t".repeat(150), "target"));
  assert.equal(readFileSync(join(ws, "b"), "utf8"), "linked");
  rmSync(room, { recursive: true });
});

test("the room's lock is taken in turn", async () => {
  const room = temp();
  const order: string[] = [];
  let entered = () => {};
  const inside = new Promise<void>((r) => (entered = r));
  let leave = () => {};
  const out = new Promise<void>((r) => (leave = r));
  const first = withLock(room, async () => {
    order.push("first in");
    entered();
    await out;
    order.push("first out");
  });
  // Asked for while the first holds it (and given what is queued to run meanwhile): it waits.
  await inside;
  const second = withLock(room, async () => void order.push("second"));
  await settle();
  leave();
  await Promise.all([first, second]);
  assert.deepEqual(order, ["first in", "first out", "second"]);
  rmSync(room, { recursive: true });
});

test("jsonl files: logical names, packed ones too, once each", async () => {
  const root = temp();
  write(join(root, "a.jsonl"), "");
  write(join(root, "sub/b.jsonl.zst"), "");
  write(join(root, "sub/b.jsonl"), "");
  write(join(root, "c.txt"), "");
  write(join(root, "a.jsonl.archive-lock"), "");
  const out: string[] = [];
  await jsonlFilesSoon(root, out);
  assert.deepEqual(out.sort(), [join(root, "a.jsonl"), join(root, "sub/b.jsonl")]);
  assert.equal(withExtension("/x/abc.jsonl", "jsonl.archive-lock"), join("/x", "abc.jsonl.archive-lock"));
  assert.equal(withExtension("/x/abc.jsonl.zst", "zst.writing"), join("/x", "abc.jsonl.zst.writing"));
  rmSync(root, { recursive: true });
});

// ── footprint.rs ──

test("a file linked twice counts once", async () => {
  const root = temp();
  write(join(root, "a/file"), Buffer.alloc(64_000, 7));
  mkdirSync(join(root, "b"));
  linkSync(join(root, "a/file"), join(root, "b/file"));
  const once = await measured(join(root, "a"));
  const both = await measured(root);
  assert.ok(both < once + 10_000, `${once} ${both}`);
  rmSync(root, { recursive: true });
});

test("what can be made again", async () => {
  const p = temp();
  write(join(p, "android/build.gradle.kts"), "x");
  write(join(p, "android/settings.gradle.kts"), "x");
  write(join(p, "rs/Cargo.toml"), "x");
  for (const dir of ["x/node_modules", "android/build", "android/.gradle", "rs/target"]) assert.equal((await rebuildableSoon(join(p, dir))) !== null, true, dir);
  for (const dir of ["site/build", "site/target", "dist"]) assert.equal((await rebuildableSoon(join(p, dir))) !== null, false, dir);
  rmSync(p, { recursive: true });
});

test("what can be made again known by what is in it or beside it, never by a bare name: Elixir, MoonBit, Xcode, Cargo of any name", async () => {
  const p = temp();
  const dir = (path: string) => mkdirSync(join(p, path), { recursive: true });
  const TAG = "Signature: 8a477f597d28d172789f06886806bc55\n# This file is a cache directory tag created by cargo.\n# For information about cache directory tags see https://bford.info/cachedir/\n";
  // Elixir: _build and deps beside mix.exs.
  write(join(p, "ex/mix.exs"), "x");
  dir("ex/_build/dev");
  dir("ex/deps/jason");
  // MoonBit: _build beside its module's manifest or its work's, or above within the checkout; .mooncakes beside.
  write(join(p, "mb/moon.mod.json"), "{}");
  dir("mb/_build");
  dir("mb/.mooncakes");
  write(join(p, "work/moon.work"), "x");
  dir("work/_build");
  // New MoonBit manifest filenames (moon.mod / moon.pkg without .json or moon.work).
  write(join(p, "mb-new/moon.mod"), 'name: "demo"\n');
  dir("mb-new/_build");
  dir("mb-new/.mooncakes");
  write(join(p, "mb-pkg/moon.pkg"), 'import {}\n');
  dir("mb-pkg/_build");
  dir("repo/.git");
  write(join(p, "repo/moon.mod.json"), "{}");
  write(join(p, "repo/src/lib/moon.pkg.json"), "{}");
  dir("repo/src/lib/sub/_build");
  dir("repo-new/.git");
  write(join(p, "repo-new/moon.mod"), 'name: "demo"\n');
  write(join(p, "repo-new/src/lib/moon.pkg"), 'import {}\n');
  dir("repo-new/src/lib/sub/_build");
  // (above the checkout's top: not its; outside a checkout, only beside)
  write(join(p, "outer/moon.mod.json"), "{}");
  dir("outer/inner/.git");
  dir("outer/inner/_build");
  dir("outer/loose/_build");
  // Xcode's derived data, of any name: its products and intermediates.
  dir("DerivedData-App/Build/Products");
  dir("DerivedData-App/Build/Intermediates.noindex");
  dir("only-products/Build/Products");
  // Cargo's target of any name: its CACHEDIR.TAG, and Cargo's own files in it.
  write(join(p, "rs-a/CACHEDIR.TAG"), TAG);
  write(join(p, "rs-a/.rustc_info.json"), "{}");
  write(join(p, "rs-b/CACHEDIR.TAG"), TAG);
  dir("rs-b/release/.fingerprint");
  write(join(p, "rs-c/CACHEDIR.TAG"), TAG);
  dir("rs-c/debug/deps");
  write(join(p, "rs-tag-only/CACHEDIR.TAG"), TAG);
  write(join(p, "other-cache/CACHEDIR.TAG"), "Signature: 8a477f597d28d172789f06886806bc55\n# a cache of another program's\n");
  write(join(p, "other-cache/.rustc_info.json"), "{}");
  write(join(p, "no-tag/.rustc_info.json"), "{}");
  dir("no-tag/debug/deps");
  dir("bare/_build");
  dir("bare/deps");
  dir("bare/.mooncakes");
  const found = [
    "ex/_build", "ex/deps", "mb/_build", "mb/.mooncakes", "work/_build",
    "mb-new/_build", "mb-new/.mooncakes", "mb-pkg/_build",
    "repo/src/lib/sub/_build", "repo-new/src/lib/sub/_build",
    "DerivedData-App", "rs-a", "rs-b", "rs-c",
  ];
  const not = ["outer/inner/_build", "outer/loose/_build", "only-products", "rs-tag-only", "other-cache", "no-tag", "bare/_build", "bare/deps", "bare/.mooncakes", "repo/src", "ex"];
  for (const d of found) {
    assert.equal(rebuildableKind(join(p, d)), "found", d);
    assert.equal(await rebuildableSoon(join(p, d)), "found", `${d} (off the thread)`);
  }
  for (const d of not) {
    assert.equal(rebuildableKind(join(p, d)), null, d);
    assert.equal(await rebuildableSoon(join(p, d)), null, `${d} (off the thread)`);
  }
  // (those by name stay so)
  write(join(p, "rs/Cargo.toml"), "x");
  dir("rs/target");
  assert.equal(rebuildableKind(join(p, "rs/target")), "named");
  assert.equal(await rebuildableSoon(join(p, "x/node_modules")), "named");
  // A room's measure lists them, each whole.
  assert.deepEqual((await measureRoom(join(p, "ex"))).rebuild.map(([d]) => d.slice(p.length + 1)).sort(), ["ex/_build", "ex/deps"]);
  rmSync(p, { recursive: true });
});

test("archive cleanup takes one known by what is in it, inside a checkout, only where git ignores it", async () => {
  const p = temp();
  const git = (args: string[]) => execFileSync("git", ["-C", p, ...args]);
  git(["init", "-q"]);
  const TAG = "Signature: 8a477f597d28d172789f06886806bc55\n# This file is a cache directory tag created by cargo.\n";
  const cargo = (d: string) => {
    write(join(p, d, "CACHEDIR.TAG"), TAG);
    write(join(p, d, ".rustc_info.json"), "{}");
  };
  write(join(p, ".gitignore"), "/ignored-out\n_build/\n.mooncakes/\nlogs/\n");
  cargo("ignored-out");
  cargo("kept-out");
  cargo("logs/rs");
  write(join(p, "mix.exs"), "x");
  write(join(p, "_build/dev/x.beam"), "x");
  write(join(p, "deps/jason/mix.exs"), "x");
  write(join(p, "mb-new/moon.mod"), 'name: "demo"\n');
  write(join(p, "mb-new/src/lib/moon.pkg"), "import {}\n");
  write(join(p, "mb-new/_build/a.o"), "x");
  write(join(p, "mb-new/.mooncakes/core/x.mbt"), "x");
  write(join(p, "mb-new/src/lib/sub/_build/b.o"), "x");
  // (by its name, as before: untracked, it goes ignored or not)
  write(join(p, "node_modules/dependency.js"), "x");
  assert.equal(await safeToRemove(join(p, "ignored-out")), true, "ignored by its path");
  assert.equal(await safeToRemove(join(p, "_build")), true, "ignored as a directory");
  assert.equal(await safeToRemove(join(p, "mb-new/_build")), true, "moon.mod _build ignored inside checkout");
  assert.equal(await safeToRemove(join(p, "mb-new/.mooncakes")), true, "moon.mod .mooncakes ignored inside checkout");
  assert.equal(await safeToRemove(join(p, "mb-new/src/lib/sub/_build")), true, "moon.pkg nested _build ignored inside checkout");
  assert.equal(await safeToRemove(join(p, "logs/rs")), true, "in an ignored directory");
  assert.equal(await safeToRemove(join(p, "kept-out")), false, "not ignored: the project's own");
  assert.equal(await safeToRemove(join(p, "deps")), false, "not ignored: the project's own");
  assert.equal(await safeToRemove(join(p, "node_modules")), true);
  // (outside a checkout, it goes)
  const q = temp();
  write(join(q, "out/CACHEDIR.TAG"), TAG);
  write(join(q, "out/.rustc_info.json"), "{}");
  write(join(q, "mb-standalone/moon.mod"), 'name: "demo"\n');
  write(join(q, "mb-standalone/_build/a.o"), "x");
  write(join(q, "mb-standalone/.mooncakes/core/x.mbt"), "x");
  write(join(q, "mb-pkg-only/moon.pkg"), "import {}\n");
  write(join(q, "mb-pkg-only/_build/a.o"), "x");
  assert.equal(await safeToRemove(join(q, "out")), true);
  assert.equal(await safeToRemove(join(q, "mb-standalone/_build")), true);
  assert.equal(await safeToRemove(join(q, "mb-standalone/.mooncakes")), true);
  assert.equal(await safeToRemove(join(q, "mb-pkg-only/_build")), true);
  rmSync(p, { recursive: true });
  rmSync(q, { recursive: true });
});

test("archive cleanup keeps attachments, git and symlink targets", async () => {
  const p = temp();
  write(join(p, "uploads/node_modules/evidence.js"), "x".repeat(100));
  write(join(p, ".git/node_modules/metadata"), "x".repeat(100));
  write(join(p, "app/node_modules/dependency.js"), "x".repeat(100));
  const outside = temp();
  write(join(outside, "node_modules/source"), "x".repeat(100));
  symlinkSync(outside, join(p, "linked"));
  const found = (await measureRoom(p)).rebuild;
  assert.equal(found.length, 1);
  assert.equal(found[0]![0], join(p, "app/node_modules"));
  const data = join(p, "data");
  const workspace = join(data, "sessions/cl/chat/workspace");
  mkdirSync(workspace, { recursive: true });
  assert.equal(roomOf(data, workspace), join(data, "sessions/cl/chat"));
  symlinkSync(outside, join(data, "sessions/cl/escape"));
  mkdirSync(join(outside, "workspace"));
  assert.equal(roomOf(data, join(data, "sessions/cl/escape/workspace")), null);
  rmSync(p, { recursive: true });
  rmSync(outside, { recursive: true });
});

test("archive cleanup keeps tracked files in generated directories", async () => {
  const p = temp();
  const git = (args: string[]) => execFileSync("git", ["-C", p, ...args]);
  git(["init", "-q"]);
  write(join(p, "node_modules/local-source.js"), "x".repeat(100));
  git(["add", "node_modules/local-source.js"]);
  assert.ok(!(await safeToRemove(join(p, "node_modules"))));
  write(join(p, "scratch/node_modules/dependency.js"), "x".repeat(100));
  assert.ok(await safeToRemove(join(p, "scratch/node_modules")));
  rmSync(p, { recursive: true });
});
