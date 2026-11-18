// The Pi driver (src/agents/pi.ts) against a fake pi (test/fake/pi: Pi's RPC as Pi 1.5 speaks it) under the real runner,
// its lines read by the station's program (mb/src/pi): turns and their steps, what it is started with (its arguments,
// environment, the provider and the station's tools its extension is given), failures, a steer in the running turn,
// abort, an extension's dialog, the process exiting, resuming, the session kept where the station reads it, and a
// session taken up by a next driver (with a snapshot, and after a crash) with its turn's end told once.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { after, describe, test } from "node:test";
import { fileURLToPath } from "node:url";
import { BRIDGE, PiDriver, piHome, piSetup, sessionFile } from "../src/agents/pi.ts";
import { piRoute, profileEnv, profileRuntimes } from "../src/agents/profiles.ts";
import type { AgentSession, OpenOptions, Profile, RuntimeEvent } from "../src/agents/runtime.ts";
import { allLeft } from "../src/agents/runner.ts";
import { learn } from "../src/accounts/catalog.ts";
import { transcriptPath } from "./reference/transcript-paths.ts";

const fake = join(dirname(fileURLToPath(import.meta.url)), "fake");
process.env.PATH = `${fake}${delimiter}${process.env.PATH}`;
// Inherited, and not to reach the agent.
process.env.PI_CODING_AGENT_DIR = "/elsewhere";
process.env.STILLFAIL_PI_KEY = "leaked";
// Short: the runners' sockets live under it (104 bytes at most on macOS).
const data = mkdtempSync(process.platform === "win32" ? join(tmpdir(), "pi-") : "/tmp/pi-");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
/// Looks every 20 ms until `done` holds: what real processes do has no event here. No deadline.
async function eventually(done: () => boolean) {
  while (!done()) await sleep(20);
}
/// The fifos a `gate:<name>` turn waits at (test/fake/pi.mjs): `open(part)` lets it go on.
function gates(dump: string, name: string) {
  const at = `${dump}.${name}`;
  if (process.platform !== "win32") for (const part of ["a", "b"]) execFileSync("/usr/bin/mkfifo", [`${at}.${part}`]);
  return { open: (part: "a" | "b") => writeFile(`${at}.${part}`, "go"), said: () => existsSync(`${at}.said`) };
}
const drivers: PiDriver[] = [];
after(async () => {
  await Promise.all(drivers.map((d) => d.shutdown()));
  rmSync(data, { recursive: true, force: true });
});

function driver() {
  const d = new PiDriver({ data });
  drivers.push(d);
  return d;
}

let n = 0;
function options(extra: Partial<OpenOptions> = {}, access: Record<string, unknown> = { kind: "opencode-go", key: "k1" }): OpenOptions & { dump: string } {
  const i = ++n;
  const home = join(data, `h${i}`);
  mkdirSync(home, { recursive: true });
  const dump = join(data, `dump${i}`);
  return {
    key: `slack:T1:C${i}:1700000000.000${i}`,
    profile: { id: "p", runtime: "pi", home, access, env: { FAKE_DUMP: dump } },
    cwd: data,
    model: "m1",
    instructions: "be brief",
    mcpToken: "fake-mcp-secret-76c49f207abe",
    mcpUrl: "http://127.0.0.1:4750/mcp",
    route: `route${i}`,
    dump,
    ...extra,
  };
}

function listen() {
  const events: RuntimeEvent[] = [];
  const push = (e: RuntimeEvent) => void events.push(e);
  const until = (what: (events: RuntimeEvent[]) => boolean) => eventually(() => what(events));
  return { events, push, until };
}

