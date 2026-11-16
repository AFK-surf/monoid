// The MoonBit program's gathering and placing of a retired station's files (`--builder replica-carry`, station/mb's
// src/replica/carry.mbt, started by src/replica/carry.ts) held to the worker thread's from before (carry-reference.ts)
// on the same station: the same lists byte for byte, the same index and answers (a checkout with its own repository and
// one inside it, a linked worktree with commits no remote has, links, what a build makes again, transcripts of each
// runtime and a put-away one, a room not the station's own, files it cannot read, names JavaScript and the disk sort
// apart), a gathering again taking a file's hash from its list before; and the same files put on two stations, by
// their bytes, modes, times and links, what they made, kept and put aside.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, cpSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, readlinkSync, realpathSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join, relative } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import { MbProcess, mbReaderBinary } from "../src/read/mb-reader.ts";
import { claudeProject } from "../src/read/transcript.ts";
import { type CarryIndex, type Gathered, gatherSoon, inProgram, placeSoon, previewSoon, sizesSoon } from "../src/replica/carry.ts";
import { Store } from "../src/store/store.ts";
import { gather, linesOf, place, preview, sizes } from "./carry-reference.ts";
import { HOME, OTHER, chat, dataDir as madeDir, station as madeStation } from "./replica-fakes.ts";

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : false;

// What ends this file's process, said as it ends (scripts/check.sh shows each `as it ended:` line of a failing slice):
// CI's Linux slice failed this file whole at 299b40fd64 and b6631c119d, every line of its own out of the tail, nothing
// said why. An error no test took, by where it came from (a monitor: what Node and its runner do with it is unchanged),
// and a process ending other than 0 with what still held it.
const endSaid = (what: string) => process.stderr.write(`test/mb-replica-carry.test.ts: as it ended: ${what}\n`);
const told = (error: unknown) => (error instanceof Error ? (error.stack ?? error.message) : String(error)).split("\n").slice(0, 12).join(" | ");
process.on("uncaughtExceptionMonitor", (error, origin) => endSaid(`${origin}: ${told(error)}`));
// (the runner takes a rejection itself, so one more listener changes nothing of what it does with it)
process.on("unhandledRejection", (reason) => endSaid(`unhandledRejection: ${told(reason)}`));
process.on("exit", (code) => {
  if (code === 0 && !process.exitCode) return;
  const held = (process as unknown as { _getActiveHandles(): { constructor?: { name?: string }; pid?: number; spawnargs?: string[] }[] })._getActiveHandles()
    .map((h) => (h.constructor?.name === "ChildProcess" ? `ChildProcess ${h.pid} ${(h.spawnargs ?? []).join(" ").slice(0, 120)}` : (h.constructor?.name ?? "?")));
  endSaid(`exit ${code} (exitCode ${process.exitCode ?? "unset"}), program ${binary ?? "none"}, held: ${held.join(", ") || "nothing"}`);
});
// What this file makes on the disk, each directory, so that its last test holds that nothing of it is left its station
// could not remove (CI's Linux slice, 0ece7318d1: setup-env.mjs's exit hook failed removing the run's directory, a
// directory of no permission left in it).
const mine: string[] = [];
const dataDir = (name?: string) => {
  const dir = madeDir(name);
  mine.push(dir);
  return dir;
};
const station = (...args: Parameters<typeof madeStation>) => {
  const made = madeStation(...args);
  mine.push(made.data);
  return made;
};
// (a bundle made twice of the same commits is the same bytes only when git packs it on one thread)
Object.assign(process.env, { GIT_CONFIG_COUNT: "1", GIT_CONFIG_KEY_0: "pack.threads", GIT_CONFIG_VALUE_0: "1" });
const gitEnv = () => ({ ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@x", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@x", GIT_CONFIG_NOSYSTEM: "1", HOME: dataDir("gh") });
const git = (dir: string, ...args: string[]) => execFileSync("git", ["-C", dir, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], env: gitEnv() }).trim();
/// Whether this process may read whatever it likes (root): a file it cannot read is then none.
const root = process.getuid?.() === 0;

