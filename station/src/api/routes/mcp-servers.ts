// Station-managed third-party MCP servers API (`config.json` `mcpServers`):
// - GET /mcp-servers: masked config + live status for any workspace member
// - PUT /mcp-servers: patch `{ servers: { [name]: entry | null } }` for workspace owners and admins (masked values preserved)
// - POST /mcp-servers/reload (or POST /mcp-servers/:name/reload): reconnect and refresh tools for owners and admins
import { type Answer, type Request, error, json } from "../request.ts";
import type { Route } from "../admin.ts";
import { managesStation } from "../../mesh/credential.ts";
import type { ConfigFile } from "../../ops/config.ts";
import { log } from "../../ops/log.ts";
import type { ManagedMcp } from "../../tools/managed-mcp.ts";
import { managedMcpConfig, mergeManagedMcpPatch } from "../../tools/managed-mcp-config.ts";

export type McpServersDeps = {
  config: ConfigFile;
  managedMcp: ManagedMcp;
  changed?: () => void;
};

const isObject = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);

export const routes = ({ config, managedMcp, changed }: McpServersDeps): Route[] => [
  {
    method: "GET",
    pattern: /^\/mcp-servers$/,
    handle: async (): Promise<Answer> => json(200, JSON.stringify({ servers: managedMcp.view() })),
  },
  {
    method: "PUT",
    pattern: /^\/mcp-servers$/,
    handle: async (r: Request): Promise<Answer> => {
      if (!managesStation(r.viewer)) return error(403, "Only workspace owners and admins can manage MCP servers.");
      let body: Record<string, unknown>;
      try {
        const parsed = JSON.parse(r.body.toString("utf8") || "{}");
        body = isObject(parsed) ? parsed : {};
      } catch {
        return error(400, "invalid JSON");
      }
      const patch = isObject(body.servers) ? body.servers : null;
      if (patch === null) return error(400, "servers: a map of server names to configurations, or null to remove");
      const before = managedMcpConfig(config.raw());
      let next;
      try {
        next = mergeManagedMcpPatch(before, patch);
      } catch (e) {
        return error(400, (e as Error).message);
      }
      try {
        await config.updateSoon((raw) => {
          if (Object.keys(next).length > 0) raw.mcpServers = next;
          else delete raw.mcpServers;
        });
      } catch (e) {
        return error(400, (e as Error).message);
      }
      log.info("mcp", "managed MCP servers updated", { names: Object.keys(next), by: r.viewer.email });
      // `config.listen` reconciles `managedMcp` asynchronously; return immediately with `connecting` status instead of
      // blocking the HTTP request on upstream handshakes (live updates push via `overviewChanged`).
      changed?.();
      return json(200, JSON.stringify({ servers: managedMcp.view() }));
    },
  },
  {
    method: "POST",
    pattern: /^\/mcp-servers\/reload$/,
    handle: async (r: Request): Promise<Answer> => {
      if (!managesStation(r.viewer)) return error(403, "Only workspace owners and admins can reload MCP servers.");
      void managedMcp.reload();
      changed?.();
      return json(200, JSON.stringify({ servers: managedMcp.view() }));
    },
  },
  {
    method: "POST",
    pattern: /^\/mcp-servers\/([^/]+)\/reload$/,
    handle: async (r: Request, [rawName]: string[]): Promise<Answer> => {
      if (!managesStation(r.viewer)) return error(403, "Only workspace owners and admins can reload MCP servers.");
      let name: string;
      try {
        name = decodeURIComponent(rawName ?? "");
      } catch {
        return error(400, "invalid server name");
      }
      const cfg = managedMcpConfig(config.raw());
      if (!(name in cfg)) return error(404, `unknown MCP server ${name}`);
      void managedMcp.reload(name);
      changed?.();
      return json(200, JSON.stringify({ servers: managedMcp.view() }));
    },
  },
];
