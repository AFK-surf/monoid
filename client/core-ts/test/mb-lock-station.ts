// Shared JSON-RPC client for the MoonBit `harness-lock` builder (`station/mb/src/reader_harness/cloud_lock.mbt`).
// Zero `station/src/` imports: drives real `@cloud_lock.Cloud`, `@cloud_lock.DeviceBuilds`, and `@gate.Keeper` over
// `./mb-harness.ts`, passing the test clock's current `nowMs` on every RPC so virtual time stays in lockstep.
import { after } from "node:test";
import type { Entry as StationEntry, LockState } from "../../../shared/lock.ts";
import { type HarnessClient, startHarness } from "./mb-harness.ts";

let shared: HarnessClient | null = null;

export function lockHarness(): HarnessClient {
  if (shared === null) shared = startHarness("harness-lock");
  return shared;
}

export async function closeLockHarness(): Promise<void> {
  if (shared === null) return;
  const h = shared;
  shared = null;
  await h.close();
}

after(async () => {
  await closeLockHarness();
});

export async function setLockClock(ms: number): Promise<void> {
  await lockHarness().call("setClock", { nowMs: ms });
}

export type InLockOk = { ok: true; viewer: Record<string, any> };
export type InLockRefused = { ok: false; refusal: true; message: string; body: Record<string, any> };
export type InLockResult = InLockOk | InLockRefused;

export type HydratedLocked = { state: LockState | null; waiting: boolean };

function hydrateLockState(raw: Record<string, any> | null | undefined): LockState | null {
  if (raw === null || raw === undefined) return null;
  return {
    ws: raw.ws,
    seq: raw.seq,
    head: raw.head,
    genesis: raw.genesis,
    origins: raw.origins,
    rp_id: raw.rp_id,
    cloud_keys: raw.cloud_keys,
    members: new Map(raw.members),
    devices: new Map(raw.devices),
    signKeys: new Map(raw.signKeys),
    passkeys: new Map(raw.passkeys),
    signed: new Set(raw.signed),
    stations: new Map(raw.stations),
    gateways: new Set(raw.gateways),
    persons: new Map(raw.persons),
    disabled: raw.disabled,
    ...(typeof raw.moved === "string" ? { moved: raw.moved } : {}),
  } as LockState;
}

function hydrateLocked(raw: { state?: Record<string, any> | null; waiting?: boolean } | null | undefined): HydratedLocked | null {
  if (raw === null || raw === undefined) return null;
  return { state: hydrateLockState(raw.state), waiting: raw.waiting === true };
}

function bodyText(body: string | Uint8Array | Buffer | null | undefined): string {
  if (body === null || body === undefined) return "";
  if (typeof body === "string") return body;
  return Buffer.from(body).toString("utf8");
}

export interface BringableLog {
  readonly sub: string;
  readonly entries: readonly unknown[];
  readonly bodies: Map<string, any>;
  readonly app?: { base: { hex: string } };
}

export class MbLockStation {
  readonly handle: number;
  readonly data: string;
  private readonly clock: () => number;

  private constructor(handle: number, data: string, clock: () => number) {
    this.handle = handle;
    this.data = data;
    this.clock = clock;
  }

  static async create(data: string, state: Record<string, unknown>, clock: () => number): Promise<MbLockStation> {
    const out = await lockHarness().call<{ handle: number }>("create", { data, state, nowMs: clock() });
    return new MbLockStation(out.handle, data, clock);
  }

  private call<T = any>(op: string, params: Record<string, unknown> = {}): Promise<T> {
    return lockHarness().call<T>(op, { ...params, handle: this.handle, nowMs: this.clock() });
  }

  takeLock(entries: readonly unknown[], ws?: string | null, fork?: boolean): Promise<{ taken: number; off: unknown[]; refusal: string | null }> {
    return this.call("takeLock", { entries, ...(ws ? { ws } : {}), ...(fork ? { fork: true } : {}) });
  }

  keepLock(entries: readonly unknown[], ws?: string | null, fork?: boolean): Promise<{ taken: number; off: unknown[]; refusal: string | null }> {
    return this.takeLock(entries, ws, fork);
  }

  lockKept(ws?: string | null): Promise<StationEntry[]> {
    return this.call("lockKept", ws ? { ws } : {});
  }

