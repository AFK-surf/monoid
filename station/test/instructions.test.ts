// The agent's instructions and the migration notes (src/agents/instructions.ts, migrations.ts: their source).
import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
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

test("readMemory enforces 16 KB hard cap safely on UTF-8/emoji/long-line while reporting untruncated overgrown size", async () => {
  const dir = mkdtempSync(join(tmpdir(), "instructions-cap-"));
  try {
    const path = join(dir, "MEMORY.md");
    assert.equal(ts.MEMORY_INJECT_HARD_MAX, 16 * 1024);
    assert.equal(ts.STATION_MEMORY_MAX, 4 * 1024);

    // <= 8 KB: no truncation, no overgrown warning
    const small = "- 规则一\n- 规则二";
    writeFileSync(path, small);
    assert.equal(await ts.readMemory(path), small);

    // 8–16 KB: no truncation, overgrown warning present
    const mediumLine = `- ${"a".repeat(90)}\n`;
    const medium = mediumLine.repeat(110).trim(); // ~10.2 KB
    assert.ok(Buffer.byteLength(medium, "utf8") > ts.MEMORY_MOST);
    assert.ok(Buffer.byteLength(medium, "utf8") <= ts.MEMORY_INJECT_HARD_MAX);
    writeFileSync(path, medium);
    const mediumOut = await ts.readMemory(path);
    assert.ok(mediumOut.startsWith(medium));
    assert.ok(!mediumOut.includes("truncated at 16 KB"));
    assert.match(mediumOut, /- MEMORY\.md: 1[01] KB, past 8 KB/);

    // > 16 KB with multi-byte Chinese & 4-byte emoji: truncated body <= 16 KB, valid UTF-8, overgrown reports full size
    const cjkLine = "- 中文规则：遇到共享机器问题先查日志，不要乱杀进程 🚀🔥\n";
    const big = cjkLine.repeat(350).trim(); // > 20 KB
    const bigBytes = Buffer.byteLength(big, "utf8");
    const bigKb = Math.ceil(bigBytes / 1024);
    assert.ok(bigBytes > ts.MEMORY_INJECT_HARD_MAX);
    writeFileSync(path, big);
    const bigOut = await ts.readMemory(path);
    const marker = "\n\n[still.fail: MEMORY.md truncated at 16 KB";
    const markerIdx = bigOut.indexOf(marker);
    assert.ok(markerIdx > 0, "must include truncation notice");
    const body = bigOut.slice(0, markerIdx);
    assert.ok(Buffer.byteLength(body, "utf8") <= ts.MEMORY_INJECT_HARD_MAX, "truncated body must be <= 16 KB");
    assert.ok(!body.includes("\uFFFD"), "must not contain replacement characters");
    assert.equal(Buffer.from(body, "utf8").toString("utf8"), body, "must round-trip cleanly as UTF-8");
    assert.ok(bigOut.includes(`actual ${bigKb} KB`), "truncation notice must include actual KB");
    assert.ok(bigOut.includes(path), "truncation notice must include file path");
    assert.ok(bigOut.includes(`- MEMORY.md: ${bigKb} KB, past 8 KB`), "overgrown must report untruncated size");

    // Single line > 16 KB with 4-byte emoji: cuts on complete code point boundary, no broken surrogate pair
    const singleLine = "🚀".repeat(5000); // 20,000 bytes on one line
    writeFileSync(path, singleLine);
    const singleOut = await ts.readMemory(path);
    const singleIdx = singleOut.indexOf(marker);
    assert.ok(singleIdx > 0);
    const singleBody = singleOut.slice(0, singleIdx);
    assert.ok(Buffer.byteLength(singleBody, "utf8") <= ts.MEMORY_INJECT_HARD_MAX);
    assert.equal(Buffer.byteLength(singleBody, "utf8"), 16 * 1024);
    assert.equal([...singleBody].every((ch) => ch === "🚀"), true, "every code point must be an intact emoji");
    assert.ok(singleOut.includes("- MEMORY.md: 20 KB, past 8 KB; 1 line past 1500 bytes"));

    // Short first line (20 bytes) + 20 KB second line must NOT degenerate to 20 bytes
    const shortFirst = "# global memory rule\n" + "a".repeat(20 * 1024);
    writeFileSync(path, shortFirst);
    const shortFirstOut = await ts.readMemory(path);
    const shortFirstIdx = shortFirstOut.indexOf(marker);
    assert.ok(shortFirstIdx > 0);
    const shortFirstBody = shortFirstOut.slice(0, shortFirstIdx);
    assert.equal(Buffer.byteLength(shortFirstBody, "utf8"), ts.MEMORY_INJECT_HARD_MAX, "must fill up to 16 KB instead of cutting at 20-byte first line");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("readMemory auto-injects current station memory from skills/machines/<stationTag>.md with 4 KB cap, escaping, and safe lstat", async () => {
  const dir = mkdtempSync(join(tmpdir(), "instructions-station-"));
  try {
    const path = join(dir, "MEMORY.md");
    writeFileSync(path, "- global rule");

    // Absent station file: silently skipped, byte-identical to no station
    assert.equal(await ts.readMemory(path, "pvg-office-2"), "- global rule");

    // Station name normalization: special chars, 40-cp surrogate pair safety, trailing '-', Windows reserved names
    assert.equal(ts.stationTag("Tokyo Mac Studio / #0!"), "Tokyo-Mac-Studio-0");
    assert.equal(ts.stationTag("   "), "station");
    assert.equal(ts.stationTag(`${"a".repeat(39)}😀b`), `${"a".repeat(39)}a`.slice(0, 39)); // emoji is not \p{L}\p{N}, becomes trailing '-' and is stripped
    assert.equal(ts.stationTag(`${"a".repeat(39)}𠀀b`), `${"a".repeat(39)}𠀀`, "40th code point outside BMP stays intact (no broken surrogate pair)");
    assert.equal(ts.stationTag(`${"a".repeat(39)}-b`), "a".repeat(39), "trailing dash after 40-cp cut is stripped");
    assert.equal(ts.stationTag("CON"), "CON-station");
    assert.equal(ts.stationTag("nul"), "nul-station");
    assert.equal(ts.stationTag("Com1"), "Com1-station");
    assert.equal(ts.stationTag("LPT9"), "LPT9-station");
    assert.equal(ts.stationTag("COM0"), "COM0");

    const machinesDir = join(dir, "skills", "machines");
    mkdirSync(machinesDir, { recursive: true });
    const stationFile = join(machinesDir, "Tokyo-Mac-Studio-0.md");
    writeFileSync(stationFile, "- xcode lives in /Applications/Xcode.app\n");
    chmodSync(stationFile, 0o644);

    const injected = await ts.readMemory(path, "Tokyo Mac Studio / #0!");
    assert.equal(
      injected,
      `- global rule\n\n<station-memory station="Tokyo Mac Studio / #0!" path="${stationFile}">\n- xcode lives in /Applications/Xcode.app\n</station-memory>`,
    );

    // XML attribute escaping for station name containing quotes and ampersands
    const specialFile = join(machinesDir, "Lab-A-B.md");
    writeFileSync(specialFile, "- lab note\n");
    chmodSync(specialFile, 0o644);
    const escaped = await ts.readMemory(path, 'Lab "A" & B');
    assert.ok(escaped.includes('<station-memory station="Lab &quot;A&quot; &amp; B"'), escaped);

    // Symlink and 0600 owner-only private files are skipped
    const secretFile = join(machinesDir, "secret-host.md");
    writeFileSync(secretFile, "- private secret\n");
    chmodSync(secretFile, 0o600);
    assert.equal(await ts.readMemory(path, "secret-host"), "- global rule", "0600 private station file must be skipped");

    const linkFile = join(machinesDir, "link-host.md");
    symlinkSync(stationFile, linkFile);
    assert.equal(await ts.readMemory(path, "link-host"), "- global rule", "symlink station file must be skipped");

    // Placed between MEMORY.md body and overgrown notice
    const medium = `${"- rule\n".repeat(ts.MEMORY_MOST / 7 + 5)}`.trim();
    writeFileSync(path, medium);
    const withOvergrown = await ts.readMemory(path, "Tokyo Mac Studio / #0!");
    const smIdx = withOvergrown.indexOf("<station-memory");
    const ogIdx = withOvergrown.indexOf("[still.fail: this memory has grown");
    assert.ok(smIdx > 0 && ogIdx > smIdx, "<station-memory> must appear between MEMORY.md and overgrown");

    // Station memory > 4 KB (and > 8 KB bounded read cap) is safely truncated and reports actual file size
    const bigStation = "- 机器路径与运维提示：共享机器不要乱杀进程 🧭\n".repeat(400).trim(); // > 20 KB
    const bigStationKb = Math.ceil(Buffer.byteLength(bigStation, "utf8") / 1024);
    assert.ok(Buffer.byteLength(bigStation, "utf8") > ts.STATION_MEMORY_MAX + 4096);
    writeFileSync(stationFile, bigStation);
    chmodSync(stationFile, 0o644);
    const truncStation = await ts.readMemory(path, "Tokyo Mac Studio / #0!");
    const openTag = `<station-memory station="Tokyo Mac Studio / #0!" path="${stationFile}">\n`;
    const innerStart = truncStation.indexOf(openTag) + openTag.length;
    const innerEnd = truncStation.indexOf("\n</station-memory>");
    const inner = truncStation.slice(innerStart, innerEnd);
    const stNoticeIdx = inner.indexOf("\n\n[still.fail: station memory truncated at 4 KB");
    assert.ok(stNoticeIdx > 0, "station memory must include truncation notice");
    assert.ok(inner.includes(`actual ${bigStationKb} KB`), "truncation notice must report actual file size");
    const stBody = inner.slice(0, stNoticeIdx);
    assert.ok(Buffer.byteLength(stBody, "utf8") <= ts.STATION_MEMORY_MAX);
    assert.equal(Buffer.from(stBody, "utf8").toString("utf8"), stBody);
    assert.ok(inner.includes(stationFile));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("linkSkills forwards ownName to readMemory and instructions describe four-layer memory routing with exact station path", async () => {
  const { linkSkills } = await import("../src/sessions/actor.ts");
  const dir = mkdtempSync(join(tmpdir(), "instructions-link-"));
  try {
    const ws = join(dir, "ws");
    mkdirSync(ws, { recursive: true });
    const agentDir = join(dir, "agent");
    mkdirSync(join(agentDir, "skills", "machines"), { recursive: true });
    const memPath = join(agentDir, "MEMORY.md");
    const stFile = join(agentDir, "skills", "machines", "pvg-office-2.md");
    writeFileSync(memPath, "- global");
    writeFileSync(stFile, "- linux build host");
    chmodSync(stFile, 0o644);

    const row = { key: "k", workspace: ws, cwd: null };
    const withoutOwn = await linkSkills(row, { memoryPath: () => memPath });
    assert.equal(withoutOwn, "- global");
    const withOwn = await linkSkills(row, { memoryPath: () => memPath, ownName: () => "pvg-office-2" });
    assert.ok(withOwn.includes('<station-memory station="pvg-office-2"'));
    assert.ok(withOwn.includes("- linux build host"));

    const instrWithStation = ts.sessionInstructions(ws, null, "/repos", memPath, withOwn, "", "pvg-office-2");
    assert.ok(instrWithStation.includes("skills/machines/pvg-office-2.md"), "must name exact station file when station is known");
    assert.ok(instrWithStation.includes('skill_read {name: "machines", file: "<tag>.md"}'));
    assert.ok(instrWithStation.includes("skills/people/<name>.md"));
    assert.ok(instrWithStation.includes("YAML frontmatter"));
    assert.ok(instrWithStation.includes("update/replace it in place"));
    assert.ok(!instrWithStation.includes("<= 150 chars"));

    const instrNoStation = ts.sessionInstructions(ws, null, "/repos", memPath, "", "", "");
    assert.ok(instrNoStation.includes("skills/machines/<station-tag>.md"), "must fall back to placeholder when station is empty");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
