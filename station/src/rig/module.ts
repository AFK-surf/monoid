// A rig on the station transport (a station that only runs tasks, 2026-11-10): what it answers the workspace's stations, and what it tells
// them. Supports both rig-only machines (RigLive) and mixed-mode machines (StationLive, where the station is full in
// some workspaces and tasks-only in others). Every request in a rig workspace passes its allowlist and grants first
// (`guard`); requests in full workspaces bypass the rig guard untouched.
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import type { Duplex } from "node:stream";
import { joinWorkspace } from "../cli.ts";
import { reachDevice } from "../devices/connect.ts";
import { DeviceRefused } from "../mesh/peer-http.ts";
import type { Json } from "../store/store.ts";
import { type Cloud, joinedPendingPath, pendingLockPath } from "../cloud/state.ts";
import { pendingLock } from "../cloud/presence.ts";
import { writePrivateSoon } from "../ops/files.ts";
import { Refused, type PeerBus } from "../mesh/bus.ts";
import { Fibers } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { CommandLog } from "./log.ts";
import { type Ended, Refusal, RigGrants, type RigWs, type Self } from "./grants.ts";

/// Methods allowed in a rig workspace (explicit allowlist so mixed-mode stations never expose full-station RPCs to rig workspaces).
const RIG_ALLOWED_EXACT: ReadonlySet<string> = new Set([
  "describe", "session.close", "session.size", "vault.run", "vault.capture", "vault.capabilities", "vault.revoke",
]);
function isRigAllowed(method: string): boolean {
  return RIG_ALLOWED_EXACT.has(method)
    || method.startsWith("rig.")
    || method.startsWith("task.")
    || method.startsWith("file.")
    || method.startsWith("sync.");
}

/// What a station asks of a rig without a grant: how it is and who may use it, what its person signed, and what reads
/// back, stops or clears what a chat of that station ran here (keyed by that station and session: jobs/remote.ts).
const UNGATED: ReadonlySet<string> = new Set([
  "describe", "task.get", "task.gets", "task.log", "task.list", "task.stop", "task.files", "task.collected", "task.mirrors", "task.clean",
  "file.get", "sync.changes", "session.close", "session.size", "vault.capabilities", "vault.revoke",
]);

/// A station not told is told again after this, then twice as long each time, a minute apart at most, for an hour.
const AGAIN_MS = 1000;
const AGAIN_MAX_MS = 60_000;
const AGAIN_FOR_MS = 3_600_000;
/// The most lines of the command log a station is given at once.
const LOG_MAX = 200;

export type RigDeps = {
  data: string;
  cloud: Cloud;
  bus: PeerBus;
  /// Whether a chat (a station's session) has something running here, stopping it, and all that have.
  busy: (workspace: string, station: string, session: string) => boolean;
  stop: (workspace: string, station: string, session: string) => void | Promise<void>;
  running: () => { workspace: string; station: string; session: string }[];
  join?: (token: string, person: string, lock?: string, expectedWorkspace?: string) => Promise<{ workspace: string; workspace_name: string; name: string }>;
  fibers?: Fibers;
};

export class Rig {
  readonly grants: RigGrants;
  readonly commands: CommandLog;
  readonly #d: RigDeps;
  readonly #fibers: Fibers;
  /// The stations not told the last change yet, keyed by `${ws}\0${station}`.
  readonly #untold = new Map<string, { wait: number; until: number; stop: () => void }>();
  #unlisten: (() => void) | null = null;
  #known = new Set<string>();
  /// The chats' connections to this rig's devices open now.
  readonly #wired = new Set<{ workspace: string; device: string; station: string; session: string; socket: Duplex }>();

