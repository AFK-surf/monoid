// Agent tool `mcp_servers`: lets an agent inspect this station's managed third-party MCP servers (`list`)
// and propose changes (`upsert`, `remove`, `reload`) that take effect only after a workspace owner/admin
// explicitly confirms on the options card in the still.fail app (`parts.cardChoice("mcpServer", …)`).
import { randomBytes } from "node:crypto";
import { managesStation } from "../mesh/credential.ts";
import { maskValue } from "../ops/agent-env.ts";
import type { ConfigFile } from "../ops/config.ts";
import type { ManagedMcp } from "./managed-mcp.ts";
import { managedMcpConfig, mergeManagedMcpPatch } from "./managed-mcp-config.ts";
import type { Tool } from "./mcp.ts";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Json = any;
type CardAt = { thread: number; n: number; ts: string | null };

export type ManagedMcpAsksDeps = {
  managedMcp: ManagedMcp;
  config: ConfigFile;
  wsOf(session: string): string | null;
  cards: {
    post(session: string, text: string, card: unknown): Promise<{ thread: number; ts: string } | null>;
  };
  notify(session: string, text: string): void;
};

type McpAskAction = "upsert" | "remove" | "reload";

type McpAsk = {
  id: string;
  session: string;
  ws: string;
  action: McpAskAction;
  name: string | null;
  patch?: Record<string, unknown>;
  confirmLabel: string;
  state: "asked" | "confirmed" | "declined";
  thread: number | null;
  ts: string | null;
  by: string | null;
};

const MAX_PENDING_ASKS = 32;
const CONFIRM_LABEL = "批准并应用";
const DECLINE_LABEL = "拒绝";

