// Station apps (src/apps/registry.ts, src/api/routes/apps.ts, src/tools/apps.ts): versions kept whole and made current,
// a save on a version that moved on refused, a rollback recorded as a step, the schema guard, the documents, what is
// told, the routes' workspaces and who may write, the tools, and the model's completion against a fake provider and
// through a Claude Code or Codex profile's own runtime (the real drivers, fake `claude` and `codex` on PATH, real runners).
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { appCompletion } from "../src/apps/completion.ts";
import { ClaudeDriver } from "../src/agents/claude.ts";
import { CodexDriver } from "../src/agents/codex.ts";
import type { AgentDriver } from "../src/agents/runtime.ts";
import { AppRefused, type AppEvent, Apps, DOCS_MOST } from "../src/apps/registry.ts";
import { type AppCompletion, routes } from "../src/api/routes/apps.ts";
import type { Request } from "../src/api/request.ts";
import type { Route } from "../src/api/admin.ts";
import { appTools } from "../src/tools/apps.ts";
import type { Tool } from "../src/tools/mcp.ts";

const mbui = (o: Record<string, unknown>) => new TextEncoder().encode(JSON.stringify(o));
const WASM = new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]);

function world() {
  let t = 1_000;
  const told: AppEvent[] = [];
  const apps = new Apps(new DatabaseSync(":memory:"), () => (t += 1), (e) => told.push(e));
  return { apps, told };
}

const refused = (status: number, f: () => unknown, words?: RegExp) =>
  assert.throws(f, (e: unknown) => e instanceof AppRefused && e.status === status && (words === undefined || words.test(e.message)));

test("each save is a new version kept whole, made current, and told", () => {
  const { apps, told } = world();
  const one = apps.save("w1", { id: "todo", title: "待办", kind: "mbui", source: mbui({ type: "text", text: "a" }), note: "first", by: "s1" });
  assert.deepEqual([one.rev, one.current, one.title, one.kind], [1, 1, "待办", "mbui"]);
  const two = apps.save("w1", { id: "todo", kind: "mbui", source: mbui({ type: "text", text: "b" }), note: "second", by: "s2", base: 1 });
  assert.deepEqual([two.rev, two.current, two.title], [2, 2, "待办"]);
  assert.equal(new TextDecoder().decode(apps.get("w1", "todo").source), JSON.stringify({ type: "text", text: "b" }));
  assert.equal(new TextDecoder().decode(apps.get("w1", "todo", 1).source), JSON.stringify({ type: "text", text: "a" }));
  const v = apps.versions("w1", "todo");
  assert.deepEqual(v.versions.map((x) => [x.rev, x.note, x.by]), [[2, "second", "s2"], [1, "first", "s1"]]);
  assert.match(v.versions[0]!.sha256, /^[0-9a-f]{64}$/);
  assert.deepEqual(told, [{ kind: "app", ws: "w1", id: "todo", rev: 1, current: 1 }, { kind: "app", ws: "w1", id: "todo", rev: 2, current: 2 }]);
  // One workspace's apps are not another's.
  assert.deepEqual(apps.list("w2"), []);
  refused(404, () => apps.get("w2", "todo"), /app_list/);
});

test("a save made on a version that moved on is refused, saying which to start from", () => {
  const { apps } = world();
  apps.save("w", { id: "a", kind: "mbui", source: mbui({}), note: "1", by: "x" });
  apps.save("w", { id: "a", kind: "mbui", source: mbui({ v: 2 }), note: "2", by: "y", base: 1 });
  refused(409, () => apps.save("w", { id: "a", kind: "mbui", source: mbui({ v: 3 }), note: "3", by: "x", base: 1 }), /version 2.*base_rev 2/);
  assert.equal(apps.meta("w", "a").rev, 2);
  refused(400, () => apps.save("w", { id: "a", kind: "mbui", source: mbui({}), note: " ", by: "x" }), /note is required/);
  refused(400, () => apps.save("w", { id: "Bad_Id", kind: "mbui", source: mbui({}), note: "n", by: "x" }));
  refused(400, () => apps.save("w", { id: "a", kind: "mbui", source: mbui({ app: "other" }), note: "n", by: "x" }), /"app"/);
  refused(400, () => apps.save("w", { id: "a", kind: "mbui", source: new TextEncoder().encode("{nope"), note: "n", by: "x" }), /not JSON/);
  refused(400, () => apps.save("w", { id: "a", kind: "wasm", source: WASM, note: "n", by: "x" }), /\.mbui app/);
  refused(400, () => apps.save("w", { id: "g", kind: "wasm", source: new Uint8Array([1, 2, 3, 4]), note: "n", by: "x" }), /WebAssembly/);
  assert.equal(apps.save("w", { id: "g", kind: "wasm", source: WASM, note: "n", by: "x" }).kind, "wasm");
});

