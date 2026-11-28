// The GitHub Copilot driver (src/agents/copilot.ts) and the station's own program it runs (assets/agents/copilot-bridge.mjs)
// under the real runner, read by the station's program as Cursor's: the profile's token alone (none: not opened, no
// login of the machine's borrowed), what the bridge is given, a subagent refused the tools a session speaks by, and,
// with GitHub's SDK and its runtime (STILLFAIL_TEST_COPILOT_SDK: the package's directory, its platform's runtime package
// with it) against a local model and the station's tools on 127.0.0.1, turns end to end: streamed text, a call of the
// station's tools, a subagent's call refused before it is made, each model call's usage and the transcript as the
// history and usage readers read them, a steer into the running turn, cancel, compaction, another model and effort,
// and the session resumed by a next process.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, describe, test } from "node:test";
import { fileURLToPath } from "node:url";
import { callOf, countsOf, ownConfig, refusal, resultOf } from "../assets/agents/copilot-bridge.mjs";
import { CopilotDriver, NOT_SIGNED_IN, SILENT, chatModels, copilotHome, copilotRules, copilotToken } from "../src/agents/copilot.ts";
import { CommandMissing } from "../src/agents/runner.ts";
import type { AgentSession, OpenOptions, Profile, RuntimeEvent } from "../src/agents/runtime.ts";
import { SLACK_SPOKEN, SPEAKS } from "../src/tools/mcp.ts";
import { readTimeline, transcriptPath } from "./reference/transcript.ts";
import { callsOf } from "./usage-counter-reference.ts";
import { startMcp, startModel } from "./fake/copilot-model.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const envBridge = join(here, "fake", "copilot-env-bridge.mjs");
const sdk = process.env.STILLFAIL_TEST_COPILOT_SDK;
const noSdk = sdk === undefined || !existsSync(join(sdk, "package.json")) ? "GitHub's Copilot SDK is not installed here (STILLFAIL_TEST_COPILOT_SDK: its package's directory)" : false;
// Inherited, and never to reach the runtime: a login of the machine's.
for (const name of ["GH_TOKEN", "GITHUB_TOKEN", "COPILOT_GITHUB_TOKEN"]) process.env[name] = "gho_machine";
process.env.COPILOT_HOME = "/machine/copilot";
// Short: the runners' sockets live under it (104 bytes at most on macOS).
const data = mkdtempSync(process.platform === "win32" ? join(tmpdir(), "cp-") : "/tmp/cp-");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
/// Looks every 20 ms until `done` holds: what real processes do has no event here. No deadline.
async function eventually(done: () => boolean) {
  while (!done()) await sleep(20);
}
const drivers: CopilotDriver[] = [];
const servers: { close(): void }[] = [];
after(async () => {
  await Promise.all(drivers.map((d) => d.shutdown()));
  for (const s of servers) s.close();
  rmSync(data, { recursive: true, force: true });
});

const profile = (access: Record<string, unknown> = {}, env: Record<string, unknown> = {}, home = "/tmp/copilot"): Profile =>
  ({ id: "copilot", runtime: "copilot", home, access, env }) as Profile;

let n = 0;
function options(extra: Partial<OpenOptions> = {}, token: string | null = "gho_profile"): OpenOptions & { dump: string } {
  const i = ++n;
  const home = join(data, `h${i}`);
  mkdirSync(copilotHome(home), { recursive: true });
  if (token !== null) writeFileSync(join(copilotHome(home), "github-token"), `${token}\n`);
  const skills = join(data, `skills${i}`);
  mkdirSync(skills, { recursive: true });
  return {
    key: `slack:T1:C${i}:1700000000.000${i}`,
    profile: { id: "cp", runtime: "copilot", home, access: { kind: "subscription" } },
    cwd: data,
    instructions: "be brief",
    skills,
    mcpToken: "tok",
    mcpUrl: "http://127.0.0.1:4750/mcp",
    route: `route${i}`,
    dump: join(data, `dump${i}`),
    ...extra,
  };
}