/// A station with all a gathering meets.
function world() {
  const made = station();
  const { data, db, store } = made;
  const wsOf = (key: string) => (store.getSession(key) as { workspace: string }).workspace;
  const aws = wsOf("chat:a");
  // its files, names JavaScript's sort and the bytes' order put apart, links of each kind
  for (const name of ["notes.md", "Z.txt", "a.txt", "é.txt", "\u{1F600}.txt", "Ａ.txt", "cached.txt"]) writeFileSync(join(aws, name), `${name}\n`);
  chmodSync(join(aws, "a.txt"), 0o750);
  utimesSync(join(aws, "notes.md"), 1_700_000_000.123456, 1_700_000_000.123456);
  utimesSync(join(aws, "cached.txt"), 1_700_000_100, 1_700_000_100);
  symlinkSync(join(aws, "uploads", "pic.png"), join(aws, "pic-link"));
  symlinkSync("notes.md", join(aws, "rel-link"));
  symlinkSync(join(aws, "nothing"), join(aws, "dangling"));
  // what a build or an install makes again, and what only looks like it
  for (const [dir, beside] of [["node_modules", null], [".next", null], ["__pycache__", null], ["target", "Cargo.toml"], ["build", "build.gradle"], [".gradle", "settings.gradle"]] as const) {
    const at = join(aws, "proj", dir);
    mkdirSync(at, { recursive: true });
    writeFileSync(join(at, "made.bin"), "made again");
    if (beside !== null) writeFileSync(join(aws, "proj", beside), "a build's");
  }
  mkdirSync(join(aws, "lone", "target"), { recursive: true });
  writeFileSync(join(aws, "lone", "target", "kept.txt"), "no Cargo.toml beside it: kept");
  // (by what is in them or beside them: Elixir's and MoonBit's, Xcode's derived data and a Cargo target of any name near
  // the room's top, the same deep (gone), and what only looks like them (kept))
  const put = (path: string, text = "made again") => (mkdirSync(join(path, ".."), { recursive: true }), writeFileSync(path, text));
  put(join(aws, "ex", "mix.exs"), "x");
  put(join(aws, "ex", "_build", "dev", "x.beam"));
  put(join(aws, "ex", "deps", "jason", "lib.ex"));
  put(join(aws, "mb", "moon.mod.json"), "{}");
  put(join(aws, "mb", "_build", "main.wasm"));
  put(join(aws, "mb", ".mooncakes", "x.mbt"));
  put(join(aws, "bare", "_build", "kept-too.txt"), "a bare name: kept");
  put(join(aws, "bare", "deps", "kept.txt"), "a bare name: kept");
  for (const at of ["ios-dd", "a/b/c/d/dd"]) {
    put(join(aws, at, "Build", "Products", "app"));
    put(join(aws, at, "Build", "Intermediates.noindex", "o"));
  }
  put(join(aws, "only-products", "Build", "Products", "kept.app"), "products alone: kept");
  put(join(aws, "rs-out", "CACHEDIR.TAG"), "Signature: 8a477f597d28d172789f06886806bc55\n# This file is a cache directory tag created by cargo.\n");
  put(join(aws, "rs-out", ".rustc_info.json"), "{}");
  put(join(aws, "rs-out", "debug", "app"));
  put(join(aws, "other-cache", "CACHEDIR.TAG"), "Signature: 8a477f597d28d172789f06886806bc55\n# another program's\n");
  put(join(aws, "other-cache", ".rustc_info.json"), "{}");
  // what it cannot read
  mkdirSync(join(aws, "closed"));
  writeFileSync(join(aws, "closed", "in.txt"), "behind a closed door");
  writeFileSync(join(aws, "secret.txt"), "not for this process");
  chmodSync(join(aws, "secret.txt"), 0o000);
  chmodSync(join(aws, "closed"), 0o000);
  // a checkout with its own repository (another branch not pushed, a file changed, one untracked, one ignored, an
  // install's output), a repository inside it
  const remote = join(dataDir("remote"), "r.git");
  mkdirSync(remote, { recursive: true });
  git(remote, "init", "-q", "--bare", "-b", "main");
  const seed = dataDir("seed");
  git(seed, "init", "-q", "-b", "main");
  writeFileSync(join(seed, "a.txt"), "one\n");
  writeFileSync(join(seed, ".gitignore"), "ignored.log\n");
  git(seed, "add", "-A");
  git(seed, "commit", "-q", "-m", "first");
  git(seed, "remote", "add", "origin", remote);
  git(seed, "push", "-q", "origin", "main");
  const repo = join(aws, "repo");
  execFileSync("git", ["clone", "-q", "-b", "main", remote, repo], { stdio: "ignore", env: gitEnv() });
  git(repo, "checkout", "-q", "-b", "work");
  writeFileSync(join(repo, "b.txt"), "mine\n");
  git(repo, "add", "b.txt");
  git(repo, "commit", "-q", "-m", "not pushed");
  writeFileSync(join(repo, "a.txt"), "changed\n");
  writeFileSync(join(repo, "new.txt"), "untracked\n");
  writeFileSync(join(repo, "ignored.log"), "ignored\n");
  mkdirSync(join(repo, "node_modules", "x"), { recursive: true });
  writeFileSync(join(repo, "node_modules", "x", "i.js"), "built\n");
  const inner = join(repo, "inner");
  mkdirSync(inner);
  git(inner, "init", "-q", "-b", "main");
  writeFileSync(join(inner, "i.txt"), "inner\n");
  git(inner, "add", "-A");
  git(inner, "commit", "-q", "-m", "inner");
  // a linked worktree of the station's clone: a branch pushed, then a commit no remote has
  const main = join(data, "repos", "r");
  mkdirSync(join(data, "repos"), { recursive: true });
  execFileSync("git", ["clone", "-q", remote, main], { stdio: "ignore", env: gitEnv() });
  const wt = join(aws, "wt");
  git(main, "worktree", "add", "-q", "-b", "feat", wt);
  writeFileSync(join(wt, "x.txt"), "pushed\n");
  git(wt, "add", "x.txt");
  git(wt, "commit", "-q", "-m", "x");
  git(wt, "push", "-q", "origin", "feat");
  writeFileSync(join(wt, "y.txt"), "never pushed\n");
  git(wt, "add", "y.txt");
  git(wt, "commit", "-q", "-m", "y");
  // the archived chat's room: its packed workspace, its lock and what is being written stay
  const room = join(data, "sessions", "chat", "chat:b");
  mkdirSync(room, { recursive: true });
  writeFileSync(join(room, "workspace.tar.zst"), "packed");
  writeFileSync(join(room, "archive.lock"), "");
  writeFileSync(join(room, "workspace.tar.zst.writing"), "half");
  // chats of each runtime, one in a person's project, one in the data directory itself
  chat(store, data, "chat:c", null, 1);
  chat(store, data, "chat:d", null, 1);
  for (const key of ["chat:c", "chat:d"]) mkdirSync(wsOf(key), { recursive: true });
  const project = join(data, "elsewhere", "proj");
  mkdirSync(project, { recursive: true });
  writeFileSync(join(project, "mine.txt"), "a person's");
  store.insertSession({ key: "chat:out", connect: "chat", runtime: "claude", profile: "cc", workspace: project, token: "t-out", createdAt: 1, lastActiveAt: 1, ws: null });
  store.insertSession({ key: "chat:data", connect: "chat", runtime: "claude", profile: "cc", workspace: data, token: "t-data", createdAt: 1, lastActiveAt: 1, ws: null });
  store.setRuntimeSessionId("chat:a", "run-1");
  store.setRuntimeSessionId("chat:b", "run-b");
  store.close();
  const d = new DatabaseSync(db);
  d.exec("UPDATE sessions SET runtime = 'codex' WHERE key = 'chat:c'; UPDATE sessions SET runtime = 'dsh', runtime_session_id = 'dsh-1' WHERE key = 'chat:d'");
  const run = d.prepare("INSERT INTO runtime_sessions (session_key, id, profile, at, runtime) VALUES (?, ?, ?, ?, ?)");
  run.run("chat:a", "run-0", "cc", 1, null);
  run.run("chat:a", "run-1", "cc", 2, "claude");
  run.run("chat:c", "cdx-1", null, 1, "codex");
  run.run("chat:c", "gone-1", null, 2, "nothing-such");
  // an Antigravity CLI conversation: what its CLI keeps of it in its profile's home goes too
  run.run("chat:c", "agy-1", "lent-g", 3, "agy");
  run.run("chat:c", "../agy-2", "lent-g", 4, "agy");
  d.close();
  const cli = join(data, "homes", "lent-g", "agy", ".gemini", "antigravity-cli");
  for (const dir of ["conversations", "annotations", "brain/agy-1/notes", "brain/other-1", "implicit"]) mkdirSync(join(cli, dir), { recursive: true });
  writeFileSync(join(cli, "conversations", "agy-1.db"), "trajectory");
  writeFileSync(join(cli, "conversations", "agy-1.db-wal"), "wal");
  writeFileSync(join(cli, "conversations", "agy-1.db-shm"), "shm");
  writeFileSync(join(cli, "conversations", "other-1.db"), "another's");
  writeFileSync(join(cli, "annotations", "agy-1.pbtxt"), "seen");
  writeFileSync(join(cli, "brain", "agy-1", "notes", "plan.md"), "plan");
  writeFileSync(join(cli, "brain", "other-1", "plan.md"), "another's");
  writeFileSync(join(cli, "implicit", "agy-1.pb"), "the CLI's own");
  writeFileSync(join(cli, "antigravity-oauth-token"), "a sign-in");
  const claude = join(data, "transcripts", "claude", claudeProject(aws)!);
  mkdirSync(join(claude, "run-1", "subagents"), { recursive: true });
  writeFileSync(join(claude, "run-0.jsonl"), '{"type":"user","n":0}\n');
  writeFileSync(join(claude, "run-1.jsonl"), '{"type":"user"}\n');
  writeFileSync(join(claude, "run-1", "subagents", "agent-x.jsonl"), '{"type":"agent"}\n');
  const bProject = join(data, "transcripts", "claude", claudeProject(wsOf2(data, "chat:b"))!);
  mkdirSync(bProject, { recursive: true });
  writeFileSync(join(bProject, "run-b.jsonl.zst"), "put away");
  const days = join(data, "transcripts", "codex", "2026", "11", "15");
  mkdirSync(days, { recursive: true });
  writeFileSync(join(days, "rollout-2026-11-15T00-00-00-cdx-1.jsonl"), '{"codex":1}\n');
  const dsh = join(data, "transcripts", "dsh", "x", "dsh-1");
  mkdirSync(dsh, { recursive: true });
  writeFileSync(join(dsh, "session.v1.jsonl"), "v1\n");
  writeFileSync(join(dsh, "session.v2.jsonl"), "v2\n");
  // the agent home: its own files go, the station's own skills, a sync's, a hidden one and a link do not
  const agent = join(dataDir("home"), "agent");
  for (const dir of ["skills/mine/sub", "skills/mine/node_modules", "skills/.hidden", "skills/synced", "skills/stillfail-chats"]) mkdirSync(join(agent, dir), { recursive: true });
  writeFileSync(join(agent, "MEMORY.md"), "- a rule\n");
  writeFileSync(join(agent, "presets.json"), "[]");
  writeFileSync(join(agent, "skills", "mine", "SKILL.md"), "mine");
  writeFileSync(join(agent, "skills", "mine", "sub", "more.md"), "more");
  writeFileSync(join(agent, "skills", "mine", "node_modules", "x.js"), "made");
  writeFileSync(join(agent, "skills", ".hidden", "SKILL.md"), "hidden");
  writeFileSync(join(agent, "skills", "synced", "SKILL.md"), "synced");
  writeFileSync(join(agent, "skills", "stillfail-chats", "SKILL.md"), "the station's");
  writeFileSync(join(agent, "skills", "loose.md"), "not a skill");
  symlinkSync(join(agent, "skills", "mine"), join(agent, "skills", "linked"));
  return { data, db, aws, agent, wt };
}

