// A workspace relay keeps one authenticated control stream to its issuer. Changes
// coalesce while a slow receiver consumes a snapshot; no unbounded event queue.
import type { Connection, Stream } from "./endpoint.ts";
import { Reader, writeLine } from "./wire.ts";
import { wall } from "../ops/fibers.ts";
import type { ScopeSync } from "./scope-sync.ts";
export async function watchRelay(sync: ScopeSync, scope: string, node: string, first: any, stream: Stream, conn: Connection, reader: Reader): Promise<void> {
  await sync.relayAnnouncement(scope, node, first);
  let dirty = true, ended = false, wake: (() => void) | undefined;
  const off = sync.listen((changed) => {
    if (changed !== scope || ended) return;
    // Revocation closes the transport immediately, even if a snapshot write waits.
    try { sync.relayView(scope, node); }
    catch { conn.close(1, "relay registration removed"); }
    dirty = true; wake?.();
  });
  const closed = conn.closed().then(() => { ended = true; wake?.(); });
  const write = async (frame: unknown) => wall.within(15_000, writeLine(stream, frame), "relay directory consumer stalled");
  const sending = async () => {
    let revision = 0;
    while (!ended) {
      if (!dirty) { await new Promise<void>((resolve) => { wake = resolve; }); wake = undefined; continue; }
      dirty = false;
      const { records, ...policy } = sync.relayView(scope, node);
      const version = ++revision;
      await write({ begin: version, ...policy, count: records.length });
      for (const record of records) await write({ record });
      await write({ end: version });
    }
  };
  const receiving = async () => {
    while (!ended) {
      const update = await reader.line();
      if (!update || typeof update !== "object" || !update.announcement) throw new Error("invalid relay address update");
      await sync.relayAnnouncement(scope, node, update.announcement);
    }
  };
  try { await Promise.race([sending(), receiving(), closed]); }
  finally { ended = true; wake?.(); off(); conn.close(0, "relay directory ended"); }
}
