import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { execFileSync } from "node:child_process";
import { changelog, draft, lastBase, readRelease, stable, type Entry } from "../scripts/changelog.ts";

const note = (version: number, lines = "- 新功能：一件事\n- 修复：另一件") => `---\nversion: ${version}\ndate: 2026-10-02\nparts: [web, android]\n---\n${lines}\n`;

test("a release's notes are one entry: its version, day, parts and lines", () => {
  const entry = readRelease(note(1400, "说明不算\n- 新功能：一件事\n  - 修复：另一件\n"));
  assert.deepEqual({ ...entry, at: undefined }, { version: 1400, commit: "", at: undefined, text: ["新功能：一件事", "修复：另一件"], fixes: [], parts: ["android", "web"] });
  assert.equal(new Date(entry.at * 1000).toISOString(), "2026-10-02T04:00:00.000Z");
  assert.throws(() => readRelease("- 没有头\n"), /front matter/);
  assert.throws(() => readRelease(note(1400).replace("web, android", "web, ios")), /parts/);
  assert.throws(() => readRelease(note(1400, "没有一行")), /no lines/);
});

test("the stable channel's entries, newest first, each with the fixes of the test channel's in between", () => {
  const root = mkdtempSync(join(tmpdir(), "stable-"));
  mkdirSync(join(root, "docs/releases"), { recursive: true });
  writeFileSync(join(root, "docs/releases/0.1.1300.md"), note(1300));
  writeFileSync(join(root, "docs/releases/0.1.1400.md"), note(1400));
  writeFileSync(join(root, "docs/releases/README.md"), "not a release");
  const beta = (version: number, fixes: number[]): Entry => ({ version, commit: "c", at: 0, text: ["x"], fixes, parts: ["web"] });
  const entries = stable(root, [beta(1410, [9]), beta(1350, [7, 8]), beta(1300, [5]), beta(1200, [3])]);
  assert.deepEqual(entries.map((e) => [e.version, e.fixes]), [[1400, [7, 8]], [1300, [3, 5]]]);
});

test("the next notes are drafted from the newest release's base: a release branch's main commit, else its version", () => {
  const root = mkdtempSync(join(tmpdir(), "stable-"));
  mkdirSync(join(root, "docs/releases"), { recursive: true });
  assert.equal(lastBase(root), 0);
  writeFileSync(join(root, "docs/releases/0.1.1300.md"), note(1300));
  assert.equal(lastBase(root), 1300);
  writeFileSync(join(root, "docs/releases/0.1.1404.md"), note(1404).replace("parts:", "base: 1400\nbranch: release/2026-10-02\nparts:"));
  assert.equal(lastBase(root), 1400);
  assert.deepEqual(stable(root).map((e) => e.version), [1404, 1300]);
});

test("what is the test channel's alone is left out of the stable channel's fixes and of the next notes' draft", () => {
  const root = mkdtempSync(join(tmpdir(), "stable-"));
  mkdirSync(join(root, "docs/releases"), { recursive: true });
  writeFileSync(join(root, "docs/releases/0.1.1300.md"), note(1300));
  writeFileSync(join(root, "docs/releases/0.1.1400.md"), note(1400));
  const beta = (version: number, fixes: number[], channel?: "beta"): Entry => ({ version, commit: "c", at: 0, text: ["x"], fixes, parts: ["web"], ...(channel ? { channel } : {}) });
  const entries = stable(root, [beta(1350, [7]), beta(1360, [8], "beta"), beta(1300, [5])]);
  assert.deepEqual(entries.map((e) => [e.version, e.fixes]), [[1400, [7]], [1300, [5]]]);

  // a repository of four commits: one said for all, one for the test channel, one marked so by the notes, one plain
  const repo = mkdtempSync(join(tmpdir(), "draft-"));
  const git = (...args: string[]) => execFileSync("git", args, { cwd: repo, encoding: "utf8", env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" } });
  git("init", "-q", "-b", "main");
  const commit = (file: string, message: string) => {
    writeFileSync(join(repo, file), file);
    git("add", file);
    git("commit", "-q", "-m", message);
    return git("rev-parse", "HEAD").trim();
  };
  commit("a", "a\n\nChangelog: 修复：给所有人\nChangelog-parts: web\n");
  commit("b", "b\n\nChangelog: 新增：只在测试版\nChangelog-parts: web\nChangelog-channel: beta\n");
  const c = commit("c", "c\n\nChangelog: 新增：后来才说只在测试版\nChangelog-parts: web\n");
  mkdirSync(join(repo, "docs"), { recursive: true });
  writeFileSync(join(repo, "docs/changelog-notes.json"), JSON.stringify({ [c.slice(0, 10)]: { channel: "beta" } }));
  commit("d", "d\n\nChangelog: 改进：也给所有人\nChangelog-parts: web\n");
  const all = changelog(repo);
  assert.deepEqual(all.map((e) => [e.text[0], e.channel ?? "all"]), [
    ["改进：也给所有人", "all"],
    ["新增：后来才说只在测试版", "beta"],
    ["新增：只在测试版", "beta"],
    ["修复：给所有人", "all"],
  ]);
  const drafted = draft(repo);
  assert.match(drafted, /修复：给所有人/);
  assert.match(drafted, /改进：也给所有人/);
  assert.doesNotMatch(drafted, /只在测试版/);
});
