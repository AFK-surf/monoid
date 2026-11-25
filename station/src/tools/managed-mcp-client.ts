// MCP client transports for station-managed third-party servers:
// - stdio subprocess (newline-delimited JSON-RPC 2.0, isolated process group)
// - streamable HTTP (`type: "http"`, JSON or SSE responses, `Mcp-Session-Id`)
// - legacy HTTP+SSE (`type: "sse"`, GET event stream + POST endpoint)
import { type ChildProcess, spawn } from "node:child_process";
import { profileFetch, startEnv } from "../ops/agent-env.ts";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { platform } from "../platform/index.ts";
import type { Content, ToolReply } from "./mcp.ts";
import {
  type ManagedMcpServerConfig,
  MOST_TOOLS_PER_SERVER,
  type RemoteMcpServerConfig,
  type StdioMcpServerConfig,
  isRemoteConfig,
  truncateContent,
} from "./managed-mcp-config.ts";

export const HANDSHAKE_TIMEOUT_MS = 30_000;
export const CALL_TIMEOUT_MS = 15 * 60_000;
const STDIO_GRACE_MS = 3_000;
const MAX_FRAME_BYTES = 4 * 1024 * 1024;
const MAX_STDERR_BYTES = 4 * 1024;
const MCP_PROTOCOL_VERSION = "2025-06-18";

export type UpstreamTool = {
  name: string;
  description: string;
  inputSchema: unknown;
};

export type McpClientEvents = {
  onToolsChanged?: () => void;
  onExit?: (error: Error) => void;
};

export type McpClient = {
  connect(signal?: AbortSignal): Promise<UpstreamTool[]>;
  listTools(signal?: AbortSignal): Promise<UpstreamTool[]>;
  callTool(name: string, args: Record<string, unknown>, signal?: AbortSignal): Promise<ToolReply>;
  close(): Promise<void>;
};

export type FetchLike = typeof profileFetch;

function normalizeSchema(schema: unknown): Record<string, unknown> {
  if (schema !== null && typeof schema === "object" && !Array.isArray(schema)) {
    const obj = schema as Record<string, unknown>;
    return "type" in obj ? obj : { type: "object", ...obj };
  }
  return { type: "object", properties: {} };
}

function parseToolsResult(result: unknown): { tools: UpstreamTool[]; nextCursor?: string } {
  const r = result as { tools?: unknown; nextCursor?: unknown } | null;
  const raw = Array.isArray(r?.tools) ? r!.tools : [];
  const tools: UpstreamTool[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const t = item as { name?: unknown; description?: unknown; inputSchema?: unknown };
    if (typeof t.name !== "string" || t.name.trim() === "") continue;
    tools.push({
      name: t.name,
      description: typeof t.description === "string" ? t.description : "",
      inputSchema: normalizeSchema(t.inputSchema),
    });
  }
  const nextCursor = typeof r?.nextCursor === "string" && r.nextCursor !== "" ? r.nextCursor : undefined;
  return { tools, nextCursor };
}

function parseCallResult(result: unknown): ToolReply {
  const r = result as { content?: unknown; isError?: unknown } | null;
  const rawContent: Content[] = Array.isArray(r?.content)
    ? (r!.content.filter((c): c is Content => c !== null && typeof c === "object") as Content[])
    : [{ type: "text", text: result === undefined ? "" : JSON.stringify(result) }];
  return {
    content: truncateContent(rawContent),
    ...(r?.isError === true ? { isError: true } : {}),
  };
}

function combineSignals(timeoutMs: number, caller?: AbortSignal): { signal: AbortSignal; dispose: () => void } {
  const controller = new AbortController();
  const onAbort = () => controller.abort(caller?.reason ?? new Error("aborted"));
  if (caller?.aborted) {
    controller.abort(caller.reason ?? new Error("aborted"));
    return { signal: controller.signal, dispose: () => {} };
  }
  caller?.addEventListener("abort", onAbort, { once: true });
  const stopTimer = wall.after(timeoutMs, () => controller.abort(new Error(`timed out after ${Math.round(timeoutMs / 1000)}s`))); // timer: a timeout or deadline (MCP request timeout)
  return {
    signal: controller.signal,
    dispose: () => {
      stopTimer();
      caller?.removeEventListener("abort", onAbort);
    },
  };
}

