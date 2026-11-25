// The store's schema (once the Rust station's store.rs `// ── schema`): the tables as CREATE … IF NOT EXISTS, and the
// columns that came after, added in place on open (add_*_columns).
import { ENROLLMENT_TABLES, ANNOUNCEMENT_TABLE, RELAY_RECORD_TABLE } from "./mesh-schema.ts";
import type { DatabaseSync } from "node:sqlite";
import { hasLegacySaid, installLegacySaid } from "./legacy-said-build.ts";
import { hasLegacyAgent, installLegacyAgent } from "./legacy-agent-build.ts";
import { hasLegacyLoginCards, installLegacyLoginCards } from "./legacy-login-cards.ts";
import { hasLegacyEdits, hasOldEditIndex, installLegacyEdits, legacyEditLatest, legacyEditsUseOldIndex, usesLegacyEdits } from "./legacy-edits-build.ts";
import { repairWidgetSourceBeforeAdd, widgetSourceBeforeAddNeedsRepair } from "./widget-sources.ts";
import { COMPACTED_FROM, FORMER_OWN_NAMES, STILLFAIL_CONNECT, STILLFAIL_SURFACE } from "./rows.ts";
import { CC_SESSION_ORDER } from "./cc-thread-index.ts";
import { systemCardSql } from "./card-kinds.ts";
import { incrementalTotalsDecided } from "./usage-totals-source.ts";

/// Bump on a change a station before it cannot open. 12 is the Rust station's, brought up on open (store.ts
/// `#upgradeFrom12`); a database of another version is refused.
export const SCHEMA_VERSION = 13;

export const SCHEMA = `
${ENROLLMENT_TABLES}
${ANNOUNCEMENT_TABLE}
${RELAY_RECORD_TABLE}
CREATE TABLE IF NOT EXISTS archive_suggestions (
  thread INTEGER PRIMARY KEY,
  version INTEGER NOT NULL,
  at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS archive_policy (
  id INTEGER PRIMARY KEY,
  at INTEGER NOT NULL,
  policy TEXT NOT NULL,
  author TEXT NOT NULL,
  summary TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS archive_verdicts (
  thread INTEGER PRIMARY KEY,
  version INTEGER NOT NULL,
  at INTEGER NOT NULL,
  verdict TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS decision_checks (
  id INTEGER PRIMARY KEY,
  session TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  result TEXT NOT NULL
);
-- Decision lookups are installed after SCHEMA: an older populated table must not be indexed in one long startup write.
CREATE TABLE IF NOT EXISTS sessions (
  key TEXT PRIMARY KEY,
  connect TEXT NOT NULL,
  scope TEXT NOT NULL,
  title TEXT,
  created_by TEXT,
  runtime TEXT NOT NULL,
  profile TEXT NOT NULL,
  profile_pinned INTEGER NOT NULL DEFAULT 0,
  profiles TEXT,
  model TEXT,
  effort TEXT,
  fast INTEGER,
  speed TEXT,
  tui INTEGER,
  afresh INTEGER,
  context INTEGER,
  context_before INTEGER,
  compactions INTEGER,
  runtime_session_id TEXT,
  workspace TEXT NOT NULL,
  token TEXT NOT NULL UNIQUE,
  running INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  last_active_at INTEGER NOT NULL,
  archived_at INTEGER,
  archived_by TEXT,
  shown_at INTEGER,
  cwd TEXT,
  original_runtime TEXT,
  conv TEXT
);
-- The sessions shown (store.ts LIVE_SESSIONS): what the station's own periodic work goes over; the archived ones only grow.
CREATE INDEX IF NOT EXISTS sessions_live ON sessions (last_active_at) WHERE archived_at IS NULL;
-- The sessions running (store.ts ANY_RUNNING, RUNNING_SESSIONS).
CREATE INDEX IF NOT EXISTS sessions_running ON sessions (key) WHERE running = 1;
-- The sessions someone started lately (store.ts modelsUsedBy: the models they chose, as a chat is opened for them).
CREATE INDEX IF NOT EXISTS sessions_by_creator ON sessions (created_by, created_at);
CREATE TABLE IF NOT EXISTS threads (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  surface TEXT NOT NULL,
  channel TEXT NOT NULL,
  thread_ts TEXT NOT NULL,
  title TEXT,
  created_by TEXT,
  created_at INTEGER NOT NULL,
  archived_at INTEGER,
  home TEXT,
  hidden_at INTEGER,
  hidden_by TEXT,
  shown_at INTEGER,
  auto_title TEXT,
  auto_title_n INTEGER,
  auto_title_changes INTEGER NOT NULL DEFAULT 0,
  links TEXT,
  project TEXT,
  project_locked INTEGER NOT NULL DEFAULT 0,
  tags TEXT,
  UNIQUE (surface, channel, thread_ts)
);
CREATE TABLE IF NOT EXISTS thread_sessions (
  thread INTEGER NOT NULL,
  session TEXT NOT NULL,
  connect TEXT NOT NULL,
  joined_at INTEGER NOT NULL,
  left_at INTEGER,
  PRIMARY KEY (thread, session)
);
CREATE INDEX IF NOT EXISTS thread_sessions_session ON thread_sessions (session);
-- The latest Slack stop per bot, thread and session: retries must not stop a later turn.
CREATE TABLE IF NOT EXISTS slack_stops (
  session TEXT NOT NULL,
  connect TEXT NOT NULL,
  channel TEXT NOT NULL,
  thread_ts TEXT NOT NULL,
  event_ts TEXT NOT NULL,
  turn_id TEXT,
  PRIMARY KEY (session, connect, channel, thread_ts)
);
-- The threads at an address on any surface (store.ts threadsAt: session_send to a thread by its channel and ts).
CREATE INDEX IF NOT EXISTS threads_at ON threads (channel, thread_ts);
CREATE TABLE IF NOT EXISTS entries (
  thread INTEGER NOT NULL,
  n INTEGER NOT NULL,
  kind TEXT NOT NULL,
  target INTEGER,
  ts TEXT,
  author_kind TEXT NOT NULL,
  author TEXT NOT NULL,
  text TEXT,
  attachments TEXT,
  quotes TEXT,
  declared TEXT,
  at INTEGER NOT NULL,
  client TEXT,
  profile TEXT,
  runtime TEXT,
  options TEXT,
  card TEXT,
  proposal TEXT,
  PRIMARY KEY (thread, n)
);
CREATE TABLE IF NOT EXISTS proposal_outcomes (
  thread INTEGER NOT NULL,
  n INTEGER NOT NULL,
  status TEXT NOT NULL,
  project TEXT,
  resolved_by TEXT NOT NULL,
  resolved_at INTEGER NOT NULL,
  info_note TEXT,
  info_refs TEXT,
  info_synced INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (thread, n)
);
CREATE UNIQUE INDEX IF NOT EXISTS entries_ts ON entries (thread, ts) WHERE ts IS NOT NULL;
-- The first person to answer a card is found by its entry number, without reading intervening agent messages.
CREATE INDEX IF NOT EXISTS entries_people_by_n ON entries (thread, n) WHERE author_kind = 'person' AND kind = 'message';
-- The Router's idempotency key is committed with its message. Targets are kept only until delivery has been handed on.
CREATE TABLE IF NOT EXISTS comma_router_once (
  -- A retry may still be finishing while an expired key is reused. Never reuse its identity.
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,
  thread INTEGER NOT NULL,
  n INTEGER NOT NULL,
  at INTEGER NOT NULL,
  pending INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS comma_router_once_age ON comma_router_once (at);
CREATE INDEX IF NOT EXISTS comma_router_once_thread ON comma_router_once (thread);
CREATE TABLE IF NOT EXISTS comma_router_once_targets (
  id INTEGER NOT NULL,
  position INTEGER NOT NULL,
  session TEXT NOT NULL,
  PRIMARY KEY (id, position)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS comma_router_once_target_session ON comma_router_once_targets (session, id);
CREATE TABLE IF NOT EXISTS deliveries (
  thread INTEGER NOT NULL,
  n INTEGER NOT NULL,
  session TEXT NOT NULL,
  delivered_at INTEGER,
  PRIMARY KEY (thread, n, session)
);
CREATE INDEX IF NOT EXISTS deliveries_pending ON deliveries (session) WHERE delivered_at IS NULL;
CREATE INDEX IF NOT EXISTS deliveries_session ON deliveries (session, thread);
-- What a session took lately, as it was delivered (usage.ts TAKEN_SINCE: whom a turn from before turns said so worked
-- for, as the usage counter reads its calls).
CREATE INDEX IF NOT EXISTS deliveries_taken ON deliveries (session, delivered_at) WHERE delivered_at IS NOT NULL;
CREATE TABLE IF NOT EXISTS reads (
  viewer TEXT NOT NULL,
  thread INTEGER NOT NULL,
  n INTEGER NOT NULL,
  at INTEGER NOT NULL,
  PRIMARY KEY (viewer, thread)
);
-- A viewer's personal list visibility; this is independent of the thread's archived state.
CREATE TABLE IF NOT EXISTS hidden_chats (
  viewer TEXT NOT NULL,
  thread INTEGER NOT NULL,
  PRIMARY KEY (viewer, thread)
);
-- Notifications can be silenced independently of list visibility.
CREATE TABLE IF NOT EXISTS muted_chats (
  viewer TEXT NOT NULL,
  thread INTEGER NOT NULL,
  PRIMARY KEY (viewer, thread)
);
CREATE TABLE IF NOT EXISTS profile_status (
  profile TEXT PRIMARY KEY,
  check_json TEXT, checked_at INTEGER,
  quota_json TEXT, quota_at INTEGER
);
CREATE TABLE IF NOT EXISTS bindings (
  connect TEXT PRIMARY KEY,
  session_key TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS turns (
  id TEXT PRIMARY KEY,
  session_key TEXT NOT NULL,
  kind TEXT NOT NULL,
  started_at INTEGER NOT NULL,
  ended_at INTEGER,
  outcome TEXT,
  detail TEXT,
  declared TEXT,
  wait_seconds INTEGER,
  wait_for TEXT,
  need TEXT,
  about_thread INTEGER,
  about_n INTEGER,
  about_ts TEXT,
  wait_watch INTEGER
);
-- A session's turns, by when they started: every list of chats and sessions counts each session's turns and takes its
-- latest (sessionStats); without it each scanned every turn of every session (some 160 ms a list on a busy station).
CREATE INDEX IF NOT EXISTS turns_by_session ON turns (session_key, started_at);
-- The turns running or ended lately (usage.ts usageActiveSessions, at each read of the usage counter: every few seconds
-- while agents work): without it each read scanned every turn of the station's.
CREATE INDEX IF NOT EXISTS turns_ended ON turns (ended_at);
CREATE TABLE IF NOT EXISTS processes (
  pgid INTEGER PRIMARY KEY,
  started_at INTEGER NOT NULL,
  runtime TEXT NOT NULL,
  label TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS jobs (
  id TEXT PRIMARY KEY,
  session_key TEXT NOT NULL,
  name TEXT NOT NULL,
  command TEXT NOT NULL,
  cwd TEXT NOT NULL,
  port INTEGER,
  token TEXT NOT NULL UNIQUE,
  state TEXT NOT NULL,
  pgid INTEGER,
  exit_code INTEGER,
  started_at INTEGER NOT NULL,
  ended_at INTEGER,
  restarts INTEGER NOT NULL DEFAULT 0,
  log TEXT NOT NULL,
  watch INTEGER NOT NULL DEFAULT 0,
  queued INTEGER,
  screen INTEGER,
  size TEXT,
  small INTEGER
);
CREATE INDEX IF NOT EXISTS jobs_by_session ON jobs (session_key);
-- The jobs running (store.ts runningJobs, JOBS_RUNNING: every station_list that asks how busy this one is, the
-- memory's watch every ten seconds, who keeps watch), and the services stopped on their own that hold their port
-- (JOBS_UP: what keeps a session from being archived): without them each looked at every job the station ever ran.
CREATE INDEX IF NOT EXISTS jobs_state ON jobs (state);
CREATE INDEX IF NOT EXISTS jobs_up ON jobs (state, port);
CREATE TABLE IF NOT EXISTS job_notices (
  job_id TEXT NOT NULL,
  at INTEGER NOT NULL,
  text TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS job_notices_by_job ON job_notices (job_id, at);
CREATE TABLE IF NOT EXISTS identities (
  viewer TEXT NOT NULL,
  slack_user TEXT NOT NULL,
  at INTEGER NOT NULL,
  PRIMARY KEY (viewer, slack_user)
);
-- Came after schema version 12 without changing it: made in place on open, like add_archive_columns' columns.
-- The chats a viewer keeps at the top of their list, by their item's id (its session's key), and since when.
CREATE TABLE IF NOT EXISTS pins (
  viewer TEXT NOT NULL,
  session TEXT NOT NULL,
  at INTEGER NOT NULL,
  PRIMARY KEY (viewer, session)
);
CREATE TABLE IF NOT EXISTS widget_states (
  session TEXT NOT NULL,
  path TEXT NOT NULL,
  state TEXT NOT NULL,
  model TEXT,
  updated_at INTEGER NOT NULL,
  told_at INTEGER,
  PRIMARY KEY (session, path)
);
-- Pending decisions (an agent's block post with options) a viewer said they will not take up: not on their list
-- any more, still pending for everyone else. By the post's thread and entry number.
CREATE TABLE IF NOT EXISTS dismissed (
  viewer TEXT NOT NULL,
  thread INTEGER NOT NULL,
  n INTEGER NOT NULL,
  at INTEGER NOT NULL,
  PRIMARY KEY (viewer, thread, n)
);
-- A viewer keeps a chat instead of receiving archive reminders.
CREATE TABLE IF NOT EXISTS kept_chats (
  viewer TEXT NOT NULL,
  thread INTEGER NOT NULL,
  PRIMARY KEY (viewer, thread)
);
-- A card closed by its viewer or withdrawn by its author.
CREATE TABLE IF NOT EXISTS closed_cards (
  thread INTEGER NOT NULL,
  n INTEGER NOT NULL,
  viewer TEXT NOT NULL,
  at INTEGER NOT NULL,
  PRIMARY KEY (thread, n)
);
-- What a person chose on a card with an option that closes it (closeCard): no message is sent and its agent is not
-- woken, so the agent (session, the card's author) is told with what it is next handed (told_at). Kept after, for
-- chat_history. ts: the card's post.
CREATE TABLE IF NOT EXISTS card_choices (
  thread INTEGER NOT NULL,
  n INTEGER NOT NULL,
  session TEXT NOT NULL,
  ts TEXT,
  viewer TEXT NOT NULL,
  option TEXT NOT NULL,
  at INTEGER NOT NULL,
  told_at INTEGER,
  PRIMARY KEY (thread, n)
);
CREATE INDEX IF NOT EXISTS card_choices_untold ON card_choices (session, at) WHERE told_at IS NULL;
-- A chat moved here from a station retired (replica/retire.ts): what its agent is told of it, once, with what it is
-- next handed (told_at), never woken for it.
CREATE TABLE IF NOT EXISTS moved_notes (
  session TEXT PRIMARY KEY,
  text TEXT NOT NULL,
  told_at INTEGER
);
-- What the agents spent (store/usage.rs): one row per model call their runtimes recorded, read from the transcripts,
-- with whom and what it was for as it was then. Kept when its session goes: it was spent all the same. The one record
-- of it: a chat's usage and the usage page are both added up from here (usage/module.ts, read/usage.ts). calls: how
-- many calls the row is (a runtime that tells a turn's counts at once, Devin or Grok Build, says how many it made).
-- context: of a main-thread row, what its session's context held after it (the prompt a call sent; what the runtime
-- says of a turn's last call); context_window: the model's window where the runtime tells it. NULL: not told.
CREATE TABLE IF NOT EXISTS usage (
  id TEXT PRIMARY KEY,
  at INTEGER NOT NULL,
  session TEXT NOT NULL,
  turn TEXT,
  thread INTEGER,
  person TEXT,
  profile TEXT,
  runtime TEXT NOT NULL,
  model TEXT,
  subagent INTEGER NOT NULL DEFAULT 0,
  fast INTEGER NOT NULL DEFAULT 0,
  input INTEGER NOT NULL,
  cache_read INTEGER NOT NULL,
  cache_write INTEGER NOT NULL,
  cache_write_long INTEGER NOT NULL,
  output INTEGER NOT NULL,
  calls INTEGER NOT NULL DEFAULT 1,
  context INTEGER,
  context_window INTEGER
);
CREATE INDEX IF NOT EXISTS usage_at ON usage (at);
-- A session's calls (session_usage, accounts.ts lastContexts) read without the rest.
CREATE INDEX IF NOT EXISTS usage_session ON usage (session, at);
-- The runtime sessions a session has run in, the first first, each with the profile it last ran on. The latest is
-- sessions.runtime_session_id; one before it was left for a new one (its account changed), and its history goes on
-- from theirs.
CREATE TABLE IF NOT EXISTS runtime_sessions (
  session_key TEXT NOT NULL,
  id TEXT NOT NULL,
  profile TEXT,
  at INTEGER NOT NULL,
  runtime TEXT,
  PRIMARY KEY (session_key, id)
);
-- The session that went on with a runtime's session, by its id (rows.ts SESSION_OF_RUNTIME: a machine's session gone
-- on with, Codex's fast mode).
CREATE INDEX IF NOT EXISTS runtime_sessions_by_id ON runtime_sessions (id);
CREATE INDEX IF NOT EXISTS sessions_by_runtime_id ON sessions (runtime_session_id) WHERE runtime_session_id IS NOT NULL;
-- How far each transcript has been read for it.
CREATE TABLE IF NOT EXISTS usage_files (
  path TEXT PRIMARY KEY,
  session TEXT,
  offset INTEGER NOT NULL,
  model TEXT
);
-- Chats an agent opened for another (chat_create, sessions/opened.ts): the session opened (child) and the one that
-- opened it (parent), each by its station ('' for this one) and key, with the key the opener gave the call. The station
-- of either keeps a row: the child's to tell its parent how its turns end, the parent's to know its children by. The
-- child's also keeps what its parent was called then (opener_title, addOpenerTitle), for its chat's way back to it.
-- led (addLedColumn): 1 for a chat its opener leads (chat_create for me), 0 for one opened for its person; NULL
-- before it.
CREATE TABLE IF NOT EXISTS opened_chats (
  child_station TEXT NOT NULL,
  child TEXT NOT NULL,
  parent_station TEXT NOT NULL,
  parent TEXT NOT NULL,
  key TEXT NOT NULL,
  title TEXT,
  link TEXT,
  state TEXT,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (child_station, child)
);
CREATE INDEX IF NOT EXISTS opened_chats_by_key ON opened_chats (parent_station, parent, key, child_station);
-- Chats shared with other workspaces (xshare/), by the session key their links name: to whom
-- (to: JSON [{workspace, name}]), whether they may write in it, who changed it last and when.
CREATE TABLE IF NOT EXISTS chat_shares (
  session TEXT PRIMARY KEY,
  shared TEXT NOT NULL,
  write INTEGER NOT NULL DEFAULT 0,
  by TEXT NOT NULL,
  at INTEGER NOT NULL
);
-- Chats published as snapshots, gone with public sharing.
DROP TABLE IF EXISTS published;
-- Where chats were relayed (sessions/relay.ts): each connect's channel or group, by when a chat was last
-- relayed there, so the picker offers the places used before first.
CREATE TABLE IF NOT EXISTS relayed_to (
  connect TEXT NOT NULL,
  channel TEXT NOT NULL,
  at INTEGER NOT NULL,
  PRIMARY KEY (connect, channel)
);
-- The threads of this station's connects whose chats run on another station of the workspace (connects/remote.ts):
-- every event of one goes there.
CREATE TABLE IF NOT EXISTS connect_threads (
  connect TEXT NOT NULL,
  channel TEXT NOT NULL,
  thread_ts TEXT NOT NULL,
  station TEXT NOT NULL,
  PRIMARY KEY (connect, channel, thread_ts)
);
-- Each task another station's chat ran here, as it began running (jobs/jobs.ts spawn: a remote: session's job, not
-- a service started again): its job, when, and whose (its session's key, remote:<workspace>:<station>:<session>),
-- kept 90 days whatever comes of the task and its session (store.ts noteRemoteRun), for what a workspace's card says of
-- the tasks its chats ran on other stations (read/usage.ts remoteRuns).
CREATE TABLE IF NOT EXISTS remote_runs (
  job TEXT PRIMARY KEY,
  at INTEGER NOT NULL,
  session TEXT NOT NULL
);
-- How many entries each session's transcript has, as the station last read it while the session was at work
-- (sessions/live.ts): its summary says so, and a device that missed some of them knows to read them.
CREATE TABLE IF NOT EXISTS transcript_lengths (
  session TEXT PRIMARY KEY,
  n INTEGER NOT NULL
);
-- What each session's calls used (read/usage.ts SessionUsage, as JSON), as the usage counter recorded them
-- (usage/module.ts keepUsage): its summary says it, so a device knows what an agent at rest used without following it.
CREATE TABLE IF NOT EXISTS session_usage (
  session TEXT PRIMARY KEY,
  usage TEXT NOT NULL
);
-- The highest build each device a lock here names said as it asked (by its id in the lock; -1: none said) and when it
-- was last seen, unix seconds (mesh/device-builds.ts): written only as the build rises or the day changes.
CREATE TABLE IF NOT EXISTS device_builds (
  id TEXT PRIMARY KEY,
  build INTEGER NOT NULL,
  at INTEGER NOT NULL
);
-- Since when the station keeps them (its first start with them), unix seconds: one row.
CREATE TABLE IF NOT EXISTS device_builds_since (
  one INTEGER PRIMARY KEY CHECK (one = 1),
  at INTEGER NOT NULL
);
-- The models a person starred in a workspace, as their devices carry them (api/routes/stars.ts; the stars as JSON,
-- the Stars of preset-records.ts, the core's): one row a person (their sub) a workspace, read by its key.
CREATE TABLE IF NOT EXISTS model_stars (
  ws TEXT NOT NULL,
  sub TEXT NOT NULL,
  stars TEXT NOT NULL,
  PRIMARY KEY (ws, sub)
);
-- A person's drafts of 待派发 in a workspace, as their devices carry them (sessions/board-drafts.ts; the drafts as JSON
-- by id, the KeptDraft of the core's board-drafts.ts): one row a person (their sub) a workspace, read by its key.
CREATE TABLE IF NOT EXISTS board_drafts (
  ws TEXT NOT NULL,
  sub TEXT NOT NULL,
  drafts TEXT NOT NULL,
  PRIMARY KEY (ws, sub)
);
-- The chats handed from here to another station while both are up (replica/handover.ts): where each went, the
-- workspace it was of here (null: the home one), its chat's thread here and there. Its rows here stay (a hand-back
-- goes on from them); a device, a link or a letter naming it is told where it is.
CREATE TABLE IF NOT EXISTS handed_over (
  session TEXT PRIMARY KEY,
  station TEXT NOT NULL,
  ws TEXT,
  thread INTEGER,
  there INTEGER,
  at INTEGER NOT NULL
);
-- What a chat being handed here has put in so far (the ctx of replica/handover.ts In), written in the same transaction as
-- each page of its rows: a stop between a page and the hand-over's own file leaves nothing a drop does not take out.
-- Gone once it is shown or dropped.
CREATE TABLE IF NOT EXISTS handover_in (
  id TEXT PRIMARY KEY,
  ctx TEXT NOT NULL
);
`;

