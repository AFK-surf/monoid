// The accounts module (move/AGENTS.md): an item is one account's login, known across the workspace by the share it is
// (`share:<id>`), the key it runs with (`key:<hash>`) or, a login of this station's own, its profile here
// (`own:<profile>@<station>`); this machine's own login (`machine:<id>`) cannot go. Moved by share/index.ts
// `moveProfile`, so that the chats still here go on (`usableHere`): one shared is borrowed here after it; one not
// shared whose login can be (share/index.ts `shareRefusal`: not a SuperGrok, Cursor, Devin, Copilot or Kimi
// sign-in) is shared first, with this station and the one it goes to alone, and moved as a shared one, borrowed here
// after it too (not one shared with stations this one is not among: no copy is kept here of that) (the owner, 2026-11-14: while a migration goes on both stations keep working, logins lent between them);
// one that cannot be is gone from here, and what needs it here is stopped first. Moved back by the same, asked of the
// station it went to; a share this move made (kept, `accounts-shared.json`) is undone once the login is home, unless a
// person opened it to another station meanwhile. There once the other station hosts it, its own or the share's host
// (`move.accounts`, asked as a plan is made, says which; one from before says only that it has a profile of it, taken
// as hosting it): one it only borrows is here still, this station's and lost with it, but usable there
// (`usableThere`), and its move makes the other its host, this one borrowing it. A move back asked of a station that
// only borrows it is refused there, saying where the login is. One both only borrow, from a third station, is neither's
// to move: no item; one this station borrows from a third and the other lacks cannot go.
//
// An item's id is what its account is known by now, the same on every station (`accountItemId`; the chats' needs say
// it so, handover.ts `accountsOf`). A login a move shares is renamed once, as its share is made: the plan made before
// names it `own:…` (or `key:…`), and that item stays `there` for the rest of the turn (its state is kept by that id);
// every plan after, here and on the other station, and every chat's needs, name it `share:<id>`, which the other
// station's `move.accounts` finds (the share it hosts) and `move.back` is asked for. Its profile keeps its id here
// throughout (a borrowed copy under the same id, its host's again as it comes back), so once its share is undone it is
// `own:<profile>@<station>` again, as before it moved.
import { join } from "node:path";
import { log } from "../ops/log.ts";
import { stationLang, tr } from "../ops/i18n.ts";
import type { AccountOf } from "../replica/handover.ts";
import { shareRefusal } from "../share/index.ts";
import { KeptSet, LentLog } from "./kept.ts";
import { type Item, type ItemState, type Module, named, unanswered, notAnswered } from "./module.ts";

type Json = any;

/// The item an account of profile `id` is (as handover.ts `accountsOf` knows it).
export const accountItemId = (id: string, a: AccountOf | null) => (a?.share !== undefined ? `share:${a.share}` : a?.key !== undefined ? `key:${a.key}` : a?.own !== undefined ? `own:${a.own}` : `machine:${id}`);

/// A login not shared moved as a shared one, and that share undone once it is back (share/index.ts `moveProfile`'s
/// `shareFirst`, `unshareMoved`).
export type ShareMoves = {
  /// Profile `id` moved to `to`, shared first where it is not (`made` told the share's id before it is made): its id there
  /// and the share it moved as.
  move: (id: string, to: string, made: (share: string) => Promise<void>) => Promise<{ id: string; share?: string }>;
  /// The share a move made undone, where it is this station's and allowed to none but `stations`: whether it was.
  unshare: (share: string, stations: string[]) => Promise<boolean>;
  /// Profile `id` lent to `to`, this station staying its host (share/index.ts `lendTo`): what it changed.
  lend?: (id: string, to: string) => Promise<{ share: string; made: boolean; widened: boolean }>;
  /// What `lend` changed undone (share/index.ts `unlend`).
  unlend?: (share: string, to: string, made: boolean, widened: boolean) => Promise<void>;
  /// How many chats on station `to` run on share `share` (its `move.uses`); null: not answered, or a station from
  /// before that does not say.
  usesThere?: (to: string, share: string) => Promise<number | null>;
  /// The chats handed from here to station `to` whose login is profile `pid` (as a start mends what was kept lent).
  handedOn?: (to: string, pid: string) => string[];
};

/// A login lent for what moved (`move/accounts-lent.log`, by its share, a line for each item it is lent for): to which station, as which item and profile,
/// what lending it changed, and the items there it was lent for (by name): taken back when the last of them is here.
/// `hostMoved`: its host moved there since (asked for by name): no longer lent; the other's addition taken off as it
/// comes home (`cameHome`).
type Lent = { to: string; item: string; pid: string; made: boolean; widened: boolean; for: string[]; hostMoved?: true };

