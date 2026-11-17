// Search-to-read behavior across stations, scoped to the requesting session's workspace.
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { searchTools, type SearchDeps } from "../src/search/tool.ts";
import { formatSkillFromCatalog, type SkillCatalog, skillForPeer, SKILL_READ } from "../src/search/skills.ts";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { memory } from "./reference/memory.ts";
import { readersOf } from "./reference.ts";
import { Store } from "../src/store/store.ts";

function fixture(t: { after(fn: () => void): void }) {
  const data = mkdtempSync(join(tmpdir(), "skill-read-"));
  t.after(() => rmSync(data, { recursive: true, force: true }));
  for (const [dir, text] of [["agent", "home instructions"], ["agent/workspaces/W2", "joined instructions"]]) {
    const skill = join(data, dir!, "skills/mbui");
    mkdirSync(skill, { recursive: true });
    writeFileSync(join(skill, "SKILL.md"), text!);
    writeFileSync(join(skill, "render.md"), `${text}: offscreen reference`);
  }
  return data;
}

/// A workspace's catalog as GET /memory answered it before the readers did (test/reference/memory.ts).
const catalogOf = (data: string) => async (ws?: string): Promise<SkillCatalog> => memory(data, ws);

function deps(data: string, readCatalog = catalogOf(data)): SearchDeps {
  return {
    search: { query: async () => ({ groups: [], building: false }) } as unknown as SearchDeps["search"],
    readSkill: async (ws, name, file) => formatSkillFromCatalog(await readCatalog(ws), name, file),
    workspaceOf: () => ({ workspace: "W2", home: false }),
    link: () => undefined,
    stations: async () => [{ id: "local", name: "orchard", here: true }, { id: "remote", name: "cedar", here: false }],
    ask: async (_station, request) => request.method === SKILL_READ
      ? skillForPeer(readCatalog, request, String(request.workspace), "W1")
      : { groups: [{ kind: "skill", more: false, hits: [{ key: "k:W2:mbui", kind: "skill", skill: "mbui", title: "mbui", text: "offscreen", at: null }] }] },
  };
}

const tool = (d: SearchDeps, name: string) => searchTools(d).find((t) => t.name === name)!;

test("search gives a usable remote skill read call, carrying the session workspace", async (t) => {
  const d = deps(fixture(t));
  const calls: Record<string, unknown>[] = [];
  const ask = d.ask;
  d.ask = async (station, request) => { calls.push(request); return ask(station, request); };
  const result = await tool(d, "search").run("session", { query: "offscreen", kinds: ["skill"] });
  const args = JSON.parse(result.match(/read with skill_read (\{[^\n]+\})/)![1]!);
  assert.deepEqual(args, { station: "remote", name: "mbui" });
  const read = await tool(d, "skill_read").run("session", args);
  assert.match(read, /joined instructions/);
  assert.doesNotMatch(read, /home instructions/);
  assert.ok(calls.every((c) => c.workspace === "W2"));
  assert.match(await tool(d, "skill_read").run("session", { ...args, file: "render.md" }), /offscreen reference/);
});

test("local and peer readers use only the selected workspace catalog and listed files", async (t) => {
  const data = fixture(t);
  const d = deps(data);
  const read = tool(d, "skill_read");
  assert.match(await read.run("session", { name: "mbui" }), /joined instructions/);
  assert.match(await read.run("session", { name: "mbui", station: "orchard" }), /joined instructions/);
  assert.match((await skillForPeer(catalogOf(data), { name: "mbui" }, "W1", "W1")).text, /home instructions/);
  await assert.rejects(skillForPeer(catalogOf(data), { name: "mbui" }, "W3", "W1"), /No skill/);
  for (const args of [{ name: "../mbui" }, { name: "mbui", file: "../MEMORY.md" }, { name: "mbui", file: "/etc/passwd" }, { name: "mbui", file: "missing.md" }]) {
    await assert.rejects(read.run("session", args), /No skill|No file/);
  }
  d.workspaceOf = () => null;
  await assert.rejects(read.run("unknown", { name: "mbui" }), /unknown session/);
});

test("remote failures, old stations and ambiguous station names are explicit", async (t) => {
  const d = deps(fixture(t));
  const read = tool(d, "skill_read");
  await assert.rejects(read.run("s", { name: "mbui", station: "missing" }), /No such station/);
  d.ask = async () => ({ error: "unknown method" });
  await assert.rejects(read.run("s", { name: "mbui", station: "cedar" }), /may need an update/);
  d.ask = async () => { throw new Error("station offline"); };
  await assert.rejects(read.run("s", { name: "mbui", station: "cedar" }), /station offline/);
  d.stations = async () => [{ id: "a", name: "same", here: false }, { id: "b", name: "same", here: false }];
  await assert.rejects(read.run("s", { name: "mbui", station: "same" }), /ambiguous/);
});

test("skill_read and skill.read read the catalog through the MoonBit readers, as the reference reads it", { skip: mbReaderBinary() === null ? "the MoonBit program is not built here" : false }, async (t) => {
  const data = fixture(t);
  // (the readers open the station's database, as on a station)
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const readers = readersOf(data, mbReaderBinary());
  t.after(() => (readers.close(), store.close()));
  // As search/module.ts reads it: GET /memory's op, of the workspace asked (none: the home one's).
  const program = async (ws?: string): Promise<SkillCatalog> => JSON.parse(await readers.read("memory", ws ? { workspace: ws } : {}, "zh"));
  const reference = catalogOf(data);
  const read = tool(deps(data, program), "skill_read");
  const before = tool(deps(data, reference), "skill_read");
  for (const args of [{ name: "mbui" }, { name: "mbui", file: "render.md" }, { name: "mbui", station: "cedar" }, { name: "mbui", station: "cedar", file: "render.md" }]) {
    const said = await read.run("session", args);
    assert.equal(said, await before.run("session", args));
    assert.match(said, /^Skill "mbui", file "(SKILL|render)\.md"\nAvailable files: "SKILL.md", "render.md"\n\njoined instructions/);
  }
  for (const [ws, home] of [["W1", "W1"], [null, "W1"], ["W2", "W1"]] as const)
    assert.deepEqual(await skillForPeer(program, { name: "mbui", file: "render.md" }, ws, home), await skillForPeer(reference, { name: "mbui", file: "render.md" }, ws, home));
  for (const args of [{ name: "missing" }, { name: "mbui", file: "missing.md" }]) {
    const why = await before.run("session", args).then(() => "", (e: Error) => e.message);
    await assert.rejects(read.run("session", args), { message: why });
  }
});