/// Parses SSE events from a ReadableStream<Uint8Array> and invokes `onEvent` for each complete event.
async function readSseStream(
  body: ReadableStream<Uint8Array>,
  onEvent: (event: string, data: string) => void | Promise<void>,
  signal?: AbortSignal,
): Promise<void> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  let eventName = "message";
  let dataLines: string[] = [];

  const flush = async () => {
    if (dataLines.length === 0) {
      eventName = "message";
      return;
    }
    const data = dataLines.join("\n");
    const ev = eventName;
    eventName = "message";
    dataLines = [];
    await onEvent(ev, data);
  };

  try {
    for (;;) {
      if (signal?.aborted) break;
      const { value, done } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      if (buf.length > MAX_FRAME_BYTES) throw new Error("SSE frame exceeded 4 MiB limit");
      let idx: number;
      while ((idx = buf.indexOf("\n")) !== -1) {
        let line = buf.slice(0, idx);
        buf = buf.slice(idx + 1);
        if (line.endsWith("\r")) line = line.slice(0, -1);
        if (line === "") {
          await flush();
        } else if (line.startsWith(":")) {
          continue;
        } else if (line.startsWith("event:")) {
          eventName = line.slice(6).trim();
        } else if (line.startsWith("data:")) {
          const rest = line.slice(5);
          dataLines.push(rest.startsWith(" ") ? rest.slice(1) : rest);
        }
      }
    }
    await flush();
  } finally {
    reader.releaseLock();
  }
}

// ── Stdio MCP Client ─────────────────────────────────────────────────────────

type PendingRpc = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  dispose: () => void;
};

export class StdioMcpClient implements McpClient {
  private readonly name: string;
  private readonly cfg: StdioMcpServerConfig;
  private readonly events: McpClientEvents;
  private child: ChildProcess | null = null;
  private nextId = 1;
  private pending = new Map<number, PendingRpc>();
  private stderrBuf = "";
  private closed = false;
  private exited = false;

  constructor(name: string, cfg: StdioMcpServerConfig, events: McpClientEvents = {}) {
    this.name = name;
    this.cfg = cfg;
    this.events = events;
  }

  lastStderr(): string {
    return this.stderrBuf.trim();
  }

  async connect(signal?: AbortSignal): Promise<UpstreamTool[]> {
    const env = { ...startEnv(), ...(this.cfg.env ?? {}) };
    const detached = platform.os !== "windows";
    const child = spawn(this.cfg.command, this.cfg.args ?? [], {
      stdio: ["pipe", "pipe", "pipe"],
      env,
      detached,
    });
    this.child = child;

    let stdoutBuf: Buffer = Buffer.alloc(0);
    child.stdout?.on("data", (chunk: Buffer) => {
      stdoutBuf = stdoutBuf.length === 0 ? chunk : Buffer.concat([stdoutBuf, chunk]);
      if (stdoutBuf.length > MAX_FRAME_BYTES) {
        this.failAll(new Error(`stdio server ${this.name}: stdout line exceeded 4 MiB limit`));
        void this.close();
        return;
      }
      let nl: number;
      while ((nl = stdoutBuf.indexOf(0x0a)) !== -1) {
        const line = stdoutBuf.subarray(0, nl).toString("utf8").trim();
        stdoutBuf = stdoutBuf.subarray(nl + 1);
        if (line !== "") this.onLine(line);
      }
    });

    child.stderr?.on("data", (chunk: Buffer) => {
      const text = chunk.toString("utf8");
      this.stderrBuf += text;
      if (this.stderrBuf.length > MAX_STDERR_BYTES) {
        this.stderrBuf = this.stderrBuf.slice(-MAX_STDERR_BYTES);
      }
    });

    child.on("error", (err) => {
      this.handleExit(new Error(`failed to start ${this.cfg.command}: ${err.message}`));
    });

    child.on("exit", (code, sig) => {
      const detail = this.lastStderr();
      const why = sig ? `killed by ${sig}` : `exited with code ${code ?? "null"}`;
      this.handleExit(new Error(detail ? `${why}: ${detail.slice(-300)}` : why));
    });

    await this.request("initialize", {
      protocolVersion: MCP_PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: "still.fail", version: "0.0.0" },
    }, HANDSHAKE_TIMEOUT_MS, signal);

