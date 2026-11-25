// The iroh a host binds (iroh.ts) from a binding's promises: station/native/mesh's napi addon on Node
// (hosts/node-addon.ts), client/iroh-wasm in a browser (hosts/web.ts). Both have the same calls; this makes them the
// core's Effects.
import { Effect, Fiber } from "effect";
import { accessMapOf, relayUrlKey } from "./iroh-access.ts";
export { accessOf } from "./iroh-access.ts";
import { HostError } from "./error.ts";
import type { BindOptions, CloseReason, Iroh, IrohAddr, IrohConnection, IrohEndpoint, IrohStream, IrohMeshScope, IrohMeshDescriptor, IrohLeafAttachment } from "./iroh.ts";

export type BoundStream = {
  read(): Promise<Uint8Array | null>;
  write(bytes: never): Promise<void>;
  finish(): Promise<void>;
  stopped(): Promise<number | null | void>;
  reset?(code: number): Promise<void> | void;
  /// The addon's since its streams took frames as datagrams (iroh.ts `receiveMediaDatagrams`).
  receiveMediaDatagrams?(token: number): Promise<boolean>;
};
export type BoundConnection = {
  remoteId(): string;
  acceptBi(): Promise<BoundStream | null>;
  openBi(): Promise<BoundStream>;
  openUni(): Promise<BoundStream>;
  close(code: number, reason: string): void;
  closeReason(): CloseReason | null | undefined;
  closedInfo(): Promise<CloseReason>;
  paths(): { id: string; selected: boolean; relay?: string | null; ip?: string | null; rttMs?: number | null; txPackets: number; lostPackets: number }[];
  stats(): { rxBytes: number; txBytes: number };
};
export type BoundEndpoint = {
  meshUseLeaf?(value: {scope: string; attachment: IrohLeafAttachment}): Promise<void>;
  meshDetachLeaf?(value: {scope: string; attachmentId: number[]}): Promise<void>;
  meshConfigure?(scope: IrohMeshScope): Promise<IrohMeshDescriptor>;
  meshRemove?(scope: string): Promise<void>;
  id(): string;
  /// `givenUp`: resolves when the dial is to be given up (a binding from before takes no such argument and goes on).
  connect(addr: IrohAddr, alpn: never, additional: never[], givenUp?: Promise<void>): Promise<BoundConnection>;
  /// The addon's alone (iroh-wasm takes no connections): the next one coming, its handshake done, and the ALPN agreed.
  accept?(): Promise<(BoundConnection & { alpn(): Uint8Array }) | null>;
  addAddr(addr: IrohAddr): void;
  networkChange(): Promise<void>;
  relayStatus(): { url: string; connected: boolean; access?: string }[];
  setRelayEntries?(entries: { entry: string; relay: string }[]): Promise<void>;
  setDisabledRelays?(id: string, relays: string[]): Promise<void>;
  insertRelay?(url: string): Promise<void>;
  removeRelay?(url: string): Promise<void>;
  mediaDatagrams?(): boolean;
  close(): Promise<void>;
};

const host = (e: unknown) => new HostError(e instanceof Error ? e.message : String(e));
const call = <A>(f: () => Promise<A>): Effect.Effect<A, HostError> => Effect.tryPromise({ try: f, catch: host });
/// The binding's bytes (a Buffer) as plain ones, not copied.
const view = (b: Uint8Array) => new Uint8Array(b.buffer, b.byteOffset, b.byteLength);

