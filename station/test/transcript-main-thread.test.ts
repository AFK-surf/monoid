// What the station's main thread waits on as it looks for a session's transcripts (src/read/transcript.ts
// `transcriptPathsSoon`, `transcriptSourcesSoon`, `rememberCodexRolloutSoon`), carries a session's subagents to its new
// runtime session (src/sessions/afresh.ts `carrySubagents`), finds an archived session's files where no locator is
// (src/sessions/cold.ts `historyFilesSoon`) and makes a post's local links its attachments (src/sessions/local-links.ts
// `prepare`): nothing of node:fs's synchronous calls (station/AGENTS.md, the main thread waits on nothing). Each looked
// through every Claude project and every day of Codex's rollouts on the station's thread before, seconds of it.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import type { Profile } from "../src/agents/runtime.ts";
import { claudeProject, sharedTranscripts } from "../src/read/transcript.ts";
import { rememberCodexRolloutSoon, transcriptPathsSoon, transcriptSourcesSoon } from "../src/read/transcript-soon.ts";
import { carrySubagents } from "../src/sessions/afresh.ts";
import { ColdRooms } from "../src/sessions/cold.ts";
import type { Hub } from "../src/sessions/hub.ts";
import { prepare } from "../src/sessions/local-links.ts";
import { MANUAL } from "../src/store/store.ts";
import { Rig } from "./hub-fakes.ts";
import { syncCalls } from "./main-thread-sync.ts";
import { transcriptPaths, transcriptSources } from "./reference/transcript-paths.ts";

const dirs: string[] = [];
after(() => { for (const d of dirs) rmSync(d, { recursive: true, force: true }); });
const temp = () => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "transcript-main-thread-")));
  dirs.push(dir);
  return dir;
};
const write = (path: string, text = "{}\n") => {
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, text);
};

test("a session's transcripts are looked for through every Claude project and every day of Codex's, its home's too, waiting on no file", async () => {
  const data = temp();
  const home = join(data, "homes", "a");
  const claude = sharedTranscripts(data, "claude");
  for (let i = 0; i < 30; i++) mkdirSync(join(claude, `-other-${i}`), { recursive: true });
  // One that ran elsewhere (every project listed), one where it works (its place), one put away.
  write(join(claude, "-old-place", "before.jsonl"));
  const work = join(data, "work");
  mkdirSync(work, { recursive: true });
  write(join(claude, claudeProject(work)!, "now.jsonl"));
  write(join(claude, "-old-place", "packed.jsonl.zst"));
  // Codex's by day, in the shared place and in a home that keeps its own; one linked in.
  const codex = sharedTranscripts(data, "codex");
  for (let d = 1; d < 28; d++) mkdirSync(join(codex, "2026", "10", String(d).padStart(2, "0")), { recursive: true });
  write(join(codex, "2026", "10", "29", "rollout-2026-10-29T07-00-00-abc.jsonl"));
  write(join(home, "sessions", "2026", "11", "01", "rollout-2026-11-01T00-00-00-own.jsonl.zst"));
  write(join(data, "elsewhere", "rollout-linked.jsonl"));
  symlinkSync(join(data, "elsewhere"), join(codex, "link"), "dir");
  // A thread's own path, said before its file is there.
  const said = join(home, "sessions", "2026", "11", "02", "rollout-2026-11-02T00-00-00-said.jsonl");
  const sources = [
    { id: "before", runtime: "claude", profile: null },
    { id: "now", runtime: "claude", profile: "a" },
    { id: "abc", runtime: "codex", profile: null },
    { id: "own", runtime: "codex", profile: "a" },
  ];
  const profiles = [{ id: "a", home }];
  let found: unknown[] = [];
  const calls = await syncCalls(async () => {
    found = [
      await transcriptPathsSoon("claude", data, [home], ["before", "now", "packed", "none"], [work]),
      await transcriptPathsSoon("claude", data, [home], ["fresh"], [work], { anywhere: false }),
      await transcriptPathsSoon("codex", data, [home], ["abc", "own", "linked"]),
      await rememberCodexRolloutSoon(home, "said", said),
      await transcriptPathsSoon("codex", data, [home], ["said"], [], { anywhere: false }),
      await transcriptSourcesSoon(data, profiles, sources, [work]),
    ];
  });
  assert.deepEqual(calls, []);
  assert.deepEqual(found, [
    { paths: [join(claude, "-old-place", "before.jsonl"), join(claude, claudeProject(work)!, "now.jsonl"), join(claude, "-old-place", "packed.jsonl")], current: false },
    { paths: [], current: false },
    { paths: [join(codex, "2026", "10", "29", "rollout-2026-10-29T07-00-00-abc.jsonl"), join(home, "sessions", "2026", "11", "01", "rollout-2026-11-01T00-00-00-own.jsonl"), join(codex, "link", "rollout-linked.jsonl")], current: true },
    said,
    { paths: [], current: false },
    {
      paths: [
        { path: join(claude, "-old-place", "before.jsonl"), runtime: "claude" }, { path: join(claude, claudeProject(work)!, "now.jsonl"), runtime: "claude" },
        { path: join(codex, "2026", "10", "29", "rollout-2026-10-29T07-00-00-abc.jsonl"), runtime: "codex" },
        { path: join(home, "sessions", "2026", "11", "01", "rollout-2026-11-01T00-00-00-own.jsonl"), runtime: "codex" },
      ],
      current: true,
    },
  ]);
  // As the station found them on its thread before (test/reference/transcript-paths.ts), the same.
  assert.deepEqual(transcriptPaths("codex", data, [home], ["abc", "own", "linked"]), found[2]);
  assert.deepEqual(transcriptSources(data, profiles, sources, [work]), found[5]);
});

