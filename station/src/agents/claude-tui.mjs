// A Claude TUI and its hooks live under one station runner. Only lifecycle frames go to the runner's
// durable stdout. Terminal bytes are private to the PTY, and chat replies use the session's usual MCP server.
import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { createConnection, createServer } from "node:net";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(import.meta.url);
const digest = text => createHash("sha256").update(text).digest("hex");
const frame = (value) => process.stdout.write(JSON.stringify(value) + "\n");

async function hook() {
  let input = "";
  for await (const chunk of process.stdin) input += chunk;
  const h = JSON.parse(input);
  if (h.agent_id || h.session_id !== process.env.STILLFAIL_RUNTIME_SESSION_ID) return;
  // Tool inputs, pasted messages and the last assistant response can be large. Never send them to the runner.
  const event = { key: process.env.STILLFAIL_TUI_KEY, event: h.hook_event_name };
  if (event.event === "UserPromptSubmit") {
    const prompt = String(h.prompt ?? "").replace(/^<pasted_content id="[^"]+">\n([\s\S]*)\n<\/pasted_content>$/, "$1");
    event.prompt = digest(prompt);
  } else if (event.event === "StopFailure") {
    event.error = String(h.error_details || h.last_assistant_message || h.error || "Claude API error").slice(0, 1500);
  }
  await notify(event);
}

async function notify(event) {
  const socket = createConnection(Number(process.env.STILLFAIL_TUI_PORT), "127.0.0.1");
  socket.setEncoding("utf8");
  socket.write(JSON.stringify(event) + "\n");
  let answer = "";
  for await (const chunk of socket) answer += chunk;
  if (answer.trim() !== "ok") throw new Error("Claude TUI bridge refused its hook");
}

// This station's MCP is stateless HTTP JSON-RPC. Give Claude the same responses over stdio so the
// first paste can wait until Claude itself has received the list, including its per-tool loading hints.
async function serveMcp(url) {
  const calls = new Map();
  const input = createInterface({ input: process.stdin });
  input.once("close", () => { for (const call of calls.values()) call.abort(); });

  async function forward(request, line) {
    if (request.method === "notifications/cancelled") calls.get(request.params?.requestId)?.abort();
    const call = new AbortController();
    const expectsReply = "id" in request;
    if (expectsReply) calls.set(request.id, call);
    let listed = false;
    try {
      const reply = await fetch(url, {
        method: "POST", redirect: "error", signal: call.signal,
        headers: { "content-type": "application/json", authorization: "Bearer " + process.env.STILLFAIL_MCP_TOKEN },
        body: line,
      });
      if (!reply.ok) throw new Error("Station MCP returned HTTP " + reply.status);
      if (!expectsReply) { await reply.arrayBuffer(); return; }
      const result = await reply.json();
      await new Promise((resolve, reject) => process.stdout.write(JSON.stringify(result) + "\n", err => err ? reject(err) : resolve()));
      listed = request.method === "tools/list" && Array.isArray(result.result?.tools) && !result.result.nextCursor;
    } catch (error) {
      if (!call.signal.aborted && expectsReply) frame({ jsonrpc: "2.0", id: request.id, error: { code: -32603, message: error.message } });
    } finally {
      if (expectsReply) calls.delete(request.id);
    }
    if (listed) await notify({ key: process.env.STILLFAIL_TUI_KEY, event: "ToolsListed" });
  }

  for await (const line of input) {
    forward(JSON.parse(line), line).catch(error => process.stderr.write(error.message + "\n"));
  }
}

