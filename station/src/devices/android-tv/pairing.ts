// Multi-protocol step-by-step Android TV pairing manager (`atv_remote` + `adb`) with TTL auto-cancel,
// plus unified device add/rebind helpers supporting both AirPlay and Android TV.
import { randomBytes } from "node:crypto";
import type { DeviceProtocol } from "../../../../client/core-ts/src/rig-form.ts";
import { wall } from "../../ops/fibers.ts";
import type { DeviceCredentialStore } from "../credentials.ts";
import type { AirPlayPairingManager } from "../airplay/pairing.ts";
import type { DeviceRegistry, Kept } from "../registry.ts";
import {
  ANDROID_TV_PROTOCOLS,
  AndroidTvError,
  type AndroidTvAdapter,
  type AndroidTvAdbCredentials,
  type AndroidTvAdbMode,
  type AndroidTvCredentials,
  type AndroidTvProtocol,
  type AndroidTvRemoteCredentials,
} from "./types.ts";

const DEFAULT_TTL_MS = 5 * 60_000;
export const ANDROID_TV_PAIR_PREFIX = "atv_";

export type AndroidTvPairStartInput = {
  ws: string;
  identifier: string;
  address?: string;
  name?: string;
  model?: string;
  protocols: AndroidTvProtocol[];
  pairPort?: number;
  adbPort?: number;
  adbMode?: AndroidTvAdbMode;
};

export type AndroidTvPairStepResponse =
  | {
      pairId: string;
      done: false;
      step: number;
      total: number;
      protocol: AndroidTvProtocol;
      deviceProvidesPin: boolean;
      adbMode?: AndroidTvAdbMode;
      pairPort?: number;
      adbPort?: number;
      pairedProtocols: AndroidTvProtocol[];
    }
  | {
      pairId: string;
      done: true;
      protocols: AndroidTvProtocol[];
      pairedProtocols: AndroidTvProtocol[];
      model?: string;
    };

export type CompletedAndroidTvPairing = {
  identifier: string;
  address?: string;
  name?: string;
  model?: string;
  protocols: AndroidTvProtocol[];
  credentials: AndroidTvCredentials;
};

type Session = {
  pairId: string;
  ws: string;
  identifier: string;
  address?: string;
  name?: string;
  model?: string;
  protocols: AndroidTvProtocol[];
  pairPort?: number;
  adbPort?: number;
  adbMode?: AndroidTvAdbMode;
  index: number;
  pairToken: string | null;
  deviceProvidesPin: boolean;
  pairedProtocols: AndroidTvProtocol[];
  credentials: AndroidTvCredentials;
  completed: boolean;
  stopTtl: () => void;
};

export class AndroidTvPairingManager {
  readonly #adapter: AndroidTvAdapter;
  readonly #ttlMs: number;
  readonly #sessions = new Map<string, Session>();

  constructor(adapter: AndroidTvAdapter, opts?: { ttlMs?: number }) {
    this.#adapter = adapter;
    this.#ttlMs = opts?.ttlMs ?? DEFAULT_TTL_MS;
  }

