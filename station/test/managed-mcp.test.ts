// Deterministic tests for station-managed third-party MCP servers:
// config validation & secret masking, tool name normalization/mapping, stdio & HTTP/SSE transports,
// content passthrough & truncation, AbortSignal cancellation, hub.everyChanged() precision,
// TestClock backoff & circuit breaker, budget/station_tool overflow, OUTWARD gating, and subagent silent rules.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Effect, Exit, Scope } from "effect";
import { TestClock } from "effect/testing";
import { checkConfig } from "../src/accounts/check.ts";
import { SILENT_SUBAGENTS, SUBAGENT_HOOK } from "../src/agents/claude.ts";
import { routes as mcpServersRoutes } from "../src/api/routes/mcp-servers.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { maskValue } from "../src/ops/agent-env.ts";
import { ManagedMcp } from "../src/tools/managed-mcp.ts";
import { ManagedMcpAsks, mcpServerTools } from "../src/tools/managed-mcp-tool.ts";
import { given } from "./hub-fakes.ts";
import type { McpClient, McpClientEvents, UpstreamTool } from "../src/tools/managed-mcp-client.ts";
import {
  MAX_RESULT_BYTES,
  MAX_TOOL_NAME_LEN,
  checkManagedMcp,
  exportedToolNames,
  mergeManagedMcpPatch,
  truncateContent,
} from "../src/tools/managed-mcp-config.ts";
import { type Content, INDIRECT, McpEndpoint, SLACK_SPOKEN, UNBOUND_REFUSAL, type Tool, type ToolReply } from "../src/tools/mcp.ts";
import { refusal as copilotRefusal } from "../assets/agents/copilot-bridge.mjs";

const managerViewer = { email: "owner@example.com", role: "owner" as const, workspace: "ws-1", home: true, sub: "u-1" };
const memberViewer = { email: "member@example.com", role: "member" as const, workspace: "ws-1", home: true, sub: "u-2" };

const mcpRpc = (endpoint: McpEndpoint, method: string, params: Record<string, unknown> = {}, signal?: AbortSignal) =>
  endpoint.handle("POST", "Bearer tok-1", JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }), signal);

// ── 1. Config validation & secret masking ────────────────────────────────────

test("config validation accepts stdio/http/sse entries and rejects reserved or malformed names", () => {
  checkConfig(
    {
      mcpServers: {
        ado: { command: "npx", args: ["-y", "@azure-devops/mcp", "org"], env: { ADO_TOKEN: "secret-123456789" } },
        docs: { type: "http", url: "https://docs.example.com/mcp", headers: { Authorization: "Bearer tok-abcdef" } },
        legacy: { type: "sse", url: "http://127.0.0.1:9000/sse", enabled: false },
      },
    },
    "/tmp",
  );

  for (const bad of ["stillfail", "STILLFAIL", "stillfail-extra", "stillfail_2", "chat_post", "slack_api", "station_tool", "foo__bar", "-bad", ""]) {
    assert.throws(() => checkManagedMcp({ [bad]: { command: "echo" } }), /reserved|invalid server name/i, bad);
  }
  assert.throws(() => checkManagedMcp({ a: { command: "echo", url: "https://x.test" } }), /cannot specify both/i);
  assert.throws(() => checkManagedMcp({ a: { type: "http", url: "ftp://x.test" } }), /http or https/i);
  assert.throws(() => checkManagedMcp({ a: { type: "ws", url: "https://x.test" } }), /http.*sse/i);
  assert.throws(() => checkManagedMcp({ a: { command: "echo", headers: { X: "1" } } }), /headers are only/i);
  assert.throws(() => checkManagedMcp({ a: { type: "http", url: "https://x.test", env: { A: "1" } } }), /args\/env are only/i);
});

test("mergeManagedMcpPatch preserves masked env/headers values, updates changed ones, and deletes nulls", () => {
  const secretEnv = "sk_live_1234567890abcdef";
  const secretHdr = "Bearer super_secret_token_999";
  const initial = mergeManagedMcpPatch(
    {},
    {
      s1: { command: "node", args: ["a.js"], env: { API_KEY: secretEnv, MODE: "prod" } },
      s2: { type: "http", url: "https://mcp.example.com", headers: { Authorization: secretHdr } },
    },
  );

  const updated = mergeManagedMcpPatch(initial, {
    s1: { command: "node", args: ["b.js"], env: { API_KEY: maskValue(secretEnv), MODE: "staging" } },
    s2: { type: "http", url: "https://mcp.example.com", headers: { Authorization: maskValue(secretHdr) }, enabled: false },
  });
  assert.equal((updated.s1 as { env?: Record<string, string> }).env?.API_KEY, secretEnv);
  assert.equal((updated.s1 as { env?: Record<string, string> }).env?.MODE, "staging");
  assert.equal((updated.s2 as { headers?: Record<string, string> }).headers?.Authorization, secretHdr);
  assert.equal(updated.s2?.enabled, false);

  const afterDelete = mergeManagedMcpPatch(updated, { s2: null });
  assert.equal("s2" in afterDelete, false);
  assert.equal("s1" in afterDelete, true);
});