function listen() {
  const events: RuntimeEvent[] = [];
  const push = (e: RuntimeEvent) => void events.push(e);
  const until = (what: (events: RuntimeEvent[]) => boolean) => eventually(() => what(events));
  return { events, push, until };
}
const ends = (events: RuntimeEvent[]) => events.filter((e) => e.type === "turnEnded") as Extract<RuntimeEvent, { type: "turnEnded" }>[];
const ended = (k: number) => (events: RuntimeEvent[]) => ends(events).length >= k;
const live = (events: RuntimeEvent[]) => events.flatMap((e) => (e.type === "live" ? [e.event] : []));
const said = (events: RuntimeEvent[]) => live(events).flatMap((e) => (e.kind === "delta" && e.field === "text" ? [e.text] : [])).join("");

describe("the Copilot driver's rules", () => {
  test("its instructions name the station's tools as Copilot does, not mcp__stillfail__", () => {
    const rules = copilotRules("Be brief.");
    assert.match(rules, /^Be brief\./);
    assert.match(rules, /stillfail-chat_post/);
    assert.doesNotMatch(rules, /mcp__stillfail__/);
  });

  test("its models: GitHub's chat models with no policy or an enabled one; none disabled, unconfigured or not for chat", () => {
    const chat = { type: "chat" };
    const body = {
      data: [
        { id: "gpt-5.4", policy: { state: "enabled" }, capabilities: chat },
        { id: "gemini-4-hydrogen", model_picker_enabled: true, capabilities: chat },
        { id: "grok-4.7", policy: null, capabilities: chat },
        { id: "claude-opus-5-5", policy: { state: "disabled" }, capabilities: chat },
        { id: "o9", policy: { state: "unconfigured" }, capabilities: chat },
        { id: "text-embedding-3", capabilities: { type: "embeddings" } },
        { policy: { state: "enabled" }, capabilities: chat },
      ],
    };
    assert.deepEqual(chatModels(body), ["gpt-5.4", "gemini-4-hydrogen", "grok-4.7"]);
    assert.deepEqual(chatModels(null), []);
    assert.deepEqual(chatModels({ data: "none" }), []);
  });

  test("a profile's token is its own: its key, its own variable, its sign-in; none borrowed from the machine", async () => {
    assert.equal(await copilotToken(profile({ key: "gho_abc" })), "gho_abc");
    assert.equal(await copilotToken(profile({ key: "github_pat_abc" })), "github_pat_abc");
    assert.equal(await copilotToken(profile({}, { COPILOT_GITHUB_TOKEN: "ghu_abc" })), "ghu_abc");
    const home = join(data, "kept");
    mkdirSync(copilotHome(home), { recursive: true });
    writeFileSync(join(copilotHome(home), "github-token"), "gho_kept\n");
    assert.equal(await copilotToken(profile({}, {}, home)), "gho_kept");
    // GH_TOKEN, GITHUB_TOKEN and COPILOT_GITHUB_TOKEN are the machine's here (above): nothing of them.
    assert.equal(await copilotToken(profile({ key: "sk-not-github" }, {}, join(data, "none"))), undefined);
    assert.equal(await copilotToken(profile({ key: "ghp_classic" }, {}, join(data, "none"))), undefined);
  });

  test("a subagent's call of a tool a session speaks by is refused; its reads, and the main agent's calls, are not", () => {
    const sub = (toolName: string, toolArgs: unknown = {}) => refusal({ agentId: "a1", toolName, toolArgs }, SILENT);
    for (const tool of SPEAKS) assert.match(sub(`stillfail-${tool}`) ?? "", new RegExp(`you are a subagent, and ${tool} is only`));
    assert.equal(refusal({ toolName: "stillfail-chat_post" }, SILENT), null, "the session's own agent");
    assert.equal(refusal({ agentId: "", toolName: "stillfail-chat_post" }, SILENT), null);
    assert.equal(sub("stillfail-read_file"), null);
    assert.equal(sub("powershell"), null);
    assert.equal(sub("other-chat_post"), null, "another server's tool of that name");
    assert.equal(sub("stillfail-slack_api", { method: "conversations.history" }), null);
    assert.match(sub("stillfail-slack_api", { method: " chat.postMessage" }) ?? "", /writing to Slack \(chat\.postMessage\)/);
    assert.ok(SLACK_SPOKEN.every((m) => sub("stillfail-slack_api", { method: m }) !== null));
  });

  test("a profile's own MCP servers and skills, from its Copilot directory; the station's server name stays the station's", () => {
    assert.deepEqual(ownConfig(undefined), { servers: {}, skills: null });
    const none = join(data, "own-none");
    mkdirSync(none, { recursive: true });
    assert.deepEqual(ownConfig(none), { servers: {}, skills: null }, "nothing given: nothing added");
    const dir = join(data, "own");
    mkdirSync(join(dir, "skills"), { recursive: true });
    const ado = { type: "stdio", command: "npx", args: ["-y", "@azure-devops/mcp", "org"], tools: ["*"] };
    const remote = { type: "http", url: "https://example.test/mcp", headers: { Authorization: "Bearer k" } };
    const ours = { type: "http", url: "http://127.0.0.1:1/mcp" };
    writeFileSync(join(dir, "mcp-config.json"), JSON.stringify({ mcpServers: { ado, remote, stillfail: ours, StillFail: ours, "stillfail-x": ours, odd: "no" } }));
    assert.deepEqual(ownConfig(dir), { servers: { ado, remote }, skills: join(dir, "skills") });
    writeFileSync(join(dir, "mcp-config.json"), "{ not json");
    assert.throws(() => ownConfig(dir), /mcp-config.json is not JSON/);
  });

  test("its calls, results and counts as Cursor's lines have them", () => {
    assert.deepEqual(callOf({ toolName: "stillfail-chat_post", mcpServerName: "stillfail", mcpToolName: "chat_post", arguments: { text: "hi" } }), { name: "mcp", args: { providerIdentifier: "stillfail", toolName: "chat_post", args: { text: "hi" } } });
    assert.deepEqual(callOf({ toolName: "powershell", arguments: { command: "ls" } }), { name: "powershell", args: { command: "ls" } });
    assert.equal(resultOf({ success: true, result: { content: "out" } }), "out");
    assert.equal(resultOf({ success: false, error: { message: "Denied", code: "denied" } }), "Denied");
    // The runtime counts what the cache read in the input, as OpenAI's API does.
    assert.deepEqual(countsOf({ inputTokens: 100, cacheReadTokens: 40, cacheWriteTokens: 3, outputTokens: 7 }), { inputTokens: 60, cacheReadTokens: 40, cacheWriteTokens: 3, outputTokens: 7 });
  });
});

