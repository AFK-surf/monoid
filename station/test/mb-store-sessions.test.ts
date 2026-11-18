// The store's sessions in MoonBit (station/mb src/store_sessions, the reader's `--builder harness-store-sessions`)
// against the TypeScript `Store` it is moved from: two databases made alike by `Store.open`, A written by the
// TypeScript, B by the program, each call made of both at the same time (one clock), and each answered alike: what it
// gives back, what it told its followers (StoreChange, in order) and how often it said a session's workspace changed,
// its arguments as it left them (an import's context, a usage write's `changed`), and at the end every table of the two
// databases, row by row. What the store of the threads' messages writes (P1-3's: threads, messages, deliveries, reads)
// is written alike on both by the TypeScript, as the ground the calls stand on.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import { latest as latestNote } from "../src/agents/migrations.ts";
import { MbProcess, mbReaderBinary } from "../src/read/mb-reader.ts";
import * as handover from "../src/store/handover.ts";
import { Store, type StoreChange } from "../src/store/store.ts";
import * as stores from "../src/store/store.ts";
import * as rows from "../src/store/rows.ts";
import * as recover from "../src/store/recover-waits.ts";
import * as awake from "../src/store/awake-waits.ts";
import * as counts from "../src/store/session-counts.ts";
import * as share from "../src/store/chat-share-index.ts";
import * as upjobs from "../src/store/session-up-jobs.ts";
import * as bindings from "../src/store/session-bindings-index.ts";
import * as widgets from "../src/store/widget-sources.ts";
import * as active from "../src/store/active-jobs.ts";
import * as upgrade from "../src/store/active-jobs-upgrade.ts";
import * as remote from "../src/store/remote-runs.ts";
import * as hours from "../src/store/profile-hours.ts";
import * as usage from "../src/store/usage.ts";
import { widgetSourcesStep } from "./reference/backfill/widget-sources.ts";
import { installCompactUsage } from "../src/store/usage-compact.ts";
import { chatShareIndexReady, chatShareIndexStep, installChatShareIndex } from "./reference/backfill/chat-share-index.ts";

const binary = mbReaderBinary();
const HOUR = 3_600_000;

/// What a call gives, as the program says it: a Map its entries, a Set its items, undefined `{$undefined: true}`.
function said(v: unknown): unknown {
  if (v === undefined) return { $undefined: true };
  return JSON.parse(JSON.stringify(v, (_, x) => (x instanceof Map ? [...x.entries()] : x instanceof Set ? [...x] : x)));
}

/// Every table of a database, row by row (each with its rowid where it has one), in one order.
function dump(store: Store): Record<string, unknown[]> {
  const out: Record<string, unknown[]> = {};
  const tables = store.db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").all() as { name: string }[];
  for (const { name } of tables) {
    const q = `"${name.replaceAll('"', '""')}"`;
    let all: unknown[];
    try { all = store.db.prepare(`SELECT rowid AS "#rowid", * FROM ${q}`).all(); }
    catch { all = store.db.prepare(`SELECT * FROM ${q}`).all(); }
    out[name] = all.map((r) => JSON.stringify(r)).sort();
  }
  return out;
}

type Ask = { id: number; now: number; call: string; args: unknown[]; latestNote: number };
type Answer = { id: number; result?: unknown; error?: string; data?: unknown; changes: unknown[]; workspace: number; args: unknown[] };

/// A TypeScript store and the program's, on two databases alike, at one time.
class Pair {
  now = 1_800_000_000_000;
  readonly dir = mkdtempSync(join(tmpdir(), "mb-store-sessions-"));
  readonly clock = { currentTimeMillisUnsafe: () => this.now } as never;
  readonly ts: Store;
  /// B, as the TypeScript opens it: what the program's writes stand on, and how its tables are read.
  readonly tsB: Store;
  readonly mb: MbProcess;
  #told: StoreChange[] = [];
  #workspace = 0;
  #id = 0;
  readonly calls = new Set<string>();
  /// The last call's arguments as the TypeScript left them.
  lastArgs: any[] = [];
  /// What the last call told.
  lastTold: any[] = [];

