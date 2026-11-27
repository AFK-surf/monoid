// Wave 16A-Hooks-TUI Real-Machine Node Parity E2E Test for `stillfail-station-pion`:
// Compares the SAME compiled `stillfail-station-pion` binary against real Node running
// `station/assets/agents/{repo-rules-hook,subagent-hook,claude-tui}.mjs` with identical inputs:
// 1. `repo-rules-hook`: nested AGENTS.md/CLAUDE.md/.claude/CLAUDE.md, dedup state persistence,
//    compaction reset, >128KB stdin payload, invalid/empty JSON, outside-repo path, missing file,
//    STILLFAIL_REPO_RULES=0, and Antigravity PostToolUse -> PostInvocation flow.
// 2. `subagent-hook`: speaking tool refusal, main-agent passthrough, slack_api write prefix match
//    vs read-only passthrough, empty writes_csv, and invalid/empty JSON.
// 3. `claude-tui hook`: SessionStart, UserPromptSubmit (<pasted_content> unwrap + SHA-256 digest),
//    StopFailure 1500-char truncation, subagent/session filtering, and bridge refusal error.
// 4. `claude-tui mcp`: HTTP POST headers/body parity, tools/list -> ToolsListed hook notify,
//    HTTP 500 -> JSON-RPC -32603 error frame, and notifications/cancelled in-flight abort.
// 5. `claude-tui` bridge (`run` mode): --settings & --mcp-config rewriting, full turn over real
//    local HTTP MCP server + real fake runner/claude executable + real `hook`/`mcp` sub-invocations,
//    byte-for-byte stdout lifecycle frame parity, clean exit, and zero orphan processes.
import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync, type ChildProcess, type SpawnSyncReturns } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer as createHttpServer, type IncomingMessage, type Server as HttpServer, type ServerResponse } from "node:http";
import { createServer as createNetServer, type AddressInfo, type Server as NetServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../..", import.meta.url));
const repoRulesMjs = join(root, "station/assets/agents/repo-rules-hook.mjs");
const subagentMjs = join(root, "station/assets/agents/subagent-hook.mjs");
const claudeTuiMjs = join(root, "station/assets/agents/claude-tui.mjs");

const dirs: string[] = [];
const stateFiles: string[] = [];
const servers: Array<HttpServer | NetServer> = [];
const children: ChildProcess[] = [];

function freshDir(tag: string): string {
  const dir = mkdtempSync(join(tmpdir(), `pion-hooks-tui-e2e-${tag}-`));
  dirs.push(dir);
  return dir;
}

function trackRuleState(who: string): string {
  const p = join(tmpdir(), "stillfail-repo-rules", `${who}.json`);
  stateFiles.push(p);
  return p;
}

after(async () => {
  for (const c of children.splice(0)) {
    if (c.exitCode === null && c.signalCode === null) {
      try { c.kill("SIGKILL"); } catch {}
    }
  }
  for (const s of servers.splice(0)) {
    await new Promise<void>((resolve) => s.close(() => resolve()));
  }
  for (const f of stateFiles.splice(0)) {
    rmSync(f, { force: true });
  }
  for (const d of dirs.splice(0)) {
    rmSync(d, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

function resolvePionBinary(): string {
  const envBin = process.env.STILLFAIL_STATION_PION;
  if (envBin && existsSync(envBin)) return envBin;
  const target = process.platform === "darwin" ? "darwin-arm64"
    : process.arch === "arm64" ? "linux-arm64" : "linux-x64";
  const out = join(root, "pion/station-main/_build", `stillfail-station-pion-${target}`);
  if (!existsSync(out)) {
    execFileSync("bash", [join(root, "pion/station-main/scripts/build.sh"), target, out], {
      cwd: root,
      stdio: "inherit",
    });
  }
  return out;
}

function runSyncWithInput(
  bin: string,
  args: string[],
  input: string,
  env: Record<string, string | undefined> = {},
  cwd: string = root,
): SpawnSyncReturns<string> {
  return spawnSync(bin, args, {
    cwd,
    input,
    encoding: "utf8",
    timeout: 20_000,
    maxBuffer: 16 * 1024 * 1024,
    env: { ...process.env, ...env },
  });
}

interface AsyncRunResult {
  status: number | null;
  signal: NodeJS.Signals | null;
  stdout: string;
  stderr: string;
}

function runAsyncWithInput(
  bin: string,
  args: string[],
  input: string,
  env: Record<string, string | undefined> = {},
  cwd: string = root,
): Promise<AsyncRunResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, {
      cwd,
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, ...env },
    });
    children.push(child);
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    child.stdout?.on("data", (c: Buffer) => out.push(c));
    child.stderr?.on("data", (c: Buffer) => err.push(c));
    const timer = setTimeout(() => {
      try { child.kill("SIGKILL"); } catch {}
      reject(new Error(`command timed out: ${bin} ${args.join(" ")}`));
    }, 20_000);
    child.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      resolve({
        status: code,
        signal,
        stdout: Buffer.concat(out).toString("utf8"),
        stderr: Buffer.concat(err).toString("utf8"),
      });
    });
    child.stdin?.end(input);
  });
}

