// A chat handed from one station of a workspace to another while both work (station/src/replica/handover.ts): shown
// once, where it is now, and going on there for the person with nothing said (a move is not their business). The
// station it left keeps its rows out of its lists and says where the chat went: to a device that asks of it (`409
// {error, moved}`, requests.ts `onMoved`), in a list of all it handed (`GET /moved`, read a page at a time as its link
// opens), and as it goes (`chat-moved` on its stream; `station` null where it came back). What it says is kept on the
// device by station and session (db/account.ts `putMoved`, its table `moved`), so a device that was away, or a station
// off, leaves no row of it behind:
//
// - its rows there go and are not listed of it again while it says so; where the station it went to says it came from
//   it (its row's `from`, account.ts `#came`), so too, so a device that never heard the one it left (it off) lists it
//   once. With neither, two stations listing one session key are two chats (a platform thread's key is its connect's,
//   each station's own), both listed;
// - what opens a chat by that station follows it (data.ts `chatNow`, any number of hops, none round): a link
//   (asks.ts `linkNow`), a page open on it (core/routing.ts `#movedTo`: each topic it holds shows its copy there, its thread as the page names
//   it), the calls that name it (`aimed`: sent where it is, once more where the station said so only as it was asked);
// - what was done here and not confirmed yet is aimed there (local.ts `moved`): its outbox (a message the station
//   answered so is sent there, never shown failed), the first messages to its agent, a chat asked for here that became
//   it, what is laid over its row; its draft by its session (composer.ts).
import { Effect } from "effect";
import type { Inner } from "../core.ts";
import type { MovedTo } from "../db/account.ts";
import { encode } from "../ops.ts";
import { StationAddr } from "../station/addr.ts";
import { get, isObject } from "../util.ts";
import { ofAddress } from "../workspace.ts";

/// How many a page of `GET /moved` asks (the station gives 500 at most).
export const MOVED_PAGE = 500;

const u64 = (v: unknown): number | null => (typeof v === "number" && Number.isInteger(v) && v >= 0 ? v : null);
const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);

/// What a station said of one chat of its (`{session, station, thread, there, at}`): its session and where it is now
/// (null: back on it); null where it says nothing that can be read.
export function movedOf(address: string, said: unknown): { session: string; to: MovedTo | null } | null {
  if (!isObject(said)) return null;
  const session = str(get(said, "session"));
  if (session === null) return null;
  const station = get(said, "station");
  if (station === null) return { session, to: null };
  if (typeof station !== "string" || station === "" || station.includes("/")) return null;
  const to = `${ofAddress(address)}/${station}`;
  // (one that says it went to the station saying so: back on it)
  if (to === address) return { session, to: null };
  const at = get(said, "at");
  return { session, to: { station: to, thread: u64(get(said, "thread")), there: u64(get(said, "there")), at: typeof at === "number" && Number.isFinite(at) ? at : null } };
}

/// `address` says its chat of `session` went to `to` (null: came back): kept, and what was done here to it aimed there.
export function heard(inner: Inner, address: string, session: string, to: MovedTo | null): void {
  const thread = to === null ? null : (to.thread ?? inner.data.moved(address, session)?.thread ?? null);
  // (back: its thread here, as the station said it went)
  const back = to === null ? (inner.data.moved(address, session)?.thread ?? null) : null;
  if (!inner.data.putMoved(address, session, to)) return;
  // Back on it: what was kept of it here as not there while it was elsewhere goes, what is shown of it asked again.
  if (to === null) inner.stations.chatHere(address, session, back);
  else aimThere(inner, address, session, thread);
}

