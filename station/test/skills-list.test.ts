import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { geminiDir } from "../src/agents/agy.ts";
import { copilotHome } from "../src/agents/copilot.ts";
import { cursorHome } from "../src/agents/cursor.ts";
import type { Profile } from "../src/agents/runtime.ts";
import { collectSkills, extractSlashInvocations, formatSkillInvocations, parseSkillFrontmatter, toListed } from "../src/sessions/skills.ts";

async function writeSkill(root: string, dirName: string, content: string): Promise<string> {
  const dir = join(root, dirName);
  await mkdir(dir, { recursive: true });
  const file = join(dir, "SKILL.md");
  await writeFile(file, content, "utf8");
  return file;
}

function fakeProfile(home: string, runtimes: Profile["runtimes"]): Profile {
  return {
    id: "p1",
    name: "Test",
    runtimes,
    home,
  };
}

test("parseSkillFrontmatter parses single-line, quoted, multiline scalars, and slash flags", () => {
  const folded = parseSkillFrontmatter(
    [
      "---",
      "name: swarm",
      "description: >-",
      "  Run multiple parallel agents",
      "  on a shared board.",
      "disable-model-invocation: true",
      "---",
      "# Swarm",
    ].join("\n"),
  );
  assert.equal(folded.frontmatter.name, "swarm");
  assert.equal(folded.frontmatter.description, "Run multiple parallel agents on a shared board.");
  assert.equal(folded.frontmatter.disableSlashCommand, undefined);

  const hidden = parseSkillFrontmatter(
    [
      "---",
      "name: swarm_monitor",
      'description: "Internal monitor"',
      "disable-slash-command: true",
      "---",
    ].join("\n"),
  );
  assert.equal(hidden.frontmatter.name, "swarm_monitor");
  assert.equal(hidden.frontmatter.disableSlashCommand, true);

  const nonUser = parseSkillFrontmatter(
    [
      "---",
      "name: internal-helper",
      "user-invocable: false",
      "---",
    ].join("\n"),
  );
  assert.equal(nonUser.frontmatter.userInvocable, false);
});

