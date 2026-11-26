// device_list and device_use: how a chat's agent finds the workspace's devices (devices/module.ts) and asks for one.
import type { DeviceEntry } from "../services.ts";
import type { Tool } from "../tools/mcp.ts";

export const DEVICE_LIST = {
  name: "device_list",
  description:
    "List workspace devices (adb, tcp, serial, airplay) attached to stations or lent Android phones, with owner, access, and thisChat status. Whole-station devices are open to every chat; rig devices and phones need owner approval via device_use.",
  inputSchema: { type: "object", properties: {}, additionalProperties: false },
};

export const DEVICE_USE = {
  name: "device_use",
  description:
    "Open or request a device from device_list. Open devices bind a 127.0.0.1 port here at once; rig devices and phones post an approval card to their owner (call again once granted). Skill stillfail-jobs (Devices).",
  inputSchema: {
    type: "object",
    properties: {
      device: { type: "string", description: "Device name or id from device_list; person's email for their phone (omit for starter's phone)." },
      reason: { type: "string", description: "Why you need it (shown on approval card)." },
      timeout: {
        type: "object",
        description: "Grant duration: idle or fixed, whole minutes 1m-30d (default: idle, 1h).",
        properties: { kind: { type: "string", enum: ["idle", "fixed"] }, seconds: { type: "integer" } },
        required: ["kind", "seconds"],
        additionalProperties: false,
      },
      done: { type: "boolean", description: "Hand back the device (or all held devices if omitted) and close its local port." },
    },
    additionalProperties: false,
  },
};

export const DEVICE_CONTROL = {
  name: "device_control",
  description:
    "Control an AirPlay device (Apple TV, HomePod, speaker). Auto-opens tunnel for whole-station devices; rig devices need device_use approval first. Skill stillfail-jobs (Devices).",
  inputSchema: {
    type: "object",
    properties: {
      device: { type: "string", description: "Device name or id from device_list." },
      action: { type: "string", description: "status|power|remote|apps|launch|playing|seek|volume|keyboard|play_url|stream_audio." },
      args: { type: "object", description: "Action arguments object.", additionalProperties: true },
      audio_path: { type: "string", description: "Local audio file path for stream_audio." },
    },
    required: ["device", "action"],
    additionalProperties: false,
  },
};

export type DeviceTools = {
  list(session: string): Promise<DeviceEntry[]>;
  use(session: string, device: string, reason: string, timeout: unknown, signal?: AbortSignal): Promise<string>;
  done(session: string, device: string): Promise<string>;
  control(
    session: string,
    device: string,
    action: string,
    args: Record<string, unknown> | undefined,
    audioPath: string | undefined,
    signal?: AbortSignal,
  ): Promise<string>;
};

export function deviceTools(d: DeviceTools): Tool[] {
  return [
    {
      ...DEVICE_LIST,
      run: async (session) => {
        const all = await d.list(session);
        if (all.length === 0) return "No device is attached to this workspace's stations, and no phone is lent to this station. A member adds one on a station's page in the still.fail app (添加设备); a person lends their Android phone by turning on 共享调试 in the app on it.";
        return JSON.stringify(all, null, 2);
      },
    },
    {
      ...DEVICE_USE,
      run: async (session, args, signal) => {
        const device = typeof args.device === "string" ? args.device.trim() : "";
        if (args.done === true) return d.done(session, device);
        return d.use(session, device, typeof args.reason === "string" ? args.reason : "", args.timeout, signal);
      },
    },
    {
      ...DEVICE_CONTROL,
      run: async (session, args, signal) => {
        const device = typeof args.device === "string" ? args.device.trim() : "";
        const action = typeof args.action === "string" ? args.action.trim() : "";
        const actionArgs = args.args !== null && typeof args.args === "object" && !Array.isArray(args.args)
          ? (args.args as Record<string, unknown>)
          : undefined;
        const audioPath = typeof args.audio_path === "string" && args.audio_path.trim() !== "" ? args.audio_path.trim() : undefined;
        return d.control(session, device, action, actionArgs, audioPath, signal);
      },
    },
  ];
}

/// Where a device is reached here once forwarded (`port` on 127.0.0.1), in words for its kind.
export function reachedAt(e: { name: string; kind: string; target: string; baud?: number }, port: number): string {
  switch (e.kind) {
    case "adb":
      return `${e.name} is reached here through the adb server of the machine it is on: \`adb -P ${port} -s ${e.target} …\` (-P on every adb command; never adb kill-server on it). Only this chat's processes connect.`;
    case "serial":
      return `${e.name} (serial ${e.target}, ${e.baud ?? 115200} baud, set raw there) is at 127.0.0.1:${port}: its bytes both ways, e.g. \`socat - TCP:127.0.0.1:${port}\` or a socket in a script. Only this chat's processes connect.`;
    case "airplay":
      return `${e.name} (AirPlay ${e.target}) is at http://127.0.0.1:${port}: use \`device_control\` for standard actions, or POST JSON \`{"action":"…","args":{…}}\` to http://127.0.0.1:${port}/action (GET /status, POST /stream-audio). Only this chat's processes connect.`;
    default:
      return `${e.name} (${e.target}) is at 127.0.0.1:${port}: connect to it there as you would to ${e.target} (http://127.0.0.1:${port}/, ssh -p ${port} …). Only this chat's processes connect.`;
  }
}