async function startHookTcpServer(replyText: string = "ok\n"): Promise<{
  port: number;
  received: string[];
  close: () => Promise<void>;
}> {
  const received: string[] = [];
  const server = createNetServer((socket) => {
    let buf = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      buf += chunk;
      if (buf.includes("\n")) {
        received.push(buf.trim());
        socket.end(replyText);
      }
    });
  });
  servers.push(server);
  await new Promise<void>((resolve, reject) => server.once("error", reject).listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  return {
    port,
    received,
    close: () => new Promise<void>((resolve) => server.close(() => resolve())),
  };
}

test("1. repo-rules-hook: byte-for-byte Node parity across nested rules, dedup, compact, large stdin, errors, and agy", () => {
  const bin = resolvePionBinary();
  const base = freshDir("repo-rules");
  const repo = join(base, "repo");
  const mid = join(repo, "apps");
  const leaf = join(mid, "web");
  const outside = join(base, "outside");

  mkdirSync(join(repo, ".git"), { recursive: true });
  mkdirSync(leaf, { recursive: true });
  mkdirSync(outside, { recursive: true });
  writeFileSync(join(repo, "AGENTS.md"), "# Root Rules\nAlways check root rules.\n");
  writeFileSync(join(mid, "CLAUDE.md"), "# Apps Rules\nFollow apps rules.\n");
  writeFileSync(join(leaf, "AGENTS.md"), "# Web Rules\nFollow web rules.\n");
  writeFileSync(join(leaf, "CLAUDE.md"), "@AGENTS.md\n");
  const targetFile = join(leaf, "index.ts");
  writeFileSync(targetFile, "export const x = 1;\n");
  const outsideFile = join(outside, "note.txt");
  writeFileSync(outsideFile, "outside repo\n");

  const stamp = `${process.pid}-${Date.now()}`;
  const sidNode = `e2e-rr-node-${stamp}`;
  const sidPion = `e2e-rr-pion-${stamp}`;
  const sidPionMjs = `e2e-rr-pion-mjs-${stamp}`;
  const stateNode = trackRuleState(`${sidNode}-main`);
  const statePion = trackRuleState(`${sidPion}-main`);
  trackRuleState(`${sidPionMjs}-main`);

  // (a) First trigger on nested file: root AGENTS.md + mid CLAUDE.md + leaf AGENTS.md
  const payload = (sid: string, filePath: string, extra?: Record<string, unknown>) =>
    JSON.stringify({
      hook_event_name: "PostToolUse",
      session_id: sid,
      cwd: repo,
      tool_input: { file_path: filePath },
      ...extra,
    });

  const n1 = runSyncWithInput(process.execPath, [repoRulesMjs], payload(sidNode, targetFile), {}, repo);
  const p1 = runSyncWithInput(bin, ["repo-rules-hook"], payload(sidPion, targetFile), {}, repo);
  const p1Mjs = runSyncWithInput(bin, [repoRulesMjs], payload(sidPionMjs, targetFile), {}, repo);
  assert.equal(n1.status, 0, n1.stderr);
  assert.equal(p1.status, 0, p1.stderr);
  assert.equal(p1Mjs.status, 0, p1Mjs.stderr);
  assert.equal(p1.stdout, n1.stdout, "first nested repo-rules-hook stdout must match Node byte-for-byte");
  assert.equal(p1Mjs.stdout, n1.stdout, ".mjs path invocation must match Node byte-for-byte");
  assert.ok(p1.stdout.includes("Root Rules") && p1.stdout.includes("Apps Rules") && p1.stdout.includes("Web Rules"));
  assert.ok(existsSync(stateNode), "Node state file should exist");
  assert.ok(existsSync(statePion), "Pion state file should exist");

  // (b) Second trigger on same session: deduplicated (empty stdout)
  const n2 = runSyncWithInput(process.execPath, [repoRulesMjs], payload(sidNode, targetFile), {}, repo);
  const p2 = runSyncWithInput(bin, ["repo-rules-hook"], payload(sidPion, targetFile), {}, repo);
  assert.equal(n2.status, 0);
  assert.equal(p2.status, 0);
  assert.equal(p2.stdout, n2.stdout);
  assert.equal(p2.stdout, "", "second trigger must be deduplicated");

  // (c) SessionStart compact resets state; subsequent trigger re-injects rules
  const compactPayload = (sid: string) =>
    JSON.stringify({ hook_event_name: "SessionStart", source: "compact", session_id: sid, cwd: repo });
  const nc = runSyncWithInput(process.execPath, [repoRulesMjs], compactPayload(sidNode), {}, repo);
  const pc = runSyncWithInput(bin, ["repo-rules-hook"], compactPayload(sidPion), {}, repo);
  assert.equal(nc.status, 0);
  assert.equal(pc.status, 0);
  assert.equal(pc.stdout, nc.stdout);
  assert.ok(!existsSync(statePion), "compact must remove Pion state file");

  const n3 = runSyncWithInput(process.execPath, [repoRulesMjs], payload(sidNode, targetFile), {}, repo);
  const p3 = runSyncWithInput(bin, ["repo-rules-hook"], payload(sidPion, targetFile), {}, repo);
  assert.equal(p3.status, 0);
  assert.equal(p3.stdout, n3.stdout, "post-compact re-injection must match Node byte-for-byte");

  // (d) Large JSON payload (>128 KB) must not be truncated
  const sidLargeNode = `e2e-rr-large-n-${stamp}`;
  const sidLargePion = `e2e-rr-large-p-${stamp}`;
  trackRuleState(`${sidLargeNode}-main`);
  trackRuleState(`${sidLargePion}-main`);
  const bigBlob = "x".repeat(140_000);
  const nl = runSyncWithInput(process.execPath, [repoRulesMjs], payload(sidLargeNode, targetFile, { big: bigBlob }), {}, repo);
  const pl = runSyncWithInput(bin, ["repo-rules-hook"], payload(sidLargePion, targetFile, { big: bigBlob }), {}, repo);
  assert.equal(pl.status, 0, pl.stderr);
  assert.equal(pl.stdout, nl.stdout, ">128KB stdin payload must match Node byte-for-byte");

  // (e) Missing file inside repo climbs to nearest existing dir
  const sidMissNode = `e2e-rr-miss-n-${stamp}`;
  const sidMissPion = `e2e-rr-miss-p-${stamp}`;
  trackRuleState(`${sidMissNode}-main`);
  trackRuleState(`${sidMissPion}-main`);
  const missingPath = join(leaf, "does-not-exist", "deep", "file.ts");
  const nm = runSyncWithInput(process.execPath, [repoRulesMjs], payload(sidMissNode, missingPath), {}, repo);
  const pm = runSyncWithInput(bin, ["repo-rules-hook"], payload(sidMissPion, missingPath), {}, repo);
  assert.equal(pm.status, 0);
  assert.equal(pm.stdout, nm.stdout, "missing nested file must climb and match Node byte-for-byte");

  // (f) Path outside git repository -> empty stdout
  const sidOutNode = `e2e-rr-out-n-${stamp}`;
  const sidOutPion = `e2e-rr-out-p-${stamp}`;
  trackRuleState(`${sidOutNode}-main`);
  trackRuleState(`${sidOutPion}-main`);
  const no = runSyncWithInput(process.execPath, [repoRulesMjs], payload(sidOutNode, outsideFile), {}, outside);
  const po = runSyncWithInput(bin, ["repo-rules-hook"], payload(sidOutPion, outsideFile), {}, outside);
  assert.equal(po.status, 0);
  assert.equal(po.stdout, no.stdout);
  assert.equal(po.stdout, "");

  // (g) Invalid JSON & empty stdin -> empty stdout, exit 0
  for (const bad of ["", "{not valid json", "   "]) {
    const nb = runSyncWithInput(process.execPath, [repoRulesMjs], bad);
    const pb = runSyncWithInput(bin, ["repo-rules-hook"], bad);
    assert.equal(pb.status, nb.status);
    assert.equal(pb.status, 0);
    assert.equal(pb.stdout, nb.stdout);
    assert.equal(pb.stdout, "");
  }

  // (h) STILLFAIL_REPO_RULES=0 disables injection
  const nd = runSyncWithInput(process.execPath, [repoRulesMjs], payload(sidNode, targetFile), { STILLFAIL_REPO_RULES: "0" }, repo);
  const pd = runSyncWithInput(bin, ["repo-rules-hook"], payload(sidPion, targetFile), { STILLFAIL_REPO_RULES: "0" }, repo);
  assert.equal(pd.status, 0);
  assert.equal(pd.stdout, nd.stdout);
  assert.equal(pd.stdout, "");

  // (i) Antigravity CLI two-phase PostToolUse -> PostInvocation
  const agyNode = `e2e-rr-agy-n-${stamp}`;
  const agyPion = `e2e-rr-agy-p-${stamp}`;
  trackRuleState(`agy-${agyNode}-main`);
  trackRuleState(`agy-${agyPion}-main`);
  const agyPostTool = (cid: string) =>
    JSON.stringify({ hookEventName: "PostToolUse", conversationId: cid, cwd: repo, toolCall: { args: { Path: targetFile } } });
  const agyPostInv = (cid: string) =>
    JSON.stringify({ hookEventName: "PostInvocation", conversationId: cid, cwd: repo });

  const na1 = runSyncWithInput(process.execPath, [repoRulesMjs], agyPostTool(agyNode), {}, repo);
  const pa1 = runSyncWithInput(bin, ["repo-rules-hook"], agyPostTool(agyPion), {}, repo);
  assert.equal(pa1.status, 0);
  assert.equal(pa1.stdout, na1.stdout);
  assert.equal(pa1.stdout, "{}");

  const na2 = runSyncWithInput(process.execPath, [repoRulesMjs], agyPostInv(agyNode), {}, repo);
  const pa2 = runSyncWithInput(bin, ["repo-rules-hook"], agyPostInv(agyPion), {}, repo);
  assert.equal(pa2.status, 0);
  assert.equal(pa2.stdout, na2.stdout, "Antigravity PostInvocation injectSteps must match Node byte-for-byte");
});