/// A session's workspace, read from the database (the store closed).
function wsOf2(data: string, key: string): string {
  return join(data, "sessions", "chat", key, "workspace");
}

const indexOf = (g: Gathered) => JSON.parse(readFileSync(g.index, "utf8")) as CarryIndex;

/// What a gathering wrote, its scratch said as `<scratch>`: its answer, its index's text and each list's.
function written(g: Gathered, scratch: string) {
  const index = readFileSync(g.index, "utf8");
  const lists = indexOf(g).sessions.map((s) => readFileSync(s.at, "utf8"));
  const agent = indexOf(g).agent;
  if (agent !== null && agent !== undefined) lists.push(readFileSync(agent.at, "utf8"));
  const as = (text: string) => text.split(scratch).join("<scratch>");
  return { answer: as(JSON.stringify(g)), index: as(index), lists };
}

/// The two gatherings of the same station, each in a scratch of its own, held to each other.
async function bothGather(data: string, db: string, ws: string, home: boolean, agent: string | null = null, keys: string[] | null = null, scratches?: [string, string]) {
  const [r, m] = scratches ?? [dataDir("scratch-ref"), dataDir("scratch-mb")];
  const ref = gather(data, db, ws, home, r, agent, keys);
  const mb = await gatherSoon(data, db, ws, home, m, undefined, agent, keys);
  const a = written(ref, r);
  const b = written(mb, m);
  assert.deepEqual(b.answer, a.answer, "the same answer");
  assert.equal(b.index, a.index, "the same index, byte for byte");
  assert.deepEqual(b.lists, a.lists, "the same lists, byte for byte");
  return { ref, mb, scratches: [r, m] as [string, string] };
}

