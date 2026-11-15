// A station's part in migrations (move/AGENTS.md): the hand-over of one chat (replica/handover.ts), the modules over
// this station's chats, accounts, jobs and connects, the scheduler over them, and what another station asks of them
// (`move.*`: which accounts it has, an item moved back to the station asking, a job started or stopped here). Made by
// the composition root (move/live.ts) and by the tests, given what it needs.
import { createHash } from "node:crypto";
import { Refused, bytesOf } from "../mesh/bus.ts";
import { PeerGone } from "../mesh/peer.ts";
import type { Fibers } from "../ops/fibers.ts";
import type { CarriedJob } from "../replica/carry-worker.ts";
import { type AccountOf, Handover, type HandoverDeps } from "../replica/handover.ts";
import { moved } from "../replica/restore.ts";
import type { Ask } from "../replica/peers.ts";
import type { Store } from "../store/store.ts";
import type { SessionPage } from "../store/store.ts";
import { type ShareMoves, accountItemId, accountsModule } from "./accounts.ts";
import { PLAN_PAGE, chatsModule, giveBack } from "./chats.ts";
import { connectsModule } from "./connects.ts";
import { JobsModule } from "./jobs.ts";
import { AskAgain, Gone, type Module, type PlanReads, Said } from "./module.ts";
import { ReposModule, repoItemId, worktreesOfClones } from "./repos.ts";
import { SettingsModule } from "./settings.ts";
import { type VaultDeps, VaultModule, vaultItemId } from "./vault.ts";
import { dirname, join } from "node:path";
import { readFileSync } from "node:fs";
import { mkdir, rename, writeFile } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { Scheduler } from "./scheduler.ts";
import { type Lang, stationLang, tr } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { hold as holdUpdates } from "../updates/holds.ts";

/// A JSON file written whole (beside, then renamed).
async function writeJsonFile(path: string, v: unknown): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
  await writeFile(tmp, JSON.stringify(v));
  await rename(tmp, path);
}

type Json = any;

export type MovesDeps = {
  data: string;
  here: () => string | null;
  home: () => string | null;
  roster: HandoverDeps["roster"];
  ask: Ask;
  fibers: Fibers;
  store: Store;
  hub: HandoverDeps["hub"];
  /// The workspace's connects (connects/workspace.ts), and this station's own of a workspace with their kind and mode.
  connects: (HandoverDeps["connects"] & {
    ownIn(ws: string): { id: string; name: string; kind: string; mode: string }[];
    /// This station's connects of `ws` (added here) that run on another station now.
    movedAway?(ws: string): { id: string; name: string; kind: string; mode: string }[];
    move(id: string, to: string, awaiting?: string[]): Promise<void>;
    /// Chats `keys` are here now (connects/workspace.ts `arrived`: what was kept for them taken).
    arrived?(keys: string[]): Promise<void>;
  }) | null;
  /// The jobs (jobs.ts): those up (of sessions `keys`, or of `ws`'s chats), one stopped, one started.
  jobs: { up(keys: string[] | null, ws?: string): (CarriedJob & { id: string })[]; stop(id: string, why: string): Promise<void>; start(job: CarriedJob): Promise<void> | void; stopNamed(session: string, name: string): Promise<void> };
  /// config.json's profiles as written; one's login moved to another station (share/index.ts `moveProfile`).
  profiles: () => Json[];
  moveProfile: (id: string, to: string) => Promise<unknown>;
  /// A login not shared that can be, shared as it moves and that share undone once it is back (accounts.ts; none: one
  /// not shared moves as it is, a test's).
  shareMoves?: ShareMoves;
  /// The sessions of `ws` here after `after`, at most `limit` (the home one's: those that say none or its id), read as
  /// a page (store `sessionPageOfWs`).
  sessionsIn: (ws: string, after: string, limit: number) => SessionPage;
  reposDir: string;
  room?: HandoverDeps["room"];
  hasGit?: HandoverDeps["hasGit"];
  git?: HandoverDeps["git"];
  lackMost?: number;
  work?: HandoverDeps["work"];
  fail?: HandoverDeps["fail"];
  changed?: () => void;
  /// config.json as written, for the settings that move (settings.ts).
  config?: { raw(): Json; update(f: (raw: Json) => void): void };
  /// This station's vault stores and the owners with secrets of a workspace here, the owners whose plain grants
  /// sessions hold (vault.ts).
  vault?: { owners(ws: string): string[]; grantOwners(keys: string[]): Map<string, string[]>; plain: VaultDeps["plain"]; vaults: VaultDeps["vaults"] };
  /// The messages a device's key keeps from being posted twice (api/admin.ts), carried with a chat that goes.
  keptSends?: HandoverDeps["keptSends"];
  keepSends?: HandoverDeps["keepSends"];
  /// Whether moving is switched on here (config.json `move`, a machine's own setting, off unless set; move/AGENTS.md).
  /// None given: on (a test's).
  moveOn?: () => boolean;
  /// The chats a plan reads at a time (chats.ts `PLAN_PAGE`; a test's smaller).
  planPage?: number;
  /// The repositories found on the machine outside the repository cache (sessions/presets.ts `RepoIndex`, as it holds
  /// them: never walked for a plan), whose linked worktrees chats may work in.
  clonesElsewhere?: () => Promise<string[]>;
  /// What keeps the station from updating itself (updates/holds.ts `hold`): held through a turn here, and while
  /// another station's request or a chat coming here is taken. None given: the station's own.
  hold?: () => () => void;
};

