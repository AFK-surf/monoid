// The jobs module (move/AGENTS.md): an item is one job or service a chat had running (`<session>#<name>`). A chat held
// (handed over, or stopped as its need moved away) has its jobs stopped and kept here (`keep`: what it takes to run
// each again, kept in `move/jobs.log`, a line a change: kept.ts `KeptLog`), so that a job runs on one station at a time; moving it starts it there, in its
// chat's directory as it is there (`move.job.start`), once its chat is there; moving it back stops it there and starts
// it here. A chat whose move failed, or that goes on here, has its kept jobs started again here (`startKept`).
import { join } from "node:path";
import type { CarriedJob } from "../replica/carry.ts";
import { log } from "../ops/log.ts";
import { KeptLog } from "./kept.ts";
import type { Arrive, Item, ItemState, Module } from "./module.ts";

type Json = any;

export const jobItemId = (j: { session: string; name: string }) => `${j.session}#${j.name}`;

export type JobsDeps = {
  data: string;
  /// The jobs and services of sessions `keys` up now, with what it takes to run each again; one stopped; one started in
  /// its session (throws why not).
  up: (keys: string[] | null, ws?: string) => (CarriedJob & { id: string })[];
  stop: (id: string, why: string) => Promise<void>;
  start: (job: CarriedJob) => Promise<void> | void;
  /// The chat item a session is of (chats.ts: the first of those sharing its home chat).
  chatOf: (session: string) => string;
  ask: (station: string, request: Json) => Promise<Json>;
  here: () => string;
};

/// What the module keeps of a job, by its item id: stopped here as its chat was held (`kept`), or moved (to which
/// station).
type Kept = { kept: CarriedJob } | { moved: CarriedJob; to: string };
/// The file of before (every job kept and moved, one object): taken in as the log is first written.
type Before = { kept?: CarriedJob[]; moved?: { job: CarriedJob; to: string }[] };

export class JobsModule implements Module {
  readonly id = "jobs";
  readonly needs = ["chats"] as const;
  readonly #d: JobsDeps;
  /// Each job's, by its item id: a change writes that job's line alone.
  readonly #k: KeptLog<Kept>;
  /// The jobs kept here of each session (item ids): what a chat's going on here starts again, found by its keys.
  readonly #keptOf = new Map<string, Set<string>>();
  readonly #moving = new Set<string>();

