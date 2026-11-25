// One chat read from a station's copy that this station keeps (replica/AGENTS.md "One chat from a copy"), for a
// handoff prompt on another station while that station is away (handoff.ts). The MoonBit program reads it off the main
// thread (`--builder replica-chat`, station/mb/src/replica/chat.mbt): it folds the newest generation's batches in a
// scratch database and takes out only the chat's thread row, its last entries of people and agents, and its sessions,
// each part bounded. No TypeScript fallback.
import { sep } from "node:path";
import { MbProcess, resolveReaderSelectionAsync } from "../read/mb-reader.ts";
import type { ReaderSelectConfig } from "../read/reader-select.ts";
import type { Head } from "./format.ts";
import type { Held, Holding } from "./places.ts";

type Json = any;

/// How many of the chat's last entries a reading takes at most, how many bytes of each one's text, and how many bytes the
/// whole reading is at most (older entries are left out first). The program holds to these; the answer over the mesh
/// and the prompt are made of no more.
export const CHAT_ENTRIES = 60;
export const CHAT_TEXT = 4_000;
export const CHAT_BYTES = 128 * 1024;
/// A reading as it crosses the mesh, at most: the bound above and room for its JSON.
export const CHAT_MOST = CHAT_BYTES + 64 * 1024;
/// How many of a chat's sessions a reading names at most, and how many files of one entry.
export const CHAT_SESSIONS = 20;
export const CHAT_FILES = 10;

/// The generation a chat is read from in what a station holds of `origin`'s copy in `ws` (`held`, its generations
/// oldest first): the newest whose head is of that copy and names only batches held there; undefined where none is.
export function newestWhole(held: Held, ws: string, origin: string): (Holding & { head: Head }) | undefined {
  return held.gens.filter((g): g is Holding & { head: Head } => g.head !== null && g.head.gen === g.gen && g.head.origin === origin && g.head.workspace === ws && g.head.batches.every((b) => g.batches.includes(b))).at(-1);
}

/// An entry of the chat as the copy holds it: a message, or an edit of the message `target`. `cut`: its text was cut to
/// CHAT_TEXT bytes. `files`: the names of the files it attached (the files themselves are not read).
export type ChatEntry = { n: number; kind: string; target: number | null; author_kind: string; author: string; text: string; cut: boolean; at: number; files: string[] };
/// A session of the chat as the copy holds it: where it worked on its station (`cwd`, `workspace`), and with what.
export type ChatSession = { key: string; runtime: string | null; model: string | null; effort: string | null; title: string | null; cwd: string | null; workspace: string | null; archived_at: number | null; left_at: number | null };
export type ChatThread = { id: number; title: string | null; auto_title: string | null; created_by: string | null; created_at: number; archived_at: number | null };
/// What a reading gives: which copy it is of (`origin`, `workspace`, `gen`; the station's `name` in it; `made`: when the
/// copy was made, `to`: how far it goes), the chat's thread (null: the copy holds no such chat), its last entries oldest
/// first (`earlier`: how many before them are left out), and its sessions.
export type ChatCopy = { origin: string; workspace: string; gen: string; name: string; made: number; to: number; thread: ChatThread | null; entries: ChatEntry[]; earlier: number; sessions: ChatSession[] };
/// What a keeper answers when asked for a chat of a copy: the reading; "none", it keeps no copy of that station; "newer",
/// the copy's newest head is of a format newer than the keeper reads (the keeper is to be updated first).
export type ChatReading = ChatCopy | "none" | "newer";

const text = (v: unknown, most: number): string | null => (typeof v === "string" ? (v.length > most ? v.slice(0, most) : v) : null);
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