const ends = (events: RuntimeEvent[]) => events.filter((e) => e.type === "turnEnded");
const ended = (k: number) => (events: RuntimeEvent[]) => ends(events).length >= k;
const live = (events: RuntimeEvent[]) => events.flatMap((e) => (e.type === "live" ? [e.event] : []));
const deltas = (events: RuntimeEvent[]) => live(events).flatMap((e) => (e.kind === "delta" ? [e.text] : []));
const outcome = (events: RuntimeEvent[], k = 0) => (ends(events)[k] as Extract<RuntimeEvent, { type: "turnEnded" }>).outcome;
const stdin = (dump: string) => readFileSync(`${dump}.stdin`, "utf8").trim().split("\n").map((l) => JSON.parse(l));
const started = (dump: string, k = 0) => JSON.parse(readFileSync(dump, "utf8").trim().split("\n")[k]!);
/// The session's file as Pi keeps it: its messages' roles and words.
const kept = (path: string) =>
  readFileSync(path, "utf8").trim().split("\n").map((l) => JSON.parse(l)).filter((r) => r.type === "message")
    .map((r) => [r.message.role, (r.message.content ?? []).flatMap((c: any) => (c.type === "text" ? [c.text] : c.type === "toolCall" ? [`call:${c.name}`] : []))]);

