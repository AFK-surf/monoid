// The browser fixture uses the production mesh, leaf manager, bindings, and live clock.
import "../src/i18n.ts";
import { Effect, Schedule } from "effect";
import { wrapIroh, type BoundEndpoint } from "../src/iroh-bindings.ts";
import type { BaseHost } from "../src/host-of.ts";
import type { BindOptions } from "../src/iroh.ts";
import { Mesh, type Link } from "../src/mesh.ts";
import { Runner } from "../src/runtime.ts";
import { LeafLinks } from "../src/station/mesh-leaf.ts";
import { Tracer } from "../src/trace.ts";
import { MeshWire } from "../src/station/mesh-wire.ts";
import { StationAddr } from "../src/station/addr.ts";
import { Status } from "../src/status.ts";
import { Wakes } from "../src/wake.ts";

const worker = globalThis as unknown as {
  onmessage: ((event: { data: { id: number; method: string; args: any } }) => void) | null;
  postMessage(value: unknown): void;
};
const runner = new Runner();
const kept = new Map<string, Uint8Array>();
const records: { at: number; text: string }[] = [];
const closures: { at: number; address: string; reason: unknown }[] = [];
const host: BaseHost = {
  recorder: { on: () => true, line: text => { records.push({ at: Date.now(), text }); } },
  storageGet: key => Effect.sync(() => kept.get(key) ?? null),
  storageSet: (key, value) => Effect.sync(() => { kept.set(key, value); }),
  nowMs: () => Date.now(), monotonicMs: () => performance.now(),
  utcOffsetMin: at => -new Date(at).getTimezoneOffset(),
  randomBytes: bytes => { bytes.set(crypto.getRandomValues(new Uint8Array(bytes.length))); },
};
const alpn = new TextEncoder().encode("relay-load-side/1");
const head = (path: string) => ({ method: "GET", path, headers: [["stillfail-build", "0.1.999999"]] as [string, string][] });
const links = new Map<string, { link: Link; credential: string }>();
const bound: BoundEndpoint[] = [];
const eventsByAddress: Record<string, { opens: number; chunks: number; ends: number }> = {};
const counts = { configured: 0, removed: 0, attached: 0, eventOpens: 0, eventChunks: 0, eventEnds: 0, leafLines: 0 };
const identities: { kind: string; id: string; scope?: string }[] = [];
const errors: string[] = [];
runner.onDefect = e => { errors.push(String(e)); };
let mesh: Mesh;
const credentials = (credential: string) => () => Effect.succeed({ credential, also: null });