  #scheduleTtl(s: Session): void {
    s.stopTtl();
    // timer: expire abandoned Android TV pairing session and close TLS pairing socket
    s.stopTtl = wall.after(this.#ttlMs, () => {
      if (this.#sessions.get(s.pairId) !== s) return;
      this.#sessions.delete(s.pairId);
      const token = s.pairToken;
      s.pairToken = null;
      if (token !== null) {
        void this.#adapter.pairCancel({ pairToken: token }).catch(() => {});
      }
    });
  }

  async start(input: AndroidTvPairStartInput): Promise<AndroidTvPairStepResponse> {
    const identifier = input.identifier.trim();
    if (!identifier) throw new AndroidTvError("invalid_params", "identifier is required");
    const protocols: AndroidTvProtocol[] = [];
    for (const p of input.protocols) {
      if (ANDROID_TV_PROTOCOLS.includes(p) && !protocols.includes(p)) protocols.push(p);
    }
    const pairId = `${ANDROID_TV_PAIR_PREFIX}${randomBytes(12).toString("hex")}`;
    if (protocols.length === 0) {
      const s: Session = {
        pairId,
        ws: input.ws,
        identifier,
        ...(input.address ? { address: input.address } : {}),
        ...(input.name ? { name: input.name } : {}),
        ...(input.model ? { model: input.model } : {}),
        protocols: [],
        index: 0,
        pairToken: null,
        deviceProvidesPin: false,
        pairedProtocols: [],
        credentials: {},
        completed: true,
        stopTtl: () => {},
      };
      this.#sessions.set(pairId, s);
      this.#scheduleTtl(s);
      return { pairId, done: true, protocols: [], pairedProtocols: [] };
    }

    const first = protocols[0]!;
    const started = await this.#adapter.pairStart({
      identifier,
      ...(input.address ? { address: input.address } : {}),
      protocol: first,
      ...(input.pairPort !== undefined ? { pairPort: input.pairPort } : {}),
      ...(input.adbPort !== undefined ? { adbPort: input.adbPort } : {}),
      ...(input.adbMode !== undefined ? { adbMode: input.adbMode } : {}),
    });
    const s: Session = {
      pairId,
      ws: input.ws,
      identifier,
      ...(input.address ? { address: input.address } : {}),
      ...(input.name ? { name: input.name } : {}),
      ...(input.model ? { model: input.model } : {}),
      protocols,
      ...(input.pairPort !== undefined ? { pairPort: input.pairPort } : {}),
      ...(input.adbPort !== undefined ? { adbPort: input.adbPort } : {}),
      ...(input.adbMode !== undefined ? { adbMode: input.adbMode } : {}),
      index: 0,
      pairToken: started.pairToken,
      deviceProvidesPin: started.deviceProvidesPin,
      pairedProtocols: [],
      credentials: {},
      completed: false,
      stopTtl: () => {},
    };
    this.#sessions.set(pairId, s);
    this.#scheduleTtl(s);
    return {
      pairId,
      done: false,
      step: 1,
      total: protocols.length,
      protocol: first,
      deviceProvidesPin: started.deviceProvidesPin,
      ...(started.adbMode ? { adbMode: started.adbMode } : {}),
      ...(started.pairPort !== undefined ? { pairPort: started.pairPort } : {}),
      ...(started.adbPort !== undefined ? { adbPort: started.adbPort } : {}),
      pairedProtocols: [],
    };
  }

  async finish(
    ws: string,
    pairId: string,
    opts: { pin?: string; skip?: boolean; pairPort?: number; adbPort?: number },
  ): Promise<AndroidTvPairStepResponse> {
    const s = this.#sessions.get(pairId);
    if (s === undefined || s.ws !== ws) {
      throw new AndroidTvError("invalid_pair_id", "pairing session not found or expired");
    }
    if (s.completed) {
      return {
        pairId,
        done: true,
        protocols: [...s.protocols],
        pairedProtocols: [...s.pairedProtocols],
        ...(s.model ? { model: s.model } : {}),
      };
    }
    this.#scheduleTtl(s);
    const currentProto = s.protocols[s.index]!;
    const token = s.pairToken;

    if (opts.skip === true) {
      s.pairToken = null;
      if (token !== null) {
        await this.#adapter.pairCancel({ pairToken: token }).catch(() => {});
      }
    } else {
      let activeToken = token;
      if (activeToken === null) {
        const restarted = await this.#adapter.pairStart({
          identifier: s.identifier,
          ...(s.address ? { address: s.address } : {}),
          protocol: currentProto,
          ...(s.pairPort !== undefined ? { pairPort: s.pairPort } : {}),
          ...(s.adbPort !== undefined ? { adbPort: s.adbPort } : {}),
          ...(s.adbMode !== undefined ? { adbMode: s.adbMode } : {}),
        });
        activeToken = restarted.pairToken;
        s.pairToken = activeToken;
      }
      // Keep s.pairToken on retryable errors (invalid_pin, adb_unauthorized) so user can retry immediately.
      try {
        const res = await this.#adapter.pairFinish({
          pairToken: activeToken,
          ...(opts.pin !== undefined ? { pin: opts.pin } : {}),
          ...(opts.pairPort !== undefined ? { pairPort: opts.pairPort } : {}),
          ...(opts.adbPort !== undefined ? { adbPort: opts.adbPort } : {}),
        });
        s.pairToken = null;
        if (currentProto === "atv_remote") {
          s.credentials.atv_remote = res.credentials as AndroidTvRemoteCredentials;
        } else {
          s.credentials.adb = res.credentials as AndroidTvAdbCredentials;
        }
        if (res.model && !s.model) s.model = res.model;
        if (!s.pairedProtocols.includes(currentProto)) s.pairedProtocols.push(currentProto);
      } catch (err) {
        if (!(err instanceof AndroidTvError && (err.code === "invalid_pin" || err.code === "adb_unauthorized"))) {
          s.pairToken = null;
        }
        throw err;
      }
    }

    s.index++;
    if (s.index < s.protocols.length) {
      const nextProto = s.protocols[s.index]!;
      const started = await this.#adapter.pairStart({
        identifier: s.identifier,
        ...(s.address ? { address: s.address } : {}),
        protocol: nextProto,
        ...(s.pairPort !== undefined ? { pairPort: s.pairPort } : {}),
        ...(s.adbPort !== undefined ? { adbPort: s.adbPort } : {}),
        ...(s.adbMode !== undefined ? { adbMode: s.adbMode } : {}),
      });
      s.pairToken = started.pairToken;
      s.deviceProvidesPin = started.deviceProvidesPin;
      this.#scheduleTtl(s);
      return {
        pairId,
        done: false,
        step: s.index + 1,
        total: s.protocols.length,
        protocol: nextProto,
        deviceProvidesPin: started.deviceProvidesPin,
        ...(started.adbMode ? { adbMode: started.adbMode } : {}),
        ...(started.pairPort !== undefined ? { pairPort: started.pairPort } : {}),
        ...(started.adbPort !== undefined ? { adbPort: started.adbPort } : {}),
        pairedProtocols: [...s.pairedProtocols],
      };
    }

    s.completed = true;
    s.pairToken = null;
    this.#scheduleTtl(s);
    return {
      pairId,
      done: true,
      protocols: [...s.protocols],
      pairedProtocols: [...s.pairedProtocols],
      ...(s.model ? { model: s.model } : {}),
    };
  }

  async cancel(ws: string, pairId: string): Promise<void> {
    const s = this.#sessions.get(pairId);
    if (s === undefined || s.ws !== ws) return;
    s.stopTtl();
    this.#sessions.delete(pairId);
    const token = s.pairToken;
    s.pairToken = null;
    if (token !== null) {
      await this.#adapter.pairCancel({ pairToken: token }).catch(() => {});
    }
  }

  peekCredentials(ws: string, pairId: string): CompletedAndroidTvPairing | null {
    const s = this.#sessions.get(pairId);
    if (s === undefined || s.ws !== ws || !s.completed) return null;
    return {
      identifier: s.identifier,
      ...(s.address ? { address: s.address } : {}),
      ...(s.name ? { name: s.name } : {}),
      ...(s.model ? { model: s.model } : {}),
      protocols: [...s.pairedProtocols],
      credentials: { ...s.credentials },
    };
  }

  consumeCredentials(ws: string, pairId: string): boolean {
    const s = this.#sessions.get(pairId);
    if (s === undefined || s.ws !== ws || !s.completed) return false;
    s.stopTtl();
    this.#sessions.delete(pairId);
    s.credentials = {};
    return true;
  }

  async close(): Promise<void> {
    const all = [...this.#sessions.values()];
    this.#sessions.clear();
    await Promise.all(
      all.map(async (s) => {
        s.stopTtl();
        const token = s.pairToken;
        s.pairToken = null;
        if (token !== null) {
          await this.#adapter.pairCancel({ pairToken: token }).catch(() => {});
        }
      }),
    );
  }
}

