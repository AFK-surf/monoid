// Multi-protocol step-by-step AirPlay pairing session manager with TTL auto-cancel.
import { randomBytes } from "node:crypto";
import { wall } from "../../ops/fibers.ts";
import type { DeviceRegistry, Kept } from "../registry.ts";
import type { AirPlayCredentialStore } from "./credentials.ts";
import {
  AIRPLAY_PROTOCOLS,
  AirPlayError,
  type AirPlayAdapter,
  type AirPlayCredentials,
  type AirPlayProtocol,
} from "./types.ts";

const DEFAULT_TTL_MS = 5 * 60_000;

export type PairStartInput = {
  ws: string;
  identifier: string;
  address?: string;
  name?: string;
  model?: string;
  protocols: AirPlayProtocol[];
};

export type PairStepResponse =
  | {
      pairId: string;
      done: false;
      step: number;
      total: number;
      protocol: AirPlayProtocol;
      deviceProvidesPin: boolean;
      pairedProtocols: AirPlayProtocol[];
    }
  | {
      pairId: string;
      done: true;
      protocols: AirPlayProtocol[];
      pairedProtocols: AirPlayProtocol[];
    };

export type CompletedPairing = {
  identifier: string;
  address?: string;
  name?: string;
  model?: string;
  protocols: AirPlayProtocol[];
  credentials: AirPlayCredentials;
};

type Session = {
  pairId: string;
  ws: string;
  identifier: string;
  address?: string;
  name?: string;
  model?: string;
  protocols: AirPlayProtocol[];
  index: number;
  pairToken: string | null;
  deviceProvidesPin: boolean;
  pairedProtocols: AirPlayProtocol[];
  credentials: AirPlayCredentials;
  completed: boolean;
  stopTtl: () => void;
};

export class AirPlayPairingManager {
  readonly #adapter: AirPlayAdapter;
  readonly #ttlMs: number;
  readonly #sessions = new Map<string, Session>();

  constructor(adapter: AirPlayAdapter, opts?: { ttlMs?: number }) {
    this.#adapter = adapter;
    this.#ttlMs = opts?.ttlMs ?? DEFAULT_TTL_MS;
  }

  #scheduleTtl(s: Session): void {
    s.stopTtl();
    // timer: expire abandoned airplay pairing session and dismiss on-screen TV PIN dialog
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