/// What a profile of config.json is known by across the workspace (handover.ts `AccountOf`): the share it is or is a
/// copy of; the key it runs with; one moved here keeps its id (`own`); this machine's login: none.
export function accountOf(p: Json, station: string): AccountOf | null {
  if (p === undefined || p === null || p.machine === true) return null;
  const name = typeof p.name === "string" && p.name !== "" ? p.name : String(p.id);
  if (p.share !== null && typeof p.share === "object" && typeof p.share.id === "string") return { share: p.share.id, name };
  if (p.access?.kind !== "subscription" && p.env !== null && typeof p.env === "object" && Object.keys(p.env).length > 0) {
    const env = Object.fromEntries(Object.entries(p.env).sort(([a], [b]) => a.localeCompare(b)));
    return { key: createHash("sha256").update(JSON.stringify([p.runtime ?? "", env])).digest("hex").slice(0, 32), name };
  }
  return { own: `${p.id}@${station}`, name };
}

export class Moves {
  readonly handover: Handover;
  readonly jobs: JobsModule;
  readonly scheduler: Scheduler;
  readonly modules: Module[];
  readonly #accounts: ReturnType<typeof accountsModule>;
  readonly repos: ReposModule;
  readonly vault: VaultModule;
  readonly settings: SettingsModule;
  readonly #d: MovesDeps;
  /// Whether a busy chat's turn is waited for as it moves (station_move `wait`, for the request under way).
  wait = true;
  /// What each profile here was known by, kept as it moves away (`move/accounts-known.json`, with the accounts
  /// module's state): a chat stopped for one names it so after a start too.
  readonly #known: Map<string, AccountOf>;

  /// In a turn, the stations it found gone (by id: what each later ask of one fails with at once) and those whose
  /// connection was found gone once (`PeerGone`: the next ask dials anew). Out of a turn, asks go as they are.
  readonly #gone = new Map<string, Error>();
  readonly #suspect = new Set<string>();
  /// The stations a request was sent again to in this turn, after the first that met their connection gone: once a
  /// turn a station, not once a request.
  readonly #sentAgain = new Set<string>();
  #inTurn = false;

