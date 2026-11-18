/// The path's relay is its logical server; show the address actually carrying that server's connection.
export function accessOf(relay: string | null, statuses: { url: string; access?: string }[]): string | null {
  if (relay === null) return null;
  const key = (url: string) => {
    try { return new URL(url).href; } catch { return url; }
  };
  return statuses.find((s) => key(s.url) === key(relay))?.access ?? relay;
}