/// Each message as it reads now: its latest edit's words, files and quotes.
export const MERGED = `CREATE VIEW merged AS
  SELECT m.thread, m.n, m.ts, m.author_kind, m.author,
    CASE WHEN e.n IS NULL THEN m.text ELSE e.text END AS text,
    CASE WHEN e.n IS NULL THEN m.attachments ELSE e.attachments END AS attachments,
    CASE WHEN e.n IS NULL THEN m.quotes ELSE e.quotes END AS quotes,
    m.declared, m.client, m.agent_identity, m.at AS created_at, e.at AS edited_at, m.letter
  FROM entries m
  LEFT JOIN entries e ON e.thread = m.thread
    AND e.n = (SELECT MAX(x.n) FROM entries x WHERE x.thread = m.thread AND x.target = m.n)
  WHERE m.kind = 'message';`;

const has = (db: DatabaseSync, table: string, column: string): boolean =>
  db.prepare(`SELECT 1 FROM pragma_table_info('${table}') WHERE name = ?`).get(column) !== undefined;

const hasEditIndex = (db: DatabaseSync) =>
  db.prepare("SELECT 1 FROM sqlite_master WHERE type='index' AND name='entries_edits'").get() !== undefined;

export { usesLegacyEdits } from "./legacy-edits-build.ts";