/// What a gathering names, as the station it goes to holds it once sent: each file's bytes, each list and bundle.
function sent(g: Gathered): string {
  const dir = join(dataDir("sent"), "files");
  mkdirSync(dir, { recursive: true });
  const index = indexOf(g);
  for (const s of index.sessions) {
    cpSync(s.at, join(dir, s.list));
    for (const line of linesOf(s.at)) {
      const f = JSON.parse(line);
      if ("hash" in f && !existsSync(join(dir, f.hash))) cpSync(f.path, join(dir, f.hash));
    }
  }
  for (const [hash, path] of Object.entries(index.bundles)) cpSync(path, join(dir, hash));
  return dir;
}

/// Every path under `dir` (the root said ""), as a placing left it: a file's bytes, mode, time and how many names it
/// has, a link's target (`dir` said as `<to>`), a folder. The program's shell's own folder (`shell`, which every
/// program of the station's keeps there) aside.
function tree(dir: string): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (at: string) => {
    for (const name of readdirSync(at).sort()) {
      if (at === dir && name === "shell") continue;
      const path = join(at, name);
      const st = lstatSync(path);
      // (a Claude project's name is its directory's path: said as <project> for either station)
      let rel = relative(dir, path);
      for (const at of [realpathSync(dir), dir]) rel = rel.split(claudeProject(at)!).join("<project>");
      if (st.isSymbolicLink()) out[rel] = `link ${readlinkSync(path).split(dir).join("<to>")}`;
      else if (st.isDirectory()) {
        out[rel] = "dir";
        walk(path);
      } else out[rel] = `file ${(st.mode & 0o777).toString(8)} ${st.mtimeMs} ${st.nlink} ${readFileSync(path).toString("hex")}`;
    }
  };
  walk(dir);
  return out;
}

