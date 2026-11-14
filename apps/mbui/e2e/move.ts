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
//     not committed, a job) there and back;
//   3 faults, each on a chat of its own and from a state checked clean: n none (a 300 MB room moved with its needs), a B
//     killed in the first pass, b A killed while the chat is held, c B killed as
//     it took the chat, d move.stop in the first pass, e C without room, f A handed over to a fresh process (SIGUSR2 to
//     its launcher) in an agent's turn and in a move's;
//   4 everything (all) to B and all back;
//   5 measured, printed: a 500 MB / 5,000-file room's first pass and pause, 300 chats moved with all, GET /move (the
//     `stationMove` topic's first answer, and station_move plan) with 300 and 2,400 chats.
// Each check says PASS or FAIL with what was seen; a failed one does not stop the next where that can go on alone.
// E2E_SF_SRC, E2E_ORIGIN, E2E_PEER_DATA as peer.ts; E2E_WORK, E2E_STATION as e2e-local.sh's. E2E_MOVE_ONLY: the
// parts to run (e.g. "1 2 3a 5"; all of them where unset).
import { execFileSync, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, rmSync, statSync, statfsSync, unlinkSync, watch, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { check as checked, Device, dir, fail, failures, type J, log, whenChanged, within } from "./device.ts";

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
setTimeout(() => over("the run", runLimit), runLimit * 1000).unref();
let partTimer: ReturnType<typeof setTimeout> | undefined;
const limit = (what: string, s: number) => {
  clearTimeout(partTimer);
  log(`${what}: begins, its limit ${s} s`);
  partTimer = setTimeout(() => over(what, s), s * 1000);
  partTimer.unref();
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
const outOf = (key: string) => handovers("A", "out").filter((o) => (o.keys ?? []).includes(key)).sort((x, y) => y.at - x.at)[0] ?? null;
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
    this.#w = watch(d, () => this.scan());
    this.scan();
  }
  scan(): void {
    for (const o of handovers(this.n, "out")) {
      const l = this.seen.get(o.id) ?? [];
      const held = o.held !== false;
      const last = l.at(-1);
      if (last === undefined || last.step !== o.step || last.held !== held) l.push({ step: o.step, held, at: Date.now() });
      this.seen.set(o.id, l);
    }
  }
  of(id: string) {
    return this.seen.get(id) ?? [];
  }
  close() {
    this.#w?.close();
  }
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
  // (the job's own shell alone, whose argv is `sh -c <its command>`: what started it may carry the line among its own)
  const mine = new RegExp(`^\\s*(\\d+)\\s+(?:\\S*/)?(?:ba|z)?sh -c while :; do sleep 3600; done; : drill-job-${tag}$`);
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
  const before = new Set(texts(await a.until(chatT(key), (v) => v?.messages && v, 60_000)));
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
  const answered = a.until(chatT(key), (v) => texts(v).find((t) => t.startsWith(prefix) && !before.has(t)) ?? failedSend(v, text), ms);
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
async function newChat(label: string): Promise<string> {
  const { key: made } = await a.call("chat.create", { station: A, runtime: "claude" });
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
async function heldOf(key: string, t0: number): Promise<J> {
  log(`  waiting for ${key.slice(-8)} held (its second pass)`);
  const got = await whenChanged([DATA.A], () => {
    const o = outOf(key);
    if (o?.held === true) return { o };
    return cannotCome(key, t0);
  }, 300_000, () => `never held: ${brief(outOf(key))}`);
  if ("why" in got) throw new Error(`it can never be held: ${got.why}`);
  return got.o;
}
/// Why hand-over `key` asked at `t0` goes no further: its step failed, or A's turn ended (move/last.json); else false.
function cannotCome(key: string, t0: number): { why: string } | false {
  const o = outOf(key);
  if (o !== null && o.at >= t0 - 1000 && o.step === "failed") return { why: `its hand-over ${o.id} failed: ${o.error} (at ${o.done ?? "?"} of ${o.total ?? "?"} bytes)` };
  const l = lastOn("A", ws);
  if (l !== null && l.at >= t0 && !existsSync(`${DATA.A}/move/turn.json`)) return { why: `A's turn ended: ${outcome(l)}; its hand-over ${o?.step}: ${o?.error ?? ""}` };
  return false;
}

/// The end of the move or move back asked of station `n` at `since`: its `last` (move/last.json) once its turn ended.
function turnEnds(n: Name, since: number, ms = 300_000): Promise<J> {
  log(`  waiting for the end of the turn on ${n}`);
  return whenChanged([`${DATA[n]}/move`], () => {
    const l = lastOn(n, ws);
    return l !== null && l.at >= since && !existsSync(`${DATA[n]}/move/turn.json`) && l;
  }, ms, () => `no end of the turn asked at ${since} on ${n}: last ${brief(lastOn(n, ws))}, turn ${existsSync(`${DATA[n]}/move/turn.json`) ? readFileSync(`${DATA[n]}/move/turn.json`, "utf8") : "none"}`);
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
const outcome = (l: J) => `done [${(l?.done ?? []).map(named).join(", ")}] refused [${(l?.refused ?? []).map((r: J) => `${named(r.item)}: ${r.why}`).join(" | ")}] failed ${l?.failed ? `${named(l.failed.item ?? "-")}: ${l.failed.error}` : "none"}${l?.stoppedBy !== undefined ? ` stoppedBy ${l.stoppedBy}` : ""}`;
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
  const v = await a.until(moveT(bId), (v) => v?.modules && v, 60_000);
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
      if (mapped !== null && st === "none" && existsSync(mapped) && readdirSync(mapped).length > 0) throw new Error(`${n} has a room for it at ${mapped} (${readdirSync(mapped).slice(0, 5).join(", ")}) and no chat`);
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
    const made = await a.call("workspace.enroll", { account: a.sub, workspace: ws, name });
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
    // (the other chat of A, made by the harness's up: what an item moved away stops here)
    const k0 = sql("A", "select key from sessions").map((r) => r.key as string).find((k) => k !== k2) ?? "";
    let heldNote = "";
    let t0 = 0;
    let before: string[] = [];
    const rid = runtimeId("A", k2) ?? "";
    await check("2: the chat moved to B (move.start with what it needs), its turn ending with it there", async () => {
      before = texts(await a.until(chatT(k2), (v) => v?.messages && v));
      for (const t of turns().filter((t) => t.session === rid)) log(`  before the move, handed on ${at(t.cwd)}: ${t.text.replace(/\s+/g, " ").slice(0, 100)}`);
      t0 = Date.now();
      await a.call("move.start", { station: A, to: bId, module: "chats", item: k2, withNeeds: true });
      // a message said while the chat is held: as its hand-over says held (its second pass), at once
      const held = heldOf(k2, t0).then(async (o) => {
        heldNote = `held-${tag}`;
        await a.call("chat.send", { station: A, session: k2, text: `drill-note:${heldNote}` });
        log(`  said while ${o.step}${outOf(k2)?.step !== o.step ? ` (it was ${outOf(k2)?.step} once sent)` : ""}`);
      });
      held.catch((e) => log(`  ${e.message}`));
      const l = await turnEnds("A", t0);
      await within(held.catch(() => {}), 10_000);
      log(`  ${outcome(l)}; steps ${brief(steps.A!.of(outOf(k2)?.id ?? "").map((s) => `${s.step}${s.held ? "*" : ""}+${s.at - t0}`))}`);
      if (standing("B", k2) !== "live") throw new Error(`${standings(k2)}; ${outcome(l)}`);
      arrived = true;
      movedWith = (l.done ?? []).filter((d: J) => d.module !== "chats");
      const profilesA = (JSON.parse(readFileSync(`${DATA.A}/config.json`, "utf8")).profiles ?? []).map((p: J) => p.id);
      log(`  A's profiles now ${brief(profilesA)}; stopped on A: ${existsSync(`${DATA.A}/move/stopped.json`) ? readFileSync(`${DATA.A}/move/stopped.json`, "utf8").slice(0, 400) : "none"}`);
    });
    if (arrived) {
      await check("2: the device lists the chat once, on B", () => listedOnceOn(k2, "B"));
      await check("2: nothing was posted into the chat by a station and its agent was not woken by the move", async () => {
        const now = texts(await a.until(chatT(k2), (v) => v?.messages && v));
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
        const v = await a.until(chatT(k2), (v) => texts(v).some((t) => t.startsWith(`drill-noted ${heldNote}`)) && v, 120_000);
        const asked = texts(v).filter((t) => t === `drill-note:${heldNote}`).length;
        const answers = texts(v).filter((t) => t.startsWith(`drill-noted ${heldNote}`));
        const cwd = /cwd=(\S+)/.exec(answers[0] ?? "")?.[1] ?? "";
        if (asked !== 1 || answers.length !== 1 || at(cwd) !== "B") throw new Error(`said ${asked} times, answered ${answers.length} (${brief(answers)})`);
        const handed = turns(t0).filter((t) => t.text.includes(`drill-note:${heldNote}`));
        if (handed.length !== 1) throw new Error(`handed to an agent ${handed.length} times: ${brief(handed.map((t) => `${t.pid}@${at(t.cwd)}`))}`);
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
          fail("2: back on A while its account is still on B: stopped, and the person is told so", new Error(`not reachable by this login: A borrows it (${brief(borrowed.map((p: J) => ({ id: p.id, share: p.share ?? null })))}); it needs a login that cannot be shared, which the drill has no way to make yet`));
        }
        if (account !== undefined && standing("A", k2) === "live" && borrowed.length === 0) {
          const nonce = randomBytes(3).toString("hex");
          await check("2: back on A while its account is still on B: stopped, and the person is told so", async () => {
            log(`  A's stopped.json: ${existsSync(`${DATA.A}/move/stopped.json`) ? readFileSync(`${DATA.A}/move/stopped.json`, "utf8").slice(0, 600) : "none"}`);
            const m = await a.until(moveT(bId), (v) => v?.modules && v, 60_000);
            const row = (m.modules.find((x: J) => x.id === "chats")?.items ?? []).find((x: J) => x.id === k2);
            log(`  A's page: the chat's row ${brief(row)}; note ${m.note}`);
            await a.call("chat.send", { station: A, session: k2, text: `drill-recall:${nonce}` });
            if (k0 !== "") await a.call("chat.send", { station: A, session: k0, text: `drill-note:k0-${nonce}` });
            await whenChanged([DATA.A], () => sql("A", `select count(*) n from entries where text like ${lit(`%drill-recall:${nonce}%`)}`)[0].n > 0, 60_000, () => "the message is not in A's log");
            const v = await a.until(chatT(k2), (v) => v?.messages && v);
            // (what of the chat's page a person reads of where it stands: its line, the line over its composer, what is
            // said under what they sent, its messages since; not the whole value, where a field's name matched before)
            const shown = { stateText: v.stateText ?? null, offlineNote: v.offlineNote ?? null, connection: v.connection ?? null, outbox: (v.outbox ?? []).map((o: J) => `${o.state}${o.waits ? `: ${o.waits}` : ""}`), messages: texts(v).slice(-3) };
            log(`  the chat as the device shows it now: ${brief(shown, 900)}`);
            if (row?.state !== "stopped") throw new Error(`its row on A's page says ${row?.state} (${row?.stateText}), not stopped waiting for its account`);
            const read = [shown.stateText, shown.offlineNote, JSON.stringify(shown.connection), ...shown.outbox, ...texts(v).filter((t) => !t.startsWith("drill-"))].join(" | ");
            if (!/停|等|stopped|waits for|账号|登录|login|account/i.test(read)) throw new Error(`nothing on the chat's page tells the person it is stopped and what it waits for (only the move page's row says ${row?.stateText}): ${read.slice(0, 400)}`);
          });
          await check("2: its account moved back: the chat goes on, what was said meanwhile answered once, its job on A, A's other chat answers too", async () => {
            const la = await moveBack(account.id, "B", "accounts");
            log(`  ${outcome(la)}; A's profiles ${brief((JSON.parse(readFileSync(`${DATA.A}/config.json`, "utf8")).profiles ?? []).map((p: J) => p.id))}`);
            const v = await a.until(chatT(k2), (v) => texts(v).some((t) => t.startsWith(`drill-recall ${nonce} `)) && v, 120_000);
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
      }
    }
  }

  // ── 3: faults ──
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
      const logins = (JSON.parse(readFileSync(`${DATA.A}/config.json`, "utf8")).profiles ?? []).filter((p: J) => p.runtime === "claude");
      if (logins.length === 0) throw new Error(`A has no login to run a chat on (B's: ${brief((JSON.parse(readFileSync(`${DATA.B}/config.json`, "utf8")).profiles ?? []).map((p: J) => p.id))})`);
      const k = await newChat(`clean-${label}-${tag}`);
      const said = await say(k, `drill-note:clean-${label}`, `drill-noted clean-${label}`, 60_000);
      if (at(/cwd=(\S+)/.exec(said)?.[1] ?? "") !== "A") throw new Error(`a new chat on A answered from elsewhere: ${said}`);
      return true;
    } catch (e) {
      fail(`${label}: begins from a clean state (the part is not run)`, e);
      return false;
    }
  };

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
      } finally {
        await up("B");
      }
    });
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
        const v = await a.until(chatT(key), (v) => v?.messages && v, 10_000).catch(() => null);
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
        const v = await a.until(chatT(key), (v) => texts(v).some((t) => t.startsWith(`drill-noted ${note}`)) && v, 180_000).catch(async (e) => {
          const now = await a.until(chatT(key), (v) => v?.messages && v, 10_000).catch(() => null);
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
    try {
      let key = "";
      let freeBefore = 0;
      await check("3e: C enrolled with its data on a small APFS volume of its own", async () => {
        cId = await enroll("C", "move-small");
        C = `${ws}/${cId}`;
        stationDo("second-stop", "third");
        rmSync(dmg, { force: true });
        sh("hdiutil", ["create", "-quiet", "-size", "120m", "-fs", "APFS", "-volname", "drillsmall", dmg]);
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
        await check("3e: a chat larger than C's free room: refused before it is held, saying what to do, or failed with the chat working on A and C clean", async () => {
          key = await faultChat("f3e", Math.ceil(freeBefore / 1024 / 1024) + 60, 300);
          const t0 = Date.now();
          await a.call("move.start", { station: A, to: cId, module: "chats", item: key, withNeeds: true });
          const l = await turnEnds("A", t0);
          const o = outOf(key);
          const why = l.failed?.error ?? (l.refused ?? []).map((r: J) => r.why).join(" | ");
          log(`  ${outcome(l)}; its hand-over ${o?.step} held=${o?.held}`);
          if (standing("A", key) !== "live") throw new Error(standings(key));
          if (o !== null && o.held !== false) throw new Error("it was held before it was refused");
          if (!/free|room|space/i.test(why)) throw new Error(`what it said does not say what to do about room: ${why}`);
          const s = statfsSync(DATA.C);
          const free = Number(s.bavail) * Number(s.bsize);
          log(`  C free before ${(freeBefore / 1048576).toFixed(0)} MB, after ${(free / 1048576).toFixed(0)} MB`);
          await whenChanged([`${DATA.C}/replica`], () => !handovers("C", "in").some((i) => (i.keys ?? []).includes(key) && i.step === "coming") && true, 120_000, () => `C's hand-over in: ${brief(handovers("C", "in"))}`);
          if (free < freeBefore - 20 * 1048576) throw new Error(`C has ${((freeBefore - free) / 1048576).toFixed(0)} MB less free than before`);
        });
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
          if (standing("C", small) !== "live") throw new Error(`${standings(small)}; ${outcome(l)}`);
          const said = await say(small, `drill-note:f3e-small-${tag}`, `drill-noted f3e-small-${tag}`);
          if (at(/cwd=(\S+)/.exec(said)?.[1] ?? "") !== "C") throw new Error(said);
          await home(small);
        });
      }
    } finally {
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
  }
  if (part("3f") && (limit("3f", 900), await clean("3f"))) {
    const launcher = () => spawnSync("pgrep", ["-f", `run --app ${ST}/app --data`], { encoding: "utf8" }).stdout.split("\n").filter((x) => x !== "").map(Number)[0];
    /// A handed over to a fresh Node by its launcher (SIGUSR2, what an update does once it goes ahead), until the new
    /// one says it has taken over.
    const handOverA = async () => {
      const log0 = statSync(`${RUN}/station.log`).size;
      const pid = launcher();
      if (pid === undefined) throw new Error("A's launcher not found: the harness's stations run under it");
      process.kill(pid, "SIGUSR2");
      await whenChanged([RUN], () => readFileSync(`${RUN}/station.log`, "utf8").slice(log0).match(/Node [0-9]+ has taken over/), 120_000, () => "no new Node took over");
    };
    let key = "";
    await check("3f: A handed over to a fresh process (SIGUSR2 to its launcher) during an agent's turn: the turn is not cut", async () => {
      key = await newChat(`f3f-${tag}`);
      const g = `g${tag}`;
      const t0 = Date.now();
      await a.call("chat.send", { station: A, session: key, text: `drill-gate:${g}` });
      const began = await whenChanged([ST], () => turns(t0).find((t) => t.text.includes(`drill-gate:${g}`)), 60_000, () => "the gated turn never began");
      await handOverA();
      writeFileSync(`${FAKE}.gate-${g}`, "go\n");
      const v = await a.until(chatT(key), (v) => texts(v).some((t) => t.startsWith(`drill-gated ${g}`)) && v, 120_000);
      const answers = texts(v).filter((t) => t.startsWith(`drill-gated ${g}`));
      const handed = turns(t0).filter((t) => t.text.includes(`drill-gate:${g}`));
      if (answers.length !== 1 || !answers[0]!.includes(`pid=${began.pid}`) || handed.length !== 1) throw new Error(`answers ${brief(answers)}, the turn began in ${began.pid}, handed ${handed.length} times`);
    });
    let k3 = "";
    await check("3f: A handed over to a fresh process during a move's first pass: the move's turn is not cut", async () => {
      k3 = await faultChat("f3f-move", 300);
      const t0 = Date.now();
      await a.call("move.start", { station: A, to: bId, module: "chats", item: k3, withNeeds: true });
      await firstPass(k3, t0);
      await handOverA();
      const l = await turnEnds("A", t0);
      log(`  ${outcome(l)}; ${standings(k3)}; its hand-over ${outOf(k3)?.step}: ${outOf(k3)?.error}`);
      if (standing("B", k3) !== "live") throw new Error(`cut: ${outcome(l)}`);
    });
    if (k3 !== "") await endsWell("3f", k3);
    log("SKIP 3f: the station's own self-update waits for a move's turn (updates/holds.ts): not built, the harness's stations have autoUpdate off and no newer release to update to; only the launcher's handover (SIGUSR2) is reachable, above");
  }

  // ── 4: everything to B and all back ──
  if (part("4") && (limit("4", 3600), await clean("4"))) {
    const keys: string[] = [];
    const archived: string[] = [];
    let jobTag = "";
    await check("4: setup: about 12 chats on A (3 archived with their packed workspace), a job, the vault item, the skill, a setting, the account", async () => {
      for (let i = 0; i < 10; i++) keys.push(await newChat(`all-${i}-${tag}`));
      for (const k of keys) writeFileSync(join(roomOn("A", k)!, "mine.txt"), `${k}\n`);
      jobTag = `all${tag}`;
      await say(keys[0]!, `drill-job:${jobTag}`, `drill-job ${jobTag}`);
      await whenChanged([DATA.A], () => jobs(jobTag).length > 0, 60_000, () => "no job");
      for (const k of keys.slice(7)) {
        const thread = (await a.until(chatT(k), (v) => typeof v?.thread?.id === "number" && v)).thread.id;
        await a.call("chat.archive", { station: A, session: k, thread, archived: true });
        archived.push(k);
      }
      await whenChanged([DATA.A], () => archived.every((k) => {
        const r = roomOn("A", k)!;
        return existsSync(join(r, "workspace.tar.zst")) || existsSync(join(dirname(r), "workspace.tar.zst"));
      }), 120_000, () => `not packed: ${archived.map((k) => roomOn("A", k)).join(", ")}`);
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
      measured(`all of A (${before.length} chats) to B: ${((Date.now() - t0) / 1000).toFixed(1)} s`);
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
        measured(`all of it back from B (${before.length} chats): ${((Date.now() - t0) / 1000).toFixed(1)} s`);
        log(`  ${outcome(l)}`);
        const now = new Set(allChats());
        const missing = before.filter((k) => !now.has(k));
        if (missing.length > 0) throw new Error(`not back on A: ${missing.slice(0, 5).map((k) => `${k} ${standings(k)}`).join("; ")} (${missing.length})`);
        for (const k of keys) if (readFileSync(join(roomOn("A", k)!, "mine.txt"), "utf8") !== `${k}\n`) throw new Error(`${k}'s file`);
        const j = jobs(jobTag);
        if (!(j.length === 1 && j[0]!.on === "A")) throw new Error(`the job: ${jobsText(jobTag)}`);
        const onB = sql("B", "select count(*) n from sessions where (ws is null or (ws not like 'handed:%' and ws not like 'coming:%'))")[0].n;
        if (onB > 0) throw new Error(`B still shows ${onB} chats`);
        const cfg = JSON.parse(readFileSync(`${DATA.B}/config.json`, "utf8"));
        if (cfg.maxNudges !== undefined) throw new Error(`B kept the setting it was given: maxNudges ${cfg.maxNudges}`);
        if (existsSync(`${DATA.B}/agent/skills/drill-skill`)) throw new Error("B kept the skill it was given");
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
      await a.stationState(ws, (s) => s.state === "online", 120_000, aId);
    };
    /// What the stations' logs say of their main thread held since `from` (each log's byte offset): how often, the longest.
    const logs = () => ({ A: `${RUN}/station.log`, B: `${RUN}/second.log` });
    const offsets = () => Object.fromEntries(Object.entries(logs()).map(([n, f]) => [n, existsSync(f) ? statSync(f).size : 0])) as Record<string, number>;
    const holds = (from: Record<string, number>) => Object.entries(logs()).map(([n, f]) => {
      const t = existsSync(f) ? readFileSync(f, "utf8").slice(from[n] ?? 0) : "";
      const ms = [...t.matchAll(/the main thread was held.*?heldMs=(\d+)/g)].map((m) => Number(m[1]));
      return `${n}: ${ms.length} held, longest ${ms.length === 0 ? 0 : Math.max(...ms)} ms${ms.filter((x) => x > 200).length > 0 ? ` (${ms.filter((x) => x > 200).length} over 200 ms)` : ""}`;
    }).join("; ");
    /// GET /move as the device asks it: the `stationMove` topic's first answer for a page not read yet, and how long
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
      const n = sql("A", "select count(*) n from sessions where (ws is null or (ws not like 'handed:%' and ws not like 'coming:%'))")[0].n as number;
      let from = offsets();
      const t0 = Date.now();
      await a.call("move.start", { station: A, to: bId, all: true });
      const l = await turnEnds("A", t0, 3_600_000);
      const s = (Date.now() - t0) / 1000;
      const left = sql("A", "select count(*) n from sessions where (ws is null or (ws not like 'handed:%' and ws not like 'coming:%'))")[0].n as number;
      measured(`${n} chats moved with all: ${s.toFixed(0)} s, ${((n - left) / (s / 60)).toFixed(0)} chats a minute, ${left} left on A; main thread: ${holds(from)} (${outcome(l).slice(0, 600)})`);
      from = offsets();
      const t1 = Date.now();
      await a.call("move.back", { station: A, from: bId, all: true });
      const lb = await turnEnds("A", t1, 3_600_000);
      const sb = (Date.now() - t1) / 1000;
      measured(`and back: ${sb.toFixed(0)} s, ${(n / (sb / 60)).toFixed(0)} chats a minute; main thread: ${holds(from)} (${outcome(lb).slice(0, 600)})`);
      if (left > 0) throw new Error(`${left} chats not moved`);
    });
  }
} catch (e) {
  fail("the run", e);
}
clearTimeout(partTimer);
steps.A?.close();
for (const r of report) log(`MEASURED ${r}`);
log(failures() === 0 ? "ALL PASSED" : `${failures()} FAILED`);
await within(Promise.all([a.close(), bob.close()]), 5000);
process.exit(failures() === 0 ? 0 : 1);