/// A view's index can be removed by another connection while this station is running. Switch it under a writer,
/// installing the old-store lookup if necessary, without building an index over the whole store at once.
export function repairMergedEditLookup(db: DatabaseSync): void {
  const view = () => (db.prepare("SELECT sql FROM sqlite_master WHERE type='view' AND name='merged'").get() as { sql: string } | undefined)?.sql ?? "";
  const needsRepair = (sql: string) => sql.includes("legacy_edit_meta")
    ? sql.includes("INDEXED BY entries_target") && !hasOldEditIndex(db) : !hasEditIndex(db);
  const viewNeedsRepair = needsRepair(view());
  if (!viewNeedsRepair && !widgetSourceBeforeAddNeedsRepair(db)) return;
  if (viewNeedsRepair && !hasEditIndex(db)) installLegacyEdits(db, true);
  db.exec("BEGIN IMMEDIATE");
  try {
    if (needsRepair(view())) {
      if (hasLegacyEdits(db) && legacyEditsUseOldIndex(db) && !hasOldEditIndex(db))
        db.prepare("UPDATE legacy_edit_meta SET old_index=0 WHERE id=1").run();
      const merged = usesLegacyEdits(db) ? MERGED.replace("SELECT MAX(x.n) FROM entries x WHERE x.thread = m.thread AND x.target = m.n",
        legacyEditLatest("m.thread", "m.n", "1", legacyEditsUseOldIndex(db))) : MERGED;
      db.exec(`DROP VIEW IF EXISTS merged; ${merged}`);
    }
    repairWidgetSourceBeforeAdd(db);
    db.exec("COMMIT");
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

/// A small store can build the native lookup under one writer. Prepare a larger older store in bounded steps.
export function addEditIndex(db: DatabaseSync): void {
  if (hasEditIndex(db) || hasLegacyEdits(db)) return;
  let prepare = false;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!hasEditIndex(db) && !hasLegacyEdits(db)) {
      if (db.prepare("SELECT 1 FROM entries LIMIT 1 OFFSET 63").get() === undefined)
        db.exec("CREATE INDEX IF NOT EXISTS entries_edits ON entries (thread, target, n) WHERE target IS NOT NULL");
      else prepare = true;
    }
    db.exec("COMMIT");
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
  if (prepare) installLegacyEdits(db,true);
}

/// Older records with no runtime belong to the session's original runtime. Remember it on the session when it first
/// changes, instead of rewriting every old transcript record while opening the database.
export function addRuntimeSessionRuntime(db: DatabaseSync): void {
  if (!has(db, "runtime_sessions", "runtime")) db.exec("ALTER TABLE runtime_sessions ADD COLUMN runtime TEXT");
  if (!has(db, "sessions", "original_runtime")) db.exec("ALTER TABLE sessions ADD COLUMN original_runtime TEXT");
  // A previous station can still change the runtime during handover. Remember the original for its writes too.
  // The index exists only where a previous version could already have switched a session before this field was added.
  const first = hasRuntimeOrderIndex(db)
    ? "COALESCE((SELECT runtime FROM runtime_sessions INDEXED BY runtime_sessions_ordered WHERE session_key = OLD.key ORDER BY at, rowid LIMIT 1), OLD.runtime)" : "OLD.runtime";
  db.exec(`CREATE TRIGGER IF NOT EXISTS sessions_original_runtime AFTER UPDATE OF runtime ON sessions
    WHEN OLD.runtime IS NOT NEW.runtime AND OLD.original_runtime IS NULL AND NEW.original_runtime IS NULL BEGIN
      UPDATE sessions SET original_runtime = ${first} WHERE key = NEW.key AND original_runtime IS NULL;
    END`);
}

/// Some stations already built this index while adding per-transcript runtimes. It lets us recover a session's first
/// runtime if it changed before original_runtime was introduced, without building an index over history at startup.
export function hasRuntimeOrderIndex(db: DatabaseSync): boolean {
  return db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'runtime_sessions_ordered'").get() !== undefined;
}

/// add_archive_columns: columns archiving came with, added to a database made before them. When they come, each
/// session's first chat on the page is taken as its own, and chats of sessions archived then as archived with them.
export function addArchiveColumns(db: DatabaseSync): void {
  for (const [column, kind] of [["archived_by", "TEXT"], ["shown_at", "INTEGER"], ["cwd", "TEXT"], ["fast", "INTEGER"], ["speed", "TEXT"], ["tui", "INTEGER"], ["afresh", "INTEGER"], ["context", "INTEGER"], ["context_before", "INTEGER"], ["profiles", "TEXT"], ["compactions", "INTEGER"]]) {
    if (!has(db, "sessions", column!)) db.exec(`ALTER TABLE sessions ADD COLUMN ${column} ${kind}`);
  }
  // Came with waiting's limit, after the turns table.
  if (!has(db, "turns", "wait_seconds")) db.exec("ALTER TABLE turns ADD COLUMN wait_seconds INTEGER");
  // Came with saying what a wait is for (chat_state waiting `for`).
  if (!has(db, "turns", "wait_for")) db.exec("ALTER TABLE turns ADD COLUMN wait_for TEXT");
  // Came with migration notes: the last one each session was told. A session from before them was told none.
  if (!has(db, "sessions", "told_notes")) db.exec("ALTER TABLE sessions ADD COLUMN told_notes INTEGER");
  // Came with need_help's `need`: what a person has to give or do.
  if (!has(db, "turns", "need")) db.exec("ALTER TABLE turns ADD COLUMN need TEXT");
  // Came with `about`: the message a turn's state is about.
  for (const [column, kind] of [["about_thread", "INTEGER"], ["about_n", "INTEGER"], ["about_ts", "TEXT"]]) {
    if (!has(db, "turns", column!)) db.exec(`ALTER TABLE turns ADD COLUMN ${column} ${kind}`);
  }
  // Came with usage (store/usage.ts): whom a turn worked for, where, and on which profile.
  for (const [column, kind] of [["profile", "TEXT"], ["person", "TEXT"], ["thread", "INTEGER"]]) {
    if (!has(db, "turns", column!)) db.exec(`ALTER TABLE turns ADD COLUMN ${column} ${kind}`);
  }
  if (has(db, "threads", "home")) return;
  db.exec(
    `BEGIN;
     ALTER TABLE threads ADD COLUMN home TEXT;
     ALTER TABLE threads ADD COLUMN hidden_at INTEGER;
     ALTER TABLE threads ADD COLUMN hidden_by TEXT;
     ALTER TABLE threads ADD COLUMN shown_at INTEGER;
     UPDATE threads SET home = (SELECT ts.session FROM thread_sessions ts WHERE ts.thread = threads.id ORDER BY ts.joined_at, ts.rowid LIMIT 1)
     WHERE surface = '${STILLFAIL_SURFACE}' AND id = (
       SELECT MIN(t2.id) FROM threads t2 JOIN thread_sessions ts2 ON ts2.thread = t2.id
       WHERE t2.surface = '${STILLFAIL_SURFACE}' AND ts2.session = (SELECT ts.session FROM thread_sessions ts WHERE ts.thread = threads.id ORDER BY ts.joined_at, ts.rowid LIMIT 1));
     UPDATE sessions SET archived_by = 'manual' WHERE archived_at IS NOT NULL AND archived_by IS NULL;
     UPDATE threads SET hidden_at = (SELECT archived_at FROM sessions WHERE key = threads.home), hidden_by = 'manual'
     WHERE home IN (SELECT key FROM sessions WHERE archived_at IS NOT NULL);
     COMMIT;`,
  );
}

/// The indexes on the threads' columns that came with homes (addArchiveColumns), made once those are there: a session's
/// own chat (store.ts homeChat, usage.ts usageTurns: each part of a transcript the usage counter reads), and the chats
/// of their own the auto-archiving goes over, without reading every thread.
export function addThreadIndexes(db: DatabaseSync): void {
  db.exec(`CREATE INDEX IF NOT EXISTS threads_home ON threads (home) WHERE home IS NOT NULL;
    CREATE INDEX IF NOT EXISTS threads_own ON threads (surface) WHERE home IS NULL AND hidden_at IS NULL;`);
}

/// add_client_column: the column a message's app came with (entries.client) and those after it, and the `merged` view
/// made anew with them.
export function addClientColumn(db: DatabaseSync): void {
  if (!has(db, "entries", "agent_identity")) db.exec("ALTER TABLE entries ADD COLUMN agent_identity TEXT");
  if (!has(db, "entries", "client")) db.exec("ALTER TABLE entries ADD COLUMN client TEXT");
  // The profile a notice is about; the `merged` view has no need of it.
  if (!has(db, "entries", "profile")) db.exec("ALTER TABLE entries ADD COLUMN profile TEXT");
  // The runtime a notice says is not installed (offered to install).
  if (!has(db, "entries", "runtime")) db.exec("ALTER TABLE entries ADD COLUMN runtime TEXT");
  // A block post's answers to pick from; the `merged` view has no need of them.
  if (!has(db, "entries", "options")) db.exec("ALTER TABLE entries ADD COLUMN options TEXT");
  // A message's card; an options card is kept in `options` too, which stations from before cards read.
  if (!has(db, "entries", "card")) db.exec("ALTER TABLE entries ADD COLUMN card TEXT");
  // A database from before cards has no card column when SCHEMA runs. Make the login lookup only after adding it.
  addLoginCardIndex(db);
  // How a session ran before a notice of its change and how it runs after (rows.ts RunChange); the `merged` view has no
  // need of it.
  if (!has(db, "entries", "change")) db.exec("ALTER TABLE entries ADD COLUMN change TEXT");
  // A chat's latest card is looked for on every list of chats: only its posts with one are read.
  db.exec("CREATE INDEX IF NOT EXISTS entries_options ON entries (thread, n) WHERE options IS NOT NULL");
  db.exec("CREATE INDEX IF NOT EXISTS entries_cards ON entries (thread, n) WHERE card IS NOT NULL");
  // A prior upgrade may have added the table column without rebuilding this view. Older stores use their prepared
  // lookup once ready, while a store that acquired the native index goes back to the native view.
  const legacyEdits = usesLegacyEdits(db);
  const view = (db.prepare("SELECT sql FROM sqlite_master WHERE type='view' AND name='merged'").get() as { sql: string } | undefined)?.sql ?? "";
  const usesLegacy = view.includes("legacy_edit_meta");
  const obsoleteOldView = !usesLegacy && view.includes("INDEXED BY entries_target");
  if (!has(db, "merged", "client") || !has(db, "merged", "agent_identity") || !has(db, "merged", "letter") || legacyEdits !== usesLegacy || obsoleteOldView) {
    const original = "SELECT MAX(x.n) FROM entries x WHERE x.thread = m.thread AND x.target = m.n";
    const merged = legacyEdits ? MERGED.replace(original,legacyEditLatest("m.thread","m.n","1",legacyEditsUseOldIndex(db))) : MERGED;
    db.exec(`BEGIN; DROP VIEW IF EXISTS merged; ${merged} COMMIT;`);
  }
}

/// Keep the native index for older connections and prepare a per-login lookup in bounded batches.
function addLoginCardIndex(db: DatabaseSync): void {
  const native = () => db.prepare("SELECT 1 FROM sqlite_master WHERE type='index' AND name='entries_login_cards'").get() !== undefined;
  if (hasLegacyLoginCards(db)) return;
  if (!native()) {
    db.exec("BEGIN IMMEDIATE");
    try {
      if (!hasLegacyLoginCards(db) && !native() && db.prepare("SELECT 1 FROM entries LIMIT 1 OFFSET 63").get() === undefined)
        db.exec(`CREATE INDEX IF NOT EXISTS entries_login_cards ON entries (thread, n) WHERE card LIKE '%"login"%'`);
      db.exec("COMMIT");
    } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
  }
  installLegacyLoginCards(db);
}

/// The column letters came with (entries.letter, rows.ts Letter): what two chats' agents write each other, kept apart
/// from what is said in a chat. Before it, a letter was known by its heading alone (`来自 …：`, by an agent not of the
/// thread): those are marked once as the column comes, with the chat their heading names. Runs before addClientColumn,
/// whose `merged` view has the column.
export function addLetterColumn(db: DatabaseSync): void {
  if (has(db, "entries", "letter")) return;
  const version = () => (db.prepare("PRAGMA main.data_version").get() as { data_version: number }).data_version;
  const readHeadings = () => db.prepare(
    `SELECT thread, n, text FROM entries e WHERE kind = 'message' AND author_kind = 'agent' AND (text LIKE '来自 %' OR text LIKE 'From %')
     AND author NOT IN (SELECT session FROM thread_sessions WHERE thread = e.thread)`,
  ).all() as { thread: number; n: number; text: string }[];
  // Most upgrades can read the headings without holding the writer. If another connection commits in the meantime,
  // read them again under the writer lock: entries or a session membership may have changed.
  const readVersion = version();
  let before = readHeadings();
  db.exec("BEGIN IMMEDIATE");
  try {
    // Another opener may have completed the same upgrade while the headings were being read.
    if (!has(db, "entries", "letter")) {
      if (version() !== readVersion) before = readHeadings();
      db.exec("ALTER TABLE entries ADD COLUMN letter TEXT");
      db.exec("CREATE INDEX IF NOT EXISTS entries_letters ON entries (thread, n) WHERE letter IS NOT NULL");
      const mark = db.prepare("UPDATE entries SET letter = ? WHERE thread = ? AND n = ?");
      for (const r of before) mark.run(JSON.stringify({ way: "in", ...headedFrom(r.text) }), r.thread, r.n);
    }
    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
}

/// The chat a letter's heading names (sessions/messages.ts `header`): `来自 [title](link)：`, Slack's `From <link|title>:`,
/// or a title alone.
export function headedFrom(text: string): { title: string; link: string | null } {
  const head = (text.split("\n", 1)[0] ?? "").replace(/^(来自|From) /, "").replace(/(：|:)\s*$/, "");
  const md = /^\[(.*)\]\((\S+)\)$/.exec(head);
  if (md) return { title: md[1]!, link: md[2]! };
  const slack = /^<([^|>]+)\|(.*)>$/.exec(head);
  if (slack) return { title: slack[2]!, link: slack[1]! };
  return { title: head, link: null };
}

/// add_auto_title_columns: the columns a chat's own name from its agent came with (threads.auto_title…).
export function addAutoTitleColumns(db: DatabaseSync): void {
  for (const [column, kind] of [["auto_title", "TEXT"], ["auto_title_n", "INTEGER"], ["auto_title_changes", "INTEGER NOT NULL DEFAULT 0"]]) {
    if (!has(db, "threads", column!)) db.exec(`ALTER TABLE threads ADD COLUMN ${column} ${kind}`);
  }
}

/// add_thread_links_column: external links for a thread (e.g. Comma Task web/app links in threads.links).
export function addThreadLinksColumn(db: DatabaseSync): void {
  if (!has(db, "threads", "links")) db.exec("ALTER TABLE threads ADD COLUMN links TEXT");
}

/// add_watch_column: the column watching jobs came with (jobs.watch).
export function addWatchColumn(db: DatabaseSync): void {
  if (!has(db, "jobs", "watch")) db.exec("ALTER TABLE jobs ADD COLUMN watch INTEGER NOT NULL DEFAULT 0");
}

/// The columns the station's queue came with (jobs/admit.ts): a job waiting for room (jobs.queued), one that uses the
/// screen (jobs.screen).
export function addQueueColumns(db: DatabaseSync): void {
  if (!has(db, "jobs", "queued")) db.exec("ALTER TABLE jobs ADD COLUMN queued INTEGER");
  if (!has(db, "jobs", "screen")) db.exec("ALTER TABLE jobs ADD COLUMN screen INTEGER");
}

/// A job that asked for the single small-work slot (added after jobs.size on older stores too).
export function addSmallJobColumn(db: DatabaseSync): void {
  if (!has(db, "jobs", "small")) db.exec("ALTER TABLE jobs ADD COLUMN small INTEGER");
}

/// The column saying a wait is its session's watch came with (turns.wait_watch, chat_state waiting `watch`): 1 it is, 0
/// something else; NULL said before it (taken as its watch while one runs).
export function addWaitWatchColumn(db: DatabaseSync): void {
  if (!has(db, "turns", "wait_watch")) db.exec("ALTER TABLE turns ADD COLUMN wait_watch INTEGER");
}

/// The column an opened chat's way back to its opener came with (opened_chats.opener_title): what the chat that opened
/// it was called when it did; NULL before it.
export function addOpenerTitle(db: DatabaseSync): void {
  if (!has(db, "opened_chats", "opener_title")) db.exec("ALTER TABLE opened_chats ADD COLUMN opener_title TEXT");
}

/// The column chat_create's `for` came with (opened_chats.led): 1 a chat its opener leads, 0 one opened for its
/// person, NULL before it (its opener told as a leader is, its asks its person's).
export function addLedColumn(db: DatabaseSync): void {
  if (!has(db, "opened_chats", "led")) db.exec("ALTER TABLE opened_chats ADD COLUMN led INTEGER");
}

/// The column leaving a thread came with (thread_sessions.left_at, chat_leave): NULL for a session that hears it.
export function addLeftColumn(db: DatabaseSync): void {
  if (!has(db, "thread_sessions", "left_at")) db.exec("ALTER TABLE thread_sessions ADD COLUMN left_at INTEGER");
}

/// The column a job's sandbox size came with (jobs.size); since sandboxes are station_task's targets, where a job runs in one, as JSON
/// (agents/sandbox.ts `SandboxPlace`).
export function addSizeColumn(db: DatabaseSync): void {
  if (!has(db, "jobs", "size")) db.exec("ALTER TABLE jobs ADD COLUMN size TEXT");
}

/// What each session's calls add up to, by runtime, model ('' for none) and speed (store/usage.ts `usageOfSession`): kept
/// by the database itself as calls are recorded (or their output grows), whatever station process records them. A
/// session's usage is a few rows, where adding up its calls read every one of them, scattered over the table: some
/// 20,000 for a long chat, seconds of reading on a machine short of memory, on the main thread, each time the live view
/// of a session at work told its usage (a station, 2026-10-24: the station stopped answering for up to a minute).
/// The triggers that add a call to its session's totals and take one away, each by the calls it is (usage.calls).
const USAGE_TOTALS_KEPT = `
CREATE TRIGGER usage_totals_add AFTER INSERT ON usage BEGIN
  INSERT INTO usage_totals (session, runtime, model, fast, calls, input, cache_read, cache_write, cache_write_long, output)
  VALUES (NEW.session, NEW.runtime, COALESCE(NEW.model, ''), NEW.fast, NEW.calls, NEW.input, NEW.cache_read, NEW.cache_write, NEW.cache_write_long, NEW.output)
  ON CONFLICT (session, runtime, model, fast) DO UPDATE SET calls = calls + excluded.calls, input = input + excluded.input, cache_read = cache_read + excluded.cache_read,
    cache_write = cache_write + excluded.cache_write, cache_write_long = cache_write_long + excluded.cache_write_long, output = output + excluded.output;
END;
CREATE TRIGGER usage_totals_drop AFTER DELETE ON usage BEGIN
  UPDATE usage_totals SET calls = calls - OLD.calls, input = input - OLD.input, cache_read = cache_read - OLD.cache_read, cache_write = cache_write - OLD.cache_write,
    cache_write_long = cache_write_long - OLD.cache_write_long, output = output - OLD.output
  WHERE session = OLD.session AND runtime = OLD.runtime AND model = COALESCE(OLD.model, '') AND fast = OLD.fast;
END;
`;
const USAGE_TOTALS = `
CREATE TABLE usage_totals (
  session TEXT NOT NULL,
  runtime TEXT NOT NULL,
  model TEXT NOT NULL,
  fast INTEGER NOT NULL,
  calls INTEGER NOT NULL,
  input INTEGER NOT NULL,
  cache_read INTEGER NOT NULL,
  cache_write INTEGER NOT NULL,
  cache_write_long INTEGER NOT NULL,
  output INTEGER NOT NULL,
  PRIMARY KEY (session, runtime, model, fast)
) WITHOUT ROWID;
`;
const USAGE_TOTALS_NORMAL = `
${USAGE_TOTALS_KEPT}
CREATE TRIGGER usage_totals_grow AFTER UPDATE OF output ON usage WHEN NEW.output <> OLD.output BEGIN
  UPDATE usage_totals SET output = output + NEW.output - OLD.output
  WHERE session = NEW.session AND runtime = NEW.runtime AND model = COALESCE(NEW.model, '') AND fast = NEW.fast;
END;
`;

/// The columns usage came with as the one record of what was spent (usage.calls, context, context_window), added to a
/// table made before them, in one transaction: a row from before is one call and its untold context remains unknown;
/// the triggers made before them (the totals', the
/// compactions') are made anew to read them. Before the totals and compactions are made, which read them too.
export function addUsageColumns(db: DatabaseSync): void {
  if (has(db, "usage", "calls")) return;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!has(db, "usage", "calls")) {
      db.exec(`ALTER TABLE usage ADD COLUMN calls INTEGER NOT NULL DEFAULT 1;
        ALTER TABLE usage ADD COLUMN context INTEGER;
        ALTER TABLE usage ADD COLUMN context_window INTEGER;`);
      const made = (name: string) => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'trigger' AND name = ?").get(name) !== undefined;
      if (made("usage_totals_add")) db.exec(`DROP TRIGGER usage_totals_add; DROP TRIGGER usage_totals_drop; ${USAGE_TOTALS_KEPT}`);
      if (made("usage_compactions_add")) db.exec(`DROP TRIGGER usage_compactions_add; ${USAGE_COMPACTIONS_KEPT}`);
    }
    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
}

/// Install an empty total. If calls predate it, mark the coverage: a separate incremental source is installed after
/// the detail structures, without walking or claiming the older calls. A new database uses the ordinary triggers.
export function addUsageTotals(db: DatabaseSync): void {
  const made = () => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'usage_totals'").get() !== undefined;
  if (made()) return;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!made()) {
      const old = db.prepare("SELECT 1 FROM usage LIMIT 1").get() !== undefined;
      db.exec(`DROP TRIGGER IF EXISTS usage_totals_add; DROP TRIGGER IF EXISTS usage_totals_drop;
        DROP TRIGGER IF EXISTS usage_totals_grow; ${USAGE_TOTALS}`);
      db.exec(old ? "CREATE TABLE usage_totals_incremental (id INTEGER PRIMARY KEY CHECK (id = 1)); INSERT INTO usage_totals_incremental VALUES (1);" : USAGE_TOTALS_NORMAL);
    }
    db.exec("COMMIT");
    incrementalTotalsDecided(db);
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
}

