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
//   4 everything (all) to B and all back;
//   5 measured, printed: a 500 MB / 5,000-file room's first pass and pause, 300 chats moved with all, GET /move (the
//     `stationMove` topic's first answer, and station_move plan) with 300 and 2,400 chats.
//   6 a chat moved to a B that still holds a retired copy of it (its row `retired:`, entries only B has, an older room
//     and transcript: e2e/move-stale.ts) and back: listed once, every entry once in order, the room exact, its context.
//   6b a chat whose key is live on both: shown as one that cannot move, a move refused, B untouched;
//   7 one station asking another each second while the other is handed to a new process, stopped and started, and
//     handed to one that dies at start: each ask answered or refused within 2 s, answered again within 5 s of it ready;
//   8 a device away while a chat moves A→B, A down as it comes back, with no place in B's stream B can go on from (8:
//     never told by B; 8r: told, its place taken out as B's log moving past it would): it lists the chat once, on B,
//     which only B's list read can tell it (its session's `from`).
// Each check says PASS or FAIL with what was seen; a failed one does not stop the next where that can go on alone.
// E2E_SF_SRC, E2E_ORIGIN, E2E_PEER_DATA as peer.ts; E2E_WORK, E2E_STATION as e2e-local.sh's. E2E_MOVE_ONLY: the
// parts to run (e.g. "1 2 3a 5"; all of them where unset).
import { execFileSync, spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, rmSync, statSync, statfsSync, unlinkSync, watch, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { check as checked, deadline, Device, dir, fail, failures, heldProbe, type J, log, whenChanged, within } from "./device.ts";

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
  const pids = spawnSync("ps", ["-axo", "pid=,args="], { encoding: "utf8" }).stdout.split("\n").map((l) => mine.exec(l)?.[1]).filter((x): x is string => x !== undefined).map(Number);
  return pids.map((pid) => {
    const l = spawnSync("lsof", ["-nP", "-a", "-p", String(pid), "-d", "cwd", "-Fn"], { encoding: "utf8" }).stdout;
    const cwd = /^n(.*)$/m.exec(l)?.[1] ?? "";
    return { pid, cwd, on: at(cwd) };
  });
}
/// What there is of job `tag` to say where it is not as wanted: every process naming it, and its logs' last lines.
function jobEvidence(tag: string): string {
  const ps = spawnSync("ps", ["-axo", "pid=,ppid=,args="], { encoding: "utf8" }).stdout.split("\n").filter((l) => l.includes(`drill-job-${tag}`)).map((l) => l.trim().slice(0, 200));
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

/// Where chat `key` is stopped, as the station it is shown on keeps it (move/stopped.json): what it waits for; null
/// where it is not stopped.
function stoppedOf(key: string): string | null {
  for (const n of stations()) {
    let l: J = [];
    try {
      l = JSON.parse(readFileSync(`${DATA[n]}/move/stopped.json`, "utf8"));
    } catch {
      continue;
    }
    const s = (Array.isArray(l) ? l : []).find((x: J) => x?.item?.module === "chats" && x?.item?.id === key);
    if (s !== undefined && standing(n, key) === "live") return `stopped on ${n}, waiting for ${s.waitsFor?.module} ${s.waitsFor?.id}`;
  }
  return null;
}
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
    () => `${n}'s launcher said nothing of a handover in 10 s: ${since(file, from).split("\n").slice(-5).join(" | ")}`);
  return { from, log: file };
}
/// What `n`'s launcher said since `from` once it said how the handover ended: taken over, or not handed over (its own
/// words: the station's "a chat was not handed over" in the same log is a chat's, drill 19 took it for the launcher's).
function handoverEnd(h: { from: number; log: string }, ms = 120_000): Promise<string> {
  log("  waiting for the handover's end in the launcher's log");
  return whenChanged([RUN], () => /Node [0-9]+ has taken over|not handed over; going on as before[^\n]*|Node [0-9]+ did not take over[^\n]*/.exec(since(h.log, h.from))?.[0], ms,
    () => `no end of the handover said: ${since(h.log, h.from).split("\n").slice(-6).join(" | ")}`);
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
const steps: { A?: Steps } = {};
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
/// (its station's move/stopped.json, what GET /move's `stopped` says), saying why.
async function say(key: string, text: string, prefix: string, ms = 120_000): Promise<string> {
  log(`  saying ${text.slice(0, 80)}, waiting for ${prefix}`);
  const before = new Set(texts(await untilChat(key, (v) => v?.messages && v, 60_000)));
  const stopped0 = stoppedOf(key);
  if (stopped0 !== null) throw new Error(`no answer can come: the chat is ${stopped0} (${standings(key)})`);
  await a.call("chat.send", { station: A, session: key, text });
  // (the chat stopped meanwhile, as its station's files say; a wait that never ends otherwise. Let go of at the next
  // change once the answer came)
  let over = false;
  const stops = whenChanged(stations().map((n) => DATA[n]), () => {
    if (over) return { over };
    const s = stoppedOf(key);
    return s !== null && { stopped: s };
  }, ms + 5_000, () => "").catch(() => new Promise<never>(() => {}));
  const answered = untilChat(key, (v) => texts(v).find((t) => t.startsWith(prefix) && !before.has(t)) ?? failedSend(v, text), ms);
  const got = await Promise.race([answered, stops.then((s) => ("stopped" in s ? s : answered))]).finally(() => void (over = true));
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
  await check("setup: a vault item alice stored (the plain library) and a skill in A's agent home", async () => {
    item = (await a.call("vault.putItem", {
      workspace: ws, vault: "plain",
      plain: { kind: "token", name: `drill-token-${tag}`, fields: { value: `v-${tag}` }, domains: [], notes: "" },
      listing: { name: `drill-token-${tag}`, kind: "token", modes: ["proxy"], hosts: ["api.example.test"] },
    }))?.id ?? "";
    const rows = await whenChanged([DATA.A], () => {
      const r = sql("A", "select id, owner from vault_plain");
      return r.length > 0 && r;
    }, 60_000, () => "A keeps no plain item");
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
  await check("setup: B enrolled beside A with the app's command, moving switched on there, online", async () => {
    bId = await enroll("B", "move-b");
    B = `${ws}/${bId}`;
    if (!/"move":true/.test(readFileSync(`${DATA.B}/config.json`, "utf8"))) throw new Error(`B's config: ${readFileSync(`${DATA.B}/config.json`, "utf8")}`);
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
      log(`  A's profiles now ${brief(profilesA)}; stopped on A: ${existsSync(`${DATA.A}/move/stopped.json`) ? readFileSync(`${DATA.A}/move/stopped.json`, "utf8").slice(0, 400) : "none"}`);
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
            log(`  A's stopped.json: ${existsSync(`${DATA.A}/move/stopped.json`) ? readFileSync(`${DATA.A}/move/stopped.json`, "utf8").slice(0, 600) : "none"}`);
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
        log(`  ${outcome(l)}; ${standings(kc)}; A's stopped ${existsSync(`${DATA.A}/move/stopped.json`) ? readFileSync(`${DATA.A}/move/stopped.json`, "utf8").slice(0, 600) : "none"}`);
        if (standing("A", kc) !== "live") throw new Error(`not back on A: ${standings(kc)}; ${outcome(l)}`);
        back = true;
        const s = stoppedOf(kc);
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
          // (author_kind ember, station/src/store/rows.ts STATION_AUTHOR), station.move.stoppedChat: zh 「这个对话在「A」上
          // 暂停了：它在等「Kimi Code」…」; and no turn begins)
          const t0 = Date.now();
          await a.call("chat.send", { station: A, session: kc, text: `drill-recall:${nonce}` });
          await whenChanged([DATA.A], () => sql("A", `select count(*) n from entries where text like ${lit(`%drill-recall:${nonce}%`)}`)[0].n > 0, 60_000, () => "the message is not in A's log");
          const notices = () => sql("A", `select text from entries e join threads t on t.id = e.thread where t.home = ${lit(kc)} and e.at >= ${t0} and e.author_kind = 'ember'`).map((r) => String(r.text));
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
            log(`  the login alone to B: ${outcome(lo)}; its turn's stopped ${brief(lo?.stopped ?? null, 600)}; ${standings(kd)}; stopped ${stoppedOf(kd)}`);
            // (the facts at that moment, for the station's side: no verdict of them)
            log(`  2k's second chat as the login left, its facts: A's stopped.json ${existsSync(`${DATA.A}/move/stopped.json`) ? readFileSync(`${DATA.A}/move/stopped.json`, "utf8").slice(0, 1200) : "none"}\n    ${heldOf2(kd)}\n    the first chat: ${heldOf2(kc)}\n    A's runtime sessions of both: ${brief(sql("A", `select session_key, profile, id from runtime_sessions where session_key in (${lit(kd)}, ${lit(kc)})`))}\n    the stations' logs around it:\n    ${logsAround(Date.now() - 1500)}`);
            if (stoppedOf(kd) === null) throw new Error(`not stopped on A as its login left: ${standings(kd)}`);
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
            log(`  2k's second chat, its facts: A's stopped.json ${existsSync(`${DATA.A}/move/stopped.json`) ? readFileSync(`${DATA.A}/move/stopped.json`, "utf8").slice(0, 800) : "none"}\n    ${heldOf2(kd)}`);
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
        await check("3e: C still works after: a small chat moved to C answers there, and comes back", async () => {
          const small = await newChat(`f3e-small-${tag}`);
          const l = await moveChat(small, "C");
          for (const d of l.done ?? []) if (d.module === "accounts") toC.add(d.id);
          if (standing("C", small) !== "live") throw new Error(`${standings(small)}; ${outcome(l)}`);
          const said = await say(small, `drill-note:f3e-small-${tag}`, `drill-noted f3e-small-${tag}`);
          if (at(/cwd=(\S+)/.exec(said)?.[1] ?? "") !== "C") throw new Error(said);
          await home(small);
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
      await whenChanged([DATA.A], () => jobs(jobTag).length > 0, 60_000, () => "no job");
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
        if (sql("B", "select count(*) n from vault_plain")[0].n < 1) throw new Error("no plain item on B");
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
        if (sql("B", "select count(*) n from vault_plain")[0].n > 0) throw new Error("B kept the vault item it was given");
      });
    }
    log("SKIP 4: a connect moved with it: not built, the harness has no Slack, Feishu or Comma fake a connect could run against; no connect was part of `all`");
  }

  // ── 5: measured ──
  if (part("5")) {
    limit("5", 10800);
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
      const ready = await a.answered(aId, "/", up, 120_000);
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
    const duringMove = () => {
      const from = new Date();
      return {
        end: async () => {
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
            .filter((m): m is RegExpExecArray => m !== null && m[2] === aId.slice(0, 8) && when(m[1]!) >= from.getTime() && when(m[1]!) <= to.getTime());
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
    await check("5: 300 chats (40 shown, 260 archived): GET /move timed", async () => {
      timer = await newChat(`timer-${tag}`);
      await seed(40, 260);
      await timeMove("300 chats", timer);
    });
    await check("5: a real station's shape, 2,384 chats (149 shown, 2,235 archived): GET /move timed, all of it moved with `all` and back, timed", async () => {
      if (timer === "") timer = await newChat(`timer-${tag}`);
      await seed(149, 2235);
      await timeMove("2,384 chats", timer);
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
      measured(`2,384 chats there, during the move: ${await there.end()}`);
      const seenS = (Date.now() - t0) / 1000;
      // (what is measured is the station's: its turn's end as it wrote it)
      const s = typeof l?.at === "number" ? (l.at - t0) / 1000 : seenS;
      const left = sql("A", "select count(*) n from sessions where (ws is null or (ws not like 'handed:%' and ws not like 'coming:%'))")[0].n as number;
      // (the turn's end as the station wrote it, `last.at`, beside when this wait saw it: drill 22's way back was seen
      // 600 s after its last chat with nothing in either station's log between; what was left or failed, whole)
      const ends = (x: J, t: number, seen: number) => `the station's turn ended at ${typeof x?.at === "number" ? ((x.at - t) / 1000).toFixed(1) : "?"} s, seen at ${seen.toFixed(1)} s`;
      const notDone = (x: J) => `refused [${(x?.refused ?? []).map((r: J) => `${named(r.item)}: ${r.why}`).join(" | ")}] failed ${failuresOf(x).map((f) => `${f.item}: ${f.error}`).join(" | ") || "none"}`;
      measured(`${n} chats moved with all: ${s.toFixed(0)} s, ${((n - left) / (s / 60)).toFixed(0)} chats a minute, ${left} left on A; ${ends(l, t0, seenS)}; main thread: ${holds(from)}; ${notDone(l)}`);
      from = offsets();
      const t1 = Date.now();
      await a.call("move.back", { station: A, from: bId, all: true });
      const back = duringMove();
      const lb = await turnEnds("A", t1, 3_600_000);
      measured(`2,384 chats back, during the move: ${await back.end()}`);
      log(`  the watched page took ${watching.values.length} values through both moves`);
      watching.stop();
      const seenB = (Date.now() - t1) / 1000;
      const sb = typeof lb?.at === "number" ? (lb.at - t1) / 1000 : seenB;
      measured(`and back: ${sb.toFixed(0)} s, ${(n / (sb / 60)).toFixed(0)} chats a minute; ${ends(lb, t1, seenB)}; main thread: ${holds(from)}; ${notDone(lb)}`);
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

    await check("7a: A handed over to a new process as an update does (SIGUSR2 to its launcher) while B asks it each second: no ask over 2 s, every one answered", async () => {
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
    await check("7b: A's whole station stopped while B asks it, started again once alice's device sees it down and an ask of B's is held in the stop: every ask answered or refused in words, none timed out, each by 5 s after A is ready", async () => {
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
    await check("7b: A stopped while B asks it till an ask begun in the stop has its answer: what that ask gets, and when (measured, no bound yet)", async () => {
      const { asks, downAt, upAt } = await acrossStop("answered");
      for (const x of asks.filter((x) => x.at >= downAt && x.at < upAt)) measured(`7b long stop: an ask begun ${((x.at - downAt) / 1000).toFixed(1)} s into it got after ${(x.ms / 1000).toFixed(1)} s (${((x.at + x.ms - upAt) / 1000).toFixed(1)} s from A ready): ${x.said.slice(0, 160)}`);
    });
    await check("7c: A's new process dies at start beside the serving one (not handed over; going on as before), then B asks A and A asks B: no ask over 2 s, every one answered", async () => {
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
} catch (e) {
  fail("the run", e);
}
partOver();
steps.A?.close();
for (const r of report) log(`MEASURED ${r}`);
log(failures() === 0 ? "ALL PASSED" : `${failures()} FAILED`);
await within(Promise.all([a.close(), bob.close()]), 5000);
process.exit(failures() === 0 ? 0 : 1);
