// The TypeScript reads the station answered before its reader moved to the MoonBit program, kept for the tests
// to compare the program with; what the station itself still runs of it is station/src/read/machine.ts's.
//
// Sessions this machine's own Claude Code and Codex keep (run in a terminal, in ~/.claude and ~/.codex), for a person
// to go on with one in a chat: ported from the Rust station's machine_sessions.rs (`list`, `find`, `conversation` and what
// they read with), and the routes' answers (admin/mod.rs GET /machine-sessions, GET /machine-sessions/:runtime/:id).
// Only read; blocking (many transcripts), so it runs in a reader thread.
//
// Directories are read in the order the file system gives (opendir, as Rust's read_dir), not sorted: which of equally
// recent files comes first, and which project a Claude session is found in first, stay the Rust's.
import { join } from "node:path";
import { type Lang, tr } from "../../src/ops/i18n.ts";
import { type Json, type Store, sessionOfRuntime } from "./store.ts";
import { HttpError } from "./views.ts";
import { parseIso } from "../../src/read/transcript.ts";
import { type Runtime, type Roots, roots, type MachineSession, str, get, parse, extension, readDir, lines, hasCodexEvents, said, stamp, rolloutsIn, read, codexNames, named, find } from "../../src/read/machine.ts";

export * from "../../src/read/machine.ts";
export { type Runtime, type Roots, roots, type MachineSession, str, get, parse, extension, readDir, lines, hasCodexEvents, said, stamp, rolloutsIn, read, codexNames, named, find };

/// transcript.rs parse_iso: milliseconds of an ISO time (YYYY-MM-DDTHH:MM:SS[.fff]), read by position.
export { parseIso };

/// conversation: what was said in a session's transcript, oldest first: people's messages, and each turn's words of
/// the agent in one message.
function conversation(runtime: Runtime, path: string): Json[] {
  const records = lines(path).map(parse).filter((r) => r !== undefined);
  const events = runtime === "codex" && hasCodexEvents(records);
  const out: { person: boolean; text: string; at: number | null }[] = [];
  for (const r of records) {
    const ts = str(get(r, "timestamp"));
    const at = ts === null ? null : parseIso(ts);
    for (const [person, text] of said(runtime, events, r)) {
      const last = out.at(-1);
      if (last && !person && !last.person) last.text += `\n\n${text}`;
      else out.push({ person, text, at });
    }
  }
  return out;
}

/// list: the machine's sessions, most recently written first, at most `limit`: those that ran somewhere and asked
/// something.
function list(r: Roots, limit: number): MachineSession[] {
  const files: [Runtime, string, number, number][] = [];
  for (const dir of readDir(r.claude)) {
    const d = join(r.claude, dir.name);
    for (const file of readDir(d)) {
      const path = join(d, file.name);
      if (extension(file.name) !== "jsonl") continue;
      const st = stamp(path);
      if (st) files.push(["claude", path, st[0], st[1]]);
    }
  }
  const rollouts: string[] = [];
  rolloutsIn(r.codex, rollouts);
  for (const path of rollouts) {
    const st = stamp(path);
    if (st) files.push(["codex", path, st[0], st[1]]);
  }
  files.sort((a, b) => b[2] - a[2]);
  const names = codexNames(r);
  // Codex may keep a thread in more than one file: the latest written stands for it.
  const seen = new Set<string>();
  const out: MachineSession[] = [];
  for (const [runtime, path, at, size] of files) {
    if (out.length >= limit) break;
    const s = read(runtime, path, at, size);
    if (s === null || seen.has(`${s.runtime}\0${s.id}`)) continue;
    seen.add(`${s.runtime}\0${s.id}`);
    out.push(named(s, names));
  }
  return out;
}

/// A MachineSession as serde writes it: `path` skipped.
function shown(s: MachineSession): Json {
  const { path: _, ...rest } = s;
  return rest;
}

// ---- the routes' answers (admin/mod.rs) ----

/// GET /machine-sessions: the machine's latest 100, each with the station's session already going on with it.
export function machineSessions(s: Store, source: Roots = roots()): Json {
  const found = list(source, 100);
  // The session going on with each, by the index of runtime sessions (the latest active of two): every session the
  // station ever had was read with its runtime sessions for it, 1,500 on a station, 14 s (2026-11-03).
  for (const m of found) m.session = sessionOfRuntime(s, m.runtime, m.id);
  return { sessions: found.map(shown) };
}

/// GET /machine-sessions/:runtime/:id: one of them to look at before going on with it: what was said, the latest
/// `limit` (a usize, default 200, 1–1000).
export function machineSession(s: Store, lang: Lang, runtime: string, id: string, limitParam: string | undefined): Json {
  if (runtime !== "claude" && runtime !== "codex") throw new HttpError(404, `no runtime ${runtime}`);
  // str::parse::<usize>: digits, a `+` before them at most, no more than a u64 holds; else the default.
  const asked = limitParam !== undefined && /^\+?[0-9]+$/.test(limitParam) && BigInt(limitParam) <= 18446744073709551615n ? BigInt(limitParam) : 200n;
  const limit = Number(asked < 1n ? 1n : asked > 1000n ? 1000n : asked);
  const found = find(roots(), runtime, id);
  if (found === null) throw new HttpError(404, tr(lang, "station.admin.noLocalSession", { id }));
  const said = conversation(runtime, found.path);
  found.session = sessionOfRuntime(s, runtime, found.id);
  const total = said.length;
  return { session: shown(found), total, said: said.slice(Math.max(0, total - limit)) };
}