  constructor(deps: RigDeps) {
    this.#d = deps;
    this.#fibers = deps.fibers ?? new Fibers("rig");
    const { cloud, bus } = deps;
    this.commands = new CommandLog(join(deps.data, "rig", "commands.log"));
    this.grants = new RigGrants({
      path: join(deps.data, "rig", "grants.json"),
      selfFor: (workspace) => this.selfFor(workspace),
      workspaces: () => this.workspaces(),
      busy: (workspace, station, session) => deps.busy(workspace, station, session),
      stop: (workspace, station, session) => deps.stop(workspace, station, session),
      running: () => deps.running(),
      ended: (ended) => this.#tell(ended.workspace, ended.station, { ended }),
      changed: (workspace) => this.#tellAll(workspace),
      cut: (workspace, device, station, session) => this.#cut(workspace, device, station, session),
      fibers: this.#fibers,
    });
    bus.guarded((workspace, peer, request) => this.#guard(workspace, peer, request));
    bus.on("rig.", async (peer, request, workspace) => this.#heard(peer, request, workspace ?? ""));
    bus.whenAttached(() => {
      this.#tellAll(null, true);
      let prevRigWs = new Set(cloud.rigMemberships().map((m) => m.workspace));
      const waitedByWs = new Map<string, boolean>();
      for (const ws of prevRigWs) waitedByWs.set(ws, cloud.waiting(ws === cloud.home() ? null : ws));
      this.#unlisten = cloud.listen(() => {
        const nowRigWs = new Set(cloud.rigMemberships().map((m) => m.workspace));
        for (const ws of prevRigWs) {
          if (!nowRigWs.has(ws)) {
            this.grants.clearWorkspace(ws);
            for (const w of [...this.#wired]) {
              if (w.workspace !== ws) continue;
              this.#wired.delete(w);
              w.socket.destroy();
            }
            waitedByWs.delete(ws);
          }
        }
        for (const ws of nowRigWs) {
          const was = waitedByWs.get(ws) ?? false;
          const nowWaited = cloud.waiting(ws === cloud.home() ? null : ws);
          waitedByWs.set(ws, nowWaited);
          this.#tellAll(ws, true, !(was && !nowWaited));
        }
        // Clean up any #untold / #known entries for workspaces no longer rig.
        this.#pruneUntold();
        prevRigWs = nowRigWs;
      });
    });
  }

  /// What this machine is in `workspace`, if it is a rig there.
  selfFor(workspace: string): RigWs | null {
    const s = this.#d.cloud.state;
    const rig = this.#d.cloud.rigIn(workspace);
    if (s === null || rig === null || !workspace || this.#d.cloud.removed()) return null;
    return { id: s.station, workspace, owner: rig.owner, person: rig.person };
  }

  /// All rig workspaces this machine currently participates in.
  workspaces(): RigWs[] {
    const s = this.#d.cloud.state;
    if (s === null || this.#d.cloud.removed()) return [];
    return this.#d.cloud.rigMemberships().map((m) => ({ id: s.station, workspace: m.workspace, owner: m.rig.owner, person: m.rig.person }));
  }

  /// The first rig workspace (for legacy single-workspace callers).
  self(): Self | null {
    return this.workspaces()[0] ?? null;
  }

  /// What `describe` says besides a station's own in `workspace`: rig metadata when this station is a rig in `workspace`,
  /// or `{}` when it is a whole station in `workspace`.
  described(workspace?: string): Json {
    const ws = workspace || this.#d.cloud.home() || "";
    const rig = this.#d.cloud.rigIn(ws);
    if (rig === null) return {};
    const view = this.grants.view(ws);
    return {
      sessions: false, messages: false, reads: false, chats: false,
      rig: view === null ? null : { ...view, owner_email: rig.owner_email, owner_name: rig.owner_name, ...(this.grants.proof(ws) !== null ? { proof: true } : {}) },
    };
  }

  /// A connection to device `id` here for a chat (`session` of station `peer` in `workspace`).
  async device(peer: string, workspace: string, session: string, id: string, probe: boolean): Promise<Duplex | null> {
    const why = this.grants.deviceRefusal(workspace, peer, session, id, !probe);
    if (why !== null) throw new DeviceRefused(/no such device/.test(why) ? 404 : 403, why);
    if (probe) return null;
    const d = this.grants.devices(workspace).find((x) => x.id === id);
    if (d === undefined) throw new DeviceRefused(404, "no such device on this rig");
    const socket = await reachDevice(d);
    const wire = { workspace, device: id, station: peer, session, socket };
    this.#wired.add(wire);
    socket.once("close", () => this.#wired.delete(wire));
    this.commands.add({ at: this.#fibers.now(), workspace, station: peer, session, key: id, name: d.name, command: `${d.kind} ${d.target}`, kind: "device" });
    return socket;
  }

  #cut(workspace: string, device: string, station: string | null, session: string | null): void {
    for (const w of [...this.#wired]) {
      if (w.workspace !== workspace || w.device !== device || (station !== null && w.station !== station) || (session !== null && w.session !== session)) continue;
      if (this.selfFor(workspace) !== null && this.grants.deviceRefusal(workspace, w.station, w.session, device, false) === null) continue;
      this.#wired.delete(w);
      w.socket.destroy();
    }
  }

  /// Why a station in `workspace` may not reach this rig's services now (mesh/peer-http.ts), or null.
  stationRefusal(peer: string, workspace: string): string | null {
    return this.grants.stationRefusal(workspace, peer);
  }

  #guard(workspace: string, peer: string, request: Json): void {
    // Full workspace: not guarded by rig.
    if (this.#d.cloud.rigIn(workspace) === null) return;
    const method = typeof request?.method === "string" ? request.method : "";
    if (!isRigAllowed(method)) throw new Refused(`a rig does not answer ${method}`);
    if (UNGATED.has(method) || method.startsWith("rig.")) return;
    const session = typeof request?.session === "string" ? request.session : "";
    if (session === "") throw new Refused("a rig runs only what a chat asks of it (no session named)");
    const why = this.grants.refusal(workspace, peer, session);
    if (why !== null) throw new Refused(why);
    if (method === "task.prepare" && typeof request?.spec?.command === "string") {
      this.commands.add({ at: this.#fibers.now(), workspace, station: peer, session, key: String(request.key ?? ""), name: String(request.spec.name ?? ""), command: request.spec.command, kind: "task" });
    } else if ((method === "vault.run" || method === "vault.capture") && typeof request?.command === "string") {
      this.commands.add({ at: this.#fibers.now(), workspace, station: peer, session, key: String(request.id ?? ""), name: "", command: request.command, kind: "secret" });
    }
  }

  async #added(ws: string, lock: string | null): Promise<Json> {
    const cloud = this.#d.cloud;
    if (lock !== null) {
      const isHome = ws === cloud.home();
      if (isHome) {
        if (cloud.chain(null) === null && pendingLock(this.#d.data) === null) {
          await writePrivateSoon(pendingLockPath(this.#d.data), JSON.stringify({ hash: lock }));
          cloud.lockNamed();
        }
      } else {
        if (cloud.chain(ws) === null && cloud.pendingLock(ws) === null) {
          const path = joinedPendingPath(this.#d.data, ws);
          mkdirSync(dirname(path), { recursive: true }); // sync: once when a joined rig workspace names its first pending lock
          await writePrivateSoon(path, JSON.stringify({ hash: lock }));
          cloud.lockNamed();
        }
      }
    }
    return { ok: true };
  }

  #heard(peer: string, request: Json, workspace: string): Json {
    const method = typeof request?.method === "string" ? request.method : "";
    const self = this.selfFor(workspace);
    if (self === null) throw new Refused("this rig is of another workspace");
    try {
      switch (method) {
        case "rig.describe":
          return this.described(workspace);
        case "rig.grant":
          return this.grants.grant(workspace, peer, request.signed, request.chain);
        case "rig.revoke":
          this.grants.revoke(workspace, request.signed, request.chain);
          return { ok: true };
        case "rig.release":
          return { released: this.grants.release(workspace, peer, String(request.request ?? "")) };
        case "rig.settings":
          this.grants.settings(workspace, request.signed, request.chain);
          return { ok: true };
        case "rig.device":
          this.grants.device(workspace, request.signed, request.chain);
          return { ok: true };
        case "rig.added":
          return this.#added(workspace, this.grants.added(workspace, request.signed, request.pin, request.chain).lock);
        case "rig.full": {
          const s = this.grants.full(workspace, request.signed, request.chain);
          this.#d.cloud.update((st) => {
            st.full_pending = { ...(st.full_pending ?? {}), [workspace]: { at: s.body.at } };
          });
          return { ok: true };
        }
        case "rig.join": {
          const s = this.grants.join(workspace, request.signed, request.chain);
          const runJoin = this.#d.join
            ? this.#d.join(s.body.token, self.person, s.body.lock, s.body.ws)
            : joinWorkspace(this.#d.data, s.body.token, s.body.lock, { cloud: this.#d.cloud, rig: self.person, expectedWorkspace: s.body.ws });
          return runJoin.then((joined) => {
            if (joined.workspace !== s.body.ws) throw new Refused(`enrollment token is for workspace ${joined.workspace}, not ${s.body.ws}`);
            this.#d.cloud.reload(true);
            return { ok: true, workspace: joined.workspace, workspace_name: joined.workspace_name, name: joined.name };
          });
        }
        case "rig.proof":
          return { add: this.grants.proof(workspace) };
        case "rig.log": {
          const limit = Number.isSafeInteger(request.limit) ? Math.min(Math.max(1, request.limit), LOG_MAX) : 50;
          const singleRig = this.workspaces().length === 1;
          return this.commands.last(limit, workspace, singleRig).then((commands) => ({ commands: commands as unknown as Json }));
        }
        default:
          throw new Refused(`unknown method ${method}`);
      }
    } catch (error) {
      if (error instanceof Refusal) throw new Refused(error.message);
      throw error;
    }
  }

  #stations(workspace: string): string[] {
    const self = this.selfFor(workspace);
    if (self === null) return [];
    return (this.#d.cloud.membership(workspace)?.peers ?? []).flatMap((p) => (typeof p?.id === "string" && p.id !== self.id ? [p.id as string] : []));
  }

  #pruneUntold(): void {
    const active = new Set<string>();
    for (const m of this.#d.cloud.rigMemberships()) {
      for (const station of this.#stations(m.workspace)) active.add(`${m.workspace}\0${station}`);
    }
    for (const [k, waiting] of this.#untold) {
      if (!active.has(k)) {
        waiting.stop();
        this.#untold.delete(k);
      }
    }
    for (const k of [...this.#known]) {
      if (!active.has(k)) this.#known.delete(k);
    }
  }

  /// Every station in `workspace` (or all rig workspaces when null) told how this rig is now.
  #tellAll(workspace: string | null = null, hello = false, fresh = false): void {
    const targets = workspace === null ? this.#d.cloud.rigMemberships().map((m) => m.workspace) : [workspace];
    for (const ws of targets) {
      const stations = this.#stations(ws);
      for (const [k, waiting] of this.#untold) {
        if (k.startsWith(`${ws}\0`) && !stations.includes(k.slice(ws.length + 1))) {
          waiting.stop();
          this.#untold.delete(k);
        }
      }
      for (const k of [...this.#known]) {
        if (k.startsWith(`${ws}\0`) && !stations.includes(k.slice(ws.length + 1))) this.#known.delete(k);
      }
      for (const station of stations) {
        const k = `${ws}\0${station}`;
        if (!fresh || !this.#known.has(k)) this.#tell(ws, station, {}, hello);
        this.#known.add(k);
      }
    }
  }

  #tell(workspace: string, station: string, more: { ended?: Ended }, hello = false): void {
    const self = this.selfFor(workspace);
    if (self === null || !this.#stations(workspace).includes(station)) return;
    const k = `${workspace}\0${station}`;
    this.#untold.get(k)?.stop();
    this.#untold.delete(k);
    const request = { method: hello ? "rig.hello" : "rig.changed", workspace, ...this.described(workspace), ...more } as Json;
    const attempt = (wait: number, until: number) => {
      void this.#d.bus.ask(station, request).catch((error) => {
        if (error instanceof Refused || this.#fibers.now() >= until) return;
        const entry = { wait: Math.min(wait * 2, AGAIN_MAX_MS), until, stop: () => {} };
        entry.stop = this.#fibers.after(wait, () => {
          if (this.#untold.get(k) !== entry) return;
          this.#untold.delete(k);
          const again = { ...request, ...this.described(workspace) } as Json;
          Object.assign(request, again);
          attempt(entry.wait, until);
        });
        this.#untold.set(k, entry);
        log.info("rig", "a station was not told of this rig; told again later", { workspace, station: station.slice(0, 12), error: (error as Error).message });
      });
    };
    attempt(AGAIN_MS, this.#fibers.now() + AGAIN_FOR_MS);
  }

  async close(): Promise<void> {
    this.#unlisten?.();
    for (const waiting of this.#untold.values()) waiting.stop();
    for (const w of this.#wired) w.socket.destroy();
    this.#wired.clear();
    this.#untold.clear();
    await this.grants.close();
    await this.grants.written();
    await this.commands.written();
    if (this.#d.fibers === undefined) await this.#fibers.close();
  }
}
