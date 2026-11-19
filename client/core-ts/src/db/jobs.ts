// Station jobs table reads and writes (account.ts).
import type { SqlRow, SqlValue } from "../host.ts";
import { type DbEnv, type J, K, get, idText, parse, placesFor, str } from "./collection.ts";

export class JobsStore {
  readonly #env: DbEnv;

  constructor(env: DbEnv) {
    this.#env = env;
  }

  jobItem(station: string, id: string, json: SqlValue, chat: SqlValue, fromDb = true): J {
    return this.#env.cached(K("jobitem", station, id), json, (job) => {
      if (chat !== null && chat !== undefined) job.chat = parse(chat);
      return job;
    }, fromDb);
  }

  /// A job as it is now.
  job(station: string, id: string): J {
    const kept = this.#env.cache.get(K("job", station, id));
    if (kept !== undefined && kept !== null) return kept;
    const r = this.#env.sql.all("SELECT json FROM job WHERE station = ? AND id = ?", [station, id])[0];
    return r ? this.#env.cached(K("job", station, id), r[0]) : undefined;
  }

  /// A station's open jobs as read (GET /jobs), each with its chat.
  setJobs(station: string, list: J[], confirmed: number | null): void {
    this.#env.write(() => {
      const was = new Map<string, SqlRow>();
      // Only open jobs can be retained or need closing. An incoming closed job is written anew either way.
      for (const r of this.#env.sql.all("SELECT id, ord, json, chat, open FROM job WHERE station = ? AND open = 1", [station])) was.set(String(r[0]), r);
      const items: [string, J][] = [];
      const seen = new Set<string>();
      for (const j of list) {
        const id = idText(get(j, "id"));
        if (id === null || seen.has(id)) continue;
        seen.add(id);
        items.push([id, j]);
      }
      const places = placesFor(items.map(([id]) => (was.get(id)?.[4] === 1 ? (was.get(id)![1] as number) : null)));
      let changed = false;
      items.forEach(([id, item], i) => {
        const job = { ...item };
        const chat = job.chat === undefined ? null : JSON.stringify(job.chat);
        delete job.chat;
        const json = JSON.stringify(job);
        const r = was.get(id);
        if (r && r[4] === 1 && r[1] === places[i] && r[2] === json && r[3] === chat) return;
        changed = true;
        this.#putJobRow(station, id, json, chat, 1, places[i], str(get(job, "session")));
      });
      for (const [id, r] of was) {
        if (seen.has(id) || r[4] !== 1) continue;
        changed = true;
        this.#env.run("UPDATE job SET open = 0 WHERE station = ? AND id = ?", [station, id]);
        this.#env.loadedList(station, "jobs")?.delete(id);
        this.#env.tell({ topic: "jobs", station });
      }
      this.#env.markListed(station, "jobs", confirmed, changed);
    });
  }

  #putJobRow(station: string, id: string, json: string, chat: string | null, open: number, ord: number, session: string | null): void {
    this.#env.run("INSERT OR REPLACE INTO job (station, id, session, open, ord, chat, json) VALUES (?, ?, ?, ?, ?, ?, ?)", [station, id, session, open, ord, chat, json]);
    this.#env.cache.delete(K("job", station, id));
    this.#env.cache.delete(K("jobitem", station, id));
    const list = this.#env.loadedList(station, "jobs");
    if (open) list?.set(id, this.jobItem(station, id, json, chat, false), [ord]);
    else list?.delete(id);
    this.#env.tell({ topic: "jobs", station });
    this.#env.tell({ topic: "job", station, id });
  }

  /// A job as an event has it: as it is now, among the open ones while it is open (with the chat the list said).
  /// Answers whether it is open and the list does not have it (which chat it is in is the station's to say).
  putJob(station: string, job: J, open: boolean): boolean {
    const id = idText(get(job, "id"));
    if (id === null) return false;
    let unknown = false;
    this.#env.write(() => {
      const r = this.#env.sql.all("SELECT ord, json, chat, open FROM job WHERE station = ? AND id = ?", [station, id])[0];
      const json = JSON.stringify(job);
      const wasOpen = r?.[3] === 1;
      const nowOpen = open && wasOpen ? 1 : 0;
      if (open && !wasOpen) unknown = this.#env.listed(station, "jobs");
      if (r && r[1] === json && (r[3] as number) === nowOpen) return;
      this.#putJobRow(station, id, json, (r?.[2] as string | null | undefined) ?? null, nowOpen, (r?.[0] as number | undefined) ?? 0, str(get(job, "session")));
    });
    return unknown;
  }

  /// A job gone from its station (`job-removed`): its row let go of, off the open ones at once. Answers whether it was
  /// among them.
  dropJob(station: string, id: string): boolean {
    let was = false;
    this.#env.write(() => {
      const r = this.#env.sql.all("SELECT open FROM job WHERE station = ? AND id = ?", [station, id])[0];
      if (!r) return;
      was = r[0] === 1;
      this.#env.run("DELETE FROM job WHERE station = ? AND id = ?", [station, id]);
      this.#env.cache.delete(K("job", station, id));
      this.#env.cache.delete(K("jobitem", station, id));
      this.#env.loadedList(station, "jobs")?.delete(id);
      if (was) this.#env.tell({ topic: "jobs", station });
      this.#env.tell({ topic: "job", station, id });
    });
    return was;
  }

  /// A session gone from its station: its jobs no longer among the open ones (its station ends them with it), at once.
  /// (`job_open`: the station's open ones are few, its jobs of before many.)
  closeSessionJobs(station: string, session: string): void {
    this.#env.write(() => {
      const found = this.#env.sql.all("SELECT id FROM job INDEXED BY job_open WHERE station = ? AND open = 1 AND session = ?", [station, session]);
      if (found.length === 0) return;
      for (const r of found) {
        const id = String(r[0]);
        this.#env.run("UPDATE job SET open = 0 WHERE station = ? AND id = ?", [station, id]);
        this.#env.cache.delete(K("jobitem", station, id));
        this.#env.loadedList(station, "jobs")?.delete(id);
      }
      this.#env.tell({ topic: "jobs", station });
    });
  }
}