    this.notify("notifications/initialized", {});
    return await this.listTools(signal);
  }

  async listTools(signal?: AbortSignal): Promise<UpstreamTool[]> {
    const all: UpstreamTool[] = [];
    let cursor: string | undefined;
    for (let page = 0; page < 16; page++) {
      const result = await this.request("tools/list", cursor ? { cursor } : {}, HANDSHAKE_TIMEOUT_MS, signal);
      const parsed = parseToolsResult(result);
      for (const t of parsed.tools) {
        if (all.length >= MOST_TOOLS_PER_SERVER) return all;
        all.push(t);
      }
      if (!parsed.nextCursor) break;
      cursor = parsed.nextCursor;
    }
    return all;
  }

  async callTool(name: string, args: Record<string, unknown>, signal?: AbortSignal): Promise<ToolReply> {
    const result = await this.request("tools/call", { name, arguments: args }, CALL_TIMEOUT_MS, signal);
    return parseCallResult(result);
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.failAll(new Error(`MCP server ${this.name} closed`));
    const child = this.child;
    if (!child || this.exited) return;
    try {
      child.stdin?.end();
    } catch {}
    await new Promise<void>((resolve) => {
      if (this.exited || child.exitCode !== null || child.signalCode !== null) {
        resolve();
        return;
      }
      let settled = false;
      const done = () => {
        if (settled) return;
        settled = true;
        stopKill();
        resolve();
      };
      child.once("exit", done);
      this.signalGroup(child, "SIGTERM");
      const stopKill = wall.after(STDIO_GRACE_MS, () => { // timer: a timeout or deadline (stdio MCP graceful shutdown)
        this.signalGroup(child, "SIGKILL");
        done();
      });
    });
  }

  private signalGroup(child: ChildProcess, sig: NodeJS.Signals): void {
    const pid = child.pid;
    if (pid && platform.os !== "windows") {
      try {
        process.kill(-pid, sig);
        return;
      } catch {}
    }
    try {
      child.kill(sig);
    } catch {}
  }

  private onLine(line: string): void {
    let msg: any;
    try {
      msg = JSON.parse(line);
    } catch {
      return;
    }
    if (!msg || typeof msg !== "object") return;
    if (msg.method === "notifications/tools/list_changed") {
      this.events.onToolsChanged?.();
      return;
    }
    if (typeof msg.id === "number") {
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      p.dispose();
      if (msg.error) {
        const message = typeof msg.error?.message === "string" ? msg.error.message : JSON.stringify(msg.error);
        p.reject(new Error(message));
      } else {
        p.resolve(msg.result);
      }
    }
  }

  private notify(method: string, params: Record<string, unknown>): void {
    if (!this.child?.stdin?.writable) return;
    this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
  }

  private request(method: string, params: Record<string, unknown>, timeoutMs: number, caller?: AbortSignal): Promise<unknown> {
    if (this.closed || this.exited || !this.child?.stdin?.writable) {
      return Promise.reject(new Error(`MCP server ${this.name} is not running`));
    }
    const id = this.nextId++;
    const { signal, dispose } = combineSignals(timeoutMs, caller);
    return new Promise((resolve, reject) => {
      const onAbort = () => {
        if (!this.pending.has(id)) return;
        this.pending.delete(id);
        dispose();
        const reason = signal.reason instanceof Error ? signal.reason : new Error(String(signal.reason ?? "aborted"));
        reject(reason);
      };
      if (signal.aborted) {
        dispose();
        const reason = signal.reason instanceof Error ? signal.reason : new Error(String(signal.reason ?? "aborted"));
        reject(reason);
        return;
      }
      signal.addEventListener("abort", onAbort, { once: true });
      this.pending.set(id, {
        resolve,
        reject,
        dispose: () => {
          signal.removeEventListener("abort", onAbort);
          dispose();
        },
      });
      try {
        this.child!.stdin!.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
      } catch (err) {
        this.pending.delete(id);
        signal.removeEventListener("abort", onAbort);
        dispose();
        reject(err instanceof Error ? err : new Error(String(err)));
      }
    });
  }

  private failAll(error: Error): void {
    for (const [, p] of this.pending) {
      p.dispose();
      p.reject(error);
    }
    this.pending.clear();
  }

  private handleExit(error: Error): void {
    if (this.exited) return;
    this.exited = true;
    this.failAll(error);
    if (!this.closed) this.events.onExit?.(error);
  }
}