// ── 2. Tool name normalization, truncation & collision disambiguation ────────

test("exportedToolNames normalizes illegal chars, bounds length to 48, and is invariant to upstream tool order", () => {
  const single = exportedToolNames("jira", ["issue.get/v2:detail"]);
  const a = single.get("issue.get/v2:detail")!;
  assert.equal(a, "jira__issue_get_v2_detail");
  assert.match(a, /^[a-zA-Z0-9_-]{1,48}$/);

  const longA = "extremely_verbose_upstream_tool_name_version_one";
  const longB = "extremely_verbose_upstream_tool_name_version_two";
  const forward = exportedToolNames("srv", ["a.b", "a_b", longA, longB, "plain"]);
  const reversed = exportedToolNames("srv", ["plain", longB, longA, "a_b", "a.b"]);

  // Order-independence: every upstream tool gets the exact same exported name regardless of list order.
  for (const orig of ["a.b", "a_b", longA, longB, "plain"]) {
    const f = forward.get(orig)!;
    const r = reversed.get(orig)!;
    assert.equal(f, r, `name drifted for ${orig}: ${f} vs ${r}`);
    assert.ok(f.length <= MAX_TOOL_NAME_LEN, `length ${f.length}`);
    assert.match(f, /^[a-zA-Z0-9_-]{1,48}$/);
  }
  // Colliding tools both get distinct deterministic hashed names.
  assert.notEqual(forward.get("a.b"), forward.get("a_b"));
  assert.notEqual(forward.get(longA), forward.get(longB));
  assert.equal(forward.get("plain"), "srv__plain");
});

// ── 3. Content passthrough & truncation ──────────────────────────────────────

test("truncateContent preserves text, image, and resource blocks verbatim and truncates oversized text", () => {
  const items: Content[] = [
    { type: "text", text: "hello" },
    { type: "image", data: "AQID", mimeType: "image/png" },
    { type: "resource", resource: { uri: "file:///a.txt", mimeType: "text/plain", text: "body" } },
  ];
  assert.deepEqual(truncateContent(items), items);

  const huge: Content[] = [{ type: "text", text: "x".repeat(MAX_RESULT_BYTES + 10_000) }];
  const cut = truncateContent(huge);
  assert.equal(cut.length, 1);
  assert.equal(cut[0]?.type, "text");
  assert.ok((cut[0] as { text: string }).text.includes("[truncated:"));
  assert.ok(Buffer.byteLength(JSON.stringify(cut[0]), "utf8") <= MAX_RESULT_BYTES + 256);
});

// ── 4. Real stdio fake MCP server subprocess end-to-end ──────────────────────

const FAKE_STDIO_SERVER = `
const readline = require("node:readline");
const rl = readline.createInterface({ input: process.stdin });
const send = (obj) => process.stdout.write(JSON.stringify(obj) + "\\n");
rl.on("line", (line) => {
  if (!line.trim()) return;
  const msg = JSON.parse(line);
  if (msg.method === "initialize") {
    return send({ jsonrpc: "2.0", id: msg.id, result: { protocolVersion: "2025-06-18", capabilities: { tools: { listChanged: true } }, serverInfo: { name: "fake", version: "1.0" } } });
  }
  if (msg.method === "tools/list") {
    return send({
      jsonrpc: "2.0",
      id: msg.id,
      result: {
        tools: [
          { name: "echo.secret", description: "Echoes text and secret length", inputSchema: { type: "object", properties: { text: { type: "string" } } } },
          { name: "multi", description: "Returns text + image + resource", inputSchema: { type: "object", properties: {} } },
          { name: "fail", description: "Returns isError", inputSchema: { type: "object", properties: {} } },
          { name: "slow", description: "Waits forever until killed/aborted", inputSchema: { type: "object", properties: {} } },
        ],
      },
    });
  }
  if (msg.method === "tools/call") {
    const n = msg.params.name;
    if (n === "echo.secret") {
      const secret = process.env.SECRET_TOKEN || "";
      return send({ jsonrpc: "2.0", id: msg.id, result: { content: [{ type: "text", text: msg.params.arguments.text + ":" + secret }] } });
    }
    if (n === "multi") {
      return send({
        jsonrpc: "2.0",
        id: msg.id,
        result: {
          content: [
            { type: "text", text: "caption" },
            { type: "image", data: "iVBORw==", mimeType: "image/png" },
            { type: "resource", resource: { uri: "memo://1", text: "doc" } },
          ],
        },
      });
    }
    if (n === "fail") {
      return send({ jsonrpc: "2.0", id: msg.id, result: { content: [{ type: "text", text: "boom" }], isError: true } });
    }
    if (n === "slow") {
      // Intentionally never answers so caller AbortSignal cancels it.
      return;
    }
  }
});
`;