test("a rollback makes an older version current, the versions as they were, and is a step of the history", () => {
  const { apps, told } = world();
  for (const n of [1, 2, 3]) apps.save("w", { id: "a", kind: "mbui", source: mbui({ n }), note: `v${n}`, by: "x" });
  told.length = 0;
  const back = apps.publish("w", { id: "a", rev: 1, by: "p@x", note: "3 broke it" });
  assert.deepEqual([back.rev, back.current], [3, 1]);
  assert.deepEqual(told, [{ kind: "app", ws: "w", id: "a", rev: 3, current: 1 }]);
  assert.equal(new TextDecoder().decode(apps.get("w", "a").source), JSON.stringify({ n: 1 }));
  const v = apps.versions("w", "a");
  assert.deepEqual(v.versions.map((x) => x.rev), [3, 2, 1]);
  assert.deepEqual(v.history.map((h) => [h.current, h.note]), [[1, "3 broke it"], [3, "v3"], [2, "v2"], [1, "v1"]]);
  refused(404, () => apps.publish("w", { id: "a", rev: 9, by: "x" }), /versions 1 to 3/);
  // The newest again; a save after a rollback goes on from the newest.
  assert.equal(apps.publish("w", { id: "a", rev: 3, by: "x" }).current, 3);
  assert.equal(apps.save("w", { id: "a", kind: "mbui", source: mbui({ n: 4 }), note: "v4", by: "x", base: 3 }).rev, 4);
});

test("a version reading an older schema than the data's is not made current unless forced", () => {
  const { apps } = world();
  apps.save("w", { id: "a", kind: "mbui", source: mbui({ schema: 1 }), note: "v1", by: "x" });
  apps.putDoc("w", { app: "a", collection: "items", id: "i1", data: { t: "old" }, by: "x" });
  apps.save("w", { id: "a", kind: "mbui", source: mbui({ schema: 2 }), note: "v2", by: "x" });
  assert.equal(apps.meta("w", "a").schema, 2);
  apps.putDoc("w", { app: "a", collection: "items", id: "i2", data: { t: "new" }, by: "x" });
  assert.deepEqual(apps.docs("w", "a", "items").map((d) => [d.id, d.schema]), [["i1", 1], ["i2", 2]]);
  refused(409, () => apps.publish("w", { id: "a", rev: 1, by: "x" }), /schema 1.*schema 2/);
  refused(409, () => apps.save("w", { id: "a", kind: "mbui", source: mbui({}), note: "v3", by: "x" }), /schema 0/);
  assert.equal(apps.meta("w", "a").current, 2);
  assert.equal(apps.publish("w", { id: "a", rev: 1, by: "x", force: true }).current, 1);
  // The save's own schema stands for a .wasm's.
  apps.save("w", { id: "g", kind: "wasm", source: WASM, note: "v1", by: "x", schema: 5 });
  assert.equal(apps.meta("w", "g").schema, 5);
});