/// `bind` the binding's; `bytes` makes bytes as it takes them (Node's addon: a Buffer).
/// Only the web host exposes relay controls; a native binding may have private methods with those names.
export function wrapIroh(bind: (o: BindOptions) => Promise<BoundEndpoint>, bytes: (b: Uint8Array) => unknown, options: { relayControls?: boolean } = {}): Iroh {
  const out = (b: Uint8Array) => bytes(b) as never;
  const stream = (s: BoundStream): IrohStream => ({
    read: () =>
      call(async () => {
        const b = await s.read();
        return b === null || b === undefined ? null : view(b);
      }),
    write: (b) => call(() => s.write(out(b))),
    finish: () => call(() => s.finish()),
    stopped: () =>
      call(async () => {
        const code = await s.stopped();
        return typeof code === "number" ? code : null;
      }),
    reset: (code) => void Promise.resolve(s.reset?.(code)).catch(() => {}),
    ...(s.receiveMediaDatagrams && { receiveMediaDatagrams: (token: number) => call(() => s.receiveMediaDatagrams!(token)) }),
  });
  const connection = (c: BoundConnection, resolveRelay: (relay: string | null) => string | null): IrohConnection => ({
    remoteId: () => c.remoteId(),
    openBi: () => Effect.map(call(() => c.openBi()), stream),
    acceptBi: () => Effect.orElseSucceed(Effect.map(call(() => c.acceptBi()), (s) => (s === null ? null : stream(s))), () => null),
    openUni: () => Effect.map(call(() => c.openUni()), stream),
    close: (code, reason) => c.close(code, reason),
    closeReason: () => c.closeReason() ?? null,
    closed: () => Effect.promise(() => c.closedInfo()),
    paths: () =>
      c.paths().map((p) => ({ id: p.id, selected: p.selected, relay: resolveRelay(p.relay ?? null), ip: p.ip ?? null, rttMs: p.rttMs ?? null, txPackets: p.txPackets, lostPackets: p.lostPackets })),
    stats: () => c.stats(),
  });
  const endpoint = (e: BoundEndpoint): IrohEndpoint => {
    const accept = e.accept?.bind(e);
    let accessMap: Map<string, string | undefined> | null = null;
    const readRelayStatus = () => {
      const statuses = e.relayStatus();
      accessMap = accessMapOf(statuses);
      return statuses;
    };
    const clearAccess = () => {
      accessMap = null;
    };
    const resolveRelay = (relay: string | null): string | null => {
      if (relay === null) return null;
      const k = relayUrlKey(relay);
      if (accessMap === null || !accessMap.has(k)) readRelayStatus();
      return accessMap!.get(k) ?? relay;
    };
    return {
      id: () => e.id(),
      ...(e.meshUseLeaf && { meshUseLeaf: (value: {scope: string; attachment: IrohLeafAttachment}) => call(() => e.meshUseLeaf!(value)) }),
      ...(e.meshDetachLeaf && { meshDetachLeaf: (value: {scope: string; attachmentId: number[]}) => call(() => e.meshDetachLeaf!(value)) }),
      ...(e.meshConfigure && { meshConfigure: (scope: IrohMeshScope) => call(() => e.meshConfigure!(scope)) }),
      ...(e.meshRemove && { meshRemove: (scope: string) => call(() => e.meshRemove!(scope)) }),
      connect: (addr, alpn, additional, givenUp) =>
        Effect.map(
          // Given up when `givenUp` succeeds or this is interrupted (its answer let go either way).
          Effect.gen(function* () {
            let giveUp = () => {};
            const given = new Promise<void>((resolve) => (giveUp = resolve));
            const told = givenUp === undefined ? null : yield* Effect.forkChild(Effect.andThen(givenUp, Effect.sync(() => giveUp())));
            return yield* call(() => e.connect(addr, out(alpn), additional.map(out), given)).pipe(
              Effect.onInterrupt(() => Effect.sync(() => giveUp())),
              Effect.ensuring(told === null ? Effect.void : Fiber.interrupt(told)),
            );
          }),
          (c) => connection(c, resolveRelay),
        ),
      // Only where the binding takes connections: a host without has no `accept` (iroh.ts).
      ...(accept && {
        accept: () => Effect.orElseSucceed(Effect.map(call(accept), (c) => (c === null ? null : { connection: connection(c, resolveRelay), alpn: view(c.alpn()) })), () => null),
      }),
      addAddr: (addr) => e.addAddr(addr),
      networkChange: () => Effect.ensuring(Effect.promise(() => e.networkChange()), Effect.sync(clearAccess)),
      relayStatus: readRelayStatus,
      ...(e.setRelayEntries && { setRelayEntries: (entries: { entry: string; relay: string }[]) => Effect.ensuring(call(() => e.setRelayEntries!(entries)), Effect.sync(clearAccess)) }),
      ...(options.relayControls && e.setDisabledRelays && { setDisabledRelays: (id: string, relays: string[]) => call(() => e.setDisabledRelays!(id, relays)) }),
      ...(options.relayControls && e.insertRelay && { insertRelay: (url: string) => Effect.ensuring(call(() => e.insertRelay!(url)), Effect.sync(clearAccess)) }),
      ...(options.relayControls && e.removeRelay && { removeRelay: (url: string) => Effect.ensuring(call(() => e.removeRelay!(url)), Effect.sync(clearAccess)) }),
      ...(e.mediaDatagrams && { mediaDatagrams: () => e.mediaDatagrams!() }),
      close: () => Effect.promise(() => e.close()),
    };
  };
  return { bind: (o) => Effect.map(call(() => bind(o)), endpoint) };
}