describe("the Pi driver", { concurrency: true }, () => {
  test("a turn completes, from a process started with its arguments, environment, provider and the station's tools", async () => {
    const d = driver();
    const o = options({ effort: "high", skills: join(data, "skills-of-the-workspace") });
    const { events, push, until } = listen();
    const session = await d.open(o, push);
    assert.match(session.id(), /^[0-9a-f-]{36}$/, "named by the station");
    await session.prompt("say:hello");
    assert.equal(session.busy(), true);
    await until(ended(1));
    assert.deepEqual(outcome(events), { kind: "completed" });
    assert.equal(session.busy(), false);
    assert.ok(!events.some((e) => e.type === "turnStarted"), "our own prompt's turn is not one started without us");
    assert.deepEqual(live(events).filter((e) => e.kind !== "phase").map((e) => e.kind), ["start", "delta", "end", "start", "delta", "end"]);
    assert.deepEqual(live(events).filter((e) => e.kind === "start").map((e) => (e as { step: string }).step), ["thinking", "text"]);
    assert.deepEqual(deltas(events), ["thinking it over", "hello"]);

    const run = started(o.dump);
    const file = sessionFile(o.profile.home, session.id());
    const instructions = run.argv[run.argv.indexOf("--append-system-prompt") + 1];
    assert.deepEqual(run.argv, [
      "--mode", "rpc", "--offline", "--no-extensions", "-e", "builtin:mcp", "-e", BRIDGE, "--no-approve", "--no-skills", "--session", file,
      "--skill", o.skills, "--append-system-prompt", instructions, "--model", "stillfail/m1", "--thinking", "high",
    ]);
    assert.equal(readFileSync(instructions, "utf8"), "be brief", "after Pi's own, from a file of the session's");
    assert.ok(existsSync(BRIDGE));
    const env = run.env;
    assert.equal(env.PI_CODING_AGENT_DIR, piHome(o.profile.home), "the profile's own, not the person's");
    assert.equal(env.PI_TELEMETRY, "0");
    assert.equal(env.PI_SKIP_VERSION_CHECK, "1");
    assert.equal(env.STILLFAIL_PI_KEY, "k1", "the profile's key, not the station's own");
    assert.equal(env.STILLFAIL_MCP_TOKEN, o.mcpToken);
    // What the station's extension registers: OpenCode Go on pi-ai's chat completions, the session's route its header,
    // the effort taken; the station's tools at their address. No secret: the key is read from the environment.
    assert.deepEqual(JSON.parse(env.STILLFAIL_PI_SETUP), {
      tools: { url: o.mcpUrl },
      provider: {
        name: "OpenCode Go", baseUrl: "https://opencode.ai/zen/go/v1", api: "openai-completions", apiKey: "$STILLFAIL_PI_KEY",
        models: [{ id: "m1", name: "m1", reasoning: true, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
        headers: { "x-opencode-session": `stillfail-${o.route}` }, compat: { supportsDeveloperRole: false },
      },
    });
    assert.ok(!env.STILLFAIL_PI_SETUP.includes("k1") && !run.argv.join(" ").includes(o.mcpToken));

    // Opened once it answered.
    const sent = stdin(o.dump);
    assert.deepEqual(sent[0], { id: "open", type: "get_state" });
    assert.equal(sent[1].type, "prompt");
    assert.equal(sent[1].message, "say:hello");
    await assert.rejects(session.prompt("x").then(() => session.prompt("y")), /a turn is already running/);
    await until(ended(2));
    assert.equal(await session.steer("more"), false, "nothing running to steer");

    // Kept where the station reads its transcripts.
    assert.equal(transcriptPath("pi", o.profile.home, session.id()), file);
    assert.deepEqual(kept(file), [["user", ["say:hello"]], ["assistant", ["hello"]], ["user", ["x"]], ["assistant", ["x"]]]);
    await session.dispose();
    await until((e) => e.some((x) => x.type === "closed"));
  });

  test("a tool call is a step with its input and output", async () => {
    const d = driver();
    const { events, push, until } = listen();
    const session = await d.open(options(), push);
    await session.prompt("cmd");
    await until(ended(1));
    const tool = live(events).find((e) => e.kind === "start" && e.step === "tool");
    assert.deepEqual(tool, { kind: "start", id: "call_1", step: "tool", tool: "bash", input: "" });
    // Its input as it streams, its output with its result, and its end only then.
    const of = live(events).filter((e) => "id" in e && e.id === "call_1").map((e) => (e.kind === "delta" ? `${e.field}:${e.text}` : e.kind));
    assert.deepEqual(of, ["start", 'input:{"command":"ls"}', "output:a\n", "end"]);
    const phases = live(events).flatMap((e) => (e.kind === "phase" ? [e.phase] : []));
    assert.deepEqual(phases.slice(0, 4), ["requesting", "responding", "working", "requesting"]);
    assert.deepEqual(outcome(events), { kind: "completed" });
    await session.dispose();
  });

  test("a failed answer fails the turn as what Pi said; a prompt it refuses ends at once", async () => {
    const d = driver();
    const { events, push, until } = listen();
    const session = await d.open(options(), push);
    await session.prompt("fail:auth");
    await until(ended(1));
    const failed = outcome(events);
    assert.equal(failed.kind, "failed");
    assert.equal((failed as { reason: string }).reason, "auth");
    assert.match((failed as { message: string }).message, /Incorrect API key/);
    await session.prompt("refuse");
    await until(ended(2));
    assert.equal(outcome(events, 1).kind, "failed");
    assert.equal(session.busy(), false);
    await session.prompt("say:fine");
    await until(ended(3));
    assert.deepEqual(outcome(events, 2), { kind: "completed" });
    await session.dispose();
  });

  test("abort stops the turn; its end comes as aborted, and the session goes on", async () => {
    const d = driver();
    const o = options();
    const { events, push, until } = listen();
    const session = await d.open(o, push);
    await session.prompt("hold");
    await until((e) => deltas(e).includes("holding"));
    await session.abort();
    await until(ended(1));
    assert.deepEqual(outcome(events), { kind: "aborted" });
    assert.ok(stdin(o.dump).some((m) => m.type === "abort"));
    await session.prompt("say:again");
    await until(ended(2));
    assert.deepEqual(outcome(events, 1), { kind: "completed" });
    await session.dispose();
  });

  test("a steer goes into the running turn, which reads it and goes on", async () => {
    const d = driver();
    const o = options();
    const { events, push, until } = listen();
    const session = await d.open(o, push);
    await session.prompt("hold");
    await until((e) => deltas(e).includes("holding"));
    assert.equal(await session.steer("more"), true);
    await until(ended(1));
    assert.deepEqual(outcome(events), { kind: "completed" });
    assert.ok(deltas(events).includes("steer:more"), "read in the same turn");
    assert.equal(ends(events).length, 1);
    assert.ok(!events.some((e) => e.type === "turnStarted"));
    assert.ok(stdin(o.dump).some((m) => m.type === "steer" && m.message === "more"));
    await session.dispose();
  });

  test("a call to the station's tools failing as unreachable is told as toolsLost; an extension's dialog is cancelled", async () => {
    const d = driver();
    const o = options();
    const { events, push, until } = listen();
    const session = await d.open(o, push);
    await session.prompt("tools");
    await until(ended(1));
    assert.ok(events.some((e) => e.type === "toolsLost" && /ECONNREFUSED/.test(e.why)));
    await session.prompt("ask");
    await until(ended(2));
    await eventually(() => stdin(o.dump).some((m) => m.type === "extension_ui_response"));
    assert.deepEqual(stdin(o.dump).find((m) => m.type === "extension_ui_response"), { type: "extension_ui_response", id: "ui-1", cancelled: true });
    await session.dispose();
  });

  test("the process exiting during a turn fails it as exited, then closes the session", async () => {
    const d = driver();
    const { events, push, until } = listen();
    const session = await d.open(options(), push);
    await session.prompt("exit");
    await until((e) => e.some((x) => x.type === "closed"));
    const o = outcome(events);
    assert.equal(o.kind, "failed");
    assert.equal((o as { reason: string }).reason, "exited");
    await assert.rejects(session.prompt("x"), /closed/);
  });

  test("a session is resumed by its id in a new process; one Pi does not have is refused before it starts", async () => {
    const d = driver();
    const o = options();
    const a = listen();
    const first = await d.open(o, a.push);
    await first.prompt("say:one");
    await a.until(ended(1));
    const id = first.id();
    await first.dispose();
    const b = listen();
    const again = await d.open({ ...o, resume: id }, b.push);
    assert.equal(again.id(), id);
    await again.prompt("say:two");
    await b.until(ended(1));
    assert.equal(started(o.dump, 1).argv[started(o.dump, 1).argv.indexOf("--session") + 1], sessionFile(o.profile.home, id));
    assert.deepEqual(kept(sessionFile(o.profile.home, id)).filter(([role]) => role === "assistant").map(([, words]) => words), [["one"], ["two"]]);
    await again.dispose();
    await assert.rejects(d.open({ ...o, resume: "11111111-1111-4111-8111-111111111111" }, () => {}), /no Pi session/);
  });

  for (const crashed of [false, true]) {
    test(`a next driver takes the session up ${crashed ? "after a crash (no snapshot)" : "from its snapshot"}: the turn ends once, no live event twice`, async () => {
      const first = driver();
      const o = options();
      const a = listen();
      const session = await first.open(o, a.push);
      const gate = gates(o.dump, "g");
      await session.prompt("gate:g");
      await a.until((e) => deltas(e).includes("first "));
      let snapshot: unknown = null;
      // (its lines held as the hub holds them before a snapshot: hub.ts `handOver`)
      if (!crashed) await first.freeze();
      if (!crashed) snapshot = JSON.parse(JSON.stringify(session.snapshot()));
      // Stops: the process goes on under its runner, saying the rest with nobody reading.
      first.detach();
      // (the station let go before the next takes up, as the hub waits: every line handled acknowledged)
      await allLeft();
      await gate.open("a");
      await eventually(gate.said);
      const next = driver();
      const b = listen();
      // (after a crash, taken up before the station's door opened: no address of its tools known)
      const taken: AgentSession = await next.adopt({ ...o, resume: session.id(), ...(crashed ? { mcpUrl: "" } : {}) }, snapshot, b.push);
      assert.equal(taken.mcpUrl?.(), crashed ? null : o.mcpUrl);
      assert.equal(taken.id(), session.id());
      assert.equal(taken.busy(), true);
      await gate.open("b");
      await b.until(ended(1));
      const all = [...a.events, ...b.events];
      assert.equal(ends(all).length, 1, "the turn's end, once");
      assert.deepEqual(outcome(b.events), { kind: "completed" });
      assert.deepEqual(deltas(all), ["first ", "second"], "every delta once, in order");
      const starts = live(all).filter((e) => e.kind === "start").length;
      assert.equal(starts, 1);
      assert.equal(live(all).filter((e) => e.kind === "end").length, starts, "every step started ends");
      assert.equal(b.events.filter((e) => e.type === "turnStarted").length, crashed ? 1 : 0);
      await taken.prompt("say:after");
      await b.until(ended(2));
      assert.deepEqual(outcome(b.events, 1), { kind: "completed" });
      await taken.dispose();
      await b.until((e) => e.some((x) => x.type === "closed"));
      assert.ok(!a.events.some((e) => e.type === "closed"), "the first driver hears nothing after letting go");
    });
  }
});

describe("what a profile runs Pi on", () => {
  const profile = (access: Record<string, unknown>, extra: Partial<Profile> = {}): Profile => ({ id: "p", runtime: "pi", home: "/h", access, ...extra });

  test("Pi runs wherever DeepSeek Harness does: a provider's key on the protocol it speaks, OpenCode Go and Anthropic keys", () => {
    assert.ok(profileRuntimes(profile({ kind: "api-provider", provider: "openrouter", key: "k" })).includes("pi"));
    assert.ok(profileRuntimes(profile({ kind: "opencode-go", key: "k" })).includes("pi"));
    assert.ok(profileRuntimes(profile({ kind: "anthropic-api", key: "k" })).includes("pi"));
    assert.deepEqual(profileRuntimes(profile({ kind: "env" })), ["pi"]);
    assert.deepEqual(profileRuntimes(profile({ kind: "subscription" })), [], "no sign-in of Pi's here");
    // DeepSeek's own API on its chat completions (dsh has a route of its own there).
    assert.deepEqual(piRoute(profile({ kind: "api-provider", provider: "deepseek", key: "k" })), { name: "DeepSeek", api: "openai-completions", baseURL: "https://api.deepseek.com" });
    assert.deepEqual(piRoute(profile({ kind: "anthropic-api", key: "k" })), { name: "Anthropic", api: "anthropic-messages", baseURL: "https://api.anthropic.com" });
    assert.equal(piRoute(profile({ kind: "env" })), null);
    assert.deepEqual(profileEnv(profile({ kind: "api-provider", provider: "openrouter", key: "k" }), "pi"), { STILLFAIL_PI_KEY: "k" });
  });

  test("a model is needed on a provider's route; custom variables keep Pi's own configuration", () => {
    const o = options();
    const route = piRoute(profile({ kind: "opencode-go", key: "k" }));
    assert.throws(() => piSetup(route, undefined, o, "/f.jsonl", null), /names no model/);
    const own = piSetup(null, "anthropic/claude-opus-5-5", o, "/f.jsonl", null);
    assert.equal(own.setup.provider, undefined);
    assert.deepEqual(own.args.slice(own.args.indexOf("--model"), own.args.indexOf("--model") + 2), ["--model", "anthropic/claude-opus-5-5"]);
    assert.ok(!piSetup(null, undefined, o, "/f.jsonl", null).args.includes("--model"), "none named: Pi's own default");
  });

  test("the model it registers takes its window, output and images from the model catalog", () => {
    learn({ "pi-test-model": { context: 400_000, output: 64_000, input: ["text", "image"] } });
    let setup;
    try {
      setup = piSetup(piRoute(profile({ kind: "anthropic-api", key: "k" })), "pi-test-model", options({ effort: undefined }), "/f.jsonl", null).setup;
    } finally {
      learn(null);
    }
    assert.deepEqual(setup.provider.models, [{ id: "pi-test-model", name: "pi-test-model", reasoning: false, input: ["text", "image"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 400_000, maxTokens: 64_000 }]);
    assert.equal(setup.provider.compat, undefined, "Anthropic's protocol has its system prompt apart");
  });
});