test("2. subagent-hook: byte-for-byte Node parity across speaking tools, slack_api writes/reads, main agent, and invalid JSON", () => {
  const bin = resolvePionBinary();
  const writesCsv = "chat.,reactions.,files.upload,pins.";

  const cases: Array<{ name: string; extraArgs: string[]; input: string }> = [
    {
      name: "subagent speaking tool refused",
      extraArgs: [writesCsv],
      input: JSON.stringify({ agent_id: "sub-1", tool_name: "mcp__stillfail__chat_post", tool_input: { text: "hi" } }),
    },
    {
      name: "main agent without agent_id allowed",
      extraArgs: [writesCsv],
      input: JSON.stringify({ tool_name: "mcp__stillfail__chat_post", tool_input: { text: "hi" } }),
    },
    {
      name: "main agent with empty agent_id allowed",
      extraArgs: [writesCsv],
      input: JSON.stringify({ agent_id: "", tool_name: "mcp__stillfail__chat_post" }),
    },
    {
      name: "subagent slack_api write refused",
      extraArgs: [writesCsv],
      input: JSON.stringify({
        agent_id: "sub-2",
        tool_name: "mcp__stillfail__slack_api",
        tool_input: { method: "  chat.postMessage  " },
      }),
    },
    {
      name: "subagent slack_api read-only allowed",
      extraArgs: [writesCsv],
      input: JSON.stringify({
        agent_id: "sub-2",
        tool_name: "mcp__stillfail__slack_api",
        tool_input: { method: "conversations.history" },
      }),
    },
    {
      name: "subagent slack_api with no writes_csv allowed",
      extraArgs: [],
      input: JSON.stringify({
        agent_id: "sub-3",
        tool_name: "mcp__stillfail__slack_api",
        tool_input: { method: "chat.postMessage" },
      }),
    },
    {
      name: "invalid JSON allowed",
      extraArgs: [writesCsv],
      input: "{broken",
    },
    {
      name: "empty stdin allowed",
      extraArgs: [writesCsv],
      input: "",
    },
  ];

  for (const tc of cases) {
    const nr = runSyncWithInput(process.execPath, [subagentMjs, ...tc.extraArgs], tc.input);
    const pr = runSyncWithInput(bin, ["subagent-hook", ...tc.extraArgs], tc.input);
    const prMjs = runSyncWithInput(bin, [subagentMjs, ...tc.extraArgs], tc.input);
    assert.equal(pr.status, nr.status, `${tc.name}: exit code mismatch`);
    assert.equal(pr.stdout, nr.stdout, `${tc.name}: stdout must match Node byte-for-byte`);
    assert.equal(prMjs.status, nr.status, `${tc.name} (.mjs): exit code mismatch`);
    assert.equal(prMjs.stdout, nr.stdout, `${tc.name} (.mjs): stdout must match Node byte-for-byte`);
  }
});

