// The TypeScript reads the station answered before its reader moved to the MoonBit program, kept for the tests
// to compare the program with; what the station itself still runs of it is station/src/read/jobs.ts's.
//
// Background jobs as the pages read them (the Rust station's jobs.rs `shown`, `output_at`, `tail`; admin/views.rs
// `open_jobs`; admin/mod.rs GET /jobs, /jobs/:id, /jobs/:id/log). What a job is comes from its record: the station's
// hub, which runs them, keeps it current, so a read gives the state it last wrote.
import type { Viewer } from "../../src/mesh/credential.ts";
import * as store from "./store.ts";
import type { Json, JobRow, Store } from "./store.ts";
import { HttpError, chats, scopeOfJobNames, shownTitleOf } from "./views.ts";
import type { Lang } from "../../src/ops/i18n.ts";
import { log } from "../../src/ops/log.ts";
import { closeSync, fstatSync, openSync, readFileSync, readSync, statSync } from "node:fs";
import type { JobRow as StationJobRow, Store as StationStore } from "../../src/store/store.ts";
import { rustLines } from "../../src/read/jobs.ts";

export { rustLines };

/// How much of a log `tail` reads at most.
const LOG_BYTES = 64 * 1024;

/// output_at, as the station read it on its main thread before src/read/jobs.ts's went to node:fs/promises.
export function outputAt(path: string): number | null {
  try {
    const meta = statSync(path, { bigint: true });
    if (meta.size === 0n || meta.mtimeNs < 0n) return null;
    return Number(meta.mtimeNs / 1_000_000n);
  } catch {
    return null;
  }
}

/// tail, as the station read it on its main thread before src/read/jobs.ts's went to node:fs/promises.
export function tail(path: string, lines: number): string {
  const now = tailLines(path);
  if (now.length >= lines) return now.slice(now.length - lines).join("\n");
  const before = tailLines(`${path}.1`);
  const all = [...before, ...now];
  return all.slice(Math.max(0, all.length - lines)).join("\n");
}

function tailLines(path: string): string[] {
  let file: number;
  try {
    file = openSync(path, "r");
  } catch {
    return [];
  }
  let bytes: Buffer;
  try {
    let size = LOG_BYTES;
    try {
      size = fstatSync(file).size;
    } catch {
      // Metadata failing: read a bounded portion from the start.
    }
    const from = Math.max(0, size - LOG_BYTES);
    const chunks: Buffer[] = [];
    const piece = Buffer.alloc(64 * 1024);
    try {
      // The job may keep writing while this is read. Stop at the end seen above; later writes are read next time.
      for (let at = from; at < size; ) {
        const n = readSync(file, piece, 0, Math.min(piece.length, size - at), at);
        if (n === 0) break;
        chunks.push(Buffer.from(piece.subarray(0, n)));
        at += n;
      }
    } catch {
      // read_to_end failing keeps what it read.
    }
    bytes = Buffer.concat(chunks);
  } finally {
    closeSync(file);
  }
  return rustLines(new TextDecoder("utf-8").decode(bytes));
}

/// The exit code a job's shell wrote when it ended, if it did (src/jobs/jobs.ts reads it with node:fs/promises).
export function readExit(path: string): number | null {
  try {
    const text = readFileSync(path, "utf8").trim();
    return /^[+-]?\d+$/.test(text) ? Number(text) : null;
  } catch {
    return null;
  }
}

/// The watches running, by session, as the station's own store has them (the pages' `watch` of a watching chat's agent
/// is the MoonBit reader's): the watches' names (oldest first), since when the first runs, when one last gave word
/// (`at`: its latest notice, else its start; a notice is news to the pages, output is not).
export function watching(store: StationStore): Map<string, { names: string[]; since: number; at: number }> {
  const by = new Map<string, StationJobRow[]>();
  for (const job of store.jobsRunning().filter((j) => j.watch)) {
    const list = by.get(job.sessionKey) ?? [];
    list.push(job);
    by.set(job.sessionKey, list);
  }
  const out = new Map<string, { names: string[]; since: number; at: number }>();
  for (const [key, jobs] of by) {
    // A stable sort, as sort_by_key is.
    jobs.sort((a, b) => a.startedAt - b.startedAt);
    const at = Math.max(...jobs.map((j) => Math.max(store.jobNotices(j.id, 1)[0]?.at ?? j.startedAt, j.startedAt)));
    out.set(key, { names: jobs.map((j) => j.name), since: jobs[0]!.startedAt, at });
  }
  return out;
}
/// How many of a job's notices the pages get with it.
const NOTICES_SHOWN = 20;

/// JobRow as serde writes it (the token skipped, `sessionKey` as `session`).
function jobJson(j: JobRow): Json {
  return {
    id: j.id, session: j.sessionKey, name: j.name, command: j.command, cwd: j.cwd, port: j.port, state: j.state, pgid: j.pgid,
    exitCode: j.exitCode, startedAt: j.startedAt, endedAt: j.endedAt, restarts: j.restarts, log: j.log, watch: j.watch,
  };
}

