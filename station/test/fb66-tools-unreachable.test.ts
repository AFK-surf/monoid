// FB-66: a session taken across to another runtime (Antigravity CLI) whose processes could not reach the station's
// tools was started again twice and then given up on, every message for 16 hours, on the same profile: nothing moved it
// off, and every other session the pool sent there fell in as well. A session left to the station whose processes keep
// missing the station's tools (three in a row, the second after a backoff that outlasts a handover) now goes on on
// another profile of its runtime, else another runtime's, that profile passed over by the pool until a turn on it
// reaches them again or a while has gone; one kept to its profile stays and is told why with a way out. A single miss
// is only a restart. And the station's tools listed to Antigravity CLI stay within what it keeps whatever third-party
// MCP servers add (#8727), so a large one cannot push chat_post out of its pool again.
import assert from "node:assert/strict";
import { test } from "node:test";
import { AGY_TOOL_BUDGET, AGY_TOOL_CEILING, AGY_TOOL_WRAP } from "../src/agents/agy.ts";
import { CORE, INDIRECT, McpEndpoint, type Tool } from "../src/tools/mcp.ts";
import { FakeDriver, Rig, message, settle, testClock } from "./hub-fakes.ts";
import { stationTools } from "./station-tools.ts";

const MODEL = "gemini-4-argon";

/// A rig whose chats bound to `cl` run Antigravity CLI on MODEL, which a Claude Code profile runs as well.
function agyRig(o: { agy?: string[]; pin?: string } = {}) {
  const time = testClock();
  const heard = new Map<string, number>();
  const r = new Rig({ clock: time.clock, maxNudges: 2, toolsHeard: heard });
  const agy = new FakeDriver("agy");
  r.edit((raw) => {
    raw.profiles = [
      { id: "cc", runtime: "claude", home: "homes/cc", models: [MODEL] },
      ...(o.agy ?? ["ag"]).map((id) => ({ id, runtime: "agy", home: `homes/${id}`, models: [MODEL] })),
    ];
    raw.connects.find((c: any) => c.id === "cl").bind = { runtime: "agy", model: MODEL, ...(o.pin ? { profile: o.pin } : {}) };
  });
  r.hub = r.newHub({ chats: (id) => (id === "cl" ? r.chat : undefined), drivers: [r.claude, r.codex, agy] });
  return { r, agy, time, heard };
}

/// Its process ends its turn having never reached the station's tools; the third such in a row follows the backoff.
async function missesThrice(rig: ReturnType<typeof agyRig>, driver: FakeDriver) {
  const before = driver.count();
  driver.last().complete();
  await settle();
  assert.equal(driver.count(), before + 1, "started again at once");
  driver.last().complete();
  await settle();
  assert.equal(driver.count(), before + 1, "the next waits out the backoff");
  await rig.time.adjust(5_000);
  await settle();
  assert.equal(driver.count(), before + 2, "started again after the backoff");
  driver.last().complete();
  await settle();
}

test("FB-66: a session taken across to agy whose processes never reach the station's tools goes back to a runtime that can, and the pool passes agy over", async () => {
  const rig = agyRig();
  const { r, agy, heard } = rig;
  try {
    const m = message();
    await r.accept(m);
    await settle();
    assert.equal(agy.count(), 1);
    const key = agy.last().options.route;
    assert.deepEqual([r.session(key).runtime, r.session(key).profile], ["agy", "ag"]);

    await missesThrice(rig, agy);
    assert.equal(agy.count(), 3, "no fourth Antigravity CLI process");
    assert.equal(r.claude.count(), 1, "goes on on Claude Code rather than being given up on");
    assert.deepEqual([r.session(key).runtime, r.session(key).profile, r.session(key).model], ["claude", "cc", MODEL]);
    assert.equal(r.claude.last().options.route, key);
    assert.equal(r.claude.last().prompts.length, 1);
    assert.ok(r.chat.texts().some((t) => t.startsWith("已切换")), r.chat.texts().join("\n"));
    assert.ok(!r.chat.texts().some((t) => t.includes("未产出结果")), "not given up on");

    // It reaches them there and ends its turn.
    heard.set(key, 1);
    await r.call(key, "chat_state", { kind: "all_done", done: "answered on Claude Code" });
    r.claude.last().complete();
    await settle();
    assert.equal(r.session(key).runtime, "claude");

    // Another chat bound to agy is not sent into the same hole: it starts on Claude Code at once.
    const m2 = message();
    await r.accept(m2);
    await settle();
    assert.equal(agy.count(), 3, "no Antigravity CLI process for the next chat");
    assert.equal(r.claude.count(), 2);
    assert.equal(r.session(r.claude.last().options.route).runtime, "claude");

    // An hour on, agy is tried again.
    await rig.time.adjust(60 * 60 * 1000 + 1);
    const m3 = message();
    await r.accept(m3);
    await settle();
    assert.equal(agy.count(), 4, "agy is no longer passed over once the while has gone");
  } finally {
    await r.close();
  }
});

test("FB-66: another profile of the same runtime is tried first; one runtime's two profiles missing the tools pass the runtime over", async () => {
  const rig = agyRig({ agy: ["ag", "ag2"] });
  const { r, agy } = rig;
  try {
    await r.accept(message());
    await settle();
    const key = agy.last().options.route;
    const first = r.session(key).profile;
    const second = first === "ag" ? "ag2" : "ag";

    await missesThrice(rig, agy);
    assert.equal(r.claude.count(), 0);
    assert.equal(agy.count(), 4, "goes on in a new Antigravity CLI process");
    assert.deepEqual([r.session(key).runtime, r.session(key).profile], ["agy", second]);
    assert.equal(agy.last().options.profile.id, second);

    await missesThrice(rig, agy);
    assert.equal(agy.count(), 6);
    assert.equal(r.claude.count(), 1, "both its runtime's profiles missed them: on to Claude Code");
    assert.deepEqual([r.session(key).runtime, r.session(key).profile], ["claude", "cc"]);
  } finally {
    await r.close();
  }
});