test("collectSkills for Antigravity (agy) follows profile geminiDir, enabled plugins, builtins, and workspace dedup", async () => {
  const root = await mkdtemp(join(tmpdir(), "sf-skills-agy-"));
  try {
    const profileHome = join(root, "profile-agy");
    const gemini = geminiDir(profileHome);
    const cwd = join(root, "session-work");
    const wsSkills = join(root, "agent-home", "skills");

    // 1. Antigravity builtin skills: user-invocable /swarm kept even with disable-model-invocation: true;
    //    disable-slash-command: true skills excluded.
    await writeSkill(
      join(gemini, "antigravity-cli", "builtin", "skills"),
      "native_swarm",
      "---\nname: swarm\ndescription: >-\n  Coordinate parallel swarm workers\ndisable-model-invocation: true\n---\n# Swarm\n",
    );
    await writeSkill(
      join(gemini, "antigravity-cli", "builtin", "skills"),
      "swarm_monitor",
      "---\nname: swarm_monitor\ndescription: Internal monitor\ndisable-slash-command: true\n---\n",
    );
    await writeSkill(
      join(gemini, "antigravity-cli", "builtin", "skills"),
      "run-workflow",
      "---\nname: run-workflow\ndescription: Orchestrate workflows\n---\n",
    );

    // 2. Profile config skills & plugins (enabled vs disabled).
    await writeSkill(
      join(gemini, "config", "skills"),
      "my-agy-skill",
      "---\nname: my-agy-skill\ndescription: Custom Antigravity skill\n---\n",
    );
    await mkdir(join(gemini, "config"), { recursive: true });
    await writeFile(
      join(gemini, "config", "config.json"),
      JSON.stringify({ plugins: { "disabled-plug": { enabled: false }, "enabled-plug": { enabled: true } } }),
    );
    await writeSkill(
      join(gemini, "config", "plugins", "enabled-plug", "skills"),
      "plug-skill",
      "---\nname: plug-skill\ndescription: From enabled plugin\n---\n",
    );
    await writeSkill(
      join(gemini, "config", "plugins", "disabled-plug", "skills"),
      "hidden-plug-skill",
      "---\nname: hidden-plug-skill\ndescription: From disabled plugin\n---\n",
    );
    await mkdir(join(gemini, "config", "plugins", "meta-disabled"), { recursive: true });
    await writeFile(join(gemini, "config", "plugins", "meta-disabled", "plugin.json"), JSON.stringify({ disabled: true }));
    await writeSkill(
      join(gemini, "config", "plugins", "meta-disabled", "skills"),
      "meta-hidden",
      "---\nname: meta-hidden\ndescription: Disabled in plugin.json\n---\n",
    );

    // 3. Shared workspace, project memory, and station built-in skills; also symlinked into cwd/.agents/skills.
    await writeSkill(wsSkills, "team-deploy", "---\nname: team-deploy\ndescription: Deploy team staging\n---\n");
    await writeSkill(wsSkills, "monoid", "---\nname: monoid\ndescription: 项目记忆：monoid 仓库构建与测试\n---\n");
    await writeSkill(wsSkills, "stillfail-show", "---\nname: stillfail-show\ndescription: Show UI evidence\n---\n");
    await mkdir(join(cwd, ".agents", "skills"), { recursive: true });
    await symlink(join(wsSkills, "team-deploy"), join(cwd, ".agents", "skills", "team-deploy"), "dir");

    // 4. Genuine session-local skill in cwd/.agent/skills.
    await writeSkill(join(cwd, ".agent", "skills"), "local-only", "---\nname: local-only\ndescription: Session local skill\n---\n");

    const skills = await collectSkills({
      runtime: "agy",
      profile: fakeProfile(profileHome, ["agy"]),
      cwd,
      workspaceSkillsDir: wsSkills,
      siteSkillsDir: null,
    });

    const byName = new Map(skills.map((s) => [s.name, s]));
    assert.equal(byName.get("local-only")?.source, "session");
    assert.equal(byName.get("swarm")?.source, "agent");
    assert.equal(byName.get("swarm")?.description, "Coordinate parallel swarm workers");
    assert.equal(byName.get("run-workflow")?.source, "agent");
    assert.equal(byName.get("my-agy-skill")?.source, "agent");
    assert.equal(byName.get("plug-skill")?.source, "agent");
    assert.equal(byName.get("team-deploy")?.source, "workspace");
    assert.equal(byName.get("monoid")?.source, "project");
    assert.equal(byName.get("stillfail-show")?.source, "builtin");

    // Excluded entries
    assert.equal(byName.has("swarm_monitor"), false);
    assert.equal(byName.has("hidden-plug-skill"), false);
    assert.equal(byName.has("meta-hidden"), false);

    // Priority ordering: session before agent before workspace before project before builtin.
    const idx = (n: string) => skills.findIndex((s) => s.name === n);
    assert.ok(idx("local-only") < idx("swarm"));
    assert.ok(idx("swarm") < idx("team-deploy"));
    assert.ok(idx("team-deploy") < idx("monoid"));
    assert.ok(idx("monoid") < idx("stillfail-show"));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("collectSkills switches cleanly across claude, codex, copilot, cursor, and pi", async () => {
  const root = await mkdtemp(join(tmpdir(), "sf-skills-multi-"));
  try {
    const profileHome = join(root, "profile");
    const cwd = join(root, "work");
    const wsSkills = join(root, "ws-skills");

    // Claude skills + nested commands + disabled skill ("loop").
    await writeSkill(join(profileHome, "skills"), "claude-own", "---\nname: claude-own\ndescription: Claude profile skill\n---\n");
    await writeSkill(join(profileHome, "skills"), "loop", "---\nname: loop\ndescription: Disabled in station\n---\n");
    await mkdir(join(cwd, ".claude", "commands", "team"), { recursive: true });
    await writeFile(join(cwd, ".claude", "commands", "team", "review.md"), "---\ndescription: Run team PR review\n---\nBody\n");

    // Copilot & Cursor skills
    await writeSkill(join(copilotHome(profileHome), "skills"), "copilot-own", "---\nname: copilot-own\ndescription: Copilot skill\n---\n");
    await writeSkill(join(cursorHome(profileHome), "skills"), "cursor-own", "---\nname: cursor-own\ndescription: Cursor skill\n---\n");

    // Workspace skill
    await writeSkill(wsSkills, "shared-one", "---\nname: shared-one\ndescription: Shared workspace skill\n---\n");

    const claudeSkills = await collectSkills({
      runtime: "claude",
      profile: fakeProfile(profileHome, ["claude"]),
      cwd,
      workspaceSkillsDir: wsSkills,
      siteSkillsDir: null,
    });
    assert.ok(claudeSkills.some((s) => s.name === "claude-own" && s.source === "agent"));
    assert.ok(claudeSkills.some((s) => s.name === "team:review" && s.source === "session"));
    assert.ok(claudeSkills.some((s) => s.name === "shared-one" && s.source === "workspace"));
    assert.equal(claudeSkills.some((s) => s.name === "loop"), false);
    assert.equal(claudeSkills.some((s) => s.name === "copilot-own"), false);

    const copilotSkills = await collectSkills({
      runtime: "copilot",
      profile: fakeProfile(profileHome, ["copilot"]),
      cwd,
      workspaceSkillsDir: wsSkills,
      siteSkillsDir: null,
    });
    assert.ok(copilotSkills.some((s) => s.name === "copilot-own" && s.source === "agent"));
    assert.equal(copilotSkills.some((s) => s.name === "claude-own"), false);

    const cursorSkills = await collectSkills({
      runtime: "cursor",
      profile: fakeProfile(profileHome, ["cursor"]),
      cwd,
      workspaceSkillsDir: wsSkills,
      siteSkillsDir: null,
    });
    assert.ok(cursorSkills.some((s) => s.name === "cursor-own" && s.source === "agent"));
    assert.equal(cursorSkills.some((s) => s.name === "claude-own"), false);

    // Pi only loads workspace skills (--no-skills --skill <wsSkills>).
    const piSkills = await collectSkills({
      runtime: "pi",
      profile: fakeProfile(profileHome, ["pi"]),
      cwd,
      workspaceSkillsDir: wsSkills,
      siteSkillsDir: null,
    });
    assert.deepEqual(
      piSkills.map((s) => s.name),
      ["shared-one"],
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("extractSlashInvocations and formatSkillInvocations match explicit /skill calls and ignore paths/URLs/code", () => {
  assert.deepEqual(extractSlashInvocations("/swarm 帮我并行重构"), ["swarm"]);
  assert.deepEqual(extractSlashInvocations("请用 /team:review 检查 https://example.com/swarm 和 src/swarm.ts"), ["team:review"]);
  assert.deepEqual(extractSlashInvocations("```\n/swarm\n```\n普通内容"), []);
  assert.deepEqual(extractSlashInvocations("试试 /plan，然后 /swarm。"), ["plan", "swarm"]);

  const resolved = [
    { name: "swarm", description: "Parallel agents", source: "agent" as const, path: "/home/a/builtin/skills/native_swarm/SKILL.md" },
    { name: "team:review", description: "Review", source: "session" as const, path: "/work/.claude/commands/team/review.md" },
  ];
  const hint = formatSkillInvocations(["请用 /swarm 处理这个任务"], resolved);
  assert.ok(hint.includes('<skill-invocation name="swarm" path="/home/a/builtin/skills/native_swarm/SKILL.md">'));
  assert.ok(hint.includes("Read /home/a/builtin/skills/native_swarm/SKILL.md"));
  assert.equal(formatSkillInvocations(["/unknown-command hello"], resolved), "");
});

test("toListed names the chat's preset or project on session skills only, and nothing where none is known", () => {
  const resolved = [
    { name: "team:review", description: "Review", source: "session" as const, path: "/work/.claude/commands/team/review.md" },
    { name: "shared-one", description: "Shared", source: "workspace" as const, path: "/ws/skills/shared-one/SKILL.md" },
  ];
  assert.deepEqual(toListed(resolved, "发版值守"), [
    { name: "team:review", description: "Review", source: "session", place: "发版值守" },
    { name: "shared-one", description: "Shared", source: "workspace" },
  ]);
  assert.deepEqual(toListed(resolved, ""), [
    { name: "team:review", description: "Review", source: "session" },
    { name: "shared-one", description: "Shared", source: "workspace" },
  ]);
});