  /// What this station's moves ask of another: in a turn, a station found gone is asked nothing more until it ends,
  /// every step toward it failing at once with the same words (drill 23's 185 s of asks of a station killed).
  readonly #ask: Ask = async (station, request) => {
    if (!this.#inTurn) return await this.#d.ask(station, request);
    const gone = this.#gone.get(station);
    if (gone !== undefined) throw gone;
    try {
      const answer = await this.#d.ask(station, request);
      this.#suspect.delete(station);
      return answer;
    } catch (e) {
      if (e instanceof Refused) {
        this.#suspect.delete(station);
        throw e;
      }
      // (its connection found gone: a stream ended with no answer is that too, mesh/peer.ts having let the connection go,
      // so the next request dials anew. Once a turn a station the request is sent again on it: one with no bytes here,
      // one with bytes by its caller from its start (`AskAgain`); that failing too, or no answer in time, it is gone)
      const timedOut = e instanceof Error && e.message.startsWith("peer request timed out");
      const unanswered = e instanceof PeerGone || (e instanceof Error && e.message === "the other station answered nothing");
      const name = this.#d.roster(this.#d.home() ?? "")?.find((r) => r.id === station)?.name || station.slice(0, 12);
      if (unanswered && !this.#sentAgain.has(station)) {
        this.#sentAgain.add(station);
        this.#suspect.add(station);
        log.info("move", "a request met the other station's connection gone: sent again once, dialed anew", { station: station.slice(0, 12), error: (e as Error).message });
        if (bytesOf(request) !== null) throw new AskAgain(tr(stationLang(), "station.move.noAnswer", { station: name }));
        return await this.#ask(station, request);
      }
      if (unanswered || timedOut || this.#suspect.has(station)) {
        const gone = new Gone(tr(stationLang(), "station.move.gone", { station: name }));
        this.#gone.set(station, gone);
        log.warn("move", "a station found gone in a turn: asked nothing more of it till it ends", { station: station.slice(0, 12), error: (e as Error).message });
        throw gone;
      }
      throw e;
    }
  };

