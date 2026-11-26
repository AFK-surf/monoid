// A workspace's devices (设备, 2026-11-10): what agents use that runs no station, one list, each its person's
// (station/src/devices/). The `devices` topic and the `device.*` calls. Where one is decides who keeps it and who may
// use it:
//
// - attached to a whole station: that station keeps it (`GET /devices`, the `devices` event), and every chat may use it;
// - attached to a station that only runs tasks: the rig keeps it, as its person signed (rigs.ts `device`), and says it
//   as it says itself (the `rigs` topic's data); a chat uses it by its person's grant (`rig.decide`, a card), or 免批准
//   on it (`device.setOpen`);
// - a person's phone lent by its app: each station says the phones lent to it (`phones` beside its devices).
import { Effect } from "effect";
import { CoreError } from "./error.ts";
import type { Host } from "./host.ts";
import { t } from "./i18n.ts";
import type { PersonalLock } from "./personal-lock.ts";
import { AIRPLAY_PROTOCOLS, type AirPlayProtocol, type Device, type DeviceKind, DEVICE_KINDS, deviceRefusal } from "./rig-form.ts";
import type { Rigs } from "./rigs.ts";
import { StationAddr } from "./station/addr.ts";
import type { Store } from "./store.ts";
import { get } from "./util.ts";

// deno-lint-ignore no-explicit-any
type J = any;

export type DeviceCall =
  /// A device attached to `station` (a whole one's, or a rig of this person's), named `name`, reached at `target`.
  | {
      kind: "add";
      workspace: string;
      station: string;
      name: string;
      deviceKind: DeviceKind;
      target: string;
      baud?: number;
      model?: string;
      protocols?: AirPlayProtocol[];
      paired?: boolean;
      pairId?: string;
    }
  /// One taken off its station.
  | { kind: "remove"; workspace: string; station: string; device: string }
  /// 免批准 on one of a rig's devices.
  | { kind: "setOpen"; workspace: string; station: string; device: string; open: boolean }
  /// Scan a station's LAN for AirPlay receivers.
  | { kind: "scan"; workspace: string; station: string; deviceKind: "airplay"; timeoutMs?: number; host?: string }
  /// Install the on-demand pyatv environment on a station.
  | { kind: "installAirplay"; workspace: string; station: string }
  /// Start multi-protocol AirPlay PIN pairing on a station.
  | {
      kind: "pairStart";
      workspace: string;
      station: string;
      identifier: string;
      address?: string;
      name?: string;
      model?: string;
      protocols: AirPlayProtocol[];
    }
  /// Submit PIN or skip the current protocol step of an AirPlay pairing session.
  | { kind: "pairFinish"; workspace: string; station: string; pairId: string; pin?: string; skip?: boolean }
  /// Cancel an active AirPlay pairing session.
  | { kind: "pairCancel"; workspace: string; station: string; pairId: string }
  /// Re-pair an existing AirPlay device with a completed pairing session.
  | { kind: "rebindPair"; workspace: string; station: string; device: string; pairId: string };

function parseProtocols(raw: unknown): AirPlayProtocol[] | undefined {
  if (!Array.isArray(raw)) return undefined;
  const out: AirPlayProtocol[] = [];
  for (const item of raw) {
    if (typeof item === "string" && AIRPLAY_PROTOCOLS.includes(item as AirPlayProtocol) && !out.includes(item as AirPlayProtocol)) {
      out.push(item as AirPlayProtocol);
    }
  }
  return out;
}