const said = (path: string, to: string) => (existsSync(path) ? readFileSync(path, "utf8").split(to).join("<to>") : null);

test("the program gathers what the worker thread gathered: the same lists, index and answer, a file of the gathering before taken by its size and time", { skip }, async () => {
  const { data, db, aws, agent, wt } = world();
  const first = await bothGather(data, db, HOME, true, agent);
  const index = indexOf(first.mb);
  // (what it is held to holds what a gathering is: that the two agree on nothing would say nothing)
  assert.equal(index.gits.length, 1);
  assert.equal(index.gits[0]!.dir, wt);
  assert.notEqual(index.gits[0]!.bundle, null, "the commit no remote has, bundled");
  assert.deepEqual([...index.skipped].sort(), ["chat:data", "chat:out"]);
  assert.ok(index.agent !== null && index.agent!.files === 4, "MEMORY.md, presets.json and mine's two");
  if (!root) {
    assert.equal(first.mb.unreadableCount, 2);
    assert.deepEqual(first.mb.unreadable, [join(aws, "closed"), join(aws, "secret.txt")]);
  }
  const listed = indexOf(first.mb).sessions.flatMap((s) => [...linesOf(s.at)].map((l) => JSON.parse(l).path as string));
  for (const want of ["\u{1F600}.txt", "run-1/subagents/agent-x.jsonl", "run-b.jsonl.zst", "rollout-2026-11-15T00-00-00-cdx-1.jsonl", "session.v2.jsonl", "lone/target/kept.txt", "repo/.git/HEAD", "repo/inner/i.txt", "wt/y.txt", "workspace.tar.zst", "pic-link", "dangling", "conversations/agy-1.db", "conversations/agy-1.db-wal", "annotations/agy-1.pbtxt", "brain/agy-1/notes/plan.md"]) {
    assert.ok(listed.some((p) => p.endsWith(want)), want);
  }
  for (const not of ["made.bin", "ignored.log", "node_modules", "archive.lock", ".writing", "mine.txt", "session.v1.jsonl", "ex/_build", "ex/deps", "mb/_build", "mb/.mooncakes", "ios-dd/", "rs-out/", "agy-1.db-shm", "other-1", "implicit", "oauth", "agy-2"]) assert.ok(!listed.some((p) => p.includes(not)), not);
  for (const kept of ["bare/_build/kept-too.txt", "bare/deps/kept.txt", "a/b/c/d/dd/Build/Products/app", "only-products/Build/Products/kept.app", "other-cache/.rustc_info.json"]) assert.ok(listed.some((p) => p.endsWith(kept)), kept);
  assert.ok(!listed.includes(join(wt, ".git")), "a linked worktree's .git is made again there, not carried");
  // JavaScript's order, not the bytes': 😀 (U+D83D…) before Ａ (U+FF21)
  assert.ok(listed.indexOf(join(aws, "\u{1F600}.txt")) < listed.indexOf(join(aws, "Ａ.txt")));

  // Again, in the same scratches: a file changed is hashed again; one whose size and time are as before is not.
  writeFileSync(join(aws, "cached.txt"), "CACHED.TXT\n");
  utimesSync(join(aws, "cached.txt"), 1_700_000_100, 1_700_000_100);
  writeFileSync(join(aws, "notes.md"), "changed since\n");
  const again = await bothGather(data, db, HOME, true, agent, null, first.scratches);
  const line = [...linesOf(indexOf(again.mb).sessions.find((s) => s.key === "chat:a")!.at)].map((l) => JSON.parse(l)).find((f) => f.path === join(aws, "cached.txt"));
  assert.equal(line.hash, createHash("sha256").update("cached.txt\n").digest("hex"), "its hash from the list before");
  assert.ok(again.mb.files === first.mb.files);
  chmodSync(join(aws, "closed"), 0o755);
  chmodSync(join(aws, "secret.txt"), 0o644);
});