/// Unified commit helper for adding a device (AirPlay, Android TV, or plain tcp/adb/serial),
/// preserving `pairId` when registry validation fails (e.g. duplicate name) so the user can rename and retry.
export async function commitAnyDeviceAdd(
  registry: DeviceRegistry,
  managers: { airplay: AirPlayPairingManager; androidTv: AndroidTvPairingManager },
  credentials: DeviceCredentialStore<Record<string, unknown>>,
  ws: string,
  by: { sub: string; email: string; name: string },
  b: Record<string, unknown>,
  at: number,
): Promise<{ ok: true; device: Kept } | { ok: false; status: number; message: string }> {
  const pairId = typeof b.pairId === "string" && b.pairId.trim() !== "" ? b.pairId.trim() : null;
  let peeked: { model?: string; protocols: DeviceProtocol[]; credentials: Record<string, unknown> } | null = null;
  let consume: (() => void) | null = null;

  if (b.kind === "airplay" && pairId !== null) {
    const p = managers.airplay.peekCredentials(ws, pairId);
    if (p === null) return { ok: false, status: 422, message: "invalid or incomplete pairing session (pairId)" };
    peeked = { model: p.model, protocols: p.protocols, credentials: p.credentials as Record<string, unknown> };
    consume = () => managers.airplay.consumeCredentials(ws, pairId);
  } else if (b.kind === "android_tv" && pairId !== null) {
    const p = managers.androidTv.peekCredentials(ws, pairId);
    if (p === null) return { ok: false, status: 422, message: "invalid or incomplete pairing session (pairId)" };
    peeked = { model: p.model, protocols: p.protocols, credentials: p.credentials as Record<string, unknown> };
    consume = () => managers.androidTv.consumeCredentials(ws, pairId);
  }

  const given = peeked === null
    ? {
        name: b.name,
        kind: b.kind,
        target: b.target,
        baud: b.baud,
        model: b.model,
        protocols: b.protocols,
        paired: b.paired,
      }
    : {
        name: b.name,
        kind: b.kind,
        target: b.target,
        baud: b.baud,
        model: b.model ?? peeked.model,
        protocols: peeked.protocols.length > 0 ? peeked.protocols : b.protocols,
        paired: Object.keys(peeked.credentials).length > 0,
      };
  const made = registry.add(ws, by, given, at);
  if (typeof made === "string") return { ok: false, status: 422, message: made };
  if (peeked !== null && Object.keys(peeked.credentials).length > 0) {
    try {
      await credentials.set(ws, made.id, peeked.credentials);
    } catch (err) {
      registry.remove(ws, made.id);
      throw err;
    }
  }
  consume?.();
  return { ok: true, device: made };
}

