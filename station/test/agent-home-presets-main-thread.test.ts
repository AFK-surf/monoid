// What the station's main thread waits on as it keeps the agents' homes, its presets and a handover's file
// (src/sessions/agent-home.ts, src/agenthome/module.ts; src/sessions/presets.ts; src/sessions/hub.ts `handOver`,
// `takeUp`): nothing of node:fs's synchronous calls (station/AGENTS.md, the main thread waits on nothing). Every change
// of config.json wrote each workspace's skills and compared a stale home's transcripts whole on it; every preset read,
// changed or opened a chat with read and wrote its files there.
import assert from "node:assert/strict";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { linkSiteSkills, linkTranscripts, unlinkAgentHome, workspaceAgentHome, workspaceAgentHomePath, writeBuiltinSkills } from "../src/sessions/agent-home.ts";
import { Presets, keepCopy } from "../src/sessions/presets.ts";
import { handoverFile } from "../src/sessions/hub.ts";
import { Rig } from "./hub-fakes.ts";
import { syncCalls } from "./main-thread-sync.ts";

const dirs: string[] = [];
after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});
const temp = (name: string) => {
  const dir = mkdtempSync(join(tmpdir(), name));
  dirs.push(dir);
  return dir;
};
const line = (text: string) => `${JSON.stringify({ type: "user", text })}\n`;

test("the agents' homes kept, the deployment's skills linked and a stale home's transcripts gathered wait on no file", async () => {
  const root = temp("agent-home-main-thread-");
  const [agent, data, site] = [join(root, "agent"), join(root, "data"), join(root, "site")];
  mkdirSync(join(agent, "skills"), { recursive: true });
  mkdirSync(join(site, "machine"), { recursive: true });
  writeFileSync(join(site, "machine", "SKILL.md"), "the machine");
  // What a station before this one linked into a profile's home.
  const cc = join(data, "homes", "cc");
  mkdirSync(join(cc, "skills"), { recursive: true });
  writeFileSync(join(agent, "MEMORY.md"), "# memory\n");
  // (a link the test makes: what the station made before)
  symlinkSync(join(agent, "MEMORY.md"), join(cc, "CLAUDE.md"));
  // A profile's transcripts written before they were linked, and a home no profile names, with a copy of one of the
  // shared place's files from before it grew (its start, compared piece by piece).
  mkdirSync(join(cc, "projects", "w"), { recursive: true });
  writeFileSync(join(cc, "projects", "w", "a.jsonl"), line("mine"));
  const stale = join(data, "homes", "old");
  mkdirSync(join(stale, "projects", "w"), { recursive: true });
  const shared = join(data, "transcripts", "claude", "w");
  mkdirSync(shared, { recursive: true });
  writeFileSync(join(shared, "b.jsonl"), line("one") + line("two"));
  writeFileSync(join(stale, "projects", "w", "b.jsonl"), line("one"));
  writeFileSync(join(stale, "projects", "w", "c.jsonl"), line("only here"));
  const profiles = [{ id: "cc", runtimes: ["claude" as const], home: cc }];

  let joined = "";
  const calls = await syncCalls(async () => {
    await writeBuiltinSkills(agent, true, site);
    await linkSiteSkills(join(agent, "skills"), site);
    await unlinkAgentHome(agent, profiles);
    await linkTranscripts(data, profiles);
    // A joined workspace's, made by two at once.
    const [one, two] = await Promise.all([workspaceAgentHome(agent, "W2", "W1"), workspaceAgentHome(agent, "W2", "W1")]);
    assert.equal(one, two);
    joined = one;
  });
  assert.deepEqual(calls, []);
  assert.ok(readFileSync(join(agent, "skills", "stillfail-jobs", "SKILL.md"), "utf8").includes("job_start"));
  assert.ok(existsSync(join(agent, "skills", "stillfail-feedback", "SKILL.md")));
  assert.equal(readlinkSync(join(agent, "skills", "machine")), join(site, "machine"));
  assert.ok(!existsSync(join(cc, "CLAUDE.md")), "the old link taken away");
  assert.equal(readlinkSync(join(cc, "projects")), join(data, "transcripts", "claude"));
  assert.equal(readFileSync(join(shared, "a.jsonl"), "utf8"), line("mine"));
  assert.equal(readFileSync(join(shared, "b.jsonl"), "utf8"), line("one") + line("two"), "the longer kept: the stale one is its start");
  assert.equal(readFileSync(join(shared, "c.jsonl"), "utf8"), line("only here"));
  assert.ok(lstatSync(join(stale, "projects")).isSymbolicLink(), "the stale home's given way to the link");
  assert.equal(joined, workspaceAgentHomePath(agent, "W2", "W1"));
  assert.equal(readFileSync(join(joined, "MEMORY.md"), "utf8"), "# still.fail memory\n");
  assert.ok(existsSync(join(joined, "skills", "stillfail-jobs", "SKILL.md")));
  assert.ok(existsSync(join(joined, "skills", "stillfail-feedback", "SKILL.md")), "as the home workspace has it");
});