test("documents: written whole with their rev, a write on a moved rev refused, deleted, bounded and told", () => {
  const { apps, told } = world();
  apps.save("w", { id: "a", kind: "mbui", source: mbui({}), note: "v1", by: "x" });
  told.length = 0;
  assert.deepEqual(apps.putDoc("w", { app: "a", collection: "notes", id: "n1", data: { text: "hi" }, by: "x", base: 0 }), { rev: 1 });
  assert.deepEqual(apps.putDoc("w", { app: "a", collection: "notes", id: "n1", data: { text: "hi!" }, by: "y", base: 1 }), { rev: 2 });
  refused(409, () => apps.putDoc("w", { app: "a", collection: "notes", id: "n1", data: 1, by: "x", base: 1 }), /rev 2/);
  assert.deepEqual(apps.doc("w", "a", "notes", "n1")?.data, { text: "hi!" });
  assert.deepEqual(apps.deleteDoc("w", { app: "a", collection: "notes", id: "n1" }), { deleted: true });
  assert.deepEqual(apps.deleteDoc("w", { app: "a", collection: "notes", id: "n1" }), { deleted: false });
  assert.equal(apps.doc("w", "a", "notes", "n1"), null);
  assert.deepEqual(told, [
    { kind: "app-doc", ws: "w", app: "a", collection: "notes", id: "n1", rev: 1, deleted: false },
    { kind: "app-doc", ws: "w", app: "a", collection: "notes", id: "n1", rev: 2, deleted: false },
    { kind: "app-doc", ws: "w", app: "a", collection: "notes", id: "n1", rev: 3, deleted: true },
  ]);
  refused(413, () => apps.putDoc("w", { app: "a", collection: "c", id: "big", data: "x".repeat(70_000), by: "x" }), /split/);
  refused(400, () => apps.putDoc("w", { app: "a", collection: "bad/name", id: "d", data: 1, by: "x" }));
  refused(404, () => apps.putDoc("w", { app: "none", collection: "c", id: "d", data: 1, by: "x" }));
  for (let i = 0; i < DOCS_MOST; i++) apps.putDoc("w", { app: "a", collection: "full", id: `d${String(i).padStart(4, "0")}`, data: i, by: "x" });
  refused(409, () => apps.putDoc("w", { app: "a", collection: "full", id: "one-more", data: 0, by: "x" }), /delete some/);
  assert.equal(apps.docs("w", "a", "full").length, DOCS_MOST);
});

const viewer = (workspace: string, role = "member") => ({ sub: `u-${role}`, email: `${role}@x`, name: role, role, workspace, device: "d" });
function ask(rs: Route[], method: string, path: string, v: ReturnType<typeof viewer>, body?: unknown, query: [string, string][] = []) {
  const route = rs.find((r) => r.method === method && r.pattern.test(path));
  assert.ok(route, `${method} ${path} is a route`);
  const r: Request = { method, path, query, headers: {}, body: Buffer.from(body === undefined ? "" : JSON.stringify(body)), viewer: v, lang: "en" };
  return route.handle(r, [...path.match(route.pattern)!.slice(1)]).then((a) => ({ status: a.status, body: JSON.parse((a.body as Buffer).toString("utf8")) }));
}

/// A provider that answers chat completions as an OpenAI-shaped endpoint does, and keeps what it was asked.
function provider(answer: (body: any) => { status: number; json: unknown }) {
  const asked: { url: string; headers: Record<string, string>; body: any }[] = [];
  const fetcher = (async (url: string, init: { headers?: Record<string, string>; body?: string } = {}) => {
    const body = JSON.parse(init.body ?? "{}");
    asked.push({ url, headers: init.headers ?? {}, body });
    const a = answer(body);
    return new Response(JSON.stringify(a.json), { status: a.status, headers: { "content-type": "application/json" } });
  }) as any;
  return { fetcher, asked };
}

const CONFIG = { endpoint: "https://llm.example/v1/chat/completions", key: "sk-secret", model: "m-1", headers: {} };

