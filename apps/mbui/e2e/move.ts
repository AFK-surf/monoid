// A station's things moved to another station of its workspace and back, end to end on real processes, with faults
// (scripts/e2e-local.sh move, after up with moving switched on; move-all, the side run's). The drill of
// station/src/move/AGENTS.md: the test station A, a second whole station B enrolled beside it (the app's command), and
// a third, C, whose data is a small APFS volume of its own; alice (owner) on a device (e2e/device.ts: still.fail's TS
// core in Node) and bob (a member) on another. Everything a person does is done through the core's calls and topics
// (move.start, move.back, move.stop, `stationMove`, the chat list, chat.send); what an agent does, by the fake agent's
// words (e2e/fake/claude.mjs: drill-*); what is checked is read of the stations themselves: their databases (read
// only), their files on disk (handover/out and in, move/last.json, the chats' rooms), their processes (the jobs'), and
// what their agents were handed ($FAKE_DUMP.turns).
//   1 the page's data: what moves A→B with true counts, B offered, bob refused;
//   2 one chat (messages, transcript, a file, a git worktree of the repos cache with a commit no remote has and a change
//     not committed, a job) there and back, a rename and a pin sent to A while it is held (A's still) ending up on B; 2k one on a login that cannot be shared, back on A while that login is on B;
//   3 faults, each on a chat of its own and from a state checked clean: n none (a 300 MB room moved with its needs), a B
//     killed in the first pass, b A killed while the chat is held, c B killed as
//     it took the chat, d move.stop in the first pass, e C without room, f A handed over to a fresh process (SIGUSR2 to
//     its launcher) in an agent's turn and in a move's;
//   3h C on a sparse volume over the floor, its disk filled by allocation once a chat's first pass began there: the
//     hand-over fails, the chat on A answering, nothing of it on C, C's room back once the filler goes;
//   4 everything (all) to B and all back; 4s a Slack connect on Slack's stand-in (e2e/slack-stand-in.ts, each station
//     pointed at a port of its own): a chat of it moved alone and answered from B through A's connect, the connect
//     refused before its chats and moved after them (an event a second across it), back, B killed between, A killed
//     during, A handed over while B answers; a single-session one moved first with what is said meanwhile kept;
//   5 measured, printed: a 500 MB / 5,000-file room's first pass and pause, 300 chats moved with all, GET /move (the
//     `stationMove` topic's first answer, and station_move plan) with 300 and 2,400 chats.
//   6 a chat moved to a B that still holds a retired copy of it (its row `retired:`, entries only B has, an older room
//     and transcript: e2e/move-stale.ts) and back: listed once, every entry once in order, the room exact, its context.
//   6b a chat whose key is live on both: shown as one that cannot move, a move refused, B untouched;
//   7 one station asking another each second while the other is handed to a new process, stopped and started, and
//     handed to one that dies at start: each ask answered or refused within 2 s, answered again within 5 s of it ready;
//     7h: asked as each of 10 handovers begins (its launcher's "handing over from Node"): every such ask answered;
//   8 a device away while a chat moves A→B, A down as it comes back, with no place in B's stream B can go on from (8:
//     never told by B; 8r: told, its place taken out as B's log moving past it would): it lists the chat once, on B,
//     which only B's list read can tell it (its session's `from`).
//   9 single-chat moves A→B, one turn each with no pause: one batch while both stations are handed to their next
//     process again and again (the invariant), then (9p) one handover a batch, of A or of B, at each phase of a turn,
//     and (9a) an agent's station_move calls: every chat in sight on one station, what A says went in sight on B,
//     failed moves told in words and moved on a second ask, the window counted as met; the moves tallied;
//   9m the real run's limbo (A says it went, its hand-over failed and never shown, B dropped it) made on a build of
//     main held at its hand-over's test hook (e2e/move-drill-hold.patch, E2E_MOVE_LIMBO_DIST, E2E_DRILL_HOLD; skipped
//     without), then A's own build started on it: in sight on A again, once, nothing on B, and it moves.
// Each check says PASS or FAIL with what was seen; a failed one does not stop the next where that can go on alone.
// E2E_SF_SRC, E2E_ORIGIN, E2E_PEER_DATA as peer.ts; E2E_WORK, E2E_STATION as e2e-local.sh's. E2E_MOVE_ONLY: the
// parts to run (e.g. "1 2 3a 5"; all of them where unset).
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, rmSync, statSync, statfsSync, unlinkSync, unwatchFile, watch, watchFile, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { check as checked, deadline, Device, dir, fail, failures, heldProbe, type J, log, whenChanged, within } from "./device.ts";
import { type Call, SlackStandIn } from "./slack-stand-in.ts";

const WORK = process.env.E2E_WORK!;
// The last line the drill said: what a limit that passes names as waited for (each wait says itself as it begins).
let lastSaid = "";
const said0 = console.log;
console.log = (...xs: unknown[]) => {
  lastSaid = xs.map(String).join(" ");
  said0(...xs);
};
/// The run's limit (E2E_MOVE_LIMIT, the harness's, less a minute to say it) and each part's (`limit`): past one, it fails
/// by name with what it was waiting for and the run ends, what the part left half done being no state to go on from.
/// A step that holds the thread itself (a synchronous child) is bounded by its own timeout (`stationDo`) and, past all,
/// by the harness's limit (scripts/e2e-local.sh move).
const over = (what: string, s: number) => {
  fail(`${what}: over its limit of ${s} s`, new Error(`waiting for: ${lastSaid.trim()}`));
  log(`${failures()} FAILED`);
  process.exit(1);
};
const runLimit = Math.max(60, Number(process.env.E2E_MOVE_LIMIT ?? 14400) - 60);
deadline(runLimit * 1000, () => over("the run", runLimit));
let partOver = () => {};
const limit = (what: string, s: number) => {
  partOver();
  log(`${what}: begins, its limit ${s} s`);
  partOver = deadline(s * 1000, () => over(what, s));
};
/// scripts/e2e-local.sh's words (crash, again, halt, second-station …), its last line logged; failed past `ms` (a
/// station that does not start, or a child that keeps the pipe open: drill 8's `again station` held it 2 h 38 min).
const stationDo = (what: string, ...more: string[]) => {
  const ms = 180_000;
  const r = spawnSync("scripts/e2e-local.sh", [what, ...more], { encoding: "utf8", timeout: ms, killSignal: "SIGKILL", env: { ...process.env, HOME: process.env.E2E_HOME ?? process.env.HOME } });
  const last = `${r.stdout ?? ""}${r.stderr ?? ""}`.trim().split("\n").pop();
  if (r.error !== undefined || r.status !== 0) throw new Error(`e2e-local.sh ${what} ${more.join(" ")}: ${r.error?.message ?? `exit ${r.status}`}${r.signal ? ` (${r.signal}, past ${ms / 1000} s?)` : ""}: ${last}`);
  log(`  station: ${last}`);
};

const ST = process.env.E2E_STATION!;
const RUN = `${WORK}/run`;
const DATA = { A: `${ST}/data`, B: `${ST}-b/data`, C: `${ST}-third/data` } as const;
type Name = keyof typeof DATA;
const SHELL_NAME: Record<Name, string> = { A: "station", B: "second", C: "third" };
const FAKE = `${ST}/fake-claude.jsonl`;
const only = (process.env.E2E_MOVE_ONLY ?? "").split(/\s+/).filter((x) => x !== "");
const part = (p: string) => only.length === 0 || only.includes(p) || only.includes(p.replace(/[a-z]$/, ""));
const real = (p: string) => {
  try {
    return realpathSync(p);
  } catch {
    return p;
  }
};
const under = (path: string, n: Name) => path.startsWith(`${DATA[n]}/`) || path.startsWith(`${real(DATA[n])}/`);
const at = (path: string): Name | "?" => (["A", "B", "C"] as Name[]).find((n) => under(path, n)) ?? "?";

/// A station's database, read only (its WAL as it is): rows as JSON.
function sql(n: Name, query: string): J[] {
  const db = `${DATA[n]}/stillfail.db`;
  if (!existsSync(db)) return [];
  const r = spawnSync("sqlite3", ["-readonly", "-json", "-cmd", ".timeout 10000", db, query], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`sqlite3 on ${n}: ${r.stderr}`);
  return r.stdout.trim() === "" ? [] : JSON.parse(r.stdout);
}
const lit = (s: string) => `'${s.replace(/'/g, "''")}'`;
const sh = (cmd: string, args: string[], cwd?: string) => execFileSync(cmd, args, { encoding: "utf8", cwd, stdio: ["ignore", "pipe", "pipe"] }).trim();
const git = (cwd: string, ...args: string[]) => sh("git", ["-c", "user.name=drill", "-c", "user.email=drill@example.test", ...args], cwd);

/// Where chat `key` stands on station `n`, as its own database says: live (a chat of its, shown), coming (being put in,
/// hidden), handed (it went: its row kept, `handed_over` naming where), none.
function standing(n: Name, key: string): string {
  const row = sql(n, `select ws, workspace from sessions where key = ${lit(key)}`)[0];
  const handed = sql(n, `select station from handed_over where session = ${lit(key)}`)[0];
  if (row === undefined) return handed ? `handed(no row)->${String(handed.station).slice(0, 8)}` : "none";
  const ws = String(row.ws ?? "");
  if (ws.startsWith("coming:")) return "coming";
  if (ws.startsWith("handed:")) return `handed->${String(handed?.station ?? "?").slice(0, 8)}`;
  if (handed) return `live+handed->${String(handed.station).slice(0, 8)}`;
  return "live";
}
const stations = (): Name[] => (["A", "B", "C"] as Name[]).filter((n) => existsSync(`${DATA[n]}/stillfail.db`));
const liveOn = (key: string) => stations().filter((n) => standing(n, key) === "live");
const standings = (key: string) => stations().map((n) => `${n}:${standing(n, key)}`).join(" ");
const roomOn = (n: Name, key: string): string | null => sql(n, `select workspace from sessions where key = ${lit(key)}`)[0]?.workspace ?? null;
const runtimeId = (n: Name, key: string): string | null => sql(n, `select runtime_session_id from sessions where key = ${lit(key)}`)[0]?.runtime_session_id ?? null;

/// The hand-overs of station `n` (handover/out or in), as their files are now.
function handovers(n: Name, side: "out" | "in"): J[] {
  const d = `${DATA[n]}/replica/handover/${side}`;
  const out: J[] = [];
  for (const f of existsSync(d) ? readdirSync(d) : []) {
    if (!f.endsWith(".json")) continue;
    try {
      out.push(JSON.parse(readFileSync(join(d, f), "utf8")));
    } catch {}
  }
  return out;
}
/// Both stations' log lines of the second around `at` (their launchers' logs).
const logsAround = (at: number) => {
  const from = new Date(at - 1000).toISOString(), to = new Date(at + 1000).toISOString();
  return (["station", "second"] as const).flatMap((n) => {
    const f = `${RUN}/${n}.log`;
    return existsSync(f) ? readFileSync(f, "utf8").split("\n").filter((l) => l.slice(0, 24) >= from && l.slice(0, 24) <= to).map((l) => `${n === "station" ? "A" : "B"}: ${l.slice(0, 300)}`) : [];
  }).join("\n    ");
};
/// What both stations hold of chat `key` now, for a failure's facts: its row, where it was handed, the hand-overs out.
const heldOf2 = (key: string) => (["A", "B"] as Name[]).map((n) =>
  `${n}: sessions ${brief(sql(n, `select key, ws, archived_at, came_from, began_on, profile from sessions where key = ${lit(key)}`))}; handed_over ${brief(sql(n, `select * from handed_over where session = ${lit(key)}`))}; out ${brief(handovers(n, "out").filter((o) => (o.keys ?? []).includes(key)).map((o) => ({ id: o.id, step: o.step, ended: o.ended ?? null, at: o.at })))}`).join("\n    ");
const outOn = (n: Name, key: string) => handovers(n, "out").filter((o) => (o.keys ?? []).includes(key)).sort((x, y) => y.at - x.at)[0] ?? null;
const outOf = (key: string) => outOn("A", key);
const filesIn = (n: Name, id: string) => {
  const d = `${DATA[n]}/replica/handover/in/${id}/files`;
  return existsSync(d) ? readdirSync(d).length : 0;
};

/// Of the hand-overs out of `sender` begun from `from` to `to` (their id's time), in the order begun, cut in ten: each
/// tenth's median of what each step took as the sender's own record says (`began`, its clock: from a step's begin to
/// the next one's, the last to `done`), and of what each kind of request took the receiver to answer (its in record's
/// `spent`), with the whole run's mean of each beside: the stations' own times, through no file event.
function recordTenths(sender: Name, receiver: Name, from: number, to: number): string[] {
  const begun = (id: string) => parseInt(String(id).split("-")[0] ?? "", 36);
  const outs = handovers(sender, "out").filter((o) => begun(o.id) >= from && begun(o.id) <= to && o.began && typeof o.began === "object").sort((x, y) => begun(x.id) - begun(y.id));
  if (outs.length < 10) return [`${outs.length} hand-overs with their steps' times: too few to cut in ten (a station from before keeps none)`];
  const ins = new Map(handovers(receiver, "in").map((i) => [i.id, i] as const));
  const rows = new Map<string, number[][]>();
  const put = (k: string, tenth: number, ms: number) => {
    const r = rows.get(k) ?? Array.from({ length: 10 }, () => [] as number[]);
    r[tenth]!.push(ms);
    rows.set(k, r);
  };
  outs.forEach((o, i) => {
    const tenth = Math.min(9, Math.floor((i * 10) / outs.length));
    const steps = Object.entries(o.began as Record<string, number>).sort((x, y) => x[1] - y[1]);
    for (let j = 0; j + 1 < steps.length; j++) put(`${sender}: ${steps[j]![0]}`, tenth, steps[j + 1]![1] - steps[j]![1]);
    if (steps.length > 1) put(`${sender}: begin to its last (${steps.at(-1)![0]})`, tenth, steps.at(-1)![1] - steps[0]![1]);
    const spent = ins.get(o.id)?.spent as Record<string, number> | undefined;
    for (const [k, ms] of Object.entries(spent ?? {})) put(`${receiver} answering: ${k}`, tenth, ms);
  });
  const median = (xs: number[]) => (xs.length === 0 ? "-" : String([...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)]));
  const mean = (r: number[][]) => {
    const all = r.flat();
    return all.length === 0 ? "-" : (all.reduce((a, b) => a + b, 0) / all.length).toFixed(1);
  };
  return [`${outs.length} hand-overs by their stations' own times, by tenths, median ms | the run's mean (how many):`,
    ...[...rows.entries()].map(([k, r]) => `${k}: ${r.map(median).join(" ")} | ${mean(r)} (${r.reduce((n, x) => n + x.length, 0)})`)];
}

/// What each hand-over out of a station went through and when (this driver's clock), told by its directory's events.
class Steps {
  readonly seen = new Map<string, { step: string; held: boolean; at: number }[]>();
  #w: ReturnType<typeof watch> | null = null;
  readonly n: Name;
  constructor(n: Name) {
    this.n = n;
    const d = `${DATA[n]}/replica/handover/out`;
    mkdirSync(d, { recursive: true });
    // (the file an event names read alone: reading every record at each event held the drill's process minutes at a
    // time once a station had thousands, drill 25's part 5, its profile: 1,187 s in reading them)
    this.#w = watch(d, (_e, f) => {
      // (a record is written beside itself and renamed into place, `<id>.json.<hex>.tmp` first: that name's event is
      // no record, and taking it for one read every record again at each write, thousands of them in part 5: drill 26's
      // stalls of up to 102 s, each longer than the one before)
      if (typeof f !== "string") return this.scan();
      if (!f.endsWith(".json")) return;
      try {
        this.#take(JSON.parse(readFileSync(join(d, f), "utf8")));
      } catch {}
    });
    this.scan();
  }
  scan(): void {
    for (const o of handovers(this.n, "out")) this.#take(o);
  }
  #take(o: J): void {
    const l = this.seen.get(o.id) ?? [];
    const held = o.held !== false;
    const last = l.at(-1);
    if (last === undefined || last.step !== o.step || last.held !== held) l.push({ step: o.step, held, at: Date.now() });
    this.seen.set(o.id, l);
  }
  of(id: string) {
    return this.seen.get(id) ?? [];
  }
  /// Of the hand-overs begun from `from` to `to` (their id's time, the station's clock), in the order begun, cut in ten:
  /// each tenth's median of each change of step (`files>held*`, … as seen here), of begun to its first record seen, and
  /// of begun to its end, in ms; what a whole move's per-chat time is made of, and which of it grows along the run.
  tenths(from: number, to: number): string[] {
    const begun = (id: string) => parseInt(id.split("-")[0] ?? "", 36);
    const outs = [...this.seen.entries()].filter(([id, l]) => l.length > 0 && begun(id) >= from && begun(id) <= to).sort((x, y) => begun(x[0]) - begun(y[0]));
    if (outs.length < 10) return [`${outs.length} hand-overs seen: too few to cut in ten`];
    const name = (x: { step: string; held: boolean }) => `${x.step}${x.held ? "*" : ""}`;
    const rows = new Map<string, number[][]>();
    const put = (k: string, tenth: number, ms: number) => {
      const r = rows.get(k) ?? Array.from({ length: 10 }, () => [] as number[]);
      r[tenth]!.push(ms);
      rows.set(k, r);
    };
    outs.forEach(([id, l], i) => {
      const tenth = Math.min(9, Math.floor((i * 10) / outs.length));
      put("begun>seen", tenth, l[0]!.at - begun(id));
      for (let j = 1; j < l.length; j++) put(`${name(l[j - 1]!)}>${name(l[j]!)}`, tenth, l[j]!.at - l[j - 1]!.at);
      put("begun>end", tenth, l.at(-1)!.at - begun(id));
    });
    const median = (xs: number[]) => (xs.length === 0 ? "-" : String([...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)]));
    return [`${outs.length} hand-overs, by tenths, median ms (how many of the ${outs.length} had the change):`,
      ...[...rows.entries()].map(([k, r]) => `${k} (${r.reduce((n, x) => n + x.length, 0)}): ${r.map(median).join(" ")}`)];
  }
  close() {
    this.#w?.close();
  }
}

/// How many entries chat `key`'s latest thread has on station `n`.
function entriesOf(n: Name, key: string): number {
  const t = sql(n, `select thread from thread_sessions where session = ${lit(key)} order by joined_at desc limit 1`)[0]?.thread;
  return t === undefined ? 0 : Number(sql(n, `select count(*) n from entries where thread = ${t}`)[0]?.n ?? 0);
}

/// The turns the stations' agents were handed ($FAKE_DUMP.turns, e2e/fake/claude.mjs), since `since`.
function turns(since = 0): { at: number; pid: number; session: string; resumed: boolean; cwd: string; text: string }[] {
  const f = `${FAKE}.turns`;
  if (!existsSync(f)) return [];
  return readFileSync(f, "utf8").split("\n").filter((l) => l !== "").map((l) => JSON.parse(l)).filter((t) => t.at >= since);
}

/// The processes of the job tagged `tag` (its command line says drill-job-<tag>), each with the station its working
/// directory is of.
function jobs(tag: string): { pid: number; cwd: string; on: Name | "?" }[] {
  // (the job's own shell alone, whose argv is `sh -c <its command>` (e2e/fake/claude.mjs's drill-job: a loop, then
  // `: drill-job-<tag>`): what started it may carry the line among its own)
  const mine = new RegExp(`^\\s*(\\d+)\\s+(?:\\S*/)?(?:ba|z)?sh -c while :; do [^;]*; done; : drill-job-${tag}$`);
  // (-ww: ps cuts a long line to the width it guesses otherwise, the tag at its end among what it cut: drill 38)
  let pids = spawnSync("ps", ["-axww", "-o", "pid=,args="], { encoding: "utf8" }).stdout.split("\n").map((l) => mine.exec(l)?.[1]).filter((x): x is string => x !== undefined).map(Number);
  // (else the job as its station keeps it: its process group's leader, where that runs: a station that starts it
  // otherwise than `sh -c <command>`)
  if (pids.length === 0) {
    for (const n of stations()) {
      for (const j of sql(n, `select pgid from jobs where name = ${lit(`drill-${tag}`)} and state = 'running' and pgid is not null`)) {
        try {
          process.kill(Number(j.pgid), 0);
          pids.push(Number(j.pgid));
        } catch {}
      }
    }
    pids = [...new Set(pids)];
  }
  return pids.map((pid) => {
    const l = spawnSync("lsof", ["-nP", "-a", "-p", String(pid), "-d", "cwd", "-Fn"], { encoding: "utf8" }).stdout;
    const cwd = /^n(.*)$/m.exec(l)?.[1] ?? "";
    return { pid, cwd, on: at(cwd) };
  });
}
/// What there is of job `tag` to say where it is not as wanted: every process naming it, and its logs' last lines.
function jobEvidence(tag: string): string {
  const ps = spawnSync("ps", ["-axww", "-o", "pid=,ppid=,args="], { encoding: "utf8" }).stdout.split("\n").filter((l) => l.includes(`drill-job-${tag}`)).map((l) => l.trim().slice(0, 200));
  const logs: string[] = [];
  for (const n of stations()) {
    const d = `${DATA[n]}/jobs/logs`;
    for (const f of existsSync(d) ? readdirSync(d) : []) {
      const t = readFileSync(join(d, f), "utf8");
      if (t.includes(tag) || f.includes(tag)) logs.push(`${n}:${f}: ${t.slice(-400)}`);
    }
    const up = sql(n, `select * from jobs where name = ${lit(`drill-${tag}`)}`);
    if (up.length > 0) logs.push(`${n}'s jobs: ${brief(up, 800)}`);
  }
  return `processes [${ps.join(" | ")}] ${logs.join(" ; ")}`;
}
const jobsText = (tag: string) => jobs(tag).map((j) => `${j.pid}@${j.on}`).join(",") || `none (${jobEvidence(tag)})`;

const lastOn = (n: Name, ws: string): J | null => {
  try {
    return JSON.parse(readFileSync(`${DATA[n]}/move/last.json`, "utf8"))[ws] ?? null;
  } catch {
    return null;
  }
};
const brief = (v: J, most = 600) => JSON.stringify(v)?.slice(0, most);

/// When anything station `n` keeps of moving last changed (the newest file's time in its move/; what they hold is the
/// station's own to keep as it will, never read here).
function moveChanged(n: Name): number {
  const d = `${DATA[n]}/move`;
  let most = 0;
  for (const f of existsSync(d) ? readdirSync(d) : []) {
    try {
      most = Math.max(most, statSync(join(d, f)).mtimeMs);
    } catch {}
  }
  return most;
}
/// What station `n` says is stopped there, as its GET /move answers (`stopped`, its scheduler's: each item `module id`
/// with what it waits for), never its files: the device's last answer of it where it was asked after anything in its
/// move/ last changed, else asked afresh by alice's device, by a page of its chats not read yet (so the core reads it at
/// once, as timeMove's), let go of once answered. (Asked afresh each time, a say in part 5 would plan 2,384 chats in
/// the turn it times.)
async function stoppedOn(n: Name): Promise<{ item: string; waitsFor: string }[]> {
  const t0 = Date.now();
  const last = a.moves.findLast((x) => x.station === idOf(n));
  if (last !== undefined && last.asked > moveChanged(n)) return last.stopped;
  const w = a.watch({ topic: "stationMove", station: addr(n), to: "", module: "chats", limit: 51 + Math.floor(Math.random() * 140) });
  try {
    return (await a.moveSaid(idOf(n), t0, 60_000)).stopped;
  } finally {
    w.stop();
  }
}
/// Where chat `key` is stopped, as GET /move of the station it is shown on says: what it waits for; null where it is not
/// stopped, or its station is down or did not answer (nothing to say then: what waits on it says so itself).
async function stoppedOf(key: string): Promise<string | null> {
  for (const n of stations()) {
    if (standing(n, key) !== "live" || !alive(n)) continue;
    const s = (await stoppedOn(n).catch(() => [])).find((x) => x.item === `chats ${key}`);
    if (s !== undefined) return `stopped on ${n}, waiting for ${s.waitsFor}`;
  }
  return null;
}
/// What station `n`'s GET /move says is stopped, for a log line.
const stoppedText = async (n: Name) => brief(await stoppedOn(n).catch((e) => String(e)), 1200);
/// Whether station `n`'s launcher runs (its pid file, e2e-local.sh's, and that process).
function alive(n: Name): boolean {
  try {
    process.kill(Number(readFileSync(`${RUN}/${SHELL_NAME[n]}.pid`, "utf8").trim()), 0);
    return true;
  } catch {
    return false;
  }
}

/// What log `file` holds past byte `from` (a size statSync gave): read by bytes, not by the characters of a string, which
/// fall short of the bytes once a line says anything but ASCII (drill 22: 3f's wait sliced past the launcher's
/// "started beside" by the bytes of the station's words before it, and never saw it).
const since = (file: string, from: number) => readFileSync(file).subarray(from).toString("utf8");
/// Station `n`'s launcher, by its own process name: the harness's waitfor (its pid file's) carries the same arguments
/// after its `--`, and drill 12 signalled it, so that nothing was handed over.
function launcherOf(n: Name): number | undefined {
  const app = `${dirname(DATA[n])}/app`;
  // (-ww: ps cuts a long line to the width it guesses otherwise, the launcher's `--app` among what it cut: drill 14)
  for (const l of spawnSync("ps", ["-axww", "-o", "pid=,comm=,args="], { encoding: "utf8" }).stdout.split("\n")) {
    const m = /^\s*(\d+)\s+(\S+)\s+(.*)$/.exec(l);
    // (comm is cut to 16 characters on macOS, drill 15: the launcher is known by its argv's first word)
    if (m && m[3]!.split(" ")[0]!.endsWith("/stillfail-station") && m[3]!.includes(` run --app ${app} `)) return Number(m[1]);
  }
  return undefined;
}
/// (Both looked at every 200 ms besides the run directory's events: on the Studio the launcher's lines written by
/// waitfor's tee went untold for whole seconds, a handover seen only at its 10 s deadline, parts 7h and 9, 2026-11-16.)
/// Station `n` sent SIGUSR2 by its launcher's pid, as an update does, and the launcher's word on it from its log (each
/// station's `<name>.log`): it began a handover (a Node started beside the one serving), or the error at once where it
/// said nothing of one in 10 s.
async function handOver(n: Name): Promise<{ from: number; log: string }> {
  const file = `${RUN}/${SHELL_NAME[n]}.log`;
  const from = statSync(file).size;
  const pid = launcherOf(n);
  if (pid === undefined) {
    const mine = spawnSync("ps", ["-axww", "-o", "pid=,comm=,args="], { encoding: "utf8" }).stdout.split("\n").filter((l) => l.includes(dirname(DATA[n]))).map((l) => l.trim().slice(0, 240));
    throw new Error(`${n}'s launcher not found among: ${mine.join(" | ") || "nothing under " + dirname(DATA[n])}`);
  }
  process.kill(pid, "SIGUSR2");
  log(`  SIGUSR2 to ${n}'s launcher ${pid}; waiting for it to begin a handover`);
  await whenChanged([RUN], () => /handover: Node [0-9]+ started beside|not handed over; going on as before/.test(since(file, from)), 10_000,
    () => `${n}'s launcher said nothing of a handover in 10 s: ${since(file, from).split("\n").slice(-5).join(" | ")}`, 200);
  return { from, log: file };
}
/// What `n`'s launcher said since `from` once it said how the handover ended: taken over, or not handed over (its own
/// words: the station's "a chat was not handed over" in the same log is a chat's, drill 19 took it for the launcher's).
function handoverEnd(h: { from: number; log: string }, ms = 120_000): Promise<string> {
  log("  waiting for the handover's end in the launcher's log");
  return whenChanged([RUN], () => /Node [0-9]+ has taken over|not handed over; going on as before[^\n]*|Node [0-9]+ did not take over[^\n]*/.exec(since(h.log, h.from))?.[0], ms,
    () => `no end of the handover said: ${since(h.log, h.from).split("\n").slice(-6).join(" | ")}`, 200);
}

/// A room filled with `count` files of `bytes` bytes each, each its own random bytes (two the same would be sent once).
function fill(room: string, sub: string, count: number, bytes: number): void {
  const d = join(room, sub);
  mkdirSync(d, { recursive: true });
  for (let i = 0; i < count; i++) writeFileSync(join(d, `f${String(i).padStart(5, "0")}.bin`), randomBytes(bytes));
}

/// A check (device.ts `check`), its start said as it begins: the log's last line is always the step under way.
const check = (what: string, body: () => Promise<unknown>) => {
  log(`· ${what}`);
  return checked(what, body);
};

const a = new Device("A");
const bob = new Device("BOB", "bob");
let ws = "";
let A = "";
let aId = "";
// (the drill's own loop held over a second, said as it happens: so a late sighting is placed, the drill's or not)
heldProbe((ms) => log(`  (the drill's own process did nothing else for ${ms} ms)`));
let bId = "";
let cId = "";
let B = "";
let C = "";
const addr = (n: Name) => (n === "A" ? A : n === "B" ? B : C);
const idOf = (n: Name) => (n === "A" ? aId : n === "B" ? bId : cId);
const steps: { A?: Steps; B?: Steps } = {};
const report: string[] = [];
const measured = (s: string) => {
  report.push(s);
  log(`MEASURED ${s}`);
};

const chatT = (key: string) => ({ topic: "chat", station: A, session: key });
/// Chat `key`'s page once `ok` holds of it; at once an error where its station answers it has no such chat (404:
/// drill 13's part 6 waited 120 s and 60 s more on one).
const untilChat = <T>(key: string, ok: (v: J) => T | undefined | null | false, ms = 60_000): Promise<T> => a.until(chatT(key), ok, ms, (e) => e?.status === 404 || e?.code === "http_404");
const texts = (v: J): string[] => (v?.messages ?? []).map((m: J) => String(m.text ?? ""));
const rowsOf = (v: J): J[] => (v?.days ?? []).flatMap((d: J) => d.items ?? []);
const chatsT = () => ({ topic: "chats", scope: ws, mine: false });
const moveT = (to: string, module = "chats", limit?: number) => ({ topic: "stationMove", station: A, to, module, ...(limit ? { limit } : {}) });