/// The trigger that keeps the compactions (USAGE_COMPACTIONS) as each main-thread call is recorded: the session's call
/// before it, looked up by its index.
const USAGE_COMPACTIONS_KEPT = `
CREATE TRIGGER usage_compactions_add AFTER INSERT ON usage WHEN NEW.subagent = 0 AND NEW.model IS NOT NULL BEGIN
  INSERT INTO usage_compactions
    SELECT NEW.at, NEW.model, p.context FROM (
      SELECT b.context, b.profile, b.model FROM usage b
      WHERE b.session = NEW.session AND b.subagent = 0 AND b.at < NEW.at ORDER BY b.at DESC LIMIT 1) p
    WHERE p.context >= ${COMPACTED_FROM} AND NEW.context * 2 < p.context AND p.profile IS NEW.profile AND p.model IS NEW.model;
END;
`;

/// The old append-only compaction table, retained for older station processes; current reads use the newer index.
const USAGE_COMPACTIONS = `
CREATE TABLE usage_compactions (
  at INTEGER NOT NULL,
  model TEXT NOT NULL,
  point INTEGER NOT NULL
);
CREATE INDEX usage_compactions_at ON usage_compactions (at);
${USAGE_COMPACTIONS_KEPT}`;

/// Make the old compatibility table empty when absent; do not reconstruct old compactions.
export function addUsageCompactions(db: DatabaseSync): void {
  const made = () => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'usage_compactions'").get() !== undefined;
  if (made()) return;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!made()) db.exec(USAGE_COMPACTIONS);
    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
}

/// What lists say of each thread and session, kept as what they are made of is written, not read out of every message
/// each time a list is made (every sidebar, every GET /threads and /sessions, every event a viewer is told):
/// - thread_state: a thread's last entry, its latest message that is not a letter (`said_n`), the first a person
///   said (`person_n`), and how many letters it has. Entries only grow, and a thread's go together.
/// - thread_people: who wrote in a thread, each with the first message they wrote there.
/// - session_first: the first message a session was given (its delivery the earliest made).
/// Made once from what is there, in the same transaction as the triggers that keep them from then on (as
/// usage_totals), after the letters were marked (addLetterColumn).
// The first row of each thread is a seek in (session, thread, rowid); a session's earliest is the smallest of those.
// In particular, do not sort all of its deliveries when the first is removed. This visits its threads, not its messages.
const firstDeliveryRowid = (session: string) => `WITH RECURSIVE first_threads(thread) AS (
  VALUES ((SELECT thread FROM deliveries INDEXED BY deliveries_session WHERE session = ${session} ORDER BY thread LIMIT 1))
  UNION ALL
  SELECT (SELECT thread FROM deliveries INDEXED BY deliveries_session WHERE session = ${session} AND thread > first_threads.thread ORDER BY thread LIMIT 1)
    FROM first_threads WHERE thread IS NOT NULL
)
SELECT MIN((SELECT rowid FROM deliveries INDEXED BY deliveries_session WHERE session = ${session} AND thread = first_threads.thread ORDER BY rowid LIMIT 1))
FROM first_threads WHERE thread IS NOT NULL`;
export const firstDelivery = (session: string) => `SELECT thread, n FROM deliveries WHERE rowid = (${firstDeliveryRowid(session)})`;

// An old station can have many deliveries per thread. A session with at most 64 is small enough to scan; the station's
// first delivery is also a session's first when it belongs to it. Otherwise seek each of the session's threads.
export const SESSION_FIRST_INITIAL = `WITH RECURSIVE first_sessions(session) AS (
  VALUES ((SELECT session FROM deliveries INDEXED BY deliveries_session ORDER BY session LIMIT 1))
  UNION ALL
  SELECT (SELECT session FROM deliveries INDEXED BY deliveries_session WHERE session > first_sessions.session ORDER BY session LIMIT 1)
    FROM first_sessions WHERE session IS NOT NULL
)
INSERT INTO session_first (session, thread, n)
SELECT s.session, d.thread, d.n FROM first_sessions s
CROSS JOIN deliveries d ON d.rowid = COALESCE(
  (SELECT MIN(seq) FROM (SELECT rowid AS seq FROM deliveries INDEXED BY deliveries_session WHERE session = s.session LIMIT 65) HAVING COUNT(*) <= 64),
  (SELECT rowid FROM deliveries WHERE rowid = (SELECT MIN(rowid) FROM deliveries) AND session = s.session),
  (${firstDeliveryRowid("s.session")}))
WHERE s.session IS NOT NULL`;

