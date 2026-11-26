// The station's MCP endpoint: streamable HTTP, JSON responses only. Every request carries the
// session's bearer token; tools run on behalf of that session. This takes a request's method, authorization and body,
// and gives its status and body; the HTTP wiring is the server's.
import { log } from "../ops/log.ts";
import type { Traces } from "../mesh/traces.ts";

/// The tools that reach out of the station, refused while it is in no workspace (`gated`): what posts or sends to
/// people (chat_post, into still.fail chats and Slack, with its files), slack_api (as the workspace's Slack bot) and
/// job_start, and the peer stations' tools (peer_forward too). The rest only read the station's own records, record the turn's state
/// (chat_state) or stop something (job_stop), and stay open.
export const OUTWARD = ["chat_post", "slack_api", "job_start", "station_list", "station_task", "station_file", "peer_forward", "project_manage"];

/// What a refused outward call says.
export const UNBOUND_REFUSAL =
  "Refused: this station is not in a still.fail workspace right now (it was removed from it, or has not joined one), so it does not post to chats or Slack, call Slack, or start jobs. Nothing was sent. Stop here and do not retry: when the station is back in its workspace, the interrupted work resumes and you can post then.";

/// A tool result's parts (MCP's content): text, image, audio, embedded resource, or resource link.
export type Content =
  | { type: "text"; text: string }
  | { type: "image"; data: string; mimeType: string }
  | { type: "audio"; data: string; mimeType: string }
  | { type: "resource"; resource: Record<string, unknown> }
  | { type: "resource_link"; uri: string; name?: string; description?: string; mimeType?: string };
export type ToolReply = { content: Content[]; isError?: boolean };

export type Tool = {
  name: string;
  description: string;
  inputSchema: unknown;
  /// True for dynamically registered tools (such as station-managed third-party MCP tools) that reach outside the station
  /// and must be refused while the station is unbound from its workspace.
  outward?: boolean;
  /// The text the agent sees; a thrown error's message comes back as a tool error.
  run(session: string, args: Record<string, unknown>, signal?: AbortSignal): Promise<string>;
  /// What the agent sees when it is more than text (a screenshot, or passthrough MCP content): called instead of `run` where there is one.
  content?(session: string, args: Record<string, unknown>, signal?: AbortSignal): Promise<ToolReply>;
  /// Whether this call, which succeeded and answered `said`, ended the session's turn: nothing is left for its model to
  /// read, so a runtime that can stop there (`Listing.ended`) makes no further request.
  endsTurn?(session: string, args: Record<string, unknown>, said: string): boolean;
};

export type Reply = { status: number; body?: unknown };

/// A tool as tools/list declares it; `_meta` only where its session's runtime reads one (`Listing.loaded`).
export type Declared = { name: string; description: string; inputSchema: unknown; _meta?: Readonly<Record<string, unknown>> };
const declared = (t: Tool): Declared => ({ name: t.name, description: t.description, inputSchema: t.inputSchema });
/// What a tool's declaration weighs: its bytes as JSON, as a runtime that budgets its tools measures them closely enough.
export const weight = (t: Tool) => Buffer.byteLength(JSON.stringify(declared(t)));

/// Declared first, whatever the budget: what every turn needs (posting, ending it, reading the chat) and the work
/// sent elsewhere.
export const CORE = ["chat_post", "chat_state", "chat_history", "chat_read", "job_start", "job_log", "job_list", "job_stop", "station_task", "station_file", "skill_read"];

/// Declared next when a runtime budgets its tools (`fitted`), in this order, before sorting the remaining tools by size:
/// everyday discovery (first, so `agy` can find workspace skills omitted from `.agent/skills` without an extra
/// station_tool round-trip), collaboration, and session/device tools.
export const PRIORITY = [
  "search", "chat_list", "chat_create", "session_send", "chat_configure", "chat_archive", "session_history",
  "station_list", "device_list", "device_use", "browser", "screen", "secret_list", "secret_use", "secret_run",
];

/// Superseded tools kept callable for sessions begun before they were retired, but omitted from tools/list and
/// station_tool so new sessions pay nothing for them (device_list/device_use replace adb_devices/phone_use; persistent
/// system cards replace secret_reask; station_move replaces station_retire).
export const HIDDEN = ["adb_devices", "phone_use", "secret_reask", "station_retire"];

