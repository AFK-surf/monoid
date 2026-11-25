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