async function invoke(method: string, args: any): Promise<unknown> {
  if (method === "init") {
    const url = "/wasm/stillfail_iroh_wasm.js";
    const wasm = await import(url);
    await wasm.default();
    const iroh = wrapIroh(async (options: BindOptions) => {
      const endpoint: BoundEndpoint = await wasm.bind(options);
      bound.push(endpoint);
      identities.push({ kind: bound.length === 1 ? "main" : "pinned", id: endpoint.id() });
      const configure = endpoint.meshConfigure!.bind(endpoint);
      endpoint.meshConfigure = async config => {
        const descriptor = await configure(config);
        counts.configured++;
        const id = descriptor.binding.neighbor.map(b => b.toString(16).padStart(2, "0")).join("");
        if (!identities.some(i => i.id === id)) identities.push({ kind: "leaf", id, scope: config.scope });
        return descriptor;
      };
      const remove = endpoint.meshRemove!.bind(endpoint);
      endpoint.meshRemove = async scope => { await remove(scope); counts.removed++; };
      const attach = endpoint.meshUseLeaf!.bind(endpoint);
      endpoint.meshUseLeaf = async value => { await attach(value); counts.attached++; };
      return endpoint;
    }, bytes => bytes, { relayControls: true });
    const leaf = new LeafLinks();
    mesh = await runner.run(Mesh.make({ host, runner, tracer: new Tracer(host, runner, 0), iroh,
      wakes: new Wakes(), alpn, says: { protocol: 2 }, relayOnly: true, lookup: false,
      ...(typeof args.hotRelays === "number" && args.hotRelays > 0 ? { hotRelays: args.hotRelays } : {}),
      prepare: leaf.prepare,
      linked: (address, link, endpoint) => {
        runner.fork(Effect.map(link.conn.closed(), reason => { closures.push({ at: Date.now(), address, reason }); }));
        // Observe the policy stream without changing its contents or scheduling.
        const request = link.request.bind(link);
        link.request = (...input) => Effect.map(request(...input), reply => {
          if (input[0].path.endsWith("/mesh/leaf/events")) {
            return { ...reply, body: { take: Effect.tap(reply.body.take, chunk => Effect.sync(() => {
              if (chunk) for (const byte of chunk) if (byte === 10) counts.leafLines++;
            })) } };
          }
          return reply;
        });
        return leaf.linked(address, link, endpoint);
      },
    }, args.relays, args.entries, args.targets));
    return { id: bound[0].id() };
  }
  if (method === "connect") {
    mesh.addAddr({ id: args.station, relays: args.relays });
    const address = `${args.workspace}/${args.station}`;
    const link = await runner.run(mesh.link(address, credentials(args.credential)));
    links.set(address, { link, credential: args.credential });
    eventsByAddress[address] = { opens: 0, chunks: 0, ends: 0 };
    runner.fork(Effect.gen(function* () {
      for (;;) {
        const live = yield* mesh.link(address, credentials(args.credential));
        const reply = yield* live.request(head("/admin/api/relay-load/events"), new Uint8Array());
        if (reply.status !== 200) throw Error(`events: ${reply.status}`);
        counts.eventOpens++; eventsByAddress[address].opens++;
        try {
          for (;;) { const chunk = yield* reply.body.take; if (chunk === null) break; counts.eventChunks++; eventsByAddress[address].chunks++; }
          counts.eventEnds++; eventsByAddress[address].ends++;
        } finally { reply.cancel(); }
      }
    }).pipe(Effect.retry({ schedule: Schedule.spaced("100 millis") })));
    return { address };
  }
  if (method === "request") {
    const item = links.get(args.address)!;
    const link = await runner.run(mesh.link(args.address, credentials(item.credential)));
    const reply = await runner.run(link.request(head("/admin/api/relay-load/ok"), new Uint8Array()));
    try { while (await runner.run(reply.body.take) !== null) { /* Drain the application reply. */ } }
    finally { reply.cancel(); }
    return { status: reply.status, sameConnection: link.conn === item.link.conn, closed: item.link.closed() };
  }
  if (method === "wire-request") {
    const item = links.get(args.address)!;
    const status = new Status(host as any, runner);
    const wire = new MeshWire({ mesh: () => Effect.succeed(mesh), meshNow: () => mesh,
      credentials: () => credentials(item.credential), relays: () => [], status: () => status });
    return await runner.run(Effect.scoped(Effect.gen(function* () {
      const reply = yield* wire.request(StationAddr.parse(args.address), head("/admin/api/relay-load/ok"), new Uint8Array());
      while ((yield* reply.body.take) !== null) { /* Fully consume before the request scope ends. */ }
      return { status: reply.status, sameConnection: mesh.current(args.address)?.conn === item.link.conn, closed: item.link.closed() };
    })).pipe(Effect.timeout("30 seconds")));
  }
  if (method === "snapshot") return { eventsByAddress: structuredClone(eventsByAddress), at: Date.now(), records: [...records], closures: [...closures], counts: { ...counts }, identities, errors,
    relays: bound[0].relayStatus(),
    links: [...links].map(([address, item]) => ({ address, originalClosed: item.link.closed(), originalCloseReason: item.link.conn.closeReason(), originalPaths: item.link.conn.paths(),
      sameConnection: mesh.current(address)?.conn === item.link.conn,
      paths: mesh.current(address)?.conn.paths() ?? [], via: mesh.current(address)?.via() ?? null })),
  };
  if (method === "endpoint") {
    const endpoint = bound[0] as BoundEndpoint & Record<string, (...args: any[]) => unknown>;
    if (typeof endpoint[args.method] !== "function") throw Error(`missing endpoint method: ${args.method}`);
    await endpoint[args.method](...args.values);
    return null;
  }
  if (method === "close") { await runner.run(mesh.close()); runner.shutdown(); return null; }
  throw Error(`unknown fixture command: ${method}`);
}
worker.onmessage = ({ data }) => {
  void invoke(data.method, data.args).then(
    result => worker.postMessage({ id: data.id, result }),
    error => worker.postMessage({ id: data.id, error: String(error?.stack ?? error) }),
  );
};
worker.postMessage({ ready: true });
