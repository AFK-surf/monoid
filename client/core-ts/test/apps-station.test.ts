// Station apps end to end, a core over the station's own code (station/src/apps/registry.ts, api/routes/apps.ts,
// tools/apps.ts, apps/completion.ts and sessions/text-runtime.ts): an agent saves an app with its tool, the core reads it
// (`app.get`), writes a document (`app.putDoc`) that a watcher (`app.watch`) hears of on the station's event stream,
// asks the chat's model through a Claude Code and a Codex profile (fake drivers on the station's real text-only turn),
// and hears a second version and a rollback; a save on a version that moved on is refused. With 实验性功能's 站点应用
// off (features.ts `apps`, the default) every app call is refused here, saying where to turn it on, and the station is
// asked nothing. The station's network is the core tests' own (station-fixture.ts); the time is the test's clock.
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import type { AgentDriver, AgentSession, OpenOptions, RuntimeEvent } from "../../../station/src/agents/runtime.ts";
import type { Route } from "../../../station/src/api/admin.ts";
import type { Request } from "../../../station/src/api/request.ts";
import { routes } from "../../../station/src/api/routes/apps.ts";
import { appCompletion } from "../../../station/src/apps/completion.ts";
import { Apps, appEventTold } from "../../../station/src/apps/registry.ts";
import { appTools } from "../../../station/src/tools/apps.ts";
import type { HttpRequest, HttpResponse } from "../src/host.ts";
import type { CoreMessage } from "../src/protocol.ts";
import { jsonResponse } from "../src/testing.ts";
import { call } from "./helpers.ts";
import { started, stationLater } from "./station-fixture.ts";

// deno-lint-ignore no-explicit-any
type J = any;

const STATION = "ws/st";
const UI = 1;

const dirs: string[] = [];
after(async () => {
  for (const d of dirs) await rm(d, { recursive: true, force: true });
});

/// A runtime's driver that answers one text-only turn at once with `<runtime>:<prompt>`, keeping what it was opened with
/// and whether each session was disposed.
function fakeDriver(runtime: "claude" | "codex") {
  const opened: { options: OpenOptions; disposed: boolean }[] = [];
  const driver = {
    runtime: () => runtime,
    open: async (options: OpenOptions, events: (e: RuntimeEvent) => void): Promise<AgentSession> => {
      const kept = { options, disposed: false };
      opened.push(kept);
      return {
        id: () => `${runtime}-1`,
        busy: () => false,
        prompt: async (text: string) => {
          events({ type: "live", event: { kind: "start", id: "t1", step: "text" } });
          events({ type: "live", event: { kind: "delta", id: "t1", field: "text", text: `${runtime}:${text}` } });
          events({ type: "turnEnded", outcome: { kind: "completed" } });
        },
        steer: async () => false,
        backgroundTools: async () => {},
        abort: async () => {},
        dispose: async () => {
          kept.disposed = true;
        },
      } as unknown as AgentSession;
    },
    adopt: async () => {
      throw new Error("nothing to take up");
    },
    shutdown: async () => {},
    detach: () => {},
  } as unknown as AgentDriver;
  return { driver, opened };
}

/// The station of workspace `ws`: its apps in memory, what they tell given to `tell` (its event stream), an agent's
/// chat `k1` (working in `dir`) on a Claude Code profile and a chat `k2` on a Codex one, its routes answering the core's
/// requests (each answer kept as a promise the test can wait on: what the station does is its own, off the core's clock).
async function station(tell: (name: string, data: unknown) => void) {
  const dir = await mkdtemp(join(tmpdir(), "apps-e2e-"));
  dirs.push(dir);
  const apps = new Apps(new DatabaseSync(":memory:"), (() => {
    let t = 1_000;
    return () => (t += 1);
  })(), (e) => {
    const said = appEventTold(e);
    tell(said.name, said.data);
  });
  const claude = fakeDriver("claude");
  const codex = fakeDriver("codex");
  const rows: Record<string, J> = {
    k1: { key: "k1", ws: "ws", profile: "pc", model: null, runtime: "claude" },
    k2: { key: "k2", ws: "ws", profile: "px", model: "picked", runtime: "codex" },
  };
  const profiles: Record<string, J> = {
    pc: { id: "pc", runtime: "claude", runtimes: ["claude"], home: dir, model: "claude-default", spelling: () => null },
    px: { id: "px", runtime: "codex", runtimes: ["codex"], home: dir, model: "codex-default", spelling: () => null },
  };
  const scratch = join(dir, "run", "app-llm");
  const side = {
    getSession: (k: string) => rows[k] ?? null,
    profile: (id: string) => profiles[id] ?? null,
    allows: () => true,
    home: () => "ws",
    driver: (r: string) => (r === "claude" ? claude.driver : r === "codex" ? codex.driver : undefined),
    scratch,
  };
  const rs: Route[] = routes({ apps, completion: (k) => appCompletion(side as never, k) });
  const tools = appTools(apps, (k) => (rows[k] ? { ws: "ws", dir } : null));
  const tool = async (name: string, args: Record<string, unknown>) => JSON.parse(await tools.find((t) => t.name === name)!.run("k1", args));
  const asked: string[] = [];
  const answering: Promise<unknown>[] = [];
  const serve = async (req: HttpRequest): Promise<HttpResponse> => {
    const url = new URL(req.url);
    const path = url.pathname.replace(/^\/admin\/api/, "");
    asked.push(`${req.method} ${path}${url.search}`);
    for (const route of rs) {
      const m = route.method === req.method ? route.pattern.exec(path) : null;
      if (m === null) continue;
      const r: Request = {
        method: req.method,
        path,
        query: [...url.searchParams.entries()],
        headers: {},
        body: Buffer.from(req.body ?? new Uint8Array()),
        viewer: { sub: "s1", email: "a@x.com", name: "A", role: "member", workspace: "ws", device: "d" } as never,
        lang: "en",
      };
      const a = await route.handle(r, m.slice(1) as never);
      return { status: a.status, headers: [["content-type", "application/json"]], body: new Uint8Array(a.body as Buffer) };
    }
    return jsonResponse(404, { error: `no route ${req.method} ${path}` });
  };
  const answer = (req: HttpRequest): Promise<HttpResponse> | undefined => {
    if (!/\/admin\/api\/apps(\/|$|\?)/.test(req.url)) return undefined;
    const p = serve(req);
    answering.push(p);
    return p;
  };
  return { dir, apps, tool, answer, asked, answering, claude, codex, scratch, profiles };
}

