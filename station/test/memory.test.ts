// The agents' memory as GET /memory reads it (src/read/memory.ts): the global one, and each skill with the other
// Markdown files beside its SKILL.md.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { memory } from "./reference/memory.ts";

test("a_skill_comes_with_its_other_files", () => {
  const data = mkdtempSync(join(tmpdir(), "memory-"));
  const skill = join(data, "agent/skills/ember");
  mkdirSync(skill, { recursive: true });
  writeFileSync(join(data, "agent/MEMORY.md"), "# memory\n");
  writeFileSync(join(skill, "SKILL.md"), "---\nname: ember\ndescription: 项目记忆：ember\n---\n总览\n");
  writeFileSync(join(skill, "verify.md"), "验证\n");
  writeFileSync(join(skill, "design.md"), "设计\n");
  writeFileSync(join(skill, "SKILL.conflict-mini.md"), "冲突\n");
  writeFileSync(join(skill, "shot.png"), "png");
  const read = memory(data) as any;
  assert.equal(read.global.text, "# memory\n");
  assert.equal(read.skills[0].project, true);
  assert.deepEqual(read.skills[0].files, [{ name: "design.md", text: "设计\n" }, { name: "verify.md", text: "验证\n" }]);
});

test("memory_includes_version_metadata_and_previous_blob_when_kept", () => {
  const data = mkdtempSync(join(tmpdir(), "memory-rec-"));
  const skill = join(data, "agent/skills/ember");
  const blobs = join(data, "share/memory/blobs");
  mkdirSync(skill, { recursive: true });
  mkdirSync(blobs, { recursive: true });
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "agent/MEMORY.md"), "# memory\n- new rule\n");
  writeFileSync(join(skill, "SKILL.md"), "---\nname: ember\ndescription: 项目记忆：ember\n---\n新总览\n");
  const prevGlobalHash = "1".repeat(64);
  const prevSkillHash = "2".repeat(64);
  const currGlobalHash = "3".repeat(64);
  const currSkillHash = "4".repeat(64);
  const willowId = "a".repeat(64);
  const mapleId = "b".repeat(64);
  writeFileSync(join(blobs, prevGlobalHash), "# memory\n- old rule\n");
  writeFileSync(join(blobs, prevSkillHash), "---\nname: ember\ndescription: 项目记忆：ember\n---\n旧总览\n");
  writeFileSync(
    join(data, "mesh/cloud.json"),
    JSON.stringify({
      workspace: "ws1",
      station: willowId,
      name: "Willow",
      peers: [{ id: mapleId, name: "Maple" }],
    }),
  );
  writeFileSync(
    join(data, "share/memory/ws1.json"),
    JSON.stringify({
      clock: 2000,
      files: {
        "MEMORY.md": { hash: currGlobalHash, at: 1500, by: willowId, prev: [prevGlobalHash], size: 20, mode: 0o644 },
        "skills/ember/SKILL.md": { hash: currSkillHash, at: 2000, by: mapleId, prev: [prevSkillHash], size: 40, mode: 0o644 },
      },
    }),
  );
  const read = memory(data) as any;
  assert.equal(read.global.at, 1500);
  assert.equal(read.global.by, "Willow");
  assert.equal(read.global.prev, "# memory\n- old rule\n");
  assert.equal(read.skills[0].at, 2000);
  assert.equal(read.skills[0].by, "Maple");
  assert.equal(read.skills[0].prev, "---\nname: ember\ndescription: 项目记忆：ember\n---\n旧总览\n");
});