function formatServerSummary(name: string, raw: Record<string, unknown>, isUpdate: boolean, reason: string): string {
  const transport = raw.type === "http" ? "HTTP" : raw.type === "sse" ? "SSE" : "stdio";
  const lines: string[] = [
    `**${isUpdate ? "更新" : "注册"} MCP 服务：\`${name}\`**（${transport}）`,
  ];
  if (transport === "stdio") {
    const cmd = typeof raw.command === "string" ? raw.command : "";
    const args = Array.isArray(raw.args) ? raw.args.filter((a): a is string => typeof a === "string").join(" ") : "";
    lines.push(`- 命令：\`${args ? `${cmd} ${args}` : cmd}\``);
    if (raw.env && typeof raw.env === "object" && !Array.isArray(raw.env)) {
      const keys = Object.entries(raw.env as Record<string, unknown>)
        .filter(([, v]) => typeof v === "string")
        .map(([k, v]) => `${k}=${maskValue(v as string)}`);
      if (keys.length > 0) lines.push(`- 环境变量：${keys.map((k) => `\`${k}\``).join(", ")}`);
    }
  } else {
    const url = typeof raw.url === "string" ? raw.url : "";
    lines.push(`- 地址：\`${url}\``);
    if (raw.headers && typeof raw.headers === "object" && !Array.isArray(raw.headers)) {
      const keys = Object.entries(raw.headers as Record<string, unknown>)
        .filter(([, v]) => typeof v === "string")
        .map(([k, v]) => `${k}: ${maskValue(v as string)}`);
      if (keys.length > 0) lines.push(`- 请求头：${keys.map((k) => `\`${k}\``).join(", ")}`);
    }
  }
  lines.push(`- 启用：${raw.enabled === false ? "否" : "是"} · 跨 Station 共享：${raw.shared === true ? "是" : "否"}`);
  if (reason) lines.push(`- 说明：${reason}`);
  lines.push("", "需工作区管理员/所有者点击下方按钮确认后生效。");
  return lines.join("\n");
}

export class ManagedMcpAsks {
  readonly #d: ManagedMcpAsksDeps;
  #asks: McpAsk[] = [];

  constructor(d: ManagedMcpAsksDeps) {
    this.#d = d;
  }

  async tool(session: string, rawArgs: Json): Promise<Json> {
    const nested = rawArgs?.args && typeof rawArgs.args === "object" && !Array.isArray(rawArgs.args)
      ? (rawArgs.args as Record<string, unknown>)
      : null;
    const args: Record<string, unknown> = nested !== null
      ? { ...rawArgs, ...nested, args: nested.args }
      : { ...rawArgs };
    const action = typeof args?.action === "string" ? args.action.trim() : "";
    if (action === "list") {
      return { servers: this.#d.managedMcp.view() };
    }
    const ws = this.#d.wsOf(session);
    if (ws === null) throw new Error("this chat is of no workspace here");
    const reason = typeof args?.reason === "string" ? args.reason.trim().slice(0, 400) : "";

    if (action === "upsert") {
      const name = typeof args?.name === "string" ? args.name.trim() : "";
      if (name === "") throw new Error("name is required for upsert");
      const entry = this.#buildEntry(args);
      const current = managedMcpConfig(this.#d.config.raw());
      const isUpdate = Object.prototype.hasOwnProperty.call(current, name);
      const patch: Record<string, unknown> = { [name]: entry };
      // Validate up front so invalid configs fail immediately without posting an approval card.
      mergeManagedMcpPatch(current, patch);
      const text = formatServerSummary(name, entry, isUpdate, reason);
      return await this.#postAsk(session, ws, "upsert", name, patch, text);
    }

    if (action === "remove") {
      const name = typeof args?.name === "string" ? args.name.trim() : "";
      if (name === "") throw new Error("name is required for remove");
      const current = managedMcpConfig(this.#d.config.raw());
      if (!Object.prototype.hasOwnProperty.call(current, name)) {
        throw new Error(`no managed MCP server named "${name}" on this station`);
      }
      const patch: Record<string, unknown> = { [name]: null };
      const lines = [`**删除 MCP 服务：\`${name}\`**`];
      if (reason) lines.push(`- 说明：${reason}`);
      lines.push("", "需工作区管理员/所有者点击下方按钮确认后生效。");
      return await this.#postAsk(session, ws, "remove", name, patch, lines.join("\n"));
    }

    if (action === "reload") {
      const name = typeof args?.name === "string" && args.name.trim() !== "" ? args.name.trim() : null;
      if (name !== null) {
        const current = managedMcpConfig(this.#d.config.raw());
        if (!Object.prototype.hasOwnProperty.call(current, name)) {
          throw new Error(`no managed MCP server named "${name}" on this station`);
        }
      }
      const lines = [name ? `**重新连接 MCP 服务：\`${name}\`**` : "**重新连接全部 MCP 服务**"];
      if (reason) lines.push(`- 说明：${reason}`);
      lines.push("", "需工作区管理员/所有者点击下方按钮确认后生效。");
      return await this.#postAsk(session, ws, "reload", name, undefined, lines.join("\n"));
    }

    throw new Error("action must be one of list, upsert, remove, reload");
  }

  #buildEntry(args: Json): Record<string, unknown> {
    const raw = args?.server && typeof args.server === "object" && !Array.isArray(args.server)
      ? (args.server as Record<string, unknown>)
      : (args as Record<string, unknown>);
    const out: Record<string, unknown> = {};
    if (raw.type === "http" || raw.type === "sse") {
      out.type = raw.type;
      if (typeof raw.url === "string") out.url = raw.url;
      if (raw.headers !== undefined) out.headers = raw.headers;
    } else {
      if (typeof raw.command === "string") out.command = raw.command;
      if (raw.args !== undefined) out.args = raw.args;
      if (raw.env !== undefined) out.env = raw.env;
    }
    if (typeof raw.enabled === "boolean") out.enabled = raw.enabled;
    if (typeof raw.shared === "boolean") out.shared = raw.shared;
    return out;
  }

  async #postAsk(
    session: string,
    ws: string,
    action: McpAskAction,
    name: string | null,
    patch: Record<string, unknown> | undefined,
    text: string,
  ): Promise<Json> {
    const a: McpAsk = {
      id: `mcp_${randomBytes(6).toString("hex")}`,
      session,
      ws,
      action,
      name,
      ...(patch !== undefined ? { patch } : {}),
      confirmLabel: CONFIRM_LABEL,
      state: "asked",
      thread: null,
      ts: null,
      by: null,
    };
    const card = {
      type: "options",
      options: [
        { label: CONFIRM_LABEL, detail: "立即应用此 MCP 服务变更", action: "close", recommended: true },
        { label: DECLINE_LABEL, detail: "取消此次变更", action: "close" },
      ],
      mcpServer: { ask: a.id, action, name },
    };
    const posted = await this.#d.cards.post(session, text, card);
    a.thread = posted?.thread ?? null;
    a.ts = posted?.ts ?? null;
    this.#asks = [...this.#asks.filter((x) => !(x.session === session && x.state === "asked")), a].slice(-MAX_PENDING_ASKS);
    return {
      ask: a.id,
      card: "posted",
      say: `A confirmation card is in this chat: a workspace owner or admin must approve it (${CONFIRM_LABEL}) before the MCP change takes effect. End your turn with need_human or wait for their decision.`,
    };
  }

  #askAt(card: Json, at: CardAt): McpAsk | null {
    const id = card?.mcpServer?.ask;
    const a = this.#asks.find((x) => x.id === id);
    return a === undefined || a.thread !== at.thread || a.ts !== at.ts ? null : a;
  }

  may(viewer: { role: string; workspace: string | null; email: string }, card: Json, at: CardAt): string | null {
    const a = this.#askAt(card, at);
    if (a === null || a.state !== "asked") return "This MCP confirmation card is no longer pending.";
    if (!managesStation(viewer) || viewer.workspace !== a.ws) return "Only workspace owners or admins can approve MCP server changes.";
    return null;
  }

  chosen(viewer: { email: string }, card: Json, option: string, at: CardAt): void {
    const a = this.#askAt(card, at);
    if (a === null || a.state !== "asked") return;
    a.by = viewer.email;
    const picked = option.trim();
    if (picked !== a.confirmLabel) {
      a.state = "declined";
      this.#d.notify(a.session, `${viewer.email} declined the MCP server change (${a.action}${a.name ? ` ${a.name}` : ""}): nothing was changed.`);
      return;
    }
    a.state = "confirmed";
    if (a.action === "reload") {
      void this.#d.managedMcp.reload(a.name ?? undefined).then(
        () => this.#d.notify(a.session, `${viewer.email} approved reloading MCP server${a.name ? ` "${a.name}"` : "s"}: reload triggered.`),
        (e) => this.#d.notify(a.session, `${viewer.email} approved reloading MCP server${a.name ? ` "${a.name}"` : "s"}, but it failed: ${(e as Error).message}`),
      );
      return;
    }
    const before = managedMcpConfig(this.#d.config.raw());
    let next;
    try {
      next = mergeManagedMcpPatch(before, a.patch ?? {});
    } catch (e) {
      this.#d.notify(a.session, `${viewer.email} approved MCP server change (${a.action}${a.name ? ` "${a.name}"` : ""}), but applying it failed: ${(e as Error).message}`);
      return;
    }
    void this.#d.config.updateSoon((raw) => {
      if (Object.keys(next).length > 0) raw.mcpServers = next;
      else delete raw.mcpServers;
    }).then(
      () => this.#d.notify(a.session, `${viewer.email} approved MCP server change (${a.action}${a.name ? ` "${a.name}"` : ""}): applied.`),
      (e) => this.#d.notify(a.session, `${viewer.email} approved MCP server change (${a.action}${a.name ? ` "${a.name}"` : ""}), but applying it failed: ${(e as Error).message}`),
    );
  }
}

export const MCP_SERVERS_TOOL = {
  name: "mcp_servers",
  description: "Manage station MCP servers (list/upsert/remove/reload; stdio/http/sse, shared). Writes need card.",
  inputSchema: {
    type: "object",
    properties: {
      action: { type: "string", enum: ["list", "upsert", "remove", "reload"] },
      args: { type: "object" },
    },
    required: ["action"],
    additionalProperties: false,
  },
};

export function mcpServerTools(asks: ManagedMcpAsks): Tool[] {
  return [{
    ...MCP_SERVERS_TOOL,
    run: async (session, args) => JSON.stringify(await asks.tool(session, args), null, 2),
  }];
}
