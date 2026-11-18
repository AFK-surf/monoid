// The station's native mesh addon (native/mesh §3): what it offers besides the endpoint (endpoint.ts: iroh), which is
// the image codecs of the thumbnails and the rest below, and where it is. A release has it beside the station's code
// (mesh.node); a checkout has it where cargo built it; STILLFAIL_MESH_NATIVE says otherwise.
import { log } from "../ops/log.ts";
import { fileURLToPath } from "node:url";
import { type Bind, type Endpoint, type Endpoints, type MeshScopeView, loadAddon } from "./endpoint.ts";

export type { Addr, Connection, Endpoint, Stream, Traffic } from "./endpoint.ts";

export type Mesh = Endpoints & {
  /// thumbs.rs `thumbnail` (native/mesh/src/thumbs.rs): the image's thumbnail in `dir`, made if not there yet; null when
  /// the image is shown itself.
  thumbnail(image: string, dir: string): Promise<{ path: string; type: string } | null>;
  /// thumbs.rs `preview`: the image's preview in `dir` (at most 2048 across), made if not there yet; null when the image
  /// is shown itself (300 KiB or less, or no copy at half its bytes or less).
  preview(image: string, dir: string): Promise<{ path: string; type: string } | null>;
  /// thumbs.rs `keep` for one image: its ThumbHash (base64) and its size as seen; with `dir`, its thumbnail made after
  /// (not waited for) when it is over 24 KiB. Null when it is not readable as an image.
  thumbhash(image: string, dir?: string | null): Promise<{ hash: string; width: number; height: number } | null>;
  /// archive.rs `file_lock` (native/mesh/src/local.rs): an exclusive flock on the file, across processes.
  fileLock(path: string): Promise<{ release(): void }>;
  /// local_links.rs `prepare`: the text with local links made attachments, and the attachments' paths; throws its refusal.
  prepareLocalLinks(text: string, paths: string[], workspace: string): { text: string; paths: string[] };
  /// usage.rs `process_usage`: what each pid has used so far, null where not read. Absent from an addon from before.
  /// local.rs `peer_process`: the process at the other end of a connected Unix socket (its pid; on macOS its audit token,
  /// hex), null when the system does not say. Absent from an addon from before.
  peerProcess?(fd: number): { pid: number; auditToken: string | null } | null;
  /// verify.rs `verify`: whether the signature is the key's over the message, by libcrux (formally verified). Absent from
  /// an addon from before.
  verify?(alg: "Ed25519" | "ES256" | "ES256-der", key: Buffer, signature: Buffer, message: Buffer): boolean;
  processUsage?(pids: number[]): ({ cpuNs: number; footprint: number; wakeups: number; energyNj: number; diskRead?: number; diskWritten?: number } | null)[];
  /// Where the endpoint is the front's (mesh/front.ts `withFront`): whether this process is linked to it now, or is
  /// linking to it again. Absent where this process binds the endpoint itself.
  frontLink?(): "ok" | "reconnecting";
  /// Whether a relay holds an endpoint bound here inactive for another of the same id (another station on this
  /// station's key: the relays carry each peer's packets to the other one only, ops/health.ts `conflict`).
  relayConflict?(): boolean;
};

/// Whether any of `endpoints` is held inactive by a relay for another of its id.
export function relaysConflict(endpoints: Iterable<Endpoint>): boolean {
  for (const e of endpoints) if (e.relayStatus?.().some((r) => r.conflict === true)) return true;
  return false;
}

/// The addon binding the endpoints itself (no front): what it bound kept until closed, for `relayConflict`.
export function withRelays(mesh: Mesh): Mesh {
  const bound = new Set<Endpoint>();
  return {
    ...mesh,
    bind: async (options: Bind) => {
      const endpoint = await mesh.bind(options);
      bound.add(endpoint);
      const native = endpoint as Endpoint & {
        meshSubscribe?(id: number, listener: (error: Error | null, scopes: MeshScopeView[]) => void): Promise<void>;
        meshUnsubscribe?(id: number): void;
      };
      if (native.meshSubscribe && native.meshUnsubscribe) {
        let serial = 0;
        endpoint.meshListen = (listener) => {
          const id = ++serial;
          let active = true;
          void native.meshSubscribe!(id, (error, scopes) => { if (active && !error) listener(scopes); }).then(
            () => { if (!active) native.meshUnsubscribe!(id); },
            (error) => { active = false; log.warn("mesh", "native scope subscription failed", { error: String(error) }); },
          );
          return () => { active = false; native.meshUnsubscribe!(id); };
        };
      }
      const close = endpoint.close.bind(endpoint);
      endpoint.close = () => {
        bound.delete(endpoint);
        return close();
      };
      return endpoint;
    },
    relayConflict: () => relaysConflict(bound),
  };
}

/// Loaded once: the mesh (services.ts) and the thumbnails (drive/thumbs.ts) share it.
let loaded: Mesh | undefined;

/// A fixed UDP address lets an operator admit LAN connections through an egress firewall. The native bind rejects
/// invalid or occupied addresses; never fall back to a random port when an address was explicitly configured.
/// `STILLFAIL_MESH_DSCP` marks every iroh packet of the station with that DSCP, its relays' connections too, for a
/// router that sends them their own way (docs/station-lan-firewall.md); the native bind rejects one outside 1 to 63,
/// and anything not a number is rejected here: never a station silently unmarked.
export async function bindStation(mesh: Endpoints, options: Bind, env: NodeJS.ProcessEnv = process.env): Promise<Endpoint> {
  const dscp = env.STILLFAIL_MESH_DSCP;
  if (dscp !== undefined && !/^[0-9]{1,3}$/.test(dscp)) throw new Error(`STILLFAIL_MESH_DSCP must be a DSCP, 1 to 63, not ${JSON.stringify(dscp)}`);
  return mesh.bind({ ...options, bindAddr: env.STILLFAIL_MESH_BIND_ADDR, ...(dscp !== undefined ? { dscp: Number(dscp) } : {}) });
}

export function loadMesh(): Mesh {
  if (loaded !== undefined) return loaded;
  const candidates = [
    process.env.STILLFAIL_MESH_NATIVE,
    fileURLToPath(new URL("./mesh.node", import.meta.url)),
    fileURLToPath(new URL("../../native/mesh/target/release/libstillfail_mesh.dylib", import.meta.url)),
    fileURLToPath(new URL("../../native/mesh/target/release/libstillfail_mesh.so", import.meta.url)),
  ];
  loaded = loadAddon<Mesh>(candidates);
  return loaded;
}