/// What every turn calls: an agent's answer reaches people only through chat_post, and a turn ends with it or chat_state.
export const EVERY_TURN = ["chat_post", "chat_state"];

/// By which a session speaks or acts in chats as itself: it posts, ends its turn, writes to another chat's agent, opens
/// a chat, leaves one, archives or configures one. They are for the session's own agent alone (the user, 2026-11-14: 「subagent
/// 不应该能自己发消息」): one it started hands its result back to it and says nothing itself. The endpoint cannot hold
/// that: a subagent's call comes with its session's token, as its parent's does, so each runtime's driver keeps its
/// subagents from these (agents/claude.ts `SILENT_SUBAGENTS`). Not OUTWARD, which is where a call lands whoever makes
/// it: a subagent starts a job or a task as its parent would, and chat_state lands nowhere outside the station.
/// A new tool is sorted into these or out of them in test/speaks.test.ts.
export const SPEAKS = ["chat_post", "chat_state", "session_send", "chat_create", "chat_leave", "chat_archive", "chat_configure", "project_manage"];
/// The one that speaks only where its method writes (a post, an edit, a reaction, a direct message, as the session's
/// Slack bot): its own agent's alone as those above are, while a subagent reads Slack as its parent does, so a driver
/// keeps its subagents from the writes and lets the rest through.
export const SPEAKS_WRITING = "slack_api";
/// The Slack methods that write, each a method or the start of some: they land in a thread, so the threads rule
/// applies to them (sessions/conversations.ts `slackApi`), and they are what a subagent is kept from. One list for
/// both: what is added here for the one holds for the other.
export const SLACK_WRITES = [
  "chat.postMessage",
  "chat.postEphemeral",
  "chat.scheduleMessage",
  "chat.update",
  "chat.delete",
  "chat.meMessage",
  "reactions.add",
  "reactions.remove",
  "pins.add",
  "pins.remove",
  "files.completeUploadExternal",
  "assistant.threads.",
];
export const isSlackWrite = (method: string) => SLACK_WRITES.some((w) => method.startsWith(w));
/// What a subagent is kept from in Slack: the writes, and a streamed message, which puts words in a thread as a post
/// does. Not among the writes: the threads rule finds a write's thread by the message it names, and a stream's later
/// calls name only the stream's own message, which the station keeps no row of.
export const SLACK_SPOKEN = [...SLACK_WRITES, "chat.startStream", "chat.appendStream", "chat.stopStream"];
export const speaksInSlack = (method: string) => SLACK_SPOKEN.some((w) => method.startsWith(w));

/// What a session's runtime needs of its list of tools; nothing said, the list is every tool as it is.
export type Listing = {
  /// How many bytes of tools it declares to its model, for one that drops those beyond (`fitted`).
  budget?: number;
  /// The `_meta` by which it declares a tool to its model from the first request, for one that otherwise keeps a
  /// server's tools back until its model searches for them: put on the EVERY_TURN tools alone, so that a turn does not
  /// begin with a search for what it must call, and the rest stay as cheap as that runtime made them.
  loaded?: Readonly<Record<string, unknown>>;
  /// The `_meta` of a tool result by which it ends its turn there, for a call that `endsTurn`.
  ended?: Readonly<Record<string, unknown>>;
};

/// The tool that reaches those a budget left undeclared.
export const INDIRECT = "station_tool";

