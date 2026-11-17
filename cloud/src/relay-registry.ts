// The cloud's list of relays (relays.ts), kept by the Directory (directory.ts `relayEnrolled` and the rest) and told to
// every station in its state frame and every device in its `/v1/me` as it changes: what a deploy's config used to say
// (RELAY_URLS and the rest), which the Directory took as its list once (2026-11-17). Its operator keeps it, on
// the console or with ADMIN_TOKEN (api.ts `relayAdmin`): a relay put on it, a name changed, one taken off.
//
// A relay of another's is never put on it by deploying one (the user, 2026-11-17): only the operator puts one, or a
// relay holding a token the operator made for it (`relay_tokens`, a day, used once, naming what the relay is called and
// maybe its URL), which it gives `POST /v1/relays/enroll` from its machine (relay-enroll.sh). It is given a secret
// of its own then, kept here as its digest, which its counters come with (relay-load.sh, relay-load.ts); one listed
// with none (as the config listed them) is believed by the address its counters come from, as before. The cloud does
// not reach a relay to see that it answers (a Worker reaches no bare address, nor most ports): a device and a station
// measure each relay and pass over one that does not answer (client/core-ts mesh.ts), and the console shows one whose
// counters stopped coming. Who may carry packets through a relay is not asked: they are end to end encrypted, and a
// relay that asked the cloud would stop carrying them while the cloud is down.
import type { Listed, Relays } from "./relays";
import { relayUrl, relayUrls, sameUrl } from "./relays";

export const RELAY_TABLES = `
  CREATE TABLE IF NOT EXISTS relays (url TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', target TEXT, secret_hash TEXT, added_at INTEGER NOT NULL, added_by TEXT NOT NULL DEFAULT '');
  CREATE TABLE IF NOT EXISTS relay_tokens (token_hash TEXT PRIMARY KEY, name TEXT NOT NULL, url TEXT, target TEXT, made_by TEXT NOT NULL, expires_at INTEGER NOT NULL);
`;

/** At most this many on the list: every station's state frame and every `/v1/me` carries it whole. */
export const RELAYS_MOST = 32;
/** How long a token made for a relay is good for. */
export const RELAY_TOKEN_TTL_SEC = 86_400;
/** At most this long a name. */
const NAME_MOST = 40;

/** A relay on the list as the console shows it: when it was put there and by whom (an email, `admin-token` by ADMIN_TOKEN, `config` for one the
 * deploy's config listed, `token` for one that came with a token), and whether it has a secret of its own. */
export type RelayListed = Listed & { added_at: number; added_by: string; enrolled: boolean };
/** What the operator says of a relay to put on the list, or of a token to make for one. */
export type RelayTokenInput = { name?: unknown; url?: unknown; target?: unknown };

const nameOf = (raw: unknown): string | null => (raw === undefined || raw === null ? "" : typeof raw === "string" && raw.trim().length <= NAME_MOST ? raw.trim() : null);

/**
 * A relay to put on the list as `input` says: its URL as one is kept, its name, and (an entry) the relay of the list it
 * is a way into; or why it cannot be (`invalid_relay`, `invalid_name`, `invalid_target`, `too_many_relays`). A URL on
 * the list already is put anew (its name, what it is a way into); the cloud's own relay only named.
 */
export function relayPut(input: RelayTokenInput, r: Relays, insecure: boolean): Listed | string {
  const url = relayUrl(input.url, insecure);
  if (url === null) return "invalid_relay";
  const name = nameOf(input.name);
  if (name === null) return "invalid_name";
  let target: string | null = null;
  if (input.target !== undefined && input.target !== null && input.target !== "") {
    const said = relayUrl(input.target, insecure);
    const relay = said === null ? undefined : relayUrls(r).find((u) => sameUrl(u) === sameUrl(said));
    // An entry is a way into a relay of the list, and is no relay itself (the cloud's own one either).
    if (relay === undefined || relayUrls(r).some((u) => sameUrl(u) === sameUrl(url))) return "invalid_target";
    target = relay;
  }
  if (!r.listed.some((l) => sameUrl(l.url) === sameUrl(url)) && r.listed.length >= RELAYS_MOST) return "too_many_relays";
  return { url, name, target };
}

/** A token to make for a relay as `input` says: what it will be called, and the URL it must enroll (null: any), or
 * what it is a way into; or why it cannot be. */
export function relayTokenOf(input: RelayTokenInput, r: Relays, insecure: boolean): { name: string; url: string | null; target: string | null } | string {
  const name = nameOf(input.name);
  if (name === null || name === "") return "invalid_name";
  if (input.url === undefined || input.url === null || input.url === "") {
    if (input.target !== undefined && input.target !== null && input.target !== "") return "invalid_relay";
    return { name, url: null, target: null };
  }
  const put = relayPut({ ...input, name }, r, insecure);
  return typeof put === "string" ? put : { name, url: put.url, target: put.target };
}