test("FB-66: a session kept to its profile is not moved, and is told once why and what to do", async () => {
  const rig = agyRig({ pin: "ag" });
  const { r, agy } = rig;
  try {
    const m = message();
    await r.accept(m);
    await settle();
    const key = agy.last().options.route;
    assert.equal(r.session(key).profilePinned, true);

    await missesThrice(rig, agy);
    assert.equal(r.claude.count(), 0, "a pinned session is never moved");
    assert.deepEqual([r.session(key).runtime, r.session(key).profile], ["agy", "ag"]);
    const told = () => r.chat.texts().filter((t) => t.includes("连不上 station 的工具"));
    assert.equal(told().length, 1, r.chat.texts().join("\n"));
    assert.ok(told()[0]!.includes("换"), told()[0]);

    // Asked again, it misses them again: not told a second time.
    await r.accept({ ...message(), threadTs: m.threadTs, ts: `${Number(m.ts) + 1}.000100` });
    await settle();
    assert.equal(agy.count(), 4);
    await missesThrice(rig, agy);
    assert.equal(r.claude.count(), 0);
    assert.equal(told().length, 1, "told once, not every turn");
  } finally {
    await r.close();
  }
});

test("FB-66: a single miss is only a restart; the profile stays and is not passed over", async () => {
  const rig = agyRig();
  const { r, agy, heard } = rig;
  try {
    await r.accept(message());
    await settle();
    const key = agy.last().options.route;
    agy.last().complete();
    await settle();
    assert.equal(agy.count(), 2, "started again");
    // This one reaches them and ends its turn.
    heard.set(key, 1);
    await r.call(key, "chat_state", { kind: "all_done", done: "answered" });
    agy.last().complete();
    await settle();
    assert.deepEqual([r.session(key).runtime, r.session(key).profile], ["agy", "ag"]);
    assert.equal(r.claude.count(), 0);

    await r.accept(message());
    await settle();
    assert.equal(agy.count(), 3, "the next chat still starts on agy");
    assert.equal(r.claude.count(), 0);
  } finally {
    await r.close();
  }
});

test("FB-66: many third-party MCP tools keep the agy listing within AGY_TOOL_CEILING, chat_post declared, every tool still reached", async () => {
  // As a large third-party server hosted by the station adds them (#8727 `dynamicTools`): ~100 tools with long descriptions.
  const third: Tool[] = Array.from({ length: 120 }, (_, i) => ({
    name: `github_tool_number_${i}`,
    description: `Runs GitHub operation number ${i} against the repository named, with every option the upstream server supports and documents at length. ${"More words. ".repeat(10)}`,
    inputSchema: { type: "object", properties: { owner: { type: "string" }, repo: { type: "string" } }, required: ["owner", "repo"] },
    run: async (_session, args) => `ran ${i} on ${JSON.stringify(args)}`,
  }));
  const all = stationTools();
  const e = new McpEndpoint(() => "s", [...all, ...third], undefined, () => ({ budget: AGY_TOOL_BUDGET }));
  const rpc = async (method: string, params?: unknown) => ((await e.handle("POST", "Bearer t", JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }))) as any).body;
  const list: any[] = (await rpc("tools/list")).result.tools;
  const bytes = list.reduce((n, t) => n + Buffer.byteLength(JSON.stringify(t)), 0);
  const wrapped = bytes + list.length * AGY_TOOL_WRAP;
  assert.ok(bytes <= AGY_TOOL_BUDGET, `listed ${bytes} B`);
  assert.ok(wrapped <= AGY_TOOL_CEILING, `${list.length} tools, ${bytes} B listed, ${wrapped} B in agy, over ${AGY_TOOL_CEILING}`);
  const names = list.map((t) => t.name);
  for (const name of [...CORE, "search"]) assert.ok(names.includes(name), `${name} is not declared`);
  assert.equal(names.at(-1), INDIRECT);

  // Every tool left undeclared is still found: listed by station_tool called with no name, described by name, and run.
  const listed = await rpc("tools/call", { name: INDIRECT, arguments: {} });
  assert.ok(!listed.result.isError, JSON.stringify(listed));
  const text: string = listed.result.content[0].text;
  for (const t of [...all, ...third]) {
    if (names.includes(t.name) || ["adb_devices", "phone_use", "secret_reask", "station_retire"].includes(t.name)) continue;
    assert.ok(text.includes(t.name), `${t.name} not listed by station_tool`);
  }
  const described = await rpc("tools/call", { name: INDIRECT, arguments: { name: "github_tool_number_119" } });
  assert.equal(JSON.parse(described.result.content[0].text).name, "github_tool_number_119");
  const ran = await rpc("tools/call", { name: INDIRECT, arguments: { name: "github_tool_number_7", arguments: { owner: "o", repo: "r" } } });
  assert.equal(ran.result.content[0].text, 'ran 7 on {"owner":"o","repo":"r"}');

  // Without third-party tools the listing is what it was (the indirect tool's full form).
  const plain = new McpEndpoint(() => "s", all, undefined, () => ({ budget: AGY_TOOL_BUDGET }));
  const plainList: any[] = ((await plain.handle("POST", "Bearer t", JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }))) as any).body.result.tools;
  const ind = plainList.at(-1);
  assert.equal(ind.name, INDIRECT);
  assert.ok(Array.isArray(ind.inputSchema.properties.name.enum) && ind.inputSchema.properties.name.enum.length > 0);
});