/// The tools to declare within `budget` bytes, and the rest, reached through INDIRECT. A runtime that budgets its tools
/// drops the largest beyond it and gives the model no way to call them (Antigravity CLI 1.5.6 in ACP: chat_post,
/// the largest, went first, and a session could no longer post). So the list is fitted here, deterministically: the
/// CORE tools, then PRIORITY tools in order, then the others from the lightest while they fit, and INDIRECT naming the
/// rest. HIDDEN tools are omitted from both lists. So many left over that INDIRECT naming them would not fit (a large
/// third-party MCP server's, hosted by the station: 120 tools listed 41 KB to Antigravity CLI, past what it keeps, and
/// would push chat_post out of its pool again, FB-66), the CORE tools and the PRIORITY ones that fit beside the
/// smallest INDIRECT are declared, and INDIRECT takes the fullest of its forms that fits in what is left (`room`).
export function fitted(tools: readonly Tool[], budget: number): { declared: Tool[]; indirect: Tool[]; room: number } {
  const visible = tools.filter((t) => !HIDDEN.includes(t.name));
  const core = CORE.flatMap((name) => visible.filter((t) => t.name === name));
  const priority = PRIORITY.flatMap((name) => visible.filter((t) => t.name === name && !CORE.includes(t.name)));
  const rest = visible.filter((t) => !CORE.includes(t.name) && !PRIORITY.includes(t.name)).sort((a, b) => weight(a) - weight(b) || (a.name < b.name ? -1 : 1));
  const queue = [...priority, ...rest];
  const fits = (list: readonly Tool[], left: readonly Tool[]) => list.reduce((n, t) => n + weight(t), 0) + (left.length === 0 ? 0 : weight(indirectTool(left)));
  const out = [...core];
  const indirect: Tool[] = [];
  for (let i = 0; i < queue.length; i++) {
    const t = queue[i]!;
    if (fits([...out, t], [...indirect, ...queue.slice(i + 1)]) <= budget) out.push(t);
    else indirect.push(t);
  }
  const sum = (list: readonly Tool[]) => list.reduce((n, t) => n + weight(t), 0);
  if (fits(out, indirect) <= budget) return { declared: visible.filter((t) => out.includes(t)), indirect, room: budget - sum(out) };
  const least = weight(indirectTool(queue, 0));
  const kept = [...core];
  for (const t of priority) if (sum([...kept, t]) + least <= budget) kept.push(t);
  const left = queue.filter((t) => !kept.includes(t));
  return { declared: visible.filter((t) => kept.includes(t)), indirect: left, room: budget - sum(kept) };
}

/// The tool that calls one left undeclared by name: given only `name`, it answers that tool's description and
/// parameters; given `arguments` too, it runs it (the endpoint runs it as it runs any call, refusals included); given
/// no name, it lists them. Its fullest form that weighs at most `room` bytes: each named with its first sentence; each
/// named; none named, for it to list.
export function indirectTool(rest: readonly Tool[], room = Infinity): Tool {
  const run = async () => {
    throw new Error("station_tool is run by the endpoint");
  };
  const args = { type: "object", description: "The tool's arguments, as its parameters say." };
  const lines = rest.map((t) => `${t.name}: ${firstSentence(t.description)}`).join("\n");
  const full: Tool = {
    name: INDIRECT,
    description: `Call a station tool not declared to you, by name. First call it with only name to read that tool's description and parameters, then with name and arguments to run it. The tools:\n${lines}`,
    inputSchema: { type: "object", properties: { name: { type: "string", enum: rest.map((t) => t.name) }, arguments: args }, required: ["name"] },
    run,
  };
  if (weight(full) <= room) return full;
  const named: Tool = {
    name: INDIRECT,
    description: `Call a station tool not declared to you, by name. Call it with no name to list them with what each does, with only name to read one's description and parameters, then with name and arguments to run it. The tools: ${rest.map((t) => t.name).join(", ")}`,
    inputSchema: { type: "object", properties: { name: { type: "string", enum: rest.map((t) => t.name) }, arguments: args } },
    run,
  };
  if (weight(named) <= room) return named;
  return {
    name: INDIRECT,
    description: `Call a station tool not declared to you (${rest.length} of them, the station's and its MCP servers'), by name. Call it with no name first to list them with what each does, then with only name to read one's description and parameters, then with name and arguments to run it.`,
    inputSchema: { type: "object", properties: { name: { type: "string" }, arguments: args } },
    run,
  };
}

const firstSentence = (text: string) => {
  const m = /^.*?[.:](?=\s|$)/s.exec(text);
  return (m ? m[0] : text).replace(/\s+/g, " ").slice(0, 160);
};

/// The arguments as the tool's schema types them now. A session whose tool list is older than a parameter (it is told to
/// pass new ones anyway) sends it untyped, as text: `done: "true"` (2026-11-03: phone_use {done: true} from such a
/// session was read as not given). A boolean or number parameter given as its text is read as the value it says.
export function typed(args: Record<string, unknown>, schema: unknown): Record<string, unknown> {
  const properties = (schema as { properties?: Record<string, { type?: unknown }> } | null)?.properties;
  if (properties === undefined || properties === null) return args;
  let out: Record<string, unknown> | null = null;
  for (const [key, value] of Object.entries(args)) {
    if (typeof value !== "string") continue;
    const type = properties[key]?.type;
    const t = value.trim();
    const read = type === "boolean" ? (t === "true" ? true : t === "false" ? false : undefined)
      : (type === "number" || type === "integer") && /^-?\d+(\.\d+)?$/.test(t) ? Number(t) : undefined;
    if (read === undefined) continue;
    out ??= { ...args };
    out[key] = read;
  }
  return out ?? args;
}

