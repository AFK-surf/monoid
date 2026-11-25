// The agent's instructions and the migration notes (src/agents/instructions.ts, migrations.ts: their source).
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import * as ts from "../src/agents/instructions.ts";
import { NOTES, latest, untold, REWRITTEN } from "../src/agents/migrations.ts";

test("the session instructions name the session's places, and a project only when it has one", () => {
  const plain = ts.sessionInstructions("/w/s/workspace", null, "/w/repos", "/w/agent/MEMORY.md", "");
  for (const place of ["/w/s/workspace", "/w/repos", "/w/agent/MEMORY.md"]) assert.ok(plain.includes(place), place);
  assert.ok(!plain.includes("Project directory"));
  const project = ts.sessionInstructions("/w/s/workspace", "/p", "/w/repos", "/w/agent/MEMORY.md", "");
  assert.ok(project.includes("- Project directory: /p. This session began outside still.fail"));
  assert.equal(project.replace(/- Project directory: [^\n]*\n/, ""), plain);
  assert.ok(!plain.includes("<memory"), "no memory where there is none");
});

test("stillfail-move is named only where moving is on here (every station's; a test's may say not), nothing else changed", () => {
  const on = ts.sessionInstructions("/ws/c", null, "/repos", "/m/MEMORY.md", "");
  const off = ts.sessionInstructions("/ws/c", null, "/repos", "/m/MEMORY.md", "", "", "", false);
  assert.ok(on.includes(ts.MOVE_LINE));
  assert.ok(!off.includes("stillfail-move"));
  assert.equal(off, on.replace(ts.MOVE_LINE, ""));
});

test("the session instructions tell the memory they name, as it is now", async () => {
  const dir = mkdtempSync(join(tmpdir(), "instructions-"));
  const path = join(dir, "MEMORY.md");
  writeFileSync(path, "# lessons\n- one\n");
  assert.ok(ts.sessionInstructions("/w/s/workspace", null, "/w/repos", path, await ts.readMemory(path)).endsWith(`\n\n<memory path="${path}">\n# lessons\n- one\n</memory>`));
  rmSync(dir, { recursive: true, force: true });
});

test("memory grown past what an agent can use is said after it, file by file, and nothing where none is", async () => {
  const dir = mkdtempSync(join(tmpdir(), "instructions-"));
  const path = join(dir, "MEMORY.md");
  writeFileSync(path, "# lessons\n- one\n");
  mkdirSync(join(dir, "skills", "small"), { recursive: true });
  writeFileSync(join(dir, "skills", "small", "SKILL.md"), "---\nname: small\n---\n- a fact\n");
  assert.equal(await ts.readMemory(path), "# lessons\n- one", "nothing said of memory that fits");
  mkdirSync(join(dir, "skills", "proj"), { recursive: true });
  writeFileSync(join(dir, "skills", "proj", "SKILL.md"), `---\nname: proj\n---\n${"- 现状：".padEnd(ts.LINE_MOST, "做")}\n${"- fact\n".repeat(ts.SKILL_MOST / 7)}`);
  writeFileSync(path, `# lessons\n${"- rule\n".repeat(ts.MEMORY_MOST / 7 + 1)}`);
  const told = await ts.readMemory(path);
  assert.ok(told.startsWith("# lessons\n- rule\n"), "the memory itself first");
  const note = told.slice(told.indexOf("[still.fail: this memory has grown"));
  assert.match(note, /^- MEMORY\.md: 9 KB, past 8 KB$/m);
  assert.match(note, /^- skills\/proj\/SKILL\.md: \d+ KB, past 24 KB; 1 line past 1500 bytes$/m);
  assert.ok(!note.includes("skills/small"), "a skill that fits is not named");
  assert.ok(note.includes("drop progress, status and handover notes"));
  rmSync(dir, { recursive: true, force: true });
});

test("overgrown says nothing of files within their bounds", () => {
  const full = "- x\n".repeat(ts.SKILL_MOST / 4);
  assert.equal(ts.overgrown([["MEMORY.md", "- one"], ["skills/x/SKILL.md", full], ["skills/y/SKILL.md", `- ${"x".repeat(ts.LINE_MOST - 2)}`]]), "");
  assert.equal(ts.overgrown([["skills/x/SKILL.md", `${full}y`]]).split("\n")[1], "- skills/x/SKILL.md: 25 KB, past 24 KB");
});