/// What chat `key` was answered after `text` was said in it by alice's device (aimed at A, where it began: the core
/// sends it on to where it is): the first new message beginning `prefix`.
/// It fails at once where no answer can come: what was said failed in the outbox, or the chat is stopped where it is
/// (what GET /move's `stopped` of its station says), saying why.
async function say(key: string, text: string, prefix: string, ms = 120_000): Promise<string> {
  log(`  saying ${text.slice(0, 80)}, waiting for ${prefix}`);
  const before = new Set(texts(await untilChat(key, (v) => v?.messages && v, 60_000)));
  const stopped0 = await stoppedOf(key);
  if (stopped0 !== null) throw new Error(`no answer can come: the chat is ${stopped0} (${standings(key)})`);
  await a.call("chat.send", { station: A, session: key, text });
  // (the chat stopped meanwhile, as GET /move of its station says, asked again as what its station keeps of moving
  // changes, one ask at a time; a wait that never ends otherwise. Let go of at the next change once the answer came)
  let over = false;
  const stops = new Promise<{ stopped: string }>((resolve) => {
    let looking = false;
    let again = false;
    const look = async () => {
      if (looking) return void (again = true);
      looking = true;
      do {
        again = false;
        const s = await stoppedOf(key).catch(() => null);
        if (s !== null && !over) return resolve({ stopped: s });
      } while (again && !over);
      looking = false;
    };
    whenChanged(stations().map((n) => `${DATA[n]}/move`), () => over || void look(), ms + 5_000, () => "").catch(() => {});
  });
  const answered = untilChat(key, (v) => texts(v).find((t) => t.startsWith(prefix) && !before.has(t)) ?? failedSend(v, text), ms);
  const got = await Promise.race([answered, stops]).finally(() => void (over = true));
  if (typeof got !== "string") {
    if ("stopped" in got) throw new Error(`no answer can come: the chat is ${got.stopped} (${standings(key)})`);
    throw new Error(`what was said did not go: ${got.failed}`);
  }
  return got;
}
/// A message of the outbox that the core says failed (the station refused it): why, at once, never a wait for good.
function failedSend(v: J, text: string): { failed: string } | undefined {
  const o = (v?.outbox ?? []).find((x: J) => x.text === text && x.state === "failed");
  return o === undefined ? undefined : { failed: String(o.error ?? v?.failed ?? "failed") };
}
/// A chat made on A whose agent answered once: its session key as the station has it.
async function newChat(label: string, profile?: string): Promise<string> {
  const { key: made } = await a.call("chat.create", { station: A, runtime: "claude", ...(profile ? { profile } : {}) });
  await a.call("chat.send", { station: A, session: made, text: `drill-seed:${label}` });
  const v = await a.until({ topic: "chat", station: A, session: made }, (v) => failedSend(v, `drill-seed:${label}`) ?? (texts(v).some((t) => t.startsWith(`drill-seeded ${label}`)) && typeof v?.key === "string" && typeof v?.thread?.id === "number" && v), 120_000);
  if (v.failed !== undefined) throw new Error(`a new chat on A did not take its first message: ${v.failed}`);
  // (named, as a person does: a chat left unnamed has its agent asked for a title, which is no move's)
  await a.call("chat.rename", { station: A, thread: v.thread.id, title: `drill ${label}` });
  return v.key as string;
}
/// A Claude login of station `n`'s own in its config.json (a profile and its home with a credentials file, as the
/// harness's `up` gives A its `cc`): written while that station is stopped.
function addLogin(n: Name, id: string): void {
  const path = `${DATA[n]}/config.json`;
  const cfg = JSON.parse(readFileSync(path, "utf8"));
  cfg.profiles = [...(cfg.profiles ?? []).filter((p: J) => p.id !== id), { id, runtime: "claude", home: `homes/${id}`, models: ["claude-sonnet-5-5"] }];
  writeFileSync(path, JSON.stringify(cfg, null, 2));
  mkdirSync(`${DATA[n]}/homes/${id}`, { recursive: true });
  writeFileSync(`${DATA[n]}/homes/${id}/.credentials.json`, "{}");
}
/// The device's rows of chat `key` once `ok` holds of them (or the time is up: an error saying what they were).
async function listed(key: string, ok: (rows: J[]) => boolean, ms = 90_000, what = "as wanted"): Promise<J[]> {
  log(`  waiting for alice's list to show ${key.slice(-8)} ${what}`);
  let seen: J[] = [];
  try {
    return await a.until(chatsT(), (v) => {
      seen = rowsOf(v).filter((r) => r.session === key);
      return v?.days && ok(seen) && seen;
    }, ms);
  } catch {
    throw new Error(`the device lists it as ${brief(seen.map((r) => ({ station: r.station, title: r.title })))}`);
  }
}
const listedOnceOn = (key: string, n: Name, ms?: number) => listed(key, (r) => r.length === 1 && r[0].station === addr(n), ms, `once, on ${n}`);

/// Until hand-over `key`'s first pass to `to` is under way: `to` has files of it and A has not held it yet. At once an
/// error where it cannot come: its hand-over failed, or the turn asked at `t0` ended.
async function firstPass(key: string, t0: number, to: Name = "B"): Promise<J> {
  log(`  waiting for ${key.slice(-8)}'s first pass to ${to} (files there, not held)`);
  const got = await whenChanged([DATA.A, DATA[to]], () => {
    const o = outOf(key);
    if (o !== null && o.step === "files" && o.held === false && filesIn(to, o.id) > 0) return { o };
    return cannotCome(key, t0);
  }, 180_000, () => `never in its first pass: ${brief(outOf(key))}`);
  if ("why" in got) throw new Error(`no first pass can come: ${got.why}`);
  return got.o;
}
/// Until hand-over `key` is held (its second pass); at once an error where it cannot come, as `firstPass`.
/// `from`: the station it leaves (B as it is moved back: A's turn, B's hand-over).
async function heldOf(key: string, t0: number, from: Name = "A"): Promise<J> {
  log(`  waiting for ${key.slice(-8)} held on ${from} (its second pass)`);
  const got = await whenChanged([DATA.A, DATA[from]], () => {
    const o = outOn(from, key);
    if (o?.held === true && o.at >= t0 - 1000) return { o };
    return cannotCome(key, t0, from);
  }, 300_000, () => `never held: ${brief(outOf(key))}`);
  if ("why" in got) throw new Error(`it can never be held: ${got.why}`);
  return got.o;
}
/// Why hand-over `key` asked at `t0` goes no further: its step failed, or A's turn ended (move/last.json); else false.
function cannotCome(key: string, t0: number, from: Name = "A"): { why: string } | false {
  const o = outOn(from, key);
  if (o !== null && o.at >= t0 - 1000 && o.step === "failed") return { why: `its hand-over ${o.id} failed: ${o.error} (at ${o.done ?? "?"} of ${o.total ?? "?"} bytes)` };
  const l = lastOn("A", ws);
  if (l !== null && l.at >= t0 && !existsSync(`${DATA.A}/move/turn.json`)) return { why: `A's turn ended: ${outcome(l)}; its hand-over ${o?.step}: ${o?.error ?? ""}` };
  return false;
}

/// The end of the move or move back asked of station `n` at `since`: its `last` (move/last.json) once its turn ended.
function turnEnds(n: Name, since: number, ms = 300_000): Promise<J> {
  log(`  waiting for the end of the turn on ${n}`);
  // (on its directory's file events and every second besides: a missed file event left drill 23 seeing a turn's end
  // 215 and 268 s late; what is measured of a turn is the station's own end, `last.at`, whenever it is seen)
  const ended = () => {
    const l = lastOn(n, ws);
    return l !== null && l.at >= since && !existsSync(`${DATA[n]}/move/turn.json`) && l;
  };
  return whenChanged([`${DATA[n]}/move`], () => ended(), ms, () => `no end of the turn asked at ${since} on ${n}: last ${brief(lastOn(n, ws))}, turn ${existsSync(`${DATA[n]}/move/turn.json`) ? readFileSync(`${DATA[n]}/move/turn.json`, "utf8") : "none"}`, 1000);
}
/// Chat `key` moved from A to station `to` by alice's device as the page does it (with what it needs first), and the
/// turn's end; `ms` its deadline.
async function moveChat(key: string, to: Name, ms = 300_000): Promise<J> {
  const t0 = Date.now();
  await a.call("move.start", { station: A, to: idOf(to), module: "chats", item: key, withNeeds: true });
  return turnEnds("A", t0, ms);
}
async function moveBack(key: string, from: Name, module = "chats", ms = 300_000): Promise<J> {
  const t0 = Date.now();
  await a.call("move.back", { station: A, from: idOf(from), module, item: key });
  return turnEnds("A", t0, ms);
}
const named = (x: J) => (typeof x === "string" ? x : `${x?.module} ${x?.id}`);
/// Each item whose move failed in a turn, with its words: `last.failures` (a station that goes on past a failure, every
/// one named), else its one `failed`.
const failuresOf = (l: J): { item: string; error: string }[] =>
  Array.isArray(l?.failures) && l.failures.length > 0 ? l.failures.map((f: J) => ({ item: named(f.item ?? "-"), error: String(f.error) })) : l?.failed ? [{ item: named(l.failed.item ?? "-"), error: String(l.failed.error) }] : [];
/// What a turn said of item `id` failing ("chats <key>"), else of the first that failed; "" where none did.
const failedWhy = (l: J, id?: string) => (failuresOf(l).find((f) => id === undefined || f.item === id) ?? (id === undefined ? undefined : failuresOf(l)[0]))?.error ?? "";
/// A failed turn's `last.lent` against A's login as it is now: what it lists lent must still be lent (A's login shared
/// with the other), none once the lending was taken back (`489f4480e`: `last.lent` is what the turn left lent).
async function lentLeft(l: J): Promise<void> {
  const lent = ((l?.lent ?? []) as J[]).map((x: J) => (typeof x === "string" ? x : named(x)));
  const shared = (JSON.parse(readFileSync(`${DATA.A}/config.json`, "utf8")).profiles ?? []).filter((p: J) => p.share != null && p.share.borrowed !== true && (p.share.allow ?? []).length > 0);
  log(`  the turn's lent ${brief(lent)}; A's logins shared now ${brief(shared.map((p: J) => ({ id: p.id, allow: p.share.allow })))}`);
  if (lent.length > 0 && shared.length === 0) throw new Error(`the turn lists ${lent.join(", ")} lent, and A lends nothing now`);
}
const outcome = (l: J) => `done [${(l?.done ?? []).map(named).join(", ")}]${(l?.lent ?? []).length > 0 ? ` lent [${l.lent.map(named).join(", ")}]` : ""} refused [${(l?.refused ?? []).map((r: J) => `${named(r.item)}: ${r.why}`).join(" | ")}] failed ${failuresOf(l).length > 0 ? failuresOf(l).map((f) => `${f.item}: ${f.error}`).join(" | ") : "none"}${l?.stoppedBy !== undefined ? ` stoppedBy ${l.stoppedBy}` : ""}`;
/// Chat `key` back on A from where it is, with what moved with it (its account, its jobs, its repository): the page's
/// 全部迁回, `move.back {all}` from A's page, until it is live on A and its agent answers there.
async function home(key: string): Promise<void> {
  for (const n of ["B", "C"] as Name[]) {
    if (!existsSync(`${DATA[n]}/stillfail.db`) || standing(n, key) !== "live") continue;
    const t0 = Date.now();
    await a.call("move.back", { station: A, from: idOf(n), all: true });
    const l = await turnEnds("A", t0);
    if (standing("A", key) !== "live") throw new Error(`not back on A: ${standings(key)}; ${outcome(l)}`);
  }
}

/// A's page of moving to B once A has no turn under way (move/turn.json, the station's own word: a wait for the page's
/// `moving` to be none sat out its 120 s before every part after 2 in drill-move-7, no GET /move asked meanwhile). That
/// the page then says nothing moves is a check of its own.
async function atRest(label: string): Promise<J> {
  log(`  ${label}: waiting for A to have no move under way (move/turn.json gone), then for its page`);
  await whenChanged([DATA.A], () => !existsSync(`${DATA.A}/move/turn.json`), 300_000, () => `A's turn still under way: ${readFileSync(`${DATA.A}/move/turn.json`, "utf8").slice(0, 400)}`);
  // (what the page holds read after the turn's end, as A tells `move` changed: else a value of before it, drill 11's
  // "there" and drill 15's missing row of the same chat on the same tree, read before and during the turn)
  const ended = Date.now();
  // (the page as the device holds it from now, each value with when it came: what counts is one that came after the
  // read it waited for, not a value that is merely another object: drill 26's 6b took the device's value of before A's
  // restart, its first read since not yet in, so; the lead, 2026-11-14)
  const held = a.watch(moveT(bId));
  try {
    const v0 = await a.until(moveT(bId), (v) => v?.modules && v, 60_000);
    const read = await a.answered(aId, "/move?", ended - 500, 10_000).then(
      (x) => (log("  A's page read again after its turn's end"), x.at),
      (e) => (log(`  A's page not read again within 10 s of its turn's end (not told it changed?): ${String(e).slice(0, 300)}`), null));
    const after = () => (read === null ? undefined : held.values.find((x) => x.at >= read && x.value?.modules));
    if (read !== null) await whenChanged([], () => after() !== undefined, 2_000, () => "no value after the read", 50).catch(() => undefined);
    var v: J = after()?.value ?? held.values.at(-1)?.value ?? v0;
  } finally {
    held.stop();
  }
  if ((v.moving ?? null) === null) return v;
  let now = v;
  await check(`${label}: A's page says nothing moves once its turn ended`, async () => {
    log(`  the page says moving ${brief(v.moving)} with no turn on A; waiting 10 s for it to be told`);
    now = await a.until(moveT(bId), (x) => x?.modules && (x.moving ?? null) === null && x, 10_000).catch(() => {
      throw new Error(`it says moving ${brief(v.moving)} (${v.note}) and A has no turn: its last ${brief(lastOn("A", ws), 300)}`);
    });
  });
  return now;
}

/// A row of A's page toward B as alice's device is left holding it once A has gone quiet after a turn (`v`, atRest's):
/// where it is not yet as `ok` wants, the device's further reads of the page are waited for (each a telling of A's
/// `move`), up to `ms`, and the newest judged. A first read stale and a later one right is said as a line of its own
/// (STALE …), not a failure: what a person is left looking at is what fails (the lead, 2026-11-14).
async function rowSettled(label: string, v: J, key: string, ok: (row: J) => boolean, module = "chats", ms = 5000): Promise<J> {
  const rowOf = (x: J) => ((x?.modules?.find((m: J) => m.id === module)?.items ?? []) as J[]).find((r: J) => r.id === key);
  const first = rowOf(v);
  if (ok(first)) return first;
  const t0 = Date.now();
  const reads0 = a.answers.filter((x) => x.station === aId && x.path.startsWith("/admin/api/move?")).length;
  const got = await a.until(moveT(bId, module), (x) => x?.modules && ok(rowOf(x)) && x, ms).catch(() => null);
  const reads = a.answers.filter((x) => x.station === aId && x.path.startsWith("/admin/api/move?")).length - reads0;
  if (got === null) return first;
  log(`STALE ${label}: ${key.slice(-8)}'s row read at the turn's end as ${brief(first)}, right ${Date.now() - t0} ms later after ${reads} further read(s) of the page: ${brief(rowOf(got))}`);
  return rowOf(got);
}

/// Each fault from a clean state: whatever of A is on B (the page counts it done) brought back first, all of it.
async function reset(label: string): Promise<void> {
  const v = await atRest(label);
  const there = (v?.modules ?? []).filter((m: J) => m.done > 0);
  if (there.length === 0) return;
  log(`  ${label}: bringing back first ${there.map((m: J) => `${m.id} ${m.done}`).join(", ")}`);
  const t0 = Date.now();
  await a.call("move.back", { station: A, from: bId, all: true });
  log(`  ${outcome(await turnEnds("A", t0))}`);
}

/// Station `n` started again after a fault, until alice's device sees it online.
async function up(n: Name): Promise<void> {
  stationDo("again", SHELL_NAME[n]);
  log(`  waiting for ${n} online on alice's device`);
  await a.until({ topic: "stations", scope: ws }, (v) => (v ?? []).find((s: J) => s.id === idOf(n) && s.online), 120_000);
}

/// What every fault must end with: chat `key` on exactly one station, listed once there, answering there, nothing of
/// it on the other (no row shown, no room, nothing half placed), and its next move succeeding. Each a check of its own.
async function endsWell(label: string, key: string): Promise<void> {
  let on: Name | null = null;
  await check(`${label}: on exactly one station, listed once there`, async () => {
    log(`  waiting for ${key.slice(-8)} shown on one station alone, nothing coming`);
    const live = await whenChanged(stations().map((n) => DATA[n]), () => {
      const l = liveOn(key);
      const coming = stations().some((n) => standing(n, key) === "coming");
      return l.length === 1 && !coming && l;
    }, 180_000, () => `standing ${standings(key)}`);
    on = live[0]!;
    await listedOnceOn(key, on);
    log(`  on ${on}: ${standings(key)}`);
  });
  if (on === null) return;
  const there: Name = on;
  await check(`${label}: answers there`, async () => {
    const n = randomBytes(3).toString("hex");
    const said = await say(key, `drill-note:${label}-${n}`, `drill-noted ${label}-${n}`);
    const cwd = /cwd=(\S+)/.exec(said)?.[1] ?? "";
    if (at(cwd) !== there) throw new Error(`answered from ${at(cwd)} (${cwd}), not ${there}`);
  });
  await check(`${label}: the other stations show nothing of it, nothing half placed`, async () => {
    for (const n of stations()) {
      if (n === there) continue;
      // (what was being put in there, taken out: its hand-over in at rest, its files gone)
      await whenChanged([`${DATA[n]}/replica`], () => !handovers(n, "in").some((i) => (i.keys ?? []).includes(key) && i.step === "coming") && true, 120_000,
        () => `${n}'s hand-over in: ${brief(handovers(n, "in").filter((i) => (i.keys ?? []).includes(key)).map((i) => ({ id: i.id, step: i.step, error: i.error })))}`);
      const st = standing(n, key);
      if (st === "live" || st === "coming") throw new Error(`${n}: ${st}`);
      for (const i of handovers(n, "in").filter((i) => (i.keys ?? []).includes(key))) if (filesIn(n, i.id) > 0 && i.step !== "shown") throw new Error(`${n} keeps ${filesIn(n, i.id)} files of hand-over ${i.id} (${i.step})`);
      const roomThere = roomOn(there, key);
      const mapped = roomThere === null ? null : roomThere.replace(DATA[there], DATA[n]).replace(real(DATA[there]), DATA[n]);
      if (mapped !== null && st === "none" && existsSync(mapped) && readdirSync(mapped).length > 0) throw new Error(`${n} has a room for it at ${mapped} (${readdirSync(mapped).slice(0, 5).join(", ")}) and no chat; ${n}'s hand-overs in of it ${brief(handovers(n, "in").filter((i) => (i.keys ?? []).includes(key)).map((i) => ({ id: i.id, step: i.step })))}, A's out ${brief(handovers("A", "out").filter((o) => (o.keys ?? []).includes(key)).map((o) => ({ id: o.id, step: o.step, dropOwed: o.dropOwed, error: o.error })), 500)}`);
    }
  });
  await check(`${label}: its next move succeeds`, async () => {
    if (there === "A") {
      const l = await moveChat(key, "B");
      if (standing("B", key) !== "live") throw new Error(`${standings(key)}; ${outcome(l)}`);
      await listedOnceOn(key, "B");
    }
    await home(key);
    await listedOnceOn(key, "A");
  });
}