/// The answer the core gave call `id` (`ok` or `error`), taken out of what it emitted.
function answered(emitted: [number, CoreMessage][], id: number): J {
  const i = emitted.findIndex(([, m]) => (m as J).id === id && ("ok" in (m as J) || "error" in (m as J)));
  if (i < 0) return undefined;
  return emitted.splice(i, 1)[0]![1];
}

async function rig() {
  const told: { name: string; data: unknown }[] = [];
  let push: ((name: string, data: unknown) => void) | null = null;
  const st = await station((name, data) => {
    told.push({ name, data });
    push?.(name, data);
  });
  const s = await started(undefined, 0, undefined, (x) => stationLater(x.host, st.answer));
  push = s.push;
  let next = 100;
  /// Call `name` (an app's of the station) and its answer, once the station answered whatever it was asked and the core
  /// gave it out.
  const ask = async (name: string, params: Record<string, unknown>): Promise<J> => {
    const id = ++next;
    call(s.core, UI, id, name, name.startsWith("app.") ? { station: STATION, ...params } : params);
    await s.host.settle();
    while (st.answering.length > 0) {
      await Promise.all(st.answering.splice(0));
      await s.host.settle();
    }
    const a = answered(s.host.emitted, id);
    if (a === undefined) throw new Error(`${name} not answered`);
    return a;
  };
  return { ...s, st, told, ask };
}

/// What app.watch call `id` was given as its progress since last taken (its `value`s).
function heard(emitted: [number, CoreMessage][], id: number): J[] {
  const out: J[] = [];
  for (let i = emitted.length - 1; i >= 0; i--) {
    const m = emitted[i]![1] as J;
    if (m.id === id && "value" in m) {
      out.unshift(m.value);
      emitted.splice(i, 1);
    }
  }
  return out;
}