/// What was done here to `address`'s chat of `session` (its thread there `thread`) aimed where it is now.
function aimThere(inner: Inner, address: string, session: string, thread: number | null): void {
  const now = inner.data.chatNow(address, { session });
  if (now === null) return;
  // Told it is there now: what was kept of it there as not there (a read answered 404 while it was elsewhere) goes,
  // and what a page holds of it is asked again (sync.ts chatHere): a reader reads when it is told.
  inner.stations.chatHere(now.station, session, now.thread);
  const sends = inner.views?.local.moved(address, session, thread, now.station, now.thread) ?? [];
  if (now.thread !== null) inner.viewCalls?.movedSends(now.station, now.thread, sends);
  // Its draft, by its session, where none is kept there (composer.ts keeps it there from now on).
  const here = { topic: "draft", station: address, chat: session };
  const draft = inner.data.get(here);
  if (draft !== undefined && inner.data.get({ ...here, station: now.station }) === undefined) {
    inner.data.set({ ...here, station: now.station }, draft, false);
    inner.data.forgetTopic(here);
  }
}

/// Every chat a station handed elsewhere, read a page at a time (`GET /moved`): kept, and those it no longer names back
/// on it. A station from before says none (404).
function readStation(inner: Inner, address: string): Effect.Effect<void> {
  return Effect.gen(function* () {
    if (!inner.stations.link(address) || !inner.stations.reachable(address)) return;
    const addr = StationAddr.parse(address);
    const named = new Set<string>();
    let after = "";
    for (;;) {
      const answer = yield* Effect.result(inner.stations.requests.call(addr, "GET", `/moved?after=${encode(after)}&limit=${MOVED_PAGE}`, null, { quiet: true }));
      if (answer._tag === "Failure") return;
      const page = get(answer.success, "moved");
      if (!Array.isArray(page)) return;
      for (const said of page) {
        const m = movedOf(address, said);
        if (m === null) continue;
        named.add(m.session);
        heard(inner, address, m.session, m.to);
      }
      const last = page.length > 0 ? str(get(page[page.length - 1], "session")) : null;
      if (page.length < MOVED_PAGE || last === null || last <= after) break;
      after = last;
    }
    // (one the station it went to says came from here, while it still says so: that is said of it, not this one's
    // silence)
    const id = address.slice(address.lastIndexOf("/") + 1);
    for (const session of inner.data.movedFrom(address)) {
      if (named.has(session)) continue;
      const to = inner.data.moved(address, session);
      if (to?.came === true && get(inner.data.summary(to.station, session), "from") === id) continue;
      heard(inner, address, session, null);
    }
  });
}

/// A call's params aimed where the chat they name is now (data.ts chatNow): its station, and its thread there; one
/// named by its session (`session`, a draft's `chat`, an agent's `key`) its station alone.
export function aimed(inner: Inner, params: unknown): unknown {
  if (!isObject(params) || typeof params.station !== "string") return params;
  const station = params.station;
  const data = inner.data;
  if (typeof params.thread === "number") {
    const now = data.chatNow(station, { thread: params.thread });
    return now === null || now.thread === null ? params : { ...params, station: now.station, thread: now.thread };
  }
  for (const field of ["session", "chat", "key"] as const) {
    const session = params[field];
    if (typeof session !== "string" || session === "") continue;
    // (an agent's key only where its station said it went: a key names other things too)
    if (field === "key" && data.moved(station, session) === undefined) continue;
    const now = data.chatNow(station, { session });
    if (now !== null) return { ...params, station: now.station };
  }
  return params;
}

export function install(inner: Inner): void {
  inner.stations.also.push({
    read: (address) => readStation(inner, address),
    event: (address, name, data) => {
      if (name !== "chat-moved") return;
      const m = movedOf(address, data);
      if (m !== null) heard(inner, address, m.session, m.to);
    },
    // (not read again after an absence: a stream that came back says each change it missed)
  });
  inner.stations.requests.onMoved = (station, said) => {
    const address = station.toString();
    const m = movedOf(address, said);
    if (m !== null) heard(inner, address, m.session, m.to);
  };
  // A chat back on the station it left: its rows there made again.
  inner.data.onFreed((station, session) => inner.stations.remakeRows(station, session));
  // One the station it went to says came from another (its row's `from`): as that one had said it went.
  inner.data.onCame((station, session) => aimThere(inner, station, session, inner.data.moved(station, session)?.thread ?? null));
}