// An outer INSERT OR REPLACE / OR ABORT overrides OR IGNORE in a trigger. Do not attempt an insert if this session
// already has a first delivery: the caller's conflict policy must neither replace the summary nor reject a new message.
const SESSION_FIRST_ADD = `CREATE TRIGGER session_first_add AFTER INSERT ON deliveries BEGIN
  -- REPLACE may remove the first delivery without firing DELETE triggers; its replacement has a new rowid.
  UPDATE session_first SET (thread, n) = (${firstDelivery("NEW.session")})
    WHERE session = NEW.session AND thread = NEW.thread AND n = NEW.n AND EXISTS
      (SELECT 1 FROM (${firstDelivery("NEW.session")}) first WHERE first.thread IS NOT NEW.thread OR first.n IS NOT NEW.n);
  INSERT INTO session_first SELECT NEW.session, NEW.thread, NEW.n
    WHERE NOT EXISTS (SELECT 1 FROM session_first WHERE session = NEW.session);
END;`;
const SESSION_FIRST_DROP = `CREATE TRIGGER session_first_drop AFTER DELETE ON deliveries
  WHEN EXISTS (SELECT 1 FROM session_first WHERE session = OLD.session AND thread = OLD.thread AND n = OLD.n) BEGIN
  DELETE FROM session_first WHERE session = OLD.session;
  INSERT INTO session_first (session, thread, n)
    SELECT OLD.session, next.thread, next.n FROM (${firstDelivery("OLD.session")}) next
    WHERE NOT EXISTS (SELECT 1 FROM session_first WHERE session = OLD.session);
END;`;
const ENTRIES_SAID_INDEX = "CREATE INDEX IF NOT EXISTS entries_said ON entries (thread, n, author_kind, author, letter) WHERE kind = 'message' AND letter IS NULL";

const THREAD_STATE_SCAN = `INSERT INTO thread_state
  SELECT thread, MAX(n), MAX(CASE WHEN kind = 'message' AND letter IS NULL THEN n END),
    MIN(CASE WHEN kind = 'message' AND author_kind = 'person' THEN n END), COUNT(CASE WHEN kind = 'message' AND letter IS NOT NULL THEN 1 END)
  FROM entries GROUP BY thread;`;

// Seek each thread's boundaries in the indexes already used by readers. Only its old letters need counting.
export const THREAD_STATE_SEEK = `WITH RECURSIVE state_threads(thread) AS (
  VALUES ((SELECT thread FROM entries ORDER BY thread LIMIT 1))
  UNION ALL
  SELECT (SELECT thread FROM entries WHERE thread > state_threads.thread ORDER BY thread LIMIT 1)
    FROM state_threads WHERE thread IS NOT NULL
)
INSERT INTO thread_state (thread, last_n, said_n, person_n, letters)
SELECT t.thread,
  (SELECT e.n FROM entries AS e WHERE e.thread = t.thread ORDER BY e.n DESC LIMIT 1),
  (SELECT e.n FROM entries AS e INDEXED BY entries_said WHERE e.thread = t.thread AND e.kind = 'message' AND e.letter IS NULL ORDER BY e.n DESC LIMIT 1),
  (SELECT e.n FROM entries AS e INDEXED BY entries_people_by_n WHERE e.thread = t.thread AND e.kind = 'message' AND e.author_kind = 'person' ORDER BY e.n LIMIT 1),
  (SELECT COUNT(*) FROM entries AS e INDEXED BY entries_letters WHERE e.thread = t.thread AND e.kind = 'message' AND e.letter IS NOT NULL)
FROM state_threads t WHERE t.thread IS NOT NULL;`;

const LIST_STATE = (threadState: string) => `
CREATE TABLE thread_state (
  thread INTEGER PRIMARY KEY,
  last_n INTEGER NOT NULL,
  said_n INTEGER,
  person_n INTEGER,
  letters INTEGER NOT NULL
);
CREATE TABLE thread_people (
  thread INTEGER NOT NULL,
  author TEXT NOT NULL,
  first_n INTEGER NOT NULL,
  PRIMARY KEY (thread, author)
) WITHOUT ROWID;
CREATE TABLE session_first (
  session TEXT PRIMARY KEY,
  thread INTEGER NOT NULL,
  n INTEGER NOT NULL
) WITHOUT ROWID;
${threadState}
INSERT INTO thread_people
  SELECT thread, author, MIN(n) FROM entries WHERE kind = 'message' AND author_kind = 'person' GROUP BY thread, author;
${SESSION_FIRST_INITIAL};
CREATE TRIGGER thread_state_add AFTER INSERT ON entries BEGIN
  INSERT INTO thread_state VALUES (NEW.thread, NEW.n,
      CASE WHEN NEW.kind = 'message' AND NEW.letter IS NULL THEN NEW.n END,
      CASE WHEN NEW.kind = 'message' AND NEW.author_kind = 'person' THEN NEW.n END,
      CASE WHEN NEW.kind = 'message' AND NEW.letter IS NOT NULL THEN 1 ELSE 0 END)
  ON CONFLICT (thread) DO UPDATE SET
    last_n = MAX(last_n, excluded.last_n),
    said_n = CASE WHEN excluded.said_n IS NULL THEN said_n WHEN said_n IS NULL THEN excluded.said_n ELSE MAX(said_n, excluded.said_n) END,
    person_n = CASE WHEN excluded.person_n IS NULL THEN person_n WHEN person_n IS NULL THEN excluded.person_n ELSE MIN(person_n, excluded.person_n) END,
    letters = letters + excluded.letters;
  INSERT INTO thread_people SELECT NEW.thread, NEW.author, NEW.n WHERE NEW.kind = 'message' AND NEW.author_kind = 'person'
  ON CONFLICT (thread, author) DO UPDATE SET first_n = MIN(first_n, excluded.first_n);
END;
CREATE TRIGGER thread_state_drop AFTER DELETE ON entries BEGIN
  DELETE FROM thread_state WHERE thread = OLD.thread;
  DELETE FROM thread_people WHERE thread = OLD.thread;
END;
${SESSION_FIRST_ADD}
${SESSION_FIRST_DROP}
`;

/// Letters (rows.ts Letter): what two chats' agents write each other, kept in a log of their own beside each chat's,
/// numbered from 1 in it, not among what is said in the chat (its entries): a chat's pages, its unread and its latest
/// page are of what it shows alone. Those from before it stay entries marked as letters (addLetterColumn).
/// - letters: a chat's letters both ways, in the order written.
/// - letter_deliveries: a letter coming in handed to the chat's sessions, as deliveries are a message.
const LETTERS = `
CREATE TABLE letters (
  thread INTEGER NOT NULL,
  n INTEGER NOT NULL,
  ts TEXT NOT NULL,
  author_kind TEXT NOT NULL,
  author TEXT NOT NULL,
  text TEXT NOT NULL,
  attachments TEXT,
  at INTEGER NOT NULL,
  letter TEXT NOT NULL,
  PRIMARY KEY (thread, n)
);
CREATE TABLE letter_deliveries (
  thread INTEGER NOT NULL,
  n INTEGER NOT NULL,
  session TEXT NOT NULL,
  delivered_at INTEGER,
  PRIMARY KEY (thread, n, session)
);
CREATE INDEX letter_deliveries_pending ON letter_deliveries (session) WHERE delivered_at IS NULL;
`;

/// The letters' own log (LETTERS), made once (as addListState).
export function addLetters(db: DatabaseSync): void {
  const made = () => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'letters'").get() !== undefined;
  if (made()) return;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!made()) db.exec(LETTERS);
    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
}

/// What JavaScript's trim() takes off a string's ends (WhiteSpace and LineTerminator), for SQLite's trim(X, Y).
const TRIMMED = "char(9, 10, 11, 12, 13, 32, 160, 5760, 8192, 8193, 8194, 8195, 8196, 8197, 8198, 8199, 8200, 8201, 8202, 8232, 8233, 8239, 8287, 12288, 65279)";

/// The options of an entry's card as rows.ts `cardOf` reads it (its own card when that reads as JSON, else its options
/// from before cards, as an options card), as JSON: NULL when it is no options card with a list of them.
const cardOptions = (card: string, options: string) => `CASE
  WHEN json_valid(${card}) THEN CASE WHEN json_extract(${card}, '$.type') = 'options' AND json_type(${card}, '$.options') = 'array' THEN json_extract(${card}, '$.options') END
  WHEN json_valid(${options}) AND json_type(${options}) = 'array' THEN ${options} END`;

/// The labels of those options (`cardOptions`), each trimmed, the empty left out, as a JSON array.
const cardLabels = (optionsJson: string) => `(SELECT json_group_array(label) FROM (
  SELECT trim(CASE WHEN o.type = 'object' THEN CASE WHEN json_type(o.value, '$.label') = 'text' THEN json_extract(o.value, '$.label') END END, ${TRIMMED}) AS label
  FROM json_each(${optionsJson}) o) WHERE label IS NOT NULL AND label != '')`;

/// Whether `text` (a person's words) is, trimmed, one of `labels` (`cardLabels`).
const saidLabel = (labels: string, text: string) => `(${text} IS NOT NULL AND EXISTS (SELECT 1 FROM json_each(${labels}) l WHERE l.value = trim(${text}, ${TRIMMED})))`;

/// Only cards since the preceding person's message are still awaiting that person's next message. The preceding
/// message and the cards after it are both located by their existing (thread, n) indexes.
const CARD_OUTCOMES_ANSWERED = `CREATE TRIGGER card_outcomes_answered AFTER INSERT ON entries WHEN NEW.kind = 'message' AND NEW.author_kind = 'person' BEGIN
  UPDATE card_outcomes SET answered = 1, said = ${saidLabel("card_outcomes.labels", "NEW.text")}
  WHERE thread = NEW.thread AND n < NEW.n AND n > COALESCE((
    SELECT p.n FROM entries p INDEXED BY entries_people_by_n
    WHERE p.thread = NEW.thread AND p.kind = 'message' AND p.author_kind = 'person' AND p.n < NEW.n
    ORDER BY p.n DESC LIMIT 1), -1) AND answered = 0;
END;`;

/// The decision cards agents asked with (an options card, or options from before cards) and how each was answered,
/// kept by the database as messages are written, as the lists' state is (LIST_STATE): what the usage page's 决策点击率
/// counts (read/store.ts `decisionCards`). Worked out from every card each time it was read, each looking up the next
/// thing a person said: 30 to 98 seconds a read on a station short of memory (2026-11-02), every minute while a page showed
/// usage, one of the readers held by it all along.
/// - labels: its options' labels, trimmed (`cardLabels`).
/// - answered: a person has said something in its chat since; `said`: the first such message was one of its labels.
/// Whether a person closed it with an option is closed_cards' (by a viewer not its author), read as it is counted.
/// Entries only grow, a thread's going all together: what a person said decides the cards before it still open.
const CARD_OUTCOMES = `
CREATE TABLE card_outcomes (
  thread INTEGER NOT NULL,
  n INTEGER NOT NULL,
  author TEXT NOT NULL,
  labels TEXT NOT NULL,
  answered INTEGER NOT NULL,
  said INTEGER NOT NULL,
  PRIMARY KEY (thread, n)
) WITHOUT ROWID;
CREATE TRIGGER card_outcomes_asked AFTER INSERT ON entries
  WHEN NEW.kind = 'message' AND NEW.author_kind = 'agent' AND (NEW.card IS NOT NULL OR NEW.options IS NOT NULL) BEGIN
  INSERT OR REPLACE INTO card_outcomes
    SELECT NEW.thread, NEW.n, NEW.author, ${cardLabels("o.options")}, 0, 0 FROM (SELECT ${cardOptions("NEW.card", "NEW.options")} AS options) o
    WHERE o.options IS NOT NULL;
END;
${CARD_OUTCOMES_ANSWERED}
CREATE TRIGGER card_outcomes_dropped AFTER DELETE ON entries WHEN OLD.kind = 'message' AND OLD.author_kind = 'agent' BEGIN
  DELETE FROM card_outcomes WHERE thread = OLD.thread AND n = OLD.n;
END;
`;

/// Install empty decision statistics and their triggers without reconstructing old messages. If messages already
/// exist, persist the missing coverage so the usage page never mistakes the new-only results for complete history.
export function addCardOutcomes(db: DatabaseSync): void {
  const made = () => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'card_outcomes'").get() !== undefined;
  if (!made()) {
    db.exec("BEGIN IMMEDIATE");
    try {
      if (!made()) {
        const old = db.prepare("SELECT 1 FROM entries LIMIT 1").get() !== undefined;
        db.exec(CARD_OUTCOMES);
        if (old) db.exec("CREATE TABLE IF NOT EXISTS card_outcomes_incomplete (id INTEGER PRIMARY KEY)");
      }
      db.exec("COMMIT");
    } catch (e) {
      db.exec("ROLLBACK");
      throw e;
    }
  }
  const bounded = () => ((db.prepare("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'card_outcomes_answered'").get() as { sql: string } | undefined)?.sql ?? "").includes("INDEXED BY entries_people_by_n");
  if (!bounded()) {
    // Replace just the trigger on older databases; the outcomes themselves need no scan or rebuild.
    db.exec("BEGIN IMMEDIATE");
    try {
      if (!bounded()) db.exec(`DROP TRIGGER IF EXISTS card_outcomes_answered; ${CARD_OUTCOMES_ANSWERED}`);
      db.exec("COMMIT");
    } catch (e) {
      db.exec("ROLLBACK");
      throw e;
    }
  }
}