/// shown: a job as the pages show it: its record, what it said lately (newest first) and when its output last grew.
export function shown(s: Store, job: JobRow): Json {
  const v = jobJson(job);
  v.notices = store.jobNotices(s, job.id, NOTICES_SHOWN);
  v.outputAt = outputAt(job.log);
  return v;
}

/// GET /jobs: the jobs still up (running, or a service being started again), newest first, each
/// with the chat it is in as the viewer's list has it (`chat`: its id, title and whether it is archived). Those of the
/// viewer's workspace's chats. The jobs up by the index of their states, and the chats of their sessions alone: read
/// with every job the station ever ran, the whole sidebar and (for a session whose own chat is not listed) the whole
/// archive, this could hold up every device reading the station again.
/// `chats`: each with the chat it is in; without (a device that names it from the sidebar it holds), the jobs alone: the
/// sidebar's items do not need to be read for it.
export function openJobs(s: Store, viewer: Viewer, _lang: Lang, named = true): Json[] {
  // Record what a slow read spent at each stage, including whether it included chats.
  const started = performance.now();
  const slow = (stage: Record<string, unknown>) => {
    const ms = Math.round(performance.now() - started);
    if (ms >= 1_000) log.warn("readers", "a jobs read's stages", { ms, named, ...stage });
  };
  const up = store.upJobs(s, viewer);
  const seen = store.seenBy(s, viewer, up.map((j) => j.sessionKey));
  const open = up.filter((j) => seen(j.sessionKey));
  const looked = Math.round(performance.now() - started);
  if (open.length === 0) return (slow({ up: up.length, looked }), []);
  if (!named) {
    const out = open.map((j) => shown(s, j));
    slow({ up: up.length, open: open.length, looked });
    return out;
  }
  // Each job's chat: the session's own over one it only takes part in, a listed one over an archived one (the last of
  // each, as the sidebar lists them): of the items its session and the chats it takes part in make (views.ts
  // `scopeOfJobNames`), each as the whole list has it. The archive's are read only for a session whose own chat is not listed.
  const keys = new Set(open.map((j) => j.sessionKey));
  const scope = scopeOfJobNames(s, [...keys]);
  const scan = (archived: boolean) => {
    const own = new Map<string, Json>();
    const any = new Map<string, Json>();
    for (const chat of chats(s, viewer, archived, scope, true)) {
      // (named as the list names it, "" where the client says the word: views.ts `shownTitleOf`)
      const named = chat.named;
      const title = named ? shownTitleOf(named.thread, named.firstText ?? null, named.channelName ?? null) : (chat.title ?? null);
      const shownChat = { id: chat.id ?? null, title, archived };
      for (const agent of Array.isArray(chat.agents) ? chat.agents : []) {
        const key = agent?.key;
        if (typeof key !== "string" || !keys.has(key)) continue;
        any.set(key, shownChat);
        if (chat.session === key) own.set(key, shownChat);
      }
    }
    return { own, any };
  };
  const scanStart = performance.now();
  const listed = scan(false);
  const listedMs = Math.round(performance.now() - scanStart);
  const archived = [...keys].some((key) => !listed.own.has(key)) ? scan(true) : null;
  slow({ up: up.length, open: open.length, looked, listedMs, archivedScanned: archived !== null });
  return open.map((j) => {
    const v = shown(s, j);
    const k = j.sessionKey;
    const chat = listed.own.get(k) ?? archived?.own.get(k) ?? listed.any.get(k) ?? archived?.any.get(k);
    if (chat !== undefined) v.chat = chat;
    return v;
  });
}

/// GET /jobs/:id: a background job (a web service's own page finds its port by it).
export function job(s: Store, id: string): Json {
  const j = store.getJob(s, id);
  if (j === null) throw new HttpError(404, `no job ${id}`);
  return shown(s, j);
}

/// GET /jobs/:id/log: a job's last output (`lines`, default 200, from 1 to 1000), and that `/events` follows it.
export function jobLog(s: Store, id: string, lines: string | undefined): Json {
  const j = store.getJob(s, id);
  if (j === null) throw new HttpError(404, `no job ${id}`);
  const n = Math.min(Math.max(parseUsize(lines) ?? 200, 1), 1000);
  return { text: tail(j.log, n), outputAt: outputAt(j.log), follows: true, state: j.state };
}

/// `str::parse::<usize>`: digits with a + at most, no bigger than a usize; null otherwise.
export function parseUsize(text: string | undefined): number | null {
  if (text === undefined || !/^\+?\d+$/.test(text)) return null;
  const n = BigInt(text.replace(/^\+/, ""));
  return n > 18446744073709551615n ? null : Number(n);
}