try {
  const signed = await a.signIn();
  ws = signed.workspace;
  A = signed.station;
  aId = A.split("/")[1]!;
  log(`A signed in as ${a.sub}: workspace ${ws}, station ${A}`);
  await a.stationState(ws, (s) => s.state === "online", 120_000);

  limit("setup", 300);
  // ── setup: the chat of check 2 on A with all it is to take along, a vault item, the agent home's skill; B enrolled ──
  const tag = randomBytes(3).toString("hex");
  const secret = `s${tag}`;
  const secretB = `b${tag}`;
  let k2 = "";
  let room2 = "";
  let commit2 = "";
  await check("setup: the chat of check 2 on A: messages, a transcript, a file, a linked worktree with a commit no remote has and a change, a job", async () => {
    k2 = await newChat(`c2-${tag}`);
    await say(k2, `drill-remember:${secret}`, `drill-remembered ${secret}`);
    room2 = roomOn("A", k2)!;
    writeFileSync(join(room2, "notes.txt"), `notes of ${tag}\n`);
    writeFileSync(join(room2, "gone-later.txt"), "deleted on B before it comes back\n");
    // (a repository no station can reach but by this machine's path: its remote for both, as a company's git server)
    const origin = `${WORK}/move-origin.git`;
    if (!existsSync(origin)) {
      sh("git", ["init", "-q", "--bare", origin]);
      const seed = `${WORK}/move-origin-seed`;
      rmSync(seed, { recursive: true, force: true });
      sh("git", ["clone", "-q", origin, seed]);
      writeFileSync(join(seed, "README.md"), "drill\n");
      git(seed, "add", "README.md");
      git(seed, "commit", "-q", "-m", "drill: the remote's first");
      git(seed, "push", "-q", "origin", "HEAD:main");
    }
    // the canonical clone in A's repos cache (sessions/hub.ts reposDir), the chat's worktree hanging on it
    const cache = `${DATA.A}/repos/drill-origin`;
    if (!existsSync(cache)) sh("git", ["clone", "-q", origin, cache]);
    git(cache, "worktree", "add", "-q", "-b", `drill-${tag}`, join(room2, "proj"), "origin/main");
    writeFileSync(join(room2, "proj", "work.txt"), `work of ${tag}\n`);
    git(join(room2, "proj"), "add", "work.txt");
    git(join(room2, "proj"), "commit", "-q", "-m", `drill: a commit no remote has ${tag}`);
    commit2 = git(join(room2, "proj"), "rev-parse", "HEAD");
    writeFileSync(join(room2, "proj", "README.md"), "drill, changed and not committed\n");
    const started = await say(k2, `drill-job:${tag}`, `drill-job ${tag}`);
    await whenChanged([DATA.A], () => jobs(tag).length > 0, 60_000, () => `no job up: ${started.slice(0, 300)}; ${jobEvidence(tag)}`);
    log(`  chat ${k2}, room ${room2}, commit ${commit2.slice(0, 10)}, job ${jobsText(tag)}`);
  });
  let item = "";
  let encrypted = false;
  await check("setup: a vault item alice stored (the plain library, or in safe mode a vault of hers on A) and a skill in A's agent home", async () => {
    const plain = { kind: "token", name: `drill-token-${tag}`, fields: { value: `v-${tag}` }, domains: [], notes: "" };
    const listing = { name: `drill-token-${tag}`, kind: "token", modes: ["proxy"], hosts: ["api.example.test"] };
    // (a workspace in safe mode keeps no plain library: its secrets go in an encrypted vault, its rows opaque to every
    // station, the vault module carrying them as they are: move/vault.ts)
    const put = await a.call("vault.putItem", { workspace: ws, vault: "plain", plain, listing }).catch((e: Error) => {
      if (!/vault_locked/.test(String(e?.message ?? e))) throw e;
      return null;
    });
    if (put !== null) item = put?.id ?? "";
    else {
      encrypted = true;
      await a.call("vault.setup", { workspace: ws });
      await a.until({ topic: "vaults", workspace: ws }, (v) => v?.setUp, 60_000);
      const vault = (await a.call("vault.create", { workspace: ws, name: `drill-${tag}`, station: aId })).id as string;
      item = (await a.call("vault.putItem", { workspace: ws, vault, plain, listing }))?.id ?? "";
    }
    const rows = await whenChanged([DATA.A], () => {
      const r = sql("A", encrypted ? "select id, vault from vault_items" : "select id, owner from vault_plain");
      return r.length > 0 && r;
    }, 60_000, () => `A keeps no ${encrypted ? "vault" : "plain"} item`);
    log(`  item ${item}: A keeps ${brief(rows)}`);
    mkdirSync(`${DATA.A}/agent/skills/drill-skill`, { recursive: true });
    writeFileSync(`${DATA.A}/agent/skills/drill-skill/SKILL.md`, `---\nname: drill-skill\ndescription: the move drill's\n---\n${tag}\n`);
  });
  const enroll = async (n: "B" | "C", name: string) => {
    const before = new Set<string>(((await a.until({ topic: "workspace", workspace: ws }, (v) => v?.stations && v)).stations as J[]).map((s) => s.id));
    let made = await a.call("workspace.enroll", { account: a.sub, workspace: ws, name });
    // (a token beginning with `-` is taken by `stillfail station enroll` for an option, drill 17's `--NS_e6cc…`: a
    // product fault being fixed on main; until then another is asked for, said here)
    for (let i = 0; i < 5 && String(made?.token ?? "").startsWith("-"); i++) {
      log(`  the enrolment token begins with "-" (${String(made.token).slice(0, 6)}…), which the enrol command takes for an option: another asked for`);
      made = await a.call("workspace.enroll", { account: a.sub, workspace: ws, name });
    }
    const file = `${dir}/enroll-${n}.log`;
    mkdirSync(dir, { recursive: true });
    writeFileSync(file, `ANSWER workspace.enroll ok ${JSON.stringify(made)}\n`);
    stationDo("second-station", file, SHELL_NAME[n]);
    const id = (await a.until({ topic: "workspace", workspace: ws }, (v) => (v?.stations ?? []).find((s: J) => !before.has(s.id)), 60_000)).id as string;
    await a.until({ topic: "stations", scope: ws }, (v) => (v ?? []).find((s: J) => s.id === id && s.online), 120_000);
    return id;
  };
  await check("setup: B enrolled beside A with the app's command, on the test channel (moving is on there), online", async () => {
    bId = await enroll("B", "move-b");
    B = `${ws}/${bId}`;
    if (!/"updateChannel":"beta"/.test(readFileSync(`${DATA.B}/config.json`, "utf8"))) throw new Error(`B's config: ${readFileSync(`${DATA.B}/config.json`, "utf8")}`);
    log(`  B ${bId}`);
  });
  if (bId === "") throw new Error("no B: nothing to move to");
  // (no agent-home module since c5e5ba9ce: main keeps the agents' memory and skills the same on every station of a
  // workspace by itself (#6206), so the skill is on B with no move at all)
  await check("setup: the skill in A's agent home is on B by the workspace's own sharing, within 30 s of B enrolled, with no move", async () => {
    const t0 = Date.now();
    const at = `${DATA.B}/agent/skills/drill-skill/SKILL.md`;
    log("  waiting for the skill on B");
    await whenChanged([DATA.B], () => existsSync(at) && readFileSync(at, "utf8").includes(tag), 30_000, () => `not on B: B's agent/skills ${existsSync(`${DATA.B}/agent/skills`) ? readdirSync(`${DATA.B}/agent/skills`).join(", ") : "none"}; B's agent ${existsSync(`${DATA.B}/agent`) ? readdirSync(`${DATA.B}/agent`).join(", ") : "none"}`);
    log(`  on B after ${((Date.now() - t0) / 1000).toFixed(1)} s`);
  });
  steps.A = new Steps("A");
  steps.B = new Steps("B");

  // ── 1: the page's data ──
  if (part("1")) {
    limit("1", 300);
    await check("1: stationMove A→B lists the modules with true counts", async () => {
      const v = await a.until(moveT(bId), (v) => v?.modules?.length > 0 && v, 60_000);
      const chats = v.modules.find((m: J) => m.id === "chats");
      const sessions = sql("A", "select count(*) n from sessions where (ws is null or (ws not like 'handed:%' and ws not like 'coming:%'))")[0].n;
      log(`  modules: ${v.modules.map((m: J) => `${m.id} ${m.done}/${m.total}`).join(", ")}; A's sessions ${sessions}, the job's processes ${jobsText(tag)}`);
      if (chats?.total !== sessions) throw new Error(`chats total ${chats?.total}, A has ${sessions} sessions`);
      const jobsM = v.modules.find((m: J) => m.id === "jobs");
      if (jobs(tag).length > 0 && (jobsM?.total ?? 0) < 1) throw new Error(`a job is up and the jobs module says ${brief(jobsM)}`);
      if ((v.modules.find((m: J) => m.id === "accounts")?.total ?? 0) < 1) throw new Error("no account to move, and A's chats run on one");
      if ((v.modules.find((m: J) => m.id === "vault")?.total ?? 0) < 1) throw new Error("no vault item to move, and alice stored one");
    });
    await check("1: B is offered as a target; alice may move", async () => {
      const v = await a.until(moveT(bId), (v) => v?.targets?.some((t: J) => t.station === bId) && v, 60_000).catch(async () => {
        throw new Error(`targets ${brief((await a.until(moveT(bId), (v) => v, 10_000))?.targets)}`);
      });
      if (v.canMove !== true) throw new Error(`canMove ${v.canMove}`);
    });
    await check("1: a member who is not owner or admin cannot start a move (bob refused, his page offers no move)", async () => {
      await a.call("workspace.addMembers", { account: a.sub, workspace: ws, role: "member", emails: ["bob@example.test"] });
      await bob.signIn();
      const v = await bob.until({ topic: "stationMove", station: A, to: bId, module: "chats" }, (v) => v?.modules && v, 90_000);
      if (v.canMove !== false || (v.allMove ?? null) !== null) throw new Error(`bob's page: canMove ${v.canMove}, allMove ${brief(v.allMove)}`);
      const r = await bob.call("move.start", { station: A, to: bId, module: "chats", item: k2, withNeeds: true }).then((x) => ({ ok: x }), (e) => ({ err: String(e) }));
      if (!("err" in r)) throw new Error(`bob's move.start answered ${brief(r)}`);
      log(`  bob refused: ${r.err.slice(0, 300)}`);
      if (standing("A", k2) !== "live") throw new Error(`the chat moved all the same: ${standings(k2)}`);
    });
  }

  // ── 2: one chat there and back ──
  if (part("2") && k2 !== "") {
    limit("2", 900);
    let arrived = false;
    let movedWith: { module: string; id: string }[] = [];
    let lentWith: string[] = [];
    // (the other chat of A, made by the harness's up: what an item moved away stops here)
    const k0 = sql("A", "select key from sessions").map((r) => r.key as string).find((k) => k !== k2) ?? "";
    let heldNote = "";
    // (a rename and a pin sent to A as the chat is held there, its second pass: still A's, which takes them, the
    // hand-over carrying them; what each answered. Not the moment after A said it went and before the device was told,
    // which a station answers 409 `moved`: no request of a device here can be put in that moment on purpose)
    let heldMarks: { title: string; renamed: string; pinned: string } | null = null;
    let t0 = 0;
    let before: string[] = [];
    const rid = runtimeId("A", k2) ?? "";
    await check("2: the chat moved to B (move.start with what it needs), its turn ending with it there", async () => {
      before = texts(await untilChat(k2, (v) => v?.messages && v));
      for (const t of turns().filter((t) => t.session === rid)) log(`  before the move, handed on ${at(t.cwd)}: ${t.text.replace(/\s+/g, " ").slice(0, 100)}`);
      t0 = Date.now();
      await a.call("move.start", { station: A, to: bId, module: "chats", item: k2, withNeeds: true });
      // a message said while the chat is held: as its hand-over says held (its second pass), at once
      const held = heldOf(k2, t0).then(async (o) => {
        heldNote = `held-${tag}`;
        await a.call("chat.send", { station: A, session: k2, text: `drill-note:${heldNote}` });
        log(`  said while ${o.step}${outOf(k2)?.step !== o.step ? ` (it was ${outOf(k2)?.step} once sent)` : ""}`);
        // (and, in the same moment, a rename and a pin of it named on A, as a device that has not been told does)
        const title = `drill-renamed-${tag}`;
        const said = (p: Promise<J>) => p.then((r) => (r && typeof r === "object" && "err" in r ? `refused: ${JSON.stringify(r.err).slice(0, 160)}` : "ok"), (e) => `failed: ${String(e?.message ?? e).slice(0, 160)}`);
        const [renamed, pinned] = await Promise.all([said(a.call("chat.rename", { station: A, session: k2, title })), said(a.call("chat.pin", { station: A, session: k2, pinned: true }))]);
        heldMarks = { title, renamed, pinned };
        log(`  renamed and pinned while ${outOf(k2)?.step}: rename ${renamed}, pin ${pinned}`);
      });
      held.catch((e) => log(`  ${e.message}`));
      const l = await turnEnds("A", t0);
      await within(held.catch(() => {}), 10_000);
      log(`  ${outcome(l)}; steps ${brief(steps.A!.of(outOf(k2)?.id ?? "").map((s) => `${s.step}${s.held ? "*" : ""}+${s.at - t0}`))}`);
      if (standing("B", k2) !== "live") throw new Error(`${standings(k2)}; ${outcome(l)}`);
      arrived = true;
      movedWith = (l.done ?? []).filter((d: J) => d.module !== "chats");
      // (a login that can be shared is lent, not moved: A stays its host, B borrows it, `last.lent`, 5beeaa8cf)
      lentWith = ((l.lent ?? []) as J[]).map((x: J) => (typeof x === "string" ? x : named(x)));
      const profilesA = (JSON.parse(readFileSync(`${DATA.A}/config.json`, "utf8")).profiles ?? []).map((p: J) => p.id);
      log(`  A's profiles now ${brief(profilesA)}; stopped on A: ${await stoppedText("A")}`);
    });
    if (arrived) {
      await check("2: the login it needs lent to B, not moved: A still hosts it, B borrows it", async () => {
        const prof = (n: Name) => (JSON.parse(readFileSync(`${DATA[n]}/config.json`, "utf8")).profiles ?? []).filter((p: J) => p.runtime === "claude").map((p: J) => ({ id: p.id, share: p.share ?? null }));
        log(`  lent ${brief(lentWith)}; moved ${brief(movedWith.filter((x) => x.module === "accounts"))}; A's ${brief(prof("A"))}; B's ${brief(prof("B"))}`);
        if (movedWith.some((x) => x.module === "accounts")) throw new Error(`the login moved: ${brief(movedWith)}`);
        if (lentWith.length === 0) throw new Error("nothing said lent");
        if (!prof("A").some((p: J) => p.share?.borrowed !== true)) throw new Error(`A hosts no login of its own: ${brief(prof("A"))}`);
        if (!prof("B").some((p: J) => p.share?.borrowed === true)) throw new Error(`B borrows none: ${brief(prof("B"))}`);
      });
      await check("2: the device lists the chat once, on B", () => listedOnceOn(k2, "B"));
      await check("2: nothing was posted into the chat by a station and its agent was not woken by the move", async () => {
        const now = texts(await untilChat(k2, (v) => v?.messages && v));
        const added = now.filter((t) => !before.includes(t) && !t.includes(heldNote || "\u0000"));
        if (added.length > 0) throw new Error(`new in the chat: ${brief(added)}`);
        // (what its agent was handed since the move began, each with what it came of: a message said to it, the
        // station's ask for a title after a turn ended, or nothing anyone said: the move's own)
        const mine = turns(t0).filter((t) => t.session === rid);
        for (const t of mine) log(`  handed on ${at(t.cwd)} (pid ${t.pid}, resumed ${t.resumed}): ${t.text.replace(/\s+/g, " ").slice(0, 160)}`);
        const woke = mine.filter((t) => !(heldNote !== "" && t.text.includes(`drill-note:${heldNote}`)) && !t.text.includes("still has no title"));
        const titled = mine.filter((t) => t.text.includes("still has no title"));
        if (titled.length > 0) log(`  (asked for a title on ${titled.map((t) => at(t.cwd)).join(", ")} after a turn there ended: actor.ts askedToName, kept in its memory alone)`);
        if (woke.length > 0) throw new Error(`its agent was handed what nobody said: ${brief(woke.map((t) => t.text.slice(0, 160)))}`);
      });
      await check("2: a message said while the chat was held arrives once on B, answered once there", async () => {
        if (heldNote === "") throw new Error("no message was said while it was held (never seen held)");
        const v = await untilChat(k2, (v) => texts(v).some((t) => t.startsWith(`drill-noted ${heldNote}`)) && v, 120_000);
        const asked = texts(v).filter((t) => t === `drill-note:${heldNote}`).length;
        const answers = texts(v).filter((t) => t.startsWith(`drill-noted ${heldNote}`));
        const cwd = /cwd=(\S+)/.exec(answers[0] ?? "")?.[1] ?? "";
        if (asked !== 1 || answers.length !== 1 || at(cwd) !== "B") throw new Error(`said ${asked} times, answered ${answers.length} (${brief(answers)})`);
        const handed = turns(t0).filter((t) => t.text.includes(`drill-note:${heldNote}`));
        if (handed.length !== 1) throw new Error(`handed to an agent ${handed.length} times: ${brief(handed.map((t) => `${t.pid}@${at(t.cwd)}`))}`);
      });
      await check("2: a rename and a pin sent to A while the chat is held there end up on B (A takes them, the hand-over's second pass carries them)", async () => {
        const m = heldMarks as { title: string; renamed: string; pinned: string } | null;
        if (m === null) throw new Error("none was sent while it was held (never seen held)");
        const on = (n: Name) => ({
          title: sql(n, `select title from sessions where key = ${lit(k2)}`)[0]?.title ?? null,
          pins: sql(n, `select viewer from pins where session = ${lit(k2)}`).map((r) => r.viewer as string),
        });
        // (B's as its stores say it, waited for as a fact of state: at most 30 s after it is live there)
        const b = await whenChanged([DATA.B], () => {
          const x = on("B");
          return x.title === m.title && x.pins.some((v) => v.startsWith("alice")) && x;
        }, 30_000, () => `on B ${brief(on("B"))}, on A ${brief(on("A"))}; the device was answered: rename ${m.renamed}, pin ${m.pinned}`);
        log(`  on B: ${brief(b)}; the device was answered: rename ${m.renamed}, pin ${m.pinned}`);
      });
      await check("2: a message sent to it is answered on B by its agent going on from its transcript", async () => {
        const nonce = randomBytes(3).toString("hex");
        const said = await say(k2, `drill-recall:${nonce}`, `drill-recall ${nonce} `);
        log(`  ${said}`);
        const cwd = /cwd=(\S+)/.exec(said)?.[1] ?? "";
        if (at(cwd) !== "B") throw new Error(`answered from ${at(cwd)}: ${said}`);
        if (!said.includes(`secret=${secret}`)) throw new Error(`its transcript there lacks what it was told before: ${said}`);
        if (!said.includes("resumed=true")) throw new Error(`a new context, not resumed: ${said}`);
        // (something said on B, for its agent to recall once back on A)
        await say(k2, `drill-remember:${secretB}`, `drill-remembered ${secretB}`);
      });
      await check("2: its file, its commit and its change not committed are there on B, its worktree a working one", async () => {
        const r = roomOn("B", k2)!;
        if (!under(r, "B")) throw new Error(`its room on B is ${r}`);
        if (readFileSync(join(r, "notes.txt"), "utf8") !== `notes of ${tag}\n`) throw new Error("notes.txt differs");
        const head = git(join(r, "proj"), "rev-parse", "HEAD");
        if (head !== commit2) throw new Error(`HEAD ${head}, was ${commit2}`);
        const st = execFileSync("git", ["status", "--porcelain"], { cwd: join(r, "proj"), encoding: "utf8" });
        if (!/^ M README\.md$/m.test(st)) throw new Error(`status: ${JSON.stringify(st)}`);
        const common = git(join(r, "proj"), "rev-parse", "--git-common-dir");
        if (!under(real(join(r, "proj", common)), "B")) throw new Error(`its worktree hangs on ${common}, not of B`);
        log(`  B's worktree hangs on ${common}`);
      });
      await check("2: one chat moved with what it needs leaves A working: A's other chat answers a new message at once, a new chat on A works", async () => {
        // (the lead, 2026-11-14: an own login that can be shared is shared as it moves, A borrowing it; one that cannot
        // is refused in words, never taken along by one chat's move)
        log(`  A's profiles ${brief((JSON.parse(readFileSync(`${DATA.A}/config.json`, "utf8")).profiles ?? []).map((p: J) => ({ id: p.id, share: p.share ?? null })))}`);
        if (k0 !== "") {
          const n = randomBytes(3).toString("hex");
          const said = await say(k0, `drill-note:other-${n}`, `drill-noted other-${n}`, 60_000);
          if (at(/cwd=(\S+)/.exec(said)?.[1] ?? "") !== "A") throw new Error(`A's other chat answered from elsewhere: ${said}`);
        }
        await newChat(`after-move-${tag}`);
      });
      await check("2: the job runs on B and not on A", async () => {
        const j = await whenChanged([DATA.B, DATA.A], () => {
          const l = jobs(tag);
          return l.length === 1 && l[0]!.on === "B" && l;
        }, 120_000, () => `the job's processes: ${jobsText(tag)}`);
        log(`  job ${j[0]!.pid} in ${j[0]!.cwd}`);
      });
      let backed = false;
      await check("2: changed and deleted on B, moved back (move.back of the chat from A's page): on A as it is on B now", async () => {
        const r = roomOn("B", k2)!;
        writeFileSync(join(r, "notes.txt"), `notes of ${tag}, changed on B\n`);
        unlinkSync(join(r, "gone-later.txt"));
        // the chat's own 迁回 on its row first, as a person presses it
        const l = await moveBack(k2, "B");
        log(`  its own 迁回: ${outcome(l)}; ${standings(k2)}`);
        if (standing("A", k2) !== "live") fail("2: the chat's own move back (its row's 迁回) brings it back", new Error(`${standings(k2)}; ${outcome(l)}`));
        // then as its refusal says: what needs it first (its job), then it, the account it runs on still on B
        const job = movedWith.find((x) => x.module === "jobs");
        const account = movedWith.find((x) => x.module === "accounts");
        if (standing("A", k2) !== "live" && job !== undefined) {
          await check("2: its job moved back alone, the chat still on B: where it runs", async () => {
            const lj = await moveBack(job.id, "B", "jobs");
            log(`  ${outcome(lj)}; the job's processes ${jobsText(tag)}; the chat ${standings(k2)}`);
            if (jobs(tag).some((j) => j.on === "A") && standing("B", k2) === "live") throw new Error(`the job runs on A (${jobsText(tag)}) while its chat is on B, its room on A not yet mirrored back`);
          });
          const lc = await moveBack(k2, "B");
          log(`  the chat's 迁回 again: ${outcome(lc)}; ${standings(k2)}`);
        }
        // (an own login that can be shared is shared as it moves, A borrowing it: then this login leaves nothing on A to
        // stop, and the case is to be driven by one that cannot be shared; arriveStopped, the other way the lead named,
        // is forward only and neither POST /move nor station_move takes it yet)
        const borrowed = (JSON.parse(readFileSync(`${DATA.A}/config.json`, "utf8")).profiles ?? []).filter((p: J) => p.runtime === "claude");
        if (account !== undefined && standing("A", k2) === "live" && borrowed.length > 0) {
          log(`  (A hosts the login it lent, ${brief(borrowed.map((p: J) => ({ id: p.id, share: p.share ?? null })))}: back on A nothing waits for it; the stopped path is 2k's, a login that cannot be shared)`);
        }
        if (account !== undefined && standing("A", k2) === "live" && borrowed.length === 0) {
          const nonce = randomBytes(3).toString("hex");
          await check("2: back on A while its account is still on B: stopped, and the person is told so", async () => {
            log(`  A's stopped: ${await stoppedText("A")}`);
            const m = await a.until(moveT(bId), (v) => v?.modules && v, 60_000);
            const row = await rowSettled("2", m, k2, (r) => r?.state === "stopped");
            const chatsM = m.modules.find((x: J) => x.id === "chats");
            log(`  A's page: the chat's row ${brief(row)}; note ${m.note}; its chats ${chatsM?.done}/${chatsM?.total}, the rows it shows ${brief((chatsM?.items ?? []).map((x: J) => `${x.id.slice(-8)} ${x.state}`), 400)}${chatsM?.more ? " and more" : ""}`);
            await a.call("chat.send", { station: A, session: k2, text: `drill-recall:${nonce}` });
            if (k0 !== "") await a.call("chat.send", { station: A, session: k0, text: `drill-note:k0-${nonce}` });
            await whenChanged([DATA.A], () => sql("A", `select count(*) n from entries where text like ${lit(`%drill-recall:${nonce}%`)}`)[0].n > 0, 60_000, () => "the message is not in A's log");
            const v = await untilChat(k2, (v) => v?.messages && v);
            // (what of the chat's page a person reads of where it stands: its line, the line over its composer, what is
            // said under what they sent, its messages since; not the whole value, where a field's name matched before)
            const shown = { stateText: v.stateText ?? null, offlineNote: v.offlineNote ?? null, connection: v.connection ?? null, outbox: (v.outbox ?? []).map((o: J) => `${o.state}${o.waits ? `: ${o.waits}` : ""}`), messages: texts(v).slice(-3) };
            log(`  the chat as the device shows it now: ${brief(shown, 900)}`);
            if (row?.state !== "stopped") throw new Error(`its row on A's page says ${row?.state} (${row?.stateText}), not stopped waiting for its account`);
            const read = [shown.stateText, shown.offlineNote, JSON.stringify(shown.connection), ...shown.outbox, ...texts(v).filter((t) => !t.startsWith("drill-"))].join(" | ");
            // (a line that says it is stopped and names what it waits for: the login, as the move page's row names it)
            const waited = /等「([^」]+)」/.exec(String(row?.stateText ?? ""))?.[1] ?? "cc";
            const telling = read.split(" | ").find((x) => /停|等|stopped|wait/i.test(x) && x.includes(waited));
            log(`  what tells the person: ${brief(telling ?? null, 400)} (lines read: ${read.slice(0, 400)})`);
            if (telling === undefined) throw new Error(`nothing on the chat's page says it is stopped waiting for ${waited}: ${read.slice(0, 400)}`);
          });
          await check("2: its account moved back: the chat goes on, what was said meanwhile answered once, its job on A, A's other chat answers too", async () => {
            const la = await moveBack(account.id, "B", "accounts");
            log(`  ${outcome(la)}; A's profiles ${brief((JSON.parse(readFileSync(`${DATA.A}/config.json`, "utf8")).profiles ?? []).map((p: J) => p.id))}`);
            const v = await untilChat(k2, (v) => texts(v).some((t) => t.startsWith(`drill-recall ${nonce} `)) && v, 120_000);
            const answers = texts(v).filter((t) => t.startsWith(`drill-recall ${nonce} `));
            if (answers.length !== 1 || at(/cwd=(\S+)/.exec(answers[0]!)?.[1] ?? "") !== "A") throw new Error(`answered ${brief(answers)}`);
            if (k0 !== "") await a.until({ topic: "chat", station: A, session: k0 }, (v) => texts(v).filter((t) => t.startsWith(`drill-noted k0-${nonce}`)).length === 1 && v, 120_000);
            await whenChanged([DATA.A], () => jobs(tag).length === 1 && jobs(tag)[0]!.on === "A", 60_000, () => `the job's processes: ${jobsText(tag)}`);
          });
        }
        const t1 = Date.now();
        await a.call("move.back", { station: A, from: bId, all: true });
        log(`  全部迁回 of what is left: ${outcome(await turnEnds("A", t1))}`);
        backed = true;
        const ra = roomOn("A", k2)!;
        if (readFileSync(join(ra, "notes.txt"), "utf8") !== `notes of ${tag}, changed on B\n`) throw new Error("notes.txt is not B's");
        if (existsSync(join(ra, "gone-later.txt"))) throw new Error("the file deleted on B is on A again");
        if (git(join(ra, "proj"), "rev-parse", "HEAD") !== commit2) throw new Error("the commit is not there");
      });
      if (backed) {
        await check("2: back on A it is listed once there and works", async () => {
          await listedOnceOn(k2, "A");
          const nonce = randomBytes(3).toString("hex");
          const said = await say(k2, `drill-recall:${nonce}`, `drill-recall ${nonce} `);
          log(`  ${said}`);
          const cwd = /cwd=(\S+)/.exec(said)?.[1] ?? "";
          if (at(cwd) !== "A") throw new Error(`answered from ${at(cwd)}: ${said}`);
          // (there and back: its agent goes on from its transcript, what it was told before the move recalled, as
          // `--resume` given; agents/claude.ts bringTranscript's EEXIST of drill-move-7 is about this)
          if (!said.includes(`secret=${secretB}`)) throw new Error(`its transcript on A lacks what it was told on B (${secretB}): ${said}`);
          if (!said.includes("resumed=true")) throw new Error(`a new context, not resumed: ${said}`);
        });
        await check("2: back on A its job runs on A only", async () => {
          await whenChanged([DATA.A, DATA.B], () => {
            const l = jobs(tag);
            return l.length === 1 && l[0]!.on === "A";
          }, 120_000, () => `the job's processes: ${jobsText(tag)}`);
        });
        await check("2: B keeps nothing visible of it", async () => {
          const st = standing("B", k2);
          if (st === "live" || st === "coming") throw new Error(`B: ${st}`);
          const onB = sql("B", `select key, ws from sessions where key = ${lit(k2)}`);
          log(`  B's row: ${brief(onB)}`);
          await listedOnceOn(k2, "A");
        });
        // (the chat back, its login's lending taken back: unshared again, B keeping no copy; 5beeaa8cf)
        if (lentWith.length > 0) {
          await check("2: back on A, the login's lending taken back: B keeps no copy of it, A's is its own again", async () => {
            const prof = (n: Name) => (JSON.parse(readFileSync(`${DATA[n]}/config.json`, "utf8")).profiles ?? []).filter((p: J) => p.runtime === "claude").map((p: J) => ({ id: p.id, share: p.share ?? null }));
            const gone = await whenChanged([DATA.B], () => !prof("B").some((p: J) => p.share?.borrowed === true), 30_000, () => `B still borrows: ${brief(prof("B"))}`).then(() => true, (e) => e);
            log(`  A's ${brief(prof("A"))}; B's ${brief(prof("B"))}`);
            if (gone !== true) throw gone;
            if (!prof("A").some((p: J) => p.share?.borrowed !== true)) throw new Error(`A hosts no login of its own: ${brief(prof("A"))}`);
          });
        }
      }
    }
  }

  // ── 2k: back on A while its login is on B, by a login that cannot be shared (a Kimi Code sign-in: share/index.ts
  // shareRefusal), so that it moves as it is and A keeps no copy ──
  if (part("2k")) {
    limit("2k", 900);
    let kc = "";
    const kimi = "kimi-code";
    await check("2k: setup: a Kimi Code sign-in on A (seeded by hand in A's config.json and its home while A is stopped: its tokens far from due, so A never asks Kimi), a chat on it", async () => {
      stationDo("halt", "station");
      try {
        const cfgPath = `${DATA.A}/config.json`;
        const cfg = JSON.parse(readFileSync(cfgPath, "utf8"));
        if (!(cfg.profiles ?? []).some((p: J) => p.id === kimi)) cfg.profiles = [...(cfg.profiles ?? []), { id: kimi, name: "Kimi Code", access: { kind: "api-provider", provider: kimi, login: true }, home: `homes/${kimi}`, env: {}, models: ["claude-sonnet-5-5"] }];
        writeFileSync(cfgPath, JSON.stringify(cfg, null, 2));
        const home = `${DATA.A}/homes/${kimi}`;
        mkdirSync(home, { recursive: true });
        writeFileSync(join(home, "kimi-code.json"), JSON.stringify({ access: `drill-${tag}`, refresh: `drill-${tag}`, expiresAt: Date.now() + 30 * 86_400_000, lifeMs: 15 * 60_000, deviceId: `drill-${tag}` }), { mode: 0o600 });
        writeFileSync(join(home, "kimi-code.token"), `drill-${tag}`, { mode: 0o600 });
        // (the chats on A before it keep their logins: a Kimi sign-in is paid for already, and the account pool takes a
        // chat on one billed per use onto it at its next turn (sessions/accounts.ts), which made part 2's chat need this
        // login and the login's move refused for stopping it: drill 2026-11-20)
        execFileSync("sqlite3", [`${DATA.A}/stillfail.db`, `UPDATE sessions SET profile_pinned = 1 WHERE profile <> '${kimi}'`]);
      } finally {
        await up("A");
        log("  waiting for A online on alice's device's link");
        await a.stationState(ws, (s) => s.state === "online", 120_000, aId);
      }
      kc = await newChat(`kimi-${tag}`, kimi);
      const prof = sql("A", `select profile from sessions where key = ${lit(kc)}`)[0]?.profile;
      if (prof !== kimi) throw new Error(`the chat runs on ${prof}, not ${kimi}`);
      await say(kc, `drill-remember:k${tag}`, `drill-remembered k${tag}`);
    });
    if (kc !== "") {
      let item = "";
      await check("2k: moved to B with what it needs: its login goes as it is, A keeps no copy of it", async () => {
        const l = await moveChat(kc, "B");
        item = (l.done ?? []).find((d: J) => d.module === "accounts")?.id ?? "";
        const onA = (JSON.parse(readFileSync(`${DATA.A}/config.json`, "utf8")).profiles ?? []).map((p: J) => ({ id: p.id, share: p.share ?? null }));
        log(`  ${outcome(l)}; A's profiles ${brief(onA)}`);
        if (standing("B", kc) !== "live") throw new Error(`${standings(kc)}; ${outcome(l)}`);
        if (item === "") throw new Error(`no login moved with it: ${outcome(l)}`);
        if (onA.some((p: J) => p.id === kimi)) throw new Error(`A still has ${kimi}: ${brief(onA)}`);
      });
      const nonce = randomBytes(3).toString("hex");
      let back = false;
      await check("2k: the chat alone moved back while its login stays on B: on A, stopped, waiting for it", async () => {
        const l = await moveBack(kc, "B");
        log(`  ${outcome(l)}; ${standings(kc)}; A's stopped ${await stoppedText("A")}`);
        if (standing("A", kc) !== "live") throw new Error(`not back on A: ${standings(kc)}; ${outcome(l)}`);
        back = true;
        const s = await stoppedOf(kc);
        if (s === null || !s.includes(item)) throw new Error(`not stopped waiting for ${item}: ${s}`);
        const m = await atRest("2k");
        const chatsM = m.modules.find((x: J) => x.id === "chats");
        const row = await rowSettled("2k", m, kc, (r) => r?.state === "stopped");
        log(`  A's page: its row ${brief(row)}; rows ${brief((chatsM?.items ?? []).map((x: J) => `${x.id.slice(-8)} ${x.state}`), 400)}`);
        // (what the station's chats module reads for its state, move/chats.ts state: where it was handed, its hand-over out)
        log(`  A's own: handed_over ${brief(sql("A", `select station from handed_over where session = ${lit(kc)}`))}; its hand-overs out ${brief(handovers("A", "out").filter((o) => (o.keys ?? []).includes(kc)).map((o) => ({ id: o.id, step: o.step, at: o.at })), 600)}`);
        if (row?.state !== "stopped") throw new Error(`its row on A's page says ${row?.state} (${row?.stateText}), not stopped`);
      });
      if (back) {
        await check("2k: the person is told in the chat that it is stopped and what it waits for", async () => {
          // (the station answers a person's message to a chat a move stopped once, with its own notice in the chat
          // (author_kind station, station/src/store/rows.ts STATION_AUTHOR), station.move.stoppedChat: zh 「这个对话在「A」上
          // 暂停了：它在等「Kimi Code」…」; and no turn begins)
          const t0 = Date.now();
          await a.call("chat.send", { station: A, session: kc, text: `drill-recall:${nonce}` });
          await whenChanged([DATA.A], () => sql("A", `select count(*) n from entries where text like ${lit(`%drill-recall:${nonce}%`)}`)[0].n > 0, 60_000, () => "the message is not in A's log");
          const notices = () => sql("A", `select text from entries e join threads t on t.id = e.thread where t.home = ${lit(kc)} and e.at >= ${t0} and e.author_kind = 'station'`).map((r) => String(r.text));
          const said = await whenChanged([DATA.A], () => {
            const n = notices().filter((x) => /暂停|在等|paused|stopped|waiting/i.test(x) && /Kimi Code|kimi-code/i.test(x));
            return n.length > 0 && n;
          }, 30_000, () => `no notice of the station's in the chat saying it is stopped waiting for Kimi Code: its notices since ${brief(notices(), 400)}`);
          // (once: the next check's answer, once, after its login is back, says no second turn came of it either)
          const all = notices().filter((x) => /暂停|在等|paused|stopped|waiting/i.test(x) && /Kimi Code|kimi-code/i.test(x));
          const begun = turns(t0).filter((t) => t.text.includes(`drill-recall:${nonce}`));
          log(`  the station's notice: ${brief(said[0], 400)}; notices of it ${all.length}; turns begun ${begun.length}`);
          if (all.length !== 1) throw new Error(`told ${all.length} times: ${brief(all, 600)}`);
          if (begun.length > 0) throw new Error(`a turn began in the stopped chat: ${brief(begun, 400)}`);
        });
        await check("2k: its login moved back: the chat goes on, what was said meanwhile answered once, on A, from its context", async () => {
          const l = await moveBack(item, "B", "accounts");
          log(`  ${outcome(l)}; A's profiles ${brief((JSON.parse(readFileSync(`${DATA.A}/config.json`, "utf8")).profiles ?? []).map((p: J) => p.id))}`);
          log(`  waiting for drill-recall ${nonce} answered`);
          const v = await untilChat(kc, (v) => texts(v).some((t) => t.startsWith(`drill-recall ${nonce} `)) && v, 120_000);
          const answers = texts(v).filter((t) => t.startsWith(`drill-recall ${nonce} `));
          log(`  ${brief(answers)}`);
          if (answers.length !== 1 || at(/cwd=(\S+)/.exec(answers[0]!)?.[1] ?? "") !== "A") throw new Error(`answered ${brief(answers)}`);
          if (!answers[0]!.includes(`secret=k${tag}`)) throw new Error(`not from its context: ${answers[0]}`);
        });
      }
      // A second chat on the login, stopped on A by the login going to B alone: its row on A's page offers 迁移 (the core's
      // view: what it waits for is on the station the page is toward), pressed as the app presses it (move.start of the
      // item with what it needs): it goes to B and goes on there. What the station does with a stopped chat's move is
      // said as it is. Then both back as they were: the chat home (stopped again), the login after it.
      if (back) {
        let kd = "";
        let moved = false;
        try {
          await check("2k: a second chat on the login, stopped on A as the login went to B alone: its row's 迁移 takes it to B, where it goes on from its context", async () => {
            kd = await newChat(`kimi2-${tag}`, kimi);
            await say(kd, `drill-remember:d${tag}`, `drill-remembered d${tag}`);
            const t0 = Date.now();
            await a.call("move.start", { station: A, to: bId, module: "accounts", item });
            const lo = await turnEnds("A", t0);
            moved = true;
            log(`  the login alone to B: ${outcome(lo)}; its turn's stopped ${brief(lo?.stopped ?? null, 600)}; ${standings(kd)}; stopped ${await stoppedOf(kd)}`);
            // (the facts at that moment, for the station's side: no verdict of them)
            log(`  2k's second chat as the login left, its facts: A's stopped ${await stoppedText("A")}\n    ${heldOf2(kd)}\n    the first chat: ${heldOf2(kc)}\n    A's runtime sessions of both: ${brief(sql("A", `select session_key, profile, id from runtime_sessions where session_key in (${lit(kd)}, ${lit(kc)})`))}\n    the stations' logs around it:\n    ${logsAround(Date.now() - 1500)}`);
            if ((await stoppedOf(kd)) === null) throw new Error(`not stopped on A as its login left: ${standings(kd)}`);
            const m = await atRest("2k");
            const row = await rowSettled("2k", m, kd, (r) => r?.state === "stopped" && r?.action === "move");
            log(`  A's page: its row ${brief(row)}`);
            if (row?.state !== "stopped" || row?.action !== "move") throw new Error(`its row offers no 迁移: ${brief(row)}`);
            const n2 = randomBytes(3).toString("hex");
            await a.call("chat.send", { station: A, session: kd, text: `drill-recall:${n2}` });
            await whenChanged([DATA.A], () => sql("A", `select count(*) n from entries where text like ${lit(`%drill-recall:${n2}%`)}`)[0].n > 0, 60_000, () => "the message is not in A's log");
            // (the press: what the app's 迁移 on that row sends, station_move_node.mbt item_act)
            const t1 = Date.now();
            await a.call("move.start", { station: A, to: bId, module: "chats", item: kd, withNeeds: true });
            const l = await turnEnds("A", t1);
            log(`  the press, as the station took it: ${outcome(l)}; ${standings(kd)}`);
            if (standing("B", kd) !== "live") throw new Error(`not on B: ${standings(kd)}; ${outcome(l)}`);
            const v = await untilChat(kd, (v) => texts(v).some((t) => t.startsWith(`drill-recall ${n2} `)) && v, 120_000);
            const answers = texts(v).filter((t) => t.startsWith(`drill-recall ${n2} `));
            log(`  ${brief(answers)}`);
            if (answers.length !== 1 || at(/cwd=(\S+)/.exec(answers[0]!)?.[1] ?? "") !== "B") throw new Error(`answered ${brief(answers)}`);
            if (!answers[0]!.includes(`secret=d${tag}`)) throw new Error(`not from its context: ${answers[0]}`);
            const after = await atRest("2k");
            const rowAfter = await rowSettled("2k", after, kd, (r) => r?.state === "there");
            log(`  A's page after: its row ${brief(rowAfter)}`);
            // (the facts at that moment, for the station's side: no verdict of them)
            log(`  2k's second chat, its facts: A's stopped ${await stoppedText("A")}\n    ${heldOf2(kd)}`);
            if (rowAfter?.state !== "there") throw new Error(`its row on A's page reads ${rowAfter?.state}, not there`);
          });
        } finally {
          // (home as 2k found it: the second chat back (it arrives stopped), then the login, both chats going on on A)
          if (kd !== "" && standing("B", kd) === "live") await moveBack(kd, "B").then((l) => log(`  the second chat home: ${outcome(l)}`), (e) => log(`  the second chat not home: ${e}`));
          if (moved) await moveBack(item, "B", "accounts").then((l) => log(`  the login home: ${outcome(l)}; ${standings(kd)}`), (e) => log(`  the login not home: ${e}`));
        }
      }
      await reset("2k").catch((e) => log(`  2k's end: ${String(e).slice(0, 300)}`));
      // (A left as 2k found it: its chat archived, the sign-in taken out of A's config, else the pool gives new chats to
      // the login with fewest, sessions/pool.ts pickProfile, and drill 10's 3n ran on it)
      await untilChat(kc, (v) => typeof v?.thread?.id === "number" && v, 30_000).then((v) => a.call("chat.archive", { station: A, session: kc, thread: v.thread.id, archived: true })).catch((e) => log(`  2k's chat not archived: ${String(e).slice(0, 200)}`));
    }
    await check("2k: end: A as 2k found it (the Kimi sign-in taken out of its config)", async () => {
      stationDo("halt", "station");
      try {
        const cfgPath = `${DATA.A}/config.json`;
        const cfg = JSON.parse(readFileSync(cfgPath, "utf8"));
        cfg.profiles = (cfg.profiles ?? []).filter((p: J) => p.id !== kimi);
        writeFileSync(cfgPath, JSON.stringify(cfg, null, 2));
        log(`  A's profiles ${brief(cfg.profiles.map((p: J) => p.id))}; B's ${brief((JSON.parse(readFileSync(`${DATA.B}/config.json`, "utf8")).profiles ?? []).map((p: J) => p.id))}`);
      } finally {
        await up("A");
        await a.stationState(ws, (s) => s.state === "online", 120_000, aId);
      }
    });
  }

  // ── what a part needs to begin from a clean state, and a chat with a room of its own (parts 6, 3, 4, 7) ──
  /// A chat on A for a fault, with a room of `mb` MB in `files` files (so that its first pass takes seconds).
  const faultChat = async (label: string, mb: number, files = 400) => {
    const key = await newChat(`${label}-${tag}`);
    fill(roomOn("A", key)!, "bulk", files, Math.floor((mb * 1024 * 1024) / files));
    return key;
  };
  /// Whether a fault's part may begin: what any part before left of A on B brought back (reset), every station up
  /// and online, the login on A, and a new chat on A answering there. Not so: what is not clean is said, as a FAIL,
  /// and the part does not run (never a part run on from a state it did not check).
  const clean = async (label: string): Promise<boolean> => {
    log(`  ${label}: from a clean state? every station up, the login on A, a new chat on A answering`);
    try {
      await reset(label);
      const down = (["A", "B"] as Name[]).filter((n) => !alive(n));
      if (down.length > 0) throw new Error(`not up: ${down.join(", ")}`);
      for (const n of ["A", "B"] as Name[]) {
        log(`  waiting for ${n} online on alice's device`);
        await a.until({ topic: "stations", scope: ws }, (v) => (v ?? []).find((s: J) => s.id === idOf(n) && s.online), 60_000).catch(() => {
          throw new Error(`${n} is not online on alice's device`);
        });
      }
      const logins = (JSON.parse(readFileSync(`${DATA.A}/config.json`, "utf8")).profiles ?? []).filter((p: J) => p.runtime === "claude" || p.borrowed === true || p.share !== undefined);
      if (logins.length === 0) {
        // (the product lost it, a FAIL of the part that did; this part runs all the same, on one seeded again as `up`
        // seeds it: so each part stands on its own)
        const cfgOf = (n: Name) => existsSync(`${DATA[n]}/config.json`) ? brief((JSON.parse(readFileSync(`${DATA[n]}/config.json`, "utf8")).profiles ?? []).map((p: J) => ({ id: p.id, share: p.share ?? null, borrowed: p.borrowed ?? null, host: p.host ?? null })), 400) : "none";
        log(`  RESTORED BY HAND: A has no login to run a chat on (A's ${cfgOf("A")}, B's ${cfgOf("B")}, A's accounts kept ${["accounts-known.json", "accounts-shared.json"].map((f) => existsSync(`${DATA.A}/move/${f}`) ? `${f} ${readFileSync(`${DATA.A}/move/${f}`, "utf8").slice(0, 300)}` : "").join(" ")}): cc seeded again in A's config as the harness's up does`);
        stationDo("halt", "station");
        try {
          const cfgPath = `${DATA.A}/config.json`;
          const cfg = JSON.parse(readFileSync(cfgPath, "utf8"));
          cfg.profiles = [...(cfg.profiles ?? []).filter((p: J) => p.id !== "cc"), { id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-sonnet-5-5"] }];
          writeFileSync(cfgPath, JSON.stringify(cfg, null, 2));
          mkdirSync(`${DATA.A}/homes/cc`, { recursive: true });
          if (!existsSync(`${DATA.A}/homes/cc/.credentials.json`)) writeFileSync(`${DATA.A}/homes/cc/.credentials.json`, "{}");
        } finally {
          await up("A");
          await a.stationState(ws, (s) => s.state === "online", 120_000, aId);
        }
      }
      const k = await newChat(`clean-${label}-${tag}`);
      const said = await say(k, `drill-note:clean-${label}`, `drill-noted clean-${label}`, 60_000);
      if (at(/cwd=(\S+)/.exec(said)?.[1] ?? "") !== "A") throw new Error(`a new chat on A answered from elsewhere: ${said}`);
      return true;
    } catch (e) {
      fail(`${label}: begins from a clean state (the part is not run)`, e);
      return false;
    }
  };

  // ── 6: a chat moved to a station that still holds a retired copy of it (what this morning's failed retirement left
  // on the real target, of every chat) and back ──
  if (part("6") && (limit("6", 900), await clean("6"))) {
    /// Each file of `room` (relative path) by a digest of its bytes.
    const snapshot = (room: string): Map<string, string> => {
      const m = new Map<string, string>();
      const walk = (d: string, rel: string) => {
        for (const e of readdirSync(d, { withFileTypes: true })) {
          const r = rel === "" ? e.name : `${rel}/${e.name}`;
          if (e.isDirectory()) walk(join(d, e.name), r);
          else if (e.isFile()) m.set(r, createHash("sha256").update(readFileSync(join(d, e.name))).digest("hex").slice(0, 12));
        }
      };
      if (existsSync(room)) walk(room, "");
      return m;
    };
    const differ = (want: Map<string, string>, got: Map<string, string>): string[] => [
      ...[...want].filter(([f, h]) => got.get(f) !== h).map(([f]) => `${f} ${got.has(f) ? "differs" : "missing"}`),
      ...[...got.keys()].filter((f) => !want.has(f)).map((f) => `${f} extra`),
    ];
    /// The texts of chat `key`'s thread on station `n`, in its order (its latest thread there).
    const entriesOn = (n: Name, key: string): string[] => {
      const t = sql(n, `select thread from thread_sessions where session = ${lit(key)} order by joined_at desc limit 1`)[0]?.thread;
      return t === undefined ? [] : sql(n, `select text from entries where thread = ${t} and text is not null and text != '' order by n`).map((r) => String(r.text));
    };
    /// Chat `key`'s thread on station `n` as its entries are: n, ts, kind, first words.
    const entryRows = (n: Name, key: string): string => {
      const t = sql(n, `select thread from thread_sessions where session = ${lit(key)} order by joined_at desc limit 1`)[0]?.thread;
      return t === undefined ? "no thread" : `thread ${t}: ` + sql(n, `select n, ts, kind, substr(coalesce(text, ''), 1, 40) t from entries where thread = ${t} order by n`).map((r) => `${r.n} ${r.ts} ${r.kind} ${JSON.stringify(r.t)}`).join(" | ");
    };
    /// What station `n` holds of chat `key` itself: its row, where it says it was handed, its hand-overs in.
    const heldOn = (n: Name, key: string): string =>
      `${n}'s row ${brief(Object.fromEntries(Object.entries(sql(n, `select * from sessions where key = ${lit(key)}`)[0] ?? {}).filter(([c]) => !["token", "title"].includes(c))), 900)}, handed_over ${brief(sql(n, `select station, ws from handed_over where session = ${lit(key)}`))}, hand-overs in ${brief(handovers(n, "in").filter((i) => (i.keys ?? []).includes(key)).map((i) => ({ id: i.id, step: i.step })))}, out ${brief(handovers(n, "out").filter((o) => (o.keys ?? []).includes(key)).map((o) => ({ id: o.id.slice(-8), step: o.step, shown: o.shown ?? null })), 400)}`;
    let k6 = "";
    let roomA: Map<string, string> = new Map();
    const r1 = `r${tag}`;
    const r2 = `q${tag}`;
    await check("6: setup: a chat moved A→B and back with its room, more said and changed on A; B left as a retirement leaves it (by hand, e2e/move-stale.ts with B's own store, B stopped: its row's ws retired:, two entries only B has, its room older, its transcript what the chat left there)", async () => {
      k6 = await newChat(`stale-${tag}`);
      await say(k6, `drill-remember:${r1}`, `drill-remembered ${r1}`);
      const room = roomOn("A", k6)!;
      writeFileSync(join(room, "same.txt"), "the same on both\n");
      writeFileSync(join(room, "differs.txt"), "A's first\n");
      writeFileSync(join(room, "lacking.txt"), "A's, gone from B's copy\n");
      const l = await moveChat(k6, "B");
      if (standing("B", k6) !== "live") throw new Error(`not to B: ${standings(k6)}; ${outcome(l)}`);
      await home(k6);
      // (what A has since that B's copy will not: words said, a remembered word newer than B's transcript, a file changed)
      await say(k6, `drill-remember:${r2}`, `drill-remembered ${r2}`);
      writeFileSync(join(room, "differs.txt"), "A's, changed after it came back\n");
      stationDo("halt", "second");
      try {
        const aName = String(((await a.until({ topic: "workspace", workspace: ws }, (v) => v?.stations && v, 30_000)).stations as J[]).find((s) => s.id === aId)?.name ?? "A");
        log(`  ${execFileSync(process.execPath, ["--no-warnings", join(dirname(new URL(import.meta.url).pathname), "move-stale.ts"), process.env.E2E_SF_SRC!, DATA.B, k6, ws, tag, "differs.txt", "lacking.txt", aId, aName], { encoding: "utf8", timeout: 120_000 }).trim()}`);
      } finally {
        await up("B");
      }
      log(`  B's row of it: ${brief(sql("B", `select ws, workspace from sessions where key = ${lit(k6)}`))}; standing ${standings(k6)}`);
    });
    if (k6 !== "") {
      await check("6: B's own move page does not list the retired row as a chat of B's", async () => {
        const v = await a.until({ topic: "stationMove", station: B, to: aId, module: "chats" }, (v) => v?.modules && v, 60_000);
        const chatsM = v.modules.find((m: J) => m.id === "chats");
        log(`  B's page: chats ${chatsM?.done}/${chatsM?.total}: ${brief((chatsM?.items ?? []).map((x: J) => `${x.id.slice(-8)} ${x.state}`), 300)}`);
        if ((chatsM?.items ?? []).some((x: J) => x.id === k6)) throw new Error(`B's page lists ${k6} as a chat of B's`);
      });
      /// Chat `k6` moved (to B by A's page with its needs, or back by its 全部迁回), a message said in its hold; then
      /// each thing it must be on the station it went to, a check each.
      const there = async (to: Name, label: string, last: string) => {
        const from: Name = to === "B" ? "A" : "B";
        const wantEntries = entriesOn(from, k6);
        const wantRoom = snapshot(roomOn(from, k6)!);
        const note = `${label}-${tag}`;
        let said = false;
        await check(`6: ${label}: moved, a message said while it is held`, async () => {
          const t0 = Date.now();
          if (to === "B") await a.call("move.start", { station: A, to: bId, module: "chats", item: k6, withNeeds: true });
          else await a.call("move.back", { station: A, from: bId, all: true });
          const held = heldOf(k6, t0, from).then(async () => {
            await a.call("chat.send", { station: A, session: k6, text: `drill-note:${note}` });
            said = true;
          });
          held.catch((e) => log(`  ${e.message}`));
          const l = await turnEnds("A", t0);
          await within(held.catch(() => {}), 10_000);
          log(`  ${outcome(l)}; ${standings(k6)}; its hand-over ${outOn(from, k6)?.step}: ${outOn(from, k6)?.error ?? ""}`);
          log(`  ${heldOn(to, k6)}; ${heldOn(from, k6)}`);
          await untilChat(k6, (v) => v?.messages && v, 15_000).then(() => log("  the device opens the chat's page"), (e) => log(`  the device does not open the chat's page: ${String(e).slice(0, 400)}`));
          if (liveOn(k6).join() !== to) throw new Error(`${standings(k6)}; ${outcome(l)}`);
        });
        await check(`6: ${label}: listed once, on ${to}`, () => listedOnceOn(k6, to));
        // (the lead, 2026-11-14, as the station agent traced the code: no renumbering is written; each station's log
        // keeps its own numbers, an arriving entry the same at its number skipped, one found by ts elsewhere is that one,
        // one not found numbered on. Where the copy's own entries sit may differ between the two: no failure)
        await check(`6: ${label}: every entry of ${from}'s on ${to} once, each only the copy had once`, async () => {
          const got = entriesOn(to, k6);
          const extra = got.filter((t) => !wantEntries.includes(t) && !t.includes(note));
          log(`  ${from} had ${wantEntries.length}, ${to} has ${got.length}; only on ${to}: ${brief(extra.map((t) => t.slice(0, 60)), 400)}`);
          const whys: string[] = [];
          const count = (l: string[], t: string) => l.filter((x) => x === t).length;
          for (const t of new Set(wantEntries)) if (count(got, t) !== count(wantEntries, t)) whys.push(`${brief(t.slice(0, 60))} ${count(wantEntries, t)}x on ${from}, ${count(got, t)}x on ${to}`);
          for (const t of new Set(extra)) if (count(got, t) !== 1) whys.push(`${brief(t.slice(0, 60))} ${count(got, t)}x on ${to}`);
          const why = whys.length === 0 ? null : whys.join("; ");
          if (why !== null) {
            log(`  ${from}'s ${entryRows(from, k6)}`);
            log(`  ${to}'s ${entryRows(to, k6)}`);
            throw new Error(why);
          }
        });
        await check(`6: ${label}: its room on ${to} exactly ${from}'s`, async () => {
          const d = differ(wantRoom, snapshot(roomOn(to, k6)!));
          if (d.length > 0) throw new Error(d.slice(0, 10).join(", "));
        });
        const handedT0 = Date.now() - 30_000;
        await check(`6: ${label}: what was said while it was held arrives once, answered once on ${to}`, async () => {
          log(`  what agents were handed of it since: ${brief(turns(handedT0).filter((t) => t.text.includes(tag) && /drill-note:/.test(t.text)).map((t) => `${t.pid}@${at(t.cwd)} +${t.at - handedT0}ms: ${(t.text.match(/drill-note:\S+/g) ?? []).join(", ")}`), 800)}`);
          if (!said) throw new Error("nothing was said: it was never seen held");
          log(`  waiting for ${note} answered`);
          // (it cannot come once the chat holds the note and its agent is idle with nothing pending: then 10 s more, not
          // 120: drill 18's sat out the whole wait)
          const idle = (v: J) => texts(v).includes(`drill-note:${note}`) && (v?.agents ?? []).every((x: J) => x?.session?.running === false && (x?.session?.pending ?? 0) === 0);
          const first = await untilChat(k6, (v) => (texts(v).some((t) => t.startsWith(`drill-noted ${note}`)) || idle(v)) && v, 120_000);
          const v = texts(first).some((t) => t.startsWith(`drill-noted ${note}`)) ? first : await untilChat(k6, (v) => texts(v).some((t) => t.startsWith(`drill-noted ${note}`)) && v, 10_000).catch(() => {
            throw new Error(`not answered: the chat holds it, its agent idle with nothing pending (${brief((first?.agents ?? []).map((x: J) => ({ running: x?.session?.running, pending: x?.session?.pending, lastTurn: x?.session?.lastTurn?.ending })))}), and no answer 10 s after`);
          });
          const asked = texts(v).filter((t) => t === `drill-note:${note}`).length;
          const answers = texts(v).filter((t) => t.startsWith(`drill-noted ${note}`));
          if (asked !== 1 || answers.length !== 1 || at(/cwd=(\S+)/.exec(answers[0]!)?.[1] ?? "") !== to) throw new Error(`said ${asked} times, answered ${brief(answers)}`);
        });
        await check(`6: ${label}: its agent goes on from its context on ${to} (what it was told last, resumed)`, async () => {
          const nonce = randomBytes(3).toString("hex");
          const got = await say(k6, `drill-recall:${nonce}`, `drill-recall ${nonce} `);
          log(`  ${got}`);
          if (at(/cwd=(\S+)/.exec(got)?.[1] ?? "") !== to) throw new Error(`answered from elsewhere: ${got}`);
          if (!got.includes(`secret=${last}`)) throw new Error(`it does not recall ${last}, the last it was told (${r1}: what B's stale copy holds; ${r2}: what A had before it went): ${got}`);
          if (!got.includes("resumed=true")) throw new Error(`a new context: ${got}`);
        });
      };
      await there("B", "to B over the retired copy", r2);
      // (something said on B for A to recall once back: drill 8 found A going on from its own copy of before)
      const r3 = `p${tag}`;
      if (liveOn(k6).join() === "B") {
        await say(k6, `drill-remember:${r3}`, `drill-remembered ${r3}`).catch((e) => log(`  not said on B: ${e.message}`));
        await there("A", "back to A", r3);
        // (from a state with nothing pending: the first trip brings B level with A and lets what was owed be answered
        // (drill 18's A gained the late answer to the note its arrival left unanswered, a fault known); the two after it
        // add nothing on either side)
        await check("6: trips there and back add no entry on either side (counted after a first trip, then two more)", async () => {
          const trip = async (i: number) => {
            const l = await moveChat(k6, "B");
            if (standing("B", k6) !== "live") throw new Error(`trip ${i} not to B: ${standings(k6)}; ${outcome(l)}`);
            await home(k6);
          };
          const rows = (n: Name) => {
            const t = sql(n, `select thread from thread_sessions where session = ${lit(k6)} order by joined_at desc limit 1`)[0]?.thread;
            return t === undefined ? [] : sql(n, `select n, ts, kind, author, substr(coalesce(text, ''), 1, 50) t from entries where thread = ${t} order by n`);
          };
          await trip(1);
          const before = { A: rows("A"), B: rows("B") };
          await trip(2);
          await trip(3);
          const after = { A: rows("A"), B: rows("B") };
          const added = (was: J[], now: J[]) => now.filter((r) => !was.some((w) => w.ts === r.ts && w.t === r.t)).map((r) => `${r.n} ${r.ts} ${r.kind} ${r.author} ${JSON.stringify(r.t)}`);
          log(`  entries after the first trip A ${before.A.length} B ${before.B.length}, after two more A ${after.A.length} B ${after.B.length}`);
          const addA = added(before.A, after.A);
          const addB = added(before.B, after.B);
          if (addA.length + addB.length > 0 || after.A.length !== before.A.length || after.B.length !== before.B.length) {
            throw new Error(`added on A: ${brief(addA, 600)}; on B: ${brief(addB, 600)}`);
          }
        });
      }
    }
  }
  // ── 6b: a chat whose key is live on both stations (moved A→B, then put back in sight on A by hand): A's page shows it
  // as one that cannot move, in words, and a move asked anyway is refused, nothing of B changed ──
  if (part("6b") && (limit("6b", 600), await clean("6b"))) {
    let kl = "";
    const keep = `${WORK}/move-live-${tag}.json`;
    const live = (mode: "live" | "restore") => execFileSync(process.execPath, ["--no-warnings", join(dirname(new URL(import.meta.url).pathname), "move-live.ts"), process.env.E2E_SF_SRC!, DATA.A, kl, mode, keep], { encoding: "utf8", timeout: 120_000 }).trim();
    let seeded = false;
    await check("6b: setup: a chat moved A→B, then put back in sight on A by hand (e2e/move-live.ts through A's own store, A stopped): live on both", async () => {
      kl = await newChat(`live-${tag}`);
      const l = await moveChat(kl, "B");
      if (standing("B", kl) !== "live") throw new Error(`not to B: ${standings(kl)}; ${outcome(l)}`);
      stationDo("halt", "station");
      try {
        log(`  ${live("live")}`);
        seeded = true;
      } finally {
        await up("A");
        await a.stationState(ws, (s) => s.state === "online", 120_000, aId);
      }
      if (liveOn(kl).join() !== "A,B") throw new Error(`not live on both: ${standings(kl)}`);
      log(`  ${standings(kl)}`);
    });
    if (seeded) {
      await check("6b: A's page toward B shows it as one that cannot move, saying why", async () => {
        const v = await atRest("6b");
        const row = await rowSettled("6b", v, kl, (r) => r?.state === "cannot" && String(r?.note ?? "").trim() !== "");
        const readAt = Date.now();
        log(`  its row ${brief(row)}`);
        // (the facts at that moment, for the station's side: no verdict of them)
        log(`  6b's facts: ${heldOf2(kl)}\n    the seed's set-aside: ${existsSync(`${keep}.out`) ? readdirSync(`${keep}.out`).join(", ") : "none"}\n    A's plans asking B which chats are live, the last three: ${(existsSync(`${RUN}/station.log`) ? readFileSync(`${RUN}/station.log`, "utf8").split("\n").filter((l) => l.includes("asked which chats are live")).slice(-3) : []).join("\n      ") || "none"}\n    the stations' logs around the read:\n    ${logsAround(readAt)}`);
        if (row?.state !== "cannot" || String(row?.note ?? "").trim() === "") throw new Error(`its row ${brief(row)}: not one that cannot move, with words`);
      });
      await check("6b: a move asked anyway is refused, nothing of B changed", async () => {
        const rowB = () => brief(sql("B", `select ws, came_from, last_active_at, archived_at from sessions where key = ${lit(kl)}`));
        const before = { row: rowB(), entries: entriesOf("B", kl), room: roomOn("B", kl) };
        const roomFiles = (r: string | null) => (r !== null && existsSync(r) ? readdirSync(r).sort().join(",") : "none");
        const files0 = roomFiles(before.room);
        const l = await moveChat(kl, "B");
        log(`  ${outcome(l)}; ${standings(kl)}`);
        const why = [...(l.refused ?? []).filter((r: J) => named(r.item) === `chats ${kl}`).map((r: J) => r.why), failedWhy(l, `chats ${kl}`)].filter((x) => x !== "").join(" | ");
        if ((l.done ?? []).some((d: J) => named(d) === `chats ${kl}`)) throw new Error(`it moved: ${outcome(l)}`);
        if (why === "") throw new Error(`not refused in words: ${outcome(l)}`);
        const after = { row: rowB(), entries: entriesOf("B", kl), room: roomOn("B", kl) };
        if (after.row !== before.row || after.entries !== before.entries || roomFiles(after.room) !== files0) throw new Error(`B changed: row ${before.row} -> ${after.row}, entries ${before.entries} -> ${after.entries}, room ${files0} -> ${roomFiles(after.room)}`);
      });
      // (A as 6b found it: the row put back as it was, then the chat brought home from B)
      stationDo("halt", "station");
      try {
        log(`  6b's end: ${live("restore")}`);
      } finally {
        await up("A");
        await a.stationState(ws, (s) => s.state === "online", 120_000, aId);
      }
      await home(kl).catch((e) => log(`  6b's chat not brought home: ${String(e).slice(0, 300)}`));
    }
  }

  // ── 3: faults ──
  if (part("3n") && (limit("3n", 900), await clean("3n"))) {
    // (drill-move-7's 3b: a chat's first pass cut half a second after its login moved, B's answer's stream reset, with
    // nothing killed; this is that alone)
    let key = "";
    await check("3n: a chat with a 300 MB room moved with what it needs, nothing killed: it goes", async () => {
      key = await faultChat("f3n", 300);
      const t0 = Date.now();
      const l = await moveChat(key, "B");
      const o = outOf(key);
      log(`  ${outcome(l)}; its hand-over ${o?.id} ${o?.step}: ${o?.error ?? ""} (${o?.done ?? "?"} of ${o?.total ?? "?"} bytes); steps ${brief(steps.A!.of(o?.id ?? "").map((s) => `${s.step}${s.held ? "*" : ""}+${s.at - t0}`))}`);
      if (standing("B", key) !== "live") throw new Error(`${standings(key)}; ${outcome(l)}`);
    });
    if (key !== "") await endsWell("3n", key);
  }
  if (part("3a") && (limit("3a", 900), await clean("3a"))) {
    let key = "";
    let failedLent: J = null;
    await check("3a: B killed (SIGKILL, its machine as it loses power) during the chat's first pass, started again", async () => {
      key = await faultChat("f3a", 300);
      const t0 = Date.now();
      await a.call("move.start", { station: A, to: bId, module: "chats", item: key, withNeeds: true });
      const o = await firstPass(key, t0);
      try {
        stationDo("crash", "second");
        log(`  killed with ${filesIn("B", o.id)} files of it there`);
        const l = await turnEnds("A", t0);
        log(`  A's turn: ${outcome(l)}; its hand-over ${outOf(key)?.step}: ${outOf(key)?.error}`);
        failedLent = l;
      } finally {
        await up("B");
      }
    });
    if (failedLent !== null) await check("3a: the failed turn lists no login lent, its lending taken back", () => lentLeft(failedLent));
    if (key !== "") await endsWell("3a", key);
  }
  if (part("3b") && (limit("3b", 900), await clean("3b"))) {
    let key = "";
    await check("3b: A killed while the chat is held (its second pass), started again", async () => {
      key = await faultChat("f3b", 300);
      const room = roomOn("A", key)!;
      const t0 = Date.now();
      await a.call("move.start", { station: A, to: bId, module: "chats", item: key, withNeeds: true });
      await firstPass(key, t0);
      // (its files changed meanwhile: what the second pass, held, sends again, so that it is held for seconds)
      fill(room, "bulk", 400, Math.floor((150 * 1024 * 1024) / 400));
      const o = await heldOf(key, t0);
      try {
        stationDo("crash", "station");
        log(`  killed at ${o.step}, held`);
      } finally {
        await up("A");
        log("  waiting for A online on alice's device's link");
        await a.stationState(ws, (s) => s.state === "online", 120_000, aId);
      }
    });
    if (key !== "") await endsWell("3b", key);
  }
  if (part("3c") && (limit("3c", 900), await clean("3c"))) {
    let key = "";
    let note = "";
    await check("3c: B killed just after it took the chat (A says it went), started again; a message said meanwhile", async () => {
      key = await faultChat("f3c", 50, 100);
      const t0 = Date.now();
      await a.call("move.start", { station: A, to: bId, module: "chats", item: key, withNeeds: true });
      log(`  waiting for ${key.slice(-8)} gone from A`);
      const o = await whenChanged([DATA.A], () => (["gone", "done"].includes(outOf(key)?.step) ? { o: outOf(key) } : cannotCome(key, t0)), 300_000, () => `never gone: ${brief(outOf(key))}`);
      if ("why" in o) throw new Error(`it never went: ${o.why}`);
      try {
        stationDo("crash", "second");
        const inB = handovers("B", "in").find((i) => i.id === o.o.id);
        log(`  killed at A's ${o.o.step}, B's ${inB?.step ?? "none"}`);
        note = `f3c-${tag}`;
        // (whatever the send answers while B is down, what was said is to arrive once B is up: the next check)
        const sent = await a.call("chat.send", { station: A, session: key, text: `drill-note:${note}` }).then((x) => `sent ${brief(x, 200)}`, (e) => `the send answered ${String(e).slice(0, 300)}`);
        const v = await untilChat(key, (v) => v?.messages && v, 10_000).catch(() => null);
        log(`  said while B was down: ${sent}; the device's outbox ${brief((v?.outbox ?? []).map((x: J) => ({ text: x.text, state: x.state, error: x.error ?? null, waits: x.waits ?? null })))}`);
      } finally {
        await up("B");
      }
      const l = await turnEnds("A", t0);
      log(`  A's turn: ${outcome(l)}`);
    });
    if (key !== "" && note !== "") {
      await check("3c: said while B was down: arrives once, answered once after B is up", async () => {
        log(`  waiting for ${note} answered`);
        const v = await untilChat(key, (v) => texts(v).some((t) => t.startsWith(`drill-noted ${note}`)) && v, 180_000).catch(async (e) => {
          const now = await untilChat(key, (v) => v?.messages && v, 10_000).catch(() => null);
          const onB = sql("B", `select count(*) n from entries where text like ${lit(`%drill-note:${note}%`)}`)[0]?.n;
          const onA = sql("A", `select count(*) n from entries where text like ${lit(`%drill-note:${note}%`)}`)[0]?.n;
          throw new Error(`not answered: in B's log ${onB}, in A's ${onA}; the device's outbox ${brief((now?.outbox ?? []).map((x: J) => ({ text: x.text, state: x.state, error: x.error ?? null })))}; ${String(e).slice(0, 200)}`);
        });
        const asked = texts(v).filter((t) => t === `drill-note:${note}`).length;
        const answers = texts(v).filter((t) => t.startsWith(`drill-noted ${note}`)).length;
        if (asked !== 1 || answers !== 1) throw new Error(`said ${asked} times, answered ${answers}`);
      });
    }
    if (key !== "") await endsWell("3c", key);
  }
  if (part("3d") && (limit("3d", 900), await clean("3d"))) {
    let key = "";
    await check("3d: move.stop during the first pass: the chat here and working, last.stoppedBy says who", async () => {
      key = await faultChat("f3d", 300);
      const t0 = Date.now();
      await a.call("move.start", { station: A, to: bId, module: "chats", item: key, withNeeds: true });
      await firstPass(key, t0);
      await a.call("move.stop", { station: A });
      const l = await turnEnds("A", t0);
      log(`  ${outcome(l)}`);
      if (l.stoppedBy !== "alice@example.test") throw new Error(`stoppedBy ${brief(l.stoppedBy)}`);
      if (standing("A", key) !== "live") throw new Error(standings(key));
    });
    if (key !== "") await endsWell("3d", key);
  }
  if (part("3e") && (limit("3e", 900), await clean("3e"))) {
    const dmg = `${WORK}/drill-small.dmg`;
    let mounted = false;
    /// The logins moved to C with a chat's needs (its chat refused or not): brought back each before C goes.
    const toC = new Set<string>();
    try {
      let key = "";
      let freeBefore = 0;
      await check("3e: C enrolled with its data on a small APFS volume of its own", async () => {
        cId = await enroll("C", "move-small");
        C = `${ws}/${cId}`;
        stationDo("second-stop", "third");
        rmSync(dmg, { force: true });
        // (a station keeps 1 GB free past what a chat takes, replica/retire.ts HEADROOM, handover.ts's `need`: C has room for a
        // small chat and not for a big one; drill 10's 120 MB took none)
        sh("hdiutil", ["create", "-quiet", "-size", "1600m", "-fs", "APFS", "-volname", "drillsmall", dmg]);
        const orig = `${DATA.C}.orig`;
        rmSync(orig, { recursive: true, force: true });
        sh("mv", [DATA.C, orig]);
        mkdirSync(DATA.C);
        sh("hdiutil", ["attach", "-quiet", "-nobrowse", "-mountpoint", DATA.C, dmg]);
        mounted = true;
        sh("cp", ["-a", `${orig}/.`, DATA.C]);
        rmSync(orig, { recursive: true, force: true });
        // (a login of C's own, so a chat made there answers with nothing moved to it: what shows C works once nothing
        // can move there, the floor refusing every chat on a disk this small)
        addLogin("C", "cc-c");
        stationDo("again", "third");
        await a.until({ topic: "stations", scope: ws }, (v) => (v ?? []).find((s: J) => s.id === cId && s.online), 120_000);
        const s = statfsSync(DATA.C);
        freeBefore = Number(s.bavail) * Number(s.bsize);
        log(`  C ${cId}: ${(freeBefore / 1024 / 1024).toFixed(0)} MB free`);
      });
      if (cId !== "" && mounted) {
        let tooBig: J = null;
        await check("3e: a chat larger than C's free room: refused before it is held, saying what to do, or failed with the chat working on A and C clean", async () => {
          key = await faultChat("f3e", Math.ceil((freeBefore - 1024 * 1048576) / 1048576) + 60, 300);
          const t0 = Date.now();
          await a.call("move.start", { station: A, to: cId, module: "chats", item: key, withNeeds: true });
          const l = await turnEnds("A", t0);
          for (const d of l.done ?? []) if (d.module === "accounts") toC.add(d.id);
          const o = outOf(key);
          const why = failedWhy(l, `chats ${key}`) || (l.refused ?? []).map((r: J) => r.why).join(" | ");
          log(`  ${outcome(l)}; its hand-over ${o?.step} held=${o?.held}`);
          if (standing("A", key) !== "live") throw new Error(standings(key));
          if (o !== null && o.held !== false) throw new Error("it was held before it was refused");
          // (the station's words in either language: station.move.why.noRoom, zh 「…先在那边腾出空间，或换一台 station」)
          if (!/free|room|space|腾出|空间/i.test(why)) throw new Error(`what it said does not say what to do about room: ${why}`);
          const s = statfsSync(DATA.C);
          const free = Number(s.bavail) * Number(s.bsize);
          log(`  C free before ${(freeBefore / 1048576).toFixed(0)} MB, after ${(free / 1048576).toFixed(0)} MB`);
          await whenChanged([`${DATA.C}/replica`], () => !handovers("C", "in").some((i) => (i.keys ?? []).includes(key) && i.step === "coming") && true, 120_000, () => `C's hand-over in: ${brief(handovers("C", "in"))}`);
          if (free < freeBefore - 20 * 1048576) throw new Error(`C has ${((freeBefore - free) / 1048576).toFixed(0)} MB less free than before`);
          tooBig = l;
        });
        if (tooBig !== null) await check("3e: the too-big chat's failed turn lists no login lent, its lending taken back", () => lentLeft(tooBig));
        if (key !== "") {
          await check("3e: the chat answers on A, listed once there", async () => {
            await listedOnceOn(key, "A");
            const said = await say(key, `drill-note:f3e-${tag}`, `drill-noted f3e-${tag}`);
            if (at(/cwd=(\S+)/.exec(said)?.[1] ?? "") !== "A") throw new Error(said);
          });
        }
        // (a station keeps the larger of 20 GiB and a tenth of its disk free, handover.ts `floorOf`: C, on 1.6 GB, takes
        // no chat at all, and says so in numbers before anything of it is held)
        await check("3e: a small chat's move to C: refused before it is held, in the floor's words with its numbers; on A, nothing of it on C", async () => {
          const small = await newChat(`f3e-small-${tag}`);
          const t0 = Date.now();
          await a.call("move.start", { station: A, to: cId, module: "chats", item: small, withNeeds: true });
          const l = await turnEnds("A", t0);
          for (const d of l.done ?? []) if (d.module === "accounts") toC.add(d.id);
          const o = outOf(small);
          const why = failedWhy(l, `chats ${small}`) || (l.refused ?? []).map((r: J) => r.why).join(" | ");
          log(`  ${outcome(l)}; its hand-over ${o?.step ?? "none"} held=${o?.held ?? "-"}`);
          const nums = [...why.matchAll(/(\d+(?:\.\d+)?)\s*(?:GB|GiB)/g)].map((m) => m[1]);
          if (nums.length < 3) throw new Error(`not the floor's words with its three numbers (left there, the chat's, the floor): ${why}`);
          if (o !== null && o.held !== false) throw new Error("it was held before it was refused");
          if (standing("A", small) !== "live") throw new Error(standings(small));
          if (standing("C", small) !== "none") throw new Error(`C has ${standing("C", small)} of it`);
          if (handovers("C", "in").some((i) => (i.keys ?? []).includes(small) && i.step === "coming")) throw new Error(`C has a hand-over of it coming: ${brief(handovers("C", "in"))}`);
          log(`  said: ${why.slice(0, 300)} (${nums.join(", ")})`);
        });
        await check("3e: C still works where it needs no room for a chat: a chat made on C answers there, and C answers its move page", async () => {
          const { key: made } = await a.call("chat.create", { station: C, runtime: "claude", profile: "cc-c" });
          await a.call("chat.send", { station: C, session: made, text: `drill-note:f3e-c-${tag}` });
          const v = await a.until({ topic: "chat", station: C, session: made }, (v) => failedSend(v, `drill-note:f3e-c-${tag}`) ?? texts(v).find((t) => t.startsWith(`drill-noted f3e-c-${tag}`)), 120_000);
          if (typeof v !== "string") throw new Error(`what was said on C did not go: ${v.failed}`);
          if (at(/cwd=(\S+)/.exec(v)?.[1] ?? "") !== "C") throw new Error(v);
          const t0 = Date.now();
          const page = await a.until({ topic: "stationMove", station: C, to: aId, module: "chats" }, (p) => p?.modules && p, 60_000);
          await a.answered(cId, "/move", t0, 10_000, true);
          log(`  answered on C: ${v.slice(0, 120)}; C's move page: ${page.modules.map((m: J) => `${m.id} ${m.done}/${m.total}`).join(", ")}`);
        });
      }
    } finally {
      // (what moved to C, a login with a chat's needs among it, brought back before C is taken away with it: drill 9's
      // login went A→C with 3e's refused chat and was deleted with C)
      if (cId !== "") {
        const t0 = Date.now();
        await a.call("move.back", { station: A, from: cId, all: true }).then(() => turnEnds("A", t0, 120_000)).then((l) => log(`  what moved to C brought back: ${outcome(l)}`), (e) => log(`  what moved to C not brought back: ${String(e).slice(0, 300)}`));
        // (全部迁回 stops at its first item that fails, a chat whose move to C failed among them (move/scheduler.ts
        // `#back`): each login brought back alone then, or it is lost with C, drill 10)
        // (a login shared as it moved is named `share:…` after its move, accounts.ts: what A's page to C says is there)
        const thereOnC = await a.until({ topic: "stationMove", station: A, to: cId, module: "accounts" }, (v) => v?.modules && v, 30_000)
          .then((v) => (v.modules.find((m: J) => m.id === "accounts")?.items ?? []).filter((x: J) => x.state === "there" || x.state === "failed").map((x: J) => x.id as string), () => [] as string[]);
        log(`  logins moved to C: ${[...toC].join(", ") || "none"}; A's page to C says there: ${thereOnC.join(", ") || "none"}`);
        for (const id of new Set([...thereOnC, ...toC])) {
          const have = (JSON.parse(readFileSync(`${DATA.A}/config.json`, "utf8")).profiles ?? []).map((p: J) => brief(p.share ?? p.id));
          const t1 = Date.now();
          await a.call("move.back", { station: A, from: cId, module: "accounts", item: id }).then(() => turnEnds("A", t1, 120_000)).then((l) => log(`  ${id} back from C: ${outcome(l)}; A's profiles were ${have.join(", ")}`), (e) => log(`  ${id} not back from C: ${String(e).slice(0, 300)}`));
        }
      }
      try {
        if (cId !== "") stationDo("second-stop", "third");
        if (mounted) sh("hdiutil", ["detach", "-quiet", "-force", DATA.C]);
        rmSync(dmg, { force: true });
        if (cId !== "") {
          await a.call("workspace.removeStation", { account: a.sub, workspace: ws, station: cId }).catch((e) => log(`  C not taken out: ${e}`));
          stationDo("second-down", "third");
        }
      } catch (e) {
        log(`  C's end: ${String(e).slice(0, 300)}`);
      }
    }
    // (drill 24: 3e moved a chat to C with its login, the chat came back alone, the login stayed hosted on C, A borrowing
    // it, and as C left the workspace A's copy was taken away: the next part found A with no login (RESTORED BY HAND).
    // The login is A's to keep: shared, not moved, its host stays where it was. Held until that lands, and after.)
    if (cId !== "") {
      await check("3e: C gone: A still has its login (what went to C with a chat is not lost with C)", async () => {
        const usable = () => (JSON.parse(readFileSync(`${DATA.A}/config.json`, "utf8")).profiles ?? []).filter((p: J) => p.id === "cc" && p.share?.borrowed !== true);
        // (a borrowed copy is taken away once A hears its host left, some seconds after: waited for, at most 30 s)
        const lost = await whenChanged([DATA.A], () => usable().length === 0, 30_000, () => "kept").then(() => true, () => false);
        log(`  A's profiles: ${brief((JSON.parse(readFileSync(`${DATA.A}/config.json`, "utf8")).profiles ?? []).map((p: J) => ({ id: p.id, share: p.share ?? null })), 400)}`);
        if (lost) throw new Error("A has no login of its own any more: it went to C with a chat and was lost with C");
      });
    }
  }
  // ── 3h: C's disk filled while a chat's files are going (the floor looks only before they go) ──
  if (part("3h") && (limit("3h", 1800), await clean("3h"))) {
    const img = `${WORK}/drill-fill`;
    let mounted = false;
    let key = "";
    let freeBefore = 0;
    const filler = () => `${DATA.C}/drill-filler`;
    const freeOn = (p: string) => {
      const s = statfsSync(p);
      return Number(s.bavail) * Number(s.bsize);
    };
    const GiB = 1024 ** 3;
    const toC = new Set<string>();
    /// `bytes` of C's volume taken at once by allocation, none of it written (macOS F_PREALLOCATE, then the file's size
    /// set: the inner volume's free space falls, the sparse image under it does not grow); where that does not take the
    /// room, written (zeros, a block at a time).
    const take = async (bytes: number): Promise<string> => {
      const want = freeOn(DATA.C) - bytes;
      const pa = spawnSync("python3", ["-I", "-c", [
        "import errno, fcntl, os, struct, sys",
        "f, n = sys.argv[1], int(sys.argv[2])",
        "fd = os.open(f, os.O_RDWR | os.O_CREAT, 0o600)",
        // (fstore_t: F_ALLOCATEALL, F_PEOFPOSMODE, offset 0 from the physical end, a length; F_PREALLOCATE is 42 on
        // macOS. Asked whole, APFS refuses it, ENOSPC: drill 36. So a piece at a time, each smaller where one does not fit)
        "got, piece = 0, 1 << 30",
        "while got < n and piece >= (8 << 20):",
        "    ask = min(piece, n - got)",
        "    try:",
        "        r = fcntl.fcntl(fd, 42, struct.pack('IiqqQ', 4, 3, 0, ask, 0)); got += struct.unpack('IiqqQ', r)[4]",
        "    except OSError as e:",
        "        if e.errno != errno.ENOSPC: raise",
        "        piece //= 2",
        "os.ftruncate(fd, got)",
        "os.close(fd)",
        "print('allocated', got)",
      ].join("\n"), filler(), String(bytes)], { encoding: "utf8" });
      const said = `${(pa.stdout ?? "").trim()} ${(pa.stderr ?? "").trim().split("\n").pop() ?? ""}`.trim();
      if (freeOn(DATA.C) <= want + 256 * 1048576) return `allocated (${said})`;
      log(`  allocation took too little: ${said}; ${((freeOn(DATA.C) - want) / 1048576).toFixed(0)} MB over what was wanted`);
      // (written by a child of its own, the drill's loop going on meanwhile: rr34-1126's dd held it 15 s)
      const status = await new Promise<number | null>((resolve) => spawn("dd", ["if=/dev/zero", `of=${filler()}`, "bs=8m", `count=${Math.floor(bytes / (8 * 1048576))}`], { stdio: "ignore" }).on("exit", resolve));
      return `written (dd ${status}: a full disk ends it with 1)`;
    };
    try {
      await check("3h: setup: this machine has the room; C enrolled on a 24 GiB sparse APFS volume of its own, over the floor", async () => {
        const host = freeOn(WORK);
        log(`  this machine's disk: ${(host / GiB).toFixed(1)} GiB free`);
        if (host < 30 * GiB) throw new Error(`not run: this machine has ${(host / GiB).toFixed(1)} GiB free, 30 wanted`);
        cId = await enroll("C", "move-fill");
        C = `${ws}/${cId}`;
        stationDo("second-stop", "third");
        rmSync(`${img}.sparseimage`, { force: true });
        sh("hdiutil", ["create", "-quiet", "-type", "SPARSE", "-size", "24g", "-fs", "APFS", "-volname", "drillfill", img]);
        const orig = `${DATA.C}.orig`;
        rmSync(orig, { recursive: true, force: true });
        sh("mv", [DATA.C, orig]);
        mkdirSync(DATA.C);
        sh("hdiutil", ["attach", "-quiet", "-nobrowse", "-mountpoint", DATA.C, `${img}.sparseimage`]);
        mounted = true;
        sh("cp", ["-a", `${orig}/.`, DATA.C]);
        rmSync(orig, { recursive: true, force: true });
        stationDo("again", "third");
        await a.until({ topic: "stations", scope: ws }, (v) => (v ?? []).find((s: J) => s.id === cId && s.online), 120_000);
        freeBefore = freeOn(DATA.C);
        log(`  C ${cId}: ${(freeBefore / GiB).toFixed(2)} GiB free`);
        if (freeBefore < 21 * GiB) throw new Error(`C's volume has ${(freeBefore / GiB).toFixed(2)} GiB free: not over the floor (20 GiB) with a chat's room`);
      });
      if (cId !== "" && mounted) {
        await check("3h: C's volume filled once the first pass began: the hand-over fails, the chat on A answering, nothing of it on C", async () => {
          key = await faultChat("f3h", 1000, 400);
          const t0 = Date.now();
          await a.call("move.start", { station: A, to: cId, module: "chats", item: key, withNeeds: true });
          await firstPass(key, t0, "C");
          const free0 = freeOn(DATA.C);
          const how = await take(free0 - 64 * 1048576);
          const free1 = freeOn(DATA.C);
          log(`  C's volume: ${(free0 / 1048576).toFixed(0)} MB free as the first pass began, ${(free1 / 1048576).toFixed(0)} MB once filled (${how}); this machine's disk ${(freeOn(WORK) / GiB).toFixed(1)} GiB free`);
          if (free1 > 256 * 1048576) throw new Error(`C's volume not filled: ${(free1 / 1048576).toFixed(0)} MB free`);
          const l = await turnEnds("A", t0, 600_000);
          for (const d of l.done ?? []) if (d.module === "accounts") toC.add(d.id);
          const o = outOf(key);
          log(`  ${outcome(l)}; its hand-over ${o?.step} ${o?.error ?? ""}`);
          if ((l.done ?? []).some((d: J) => named(d) === `chats ${key}`)) throw new Error(`moved though C's disk was full: ${outcome(l)}`);
          // (C's own write failing is C's refusal, in numbers: station.move.why.fullThere, its error's code and what is free
          // there now; never the words of a station that did not answer)
          const why = failedWhy(l, `chats ${key}`) || (l.refused ?? []).map((r: J) => r.why).join(" | ");
          if (/没有应答|did not answer|not answer/i.test(why)) throw new Error(`told as a station that did not answer: ${why}`);
          if (!/ENOSPC|EDQUOT|EROFS/.test(why) || !/\d+(?:\.\d+)?\s*(?:GB|GiB|MB)/.test(why)) throw new Error(`not C's full disk in numbers (its error's code, what is free there): ${why}`);
          if (standing("A", key) !== "live") throw new Error(standings(key));
          await whenChanged([`${DATA.C}/replica`], () => !handovers("C", "in").some((i) => (i.keys ?? []).includes(key) && i.step === "coming") && true, 120_000, () => `C's hand-over in: ${brief(handovers("C", "in"))}`);
          if (standing("C", key) !== "none") throw new Error(`C has ${standing("C", key)} of it`);
          const said = await say(key, `drill-note:f3h-${tag}`, `drill-noted f3h-${tag}`);
          if (at(/cwd=(\S+)/.exec(said)?.[1] ?? "") !== "A") throw new Error(said);
        });
        await check("3h: the filler gone, C's room comes back (nothing of the chat left there) and the chat moves there and back", async () => {
          rmSync(filler(), { force: true });
          // (APFS gives back what a file took as it gets to it, not at its unlink: drill 36 read C 24 GB short at once)
          await whenChanged([], () => freeOn(DATA.C) >= freeBefore - 100 * 1048576, 120_000, () => "", 1000).catch(() => {});
          const free = freeOn(DATA.C);
          log(`  C free before ${(freeBefore / 1048576).toFixed(0)} MB, now ${(free / 1048576).toFixed(0)} MB`);
          if (free < freeBefore - 100 * 1048576) throw new Error(`C has ${((freeBefore - free) / 1048576).toFixed(0)} MB less free than before: what was placed of the chat stayed`);
          const l = await moveChat(key, "C");
          for (const d of l.done ?? []) if (d.module === "accounts") toC.add(d.id);
          if (standing("C", key) !== "live") throw new Error(`${standings(key)}; ${outcome(l)}`);
          const said = await say(key, `drill-note:f3h-c-${tag}`, `drill-noted f3h-c-${tag}`);
          if (at(/cwd=(\S+)/.exec(said)?.[1] ?? "") !== "C") throw new Error(said);
          await home(key);
        });
      }
    } finally {
      rmSync(filler(), { force: true });
      if (cId !== "") {
        const t0 = Date.now();
        await a.call("move.back", { station: A, from: cId, all: true }).then(() => turnEnds("A", t0, 120_000)).then((l) => log(`  what moved to C brought back: ${outcome(l)}`), (e) => log(`  what moved to C not brought back: ${String(e).slice(0, 300)}`));
        for (const id of toC) {
          const t1 = Date.now();
          await a.call("move.back", { station: A, from: cId, module: "accounts", item: id }).then(() => turnEnds("A", t1, 120_000)).then((l) => log(`  ${id} back from C: ${outcome(l)}`), (e) => log(`  ${id} not back from C: ${String(e).slice(0, 300)}`));
        }
      }
      try {
        if (cId !== "") stationDo("second-stop", "third");
        if (mounted) sh("hdiutil", ["detach", "-quiet", "-force", DATA.C]);
        rmSync(`${img}.sparseimage`, { force: true });
        if (cId !== "") {
          await a.call("workspace.removeStation", { account: a.sub, workspace: ws, station: cId }).catch((e) => log(`  C not taken out: ${e}`));
          stationDo("second-down", "third");
        }
      } catch (e) {
        log(`  C's end: ${String(e).slice(0, 300)}`);
      }
      cId = "";
    }
  }
  if (part("3f") && (limit("3f", 900), await clean("3f"))) {

    /// A handed over to a fresh Node by its launcher (SIGUSR2, what an update does once it goes ahead), until the new
    /// one says it has taken over.
    const handOverA = async () => {
      const end = await handoverEnd(await handOver("A"));
      if (!/has taken over/.test(end)) throw new Error(`not handed over: ${end}`);
    };
    let key = "";
    await check("3f: A handed over to a fresh process (SIGUSR2 to its launcher) during an agent's turn: the turn is not cut", async () => {
      key = await newChat(`f3f-${tag}`);
      const g = `g${tag}`;
      const t0 = Date.now();
      await a.call("chat.send", { station: A, session: key, text: `drill-gate:${g}` });
      const began = await whenChanged([ST], () => turns(t0).find((t) => t.text.includes(`drill-gate:${g}`)), 60_000, () => "the gated turn never began");
      // (the gate opened whatever the handover's check says: a turn left open is in its turn for good, and the next part
      // that moves this chat waits ten minutes on it: drill 22's part 4)
      try {
        await handOverA();
      } finally {
        writeFileSync(`${FAKE}.gate-${g}`, "go\n");
      }
      const v = await untilChat(key, (v) => texts(v).some((t) => t.startsWith(`drill-gated ${g}`)) && v, 120_000);
      const answers = texts(v).filter((t) => t.startsWith(`drill-gated ${g}`));
      const handed = turns(t0).filter((t) => t.text.includes(`drill-gate:${g}`));
      if (answers.length !== 1 || !answers[0]!.includes(`pid=${began.pid}`) || handed.length !== 1) throw new Error(`answers ${brief(answers)}, the turn began in ${began.pid}, handed ${handed.length} times`);
    });
    let k3 = "";
    // (a handover by hand in a move's first pass fails that chat's hand-over cleanly: the station's own updates are held
    // while a move's turn runs, so only a hand-made one meets it; the lead, 2026-11-14: right, as long as the chat is
    // here and working, the turn says what happened and what to do, and nothing is left on B: the last two by endsWell)
    await check("3f: A handed over to a fresh process during a move's first pass: the chat stays on A and the turn says what happened and what to do", async () => {
      k3 = await faultChat("f3f-move", 300);
      const t0 = Date.now();
      await a.call("move.start", { station: A, to: bId, module: "chats", item: k3, withNeeds: true });
      await firstPass(k3, t0);
      await handOverA();
      const l = await turnEnds("A", t0);
      log(`  ${outcome(l)}; ${standings(k3)}; its hand-over ${outOf(k3)?.step}: ${outOf(k3)?.error}`);
      if (standing("B", k3) === "live") return;
      if (standing("A", k3) !== "live") throw new Error(`neither went nor stayed: ${standings(k3)}`);
      const why = failedWhy(l, `chats ${k3}`) || String(outOf(k3)?.error ?? "");
      // (what to do, as the station says it in its language: a hand-over's own, station.move.restartedMidway /
      // stoppedMidway / stoppedHeld, zh 「…再迁移一次」, en "…hand it over again"; or the turn's, a station restarted mid-move,
      // zh 「…再发起一次即可继续」 (drill 23), en "…ask again to go on"; or an error worded by the move, station.move.why
      // .unanswered / failedHere / carryUnanswered / carryFailed, zh 「…再试一次」「…再迁一次」, en "…try again", "…move it
      // again")
      if (!/再迁移一次|再发起一次|再交接一次|再试一次|再迁一次|over again|ask again|try again|move it again/i.test(why)) throw new Error(`it stayed on A, but what the turn says does not say what to do: ${why || outcome(l)}`);
    });
    if (k3 !== "") await endsWell("3f", k3);
    log("SKIP 3f: the station's own self-update waits for a move's turn (updates/holds.ts): not built, the harness's stations have autoUpdate off and no newer release to update to; only the launcher's handover (SIGUSR2) is reachable, above");
  }

  // ── 4: everything to B and all back ──
  if (part("4") && (limit("4", 3600), await clean("4"))) {
    const keys: string[] = [];
    const archived: string[] = [];
    /// An archived chat's room as its station packed it on A (its `mine.txt` inside): the packed file, and its bytes'
    /// digest as packed before the move (drill 22 read `workspace/mine.txt` of a packed room, which has none).
    const packedOf = (k: string): string | null => {
      const r = roomOn("A", k)!;
      return [join(r, "workspace.tar.zst"), join(dirname(r), "workspace.tar.zst")].find((f) => existsSync(f)) ?? null;
    };
    const digestOf = (f: string) => createHash("sha256").update(readFileSync(f)).digest("hex");
    const packed = new Map<string, string>();
    let jobTag = "";
    await check("4: setup: about 12 chats on A (3 archived with their packed workspace), a job, the vault item, the skill, a setting, the account", async () => {
      for (let i = 0; i < 10; i++) keys.push(await newChat(`all-${i}-${tag}`));
      for (const k of keys) writeFileSync(join(roomOn("A", k)!, "mine.txt"), `${k}\n`);
      jobTag = `all${tag}`;
      await say(keys[0]!, `drill-job:${jobTag}`, `drill-job ${jobTag}`);
      // (a job is a process: no file of A's need change as it starts, so looked at each second as well; drill 37's
      // started as A's directory had gone quiet and was never looked for again)
      await whenChanged([DATA.A], () => jobs(jobTag).length > 0, 60_000, () => `no job: ${jobEvidence(jobTag)}`, 1000);
      for (const k of keys.slice(7)) {
        const thread = (await untilChat(k, (v) => typeof v?.thread?.id === "number" && v)).thread.id;
        await a.call("chat.archive", { station: A, session: k, thread, archived: true });
        archived.push(k);
      }
      await whenChanged([DATA.A], () => archived.every((k) => packedOf(k) !== null), 120_000, () => `not packed: ${archived.map((k) => roomOn("A", k)).join(", ")}`);
      for (const k of archived) packed.set(k, digestOf(packedOf(k)!));
    });
    const plan0 = await a.until(moveT(bId), (v) => v?.modules?.length > 0 && v, 60_000).catch(() => null);
    log(`  before: ${plan0?.modules?.map((m: J) => `${m.id} ${m.done}/${m.total}`).join(", ")}`);
    const allChats = () => sql("A", "select key from sessions where (ws is null or (ws not like 'handed:%' and ws not like 'coming:%'))").map((r) => r.key as string);
    const before = allChats();
    let moved = false;
    await check("4: move.start {all} to B: every module done of total", async () => {
      const t0 = Date.now();
      await a.call("move.start", { station: A, to: bId, all: true });
      const l = await turnEnds("A", t0, 1_800_000);
      measured(`all of A (${before.length} chats) to B: ${(((typeof l?.at === "number" ? l.at : Date.now()) - t0) / 1000).toFixed(1)} s by the station's turn (seen at ${((Date.now() - t0) / 1000).toFixed(1)} s)`);
      log(`  ${outcome(l)}`);
      moved = true;
      const v = await atRest("4");
      const short = v.modules.filter((m: J) => m.done !== m.total);
      log(`  after: ${v.modules.map((m: J) => `${m.id} ${m.done}/${m.total}`).join(", ")}`);
      if (short.length > 0) throw new Error(`not all there: ${short.map((m: J) => `${m.id} ${m.done}/${m.total}${(m.items ?? []).filter((x: J) => x.state !== "there").slice(0, 3).map((x: J) => ` [${x.label}: ${x.state} ${x.note}]`).join("")}`).join("; ")}`);
    });
    if (moved) {
      await check("4: each chat once on B (the device's list) and answering there", async () => {
        for (const k of before) {
          if (!liveOn(k).includes("B")) throw new Error(`${k}: ${standings(k)}`);
        }
        for (const k of keys.slice(0, 7)) {
          await listedOnceOn(k, "B");
          const said = await say(k, `drill-note:all-${k.slice(-6)}`, `drill-noted all-${k.slice(-6)}`);
          if (at(/cwd=(\S+)/.exec(said)?.[1] ?? "") !== "B") throw new Error(`${k}: ${said}`);
        }
      });
      await check("4: archived chats on B with their packed workspace", async () => {
        for (const k of archived) {
          const r = roomOn("B", k);
          if (r === null || !(existsSync(join(r, "workspace.tar.zst")) || existsSync(join(dirname(r), "workspace.tar.zst")))) throw new Error(`${k}: room ${r} without workspace.tar.zst`);
        }
      });
      await check("4: the job, the vault item, the skill, the setting and the account on B", async () => {
        const j = jobs(jobTag);
        if (!(j.length === 1 && j[0]!.on === "B")) throw new Error(`the job: ${jobsText(jobTag)}`);
        if (sql("B", `select count(*) n from ${encrypted ? "vault_items" : "vault_plain"}`)[0].n < 1) throw new Error(`no ${encrypted ? "vault" : "plain"} item on B`);
        if (!existsSync(`${DATA.B}/agent/skills/drill-skill/SKILL.md`)) throw new Error("no skill on B");
        const cfg = JSON.parse(readFileSync(`${DATA.B}/config.json`, "utf8"));
        if (cfg.maxNudges !== 7) throw new Error(`B's maxNudges ${cfg.maxNudges}`);
        if (!(cfg.profiles ?? []).some((p: J) => p.runtime === "claude")) throw new Error(`B's profiles ${brief(cfg.profiles)}`);
      });
      await check("4: nothing of its chats left visible on A; A's page offers taking it out of the workspace", async () => {
        const left = allChats();
        if (left.length > 0) throw new Error(`A still shows ${left.length}: ${left.slice(0, 5).map((k) => `${k} ${standings(k)}`).join("; ")}`);
        const v = await a.until(moveT(bId), (v) => v?.modules && v, 60_000);
        if (v.allThere !== true) throw new Error(`allThere ${v.allThere}`);
      });
      await check("4: all back (move.back {all} from A's page): A as before", async () => {
        const t0 = Date.now();
        await a.call("move.back", { station: A, from: bId, all: true });
        const l = await turnEnds("A", t0, 1_800_000);
        measured(`all of it back from B (${before.length} chats): ${(((typeof l?.at === "number" ? l.at : Date.now()) - t0) / 1000).toFixed(1)} s by the station's turn (seen at ${((Date.now() - t0) / 1000).toFixed(1)} s)`);
        log(`  ${outcome(l)}`);
        const now = new Set(allChats());
        const missing = before.filter((k) => !now.has(k));
        if (missing.length > 0) throw new Error(`not back on A: ${missing.slice(0, 5).map((k) => `${k} ${standings(k)}`).join("; ")} (${missing.length})`);
        for (const k of keys) {
          // (an archived one's room packed as it was before it went, byte for byte; the others' file as written)
          if (packed.has(k)) {
            const f = packedOf(k);
            if (f === null || digestOf(f) !== packed.get(k)) throw new Error(`${k}'s packed room: ${f === null ? "none on A" : "not the bytes it had before it went"}`);
          } else if (readFileSync(join(roomOn("A", k)!, "mine.txt"), "utf8") !== `${k}\n`) throw new Error(`${k}'s file`);
        }
        const j = jobs(jobTag);
        if (!(j.length === 1 && j[0]!.on === "A")) throw new Error(`the job: ${jobsText(jobTag)}`);
        const onB = sql("B", "select count(*) n from sessions where (ws is null or (ws not like 'handed:%' and ws not like 'coming:%'))")[0].n;
        if (onB > 0) throw new Error(`B still shows ${onB} chats`);
        const cfg = JSON.parse(readFileSync(`${DATA.B}/config.json`, "utf8"));
        if (cfg.maxNudges !== undefined) throw new Error(`B kept the setting it was given: maxNudges ${cfg.maxNudges}`);
        // (the skill stays on B: the workspace's skills are every station's, no move's to take back)
        // (a vault in safe mode is every station's: alice's device brings it to each station that lacks it, client/core-ts
        // src/views/vault.ts `spread`, so B keeps it whatever the move did; only the plain library's is the move's alone)
        if (!encrypted && sql("B", "select count(*) n from vault_plain")[0].n > 0) throw new Error("B kept the vault item it was given");
      });
    }
    log("SKIP 4: a connect moved with `all`: no connect is part of this part's station; a Slack connect's chats and the connect itself are part 4s's, on Slack's stand-in");
  }

  // ── 4s: a Slack connect, its chats and itself moved, on real processes, Slack being its stand-in ──
  // (e2e/slack-stand-in.ts: each station pointed at a port of its own, so every call and socket is known by the station
  // that made it)
  if (part("4s") && (limit("4s", 5400), await clean("4s"))) {
    const APP = "xapp-1-drill";
    const APP1 = "xapp-2-drill";
    const sl = new SlackStandIn(process.env.E2E_SF_SRC!, [{ app: APP, bot: "xoxb-1-drill", user: "UBOT" }, { app: APP1, bot: "xoxb-2-drill", user: "UBOT2" }], (line) => log(`  ${line}`));
    const CH = "C1";
    const CH1 = "C2";
    const dk = "dk";
    const dks = "dks";
    const itemOf = (id: string) => `${id}@${aId}`;
    const keyOf = (ts: string) => `${dk}:${CH}:${ts}`;
    const cfgOf = (n: Name): J => JSON.parse(readFileSync(`${DATA[n]}/config.json`, "utf8"));
    // (as the station it moved to names it: `<id>@<the station it was added on>`, connects/workspace.ts take)
    const holds = (id: string) => (["A", "B"] as Name[]).filter((n) => (cfgOf(n).connects ?? []).some((c: J) => c?.id === id || c?.id === itemOf(id)));
    /// What was asked in a thread, and whether an answer must come (one said while its chat's station was down need
    /// not: what is said then is the notice's); each is held to one answer at the part's end.
    const asked: { thread: string; word: string; channel: string; must: boolean }[] = [];
    const sayIn = (thread: string | undefined, text: string, word: string, o: { app?: string; channel?: string; must?: boolean } = {}) => {
      const s = sl.say(o.app ?? APP, o.channel ?? CH, text, thread);
      asked.push({ thread: thread ?? s.ts, word, channel: o.channel ?? CH, must: o.must ?? true });
      log(`  Slack: ${thread === undefined ? "a new conversation" : `in ${thread}`}: ${text} (${s.id})`);
      return s;
    };
    const answersTo = (thread: string, word: string, channel = CH) => sl.posted(channel, thread).filter((c) => (c.params.text ?? "").startsWith(word));
    const answerTo = (thread: string, word: string, ms = 180_000, channel = CH) => sl.until(`answer "${word}" in ${thread}`, () => answersTo(thread, word, channel)[0], ms);
    const cwdOf = (c: Call): Name | "?" => at(/cwd=(\S+)/.exec(c.params.text ?? "")?.[1] ?? "");
    const sockets = (app = APP) => sl.live(app).map((s) => `${s.station}#${s.n}`).join(",") || "none";
    /// Each two sockets of `app` open at once between `from` and `to`: which, and for how long (ms).
    const overlaps = (app: string, from = 0, to = Infinity) => {
      const of = sl.sockets.filter((s) => s.app === app);
      const out: string[] = [];
      for (let i = 0; i < of.length; i++) {
        for (let j = i + 1; j < of.length; j++) {
          const x = of[i]!;
          const y = of[j]!;
          const start = Math.max(x.opened, y.opened, from);
          const end = Math.min(x.closed || Date.now(), y.closed || Date.now(), to);
          if (end > start) out.push({ ms: end - start, said: `${x.station}#${x.n} and ${y.station}#${y.n} for ${end - start} ms at ${new Date(start).toISOString().slice(11, 23)}` });
        }
      }
      return out;
    };
    /// Each time between `from` and `to` that no socket of `app` was open (a station that was down aside: what is
    /// asked of this is a move's own).
    const gaps = (app: string, from: number, to = Date.now()) =>
      (sl.none.get(app) ?? []).filter((g) => g.from > 0 && g.from < to && (g.to === 0 || g.to > from)).map((g) => ({ ms: (g.to || to) - g.from, said: `none open for ${(g.to || to) - g.from} ms at ${new Date(g.from).toISOString().slice(11, 23)}` }));
    /// A move's window as measured (both open at once, none open), and what of it is over a second: the platform takes
    /// several sockets of an app, giving an event to one, so what is held is each event handled once; a window as long
    /// as a second is no switch.
    const windowOf = (label: string, app: string, from: number, to = Date.now()) => {
      const two = overlaps(app, from, to);
      const none = gaps(app, from, to);
      measured(`4s ${label}: ${two.length === 0 ? "never two open" : `two open: ${two.map((x) => x.said).join("; ")}`}; ${none.length === 0 ? "never none open" : none.map((x) => x.said).join("; ")}`);
      return [...two, ...none].filter((x) => x.ms > 1000).map((x) => x.said);
    };
    /// The live chat of thread `ts` in `channel`, wherever it is (its key there: B names a connect it took by its
    /// origin, `dk@<A's id>`).
    const chatOf = (ts: string, channel = CH): { on: Name; key: string } | null => {
      for (const n of stations()) {
        const k = sql(n, `select key from sessions where key like ${lit(`%:${channel}:${ts}`)} and (ws is null or (ws not like 'handed:%' and ws not like 'coming:%'))`)[0]?.key;
        if (typeof k === "string") return { on: n, key: k };
      }
      return null;
    };
    /// Whether A's login is lent to B now (A's config: cc shared with B, A its host), and the chats of a connect on B by
    /// whose they are: moved from A (named as A names them) or begun there (`<id>@<A's id>`, B's name of a connect it took).
    const lentToB = () => (cfgOf("A").profiles ?? []).some((p: J) => p.id === "cc" && p.share != null && p.share.borrowed !== true && (p.share.allow ?? []).some((x: string) => bId.startsWith(x) || x.startsWith(bId.slice(0, 8))));
    const onB = (id: string) => ({ fromA: chatsOn("B", id).filter((k) => k.startsWith(`${id}:`)), begun: sql("B", `select key from sessions where key like ${lit(`${itemOf(id)}:%`)} and archived_at is null and (ws is null or (ws not like 'handed:%' and ws not like 'coming:%'))`).map((r) => r.key as string) });
    /// How many of the app's sockets an envelope was acknowledged on.
    const ackedOn = (id: string) => sl.sockets.filter((s) => s.acked.has(id)).map((s) => `${s.station}#${s.n}`);
    const moveConnect = async (id: string, to: Name, withNeeds = true) => {
      const t0 = Date.now();
      await a.call("move.start", { station: A, to: idOf(to), module: "connects", item: itemOf(id), withNeeds });
      return turnEnds("A", t0);
    };
    const backConnect = async (id: string, from: Name) => {
      const t0 = Date.now();
      await a.call("move.back", { station: A, from: idOf(from), module: "connects", item: itemOf(id) });
      return turnEnds("A", t0);
    };
    /// The connect's chats live on `n` now (by their sessions there).
    const chatsOn = (n: Name, id = dk) => sql(n, `select key from sessions where key like ${lit(`${id}:%`)} and (ws is null or (ws not like 'handed:%' and ws not like 'coming:%'))`).map((r) => r.key as string);
    /// People's pace in Slack: a message a second while a move runs, a cadence of the drill's, no wait for anything.
    const cadence = () => new Promise((r) => setTimeout(r, 1000)); // det-ok(script-wait): a cadence (a message a second across a move), not a wait for an event
    /// Once the turn asked at `after` ended: that what was said since got to the station that holds the connect now,
    /// `n` of them acknowledged there (so the cadence ran past the move, not before it alone).
    const takenSince = (sent: { id: string }[], after: number, n: number, station: string) =>
      sl.until(`${n} said after the move taken on ${station}`, () => sent.filter((d) => {
        const e = sl.sent.get(d.id)!;
        return (e.deliveries[0]?.at ?? 0) >= after && e.acked?.station === station;
      }).length >= n, 60_000);
    let ok = false;
    await check("4s: setup: A and B pointed at Slack's stand-in, a Slack connect (multi-session) and a single-session one on A, each app's one socket A's", async () => {
      for (const n of ["A", "B"] as Name[]) writeFileSync(join(dirname(DATA[n]), "slack-api"), await sl.listen(n));
      stationDo("halt", "station");
      try {
        const cfg = cfgOf("A");
        const own = (cfg.connects ?? []).filter((c: J) => c?.id !== dk && c?.id !== dks);
        cfg.connects = [
          ...own,
          { id: dk, name: "Drill Slack", mode: "multi-session", bind: { runtime: "claude" }, createdBy: { id: "alice@example.test" }, slack: { appToken: APP, botToken: "xoxb-1-drill", appId: "A1" } },
          { id: dks, name: "Drill Slack one", mode: "single-session", bind: { runtime: "claude" }, createdBy: { id: "alice@example.test" }, slack: { appToken: APP1, botToken: "xoxb-2-drill", appId: "A2" } },
        ];
        writeFileSync(`${DATA.A}/config.json`, JSON.stringify(cfg, null, 2));
      } finally {
        await up("A");
      }
      stationDo("halt", "second");
      await up("B");
      await sl.until("A's sockets", () => sl.live(APP).length === 1 && sl.live(APP1).length === 1, 120_000);
      log(`  sockets: ${sockets(APP)} / ${sockets(APP1)}; calls so far: ${[...new Set(sl.calls.map((c) => `${c.station}:${c.method}`))].join(" ")}`);
      if (sl.live(APP)[0]!.station !== "A" || sl.live(APP1)[0]!.station !== "A") throw new Error(`a socket not A's: ${sockets(APP)} / ${sockets(APP1)}`);
      ok = true;
    });
    let t1 = "";
    let t2 = "";
    let k1 = "";
    let k2 = "";
    if (ok) {
      await check("4s: a conversation in Slack on A: its chat made on A, answered once in its thread, by an agent on A", async () => {
        t1 = sayIn(undefined, `drill-remember:s${tag}`, `drill-remembered s${tag}`).ts;
        const c = await answerTo(t1, `drill-remembered s${tag}`);
        k1 = keyOf(t1);
        log(`  answered by ${c.station}'s connect; ${standings(k1)}; posts in it ${brief(sl.posted(CH, t1).map((p) => (p.params.text ?? "").slice(0, 60)))}`);
        if (standing("A", k1) !== "live") throw new Error(`its chat: ${standings(k1)}`);
        t2 = sayIn(undefined, `drill-note:a${tag}`, `drill-noted a${tag} `).ts;
        const c2 = await answerTo(t2, `drill-noted a${tag} `);
        k2 = keyOf(t2);
        if (cwdOf(c2) !== "A") throw new Error(`the second answered from ${cwdOf(c2)}: ${c2.params.text}`);
      });
    }
    if (k1 !== "" && k2 !== "") {
      let moved = false;
      await check("4s: its chat moved alone to B: the connect stays on A, nothing posted into the thread by the move", async () => {
        const before = sl.posted(CH, t1).length;
        const l = await moveChat(k1, "B");
        log(`  ${outcome(l)}; ${standings(k1)}; holds ${holds(dk).join(",")}; sockets ${sockets()}`);
        if (standing("B", k1) !== "live") throw new Error(`not on B: ${standings(k1)}; ${outcome(l)}`);
        if ((l.done ?? []).some((d: J) => named(d).startsWith("connects "))) throw new Error(`the connect went with it: ${outcome(l)}`);
        moved = true;
        if (holds(dk).join() !== "A") throw new Error(`the connect is on ${holds(dk).join(",") || "none"}`);
        const after = sl.posted(CH, t1).slice(before);
        if (after.length > 0) throw new Error(`posted into its thread by the move: ${brief(after.map((c) => `${c.station}: ${c.params.text}`))}`);
      });
      if (moved) {
        await check("4s: a message in its thread afterwards: taken by A's connect, answered once, from B, in the same thread, the agent going on from its context", async () => {
          const nonce = randomBytes(3).toString("hex");
          const s = sayIn(t1, `drill-recall:${nonce}`, `drill-recall ${nonce} `);
          const c = await answerTo(t1, `drill-recall ${nonce} `);
          const e = sl.sent.get(s.id)!;
          log(`  delivered ${brief(e.deliveries)}, acknowledged by ${e.acked?.station}; posted by ${c.station}'s connect: ${(c.params.text ?? "").slice(0, 200)}`);
          if (e.acked?.station !== "A") throw new Error(`acknowledged by ${e.acked?.station ?? "nobody"}, not A's connect`);
          if (cwdOf(c) !== "B") throw new Error(`answered from ${cwdOf(c)}: ${c.params.text}`);
          if (!(c.params.text ?? "").includes(`secret=s${tag}`)) throw new Error(`not from its context: ${c.params.text}`);
          if (c.station !== "A") throw new Error(`posted through ${c.station}, where the connect is not`);
        });
        await check("4s: a second chat of the connect still on A works as before", async () => {
          sayIn(t2, `drill-note:b${tag}`, `drill-noted b${tag} `);
          const c = await answerTo(t2, `drill-noted b${tag} `);
          if (cwdOf(c) !== "A") throw new Error(`answered from ${cwdOf(c)}`);
        });
        await check("4s: the connect moved alone before its other chat: refused, naming it; still A's, its socket A's", async () => {
          const l = await moveConnect(dk, "B", false);
          log(`  ${outcome(l)}; holds ${holds(dk).join(",")}; sockets ${sockets()}`);
          const r = (l.refused ?? []).find((x: J) => named(x.item) === `connects ${itemOf(dk)}`);
          if (r === undefined) throw new Error(`not refused: ${outcome(l)}`);
          if (!String(r.why).includes(k2.slice(-8)) && !/chat|对话/.test(String(r.why))) throw new Error(`refused, not naming its chat: ${r.why}`);
          if (holds(dk).join() !== "A" || sockets() !== `A#${sl.live(APP)[0]?.n}`) throw new Error(`holds ${holds(dk).join(",")}, sockets ${sockets()}`);
        });
        let switched = false;
        let L: { ts: string; event: J } = { ts: "", event: null };
        let F: { ts: string; event: J } = { ts: "", event: null };
        let ends: { ids: { last: string; first: string }; lastOn: string } = { ids: { last: "", first: "" }, lastOn: "" };
        await check("4s: its other chat moved, then the connect: events at B's socket, A's closed, one socket at a time, an event a second across it none lost or doubled", async () => {
          const l2 = await moveChat(k2, "B");
          if (standing("B", k2) !== "live") throw new Error(`the other chat not on B: ${standings(k2)}; ${outcome(l2)}`);
          // (a new conversation a second from before the connect's move to after its turn's end)
          const during: { ts: string; id: string; word: string }[] = [];
          let stop = false;
          const sender = (async () => {
            for (let i = 0; !stop && i < 120; i++) {
              const word = `drill-noted w${i}${tag} `;
              during.push({ ...sayIn(undefined, `drill-note:w${i}${tag}`, word), word });
              await cadence();
            }
          })();
          // (the cadence under way before the move: its first conversation answered)
          await sl.until("the first conversation said", () => during.length > 0, 10_000);
          await answerTo(during[0]!.ts, during[0]!.word);
          // (the window's two ends: one event down A's socket the moment B asks for its own, one the first down B's)
          L = sl.message(APP, CH, `drill-note:l${tag}`);
          F = sl.message(APP, CH, `drill-note:f${tag}`);
          asked.push({ thread: L.ts, word: `drill-noted l${tag} `, channel: CH, must: true }, { thread: F.ts, word: `drill-noted f${tag} `, channel: CH, must: true });
          ends = sl.arm(APP, "B", L.event, F.event);
          const from = Date.now();
          let l: J;
          try {
            l = await moveConnect(dk, "B");
            await takenSince(during, Date.now(), 2, holds(dk)[0] ?? "B");
          } finally {
            stop = true;
            await sender;
          }
          log(`  ${outcome(l)}; holds ${holds(dk).join(",")}; sockets ${sockets()}; ${during.length} sent across it`);
          // (refused for a conversation begun while it moved, its chat made on A after the turn's plan: said, then the
          // connect moved again with nothing said meanwhile, so the rest is driven)
          let raced = "";
          if (!(l.done ?? []).some((d: J) => named(d) === `connects ${itemOf(dk)}`)) {
            raced = outcome(l);
            log(`  not moved with conversations begun across it: ${raced}; A's chats of it now ${brief(chatsOn("A"))}`);
            const again = await moveConnect(dk, "B");
            log(`  again, nothing said meanwhile: ${outcome(again)}; holds ${holds(dk).join(",")}; sockets ${sockets()}`);
            if (!(again.done ?? []).some((d: J) => named(d) === `connects ${itemOf(dk)}`)) throw new Error(`not moved even so: ${outcome(again)}; first ${raced}`);
          }
          switched = true;
          if (holds(dk).join() !== "B") throw new Error(`held by ${holds(dk).join(",") || "none"}`);
          await sl.until("B's socket alone", () => sl.live(APP).length === 1 && sl.live(APP)[0]!.station === "B", 60_000).catch(() => {
            throw new Error(`sockets ${sockets()}`);
          });
          const answered = await Promise.all(during.map((d) => answerTo(d.ts, d.word, 300_000).then((c) => ({ d, c }), () => ({ d, c: null }))));
          for (const { d, c } of answered) {
            const e = sl.sent.get(d.id)!;
            log(`    ${d.word.trim()}: delivered ${e.deliveries.map((x) => `${x.station}#${x.n}${x.attempt > 0 ? `(retry ${x.attempt})` : ""}`).join(" ")}, acked ${e.acked?.station ?? "never"}, answered ${answersTo(d.ts, d.word).length}× ${c === null ? "" : `from ${cwdOf(c)} via ${c.station}`}`);
          }
          const lost = answered.filter((x) => x.c === null).map((x) => x.d.word.trim());
          const twice = answered.filter((x) => answersTo(x.d.ts, x.d.word).length > 1).map((x) => x.d.word.trim());
          if (lost.length > 0 || twice.length > 0) throw new Error(`unanswered ${brief(lost)}; answered more than once ${brief(twice)}`);
          const acks = during.filter((d) => ackedOn(d.id).length !== 1).map((d) => `${d.word.trim()} acknowledged on ${brief(ackedOn(d.id))}`);
          if (acks.length > 0) throw new Error(`not acknowledged once: ${acks.join("; ")}`);
          const long = windowOf("the connect's move to B", APP, from);
          if (long.length > 0) throw new Error(`over a second: ${long.join("; ")}`);
          if (raced !== "") throw new Error(`a conversation begun while it moved held the connect back (moved only when asked again with nothing said): ${raced}`);
        });
        await check("4s: at the move's two ends, one event down the leaving station's socket as the other asked for its own, one the first down the new one: each handled once, answered once, from where its chat is", async () => {
          log(`  the last went ${ends.lastOn || "nowhere: B never asked for a socket"} (${ends.ids.last}), the first ${ends.ids.first || "never"}`);
          if (ends.ids.last === "" || ends.ids.first === "") throw new Error(`the window's ends not given: ${brief(ends)}`);
          for (const [name, m, id] of [["last", L, ends.ids.last], ["first", F, ends.ids.first]] as const) {
            const word = `drill-noted ${name === "last" ? "l" : "f"}${tag} `;
            const c = await answerTo(m.ts, word, 180_000).catch(() => null);
            const e = sl.sent.get(id)!;
            const chat = chatOf(m.ts);
            log(`  the ${name}: delivered ${e.deliveries.map((x) => `${x.station}#${x.n}${x.attempt > 0 ? `(retry ${x.attempt})` : ""}`).join(" ")}, acknowledged on ${brief(ackedOn(id))}; its chat ${chat === null ? "none" : `${chat.key} on ${chat.on}`}; answered ${answersTo(m.ts, word).length}×${c === null ? "" : ` from ${cwdOf(c)} via ${c.station}`}`);
            if (c === null) throw new Error(`the ${name} not answered`);
            if (answersTo(m.ts, word).length !== 1) throw new Error(`the ${name} answered ${answersTo(m.ts, word).length}×`);
            if (ackedOn(id).length !== 1) throw new Error(`the ${name} acknowledged on ${brief(ackedOn(id))}`);
            if (chat === null || cwdOf(c) !== chat.on) throw new Error(`the ${name} answered from ${cwdOf(c)}, its chat ${chat === null ? "nowhere" : `on ${chat.on}`}`);
          }
        });
        if (switched) {
          await check("4s: with the connect on B, its moved chat's thread answered once, through B's own socket", async () => {
            sayIn(t1, `drill-note:c${tag}`, `drill-noted c${tag} `);
            const c = await answerTo(t1, `drill-noted c${tag} `);
            if (cwdOf(c) !== "B" || c.station !== "B") throw new Error(`answered from ${cwdOf(c)} via ${c.station}`);
          });
          await check("4s: back: the connect first while its chats are on B (refused with its reason, or taken back and still routing them), then the chats, then the connect: on A again, A's socket alone, both threads answered once", async () => {
            const lc = await backConnect(dk, "B");
            log(`  the connect back first: ${outcome(lc)}; holds ${holds(dk).join(",")}; sockets ${sockets()}`);
            const refused = (lc.refused ?? []).find((x: J) => named(x.item) === `connects ${itemOf(dk)}`);
            if (refused !== undefined) log(`  refused: ${refused.why}`);
            for (const k of [k1, k2]) {
              const l = await moveBack(k, "B");
              log(`  ${k.slice(-17)} back: ${outcome(l)}; ${standings(k)}`);
              if (standing("A", k) !== "live") throw new Error(`${k} not back: ${standings(k)}; ${outcome(l)}`);
            }
            // (the login it was lent for k1 and k2 stays lent while what the connect's move took there, and what was
            // begun there on it, runs on it: move.uses)
            const still = onB(dk);
            log(`  on B still: ${still.fromA.length} moved from A, ${still.begun.length} begun there; A's login lent to B: ${lentToB()}`);
            if (still.fromA.length + still.begun.length > 0 && !lentToB()) throw new Error(`A took its login back with chats on B still on it: ${brief(still)}`);
            if (holds(dk).join() !== "A") {
              const l = await backConnect(dk, "B");
              log(`  the connect back: ${outcome(l)}; holds ${holds(dk).join(",")}`);
            }
            if (holds(dk).join() !== "A") throw new Error(`the connect is on ${holds(dk).join(",") || "none"}`);
            await sl.until("A's socket alone", () => sl.live(APP).length === 1 && sl.live(APP)[0]!.station === "A", 60_000).catch(() => {
              throw new Error(`sockets ${sockets()}`);
            });
            sayIn(t1, `drill-note:d${tag}`, `drill-noted d${tag} `);
            const c = await answerTo(t1, `drill-noted d${tag} `);
            if (cwdOf(c) !== "A") throw new Error(`answered from ${cwdOf(c)}`);
            // (a conversation begun while the connect was on B: its chat is B's, routed there from A now)
            const w = asked.find((x) => x.word.startsWith("drill-noted w") && chatsOn("B").includes(keyOf(x.thread)));
            if (w !== undefined) {
              sayIn(w.thread, `drill-note:e${tag}`, `drill-noted e${tag} `);
              const c2 = await answerTo(w.thread, `drill-noted e${tag} `);
              log(`  a conversation begun on B, after: answered from ${cwdOf(c2)} via ${c2.station}`);
              if (cwdOf(c2) !== "B" || c2.station !== "A") throw new Error(`answered from ${cwdOf(c2)} via ${c2.station}`);
            } else log("  (no conversation begun while the connect was on B is on B)");
          });
        }
      }
    }

    // ── its faults, as part 3 has them for chats ──
    if (k1 !== "" && holds(dk).join() === "A") {
      let t3 = "";
      let k3 = "";
      await check("4s fault: B killed between a chat's move and the connect's: told in the thread while B is down, the connect stays A's, answered from B once B is back", async () => {
        t3 = sayIn(undefined, `drill-remember:f${tag}`, `drill-remembered f${tag}`).ts;
        await answerTo(t3, `drill-remembered f${tag}`);
        k3 = keyOf(t3);
        const l = await moveChat(k3, "B");
        if (standing("B", k3) !== "live") throw new Error(`not on B: ${standings(k3)}; ${outcome(l)}`);
        stationDo("crash", "second");
        const downAt = Date.now();
        sayIn(t3, `drill-note:x${tag}`, `drill-noted x${tag} `, { must: false });
        // (connects/workspace.ts receive: an event of a chat on another station that did not get there is told in its
        // thread, station.connect.stationAway)
        const toldNow = () => sl.posted(CH, t3).filter((c) => c.at >= downAt);
        await sl.until("a notice in the thread while B is down", () => toldNow().length > 0, 120_000).catch(() => {});
        log(`  posted in its thread since B went down: ${brief(toldNow().map((c) => `${c.station}: ${(c.params.text ?? "").slice(0, 160)}`)) || "nothing"}`);
        const silent = toldNow().length === 0;
        const lc = await moveConnect(dk, "B").catch((e) => ({ error: String(e) }) as J);
        log(`  the connect to B, B down: ${"error" in lc ? lc.error : outcome(lc)}; holds ${holds(dk).join(",")}; sockets ${sockets()}`);
        if (holds(dk).join() !== "A") throw new Error(`the connect is on ${holds(dk).join(",") || "none"} with B down`);
        if (sl.live(APP).length !== 1 || sl.live(APP)[0]!.station !== "A") throw new Error(`sockets ${sockets()}`);
        await up("B");
        sayIn(t3, `drill-recall:y${tag}`, `drill-recall y${tag} `);
        const c = await answerTo(t3, `drill-recall y${tag} `);
        if (cwdOf(c) !== "B") throw new Error(`answered from ${cwdOf(c)}`);
        log(`  the message said while B was down: answered ${answersTo(t3, `drill-noted x${tag} `).length}×`);
        if (silent) throw new Error("nothing said in the thread of a message to a chat whose station was down (the rest held)");
      });
      // (not a cut of the move between B's taking it and A's letting it go: nothing outside the station stops it there,
      // and it ended within milliseconds every run; what is held is the state after A's end at its first moment)
      await check("4s fault: A killed the moment the connect's move is asked: afterwards one station holds it, one socket, an event answered once", async () => {
        for (const k of chatsOn("A")) {
          const l = await moveChat(k, "B");
          if (standing("B", k) !== "live") throw new Error(`${k} not on B: ${outcome(l)}`);
        }
        await a.call("move.start", { station: A, to: bId, module: "connects", item: itemOf(dk), withNeeds: false });
        stationDo("crash", "station");
        const heldThen = holds(dk);
        await up("A");
        await a.stationState(ws, (s) => s.state === "online", 120_000, aId);
        log(`  held as A died: ${heldThen.join(",") || "none"}; now ${holds(dk).join(",") || "none"}; sockets ${sockets()}`);
        await sl.until("one socket", () => sl.live(APP).length === 1, 120_000).catch(() => {
          throw new Error(`sockets ${sockets()}`);
        });
        if (holds(dk).length !== 1) throw new Error(`held by ${holds(dk).join(",") || "none"}`);
        if (sl.live(APP)[0]!.station !== holds(dk)[0]) throw new Error(`the socket is ${sockets()}, the connect ${holds(dk)[0]}'s`);
        sayIn(t1, `drill-note:g${tag}`, `drill-noted g${tag} `);
        const c = await answerTo(t1, `drill-noted g${tag} `);
        log(`  answered from ${cwdOf(c)} via ${c.station}`);
      });
      // (the connect A's again, its chats on B, for the next: once A, started again, has reached B, B's log saying A asked
      // it which chats are live there; drill 37's asked at once and was refused, A's link to B not yet up)
      if (holds(dk).join() === "B") {
        const bLog = `${RUN}/${SHELL_NAME.B}.log`;
        const from = existsSync(bLog) ? statSync(bLog).size : 0;
        await a.until(moveT(bId), (v) => v?.modules && v, 60_000).catch(() => {});
        await whenChanged([RUN], () => new RegExp(`asked which chats are live there station=${aId.slice(0, 12)}`).test(since(bLog, from)), 60_000, () => "", 1000).catch(() => log("  A was not seen asking B within 60 s"));
      }
      if (holds(dk).join() === "B") await backConnect(dk, "B").then((l) => log(`  the connect back: ${outcome(l)}`), (e) => log(`  the connect not back: ${String(e).slice(0, 300)}`));
      if (holds(dk).join() === "A" && standing("B", k1) === "live") {
        await check("4s fault: A handed over to a fresh process (SIGUSR2) while a routed thread is answered on B: answered once, one socket at a time", async () => {
          const gate = `${FAKE}.gate-s${tag}`;
          sayIn(t1, `drill-gate:s${tag}`, `drill-gated s${tag} `);
          await whenChanged([dirname(FAKE)], () => existsSync(`${FAKE}.turns`) && readFileSync(`${FAKE}.turns`, "utf8").includes(`drill-gate:s${tag}`), 120_000, () => "the gated turn not begun");
          const opens = sl.sockets.length;
          const from = Date.now();
          const h = await handOver("A");
          log(`  ${await handoverEnd(h)}`);
          writeFileSync(gate, "");
          const c = await answerTo(t1, `drill-gated s${tag} `);
          const during = sl.sockets.slice(opens).map((s) => `${s.station}#${s.n} ${s.opened}-${s.closed || "open"}`);
          log(`  answered via ${c.station}; sockets opened since: ${brief(during)}; now ${sockets()}`);
          const long = windowOf("A's handover", APP, from);
          if (long.length > 0) throw new Error(`over a second: ${long.join("; ")}`);
          if (answersTo(t1, `drill-gated s${tag} `).length !== 1) throw new Error(`answered ${answersTo(t1, `drill-gated s${tag} `).length}×`);
        });
      } else fail("4s fault: A handed over while a routed thread is answered on B", new Error(`not run: it needs the connect on A and its chat on B, and the connect is on ${holds(dk).join(",") || "none"}, the chat ${standings(k1)}`));
    } else fail("4s faults", new Error(`not run: they begin with the connect on A, and it is on ${holds(dk).join(",") || "none"}${k1 === "" ? ", no chat of it made" : ""}`));

    // ── a single-session connect: not routed, so it goes first, its chat stopped, and what Slack says meanwhile kept ──
    {
      let ks = "";
      let ts1 = "";
      await check("4s single: a single-session Slack connect's chat on A answered", async () => {
        ts1 = sayIn(undefined, `drill-remember:o${tag}`, `drill-remembered o${tag}`, { app: APP1, channel: CH1 }).ts;
        await answerTo(ts1, `drill-remembered o${tag}`, 180_000, CH1);
        ks = sql("A", `select key from sessions where key like ${lit(`${dks}:%`)}`)[0]?.key ?? "";
        if (ks === "") throw new Error("no session of it on A");
      });
      if (ks !== "") {
        await check("4s single: its chat moved with what it needs: the connect first, then the chat; what is said meanwhile kept, taken there once, in order", async () => {
          const words: string[] = [];
          const qs: { id: string }[] = [];
          let stop = false;
          const sender = (async () => {
            for (let i = 0; !stop && i < 60; i++) {
              words.push(`q${i}${tag}`);
              qs.push(sayIn(ts1, `drill-note:q${i}${tag}`, `drill-noted q${i}${tag} `, { app: APP1, channel: CH1, must: false }));
              await cadence();
            }
          })();
          let l: J;
          try {
            l = await moveChat(ks, "B");
            await takenSince(qs, Date.now(), 1, "B");
          } finally {
            stop = true;
            await sender;
          }
          log(`  ${outcome(l)}; ${standings(ks)}; holds ${holds(dks).join(",")}; sockets ${sockets(APP1)}`);
          if (standing("B", ks) !== "live" || holds(dks).join() !== "B") throw new Error(`${standings(ks)}, the connect ${holds(dks).join(",") || "none"}'s`);
          const order = (l.done ?? []).map(named);
          if (order.indexOf(`connects ${itemOf(dks)}`) > order.indexOf(`chats ${ks}`)) throw new Error(`the chat before its connect: ${order.join(", ")}`);
          const last = words.at(-1)!;
          await whenChanged([DATA.B], () => sql("B", `select count(*) n from entries where text like ${lit(`%drill-note:${last}%`)}`)[0].n > 0, 120_000, () => "the last said not in B's log");
          const said = sql("B", `select text from entries where text like ${lit(`%drill-note:q%${tag}%`)} order by thread, n`).map((r) => new RegExp(`drill-note:(q\\d+)${tag}`).exec(String(r.text))?.[1]);
          const want = words.map((w) => w.replace(tag, ""));
          log(`  in B's log: ${brief(said)}; said: ${brief(want)}`);
          const twice = want.filter((w) => said.filter((x) => x === w).length > 1);
          const missing = want.filter((w) => !said.includes(w));
          if (twice.length > 0 || missing.length > 0) throw new Error(`missing ${brief(missing)}, twice ${brief(twice)}`);
          if (said.join() !== want.join()) throw new Error(`out of order: ${brief(said)}`);
        });
        await check("4s single: back: on A, its connect A's, one socket, answered there", async () => {
          const l = await moveBack(ks, "B");
          log(`  ${outcome(l)}; ${standings(ks)}; holds ${holds(dks).join(",")}`);
          if (holds(dks).join() !== "A") {
            const lc = await backConnect(dks, "B");
            log(`  the connect back: ${outcome(lc)}; holds ${holds(dks).join(",")}`);
          }
          if (standing("A", ks) !== "live" || holds(dks).join() !== "A") throw new Error(`${standings(ks)}, the connect ${holds(dks).join(",") || "none"}'s`);
          await sl.until("A's socket alone", () => sl.live(APP1).length === 1 && sl.live(APP1)[0]!.station === "A", 60_000).catch(() => {
            throw new Error(`sockets ${sockets(APP1)}`);
          });
          sayIn(ts1, `drill-note:r${tag}`, `drill-noted r${tag} `, { app: APP1, channel: CH1 });
          const c = await answerTo(ts1, `drill-noted r${tag} `, 180_000, CH1);
          if (cwdOf(c) !== "A") throw new Error(`answered from ${cwdOf(c)}`);
        });
      }
    }
    await check("4s: the login lent while chats on B run on it, taken back once they are back (moved from A, or begun there and moved to A)", async () => {
      for (const id of [dk, dks]) {
        if (holds(id).join() === "B") await backConnect(id, "B").then((l) => log(`  ${id} back: ${outcome(l)}`));
      }
      const before = { dk: onB(dk), dks: onB(dks) };
      log(`  on B: ${brief(before)}; lent to B: ${lentToB()}`);
      if ([...before.dk.fromA, ...before.dk.begun, ...before.dks.fromA, ...before.dks.begun].length > 0 && !lentToB()) throw new Error(`not lent with chats on B on it: ${brief(before)}`);
      for (const k of [...before.dk.fromA, ...before.dks.fromA]) {
        const l = await moveBack(k, "B");
        if (standing("A", k) !== "live") throw new Error(`${k} not back: ${standings(k)}; ${outcome(l)}`);
      }
      // (a Slack chat is archived by no call of the app's, chat.archive taking only still.fail's own: those begun on B
      // are moved to A by B's own turn, which ends their use of the login as well)
      for (const k of [...before.dk.begun, ...before.dks.begun]) {
        const t0 = Date.now();
        await a.call("move.start", { station: B, to: aId, module: "chats", item: k, withNeeds: true });
        const l = await turnEnds("B", t0);
        if (chatsOn("B", k.split(":")[0]!).includes(k)) throw new Error(`${k} still on B: ${outcome(l)}`);
      }
      const left = { dk: onB(dk), dks: onB(dks) };
      log(`  then on B: ${brief(left)}`);
      await whenChanged([DATA.A], () => !lentToB(), 120_000, () => `still lent to B: ${brief((cfgOf("A").profiles ?? []).map((p: J) => ({ id: p.id, share: p.share ?? null })))}; on B ${brief(left)}`, 1000);
      log("  A's login taken back");
    });
    log("SKIP 4s: a Comma connect moved: not built, the harness has no Comma stand-in (and Feishu's routed connect is Slack's path with another platform's client, not driven here)");

    await check("4s: every message said in Slack answered exactly once (but those said to a station that was down, which need not be)", async () => {
      // (what is still to come comes within the minute, else it is counted as it is)
      await sl.until("every answer", () => asked.every((x) => !x.must || answersTo(x.thread, x.word, x.channel).length > 0), 60_000).catch(() => {});
      const none = asked.filter((x) => x.must && answersTo(x.thread, x.word, x.channel).length === 0).map((x) => x.word.trim());
      const more = asked.filter((x) => answersTo(x.thread, x.word, x.channel).length > 1).map((x) => `${x.word.trim()} ×${answersTo(x.thread, x.word, x.channel).length}`);
      const unacked = [...sl.sent.values()].filter((e) => e.acked === null).map((e) => e.id);
      const again = [...sl.sent.values()].filter((e) => e.deliveries.length > 1).map((e) => `${e.id}×${e.deliveries.length}`);
      log(`  ${asked.length} said; sent again by Slack ${brief(again)}; never acknowledged ${brief(unacked)}`);
      log(`  answered by the stand-in with { ok: true } and nothing else: ${[...sl.generic].map(([m, n]) => `${m} ×${n}`).join(", ") || "none"}`);
      log(`  sockets: ${sl.sockets.map((s) => `${s.app === APP ? "dk" : "dks"} ${s.station}#${s.n} ${((s.closed || Date.now()) - s.opened) / 1000}s`).join(", ")}`);
      if (none.length > 0 || more.length > 0) throw new Error(`unanswered ${brief(none)}; more than once ${brief(more)}`);
    });
    await check("4s: never two sockets of one app open at once for a second or more, across the part (shorter, measured)", async () => {
      const two = [...overlaps(APP).map((x) => ({ ...x, said: `dk: ${x.said}` })), ...overlaps(APP1).map((x) => ({ ...x, said: `dks: ${x.said}` }))];
      measured(`4s: two sockets of one app open at once: ${two.length === 0 ? "never" : two.map((x) => x.said).join("; ")}`);
      const long = two.filter((x) => x.ms > 1000).map((x) => x.said);
      if (long.length > 0) throw new Error(`for a second or more: ${long.join("; ")}`);
    });

    // (the stations as part 4 left them: no connect, nothing pointed at the stand-in; the chats Slack made stay)
    await check("4s: end: the connects taken out of A's and B's config and the stand-in let go", async () => {
      for (const [n, shell] of [["A", "station"], ["B", "second"]] as const) {
        stationDo("halt", shell);
        try {
          const cfg = cfgOf(n);
          cfg.connects = (cfg.connects ?? []).filter((c: J) => c?.id !== dk && c?.id !== dks);
          writeFileSync(`${DATA[n]}/config.json`, JSON.stringify(cfg, null, 2));
          rmSync(join(dirname(DATA[n]), "slack-api"), { force: true });
        } finally {
          await up(n);
        }
      }
      await sl.close();
    });
  }

  // ── 5: measured ──
  if (part("5")) {
    limit("5", 10800);
    // (E2E_MOVE_CHATS: the whole move's size, shown and archived as the real station's 149 of 2,384; E2E_MOVE_WHOLE_ONLY:
    // the 500 MB chat's trip and that move alone, there and back, their tables and totals, the 300 chats' timing left
    // out: a trip of a few minutes to set two trees side by side)
    const many = Number(process.env.E2E_MOVE_CHATS ?? 2384);
    const manyShown = Math.round((many * 149) / 2384);
    const wholeOnly = process.env.E2E_MOVE_WHOLE_ONLY === "1";
    await check("5: one chat with a 500 MB / 5,000-file room: its first pass and its pause, measured", async () => {
      const key = await newChat(`big-${tag}`);
      const t1 = Date.now();
      fill(roomOn("A", key)!, "bulk", 5000, 100 * 1024);
      log(`  room made in ${((Date.now() - t1) / 1000).toFixed(1)} s`);
      const t0 = Date.now();
      await a.call("move.start", { station: A, to: bId, module: "chats", item: key, withNeeds: true });
      const l = await turnEnds("A", t0, 1_800_000);
      const s = steps.A!.of(outOf(key)?.id ?? "");
      const heldAt = s.find((x) => x.held)?.at;
      const goneAt = s.find((x) => x.step === "gone" || x.step === "done")?.at;
      measured(`500 MB / 5,000 files: first pass ${heldAt ? ((heldAt - t0) / 1000).toFixed(1) : "?"} s, held ${heldAt && goneAt ? ((goneAt - heldAt) / 1000).toFixed(2) : "?"} s, turn ${((Date.now() - t0) / 1000).toFixed(1)} s (${outcome(l)})`);
      if (standing("B", key) !== "live") throw new Error(`${standings(key)}; ${outcome(l)}`);
      await home(key);
    });
    /// A's chats brought to `live` shown and `archived` archived, what lacks made by the station's own store while A
    /// is stopped (e2e/move-seed.ts), then A started again and online.
    const seed = async (live: number, archived: number) => {
      const countOf = (q: string) => sql("A", `select count(*) n from sessions where (ws is null or (ws not like 'handed:%' and ws not like 'coming:%')) and ${q}`)[0].n as number;
      const addLive = Math.max(0, live - countOf("archived_at is null"));
      const addOld = Math.max(0, archived - countOf("archived_at is not null"));
      if (addLive + addOld === 0) return;
      const home = sql("A", "select ws from sessions where ws is not null and ws not like 'handed:%' and ws not like 'coming:%' limit 1")[0]?.ws ?? ws;
      stationDo("halt", "station");
      log(`  ${execFileSync(process.execPath, ["--no-warnings", join(dirname(new URL(import.meta.url).pathname), "move-seed.ts"), process.env.E2E_SF_SRC!, DATA.A, home, String(addLive), String(addOld), randomBytes(3).toString("hex")], { encoding: "utf8", timeout: 1_800_000 }).trim()}`);
      stationDo("again", "station");
      const up = Date.now();
      await a.stationState(ws, (s) => s.state === "online", 120_000, aId);
      // (and the device's link to it usable again: a request of its answered by the new process. Online is the cloud's
      // word, which comes first: drill 28's link to A, dialled into the endpoint as it closed, sat three beats (15 s) on
      // a dead connection, and the page's first answer timed after online read 16,446 ms where GET /move took 15)
      // (a request asked after A was up, not one asked of the process before and answered as A came back: p5-5a0d's
      // 300 chats took one of those for the link usable, and its first answer waited 14 s on the dead link)
      const ready = await a.answered(aId, "/", up, 120_000, true);
      log(`  A's link usable again ${ready.at - up} ms after A was up (${ready.method} ${ready.path.replace(/\?.*$/, "")})`);
    };
    /// What the stations' logs say of their main thread held since `from` (each log's byte offset): how often, the longest.
    const logs = () => ({ A: `${RUN}/station.log`, B: `${RUN}/second.log` });
    const offsets = () => Object.fromEntries(Object.entries(logs()).map(([n, f]) => [n, existsSync(f) ? statSync(f).size : 0])) as Record<string, number>;
    const holds = (from: Record<string, number>) => Object.entries(logs()).map(([n, f]) => {
      const t = existsSync(f) ? since(f, from[n] ?? 0) : "";
      const ms = [...t.matchAll(/the main thread was held.*?heldMs=(\d+)/g)].map((m) => Number(m[1]));
      return `${n}: ${ms.length} held, longest ${ms.length === 0 ? 0 : Math.max(...ms)} ms${ms.filter((x) => x > 200).length > 0 ? ` (${ms.filter((x) => x > 200).length} over 200 ms)` : ""}`;
    }).join("; ");
    /// GET /move as the device asks it, its link to A usable (seed's wait): the `stationMove` topic's first answer for a page not read yet, and how long
    /// the request itself took (its answer read to its end); and station_move plan through an agent, less a turn's own.
    const timeMove = async (label: string, key: string) => {
      const limit = 51 + Math.floor(Math.random() * 140);
      const from = offsets();
      const t0 = Date.now();
      await a.until(moveT(bId, "chats", limit), (v) => v?.modules && v, 300_000);
      const shown = Date.now() - t0;
      const answered = await a.answered(aId, "/move", t0, 1000).then((x) => x.at - t0, () => -1);
      const t1 = Date.now();
      await say(key, `drill-seed:base-${label}`, `drill-seeded base-${label}`);
      const turn = Date.now() - t1;
      const t2 = Date.now();
      await say(key, `drill-move:${JSON.stringify({ action: "plan", to: bId })}`, "drill-move:", 600_000);
      const plan = Date.now() - t2;
      measured(`${label}: stationMove first answer ${shown} ms (GET /move answered at ${answered} ms); station_move plan ${plan} ms (a turn alone ${turn} ms); main thread: ${holds(from)}`);
    };
    /// While a whole station's move runs, A's move page as a person watching holds it (one subscription, `watching`
    /// below): at its end, from the device's record (each request with when it was answered and how long it took), how
    /// often that page was read, and how long each read took. The drill adds no read of its own: drill 27's
    /// timed reads, each a page of another size, stayed live a minute each (the core's grace) and were read again at
    /// every telling, 35 of the 36 reads a second.
    /// Each station's processes (its Node, its MoonBit programs, whatever runs on its data directory) as `ps` sees them:
    /// pid, %CPU, RSS (MB) and what it is, by station.
    const procs = () => {
      const lines = spawnSync("ps", ["-axww", "-o", "pid=,%cpu=,rss=,args="], { encoding: "utf8" }).stdout.split("\n");
      return (["A", "B"] as Name[]).map((n) => `${n}: ${lines.filter((l) => l.includes(`${dirname(DATA[n])}/`) && !/\bps\b/.test(l)).map((l) => {
        const m = /^\s*(\d+)\s+([\d.]+)\s+(\d+)\s+(.*)$/.exec(l);
        if (m === null) return "";
        const what = m[4]!.includes("main.js") ? "node" : (/\/([^/\s]+)(?:\s|$)/.exec(m[4]!.split(" --")[0]!)?.[1] ?? m[4]!.slice(0, 30));
        const flag = /--(sessions|serve|data|builder|replica|front)\b/.exec(m[4]!)?.[1];
        return `${what}${flag ? `:${flag}` : ""} ${m[2]}% ${(Number(m[3]) / 1024).toFixed(0)}MB`;
      }).filter((x) => x !== "").join(", ")}`).join(" | ") + ` | machine: ${spawnSync("ps", ["-axr", "-o", "%cpu=,comm="], { encoding: "utf8" }).stdout.split("\n").slice(0, 5).map((l) => l.trim().replace(/\s+\S*\//, " ")).filter((l) => l !== "").join(", ")}`;
    };
    const duringMove = () => {
      const from = new Date();
      // (the stations' processes sampled every 10 s while the move runs, into the log: which works beside the
      // hand-overs)
      const sampler = setInterval(() => log(`  cpu: ${procs()}`), 10_000);
      return {
        end: async () => {
          clearInterval(sampler);
          const to = new Date();
          // (the record says a line's time of day alone, UTC: put on the day `from` is, and on the next where it is
          // over 12 hours before `from`. Drill 29's move there ran from 23:59:03 to 00:09:41, and the times compared as
          // words read none of its 1,190 reads)
          const midnight = Date.UTC(from.getUTCFullYear(), from.getUTCMonth(), from.getUTCDate());
          const when = (t: string) => {
            const [h, m, s] = t.split(":").map(Number);
            const at = midnight + ((h! * 60 + m!) * 60 + s!) * 1000;
            return at < from.getTime() - 43_200_000 ? at + 86_400_000 : at;
          };
          const rec = readFileSync(join(dir, a.name, "record.log"), "utf8").split("\n")
            .map((l) => /^asked: (\d\d:\d\d:\d\d\.\d{3}) (\S+) GET \/admin\/api\/move\?(\S*) -> answered(?: \S+)? in (\d+) ms/.exec(l))
            // (the page's own path alone, toward B: not the drill's own reads of what is stopped, `to=`, which drill 35
            // counted as three paths more)
            .filter((m): m is RegExpExecArray => m !== null && m[2] === aId.slice(0, 8) && /^to=[0-9a-f]+&/.test(m[3]!) && when(m[1]!) >= from.getTime() && when(m[1]!) <= to.getTime());
          const perSecond = new Map<string, number>();
          for (const m of rec) perSecond.set(m[1].slice(0, 8), (perSecond.get(m[1].slice(0, 8)) ?? 0) + 1);
          const secs = Math.max(1, (to.getTime() - from.getTime()) / 1000);
          const shapes = new Set(rec.map((m) => m[3].replace(/to=[0-9a-f]+/, "")));
          const took = rec.map((m) => Number(m[4])).sort((x, y) => x - y);
          const q = (f: number) => (took.length === 0 ? "-" : `${took[Math.min(took.length - 1, Math.floor(f * took.length))]} ms`);
          return `the watched page read ${rec.length} times (${(rec.length / secs).toFixed(2)} a second, the busiest second ${Math.max(0, ...perSecond.values())}; ${shapes.size} path(s)), each answered in p50 ${q(0.5)}, p90 ${q(0.9)}, max ${took.length === 0 ? "-" : `${took.at(-1)} ms`}`;
        },
      };
    };
    let timer = "";
    if (!wholeOnly) await check("5: 300 chats (40 shown, 260 archived): GET /move timed", async () => {
      timer = await newChat(`timer-${tag}`);
      await seed(40, 260);
      await timeMove("300 chats", timer);
    });
    await check(`5: a real station's shape, ${many} chats (${manyShown} shown, ${many - manyShown} archived): GET /move timed, all of it moved with \`all\` and back, timed`, async () => {
      if (timer === "") timer = await newChat(`timer-${tag}`);
      await seed(manyShown, many - manyShown);
      await timeMove(`${many} chats`, timer);
      // (E2E_MOVE_TIMING_ONLY: the pages and the plan timed, the whole moved neither way: a timing run of its own)
      if (process.env.E2E_MOVE_TIMING_ONLY === "1") return log("  (timing only: the 2,384 chats not moved)");
      const n = sql("A", "select count(*) n from sessions where (ws is null or (ws not like 'handed:%' and ws not like 'coming:%'))")[0].n as number;
      let from = offsets();
      // (a person watching A's move page through both moves, as the app holds it: one subscription of the page)
      const watching = a.watch(moveT(bId));
      const t0 = Date.now();
      await a.call("move.start", { station: A, to: bId, all: true });
      const there = duringMove();
      const l = await turnEnds("A", t0, 3_600_000);
      measured(`${many} chats there, during the move: ${await there.end()}`);
      const seenS = (Date.now() - t0) / 1000;
      // (what is measured is the station's: its turn's end as it wrote it)
      const s = typeof l?.at === "number" ? (l.at - t0) / 1000 : seenS;
      const left = sql("A", "select count(*) n from sessions where (ws is null or (ws not like 'handed:%' and ws not like 'coming:%'))")[0].n as number;
      // (the turn's end as the station wrote it, `last.at`, beside when this wait saw it: drill 22's way back was seen
      // 600 s after its last chat with nothing in either station's log between; what was left or failed, whole)
      const ends = (x: J, t: number, seen: number) => `the station's turn ended at ${typeof x?.at === "number" ? ((x.at - t) / 1000).toFixed(1) : "?"} s, seen at ${seen.toFixed(1)} s`;
      const notDone = (x: J) => `refused [${(x?.refused ?? []).map((r: J) => `${named(r.item)}: ${r.why}`).join(" | ")}] failed ${failuresOf(x).map((f) => `${f.item}: ${f.error}`).join(" | ") || "none"}`;
      measured(`${n} chats moved with all: ${s.toFixed(0)} s, ${((n - left) / (s / 60)).toFixed(0)} chats a minute, ${left} left on A; ${ends(l, t0, seenS)}; main thread: ${holds(from)}; ${notDone(l)}`);
      // (each chat's hand-over by its steps, A's records as the drill saw them change: which step a chat's time is in)
      for (const line of steps.A!.tenths(t0, Date.now())) log(`  there: ${line}`);
      for (const line of recordTenths("A", "B", t0, Date.now())) log(`  there, own times: ${line}`);
      from = offsets();
      const t1 = Date.now();
      await a.call("move.back", { station: A, from: bId, all: true });
      const back = duringMove();
      const lb = await turnEnds("A", t1, 3_600_000);
      measured(`${many} chats back, during the move: ${await back.end()}`);
      log(`  the watched page took ${watching.values.length} values through both moves`);
      watching.stop();
      const seenB = (Date.now() - t1) / 1000;
      const sb = typeof lb?.at === "number" ? (lb.at - t1) / 1000 : seenB;
      measured(`and back: ${sb.toFixed(0)} s, ${(n / (sb / 60)).toFixed(0)} chats a minute; ${ends(lb, t1, seenB)}; main thread: ${holds(from)}; ${notDone(lb)}`);
      for (const line of steps.B!.tenths(t1, Date.now())) log(`  back: ${line}`);
      for (const line of recordTenths("B", "A", t1, Date.now())) log(`  back, own times: ${line}`);
      if (left > 0) throw new Error(`${left} chats not moved`);
    });
  }

  // ── 7: one station's asks of another while the other's process changes (for why asks went unanswered after it did:
  // drill 9 and 10's 3b and 3c). The asker asks once a second by the product's own way, a person's move back of an
  // item that is not there (POST /move/back): before anything it asks the other `move.open` (move/station.ts refusal),
  // so each answer, 202 or a refusal, is as late as that ask; each timed. None may take over 2 s, answered or refused;
  // once the other is ready, asks are answered again within 5 s ──
  if (part("7") && (limit("7", 900), await clean("7"))) {
    type Ask = { at: number; ms: number; said: string; reached: boolean };
    const unreached = /连不上|没有应答|unreachable|out of reach|not reached|timed out|connection lost|answered nothing|did not answer|does not answer/i;
    /// Station `asker` (an address) asking station `other` (an id) once a second until `stop`.
    /// The end of station `n`'s turn asked at `since` (its move/last.json once move/turn.json is gone).
    // (on its directory's file events and every second besides, as turnEnds: part 7 of 57db57fe3's run saw both
    // stations' turns of one moment only at its 35 s deadline, no file event told for them)
    const turnEndOn = (n: Name, since: number, ms: number) => whenChanged([DATA[n]], () => {
      const l = lastOn(n, ws);
      return l !== null && l.at >= since && !existsSync(`${DATA[n]}/move/turn.json`) && l;
    }, ms, () => `${n}'s turn asked at ${since} not ended`, 1000);
    /// Station `askerN` asking station `otherN` once a second until `stop`: each ask its POST and, where it was taken,
    /// the turn it began (its plan asks the other too), to its end, so that no ask overlaps the one before (drill 12's
    /// asks after the first were all "a move is under way here", answered by B alone).
    const asking = (askerN: Name, otherN: Name) => {
      const asker = addr(askerN);
      const other = idOf(otherN);
      const asks: Ask[] = [];
      let on = true;
      // (what waits on the asks: looked at again as an ask begins and as one ends)
      const waiting = new Set<() => void>();
      const told = () => { for (const f of [...waiting]) f(); };
      let begun = 0;
      const done = (async () => {
        while (on) {
          const t = Date.now();
          begun = t;
          told();
          // (how long an ask took is the station's own: its turn's end as it wrote it, `last.at`, where it began one)
          let end = 0;
          let said = (await within(a.call("move.back", { station: asker, from: other, module: "chats", item: "chat:c-drill-not-there" }).then(() => "202", (e) => String(e).replace(/^Error: [A-Z]+ move\.back: /, "").slice(0, 200)), 35_000)) ?? "no answer in 35 s";
          if (said === "202") said = await turnEndOn(askerN, t, 35_000).then((l) => ((end = typeof l?.at === "number" ? l.at : 0), `202, its turn: ${outcome(l)}`), () => "202, its turn not ended in 35 s");
          asks.push({ at: t, ms: (end || Date.now()) - t, said, reached: !unreached.test(said) && !/no answer|not ended|under way|进行|没有应答/.test(said) });
          told();
          const wait = 1000 - (Date.now() - t);
          if (wait > 0) await new Promise((r) => setTimeout(r, wait));
        }
      })();
      /// Once `ok` holds, looked at as each ask begins and ends; failed past `ms` (a deadline), saying `what`.
      const until = (ok: () => boolean, what: string, ms = 120_000): Promise<void> => new Promise((resolve, reject) => {
        const look = () => {
          if (!ok()) return;
          waiting.delete(look);
          over();
          resolve();
        };
        const over = deadline(ms, () => {
          waiting.delete(look);
          reject(new Error(`${askerN} asking ${otherN}: ${what}, not by ${ms / 1000} s`));
        });
        waiting.add(look);
        look();
      });
      return {
        asks,
        stop: async () => { on = false; await done; },
        /// `n` more asks answered (or refused) from now
        answered: (n: number) => { const from = asks.length; return until(() => asks.length >= from + n, `${n} more asks answered`); },
        /// an ask begun at `t` or after
        begunFrom: (t: number) => until(() => begun >= t, "an ask begun"),
        /// an ask begun at `t` or after answered (or refused)
        answeredFrom: (t: number, ms?: number) => until(() => asks.some((x) => x.at >= t), "an ask begun then answered", ms),
      };
    };
    const iso = (t: number) => new Date(t).toISOString();
    /// Both stations' log lines from `from` to `to` (their launchers' logs, each line's own time).
    const logsBetween = (from: number, to: number): string => {
      const out: string[] = [];
      for (const [n, files] of [["A", ["station.before.log", "station.log"]], ["B", ["second.before.log", "second.log"]]] as const) {
        for (const f of files) {
          const path = `${RUN}/${f}`;
          if (!existsSync(path)) continue;
          for (const l of readFileSync(path, "utf8").split("\n")) {
            const t = Date.parse(l.slice(0, 24));
            if (Number.isFinite(t) && t >= from && t <= to) out.push(`${n}| ${l.slice(0, 300)}`);
          }
        }
      }
      return out.join("\n");
    };
    const said = (asks: Ask[], t0: number) => asks.map((x) => `+${((x.at - t0) / 1000).toFixed(1)}s ${x.ms}ms ${x.reached ? "" : "UNREACHED "}${x.said.slice(0, 80)}`).join("; ");
    /// What of `asks` is not as held (slow, or not reached once it should be), each with both logs from its second.
    const judge = (asks: Ask[], t0: number, reachedFrom: number | null, upAt: number | null): void => {
      const slow = asks.filter((x) => x.ms > 2000);
      const late = reachedFrom === null ? [] : asks.filter((x) => x.at >= reachedFrom && !x.reached);
      const firstBack = upAt === null ? null : asks.find((x) => x.at >= upAt && x.reached);
      const back = upAt === null ? null : firstBack === undefined ? "never" : `${((firstBack.at + firstBack.ms - upAt) / 1000).toFixed(1)} s`;
      log(`  ${asks.length} asks: ${said(asks, t0).slice(0, 3000)}${back !== null ? `; answered again ${back} after A was ready` : ""}`);
      for (const x of [...slow, ...late].slice(0, 4)) log(`  the ask at ${iso(x.at)} (${x.ms} ms: ${x.said.slice(0, 120)}), both logs:\n${logsBetween(x.at - 1000, x.at + x.ms + 1000) || "  (nothing)"}`);
      const why: string[] = [];
      if (slow.length > 0) why.push(`${slow.length} took over 2 s (longest ${Math.max(...slow.map((x) => x.ms))} ms)`);
      if (late.length > 0) why.push(`${late.length} not reached when they should be`);
      if (upAt !== null && (firstBack === undefined || firstBack.at + firstBack.ms - upAt > 5000)) why.push(`answered again ${back} after A was ready, not within 5 s`);
      if (why.length > 0) throw new Error(why.join("; "));
    };

    // 7h: A handed over n times in a row (E2E_MOVE_HANDOVERS, 10 where unset) while B asks it, each ask placed against A's
    // handover windows in its launcher's log, from "handing over from Node" to "has taken over". B asks as the launcher
    // says it is handing over (that line watched as a file), two asks a handover, each the one before's end: an ask in
    // the window every time. E2E_MOVE_HANDOVER_ASK=each: B asks each second instead, each handover at its own phase of
    // that second (a measure: about one window in ten had an ask). With E2E_MOVE_HANDOVERS set, 7h alone runs.
    // (the lead, 2026-11-16: asked at a handover's first milliseconds, B said 「现在连不上」 on main as on the branch,
    // 8 of 9 and 10 of 12 such asks: every one is to be answered, the next Node's, not refused)
    const handovers = Number(process.env.E2E_MOVE_HANDOVERS ?? 0);
    const n7h = handovers > 0 ? handovers : 10;
    const askAt = process.env.E2E_MOVE_HANDOVER_ASK !== "each";
    const check7h = () => check(`7h: A handed over ${n7h} times while B asks it ${askAt ? "as each handover begins" : "each second"}: every ask in a handover window answered`, async () => {
      const t0 = Date.now();
      const asks: Ask[] = [];
      if (askAt) {
        const file = `${RUN}/${SHELL_NAME.A}.log`;
        for (let i = 1; i <= n7h; i++) {
          const from = statSync(file).size;
          const line = () => /^(\S+)[^\n]*handing over from Node [0-9]+ to Node/m.exec(since(file, from));
          let seen = () => {};
          const handing = new Promise<void>((resolve) => { seen = () => { if (line() !== null) resolve(); }; });
          // (its file's events, and its size looked at every 2 ms besides: told by the file's events alone, 11 of 20
          // asks began over 125 ms after the line, past the window, ho-7h-5)
          const w = watch(file, () => seen());
          watchFile(file, { interval: 2 }, () => seen());
          try {
            const h = await handOver("A");
            // (looked at once as well, the line perhaps written already as the handover's start was seen)
            seen();
            const ended = handoverEnd(h);
            const first = await Promise.race([handing.then(() => true), ended.then(() => false)]);
            w.close();
            unwatchFile(file);
            let late = "";
            if (first) {
              const b = asking("B", "A");
              await b.answered(2);
              await b.stop();
              asks.push(...b.asks);
              const said = Date.parse(line()?.[1] ?? "");
              late = Number.isFinite(said) ? `; asked ${b.asks[0]!.at - said} ms after the line's own time` : "";
            }
            const end = await ended;
            log(`  ${i}/${n7h}: ${end}${first ? late : " (its handing over not seen first: not asked)"}`);
            if (!/has taken over/.test(end)) throw new Error(`not handed over at ${i}: ${end}`);
          } finally {
            w.close();
            unwatchFile(file);
          }
        }
      } else {
        const b = asking("B", "A");
        await b.answered(3);
        try {
          // (each handover sent at its own phase of the asks' second, swept across it: sent as an ask ended, every
          // window fell between two asks, 0 of 250 in one, main's first run of it)
          const phased = (ms: number) => new Promise((r) => setTimeout(r, ms)); // det-ok(script-wait): the handovers' phase against the asks' second, swept across it, not a wait for an event
          for (let i = 1; i <= n7h; i++) {
            await b.begunFrom(Date.now() + 1);
            await phased(Math.round(((i - 1) * 1000) / n7h));
            const end = await handoverEnd(await handOver("A"));
            log(`  ${i}/${n7h}: ${end}`);
            if (!/has taken over/.test(end)) throw new Error(`not handed over at ${i}: ${end}`);
            await b.answered(3);
          }
        } finally {
          await b.stop();
        }
        asks.push(...b.asks);
      }
      // (A's launcher's lines with their own times: each window's start and end, in order)
      const lines = ["station.before.log", "station.log"].map((f) => `${RUN}/${f}`).filter(existsSync).flatMap((p) => readFileSync(p, "utf8").split("\n"));
      const at = (l: string) => Date.parse(l.slice(0, 24));
      const windows: { from: number; to: number }[] = [];
      let open: number | null = null;
      for (const l of lines) {
        const t = at(l);
        if (!Number.isFinite(t) || t < t0) continue;
        if (/handing over from Node [0-9]+ to Node [0-9]+/.test(l)) open = t;
        else if (/Node [0-9]+ has taken over/.test(l) && open !== null) { windows.push({ from: open, to: t }); open = null; }
      }
      const inWindow = (x: Ask) => windows.find((w) => x.at <= w.to && x.at + x.ms >= w.from);
      const landed = asks.filter((x) => inWindow(x) !== undefined);
      const refused = landed.filter((x) => !x.reached);
      const outside = asks.filter((x) => inWindow(x) === undefined && !x.reached);
      const spans = windows.map((w) => w.to - w.from).sort((p, q) => p - q);
      measured(`7h: ${windows.length} handover windows (ms: min ${spans[0] ?? "-"}, median ${spans[Math.floor(spans.length / 2)] ?? "-"}, max ${spans[spans.length - 1] ?? "-"}); ${asks.length} asks, ${landed.length} in a window, ${refused.length} of those not reached; ${outside.length} not reached outside any window`);
      for (const x of landed) {
        const w = inWindow(x)!;
        log(`  in a window: ask ${iso(x.at)} ${x.ms} ms (window ${iso(w.from)} to ${iso(w.to)}, the ask ${x.at - w.from} ms after its start): ${x.reached ? "" : "UNREACHED "}${x.said.slice(0, 140)}`);
      }
      for (const x of [...refused, ...outside].slice(0, 3)) log(`  the ask at ${iso(x.at)} (${x.ms} ms: ${x.said.slice(0, 120)}), both logs:\n${logsBetween(x.at - 1000, x.at + x.ms + 1000) || "  (nothing)"}`);
      if (refused.length + outside.length > 0) throw new Error(`${refused.length} of ${landed.length} asks in a handover window not reached; ${outside.length} outside`);
      // (asked as each handover began, none in its window is the drill's own failing, said as such: it held nothing)
      if (askAt && landed.length === 0) throw new Error(`no ask of ${asks.length} began inside a handover window: the drill asked too late, nothing held`);
    });
    if (handovers > 0) await check7h();
    if (handovers === 0) await check("7a: A handed over to a new process as an update does (SIGUSR2 to its launcher) while B asks it each second: no ask over 2 s, every one answered", async () => {
      const t0 = Date.now();
      const b = asking("B", "A");
      await b.answered(3);
      try {
        const end = await handoverEnd(await handOver("A"));
        log(`  ${end}`);
        if (!/has taken over/.test(end)) throw new Error(`not handed over: ${end}`);
      } catch (e) {
        await b.stop();
        throw e;
      }
      log("  waiting for 10 more asks answered");
      await b.answered(10);
      await b.stop();
      judge(b.asks, t0, t0, null);
    });
    /// B asking A across A's whole station stopped and started again: held down until alice's device sees it down and B
    /// has `held` of it (an ask begun in the stop: one answered as A is back; or that ask answered while A is still down:
    /// what one gets), the asks, and when A was ready.
    const acrossStop = async (held: "begun" | "answered") => {
      const t0 = Date.now();
      const b = asking("B", "A");
      await b.answered(3);
      let downAt = 0;
      let upAt = 0;
      try {
        stationDo("halt", "station");
        downAt = Date.now();
        log(`  A stopped (launcher, front and Node), till alice's device sees it down and an ask of B's begun in the stop is ${held}`);
        await a.stationState(ws, (s) => s.state !== "online", 120_000, aId);
        log("  alice's device sees A down");
        await (held === "begun" ? b.begunFrom(downAt) : b.answeredFrom(downAt, 300_000));
      } finally {
        stationDo("again", "station");
        upAt = Date.now();
        log("  A ready again (its new Node took over); 15 more asks answered");
        await b.answered(15).finally(() => b.stop());
      }
      log(`  A down from +${((downAt - t0) / 1000).toFixed(1)}s, ready at +${((upAt - t0) / 1000).toFixed(1)}s; ${b.asks.length} asks: ${said(b.asks, t0).slice(0, 3000)}`);
      return { asks: b.asks, t0, downAt, upAt };
    };
    // (the lead, 2026-11-14: an ask held while A is down and answered once it is back is answered, not failed; what is
    // held is that each is answered or refused in words, none by a timeout, by 5 s after A is ready)
    if (handovers === 0) await check("7b: A's whole station stopped while B asks it, started again once alice's device sees it down and an ask of B's is held in the stop: every ask answered or refused in words, none timed out, each by 5 s after A is ready", async () => {
      const { asks, upAt } = await acrossStop("begun");
      // (a station that did not answer, in its words in either language: station.move.noAnswer and .gone, 「…没有应答…」)
      const timedOut = asks.filter((x) => /timed out|no answer in|not ended|answered nothing|没有应答|did not answer|does not answer/.test(x.said));
      const late = asks.filter((x) => x.at + x.ms > upAt && x.at + x.ms > Math.max(upAt + 5000, x.at + 2000));
      for (const x of [...timedOut, ...late].slice(0, 4)) log(`  the ask at ${iso(x.at)} (${x.ms} ms: ${x.said.slice(0, 120)}), both logs:\n${logsBetween(x.at - 1000, x.at + x.ms + 1000) || "  (nothing)"}`);
      const why: string[] = [];
      if (timedOut.length > 0) why.push(`${timedOut.length} timed out: ${timedOut.map((x) => `${iso(x.at)} ${x.ms} ms`).join(", ")}`);
      if (late.length > 0) why.push(`${late.length} not answered by 5 s after A was ready: ${late.map((x) => `${iso(x.at)} ended ${((x.at + x.ms - upAt) / 1000).toFixed(1)} s after`).join(", ")}`);
      if (why.length > 0) throw new Error(why.join("; "));
    });
    if (handovers === 0) await check("7b: A stopped while B asks it till an ask begun in the stop has its answer: what that ask gets, and when (measured, no bound yet)", async () => {
      const { asks, downAt, upAt } = await acrossStop("answered");
      for (const x of asks.filter((x) => x.at >= downAt && x.at < upAt)) measured(`7b long stop: an ask begun ${((x.at - downAt) / 1000).toFixed(1)} s into it got after ${(x.ms / 1000).toFixed(1)} s (${((x.at + x.ms - upAt) / 1000).toFixed(1)} s from A ready): ${x.said.slice(0, 160)}`);
    });
    if (handovers === 0) await check("7c: A's new process dies at start beside the serving one (not handed over; going on as before), then B asks A and A asks B: no ask over 2 s, every one answered", async () => {
      log("  waiting for A online on alice's device's link (7b stopped it)");
      await a.stationState(ws, (s) => s.state === "online", 120_000, aId);
      // (the next Node made to die by the harness alone: A's app/station, a link to the station's build, pointed for that
      // one start at a main.js that exits 1, then put back)
      const link = `${ST}/app/station`;
      const target = execFileSync("readlink", [link], { encoding: "utf8" }).trim();
      const broken = `${WORK}/broken-station`;
      mkdirSync(broken, { recursive: true });
      writeFileSync(join(broken, "main.js"), "process.exit(1);\n");
      const failed = `${DATA.A}/run/handoff-failed`;
      rmSync(failed, { force: true });
      try {
        rmSync(link);
        execFileSync("ln", ["-s", broken, link]);
        log("  A's next Node broken (app/station pointed at a main.js that exits 1)");
        const end = await handoverEnd(await handOver("A"));
        log(`  ${end}; handoff-failed: ${existsSync(failed) ? readFileSync(failed, "utf8").trim() : "none"}`);
        if (!/not handed over/.test(end)) throw new Error(`the broken Node did not fail its handover: ${end}`);
      } finally {
        rmSync(link, { force: true });
        execFileSync("ln", ["-s", target, link]);
      }
      const t0 = Date.now();
      const b = asking("B", "A");
      const ab = asking("A", "B");
      log("  15 asks answered each way");
      await Promise.all([b.answered(15), ab.answered(15)]);
      await Promise.all([b.stop(), ab.stop()]);
      const errs: string[] = [];
      try {
        log("  B asking A:");
        judge(b.asks, t0, t0, null);
      } catch (e) {
        errs.push(`B asking A: ${(e as Error).message}`);
      }
      try {
        log("  A asking B:");
        judge(ab.asks, t0, t0, null);
      } catch (e) {
        errs.push(`A asking B: ${(e as Error).message}`);
      }
      if (errs.length > 0) throw new Error(errs.join(" | "));
    });
    if (handovers === 0) await check7h();
  }
  if (part("8") && (limit("8", 1200), await clean("8"))) {
    // A device away while a chat moves A→B, A down as it comes back: only B's list read can tell it the chat came from
    // A (its session's `from`, account.ts `#came`). Both ways a device is without a place in B's stream that B can go on
    // from: it was never told anything by B (a phone off since before B was enrolled or anything moved there), or it
    // was and B's log of events has moved past it (B keeps so many, events.ts): there its place, its database's `heard`
    // of B, is taken out by hand while it is closed, as move-stale.ts does to a station's store. Else B's stream,
    // resumed, tells it again what it missed, Node's events with their `from`, and the list read is never the one asked.
    const { DatabaseSync } = await import("node:sqlite");
    /// The device's account databases (hosts/node.ts `dbPath`: `databases/<name>.db` in its core's data), each with the
    /// rows of its workspace's records keyed `key`: what it keeps of B's stream.
    const heardIn = (name: string, key: string, drop: boolean): string[] => {
      const at = join(dir, name, "core", "databases");
      if (!existsSync(at)) return [`no ${at}`];
      return readdirSync(at).filter((f) => f.endsWith(".db")).map((f) => {
        const db = new DatabaseSync(join(at, f));
        try {
          const has = db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'workspace_pref'").get();
          if (!has) return `${f}: no workspace_pref`;
          const n = Number((db.prepare("SELECT count(*) n FROM workspace_pref WHERE key = ?").get(key) as { n: number }).n);
          if (drop && n > 0) db.prepare("DELETE FROM workspace_pref WHERE key = ?").run(key);
          return `${f}: ${n}${drop && n > 0 ? " taken out" : ""}`;
        } finally {
          db.close();
        }
      });
    };
    for (const round of [{ id: "8", told: false }, { id: "8r", told: true }]) {
      const d = new Device(`A${round.id}`);
      let k8 = "";
      let away = false;
      let aDown = false;
      /// The device's rows of chat `key` once `ok` holds of them (or an error saying what they were).
      const listedOnD = async (key: string, ok: (rows: J[]) => boolean, what: string, ms = 90_000): Promise<J[]> => {
        log(`  waiting for ${d.name}'s list to show ${key.slice(-8)} ${what}`);
        let seen: J[] = [];
        try {
          return await d.until(chatsT(), (v) => {
            seen = rowsOf(v).filter((r) => r.session === key);
            return v?.days && ok(seen) && seen;
          }, ms);
        } catch {
          throw new Error(`${d.name} lists it as ${brief(seen.map((r) => ({ station: r.station, title: r.title })))}`);
        }
      };
      const how = round.told ? "told by B before it went away, its place in B's log gone" : "never told anything by B";
      try {
        await check(`${round.id}: setup: alice's device ${d.name} (${how}) lists a chat on A, then is closed`, async () => {
          await d.signIn();
          k8 = await newChat(`away-${round.id}-${tag}`);
          await listedOnD(k8, (r) => r.length === 1 && r[0].station === A, "once, on A");
          if (round.told) {
            // (told by B: a chat of its own moved there while it watches, listed there once, so B's stream told it)
            const kw = await newChat(`seen-${round.id}-${tag}`);
            await moveChat(kw, "B");
            await listedOnD(kw, (r) => r.length === 1 && r[0].station === B, "once, on B");
            await home(kw);
          }
          await d.close();
          away = true;
        });
        if (!away) continue;
        await check(`${round.id}: moved to B while ${d.name} is away; then A stopped`, async () => {
          const l = await moveChat(k8, "B");
          if (standing("B", k8) !== "live") throw new Error(`${standings(k8)}; ${outcome(l)}`);
          stationDo("halt", "station");
          aDown = true;
        });
        // (its place in B's stream as it is: a line of the set-up, not a check)
        const kept = heardIn(d.name, `heard:${B}`, round.told);
        log(`  ${d.name}'s place in B's stream (heard:${B.slice(-8)}): ${brief(kept)}${round.told ? "" : " (none to take out: never told)"}`);
        if (!aDown) continue;
        await check(`${round.id}: back with A down, ${d.name} lists the chat once, on B (only B's list read with \`from\` can say it came from A)`, async () => {
          const t0 = Date.now();
          await d.restart();
          try {
            await listedOnD(k8, (r) => r.length === 1 && r[0].station === B, "once, on B", 120_000);
          } finally {
            const asked = d.answers.filter((x) => x.at >= t0).map((x) => `${bId.startsWith(x.station) || x.station.startsWith(bId.slice(0, 8)) ? "B" : x.station.slice(0, 8)} ${x.method} ${x.path.replace(/\?.*$/, "")}`);
            log(`  what ${d.name} read since it came back: ${brief([...new Set(asked)], 900)}`);
          }
        });
      } finally {
        await within(d.close(), 5000).catch(() => {});
        if (aDown) await up("A").catch((e) => log(`  A not up again: ${e.message}`));
        if (k8 !== "") await home(k8).catch((e) => log(`  ${k8.slice(-8)} not brought home: ${e.message}`));
      }
    }
  }

  // ── 9: chats moved one turn each, back to back, while a station is handed to its next process again and again ──
  // (the real run, 2026-11-15 12:20 UTC: a chat on neither station. The sender took an update between two turns; the
  // next call reached the process before, which began a turn and a hand-over; the next process's start failed that
  // hand-over as cut by a restart and had the other drop it, and 6 ms later the process before had its counts and
  // wrote it gone. What is held after each batch, from both stations' own databases and alice's list: every chat in
  // sight on exactly one station, every chat the sender says went in sight where it went, each failed move told in
  // words and moved on a second ask, no ask unanswered longer than a handover takes; and counted, the hand-overs
  // begun on a process with its next one already started, or the part tested nothing.)
  // E2E_MOVE_9_CHATS: chats a batch of 9p (6). 9: one batch of 12 while both stations are handed over again and
  // again; 9p: one handover a batch, of A then of B, begun at each phase of the third chat's turn in turn (before its
  // ask, its first pass, held, its rows, gone, between two turns), tallied: moved at the first ask, failed in words
  // and moved on a second ask, refused (409); 9a: an agent's station_move calls, one at a time, A handed over once in
  // each turn at each phase. 9m: E2E_MOVE_LIMBO_DIST, the build A runs while the limbo is made (main's with the
  // drill's hold, STILLFAIL_DRILL_HOLD), where unset A's own.
  /// Station `n`'s launcher's handovers since `t0`, from its log: when the next Node started beside the one serving,
  /// when it began handing over, when it had taken over.
  const handoverWindows = (n: Name, t0: number) => {
    const lines = [`${SHELL_NAME[n]}.before.log`, `${SHELL_NAME[n]}.log`].map((f) => `${RUN}/${f}`).filter(existsSync).flatMap((p) => readFileSync(p, "utf8").split("\n"));
    const out: { started: number; handing: number | null; taken: number }[] = [];
    let started: number | null = null;
    let handing: number | null = null;
    for (const l of lines) {
      const t = Date.parse(l.slice(0, 24));
      if (!Number.isFinite(t) || t < t0) continue;
      if (/handover: Node [0-9]+ started beside/.test(l)) (started = t), (handing = null);
      else if (/handing over from Node [0-9]+ to Node/.test(l)) handing = t;
      else if (/Node [0-9]+ has taken over/.test(l) && started !== null) {
        out.push({ started, handing, taken: t });
        started = null;
      }
    }
    return out;
  };
  /// Station `n` handed to its next process again and again (SIGUSR2 to its launcher, as an update does), each as the
  /// one before has taken over, until `stop` says so; how long each took, SIGUSR2 to taken over.
  const handingOver = (n: Name, stop: () => boolean) => {
    const took: number[] = [];
    const done = (async () => {
      while (!stop()) {
        const t = Date.now();
        const end = await handoverEnd(await handOver(n));
        if (!/has taken over/.test(end)) throw new Error(`${n} not handed over: ${end}`);
        took.push(Date.now() - t);
      }
    })();
    return { took, done };
  };
  /// `count` new chats on A, put in by the station's own store while A is stopped (e2e/move-seed.ts), A then up and
  /// its link usable: their keys.
  const seedA = async (count: number): Promise<string[]> => {
    const before = new Set(sql("A", "select key from sessions").map((r) => String(r.key)));
    const homeWs = sql("A", "select ws from sessions where ws is not null and ws not like 'handed:%' and ws not like 'coming:%' limit 1")[0]?.ws ?? ws;
    stationDo("halt", "station");
    log(`  ${execFileSync(process.execPath, ["--no-warnings", join(dirname(new URL(import.meta.url).pathname), "move-seed.ts"), process.env.E2E_SF_SRC!, DATA.A, homeWs, String(count), "0", randomBytes(3).toString("hex")], { encoding: "utf8", timeout: 600_000 }).trim()}`);
    stationDo("again", "station");
    const upAt = Date.now();
    await a.stationState(ws, (s) => s.state === "online", 120_000, aId);
    await a.answered(aId, "/", upAt, 120_000, true);
    return sql("A", "select key from sessions where archived_at is null").map((r) => String(r.key)).filter((k) => !before.has(k));
  };
  /// Each of `keys` given a room of E2E_MOVE_9_MB MB (20) in 100 files, so that its hand-over's passes take a second
  /// or so: long enough to be under way as the next process starts (seeded rooms alone went in milliseconds).
  const roomsOf = (keys: string[], mb = Number(process.env.E2E_MOVE_9_MB ?? 20)) => {
    if (mb <= 0) return;
    for (const k of keys) fill(roomOn("A", k)!, "bulk", 100, Math.floor((mb * 1024 * 1024) / 100));
  };
  type Moved = { key: string; at: number; askMs: number; said: string; failed: string | null; refused: boolean };
  /// Where a handover is begun in a chat's turn: before its ask, as its hand-over is at a step (A's out record: its first
  /// pass, held, its rows, gone), or after its turn ended and before the next ask.
  type Phase = "ask" | "files" | "held" | "rows" | "gone" | "between";
  const PHASES: Phase[] = ["ask", "files", "held", "rows", "gone", "between"];
  /// Whether chat `key`'s hand-over asked at `t0` is at `phase` now (as A's out record says it).
  const atPhase = (key: string, t0: number, phase: Phase) => {
    const o = outOn("A", key);
    if (o === null || o.at < t0 - 1000) return false;
    if (phase === "files") return o.step === "files" && o.held !== true;
    if (phase === "held") return o.held === true && o.step === "files";
    if (phase === "rows") return o.step === "rows";
    return o.step === "gone" || o.step === "done";
  };
  /// What each 409 met (a turn under way): when, what GET /move said then, how long until A's turn under way ended.
  const met409: string[] = [];
  /// Chats `keys` moved A→B one turn each, the next asked as the one before ended (the move.start's answer, then the
  /// turn's end on A): what each ask was answered and how long that took, and what its turn said. `at`: one handover
  /// (`fire`) begun at `phase` of the turn of chat `index`; what phase it was begun at is said back (`firedAt`).
  const batchMoves = async (keys: string[], at?: { index: number; phase: Phase; fire: () => Promise<void> }): Promise<Moved[] & { firedAt?: string }> => {
    const out: Moved[] & { firedAt?: string } = [];
    let firing: Promise<void> | null = null;
    for (const [i, key] of keys.entries()) {
      const t0 = Date.now();
      if (at?.index === i && at.phase === "ask") (out.firedAt = "ask"), (firing = at.fire());
      if (at?.index === i && !["ask", "between"].includes(at.phase)) {
        // (looked at every 10 ms besides the out directory's events: a step of a small chat lasts tens of ms)
        firing = whenChanged([`${DATA.A}/replica/handover/out`], () => atPhase(key, t0, at.phase) || (lastOn("A", ws)?.at ?? 0) >= t0 && !existsSync(`${DATA.A}/move/turn.json`), 300_000, () => "", 10)
          .then(() => {
            out.firedAt = atPhase(key, t0, at.phase) ? at.phase : `${at.phase} missed (${outOn("A", key)?.step ?? "no hand-over"} as the turn ended)`;
            return out.firedAt.includes("missed") ? undefined : at.fire();
          });
      }
      let said = "";
      let failed: string | null = null;
      try {
        await a.call("move.start", { station: A, to: bId, module: "chats", item: key, withNeeds: true });
        said = "202";
      } catch (e) {
        said = String((e as Error).message ?? e);
        failed = said;
      }
      const askMs = Date.now() - t0;
      const refused = failed !== null && /http_409/.test(failed);
      if (failed === null) {
        // (the turn's end as A says it; one that names no item of its own (a turn cut by a handover, said ended by the
        // next process) is this ask's failing, in its words)
        const l = await turnEnds("A", t0, 300_000);
        said = outcome(l);
        const named1 = [...(l?.done ?? []), ...(l?.refused ?? []).map((r: J) => r.item)].map((x) => named(x)).concat(failuresOf(l).map((f) => f.item));
        const why = failedWhy(l, `chats ${key}`);
        if (!(l.done ?? []).map(named).includes(`chats ${key}`)) failed = named1.includes(`chats ${key}`) ? why || said : `its turn ended naming nothing of it: ${failedWhy(l) || said}`;
      } else if (refused) {
        // (a turn under way, as one at a time is: what the page says of it now, and how long it holds the one turn's
        // place; the next ask waits for its end, as a person would)
        const t = Date.now();
        const page = await a.until(moveT(bId, "chats", 20), (v) => v?.modules && v, 30_000).catch(() => null);
        const l = await turnEnds("A", t, 300_000).catch(() => null);
        met409.push(`${key.slice(-8)} at ${new Date(t).toISOString()}: GET /move then moving ${brief(page?.moving ?? null, 200)}, last ${brief({ at: page?.last?.at ?? null }, 80)}; the turn under way ended ${l === null ? "never in 300 s" : `${Date.now() - t} ms later: ${outcome(l).slice(0, 200)}`}`);
      }
      out.push({ key, at: t0, askMs, said, failed, refused });
      if (at?.index === i && at.phase === "between") (out.firedAt = "between"), await at.fire();
    }
    if (firing !== null) await firing;
    return out;
  };
  /// Where each of `keys` is in sight, as both stations' databases say, and what alice's list shows once it agrees.
  const sightOf = (keys: string[]) => keys.map((key) => {
    const live = (["A", "B"] as Name[]).filter((n) => standing(n, key) === "live");
    const saysWent = standing("A", key).startsWith("handed");
    return { key, live, saysWent, standings: standings(key) };
  });
  /// What a batch left: chats on none, on both, said gone and not there; and, the stations settled, alice's list.
  const heldAfter = async (label: string, keys: string[]) => {
    // (settled: no hand-over of these chats under way on either side; one still under way after 120 s is said, and
    // what is in sight then is held as it is)
    const underWay = (k: string) => {
      const o = outOn("A", k);
      const coming = handovers("B", "in").some((i) => (i.keys ?? []).includes(k) && i.step === "coming");
      return coming || (o !== null && ["held", "files", "rows"].includes(o.step));
    };
    const settled = await whenChanged([DATA.A, DATA.B], () => !keys.some(underWay) && !existsSync(`${DATA.A}/move/turn.json`), 120_000, () => "", 1000).then(() => true, () => false);
    const stuck = settled ? [] : keys.filter(underWay);
    for (const k of stuck.slice(0, 3)) log(`  ${label}: ${k.slice(-8)} still under way after 120 s: ${standings(k)}; turn ${existsSync(`${DATA.A}/move/turn.json`) ? readFileSync(`${DATA.A}/move/turn.json`, "utf8") : "none"}\n    ${heldOf2(k)}; B's in ${brief(handovers("B", "in").filter((i) => (i.keys ?? []).includes(k)).map((i) => ({ id: i.id, step: i.step, at: i.at, error: i.error })))}`);
    const s = sightOf(keys);
    const none = s.filter((x) => x.live.length === 0);
    const both = s.filter((x) => x.live.length > 1);
    const notThere = s.filter((x) => x.saysWent && !x.live.includes("B"));
    for (const x of [...none, ...both, ...notThere].slice(0, 3)) log(`  ${x.key.slice(-8)}: ${x.standings}\n    ${heldOf2(x.key)}`);
    return { none, both, notThere, stuck };
  };
  /// Of the hand-overs of `keys` since `t0`, how many began (A's out record's `at`) on a process of A with its next one
  /// already started, and how many came to B (B's in record's `at`) while B's was: the turns that met the window.
  const metWindow = (keys: string[], t0: number) => {
    const inside = (t: number, w: { started: number; taken: number }[]) => w.some((x) => t >= x.started && t <= x.taken);
    const aW = handoverWindows("A", t0);
    const bW = handoverWindows("B", t0);
    const outs = keys.flatMap((k) => handovers("A", "out").filter((o) => (o.keys ?? []).includes(k) && o.at >= t0));
    const ins = keys.flatMap((k) => handovers("B", "in").filter((i) => (i.keys ?? []).includes(k) && i.at >= t0));
    return { aW: aW.length, bW: bW.length, onA: outs.filter((o) => inside(o.at, aW)).length, onB: ins.filter((i) => inside(i.at, bW)).length, outs: outs.length };
  };
  /// A's handover (`n`: A, B or both), SIGUSR2 to its launcher until it says it has taken over.
  const handOne = (who: Name[]) => async () => {
    await Promise.all(who.map(async (n) => {
      const end = await handoverEnd(await handOver(n));
      if (!/has taken over/.test(end)) throw new Error(`${n} not handed over: ${end}`);
    }));
  };
  /// What a batch's moves came to: moved at the first ask, failed in words (then moved on a second ask, held below),
  /// refused (409: a turn under way).
  const tally = (moved: Moved[]) => ({ first: moved.filter((m) => m.failed === null).length, failed: moved.filter((m) => m.failed !== null && !m.refused).length, refused: moved.filter((m) => m.refused).length });
  /// The properties after a batch (`moved`, of `keys`, whose handovers took at most `tookMost` ms): reasons it failed.
  const held9 = async (label: string, keys: string[], moved: Moved[], tookMost: number): Promise<string[]> => {
    const why: string[] = [];
    const held = await heldAfter(label, keys);
    if (held.stuck.length > 0) why.push(`${held.stuck.length} hand-over(s) still under way 120 s after the batch: ${held.stuck.map((k) => `${k.slice(-8)} (${standings(k)}, out ${outOn("A", k)?.step})`).join(", ")}`);
    if (held.none.length > 0) why.push(`${held.none.length} chat(s) on neither station: ${held.none.map((x) => `${x.key.slice(-8)} (${x.standings})`).join(", ")}`);
    if (held.both.length > 0) why.push(`${held.both.length} on both: ${held.both.map((x) => x.key.slice(-8)).join(", ")}`);
    if (held.notThere.length > 0) why.push(`${held.notThere.length} said gone by A and not in sight on B: ${held.notThere.map((x) => `${x.key.slice(-8)} (${x.standings})`).join(", ")}`);
    // (an ask is answered within what a handover takes, SIGUSR2 to taken over, and a second's slack for a link dialled anew)
    const late = moved.filter((m) => m.askMs > tookMost + 1000);
    if (late.length > 0) why.push(`${late.length} ask(s) answered past the longest handover (${tookMost} ms): ${late.map((m) => `${m.key.slice(-8)} ${m.askMs} ms: ${m.said.slice(0, 120)}`).join(" | ")}`);
    const failed = moved.filter((m) => m.failed !== null);
    // (in words: a person's sentence, not a code or a stack alone)
    const wordless = failed.filter((m) => !/[一-鿿]|[a-z]{3,} [a-z]{3,}/i.test(m.failed ?? ""));
    if (wordless.length > 0) why.push(`${wordless.length} failed move(s) not told in words: ${wordless.map((m) => m.failed).join(" | ")}`);
    for (const m of failed) log(`  ${m.key.slice(-8)} ${m.refused ? "refused" : "failed"}: ${m.failed?.slice(0, 200)}`);
    // (each failed one still in sight on A alone, moved on a second ask with nothing handed over)
    for (const m of failed.filter((m) => liveOn(m.key).join() === "A")) {
      const l = await moveChat(m.key, "B");
      if (standing("B", m.key) !== "live") why.push(`${m.key.slice(-8)} did not move on a second ask: ${outcome(l)}; ${standings(m.key)}`);
    }
    if (why.length === 0) await a.until(chatsT(), (v) => v?.days && keys.every((k) => { const r = rowsOf(v).filter((x) => x.session === k); return r.length === 1 && r[0].station === B; }), 90_000).catch(() => {
      why.push("alice's list does not show each once on B");
    });
    return why;
  };
  const tallies: string[] = [];
  let met9 = 0;
  if (part("9") && (limit("9", 5400), await clean("9"))) {
    const perBatch = Number(process.env.E2E_MOVE_9_CHATS ?? 6);
    // (one batch at the pace of a station handed over as soon as it took over, both at once: the invariant alone, as
    // nearly every move of it fails, on any build)
    await check(`9: 12 chats moved one turn each, back to back, while both stations are handed over again and again: every chat in sight on one station, each failed move told in words and moved on a second ask, no ask unanswered past a handover`, async () => {
      const keys = await seedA(12);
      roomsOf(keys, 5);
      const t0 = Date.now();
      let stop = false;
      const loops = (["A", "B"] as Name[]).map((n) => ({ n, ...handingOver(n, () => stop) }));
      let moved: Moved[] = [];
      try {
        moved = await batchMoves(keys);
      } finally {
        stop = true;
        await Promise.all(loops.map((l) => l.done));
      }
      const met = metWindow(keys, t0);
      met9 += met.onA + met.onB;
      const t = tally(moved);
      tallies.push(`9 both, again and again: ${t.first} moved at the first ask, ${t.failed} failed in words, ${t.refused} refused`);
      measured(`9 both: ${loops.map((l) => `${l.n} handed over ${l.took.length} times`).join(", ")}; hand-overs begun on A with its next process started ${met.onA} of ${met.outs}, come to B so ${met.onB}; ${t.first} moved at the first ask, ${t.failed} failed in words, ${t.refused} refused`);
      const why = await held9("9 both", keys, moved, Math.max(...loops.flatMap((l) => l.took), 0));
      if (why.length > 0) throw new Error(why.join("; "));
    });
    // (as the real run had it: one handover of the station a batch, begun at a phase of a turn swept batch by batch)
    for (const who of [["A"], ["B"]] as Name[][]) {
      for (const phase of PHASES) {
        const label = `9p ${who.join("+")} at ${phase}`;
        await check(`9p: ${perBatch} chats moved one turn each, back to back, ${who.join(" and ")} handed over once as the third's turn is at ${phase}: every chat in sight on one station, a failed move told in words and moved on a second ask`, async () => {
          const keys = await seedA(perBatch);
          roomsOf(keys, 5);
          const t0 = Date.now();
          let took = 0;
          const fire = handOne(who);
          const moved = await batchMoves(keys, { index: 2, phase, fire: async () => { const t = Date.now(); await fire(); took = Date.now() - t; } });
          const met = metWindow(keys, t0);
          met9 += met.onA + met.onB;
          const t = tally(moved);
          tallies.push(`${label} (begun at ${moved.firedAt ?? "?"}): ${t.first} moved at the first ask, ${t.failed} failed in words, ${t.refused} refused`);
          measured(`${label}: begun at ${moved.firedAt ?? "?"}, handover ${took} ms; ${t.first} moved at the first ask, ${t.failed} failed in words, ${t.refused} refused; begun on A with its next started ${met.onA}, come to B so ${met.onB}`);
          const why = await held9(label, keys, moved, Math.max(took, 1));
          if (why.length > 0) throw new Error(why.join("; "));
        });
      }
    }
    // (an agent driving a batch through the station's own tool, one call at a time, each waiting for its answer, as
    // run_batch.py does; A handed over once in each of its turns, at each phase in turn)
    await check(`9a: an agent moves ${PHASES.length} chats with station_move one at a time while A is handed over once in each turn, at each phase in turn: what each call answered, every chat in sight on one station`, async () => {
      const driver = await newChat(`9a-driver-${tag}`);
      const keys = await seedA(PHASES.length);
      roomsOf(keys, 5);
      const answers: { key: string; said: string }[] = [];
      for (const [i, key] of keys.entries()) {
        const phase = PHASES[i]!;
        const t0 = Date.now();
        const fire = handOne(["A"]);
        let firing: Promise<void> = Promise.resolve();
        if (phase === "ask") firing = fire();
        else if (phase !== "between") firing = whenChanged([`${DATA.A}/replica/handover/out`], () => atPhase(key, t0, phase) || (lastOn("A", ws)?.at ?? 0) >= t0 && !existsSync(`${DATA.A}/move/turn.json`), 300_000, () => "", 10).then(() => atPhase(key, t0, phase) ? fire() : undefined);
        const said = await say(driver, `drill-move:${JSON.stringify({ action: "move", to: bId, module: "chats", item: key, withNeeds: true })}`, "drill-move: ", 300_000).catch((e) => `no answer: ${(e as Error).message}`);
        await firing;
        if (phase === "between") await fire();
        answers.push({ key, said });
        log(`  ${phase}: ${key.slice(-8)} ${said.slice(0, 300)}`);
      }
      const refusedA = answers.filter((x) => /409|已有一次迁移在进行|under way/.test(x.said));
      const unanswered = answers.filter((x) => x.said.startsWith("no answer"));
      tallies.push(`9a agent: ${answers.filter((x) => standing("B", x.key) === "live").length} of ${answers.length} on B after one call each, ${refusedA.length} answered as a move under way`);
      const status = await say(driver, `drill-move:${JSON.stringify({ action: "status", to: bId })}`, "drill-move: ", 300_000).catch((e) => `no answer: ${(e as Error).message}`);
      log(`  station_move status after: ${status.slice(0, 400)}`);
      const moved: Moved[] = answers.map((x) => ({ key: x.key, at: 0, askMs: 0, said: x.said, failed: standing("B", x.key) === "live" ? null : x.said, refused: refusedA.includes(x) }));
      const why = await held9("9a", keys, moved, Number.MAX_SAFE_INTEGER);
      if (unanswered.length > 0) why.push(`${unanswered.length} call(s) never answered in 300 s: ${unanswered.map((x) => `${x.key.slice(-8)}: ${x.said.slice(0, 120)}`).join(" | ")}`);
      if (refusedA.length > 0) why.push(`${refusedA.length} call(s) answered as a move under way: ${refusedA.map((x) => `${x.key.slice(-8)}: ${x.said.slice(0, 160)}`).join(" | ")}`);
      if (why.length > 0) throw new Error(why.join("; "));
    });
    await check("9: the batches met the window: hand-overs begun on a process whose next one had started (or come to one so)", async () => {
      for (const t of tallies) log(`  ${t}`);
      for (const m of met409) log(`  409: ${m}`);
      if (met9 === 0) throw new Error("no hand-over of any batch began on a process with its next one started: the part tested nothing");
      log(`  ${met9} in all`);
    });
  }

  // ── 9m: the real run's limbo (A says its chat went, its hand-over failed and never shown, B dropped it), made on the
  // build before the fix by its own steps, held at the hand-over's own test hook; then A's own build started on that
  // data: the chat in sight on A again, once, nothing of it on B, and it moves as any. It needs a build of main with
  // the drill's hold (e2e/move-drill-hold.patch, applied to a copy of the tree, never the product; its header says
  // how): E2E_MOVE_LIMBO_DIST, that copy's station/dist, and E2E_DRILL_HOLD=counts:<path>; without them it is skipped ──
  const limboGiven = process.env.E2E_MOVE_LIMBO_DIST !== undefined && /^counts:/.test(process.env.E2E_DRILL_HOLD ?? "");
  if (part("9m") && !limboGiven) log("SKIP 9m: the limbo needs a build of main with the drill's hold, not built: apply e2e/move-drill-hold.patch to a copy of main from before the fix, build its station, and give E2E_MOVE_LIMBO_DIST=<copy>/station/dist and E2E_DRILL_HOLD=counts:<path>");
  if (part("9m") && limboGiven && (limit("9m", 1800), await clean("9m"))) {
    const link = `${ST}/app/station`;
    const own = execFileSync("readlink", [link], { encoding: "utf8" }).trim();
    const limboDist = process.env.E2E_MOVE_LIMBO_DIST ?? own;
    const holdAt = process.env.STILLFAIL_DRILL_HOLD ?? process.env.E2E_DRILL_HOLD ?? "";
    const hold = holdAt.split(":")[1] ?? "";
    /// A's next process run from `dist` (its app/station pointed there, then a handover).
    const runA = async (dist: string) => {
      rmSync(link, { force: true });
      execFileSync("ln", ["-s", dist, link]);
      const end = await handoverEnd(await handOver("A"));
      if (!/has taken over/.test(end)) throw new Error(`A not handed over to ${dist}: ${end}`);
      log(`  A runs ${dist}`);
    };
    let key = "";
    await check(`9m: the limbo made on ${limboDist === own ? "A's own build" : limboDist}: a chat's hand-over held after its counts, A handed to its next process (which fails it and has B drop it), then let go (it writes gone)`, async () => {
      key = (await seedA(1))[0]!;
      // (A handed to a process of the limbo's build in any case: on main's tree a process the harness started itself
      // never took the hold, nine-5 and nine-7, one the launcher started for a handover did)
      await runA(limboDist);
      roomsOf([key], 1);
      rmSync(`${hold}.held`, { force: true });
      rmSync(`${hold}.go`, { force: true });
      writeFileSync(`${hold}.arm`, "");
      const t0 = Date.now();
      await a.call("move.start", { station: A, to: bId, module: "chats", item: key, withNeeds: true });
      await whenChanged([dirname(hold)], () => existsSync(`${hold}.held`), 120_000, () => `the hand-over never came to its hold: ${brief(outOn("A", key))}`, 100);
      log(`  held after its counts in ${readFileSync(`${hold}.held`, "utf8")}: ${brief(outOn("A", key))}`);
      const h = await handOver("A");
      // (the next process's start fails it, as at 12:20:13.294; the process before let go at once, so that it writes gone
      // while the drop it asked of B is on its way, as 6 ms later there)
      await whenChanged([DATA.A], () => outOn("A", key)?.step === "failed", 120_000, () => `the next process did not fail it: A ${brief(outOn("A", key))}`, 5);
      writeFileSync(`${hold}.go`, "");
      log(`  the next process failed it; the process before let go: ${brief(outOn("A", key))}`);
      await whenChanged([DATA.B], () => handovers("B", "in").some((i) => (i.keys ?? []).includes(key) && i.step === "dropped"), 120_000, () => `B did not drop it: ${brief(handovers("B", "in").filter((i) => (i.keys ?? []).includes(key)))}`, 100);
      const end = await handoverEnd(h);
      log(`  ${end}`);
      await turnEnds("A", t0, 120_000).catch(() => undefined);
      // (gone as the process before wrote it: A's handed_over naming B, store.goneTo, the row's ws as that leaves it)
      const said = () => sql("A", `select station from handed_over where session = ${lit(key)}`).some((r) => String(r.station) === bId);
      await whenChanged([DATA.A], said, 60_000, () => `the process before never wrote it gone: ${standings(key)}`, 200);
      log(`  the limbo: ${standings(key)}\n    ${heldOf2(key)}`);
      if (standing("B", key) !== "none") throw new Error(`not the limbo: B has it, ${standings(key)}`);
      // (out of A's lists as it says it went: alice's list shows it on neither)
      let seen: J[] = [];
      await a.until(chatsT(), (v) => { seen = rowsOf(v).filter((r) => r.session === key); return v?.days && seen.length === 0; }, 60_000).then(() => log("  alice's list shows it on neither station"), () => log(`  alice's list still shows it: ${brief(seen.map((r) => ({ station: r.station, title: r.title })))}`));
    });
    if (key !== "" && standing("B", key) === "none" && sql("A", `select station from handed_over where session = ${lit(key)}`).length > 0) {
      await check("9m: A's own build started on it: the chat in sight on A again, once, nothing of it on B; it then moves to B as any", async () => {
        await runA(own);
        await whenChanged([DATA.A], () => standing("A", key) === "live" && sql("A", `select station from handed_over where session = ${lit(key)}`).length === 0, 120_000, () => `still not in sight on A: ${standings(key)}\n    ${heldOf2(key)}`, 1000);
        if (standing("B", key) !== "none") throw new Error(`B holds it: ${standings(key)}`);
        await listedOnceOn(key, "A");
        const l = await moveChat(key, "B");
        if (standing("B", key) !== "live") throw new Error(`it did not move: ${outcome(l)}; ${standings(key)}`);
        await listedOnceOn(key, "B");
      });
    } else await runA(own).catch((e) => log(`  A not back on its own build: ${e.message}`));
  }
} catch (e) {
  fail("the run", e);
}
partOver();
steps.A?.close();
steps.B?.close();
for (const r of report) log(`MEASURED ${r}`);
log(failures() === 0 ? "ALL PASSED" : `${failures()} FAILED`);
await within(Promise.all([a.close(), bob.close()]), 5000);
process.exit(failures() === 0 ? 0 : 1);