  lockAfter(seq: number, ws?: string | null): Promise<StationEntry[]> {
    return this.call("lockAfter", { seq, ...(ws ? { ws } : {}) });
  }

  async chain(ws?: string | null): Promise<HydratedLocked | null> {
    return hydrateLocked(await this.call("chain", ws ? { ws } : {}));
  }

  async locked(ws?: string | null): Promise<HydratedLocked | null> {
    return hydrateLocked(await this.call("locked", ws ? { ws } : {}));
  }

  async bodiesAll(ws?: string | null): Promise<Map<string, any>> {
    const pairs = await this.call<[string, any][]>("bodiesAll", ws ? { ws } : {});
    return new Map(pairs);
  }

  takeBodies(ws: string | null, bodies: readonly unknown[]): Promise<{ taken: number; refused: unknown[] }> {
    return this.call("takeBodies", { bodies, ...(ws ? { ws } : {}) });
  }

  async lockRoute(
    method: string,
    query: [string, string][],
    body: string | Uint8Array | Buffer | null | undefined,
    viewer: Record<string, unknown>,
  ): Promise<[number, any]> {
    const out = await this.call<{ status: number; body: any }>("lockRoute", {
      method,
      query,
      body: bodyText(body),
      viewer,
    });
    return [out.status, out.body];
  }

  async lockPartRoute(
    part: string,
    method: string,
    body: string | Uint8Array | Buffer | null | undefined,
    viewer: Record<string, unknown>,
  ): Promise<[number, any]> {
    const out = await this.call<{ status: number; body: any }>("lockPartRoute", {
      part,
      method,
      body: bodyText(body),
      viewer,
    });
    return [out.status, out.body];
  }

  inLock(
    admitted: Record<string, unknown>,
    role: string,
    device: string,
    hello?: Record<string, unknown> | null,
    sub?: string,
  ): Promise<InLockResult> {
    return this.call("inLock", {
      admitted,
      role,
      device,
      ...(hello !== undefined && hello !== null ? { hello } : {}),
      ...(sub !== undefined ? { sub } : {}),
    });
  }

  inLockBringing(
    admitted: Record<string, unknown>,
    role: string,
    device: string,
    hello: Record<string, unknown>,
    sub?: string,
  ): Promise<InLockResult> {
    return this.call("inLockBringing", {
      admitted,
      role,
      device,
      hello,
      ...(sub !== undefined ? { sub } : {}),
    });
  }

  personChainsEvery(): Promise<[string, StationEntry[]][]> {
    return this.call("personChainsEvery");
  }

  personChainsOf(sub: string): Promise<[string, StationEntry[]][]> {
    return this.call("personChainsOf", { sub });
  }

  async personChainsKeep(genesis: string, entries: readonly unknown[], ws?: string | null): Promise<void> {
    await this.call("personChainsKeep", { genesis, entries, ...(ws ? { ws } : {}) });
  }

  sawBuild(viewer: Record<string, unknown>, build: string | null | undefined): Promise<number | null> {
    return this.call("sawBuild", { viewer, build: build ?? null });
  }

  async deviceBuildsSaw(device: string, build: number | null, nowSec?: number): Promise<void> {
    await this.call("deviceBuildsSaw", {
      device,
      build,
      ...(nowSec !== undefined ? { nowSec } : {}),
    });
  }

  movedTooOld(ws: string, build: number | null): Promise<boolean> {
    return this.call("movedTooOld", { ws, build });
  }

  async bring(log: BringableLog, bodies = true, ws = "ws"): Promise<[number, any]> {
    const said = {
      chain: log.entries,
      ...(bodies ? { bodies: [...log.bodies.values()].filter((b) => b.ws === ws) } : {}),
    };
    const viewer = {
      sub: log.sub,
      email: `${log.sub}@x`,
      name: log.sub,
      role: "member",
      workspace: ws,
      device: log.app?.base.hex ?? "00".repeat(32),
    };
    const out = await this.lockPartRoute("person", "POST", JSON.stringify(said), viewer);
    if (out[0] !== 200) throw new Error(`the station did not take ${log.sub}'s log: ${out[0]} ${JSON.stringify(out[1])}`);
    return out;
  }

  async close(): Promise<void> {
    await this.call("close");
  }
}