describe("the Copilot driver", { concurrency: true }, () => {
  function driver(extra: Record<string, unknown> = {}, bridge?: string, sdkDir?: string) {
    const d = new CopilotDriver({ data, extra, ...(bridge !== undefined ? { bridge } : {}), ...(sdkDir !== undefined ? { sdk: sdkDir } : {}) });
    drivers.push(d);
    return d;
  }

  test("the bridge is given the profile's token, the station's tools' token and what a subagent may not call; nothing of the machine's", async () => {
    const o = options({ model: "gpt-5.5", effort: "high" });
    const d = driver({ dump: o.dump }, envBridge, data);
    const { push } = listen();
    const session = await d.open(o, push);
    assert.equal(session.id(), "fake-session");
    const [{ env, open }] = readFileSync(o.dump, "utf8").trim().split("\n").map((l) => JSON.parse(l));
    assert.equal(env.STILLFAIL_COPILOT_TOKEN, "gho_profile");
    assert.equal(env.STILLFAIL_MCP_TOKEN, "tok");
    assert.equal(env.STILLFAIL_COPILOT_SDK, data);
    for (const name of ["GH_TOKEN", "GITHUB_TOKEN", "COPILOT_GITHUB_TOKEN", "COPILOT_HOME"]) assert.equal(env[name], undefined, name);
    assert.deepEqual(open.silent, { tools: SPEAKS, slackWrites: SLACK_SPOKEN });
    assert.equal(open.model, "gpt-5.5");
    assert.equal(open.effort, "high");
    assert.equal(open.instructions, copilotRules("be brief"));
    assert.equal(open.skills, o.skills);
    assert.equal(open.own, copilotHome(o.profile.home), "the profile's own Copilot directory, not the machine's");
    assert.equal(open.sessions, join(copilotHome(o.profile.home), "sessions"));
    await session.dispose();
  });

  test("a profile not signed in is not opened, and says so; no process is started", async () => {
    const o = options({}, null);
    const d = driver({ dump: o.dump }, envBridge, data);
    await assert.rejects(d.open(o, () => {}), (e: Error) => e.message === NOT_SIGNED_IN);
    assert.ok(!existsSync(o.dump));
  });

  test("with no SDK installed in the station's runtimes the session waits for it as for a missing command", async () => {
    const d = driver();
    await assert.rejects(d.open(options(), () => {}), (e: Error) => e instanceof CommandMissing);
  });
});