  constructor(d: MovesDeps) {
    this.#d = d;
    let known: Record<string, AccountOf> = {};
    try {
      known = JSON.parse(readFileSync(join(d.data, "move", "accounts-known.json"), "utf8")) as Record<string, AccountOf>; // sync: read once, before the station serves
    } catch {}
    this.#known = new Map(Object.entries(known));
    const here = () => d.here() ?? "";
    const ask = this.#ask;
    this.repos = new ReposModule({
      data: d.data, reposDir: d.reposDir, ask, here,
      after: (ms, f) => d.fibers.after(ms, f), name: (station) => d.roster(d.home() ?? "")?.find((r) => r.id === station)?.name ?? station.slice(0, 12),
      workspaces: async (ws) => {
        const out: string[] = [];
        for await (const page of this.reads(ws).pages()) for (const r of page.rows()) out.push(r.workspace);
        return out;
      },
      git: d.git ?? (async () => { throw new Error("no git here"); }),
    });
    const none = { owners: () => [], grantOwners: () => new Map<string, string[]>(), plain: { items: () => [], item: () => null, put: () => {}, forget: () => {} }, vaults: { vaults: () => [], vault: () => null, items: () => [], item: () => null, putVault: () => {}, putItem: () => {}, forgetItem: () => {}, forgetVault: () => {} } };
    const v = d.vault ?? none;
    this.vault = new VaultModule({ data: d.data, owners: (ws) => v.owners(ws), plain: v.plain, vaults: v.vaults, ask });
    this.settings = new SettingsModule({ data: d.data, ask, config: d.config ?? { raw: () => ({}), update: () => {} } });
    this.jobs = new JobsModule({
      data: d.data, up: d.jobs.up, stop: d.jobs.stop, start: d.jobs.start, ask: (s, r) => this.#ask(s, { ...r, fromData: d.data }), here,
      chatOf: (session) => this.handover.chatOf(session),
    });
    this.handover = new Handover({
      data: d.data, here: d.here, home: d.home, roster: d.roster, ask: this.#ask, fibers: d.fibers, store: d.store, hub: d.hub, connects: d.connects,
      jobs: {
        of: (keys) => d.jobs.up(keys).map(({ id: _, ...j }) => j),
        stop: async (keys, why) => void (await this.jobs.keep(keys, why)),
        start: (job) => this.jobs.startKept([job.session]),
      },
      accounts: {
        of: (id) => {
          // (one moved away is still known by what it was: what the chats here that need it wait for)
          const p = d.profiles().find((x) => x?.id === id);
          if (p === undefined) return this.#known.get(id) ?? null;
          const a = accountOf(p, here());
          if (a !== null && JSON.stringify(this.#known.get(id)) !== JSON.stringify(a)) {
            this.#known.set(id, a);
            void writeJsonFile(join(d.data, "move", "accounts-known.json"), Object.fromEntries(this.#known)).catch(() => {});
          }
          return a;
        },
        here: (a) => this.accountHere(a),
        present: (id) => d.profiles().some((p) => p?.id === id),
      },
      reposDir: d.reposDir, room: d.room, hasGit: d.hasGit, git: d.git, lackMost: d.lackMost, work: d.work, fail: d.fail,
      changed: () => d.changed?.(),
      arrivedStopped: (keys, need, ws) => this.scheduler.noteStopped({ module: "chats", id: keys[0]! }, need, ws),
      // (a chat here again by any route: what was lent for it alone is taken back)
      shown: async (keys) => {
        await d.connects?.arrived?.(keys);
        await this.#accounts.left?.(keys.map((id) => ({ module: "chats", id }))).catch((e) => log.warn("move", "what was lent for a chat back here not taken back", { error: (e as Error).message }));
      },
      went: (keys) => this.scheduler.forget(keys.map((id) => ({ module: "chats", id }))),
      keptSends: d.keptSends, keepSends: d.keepSends,
      hold: () => (d.hold ?? holdUpdates)(),
      bindingsOf: (keys) => {
        const out: Record<string, string> = {};
        // (by session, the connects bound to it: as many as a station has single-session connects)
        for (const [session, connects] of d.store.listBindings()) if (keys.includes(session)) for (const c of connects) out[c] = session;
        return out;
      },
    });
    this.#accounts = accountsModule({
      // (the accounts module plans without waiting: the pages the plan under way read before its modules, `#planning`)
      used: (ws) => {
        const out = new Map<string, AccountOf | null>();
        const reads = this.#planning.get(ws);
        const pages = reads !== undefined && reads.loaded().length > 0 ? reads.loaded() : this.#pagesNow(ws);
        for (const page of pages) for (const k of page.keys) for (const [id, a] of this.handover.accountsOf([k], page)) out.set(id, a);
        return out;
      },
      shared: (id) => {
        const p = d.profiles().find((x) => x?.id === id);
        return p?.share !== null && typeof p?.share === "object";
      },
      moveProfile: d.moveProfile, ask: this.#ask, here,
      data: d.data, shareMoves: d.shareMoves,
      profile: (id) => d.profiles().find((x) => x?.id === id),
      present: (id) => {
        // (one moved here is known by the id it had there: an own login by its profile's id)
        const own = id.startsWith("own:") ? id.slice(4, id.lastIndexOf("@")) : null;
        return d.profiles().find((p) => typeof p?.id === "string" && (p.id === own || accountItemId(p.id, accountOf(p, here())) === id))?.id;
      },
    });
    this.modules = [
      this.#accounts,
      chatsModule({
        store: d.store, handover: this.handover, hub: d.hub, ask: this.#ask, here, reads: (ws) => this.reads(ws),
        kindOf: (id) => d.connects?.kindOf(id) ?? null, wait: () => this.wait,
        name: (id) => d.roster(d.home() ?? "")?.find((r) => r.id === id)?.name || id.slice(0, 12),
        vaultsOf: (keys, ws) => new Map([...v.grantOwners(keys)].map(([k, owners]) => [k, owners.map((o) => `${vaultItemId(o)}@${ws}`)])),
        jobs: { keep: async (keys, why) => void (await this.jobs.keep(keys, why)), startKept: (keys) => this.jobs.startKept(keys) },
      }),
      this.jobs,
      connectsModule({
        own: (ws) => [...(d.connects?.ownIn(ws) ?? []), ...(d.connects?.movedAway?.(ws) ?? [])],
        chatsOf: (id) => this.#chatsOfConnect(id),
        runsOn: (id) => d.connects?.runsOn(id) ?? null,
        kindOf: (id) => d.connects?.kindOf(id) ?? null,
        keysOf: async (id) => (await this.#ofConnect(id)).filter((k) => d.store.handedTo(k) === null),
        move: async (id, to, awaiting) => {
          if (d.connects === null) throw new Error("the connects are not up yet");
          await d.connects.move(id, to, awaiting);
        },
        ask: this.#ask, here,
      }),
      this.repos,
      this.vault,
      this.settings,
    ];
    this.scheduler = new Scheduler({
      data: d.data, modules: this.modules, changed: () => d.changed?.(), progress: () => d.changed?.(),
      tellArrived: async (to, item) => void (await this.#ask(to, { method: "move.arrived", item })),
      now: () => d.fibers.now(),
      refusal: (ws, station) => this.refusal(ws, station),
      hold: () => this.#hold(),
      restarted: () => tr(stationLang(), "station.move.restarted"),
      // (a turn's stations found gone are its own: forgotten as it begins and ends)
      turn: (on) => {
        this.#inTurn = on;
        this.#gone.clear();
        this.#suspect.clear();
        this.#sentAgain.clear();
      },
      reads: (ws) => {
        const r = this.reads(ws);
        this.#planning.set(ws, r);
        return r;
      },
    });
  }

  /// The plan under way of each workspace's reads (`reads`), for what plans without being given them.
  readonly #planning = new Map<string, PlanReads>();

  /// What one plan of `ws` reads once for its modules (module.ts `PlanReads`): the workspace's chats a page at a time,
  /// each page read as the first module asks for it and given to the others as it was, the main thread given back
  /// between pages; the linked worktrees as the clones say them, read once.
  reads(ws: string): PlanReads {
    const size = this.#d.planPage ?? PLAN_PAGE;
    const pages: SessionPage[] = [];
    let done = false;
    let clones: Promise<Map<string, { repo: string; url: string }[]>> | null = null;
    const d = this.#d;
    const iterate = async function* () {
      for (let i = 0; ; i++) {
        if (i > 0) await giveBack();
        if (i >= pages.length) {
          if (done) return;
          const page = d.sessionsIn(ws, pages.at(-1)?.keys.at(-1) ?? "", size);
          pages.push(page);
          if (page.keys.length < size) done = true;
        }
        yield pages[i]!;
      }
    };
    return {
      pages: iterate,
      load: async () => {
        for await (const _ of iterate()) void _;
      },
      loaded: () => pages,
      worktrees: async (dir) => (await (clones ??= (async () => worktreesOfClones(d.reposDir, (await d.clonesElsewhere?.()) ?? [], d.data))())).get(dir) ?? [],
    };
  }

  /// Every page of `ws`'s chats at once, for what plans outside a plan's reads (none of the scheduler's does).
  #pagesNow(ws: string): SessionPage[] {
    const size = this.#d.planPage ?? PLAN_PAGE;
    const out: SessionPage[] = [];
    for (let after = ""; ; ) {
      const page = this.#d.sessionsIn(ws, after, size);
      out.push(page);
      if (page.keys.length < size) return out;
      after = page.keys.at(-1)!;
    }
  }

  /// The sessions that came through connect `id`, every one, a page at a time.
  async #ofConnect(id: string, each?: (keys: string[]) => void): Promise<string[]> {
    const out: string[] = [];
    for (let after = ""; ; ) {
      const keys = this.#d.store.sessionsOfConnect(id, PLAN_PAGE, after);
      out.push(...keys);
      each?.(keys);
      if (keys.length < PLAN_PAGE) return out;
      after = keys.at(-1)!;
      await giveBack();
    }
  }

  async #chatsOfConnect(id: string): Promise<string[]> {
    const out = new Set<string>();
    await this.#ofConnect(id, (keys) => {
      const reads = this.#d.store.sessionPage(keys);
      for (const r of keys) out.add(this.handover.together(r, reads)[0] ?? r);
    });
    return [...out];
  }

  /// The profile here of an account known so (handover.ts `AccountOf`; null: none).
  accountHere(a: AccountOf): string | null {
    for (const p of this.#d.profiles()) {
      if (typeof p?.id !== "string" || p.machine === true) continue;
      const it = accountOf(p, this.#d.here() ?? "");
      if (it === null) continue;
      if (a.share !== undefined && (it.share === a.share || p.id === a.share)) return p.id;
      if (a.key !== undefined && it.key === a.key) return p.id;
      if (a.own !== undefined && a.own.split("@")[0] === p.id) return p.id;
    }
    return null;
  }

  async start(): Promise<void> {
    await this.handover.start();
    await this.scheduler.start();
  }

  async close(): Promise<void> {
    await this.handover.close();
  }

  /// Share `share` hosted here again, from `from`: what a trip of this station's shared for it undone (accounts.ts).
  shareCameHome(share: string, from: string): Promise<void> {
    return this.#accounts.cameHome(share, from);
  }

  /// What another station asks of this one's migrations (`move.*`).
  /// Whether moving is switched on here.
  on(): boolean {
    return this.#d.moveOn?.() ?? true;
  }

  /// Why a move or a move back with `station` of `ws` cannot begin now (null: it can): the switch here, then there (a
  /// station that answers `move.open` with a refusal is from before moving, and is taken as off); one that does not
  /// answer at all is said to be out of reach, which is what is known of it. Nothing is held either way.
  async refusal(ws: string, station: string, lang: Lang = stationLang()): Promise<string | null> {
    if (!this.on()) return tr(lang, "station.move.off");
    const name = () => this.#d.roster(ws)?.find((r) => r.id === station)?.name || station.slice(0, 12);
    let open: Json;
    // (a connection found gone fails its request, the next is dialed anew: asked once more before it is said to be out
    // of reach, as the stations' other asks are; a station just started again answers then)
    const ask = () => this.#d.ask(station, { method: "move.open", workspace: ws });
    try {
      open = await ask().catch((e) => (e instanceof PeerGone ? ask() : Promise.reject(e)));
    } catch (e) {
      if (!(e instanceof Refused)) return tr(lang, "station.move.unreachable", { station: name() });
      open = null;
    }
    if (open?.on === true) return null;
    return tr(lang, "station.move.offThere", { station: name() });
  }

  answers(inWorkspace: (peer: string) => boolean) {
    const each = this.#answers(inWorkspace);
    return async (peer: string, request: Json, workspace?: string): Promise<Json> => {
      // (another station's request taken whole before this station updates itself)
      const letGo = this.#hold();
      try {
        return await each(peer, request, workspace);
      } finally {
        letGo();
      }
    };
  }

  /// A station heard from: what is stopped here for what may have come from it meanwhile (a tell of its coming lost) is
  /// looked at (scheduler `settleStopped`), a burst of requests heard as one: while one look goes on, one more after it.
  heard(_peer: string): void {
    if (this.scheduler.stopped().length === 0) return;
    if (this.#looking) return void (this.#again = true);
    this.#looking = true;
    void (async () => {
      try {
        do {
          this.#again = false;
          await this.scheduler.settleStopped().catch(() => {});
        } while (this.#again && this.scheduler.stopped().length > 0);
      } finally {
        this.#looking = false;
      }
    })();
  }
  #looking = false;
  #again = false;

  /// The hold of updates (`hold`).
  get #hold(): () => () => void {
    return this.#d.hold ?? holdUpdates;
  }

  #answers(inWorkspace: (peer: string) => boolean) {
    const handed = this.handover.answers((peer, ws) => inWorkspace(peer) && (this.#d.roster(ws)?.some((s) => s.id === peer) ?? true));
    return async (peer: string, request: Json, workspace?: string): Promise<Json> => {
      // (switched off here: nothing is taken, before anything is held there)
      if (request?.method === "handover.begin" && !this.on()) throw new Refused(tr(stationLang(), "station.move.offThere", { station: this.#d.roster(String(workspace ?? ""))?.find((r) => r.id === this.#d.here())?.name || (this.#d.here() ?? "").slice(0, 12) }));
      if (typeof request?.method === "string" && request.method.startsWith("handover.")) return handed(peer, request, workspace);
      if (!inWorkspace(peer)) throw new Refused("not a station of this workspace");
      const method = typeof request?.method === "string" ? request.method : "";
      const bytes = bytesOf(request);
      if (method.startsWith("move.repo.")) return this.repos.answer(peer, request, bytes);
      if (method.startsWith("move.setting.")) return this.settings.answer(peer, request);
      if (method.startsWith("move.vault.")) return this.vault.answer(request);
      switch (request?.method) {
        case "move.open":
          return { on: this.on() };
        case "move.accounts": {
          // (`hosts`: whether the login is this station's, its own or a share it hosts; else it borrows it)
          const out: Record<string, string | null> = {};
          const hosts: Record<string, boolean> = {};
          for (const [id, a] of Object.entries((request.accounts ?? {}) as Record<string, AccountOf>)) {
            const pid = (out[id] = this.accountHere(a));
            if (pid !== null) hosts[id] = this.#d.profiles().find((p) => p?.id === pid)?.share?.borrowed !== true;
          }
          return { here: out, hosts };
        }
        case "move.back": {
          // (an item moved here from the station asking, moved back to it)
          if (request.to !== peer) throw new Refused("an item goes back only to the station asking");
          if (!this.on()) throw new Refused(tr(stationLang(), "station.move.offThere", { station: this.#d.roster(String(workspace ?? ""))?.find((r) => r.id === this.#d.here())?.name || (this.#d.here() ?? "").slice(0, 12) }));
          const id = String(request.id ?? "");
          if (request.module === "chats") {
            const stoppedFor = typeof request.stoppedFor?.module === "string" && typeof request.stoppedFor?.id === "string" ? { module: request.stoppedFor.module, id: request.stoppedFor.id, ...(typeof request.stoppedFor.label === "string" ? { label: request.stoppedFor.label } : {}) } : undefined;
            await this.handover.handOver(id, peer, { wait: true, stoppedFor });
            return { ok: true };
          }
          if (request.module === "accounts") {
            const pid = this.#d.profiles().find((p) => typeof p?.id === "string" && accountItemId(p.id, accountOf(p, this.#d.here() ?? "")) === id)?.id ?? this.accountHere(id.startsWith("own:") ? { own: id.slice(4), name: id } : { name: id });
            if (pid === undefined) throw new Refused(`no account ${id} here`);
            // (one this station only borrows is not here to go back: its login is with its host)
            const p = this.#d.profiles().find((x) => x?.id === pid);
            if (p?.share?.borrowed === true) {
              const host = String(p.share.host ?? "");
              const name = this.#d.roster(String(workspace ?? ""))?.find((r) => r.id === host)?.name || host.slice(0, 12);
              throw new Refused(`account ${id} is not on this station to move back: this station only borrows it, its login is on ${name}${host === peer ? " (the station asking)" : ""}`);
            }
            return { ok: true, ...((await this.#d.moveProfile(pid, peer)) as object) };
          }
          if (request.module === "connects") {
            const local = id.endsWith(`@${this.#d.here()}`) ? id.slice(0, -(this.#d.here() ?? "").length - 1) : id;
            if (this.#d.connects === null) throw new Refused("the connects are not up yet");
            await this.#d.connects.move(local, peer);
            return { ok: true };
          }
          throw new Refused(`module ${String(request.module)} moves nothing back this way`);
        }
        case "move.job.start": {
          const j = request.job as CarriedJob;
          if (typeof j?.session !== "string" || typeof j.name !== "string" || typeof j.command !== "string") throw new Refused("not a job");
          const row = this.#d.store.getSession(j.session);
          if (row === null) throw new Refused("its chat is not here");
          // (in its chat's directory as it is here: what was under the other's data directory is under this one's)
          const cwd = typeof j.cwd === "string" ? moved(j.cwd, String(request.fromData ?? ""), this.#d.data) : row.workspace;
          if (this.#d.store.jobsUp().some((x) => x.sessionKey === j.session && x.name === j.name && x.command === j.command)) return { ok: true };
          await this.#d.jobs.start({ ...j, cwd });
          return { ok: true };
        }
        case "move.arrived": {
          // (an item the asking station moved here: what waited here for it goes on)
          const item = request.item;
          if (typeof item?.module !== "string" || typeof item?.id !== "string") throw new Refused("no item named");
          return { ok: true, resumed: await this.scheduler.arrived({ module: item.module, id: item.id }) };
        }
        case "move.chats.live": {
          // (of the chats a plan toward here names, those of a key live here already: never merged into)
          const keys = Array.isArray(request.keys) ? request.keys.filter((k: unknown): k is string => typeof k === "string").slice(0, PLAN_PAGE * 4) : [];
          return { live: this.#d.store.liveOf(keys), name: this.#d.roster(String(workspace ?? ""))?.find((r) => r.id === this.#d.here())?.name || "" };
        }
        case "move.job.stop":
          await this.#d.jobs.stopNamed(String(request.session ?? ""), String(request.name ?? ""));
          return { ok: true };
      }
      throw new Refused("no such move request");
    };
  }
}