/// How many turns each session has had, kept by the database as turns are written and removed (as LIST_STATE): what a
/// session's summary says (read/store.ts `sessionStats`). Counted from all of a session's turns, it was read again each
/// time the session changed: with the session's every delivery besides (its undelivered ones looked for by the wrong
/// index), 65 pages for a session of 1,900 turns, each from the disk on a station short of memory (2026-11-02).
const SESSION_TURNS = `
CREATE TABLE session_turns (
  session TEXT PRIMARY KEY,
  n INTEGER NOT NULL
) WITHOUT ROWID;
CREATE TABLE session_turns_guard (
  session TEXT PRIMARY KEY,
  token TEXT NOT NULL,
  boundary_at INTEGER NOT NULL,
  boundary_rowid INTEGER NOT NULL
) WITHOUT ROWID;
CREATE TRIGGER session_turns_before_insert BEFORE INSERT ON turns BEGIN
  DELETE FROM session_turns_guard WHERE session IN (SELECT session_key FROM turns WHERE id = NEW.id);
  -- A replacement may delete its old row without firing DELETE triggers. Even an ignored conflict may safely leave
  -- that session unknown; a later read will count it, rather than accepting a stale summary.
  DELETE FROM session_turns WHERE session IN (SELECT session_key FROM turns WHERE id = NEW.id);
END;
CREATE TRIGGER session_turns_add AFTER INSERT ON turns BEGIN
  -- Appends after a scan's current end are read later; they need not write the guard or restart the old scan.
  DELETE FROM session_turns_guard WHERE session = NEW.session_key
    AND (NEW.started_at, NEW.rowid) <= (boundary_at, boundary_rowid);
  UPDATE session_turns SET n = n + 1 WHERE session = NEW.session_key;
  INSERT INTO session_turns (session, n) SELECT NEW.session_key, 1
    WHERE NOT EXISTS (SELECT 1 FROM session_turns WHERE session = NEW.session_key)
      AND NOT EXISTS (SELECT 1 FROM turns INDEXED BY turns_by_session
        WHERE session_key = NEW.session_key AND rowid != NEW.rowid LIMIT 1);
END;
CREATE TRIGGER session_turns_drop AFTER DELETE ON turns BEGIN
  DELETE FROM session_turns_guard WHERE session = OLD.session_key;
  UPDATE session_turns SET n = n - 1 WHERE session = OLD.session_key;
  DELETE FROM session_turns WHERE session = OLD.session_key AND n <= 0;
END;
CREATE TRIGGER session_turns_move BEFORE UPDATE OF session_key, started_at, id ON turns
  WHEN OLD.session_key IS NOT NEW.session_key OR OLD.started_at IS NOT NEW.started_at OR OLD.id IS NOT NEW.id BEGIN
  DELETE FROM session_turns_guard WHERE session IN (OLD.session_key, NEW.session_key)
    OR session IN (SELECT session_key FROM turns WHERE id = NEW.id AND rowid != OLD.rowid);
  DELETE FROM session_turns WHERE session IN (OLD.session_key, NEW.session_key) AND OLD.session_key IS NOT NEW.session_key;
  DELETE FROM session_turns WHERE session IN (SELECT session_key FROM turns WHERE id = NEW.id AND rowid != OLD.rowid);
END;
`;

/// Install counts without walking old turns under the startup write lock. A missing count is not zero: short old
/// sessions can be read directly, and a requested long session is counted in bounded slices before it is reported.
export function addSessionTurns(db: DatabaseSync): void {
  const made = () => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session_turns'").get() !== undefined;
  if (made()) return;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!made()) db.exec(SESSION_TURNS);
    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
}

/// How long each session's turns have run, ended ones' added up, kept by the database as each turn ends (and goes): what
/// a session's summary says beside how many turns it had (`workMs`), the work a device shows ("12 turns, 3 h"). Kept from
/// when it began to be kept (`session_work_from`) and never added up from the turns before: a session with a turn that
/// ended by then says none (read/store.ts SESSION_STATS), and shows its turns alone (the user, 2026-11-03). To add them
/// up, a device read a session with its every turn, again after each one: many of one session took 25 s on a station short
/// of memory (2026-11-03).
const SESSION_WORK = `
CREATE TABLE session_work (
  session TEXT PRIMARY KEY,
  ms INTEGER NOT NULL
) WITHOUT ROWID;
CREATE TABLE session_work_from (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  at INTEGER NOT NULL
);
CREATE TRIGGER session_work_add AFTER INSERT ON turns WHEN NEW.ended_at > NEW.started_at BEGIN
  INSERT INTO session_work VALUES (NEW.session_key, NEW.ended_at - NEW.started_at) ON CONFLICT (session) DO UPDATE SET ms = ms + excluded.ms;
END;
CREATE TRIGGER session_work_end AFTER UPDATE OF started_at, ended_at ON turns
WHEN NEW.ended_at IS NOT OLD.ended_at OR NEW.started_at IS NOT OLD.started_at BEGIN
  INSERT INTO session_work VALUES (NEW.session_key,
      (CASE WHEN NEW.ended_at > NEW.started_at THEN NEW.ended_at - NEW.started_at ELSE 0 END)
      - (CASE WHEN OLD.ended_at > OLD.started_at THEN OLD.ended_at - OLD.started_at ELSE 0 END))
    ON CONFLICT (session) DO UPDATE SET ms = ms + excluded.ms;
END;
CREATE TRIGGER session_work_drop AFTER DELETE ON turns WHEN OLD.ended_at > OLD.started_at BEGIN
  UPDATE session_work SET ms = ms - (OLD.ended_at - OLD.started_at) WHERE session = OLD.session_key;
  DELETE FROM session_work WHERE session = OLD.session_key AND ms <= 0;
END;
`;

/// The sessions' work (SESSION_WORK), kept from `now` on: its tables and the triggers that keep it, nothing read.
export function addSessionWork(db: DatabaseSync, now: number): void {
  const made = () => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session_work_from'").get() !== undefined;
  if (made()) return;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!made()) {
      db.exec(SESSION_WORK);
      db.prepare("INSERT INTO session_work_from VALUES (1, ?)").run(now);
    }
    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
}

/// The card each chat waits on (its latest post with a card or options, no person having written since, not closed), as
/// it is posted, answered and closed: what the sidebar's marks read for every chat shown, one row each (read/views.ts
/// `chatMarks`). Kept from when it was made on (`pending_cards_from`, the entries there were then), never worked out of
/// what was said before: a chat with a card from before is read the way it was (read/store.ts `pendingCard`). Worked
/// out at each read, it was a dozen lookups a chat, 26 s for 68 chats on a station short of memory (2026-11-03).
const PENDING_CARDS = `
CREATE TABLE pending_cards (
  thread INTEGER PRIMARY KEY,
  n INTEGER NOT NULL
);
CREATE TABLE pending_cards_from (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  entry INTEGER NOT NULL
);
CREATE TRIGGER pending_cards_post AFTER INSERT ON entries
WHEN NEW.kind = 'message' AND (NEW.card IS NOT NULL OR NEW.options IS NOT NULL) BEGIN
  INSERT INTO pending_cards VALUES (NEW.thread, NEW.n) ON CONFLICT (thread) DO UPDATE SET n = excluded.n WHERE excluded.n > pending_cards.n;
END;
CREATE TRIGGER pending_cards_answered AFTER INSERT ON entries WHEN NEW.kind = 'message' AND NEW.author_kind = 'person' BEGIN
  DELETE FROM pending_cards WHERE thread = NEW.thread AND n < NEW.n;
END;
CREATE TRIGGER pending_cards_closed AFTER INSERT ON closed_cards BEGIN
  DELETE FROM pending_cards WHERE thread = NEW.thread AND n = NEW.n;
END;
CREATE TRIGGER pending_cards_gone AFTER DELETE ON threads BEGIN
  DELETE FROM pending_cards WHERE thread = OLD.id;
END;
`;

/// The cards chats wait on (PENDING_CARDS), kept from now on: its tables and the triggers that keep it, nothing read but
/// where the entries stand.
export function addPendingCards(db: DatabaseSync): void {
  const made = () => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'pending_cards_from'").get() !== undefined;
  if (made()) return;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!made()) {
      db.exec(PENDING_CARDS);
      db.exec("INSERT INTO pending_cards_from VALUES (1, COALESCE((SELECT MAX(rowid) FROM entries), 0))");
    }
    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
}

/// A person's message in a chat of the station's own answers the card it waits on (renamed with them: `renameOwnChats`).
const PENDING_CARDS_ANSWERED = `CREATE TRIGGER pending_cards_answered AFTER INSERT ON entries
WHEN NEW.kind = 'message' AND NEW.author_kind = 'person' AND (SELECT surface FROM threads WHERE id = NEW.thread) = '${STILLFAIL_SURFACE}' BEGIN
  DELETE FROM pending_cards WHERE thread = NEW.thread AND n < NEW.n;
END;`;

/// The system cards each chat waits on (store/card-kinds.ts: a login, a vault's secret, a phone, a rig, a sign-in),
/// several at once, kept apart from PENDING_CARDS, which from here on keeps the conversational card each chat waits on:
/// a system card is let go only as it is closed (its outcome, its withdrawal), a conversational one as a person's
/// message reaches its agent (in a still.fail chat as it is written; in a platform's thread as it is handed to a
/// session, `pending_cards_delivered`), and neither replaces the other. Those waiting as it is made are taken from
/// PENDING_CARDS (one a chat, the way they were read before): nothing older is looked for.
const PENDING_SYSTEM_CARDS = `
CREATE TABLE pending_system_cards (
  thread INTEGER NOT NULL,
  n INTEGER NOT NULL,
  PRIMARY KEY (thread, n)
) WITHOUT ROWID;
INSERT OR IGNORE INTO pending_system_cards
  SELECT p.thread, p.n FROM pending_cards p JOIN entries e ON e.thread = p.thread AND e.n = p.n
  WHERE e.kind = 'message' AND ${systemCardSql("e.card")};
DELETE FROM pending_cards WHERE EXISTS (SELECT 1 FROM pending_system_cards s WHERE s.thread = pending_cards.thread AND s.n = pending_cards.n);
CREATE TRIGGER pending_system_cards_post AFTER INSERT ON entries
WHEN NEW.kind = 'message' AND ${systemCardSql("NEW.card")} BEGIN
  INSERT OR IGNORE INTO pending_system_cards VALUES (NEW.thread, NEW.n);
END;
CREATE TRIGGER pending_system_cards_closed AFTER INSERT ON closed_cards BEGIN
  DELETE FROM pending_system_cards WHERE thread = NEW.thread AND n = NEW.n;
END;
CREATE TRIGGER pending_system_cards_gone AFTER DELETE ON threads BEGIN
  DELETE FROM pending_system_cards WHERE thread = OLD.id;
END;
DROP TRIGGER IF EXISTS pending_cards_post;
CREATE TRIGGER pending_cards_post AFTER INSERT ON entries
WHEN NEW.kind = 'message' AND (NEW.card IS NOT NULL OR NEW.options IS NOT NULL) AND NOT ${systemCardSql("NEW.card")} BEGIN
  INSERT INTO pending_cards VALUES (NEW.thread, NEW.n) ON CONFLICT (thread) DO UPDATE SET n = excluded.n WHERE excluded.n > pending_cards.n;
END;
DROP TRIGGER IF EXISTS pending_cards_answered;
${PENDING_CARDS_ANSWERED}
CREATE TRIGGER pending_cards_delivered AFTER INSERT ON deliveries
WHEN EXISTS (SELECT 1 FROM entries e WHERE e.thread = NEW.thread AND e.n = NEW.n AND e.kind = 'message' AND e.author_kind = 'person') BEGIN
  DELETE FROM pending_cards WHERE thread = NEW.thread AND n < NEW.n;
END;
`;

/// The system cards kept apart (PENDING_SYSTEM_CARDS), from now on.
export function addPendingSystemCards(db: DatabaseSync): void {
  const made = () => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'pending_system_cards'").get() !== undefined;
  if (made()) return;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!made()) db.exec(PENDING_SYSTEM_CARDS);
    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
}

/// What is told as chats change (a chat's row and how it stands for each viewer, a turn's end) is read by these, each
/// lookup the size of what it finds rather than of the chat's history:
/// - entries_said: a chat's messages after where a viewer read, counted from the index alone (read/store.ts `unreadOf`;
///   `letter`, always none here, so that SQLite need not read the message to know it). From the messages themselves, a
///   page each: a notice of a chat of many messages read many pages, 3 to 16 s each time on a station short of memory
///   (2026-11-02).
/// - entries_agent_at: what an agent said during a turn, by when (`askingMessage`): by the chat alone, every message
///   it had was read.
/// - turns_by_end: a session's turns by when they ended (`TOLD_BLOCKED`, whether a blocked ask was told already): by
///   when they started, every turn the session had was read.
/// - turns_waiting: the turns that ended asking for a person, by when (store.ts WAITING_FOR_PEOPLE): by turns_ended,
///   every turn of the week was looked at, 0.4-1.1 s at a time on a busy station (mm2, 2026-11-23).
/// - sessions_models: the chats someone started by when, with their runtime and model (store.ts MODELS_USED_BY).
/// - sessions_efforts: the efforts someone's chats on a runtime and model ran at, by when (store.ts EFFORTS_USED_BY).
export function addTellIndexes(db: DatabaseSync): void {
  addSaidIndex(db);
  addAgentIndex(db);
  db.exec("CREATE INDEX IF NOT EXISTS turns_by_end ON turns (session_key, ended_at)");
  db.exec("CREATE INDEX IF NOT EXISTS turns_waiting ON turns (ended_at) WHERE declared IN ('block', 'need_help', 'need_human', 'need_decision')");
  // The archive's, a page at a time by
  // when each was archived (ARCHIVED_PAGE): its whole list was made at once, 60 s on a station (2026-11-03).
  db.exec("CREATE INDEX IF NOT EXISTS sessions_put_away ON sessions (archived_at, key) WHERE archived_at IS NOT NULL");
  db.exec("CREATE INDEX IF NOT EXISTS threads_put_away ON threads (hidden_at, id) WHERE hidden_at IS NOT NULL");
  db.exec("CREATE INDEX IF NOT EXISTS sessions_models ON sessions (created_by, created_at, runtime, model)");
  addEffortIndex(db);
}