describe("the Copilot driver on GitHub's SDK", { concurrency: false, skip: noSdk }, () => {
  type Reply = { text?: string[]; tool?: { id: string; name: string; args: unknown }; status?: number; hold?: Promise<void> };
  const lastOf = (body: any) => {
    const messages = body?.messages ?? [];
    const last = messages.at(-1);
    return { last, text: typeof last?.content === "string" ? last.content : JSON.stringify(last?.content ?? "") };
  };
  /// The request held back, once it came (`holding`: as it is now, past what TypeScript narrows).
  let held: { arrived: boolean; go: () => void } | null = null;
  const holding = () => held;
  const hold = () => {
    const h = Promise.withResolvers<void>();
    held = { arrived: false, go: () => h.resolve() };
    return h.promise;
  };
  const script = (body: any): Reply => {
    const { last, text } = lastOf(body);
    if (last?.role === "tool") return { text: ["done"] };
    if (text.includes("SUBAGENT-POSTS")) return { tool: { id: "s1", name: "stillfail-chat_post", args: { text: "from the subagent" } } };
    if (text.includes("delegate")) return { tool: { id: "task1", name: "task", args: { agent_type: "general-purpose", description: "sub", prompt: "SUBAGENT-POSTS", name: "sub" } } };
    if (text.includes("post")) return { tool: { id: "t1", name: "stillfail-chat_post", args: { text: "hi" } } };
    if (text.includes("hold")) {
      const promise = hold();
      held!.arrived = true;
      return { text: ["late"], hold: promise };
    }
    return { text: ["Hel", "lo"] };
  };

  async function world() {
    const model = await startModel(script);
    const mcp = await startMcp(["chat_post", "chat_state", "read_file"]);
    servers.push(model.server, mcp.server);
    const provider = { github: { capi: { enabled: false } }, inference: { providers: [{ name: "local", type: "openai", baseUrl: model.url, apiKey: "local" }], models: [{ id: "m1", provider: "local" }], defaultProvider: "local" } };
    const d = new CopilotDriver({ data, sdk, extra: { provider } });
    drivers.push(d);
    return { model, mcp, d };
  }

  test("turns end to end: text, the station's tool, a subagent refused, usage and transcript, steer, cancel, compaction, another model, resumed", async () => {
    const { model, mcp, d } = await world();
    const o = options({ model: "m1", mcpUrl: mcp.url });
    const { events, push, until } = listen();
    const session: AgentSession = await d.open(o, push);
    assert.match(session.id(), /^[0-9a-f-]{36}$/);

    // Streamed text, no deadline of the station's: the turn ends as the runtime goes idle.
    await session.prompt("hello");
    await until(ended(1));
    assert.deepEqual(ends(events)[0]!.outcome, { kind: "completed" });
    assert.equal(said(events), "Hello");
    // The station's instructions after Copilot's own, its tools as stillfail-<tool>, its built-in coding tools there.
    const first = model.requests.find((r: any) => Array.isArray(r.body?.messages))!.body;
    assert.match(JSON.stringify(first.messages[0]), /be brief/);
    const names = first.tools.map((t: any) => t.function.name);
    for (const name of ["stillfail-chat_post", "stillfail-read_file", "task", "view", "edit"]) assert.ok(names.includes(name), name);

    // The station's tool, called with the session's token; a subagent's call of it refused before it is made.
    await session.prompt("post it");
    await until(ended(2));
    await session.prompt("delegate it");
    await until(ended(3));
    const calls = mcp.calls.filter((c: any) => c.message.method === "tools/call");
    assert.deepEqual(calls.map((c: any) => [c.headers.authorization, c.message.params.name, c.message.params.arguments]), [["Bearer tok", "chat_post", { text: "hi" }]]);
    const refused = model.requests.find((r: any) => JSON.stringify(r.body?.messages ?? []).includes("you are a subagent, and chat_post is only"));
    assert.ok(refused, "the subagent's model was told why");
    const tool = live(events).find((e) => e.kind === "start" && e.step === "tool") as { tool: string; input: string };
    assert.equal(tool.tool, "mcp__stillfail__chat_post");
    assert.deepEqual(JSON.parse(tool.input), { text: "hi" });

    // A steer into the turn under way; then cancel one.
    held = null;
    await session.prompt("hold on");
    await eventually(() => holding()?.arrived === true);
    assert.equal(await session.steer("and this"), true);
    holding()!.go();
    await until(ended(4));
    assert.deepEqual(ends(events)[3]!.outcome, { kind: "completed" });
    held = null;
    await session.prompt("hold again");
    await eventually(() => holding()?.arrived === true);
    await session.abort();
    await until(ended(5));
    assert.deepEqual(ends(events)[4]!.outcome, { kind: "aborted" });
    holding()!.go();

    // Compaction asked for: a turn of its own, the context said compacted.
    await session.compact!();
    await until(ended(6));
    assert.ok(events.some((e) => e.type === "compacted"));

    // Another model and effort between turns, no new process.
    assert.equal(session.retune!({ ...o, model: "m1", effort: "low" }), true);
    await session.prompt("hello again");
    await until(ended(7));
    assert.deepEqual(ends(events)[6]!.outcome, { kind: "completed" });

    // What the history and the usage read.
    const path = transcriptPath("copilot", o.profile.home, session.id())!;
    assert.equal(path, join(copilotHome(o.profile.home), "sessions", `${session.id()}.jsonl`));
    const timeline = readTimeline("copilot", path).map(({ kind, text, tool }) => [kind, tool ?? null, text]);
    assert.deepEqual(timeline.slice(0, 6), [
      ["user", null, "hello"],
      ["assistant", null, "Hello"],
      ["user", null, "post it"],
      ["tool_call", "mcp__stillfail__chat_post", JSON.stringify({ text: "hi" }, null, 2)],
      ["tool_result", null, "called chat_post"],
      ["assistant", null, "done"],
    ]);
    assert.ok(timeline.some(([kind, , text]) => kind === "user" && text === "and this"), "the steered message in its place");
    const usage = callsOf("copilot", readFileSync(path, "utf8"), false, { model: null, codexId: null });
    assert.ok(usage.length >= 8, `each model call counted (${usage.length})`);
    assert.deepEqual(usage.map(({ input, cacheRead, output }) => ({ input, cacheRead, output }))[0], { input: 60, cacheRead: 40, output: 7 });

    // A next process resumes it: the conversation so far is the model's.
    const id = session.id();
    await session.dispose();
    const b = listen();
    const again = await d.open({ ...o, resume: id }, b.push);
    assert.equal(again.id(), id);
    await again.prompt("once more");
    await b.until(ended(1));
    assert.deepEqual(ends(b.events)[0]!.outcome, { kind: "completed" });
    const resumed = model.requests.at(-1)!.body;
    assert.match(JSON.stringify(resumed.messages), /hello again/);
    await again.dispose();
  });
});