export function parseDevice(name: string, params: unknown): DeviceCall | null {
  const text = (field: string) => {
    const v = get(params, field);
    return typeof v === "string" ? v.trim() : "";
  };
  const need = (field: string) => {
    const v = text(field);
    if (v === "") throw CoreError.invalid(t("core-misc.params.missing", { field }));
    return v;
  };
  switch (name) {
    case "device.add": {
      const kind = text("kind");
      if (!DEVICE_KINDS.includes(kind as DeviceKind)) throw CoreError.invalid(t("core-misc.params.missing", { field: "kind" }));
      const baud = get(params, "baud");
      const model = text("model");
      const protocols = parseProtocols(get(params, "protocols"));
      const paired = get(params, "paired");
      const pairId = text("pairId");
      return {
        kind: "add", workspace: need("workspace"), station: need("station"), name: need("name"), deviceKind: kind as DeviceKind, target: need("target"),
        ...(typeof baud === "number" ? { baud } : typeof baud === "string" && baud.trim() !== "" ? { baud: Number(baud) } : {}),
        ...(model !== "" ? { model } : {}),
        ...(protocols !== undefined ? { protocols } : {}),
        ...(typeof paired === "boolean" ? { paired } : {}),
        ...(pairId !== "" ? { pairId } : {}),
      };
    }
    case "device.remove":
      return { kind: "remove", workspace: need("workspace"), station: need("station"), device: need("device") };
    case "device.setOpen": {
      const open = get(params, "open");
      if (typeof open !== "boolean") throw CoreError.invalid(t("core-misc.params.missing", { field: "open" }));
      return { kind: "setOpen", workspace: need("workspace"), station: need("station"), device: need("device"), open };
    }
    case "device.scan": {
      const rawKind = text("kind") || "airplay";
      if (rawKind !== "airplay") throw CoreError.invalid(t("core-misc.params.missing", { field: "kind" }));
      const timeoutMs = get(params, "timeoutMs");
      const host = text("host");
      return {
        kind: "scan",
        workspace: need("workspace"),
        station: need("station"),
        deviceKind: "airplay",
        ...(typeof timeoutMs === "number" ? { timeoutMs } : {}),
        ...(host !== "" ? { host } : {}),
      };
    }
    case "device.installAirplay":
      return { kind: "installAirplay", workspace: need("workspace"), station: need("station") };
    case "device.pairStart": {
      const address = text("address");
      const deviceName = text("name");
      const model = text("model");
      const protocols = parseProtocols(get(params, "protocols")) ?? [];
      return {
        kind: "pairStart",
        workspace: need("workspace"),
        station: need("station"),
        identifier: need("identifier"),
        ...(address !== "" ? { address } : {}),
        ...(deviceName !== "" ? { name: deviceName } : {}),
        ...(model !== "" ? { model } : {}),
        protocols,
      };
    }
    case "device.pairFinish": {
      const pin = text("pin");
      const skip = get(params, "skip");
      return {
        kind: "pairFinish",
        workspace: need("workspace"),
        station: need("station"),
        pairId: need("pairId"),
        ...(pin !== "" ? { pin } : {}),
        ...(typeof skip === "boolean" ? { skip } : {}),
      };
    }
    case "device.pairCancel":
      return { kind: "pairCancel", workspace: need("workspace"), station: need("station"), pairId: need("pairId") };
    case "device.rebindPair":
      return { kind: "rebindPair", workspace: need("workspace"), station: need("station"), device: need("device"), pairId: need("pairId") };
    default:
      return null;
  }
}

export type DevicesEnv = {
  host: Host;
  store: Store;
  rigs: () => Rigs;
  personal: () => PersonalLock;
  subOf: (workspace: string) => string | null;
  /// The email a workspace is signed in as here (whose phone is the viewer's own).
  emailOf: (workspace: string) => string | null;
  view: (workspace: string) => J;
  call: (station: StationAddr, method: string, path: string, body: unknown) => Effect.Effect<unknown, CoreError>;
};

const arr = (v: unknown): J[] => (Array.isArray(v) ? v : []);
const str = (v: unknown): string => (typeof v === "string" ? v : "");
const hex = (bytes: Uint8Array) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

export class Devices {
  readonly #env: DevicesEnv;
  /// What each whole station last said of the devices attached to it and the phones lent to it, by its address.
  readonly #said = new Map<string, { workspace: string; devices: J[]; phones: J[] }>();