test("the routes: a workspace's own apps, writes only by members who may write, sources as text or base64", async () => {
  const { apps } = world();
  apps.save("w1", { id: "todo", kind: "mbui", source: mbui({ app: "todo" }), note: "v1", by: "s" });
  apps.save("w1", { id: "game", kind: "wasm", source: WASM, note: "v1", by: "s" });
  apps.save("w2", { id: "theirs", kind: "mbui", source: mbui({}), note: "v1", by: "s" });
  const rs = routes({ apps, completion: () => null });
  const member = viewer("w1");
  const reader = viewer("w1", "viewer");
  assert.deepEqual((await ask(rs, "GET", "/apps", member)).body.apps.map((a: any) => a.id), ["game", "todo"]);
  assert.equal((await ask(rs, "GET", "/apps/todo", member)).body.source, JSON.stringify({ app: "todo" }));
  assert.equal((await ask(rs, "GET", "/apps/game", member)).body.source, Buffer.from(WASM).toString("base64"));
  assert.equal((await ask(rs, "GET", "/apps/theirs", member)).status, 404);
  assert.equal((await ask(rs, "GET", "/apps/todo", member, undefined, [["rev", "7"]])).status, 404);
  // A read-only member reads, and writes nothing.
  assert.equal((await ask(rs, "GET", "/apps/todo/docs/items", reader)).status, 200);
  for (const [m, p, b] of [["PUT", "/apps/todo/docs/items/a", { data: 1 }], ["DELETE", "/apps/todo/docs/items/a", undefined], ["POST", "/apps/todo/current", { rev: 1 }], ["POST", "/apps/todo/llm", { session: "s", prompt: "hi" }]] as const) {
    const a = await ask(rs, m, p, reader, b);
    assert.equal(a.status, 403, `${m} ${p}`);
    assert.match(a.body.error, /ask an owner or admin/);
  }
  assert.deepEqual((await ask(rs, "PUT", "/apps/todo/docs/items/a", member, { data: { x: 1 } })).body, { rev: 1 });
  assert.equal((await ask(rs, "PUT", "/apps/todo/docs/items/a", member, { data: 2, base: 0 })).status, 409);
  assert.deepEqual((await ask(rs, "GET", "/apps/todo/docs/items", member)).body.docs.map((d: any) => [d.id, d.data, d.rev]), [["a", { x: 1 }, 1]]);
  assert.equal(apps.doc("w1", "todo", "items", "a")?.data !== undefined, true);
  assert.equal((await ask(rs, "PUT", "/apps/theirs/docs/items/a", member, { data: 1 })).status, 404);
  assert.deepEqual((await ask(rs, "DELETE", "/apps/todo/docs/items/a", member)).body, { deleted: true });
  apps.save("w1", { id: "todo", kind: "mbui", source: mbui({ v: 2 }), note: "v2", by: "s" });
  assert.deepEqual((await ask(rs, "POST", "/apps/todo/current", member, { rev: 1 })).body, { id: "todo", rev: 2, current: 1 });
  assert.equal((await ask(rs, "GET", "/apps/todo/versions", member)).body.history[0].by, "member@x");
});

test("the model: the chat's profile asked with its key, text only, bounded; refusals say what to do", async () => {
  const { apps } = world();
  apps.save("w1", { id: "todo", kind: "mbui", source: mbui({}), note: "v1", by: "s" });
  const chats: Record<string, AppCompletion> = {
    good: { ws: "w1", config: CONFIG },
    plain: { ws: "w1", refusal: "the chat's profile cannot answer an app: show it in a chat on a DeepSeek Harness profile" },
    elsewhere: { ws: "w2", config: CONFIG },
  };
  const p = provider((body) => ({ status: 200, json: { choices: [{ message: { content: `echo ${body.messages.at(-1).content}` } }] } }));
  const rs = routes({ apps, completion: (k) => chats[k] ?? null, fetcher: p.fetcher });
  const member = viewer("w1");
  const a = await ask(rs, "POST", "/apps/todo/llm", member, { session: "good", system: "be brief", prompt: "hello", max_tokens: 99_999 });
  assert.deepEqual(a, { status: 200, body: { text: "echo hello" } });
  assert.equal(p.asked.length, 1);
  assert.equal(p.asked[0]!.url, CONFIG.endpoint);
  assert.equal(p.asked[0]!.headers.authorization, "Bearer sk-secret");
  assert.deepEqual(p.asked[0]!.body, { model: "m-1", stream: false, max_tokens: 4096, messages: [{ role: "system", content: "be brief" }, { role: "user", content: "hello" }] });
  assert.equal("tools" in p.asked[0]!.body, false);
  const plain = await ask(rs, "POST", "/apps/todo/llm", member, { session: "plain", prompt: "hi" });
  assert.equal(plain.status, 422);
  assert.match(plain.body.error, /DeepSeek Harness/);
  assert.equal((await ask(rs, "POST", "/apps/todo/llm", member, { session: "elsewhere", prompt: "hi" })).status, 404);
  assert.equal((await ask(rs, "POST", "/apps/todo/llm", member, { session: "none", prompt: "hi" })).status, 404);
  assert.equal((await ask(rs, "POST", "/apps/todo/llm", member, { session: "good", prompt: "" })).status, 400);
  assert.equal((await ask(rs, "POST", "/apps/todo/llm", member, { session: "good", prompt: "x".repeat(40_000) })).status, 413);
  assert.equal((await ask(rs, "POST", "/apps/missing/llm", member, { session: "good", prompt: "hi" })).status, 404);
  assert.equal(p.asked.length, 1, "nothing refused reached the provider");
  // The provider failing, or answering with tool calls and no text.
  const down = routes({ apps, completion: (k) => chats[k] ?? null, fetcher: provider(() => ({ status: 429, json: {} })).fetcher });
  const d = await ask(down, "POST", "/apps/todo/llm", member, { session: "good", prompt: "hi" });
  assert.equal(d.status, 502);
  assert.match(d.body.error, /\(429\).*quota/);
  const tools = routes({ apps, completion: (k) => chats[k] ?? null, fetcher: provider(() => ({ status: 200, json: { choices: [{ message: { content: "x", tool_calls: [{}] } }] } })).fetcher });
  assert.equal((await ask(tools, "POST", "/apps/todo/llm", member, { session: "good", prompt: "hi" })).status, 502);
});