test("the program sizes what the worker thread's walk would gather (move/sizes.ts): each session's bytes, files, places and whether all of it was walked, bounded or not; the other side's by places", { skip }, async () => {
  const { data, db } = world();
  const keys = ["chat:a", "chat:out", "chat:none"];
  for (const most of [500_000, 7]) {
    const ref = sizes(data, db, keys, { most });
    const mb = await sizesSoon(data, db, keys, { most });
    assert.deepEqual(mb, ref, `the same sizes at most ${most} entries a session`);
    if (most === 7) assert.ok(mb.some((x) => !x.complete), "the bound reached");
    // (the other side's: what is at the same places)
    const places = ref.map((x) => ({ key: x.key, room: x.room, transcripts: x.transcripts }));
    assert.deepEqual(await sizesSoon(data, "", [], { most, places }), sizes(data, "", [], { most, places }), "the same, by places");
  }
  // (what the world closed opened again, as the other tests do)
  chmodSync(join(wsOf2(data, "chat:a"), "closed"), 0o755);
  chmodSync(join(wsOf2(data, "chat:a"), "secret.txt"), 0o644);
});

test("the program gathers a chat handed over alone, another workspace's, and counts a preview as the worker thread did", { skip }, async () => {
  const { data, db } = world();
  await bothGather(data, db, HOME, true, null, ["chat:a", "chat:out", "chat:none"]);
  await bothGather(data, db, OTHER, false);
  for (const [ws, home] of [[HOME, true], [OTHER, false], ["nowhere", false]] as const) assert.deepEqual(await previewSoon(data, db, ws, home), preview(data, db, ws, home));
  chmodSync(join(wsOf2(data, "chat:a"), "closed"), 0o755);
});