  constructor() {
    this.ts = Store.open(join(this.dir, "a", "stillfail.db"), join(this.dir, "a", "archive"), this.clock);
    this.tsB = Store.open(join(this.dir, "b", "stillfail.db"), join(this.dir, "b", "archive"), this.clock);
    this.ts.subscribe((c) => this.#told.push(c));
    this.ts.onSessionWorkspaceChange(() => this.#workspace++);
    this.mb = new MbProcess(binary!, ["--builder", "harness-store-sessions", "--db", join(this.dir, "b", "stillfail.db")]);
  }

  /// What the threads' store writes, alike on both (the ground the calls stand on).
  both<T>(write: (s: Store) => T): T {
    const a = write(this.ts);
    write(this.tsB);
    return a;
  }

  async ask(call: string, args: unknown[]): Promise<Answer> {
    const answered = new Promise<Answer>((resolve) => this.mb.once("message", resolve as never));
    const ask: Ask = { id: ++this.#id, now: this.now, call, args, latestNote: latestNote() };
    this.mb.postMessage(ask);
    const answer = await answered;
    assert.equal(answer.id, ask.id);
    return answer;
  }

  /// `call` of both, compared: its result (or what it threw), what it told, its arguments as left. The result.
  async c(call: string, ...args: unknown[]): Promise<any> {
    this.calls.add(call);
    const forTs = JSON.parse(JSON.stringify(args));
    const forMb = JSON.parse(JSON.stringify(args));
    this.#told = [];
    this.#workspace = 0;
    let result: unknown;
    let error: { error: string; data: unknown } | null = null;
    try { result = invoke(this.ts, call, forTs); }
    catch (e) {
      const x = e as { message: string; positions?: unknown; threads?: unknown };
      error = { error: x.message, data: x.positions !== undefined ? { positions: x.positions } : x.threads !== undefined ? { threads: x.threads } : null };
    }
    const answer = await this.ask(call, forMb);
    const where = `${call}(${JSON.stringify(args).slice(0, 300)})`;
    if (error !== null) assert.deepEqual({ error: answer.error, data: answer.data }, error, `${where} throws alike`);
    else {
      assert.equal(answer.error, undefined, `${where}: ${answer.error}`);
      assert.deepEqual(answer.result, said(result), `${where} answers alike`);
    }
    assert.deepEqual(answer.changes, said(this.#told), `${where} tells alike`);
    assert.equal(answer.workspace, this.#workspace, `${where} says a workspace changed alike`);
    assert.deepEqual(answer.args, said(forTs), `${where} leaves its arguments alike`);
    this.lastArgs = forTs;
    this.lastTold = said(this.#told) as any[];
    if (error !== null) return error;
    return said(result);
  }

  same(what: string): void {
    const a = dump(this.ts), b = dump(this.tsB);
    // (made as each database was opened, a random epoch each: archive-last.ts)
    a.archive_last_meta = b.archive_last_meta = [];
    const differ = Object.keys({ ...a, ...b }).filter((t) => JSON.stringify(a[t]) !== JSON.stringify(b[t]));
    assert.deepEqual(Object.fromEntries(differ.map((t) => [t, b[t]])), Object.fromEntries(differ.map((t) => [t, a[t]])),
      `${what}: the two databases are alike, row by row`);
  }

  async close(): Promise<void> {
    await this.mb.terminate();
    this.ts.close();
    this.tsB.close();
    rmSync(this.dir, { recursive: true, force: true });
  }
}

/// A call of the TypeScript store's by its name, its arguments as JSON gives them.
function invoke(store: Store, call: string, a: any[]): unknown {
  const s = store as any;
  switch (call) {
    case "sql": return SQL;
    case "followProfiles": return store.followProfiles(a[0], new Map(a[1]));
    case "setTranscriptLengths": return store.setTranscriptLengths(new Map(a[0]));
    case "sessionPage": return pageOps(store.sessionPage(a[0], a[1] ?? undefined), a[2]);
    case "sessionPageOfWs": return pageOps(store.sessionPageOfWs(a[0], a[1], a[2], a[3]), a[4]);
    case "refreshChatShareIndex": return share.refreshChatShareIndex(store.db);
    case "handover.afterOf": return handover.afterOf(a[0], a[1]);
    case "handover.surfaceHere": return handover.surfaceHere(a[0], a[1]);
    case "handover.newCtx": return handover.newCtx(a[0]);
    case "handover.putUsage": return handover.putUsage(store.db, a[0]);
    case "handover.handedWithUsage": return handover.handedWithUsage(store.db, a[0], a[1], a[2]);
    case "handover.handedStations": return handover.handedStations(store.db);
    case "handover.threadRefs": return handover.threadRefs(store.db, a[0], a[1]);
    case "handover.threadOfRef": return handover.threadOfRef(store.db, a[0], a[1], a[2]);
    case "handover.hasUsage": return handover.hasUsage(store.db, a[0]);
    case "handover.importHandedUsage": return handover.importHandedUsage(store.db, a[0]);
    default:
      if (typeof s[call] !== "function") throw new Error(`no call ${call}`);
      return s[call](...a);
  }
}

function pageOps(page: stores.SessionPage, ops: [string, string?][]): unknown[] {
  return ops.map(([op, key]) => op === "keys" ? [...page.keys] : op === "rows" ? page.rows() : op === "session" ? page.session(key!)
    : op === "homeMembers" ? page.homeMembers(key!) : page.ranOn(key!));
}

/// The statements the program keeps word for word (its sqls.mbt), as the TypeScript says them.
const SQL: [string, string][] = [
  ["live_sessions", stores.LIVE_SESSIONS], ["any_running", stores.ANY_RUNNING], ["running_sessions", stores.RUNNING_SESSIONS],
  ["waiting_for_people", stores.WAITING_FOR_PEOPLE], ["failed_turn_near", stores.FAILED_TURN_NEAR], ["process_by_group", stores.PROCESS_BY_GROUP],
  ["transcript_in_use", stores.TRANSCRIPT_IN_USE], ["stats_of", stores.STATS_OF], ["last_turn_of_session", stores.LAST_TURN_OF_SESSION],
  ["work_of_session", stores.WORK_OF_SESSION], ["last_read_at", stores.LAST_READ_AT], ["models_used_by", stores.MODELS_USED_BY],
  ["efforts_used_by", stores.EFFORTS_USED_BY], ["efforts_used_by_before_index", stores.EFFORTS_USED_BY_BEFORE_INDEX],
  ["people_said_after", stores.PEOPLE_SAID_AFTER], ["post_blocks_ready", stores.POST_BLOCKS_READY], ["post_after_first", stores.POST_AFTER_FIRST],
  ["post_after_indexed", stores.POST_AFTER_INDEXED],
  ["jobs_running", rows.JOBS_RUNNING], ["jobs_up", rows.JOBS_UP], ["live_on_profile", rows.LIVE_ON_PROFILE], ["last_jobs_of", rows.LAST_JOBS_OF],
  ["job_at_port", rows.JOB_AT_PORT], ["session_jobs", rows.SESSION_JOBS], ["session_of_runtime", rows.SESSION_OF_RUNTIME],
  ["recover_waits", recover.RECOVER_WAITS], ["recover_awake_waits", recover.RECOVER_AWAKE_WAITS], ["awake_wait_status", awake.AWAKE_WAIT_STATUS],
  ["session_count_total", counts.SESSION_COUNT_TOTAL], ["session_count_connect", counts.SESSION_COUNT_CONNECT], ["session_counts", counts.SESSION_COUNTS],
  ["session_counts_visible", counts.SESSION_COUNTS_VISIBLE], ["session_counts_home", counts.SESSION_COUNTS_HOME],
  ["share_dirty", share.SHARE_DIRTY], ["share_live", share.SHARE_LIVE], ["share_due", share.SHARE_DUE], ["share_next_time", share.SHARE_NEXT_TIME],
  ["share_lapsed_workspace", share.SHARE_LAPSED_WORKSPACE],
  ["session_up_job", upjobs.SESSION_UP_JOB], ["session_up_jobs", upjobs.SESSION_UP_JOBS],
  ["session_bindings_exists", bindings.SESSION_BINDINGS_EXISTS], ["session_bindings_delete", bindings.SESSION_BINDINGS_DELETE],
  ["widget_source_missing", widgets.WIDGET_SOURCE_MISSING], ["widget_source_unusual", widgets.WIDGET_SOURCE_UNUSUAL],
  ["widget_source", widgets.WIDGET_SOURCE], ["widget_source_original", widgets.WIDGET_SOURCE_ORIGINAL],
  ["awake_jobs", active.AWAKE_JOBS], ["running_limit", active.RUNNING_LIMIT], ["running_job_sessions", active.RUNNING_JOB_SESSIONS],
  ["running_wait_jobs", active.RUNNING_WAIT_JOBS], ["up_jobs_of_session", active.UP_JOBS_OF_SESSION], ["remote_queue_jobs", active.REMOTE_QUEUE_JOBS],
  ["awake_jobs_before_upgrade", active.AWAKE_JOBS_BEFORE_UPGRADE], ["running_limit_before_upgrade", active.RUNNING_LIMIT_BEFORE_UPGRADE],
  ["running_job_sessions_before_upgrade", active.RUNNING_JOB_SESSIONS_BEFORE_UPGRADE], ["running_wait_jobs_before_upgrade", active.RUNNING_WAIT_JOBS_BEFORE_UPGRADE],
  ["up_jobs_before_upgrade", active.UP_JOBS_BEFORE_UPGRADE], ["remote_queue_before_upgrade", active.REMOTE_QUEUE_BEFORE_UPGRADE],
  ["remote_queue_prepared", upgrade.REMOTE_QUEUE_PREPARED], ["delete_expired_remote_runs", remote.DELETE_EXPIRED_REMOTE_RUNS],
  ["quota_hours_read", hours.QUOTA_HOURS_READ], ["spend_hours_read", hours.SPEND_HOURS_READ],
  ["speed_quarters_read", hours.SPEED_QUARTERS_READ],
  ["active_sessions", usage.ACTIVE_SESSIONS], ["turns_from", usage.TURNS_FROM], ["turns_between", usage.TURNS_BETWEEN], ["taken_since", usage.TAKEN_SINCE],
  ["last_contexts", usage.LAST_CONTEXTS],
];

const session = (key: string, more: Record<string, unknown> = {}) => ({
  key, connect: "ember", runtime: "claude", profile: "p1", workspace: `/data/rooms/${key}`, token: `tok-${key}`,
  createdAt: 1_799_000_000_000, lastActiveAt: 1_799_000_000_000, ...more,
});

async function withPair(run: (p: Pair) => Promise<void>): Promise<void> {
  assert.notEqual(binary, null, "the MoonBit reader is built (station/mb/build.sh, or STILLFAIL_MB_READER)");
  const p = new Pair();
  try { await run(p); }
  finally { await p.close(); }
}

test("its statements are the TypeScript's, word for word", () => withPair(async (p) => {
  await p.c("sql");
}));

test("sessions: made, set, read, counted, kept in memory and forgotten as the TypeScript does", () => withPair(async (p) => {
  await p.c("insertSession", session("s1", { profilePinned: true, title: "one", createdBy: "ann", effort: "high", model: "opus" }));
  await p.c("insertSession", session("s2", { profiles: ["p1", "p2"], runtime: "codex", runtimeSessionId: "th-2", speed: "fast", fast: true, ws: "w1" }));
  await p.c("insertSession", session("s3", { profiles: [], profilePinned: false, scope: "all", createdBy: "ann", effort: "low", model: "opus", ws: "w1", cwd: "/x" }));
  await p.c("insertSession", session("s4", { connect: "slack-1", createdBy: "bob", context: 200000, ws: null }));
  for (const k of ["s1", "s2", "s3", "s4", "none"]) {
    await p.c("getSession", k);
    await p.c("sessionWs", k);
    await p.c("sessionWs", k);
  }
  await p.c("sessionsOf", ["s1", "s3", "none"]);
  await p.c("sessionsOf", []);
  await p.c("sessionKeyByToken", "tok-s2");
  await p.c("sessionKeyByToken", "tok-s2");
  await p.c("sessionKeyByToken", "nobody");
  await p.c("sessionByToken", "tok-s3");
  await p.c("listSessions");
  await p.c("liveSessions");
  await p.c("sessionKeys");
  await p.c("anyRunning");
  p.now += 1000;
  await p.c("setRunning", "s2", true);
  await p.c("anyRunning");
  await p.c("runningSessions");
  p.now += 1000;
  await p.c("touch", "s3");
  await p.c("sessionsInUse");
  await p.c("setSessionProfile", "s1", "p2", false);
  await p.c("setSessionProfile", "s1", "p3", true, ["p3", "p4"]);
  await p.c("setSessionProfile", "s1", "p3", true, null);
  await p.c("setSessionProfile", "s4", "p9", true, []);
  p.now += 1000;
  await p.c("ranIn", "s1", "rt-a", "p3");
  p.now += 1000;
  await p.c("ranIn", "s1", "rt-b", null);
  await p.c("ranIn", "s1", "rt-a", null);
  await p.c("setSessionRuntime", "s1", "codex", "p5", true, "gpt", "medium", false, 100000);
  await p.c("setSessionRuntime", "s1", "claude", "p6", false, null, null, null, null, ["p6", "p7"]);
  await p.c("setRuntimeSessionId", "s1", "rt-b");
  await p.c("conversationSince", "s1");
  await p.c("setRuntimeSessionId", "s1", "rt-new");
  await p.c("conversationSince", "s1");
  await p.c("setRuntimeSessionId", "s1", null);
  await p.c("conversationSince", "s1");
  await p.c("conversationSince", "none");
  await p.c("setRuntimeSessionId", "s1", "rt-c");
  await p.c("runtimeSessions", "s1");
  await p.c("runtimeSessionSources", "s1");
  await p.c("runtimeSessionSource", "s1", "rt-a");
  await p.c("runtimeSessionSource", "s1", "rt-c");
  await p.c("runtimeSessionSource", "s1", "rt-x");
  await p.c("runtimeSessionSource", "none", "rt-x");
  await p.c("runtimeSessionSource", "s1", "bad\u0000id");
  await p.c("ranOn", "s1", "rt-a");
  await p.c("ranOn", "s1", "rt-b");
  await p.c("sessionOfRuntime", "claude", "rt-c");
  await p.c("sessionOfRuntime", "claude", "rt-a");
  await p.c("sessionOfRuntime", "codex", "th-2");
  await p.c("sessionOfRuntime", "codex", "none");
  await p.c("transcriptInUse", "claude", "rt-a", "s2");
  await p.c("transcriptInUse", "codex", "th-2", "s1");
  await p.c("transcriptInUse", "codex", "th-2", "s2");
  await p.c("followProfiles", "s1", [["p3", "q3"], ["p6", "q6"]]);
  await p.c("followProfiles", "s1", [["zz", "q"]]);
  await p.c("followProfiles", "s1", [["p7", "q7"]]);
  await p.c("followProfiles", "none", [["p7", "q7"]]);
  await p.c("setSessionModel", "s2", "gpt-5", "high");
  await p.c("setSessionFast", "s2", null);
  await p.c("setSessionFast", "s2", true);
  await p.c("setSessionContext", "s2", 300000);
  await p.c("setSessionContextBefore", "s2", 0);
  await p.c("setSessionAfresh", "s2", false);
  await p.c("setSessionAfresh", "s2", null);
  await p.c("setSessionSpeed", "s2", "ultrafast");
  await p.c("codexSessionSpeed", "th-2");
  await p.c("codexSessionFast", "th-2");
  await p.c("setSessionSpeed", "s2", "standard");
  await p.c("codexSessionFast", "th-2");
  await p.c("setSessionSpeed", "s2", null);
  await p.c("codexSessionSpeed", "th-2");
  await p.c("codexSessionFast", "th-2");
  await p.c("codexSessionFast", "none");
  await p.c("setTitle", "s2", "two");
  await p.c("setTitle", "s2", null);
  await p.c("setTranscriptLength", "s1", 12);
  await p.c("setTranscriptLengths", [["s1", 14], ["s2", 3]]);
  await p.c("setTranscriptLengths", []);
  await p.c("sessionUsage", "s1");
  await p.c("setSessionUsage", "s1", { modelCalls: 0, b: 2, "10": 1, a: [1.5, null] });
  await p.c("setSessionUsage", "s1", { modelCalls: 0, b: 2, "10": 1, a: [1.5, null] });
  await p.c("setSessionUsage", "s2", { modelCalls: 1 });
  await p.c("setSessionUsage", "s3", { modelCalls: 2 }, true);
  await p.c("setSessionUsage", "none", { modelCalls: 2 });
  await p.c("sessionUsage", "s1");
  await p.c("putDeviceBuild", "dev-1", 9100, 1_799_000_000);
  await p.c("putDeviceBuild", "dev-1", 9200, 1_799_000_100);
  await p.c("putDeviceBuild", "dev-2", -1, 1_799_000_200);
  await p.c("deviceBuilds");
  await p.c("modelStars", "w1", "ann");
  await p.c("putModelStars", "w1", "ann", '["a","b"]');
  await p.c("modelStars", "w1", "ann");
  // (#6960) the first write waits for no other writer: refused at once while another connection holds the lock, read
  // without the lock once it is kept
  const holders = ["a", "b"].map((side) => new DatabaseSync(join(p.dir, side, "stillfail.db")));
  for (const h of holders) h.exec("BEGIN IMMEDIATE");
  assert.deepEqual(await p.c("deviceBuildsSince", 3), { error: "device builds write is busy", data: null });
  for (const h of holders) h.exec("ROLLBACK");
  await p.c("deviceBuildsSince", 5);
  for (const h of holders) h.exec("BEGIN IMMEDIATE");
  assert.equal(await p.c("deviceBuildsSince", 9), 5);
  for (const h of holders) { h.exec("ROLLBACK"); h.close(); }
  // (a session's workspace kept in memory: forgotten as all of its workspace move)
  await p.c("setSessionsWs", null, "home");
  for (const k of ["s1", "s2", "s4"]) await p.c("sessionWs", k);
  assert.equal(await p.c("sessionWs", "s1"), "home");
  await p.c("setSessionsWs", "w1", "w2");
  await p.c("setSessionsWs", "w9", "w2");
  await p.c("setSessionsWs", "w2", "w2");
  for (const k of ["s1", "s2", "s3"]) await p.c("sessionWs", k);
  assert.equal(await p.c("sessionWs", "s2"), "w2");
  await p.c("sessionCounts", null);
  await p.c("sessionCounts", { workspace: "w2" });
  await p.c("sessionCounts", { workspace: "w2", home: false });
  await p.c("overviewSessionCounts", { workspace: "w2" }, ["ember", "slack-1", "ember", 7, "none"]);
  await p.c("overviewSessionCounts", { workspace: "home", home: false }, ["ember"]);
  p.both((s) => s.db.exec("UPDATE session_count_meta SET complete = 0"));
  assert.equal((await p.c("sessionCounts", null)).error, "session counts are not ready");
  await p.c("overviewSessionCounts", { workspace: "w2" }, ["ember"]);
  p.both((s) => s.db.exec("UPDATE session_count_meta SET complete = 1"));
  // (opened chats, and a chat its opener leads: its opener told as it is archived)
  p.now += 1000;
  await p.c("insertOpened", { childStation: "", child: "s3", parentStation: "", parent: "s1", key: "k1", title: "three", link: null, openerTitle: "one", led: true });
  await p.c("insertOpened", { childStation: "far", child: "f1", parentStation: "", parent: "s1", key: "k2", title: "far", link: "https://x", led: null });
  await p.c("insertOpened", { childStation: "", child: "s4", parentStation: "other", parent: "o1", key: "k3", title: null, link: null, led: false });
  await p.c("openedWith", "", "s1", "k1", "");
  await p.c("openedWith", "", "s1", "k9", "");
  await p.c("openerOf", "s3");
  await p.c("openerOf", "s4");
  await p.c("openerOf", "s1");
  await p.c("openedBy", "s1");
  await p.c("setOpenedState", "", "s3", "all_done");
  await p.c("setOpenedState", "far", "f1", "waiting");
  await p.c("setOpenedState", "", "s4", "need_human");
  await p.c("effortsUsedBy", "ann", "claude", "opus", 0);
  await p.c("effortsUsedBy", "ann", "claude", null, 0);
  await p.c("modelsUsedBy", "ann", 0);
  await p.c("modelsUsedBy", "bob", 1_799_500_000_000);
  // (archived and shown again, with their chats and their leaders)
  const home = p.both((s) => s.openThreadOf("ember", "ember", "h-s3", null, null, "s3"));
  p.both((s) => s.joinThread(home.id, "s3", "ember"));
  const other = p.both((s) => s.openThread("slack:T1", "C1", "171.1", null, "bob"));
  p.both((s) => { s.joinThread(other.id, "s3", "slack-1"); s.joinThread(other.id, "s4", "slack-1"); });
  p.now += 1000;
  await p.c("setArchived", "s3", true, rows.MANUAL);
  assert.ok(p.lastTold.some((c) => c.type === "session" && c.key === "s1"), "its leader told");
  await p.c("manuallyArchived", home.id);
  await p.c("manuallyArchived", other.id);
  p.now += 1000;
  await p.c("setArchived", "s4", true, rows.AUTO);
  await p.c("manuallyArchived", other.id);
  await p.c("manuallyArchived", 999);
  await p.c("archivedSessions", null, null);
  await p.c("archivedSessions", null, p.now - 1000);
  await p.c("archivedSessions", { key: "s3", archivedAt: p.now - 1000 }, null);
  await p.c("archivedSessions", null, { key: "s3", archivedAt: p.now - 1000 });
  await p.c("lastArchivedSession");
  await p.c("nextArchivedAt", 0);
  await p.c("nextArchivedAt", p.now);
  await p.c("liveSessions");
  p.now += 1000;
  await p.c("setArchived", "s3", false, rows.MANUAL);
  await p.c("setArchived", "s4", false, rows.AUTO);
  await p.c("setArchived", "none", true, rows.AUTO);
  await p.c("lastArchivedSession");
  await p.c("homeChat", "s3");
  await p.c("homeChat", "s1");
  await p.c("chatsOfTheirOwn");
  p.same("sessions");
}));

test("chats: hidden, named, their posts, their shares and bindings, and a session forgotten whole", () => withPair(async (p) => {
  await p.c("insertSession", session("a1", { createdBy: "ann" }));
  await p.c("insertSession", session("a2", { createdBy: "ann" }));
  const own = p.both((s) => s.openThread("ember", "ember", "own-1", null, "ann"));
  const shared = p.both((s) => s.openThread("slack:T1", "C1", "1.0", "shared", null));
  const only = p.both((s) => s.openThread("slack:T1", "C1", "2.0", null, null));
  p.both((s) => {
    s.joinThread(own.id, "a1", "ember");
    s.joinThread(shared.id, "a1", "slack-1");
    s.joinThread(shared.id, "a2", "slack-1");
    s.joinThread(only.id, "a1", "slack-1");
  });
  for (let i = 1; i <= 140; i++) {
    p.now += 10;
    p.both((s) => s.insertMessage({ thread: own.id, ts: `m${i}`, authorKind: i % 3 === 0 ? "agent" : "person", author: i % 3 === 0 ? (i % 2 ? "a1" : "a2") : "ann", text: `said ${i}` }));
  }
  p.both((s) => { s.insertMessage({ thread: only.id, ts: "o1", authorKind: "person", author: "U1", text: "only" }); s.setRead("ann", own.id, 30); s.setRead("bob", only.id, 1); });
  await p.c("setThreadHidden", own.id, true, rows.MANUAL);
  await p.c("manuallyArchived", own.id);
  p.now += 1000;
  await p.c("setThreadHidden", own.id, false, rows.AUTO);
  await p.c("setThreadHidden", own.id, true, rows.AUTO);
  await p.c("setThreadHidden", own.id, false, rows.MANUAL);
  await p.c("chatsOfTheirOwn");
  await p.c("titleRevision", own.id);
  await p.c("setThreadTitle", own.id, "named");
  await p.c("titleRevision", own.id);
  await p.c("retitled", own.id);
  await p.c("titleRevision", own.id);
  await p.c("setThreadTitle", own.id, null);
  await p.c("autoTitle", own.id);
  await p.c("autoTitle", 999);
  await p.c("setAutoTitle", own.id, "first", false);
  await p.c("setAutoTitle", own.id, "second", true);
  await p.c("setGeneratedTitle", own.id, "made");
  await p.c("autoTitle", own.id);
  await p.c("peopleSaidAfter", own.id, 0, 5);
  await p.c("peopleSaidAfter", own.id, 100, 1000);
  await p.c("peopleSaidAfter", own.id, 0, -3.7);
  await p.c("postAfter", "a1", own.id, 0);
  await p.c("postAfter", "a2", own.id, 0);
  await p.c("postAfter", "a1", own.id, 130);
  await p.c("postAfter", "a1", own.id, 140);
  await p.c("postsAfter", "a1", [{ thread: own.id, n: 5 }, { thread: own.id, n: 1 }, { thread: own.id, n: 70 }, { thread: only.id, n: 0 }, { thread: own.id, n: 2 }]);
  await p.c("postsAfter", "a2", []);
  // (a thread whose posts are not prepared: the program says so as the TypeScript throws it)
  p.both((s) => s.db.exec("UPDATE post_blocks_meta SET fresh = 0; DELETE FROM post_blocks_coverage"));
  assert.equal((await p.c("postAfter", "a1", own.id, 4)).error, "post block history not ready");
  await p.c("postAfter", "a1", own.id, 3);
  await p.c("postsAfter", "a1", [{ thread: own.id, n: 4 }, { thread: own.id, n: 3 }, { thread: own.id, n: 2 }]);
  await p.c("lastReadAt", own.id);
  await p.c("lastReadAt", 999);
  // ── shared with other workspaces ──
  await p.c("chatShare", "a1");
  await p.c("setChatShare", "a1", [{ workspace: "wx", name: "X" }, { workspace: "wy", name: "Y" }], true, "ann");
  await p.c("setChatShare", "a2", [{ workspace: "wy", name: "Y" }], false, "bob");
  await p.c("chatShare", "a1");
  await p.c("chatShares");
  await p.c("chatShareLapsed", "a1", null);
  await p.c("lapsedShareWorkspaces", null);
  p.now += 30_000;
  await p.c("usedChatShare", "a1", ["wx"]);
  p.now += 61_000;
  await p.c("usedChatShare", "a1", ["wx", "wz"]);
  await p.c("usedChatShare", "none", ["wx"]);
  const since = p.now;
  p.now += 6 * HOUR - 50_000;
  assert.equal(typeof await p.c("lapseChatShares", since), "number");
  assert.ok(p.lastTold.some((c) => c.type === "chatMark"), "a share lapsed is told");
  await p.c("chatShareLapsed", "a1", ["wy"]);
  await p.c("chatShareLapsed", "a1", ["wx"]);
  await p.c("chatShares");
  await p.c("lapsedShareWorkspaces", ["wy", "wx", "wq"]);
  await p.c("lapsedShareWorkspaces", null);
  p.now += 60_000;
  await p.c("lapseChatShares", since);
  await p.c("chatShare", "a1");
  // (by the index of their deadlines, once it is prepared)
  p.both((s) => { installChatShareIndex(s.db); while (!chatShareIndexReady(s.db)) chatShareIndexStep(s.db, 64); });
  await p.c("refreshChatShareIndex");
  await p.c("chatShares");
  await p.c("lapsedShareWorkspaces", ["wy", "wx"]);
  await p.c("lapseChatShares", since);
  p.now += 7 * HOUR;
  await p.c("lapseChatShares", p.now - HOUR);
  await p.c("setChatShare", "a2", [], false, "bob");
  await p.c("chatShare", "a2");
  // ── single-session bindings ──
  await p.c("binding", "c1");
  await p.c("setBinding", "c1", "a2");
  await p.c("setBinding", "c2", "a2");
  await p.c("setBinding", "c3", "a1");
  await p.c("setBinding", "c1", "a1");
  await p.c("setBinding", "c3", null);
  await p.c("binding", "c1");
  await p.c("listBindings");
  await p.c("preparedSessionBound", "a1");
  await p.c("preparedSessionBound", "zz");
  // ── a session forgotten: its rows, the threads only it took part in, what kept it in memory ──
  p.both((s) => {
    s.startTurn("t-a1", "a1", "input");
    s.deliver(shared.id, 1, ["a1"]);
    s.insertJob({ id: "j-a1", sessionKey: "a1", name: "build", command: "make", cwd: "/w", port: null, token: "jt", state: "running", pgid: 9, exitCode: null, startedAt: 1, endedAt: null, restarts: 0, log: "/l", watch: false });
    s.addJobNotice("j-a1", "hi");
    s.putWidgetState("a1", "/w/x.html", "{}", "m");
    s.setPin("ann", "a1", true);
    s.setChatHidden("ann", only.id, true);
    s.setChatMuted("ann", only.id, true);
    s.keepChat("ann", only.id);
    s.setTranscriptLength("a1", 3);
  });
  await p.c("sessionKeyByToken", "tok-a1");
  await p.c("sessionWs", "a1");
  await p.c("deleteSession", "a1");
  assert.deepEqual(p.lastTold.map((c) => c.type), ["sessionRemoved", "threadRemoved", "threadRemoved", "thread"]);
  assert.equal(await p.c("sessionKeyByToken", "tok-a1"), null);
  await p.c("sessionWs", "a1");
  await p.c("getSession", "a1");
  await p.c("deleteSession", "a1");
  await p.c("listBindings");
  p.same("chats");
}));

test("turns, identities, profiles, processes, jobs and widgets", () => withPair(async (p) => {
  await p.c("insertSession", session("t1", { title: "first" }));
  await p.c("insertSession", session("t2"));
  const chat = p.both((s) => s.openThread("ember", "ember", "c-1", null, null));
  p.both((s) => { s.joinThread(chat.id, "t1", "ember"); s.joinThread(chat.id, "t2", "ember"); });
  const [card] = p.both((s) => s.insertMessage({ thread: chat.id, ts: "q1", authorKind: "agent", author: "t1", text: "pick", card: { type: "options", options: [{ label: "yes", action: "close" }] } }));
  await p.c("slackIdentities", "ann");
  await p.c("setSlackIdentity", "ann", "U1", true);
  p.now += 1;
  await p.c("setSlackIdentity", "ann", "U2", true);
  await p.c("setSlackIdentity", "ann", "U1", true);
  await p.c("slackIdentities", "ann");
  await p.c("setSlackIdentity", "ann", "U1", false);
  await p.c("hasTurns", "t1");
  await p.c("toldNotes", "t1");
  await p.c("toldNotes", "none");
  await p.c("setToldNotes", "t1", 3);
  await p.c("toldNotes", "t1");
  await p.c("lastTurn", "t1");
  await p.c("latestTurn", "t1");
  await p.c("workOf", "t1");
  await p.c("workOf", "none");
  p.now += 1000;
  await p.c("startTurnFor", "u1", "t1", "input", { profile: "p1", person: "ann", thread: chat.id });
  p.now += 1000;
  await p.c("startTurn", "u2", "t1", "follow");
  await p.c("hasTurns", "t1");
  await p.c("setWaitFor", "u2", "CI", true);
  await p.c("setAbout", "u2", [chat.id, card, "q1"]);
  await p.c("setNeed", "u2", "a choice");
  await p.c("declareTurn", "u2", "need_human", null);
  await p.c("lastTurn", "t1");
  // (a card closed while the turn ran: the turn that asks of it ends final)
  p.both((s) => s.db.prepare("INSERT INTO closed_cards (thread, n, viewer, at) VALUES (?, ?, 'ann', ?)").run(chat.id, card, p.now));
  p.now += 1000;
  await p.c("endTurn", "u2", "completed", null, "need_human", null);
  assert.equal((await p.c("latestTurn", "t1")).summary.declared, "final");
  await p.c("endTurn", "nope", "completed", null, null, null);
  p.now += 1000;
  await p.c("startTurn", "u3", "t1", "input");
  await p.c("declareTurn", "u3", "waiting", 600);
  p.now += 1000;
  await p.c("endTurn", "u3", "completed", null, "waiting", 600);
  await p.c("recoveryWaits");
  await p.c("awakeWait", p.now, 0);
  await p.c("awakeWait", p.now + 700_000, 0);
  await p.c("awakeWait", p.now + 700_000, 200_000);
  await p.c("awakeWait", 0.5, 0);
  p.both((s) => s.db.exec("UPDATE session_awake_wait_meta SET complete = 0"));
  await p.c("awakeWait", p.now, 0);
  await p.c("awakeWait", p.now + 700_000, 0);
  p.both((s) => s.db.exec("UPDATE session_awake_wait_meta SET complete = 1"));
  await p.c("forgetWait", "t1");
  await p.c("stopWait", "t1", false);
  await p.c("lastTurn", "t1");
  p.now += 1000;
  await p.c("startTurn", "u4", "t1", "input");
  p.now += 1000;
  await p.c("endTurn", "u4", "failed", "rate_limit: slow down", null, null);
  await p.c("recoveryWaits");
  await p.c("stopWait", "t1", false);
  await p.c("stopWait", "t1", true);
  p.now += 1000;
  await p.c("startTurn", "u5", "t1", "input");
  await p.c("declareTurn", "u5", "waiting", 60);
  p.now += 1000;
  await p.c("endTurn", "u5", "aborted", null, "waiting", 60);
  await p.c("forgetWait", "t1");
  await p.c("forgetWait", "t1");
  // (cut off by a restart: the one asking of a closed card ends final, a wait ends as nothing)
  p.now += 1000;
  await p.c("startTurn", "u6", "t2", "input");
  await p.c("setAbout", "u6", [chat.id, card, "q1"]);
  await p.c("declareTurn", "u6", "block", null);
  p.now += 1;
  await p.c("startTurn", "u7", "t2", "input");
  await p.c("declareTurn", "u7", "waiting", 30);
  p.now += 1000;
  assert.equal(await p.c("endCutOff", "t2"), 2);
  assert.equal(await p.c("endCutOff", "t2"), 0);
  await p.c("listTurns", "t2");
  await p.c("listTurns", "t1");
  await p.c("failedTurnsNear", "t1", 0, p.now, p.now - 5000);
  await p.c("lastTurnsOf", ["t1", "t2", "t1", "none"]);
  await p.c("statsOf", ["t2", "t1", "none"]);
  await p.c("sessionStats", null);
  await p.c("sessionStats", "t1");
  p.now += 1000;
  await p.c("startTurn", "u8", "t2", "input");
  p.now += 1000;
  await p.c("endTurn", "u8", "completed", null, "need_human", null);
  await p.c("setNeed", "u8", "your call");
  await p.c("waitingForPeople", 0, 10);
  await p.c("slackStop", "t1", "c1", "C1", "1.0");
  await p.c("rememberSlackStop", "t1", "c1", "C1", "1.0", "9.9", "u8");
  await p.c("rememberSlackStop", "t1", "c1", "C1", "1.0", "9.10", null);
  await p.c("slackStop", "t1", "c1", "C1", "1.0");
  // ── profiles ──
  await p.c("profileStatus");
  await p.c("setProfileCheck", "p1", { ok: true, checkedAt: 5 });
  await p.c("setProfileCheck", "p2", { ok: false, checkedAt: 5.5 });
  const quota = (at: number, used: number) => ({ state: "ok", checkedAt: at, windows: [{ label: "5h", usedPercent: used, resetsAt: at + HOUR, minutes: 300 }, { label: "bad" }], scoped: [{ label: "opus", scope: "opus", usedPercent: used / 2 }, { scope: "", usedPercent: 1, resetsAt: Infinity }] });
  const h0 = Math.floor(p.now / HOUR);
  for (const back of [300, 200, 3, 2, 1, 0]) await p.c("setProfileQuota", "p1", quota((h0 - back) * HOUR + 1000, 10 + back));
  await p.c("setProfileQuota", "p1", quota(h0 * HOUR + 5000, 99));
  await p.c("setProfileQuota", "p2", { state: "error", checkedAt: p.now });
  await p.c("setProfileQuota", "p3", { state: "ok" });
  await p.c("profileStatus");
  assert.equal((await p.c("profileHours", h0)).quotas.length, 4, "those PACE_HOURS before let go as each is written");
  await p.c("profileHours", h0 - 500);
  await p.c("forgetProfileHours", "p1");
  await p.c("profileHours", h0);
  // ── process groups ──
  await p.c("recordProcess", 101, 5, "claude", "t1");
  await p.c("recordProcess", 101, 6, "claude", "t1 again");
  await p.c("recordProcess", 102, 7, "codex", "app");
  await p.c("listProcesses");
  await p.c("processByGroup", 101);
  await p.c("processByGroup", 999);
  await p.c("forgetProcess", 101);
  await p.c("forgetProcess", 101);
  // ── jobs ──
  const job = (id: string, more: Record<string, unknown>) => ({ id, sessionKey: "t1", name: id, command: "run", cwd: "/w", port: null, token: `jt-${id}`, state: "running", pgid: null, exitCode: null, startedAt: p.now, endedAt: null, restarts: 0, log: `/logs/${id}`, watch: false, ...more });
  p.now += 1;
  await p.c("insertJob", job("j1", { watch: true }));
  p.now += 1;
  await p.c("insertJob", job("j2", { port: 8080, screen: true }));
  p.now += 1;
  await p.c("insertJob", job("remote_j3", { sessionKey: "t2", queued: true, small: true }));
  p.now += 1;
  await p.c("insertJob", job("j4", { sessionKey: "t2", sandbox: { name: "box", place: "eu" } }));
  await p.c("jobStarted", "j1", 4242, false);
  await p.c("jobStarted", "j2", 4243, true);
  await p.c("jobStarted", "nope", 1, true);
  // one that waited in the queue started when it left it; one that did not, and one started again, keep theirs
  await p.c("insertJob", job("remote_j5", { sessionKey: "t2", queued: true }));
  const queuedAt = p.now;
  p.now += 60_000;
  await p.c("jobStarted", "remote_j5", 4244, false);
  const started = await p.c("getJob", "remote_j5");
  assert.equal(started.startedAt, p.now);
  assert.equal(started.queued, undefined);
  assert.equal((await p.c("getJob", "j1")).startedAt, queuedAt - 3);
  p.now += 1;
  await p.c("jobStarted", "remote_j5", 4245, true);
  assert.equal((await p.c("getJob", "remote_j5")).startedAt, p.now - 1);
  await p.c("getJob", "j4");
  await p.c("getJob", "none");
  await p.c("jobByToken", "jt-j2");
  await p.c("jobsUp");
  await p.c("jobsUpOf", ["t1", "t2", "none"]);
  await p.c("liveSessionsOn", "p1", 10);
  await p.c("jobsMarkOf", ["t1", "t2", "none"]);
  await p.c("jobsMarkOf", []);
  await p.c("jobAtPort", 8080);
  await p.c("listJobs", null);
  await p.c("listJobs", "t2");
  await p.c("jobsRunning");
  await p.c("remoteQueueJobs");
  await p.c("awakeJobs");
  await p.c("runningJobsAtLeast", "t1", 2);
  await p.c("runningJobsAtLeast", "t1", 3);
  await p.c("runningJobsAtLeast", "t1", 0);
  await p.c("runningJobSessions", ["t1", "t2", "none"]);
  await p.c("runningJobSessions", []);
  await p.c("runningWaitJobIds", "t1");
  await p.c("upJobIds", "t1");
  await p.c("upJobIds", "t1", true);
  await p.c("sessionHasUpJob", "t2");
  await p.c("runningJobs");
  for (let i = 0; i < 53; i++) { p.now += 1; await p.c("addJobNotice", "j1", `note ${i}`); }
  await p.c("addJobNotice", "none", "x");
  await p.c("jobNotices", "j1", 5);
  p.now += 1;
  await p.c("jobEnded", "j1", "exited", 0);
  await p.c("jobEnded", "j2", "exited", 1);
  await p.c("jobEnded", "j4", "failed", null);
  await p.c("jobAtPort", 8080);
  await p.c("jobsUp");
  await p.c("clearEndedJobs", "t1");
  await p.c("clearEndedJobs", "t2");
  await p.c("clearEndedJobs", "t2");
  await p.c("noteRemoteRun", "remote_j3", "remote:x", p.now);
  await p.c("noteRemoteRun", "remote_old", "remote:x", p.now - 100 * 24 * HOUR);
  await p.c("noteRemoteRun", "remote_j9", "remote:y", p.now);
  // ── widgets ──
  p.both((s) => s.insertMessage({ thread: chat.id, ts: "w1", authorKind: "agent", author: "t1", text: "widget", attachments: [{ name: "Chart", path: "/w/chart.html", size: 3 }] }));
  await p.c("widgetState", "t1", "/w/chart.html");
  await p.c("putWidgetState", "t1", "/w/chart.html", '{"a":1}', "m1");
  p.now += 1;
  await p.c("putWidgetState", "t1", "/w/other.html", '{"b":1}', "m2");
  await p.c("putWidgetState", "t1", "/w/none.html", "{}", null);
  await p.c("widgetState", "t1", "/w/chart.html");
  assert.equal((await p.c("untoldWidgetModels", "t1")).error, "widget sources are still being prepared");
  // (its threads' sources prepared, as the station's builder does)
  p.both((s) => { while (!widgetSourcesStep(s.db, chat.id).done); });
  const untold = await p.c("untoldWidgetModels", "t1");
  assert.equal(untold[0]?.thread?.[1], "c-1", JSON.stringify(untold));
  await p.c("untoldWidgetModels", "t2");
  await p.c("markWidgetModelsTold", "t1", [["/w/chart.html", "m1"], ["/w/other.html", "old"]]);
  await p.c("untoldWidgetModels", "t1");
  p.now += 1;
  await p.c("putWidgetState", "t1", "/w/chart.html", '{"a":2}', "m1");
  await p.c("putWidgetState", "t1", "/w/other.html", '{"b":2}', "m3");
  await p.c("untoldWidgetModels", "t1");
  p.both((s) => s.db.exec("UPDATE widget_source_scopes SET complete = 0"));
  assert.equal((await p.c("untoldWidgetModels", "t1")).error, "widget sources are still being prepared");
  // (and what the store tells for what changes outside it)
  await p.c("notify", "t1");
  await p.c("told", [{ type: "read", viewer: "ann", thread: chat.id, n: 1 }, { type: "processes" }]);
  p.same("turns and jobs");
}));

for (const compact of [false, true]) test(`usage${compact ? ", its contexts kept" : ""}: calls across quarters, a session's compacted context, the counter's files, and what is read of them`, () => withPair(async (p) => {
  // (a station's contexts kept once the station before has gone: usage/module.ts)
  if (compact) p.both((s) => installCompactUsage(s.db));
  await p.c("insertSession", session("u1", { createdBy: "ann" }));
  await p.c("insertSession", session("u2", { ws: "w1" }));
  const chat = p.both((s) => s.openThread("ember", "ember", "u-chat", null, "ann"));
  p.both((s) => { s.joinThread(chat.id, "u1", "ember"); s.insertMessage({ thread: chat.id, ts: "p1", authorKind: "person", author: "ann", text: "begin ".repeat(80) }); });
  p.now += 1000;
  await p.c("ranIn", "u1", "rt-1", "p1");
  await p.c("setRuntimeSessionId", "u1", "rt-1");
  p.now += 1000;
  await p.c("startTurnFor", "ut1", "u1", "input", { profile: "p1", person: null, thread: null });
  await p.c("usageCounter");
  await p.c("advanceUsageCounter", p.now - 5);
  await p.c("advanceUsageCounter", 1);
  await p.c("usageCounter");
  await p.c("usageCounterFile", "/t/a.jsonl");
  const file = (session: string | null, offset: number) => ({ session, offset, model: "opus" });
  await p.c("beginUsageCounterFile", "/t/a.jsonl", file("u1", 0), { cutoff: p.now, anchor: null }, false);
  await p.c("beginUsageCounterFile", "/t/a.jsonl", file("u1", 10), { cutoff: p.now + 1, anchor: "xx" }, false);
  await p.c("beginUsageCounterFile", "/t/b.jsonl", file("u2", 0), { cutoff: p.now, anchor: "yy" }, true);
  await p.c("usageCounterFile", "/t/a.jsonl");
  const Q = 900_000;
  const base = Math.floor(p.now / Q) * Q;
  const call = (id: string, at: number, more: Record<string, unknown> = {}) => [{
    id, at, model: "opus", subagent: false, fast: false, input: 100, cacheRead: 1000, cacheWrite: 50, cacheWriteLong: 5, output: 20,
    calls: 1, context: 80_000, window: 200_000, ...more,
  }, { turn: "ut1", person: "ann", thread: chat.id, profile: "p1" }];
  await p.c("recordUsage", "/t/a.jsonl", file("u1", 100), "claude", [call("c1", base + 1000), call("c2", base + Q - 1), call("c3", base + Q + 5, { context: 90_000 })]);
  await p.c("recordUsage", "/t/a.jsonl", file("u1", 120), "claude", [call("c3", base + Q + 5, { output: 10 }), call("c3", base + Q + 5, { output: 40 })], { changed: { from: Number.MAX_SAFE_INTEGER } });
  await p.c("lastContexts", "u1", 5);
  await p.c("recentlyCompacted", "u1");
  // (a context that falls under half of what the call before sent, on its account and model: compacted)
  p.now += 1000;
  await p.c("startTurnFor", "ut2", "u1", "input", { profile: "p1", person: null, thread: null });
  await p.c("recordUsageAll", [
    { path: "/t/a.jsonl", file: file("u1", 200), runtime: "claude", calls: [call("c4", base + 2 * Q + 7, { context: 20_000 }), call("c5", base + 2 * Q + 9, { subagent: true, context: null })], options: { changed: { from: Number.MAX_SAFE_INTEGER }, counter: { cutoff: base, anchor: "zz" } } },
    { path: "/t/b.jsonl", file: file("u2", 50), runtime: "codex", calls: [call("d1", base + 3 * Q + 1, { model: "gpt", fast: true }), call("d0", base - 10, { model: "gpt" })], options: { minNewAt: base } },
    { path: "/t/c.jsonl", file: file(null, 9), runtime: "codex", calls: [call("x1", base)] },
  ]);
  await p.c("recordUsageAll", []);
  await p.c("lastContexts", "u1", 3);
  await p.c("lastContexts", "u1", 0);
  await p.c("lastContexts", "u2", 5);
  assert.equal(await p.c("recentlyCompacted", "u1"), compact);
  await p.c("savedCompactContext", "u1");
  await p.c("compactionPoints", 0);
  await p.c("compactionsReady");
  await p.c("usageFiles");
  await p.c("usageFile", "/t/a.jsonl");
  await p.c("usageFile", "/t/none.jsonl");
  await p.c("usageChanged", ["u1", "u2"]);
  await p.c("usageChanged", ["u1"], base, true);
  await p.c("usageActiveSessions", 0);
  await p.c("usageActiveSessions", p.now + 1);
  await p.c("usageTurns", "u1", base, base + 4 * Q);
  await p.c("usageTurns", "u1", 0, 1);
  await p.c("usageTurns", "u2", 0, p.now);
  await p.c("usageTurns", "none", 0, p.now);
  for (const offset of [0, 330, -480, 7]) await p.c("usageGroups", base - Q, base + 4 * Q, offset);
  await p.c("usageGroups", base + 500, base + 600, 0);
  await p.c("usageGroups", base + 600, base + 500, 0);
  await p.c("usageGroups", base, Number.MAX_SAFE_INTEGER, 0);
  await p.c("usageOfSession", "u1");
  await p.c("usageOfSession", "none");
  await p.c("usageThreads", [chat.id, 999]);
  await p.c("firstText", chat.id);
  await p.c("usageSince");
  await p.c("profileHours", Math.floor(p.now / HOUR) + 1);
  // (a session's usage as its summary says it: where its contexts were not kept when it was written, the context is
  // seeded from it as they come to be, then kept on)
  await p.c("insertSession", session("u3"));
  await p.c("ranIn", "u3", "rt-3", "p1");
  await p.c("setRuntimeSessionId", "u3", "rt-3");
  p.now += 1000;
  await p.c("recordUsage", "/t/u3.jsonl", file("u3", 1), "claude", [call("e1", p.now)]);
  if (!compact) p.both((s) => installCompactUsage(s.db));
  await p.c("setSessionUsage", "u3", { modelCalls: 1, lastCallAt: p.now, model: "opus", contextWindow: 200000, contextTokens: 5, cacheMs: 1 });
  p.now += 1000;
  await p.c("recordUsage", "/t/u3.jsonl", file("u3", 2), "claude", [call("e0", p.now - 5000), call("e2", p.now)]);
  assert.equal(await p.c("savedCompactContext", "u3") !== null, !compact, "seeded from its summary");
  await p.c("lastContexts", "u3", 5);
  await p.c("recentlyCompacted", "u3");
  p.same("usage");
}));

test("a chat handed over: its rows paged, put in, shown, handed on, dropped where its hand-over failed", () => withPair(async (p) => {
  // (the station it comes from, as the TypeScript writes it, and the program reading it)
  const fromDir = mkdtempSync(join(tmpdir(), "mb-store-sessions-from-"));
  const from = Store.open(join(fromDir, "stillfail.db"), join(fromDir, "archive"), p.clock);
  const fromMb = new MbProcess(binary!, ["--builder", "harness-store-sessions", "--db", join(fromDir, "stillfail.db")]);
  try {
    from.insertSession(session("h1", { connect: "conn-there", profile: "pt", profiles: ["pt", "pu"], workspace: "/there/rooms/h1", cwd: "/there/rooms/h1/src" }));
    from.insertSession(session("h2", { connect: "conn-there", profile: "pt" }));
    const t1 = from.openThreadOf("ember", "ember", "chat-1", "handed", null, "h1");
    const t2 = from.openThread("feishu:conn-there", "oc_1", "om_1", null, null);
    from.joinThread(t1.id, "h1", "ember");
    from.joinThread(t2.id, "h1", "conn-there");
    from.joinThread(t2.id, "h2", "conn-there");
    for (let i = 1; i <= 7; i++) {
      p.now += 10;
      from.insertMessage({ thread: t1.id, ts: `e${i}`, authorKind: i % 2 ? "person" : "agent", author: i % 2 ? "ann" : "h1", text: `t1 ${i}`, attachments: i === 3 ? [{ name: "f", path: "/there/rooms/h1/f.png", size: 1 }] : [] });
      from.insertMessage({ thread: t2.id, ts: `f${i}`, authorKind: "person", author: "U9", text: `t2 ${i}` });
    }
    from.editMessage("ember", "ember", "chat-1", "e1", "t1 1 edited");
    from.insertLetter({ thread: t1.id, ts: "L1", authorKind: "agent", author: "x", text: "来自 x", letter: { way: "in", title: "x", link: null } });
    from.startTurnFor("ht1", "h1", "input", { profile: "pt", person: "ann", thread: t1.id });
    from.setAbout("ht1", [t1.id, 2, "e2"]);
    from.endTurn("ht1", "completed", null, "all_done", null);
    from.ranIn("h1", "rt-h1", "pt");
    from.db.prepare("INSERT INTO closed_cards (thread, n, viewer, at) VALUES (?, 2, 'ann', 1)").run(t1.id);
    from.setRead("ann", t1.id, 5);
    from.setChatHidden("bob", t2.id, true);
    from.setChatMuted("bob", t2.id, true);
    from.keepChat("ann", t1.id);
    from.dismiss("ann", t1.id, 2);
    from.setPin("ann", "h1", true);
    from.insertOpened({ childStation: "", child: "h1", parentStation: "", parent: "boss", key: "kk", title: "h1", link: null, led: true });
    from.deliver(t2.id, 7, ["h1"]);
    from.recordUsage("/there/t/h1.jsonl", { session: "h1", offset: 30, model: "opus" }, "claude", [[{ id: "hu1", at: p.now, model: "opus", subagent: false, fast: false, input: 1, cacheRead: 2, cacheWrite: 3, cacheWriteLong: 4, output: 5, calls: 1, context: 9, window: 10 }, { turn: "ht1", person: "ann", thread: t1.id, profile: "pt" }]]);
    from.setSessionUsage("h1", { modelCalls: 1 });
    // (this station's own, met by the chat put in: a still.fail chat of another's home of the same ts, a platform's thread
    // both followed, a session there before)
    const mine = p.both((s) => s.openThreadOf("ember", "ember", "chat-1", null, null, "someone"));
    const met = p.both((s) => s.openThread("feishu:conn-here", "oc_1", "om_1", null, null));
    p.both((s) => s.insertMessage({ thread: met.id, ts: "f2", authorKind: "person", author: "U9", text: "t2 2" }));
    await p.c("insertSession", session("h2", { connect: "conn-here", title: "already here" }));
    p.both((s) => s.joinThread(mine.id, "h2", "ember"));
    // (paged on the station it leaves: the program pages it as the TypeScript does)
    const ask = async (call: string, args: unknown[]) => {
      const answered = new Promise<Answer>((resolve) => fromMb.once("message", resolve as never));
      fromMb.postMessage({ id: 1, now: p.now, call, args });
      return answered;
    };
    const pages: [handover.ChatTable, number | string, unknown[]][] = [];
    const keys = ["h1", "h2"];
    const threads = from.chatThreads(keys, 0);
    assert.deepEqual((await ask("chatThreads", [keys, 0])).result, threads);
    assert.deepEqual((await ask("chatThreads", [keys, threads[0], 1])).result, from.chatThreads(keys, threads[0]!, 1));
    const page = async (table: handover.ChatTable, of: number | string, limit = 3) => {
      let after: unknown = null;
      for (;;) {
        const rowsTs = from.chatPage(table, of, after, limit, keys);
        assert.deepEqual((await ask("chatPage", [table, of, after, limit, keys])).result, said(rowsTs), `${table} of ${of} after ${JSON.stringify(after)}`);
        if (rowsTs.length === 0) break;
        pages.push([table, of, rowsTs]);
        const next = handover.afterOf(table, rowsTs.at(-1)!);
        await p.c("handover.afterOf", table, rowsTs.at(-1));
        if (next === null || rowsTs.length < limit) break;
        after = next;
      }
    };
    for (const t of threads) await page("threads", t);
    for (const k of keys) await page("sessions", k);
    for (const t of threads) for (const table of ["thread_sessions", ...handover.BY_N, ...handover.MARKS] as handover.ChatTable[]) await page(table, t);
    for (const k of keys) for (const table of ["turns", "runtime_sessions", "pins", "opened_chats", "deliveries", ...handover.USAGE_TABLES] as handover.ChatTable[]) await page(table, k);
    // (put in here, alike)
    const ctxOf = () => handover.newCtx({ from: "there", here: "here", fromData: "/there", toData: "/here", connects: { "conn-there": "conn-here" }, profiles: { pt: "ph" }, ws: "coming:w1" });
    await p.c("handover.newCtx", { from: "there", fromData: "/there", toData: "/here", connects: {}, profiles: {}, ws: "coming:w1" });
    await p.c("handover.surfaceHere", "feishu:conn-there", { "conn-there": "conn-here" });
    await p.c("handover.surfaceHere", "ember", {});
    let ctx: unknown = ctxOf();
    for (const [table, , rowsOf] of pages) {
      p.now += 1;
      await p.c("importRows", ctx, table, rowsOf, "ho-1");
      ctx = p.lastArgs[0];
      assert.deepEqual(said(ctx), said(p.ts.importCtx("ho-1")));
    }
    const put = await p.c("importCtx", "ho-1");
    assert.ok(put.counts.sessions === 2 && Object.keys(put.counts.entries).length === 2 && put.made.rows.turns.length === 1, JSON.stringify(put.counts));
    assert.equal(Object.values(put.threads as Record<string, { fresh: boolean }>).filter((t) => t.fresh).length, 1, "the platform's thread met, the still.fail chat of another's put in anew");
    await p.c("importCtx", "none");
    await p.c("sessionWs", "h1");
    await p.c("showChat", ["h1", "h2"], "w1");
    await p.c("forgetImport", "ho-1");
    await p.c("importCtx", "ho-1");
    await p.c("handedTo", "h1");
    // (handed on to another station, and back)
    p.now += 1000;
    await p.c("handOff", ["h1", "none"], "far", "home-ws", { h1: { thread: t1.id, there: 77 } });
    await p.c("handedTo", "h1");
    await p.c("handedTo", "h1");
    await p.c("handedChats", "", 10);
    await p.c("liveOf", ["h1", "h2", "none"]);
    await p.c("liveOf", []);
    await p.c("goneTo", ["h2"], "far", {});
    await p.c("handedTo", "h2");
    await p.c("notGone", ["h2", "h1", "none"], "far");
    await p.c("goneTo", ["h2"], "far", { h2: { thread: null, there: 5 } });
    await p.c("shownThere", ["h2"], null);
    await p.c("deliveredThere", ["h2", "h1"]);
    await p.c("sessionsOfConnect", "conn-here", 10);
    await p.c("sessionsOfConnect", "conn-here", 1, "h1");
    await p.c("sessionsOfWs", "w1", null, "", 10);
    await p.c("sessionsOfWs", null, "home-ws", "", 10);
    await p.c("sessionsOfWs", null, null, "", 1);
    await p.c("sessionPageOfWs", null, "home-ws", "", 10, [["keys"], ["rows"], ["session", "h1"], ["session", "zz"], ["homeMembers", "h1"], ["homeMembers", "zz"], ["ranOn", "h1"], ["ranOn", "zz"]]);
    await p.c("handedTo", "h1");
    await p.c("sessionPage", ["h1", "h2", "zz"], null, [["homeMembers", "h1"], ["ranOn", "h1"], ["rows"], ["session", "h2"], ["ranOn", "zz"], ["homeMembers", "h2"]]);
    await p.c("sessionPage", ["h1"], null, [["ranOn", "h1"], ["homeMembers", "h1"], ["session", "h1"]]);
    await p.c("stillfailHomes", ["h1", "someone", "zz"]);
    await p.c("stillfailHomes", []);
    await p.c("ranOnOf", ["h1", "h2"]);
    await p.c("setMovedNote", "h1", "moved here");
    await p.c("dropConnectThreadStation", "conn-here", "oc_1", "om_1");
    await p.c("handover.handedStations");
    await p.c("handover.handedWithUsage", "far", "", 10);
    await p.c("handover.threadRefs", "h1", [t1.id, t2.id, t1.id, 999]);
    await p.c("handover.hasUsage", "h1");
    await p.c("handover.hasUsage", "zz");
    const refs = handover.threadRefs(from.db, "h1", [t1.id, t2.id]);
    for (const ref of refs) await p.c("handover.threadOfRef", "h1", ref, { "conn-there": "conn-here" });
    await p.c("handover.putUsage", { id: "pu1", at: p.now, session: "h1", runtime: "claude", input: 1, output: 2, calls: 1, cache_read: 0, cache_write: 0, cache_write_long: 0, subagent: 0, fast: 0 });
    await p.c("handover.putUsage", { id: "pu1", at: p.now, session: "h1", runtime: "claude" });
    await p.c("handover.putUsage", { id: 7 });
    await p.c("handover.importHandedUsage", { session: "h1", threads: { [t1.id]: 1 }, profiles: { pt: "ph" }, fromData: "/there", toData: "/here", usage: [{ id: "hu2", at: p.now, session: "h1", runtime: "claude", thread: t1.id, profile: "pt", input: 1, output: 1, calls: 1, cache_read: 0, cache_write: 0, cache_write_long: 0, subagent: 0, fast: 0 }, { id: "zz", session: "other" }], files: [{ path: "/there/t/h1.jsonl", session: "h1", offset: 99, model: "opus" }, { path: "/there/t/h1.jsonl", session: "h1", offset: 1 }] });
    // (a hand-over that fails: what it put in taken out, what was here before put back)
    let failed: unknown = handover.newCtx({ from: "there", fromData: "/there", toData: "/here", connects: {}, profiles: {}, ws: "coming:w2" });
    from.insertSession(session("h9", { connect: "conn-there" }));
    const t9 = from.openThread("slack:T9", "C9", "9.9", null, null);
    from.joinThread(t9.id, "h9", "slack-9");
    from.joinThread(t9.id, "h2", "slack-9");
    from.insertMessage({ thread: t9.id, ts: "g1", authorKind: "person", author: "U1", text: "g" });
    from.startTurn("ht9", "h9", "input");
    from.setSessionUsage("h2", { modelCalls: 3 });
    const fail: [handover.ChatTable, number | string][] = [["threads", t9.id], ["sessions", "h9"], ["sessions", "h2"], ["thread_sessions", t9.id], ["entries", t9.id], ["turns", "h9"], ["session_usage", "h2"], ["usage_files", "h1"]];
    for (const [table, of] of fail) {
      p.now += 1;
      await p.c("importRows", failed, table, from.chatPage(table, of, null, 500, ["h9", "h2"]));
      failed = p.lastArgs[0];
    }
    p.same("before the failed hand-over is dropped");
    await p.c("dropImport", failed);
    assert.equal(await p.c("getSession", "h9"), null);
    assert.notEqual(await p.c("getSession", "h2"), null, "a session there before stays, as it was");
    p.same("handed over");
    // (every family the leader named was asked of both)
    const named = ["chatThreads", "chatPage", "importRows", "importCtx", "forgetImport", "dropImport", "showChat", "notGone", "handOff", "goneTo",
      "shownThere", "deliveredThere", "liveOf", "handedTo", "handedChats", "setMovedNote", "sessionsOfConnect", "sessionsOfWs", "sessionPageOfWs",
      "sessionPage", "stillfailHomes", "ranOnOf", "dropConnectThreadStation"];
    for (const call of named.filter((c) => !["chatThreads", "chatPage"].includes(c))) assert.ok(p.calls.has(call), call);
  } finally {
    await fromMb.terminate();
    from.close();
    rmSync(fromDir, { recursive: true, force: true });
  }
}));