test("the tools: a file of the chat's saved as a version, listed, rolled back, its data read and written", async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "apps-tools-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const { apps } = world();
  const tools = new Map<string, Tool>(appTools(apps, (s) => (s === "s1" ? { ws: "w1", dir } : null)).map((x) => [x.name, x]));
  const call = async (name: string, args: Record<string, unknown>, session = "s1") => JSON.parse(await tools.get(name)!.run(session, args));
  await writeFile(join(dir, "todo.mbui"), JSON.stringify({ app: "todo", schema: 1 }));
  const saved = await call("app_save", { id: "todo", title: "待办", file: "todo.mbui", note: "first" });
  assert.deepEqual([saved.rev, saved.current, saved.link, saved.pinned], [1, 1, "[待办](sf-app:todo)", "sf-app:todo@1"]);
  await writeFile(join(dir, "todo.mbui"), JSON.stringify({ app: "todo", schema: 1, v: 2 }));
  assert.equal((await call("app_save", { id: "todo", file: "todo.mbui", note: "second", base_rev: 1 })).rev, 2);
  await assert.rejects(call("app_save", { id: "todo", file: "todo.mbui", note: "third", base_rev: 1 }), /someone changed it meanwhile/);
  await assert.rejects(call("app_save", { id: "todo", file: "missing.mbui", note: "x" }), /write it first/);
  await assert.rejects(call("app_save", { id: "todo", file: "todo.json", note: "x" }), /\.mbui or \.wasm/);
  await assert.rejects(call("app_list", {}, "not-a-chat"), /from a chat's agent/);
  assert.deepEqual((await call("app_list", {})).apps.map((a: any) => [a.id, a.rev]), [["todo", 2]]);
  const written = await call("app_versions", { id: "todo", rev: 1, to: "v1.mbui" });
  assert.equal(written.written.rev, 1);
  assert.equal(await readFile(join(dir, "v1.mbui"), "utf8"), JSON.stringify({ app: "todo", schema: 1 }));
  assert.equal((await call("app_publish", { id: "todo", rev: 1, note: "back" })).current, 1);
  assert.deepEqual(await call("app_data", { id: "todo", op: "set", collection: "items", doc: "a", data: { t: 1 } }), { rev: 1 });
  assert.deepEqual((await call("app_data", { id: "todo", op: "get", collection: "items", doc: "a" })).doc.data, { t: 1 });
  assert.deepEqual((await call("app_data", { id: "todo", op: "list", collection: "items" })).docs.map((d: any) => d.id), ["a"]);
  assert.deepEqual(await call("app_data", { id: "todo", op: "delete", collection: "items", doc: "a" }), { deleted: true });
  await assert.rejects(call("app_data", { id: "todo", op: "set", collection: "items" }), /doc is required/);
});

