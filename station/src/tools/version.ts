// station_version: this station's release as its agents see it (updates/updates.ts): what runs and what is out, updated
// to the latest, or put back to an earlier release its channel's feed names (`earlier`) when the latest broke something,
// as its page's 更新 and 退回旧版本 do. Said in English, as the station's own refusals to agents are.
import type { SoftwareVersion, Updates } from "../updates/updates.ts";
import type { Tool } from "./mcp.ts";

export const VERSION_TOOL = {
  name: "station_version",
  description: "This station's release: list (version, latest, earlier releases), update to the latest, or back to an earlier one when the latest broke something (auto-update pauses until a newer one).",
  inputSchema: {
    type: "object",
    properties: {
      action: { enum: ["list", "update", "back"] },
      to: { type: "string", description: "back: a version from list's earlier." },
    },
    required: ["action"],
    additionalProperties: false,
  },
};

/// What the tool says of the station's line (`get`'s): the fields an agent goes by.
const said = (v: SoftwareVersion | undefined) =>
  v === undefined
    ? {}
    : {
        version: v.version ?? null,
        latest: v.latest ?? null,
        newer: v.newer,
        channel: v.channel ?? null,
        auto: v.auto ?? null,
        autoAfter: v.autoAfter ?? null,
        earlier: v.earlier ?? [],
        state: v.state,
        ...(v.progress ? { progress: v.progress } : {}),
        ...(v.message ? { message: v.message } : {}),
        ...(v.note ? { note: v.note } : {}),
      };

export function versionTools(updates: Updates): Tool[] {
  const line = () => said(updates.get("en").find((v) => v.id === "station"));
  return [{
    ...VERSION_TOOL,
    run: async (_session, args) => {
      if (args.action === "list") return JSON.stringify(line());
      if (args.action === "update") {
        await updates.update("station", "en");
        return JSON.stringify({ started: true, ...line() });
      }
      if (args.action === "back") {
        if (typeof args.to !== "string" || args.to === "") throw new Error("to: a version list names in earlier");
        await updates.update("station", "en", args.to);
        return JSON.stringify({ started: true, ...line() });
      }
      throw new Error("action: list, update or back");
    },
  }];
}