test("what the deployment adds is told after still.fail's own instructions, before the memory, and nothing without it", async () => {
  const dir = mkdtempSync(join(tmpdir(), "instructions-"));
  const path = join(dir, "site.md");
  writeFileSync(path, "\nThis machine is a Monoid Machine: read skill monoid-machine.\n\n");
  assert.equal(await ts.readSiteInstructions({}), "", "none by default");
  assert.equal(await ts.readSiteInstructions({ STILLFAIL_SITE_INSTRUCTIONS: join(dir, "absent.md") }), "", "none when the file does not read");
  const site = await ts.readSiteInstructions({ STILLFAIL_SITE_INSTRUCTIONS: path });
  assert.equal(site, "This machine is a Monoid Machine: read skill monoid-machine.");
  const plain = ts.sessionInstructions("/w/s/workspace", null, "/w/repos", "/w/agent/MEMORY.md", "# lessons");
  assert.equal(ts.sessionInstructions("/w/s/workspace", null, "/w/repos", "/w/agent/MEMORY.md", "# lessons", ""), plain, "unchanged without a site");
  const told = ts.sessionInstructions("/w/s/workspace", null, "/w/repos", "/w/agent/MEMORY.md", "# lessons", site);
  assert.equal(told, plain.replace('\n\n<memory path=', `\n\n${site}\n\n<memory path=`));
  writeFileSync(path, "x".repeat(ts.SITE_INSTRUCTIONS_MAX + 10));
  assert.equal((await ts.readSiteInstructions({ STILLFAIL_SITE_INSTRUCTIONS: path })).length, ts.SITE_INSTRUCTIONS_MAX, "cut: a few lines, not a manual");
  rmSync(dir, { recursive: true, force: true });
});

test("a session is opened with what the deployment adds to its instructions", async () => {
  const { openOptions } = await import("../src/sessions/actor.ts");
  const row = { key: "k", workspace: "/w/s/workspace", token: "t", cwd: null };
  const deps = { mcpUrl: () => "http://127.0.0.1:1/mcp", reposDir: () => "/w/repos", memoryPath: () => "/w/agent/MEMORY.md" };
  const profile = { id: "p", runtime: "claude", runtimes: ["claude"], home: "/h", models: [], named: [], name: "p", backgroundOnMessage: true, enabled: true } as never;
  const without = (await openOptions(row, profile, deps, "")).instructions;
  assert.ok(!without.includes("Monoid"));
  const site = (await openOptions(row, profile, { ...deps, siteInstructions: () => "This machine is a Monoid Machine." }, "")).instructions;
  assert.equal(site, `${without}\n\nThis machine is a Monoid Machine.`);
});

test("the fixed prompts", () => {
  for (const name of ["NUDGE", "RESUME_AFTER_RESTART", "GO_ON_AFTER_AUTH", "GO_ON_AFTER_SPENT"] as const) assert.ok(ts[name].length > 20, name);
  assert.ok(ts.waitOver(90).includes("(90 seconds)"));
  for (const strength of ["require", "remind"] as const) assert.ok(ts.silentProgress(12, strength).includes("12 minutes") && ts.silentProgress(12, strength).includes("chat_post"));
  assert.notEqual(ts.silentProgress(12, "require"), ts.silentProgress(12, "remind"));
  assert.ok(ts.continuedHere("X").endsWith("<stillfail-instructions>\nX\n</stillfail-instructions>"));
  assert.ok(ts.resumeLost("k", ["C1/1.0"]).includes("session_history with chat k") && ts.resumeLost("k", ["C1/1.0"]).includes("chat_history for C1/1.0"));
});