test("3. claude-tui hook: byte-for-byte Node parity on SessionStart, UserPromptSubmit digest, StopFailure truncation, filtering, and refusal", async () => {
  const bin = resolvePionBinary();
  const okSrv = await startHookTcpServer("ok\n");
  const env = {
    STILLFAIL_RUNTIME_SESSION_ID: "rt-sess-42",
    STILLFAIL_TUI_KEY: "tui-secret-key",
    STILLFAIL_TUI_PORT: String(okSrv.port),
  };

  const longErr = "E".repeat(1650);
  const hookPayloads = [
    JSON.stringify({ session_id: "rt-sess-42", hook_event_name: "SessionStart" }),
    JSON.stringify({
      session_id: "rt-sess-42",
      hook_event_name: "UserPromptSubmit",
      prompt: '<pasted_content id="p-1">\nhello from paste\nline 2\n</pasted_content>',
    }),
    JSON.stringify({
      session_id: "rt-sess-42",
      hook_event_name: "StopFailure",
      error_details: longErr,
    }),
    // Filtered out: subagent & mismatched session
    JSON.stringify({ session_id: "rt-sess-42", agent_id: "sub-9", hook_event_name: "Stop" }),
    JSON.stringify({ session_id: "other-sess", hook_event_name: "Stop" }),
  ];

  const nodeEvents: string[] = [];
  for (const p of hookPayloads) {
    const before = okSrv.received.length;
    const r = await runAsyncWithInput(process.execPath, [claudeTuiMjs, "hook"], p, env);
    assert.equal(r.status, 0, r.stderr);
    if (okSrv.received.length > before) nodeEvents.push(okSrv.received[okSrv.received.length - 1]!);
  }

  const pionEvents: string[] = [];
  for (const p of hookPayloads) {
    const before = okSrv.received.length;
    const r = await runAsyncWithInput(bin, ["claude-tui", "hook"], p, env);
    assert.equal(r.status, 0, r.stderr);
    if (okSrv.received.length > before) pionEvents.push(okSrv.received[okSrv.received.length - 1]!);
  }

  assert.equal(nodeEvents.length, 3, "expected 3 forwarded hook events from Node");
  assert.deepEqual(pionEvents, nodeEvents, "Pion claude-tui hook events must match Node byte-for-byte");

  // Bridge refusal -> non-zero exit
  const badSrv = await startHookTcpServer("nope\n");
  const badEnv = { ...env, STILLFAIL_TUI_PORT: String(badSrv.port) };
  const nBad = await runAsyncWithInput(process.execPath, [claudeTuiMjs, "hook"], hookPayloads[0]!, badEnv);
  const pBad = await runAsyncWithInput(bin, ["claude-tui", "hook"], hookPayloads[0]!, badEnv);
  assert.notEqual(nBad.status, 0);
  assert.notEqual(pBad.status, 0);
  assert.ok(pBad.stderr.includes("Claude TUI bridge refused its hook"));
});

