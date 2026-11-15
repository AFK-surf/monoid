// The jobs module (move/AGENTS.md): an item is one job or service a chat had running (`<session>#<name>`). A chat held
// (handed over, or stopped as its need moved away) has its jobs stopped and kept here (`keep`: what it takes to run
// each again, kept in `move/jobs.json`), so that a job runs on one station at a time; moving it starts it there, in its
// chat's directory as it is there (`move.job.start`), once its chat is there; moving it back stops it there and starts
// it here. A chat whose move failed, or that goes on here, has its kept jobs started again here (`startKept`).
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { CarriedJob } from "../replica/carry-worker.ts";
import { log } from "../ops/log.ts";
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

/// What the module keeps: the jobs stopped here as their chat was held, and those moved (to which station).
type Kept = { kept: CarriedJob[]; moved: { job: CarriedJob; to: string }[] };

export class JobsModule implements Module {
  readonly id = "jobs";
  readonly needs = ["chats"] as const;
  readonly #d: JobsDeps;
  #k: Kept;
  readonly #moving = new Set<string>();

  constructor(d: JobsDeps) {
    this.#d = d;
    try {
      this.#k = JSON.parse(readFileSync(join(d.data, "move", "jobs.json"), "utf8")) as Kept; // sync: read once, before the station serves
    } catch {
      this.#k = { kept: [], moved: [] };
    }
  }

  /// The jobs of `keys` up now stopped and kept (a chat held): each to be moved, or started here again.
  async keep(keys: string[], why: string): Promise<CarriedJob[]> {
    const up = this.#d.up(keys);
    for (const j of up) {
      const { id, ...job } = j;
      if (!this.#k.kept.some((k) => jobItemId(k) === jobItemId(job))) this.#k.kept.push(job);
      this.#k.moved = this.#k.moved.filter((m) => jobItemId(m.job) !== jobItemId(job));
    }
    await this.#save();
    for (const j of up) await this.#d.stop(j.id, why).catch((e) => log.warn("move", "a job not stopped", { job: j.id, error: (e as Error).message }));
    return up.map(({ id: _, ...job }) => job);
  }

  /// The kept jobs of `keys` started here again (their chat goes on here).
  startKept(keys: string[]): void {
    const mine = this.#k.kept.filter((j) => keys.includes(j.session));
    this.#k.kept = this.#k.kept.filter((j) => !keys.includes(j.session));
    void this.#save();
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
    for (const j of this.#d.up(null, ws)) items.push(of(j));
    for (const j of this.#k.kept) if (!items.some((x) => x.id === jobItemId(j))) items.push(of(j));
    for (const m of this.#k.moved) if (!items.some((x) => x.id === jobItemId(m.job))) items.push(of(m.job));
    return items;
  }

  async move(item: Item, to: string): Promise<void> {
    const job = this.#k.kept.find((j) => jobItemId(j) === item.id) ?? this.#d.up(null).find((j) => jobItemId(j) === item.id);
    if (job === undefined) throw new Error(`job ${item.label} is not kept here`);
    this.#moving.add(item.id);
    try {
      // (one still up here stops first: a job runs on one station at a time)
      if ("id" in job) await this.#d.stop((job as Json).id, "it moves to another station with its chat");
      const { id: _, ...carried } = job as Json;
      await this.#d.ask(to, { method: "move.job.start", job: carried });
      this.#k.kept = this.#k.kept.filter((j) => jobItemId(j) !== item.id);
      this.#k.moved = [...this.#k.moved.filter((m) => jobItemId(m.job) !== item.id), { job: carried, to }];
      await this.#save();
    } finally {
      this.#moving.delete(item.id);
    }
  }

  /// Stopped there and started here; one whose chat is still there (`stoppedFor`) is kept here, stopped, and starts
  /// as its chat comes (`resume`): a job never runs here before its chat's room is here.
  async back(item: Item, from: string, opts?: Arrive): Promise<void> {
    const m = this.#k.moved.find((x) => jobItemId(x.job) === item.id);
    if (m === undefined) throw new Error(`job ${item.label} did not move from here`);
    await this.#d.ask(from, { method: "move.job.stop", session: m.job.session, name: m.job.name });
    this.#k.moved = this.#k.moved.filter((x) => x !== m);
    if (opts?.stoppedFor !== undefined && !this.#k.kept.some((j) => jobItemId(j) === item.id)) this.#k.kept.push(m.job);
    await this.#save();
    if (opts?.stoppedFor === undefined) this.#startHere(m.job);
  }

  /// What it waited for is here (its chat came back): a job kept for it started here, once.
  async resume(item: Item): Promise<void> {
    const j = this.#k.kept.find((x) => jobItemId(x) === item.id);
    if (j === undefined) return;
    this.#k.kept = this.#k.kept.filter((x) => x !== j);
    await this.#save();
    this.#startHere(j);
  }

  state(item: Item): ItemState {
    if (this.#moving.has(item.id)) return { state: "moving" };
    if (this.#k.moved.some((m) => jobItemId(m.job) === item.id)) return { state: "there" };
    if (this.#k.kept.some((j) => jobItemId(j) === item.id)) return { state: "stopped" };
    return { state: "here" };
  }

  async #save(): Promise<void> {
    const path = join(this.#d.data, "move", "jobs.json");
    await mkdir(dirname(path), { recursive: true });
    const tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
    await writeFile(tmp, JSON.stringify(this.#k));
    await rename(tmp, path);
  }
}
