// station_version: this station's release as its agents see it (updates/updates.ts): what runs and what is out, updated
// to the latest, or put back to an earlier release its channel's feed names (`earlier`) when the latest broke something,
// as its page's 更新 and 退回旧版本 do. Said in English, as the station's own refusals to agents are.
import type { SoftwareVersion, Updates } from "../updates/updates.ts";
import { parseWaitSpec } from "../updates/override.ts";
import type { Tool } from "./mcp.ts";

export const VERSION_TOOL = {
  name: "station_version",
  description: "This station's release: list (version, latest, earlier, override/wait), update to latest, back to an earlier one, or wait until a PR/fix/commit/version ships.",
  inputSchema: {
    type: "object",
    properties: {
      action: { type: "string", enum: ["list", "update", "back", "wait"] },
      to: { type: "string", description: "back: a version from list's earlier." },
      until: { type: "array", items: { type: "string" }, description: "wait: conditions (pr:N, fix:FB-N, commit:SHA, version:0.1.N, after:0.1.N)." },
      clear: { type: "boolean", description: "wait: clear wait conditions." },
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
        ...(v.overridden ? { overridden: v.overridden } : {}),
        ...(v.overrideBase ? { overrideBase: v.overrideBase } : {}),
        ...(v.overrideKind ? { overrideKind: v.overrideKind } : {}),
        ...(v.overrideNote ? { overrideNote: v.overrideNote } : {}),
        ...(v.autoWhen ? { autoWhen: v.autoWhen } : {}),
        ...(v.autoHeld ? { autoHeld: v.autoHeld } : {}),
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
      if (args.action === "wait") {
        if (args.clear === true) {
          await updates.setWait(null, "en");
          return JSON.stringify(line());
        }
        if (Array.isArray(args.until) && args.until.every((x: unknown) => typeof x === "string")) {
          const parsed = args.until.map((s: string) => parseWaitSpec(s));
          await updates.setWait(parsed, "en");
          return JSON.stringify(line());
        }
        throw new Error("wait: pass until (array of conditions) or clear: true");
      }
      throw new Error("action: list, update, back or wait");
    },
  }];
}
