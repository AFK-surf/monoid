// Station-managed third-party MCP servers lifecycle manager:
// starts enabled servers after handover, reconnects with exponential backoff and circuit breaker on unexpected exits,
// dynamically exposes discovered tools through the station's own `stillfail` MCP endpoint, and closes all servers on shutdown.
import type { Clock } from "effect";
import { Fibers, wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import type { Content, Tool, ToolReply } from "./mcp.ts";
import { type FetchLike, type McpClient, type McpClientEvents, type UpstreamTool, createMcpClient } from "./managed-mcp-client.ts";
import {
  type ManagedMcpConfig,
  type ManagedMcpServerConfig,
  type ManagedMcpServerView,
  type ManagedMcpStatus,
  canonicalJson,
  exportedToolNames,
  managedMcpConfig,
  maskServerView,
  truncateContent,
} from "./managed-mcp-config.ts";

const BACKOFF_MS = [1_000, 2_000, 4_000, 8_000, 16_000, 30_000];
const MAX_CONSECUTIVE_FAILURES = 5;
const STABLE_RUN_MS = 60_000;
const SHORT_CRASH_MS = 10_000;
const PEER_LIST_TIMEOUT_MS = 2_000;

export type ManagedMcpPeer = { id: string; name: string };

export type ManagedMcpDeps = {
  config: { raw(): unknown };
  clock?: Clock.Clock;
  /// Called whenever server status or tool list changes (e.g., to push `overviewChanged`).
  onStatusChanged?: () => void;
  /// Other stations in a workspace (for cross-station shared MCP discovery).
  peers?: (workspace: string) => readonly ManagedMcpPeer[];
  /// Send a mesh peer RPC (`mcp.list` / `mcp.call`) to another station in the workspace.
  ask?: (station: string, request: Record<string, unknown>) => Promise<unknown>;
  /// Injectable client factory for deterministic tests.
  makeClient?: (name: string, cfg: ManagedMcpServerConfig, events: McpClientEvents) => McpClient;
  /// Injectable fetch for remote HTTP/SSE clients.
  fetchImpl?: FetchLike;
};

type ServerEntry = {
  name: string;
  configKey: string;
  cfg: ManagedMcpServerConfig;
  status: ManagedMcpStatus;
  client: McpClient | null;
  tools: UpstreamTool[];
  error: string | null;
  failures: number;
  connectedAt: number | null;
  cancelRetry: (() => void) | null;
  generation: number;
};

type ExposedEntry = {
  server: string;
  originalName: string;
  tool: Tool;
};

export class ManagedMcp {
  private readonly deps: ManagedMcpDeps;
  private readonly fibers: Fibers;
  private readonly servers = new Map<string, ServerEntry>();
  private running = false;
  private closed = false;
  private exposedList: ExposedEntry[] = [];
  /// Cached peer-hosted shared tools per workspace (refreshed on demand when a chat runs `tools/list`).
  private peerExposed = new Map<string, Tool[]>();
  private syncQueue: Promise<void> = Promise.resolve();

  constructor(deps: ManagedMcpDeps) {
    this.deps = deps;
    this.fibers = new Fibers("managed-mcp", deps.clock);
  }

  /// Starts managing all enabled servers in config.json.
  async start(): Promise<void> {
    if (this.closed) return;
    this.running = true;
    await this.syncConfig();
  }

  /// Stops all managed servers without permanently closing the manager (e.g. when station leaves workspace).
  async stop(): Promise<void> {
    this.running = false;
    await this.enqueue(async () => {
      const closes: Promise<void>[] = [];
      for (const entry of this.servers.values()) {
        entry.generation++;
        entry.cancelRetry?.();
        entry.cancelRetry = null;
        if (entry.client) {
          const c = entry.client;
          entry.client = null;
          closes.push(c.close().catch(() => {}));
        }
        entry.tools = [];
        entry.status = entry.cfg.enabled === false ? "disabled" : "stopped";
        entry.connectedAt = null;
      }
      await Promise.all(closes);
      this.rebuildExposed();
      this.deps.onStatusChanged?.();
    });
  }

  /// Permanent shutdown (called in `AgentsLive` finalizer after `door.close`).
  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.running = false;
    await this.fibers.close();
    const closes: Promise<void>[] = [];
    for (const entry of this.servers.values()) {
      entry.generation++;
      entry.cancelRetry?.();
      entry.cancelRetry = null;
      if (entry.client) {
        const c = entry.client;
        entry.client = null;
        closes.push(c.close().catch(() => {}));
      }
      entry.tools = [];
      entry.status = "stopped";
    }
    await Promise.all(closes);
    this.servers.clear();
    this.exposedList = [];
  }

  /// Reconciles running servers against current `config.json`.
  /// Never restarts active agent sessions; chats discover updated tools on demand via `tools/list` or `station_tool`.
  async syncConfig(): Promise<void> {
    await this.enqueue(async () => {
      const cfg = managedMcpConfig(this.deps.config.raw());
      await this.reconcile(cfg);
      this.rebuildExposed();
      this.deps.onStatusChanged?.();
    });
  }

  /// Manually reconnects one server (or all enabled servers), resetting circuit-breaker state.
  /// Marks targets as `connecting` synchronously so non-blocking callers (e.g. HTTP routes) immediately see it.
  reload(name?: string): Promise<void> {
    const cfgNow = managedMcpConfig(this.deps.config.raw());
    const initialTargets = name ? (cfgNow[name] ? [name] : []) : Object.keys(cfgNow);
    for (const n of initialTargets) {
      if (cfgNow[n]?.enabled === false) continue;
      const live = this.servers.get(n);
      if (live) {
        live.status = "connecting";
        live.error = null;
      }
    }
    return this.enqueue(async () => {
      const cfg = managedMcpConfig(this.deps.config.raw());
      const targets = name ? (cfg[name] ? [name] : []) : Object.keys(cfg);
      if (targets.length === 0) return;
      const tasks: Promise<void>[] = [];
      for (const n of targets) {
        const serverCfg = cfg[n]!;
        if (serverCfg.enabled === false) continue;
        const existing = this.servers.get(n);
        if (existing) {
          existing.failures = 0;
          existing.error = null;
          tasks.push(this.restartEntry(existing));
        } else if (this.running) {
          const created = this.makeEntry(n, serverCfg);
          this.servers.set(n, created);
          tasks.push(this.connectEntry(created));
        }
      }
      await Promise.all(tasks);
      this.rebuildExposed();
      this.deps.onStatusChanged?.();
    });
  }

  /// Tools currently exposed to `McpEndpoint` (local + any cached peer shared tools).
  exposed(): readonly Tool[] {
    const local = this.exposedList.map((e) => e.tool);
    if (this.peerExposed.size === 0) return local;
    const seen = new Set(local.map((t) => t.name));
    const out = [...local];
    for (const list of this.peerExposed.values()) {
      for (const t of list) {
        if (!seen.has(t.name)) {
          seen.add(t.name);
          out.push(t);
        }
      }
    }
    return out;
  }

  /// Queries online peer stations in `workspace` for their shared (`shared: true`) MCP tools on demand,
  /// combining them with local tools. Local servers always take precedence on server-name collision.
  async exposedFor(workspace: string | null | undefined): Promise<readonly Tool[]> {
    const local = this.exposedList.map((e) => e.tool);
    if (!workspace || !this.deps.peers || !this.deps.ask) return local;
    const peers = this.deps.peers(workspace);
    if (peers.length === 0) {
      this.peerExposed.delete(workspace);
      return local;
    }
    const localServers = new Set(this.servers.keys());
    const fetched = await Promise.all(
      peers.map(async (peer) => {
        try {
          const ans = (await wall.within(
            PEER_LIST_TIMEOUT_MS,
            this.deps.ask!(peer.id, { method: "mcp.list", workspace }),
            `mcp.list timed out for ${peer.name}`,
          )) as { servers?: Array<{ name?: unknown; tools?: UpstreamTool[] }> } | null;
          const servers = Array.isArray(ans?.servers) ? ans!.servers : [];
          return { peer, servers };
        } catch {
          return { peer, servers: [] as Array<{ name?: unknown; tools?: UpstreamTool[] }> };
        }
      }),
    );

    // Count how many peers advertise each server name so collisions get deterministic peer-prefixed names.
    const serverCounts = new Map<string, number>();
    for (const { servers } of fetched) {
      for (const s of servers) {
        if (typeof s.name === "string" && s.name !== "") {
          serverCounts.set(s.name, (serverCounts.get(s.name) ?? 0) + 1);
        }
      }
    }

    const remoteTools: Tool[] = [];
    for (const { peer, servers } of fetched) {
      const peerTag = peer.id.slice(0, 6);
      for (const s of servers) {
        const srvName = typeof s.name === "string" ? s.name : "";
        if (!srvName || !Array.isArray(s.tools) || s.tools.length === 0) continue;
        const prefix = localServers.has(srvName) || (serverCounts.get(srvName) ?? 0) > 1 ? `${peerTag}_${srvName}` : srvName;
        const mapped = exportedToolNames(prefix, s.tools.map((t) => t.name));
        for (const upstream of s.tools) {
          const exported = mapped.get(upstream.name)!;
          const origName = upstream.name;
          remoteTools.push({
            name: exported,
            description: upstream.description
              ? `[${srvName} @ ${peer.name}] ${upstream.description}`
              : `[${srvName} @ ${peer.name}] ${origName}`,
            inputSchema: upstream.inputSchema,
            outward: true,
            run: async () => {
              throw new Error("remote managed MCP tools run via content()");
            },
            content: async (_session, args): Promise<ToolReply> => {
              try {
                const res = (await this.deps.ask!(peer.id, {
                  method: "mcp.call",
                  workspace,
                  server: srvName,
                  tool: origName,
                  arguments: args,
                })) as { content?: Content[]; isError?: boolean } | null;
                const content = Array.isArray(res?.content) ? truncateContent(res!.content) : [{ type: "text" as const, text: "" }];
                return { content, ...(res?.isError === true ? { isError: true } : {}) };
              } catch (err) {
                return {
                  content: [{ type: "text", text: `Remote MCP call to ${srvName} on ${peer.name} failed: ${(err as Error).message}` }],
                  isError: true,
                };
              }
            },
          });
        }
      }
    }
    this.peerExposed.set(workspace, remoteTools);
    return [...local, ...remoteTools];
  }

  /// Handles inbound mesh peer RPCs (`mcp.list` and `mcp.call`) from other stations in the same workspace.
  async handlePeer(_peer: string, request: Record<string, unknown>): Promise<unknown> {
    if (request?.method === "mcp.list") {
      const servers: { name: string; tools: UpstreamTool[] }[] = [];
      for (const name of [...this.servers.keys()].sort()) {
        const entry = this.servers.get(name)!;
        if (entry.cfg.enabled !== false && entry.cfg.shared === true && entry.status === "ready" && entry.client) {
          servers.push({ name, tools: entry.tools });
        }
      }
      return { servers };
    }
    if (request?.method === "mcp.call") {
      const serverName = typeof request.server === "string" ? request.server : "";
      const toolName = typeof request.tool === "string" ? request.tool : "";
      const args = request.arguments && typeof request.arguments === "object" && !Array.isArray(request.arguments)
        ? (request.arguments as Record<string, unknown>)
        : {};
      const entry = this.servers.get(serverName);
      if (!entry || entry.cfg.enabled === false || entry.cfg.shared !== true || entry.status !== "ready" || !entry.client) {
        return {
          content: [{ type: "text", text: `MCP server ${serverName} is not shared or not ready on this station.` }],
          isError: true,
        };
      }
      return await this.callTool(serverName, toolName, args);
    }
    throw new Error(`unknown mcp peer method: ${String(request?.method ?? "")}`);
  }

  /// Masked config + live status view for `GET /overview` and `GET /mcp-servers`.
  view(): ManagedMcpServerView[] {
    const cfg = managedMcpConfig(this.deps.config.raw());
    return Object.keys(cfg)
      .sort()
      .map((name) => {
        const serverCfg = cfg[name]!;
        const live = this.servers.get(name);
        const status: ManagedMcpStatus = live
          ? live.status
          : serverCfg.enabled === false
            ? "disabled"
            : this.running
              ? "connecting"
              : "stopped";
        return maskServerView(name, serverCfg, {
          status,
          tools: live ? live.tools.map((t) => t.name) : [],
          error: live ? live.error : null,
        });
      });
  }

  private enqueue(fn: () => Promise<void>): Promise<void> {
    const next = this.syncQueue.then(fn, fn);
    this.syncQueue = next.catch(() => {});
    return next;
  }

  private makeEntry(name: string, cfg: ManagedMcpServerConfig): ServerEntry {
    return {
      name,
      configKey: canonicalJson(cfg),
      cfg,
      status: cfg.enabled === false ? "disabled" : "stopped",
      client: null,
      tools: [],
      error: null,
      failures: 0,
      connectedAt: null,
      cancelRetry: null,
      generation: 0,
    };
  }

  private async reconcile(cfg: ManagedMcpConfig): Promise<void> {
    const ops: Promise<void>[] = [];

    // Stop & remove deleted servers.
    for (const [name, entry] of [...this.servers.entries()]) {
      if (!(name in cfg)) {
        this.servers.delete(name);
        ops.push(this.teardownEntry(entry));
      }
    }

    // Add or update configured servers.
    for (const [name, serverCfg] of Object.entries(cfg)) {
      const key = canonicalJson(serverCfg);
      const existing = this.servers.get(name);
      if (!existing) {
        const entry = this.makeEntry(name, serverCfg);
        this.servers.set(name, entry);
        if (this.running && serverCfg.enabled !== false) {
          ops.push(this.connectEntry(entry));
        }
        continue;
      }
      if (existing.configKey !== key) {
        existing.cfg = serverCfg;
        existing.configKey = key;
        existing.failures = 0;
        existing.error = null;
        if (serverCfg.enabled === false) {
          ops.push(
            this.teardownEntry(existing).then(() => {
              existing.status = "disabled";
            }),
          );
        } else if (this.running) {
          ops.push(this.restartEntry(existing));
        } else {
          ops.push(
            this.teardownEntry(existing).then(() => {
              existing.status = "stopped";
            }),
          );
        }
      } else if (this.running && serverCfg.enabled !== false && existing.status === "stopped") {
        ops.push(this.connectEntry(existing));
      }
    }

    await Promise.all(ops);
  }

  private async teardownEntry(entry: ServerEntry): Promise<void> {
    entry.generation++;
    entry.cancelRetry?.();
    entry.cancelRetry = null;
    entry.tools = [];
    entry.connectedAt = null;
    if (entry.client) {
      const c = entry.client;
      entry.client = null;
      await c.close().catch(() => {});
    }
  }

  private async restartEntry(entry: ServerEntry): Promise<void> {
    await this.teardownEntry(entry);
    if (this.running && !this.closed && entry.cfg.enabled !== false) {
      await this.connectEntry(entry);
    }
  }

  private async connectEntry(entry: ServerEntry): Promise<void> {
    if (!this.running || this.closed || entry.cfg.enabled === false) return;
    const gen = ++entry.generation;
    entry.cancelRetry?.();
    entry.cancelRetry = null;
    entry.status = "connecting";
    this.deps.onStatusChanged?.();

    const events: McpClientEvents = {
      onToolsChanged: () => {
        if (entry.generation !== gen || this.closed || !this.running) return;
        // Upstream live tools/list_changed: refresh tool table only; do NOT restart active sessions.
        this.fibers.spawn(async () => {
          const client = entry.client;
          if (!client || entry.generation !== gen) return;
          try {
            const tools = await client.listTools();
            if (entry.generation !== gen) return;
            entry.tools = tools;
            this.rebuildExposed();
            this.deps.onStatusChanged?.();
          } catch (err) {
            log.warn("mcp", "failed to refresh tools after list_changed", { server: entry.name, error: String(err) });
          }
        });
      },
      onExit: (err) => {
        if (entry.generation !== gen || this.closed || !this.running) return;
        this.onUnexpectedFailure(entry, gen, err);
      },
    };

    const client = this.deps.makeClient
      ? this.deps.makeClient(entry.name, entry.cfg, events)
      : createMcpClient(entry.name, entry.cfg, events, this.deps.fetchImpl);
    entry.client = client;

    try {
      const tools = await client.connect();
      if (entry.generation !== gen || this.closed || !this.running) {
        await client.close().catch(() => {});
        return;
      }
      entry.tools = tools;
      entry.status = "ready";
      entry.error = null;
      entry.connectedAt = this.fibers.now();
      this.rebuildExposed();
      this.deps.onStatusChanged?.();
      log.info("mcp", "managed MCP server connected", { server: entry.name, tools: tools.length });
    } catch (err) {
      if (entry.generation !== gen || this.closed || !this.running) {
        await client.close().catch(() => {});
        return;
      }
      await client.close().catch(() => {});
      if (entry.client === client) entry.client = null;
      this.onUnexpectedFailure(entry, gen, err instanceof Error ? err : new Error(String(err)));
    }
  }

  private onUnexpectedFailure(entry: ServerEntry, gen: number, error: Error): void {
    if (entry.generation !== gen || this.closed || !this.running) return;
    const now = this.fibers.now();
    const uptime = entry.connectedAt !== null ? now - entry.connectedAt : 0;
    if (entry.connectedAt !== null && uptime >= STABLE_RUN_MS) {
      entry.failures = 0;
    }
    entry.connectedAt = null;
    entry.client = null;
    entry.tools = [];
    entry.error = error.message.slice(0, 500);
    entry.failures++;

    const shortLived = uptime < SHORT_CRASH_MS;
    if (entry.failures >= MAX_CONSECUTIVE_FAILURES && shortLived) {
      entry.status = "failed";
      this.rebuildExposed();
      this.deps.onStatusChanged?.();
      log.warn("mcp", "managed MCP server tripped circuit breaker", {
        server: entry.name,
        failures: entry.failures,
        error: entry.error,
      });
      return;
    }

    const delay = BACKOFF_MS[Math.min(entry.failures - 1, BACKOFF_MS.length - 1)]!;
    entry.status = "reconnecting";
    this.rebuildExposed();
    this.deps.onStatusChanged?.();
    log.warn("mcp", "managed MCP server disconnected; scheduling reconnect", {
      server: entry.name,
      failures: entry.failures,
      delayMs: delay,
      error: entry.error,
    });
    entry.cancelRetry?.();
    entry.cancelRetry = this.fibers.after(delay, () => { // timer: a retry after a failure, with a backoff (managed MCP reconnect)
      if (entry.generation !== gen || this.closed || !this.running) return;
      entry.cancelRetry = null;
      return this.connectEntry(entry);
    });
  }

  private rebuildExposed(): void {
    const list: ExposedEntry[] = [];
    const sortedNames = [...this.servers.keys()].sort();
    for (const serverName of sortedNames) {
      const entry = this.servers.get(serverName)!;
      if (entry.status !== "ready" || !entry.client) continue;
      const mapped = exportedToolNames(serverName, entry.tools.map((t) => t.name));
      for (const upstream of entry.tools) {
        const exported = mapped.get(upstream.name)!;
        const origName = upstream.name;
        const tool: Tool = {
          name: exported,
          description: upstream.description ? `[${serverName}] ${upstream.description}` : `[${serverName}] ${origName}`,
          inputSchema: upstream.inputSchema,
          outward: true,
          run: async () => {
            throw new Error("managed MCP tools run via content()");
          },
          content: (_session, args, signal): Promise<ToolReply> => this.callTool(serverName, origName, args, signal),
        };
        list.push({ server: serverName, originalName: origName, tool });
      }
    }
    this.exposedList = list;
  }

  private async callTool(serverName: string, originalToolName: string, args: Record<string, unknown>, signal?: AbortSignal): Promise<ToolReply> {
    const entry = this.servers.get(serverName);
    if (!entry || entry.status !== "ready" || !entry.client) {
      return {
        content: [{ type: "text", text: `MCP server ${serverName} is not available right now (${entry?.status ?? "removed"}).` }],
        isError: true,
      };
    }
    return await entry.client.callTool(originalToolName, args, signal);
  }
}