export class McpEndpoint {
  /// The tools as they are now: the agents' own and the station's parts' (parts.ts), which say theirs as they are made.
  private tools: () => readonly Tool[];
  /// A bearer token's session key.
  private resolve: (token: string) => string | undefined;
  /// Why the OUTWARD tools are refused now for a session, if they are.
  private gate?: (session: string) => string | undefined;
  /// What a session's runtime needs of its list, where it needs anything.
  private listing?: (session: string) => Listing | undefined;
  /// How many `tools/list` or `tools/call` requests each session's token made here (`heard`).
  private heardBy = new Map<string, number>();
  private traces?: () => Traces | null;
  private runtimeOf?: (session: string) => string | undefined;
  private dynamicTools?: (session: string) => Promise<readonly Tool[]>;

  constructor(
    resolve: (token: string) => string | undefined,
    tools: readonly Tool[] | (() => readonly Tool[]),
    gate?: (session: string) => string | undefined,
    listing?: (session: string) => Listing | undefined,
    options?: {
      traces?: () => Traces | null;
      runtimeOf?: (session: string) => string | undefined;
      dynamicTools?: (session: string) => Promise<readonly Tool[]>;
    },
  ) {
    this.tools = typeof tools === "function" ? tools : () => tools;
    this.resolve = resolve;
    this.gate = gate;
    this.listing = listing;
    this.traces = options?.traces;
    this.runtimeOf = options?.runtimeOf;
    this.dynamicTools = options?.dynamicTools;
  }

  /// The tools a session is declared: all of them, or those within its runtime's budget and INDIRECT for the rest;
  /// the EVERY_TURN ones with its runtime's `loaded`, whose bytes its budget counts. A runtime that needs nothing is
  /// declared them byte for byte as before there was any of this: some validate or weigh what they are given.
  private listed(session: string, extra: readonly Tool[] = []): Declared[] {
    const base = this.tools();
    const seen = new Set(base.map((t) => t.name));
    const merged = extra.length === 0 ? base : [...base, ...extra.filter((t) => !seen.has(t.name))];
    const visible = merged.filter((t) => !HIDDEN.includes(t.name));
    const { budget, loaded } = this.listing?.(session) ?? {};
    const say = (t: Tool): Declared => (loaded !== undefined && EVERY_TURN.includes(t.name) ? { ...declared(t), _meta: loaded } : declared(t));
    if (budget === undefined) return visible.map(say);
    const marks = visible.reduce((n, t) => n + Buffer.byteLength(JSON.stringify(say(t))) - weight(t), 0);
    const { declared: fit, indirect, room } = fitted(visible, budget - marks);
    return (indirect.length === 0 ? fit : [...fit, indirectTool(indirect, room)]).map(say);
  }

  /// How many `tools/list` or `tools/call` requests session `session`'s token made of the endpoint since the station
  /// started: a process opened while it stays the same never reached the station's tools (mb-actor.ts `toolsUnheard`).
  heard(session: string): number {
    return this.heardBy.get(session) ?? 0;
  }