test("4. claude-tui mcp: HTTP headers/body, tools/list -> ToolsListed notify, HTTP 500 error frame, and cancellation parity", async () => {
  const bin = resolvePionBinary();
  const hookSrv = await startHookTcpServer("ok\n");
  const seenAuth: string[] = [];
  const seenContentType: string[] = [];

  const mcpSrv = createHttpServer((req: IncomingMessage, res: ServerResponse) => {
    seenAuth.push(String(req.headers.authorization ?? ""));
    seenContentType.push(String(req.headers["content-type"] ?? ""));
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      const body = JSON.parse(Buffer.concat(chunks).toString("utf8")) as { id?: unknown; method?: string };
      if (body.method === "tools/list") {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ jsonrpc: "2.0", id: body.id, result: { tools: [{ name: "chat_post" }] } }));
      } else if (body.method === "tools/fail") {
        res.writeHead(500, { "content-type": "text/plain" });
        res.end("boom");
      } else if (body.method === "tools/slow") {
        // Hold until aborted by notifications/cancelled
        req.on("close", () => {
          if (!res.writableEnded) res.end();
        });
      } else {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ jsonrpc: "2.0", id: body.id, result: { ok: true } }));
      }
    });
  });
  servers.push(mcpSrv);
  await new Promise<void>((resolve, reject) => mcpSrv.once("error", reject).listen(0, "127.0.0.1", resolve));
  const mcpUrl = `http://127.0.0.1:${(mcpSrv.address() as AddressInfo).port}/mcp`;

  const env = {
    STILLFAIL_MCP_TOKEN: "tok-mcp-secret",
    STILLFAIL_TUI_KEY: "tui-mcp-key",
    STILLFAIL_TUI_PORT: String(hookSrv.port),
  };

  const stdinLines = [
    JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }),
    JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/fail" }),
    JSON.stringify({ jsonrpc: "2.0", id: 3, method: "tools/slow" }),
    JSON.stringify({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 3 } }),
  ].join("\n") + "\n";

  // Keep stdin open until both expected responses (id 1 and id 2) arrive, since stdin EOF
  // aborts in-flight MCP HTTP requests (matching Claude Code's stdio MCP lifecycle).
  function runMcpSession(cmd: string, args: string[]): Promise<AsyncRunResult> {
    return new Promise((resolve, reject) => {
      const child = spawn(cmd, args, {
        cwd: root,
        stdio: ["pipe", "pipe", "pipe"],
        env: { ...process.env, ...env },
      });
      children.push(child);
      let stdout = "";
      let stderr = "";
      let ended = false;
      const timer = setTimeout(() => {
        try { child.kill("SIGKILL"); } catch {}
        reject(new Error(`mcp session timed out: ${cmd} ${args.join(" ")} (stdout=${stdout})`));
      }, 20_000);
      child.stdout?.setEncoding("utf8");
      child.stderr?.setEncoding("utf8");
      child.stdout?.on("data", (chunk: string) => {
        stdout += chunk;
        const lines = stdout.split("\n").filter((l) => l.length > 0);
        if (!ended && lines.length >= 2) {
          ended = true;
          child.stdin?.end();
        }
      });
      child.stderr?.on("data", (chunk: string) => { stderr += chunk; });
      child.on("error", (e) => {
        clearTimeout(timer);
        reject(e);
      });
      child.on("close", (code, signal) => {
        clearTimeout(timer);
        resolve({ status: code, signal, stdout, stderr });
      });
      child.stdin?.write(stdinLines);
    });
  }

  const hooksBeforeNode = hookSrv.received.length;
  const nRes = await runMcpSession(process.execPath, [claudeTuiMjs, "mcp", mcpUrl]);
  const nodeHookNotify = hookSrv.received.slice(hooksBeforeNode);

  const hooksBeforePion = hookSrv.received.length;
  const pRes = await runMcpSession(bin, ["claude-tui", "mcp", mcpUrl]);
  const pionHookNotify = hookSrv.received.slice(hooksBeforePion);

  assert.equal(nRes.status, 0, nRes.stderr);
  assert.equal(pRes.status, 0, pRes.stderr);
  const sortById = (s: string) =>
    s.trim().split("\n").map((l) => JSON.parse(l) as { id: number }).sort((a, b) => a.id - b.id);
  assert.deepEqual(sortById(pRes.stdout), sortById(nRes.stdout), "MCP stdout JSON-RPC frames must match Node");
  assert.deepEqual(pionHookNotify, nodeHookNotify, "ToolsListed local hook notification must match Node byte-for-byte");
  assert.equal(pionHookNotify.length, 1);
  assert.deepEqual(JSON.parse(pionHookNotify[0]!), { key: "tui-mcp-key", event: "ToolsListed" });
  assert.ok(seenAuth.every((a) => a === "Bearer tok-mcp-secret"), "every MCP request must send Bearer token");
  assert.ok(seenContentType.every((c) => c === "application/json"), "every MCP request must send application/json");
});