/// A reading as another station answered it, its shape checked and every part held to the bounds above; null where it
/// is not one.
export function asChatCopy(v: Json): ChatCopy | null {
  if (v === null || typeof v !== "object" || Array.isArray(v)) return null;
  if (typeof v.origin !== "string" || typeof v.gen !== "string") return null;
  const t = v.thread;
  const thread: ChatThread | null = t === null || typeof t !== "object" || num(t.id) === null
    ? null
    : { id: t.id, title: text(t.title, 1_000), auto_title: text(t.auto_title, 1_000), created_by: text(t.created_by, 400), created_at: num(t.created_at) ?? 0, archived_at: num(t.archived_at) };
  const entries: ChatEntry[] = (Array.isArray(v.entries) ? v.entries : []).slice(-CHAT_ENTRIES).flatMap((e: Json): ChatEntry[] => {
    if (e === null || typeof e !== "object" || num(e.n) === null) return [];
    return [{
      n: e.n,
      kind: e.kind === "edit" ? "edit" : "message",
      target: num(e.target),
      author_kind: e.author_kind === "agent" ? "agent" : "person",
      author: text(e.author, 400) ?? "",
      text: text(e.text, CHAT_TEXT) ?? "",
      cut: e.cut === true,
      at: num(e.at) ?? 0,
      files: (Array.isArray(e.files) ? e.files : []).slice(0, CHAT_FILES).flatMap((f: unknown) => (typeof f === "string" ? [f.slice(0, 300)] : [])),
    }];
  });
  const sessions: ChatSession[] = (Array.isArray(v.sessions) ? v.sessions : []).slice(0, CHAT_SESSIONS).flatMap((s: Json): ChatSession[] => {
    if (s === null || typeof s !== "object" || typeof s.key !== "string") return [];
    return [{ key: s.key.slice(0, 200), runtime: text(s.runtime, 40), model: text(s.model, 200), effort: text(s.effort, 40), title: text(s.title, 1_000), cwd: text(s.cwd, 2_000), workspace: text(s.workspace, 2_000), archived_at: num(s.archived_at), left_at: num(s.left_at) }];
  });
  return {
    origin: v.origin,
    workspace: typeof v.workspace === "string" ? v.workspace : "",
    gen: v.gen,
    name: text(v.name, 200) ?? "",
    made: num(v.made) ?? 0,
    to: num(v.to) ?? 0,
    thread,
    entries,
    earlier: Math.max(0, Math.trunc(num(v.earlier) ?? 0)),
    sessions,
  };
}

/// The chat `thread` of the copy whose generation is in `dir` (its `head.json` and `log/`), read by the program in a
/// process of its own, its scratch database at `work` (the program removes it; so does the caller). Settled only once the
/// program has ended; `signal` kills it.
export async function readChatSoon(o: {
  dir: string;
  work: string;
  thread: number;
  shellDir: string;
  readers?: ReaderSelectConfig | (() => ReaderSelectConfig);
  binary?: string;
  signal?: AbortSignal;
}): Promise<ChatCopy> {
  const binary = (await resolveReaderSelectionAsync("replica-chat", { binary: o.binary, config: o.readers, logAt: "replica" }, o.signal)).primaryBinary;
  return new Promise((resolve, reject) => {
    if (o.signal?.aborted) return reject(new Error("called off"));
    const p = new MbProcess(binary, [
      "--builder", "replica-chat", "--dir", o.dir, "--work", o.work, "--thread", String(o.thread),
      "--entries", String(CHAT_ENTRIES), "--text", String(CHAT_TEXT), "--bytes", String(CHAT_BYTES),
      "--sep", sep, "--shell-dir", o.shellDir,
    ]);
    // (what it comes to, the first thing told: given once the program has ended)
    let outcome: (() => void) | null = null;
    const decide = (f: () => void) => {
      if (outcome === null) outcome = f;
    };
    const stop = () => {
      decide(() => reject(new Error("called off")));
      p.kill();
    };
    o.signal?.addEventListener("abort", stop, { once: true });
    p.on("message", (m: { chat?: Json; error?: string }) => {
      if (m.error !== undefined) return decide(() => reject(new Error(m.error)));
      const chat = asChatCopy(m.chat);
      decide(() => (chat === null ? reject(new Error("the chat's reading said nothing of the copy")) : resolve(chat)));
    });
    let ended = false;
    const end = () => {
      if (ended) return;
      ended = true;
      o.signal?.removeEventListener("abort", stop);
      outcome!();
    };
    p.on("error", (e: Error) => {
      decide(() => reject(e));
      end();
    });
    p.on("exit", (code: number) => {
      decide(() => reject(new Error(`the chat's reading ended saying nothing (${code})`)));
      end();
    });
  });
}
