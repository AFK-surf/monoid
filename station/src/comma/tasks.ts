// The Comma Tasks a Comma connect's agents work in, kept in <data>/comma-tasks.json: for each connect, each Task by its
// address at Comma (`task`, as task.invite named it), the thread it is here (channel TASK, its ts made from the
// address), how it was started (who asked, the runtime and model it was asked to run), how far Comma gave it
// (`fetched`: task.put's `through`, what task.hello says) and through which Message the station's session answered it
// already (`answered`: Comma says so with an invite made again; those Messages are not handed to the session again).
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { PrivateFile } from "../ops/files.ts";
import { log } from "../ops/log.ts";

/// Where Comma Tasks are, as threads here.
export const TASK_CHANNEL = "TASK";

/// How a Task was started, as task.invite said: who asked (a Comma user's id), and what it asked to run.
export type Start = { requester: string; title: string | null; runtime: string | null; model: string | null };

/// Validated links to open a Task in Comma (`web`: https page, `app`: `comma*://task?...`).
export type TaskLinks = { web?: string; app?: string };

export type Task = { task: string; threadTs: string; start: Start; fetched: number; answered: number; left?: true; links?: TaskLinks };

const MAX_LINK_LENGTH = 2048;
const COMMA_SCHEME = /^comma(?:-[a-z0-9-]+)?:$/;

/// Validates `links` given by Comma on `task.invite` / `task.put`: `web` must be `https://…`, `app` must be
/// `comma*://task?…`. Rejects any other scheme or malformed URL.
export function validTaskLinks(raw: unknown): TaskLinks | null {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
  const r = raw as Record<string, unknown>;
  const out: TaskLinks = {};
  if (typeof r.web === "string" && r.web.length > 0 && r.web.length <= MAX_LINK_LENGTH) {
    try {
      const u = new URL(r.web);
      if (u.protocol === "https:" && u.hostname !== "") out.web = r.web;
    } catch {}
  }
  if (typeof r.app === "string" && r.app.length > 0 && r.app.length <= MAX_LINK_LENGTH) {
    try {
      const u = new URL(r.app);
      if (
        COMMA_SCHEME.test(u.protocol) &&
        u.hostname === "task" &&
        u.username === "" &&
        u.password === "" &&
        u.port === "" &&
        u.hash === "" &&
        (u.pathname === "" || u.pathname === "/") &&
        u.search.length > 1
      ) {
        out.app = r.app;
      }
    } catch {}
  }
  return out.web !== undefined || out.app !== undefined ? out : null;
}

type Kept = Record<string, Record<string, Task>>;

/// A Task's thread ts, made of its address as a thread's ts reads (`<seconds>.<micros>`, what a thread address takes:
/// agents/instructions.ts parseThreadAddress), the same for the same Task.
export const threadTsOf = (task: string): string => {
  const h = createHash("sha256").update(task).digest();
  return `${h.readUInt32BE(0)}.${String(h.readUInt32BE(4) % 1_000_000).padStart(6, "0")}`;
};

export class CommaTasks {
  readonly path: string;
  private readonly file: PrivateFile;
  private kept: Kept = {};

  constructor(path: string) {
    this.path = path;
    this.file = new PrivateFile(path);
    try {
      const v = JSON.parse(readFileSync(path, "utf8")); // sync: read once, before the station serves
      if (v !== null && typeof v === "object" && !Array.isArray(v)) this.kept = v;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") log.warn("comma", "comma tasks file unreadable; starting empty", { error: (error as Error).message });
    }
  }

  /// Kept in memory at once, written off the main thread (those asked while a write is on its way: the latest after it).
  private save() {
    this.file.write(JSON.stringify(this.kept)).catch((error) => {
      log.warn("comma", "comma tasks not kept", { error: (error as Error).message });
    });
  }

  /// Once what was changed is written.
  written(): Promise<void> {
    return this.file.written();
  }

  get(connect: string, task: string): Task | null {
    return this.kept[connect]?.[task] ?? null;
  }

  /// The Task whose thread here has this ts.
  byThread(connect: string, threadTs: string): Task | null {
    return Object.values(this.kept[connect] ?? {}).find((t) => t.threadTs === threadTs) ?? null;
  }

  /// The connect's Tasks it still takes part in (not left).
  taking(connect: string): Task[] {
    return Object.values(this.kept[connect] ?? {}).filter((t) => t.left !== true);
  }

  /// The station takes part in `task` (again, with an invite made again: what it answered through is kept as the most
  /// said).
  invited(connect: string, task: string, start: Start, answered: number, links?: TaskLinks | null): Task {
    const at = (this.kept[connect] ??= {});
    const had = at[task];
    const keptLinks = links ?? had?.links;
    const t: Task = {
      task, threadTs: had?.threadTs ?? threadTsOf(task), start, fetched: had?.fetched ?? 0,
      answered: Math.max(had?.answered ?? 0, answered), ...(keptLinks ? { links: keptLinks } : {}),
    };
    at[task] = t;
    this.save();
    return t;
  }

  /// Records validated links for a Task; no-op when unchanged.
  setLinks(connect: string, task: string, links: TaskLinks): void {
    const t = this.kept[connect]?.[task];
    if (!t) return;
    if (t.links?.web === links.web && t.links?.app === links.app) return;
    t.links = links;
    this.save();
  }

  /// Comma gave the Task through `through`, and said its session answered it through `answered`.
  given(connect: string, task: string, through: number | null, answered: number | null) {
    const t = this.kept[connect]?.[task];
    if (!t) return;
    if (through !== null) t.fetched = Math.max(t.fetched, through);
    if (answered !== null) t.answered = Math.max(t.answered, answered);
    this.save();
  }

  /// The Task runs elsewhere now (task.leave): nothing of it is taken again.
  left(connect: string, task: string) {
    const t = this.kept[connect]?.[task];
    if (!t || t.left) return;
    t.left = true;
    this.save();
  }

  /// A connect removed: its Tasks with it.
  forget(connect: string) {
    if (!(connect in this.kept)) return;
    delete this.kept[connect];
    this.save();
  }
}
