// Bounded anti-entropy on an already authenticated workspace connection.
// No topology or link quality is carried; the caller retries only failed sends.
import { type Announcement } from "./announcements.ts";
import type { ScopeDirectory } from "./scope-directory.ts";
export type Exchange = { versions: Record<string, number>; records: Announcement[] };
export type ExchangeRequest = { give?: Announcement[]; want?: string[] };
const key = /^[0-9a-f]{64}$/;
function response(raw: any): Exchange {
  if (!raw || !raw.versions || typeof raw.versions !== "object" || Array.isArray(raw.versions)
      || Object.keys(raw.versions).length > 256 || !Array.isArray(raw.records) || raw.records.length > 16) throw new Error("invalid mesh exchange reply");
  for (const [node, revision] of Object.entries(raw.versions)) if (!key.test(node) || !Number.isSafeInteger(revision) || Number(revision) < 1) throw new Error("invalid mesh revision");
  return raw;
}
function revisions(records: Announcement[], field: "revision" | "generation"): Map<string, number> {
  // These records have already been verified by the directory that kept them.
  return new Map(records.map((r) => { const value = JSON.parse(r.body); return [value.node, value[field]]; }));
}
export function exchangeScope(directory: ScopeDirectory, scope: string, send: (request: ExchangeRequest) => Promise<unknown>): Promise<void> {
  return exchangeSignedRecords(() => directory.records(scope), (records) => directory.take(scope, records), send, "revision", (id) => directory.admits(scope, id));
}
export async function exchangeSignedRecords(records: () => Announcement[], take: (records: Announcement[]) => Promise<void>, send: (request: ExchangeRequest) => Promise<unknown>, field: "revision" | "generation", admits: (id: string) => boolean = () => true): Promise<void> {
  let theirs = response(await send({}));
  if (theirs.records.length) throw new Error("unsolicited mesh records");
  const ours = revisions(records(), field);
  // A node the peer keeps but this station's roster does not have yet (their rosters briefly differ) is not asked for:
  // `take` would refuse the whole page for it.
  const want = Object.keys(theirs.versions).filter((id) => admits(id) && (ours.get(id) ?? 0) < theirs.versions[id]!);
  for (let i = 0; i < want.length; i += 16) {
    const requested = want.slice(i, i + 16);
    const page = response(await send({ want: requested }));
    for (const record of page.records) {
      const value = JSON.parse(record.body);
      if (!requested.includes(value.node)) throw new Error("unsolicited mesh identity");
    }
    await take(page.records);
    theirs = page;
  }
  const give = records().filter((record) => {
    const value = JSON.parse(record.body);
    return (theirs.versions[value.node] ?? 0) < value[field];
  });
  for (let i = 0; i < give.length; i += 16) {
    const reply = response(await send({ give: give.slice(i, i + 16) }));
    if (reply.records.length) throw new Error("unsolicited mesh records");
  }
}