async function run([node, runner, claude, ...args]) {
  const key = randomUUID();
  const settingsAt = args.indexOf("--settings");
  const settings = JSON.parse(args[settingsAt + 1]);
  for (const event of ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "PreCompact", "PostCompact"]) {
    (settings.hooks[event] ??= []).push({ hooks: [{ type: "command", command: node, args: [script, "hook"], timeout: 10 }] });
  }
  settings.skipDangerousModePermissionPrompt = true;
  args[settingsAt + 1] = JSON.stringify(settings);

  const mcpAt = args.indexOf("--mcp-config") + 1;
  const config = JSON.parse(args[mcpAt]);
  const { url } = config.mcpServers.stillfail;
  config.mcpServers.stillfail = { type: "stdio", command: node, args: [script, "mcp", url] };
  args[mcpAt] = JSON.stringify(config);

  let terminal, pending, deadline;
  let toolsListed = false;
  let ready = false;
  let submitted = false;
  let expectedPrompt;
  let compact = false;
  let closing = false;
  function clearDeadline() {
    clearTimeout(deadline);
    deadline = undefined;
  }
  const close = (error) => {
    if (closing) return;
    closing = true;
    clearDeadline();
    if (error) process.stderr.write(error + "\n");
    if (pending !== undefined) {
      frame({ type: "result", is_error: Boolean(error), result: error || "" });
      pending = undefined;
    }
    // EOF kills the PTY's process group. An interrupt starts a fresh TUI on --resume for the next turn.
    terminal?.stdin.end();
  };
  function expectHook(reason) {
    clearDeadline();
    deadline = setTimeout(() => close(reason), 30_000); // timer: bound a missing startup or submission acknowledgment
  }
  function deliver() {
    if (!ready || !toolsListed || pending === undefined || submitted || closing) return;
    // Only the driver's own compaction is a command. Control bytes and leading TUI shortcuts in a
    // person's text must never become keystrokes, even if they include a bracketed-paste terminator.
    const literal = pending.replace(/\r\n/g, "\n").replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f]/g, c => "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0"));
    const text = compact ? "/compact" : "<station_message>\n" + literal + "\n</station_message>";
    expectedPrompt = digest(text);
    terminal.stdin.write("\x1b[200~" + text + "\x1b[201~\r");
    submitted = true;
    expectHook("Claude TUI did not acknowledge the submitted message. Check the profile's interactive Claude setup and hooks.");
  }
  function onHook(h) {
    if (closing) return;
    switch (h.event) {
      case "ToolsListed":
      case "SessionStart":
        if (h.event === "ToolsListed") toolsListed = true;
        else ready = true;
        if (ready && toolsListed && !submitted) {
          clearDeadline();
          deliver();
        }
        break;
      case "UserPromptSubmit":
        if (submitted && !compact && expectedPrompt === h.prompt) {
          expectedPrompt = undefined;
          clearDeadline();
        }
        break;
      case "PreCompact":
        if (compact) clearDeadline();
        break;
      case "PostCompact":
        frame({ type: "system", subtype: "compact_boundary" });
        if (!compact) break;
        // Fall through: a manually requested compaction finishes here.
      case "Stop":
      case "StopFailure":
        if (pending === undefined || !submitted) break;
        if (h.event === "Stop" && !compact && expectedPrompt !== undefined) {
          close("Claude TUI ended before acknowledging the complete submitted message");
          break;
        }
        clearDeadline();
        frame({ type: "result", is_error: h.event === "StopFailure", result: h.event === "StopFailure" ? h.error : "" });
        pending = undefined;
        submitted = false;
        compact = false;
        break;
    }
  }

  const server = createServer(socket => {
    socket.unref();
    socket.on("error", () => {});
    socket.setEncoding("utf8");
    let line = "";
    socket.on("data", chunk => {
      line += chunk;
      if (line.length > 16_384) return socket.destroy();
      if (!line.includes("\n")) return;
      try {
        const event = JSON.parse(line);
        if (event.key !== key) return socket.destroy();
        onHook(event);
        socket.end("ok\n");
      } catch {
        socket.destroy();
      }
    });
  });
  await new Promise((resolve, reject) => server.once("error", reject).listen(0, "127.0.0.1", resolve));
  terminal = spawn(runner, ["--relay-pty", claude, ...args], {
    // The relay outlives a group signal to the bridge just long enough to see EOF and end its own PTY group.
    detached: true, windowsHide: true, stdio: ["pipe", "pipe", "inherit"],
    env: { ...process.env, MCP_DISCOVERY_CACHE: "0", STILLFAIL_TUI_KEY: key, STILLFAIL_TUI_PORT: String(server.address().port) },
  });
  terminal.stdin.on("error", () => {});
  terminal.stdout.resume();
  const input = createInterface({ input: process.stdin });
  input.on("line", line => {
    if (closing) return;
    try {
      const packet = JSON.parse(line);
      if (packet.type === "user" || packet.type === "compact") {
        if (pending !== undefined) return close("Claude TUI received overlapping turns");
        compact = packet.type === "compact";
        pending = compact ? "" : packet.message.content[0].text;
        frame({ type: "system", subtype: "init" });
        deliver();
      } else if (packet.request?.subtype === "interrupt") close();
      else if (packet.request?.subtype === "background_tasks" && submitted) terminal.stdin.write("\x02");
    } catch (error) {
      close(String(error));
    }
  });
  input.on("close", () => close());
  expectHook("Claude TUI is waiting for its startup hook or station tools. Check the station connection and trust its sessions folder in Claude Code, or select Print in model settings.");
  terminal.on("error", error => close(error.message));
  terminal.on("close", (code, signal) => {
    if (!closing) close("Claude TUI exited (" + (signal ?? code) + ")");
    server.close();
    input.close();
    process.stdin.destroy();
  });
}

if (process.argv[2] === "hook") await hook();
else if (process.argv[2] === "mcp") await serveMcp(process.argv[3]);
else await run(process.argv.slice(2));