test("stdio managed MCP server exposes tools via McpEndpoint, maps names, forwards multimodal/isError, masks secrets, and honours AbortSignal", async () => {
  const dir = mkdtempSync(join(tmpdir(), "sf-mcp-stdio-"));
  try {
    const config = new ConfigFile(dir);
    config.update((raw) => {
      raw.mcpServers = {
        demo: {
          command: process.execPath,
          args: ["-e", FAKE_STDIO_SERVER],
          env: { SECRET_TOKEN: "top_secret_value_12345" },
        },
      };
    });

    const mgr = new ManagedMcp({ config });
    await mgr.start();
    try {
      // View masks env secrets and reports ready + 4 tools.
      const views = mgr.view();
      assert.equal(views.length, 1);
      assert.equal(views[0]!.status, "ready");
      assert.equal(views[0]!.toolCount, 4);
      assert.equal(views[0]!.env?.SECRET_TOKEN, maskValue("top_secret_value_12345"));
      assert.ok(!JSON.stringify(views).includes("top_secret_value_12345"));

      const endpoint = new McpEndpoint((t) => (t === "tok-1" ? "sess-1" : undefined), () => mgr.exposed());
      const listed = (await mcpRpc(endpoint, "tools/list")).body as { result: { tools: { name: string }[] } };
      const names = listed.result.tools.map((t) => t.name);
      assert.ok(names.includes("demo__echo_secret"));
      assert.ok(names.includes("demo__multi"));
      assert.ok(names.includes("demo__fail"));

      // Mapped tool call reaches upstream with original name `echo.secret` and subprocess env secret.
      const echoed = (await mcpRpc(endpoint, "tools/call", { name: "demo__echo_secret", arguments: { text: "hi" } })).body as { result: ToolReply };
      assert.equal((echoed.result.content[0] as { text: string }).text, "hi:top_secret_value_12345");

      // Multimodal content (text + image + resource) preserved verbatim.
      const multi = (await mcpRpc(endpoint, "tools/call", { name: "demo__multi", arguments: {} })).body as { result: ToolReply };
      assert.equal(multi.result.content.length, 3);
      assert.equal(multi.result.content[1]?.type, "image");
      assert.equal(multi.result.content[2]?.type, "resource");

      // isError forwarded.
      const failed = (await mcpRpc(endpoint, "tools/call", { name: "demo__fail", arguments: {} })).body as { result: ToolReply };
      assert.equal(failed.result.isError, true);
      assert.equal((failed.result.content[0] as { text: string }).text, "boom");

      // AbortSignal cancels an in-flight slow call cleanly.
      const ac = new AbortController();
      const pending = mcpRpc(endpoint, "tools/call", { name: "demo__slow", arguments: {} }, ac.signal);
      ac.abort(new Error("caller cancelled"));
      const aborted = (await pending).body as { result: ToolReply };
      assert.equal(aborted.result.isError, true);
      assert.match((aborted.result.content[0] as { text: string }).text, /caller cancelled|aborted/i);
    } finally {
      await mgr.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ── 5. Streamable HTTP & legacy SSE servers ──────────────────────────────────

test("remote Streamable HTTP and legacy SSE MCP servers work through ManagedMcp with masked headers", async () => {
  let seenAuth = "";
  let sseRes: import("node:http").ServerResponse | null = null;

  const server = createServer((req, res) => {
    seenAuth = String(req.headers.authorization ?? "");
    if (req.url === "/http" && req.method === "POST") {
      let body = "";
      req.on("data", (c) => (body += c));
      req.on("end", () => {
        const msg = JSON.parse(body);
        res.setHeader("mcp-session-id", "sid-42");
        if (!("id" in msg)) return void res.writeHead(202).end();
        if (msg.method === "initialize") {
          return void res.writeHead(200, { "content-type": "application/json" }).end(
            JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "http-srv", version: "1" } } }),
          );
        }
        if (msg.method === "tools/list") {
          // Respond via SSE streamable HTTP response to exercise SSE parsing on `type: "http"`.
          res.writeHead(200, { "content-type": "text/event-stream" });
          res.write(`data: ${JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: { tools: [{ name: "ping", description: "HTTP ping", inputSchema: { type: "object", properties: {} } }] } })}\n\n`);
          return void res.end();
        }
        if (msg.method === "tools/call") {
          return void res.writeHead(200, { "content-type": "application/json" }).end(
            JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: { content: [{ type: "text", text: `pong:${req.headers["mcp-session-id"]}` }] } }),
          );
        }
      });
      return;
    }
    if (req.url === "/http" && req.method === "DELETE") {
      return void res.writeHead(204).end();
    }
    if (req.url === "/sse" && req.method === "GET") {
      res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
      res.write("event: endpoint\ndata: /sse/post\n\n");
      sseRes = res;
      return;
    }
    if (req.url === "/sse/post" && req.method === "POST") {
      let body = "";
      req.on("data", (c) => (body += c));
      req.on("end", () => {
        const msg = JSON.parse(body);
        res.writeHead(202).end();
        if (!("id" in msg) || !sseRes) return;
        let result: unknown = {};
        if (msg.method === "initialize") result = { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "sse-srv", version: "1" } };
        else if (msg.method === "tools/list") result = { tools: [{ name: "hello", description: "SSE hello", inputSchema: { type: "object", properties: {} } }] };
        else if (msg.method === "tools/call") result = { content: [{ type: "text", text: "from-sse" }] };
        sseRes.write(`event: message\ndata: ${JSON.stringify({ jsonrpc: "2.0", id: msg.id, result })}\n\n`);
      });
      return;
    }
    res.writeHead(404).end();
  });

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;

  const dir = mkdtempSync(join(tmpdir(), "sf-mcp-http-"));
  try {
    const config = new ConfigFile(dir);
    const token = "Bearer remote_secret_token_999";
    config.update((raw) => {
      raw.mcpServers = {
        api: { type: "http", url: `http://127.0.0.1:${port}/http`, headers: { Authorization: token } },
        stream: { type: "sse", url: `http://127.0.0.1:${port}/sse`, headers: { Authorization: token } },
      };
    });

    const mgr = new ManagedMcp({ config, fetchImpl: (u, init) => fetch(u, init) });
    await mgr.start();
    try {
      assert.equal(seenAuth, token);
      const views = mgr.view();
      assert.equal(views.find((v) => v.name === "api")?.headers?.Authorization, maskValue(token));
      assert.equal(views.find((v) => v.name === "stream")?.status, "ready");

      const endpoint = new McpEndpoint((t) => (t === "tok-1" ? "sess-1" : undefined), () => mgr.exposed());
      const r1 = (await mcpRpc(endpoint, "tools/call", { name: "api__ping", arguments: {} })).body as { result: ToolReply };
      assert.equal((r1.result.content[0] as { text: string }).text, "pong:sid-42");

      const r2 = (await mcpRpc(endpoint, "tools/call", { name: "stream__hello", arguments: {} })).body as { result: ToolReply };
      assert.equal((r2.result.content[0] as { text: string }).text, "from-sse");
    } finally {
      await mgr.close();
    }
  } finally {
    server.close();
    server.closeAllConnections();
    rmSync(dir, { recursive: true, force: true });
  }
});

