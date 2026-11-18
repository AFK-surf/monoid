// Only registered global relays subscribe. Each socket retains at most one
// queued frame and one replacement snapshot, independent of reader speed.
import type { MeshRelay } from "./mesh-relay-registry";
import { validKeyHex } from "./grants";
export const watchMessage = (origin: string, body: string) => `mesh-global-watch/v1\0${origin.replace(/\/+$/, "")}\0${body}`;
export function watchRequest(body: unknown, now: number): { node: string; generation: number; at: number } | null {
  if (typeof body !== "string" || body.length > 1024) return null;
  let value: any;
  try { value = JSON.parse(body); } catch { return null; }
  if (!value || !validKeyHex(value.node) || !Number.isSafeInteger(value.generation) || value.generation < 1
    || !Number.isSafeInteger(value.at) || Math.abs(value.at - now) > 60_000) return null;
  return { node: value.node, generation: value.generation, at: value.at };
}
type Listener = { node: string; generation: number; update: (relays: MeshRelay[]) => void };
export class MeshRelayEvents {
  #listeners = new Set<Listener>();
  #seen = new Map<string, number[]>();
  open(node: string, generation: number, at: number, now: number, initial: MeshRelay[]): ReadableStream<Uint8Array> | null {
    const recent = (this.#seen.get(node) ?? []).filter(t => Math.abs(t - now) <= 60_000);
    if (recent.includes(at) || recent.length >= 8 || [...this.#listeners].filter(l => l.node === node).length >= 2 || this.#listeners.size >= 64) return null;
    for (const [key, stamps] of this.#seen) if (stamps.every(t => Math.abs(t - now) > 60_000)) this.#seen.delete(key);
    if (!this.#seen.has(node) && this.#seen.size >= 256) return null;
    this.#seen.set(node, [...recent, at]);
    let pending: Uint8Array | undefined;
    let ending = false;
    let stopped = false;
    let controller: ReadableStreamDefaultController<Uint8Array>;
    let heartbeat: ReturnType<typeof setInterval> | undefined;
    const stop = () => { stopped = true; this.#listeners.delete(listener); clearInterval(heartbeat); };
    const flush = () => {
      if (stopped || !pending || (controller.desiredSize ?? 0) <= 0) return;
      const frame = pending; pending = undefined;
      const close = ending;
      if (close) stop();
      try { controller.enqueue(frame); if (close) controller.close(); }
      catch { stop(); }
    };
    const listener: Listener = { node, generation, update: relays => {
      if (stopped) return;
      pending = new TextEncoder().encode(JSON.stringify({ relays }) + "\n");
      ending = !relays.some(r => r.node === node && r.generation === generation);
      flush();
    } };
    return new ReadableStream<Uint8Array>({
      start: value => {
        controller = value; this.#listeners.add(listener); listener.update(initial);
        heartbeat = setInterval(() => { if (!pending && !stopped) { pending = new TextEncoder().encode('{"heartbeat":true}\n'); flush(); } }, 20_000); // timer: keep the stream alive without reading the registry again.
      },
      pull: flush,
      cancel: stop,
    }, { highWaterMark: 1 });
  }
  changed(relays: MeshRelay[]): void { for (const listener of this.#listeners) listener.update(relays); }
}