function normalizeHostTarget(t: string): string {
  const lower = t.trim().toLowerCase();
  const idx = lower.lastIndexOf(":");
  if (idx > 0 && lower.indexOf(":") === idx) return lower.slice(0, idx);
  return lower;
}

/// Unified re-pair / add-protocol commit helper for AirPlay and Android TV devices.
/// Validates target match and rejects empty credentials. For Android TV, merges newly paired protocols with existing credentials.
export async function commitDeviceRebind(
  registry: DeviceRegistry,
  managers: { airplay: AirPlayPairingManager; androidTv: AndroidTvPairingManager },
  credentials: DeviceCredentialStore<Record<string, unknown>>,
  ws: string,
  id: string,
  pairId: string,
): Promise<{ ok: true; device: Kept } | { ok: false; status: number; message: string }> {
  const d = registry.get(ws, id);
  if (d === null) return { ok: false, status: 404, message: "no such device on this station" };
  if (d.kind !== "airplay" && d.kind !== "android_tv") {
    return { ok: false, status: 422, message: "only airplay and android_tv devices can be re-paired" };
  }

  const peeked = d.kind === "airplay"
    ? managers.airplay.peekCredentials(ws, pairId)
    : managers.androidTv.peekCredentials(ws, pairId);
  if (peeked === null) return { ok: false, status: 422, message: "invalid or incomplete pairing session (pairId)" };

  const targetLow = d.target.toLowerCase();
  const targetHost = normalizeHostTarget(d.target);
  const idMatch = peeked.identifier.toLowerCase() === targetLow || (d.kind === "android_tv" && normalizeHostTarget(peeked.identifier) === targetHost);
  const addrMatch = typeof peeked.address === "string" && peeked.address !== ""
    && (peeked.address.toLowerCase() === targetLow || (d.kind === "android_tv" && normalizeHostTarget(peeked.address) === targetHost));
  if (!idMatch && !addrMatch) {
    return { ok: false, status: 422, message: `pairing session target (${peeked.identifier}) does not match device target (${d.target})` };
  }
  if (Object.keys(peeked.credentials).length === 0) {
    return { ok: false, status: 422, message: "re-pairing produced no credentials; existing device credentials were kept" };
  }

  let nextCreds: Record<string, unknown> = peeked.credentials as Record<string, unknown>;
  let nextProtocols: DeviceProtocol[] = [...peeked.protocols];
  if (d.kind === "android_tv") {
    const existing = (await credentials.get(ws, id).catch(() => null)) ?? {};
    nextCreds = { ...existing, ...nextCreds };
    const protoSet = new Set<DeviceProtocol>([...(d.protocols ?? []), ...peeked.protocols]);
    nextProtocols = [...protoSet];
  }

  await credentials.set(ws, id, nextCreds);
  const updated = registry.updateMeta(ws, id, {
    ...(peeked.model ? { model: peeked.model } : {}),
    protocols: nextProtocols,
    paired: true,
  });
  if (updated === null) return { ok: false, status: 404, message: "no such device on this station" };
  if (typeof updated === "string") return { ok: false, status: 422, message: updated };

  if (d.kind === "airplay") managers.airplay.consumeCredentials(ws, pairId);
  else managers.androidTv.consumeCredentials(ws, pairId);
  return { ok: true, device: updated };
}
