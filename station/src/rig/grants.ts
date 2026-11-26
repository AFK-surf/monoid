// Who may use this rig (a station that only runs tasks, 2026-11-10): its own record, which nothing but its person's signature changes. A rig
// runs what the workspace's stations send it, for the chats its person granted it to (as a vault's secret is granted:
// a chat, for a time) or, with 免批准 on, for every chat of the workspace, as a station does. The stations bring what
// the person signed (a grant, one taken back, the settings: client/core-ts/src/rig-form.ts) with that person's own
// lock; the rig checks each against the lock it pinned as it joined (`enroll --rig <hash>`), so neither a station's
// database, an agent on it, nor the cloud gives a chat this machine.
//
// Multi-workspace rigs keep all state (settings, adds, devices, deviceSettings) partitioned by workspace, and personal
// lock chains partitioned by the owner's pinned `person` root hash.
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import {
  type AddBody, type DeviceBody, type Device, type GrantBody, type JoinBody, type RevokeBody, type SettingsBody, type Signed, type Kind, TIMEOUT_MAX, signedBytes, wellFormed,
  FULL_FOR, type FullBody,
} from "../../../client/core-ts/src/rig-form.ts";
import { type Entry, entryHash, personFold, signatureOk } from "../../../shared/lock.ts";
import { PrivateFile } from "../ops/files.ts";
import { Fibers } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";

const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest();

/// Whether `signed`'s signature is its key's over its body, as a statement of `kind`.
export function signatureHolds(kind: Kind, signed: Signed<unknown>): boolean {
  try {
    return /^([0-9a-f]{2})+$/.test(signed.sig.sig) && signatureOk(signed.sig.key, Buffer.from(signed.sig.sig, "hex"), Buffer.from(signedBytes(kind, signed.body, sha256)));
  } catch {
    return false;
  }
}

/// What this machine is in one rig workspace: its key's id, its workspace, whose it is and that person's own lock.
export type RigWs = { id: string; workspace: string; owner: string; person: string };
export type Self = RigWs;

/// A grant in force: what was signed, and when the chat last used the rig (ms).
export type Live = { signed: Signed<GrantBody>; usedAt: number };
export type Ended = { workspace: string; request: string; station: string; session: string; why: "expired" | "idle" | "revoked" | "released" | "closed" | "removed"; device?: string };

type Kept = {
  /// Each owner's personal lock chain, keyed by its genesis hash (`person`).
  chains: Record<string, Entry[]>;
  /// Rig settings per workspace.
  settings: Record<string, Signed<SettingsBody>>;
  /// Safe-mode add proofs per workspace.
  adds: Record<string, Signed<AddBody>>;
  /// Grants in force, keyed by request id (each `GrantBody` carries `ws`).
  grants: Record<string, Live>;
  /// Grants taken back (their request -> when they would have ended, unix seconds).
  revoked: Record<string, number>;
  /// Devices attached per workspace, keyed by `ws -> deviceId`.
  devices: Record<string, Record<string, Signed<DeviceBody>>>;
  /// Device settings per workspace, keyed by `ws -> deviceId`.
  deviceSettings: Record<string, Record<string, Signed<SettingsBody>>>;
};

export type GrantsDeps = {
  /// Where it is kept (<data>/rig/grants.json).
  path: string;
  /// Look up this machine's rig identity in `workspace`.
  selfFor: (workspace: string) => RigWs | null;
  /// All rig workspaces this machine currently participates in.
  workspaces: () => RigWs[];
  /// Whether a chat (a station's session in `workspace`) has a task running here.
  busy: (workspace: string, station: string, session: string) => boolean;
  /// A chat lost the rig: what it runs here stops.
  stop: (workspace: string, station: string, session: string) => void | Promise<void>;
  /// The chats (workspace, station, session) with something running here.
  running: () => { workspace: string; station: string; session: string }[];
  /// A grant ended here: its station is told.
  ended: (ended: Ended) => void;
  /// A chat (or every chat: none named) may have lost a device of this rig in `workspace`: connections are re-checked and cut.
  cut?: (workspace: string, device: string, station: string | null, session: string | null) => void;
  /// Anything a station shows of this rig in `workspace` changed (grants, settings, devices).
  changed: (workspace: string) => void;
  /// The process before this one still runs (a launcher's handover) and may change the record yet: what is read now is
  /// only held, not acted on (no grant ends, nothing is written), until `reload` reads it again once that one is gone.
  held?: boolean;
  fibers?: Fibers;
};