/// As for messages, a large older store cannot install a native time index without scanning it under a writer lock.
function addAgentIndex(db: DatabaseSync): void {
  const native = () => db.prepare("SELECT 1 FROM sqlite_master WHERE type='index' AND name='entries_agent_at'").get() !== undefined;
  if (hasLegacyAgent(db) || native()) return;
  let prepare = false;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!hasLegacyAgent(db) && !native()) {
      if (db.prepare("SELECT 1 FROM entries LIMIT 1 OFFSET 63").get() === undefined)
        db.exec("CREATE INDEX IF NOT EXISTS entries_agent_at ON entries (thread, at) WHERE kind = 'message' AND author_kind = 'agent'");
      else prepare = true;
    }
    db.exec("COMMIT");
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
  if (prepare) installLegacyAgent(db,true);
}

/// A native index is cheap on a new or small store. For an older large one, answer from the old table while the
/// equivalent lookup is prepared in bounded transactions. Recheck under the lock before a native index is built.
function addSaidIndex(db: DatabaseSync): void {
  const native = () => db.prepare("SELECT 1 FROM sqlite_master WHERE type='index' AND name='entries_said'").get() !== undefined;
  if (hasLegacySaid(db) || native()) return;
  let prepare = false;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!hasLegacySaid(db) && !native()) {
      if (db.prepare("SELECT 1 FROM entries LIMIT 1 OFFSET 63").get() === undefined) db.exec(ENTRIES_SAID_INDEX);
      else prepare = true;
    }
    db.exec("COMMIT");
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
  if (prepare) installLegacySaid(db, true);
}

/// A new or small store can install this at once. An older large store keeps the existing creator/time lookup for
/// effort choices: building a native index over its whole sessions table would hold up the previous writer.
function addEffortIndex(db: DatabaseSync): void {
  const installed = () => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'sessions_efforts'").get() !== undefined;
  const small = () => db.prepare("SELECT 1 FROM sessions LIMIT 1 OFFSET 64").get() === undefined;
  if (installed() || !small()) return;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!installed() && small()) db.exec("CREATE INDEX IF NOT EXISTS sessions_efforts ON sessions (created_by, runtime, model, created_at, effort)");
    db.exec("COMMIT");
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