test("a session's subagents are carried to its new runtime session waiting on no file", async () => {
  const data = temp();
  const home = join(data, "homes", "b");
  const project = join(sharedTranscripts(data, "claude"), "-w");
  write(join(project, "from.jsonl"));
  write(join(project, "from", "subagents", "agent-x.jsonl"), "x\n");
  write(join(project, "from", "subagents", "agent-x.meta.json"), "{}");
  write(join(project, "from", "subagents", "agent-y.jsonl"), "y\n");
  const on = { id: "b", home, runtime: "claude" } as Profile;
  const hub = { config: () => ({ dataDir: data, profiles: [on] }) } as unknown as Hub;
  let carried: string[] = [];
  const calls = await syncCalls(async () => void (carried = await carrySubagents(hub, "from", "to", on, ["x", "y", "gone"])));
  assert.deepEqual(calls, []);
  assert.deepEqual(carried, ["x", "y"]);
});

test("an archived session's files are found where no locator is, waiting on no file", async () => {
  let rig!: Rig;
  const cold = new ColdRooms(() => rig.hub);
  rig = new Rig({ cold });
  try {
    rig.store.insertSession({ key: "target", connect: "cl", runtime: "claude", profile: "cc", workspace: rig.dir, runtimeSessionId: "main", token: "target", createdAt: 1, lastActiveAt: 1 });
    rig.store.ranIn("target", "main", "cc");
    rig.store.setArchived("target", true, MANUAL);
    const project = join(rig.config.profiles[0]!.home, "projects", "x");
    write(join(project, "main.jsonl"));
    write(join(project, "main", "subagents", "a.jsonl"));
    assert.equal(rig.hub.live.locateAsync, null);
    let files: string[] = [];
    let isCold = true;
    const calls = await syncCalls(async () => {
      files = await cold.historyFilesSoon("target", true);
      isCold = await cold.isCold("target");
    });
    assert.deepEqual(calls, []);
    assert.equal(files.length, 2);
    assert.equal(isCold, false);
  } finally { await rig.close(); }
});

test("a post's local links are made its attachments waiting on no file of the station's own", async () => {
  const dir = temp();
  write(join(dir, "report.pdf"), "pdf");
  // (the addon is loaded as the station starts, before it serves)
  prepare("", [], dir);
  const paths: string[] = [];
  let text = "";
  const calls = await syncCalls(async () => void (text = prepare(`see [the report](${join(dir, "report.pdf")})`, paths, dir)));
  assert.deepEqual(calls, []);
  assert.equal(text, "see [the report](report%2Epdf)");
  assert.deepEqual(paths, [join(dir, "report.pdf")]);
});
