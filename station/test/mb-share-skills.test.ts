// A shared skill's files read, hashed and written by the MoonBit program (`--builder memory`, station/mb src/memory
// skills.mbt; the station's share/index.ts) held to the TypeScript it replaced (test/reference/share-skills.ts) on the
// same trees: the same hash, the same files and bytes sent, the same refusal past what may be shared, and the same tree
// written of the same files, a bad path refused alike with nothing changed.
import assert from "node:assert/strict";
import { lstatSync, mkdirSync, readdirSync, readFileSync, readlinkSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { fresh, memoryProgram, skip } from "./memory-program.ts";
import { encodeFiles, MAX_SKILL_BYTES, MAX_SKILL_FILES, readSkill, safePath, skillHash, TooLarge, writeConflict, writeSkill } from "./reference/share-skills.ts";

type Json = any;

/// The same seeded stream of numbers on every machine.
function rng(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/// What the reference says of a skill: as the program's `skillRead` answers, or `{ tooLarge }`, or the failure.
function refRead(dir: string, bytes: boolean): Json {
  try {
    const files = readSkill(dir);
    return { hash: skillHash(files), hasSkillMd: files["SKILL.md"] !== undefined, ...(bytes ? { files: encodeFiles(files) } : {}) };
  } catch (e) {
    if (e instanceof TooLarge) return { tooLarge: true };
    return { failed: true };
  }
}

async function mbRead(dir: string, bytes: boolean): Promise<Json> {
  try {
    const { id: _, ...answer } = await memoryProgram().ask("skillRead", { dir, maxBytes: MAX_SKILL_BYTES, maxFiles: MAX_SKILL_FILES, bytes });
    return answer;
  } catch {
    return { failed: true };
  }
}

/// Both readings of `dir`, hashes alone and with the files, alike (their files compared as sets: an object's order is
/// none of the transport's).
async function sameRead(dir: string, label: string): Promise<Json> {
  for (const bytes of [false, true]) {
    const ref = refRead(dir, bytes);
    const mb = await mbRead(dir, bytes);
    assert.deepEqual(mb, ref, `${label} (bytes: ${bytes})`);
    if (bytes) assert.deepEqual(Object.keys(mb.files ?? {}).sort(), Object.keys(ref.files ?? {}).sort());
  }
  return refRead(dir, true);
}

/// A tree as it is on the disk: each path's kind and content (a link's target), in order.
function tree(dir: string): string[] {
  const out: string[] = [];
  const walk = (at: string, rel: string) => {
    for (const name of readdirSync(at).sort()) {
      const path = join(at, name);
      const r = rel === "" ? name : `${rel}/${name}`;
      const meta = lstatSync(path);
      if (meta.isSymbolicLink()) out.push(`${r} -> ${readlinkSync(path)}`);
      else if (meta.isDirectory()) {
        out.push(`${r}/`);
        walk(path, r);
      } else out.push(`${r} = ${readFileSync(path).toString("hex")}`);
    }
  };
  walk(dir, "");
  return out;
}

/// `files` (path → bytes) written under `dir`.
function make(dir: string, files: Record<string, Buffer | string>) {
  mkdirSync(dir, { recursive: true });
  for (const [path, data] of Object.entries(files)) {
    mkdirSync(join(dir, path, ".."), { recursive: true });
    writeFileSync(join(dir, path), data);
  }
}

test("skillRead: nested, UTF-8 names, empty and binary files, links and conflicts left out, as the reference reads them", { skip }, async () => {
  const root = fresh("share-skills-");
  const dir = join(root, "skill");
  make(dir, {
    "SKILL.md": "# a skill\n",
    "empty.txt": "",
    "bin.dat": Buffer.from([0, 1, 2, 255, 254, 0x80, 0xc0, 0xaf]),
    "a/b/c/deep.md": "deep\n",
    "中文/名字.md": "中文\n",
    "😀/é.md": "x",
    "ｚ.md": "z",
    "Z.md": "Z",
    "a b/c d.md": "spaces",
    "SKILL.conflict-0123456789ab.md": "kept beside",
    "sub/SKILL.conflict-x.md": "kept beside, deeper",
    "sub/SKILL.conflicts.md": "not a conflict",
  });
  mkdirSync(join(dir, "empty-dir"));
  mkdirSync(join(dir, "a", "empty"));
  symlinkSync(join(dir, "SKILL.md"), join(dir, "link.md"));
  symlinkSync(join(dir, "a"), join(dir, "link-dir"));
  symlinkSync(join(root, "nowhere"), join(dir, "dangling"));
  const read = await sameRead(dir, "the tree");
  assert.equal(read.hasSkillMd, true);
  assert.equal(read.files["SKILL.conflict-0123456789ab.md"], undefined);
  assert.equal(read.files["sub/SKILL.conflicts.md"], Buffer.from("not a conflict").toString("base64"));
  assert.equal(read.files["link.md"], undefined);
  // No SKILL.md, nothing at all, no directory there.
  make(join(root, "nomd"), { "README.md": "r" });
  assert.equal((await sameRead(join(root, "nomd"), "no SKILL.md")).hasSkillMd, false);
  mkdirSync(join(root, "none"));
  await sameRead(join(root, "none"), "an empty directory");
  assert.deepEqual(await mbRead(join(root, "gone"), false), { failed: true });
  await sameRead(join(root, "gone"), "no directory");
  writeFileSync(join(root, "a-file"), "x");
  await sameRead(join(root, "a-file"), "a file, not a directory");
});

test("skillRead: 200 files shared, 201 too many; 512 KiB shared, a byte more too large", { skip }, async () => {
  const root = fresh("share-skills-");
  const many = (n: number) => Object.fromEntries(Array.from({ length: n }, (_, i) => [i === 0 ? "SKILL.md" : `f/${String(i).padStart(3, "0")}.md`, `${i}`]));
  make(join(root, "200"), many(200));
  assert.equal((await sameRead(join(root, "200"), "200 files")).tooLarge, undefined);
  make(join(root, "201"), many(201));
  assert.deepEqual(await sameRead(join(root, "201"), "201 files"), { tooLarge: true });
  // (conflicts and links count for nothing)
  make(join(root, "200c"), { ...many(200), "SKILL.conflict-a.md": "x" });
  symlinkSync(join(root, "200c", "SKILL.md"), join(root, "200c", "l"));
  assert.equal((await sameRead(join(root, "200c"), "200 files, a conflict and a link")).tooLarge, undefined);
  make(join(root, "max"), { "SKILL.md": "a", "big.bin": Buffer.alloc(MAX_SKILL_BYTES - 1, 7) });
  assert.equal((await sameRead(join(root, "max"), "512 KiB")).tooLarge, undefined);
  make(join(root, "max1"), { "SKILL.md": "ab", "big.bin": Buffer.alloc(MAX_SKILL_BYTES - 1, 7) });
  assert.deepEqual(await sameRead(join(root, "max1"), "512 KiB and a byte"), { tooLarge: true });
  make(join(root, "one"), { "SKILL.md": Buffer.alloc(MAX_SKILL_BYTES + 1, 1) });
  assert.deepEqual(await sameRead(join(root, "one"), "one file past it"), { tooLarge: true });
});

/// What writing `files` makes of a skill that was `before`: the reference's and the program's trees, or each failure.
async function sameWrite(root: string, before: Record<string, string> | null, files: Record<string, string>, label: string) {
  const refDir = join(root, "ref", "skill");
  const mbDir = join(root, "mb", "skill");
  for (const d of [refDir, mbDir]) if (before !== null) make(d, before);
  let refError: string | null = null;
  try {
    writeSkill(refDir, files);
  } catch (e) {
    refError = (e as Error).message;
  }
  let mbError: string | null = null;
  try {
    await memoryProgram().ask("skillWrite", { dir: mbDir, files });
  } catch (e) {
    mbError = (e as Error).message;
  }
  assert.equal(mbError, refError, `${label}: refused alike`);
  if (refError === null) assert.deepEqual(tree(join(root, "mb")), tree(join(root, "ref")), `${label}: the same tree`);
  else {
    // Nothing of the skill changed (the reference may leave its temporary directory beside it; the program writes none).
    assert.deepEqual(before === null ? [] : tree(mbDir), before === null ? [] : tree(refDir), `${label}: the skill as it was`);
    assert.deepEqual(readdirSync(join(root, "mb")).filter((n) => n.includes(".tmp-")), [], `${label}: no temporary left`);
  }
}

test("skillWrite: the same tree written in place of the one before; a bad path refused alike, nothing changed", { skip }, async () => {
  const b64 = (s: string | Buffer) => Buffer.from(s).toString("base64");
  let n = 0;
  const next = () => fresh(`share-write-${n++}-`);
  const before = { "SKILL.md": "old", "old/gone.md": "gone", "SKILL.conflict-x.md": "c" };
  await sameWrite(next(), before, { "SKILL.md": b64("new\n"), "a/b/c.md": b64("c"), "中文.md": b64("中"), "bin": b64(Buffer.from([0, 255])), "empty": "" }, "a skill replaced");
  await sameWrite(next(), null, { "SKILL.md": b64("first") }, "a skill where there was none");
  await sameWrite(next(), before, {}, "no files");
  // Base64 as Node takes it: no padding, URL-safe, what is none passed over.
  await sameWrite(next(), null, { "a": "YQ", "b": "-_8", "c": "Y Q = =", "d": "YWJj=ZA", "e": "*" }, "base64 as Node reads it");
  for (const bad of ["../escape", "/abs", "a//b", "./x", "a/./b", "a/", "", "a/../b", "C:\\x", "a\\..\\b", "..", "."]) {
    await sameWrite(next(), before, { "SKILL.md": b64("new"), [bad]: b64("x") }, `the path ${JSON.stringify(bad)} (${safePath(bad) ? "safe" : "refused"} here)`);
  }
});

test("skillConflict: an edit on an older copy kept beside the skill as the reference kept it", { skip }, async () => {
  const root = fresh("share-conflict-");
  for (const [peer, content] of [["0123456789abcdef0123", Buffer.from("late\n")], ["ab", Buffer.from([0, 1, 255])], ["中文站点名字很长很长很长很长", Buffer.from("")]] as const) {
    make(join(root, "ref"), { "SKILL.md": "s" });
    make(join(root, "mb"), { "SKILL.md": "s" });
    writeConflict(join(root, "ref"), peer, content.toString("base64"));
    await memoryProgram().ask("skillConflict", { dir: join(root, "mb"), peer, content: content.toString("base64") });
    assert.deepEqual(tree(join(root, "mb")), tree(join(root, "ref")), peer);
  }
});

test("random trees: the same hash and files as the reference, written back the same", { skip }, async () => {
  const seeds = Number(process.env.SHARE_SKILLS_RANDOM_SEEDS ?? 40);
  // Names whose order is JavaScript's, not MoonBit's (its own compares lengths first) nor the bytes' (UTF-8 puts an
  // astral character after U+FFxx; UTF-16 before).
  const NAMES = ["SKILL.md", "a", "B", "b", "ab", "a.md", "Ab", "aa", "z", "_", "-", "1", "10", "2", "é", "e", "ｚ", "😀", "中", "中文", "\u{ff5e}", "\u{10000}", "a b", "x.y.z", "SKILL.conflict-q.md", "SKILL.md.bak"];
  for (let seed = 1; seed <= seeds; seed++) {
    const r = rng(seed);
    const root = fresh(`share-random-${seed}-`);
    const dir = join(root, "skill");
    const files: Record<string, Buffer> = {};
    const count = Math.floor(r() * 30);
    for (let i = 0; i < count; i++) {
      const depth = Math.floor(r() * 3);
      const parts = Array.from({ length: depth + 1 }, () => NAMES[Math.floor(r() * NAMES.length)]!);
      const path = parts.join("/");
      // (a name both a file and a directory, or one file twice where case is not told apart: the first one made wins)
      const low = path.toLowerCase();
      if (Object.keys(files).some((p) => (p = p.toLowerCase()) === low || p.startsWith(`${low}/`) || low.startsWith(`${p}/`))) continue;
      const size = r() < 0.2 ? 0 : Math.floor(r() * (r() < 0.1 ? 40_000 : 200));
      files[path] = Buffer.from(Array.from({ length: size }, () => Math.floor(r() * 256)));
    }
    make(dir, files);
    if (r() < 0.3) symlinkSync(join(dir, "nowhere"), join(dir, "link"));
    const read = await sameRead(dir, `seed ${seed}`);
    if (read.tooLarge || read.failed) continue;
    await sameWrite(join(root, "back"), { "SKILL.md": "before" }, read.files, `seed ${seed} written back`);
    // And what was written reads back to the same hash.
    assert.equal((await mbRead(join(root, "back", "mb", "skill"), false)).hash, read.hash, `seed ${seed} read back`);
  }
});
