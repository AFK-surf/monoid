// Compact MCP tool for workspace project & tag management (details live in built-in skill `stillfail-projects`).
// Intentionally has no `create` action: creating a new project must always go through `propose`.
import type { Hub } from "../sessions/hub.ts";
import { projectManage } from "../sessions/projects.ts";
import type { Tool } from "./mcp.ts";

export const PROJECT_MANAGE = {
  name: "project_manage",
  description: "Manage workspace projects and tags (propose new project, list, set_info, rename, merge, reclassify). Read skill stillfail-projects first.",
  inputSchema: {
    type: "object",
    properties: {
      action: { type: "string", enum: ["list", "propose", "set_info", "rename", "merge", "reclassify"] },
      args: { type: "object" },
    },
    required: ["action"],
    additionalProperties: false,
  },
};

export function projectTools(hub: Hub): Tool[] {
  return [{ ...PROJECT_MANAGE, run: (session, args) => projectManage(hub, session, args) }];
}