  async handle(method: string, authorization: string | undefined, body: Buffer | string, signal?: AbortSignal): Promise<Reply> {
    if (method !== "POST") return { status: 405 };
    const token = (authorization ?? "").replace(/^(Bearer |bearer )/, "").trim();
    const session = token ? this.resolve(token) : undefined;
    if (!session) return { status: 401, body: { error: "unknown session token" } };
    let message: any;
    try {
      message = JSON.parse(body.toString());
    } catch {
      return { status: 400, body: { jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } } };
    }
    if (message === null || typeof message !== "object" || !("id" in message)) return { status: 202 }; // a notification
    const params = message.params ?? null;
    const reply = (rest: Record<string, unknown>): Reply => ({ status: 200, body: { jsonrpc: "2.0", id: message.id, ...rest } });
    switch (typeof message.method === "string" ? message.method : "") {
      case "initialize":
        return reply({
          result: {
            protocolVersion: typeof params?.protocolVersion === "string" ? params.protocolVersion : "2025-06-18",
            capabilities: { tools: {} },
            serverInfo: { name: "still.fail", version: "0.0.0" },
          },
        });
      case "ping":
        return reply({ result: {} });
      case "tools/list": {
        this.heardBy.set(session, this.heard(session) + 1);
        const extra = this.dynamicTools ? await this.dynamicTools(session).catch(() => []) : [];
        return reply({ result: { tools: this.listed(session, extra) } });
      }
      case "tools/call": {
        this.heardBy.set(session, this.heard(session) + 1);
        let name = typeof params?.name === "string" ? params.name : "";
        let given = params?.arguments && typeof params.arguments === "object" && !Array.isArray(params.arguments) ? params.arguments : {};
        // One left undeclared, called through INDIRECT: its description and parameters, or its run as any call's; no
        // name, the list of them (its declaration may name none, `indirectTool`).
        let reached: Tool | undefined;
        if (name === INDIRECT && !this.tools().some((t) => t.name === INDIRECT)) {
          // (those a third-party MCP server of another station gives are listed and reached as the station's own)
          const extra = this.dynamicTools ? await this.dynamicTools(session).catch(() => []) : [];
          const own = this.tools();
          const all = [...own, ...extra.filter((t) => !own.some((o) => o.name === t.name))].filter((t) => t.name !== INDIRECT);
          if (given.name === undefined || given.name === null || given.name === "") {
            const lines = all.filter((t) => !HIDDEN.includes(t.name)).map((t) => `${t.name}: ${firstSentence(t.description)}`);
            return reply({ result: { content: [{ type: "text", text: lines.join("\n") }] } });
          }
          const named = typeof given.name === "string" ? all.find((t) => t.name === given.name) : undefined;
          if (!named) return reply({ result: { content: [{ type: "text", text: `No station tool ${JSON.stringify(given.name)}: call station_tool with no name to list them.` }], isError: true } });
          const args = given.arguments;
          if (args === undefined || args === null) return reply({ result: { content: [{ type: "text", text: JSON.stringify(declared(named)) }] } });
          if (typeof args !== "object" || Array.isArray(args)) return reply({ result: { content: [{ type: "text", text: "arguments must be an object." }], isError: true } });
          name = named.name;
          given = args;
          reached = named;
        }
        const tool = reached ?? this.tools().find((t) => t.name === name);
        if (!tool) return reply({ error: { code: -32602, message: `unknown tool ${name}` } });
        if (OUTWARD.includes(name) || tool.outward === true) {
          const why = this.gate?.(session);
          if (why !== undefined) {
            log.warn("mcp", "outward tool refused: the station is in no workspace", { session, tool: name });
            return reply({ result: { content: [{ type: "text", text: why }], isError: true } });
          }
        }
        const args = typed(given, tool.inputSchema);
        const traces = this.traces?.() ?? null;
        const span = traces?.startRoot() ?? null;
        const toolAttrs = (errType?: string): [string, unknown][] => {
          const a: [string, unknown][] = [["stillfail.tool", name]];
          const rt = this.runtimeOf?.(session);
          if (rt) a.push(["stillfail.runtime", rt]);
          if (errType) a.push(["error.type", errType]);
          return a;
        };
        try {
          if (tool.content) {
            const { content, isError } = await tool.content(session, args, signal);
            if (span && traces) traces.endInternal(span, "mcp.tool", toolAttrs(isError ? "tool_error" : undefined), isError === true, { alwaysKeep: false, slowMs: 500 });
            return reply({ result: { content, ...(isError ? { isError: true } : {}) } });
          }
          const said = await tool.run(session, args, signal);
          if (span && traces) traces.endInternal(span, "mcp.tool", toolAttrs(), false, { alwaysKeep: false, slowMs: 500 });
          const ended = this.listing?.(session)?.ended;
          const stops = ended !== undefined && tool.endsTurn?.(session, args, said) === true;
          return reply({ result: { content: [{ type: "text", text: said }], ...(stops ? { _meta: ended } : {}) } });
        } catch (error) {
          if (span && traces) traces.endInternal(span, "mcp.tool", toolAttrs(signal?.aborted ? "aborted" : "error"), true, { alwaysKeep: false, slowMs: 500 });
          if (!signal?.aborted) log.warn("mcp", "tool call failed", { session, tool: name, error: (error as Error).message });
          return reply({ result: { content: [{ type: "text", text: (error as Error).message }], isError: true } });
        }
      }
      default:
        return reply({ error: { code: -32601, message: `method not found: ${message.method}` } });
    }
  }
}