/// The lists' kept state (LIST_STATE), made once, with its triggers (as addUsageTotals).
export function addListState(db: DatabaseSync): void {
  const made = () => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'thread_state'").get() !== undefined;
  const firstSafe = (trigger: string) => ((db.prepare("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?").get(trigger) as { sql: string } | undefined)?.sql ?? "")
    .includes("WITH RECURSIVE first_threads");
  if (made() && firstSafe("session_first_add") && firstSafe("session_first_drop")) return;
  // Store.open would build this index later in addTellIndexes. Make it first for this upgrade, after old letters are marked.
  if (!made()) db.exec(ENTRIES_SAID_INDEX);
  const hasIndex = (name: string) => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?").get(name) !== undefined;
  db.exec("BEGIN IMMEDIATE");
  try {
    // A partially upgraded database may have the columns but not their indexes; preserve its original migration.
    if (!made()) db.exec(LIST_STATE(hasIndex("entries_people_by_n") && hasIndex("entries_letters") ? THREAD_STATE_SEEK : THREAD_STATE_SCAN));
    else {
      if (!firstSafe("session_first_add")) db.exec(`DROP TRIGGER IF EXISTS session_first_add; ${SESSION_FIRST_ADD}`);
      if (!firstSafe("session_first_drop")) db.exec(`DROP TRIGGER IF EXISTS session_first_drop; ${SESSION_FIRST_DROP}`);
    }
    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
}

/// The columns a station in several workspaces came with: which workspace a session's chat
/// is in (sessions.ws) and whose archive policy a row is (archive_policy.ws); NULL is the station's home workspace.
export function addWorkspaceColumns(db: DatabaseSync): void {
  if (!has(db, "sessions", "ws")) db.exec("ALTER TABLE sessions ADD COLUMN ws TEXT");
  // A chat handed here from another station (replica/handover.ts): the station it came from (none: it began here, or
  // came back to where it began) and the one it began on (none: here).
  if (!has(db, "sessions", "came_from")) db.exec("ALTER TABLE sessions ADD COLUMN came_from TEXT");
  if (!has(db, "sessions", "began_on")) db.exec("ALTER TABLE sessions ADD COLUMN began_on TEXT");
  if (!has(db, "archive_policy", "ws")) db.exec("ALTER TABLE archive_policy ADD COLUMN ws TEXT");
  // The sessions counted by connect and workspace (store.ts SESSION_COUNTS, in every overview): from the index alone.
  db.exec("CREATE INDEX IF NOT EXISTS sessions_by_connect ON sessions (connect, ws)");
  // Which workspace each session is in, by its key (read/store.ts SEEN_OF, in each usage read): from the index alone,
  // not each session's whole row (every session's, for the usage page's history).
  db.exec("CREATE INDEX IF NOT EXISTS sessions_ws ON sessions (key, ws)");
  // A workspace's sessions by key (store.ts sessionsOfWs: what a migration plans, move/), a page at a time. On an
  // expression the other reads of `ws` do not name, so that it changes none of their plans (a plain (ws, key) index
  // took the join of legacy-decision-session-store.test.ts's sessions by key from its index).
  db.exec("DROP INDEX IF EXISTS sessions_by_ws");
  db.exec("CREATE INDEX IF NOT EXISTS sessions_of_ws ON sessions (COALESCE(ws, ''), key)");
}

/// Conversation anchor column (`sessions.conv`) and its lookup indexes.
export function addConvColumn(db: DatabaseSync): void {
  if (!has(db, "sessions", "conv")) db.exec("ALTER TABLE sessions ADD COLUMN conv TEXT");
  db.exec(`CREATE INDEX IF NOT EXISTS sessions_conv ON sessions (conv, key);
    CREATE INDEX IF NOT EXISTS sessions_conv_todo ON sessions (key) WHERE scope = 'thread' AND conv IS NULL;
    CREATE INDEX IF NOT EXISTS sessions_conv_grouped ON sessions (conv, key) WHERE conv IS NOT NULL AND conv != key;`);
}

/// Chat classification columns (`threads.project`, `threads.project_locked`, `threads.tags`) and
/// non-blocking project creation proposals (`entries.proposal`), plus partial indexes for bounded lookups.
export function addProjectColumns(db: DatabaseSync): void {
  if (!has(db, "threads", "project")) db.exec("ALTER TABLE threads ADD COLUMN project TEXT");
  if (!has(db, "threads", "project_locked")) db.exec("ALTER TABLE threads ADD COLUMN project_locked INTEGER NOT NULL DEFAULT 0");
  if (!has(db, "threads", "tags")) db.exec("ALTER TABLE threads ADD COLUMN tags TEXT");
  if (!has(db, "entries", "proposal")) db.exec("ALTER TABLE entries ADD COLUMN proposal TEXT");
  db.exec(`CREATE TABLE IF NOT EXISTS proposal_outcomes (
    thread INTEGER NOT NULL,
    n INTEGER NOT NULL,
    status TEXT NOT NULL,
    project TEXT,
    resolved_by TEXT NOT NULL,
    resolved_at INTEGER NOT NULL,
    info_note TEXT,
    info_refs TEXT,
    info_synced INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (thread, n)
  );
  CREATE INDEX IF NOT EXISTS threads_project ON threads (project, id) WHERE project IS NOT NULL AND project != '';
  CREATE INDEX IF NOT EXISTS threads_tags ON threads (id) WHERE tags IS NOT NULL;`);
  if (!has(db, "proposal_outcomes", "info_note")) db.exec("ALTER TABLE proposal_outcomes ADD COLUMN info_note TEXT");
  if (!has(db, "proposal_outcomes", "info_refs")) db.exec("ALTER TABLE proposal_outcomes ADD COLUMN info_refs TEXT");
  // Existing resolved outcomes from older schemas default to 1 so an upgrade never resurrects deleted projects.
  if (!has(db, "proposal_outcomes", "info_synced")) db.exec("ALTER TABLE proposal_outcomes ADD COLUMN info_synced INTEGER NOT NULL DEFAULT 1");

  // Append-only sidecar table for proposals attached when external echo landed before insertMessage (replicated with CHAT_TABLES).
  db.exec(`CREATE TABLE IF NOT EXISTS entry_proposals (
    thread INTEGER NOT NULL,
    n INTEGER NOT NULL,
    proposal TEXT NOT NULL,
    PRIMARY KEY (thread, n)
  );`);

  // Local-only persistent outbox for external proposal delivery (never exported in CHAT_TABLES).
  db.exec(`CREATE TABLE IF NOT EXISTS pending_proposals (
    thread INTEGER NOT NULL,
    author TEXT NOT NULL,
    name TEXT NOT NULL,
    id TEXT NOT NULL,
    payload TEXT NOT NULL,
    posted_ts TEXT,
    base_n INTEGER NOT NULL DEFAULT 0,
    sending INTEGER NOT NULL DEFAULT 0,
    connect TEXT NOT NULL DEFAULT '',
    history_cursor TEXT,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (thread, author, name)
  );`);
  if (!has(db, "pending_proposals", "base_n")) db.exec("ALTER TABLE pending_proposals ADD COLUMN base_n INTEGER NOT NULL DEFAULT 0");
  if (!has(db, "pending_proposals", "sending")) db.exec("ALTER TABLE pending_proposals ADD COLUMN sending INTEGER NOT NULL DEFAULT 0");
  if (!has(db, "pending_proposals", "connect")) db.exec("ALTER TABLE pending_proposals ADD COLUMN connect TEXT NOT NULL DEFAULT ''");
  if (!has(db, "pending_proposals", "history_cursor")) db.exec("ALTER TABLE pending_proposals ADD COLUMN history_cursor TEXT");

  // Local-only derived table for O(log N) unresolved proposal deduplication (0-row upgrade scan on entries; never exported in CHAT_TABLES).
  db.exec(`CREATE TABLE IF NOT EXISTS open_proposals (
    thread INTEGER NOT NULL,
    proposer TEXT NOT NULL,
    name TEXT NOT NULL,
    n INTEGER NOT NULL,
    PRIMARY KEY (thread, proposer, name, n)
  );
  CREATE INDEX IF NOT EXISTS open_proposals_thread_n ON open_proposals (thread, n);`);

  // Local-only derived index tables for O(log N) workspace project/tag queries (never exported in CHAT_TABLES).
  db.exec(`CREATE TABLE IF NOT EXISTS _project_index_meta (
    key TEXT PRIMARY KEY,
    val TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS active_thread_index (
    ws TEXT NOT NULL,
    thread INTEGER NOT NULL,
    project TEXT,
    tags TEXT,
    PRIMARY KEY (ws, thread)
  );
  CREATE INDEX IF NOT EXISTS active_thread_index_project
    ON active_thread_index (ws, project, thread)
    WHERE project IS NOT NULL;
  CREATE INDEX IF NOT EXISTS active_thread_index_thread
    ON active_thread_index (thread, ws);
  CREATE TABLE IF NOT EXISTS active_thread_tags (
    ws TEXT NOT NULL,
    tag TEXT NOT NULL,
    thread INTEGER NOT NULL,
    PRIMARY KEY (ws, tag, thread)
  );
  CREATE INDEX IF NOT EXISTS active_thread_tags_thread
    ON active_thread_tags (ws, thread);`);

  const hasSessions = db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sessions'").get() !== undefined
    && db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'thread_sessions'").get() !== undefined;
  if (hasSessions) {
    const indexed = db.prepare("SELECT val FROM _project_index_meta WHERE key = 'active_idx_v1'").get() as { val: string } | undefined;
    if (indexed?.val !== "1") {
      const recomputeThread = (ref: string) => `DELETE FROM active_thread_index WHERE thread = ${ref};
        INSERT OR IGNORE INTO active_thread_index (ws, thread, project, tags)
        SELECT DISTINCT COALESCE(s.ws, ''), t.id, NULLIF(t.project, ''), t.tags
        FROM threads t
        JOIN thread_sessions m ON m.thread = t.id AND m.left_at IS NULL
        JOIN sessions s ON s.key = m.session AND s.archived_at IS NULL
        WHERE t.id = ${ref} AND t.hidden_at IS NULL
          AND (NULLIF(t.project, '') IS NOT NULL OR t.tags IS NOT NULL);`;
      const recomputeSession = (ref: string) => `DELETE FROM active_thread_index WHERE thread IN (SELECT thread FROM thread_sessions WHERE session = ${ref});
        INSERT OR IGNORE INTO active_thread_index (ws, thread, project, tags)
        SELECT DISTINCT COALESCE(s.ws, ''), t.id, NULLIF(t.project, ''), t.tags
        FROM threads t
        JOIN thread_sessions m ON m.thread = t.id AND m.left_at IS NULL
        JOIN sessions s ON s.key = m.session AND s.archived_at IS NULL
        WHERE t.id IN (SELECT thread FROM thread_sessions WHERE session = ${ref})
          AND t.hidden_at IS NULL
          AND (NULLIF(t.project, '') IS NOT NULL OR t.tags IS NOT NULL);`;
      db.exec("BEGIN IMMEDIATE");
      try {
        db.exec(`
          DROP TRIGGER IF EXISTS active_thread_index_ad;
          DROP TRIGGER IF EXISTS active_thread_index_ai;
          DROP TRIGGER IF EXISTS active_thread_threads_ai;
          DROP TRIGGER IF EXISTS active_thread_threads_au;
          DROP TRIGGER IF EXISTS active_thread_threads_ad;
          DROP TRIGGER IF EXISTS active_thread_ts_ai;
          DROP TRIGGER IF EXISTS active_thread_ts_au;
          DROP TRIGGER IF EXISTS active_thread_ts_ad;
          DROP TRIGGER IF EXISTS active_thread_sessions_ai;
          DROP TRIGGER IF EXISTS active_thread_sessions_au;
          DROP TRIGGER IF EXISTS active_thread_sessions_ad;
          CREATE TRIGGER active_thread_index_ad AFTER DELETE ON active_thread_index BEGIN
            DELETE FROM active_thread_tags WHERE ws = OLD.ws AND thread = OLD.thread;
          END;
          CREATE TRIGGER active_thread_index_ai AFTER INSERT ON active_thread_index
          WHEN NEW.tags IS NOT NULL AND json_valid(NEW.tags) AND json_type(NEW.tags) = 'array' BEGIN
            INSERT OR IGNORE INTO active_thread_tags (ws, tag, thread)
            SELECT NEW.ws, j.value, NEW.thread
            FROM json_each(NEW.tags) j
            WHERE j.type = 'text' AND j.value != '';
          END;
          CREATE TRIGGER active_thread_threads_ai AFTER INSERT ON threads
          WHEN NEW.hidden_at IS NULL AND (NULLIF(NEW.project, '') IS NOT NULL OR NEW.tags IS NOT NULL) BEGIN
            ${recomputeThread("NEW.id")}
          END;
          CREATE TRIGGER active_thread_threads_au AFTER UPDATE OF project, tags, hidden_at ON threads
          WHEN (OLD.project IS NOT NEW.project OR OLD.tags IS NOT NEW.tags OR OLD.hidden_at IS NOT NEW.hidden_at)
            AND (NULLIF(OLD.project, '') IS NOT NULL OR OLD.tags IS NOT NULL OR NULLIF(NEW.project, '') IS NOT NULL OR NEW.tags IS NOT NULL) BEGIN
            ${recomputeThread("NEW.id")}
          END;
          CREATE TRIGGER active_thread_threads_ad AFTER DELETE ON threads
          WHEN NULLIF(OLD.project, '') IS NOT NULL OR OLD.tags IS NOT NULL BEGIN
            DELETE FROM active_thread_index WHERE thread = OLD.id;
          END;
          CREATE TRIGGER active_thread_ts_ai AFTER INSERT ON thread_sessions BEGIN
            ${recomputeThread("NEW.thread")}
          END;
          CREATE TRIGGER active_thread_ts_au AFTER UPDATE OF left_at ON thread_sessions BEGIN
            ${recomputeThread("NEW.thread")}
          END;
          CREATE TRIGGER active_thread_ts_ad AFTER DELETE ON thread_sessions BEGIN
            ${recomputeThread("OLD.thread")}
          END;
          CREATE TRIGGER active_thread_sessions_ai AFTER INSERT ON sessions BEGIN
            ${recomputeSession("NEW.key")}
          END;
          CREATE TRIGGER active_thread_sessions_au AFTER UPDATE OF archived_at, ws ON sessions
          WHEN OLD.archived_at IS NOT NEW.archived_at OR OLD.ws IS NOT NEW.ws BEGIN
            ${recomputeSession("NEW.key")}
          END;
          CREATE TRIGGER active_thread_sessions_ad AFTER DELETE ON sessions BEGIN
            ${recomputeSession("OLD.key")}
          END;
          DELETE FROM active_thread_index;
          DELETE FROM active_thread_tags;
          INSERT OR IGNORE INTO active_thread_index (ws, thread, project, tags)
          SELECT DISTINCT COALESCE(s.ws, ''), t.id, NULLIF(t.project, ''), t.tags
          FROM threads t
          JOIN thread_sessions m ON m.thread = t.id AND m.left_at IS NULL
          JOIN sessions s ON s.key = m.session AND s.archived_at IS NULL
          WHERE t.hidden_at IS NULL
            AND (NULLIF(t.project, '') IS NOT NULL OR t.tags IS NOT NULL);
          INSERT OR REPLACE INTO _project_index_meta (key, val) VALUES ('active_idx_v1', '1');
        `);
        db.exec("COMMIT");
      } catch (e) {
        db.exec("ROLLBACK");
        throw e;
      }
    }
  }

  const openProposalsReady = db.prepare("SELECT val FROM _project_index_meta WHERE key = 'open_proposals_v2'").get() as { val: string } | undefined;
  if (openProposalsReady?.val !== "1") {
    db.exec("BEGIN IMMEDIATE");
    try {
      db.exec(`
        DROP TRIGGER IF EXISTS open_proposals_entries_ai;
        DROP TRIGGER IF EXISTS open_proposals_sidecar_ai;
        DROP TRIGGER IF EXISTS open_proposals_sidecar_ad;
        DROP TRIGGER IF EXISTS open_proposals_outcomes_ai;
        DROP TRIGGER IF EXISTS open_proposals_outcomes_ad;
        DROP TRIGGER IF EXISTS open_proposals_entries_ad;
        CREATE TRIGGER open_proposals_entries_ai AFTER INSERT ON entries
        WHEN NEW.proposal IS NOT NULL AND json_valid(NEW.proposal) AND json_extract(NEW.proposal, '$.status') = 'pending' BEGIN
          INSERT OR IGNORE INTO open_proposals (thread, proposer, name, n)
          VALUES (
            NEW.thread,
            COALESCE(NULLIF(json_extract(NEW.proposal, '$.proposer'), ''), NEW.author),
            COALESCE(json_extract(NEW.proposal, '$.name'), ''),
            NEW.n
          );
        END;
        CREATE TRIGGER open_proposals_sidecar_ai AFTER INSERT ON entry_proposals
        WHEN json_valid(NEW.proposal) AND json_extract(NEW.proposal, '$.status') = 'pending' BEGIN
          INSERT OR IGNORE INTO open_proposals (thread, proposer, name, n)
          SELECT
            NEW.thread,
            COALESCE(NULLIF(json_extract(NEW.proposal, '$.proposer'), ''), COALESCE((SELECT author FROM entries WHERE thread = NEW.thread AND n = NEW.n), '')),
            COALESCE(json_extract(NEW.proposal, '$.name'), ''),
            NEW.n
          WHERE NOT EXISTS (SELECT 1 FROM proposal_outcomes WHERE thread = NEW.thread AND n = NEW.n);
        END;
        CREATE TRIGGER open_proposals_sidecar_ad AFTER DELETE ON entry_proposals BEGIN
          DELETE FROM open_proposals WHERE thread = OLD.thread AND n = OLD.n;
          INSERT OR IGNORE INTO open_proposals (thread, proposer, name, n)
          SELECT
            e.thread,
            COALESCE(NULLIF(json_extract(e.proposal, '$.proposer'), ''), e.author),
            COALESCE(json_extract(e.proposal, '$.name'), ''),
            e.n
          FROM entries e
          WHERE e.thread = OLD.thread AND e.n = OLD.n
            AND e.proposal IS NOT NULL AND json_valid(e.proposal)
            AND json_extract(e.proposal, '$.status') = 'pending'
            AND NOT EXISTS (SELECT 1 FROM proposal_outcomes WHERE thread = OLD.thread AND n = OLD.n);
        END;
        CREATE TRIGGER open_proposals_outcomes_ai AFTER INSERT ON proposal_outcomes BEGIN
          DELETE FROM open_proposals WHERE thread = NEW.thread AND n = NEW.n;
        END;
        CREATE TRIGGER open_proposals_outcomes_ad AFTER DELETE ON proposal_outcomes BEGIN
          INSERT OR IGNORE INTO open_proposals (thread, proposer, name, n)
          SELECT
            e.thread,
            COALESCE(NULLIF(json_extract(COALESCE(e.proposal, ep.proposal), '$.proposer'), ''), e.author),
            COALESCE(json_extract(COALESCE(e.proposal, ep.proposal), '$.name'), ''),
            e.n
          FROM entries e
          LEFT JOIN entry_proposals ep ON ep.thread = e.thread AND ep.n = e.n
          WHERE e.thread = OLD.thread AND e.n = OLD.n
            AND COALESCE(e.proposal, ep.proposal) IS NOT NULL
            AND json_valid(COALESCE(e.proposal, ep.proposal))
            AND json_extract(COALESCE(e.proposal, ep.proposal), '$.status') = 'pending'
            AND NOT EXISTS (SELECT 1 FROM proposal_outcomes WHERE thread = OLD.thread AND n = OLD.n);
        END;
        CREATE TRIGGER open_proposals_entries_ad AFTER DELETE ON entries
        WHEN EXISTS (SELECT 1 FROM open_proposals WHERE thread = OLD.thread AND n = OLD.n) BEGIN
          DELETE FROM open_proposals WHERE thread = OLD.thread AND n = OLD.n;
        END;
        INSERT OR IGNORE INTO open_proposals (thread, proposer, name, n)
        SELECT
          ep.thread,
          COALESCE(NULLIF(json_extract(ep.proposal, '$.proposer'), ''), COALESCE(e.author, '')),
          COALESCE(json_extract(ep.proposal, '$.name'), ''),
          ep.n
        FROM entry_proposals ep
        LEFT JOIN entries e ON e.thread = ep.thread AND e.n = ep.n
        LEFT JOIN proposal_outcomes po ON po.thread = ep.thread AND po.n = ep.n
        WHERE po.thread IS NULL AND json_valid(ep.proposal) AND json_extract(ep.proposal, '$.status') = 'pending';
        INSERT OR REPLACE INTO _project_index_meta (key, val) VALUES ('open_proposals_v2', '1');
      `);
      db.exec("COMMIT");
    } catch (e) {
      db.exec("ROLLBACK");
      throw e;
    }
  }
}

/// The station's own chats as their names are now (rows.ts STILLFAIL_SURFACE, STILLFAIL_CONNECT): what stations wrote
/// before the rename (FORMER_OWN_NAMES) written over once, here, as the database opens, and what was made of it then
/// made again. The tables' triggers carry it into what is kept of them; nothing else reads the names of before.
export function renameOwnChats(db: DatabaseSync, has: (table: string) => boolean): void {
  const former = FORMER_OWN_NAMES.map((n) => `'${n}'`).join(",");
  const made = (name: string) => (db.prepare("SELECT sql FROM sqlite_master WHERE name = ?").get(name) as { sql: string } | undefined)?.sql ?? null;
  const stale = (sql: string | null) => sql !== null && FORMER_OWN_NAMES.some((n) => sql.includes(`'${n}'`));
  const surfaces = db.prepare(`SELECT 1 FROM threads WHERE surface IN (${former}) LIMIT 1`).get() !== undefined;
  const tables = CONNECT_TABLES.filter(has);
  const connects = tables.filter((t) => db.prepare(`SELECT 1 FROM ${t} WHERE connect IN (${former}) LIMIT 1`).get() !== undefined);
  if (!surfaces && connects.length === 0 && !stale(made("cc_session_order")) && !stale(made("pending_cards_answered"))) return;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (stale(made("cc_session_order"))) db.exec(`DROP INDEX cc_session_order; ${CC_SESSION_ORDER}`);
    if (stale(made("pending_cards_answered"))) db.exec(`DROP TRIGGER pending_cards_answered; ${PENDING_CARDS_ANSWERED}`);
    db.exec(`UPDATE OR IGNORE threads SET surface = '${STILLFAIL_SURFACE}' WHERE surface IN (${former})`);
    for (const t of tables) db.exec(`UPDATE OR IGNORE ${t} SET connect = '${STILLFAIL_CONNECT}' WHERE connect IN (${former})`);
    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
}

/// The tables that name a session's connect as they are written (what is made of them follows by their triggers).
const CONNECT_TABLES = ["sessions", "thread_sessions", "bindings", "connect_threads", "relayed_to", "slack_stops"];