test("5. claude-tui bridge (run mode): arg rewrite, full turn over real HTTP MCP + hooks, clean exit, and zero orphan processes", async () => {
  const bin = resolvePionBinary();
  const dir = freshDir("tui-bridge");

  // Real local HTTP MCP server returning tools/list.
  const mcpSrv = createHttpServer((req: IncomingMessage, res: ServerResponse) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      const body = JSON.parse(Buffer.concat(chunks).toString("utf8")) as { id?: unknown };
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ jsonrpc: "2.0", id: body.id, result: { tools: [{ name: "chat_post" }] } }));
    });
  });
  servers.push(mcpSrv);
  await new Promise<void>((resolve, reject) => mcpSrv.once("error", reject).listen(0, "127.0.0.1", resolve));
  const mcpUrl = `http://127.0.0.1:${(mcpSrv.address() as AddressInfo).port}/mcp`;

  // Fake runner script: verifies --relay-pty, records rewritten settings/mcp-config & its own PID,
  // runs the rewritten `mcp` and `hook` commands against the live bridge, reads the bracketed paste,
  // sends UserPromptSubmit + Stop hooks, then exits cleanly on stdin EOF.
  const fakeRunner = join(dir, "fake-runner.mjs");
  writeFileSync(
    fakeRunner,
    `#!${process.execPath}
import { spawnSync } from "node:child_process";
import { writeFileSync } from "node:fs";

const args = process.argv.slice(2);
const reportFile = process.env.FAKE_REPORT_FILE;
const settings = JSON.parse(args[args.indexOf("--settings") + 1]);
const mcpConfig = JSON.parse(args[args.indexOf("--mcp-config") + 1]);
writeFileSync(reportFile, JSON.stringify({ pid: process.pid, argv0: args[0], argv1: args[1], settings, mcpConfig }));

const hookCmd = settings.hooks.SessionStart[0].hooks[0];
const mcpCmd = mcpConfig.mcpServers.stillfail;

function runHook(payload) {
  const r = spawnSync(hookCmd.command, hookCmd.args, {
    input: JSON.stringify(payload),
    encoding: "utf8",
    env: process.env,
    timeout: 10000,
  });
  if (r.status !== 0) {
    process.stderr.write("hook failed: " + r.stderr + "\\n");
    process.exit(11);
  }
}

// 1. Trigger ToolsListed via the rewritten stdio MCP bridge
const mcpRes = spawnSync(mcpCmd.command, mcpCmd.args, {
  input: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }) + "\\n",
  encoding: "utf8",
  env: process.env,
  timeout: 10000,
});
if (mcpRes.status !== 0) {
  process.stderr.write("mcp failed: " + mcpRes.stderr + "\\n");
  process.exit(12);
}

// 2. Trigger SessionStart hook
runHook({ session_id: process.env.STILLFAIL_RUNTIME_SESSION_ID, hook_event_name: "SessionStart" });

// 3. Read bracketed paste from stdin, acknowledge UserPromptSubmit + Stop, then wait for EOF
let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buf += chunk;
  const start = buf.indexOf("\\x1b[200~");
  const end = buf.indexOf("\\x1b[201~\\r");
  if (start >= 0 && end > start) {
    const pasted = buf.slice(start + 6, end);
    buf = buf.slice(end + 7);
    runHook({ session_id: process.env.STILLFAIL_RUNTIME_SESSION_ID, hook_event_name: "UserPromptSubmit", prompt: pasted });
    runHook({ session_id: process.env.STILLFAIL_RUNTIME_SESSION_ID, hook_event_name: "Stop" });
  }
});
process.stdin.on("end", () => process.exit(0));
`,
  );
  chmodSync(fakeRunner, 0o755);

  const initialSettings = JSON.stringify({ hooks: {} });
  const initialMcp = JSON.stringify({ mcpServers: { stillfail: { type: "http", url: mcpUrl } } });
  const baseEnv = {
    STILLFAIL_RUNTIME_SESSION_ID: "tui-e2e-sess-1",
    STILLFAIL_MCP_TOKEN: "tok-bridge-1",
  };
  const turnInput = JSON.stringify({ type: "user", message: { content: [{ text: "hello pion tui" }] } }) + "\n";

  const nodeReport = join(dir, "node-report.json");
  const pionReport = join(dir, "pion-report.json");

  const nRes = await runAsyncWithInput(
    process.execPath,
    [claudeTuiMjs, process.execPath, fakeRunner, "/usr/bin/fake-claude", "--settings", initialSettings, "--mcp-config", initialMcp],
    turnInput,
    { ...baseEnv, FAKE_REPORT_FILE: nodeReport },
  );
  const pRes = await runAsyncWithInput(
    bin,
    ["claude-tui", bin, fakeRunner, "/usr/bin/fake-claude", "--settings", initialSettings, "--mcp-config", initialMcp],
    turnInput,
    { ...baseEnv, FAKE_REPORT_FILE: pionReport },
  );

  assert.equal(nRes.status, 0, `Node bridge stderr: ${nRes.stderr}`);
  assert.equal(pRes.status, 0, `Pion bridge stderr: ${pRes.stderr}`);
  assert.equal(pRes.stdout, nRes.stdout, "TUI bridge stdout lifecycle frames must match Node byte-for-byte");
  assert.equal(
    pRes.stdout,
    '{"type":"system","subtype":"init"}\n{"type":"result","is_error":false,"result":""}\n',
  );

  const nr = JSON.parse(readFileSync(nodeReport, "utf8")) as {
    pid: number;
    argv0: string;
    argv1: string;
    settings: { skipDangerousModePermissionPrompt: boolean; hooks: Record<string, unknown[]> };
    mcpConfig: { mcpServers: { stillfail: { type: string; command: string; args: string[] } } };
  };
  const pr = JSON.parse(readFileSync(pionReport, "utf8")) as typeof nr;

  assert.equal(pr.argv0, "--relay-pty");
  assert.equal(pr.argv1, "/usr/bin/fake-claude");
  assert.equal(pr.settings.skipDangerousModePermissionPrompt, true);
  assert.deepEqual(Object.keys(pr.settings.hooks).sort(), Object.keys(nr.settings.hooks).sort());
  assert.equal(pr.mcpConfig.mcpServers.stillfail.type, "stdio");
  assert.equal(pr.mcpConfig.mcpServers.stillfail.command, bin);
  assert.deepEqual(pr.mcpConfig.mcpServers.stillfail.args, ["claude-tui", "mcp", mcpUrl]);

  // Verify zero orphan processes: fake runner child PID must already be gone.
  let pionChildAlive = true;
  try {
    process.kill(pr.pid, 0);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ESRCH") pionChildAlive = false;
  }
  assert.equal(pionChildAlive, false, `fake runner PID ${pr.pid} must not remain as an orphan process`);
});