  async start(input: PairStartInput): Promise<PairStepResponse> {
    const identifier = input.identifier.trim();
    if (!identifier) throw new AirPlayError("invalid_params", "identifier is required");
    const protocols: AirPlayProtocol[] = [];
    for (const p of input.protocols) {
      if (AIRPLAY_PROTOCOLS.includes(p) && !protocols.includes(p)) protocols.push(p);
    }
    const pairId = randomBytes(12).toString("hex");
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
    });
    const s: Session = {
      pairId,
      ws: input.ws,
      identifier,
      ...(input.address ? { address: input.address } : {}),
      ...(input.name ? { name: input.name } : {}),
      ...(input.model ? { model: input.model } : {}),
      protocols,
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
      pairedProtocols: [],
    };
  }

  async finish(ws: string, pairId: string, opts: { pin?: string; skip?: boolean }): Promise<PairStepResponse> {
    const s = this.#sessions.get(pairId);
    if (s === undefined || s.ws !== ws) {
      throw new AirPlayError("invalid_pair_id", "pairing session not found or expired");
    }
    if (s.completed) {
      return { pairId, done: true, protocols: [...s.protocols], pairedProtocols: [...s.pairedProtocols] };
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
        });
        activeToken = restarted.pairToken;
        s.pairToken = activeToken;
      }
      s.pairToken = null;
      const res = await this.#adapter.pairFinish({
        pairToken: activeToken,
        ...(opts.pin !== undefined ? { pin: opts.pin } : {}),
      });
      s.credentials[currentProto] = res.credentials;
      if (!s.pairedProtocols.includes(currentProto)) s.pairedProtocols.push(currentProto);
    }

    s.index++;
    if (s.index < s.protocols.length) {
      const nextProto = s.protocols[s.index]!;
      const started = await this.#adapter.pairStart({
        identifier: s.identifier,
        ...(s.address ? { address: s.address } : {}),
        protocol: nextProto,
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

  /// Inspect a completed pairing session without consuming it (so validation retries keep the pairId).
  peekCredentials(ws: string, pairId: string): CompletedPairing | null {
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

  /// Consume and wipe a completed pairing session after persistence succeeds.
  consumeCredentials(ws: string, pairId: string): boolean {
    const s = this.#sessions.get(pairId);
    if (s === undefined || s.ws !== ws || !s.completed) return false;
    s.stopTtl();
    this.#sessions.delete(pairId);
    s.credentials = {};
    return true;
  }

  /// Atomically consume a completed pairing session's credentials (clearing them from memory).
  takeCredentials(ws: string, pairId: string): CompletedPairing | null {
    const peeked = this.peekCredentials(ws, pairId);
    if (peeked === null) return null;
    this.consumeCredentials(ws, pairId);
    return peeked;
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

/// Validate and commit adding a device (preserving `pairId` on validation failure so the user can retry without re-entering PIN).
export async function commitDeviceAdd(
  registry: DeviceRegistry,
  pairing: AirPlayPairingManager,
  credentials: AirPlayCredentialStore,
  ws: string,
  by: { sub: string; email: string; name: string },
  b: Record<string, unknown>,
  at: number,
): Promise<{ ok: true; device: Kept } | { ok: false; status: number; message: string }> {
  const pairId = typeof b.pairId === "string" && b.pairId.trim() !== "" ? b.pairId.trim() : null;
  let peeked: CompletedPairing | null = null;
  if (b.kind === "airplay" && pairId !== null) {
    peeked = pairing.peekCredentials(ws, pairId);
    if (peeked === null) return { ok: false, status: 422, message: "invalid or incomplete pairing session (pairId)" };
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
  if (pairId !== null && peeked !== null) {
    pairing.consumeCredentials(ws, pairId);
  }
  return { ok: true, device: made };
}

/// Validate and commit re-pairing an existing AirPlay device (requires target match and non-empty credentials).
export async function commitAirPlayRebind(
  registry: DeviceRegistry,
  pairing: AirPlayPairingManager,
  credentials: AirPlayCredentialStore,
  ws: string,
  id: string,
  pairId: string,
): Promise<{ ok: true; device: Kept } | { ok: false; status: number; message: string }> {
  const d = registry.get(ws, id);
  if (d === null) return { ok: false, status: 404, message: "no such device on this station" };
  if (d.kind !== "airplay") return { ok: false, status: 422, message: "only airplay devices can be re-paired" };
  const peeked = pairing.peekCredentials(ws, pairId);
  if (peeked === null) return { ok: false, status: 422, message: "invalid or incomplete pairing session (pairId)" };
  const targetLow = d.target.toLowerCase();
  const idMatch = peeked.identifier.toLowerCase() === targetLow;
  const addrMatch = typeof peeked.address === "string" && peeked.address !== "" && peeked.address.toLowerCase() === targetLow;
  if (!idMatch && !addrMatch) {
    return { ok: false, status: 422, message: `pairing session target (${peeked.identifier}) does not match device target (${d.target})` };
  }
  if (Object.keys(peeked.credentials).length === 0) {
    return { ok: false, status: 422, message: "re-pairing produced no credentials; existing device credentials were kept" };
  }
  await credentials.set(ws, id, peeked.credentials);
  const updated = registry.updateMeta(ws, id, {
    ...(peeked.model ? { model: peeked.model } : {}),
    protocols: peeked.protocols,
    paired: true,
  });
  if (updated === null) return { ok: false, status: 404, message: "no such device on this station" };
  if (typeof updated === "string") return { ok: false, status: 422, message: updated };
  pairing.consumeCredentials(ws, pairId);
  return { ok: true, device: updated };
}
