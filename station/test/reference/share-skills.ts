// The TypeScript the station read, hashed and wrote a shared skill's files with on its own thread (station/src/share/
// index.ts) before they moved to the MoonBit program (station/mb src/memory skills.mbt, reader `--builder memory`),
// kept for the tests to compare the program with (test/mb-share-skills.test.ts): these functions as index.ts had them.
import { createHash, randomBytes } from "node:crypto";
import { lstatSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { relativeParts } from "../../src/ops/paths.ts";

/// What a skill may hold to be shared (sent whole in one request of the station transport, which takes 1 MB).
export const MAX_SKILL_BYTES = 512 * 1024;
export const MAX_SKILL_FILES = 200;

export class TooLarge extends Error {}

const hashOf = (v: string) => createHash("sha256").update(v).digest("hex");

/// A skill's files, relative paths to their bytes; refused past the limits (or with links in it).
export function readSkill(dir: string): Record<string, Buffer> {
  const files: Record<string, Buffer> = {};
  let bytes = 0;
  const walk = (at: string) => {
    for (const name of readdirSync(at)) {
      const path = join(at, name);
      const meta = lstatSync(path);
      if (meta.isSymbolicLink()) continue;
      if (meta.isDirectory()) walk(path);
      else if (meta.isFile()) {
        // A conflict kept beside the skill is the host's to show, not part of what is shared.
        if (/^SKILL\.conflict-/.test(name)) continue;
        bytes += meta.size;
        if (bytes > MAX_SKILL_BYTES || Object.keys(files).length >= MAX_SKILL_FILES) throw new TooLarge("the skill is too large to share (512 KB, 200 files at most)");
        files[relative(dir, path).split(sep).join("/")] = readFileSync(path);
      }
    }
  };
  walk(dir);
  return files;
}

export const skillHash = (files: Record<string, Buffer>) =>
  hashOf(Object.keys(files).sort().map((k) => `${k}\0${createHash("sha256").update(files[k]!).digest("hex")}`).join("\n"));

/// A relative path that stays inside the skill (relativeParts: not rooted, no `..`), none of its components `.` or
/// empty.
export const safePath = (p: string) => {
  const parts = relativeParts(p);
  return parts !== null && !parts.some((s) => s === "." || s === "");
};

export function writeSkill(dir: string, files: Record<string, string>) {
  const temp = `${dir}.tmp-${randomBytes(4).toString("hex")}`;
  rmSync(temp, { recursive: true, force: true });
  for (const [path, data] of Object.entries(files)) {
    if (!safePath(path)) throw new Error(`bad path in a shared skill: ${path}`);
    mkdirSync(dirname(join(temp, path)), { recursive: true });
    writeFileSync(join(temp, path), Buffer.from(data, "base64"));
  }
  mkdirSync(temp, { recursive: true });
  rmSync(dir, { recursive: true, force: true });
  renameSync(temp, dir);
}

export const encodeFiles = (files: Record<string, Buffer>) => Object.fromEntries(Object.entries(files).map(([k, v]) => [k, v.toString("base64")]));

/// An edit made on an older copy kept beside the skill (index.ts `takeEdit` as it was).
export function writeConflict(dir: string, peer: string, skill: string) {
  writeFileSync(join(dir, `SKILL.conflict-${peer.slice(0, 12)}.md`), Buffer.from(skill, "base64"));
}
