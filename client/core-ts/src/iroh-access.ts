/// Normalize a relay URL for access-map lookups.
export function relayUrlKey(url: string): string {
  try { return new URL(url).href; } catch { return url; }
}

/// Build a normalized relay URL → access URL map from `relayStatus()`.
export function accessMapOf(statuses: { url: string; access?: string }[]): Map<string, string | undefined> {
  const map = new Map<string, string | undefined>();
  for (const s of statuses) map.set(relayUrlKey(s.url), s.access);
  return map;
}

/// The path's relay is its logical server; show the address actually carrying that server's connection.
export function accessOf(relay: string | null, statuses: { url: string; access?: string }[] | Map<string, string | undefined>): string | null {
  if (relay === null) return null;
  const k = relayUrlKey(relay);
  if (statuses instanceof Map) return statuses.get(k) ?? relay;
  return statuses.find((s) => relayUrlKey(s.url) === k)?.access ?? relay;
}

/// How long a read of `relayStatus()` names each relay's access URL. iroh picks a quicker entrance in the background
/// after `setRelayEntries` returns, so a map read before it switches is stale until read again; read on demand when
/// older than this (no timer), at most once per `resolveAll`.
export const ACCESS_CACHE_MS = 1_000;

export type AccessCache<S> = {
  /// Read `relayStatus()` now, refreshing the map.
  readStatus: () => S[];
  /// Forget the map (relays or network changed): the next resolve reads again.
  clear: () => void;
  /// Each path's relay as its access URL (`null` stays `null`), reading `relayStatus()` at most once.
  resolveAll: (relays: readonly (string | null | undefined)[]) => (string | null)[];
};

/// A per-endpoint cache of logical relay URL → access URL, so `conn.paths()` does not read `relayStatus()` across
/// the FFI on every call, yet follows iroh's own later switch of entrance within `ttlMs`.
export function createAccessCache<S extends { url: string; access?: string }>(
  read: () => S[],
  options: { ttlMs?: number; now?: () => number } = {},
): AccessCache<S> {
  const ttlMs = options.ttlMs ?? ACCESS_CACHE_MS;
  const now = options.now ?? Date.now;
  let map: Map<string, string | undefined> | null = null;
  let at = -Infinity;
  const readStatus = (): S[] => {
    const statuses = read() ?? [];
    map = accessMapOf(statuses);
    at = now();
    return statuses;
  };
  return {
    readStatus,
    clear: () => {
      map = null;
      at = -Infinity;
    },
    resolveAll: (relays) => {
      if (!relays.some((r) => r != null)) return relays.map(() => null);
      let fresh = false;
      // A wall clock set back (NTP) gives a negative age: read again rather than keep the map until it catches up.
      const age = now() - at;
      if (map === null || age < 0 || age >= ttlMs) {
        readStatus();
        fresh = true;
      }
      if (!fresh && relays.some((r) => r != null && !map!.has(relayUrlKey(r)))) readStatus();
      const m = map!;
      return relays.map((r) => (r == null ? null : (m.get(relayUrlKey(r)) ?? r)));
    },
  };
}