export type AccountsDeps = {
  /// The profiles here that `ws`'s chats run on, each with what it is known by (handover.ts `accountsOf`).
  used: (ws: string) => Map<string, AccountOf | null>;
  /// Whether profile `id` here is shared (a copy of it is borrowed here once it moved).
  shared: (id: string) => boolean;
  /// Its login moved to `to` (share/index.ts `moveProfile`, which refuses in words).
  moveProfile: (id: string, to: string) => Promise<unknown>;
  /// The profile in this station's config now that account item `id` is (its share, its key, or an own one by its
  /// profile's id): none, not here.
  present?: (id: string) => string | undefined;
  ask: (station: string, request: Json) => Promise<Json>;
  here: () => string;
  /// Where what this module keeps is (the shares its moves made, `move/accounts-shared.json`), and profile `id` as
  /// config.json has it, and the share's moves: given all three, a login not shared that can be is shared as it moves.
  /// None: one not shared moves as it is (a test's).
  data?: string;
  profile?: (id: string) => Json;
  shareMoves?: ShareMoves;
};

export function accountsModule(d: AccountsDeps): Module & { cameHome(share: string, from: string): Promise<void>; lookAt(from: string, said?: { share: string; uses: number }): Promise<void>; settled(): Promise<void> } {
  /// What the other station said it has, as each plan asked it: by item id, its profile there and whether it hosts the
  /// login (false: it borrows it; null: a station from before, which does not say, taken as hosting it); null: none.
  const there = new Map<string, { id: string; hosts: boolean | null } | null>();
  const local = new Map<string, string>();
  const moving = new Set<string>();
  /// The shares a move made from here, by their id, kept across a start (undone as their login comes back).
  const made = d.data !== undefined && d.shareMoves !== undefined ? new KeptSet(join(d.data, "move", "accounts-shared.json")) : null;
  /// The logins lent for what moved, by share, kept across a start; and the items lent in this station's turns now.
  const lent = d.data !== undefined && d.shareMoves?.lend !== undefined ? new LentLog<Lent>(join(d.data, "move", "accounts-lent.log"), join(d.data, "move", "accounts-lent.json")) : null;
  const lentNow = new Map<string, string>();
  /// The shares lent in the turn under way (till its end, `left` asked with none): one whose items did not go, the other
  /// not answering whether it runs anything on it, is taken back all the same (it had it for this turn alone).
  const fresh = new Set<string>();
  /// What a station from before this kept lent, mended as it starts: the chats handed to where it is lent that run on
  /// it, kept as what it is lent for (a later turn's chats were not, and the login was taken back from under them).
  const mended = (async () => {
    if (lent === null || d.shareMoves?.handedOn === undefined) return;
    for (const [share, l] of lent.entries()) {
      if (l.hostMoved === true) continue;
      for (const key of d.shareMoves.handedOn(l.to, l.pid)) await lent.lentFor(share, `chats ${key}`);
    }
  })().catch((e) => log.warn("move", "what is lent not mended as the station started", { error: (e as Error).message }));
  const lentTo = (item: Item): string | undefined => lentNow.get(item.id) ?? (item.id.startsWith("share:") ? lent?.base(item.id.slice("share:".length))?.to : undefined);
  /// Whether profile `pid`'s login, not shared, is shared as it moves (so it is borrowed here after it).
  const sharedAsItMoves = (pid: string) => {
    if (made === null || d.shared(pid)) return false;
    const p = d.profile?.(pid);
    return p !== undefined && p !== null && p.machine !== true && shareRefusal(p) === null;
  };
  /// Undoing a share as its login came home, by share id (one at a time: the move back and the take it caused both ask).
  const homing = new Map<string, Promise<void>>();
  /// Share `share` hosted here again, handed over from `from` by any route (a move back of this station's, the other's
  /// own move, a person's on the accounts page): the share a trip of this station's made for it undone, but where a
  /// person opened it to another station meanwhile; no longer this station's to undo either way.
  const cameHome = (share: string, from: string): Promise<void> => {
    // (lent there by widening, its host moved there since: the other taken off again, as a person had it)
    const l = lent?.base(share);
    if (l?.hostMoved === true) {
      return d.shareMoves!.unlend!(share, l.to, false, l.widened)
        .catch((e) => log.warn("move", "a login lent for a move not taken back as it came home", { share, error: (e as Error).message }))
        .then(() => lent!.delete(share));
    }
    if (made === null || !made.has(share)) return Promise.resolve();
    const going = homing.get(share);
    if (going !== undefined) return going;
    const undo = (async () => {
      const undone = await d.shareMoves!.unshare(share, [d.here(), from]).catch((e) => {
        log.warn("move", "a share a move made not undone as its login came home", { share, error: (e as Error).message });
        return null;
      });
      if (undone !== null) await made.delete(share);
    })().finally(() => homing.delete(share));
    homing.set(share, undo);
    return undo;
  };
  return {
    id: "accounts",
    needs: [],
    /// Once what it was asked to keep of what it lent is on disk (kept.ts `settled`).
    settled: () => lent?.settled() ?? Promise.resolve(),
    async plan(ws, to) {
      const items: Item[] = [];
      const asked: Record<string, AccountOf> = {};
      /// Those its chats name that are no profile here (removed, renamed, or moved away): an item only where the other
      /// station has it (one moved there, what what is stopped here waits for), else no need of anything.
      const gone = new Set<string>();
      for (const [pid, a] of d.used(ws)) {
        const id = accountItemId(pid, a);
        if (items.some((x) => x.id === id)) continue;
        // (not here, known before or never: an item only where the other has it, below)
        if (d.profile !== undefined && d.profile(pid) == null) gone.add(id);
        local.set(id, pid);
        if (a !== null) asked[id] = a;
        items.push({ module: "accounts", id, label: a?.name ?? pid, needs: [], ...(a === null ? { cannot: tr(stationLang(), "station.move.sched.machineLogin") } : {}) });
      }
      // (not answered: what it has is not guessed, the logins asked of it cannot go this turn, nor what needs them)
      let failed: unknown = null;
      // (no station named, the plan of this one alone: nothing asked of anyone)
      const answer = Object.keys(asked).length === 0 || to === "" ? null : await d.ask(to, { method: "move.accounts", accounts: asked }).catch((e) => ((failed = notAnswered("move.accounts", to, e)), null));
      if (failed !== null) for (const x of items) if (x.id in asked) (x.cannot = unanswered(failed)), (x.again = true);
      for (const id of Object.keys(asked)) {
        const pid = answer?.here?.[id];
        there.set(id, typeof pid === "string" ? { id: pid, hosts: typeof answer?.hosts?.[id] === "boolean" ? answer.hosts[id] : null } : null);
      }
      // (one this station only borrows, the other not hosting it either, is a third station's (the real run,
      // 2026-11-16: a whole move failed on two logins a third station hosts): no item where the other borrows it too,
      // as one that is nowhere; one the other lacks cannot go, what needs it refused or arriving stopped. Known only as
      // the other answered, in a plan toward it)
      const neither = new Set<string>();
      if (to !== "" && failed === null) {
        for (const x of items) {
          const pid = local.get(x.id);
          const share = pid === undefined ? undefined : d.profile?.(pid)?.share;
          // (borrowed from the other itself: its host, whatever it answered)
          if (!(x.id in asked) || x.cannot !== undefined || share?.borrowed !== true || share.host === to) continue;
          const t = there.get(x.id);
          if (t == null) x.cannot = tr(stationLang(), "station.share.moveBorrowed");
          else if (t.hosts === false) neither.add(x.id);
        }
      }
      // (one that is not here, nor there, answered so: no item, nothing to move nor to wait for)
      return items.filter((x) => !neither.has(x.id) && (!gone.has(x.id) || failed !== null || there.get(x.id) != null));
    },
    async move(item, to) {
      const pid = local.get(item.id);
      if (pid === undefined) throw new Error(`account ${item.label} is not on this station`);
      // (lent there before, now asked for itself: the share lending made is a move's own from now on, undone as it
      // comes home; one widened for it keeps the other till then)
      for (const [share, l] of lent?.entries() ?? []) {
        if (l.pid !== pid || l.hostMoved === true) continue;
        if (l.made) {
          await made?.add(share);
          await lent!.delete(share);
        } else await lent!.set(share, { ...l, for: [], hostMoved: true });
        lentNow.delete(l.item);
      }
      moving.add(item.id);
      try {
        let answer: Json;
        if (sharedAsItMoves(pid)) {
          // (kept before the share is made: a stop between leaves no share made here that is not known so)
          const got: { share?: string } = {};
          try {
            answer = await d.shareMoves!.move(pid, to, async (s) => {
              got.share = s;
              await made!.add(s);
            });
          } catch (e) {
            // (the share module undid the share it made, the login here as it was: nothing of it is left to undo)
            if (got.share !== undefined && d.profile?.(pid)?.share?.id !== got.share) await made!.delete(got.share);
            throw e;
          }
        } else answer = await d.moveProfile(pid, to);
        there.set(item.id, { id: typeof answer?.id === "string" ? answer.id : pid, hosts: true });
      } finally {
        moving.delete(item.id);
      }
    },
    async back(item, from) {
      await d.ask(from, { method: "move.back", module: "accounts", id: item.id, to: d.here() });
      there.set(item.id, null);
      // (home: the share this move made undone, but where a person opened it to another station meanwhile)
      if (item.id.startsWith("share:")) await cameHome(item.id.slice("share:".length), from);
    },
    state(item): ItemState {
      if (moving.has(item.id)) return { state: "moving" };
      // (lent: here, its host, and usable there too)
      const to = lentTo(item);
      if (to !== undefined) return { state: "here", lentTo: to };
      // (there once the other hosts it: one it only borrows is still this station's, lost with it)
      const t = there.get(item.id);
      return { state: t != null && t.hosts !== false ? "there" : "here" };
    },
    cameHome,
    usableThere(item) {
      return there.get(item.id) != null || lentTo(item) !== undefined;
    },
    canLend(item) {
      if (lent === null || there.get(item.id) != null) return false;
      const pid = local.get(item.id);
      const p = pid === undefined ? undefined : d.profile?.(pid);
      return p !== undefined && p !== null && p.machine !== true && p.share?.borrowed !== true && shareRefusal(p) === null;
    },
    async lend(item, to, forWhom) {
      const pid = local.get(item.id);
      if (pid === undefined || lent === null) throw new Error(`account ${item.label} is not on this station`);
      const r = await d.shareMoves!.lend!(pid, to);
      // (its record, then a line for each item it is lent for: those it was lent for before stay as they are)
      if (lent.base(r.share) === undefined) fresh.add(r.share);
      await lent.setBase(r.share, { to, item: item.id, pid, made: r.made, widened: r.widened });
      for (const n of new Set(forWhom.map(named))) await lent.lentFor(r.share, n);
      lentNow.set(item.id, to);
    },
    async lentFor(item, to, forWhom) {
      await mended;
      if (lent === null || !item.id.startsWith("share:")) return;
      const share = item.id.slice("share:".length);
      const l = lent.base(share);
      if (l === undefined || l.to !== to || l.hostMoved === true) return;
      for (const n of new Set(forWhom.map(named))) await lent.lentFor(share, n);
    },
    /// A login lent to station `from`, kept lent for nothing of this station's (only for what `from` runs on it), looked
    /// at again as `from` is heard of: a chat came from it, or it said its last chat on that login ended (`said`, its
    /// `move.unused`): taken back where nothing there runs on it.
    async lookAt(from, said) {
      if (lent === null) return;
      await mended;
      for (const [share, l] of lent.entries()) {
        if (l.to !== from || l.hostMoved === true || lent.forCount(share) > 0 || (said !== undefined && said.share !== share)) continue;
        const uses = said !== undefined ? said.uses : ((await d.shareMoves!.usesThere?.(from, share).catch(() => null)) ?? null);
        if (uses !== 0) continue;
        log.info("move", "a login lent taken back: nothing on the station it was lent to runs on it", { share, to: from.slice(0, 12) });
        await d.shareMoves!.unlend!(share, l.to, l.made, l.widened).catch((e) => log.warn("move", "a login lent for a move not taken back", { share, error: (e as Error).message }));
        await lent.delete(share);
        lentNow.delete(l.item);
      }
    },
    async left(items) {
      if (lent === null) return;
      await mended;
      // (the shares lent for these items, by their names: each item's line taken off; no other item's looked at; and
      // those kept lent only for what the other runs on them, a few)
      const shares = new Set(items.flatMap((x) => lent.sharesFor(named(x))));
      if (items.length === 0) for (const [share] of lent.entries()) if (lent.forCount(share) === 0) shares.add(share);
      for (const share of shares) {
        const l = lent.base(share);
        if (l === undefined || l.hostMoved === true) continue;
        for (const x of items) await lent.unlent(share, named(x));
        if (lent.forCount(share) > 0) continue;
        // (the last item it was lent for is here: taken back once the other says nothing there runs on it, a chat it
        // began on it too; not answered, kept lent and asked again at the next turn's end)
        const uses = (await d.shareMoves!.usesThere?.(l.to, share).catch(() => null)) ?? null;
        if (uses !== 0 && !(uses === null && fresh.has(share))) {
          log.info("move", "a login lent kept lent: the other runs chats on it, or did not say", { share, to: l.to.slice(0, 12), uses });
          continue;
        }
        await d.shareMoves!.unlend!(share, l.to, l.made, l.widened).catch((e) => log.warn("move", "a login lent for a move not taken back", { share, error: (e as Error).message }));
        await lent.delete(share);
        lentNow.delete(l.item);
        fresh.delete(share);
      }
      if (items.length === 0) fresh.clear();
    },
    isHere(item) {
      return d.present?.(item.id) !== undefined;
    },
    usableHere(item) {
      const pid = local.get(item.id);
      if (pid === undefined) return false;
      if (!d.shared(pid)) return sharedAsItMoves(pid);
      // (one shared with stations this one is not among is not borrowed here once it went: share/index.ts moveProfile)
      const allow = d.profile?.(pid)?.share?.allow;
      return d.profile?.(pid)?.share?.borrowed === true || !Array.isArray(allow) || allow.includes(d.here());
    },
  };
}