test("the migration notes are numbered 1, 2, 3…, and told once", () => {
  assert.deepEqual(NOTES.map(([n]) => n), NOTES.map((_, i) => i + 1));
  assert.ok(NOTES.every(([, note]) => note.length > 0 && !note.includes("\n")));
  assert.equal(untold(latest(), "/w/i.md"), "");
  const all = untold(0, "/w/i.md");
  assert.ok(all.startsWith("[still.fail changed how you work") && all.includes("rewritten") && all.includes("/w/i.md"));
  // A session from before the rewrite hears that it happened, not the notes it replaced.
  assert.ok(!all.includes(NOTES[REWRITTEN - 2]![1]));
  assert.ok(!untold(latest() - 1, "/w/i.md").includes(NOTES[0]![1]));
});

test("thread addresses as the agent writes them", () => {
  assert.deepEqual(ts.parseThreadAddress(" C123/1790000000.000100 "), ["C123", "1790000000.000100"]);
  for (const bad of ["c123/1.2", "C123/1", "C123/.2", "/1.2", "C123-1.2"]) assert.equal(ts.parseThreadAddress(bad), null, bad);
});

test("delivered messages and history say their time without changing their identifiers", () => {
  const m = { thread: 1, n: 1, ts: "1794667432.279000", author: "a", authorKind: "person", text: "最近的 chat", client: null, attachments: [], quotes: [], createdAt: 1794667434000 };
  const p = { message: m, surface: "ember", channel: "CHAT", threadTs: m.ts, connect: "ember" };
  const delivered = ts.formatInbound([p] as never, new Set(), new Map(), new Map(), new Map(), new Map(), "");
  assert.ok(delivered.includes('sent_at="2026-11-14T14:43:52.279Z" from="a" ts="1794667432.279000"'), delivered);
  const history = ts.formatHistory([m] as never, "web", `CHAT/${m.ts}`, "", new Map());
  assert.ok(history.includes('sent_at="2026-11-14T14:43:52.279Z" from="a" ts="1794667432.279000"'), history);
  const feishu = { ...m, ts: "om_123", createdAt: 1794667434000 };
  const opaque = ts.formatHistory([feishu] as never, "feishu:test", "oc_1/om_123", "", new Map());
  assert.ok(opaque.includes('recorded_at="2026-11-14T14:43:54.000Z" from="a" ts="om_123"'), opaque);
  const comma = ts.formatHistory([m] as never, "comma:test", `TASK/${m.ts}`, "", new Map());
  assert.ok(comma.includes('recorded_at="2026-11-14T14:43:54.000Z" from="a" ts="1794667432.279000"'), comma);
});

test("earlier choices on cards say when they were made and that what follows is not about them", () => {
  const choice = { thread: 1, n: 2, ts: "1700000000.000100", where: ["CHAT", "1700000000.000001"] as [string, string], question: "要部署吗？\n\n第二段", by: "ada@x.com", option: "不需要部署", at: 1_700_000_000_000 };
  assert.equal(ts.formatCardChoices([], new Map(), 0), "");
  const said = ts.formatCardChoices([choice, { ...choice, n: 3, ts: null, where: null, question: null, at: choice.at + 60 * 60_000 }], new Map([["ada@x.com", "Ada"]]), choice.at + 26 * 60 * 60_000 + 5 * 60_000);
  const [head, ...rest] = said.split("\n");
  assert.ok(head!.startsWith("[Earlier choices on your cards, told to you now.") && head!.includes("not about them unless it says so"), head);
  assert.equal(rest.join("\n"), [
    '<card-choice thread="CHAT/1700000000.000001" card="1700000000.000100" by="Ada (ada@x.com)" at="1700000000.000000" ago="1 d 2 h">',
    "Asked: 要部署吗？ 第二段",
    "Chosen: 不需要部署",
    "</card-choice>",
    '<card-choice by="Ada (ada@x.com)" at="1700003600.000000" ago="1 d 1 h">',
    "Chosen: 不需要部署",
    "</card-choice>",
  ].join("\n"));
  const ago = (ms: number) => ts.formatCardChoices([choice], new Map(), choice.at + ms).match(/ago="([^"]+)"/)![1];
  assert.deepEqual([0, 59_999, 60_000, 59 * 60_000, 60 * 60_000, 61 * 60_000, 24 * 60 * 60_000].map(ago), ["less than a minute", "less than a minute", "1 min", "59 min", "1 h", "1 h 1 min", "1 d"]);
});