test("the program puts in what the worker thread put: the same files, modes, times and links, linked to what was sent or copied; kept, put aside and made as it did", { skip }, async () => {
  const { data, db, agent } = world();
  chmodSync(join(wsOf2(data, "chat:a"), "closed"), 0o755);
  chmodSync(join(wsOf2(data, "chat:a"), "secret.txt"), 0o644);
  // two paths of the same bytes (the second copied, not linked), a path outside sessions and transcripts (put nowhere),
  // a file whose bytes were not sent
  const aws = wsOf2(data, "chat:a");
  writeFileSync(join(aws, "twin.txt"), "notes.md\n");
  const g = await gatherSoon(data, db, HOME, true, dataDir("scratch"), undefined, agent);
  const files = sent(g);
  const list = join(files, indexOf(g).sessions.find((s) => s.key === "chat:a")!.list);
  const extra = [
    { path: join(data, "station.key"), hash: "0".repeat(64), size: 3, mode: 0o600, mtimeMs: 1 },
    { path: join(aws, "unsent.txt"), hash: "1".repeat(64), size: 3, mode: 0o644, mtimeMs: 1 },
  ];
  writeFileSync(join(files, "0".repeat(64)), "key");
  writeFileSync(list, readFileSync(list, "utf8") + extra.map((f) => `${JSON.stringify(f)}\n`).join(""));
  const [toR, toM] = [dataDir("to-ref"), dataDir("to-mb")];
  const [fromR, fromM] = [dataDir("from-ref"), dataDir("from-mb")];
  cpSync(files, fromR, { recursive: true, preserveTimestamps: true });
  cpSync(files, fromM, { recursive: true, preserveTimestamps: true });
  const side = (to: string, from: string) => ({ to, from, made: join(dataDir("made"), "made.txt"), aside: join(dataDir("aside"), "aside"), placed: join(dataDir("placed"), "placed.txt") });
  const r = side(toR, fromR);
  const m = side(toM, fromM);
  const same = (step: string) => {
    assert.deepEqual(tree(toM), tree(toR), `${step}: the same files put`);
    assert.deepEqual(tree(fromM), tree(fromR), `${step}: what was sent linked as the same`);
    assert.equal(said(m.made, toM), said(r.made, toR), `${step}: the same made`);
    assert.equal(said(m.placed, toM), said(r.placed, toR), `${step}: the same placed`);
    const asideOf = (s: typeof r) => (said(join(s.aside, "list.txt"), s.to) ?? "").split("\n").map((l) => l.split("\t")[0]);
    assert.deepEqual(asideOf(m), asideOf(r), `${step}: the same put aside`);
  };
  const both = async (step: string, opts: { made?: boolean; aside?: boolean; placed?: boolean; projects?: boolean } = {}) => {
    const run = (s: typeof r) => [s.to, g.index, s.from, opts.made ? s.made : null, opts.aside ? s.aside : null, opts.placed ? s.placed : null, opts.projects === true] as const;
    const a = place(...run(r));
    const b = await placeSoon(...run(m));
    assert.deepEqual(b, a, `${step}: the same answer`);
    same(step);
    return b;
  };
  const first = await both("first", { made: true, aside: true, placed: true });
  assert.ok(first.placed > 0 && first.missing === 1, JSON.stringify(first));
  assert.equal(existsSync(join(toM, "station.key")), false, "nothing outside sessions and transcripts");
  assert.equal(readFileSync(join(toM, "homes", "lent-g", "agy", ".gemini", "antigravity-cli", "conversations", "agy-1.db"), "utf8"), "trajectory", "an Antigravity CLI conversation where its profile's CLI keeps it");
  // again: what the placing put is known, not looked at; without its file of what it put, found the same by its bytes
  assert.equal((await both("again", { made: true, aside: true, placed: true })).placed, 0);
  assert.equal((await both("again, looked at")).placed, 0);
  // a file changed there and a link pointed elsewhere: put back, what was there put aside the first time
  for (const to of [toR, toM]) {
    const there = join(to, relative(data, aws));
    // (a file of its own: written in place it would write what was sent, linked to it)
    rmSync(join(there, "notes.md"));
    writeFileSync(join(there, "notes.md"), "changed there, a size of its own\n");
    utimesSync(join(there, "notes.md"), 1_700_000_200, 1_700_000_200);
    rmSync(join(there, "rel-link"));
    symlinkSync("a.txt", join(there, "rel-link"));
  }
  assert.equal((await both("replaced", { made: true, aside: true })).placed, 2);
  // a chat handed over: its Claude transcripts under its room's project there
  await both("projects", { projects: true });
});