  constructor(d: JobsDeps) {
    this.#d = d;
    this.#k = new KeptLog<Kept>(join(d.data, "move", "jobs.log"), {
      path: join(d.data, "move", "jobs.json"),
      records: (raw) => {
        const b = raw as Before;
        return [...(b.kept ?? []).map((j): [string, Kept] => [jobItemId(j), { kept: j }]), ...(b.moved ?? []).map((m): [string, Kept] => [jobItemId(m.job), { moved: m.job, to: m.to }])];
      },
    });
    for (const k of this.#k.values()) if ("kept" in k) this.#index(k.kept, true);
  }

  /// Once what it was asked to keep is on disk (kept.ts `settled`).
  settled(): Promise<void> {
    return this.#k.settled();
  }

  #index(j: CarriedJob, kept: boolean): void {
    const set = this.#keptOf.get(j.session) ?? new Set<string>();
    if (kept) set.add(jobItemId(j));
    else set.delete(jobItemId(j));
    if (set.size > 0) this.#keptOf.set(j.session, set);
    else this.#keptOf.delete(j.session);
  }
  #kept(id: string): CarriedJob | undefined {
    const k = this.#k.get(id);
    return k !== undefined && "kept" in k ? k.kept : undefined;
  }
  #moved(id: string): { job: CarriedJob; to: string } | undefined {
    const k = this.#k.get(id);
    return k !== undefined && "moved" in k ? { job: k.moved, to: k.to } : undefined;
  }
  /// Job `j` kept here, stopped (`kept`), moved there, or neither: its line written.
  async #put(j: CarriedJob, as: { kept: true } | { to: string } | null): Promise<void> {
    const id = jobItemId(j);
    this.#index(j, as !== null && "kept" in as);
    if (as === null) await this.#k.delete(id);
    else await this.#k.set(id, "kept" in as ? { kept: j } : { moved: j, to: as.to });
  }

  /// The jobs of `keys` up now stopped and kept (a chat held): each to be moved, or started here again.
  async keep(keys: string[], why: string): Promise<CarriedJob[]> {
    const up = this.#d.up(keys);
    // (a chat with no job up writes nothing)
    for (const j of up) {
      const { id: _, ...job } = j;
      if (this.#kept(jobItemId(job)) === undefined) await this.#put(job, { kept: true });
    }
    for (const j of up) await this.#d.stop(j.id, why).catch((e) => log.warn("move", "a job not stopped", { job: j.id, error: (e as Error).message }));
    return up.map(({ id: _, ...job }) => job);
  }

  /// The kept jobs of `keys` started here again (their chat goes on here).
  startKept(keys: string[]): void {
    const mine = keys.flatMap((k) => [...(this.#keptOf.get(k) ?? [])].flatMap((id) => this.#kept(id) ?? []));
    for (const j of mine) void this.#put(j, null).catch((e) => log.warn("move", "a job started again here not written so", { job: j.name, error: (e as Error).message }));
    for (const j of mine) this.#startHere(j);
  }

  #startHere(j: CarriedJob): void {
    // (a start answers as it went, the jobs' program's: its refusal logged, as one thrown here was)
    const failed = (e: unknown) => log.warn("move", "a job not started again here", { job: j.name, error: (e as Error).message });
    try {
      void Promise.resolve(this.#d.start(j)).catch(failed);
    } catch (e) {
      failed(e);
    }
  }

  async plan(ws: string): Promise<Item[]> {
    const items: Item[] = [];
    const of = (j: CarriedJob) => ({ module: "jobs", id: jobItemId(j), label: `${j.name} (${j.command})`, needs: [{ module: "chats", id: this.#d.chatOf(j.session) }] });
    const seen = new Set<string>();
    const add = (j: CarriedJob) => {
      if (seen.has(jobItemId(j))) return;
      seen.add(jobItemId(j));
      items.push(of(j));
    };
    for (const j of this.#d.up(null, ws)) add(j);
    for (const k of this.#k.values()) add("kept" in k ? k.kept : k.moved);
    return items;
  }

  async move(item: Item, to: string): Promise<void> {
    // (its session's jobs up, by its key: the item's id is `<session>#<name>`)
    const session = item.id.slice(0, item.id.indexOf("#"));
    const job = this.#kept(item.id) ?? this.#d.up([session]).find((j) => jobItemId(j) === item.id);
    if (job === undefined) throw new Error(`job ${item.label} is not kept here`);
    this.#moving.add(item.id);
    try {
      // (one still up here stops first: a job runs on one station at a time)
      if ("id" in job) await this.#d.stop((job as Json).id, "it moves to another station with its chat");
      const { id: _, ...carried } = job as Json;
      await this.#d.ask(to, { method: "move.job.start", job: carried });
      await this.#put(carried, { to });
    } finally {
      this.#moving.delete(item.id);
    }
  }

  /// Stopped there and started here; one whose chat is still there (`stoppedFor`) is kept here, stopped, and starts
  /// as its chat comes (`resume`): a job never runs here before its chat's room is here.
  async back(item: Item, from: string, opts?: Arrive): Promise<void> {
    const m = this.#moved(item.id);
    if (m === undefined) throw new Error(`job ${item.label} did not move from here`);
    await this.#d.ask(from, { method: "move.job.stop", session: m.job.session, name: m.job.name });
    await this.#put(m.job, opts?.stoppedFor !== undefined ? { kept: true } : null);
    if (opts?.stoppedFor === undefined) this.#startHere(m.job);
  }

  /// What it waited for is here (its chat came back): a job kept for it started here, once.
  async resume(item: Item): Promise<void> {
    const j = this.#kept(item.id);
    if (j === undefined) return;
    await this.#put(j, null);
    this.#startHere(j);
  }

  state(item: Item): ItemState {
    if (this.#moving.has(item.id)) return { state: "moving" };
    if (this.#moved(item.id) !== undefined) return { state: "there" };
    if (this.#kept(item.id) !== undefined) return { state: "stopped" };
    return { state: "here" };
  }

}