export class Refusal extends Error {}

export class RigGrants {
  readonly #d: GrantsDeps;
  readonly #fibers: Fibers;
  #kept: Kept = { chains: {}, settings: {}, adds: {}, grants: {}, revoked: {}, devices: {}, deviceSettings: {} };
  #armed: (() => void) | null = null;
  readonly #file: PrivateFile;
  /// Read while the process before this one may still change the record (`GrantsDeps.held`), until `reload`.
  #held: boolean;
  #closed = false;

  constructor(deps: GrantsDeps) {
    this.#d = deps;
    this.#file = new PrivateFile(deps.path);
    this.#fibers = deps.fibers ?? new Fibers("rig");
    this.#held = deps.held === true;
    let text: string | null = null;
    try {
      text = readFileSync(deps.path, "utf8"); // sync: read once, before the station serves
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") log.warn("rig", "the rig's grants could not be read; none holds until they are signed again", { error: (error as Error).message });
    }
    this.#take(text);
    this.#look();
  }

  /// The record as `text` says (none: nothing kept).
  #take(text: string | null): void {
    this.#kept = { chains: {}, settings: {}, adds: {}, grants: {}, revoked: {}, devices: {}, deviceSettings: {} };
    if (text === null) return;
    try {
      this.#kept = parseKept(JSON.parse(text));
    } catch (error) {
      log.warn("rig", "the rig's grants could not be read; none holds until they are signed again", { error: (error as Error).message });
    }
  }

  /// Whether the record is only held yet (`GrantsDeps.held`).
  held(): boolean {
    return this.#held;
  }

  /// The record read again, as the process before this one left it once it is gone (a grant taken back, 免批准 turned
  /// on while this one started), and from then on acted on.
  async reload(): Promise<void> {
    let text: string | null = null;
    try {
      text = await readFile(this.#d.path, "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") log.warn("rig", "the rig's grants could not be read; none holds until they are signed again", { error: (error as Error).message });
    }
    // (stopped meanwhile: what it held is let go as it is, nothing written, no grant ended)
    if (this.#closed) return;
    this.#take(text);
    this.#held = false;
    this.#look();
  }

  #secs(): number {
    return Math.floor(this.#fibers.now() / 1000);
  }

  #save(): void {
    // (held, the record is the process before's to write: one read before its last change is never written over it)
    if (this.#held) return;
    void this.#file.write(JSON.stringify(this.#kept)).catch((error) => log.warn("rig", "the rig's grants were not written", { error: (error as Error).message }));
  }

  written(): Promise<void> {
    return this.#file.written();
  }

  #selfFor(workspace: string): RigWs {
    const self = this.#d.selfFor(workspace);
    if (self === null) throw new Refusal("this machine is no rig of a workspace now");
    return self;
  }

  /// The person's own lock as brought (`chain`, the longest a station has): taken when it is the lock pinned for
  /// `workspace` and goes on from the one kept.
  takeChain(workspace: string, chain: unknown): void {
    if (!Array.isArray(chain) || chain.length === 0) return;
    const self = this.#selfFor(workspace);
    const kept = this.#kept.chains[self.person] ?? [];
    const brought = chain as Entry[];
    let genesis: string;
    try {
      genesis = entryHash(brought[0]!);
    } catch {
      throw new Refusal("the lock brought is malformed");
    }
    if (genesis !== self.person) throw new Refusal("the lock brought is not the one this rig's person pinned on it");
    if (brought.length <= kept.length) {
      if (!brought.every((e, i) => same(e, kept[i]))) throw new Refusal("the lock brought is at odds with the one this rig has of its person");
      return;
    }
    if (!kept.every((e, i) => same(e, brought[i]))) throw new Refusal("the lock brought is at odds with the one this rig has of its person");
    try {
      personFold(brought, self.owner);
    } catch (error) {
      throw new Refusal(`the lock brought does not hold: ${(error as Error).message}`);
    }
    this.#kept.chains[self.person] = brought;
    this.#save();
  }

  #keys(self: RigWs): Set<string> {
    const chain = this.#kept.chains[self.person];
    if (chain === undefined || chain.length === 0) return new Set();
    try {
      return new Set(personFold(chain, self.owner).devices.map((d) => d.key));
    } catch {
      return new Set();
    }
  }

  #checked<B extends { sub: string; ws: string; rig: string }>(workspace: string, kind: Kind, signed: unknown): Signed<B> {
    const self = this.#selfFor(workspace);
    if (!wellFormed(kind, signed)) throw new Refusal(`not a rig's ${kind}`);
    const s = signed as Signed<B>;
    if (s.body.rig !== self.id || s.body.ws !== self.workspace) throw new Refusal("signed for another rig or workspace");
    if (s.body.sub !== self.owner) throw new Refusal("not signed by this rig's person");
    if (!this.#keys(self).has(s.sig.key)) throw new Refusal("signed by a key that is not on this rig's person's own lock");
    if (!signatureHolds(kind, s)) throw new Refusal("the signature does not hold");
    return s;
  }

  /// A grant its station brings: in force from now, until it ends. Until when at the latest (unix seconds).
  grant(workspace: string, peer: string, signed: unknown, chain?: unknown): { until: number } {
    this.takeChain(workspace, chain);
    const s = this.#checked<GrantBody>(workspace, "grant", signed);
    const b = s.body;
    if (b.station !== peer) throw new Refusal("a grant is brought by its chat's own station");
    const now = this.#secs();
    if (b.exp <= now) throw new Refusal("the grant has expired");
    if (b.request in this.#kept.revoked) throw new Refusal("the grant was taken back");
    const wsDevices = this.#kept.devices[workspace] ?? {};
    if (b.device !== undefined && !(b.device in wsDevices)) throw new Refusal("no such device on this rig");
    const was = this.#kept.grants[b.request];
    this.#kept.grants[b.request] = { signed: s, usedAt: was?.usedAt ?? this.#fibers.now() };
    this.#save();
    this.#look();
    this.#d.changed(workspace);
    return { until: b.exp };
  }

  /// A grant taken back by the person (signed), brought by any station of `workspace`.
  revoke(workspace: string, signed: unknown, chain?: unknown): void {
    this.takeChain(workspace, chain);
    const s = this.#checked<RevokeBody>(workspace, "revoke", signed);
    const live = this.#kept.grants[s.body.request];
    this.#kept.revoked[s.body.request] = live?.signed.body.exp ?? this.#secs() + TIMEOUT_MAX;
    if (live && live.signed.body.ws === workspace) this.#end(live, "revoked");
    else this.#save();
  }

  /// A grant given back by its own station (the chat archived, or its agent done with the rig).
  release(workspace: string, peer: string, request: string): boolean {
    const live = this.#kept.grants[request];
    if (!live || live.signed.body.ws !== workspace || live.signed.body.station !== peer) return false;
    this.#end(live, "released");
    return true;
  }

  /// The settings as signed: taken when newer than those kept in `workspace`.
  settings(workspace: string, signed: unknown, chain?: unknown): void {
    this.takeChain(workspace, chain);
    const s = this.#checked<SettingsBody>(workspace, "settings", signed);
    if (s.body.device !== undefined) return this.#deviceSettings(workspace, s);
    const had = this.#kept.settings[workspace] ?? null;
    if (had !== null && s.body.seq <= had.body.seq) {
      if (s.body.seq === had.body.seq && had.sig.sig === s.sig.sig) return;
      throw new Refusal("older than the settings this rig has");
    }
    this.#kept.settings[workspace] = s;
    this.#save();
    if (had?.body.open === true && !s.body.open) {
      for (const { workspace: rw, station, session } of this.#d.running()) {
        if (rw === workspace && this.#grantOf(workspace, station, session) === null) void this.#d.stop(workspace, station, session);
      }
      for (const id of Object.keys(this.#kept.devices[workspace] ?? {})) {
        if (!this.#deviceOpen(workspace, id)) this.#d.cut?.(workspace, id, null, null);
      }
    }
    this.#d.changed(workspace);
  }

  #deviceSettings(workspace: string, s: Signed<SettingsBody>): void {
    const id = s.body.device!;
    const wsDevices = this.#kept.devices[workspace] ?? {};
    if (!(id in wsDevices)) throw new Refusal("no such device on this rig");
    const wsDevSettings = (this.#kept.deviceSettings[workspace] ??= {});
    const had = wsDevSettings[id];
    if (had !== undefined && s.body.seq <= had.body.seq) {
      if (s.body.seq === had.body.seq && had.sig.sig === s.sig.sig) return;
      throw new Refusal("older than the settings this device has");
    }
    wsDevSettings[id] = s;
    this.#save();
    if (had?.body.open === true && !s.body.open && !this.open(workspace)) this.#d.cut?.(workspace, id, null, null);
    this.#d.changed(workspace);
  }

  /// A device attached to this rig in `workspace` by its person, or (`removed`) taken off it.
  device(workspace: string, signed: unknown, chain?: unknown): void {
    this.takeChain(workspace, chain);
    const s = this.#checked<DeviceBody>(workspace, "device", signed);
    const id = s.body.device.id;
    const wsDevices = (this.#kept.devices[workspace] ??= {});
    const had = wsDevices[id];
    if (had !== undefined && s.body.at < had.body.at) throw new Refusal("older than what this rig has of the device");
    if (s.body.removed) {
      delete wsDevices[id];
      if (this.#kept.deviceSettings[workspace] !== undefined) delete this.#kept.deviceSettings[workspace]![id];
      this.#save();
      for (const live of Object.values(this.#kept.grants)) {
        if (live.signed.body.ws === workspace && live.signed.body.device === id) this.#end(live, "removed");
      }
      this.#d.cut?.(workspace, id, null, null);
    } else {
      wsDevices[id] = s;
      this.#save();
    }
    this.#d.changed(workspace);
  }

  /// The devices attached in `workspace`.
  devices(workspace: string): Device[] {
    return Object.values(this.#kept.devices[workspace] ?? {}).map((d) => d.body.device);
  }

  #deviceOpen(workspace: string, id: string): boolean {
    const s = this.#kept.deviceSettings[workspace]?.[id];
    return s !== undefined && s.body.open;
  }

  /// Why a chat may not reach device `id` here now, or null.
  deviceRefusal(workspace: string, station: string, session: string, id: string, use = true): string | null {
    const self = this.#d.selfFor(workspace);
    if (self === null) return "this rig is of another workspace";
    if (!(id in (this.#kept.devices[workspace] ?? {}))) return "no such device on this rig";
    if (this.open(workspace) || this.#deviceOpen(workspace, id)) return null;
    if (use) this.#look();
    const live = this.#grantOf(workspace, station, session) ?? this.#deviceGrantOf(workspace, station, session, id);
    if (live === null) return "this chat has no grant of this device: ask for one with device_use (its owner approves it in still.fail)";
    if (use) this.#used(live);
    return null;
  }

  #deviceGrantOf(workspace: string, station: string, session: string, id: string): Live | null {
    for (const live of Object.values(this.#kept.grants)) {
      const b = live.signed.body;
      if (b.ws === workspace && b.station === station && b.session === session && b.device === id) return live;
    }
    return null;
  }

  /// What the person signed taking this rig into `workspace` in security mode (`AddBody`).
  added(workspace: string, signed: unknown, pin?: unknown, chain?: unknown): { lock: string | null } {
    const self = this.#selfFor(workspace);
    if (!wellFormed("add", signed)) throw new Refusal("not a rig's add");
    const s = signed as Signed<AddBody>;
    if (s.body.rig !== self.id || s.body.ws !== self.workspace || s.body.sub !== self.owner) throw new Refusal("signed for another rig, workspace or person");
    if (!signatureHolds("add", s)) throw new Refusal("the signature does not hold");
    this.#kept.adds[workspace] = s;
    this.#save();
    const given = pin !== undefined && pin !== null;
    const candidate = (given ? pin : signed) as Signed<AddBody> | null;
    if (typeof candidate?.body?.lock !== "string") {
      if (given) throw new Refusal("the pin names no lock");
      return { lock: null };
    }
    try {
      if (chain !== undefined && chain !== null) this.takeChain(workspace, chain);
      return { lock: this.#checked<AddBody>(workspace, "add", candidate).body.lock ?? null };
    } catch (error) {
      if (given) throw error;
      return { lock: null };
    }
  }

  /// Its person's word that this machine is to be a whole station again in `workspace` (`FullBody`).
  full(workspace: string, signed: unknown, chain?: unknown): Signed<FullBody> {
    this.takeChain(workspace, chain);
    const s = this.#checked<FullBody>(workspace, "full", signed);
    const now = this.#secs();
    if (s.body.at > now + 300 || now - s.body.at > FULL_FOR) throw new Refusal("signed too long ago: switch it again");
    return s;
  }

  /// Its person's word that this rig should join another workspace (`JoinBody`), forwarded via `workspace`.
  /// Note: `s.body.ws` is the target workspace to join, not `workspace`.
  join(workspace: string, signed: unknown, chain?: unknown): Signed<JoinBody> {
    const self = this.#selfFor(workspace);
    this.takeChain(workspace, chain);
    if (!wellFormed("join", signed)) throw new Refusal("not a rig's join");
    const s = signed as Signed<JoinBody>;
    if (s.body.rig !== self.id) throw new Refusal("signed for another rig");
    if (s.body.ws === self.workspace) throw new Refusal("already a rig in that workspace");
    if (s.body.sub !== self.owner) throw new Refusal("not signed by this rig's person");
    if (!this.#keys(self).has(s.sig.key)) throw new Refusal("signed by a key that is not on this rig's person's own lock");
    if (!signatureHolds("join", s)) throw new Refusal("the signature does not hold");
    const now = this.#secs();
    if (s.body.at > now + 300 || now - s.body.at > FULL_FOR) throw new Refusal("signed too long ago: join it again");
    return s;
  }

  /// Clears all state, stops running tasks, and cuts device connections for `ws` (when leaving or becoming full).
  clearWorkspace(ws: string): void {
    for (const r of this.#d.running()) {
      if (r.workspace === ws) void this.#d.stop(ws, r.station, r.session);
    }
    for (const id of Object.keys(this.#kept.devices[ws] ?? {})) {
      this.#d.cut?.(ws, id, null, null);
    }
    let changed = false;
    for (const [req, live] of Object.entries(this.#kept.grants)) {
      if (live.signed.body.ws === ws) {
        delete this.#kept.grants[req];
        changed = true;
      }
    }
    if (ws in this.#kept.settings) { delete this.#kept.settings[ws]; changed = true; }
    if (ws in this.#kept.adds) { delete this.#kept.adds[ws]; changed = true; }
    if (ws in this.#kept.devices) { delete this.#kept.devices[ws]; changed = true; }
    if (ws in this.#kept.deviceSettings) { delete this.#kept.deviceSettings[ws]; changed = true; }
    if (changed) {
      this.#save();
      this.#look();
    }
  }

  proof(workspace: string): Signed<AddBody> | null {
    return this.#kept.adds[workspace] ?? null;
  }

  open(workspace: string): boolean {
    const self = this.#d.selfFor(workspace);
    const s = this.#kept.settings[workspace];
    return self !== null && s !== undefined && s.body.open && s.body.rig === self.id && s.body.ws === self.workspace;
  }

  #grantOf(workspace: string, station: string, session: string): Live | null {
    for (const live of Object.values(this.#kept.grants)) {
      const b = live.signed.body;
      if (b.ws === workspace && b.station === station && b.session === session && b.device === undefined) return live;
    }
    return null;
  }

  /// Why a chat (`session` of `station` in `workspace`) may not use this rig now, or null.
  refusal(workspace: string, station: string, session: string): string | null {
    const self = this.#d.selfFor(workspace);
    if (self === null) return "this rig is of another workspace";
    if (this.open(workspace)) return null;
    this.#look();
    const live = this.#grantOf(workspace, station, session);
    if (live === null) return "this chat has no grant of this station, which only runs tasks: ask for one with station_use (its owner approves it in still.fail)";
    this.#used(live);
    return null;
  }

  #used(live: Live): void {
    const now = this.#fibers.now();
    const write = now - live.usedAt >= 60_000;
    live.usedAt = now;
    if (write) {
      this.#save();
      this.#look();
    }
  }

  /// Why a station in `workspace` may not reach a service on this rig now, or null.
  stationRefusal(workspace: string, station: string): string | null {
    const self = this.#d.selfFor(workspace);
    if (self === null) return "this rig is of another workspace";
    if (this.open(workspace)) return null;
    this.#look();
    const lives = Object.values(this.#kept.grants).filter((g) => g.signed.body.ws === workspace && g.signed.body.station === station && g.signed.body.device === undefined);
    if (lives.length === 0) return "no chat of that station has a grant of this one";
    for (const live of lives) this.#used(live);
    return null;
  }

  /// What a station in `workspace` is told of this rig (`describe`).
  view(workspace: string): {
    owner: string; person: string; open: boolean; settings: number;
    grants: { request: string; station: string; session: string; chat: string; title: string; by: string; timeout: GrantBody["timeout"]; exp: number; until: number; device?: string }[];
    devices: (Device & { open: boolean; settings: number })[];
  } | null {
    const self = this.#d.selfFor(workspace);
    if (self === null) return null;
    this.#look();
    const wsDevices = this.#kept.devices[workspace] ?? {};
    const wsDevSettings = this.#kept.deviceSettings[workspace] ?? {};
    return {
      owner: self.owner,
      person: self.person,
      open: this.open(workspace),
      settings: this.#kept.settings[workspace]?.body.seq ?? 0,
      grants: Object.values(this.#kept.grants)
        .filter((g) => g.signed.body.ws === workspace)
        .map((g) => {
          const b = g.signed.body;
          return { request: b.request, station: b.station, session: b.session, chat: b.chat, title: b.title, by: b.by, timeout: b.timeout, exp: b.exp, until: this.#until(g), ...(b.device !== undefined ? { device: b.device } : {}) };
        }),
      devices: Object.values(wsDevices).map((d) => ({ ...d.body.device, open: this.#deviceOpen(workspace, d.body.device.id), settings: wsDevSettings[d.body.device.id]?.body.seq ?? 0 })),
    };
  }

  #until(g: Live): number {
    const b = g.signed.body;
    return b.timeout.kind === "idle" ? Math.min(b.exp, Math.floor(g.usedAt / 1000) + b.timeout.seconds) : b.exp;
  }

  #end(live: Live, why: Ended["why"]): void {
    const b = live.signed.body;
    const ws = b.ws;
    delete this.#kept.grants[b.request];
    this.#save();
    if (b.device !== undefined) {
      if (this.#grantOf(ws, b.station, b.session) === null && !this.open(ws) && !this.#deviceOpen(ws, b.device)) this.#d.cut?.(ws, b.device, b.station, b.session);
    } else if (this.#grantOf(ws, b.station, b.session) === null && !this.open(ws)) {
      void this.#d.stop(ws, b.station, b.session);
      for (const id of Object.keys(this.#kept.devices[ws] ?? {})) {
        if (this.#deviceGrantOf(ws, b.station, b.session, id) === null && !this.#deviceOpen(ws, id)) this.#d.cut?.(ws, id, b.station, b.session);
      }
    }
    this.#d.ended({ workspace: ws, request: b.request, station: b.station, session: b.session, why, ...(b.device !== undefined ? { device: b.device } : {}) });
    this.#d.changed(ws);
    this.#look();
  }

  #look(): void {
    this.#armed?.();
    this.#armed = null;
    // (held, no grant ends by what may be out of date: the process before ends it, or this one once it reads the record again)
    if (this.#held) return;
    const now = this.#secs();
    let next = Infinity;
    for (const live of Object.values(this.#kept.grants)) {
      const b = live.signed.body;
      if (b.exp <= now) {
        this.#end(live, "expired");
        return;
      }
      if (b.timeout.kind === "idle") {
        if (this.#d.busy(b.ws, b.station, b.session)) live.usedAt = this.#fibers.now();
        else if (Math.floor(live.usedAt / 1000) + b.timeout.seconds <= now) {
          this.#end(live, "idle");
          return;
        }
      }
      next = Math.min(next, this.#until(live));
    }
    for (const [request, exp] of Object.entries(this.#kept.revoked)) if (exp <= now) delete this.#kept.revoked[request];
    if (next !== Infinity) this.#armed = this.#fibers.after(Math.max(1, next - now) * 1000, () => this.#look());
  }

  async close(): Promise<void> {
    this.#closed = true;
    this.#armed?.();
    if (this.#d.fibers === undefined) await this.#fibers.close();
    await this.#file.written();
  }
}

/// Parses `grants.json` supporting both the per-workspace format and the legacy single-workspace format.
function parseKept(raw: any): Kept {
  const chains: Record<string, Entry[]> = {};
  if (raw?.chains !== null && typeof raw?.chains === "object" && !Array.isArray(raw?.chains)) {
    for (const [person, list] of Object.entries(raw.chains)) {
      if (Array.isArray(list) && list.length > 0) chains[person] = list as Entry[];
    }
  } else if (Array.isArray(raw?.chain) && raw.chain.length > 0) {
    try {
      const genesis = entryHash(raw.chain[0] as Entry);
      chains[genesis] = raw.chain as Entry[];
    } catch {}
  }

  const settings: Record<string, Signed<SettingsBody>> = {};
  if (wellFormed("settings", raw?.settings)) {
    settings[(raw.settings as Signed<SettingsBody>).body.ws] = raw.settings;
  } else if (raw?.settings !== null && typeof raw?.settings === "object" && !Array.isArray(raw?.settings)) {
    for (const [ws, s] of Object.entries(raw.settings)) {
      if (wellFormed("settings", s) && (s as Signed<SettingsBody>).body.ws === ws) settings[ws] = s as Signed<SettingsBody>;
    }
  }

  const adds: Record<string, Signed<AddBody>> = {};
  if (wellFormed("add", raw?.add)) {
    adds[(raw.add as Signed<AddBody>).body.ws] = raw.add;
  } else if (raw?.adds !== null && typeof raw?.adds === "object" && !Array.isArray(raw?.adds)) {
    for (const [ws, a] of Object.entries(raw.adds)) {
      if (wellFormed("add", a) && (a as Signed<AddBody>).body.ws === ws) adds[ws] = a as Signed<AddBody>;
    }
  }

  const grants = Object.fromEntries(
    Object.entries((raw?.grants ?? {}) as Record<string, Live>).filter(([, g]) => wellFormed("grant", g?.signed) && Number.isSafeInteger(g.usedAt)),
  );
  const revoked = Object.fromEntries(
    Object.entries((raw?.revoked ?? {}) as Record<string, number>).filter(([, exp]) => Number.isSafeInteger(exp)),
  );

  const devices: Record<string, Record<string, Signed<DeviceBody>>> = {};
  if (raw?.devices !== null && typeof raw?.devices === "object" && !Array.isArray(raw?.devices)) {
    for (const [k, v] of Object.entries(raw.devices)) {
      if (wellFormed("device", v)) {
        const d = v as Signed<DeviceBody>;
        if (d.body.device.id === k && !d.body.removed) (devices[d.body.ws] ??= {})[k] = d;
      } else if (v !== null && typeof v === "object" && !Array.isArray(v)) {
        const bucket: Record<string, Signed<DeviceBody>> = {};
        for (const [id, dv] of Object.entries(v as Record<string, unknown>)) {
          if (wellFormed("device", dv)) {
            const d = dv as Signed<DeviceBody>;
            if (d.body.ws === k && d.body.device.id === id && !d.body.removed) bucket[id] = d;
          }
        }
        if (Object.keys(bucket).length > 0) devices[k] = bucket;
      }
    }
  }

  const deviceSettings: Record<string, Record<string, Signed<SettingsBody>>> = {};
  if (raw?.deviceSettings !== null && typeof raw?.deviceSettings === "object" && !Array.isArray(raw?.deviceSettings)) {
    for (const [k, v] of Object.entries(raw.deviceSettings)) {
      if (wellFormed("settings", v)) {
        const s = v as Signed<SettingsBody>;
        if (s.body.device === k) (deviceSettings[s.body.ws] ??= {})[k] = s;
      } else if (v !== null && typeof v === "object" && !Array.isArray(v)) {
        const bucket: Record<string, Signed<SettingsBody>> = {};
        for (const [id, sv] of Object.entries(v as Record<string, unknown>)) {
          if (wellFormed("settings", sv)) {
            const s = sv as Signed<SettingsBody>;
            if (s.body.ws === k && s.body.device === id) bucket[id] = s;
          }
        }
        if (Object.keys(bucket).length > 0) deviceSettings[k] = bucket;
      }
    }
  }

  return { chains, settings, adds, grants, revoked, devices, deviceSettings };
}

const same = (a: unknown, b: unknown) => {
  try {
    return entryHash(a as Entry) === entryHash(b as Entry);
  } catch {
    return false;
  }
};