// ── Streamable HTTP & Legacy SSE MCP Client ──────────────────────────────────

export class RemoteMcpClient implements McpClient {
  private readonly name: string;
  private readonly cfg: RemoteMcpServerConfig;
  private readonly events: McpClientEvents;
  private readonly fetchImpl: FetchLike;
  private nextId = 1;
  private sessionId: string | null = null;
  private closed = false;
  private sseEndpoint: string | null = null;
  private sseAbort: AbortController | null = null;
  private ssePending = new Map<number, PendingRpc>();

  constructor(name: string, cfg: RemoteMcpServerConfig, events: McpClientEvents = {}, fetchImpl: FetchLike = profileFetch) {
    this.name = name;
    this.cfg = cfg;
    this.events = events;
    this.fetchImpl = fetchImpl;
  }

  async connect(signal?: AbortSignal): Promise<UpstreamTool[]> {
    if (this.cfg.type === "sse") {
      await this.openSse(signal);
    }
    await this.request("initialize", {
      protocolVersion: MCP_PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: "still.fail", version: "0.0.0" },
    }, HANDSHAKE_TIMEOUT_MS, signal);
    await this.notify("notifications/initialized", {}, signal);
    return await this.listTools(signal);
  }

  async listTools(signal?: AbortSignal): Promise<UpstreamTool[]> {
    const all: UpstreamTool[] = [];
    let cursor: string | undefined;
    for (let page = 0; page < 16; page++) {
      const result = await this.request("tools/list", cursor ? { cursor } : {}, HANDSHAKE_TIMEOUT_MS, signal);
      const parsed = parseToolsResult(result);
      for (const t of parsed.tools) {
        if (all.length >= MOST_TOOLS_PER_SERVER) return all;
        all.push(t);
      }
      if (!parsed.nextCursor) break;
      cursor = parsed.nextCursor;
    }
    return all;
  }

  async callTool(name: string, args: Record<string, unknown>, signal?: AbortSignal): Promise<ToolReply> {
    const result = await this.request("tools/call", { name, arguments: args }, CALL_TIMEOUT_MS, signal);
    return parseCallResult(result);
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.sseAbort?.abort();
    for (const [, p] of this.ssePending) {
      p.dispose();
      p.reject(new Error(`MCP server ${this.name} closed`));
    }
    this.ssePending.clear();
    if (this.cfg.type === "http" && this.sessionId) {
      const headers: Record<string, string> = { ...(this.cfg.headers ?? {}), "mcp-session-id": this.sessionId };
      await this.fetchImpl(this.cfg.url, { method: "DELETE", headers }).catch(() => {});
    }
  }

  private baseHeaders(): Record<string, string> {
    const h: Record<string, string> = {
      accept: "application/json, text/event-stream",
      "content-type": "application/json",
      ...(this.cfg.headers ?? {}),
    };
    if (this.sessionId) h["mcp-session-id"] = this.sessionId;
    return h;
  }

  private async openSse(caller?: AbortSignal): Promise<void> {
    const { signal, dispose } = combineSignals(HANDSHAKE_TIMEOUT_MS, caller);
    const streamAbort = new AbortController();
    this.sseAbort = streamAbort;
    const onHandshakeAbort = () => streamAbort.abort(signal.reason);
    signal.addEventListener("abort", onHandshakeAbort, { once: true });

    const headers: Record<string, string> = {
      accept: "text/event-stream",
      ...(this.cfg.headers ?? {}),
    };
    let res: Response;
    try {
      res = await this.fetchImpl(this.cfg.url, { method: "GET", headers, signal: streamAbort.signal });
    } catch (err) {
      signal.removeEventListener("abort", onHandshakeAbort);
      dispose();
      throw err;
    }
    if (!res.ok || !res.body) {
      signal.removeEventListener("abort", onHandshakeAbort);
      dispose();
      throw new Error(`SSE connect failed: HTTP ${res.status}`);
    }

    const endpointReady = Promise.withResolvers<string>();
    const onAbortWait = () => endpointReady.reject(signal.reason instanceof Error ? signal.reason : new Error("SSE connect aborted"));
    signal.addEventListener("abort", onAbortWait, { once: true });

    // Background SSE reader loop; exits cleanly on close or triggers onExit on unexpected drop.
    void readSseStream(
      res.body,
      (ev, data) => {
        if (ev === "endpoint") {
          try {
            const resolved = new URL(data.trim(), this.cfg.url).toString();
            this.sseEndpoint = resolved;
            endpointReady.resolve(resolved);
          } catch (err) {
            endpointReady.reject(err instanceof Error ? err : new Error(String(err)));
          }
          return;
        }
        this.handleJsonRpcMessage(data);
      },
      streamAbort.signal,
    )
      .then(() => {
        if (!this.closed) this.handleSseDrop(new Error("SSE stream closed by server"));
      })
      .catch((err) => {
        const error = err instanceof Error ? err : new Error(String(err));
        endpointReady.reject(error);
        if (!this.closed) this.handleSseDrop(error);
      });

    try {
      await endpointReady.promise;
    } finally {
      signal.removeEventListener("abort", onHandshakeAbort);
      signal.removeEventListener("abort", onAbortWait);
      dispose();
    }
  }

  private handleSseDrop(error: Error): void {
    for (const [, p] of this.ssePending) {
      p.dispose();
      p.reject(error);
    }
    this.ssePending.clear();
    this.events.onExit?.(error);
  }

  private handleJsonRpcMessage(raw: string): void {
    let msg: any;
    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }
    if (!msg || typeof msg !== "object") return;
    if (msg.method === "notifications/tools/list_changed") {
      this.events.onToolsChanged?.();
      return;
    }
    if (typeof msg.id === "number") {
      const p = this.ssePending.get(msg.id);
      if (!p) return;
      this.ssePending.delete(msg.id);
      p.dispose();
      if (msg.error) {
        const message = typeof msg.error?.message === "string" ? msg.error.message : JSON.stringify(msg.error);
        p.reject(new Error(message));
      } else {
        p.resolve(msg.result);
      }
    }
  }

  private async notify(method: string, params: Record<string, unknown>, caller?: AbortSignal): Promise<void> {
    const url = this.cfg.type === "sse" ? this.sseEndpoint : this.cfg.url;
    if (!url) return;
    const { signal, dispose } = combineSignals(HANDSHAKE_TIMEOUT_MS, caller);
    try {
      await this.fetchImpl(url, {
        method: "POST",
        headers: this.baseHeaders(),
        body: JSON.stringify({ jsonrpc: "2.0", method, params }),
        signal,
      }).catch((err) => {
        log.warn("mcp", "remote MCP notification failed", { server: this.name, method, error: String(err) });
      });
    } finally {
      dispose();
    }
  }

  private async request(method: string, params: Record<string, unknown>, timeoutMs: number, caller?: AbortSignal): Promise<unknown> {
    if (this.closed) throw new Error(`MCP server ${this.name} is closed`);
    const id = this.nextId++;
    const body = JSON.stringify({ jsonrpc: "2.0", id, method, params });

    if (this.cfg.type === "sse") {
      if (!this.sseEndpoint) throw new Error(`SSE server ${this.name} has no endpoint`);
      const { signal, dispose } = combineSignals(timeoutMs, caller);
      const reply = new Promise<unknown>((resolve, reject) => {
        const onAbort = () => {
          if (!this.ssePending.has(id)) return;
          this.ssePending.delete(id);
          dispose();
          reject(signal.reason instanceof Error ? signal.reason : new Error(String(signal.reason ?? "aborted")));
        };
        signal.addEventListener("abort", onAbort, { once: true });
        this.ssePending.set(id, {
          resolve,
          reject,
          dispose: () => {
            signal.removeEventListener("abort", onAbort);
            dispose();
          },
        });
      });
      const res = await this.fetchImpl(this.sseEndpoint, {
        method: "POST",
        headers: this.baseHeaders(),
        body,
        signal,
      });
      if (!res.ok) {
        const pending = this.ssePending.get(id);
        if (pending) {
          this.ssePending.delete(id);
          pending.dispose();
        }
        throw new Error(`HTTP ${res.status} from ${this.name}`);
      }
      return await reply;
    }

    // Streamable HTTP (`type: "http"`)
    const { signal, dispose } = combineSignals(timeoutMs, caller);
    try {
      const res = await this.fetchImpl(this.cfg.url, {
        method: "POST",
        headers: this.baseHeaders(),
        body,
        signal,
      });
      const sid = res.headers.get("mcp-session-id");
      if (sid) this.sessionId = sid;
      if (!res.ok) {
        const snippet = (await res.text().catch(() => "")).slice(0, 300);
        throw new Error(snippet ? `HTTP ${res.status}: ${snippet}` : `HTTP ${res.status}`);
      }
      const ct = (res.headers.get("content-type") ?? "").toLowerCase();
      if (ct.includes("text/event-stream") && res.body) {
        let matched: { result?: unknown; error?: unknown } | null = null;
        await readSseStream(
          res.body,
          (_ev, data) => {
            let msg: any;
            try {
              msg = JSON.parse(data);
            } catch {
              return;
            }
            if (!msg || typeof msg !== "object") return;
            if (msg.method === "notifications/tools/list_changed") {
              this.events.onToolsChanged?.();
              return;
            }
            if (msg.id === id) matched = msg;
          },
          signal,
        );
        if (!matched) throw new Error(`no JSON-RPC response for id ${id} in SSE stream`);
        const m = matched as { result?: unknown; error?: { message?: string } };
        if (m.error) throw new Error(typeof m.error?.message === "string" ? m.error.message : JSON.stringify(m.error));
        return m.result;
      }
      const parsed = (await res.json()) as { result?: unknown; error?: { message?: string } };
      if (parsed?.error) throw new Error(typeof parsed.error?.message === "string" ? parsed.error.message : JSON.stringify(parsed.error));
      return parsed?.result;
    } finally {
      dispose();
    }
  }
}

export function createMcpClient(
  name: string,
  cfg: ManagedMcpServerConfig,
  events: McpClientEvents,
  fetchImpl?: FetchLike,
): McpClient {
  return isRemoteConfig(cfg)
    ? new RemoteMcpClient(name, cfg, events, fetchImpl)
    : new StdioMcpClient(name, cfg, events);
}