test("a gathering called off is answered at once, its program ended; one called off before it began starts none; one answered has ended as it is", { skip }, async () => {
  const made = station();
  made.store.close();
  // (this station's: each program says its shell's folder, in the data directory)
  const programs = () => MbProcess.live().filter((p) => p.args.includes("replica-carry") && p.args.includes(join(made.data, "shell"))).length;
  const before = new AbortController();
  before.abort();
  await assert.rejects(inProgram({ op: "gather", dataDir: made.data }, before.signal, "/no/such/program"), /called off/, "none started");
  assert.equal(programs(), 0);
  const c = new AbortController();
  const going = gatherSoon(made.data, made.db, HOME, true, dataDir("scratch"), c.signal);
  assert.equal(programs(), 1);
  c.abort();
  await assert.rejects(going, /called off/);
  // (settled only once it has ended: nothing of it left running as its caller goes on, setup-env.mjs's leftover)
  assert.equal(programs(), 0, "the program called off has ended as it is answered");
  await gatherSoon(made.data, made.db, HOME, true, dataDir("scratch-2"));
  assert.equal(programs(), 0, "the program that answered has ended as its answer is given");
});

test("nothing this file made is left that its station could not remove: every directory open to its owner", () => {
  // (a directory its owner cannot write or search keeps what is in it: Linux's rm of the run's directory failed on
  // one, the fixture's `closed` left at 0 by a test; a room placed so could not be dropped or deleted either)
  const closed: string[] = [];
  const walk = (dir: string) => {
    const st = lstatSync(dir);
    if (!st.isDirectory()) return;
    if ((st.mode & 0o700) !== 0o700) return void closed.push(`${dir} (${(st.mode & 0o777).toString(8)})`);
    for (const name of readdirSync(dir)) walk(join(dir, name));
  };
  for (const dir of mine) if (existsSync(dir)) walk(dir);
  assert.deepEqual(closed, [], "every directory this file made open to its owner");
});