test("presets made, changed, carried, listed, deleted and a chat's copy kept wait on no file, and none is lost to another at once", async () => {
  const root = temp("presets-main-thread-");
  const home = join(root, "agent");
  const app = join(root, "app");
  mkdirSync(join(app, ".git"), { recursive: true });
  writeFileSync(join(app, ".git", "config"), '[remote "origin"]\n\turl = git@github.com:acme/app.git\n');
  writeFileSync(join(app, "AGENTS.md"), "# app\n" + "x".repeat(20 * 1024));
  mkdirSync(join(app, ".claude", "skills", "deploy"), { recursive: true });
  writeFileSync(join(app, ".claude", "skills", "deploy", "SKILL.md"), "deploy");
  mkdirSync(join(app, ".agents", "skills", "lint"), { recursive: true });
  writeFileSync(join(app, ".agents", "skills", "lint", "SKILL.md"), "lint");
  const presets = new Presets(() => home, () => 100, { station: () => "st", workspace: () => "ws" });
  const me = { sub: "u-me", email: "me@x.com" };
  const chat = join(root, "chat");
  mkdirSync(chat);

  const calls = await syncCalls(async () => {
    const made = await presets.add(null, { name: "App", dirs: [app], instructions: "go" }, me.email, me.sub);
    assert.equal(made.dirs[0]!.repo, "github.com/acme/app");
    const changed = await presets.put(null, made.id, { name: "App 2", dirs: [app] }, me);
    assert.equal(changed.rev, 2);
    // Ten made at once, and records carried while they are: none lost.
    const records = [1, 2, 3].map((n) => ({ ...presets.record(null, { ...changed, id: `p-carried-${n}`, name: `C${n}`, rev: 1, home: "sb" }), owner: me.sub }));
    await Promise.all([
      ...Array.from({ length: 10 }, (_, n) => presets.add(null, { name: `P${n}`, dirs: [] }, me.email, me.sub)),
      ...records.map((r) => presets.carry(null, me, [r])),
    ]);
    assert.equal((await presets.list(null)).length, 1 + 10 + 3);
    assert.equal((await presets.listed(null)).length, 1 + 10);
    assert.equal((await presets.kept(null, me)).length, 1 + 10 + 3);
    assert.equal((await presets.others(null, { sub: "u-you", email: "you@x.com" })).length, 1 + 10 + 3, "everyone else's to another");
    assert.deepEqual(await presets.others(null, me), []);
    const copy = await presets.keepFor(chat, null, made.id);
    const guide = copy.dirs[0]!.guides!.find((g) => g.file === "AGENTS.md")!;
    assert.equal(guide.whole, false);
    assert.ok(guide.text.startsWith("# app") && guide.text.length <= 16 * 1024);
    assert.deepEqual(copy.dirs[0]!.skills, ["deploy", "lint"]);
    const again = await keepCopy(join(root, "chat"), { id: "x", name: "X", dirs: [{ path: app, repo: null }], instructions: "" });
    assert.deepEqual(again.dirs[0]!.skills, ["deploy", "lint"]);
    await presets.delete(null, made.id, me);
    assert.equal(await presets.get(null, made.id), null);
  });
  assert.deepEqual(calls, []);
  const file = JSON.parse(readFileSync(join(home, "presets.json"), "utf8"));
  assert.equal(file.presets.length, 10 + 3);
  assert.deepEqual(file.gone.map((g: { id: string }) => g.id).length, 1);
  assert.equal(readlinkSync(join(chat, ".claude", "skills", "deploy")), join(app, ".claude", "skills", "deploy"));
  assert.equal(readlinkSync(join(chat, ".agents", "skills", "lint")), join(app, ".agents", "skills", "lint"));
  assert.ok(existsSync(join(chat, ".stillfail-preset.json")));
  assert.deepEqual(readdirSync(home).filter((n) => n !== "presets.json"), [], "no file left beside it");
});

test("a handover's file written and taken up waits on no file", async () => {
  const r = new Rig();
  try {
    const calls = await syncCalls(async () => {
      const handed = await r.hub.handOver();
      assert.deepEqual(handed, { sessions: [] });
    });
    assert.deepEqual(calls, []);
    assert.ok(existsSync(handoverFile(r.dir)));
    r.hub = r.newHub({ chats: () => undefined });
    const taken = await syncCalls(async () => {
      await r.hub.takeUp();
    });
    assert.deepEqual(taken, []);
    assert.ok(!existsSync(handoverFile(r.dir)), "taken away once read");
  } finally {
    await r.close();
  }
});