// The model through the profile's own runtime: fake executables started as the real ones are, by name on PATH.
const fake = join(dirname(fileURLToPath(import.meta.url)), "fake");
process.env.PATH = `${fake}${delimiter}${process.env.PATH}`;
// Short: the runners' sockets live under it (104 bytes at most on macOS).
const data = mkdtempSync(process.platform === "win32" ? join(tmpdir(), "al-") : "/tmp/al-");
const scratch = join(data, "run", "app-llm");
const claudeDriver = new ClaudeDriver({ data, subscriptionToken: async () => ({ token: "renewed-login", expiresAt: Date.now() + 3600_000 }) });
const skills = join(data, "skills");
mkdirSync(skills, { recursive: true });
writeFileSync(join(data, "cert.pem"), "");
const codexDriver = new CodexDriver({ data, hostSkills: skills, caBundle: join(data, "cert.pem") });
after(async () => {
  await Promise.all([claudeDriver.shutdown(), codexDriver.shutdown()]);
  rmSync(data, { recursive: true, force: true });
});
const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };
/// A promise and what resolves it.
function told() {
  let resolve!: () => void;
  const promise = new Promise<void>((r) => (resolve = r));
  return { promise, resolve };
}
const lines = (file: string) => readFileSync(file, "utf8").trim().split("\n").map((l) => JSON.parse(l));

