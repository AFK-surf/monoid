// Thin Node adapter for the MoonBit `stillfail-reader-harness --builder harness-leaf` process.
// Bridges real native Rust iroh endpoints/connections/streams to MoonBit `@cloud_lock` + `@gate.serve` + `@mesh_scopes`.
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { harnessBinary } from "../test/mb-harness.ts";

export interface SignedRecordInput {
  descriptor: unknown;
  secretKey: Buffer | Uint8Array | string;
}

export interface LeafStationOptions {
  data: string;
  state: Record<string, unknown>;
  stationId: string;
  secretKey: Buffer | Uint8Array | string;
  records: Record<string, SignedRecordInput[]>;
  node: {
    meshAttachLeaf(conn: any, req: unknown): Promise<unknown>;
    meshDetachLeaf(req: unknown): Promise<unknown>;
  };
  onLeafView?: (workspace: string) => void;
  watchHeaders?: string[];
  onWatchedHead?: (head: any) => void;
  customStreams?: Record<string, (ctx: { head: any; stream: BridgedNodeStream }) => Promise<void>>;
}

export interface BridgedNodeStream {
  write(bytes: Buffer | Uint8Array): Promise<void>;
  finish(): Promise<void>;
  reset(code: number): Promise<void>;
  stopped(): Promise<number | null>;
}

export interface LeafStationHandle {
  handle: number;
  updateRecords(scope: string, records: SignedRecordInput[]): Promise<void>;
  serveConnection(conn: any): Promise<void>;
  close(): Promise<void>;
}

export interface LeafHarness {
  workspaceScope(origin: string, workspace: string): Promise<string>;
  createStation(opts: LeafStationOptions): Promise<LeafStationHandle>;
  close(): Promise<void>;
}

export async function writeLine(stream: { write(bytes: Buffer | Uint8Array): Promise<void> }, value: unknown): Promise<void> {
  await stream.write(Buffer.from(`${JSON.stringify(value)}\n`));
}

function toHex(key: Buffer | Uint8Array | string): string {
  return typeof key === "string" ? key : Buffer.from(key).toString("hex");
}

function encodeRecords(records: SignedRecordInput[]): { descriptor: unknown; secretKey: string }[] {
  return records.map((r) => ({ descriptor: r.descriptor, secretKey: toHex(r.secretKey) }));
}