// ── 6. Live list_changed & config sync + TestClock backoff ───────────────────

test("config edits and upstream list_changed update exposed tools in place", async () => {
  const dir = mkdtempSync(join(tmpdir(), "sf-mcp-fp-"));
  try {
    const config = new ConfigFile(dir);
    config.update((raw) => {
      raw.mcpServers = { s1: { command: "fake", env: { V: "1" } } };
    });

    let tools: UpstreamTool[] = [{ name: "t1", description: "v1", inputSchema: { type: "object", properties: {} } }];
    let lastEvents: McpClientEvents = {};

    const mgr = new ManagedMcp({
      config,
      makeClient: (_name, _cfg, events): McpClient => {
        lastEvents = events;
        return {
          connect: async () => [...tools],
          listTools: async () => [...tools],
          callTool: async () => ({ content: [{ type: "text", text: "ok" }] }),
          close: async () => {},
        };
      },
    });

    await mgr.start();
    assert.deepEqual(mgr.exposed().map((t) => t.name), ["s1__t1"]);

    // Upstream live notifications/tools/list_changed refreshes tool table in place.
    tools = [
      { name: "t1", description: "v1", inputSchema: { type: "object", properties: {} } },
      { name: "t2", description: "live-added", inputSchema: { type: "object", properties: {} } },
    ];
    lastEvents.onToolsChanged?.();
    for (let i = 0; i < 10; i++) await Promise.resolve();
    assert.deepEqual(mgr.exposed().map((t) => t.name), ["s1__t1", "s1__t2"]);

    // Disabling server removes its tools without deleting config.
    config.update((raw) => {
      raw.mcpServers.s1.enabled = false;
    });
    await mgr.syncConfig();
    assert.equal(mgr.exposed().length, 0);
    assert.equal(mgr.view()[0]!.status, "disabled");

    await mgr.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("deterministic TestClock exponential backoff and circuit breaker on repeated failures, recovered by reload", async () => {
  const scope = Effect.runSync(Scope.make());
  const clock = Effect.runSync(Scope.provide(TestClock.make(), scope));
  const dir = mkdtempSync(join(tmpdir(), "sf-mcp-backoff-"));
  try {
    const config = new ConfigFile(dir);
    config.update((raw) => {
      raw.mcpServers = { flaky: { command: "fake" } };
    });

    let attempts = 0;
    let shouldFail = true;
    const mgr = new ManagedMcp({
      config,
      clock,
      makeClient: (): McpClient => ({
        connect: async () => {
          attempts++;
          if (shouldFail) throw new Error(`crash #${attempts}`);
          return [{ name: "ok", description: "ok", inputSchema: { type: "object", properties: {} } }];
        },
        listTools: async () => [],
        callTool: async () => ({ content: [{ type: "text", text: "ok" }] }),
        close: async () => {},
      }),
    });

    await mgr.start();
    assert.equal(attempts, 1);
    assert.equal(mgr.view()[0]!.status, "reconnecting");

    // Backoffs: 1s (attempt 2), 2s (attempt 3), 4s (attempt 4), 8s (attempt 5 -> trips circuit breaker).
    for (const [ms, expectedAttempts] of [[1_000, 2], [2_000, 3], [4_000, 4], [8_000, 5]] as const) {
      await Effect.runPromise(clock.adjust(`${ms} millis`));
      await new Promise((r) => setImmediate(r));
      assert.equal(attempts, expectedAttempts);
    }
    assert.equal(mgr.view()[0]!.status, "failed");

    // Advancing further does NOT retry while circuit breaker is open.
    await Effect.runPromise(clock.adjust("120000 millis"));
    await new Promise((r) => setImmediate(r));
    assert.equal(attempts, 5);

    // Manual reload resets circuit breaker and recovers.
    shouldFail = false;
    await mgr.reload("flaky");
    assert.equal(attempts, 6);
    assert.equal(mgr.view()[0]!.status, "ready");
    assert.equal(mgr.exposed().length, 1);

    await mgr.close();
  } finally {
    await Effect.runPromise(Scope.close(scope, Exit.void));
    rmSync(dir, { recursive: true, force: true });
  }
});

// ── 7. API routes authorization, masking & reload ────────────────────────────

test("mcp-servers HTTP routes enforce owner/admin auth, preserve masked secrets, and return immediately without blocking on handshake", async () => {
  const dir = mkdtempSync(join(tmpdir(), "sf-mcp-api-"));
  try {
    const config = new ConfigFile(dir);
    let connects = 0;
    let gate = Promise.withResolvers<void>();
    const mgr = new ManagedMcp({
      config,
      makeClient: (): McpClient => ({
        connect: async () => {
          connects++;
          await gate.promise;
          return [{ name: "ping", description: "ping", inputSchema: { type: "object", properties: {} } }];
        },
        listTools: async () => [],
        callTool: async () => ({ content: [{ type: "text", text: "pong" }] }),
        close: async () => {},
      }),
    });
    config.listen(() => void mgr.syncConfig());
    await mgr.start();
    const list = mcpServersRoutes({ config, managedMcp: mgr });
    const call = async (method: string, path: string, viewer: typeof managerViewer | typeof memberViewer, body?: unknown) => {
      const route = list.find((r) => r.method === method && r.pattern.test(path));
      assert.ok(route, `route ${method} ${path}`);
      const m = route.pattern.exec(path)!;
      return await route.handle(
        { method, path, query: new URLSearchParams(), headers: {}, body: Buffer.from(body ? JSON.stringify(body) : ""), viewer, lang: "en" } as any,
        m.slice(1),
      );
    };

    // Plain member cannot PUT or reload.
    assert.equal((await call("PUT", "/mcp-servers", memberViewer, { servers: { a: { command: "echo" } } })).status, 403);
    assert.equal((await call("POST", "/mcp-servers/reload", memberViewer)).status, 403);

    // Manager adds server while handshake is blocked: PUT returns immediately with status "connecting" and masked secret.
    const secret = "secret_api_key_987654321";
    const put1 = await call("PUT", "/mcp-servers", managerViewer, {
      servers: { a: { command: "echo", env: { KEY: secret } } },
    });
    assert.equal(put1.status, 200);
    const putBody = JSON.parse(put1.body.toString("utf8"));
    assert.equal(putBody.servers[0].status, "connecting");
    assert.equal(putBody.servers[0].env.KEY, maskValue(secret));

    // Unblock handshake; single sync via config.listen completes once and transitions to ready.
    gate.resolve();
    await mgr.syncConfig();
    assert.equal(connects, 1);
    const get1 = await call("GET", "/mcp-servers", memberViewer);
    assert.equal(JSON.parse(get1.body.toString("utf8")).servers[0].status, "ready");

    // Reload also returns immediately with "connecting" without awaiting handshake.
    gate = Promise.withResolvers<void>();
    const rel = await call("POST", "/mcp-servers/a/reload", managerViewer);
    assert.equal(rel.status, 200);
    assert.equal(JSON.parse(rel.body.toString("utf8")).servers[0].status, "connecting");
    gate.resolve();
    await mgr.syncConfig();
    assert.equal(connects, 2);

    await mgr.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ── 8. Budget / station_tool overflow & OUTWARD gating ───────────────────────

test("external tools overflow into station_tool under tight budget and obey OUTWARD gate when unbound", async () => {
  const corePost: Tool = { name: "chat_post", description: "Post to chat.", inputSchema: { type: "object", properties: {} }, run: async () => "posted" };
  const coreState: Tool = { name: "chat_state", description: "Set state.", inputSchema: { type: "object", properties: {} }, run: async () => "ok" };
  const extTool: Tool = {
    name: "docs__search",
    description: "Search external documentation with a deliberately long description so it overflows the budget.",
    inputSchema: { type: "object", properties: { q: { type: "string" } } },
    outward: true,
    run: async () => "unused",
    content: async (_s, args) => ({ content: [{ type: "text", text: `found:${args.q}` }] }),
  };

  let gated: string | undefined = undefined;
  const endpoint = new McpEndpoint(
    (t) => (t === "tok-1" ? "sess-1" : undefined),
    () => [corePost, coreState, extTool],
    () => gated,
    () => ({ budget: 350 }),
  );

  // Under budget: core tools declared, external tool placed in station_tool.
  const listed = (await mcpRpc(endpoint, "tools/list")).body as { result: { tools: { name: string }[] } };
  const names = listed.result.tools.map((t) => t.name);
  assert.ok(names.includes("chat_post"));
  assert.ok(names.includes("chat_state"));
  assert.ok(names.includes(INDIRECT));
  assert.ok(!names.includes("docs__search"));

  // Calling via station_tool works.
  const viaIndirect = (await mcpRpc(endpoint, "tools/call", { name: INDIRECT, arguments: { name: "docs__search", arguments: { q: "mcp" } } })).body as { result: ToolReply };
  assert.equal((viaIndirect.result.content[0] as { text: string }).text, "found:mcp");

  // When station is unbound (gated), external tool is refused.
  gated = UNBOUND_REFUSAL;
  const refused = (await mcpRpc(endpoint, "tools/call", { name: "docs__search", arguments: { q: "mcp" } })).body as { result: ToolReply };
  assert.equal(refused.result.isError, true);
  assert.equal((refused.result.content[0] as { text: string }).text, UNBOUND_REFUSAL);
});

// ── 9. Subagent silent rules allow external tools, still block speaking tools ─

test("subagent silent rules do not block external MCP tools while still blocking stillfail speaking tools", () => {
  // Claude Code SILENT_SUBAGENTS matcher regex check:
  const matcher = new RegExp(`^(?:${SILENT_SUBAGENTS.PreToolUse[0]!.matcher})$`);
  assert.equal(matcher.test("mcp__stillfail__chat_post"), true);
  assert.equal(matcher.test("mcp__stillfail__slack_api"), true);
  assert.equal(matcher.test("mcp__stillfail__ext__chat_post"), false);
  assert.equal(matcher.test("mcp__stillfail__ext__echo"), false);

  // Actual Claude subagent-hook.mjs denies built-in chat_post for a subagent.
  const deniedOut = execFileSync(process.execPath, [SUBAGENT_HOOK, SLACK_SPOKEN.join(",")], {
    input: JSON.stringify({ agent_id: "sub-1", tool_name: "mcp__stillfail__chat_post", tool_input: {} }),
    encoding: "utf8",
  });
  assert.equal(JSON.parse(deniedOut).hookSpecificOutput.permissionDecision, "deny");

  // Copilot bridge refusal allows external tools (even if upstream tool is named chat_post) and refuses built-in chat_post.
  const silent = { tools: ["chat_post", "chat_state"], slackWrites: SLACK_SPOKEN };
  assert.equal(copilotRefusal({ agentId: "sub-1", toolName: "stillfail-ext__chat_post", toolArgs: {} }, silent), null);
  assert.equal(copilotRefusal({ agentId: "sub-1", toolName: "stillfail-ext__search", toolArgs: {} }, silent), null);
  assert.ok(copilotRefusal({ agentId: "sub-1", toolName: "stillfail-chat_post", toolArgs: {} }, silent) !== null);
});

// ── 10. Cross-station shared MCP over mesh ───────────────────────────────────

test("cross-station shared MCP exposes shared:true servers to peers over mesh and blocks shared:false servers", async () => {
  const dirA = mkdtempSync(join(tmpdir(), "sf-mcp-hostA-"));
  const dirB = mkdtempSync(join(tmpdir(), "sf-mcp-hostB-"));
  try {
    const configA = new ConfigFile(dirA);
    configA.update((raw) => {
      raw.mcpServers = {
        pub: { command: "fake", shared: true, env: { SECRET: "only-on-station-A" } },
        priv: { command: "fake", shared: false },
      };
    });
    const configB = new ConfigFile(dirB);

    const mgrA = new ManagedMcp({
      config: configA,
      makeClient: (name): McpClient => ({
        connect: async () => [{ name: "ping", description: `from ${name}`, inputSchema: { type: "object", properties: { msg: { type: "string" } } } }],
        listTools: async () => [],
        callTool: async (tool, args) => ({ content: [{ type: "text", text: `${name}:${tool}:${args.msg ?? ""}` }] }),
        close: async () => {},
      }),
    });
    const mgrB = new ManagedMcp({
      config: configB,
      peers: () => [{ id: "station-a-id", name: "Station-A" }],
      ask: async (station, req) => {
        assert.equal(station, "station-a-id");
        return await mgrA.handlePeer("station-b-id", req);
      },
    });

    await mgrA.start();
    await mgrB.start();
    try {
      // View reflects shared flag accurately.
      assert.equal(mgrA.view().find((v) => v.name === "pub")?.shared, true);
      assert.equal(mgrA.view().find((v) => v.name === "priv")?.shared, false);

      // Direct mcp.call to unshared server is refused on Station A.
      const refusedPriv = (await mgrA.handlePeer("station-b-id", { method: "mcp.call", server: "priv", tool: "ping", arguments: {} })) as ToolReply;
      assert.equal(refusedPriv.isError, true);

      // Station B discovers only `pub` via McpEndpoint tools/list and invokes it over mesh.
      const endpointB = new McpEndpoint(
        (t) => (t === "tok-1" ? "sess-1" : undefined),
        () => mgrB.exposed(),
        undefined,
        undefined,
        { dynamicTools: () => mgrB.exposedFor("ws-1") },
      );
      const listed = (await mcpRpc(endpointB, "tools/list")).body as { result: { tools: { name: string; description: string }[] } };
      const names = listed.result.tools.map((t) => t.name);
      assert.deepEqual(names, ["pub__ping"]);
      assert.ok(listed.result.tools[0]!.description.includes("Station-A"));

      const called = (await mcpRpc(endpointB, "tools/call", { name: "pub__ping", arguments: { msg: "hello" } })).body as { result: ToolReply };
      assert.equal((called.result.content[0] as { text: string }).text, "pub:ping:hello");
    } finally {
      await mgrA.close();
      await mgrB.close();
    }
  } finally {
    rmSync(dirA, { recursive: true, force: true });
    rmSync(dirB, { recursive: true, force: true });
  }
});

test("mcp_servers agent tool: list is immediate, writes require owner/admin card approval, and decline leaves config untouched", async () => {
  const dir = mkdtempSync(join(tmpdir(), "stillfail-mcp-tool-"));
  try {
    const config = new ConfigFile(join(dir, "config.json"));
    const mgr = new ManagedMcp({ config });
    const posted: { session: string; text: string; card: Record<string, unknown>; thread: number; ts: string }[] = [];
    const notices: { session: string; text: string }[] = [];
    // (an approval is applied behind the card, config.ts `updateSoon`, and told once written: waited for as it is told)
    const waiters: (() => void)[] = [];
    const told = (n: number) =>
      given(new Promise<void>((resolve) => {
        const check = () => (notices.length >= n ? resolve() : void waiters.push(check));
        check();
      }), `notice ${n} told`);
    let seq = 1;
    const asks = new ManagedMcpAsks({
      managedMcp: mgr,
      config,
      wsOf: (s) => (s === "sess-1" ? "ws-1" : null),
      cards: {
        post: async (session, text, card) => {
          const entry = { session, text, card: card as Record<string, unknown>, thread: 42, ts: `1700000000.${seq++}` };
          posted.push(entry);
          return { thread: entry.thread, ts: entry.ts };
        },
      },
      notify: (session, text) => {
        notices.push({ session, text });
        for (const w of waiters.splice(0)) w();
      },
    });
    const [tool] = mcpServerTools(asks);

    // 1. list returns immediately with no card posted
    const listRes = JSON.parse(await tool!.run!("sess-1", { action: "list" }));
    assert.deepEqual(listRes.servers, []);
    assert.equal(posted.length, 0);

    // 2. invalid upsert fails pre-validation without posting any card
    await assert.rejects(() => tool!.run!("sess-1", { action: "upsert", name: "stillfail", command: "echo" }));
    assert.equal(posted.length, 0);

    // 3. valid upsert posts confirmation card and does NOT mutate config yet
    const askRes = JSON.parse(await tool!.run!("sess-1", {
      action: "upsert",
      name: "docs",
      type: "http",
      url: "https://docs.example.com/mcp",
      headers: { Authorization: "Bearer super-secret-token-1234" },
      shared: true,
      reason: "Add docs MCP for team search",
    }));
    assert.equal(askRes.card, "posted");
    assert.equal(posted.length, 1);
    assert.equal(Object.keys((config.raw().mcpServers as Record<string, unknown> | undefined) ?? {}).length, 0);
    // Secret must be masked in the card text
    assert.ok(!posted[0]!.text.includes("super-secret-token-1234"));
    assert.ok(posted[0]!.text.includes("跨 Station 共享：是"));

    const at = { thread: posted[0]!.thread, n: 1, ts: posted[0]!.ts };
    // 4. non-admin or wrong workspace cannot approve
    assert.ok(asks.may({ role: "member", workspace: "ws-1", email: "m@example.com" }, posted[0]!.card, at) !== null);
    assert.ok(asks.may({ role: "owner", workspace: "ws-other", email: "o@example.com" }, posted[0]!.card, at) !== null);
    assert.equal(asks.may({ role: "owner", workspace: "ws-1", email: "o@example.com" }, posted[0]!.card, at), null);

    // 5. approving writes config and notifies session
    asks.chosen({ email: "o@example.com" }, posted[0]!.card, "批准并应用", at);
    await told(1);
    const afterApprove = config.raw().mcpServers as Record<string, { shared?: boolean; headers?: Record<string, string> }> | undefined;
    assert.equal(afterApprove?.docs?.shared, true);
    assert.equal(afterApprove?.docs?.headers?.Authorization, "Bearer super-secret-token-1234");
    assert.equal(notices.length, 1);
    assert.ok(notices[0]!.text.includes("approved"));

    // 6. nested args shape with stdio argv array (matches declared { action, args } schema)
    const nestedAsk = JSON.parse(await tool!.run!("sess-1", {
      action: "upsert",
      args: {
        name: "stdio_nested",
        command: "node",
        args: ["-e", "console.log(1)"],
        shared: true,
        reason: "Add stdio server via nested args",
      },
    }));
    assert.equal(nestedAsk.card, "posted");
    assert.equal(posted.length, 2);
    const atNested = { thread: posted[1]!.thread, n: 2, ts: posted[1]!.ts };
    asks.chosen({ email: "o@example.com" }, posted[1]!.card, "批准并应用", atNested);
    await told(2);
    const afterNested = config.raw().mcpServers as Record<string, { command?: string; args?: string[]; shared?: boolean }> | undefined;
    assert.equal(afterNested?.stdio_nested?.command, "node");
    assert.deepEqual(afterNested?.stdio_nested?.args, ["-e", "console.log(1)"]);
    assert.equal(afterNested?.stdio_nested?.shared, true);

    // 7. remove declined leaves config untouched
    await tool!.run!("sess-1", { action: "remove", args: { name: "docs", reason: "test decline" } });
    assert.equal(posted.length, 3);
    const at2 = { thread: posted[2]!.thread, n: 3, ts: posted[2]!.ts };
    asks.chosen({ email: "o@example.com" }, posted[2]!.card, "拒绝", at2);
    const afterDecline = config.raw().mcpServers as Record<string, unknown> | undefined;
    assert.ok(afterDecline?.docs !== undefined);
    assert.equal(notices.length, 3);
    assert.ok(notices[2]!.text.includes("declined"));

    await mgr.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