test("with 站点应用 on: an agent's app read, its documents and model used, its versions and rollback heard by a watcher", async () => {
  const { core, host, st, ask } = await rig();
  assert.ok("ok" in (await ask("prefs.set", { experimental: { apps: true } })));

  // An agent saves the app with its tool, as it would from its chat's working directory.
  await writeFile(join(st.dir, "todo.mbui"), JSON.stringify({ app: "todo", title: "Todo", root: { type: "text", text: "v1" } }));
  const saved = await st.tool("app_save", { id: "todo", title: "Todo", file: "todo.mbui", note: "first" });
  assert.deepEqual([saved.rev, saved.current, saved.link], [1, 1, "[Todo](sf-app:todo)"]);

  // The core reads it of the station.
  const got = await ask("app.get", { id: "todo" });
  assert.equal(got.ok.rev, 1);
  assert.equal(got.ok.kind, "mbui");
  assert.deepEqual(JSON.parse(got.ok.source).root, { type: "text", text: "v1" });

  // A widget showing it follows it.
  const watch = 7;
  call(core, UI, watch, "app.watch", { station: STATION, id: "todo" });
  await host.settle();
  assert.deepEqual(heard(host.emitted, watch), [{ type: "opened" }]);

  // A document written: the station keeps it, and the watcher hears of it.
  const put = await ask("app.putDoc", { id: "todo", collection: "items", doc: "a", data: { t: "milk" }, base: 0 });
  assert.deepEqual(put.ok, { rev: 1 });
  assert.deepEqual(heard(host.emitted, watch), [{ type: "app-doc", app: "todo", collection: "items", id: "a", rev: 1, deleted: false }]);
  const docs = await ask("app.docs", { id: "todo", collection: "items" });
  assert.deepEqual(docs.ok.docs.map((d: J) => [d.id, d.data]), [["a", { t: "milk" }]]);

  // The chat's model: one text-only turn of its Claude Code profile, then of a Codex one, each in a directory of its own
  // made for it and removed after, the session disposed.
  const viaClaude = await ask("app.llm", { id: "todo", key: "k1", prompt: "hello", system: "be brief" });
  assert.deepEqual(viaClaude.ok, { text: "claude:hello" });
  const c = st.claude.opened[0]!;
  assert.equal(c.options.textOnly, true);
  assert.equal(c.options.model, undefined, "the chat having none: the driver runs the profile's own");
  assert.equal(c.options.profile, st.profiles.pc, "on the chat's profile");
  assert.ok(c.options.cwd!.startsWith(st.scratch), "never the chat's workspace");
  assert.match(String(c.options.instructions), /no tools[\s\S]*be brief$/);
  assert.equal(c.disposed, true);
  const viaCodex = await ask("app.llm", { id: "todo", key: "k2", prompt: "hi" });
  assert.deepEqual(viaCodex.ok, { text: "codex:hi" });
  assert.equal(st.codex.opened[0]!.options.model, "picked", "the chat's model");
  assert.equal(st.codex.opened[0]!.disposed, true);

  // A second version from the agent: rev 2 current, heard.
  await writeFile(join(st.dir, "todo.mbui"), JSON.stringify({ app: "todo", title: "Todo", root: { type: "text", text: "v2" } }));
  const two = await st.tool("app_save", { id: "todo", file: "todo.mbui", note: "second", base_rev: 1 });
  assert.deepEqual([two.rev, two.current], [2, 2]);
  await host.settle();
  assert.deepEqual(heard(host.emitted, watch), [{ type: "app", id: "todo", rev: 2, current: 2 }]);
  assert.deepEqual(JSON.parse((await ask("app.get", { id: "todo" })).ok.source).root.text, "v2");
  assert.deepEqual((await ask("app.versions", { id: "todo" })).ok.versions.map((v: J) => v.rev), [2, 1]);

  // Rolled back to rev 1 by the agent: the versions as they were, rev 1 current, heard.
  const back = await st.tool("app_publish", { id: "todo", rev: 1, note: "v2 broke it" });
  assert.deepEqual([back.rev, back.current], [2, 1]);
  await host.settle();
  assert.deepEqual(heard(host.emitted, watch), [{ type: "app", id: "todo", rev: 2, current: 1 }]);
  assert.equal(JSON.parse((await ask("app.get", { id: "todo" })).ok.source).root.text, "v1");
  assert.equal(JSON.parse((await ask("app.get", { id: "todo", rev: 2 })).ok.source).root.text, "v2", "a version kept whole");

  // A save made on a version that moved on is refused, saying which to start from; nothing changed or heard.
  await assert.rejects(st.tool("app_save", { id: "todo", file: "todo.mbui", note: "stale", base_rev: 1 }), /version 2.*base_rev 2/);
  assert.equal(st.apps.meta("ws", "todo").rev, 2);
  await host.settle();
  assert.deepEqual(heard(host.emitted, watch), []);
  // (and from the device, as the station answers it: the rollback made of a version that is not there refused)
  const none = await ask("app.publish", { id: "todo", rev: 9 });
  assert.equal(none.error.code, "http_404");
});

test("with 站点应用 off (the default): every app call is refused, saying where to turn it on, and the station asked nothing", async () => {
  const { st, ask } = await rig();
  await writeFile(join(st.dir, "todo.mbui"), JSON.stringify({ app: "todo", root: { type: "text", text: "v1" } }));
  await st.tool("app_save", { id: "todo", file: "todo.mbui", note: "first" });
  for (const [name, params] of [
    ["app.list", {}],
    ["app.get", { id: "todo" }],
    ["app.versions", { id: "todo" }],
    ["app.publish", { id: "todo", rev: 1 }],
    ["app.docs", { id: "todo", collection: "items" }],
    ["app.putDoc", { id: "todo", collection: "items", doc: "a", data: { t: 1 } }],
    ["app.deleteDoc", { id: "todo", collection: "items", doc: "a" }],
    ["app.llm", { id: "todo", key: "k1", prompt: "hi" }],
    ["app.watch", { id: "todo" }],
  ] as const) {
    const a = await ask(name, params);
    assert.equal(a.error?.code, "feature_off", name);
    assert.match(a.error.message, /设置 › 实验性功能.*站点应用/, name);
  }
  assert.deepEqual(st.asked, [], "nothing asked of the station");
  assert.equal(st.claude.opened.length, 0);
  // Turned on, the same calls answer; off again, refused again.
  assert.ok("ok" in (await ask("prefs.set", { experimental: { apps: true } })));
  assert.equal((await ask("app.list", {})).ok.apps[0].id, "todo");
  assert.ok("ok" in (await ask("prefs.set", { experimental: { apps: null } })));
  assert.equal((await ask("app.list", {})).error.code, "feature_off");
});