let made = 0;
/// A chat on a subscription profile of `runtime`, the fake's starts and stdin dumped; the routes asking through it.
/// `spoke`: the turn's first words heard of the runtime (its process is at work); `over`: the turn over, its session
/// ended and its directory removed (completion.ts `turnOver`).
function onRuntime(runtime: "claude" | "codex", { runtimes = [runtime], deadline, model = null }: { runtimes?: string[]; deadline?: () => AbortSignal; model?: string | null } = {}) {
  const i = ++made;
  const home = join(data, `h${i}`);
  mkdirSync(home, { recursive: true });
  const dump = join(data, `dump${i}`);
  if (runtime === "claude") writeFileSync(join(home, ".credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "kept", refreshToken: "rt" } }));
  const profile = { id: `p${i}`, runtime, runtimes, home, model: `${runtime}-default`, access: { kind: "subscription" }, env: { FAKE_DUMP: dump }, spelling: () => null } as any;
  const row = { key: `chat:c${i}`, ws: "w1", profile: profile.id, model, runtime, cwd: "/the/chats/workspace", workspace: "/the/chats/workspace", effort: null } as any;
  const spoke = told();
  const over = told();
  const heard = (real: AgentDriver): AgentDriver => ({
    ...real,
    runtime: () => real.runtime(),
    open: (o, events) => real.open(o, (e) => {
      if (e.type === "live" && e.event.kind === "delta") spoke.resolve();
      events(e);
    }),
  } as AgentDriver);
  const side = { getSession: (k: string) => (k === row.key ? row : null), profile: () => profile, allows: () => true, home: () => "w1", driver: (r: string) => (r === "claude" ? heard(claudeDriver) : r === "codex" ? heard(codexDriver) : undefined), scratch, turnOver: over.resolve } as any;
  const { apps } = world();
  apps.save("w1", { id: "todo", kind: "mbui", source: mbui({}), note: "v1", by: "s" });
  const rs = routes({ apps, completion: (k) => appCompletion(side, k), deadline });
  const llm = (body: Record<string, unknown>) => ask(rs, "POST", "/apps/todo/llm", viewer("w1"), { session: row.key, ...body });
  return { llm, dump, row, profile, spoke: spoke.promise, over: over.promise };
}

test("the model through a Claude Code login: one turn with no tools, no MCP server and no session kept, in a directory of its own", async () => {
  const c = onRuntime("claude");
  const a = await c.llm({ system: "be brief", prompt: "say:hello there" });
  assert.deepEqual(a, { status: 200, body: { text: "hello there" } });
  const started = lines(c.dump)[0];
  const args = started.argv as string[];
  assert.ok(args.includes("-p"));
  assert.equal(args[args.indexOf("--tools") + 1], "");
  for (const flag of ["--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands"]) assert.ok(args.includes(flag), flag);
  assert.ok(!args.includes("--dangerously-skip-permissions"));
  assert.deepEqual(JSON.parse(args[args.indexOf("--mcp-config") + 1]!), { mcpServers: {} });
  assert.equal(args[args.indexOf("--model") + 1], "claude-default", "the profile's model, the chat having none");
  assert.match(args[args.indexOf("--append-system-prompt") + 1]!, /no tools[\s\S]*be brief$/);
  // On the profile's own login: its home, its token as the station renews it.
  assert.equal(started.env.CLAUDE_CONFIG_DIR, c.profile.home);
  assert.equal(started.env.CLAUDE_CODE_OAUTH_TOKEN, "renewed-login");
  assert.ok(lines(`${c.dump}.stdin`).some((m) => JSON.stringify(m).includes("say:hello there")));
  // Its process ended and its directory removed once it answered; never the chat's workspace.
  await c.over;
  assert.equal(alive(started.pid), false);
  assert.deepEqual(readdirSync(scratch), []);
});

test("the model through a Claude Code login: a process that exits says so, and one past the deadline is killed", async () => {
  const gone = onRuntime("claude");
  const a = await gone.llm({ prompt: "exit" });
  assert.equal(a.status, 502);
  assert.match(a.body.error, /^Claude Code failed to answer \(claude exited \(3\)[\s\S]*: check the chat's profile \(its sign-in, its quota\), or try again later$/);
  const late = new AbortController();
  const slow = onRuntime("claude", { deadline: () => late.signal });
  const asked = slow.llm({ prompt: "hold:1" });
  // (at work: it said its first words and holds the turn open)
  await slow.spoke;
  const pid = lines(slow.dump)[0].pid as number;
  assert.ok(alive(pid));
  late.abort();
  const b = await asked;
  assert.equal(b.status, 504);
  assert.match(b.body.error, /did not answer in 60 s: try again/);
  await slow.over;
  assert.equal(alive(pid), false);
});

test("the model through a Codex login: an ephemeral read-only thread with no shell or MCP server, in an empty directory", async () => {
  const c = onRuntime("codex", { model: "picked" });
  assert.deepEqual(await c.llm({ system: "be brief", prompt: "say:hi" }), { status: 200, body: { text: "hi" } });
  const sent = lines(`${c.dump}.stdin`);
  const start = sent.find((m) => m.method === "thread/start");
  assert.equal(start.params.sandbox, "read-only");
  assert.equal(start.params.ephemeral, true);
  assert.deepEqual(start.params.environments, []);
  assert.equal(start.params.config["features.shell_tool"], false);
  assert.equal(start.params.config["features.unified_exec"], false);
  assert.equal(start.params.config.web_search, "disabled");
  assert.equal(start.params.model, "picked", "the chat's model");
  assert.match(start.params.developerInstructions, /no tools[\s\S]*be brief$/);
  assert.ok(start.params.cwd.startsWith(scratch), "not the chat's workspace");
  assert.equal(lines(c.dump)[0].env.CODEX_HOME, c.profile.home);
  await c.over;
  assert.ok(lines(`${c.dump}.stdin`).some((m) => m.method === "thread/unsubscribe"));
  assert.equal(existsSync(start.params.cwd), false);
});

test("the model through a Codex login: an app-server that exits says so, and a turn past the deadline is interrupted", async () => {
  const late = new AbortController();
  const slow = onRuntime("codex", { deadline: () => late.signal });
  const asked = slow.llm({ prompt: "hold:1" });
  await slow.spoke;
  assert.ok(lines(`${slow.dump}.stdin`).some((m) => m.method === "turn/start"));
  late.abort();
  const b = await asked;
  assert.equal(b.status, 504);
  await slow.over;
  assert.ok(lines(`${slow.dump}.stdin`).some((m) => m.method === "turn/interrupt"));
  assert.ok(lines(`${slow.dump}.stdin`).some((m) => m.method === "thread/unsubscribe"));
  const gone = onRuntime("codex");
  const a = await gone.llm({ prompt: "exit" });
  assert.equal(a.status, 502);
  assert.match(a.body.error, /^Codex .*(installed and signed in|sign-in)/);
});

test("a profile with none of the runtimes that answer is refused, naming those that do", async () => {
  const c = onRuntime("claude", { runtimes: ["grok"] });
  const a = await c.llm({ prompt: "say:x" });
  assert.equal(a.status, 422);
  assert.match(a.body.error, /Claude Code or Codex profile can, or a DeepSeek Harness profile with a key/);
  assert.equal(existsSync(c.dump), false, "nothing was started");
});