export function startLeafHarness(): LeafHarness {
  const binary = harnessBinary();
  const shellDir = mkdtempSync(join(tmpdir(), "core-mb-leaf-harness-"));
  const child = spawn(binary, ["--builder", "harness-leaf", "--shell-dir", shellDir], {
    stdio: ["pipe", "pipe", "pipe"],
  });

  let nextId = 1;
  let nextConnId = 1;
  let nextStreamId = 1;
  let closed = false;
  let stderr = "";

  const pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  const stations = new Map<number, LeafStationOptions>();
  const conns = new Map<number, { conn: any; resolve: () => void; reject: (e: Error) => void }>();
  const streams = new Map<number, { raw: any; wrapped: BridgedNodeStream }>();

  const send = (obj: Record<string, unknown>) => {
    if (closed || child.stdin.destroyed) return;
    child.stdin.write(`${JSON.stringify(obj)}\n`);
  };

  const failAll = (reason: string) => {
    const err = new Error(stderr.trim() ? `${reason}\nstderr:\n${stderr.trim()}` : reason);
    for (const p of pending.values()) p.reject(err);
    pending.clear();
    for (const c of conns.values()) c.reject(err);
    conns.clear();
  };

  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk: string) => {
    if (stderr.length < 32_768) stderr += chunk;
  });

  const handleCallback = async (msg: any) => {
    const cb = msg.cb as number;
    try {
      let ok: unknown = true;
      switch (msg.kind) {
        case "leaf.attach": {
          const st = stations.get(msg.station);
          const c = conns.get(msg.conn);
          if (!st) throw new Error(`no station ${msg.station}`);
          if (!c) throw new Error(`no conn ${msg.conn}`);
          ok = await st.node.meshAttachLeaf(c.conn, msg.req);
          break;
        }
        case "leaf.detach": {
          const st = stations.get(msg.station);
          if (!st) throw new Error(`no station ${msg.station}`);
          await st.node.meshDetachLeaf(msg.req);
          break;
        }
        case "stream.write": {
          const s = streams.get(msg.stream);
          if (!s) throw new Error(`no stream ${msg.stream}`);
          await s.raw.write(Buffer.from(msg.b64, "base64"));
          break;
        }
        case "stream.finish": {
          const s = streams.get(msg.stream);
          if (s) await s.raw.finish();
          break;
        }
        case "stream.reset": {
          const s = streams.get(msg.stream);
          if (s) await s.raw.reset(msg.code ?? 0);
          break;
        }
        case "stream.custom": {
          const st = stations.get(msg.station);
          const s = streams.get(msg.stream);
          const path = msg.head?.path;
          const handler = st?.customStreams?.[path];
          if (!handler || !s) throw new Error(`no custom stream handler for ${path}`);
          await handler({ head: msg.head, stream: s.wrapped });
          break;
        }
        default:
          throw new Error(`unknown callback kind ${msg.kind}`);
      }
      send({ reply: cb, ok });
    } catch (e) {
      send({ reply: cb, error: e instanceof Error ? e.message : String(e) });
    }
  };

  const rl = createInterface({ input: child.stdout, crlfDelay: Infinity });
  rl.on("line", (line) => {
    if (!line) return;
    let msg: any;
    try {
      msg = JSON.parse(line);
    } catch (e) {
      failAll(`harness-leaf emitted non-JSON line: ${line} (${e})`);
      return;
    }
    if (typeof msg.cb === "number") {
      void handleCallback(msg);
      return;
    }
    if (typeof msg.event === "string") {
      switch (msg.event) {
        case "conn.close": {
          const c = conns.get(msg.conn);
          if (c) c.conn.close(msg.code ?? 0, msg.reason ?? "");
          break;
        }
        case "conn.ended": {
          const c = conns.get(msg.conn);
          if (c) {
            conns.delete(msg.conn);
            if (typeof msg.error === "string") c.reject(new Error(msg.error));
            else c.resolve();
          }
          break;
        }
        case "leaf.view": {
          stations.get(msg.station)?.onLeafView?.(msg.workspace);
          break;
        }
        case "stream.head": {
          stations.get(msg.station)?.onWatchedHead?.(msg.head);
          break;
        }
      }
      return;
    }
    if (typeof msg.id === "number") {
      const slot = pending.get(msg.id);
      if (!slot) return;
      pending.delete(msg.id);
      if (typeof msg.error === "string") slot.reject(new Error(msg.error));
      else slot.resolve(msg.ok);
    }
  });

  const exitPromise = new Promise<void>((resolve) => {
    child.on("error", (err) => {
      failAll(`harness-leaf spawn error: ${err.message}`);
      resolve();
    });
    child.on("close", (code, signal) => {
      if (pending.size > 0 || conns.size > 0) {
        failAll(`harness-leaf exited unexpectedly (code=${code}, signal=${signal})`);
      }
      resolve();
    });
  });

  const call = <T = any>(op: string, params: Record<string, unknown> = {}): Promise<T> => {
    if (closed) return Promise.reject(new Error("harness-leaf already closed"));
    if (child.exitCode !== null || child.signalCode !== null) {
      return Promise.reject(
        new Error(`harness-leaf already exited (code=${child.exitCode}, signal=${child.signalCode})${stderr.trim() ? `\nstderr:\n${stderr.trim()}` : ""}`),
      );
    }
    const id = nextId++;
    return new Promise<T>((resolve, reject) => {
      pending.set(id, { resolve, reject });
      child.stdin.write(`${JSON.stringify({ ...params, id, op })}\n`, (err) => {
        if (err) {
          pending.delete(id);
          reject(err);
        }
      });
    });
  };

  return {
    workspaceScope(origin: string, workspace: string): Promise<string> {
      return call<string>("workspaceScope", { origin, workspace });
    },
    async createStation(opts: LeafStationOptions): Promise<LeafStationHandle> {
      const encodedRecords: Record<string, { descriptor: unknown; secretKey: string }[]> = {};
      for (const [scope, list] of Object.entries(opts.records)) {
        encodedRecords[scope] = encodeRecords(list);
      }
      const { handle } = await call<{ handle: number }>("createStation", {
        data: opts.data,
        state: opts.state,
        stationId: opts.stationId,
        secretKey: toHex(opts.secretKey),
        records: encodedRecords,
        customPaths: opts.customStreams ? Object.keys(opts.customStreams) : [],
        watchHeaders: opts.watchHeaders ?? [],
      });
      stations.set(handle, opts);

      return {
        handle,
        async updateRecords(scope: string, records: SignedRecordInput[]): Promise<void> {
          await call("updateRecords", { handle, scope, records: encodeRecords(records) });
        },
        serveConnection(conn: any): Promise<void> {
          const ch = nextConnId++;
          const done = new Promise<void>((resolve, reject) => {
            conns.set(ch, { conn, resolve, reject });
          });
          send({ event: "conn.open", station: handle, conn: ch, remoteId: conn.remoteId() });

          void Promise.resolve(conn.closed()).then(
            (reason: unknown) => send({ event: "conn.closed", conn: ch, reason: String(reason ?? "") }),
            () => send({ event: "conn.closed", conn: ch, reason: "closed" }),
          );

          void (async () => {
            try {
              for (;;) {
                const raw = await conn.acceptBi();
                if (!raw) break;
                const sth = nextStreamId++;
                const stoppedPromise: Promise<number | null> = Promise.resolve(raw.stopped()).then(
                  (c: unknown) => (typeof c === "number" ? c : null),
                  () => null,
                );
                const wrapped: BridgedNodeStream = {
                  write: (bytes) => raw.write(bytes),
                  finish: () => raw.finish(),
                  reset: (code) => raw.reset(code),
                  stopped: () => stoppedPromise,
                };
                streams.set(sth, { raw, wrapped });
                send({ event: "stream.open", conn: ch, stream: sth });

                void (async () => {
                  try {
                    for (;;) {
                      const chunk = await raw.read();
                      if (chunk === null) {
                        send({ event: "stream.eof", stream: sth });
                        break;
                      }
                      send({ event: "stream.data", stream: sth, b64: Buffer.from(chunk).toString("base64") });
                    }
                  } catch {
                    send({ event: "stream.eof", stream: sth });
                  }
                })();

                void stoppedPromise.then((code) => {
                  send({ event: "stream.stopped", stream: sth, code });
                  streams.delete(sth);
                });
              }
            } catch {
              // connection closed
            } finally {
              send({ event: "conn.closed", conn: ch, reason: "accept ended" });
            }
          })();

          return done;
        },
        async close(): Promise<void> {
          stations.delete(handle);
          if (!closed) {
            await call("closeStation", { handle }).catch(() => {});
          }
        },
      };
    },
    async close(): Promise<void> {
      if (closed) return;
      closed = true;
      failAll("harness-leaf closed");
      try {
        rl.close();
        if (!child.stdin.destroyed) child.stdin.end();
        await exitPromise;
      } finally {
        rmSync(shellDir, { recursive: true, force: true });
      }
    },
  };
}
