// A station's part in migrations (move/AGENTS.md): the hand-over of one chat (replica/handover.ts), the modules over
// this station's chats, accounts, jobs and connects, the scheduler over them, and what another station asks of them
// (`move.*`: which accounts it has, an item moved back to the station asking, a job started or stopped here). Made by
// the composition root (move/live.ts) and by the tests, given what it needs.
import { createHash } from "node:crypto";
import { Refused } from "../mesh/bus.ts";
import type { Fibers } from "../ops/fibers.ts";
import type { CarriedJob } from "../replica/carry-worker.ts";
import { type AccountOf, Handover, type HandoverDeps } from "../replica/handover.ts";
import { moved } from "../replica/restore.ts";
import type { Ask } from "../replica/peers.ts";
import type { Store } from "../store/store.ts";
import { accountItemId, accountsModule } from "./accounts.ts";
import { chatsModule } from "./chats.ts";
import { connectsModule } from "./connects.ts";
import { JobsModule } from "./jobs.ts";
import type { Module } from "./module.ts";
import { PENDING, pendingModule } from "./pending.ts";
import { Scheduler } from "./scheduler.ts";

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
  connects: (HandoverDeps["connects"] & { ownIn(ws: string): { id: string; name: string; kind: string; mode: string }[]; runsOn(id: string): string | null; move(id: string, to: string): Promise<void> }) | null;
  /// The jobs (jobs.ts): those up (of sessions `keys`, or of `ws`'s chats), one stopped, one started.
  jobs: { up(keys: string[] | null, ws?: string): (CarriedJob & { id: string })[]; stop(id: string, why: string): Promise<void>; start(job: CarriedJob): void; stopNamed(session: string, name: string): Promise<void> };
  /// config.json's profiles as written; one's login moved to another station (share/index.ts `moveProfile`).
  profiles: () => Json[];
  moveProfile: (id: string, to: string) => Promise<unknown>;
  /// The sessions of `ws` here after `after`, at most `limit` (the home one's say none).
  sessionsIn: (ws: string, after: string, limit: number) => string[];
  reposDir: string;
  room?: HandoverDeps["room"];
  hasGit?: HandoverDeps["hasGit"];
  git?: HandoverDeps["git"];
  lackMost?: number;
  work?: HandoverDeps["work"];
  fail?: HandoverDeps["fail"];
  changed?: () => void;
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
  readonly #d: MovesDeps;
  /// What each profile here was known by, kept as it moves away (in memory: started again, a chat stopped for one
  /// names it as this machine's own).
  readonly #known = new Map<string, AccountOf>();

  constructor(d: MovesDeps) {
    this.#d = d;
    const here = () => d.here() ?? "";
    this.jobs = new JobsModule({
      data: d.data, up: d.jobs.up, stop: d.jobs.stop, start: d.jobs.start, ask: (s, r) => d.ask(s, { ...r, fromData: d.data }), here,
      chatOf: (session) => this.handover.together(session)[0] ?? session,
    });
    this.handover = new Handover({
      data: d.data, here: d.here, home: d.home, roster: d.roster, ask: d.ask, fibers: d.fibers, store: d.store, hub: d.hub, connects: d.connects,
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
          if (a !== null) this.#known.set(id, a);
          return a;
        },
        here: (a) => this.accountHere(a),
      },
      reposDir: d.reposDir, room: d.room, hasGit: d.hasGit, git: d.git, lackMost: d.lackMost, work: d.work, fail: d.fail,
      changed: () => d.changed?.(),
    });
    this.modules = [
      accountsModule({
        used: (ws) => {
          const out = new Map<string, AccountOf | null>();
          for (const key of d.sessionsIn(ws, "", 2_000)) for (const [id, a] of this.handover.accountsOf([key])) out.set(id, a);
          return out;
        },
        shared: (id) => {
          const p = d.profiles().find((x) => x?.id === id);
          return p?.share !== null && typeof p?.share === "object";
        },
        moveProfile: d.moveProfile, ask: d.ask, here,
      }),
      chatsModule({
        store: d.store, handover: this.handover, hub: d.hub, ask: d.ask, here, sessionsIn: d.sessionsIn,
        jobs: { keep: async (keys, why) => void (await this.jobs.keep(keys, why)), startKept: (keys) => this.jobs.startKept(keys) },
      }),
      this.jobs,
      connectsModule({
        own: (ws) => d.connects?.ownIn(ws) ?? [],
        chatsOf: (id) => this.#chatsOfConnect(id),
        runsOn: (id) => d.connects?.runsOn(id) ?? null,
        move: async (id, to) => {
          if (d.connects === null) throw new Error("the connects are not up yet");
          await d.connects.move(id, to);
        },
        ask: d.ask, here,
      }),
      ...PENDING.map(([id, label, why]) => pendingModule(id, label, why)),
    ];
    this.scheduler = new Scheduler({ data: d.data, modules: this.modules, changed: () => d.changed?.() });
  }

  #chatsOfConnect(id: string): string[] {
    const out = new Set<string>();
    for (const r of this.#d.store.sessionsOfConnect(id, 2_000)) out.add(this.handover.together(r)[0] ?? r);
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

  /// What another station asks of this one's migrations (`move.*`).
  answers(inWorkspace: (peer: string) => boolean) {
    const handed = this.handover.answers((peer, ws) => inWorkspace(peer) && (this.#d.roster(ws)?.some((s) => s.id === peer) ?? true));
    return async (peer: string, request: Json, workspace?: string): Promise<Json> => {
      if (typeof request?.method === "string" && request.method.startsWith("handover.")) return handed(peer, request, workspace);
      if (!inWorkspace(peer)) throw new Refused("not a station of this workspace");
      switch (request?.method) {
        case "move.accounts": {
          const out: Record<string, string | null> = {};
          for (const [id, a] of Object.entries((request.accounts ?? {}) as Record<string, AccountOf>)) out[id] = this.accountHere(a);
          return { here: out };
        }
        case "move.back": {
          // (an item moved here from the station asking, moved back to it)
          if (request.to !== peer) throw new Refused("an item goes back only to the station asking");
          const id = String(request.id ?? "");
          if (request.module === "chats") {
            await this.handover.handOver(id, peer, { wait: true });
            return { ok: true };
          }
          if (request.module === "accounts") {
            const pid = this.#d.profiles().find((p) => typeof p?.id === "string" && accountItemId(p.id, accountOf(p, this.#d.here() ?? "")) === id)?.id ?? this.accountHere(id.startsWith("own:") ? { own: id.slice(4), name: id } : { name: id });
            if (pid === undefined) throw new Refused(`no account ${id} here`);
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
          this.#d.jobs.start({ ...j, cwd });
          return { ok: true };
        }
        case "move.job.stop":
          await this.#d.jobs.stopNamed(String(request.session ?? ""), String(request.name ?? ""));
          return { ok: true };
      }
      throw new Refused("no such move request");
    };
  }
}