  constructor(env: DevicesEnv) {
    this.#env = env;
  }

  /// A station's devices read whole, as it is reached (one from before devices has no such route: it says nothing).
  read(station: string): Effect.Effect<void, CoreError> {
    return Effect.suspend(() => {
      const at = StationAddr.parse(station);
      return Effect.map(Effect.orElseSucceed(this.#env.call(at, "GET", "/devices", null), () => null), (r) => {
        if (r !== null) this.#take(station, at.workspace, r);
      });
    });
  }

  /// A station's event: `devices`, those attached to it and the phones lent to it as they are now.
  heard(station: string, name: string, data: unknown): void {
    if (name !== "devices") return;
    let workspace: string;
    try {
      workspace = StationAddr.parse(station).workspace;
    } catch {
      return;
    }
    this.#take(station, workspace, data);
  }

  #take(station: string, workspace: string, data: unknown): void {
    if (str(get(data, "workspace")) !== workspace) return;
    this.#said.set(station, { workspace, devices: arr(get(data, "devices")), phones: arr(get(data, "phones")) });
    this.#env.store.invalidate({ topic: "devices", workspace });
  }

  /// The `devices` topic of a workspace (shapes `DevicesView`).
  value(workspace: string): J {
    const env = this.#env;
    const sub = env.subOf(workspace);
    const stations = new Map<string, string>(arr(get(env.view(workspace), "stations")).map((s) => [str(s?.id), str(s?.name)]));
    const said = [...this.#said].filter(([station, s]) => s.workspace === workspace && stations.has(StationAddr.parse(station).station));
    const whole = said.flatMap(([station, s]) => {
      const id = StationAddr.parse(station).station;
      return s.devices.map((d) => ({
        id: str(d?.id), name: str(d?.name), kind: str(d?.kind), target: str(d?.target),
        ...(typeof d?.baud === "number" ? { baud: d.baud } : {}),
        ...(typeof d?.model === "string" && d.model !== "" ? { model: d.model } : {}),
        ...(Array.isArray(d?.protocols) ? { protocols: d.protocols.filter((p: unknown) => typeof p === "string") } : {}),
        ...(typeof d?.paired === "boolean" ? { paired: d.paired } : {}),
        via: "station", station: id, stationName: stations.get(id) ?? str(d?.stationName), owner: str(d?.owner), ownerEmail: str(d?.owner_email), ownerName: str(d?.owner_name),
        mine: sub !== null && d?.owner === sub, online: true, open: true, ownOpen: false, settings: 0, grants: [], requests: [],
      }));
    });
    // A phone lent to several stations is one phone: said once, with every station's chats that hold it.
    const phones = new Map<string, J>();
    for (const [station, s] of said) {
      const at = StationAddr.parse(station).station;
      for (const p of s.phones) {
        const id = str(p?.id);
        const was = phones.get(id);
        const grants = arr(p?.grants).map((g) => ({ ...g, station: at, stationName: stations.get(at) ?? "", whole: false }));
        if (was !== undefined) {
          was.grants = [...was.grants, ...grants];
          was.online = was.online || p?.online === true;
          continue;
        }
        phones.set(id, {
          id, name: str(p?.name), kind: "adb", target: str(p?.target), via: "phone", station: at, stationName: stations.get(at) ?? "",
          owner: str(p?.ownerEmail), ownerEmail: str(p?.ownerEmail), ownerName: str(p?.ownerName), mine: false, online: p?.online === true,
          open: p?.open === true, ownOpen: p?.open === true, settings: 0, grants, requests: [],
        });
      }
    }
    const email = (env.emailOf(workspace) ?? "").toLowerCase();
    for (const p of phones.values()) p.mine = email !== "" && p.ownerEmail === email;
    return { app: env.host.appKeys === true, devices: [...whole, ...env.rigs().devices(workspace), ...phones.values()] };
  }

  run(call: DeviceCall): Effect.Effect<unknown, CoreError> {
    switch (call.kind) {
      case "add":
        return this.#add(call);
      case "remove":
        return this.#remove(call);
      case "setOpen":
        return this.#env.rigs().setDeviceOpen(call.workspace, call.station, call.device, call.open);
      case "scan":
        return this.#env.call(new StationAddr(call.workspace, call.station), "POST", "/devices/scan", {
          kind: call.deviceKind,
          ...(call.timeoutMs !== undefined ? { timeoutMs: call.timeoutMs } : {}),
          ...(call.host !== undefined ? { host: call.host } : {}),
        });
      case "installAirplay":
        return this.#env.call(new StationAddr(call.workspace, call.station), "POST", "/devices/airplay/install", {});
      case "pairStart":
        return this.#env.call(new StationAddr(call.workspace, call.station), "POST", "/devices/pair/start", {
          identifier: call.identifier,
          ...(call.address !== undefined ? { address: call.address } : {}),
          ...(call.name !== undefined ? { name: call.name } : {}),
          ...(call.model !== undefined ? { model: call.model } : {}),
          protocols: call.protocols,
        });
      case "pairFinish":
        return this.#env.call(new StationAddr(call.workspace, call.station), "POST", "/devices/pair/finish", {
          pairId: call.pairId,
          ...(call.pin !== undefined ? { pin: call.pin } : {}),
          ...(call.skip !== undefined ? { skip: call.skip } : {}),
        });
      case "pairCancel":
        return this.#env.call(new StationAddr(call.workspace, call.station), "POST", "/devices/pair/cancel", {
          pairId: call.pairId,
        });
      case "rebindPair":
        return this.#env.call(
          new StationAddr(call.workspace, call.station),
          "POST",
          `/devices/${encodeURIComponent(call.device)}/pair`,
          { pairId: call.pairId },
        );
    }
  }

  #isRig(workspace: string, station: string): boolean {
    return arr(get(this.#env.view(workspace), "rigs")).some((r) => r?.id === station);
  }

  #add(call: Extract<DeviceCall, { kind: "add" }>): Effect.Effect<unknown, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const env = this.#env;
      const id = new Uint8Array(8);
      env.host.randomBytes(id);
      const device: Device = {
        id: hex(id),
        name: call.name,
        kind: call.deviceKind,
        target: call.target,
        ...(call.baud !== undefined ? { baud: call.baud } : {}),
        ...(call.model !== undefined ? { model: call.model } : {}),
        ...(call.protocols !== undefined ? { protocols: call.protocols } : {}),
        ...(call.paired !== undefined ? { paired: call.paired } : {}),
      };
      const why = deviceRefusal(device);
      if (why !== null) return yield* Effect.fail(CoreError.invalid(why));
      if (this.#isRig(call.workspace, call.station)) return yield* env.rigs().device(call.workspace, call.station, device, false);
      const { id: _, ...given } = device;
      const payload = call.pairId !== undefined ? { ...given, pairId: call.pairId } : given;
      return yield* env.call(new StationAddr(call.workspace, call.station), "POST", "/devices", payload);
    });
  }

  #remove(call: Extract<DeviceCall, { kind: "remove" }>): Effect.Effect<unknown, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const env = this.#env;
      if (this.#isRig(call.workspace, call.station)) {
        const d = env.rigs().devices(call.workspace).find((x) => x.station === call.station && x.id === call.device);
        if (d === undefined) return yield* Effect.fail(new CoreError("device_unknown", t("core-misc.device.unknown")));
        const device: Device = { id: d.id, name: d.name, kind: d.kind, target: d.target, ...(d.baud !== undefined ? { baud: d.baud } : {}) };
        return yield* env.rigs().device(call.workspace, call.station, device, true);
      }
      return yield* env.call(new StationAddr(call.workspace, call.station), "DELETE", `/devices/${encodeURIComponent(call.device)}`, null);
    });
  }
}
