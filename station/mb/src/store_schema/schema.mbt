// The store's schema (station/src/store/schema.ts): the tables as CREATE … IF NOT EXISTS, and the columns, views and
// kept states that came after, added in place on open, each by the same statements the TypeScript station runs.

///|
/// Bump on a change a station before it cannot open (schema.ts SCHEMA_VERSION). 12 is the Rust station's, brought up
/// on open (`upgrade_from_12`); a database of another version is refused.
pub let schema_version : Int = 13

///|
/// rows.ts STILLFAIL_SURFACE: a still.fail chat's surface.
let stillfail_surface : String = "chat"

///|
/// rows.ts COMPACTED_FROM: a context this large and then halved was compacted.
let compacted_from : String = "50000"

///|
pub let schema : String =
(
  $|
  $|CREATE TABLE IF NOT EXISTS mesh_relay_tokens (
  $|  hash TEXT PRIMARY KEY, scope TEXT NOT NULL, name TEXT NOT NULL,
  $|  made_by TEXT NOT NULL, expires INTEGER NOT NULL
  $|);
  $|CREATE INDEX IF NOT EXISTS mesh_relay_tokens_scope ON mesh_relay_tokens(scope, expires);
  $|CREATE TABLE IF NOT EXISTS mesh_relay_registrations (
  $|  scope TEXT NOT NULL, node TEXT NOT NULL, issuer TEXT NOT NULL,
  $|  generation INTEGER NOT NULL, name TEXT NOT NULL, made_by TEXT NOT NULL,
  $|  revoked INTEGER NOT NULL DEFAULT 0,
  $|  PRIMARY KEY(scope, node)
  $|);
  $|CREATE TABLE IF NOT EXISTS mesh_announcements (
  $| scope TEXT NOT NULL, node TEXT NOT NULL, revision INTEGER NOT NULL, body TEXT NOT NULL, signature TEXT NOT NULL,
  $| PRIMARY KEY(scope, node)
  $|);
  $|CREATE TABLE IF NOT EXISTS mesh_relay_records (
  $| scope TEXT NOT NULL, node TEXT NOT NULL, issuer TEXT NOT NULL, generation INTEGER NOT NULL,
  $| body TEXT NOT NULL, signature TEXT NOT NULL, PRIMARY KEY(scope,node)
  $|);
  $|CREATE TABLE IF NOT EXISTS archive_suggestions (
  $|  thread INTEGER PRIMARY KEY,
  $|  version INTEGER NOT NULL,
  $|  at INTEGER NOT NULL
  $|);
  $|CREATE TABLE IF NOT EXISTS archive_policy (
  $|  id INTEGER PRIMARY KEY,
  $|  at INTEGER NOT NULL,
  $|  policy TEXT NOT NULL,
  $|  author TEXT NOT NULL,
  $|  summary TEXT NOT NULL
  $|);
  $|CREATE TABLE IF NOT EXISTS archive_verdicts (
  $|  thread INTEGER PRIMARY KEY,
  $|  version INTEGER NOT NULL,
  $|  at INTEGER NOT NULL,
  $|  verdict TEXT NOT NULL
  $|);
  $|CREATE TABLE IF NOT EXISTS decision_checks (
  $|  id INTEGER PRIMARY KEY,
  $|  session TEXT NOT NULL,
  $|  created_at INTEGER NOT NULL,
  $|  result TEXT NOT NULL
  $|);
  $|-- Decision lookups are installed after SCHEMA: an older populated table must not be indexed in one long startup write.
  $|CREATE TABLE IF NOT EXISTS sessions (
  $|  key TEXT PRIMARY KEY,
  $|  connect TEXT NOT NULL,
  $|  scope TEXT NOT NULL,
  $|  title TEXT,
  $|  created_by TEXT,
  $|  runtime TEXT NOT NULL,
  $|  profile TEXT NOT NULL,
  $|  profile_pinned INTEGER NOT NULL DEFAULT 0,
  $|  profiles TEXT,
  $|  model TEXT,
  $|  effort TEXT,
  $|  fast INTEGER,
  $|  speed TEXT,
  $|  tui INTEGER,
  $|  afresh INTEGER,
  $|  context INTEGER,
  $|  context_before INTEGER,
  $|  compactions INTEGER,
  $|  runtime_session_id TEXT,
  $|  workspace TEXT NOT NULL,
  $|  token TEXT NOT NULL UNIQUE,
  $|  running INTEGER NOT NULL DEFAULT 0,
  $|  created_at INTEGER NOT NULL,
  $|  last_active_at INTEGER NOT NULL,
  $|  archived_at INTEGER,
  $|  archived_by TEXT,
  $|  shown_at INTEGER,
  $|  cwd TEXT,
  $|  original_runtime TEXT
  $|);
  $|-- The sessions shown (store.ts LIVE_SESSIONS): what the station's own periodic work goes over; the archived ones only grow.
  $|CREATE INDEX IF NOT EXISTS sessions_live ON sessions (last_active_at) WHERE archived_at IS NULL;
  $|-- The sessions running (store.ts ANY_RUNNING, RUNNING_SESSIONS).
  $|CREATE INDEX IF NOT EXISTS sessions_running ON sessions (key) WHERE running = 1;
  $|-- The sessions someone started lately (store.ts modelsUsedBy: the models they chose, as a chat is opened for them).
  $|CREATE INDEX IF NOT EXISTS sessions_by_creator ON sessions (created_by, created_at);
  $|CREATE TABLE IF NOT EXISTS threads (
  $|  id INTEGER PRIMARY KEY AUTOINCREMENT,
  $|  surface TEXT NOT NULL,
  $|  channel TEXT NOT NULL,
  $|  thread_ts TEXT NOT NULL,
  $|  title TEXT,
  $|  created_by TEXT,
  $|  created_at INTEGER NOT NULL,
  $|  archived_at INTEGER,
  $|  home TEXT,
  $|  hidden_at INTEGER,
  $|  hidden_by TEXT,
  $|  shown_at INTEGER,
  $|  auto_title TEXT,
  $|  auto_title_n INTEGER,
  $|  auto_title_changes INTEGER NOT NULL DEFAULT 0,
  $|  UNIQUE (surface, channel, thread_ts)
  $|);
  $|CREATE TABLE IF NOT EXISTS thread_sessions (
  $|  thread INTEGER NOT NULL,
  $|  session TEXT NOT NULL,
  $|  connect TEXT NOT NULL,
  $|  joined_at INTEGER NOT NULL,
  $|  left_at INTEGER,
  $|  PRIMARY KEY (thread, session)
  $|);
  $|CREATE INDEX IF NOT EXISTS thread_sessions_session ON thread_sessions (session);
  $|-- The latest Slack stop per bot, thread and session: retries must not stop a later turn.
  $|CREATE TABLE IF NOT EXISTS slack_stops (
  $|  session TEXT NOT NULL,
  $|  connect TEXT NOT NULL,
  $|  channel TEXT NOT NULL,
  $|  thread_ts TEXT NOT NULL,
  $|  event_ts TEXT NOT NULL,
  $|  turn_id TEXT,
  $|  PRIMARY KEY (session, connect, channel, thread_ts)
  $|);
  $|-- The threads at an address on any surface (store.ts threadsAt: session_send to a thread by its channel and ts).
  $|CREATE INDEX IF NOT EXISTS threads_at ON threads (channel, thread_ts);
  $|CREATE TABLE IF NOT EXISTS entries (
  $|  thread INTEGER NOT NULL,
  $|  n INTEGER NOT NULL,
  $|  kind TEXT NOT NULL,
  $|  target INTEGER,
  $|  ts TEXT,
  $|  author_kind TEXT NOT NULL,
  $|  author TEXT NOT NULL,
  $|  text TEXT,
  $|  attachments TEXT,
  $|  quotes TEXT,
  $|  declared TEXT,
  $|  at INTEGER NOT NULL,
  $|  client TEXT,
  $|  profile TEXT,
  $|  runtime TEXT,
  $|  options TEXT,
  $|  card TEXT,
  $|  PRIMARY KEY (thread, n)
  $|);
  $|CREATE UNIQUE INDEX IF NOT EXISTS entries_ts ON entries (thread, ts) WHERE ts IS NOT NULL;
  $|-- The first person to answer a card is found by its entry number, without reading intervening agent messages.
  $|CREATE INDEX IF NOT EXISTS entries_people_by_n ON entries (thread, n) WHERE author_kind = 'person' AND kind = 'message';
  $|-- The Router's idempotency key is committed with its message. Targets are kept only until delivery has been handed on.
  $|CREATE TABLE IF NOT EXISTS comma_router_once (
  $|  -- A retry may still be finishing while an expired key is reused. Never reuse its identity.
  $|  id INTEGER PRIMARY KEY AUTOINCREMENT,
  $|  key TEXT NOT NULL UNIQUE,
  $|  thread INTEGER NOT NULL,
  $|  n INTEGER NOT NULL,
  $|  at INTEGER NOT NULL,
  $|  pending INTEGER NOT NULL
  $|);
  $|CREATE INDEX IF NOT EXISTS comma_router_once_age ON comma_router_once (at);
  $|CREATE INDEX IF NOT EXISTS comma_router_once_thread ON comma_router_once (thread);
  $|CREATE TABLE IF NOT EXISTS comma_router_once_targets (
  $|  id INTEGER NOT NULL,
  $|  position INTEGER NOT NULL,
  $|  session TEXT NOT NULL,
  $|  PRIMARY KEY (id, position)
  $|) WITHOUT ROWID;
  $|CREATE INDEX IF NOT EXISTS comma_router_once_target_session ON comma_router_once_targets (session, id);
  $|CREATE TABLE IF NOT EXISTS deliveries (
  $|  thread INTEGER NOT NULL,
  $|  n INTEGER NOT NULL,
  $|  session TEXT NOT NULL,
  $|  delivered_at INTEGER,
  $|  PRIMARY KEY (thread, n, session)
  $|);
  $|CREATE INDEX IF NOT EXISTS deliveries_pending ON deliveries (session) WHERE delivered_at IS NULL;
  $|CREATE INDEX IF NOT EXISTS deliveries_session ON deliveries (session, thread);
  $|-- What a session took lately, as it was delivered (usage.ts TAKEN_SINCE: whom a turn from before turns said so worked
  $|-- for, as the usage counter reads its calls).
  $|CREATE INDEX IF NOT EXISTS deliveries_taken ON deliveries (session, delivered_at) WHERE delivered_at IS NOT NULL;
  $|CREATE TABLE IF NOT EXISTS reads (
  $|  viewer TEXT NOT NULL,
  $|  thread INTEGER NOT NULL,
  $|  n INTEGER NOT NULL,
  $|  at INTEGER NOT NULL,
  $|  PRIMARY KEY (viewer, thread)
  $|);
  $|-- A viewer's personal list visibility; this is independent of the thread's archived state.
  $|CREATE TABLE IF NOT EXISTS hidden_chats (
  $|  viewer TEXT NOT NULL,
  $|  thread INTEGER NOT NULL,
  $|  PRIMARY KEY (viewer, thread)
  $|);
  $|-- Notifications can be silenced independently of list visibility.
  $|CREATE TABLE IF NOT EXISTS muted_chats (
  $|  viewer TEXT NOT NULL,
  $|  thread INTEGER NOT NULL,
  $|  PRIMARY KEY (viewer, thread)
  $|);
  $|CREATE TABLE IF NOT EXISTS profile_status (
  $|  profile TEXT PRIMARY KEY,
  $|  check_json TEXT, checked_at INTEGER,
  $|  quota_json TEXT, quota_at INTEGER
  $|);
  $|CREATE TABLE IF NOT EXISTS bindings (
  $|  connect TEXT PRIMARY KEY,
  $|  session_key TEXT NOT NULL
  $|);
  $|CREATE TABLE IF NOT EXISTS turns (
  $|  id TEXT PRIMARY KEY,
  $|  session_key TEXT NOT NULL,
  $|  kind TEXT NOT NULL,
  $|  started_at INTEGER NOT NULL,
  $|  ended_at INTEGER,
  $|  outcome TEXT,
  $|  detail TEXT,
  $|  declared TEXT,
  $|  wait_seconds INTEGER,
  $|  wait_for TEXT,
  $|  need TEXT,
  $|  about_thread INTEGER,
  $|  about_n INTEGER,
  $|  about_ts TEXT,
  $|  wait_watch INTEGER
  $|);
  $|-- A session's turns, by when they started: every list of chats and sessions counts each session's turns and takes its
  $|-- latest (sessionStats); without it each scanned every turn of every session (some 160 ms a list on a busy station).
  $|CREATE INDEX IF NOT EXISTS turns_by_session ON turns (session_key, started_at);
  $|-- The turns running or ended lately (usage.ts usageActiveSessions, at each read of the usage counter: every few seconds
  $|-- while agents work): without it each read scanned every turn of the station's.
  $|CREATE INDEX IF NOT EXISTS turns_ended ON turns (ended_at);
  $|CREATE TABLE IF NOT EXISTS processes (
  $|  pgid INTEGER PRIMARY KEY,
  $|  started_at INTEGER NOT NULL,
  $|  runtime TEXT NOT NULL,
  $|  label TEXT NOT NULL
  $|);
  $|CREATE TABLE IF NOT EXISTS jobs (
  $|  id TEXT PRIMARY KEY,
  $|  session_key TEXT NOT NULL,
  $|  name TEXT NOT NULL,
  $|  command TEXT NOT NULL,
  $|  cwd TEXT NOT NULL,
  $|  port INTEGER,
  $|  token TEXT NOT NULL UNIQUE,
  $|  state TEXT NOT NULL,
  $|  pgid INTEGER,
  $|  exit_code INTEGER,
  $|  started_at INTEGER NOT NULL,
  $|  ended_at INTEGER,
  $|  restarts INTEGER NOT NULL DEFAULT 0,
  $|  log TEXT NOT NULL,
  $|  watch INTEGER NOT NULL DEFAULT 0,
  $|  queued INTEGER,
  $|  screen INTEGER,
  $|  size TEXT,
  $|  small INTEGER
  $|);
  $|CREATE INDEX IF NOT EXISTS jobs_by_session ON jobs (session_key);
  $|-- The jobs running (store.ts runningJobs, JOBS_RUNNING: every station_list that asks how busy this one is, the
  $|-- memory's watch every ten seconds, who keeps watch), and the services stopped on their own that hold their port
  $|-- (JOBS_UP: what keeps a session from being archived): without them each looked at every job the station ever ran.
  $|CREATE INDEX IF NOT EXISTS jobs_state ON jobs (state);
  $|CREATE INDEX IF NOT EXISTS jobs_up ON jobs (state, port);
  $|CREATE TABLE IF NOT EXISTS job_notices (
  $|  job_id TEXT NOT NULL,
  $|  at INTEGER NOT NULL,
  $|  text TEXT NOT NULL
  $|);
  $|CREATE INDEX IF NOT EXISTS job_notices_by_job ON job_notices (job_id, at);
  $|CREATE TABLE IF NOT EXISTS identities (
  $|  viewer TEXT NOT NULL,
  $|  slack_user TEXT NOT NULL,
  $|  at INTEGER NOT NULL,
  $|  PRIMARY KEY (viewer, slack_user)
  $|);
  $|-- Came after schema version 12 without changing it: made in place on open, like add_archive_columns' columns.
  $|-- The chats a viewer keeps at the top of their list, by their item's id (its session's key), and since when.
  $|CREATE TABLE IF NOT EXISTS pins (
  $|  viewer TEXT NOT NULL,
  $|  session TEXT NOT NULL,
  $|  at INTEGER NOT NULL,
  $|  PRIMARY KEY (viewer, session)
  $|);
  $|CREATE TABLE IF NOT EXISTS widget_states (
  $|  session TEXT NOT NULL,
  $|  path TEXT NOT NULL,
  $|  state TEXT NOT NULL,
  $|  model TEXT,
  $|  updated_at INTEGER NOT NULL,
  $|  told_at INTEGER,
  $|  PRIMARY KEY (session, path)
  $|);
  $|-- Pending decisions (an agent's block post with options) a viewer said they will not take up: not on their list
  $|-- any more, still pending for everyone else. By the post's thread and entry number.
  $|CREATE TABLE IF NOT EXISTS dismissed (
  $|  viewer TEXT NOT NULL,
  $|  thread INTEGER NOT NULL,
  $|  n INTEGER NOT NULL,
  $|  at INTEGER NOT NULL,
  $|  PRIMARY KEY (viewer, thread, n)
  $|);
  $|-- A viewer keeps a chat instead of receiving archive reminders.
  $|CREATE TABLE IF NOT EXISTS kept_chats (
  $|  viewer TEXT NOT NULL,
  $|  thread INTEGER NOT NULL,
  $|  PRIMARY KEY (viewer, thread)
  $|);
  $|-- A card closed by its viewer or withdrawn by its author.
  $|CREATE TABLE IF NOT EXISTS closed_cards (
  $|  thread INTEGER NOT NULL,
  $|  n INTEGER NOT NULL,
  $|  viewer TEXT NOT NULL,
  $|  at INTEGER NOT NULL,
  $|  PRIMARY KEY (thread, n)
  $|);
  $|-- What a person chose on a card with an option that closes it (closeCard): no message is sent and its agent is not
  $|-- woken, so the agent (session, the card's author) is told with what it is next handed (told_at). Kept after, for
  $|-- chat_history. ts: the card's post.
  $|CREATE TABLE IF NOT EXISTS card_choices (
  $|  thread INTEGER NOT NULL,
  $|  n INTEGER NOT NULL,
  $|  session TEXT NOT NULL,
  $|  ts TEXT,
  $|  viewer TEXT NOT NULL,
  $|  option TEXT NOT NULL,
  $|  at INTEGER NOT NULL,
  $|  told_at INTEGER,
  $|  PRIMARY KEY (thread, n)
  $|);
  $|CREATE INDEX IF NOT EXISTS card_choices_untold ON card_choices (session, at) WHERE told_at IS NULL;
  $|-- A chat moved here from a station retired (replica/retire.ts): what its agent is told of it, once, with what it is
  $|-- next handed (told_at), never woken for it.
  $|CREATE TABLE IF NOT EXISTS moved_notes (
  $|  session TEXT PRIMARY KEY,
  $|  text TEXT NOT NULL,
  $|  told_at INTEGER
  $|);
  $|-- What the agents spent (store/usage.rs): one row per model call their runtimes recorded, read from the transcripts,
  $|-- with whom and what it was for as it was then. Kept when its session goes: it was spent all the same. The one record
  $|-- of it: a chat's usage and the usage page are both added up from here (usage/module.ts, read/usage.ts). calls: how
  $|-- many calls the row is (a runtime that tells a turn's counts at once, Devin or Grok Build, says how many it made).
  $|-- context: of a main-thread row, what its session's context held after it (the prompt a call sent; what the runtime
  $|-- says of a turn's last call); context_window: the model's window where the runtime tells it. NULL: not told.
  $|CREATE TABLE IF NOT EXISTS usage (
  $|  id TEXT PRIMARY KEY,
  $|  at INTEGER NOT NULL,
  $|  session TEXT NOT NULL,
  $|  turn TEXT,
  $|  thread INTEGER,
  $|  person TEXT,
  $|  profile TEXT,
  $|  runtime TEXT NOT NULL,
  $|  model TEXT,
  $|  subagent INTEGER NOT NULL DEFAULT 0,
  $|  fast INTEGER NOT NULL DEFAULT 0,
  $|  input INTEGER NOT NULL,
  $|  cache_read INTEGER NOT NULL,
  $|  cache_write INTEGER NOT NULL,
  $|  cache_write_long INTEGER NOT NULL,
  $|  output INTEGER NOT NULL,
  $|  calls INTEGER NOT NULL DEFAULT 1,
  $|  context INTEGER,
  $|  context_window INTEGER
  $|);
  $|CREATE INDEX IF NOT EXISTS usage_at ON usage (at);
  $|-- A session's calls (session_usage, accounts.ts lastContexts) read without the rest.
  $|CREATE INDEX IF NOT EXISTS usage_session ON usage (session, at);
  $|-- The runtime sessions a session has run in, the first first, each with the profile it last ran on. The latest is
  $|-- sessions.runtime_session_id; one before it was left for a new one (its account changed), and its history goes on
  $|-- from theirs.
  $|CREATE TABLE IF NOT EXISTS runtime_sessions (
  $|  session_key TEXT NOT NULL,
  $|  id TEXT NOT NULL,
  $|  profile TEXT,
  $|  at INTEGER NOT NULL,
  $|  runtime TEXT,
  $|  PRIMARY KEY (session_key, id)
  $|);
  $|-- The session that went on with a runtime's session, by its id (rows.ts SESSION_OF_RUNTIME: a machine's session gone
  $|-- on with, Codex's fast mode).
  $|CREATE INDEX IF NOT EXISTS runtime_sessions_by_id ON runtime_sessions (id);
  $|CREATE INDEX IF NOT EXISTS sessions_by_runtime_id ON sessions (runtime_session_id) WHERE runtime_session_id IS NOT NULL;
  $|-- How far each transcript has been read for it.
  $|CREATE TABLE IF NOT EXISTS usage_files (
  $|  path TEXT PRIMARY KEY,
  $|  session TEXT,
  $|  offset INTEGER NOT NULL,
  $|  model TEXT
  $|);
  $|-- Chats an agent opened for another (chat_create, sessions/opened.ts): the session opened (child) and the one that
  $|-- opened it (parent), each by its station ('' for this one) and key, with the key the opener gave the call. The station
  $|-- of either keeps a row: the child's to tell its parent how its turns end, the parent's to know its children by. The
  $|-- child's also keeps what its parent was called then (opener_title, addOpenerTitle), for its chat's way back to it.
  $|-- led (addLedColumn): 1 for a chat its opener leads (chat_create for me), 0 for one opened for its person; NULL
  $|-- before it.
  $|CREATE TABLE IF NOT EXISTS opened_chats (
  $|  child_station TEXT NOT NULL,
  $|  child TEXT NOT NULL,
  $|  parent_station TEXT NOT NULL,
  $|  parent TEXT NOT NULL,
  $|  key TEXT NOT NULL,
  $|  title TEXT,
  $|  link TEXT,
  $|  state TEXT,
  $|  created_at INTEGER NOT NULL,
  $|  PRIMARY KEY (child_station, child)
  $|);
  $|CREATE INDEX IF NOT EXISTS opened_chats_by_key ON opened_chats (parent_station, parent, key, child_station);
  $|-- Chats shared with other workspaces (xshare/), by the session key their links name: to whom
  $|-- (to: JSON [{workspace, name}]), whether they may write in it, who changed it last and when.
  $|CREATE TABLE IF NOT EXISTS chat_shares (
  $|  session TEXT PRIMARY KEY,
  $|  shared TEXT NOT NULL,
  $|  write INTEGER NOT NULL DEFAULT 0,
  $|  by TEXT NOT NULL,
  $|  at INTEGER NOT NULL
  $|);
  $|-- Chats published as snapshots, gone with public sharing.
  $|DROP TABLE IF EXISTS published;
  $|-- Where chats were relayed (sessions/relay.ts): each connect's channel or group, by when a chat was last
  $|-- relayed there, so the picker offers the places used before first.
  $|CREATE TABLE IF NOT EXISTS relayed_to (
  $|  connect TEXT NOT NULL,
  $|  channel TEXT NOT NULL,
  $|  at INTEGER NOT NULL,
  $|  PRIMARY KEY (connect, channel)
  $|);
  $|-- The threads of this station's connects whose chats run on another station of the workspace (connects/remote.ts):
  $|-- every event of one goes there.
  $|CREATE TABLE IF NOT EXISTS connect_threads (
  $|  connect TEXT NOT NULL,
  $|  channel TEXT NOT NULL,
  $|  thread_ts TEXT NOT NULL,
  $|  station TEXT NOT NULL,
  $|  PRIMARY KEY (connect, channel, thread_ts)
  $|);
  $|-- Each task another station's chat ran here, as it began running (jobs/jobs.ts spawn: a remote: session's job, not
  $|-- a service started again): its job, when, and whose (its session's key, remote:<workspace>:<station>:<session>),
  $|-- kept 90 days whatever comes of the task and its session (store.ts noteRemoteRun), for what a workspace's card says of
  $|-- the tasks its chats ran on other stations (read/usage.ts remoteRuns).
  $|CREATE TABLE IF NOT EXISTS remote_runs (
  $|  job TEXT PRIMARY KEY,
  $|  at INTEGER NOT NULL,
  $|  session TEXT NOT NULL
  $|);
  $|-- How many entries each session's transcript has, as the station last read it while the session was at work
  $|-- (sessions/live.ts): its summary says so, and a device that missed some of them knows to read them.
  $|CREATE TABLE IF NOT EXISTS transcript_lengths (
  $|  session TEXT PRIMARY KEY,
  $|  n INTEGER NOT NULL
  $|);
  $|-- What each session's calls used (read/usage.ts SessionUsage, as JSON), as the usage counter recorded them
  $|-- (usage/module.ts keepUsage): its summary says it, so a device knows what an agent at rest used without following it.
  $|CREATE TABLE IF NOT EXISTS session_usage (
  $|  session TEXT PRIMARY KEY,
  $|  usage TEXT NOT NULL
  $|);
  $|-- The highest build each device a lock here names said as it asked (by its id in the lock; -1: none said) and when it
  $|-- was last seen, unix seconds (mesh/device-builds.ts): written only as the build rises or the day changes.
  $|CREATE TABLE IF NOT EXISTS device_builds (
  $|  id TEXT PRIMARY KEY,
  $|  build INTEGER NOT NULL,
  $|  at INTEGER NOT NULL
  $|);
  $|-- Since when the station keeps them (its first start with them), unix seconds: one row.
  $|CREATE TABLE IF NOT EXISTS device_builds_since (
  $|  one INTEGER PRIMARY KEY CHECK (one = 1),
  $|  at INTEGER NOT NULL
  $|);
  $|-- The models a person starred in a workspace, as their devices carry them (api/routes/stars.ts; the stars as JSON,
  $|-- the Stars of preset-records.ts, the core's): one row a person (their sub) a workspace, read by its key.
  $|CREATE TABLE IF NOT EXISTS model_stars (
  $|  ws TEXT NOT NULL,
  $|  sub TEXT NOT NULL,
  $|  stars TEXT NOT NULL,
  $|  PRIMARY KEY (ws, sub)
  $|);
  $|-- The chats handed from here to another station while both are up (replica/handover.ts): where each went, the
  $|-- workspace it was of here (null: the home one), its chat's thread here and there. Its rows here stay (a hand-back
  $|-- goes on from them); a device, a link or a letter naming it is told where it is.
  $|CREATE TABLE IF NOT EXISTS handed_over (
  $|  session TEXT PRIMARY KEY,
  $|  station TEXT NOT NULL,
  $|  ws TEXT,
  $|  thread INTEGER,
  $|  there INTEGER,
  $|  at INTEGER NOT NULL
  $|);
  $|-- What a chat being handed here has put in so far (the ctx of replica/handover.ts In), written in the same transaction as
  $|-- each page of its rows: a stop between a page and the hand-over's own file leaves nothing a drop does not take out.
  $|-- Gone once it is shown or dropped.
  $|CREATE TABLE IF NOT EXISTS handover_in (
  $|  id TEXT PRIMARY KEY,
  $|  ctx TEXT NOT NULL
  $|);
  $|
)

///|
/// Each message as it reads now: its latest edit's words, files and quotes.
pub let merged : String =
(
  $|CREATE VIEW merged AS
  $|  SELECT m.thread, m.n, m.ts, m.author_kind, m.author,
  $|    CASE WHEN e.n IS NULL THEN m.text ELSE e.text END AS text,
  $|    CASE WHEN e.n IS NULL THEN m.attachments ELSE e.attachments END AS attachments,
  $|    CASE WHEN e.n IS NULL THEN m.quotes ELSE e.quotes END AS quotes,
  $|    m.declared, m.client, m.agent_identity, m.at AS created_at, e.at AS edited_at, m.letter
  $|  FROM entries m
  $|  LEFT JOIN entries e ON e.thread = m.thread
  $|    AND e.n = (SELECT MAX(x.n) FROM entries x WHERE x.thread = m.thread AND x.target = m.n)
  $|  WHERE m.kind = 'message';
)

///|
/// The edit lookup the `merged` view reads (`MERGED`'s), replaced by the older store's prepared one.
let merged_edit_lookup : String = "SELECT MAX(x.n) FROM entries x WHERE x.thread = m.thread AND x.target = m.n"

///|
fn has_edit_index(db : @sql.Db) -> Bool raise {
  exists(db, "index", "entries_edits")
}

///|
/// The merged view's text (none: "").
fn view_sql(db : @sql.Db) -> String raise {
  sql_of(db, "view", "merged").unwrap_or("")
}

///|
/// The view as made for this store: with the older store's prepared edit lookup where it uses one.
fn merged_for(db : @sql.Db, legacy : Bool) -> String raise {
  if legacy {
    merged.replace(old=merged_edit_lookup, new=legacy_edit_latest("m.thread", "m.n", "1", legacy_edits_use_old_index(db)))
  } else {
    merged
  }
}

///|
/// A view's index can be removed by another connection while the station is running (schema.ts
/// `repairMergedEditLookup`, the writer's `Readers.repairEdits`): switched under a writer, the old-store lookup installed
/// where needed, without building an index over the whole store at once.
pub fn repair_merged_edit_lookup(db : @sql.Db) -> Unit raise {
  let needs_repair = (sql : String) => if sql.contains("legacy_edit_meta") {
    sql.contains("INDEXED BY entries_target") && !has_old_edit_index(db)
  } else {
    !has_edit_index(db)
  }
  let view_needs_repair = needs_repair(view_sql(db))
  if !view_needs_repair && !widget_source_before_add_needs_repair(db) {
    return
  }
  if view_needs_repair && !has_edit_index(db) {
    ignore(install_legacy_edits(db, prefer_native=true))
  }
  immediate(db, () => {
    if needs_repair(view_sql(db)) {
      if has_legacy_edits(db) && legacy_edits_use_old_index(db) && !has_old_edit_index(db) {
        ignore(db.run("UPDATE legacy_edit_meta SET old_index=0 WHERE id=1", []))
      }
      db.exec("DROP VIEW IF EXISTS merged; \{merged_for(db, uses_legacy_edits(db))}")
    }
    repair_widget_source_before_add(db)
  })
}

///|
/// A small store builds the native edit lookup under one writer; a larger older one prepares it in bounded steps.
fn add_edit_index(db : @sql.Db) -> Unit raise {
  if has_edit_index(db) || has_legacy_edits(db) {
    return
  }
  let mut prepare = false
  immediate(db, () => if !has_edit_index(db) && !has_legacy_edits(db) {
    if !some_row(db, "SELECT 1 FROM entries LIMIT 1 OFFSET 63") {
      db.exec("CREATE INDEX IF NOT EXISTS entries_edits ON entries (thread, target, n) WHERE target IS NOT NULL")
    } else {
      prepare = true
    }
  })
  if prepare {
    ignore(install_legacy_edits(db, prefer_native=true))
  }
}

///|
/// Some stations built this index while adding per-transcript runtimes (schema.ts `hasRuntimeOrderIndex`).
fn has_runtime_order_index(db : @sql.Db) -> Bool raise {
  some_row(db, "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'runtime_sessions_ordered'")
}

///|
/// Older records with no runtime belong to the session's original runtime, remembered on the session as it first
/// changes (schema.ts `addRuntimeSessionRuntime`).
fn add_runtime_session_runtime(db : @sql.Db) -> Unit raise {
  if !has(db, "runtime_sessions", "runtime") {
    db.exec("ALTER TABLE runtime_sessions ADD COLUMN runtime TEXT")
  }
  if !has(db, "sessions", "original_runtime") {
    db.exec("ALTER TABLE sessions ADD COLUMN original_runtime TEXT")
  }
  let first = if has_runtime_order_index(db) {
    "COALESCE((SELECT runtime FROM runtime_sessions INDEXED BY runtime_sessions_ordered WHERE session_key = OLD.key ORDER BY at, rowid LIMIT 1), OLD.runtime)"
  } else {
    "OLD.runtime"
  }
  db.exec(
(
  $|CREATE TRIGGER IF NOT EXISTS sessions_original_runtime AFTER UPDATE OF runtime ON sessions
  $|    WHEN OLD.runtime IS NOT NEW.runtime AND OLD.original_runtime IS NULL AND NEW.original_runtime IS NULL BEGIN
  $|      UPDATE sessions SET original_runtime = \{first} WHERE key = NEW.key AND original_runtime IS NULL;
  $|    END
)
  )
}

///|
/// add_archive_columns: the columns archiving came with and those after it on sessions and turns; as they come, each
/// session's first chat on the page taken as its own, and chats of sessions archived then as archived with them.
fn add_archive_columns(db : @sql.Db) -> Unit raise {
  for column in [
    ("archived_by", "TEXT"),
    ("shown_at", "INTEGER"),
    ("cwd", "TEXT"),
    ("fast", "INTEGER"),
    ("speed", "TEXT"),
    ("tui", "INTEGER"),
    ("afresh", "INTEGER"),
    ("context", "INTEGER"),
    ("context_before", "INTEGER"),
    ("profiles", "TEXT"),
    ("compactions", "INTEGER"),
  ] {
    let (name, kind) = column
    if !has(db, "sessions", name) {
      db.exec("ALTER TABLE sessions ADD COLUMN \{name} \{kind}")
    }
  }
  if !has(db, "turns", "wait_seconds") {
    db.exec("ALTER TABLE turns ADD COLUMN wait_seconds INTEGER")
  }
  if !has(db, "turns", "wait_for") {
    db.exec("ALTER TABLE turns ADD COLUMN wait_for TEXT")
  }
  if !has(db, "sessions", "told_notes") {
    db.exec("ALTER TABLE sessions ADD COLUMN told_notes INTEGER")
  }
  if !has(db, "turns", "need") {
    db.exec("ALTER TABLE turns ADD COLUMN need TEXT")
  }
  for column in [("about_thread", "INTEGER"), ("about_n", "INTEGER"), ("about_ts", "TEXT")] {
    let (name, kind) = column
    if !has(db, "turns", name) {
      db.exec("ALTER TABLE turns ADD COLUMN \{name} \{kind}")
    }
  }
  for column in [("profile", "TEXT"), ("person", "TEXT"), ("thread", "INTEGER")] {
    let (name, kind) = column
    if !has(db, "turns", name) {
      db.exec("ALTER TABLE turns ADD COLUMN \{name} \{kind}")
    }
  }
  if has(db, "threads", "home") {
    return
  }
  db.exec(
(
  $|BEGIN;
  $|     ALTER TABLE threads ADD COLUMN home TEXT;
  $|     ALTER TABLE threads ADD COLUMN hidden_at INTEGER;
  $|     ALTER TABLE threads ADD COLUMN hidden_by TEXT;
  $|     ALTER TABLE threads ADD COLUMN shown_at INTEGER;
  $|     UPDATE threads SET home = (SELECT ts.session FROM thread_sessions ts WHERE ts.thread = threads.id ORDER BY ts.joined_at, ts.rowid LIMIT 1)
  $|     WHERE surface = '\{stillfail_surface}' AND id = (
  $|       SELECT MIN(t2.id) FROM threads t2 JOIN thread_sessions ts2 ON ts2.thread = t2.id
  $|       WHERE t2.surface = '\{stillfail_surface}' AND ts2.session = (SELECT ts.session FROM thread_sessions ts WHERE ts.thread = threads.id ORDER BY ts.joined_at, ts.rowid LIMIT 1));
  $|     UPDATE sessions SET archived_by = 'manual' WHERE archived_at IS NOT NULL AND archived_by IS NULL;
  $|     UPDATE threads SET hidden_at = (SELECT archived_at FROM sessions WHERE key = threads.home), hidden_by = 'manual'
  $|     WHERE home IN (SELECT key FROM sessions WHERE archived_at IS NOT NULL);
  $|     COMMIT;
)
  )
}

///|
/// The indexes on the threads' columns that came with homes, made once those are there.
fn add_thread_indexes(db : @sql.Db) -> Unit raise {
  db.exec(
(
  $|CREATE INDEX IF NOT EXISTS threads_home ON threads (home) WHERE home IS NOT NULL;
  $|    CREATE INDEX IF NOT EXISTS threads_own ON threads (surface) WHERE home IS NULL AND hidden_at IS NULL;
)
  )
}

///|
/// add_client_column: the column a message's app came with (entries.client) and those after it, and the `merged` view
/// made anew with them.
fn add_client_column(db : @sql.Db) -> Unit raise {
  if !has(db, "entries", "agent_identity") {
    db.exec("ALTER TABLE entries ADD COLUMN agent_identity TEXT")
  }
  if !has(db, "entries", "client") {
    db.exec("ALTER TABLE entries ADD COLUMN client TEXT")
  }
  if !has(db, "entries", "profile") {
    db.exec("ALTER TABLE entries ADD COLUMN profile TEXT")
  }
  if !has(db, "entries", "runtime") {
    db.exec("ALTER TABLE entries ADD COLUMN runtime TEXT")
  }
  if !has(db, "entries", "options") {
    db.exec("ALTER TABLE entries ADD COLUMN options TEXT")
  }
  if !has(db, "entries", "card") {
    db.exec("ALTER TABLE entries ADD COLUMN card TEXT")
  }
  add_login_card_index(db)
  if !has(db, "entries", "change") {
    db.exec("ALTER TABLE entries ADD COLUMN change TEXT")
  }
  db.exec("CREATE INDEX IF NOT EXISTS entries_options ON entries (thread, n) WHERE options IS NOT NULL")
  db.exec("CREATE INDEX IF NOT EXISTS entries_cards ON entries (thread, n) WHERE card IS NOT NULL")
  let legacy_edits = uses_legacy_edits(db)
  let view = view_sql(db)
  let uses_legacy = view.contains("legacy_edit_meta")
  let obsolete_old_view = !uses_legacy && view.contains("INDEXED BY entries_target")
  if !has(db, "merged", "client") ||
    !has(db, "merged", "agent_identity") ||
    !has(db, "merged", "letter") ||
    legacy_edits != uses_legacy ||
    obsolete_old_view {
    db.exec("BEGIN; DROP VIEW IF EXISTS merged; \{merged_for(db, legacy_edits)} COMMIT;")
  }
}

///|
/// Keep the native index for older connections and prepare a per-login lookup in bounded batches.
fn add_login_card_index(db : @sql.Db) -> Unit raise {
  let native = () => exists(db, "index", "entries_login_cards")
  if has_legacy_login_cards(db) {
    return
  }
  if !native() {
    immediate(db, () => if !has_legacy_login_cards(db) &&
      !native() &&
      !some_row(db, "SELECT 1 FROM entries LIMIT 1 OFFSET 63") {
      db.exec("CREATE INDEX IF NOT EXISTS entries_login_cards ON entries (thread, n) WHERE card LIKE '%\"login\"%'")
    })
  }
  ignore(install_legacy_login_cards(db))
}

///|
/// The column letters came with (entries.letter): the letters known before by their heading alone (`来自 …：`, by an
/// agent not of the thread) marked once as the column comes, with the chat their heading names.
fn add_letter_column(db : @sql.Db) -> Unit raise {
  if has(db, "entries", "letter") {
    return
  }
  let version = () => num(first_row(db, "PRAGMA main.data_version"), "data_version")
  let read_headings = () => db.all(
(
  $|SELECT thread, n, text FROM entries e WHERE kind = 'message' AND author_kind = 'agent' AND (text LIKE '来自 %' OR text LIKE 'From %')
  $|     AND author NOT IN (SELECT session FROM thread_sessions WHERE thread = e.thread)
)
    , [],
  )
  let read_version = version()
  let mut before = read_headings()
  immediate(db, () => if !has(db, "entries", "letter") {
    if version() != read_version {
      before = read_headings()
    }
    db.exec("ALTER TABLE entries ADD COLUMN letter TEXT")
    db.exec("CREATE INDEX IF NOT EXISTS entries_letters ON entries (thread, n) WHERE letter IS NOT NULL")
    for r in before {
      let text = match r.get("text") {
        Some(String(t)) => t
        _ => ""
      }
      let (title, link) = headed_from(text)
      let letter = @jsjson.stringify(
        Obj([
          ("way", Str("in")),
          ("title", Str(title)),
          ("link", match link {
            Some(l) => Str(l)
            None => Null
          }),
        ]),
      )
      ignore(
        db.run("UPDATE entries SET letter = ? WHERE thread = ? AND n = ?", [
          Json::string(letter),
          r.get("thread").unwrap_or(Json::null()),
          r.get("n").unwrap_or(Json::null()),
        ]),
      )
    }
  })
}

///|
/// The chat a letter's heading names (schema.ts `headedFrom`): `来自 [title](link)：`, Slack's `From <link|title>:`, or
/// a title alone.
pub fn headed_from(text : String) -> (String, String?) {
  let all = text.to_array()
  let mut end = 0
  while end < all.length() && all[end] != '\n' {
    end += 1
  }
  let first = all[0:end].to_owned()
  let line = if first.length() >= 3 && first[0] == '来' && first[1] == '自' && first[2] == ' ' {
    String::from_array(first[3:])
  } else if first.length() >= 5 && String::from_array(first[0:5]) == "From " {
    String::from_array(first[5:])
  } else {
    String::from_array(first)
  }
  let head = without_colon_end(line)
  // ^\[(.*)\]\((\S+)\)$ (greedy: the last "](" that leaves a link with no white space)
  if head.has_prefix("[") && head.has_suffix(")") {
    let chars = head.to_array()
    let mut at = chars.length() - 2
    while at >= 1 {
      if chars[at] == '(' && chars[at - 1] == ']' {
        let link = String::from_array(chars[at + 1:chars.length() - 1])
        if link != "" && !link.to_array().any(js_space) {
          return (String::from_array(chars[1:at - 1]), Some(link))
        }
      }
      at -= 1
    }
  }
  // ^<([^|>]+)\|(.*)>$
  if head.has_prefix("<") && head.has_suffix(">") {
    let chars = head.to_array()
    let mut bar = 1
    while bar < chars.length() - 1 && chars[bar] != '|' && chars[bar] != '>' {
      bar += 1
    }
    if bar > 1 && bar < chars.length() - 1 && chars[bar] == '|' {
      return (String::from_array(chars[bar + 1:chars.length() - 1]), Some(String::from_array(chars[1:bar])))
    }
  }
  (head, None)
}

///|
/// JavaScript's `\s`: its white space and line terminators.
fn js_space(c : Char) -> Bool {
  @jsjson.is_js_space(c.to_int())
}

///|
/// `.replace(/(：|:)\s*$/, "")`: the first colon from which only white space follows, and what follows it, left out.
fn without_colon_end(s : String) -> String {
  let chars = s.to_array()
  for i, c in chars {
    if c == '：' || c == ':' {
      let mut rest = true
      for j = i + 1; j < chars.length(); j = j + 1 {
        if !js_space(chars[j]) {
          rest = false
          break
        }
      }
      if rest {
        return String::from_array(chars[0:i])
      }
    }
  }
  s
}

///|
/// add_auto_title_columns: the columns a chat's own name from its agent came with (threads.auto_title…).
fn add_auto_title_columns(db : @sql.Db) -> Unit raise {
  for column in [("auto_title", "TEXT"), ("auto_title_n", "INTEGER"), ("auto_title_changes", "INTEGER NOT NULL DEFAULT 0")] {
    let (name, kind) = column
    if !has(db, "threads", name) {
      db.exec("ALTER TABLE threads ADD COLUMN \{name} \{kind}")
    }
  }
}

///|
/// A column added where the table has none of it yet (the add_*_column steps of one column).
fn add_column(db : @sql.Db, table : String, name : String, kind : String) -> Unit raise {
  if !has(db, table, name) {
    db.exec("ALTER TABLE \{table} ADD COLUMN \{name} \{kind}")
  }
}

///|
/// add_watch_column (jobs.watch).
fn add_watch_column(db : @sql.Db) -> Unit raise {
  add_column(db, "jobs", "watch", "INTEGER NOT NULL DEFAULT 0")
}

///|
/// The columns the station's queue came with (jobs.queued, jobs.screen).
fn add_queue_columns(db : @sql.Db) -> Unit raise {
  add_column(db, "jobs", "queued", "INTEGER")
  add_column(db, "jobs", "screen", "INTEGER")
}

///|
/// A job that asked for the single small-work slot (jobs.small).
fn add_small_job_column(db : @sql.Db) -> Unit raise {
  add_column(db, "jobs", "small", "INTEGER")
}

///|
/// turns.wait_watch.
fn add_wait_watch_column(db : @sql.Db) -> Unit raise {
  add_column(db, "turns", "wait_watch", "INTEGER")
}

///|
/// opened_chats.opener_title.
fn add_opener_title(db : @sql.Db) -> Unit raise {
  add_column(db, "opened_chats", "opener_title", "TEXT")
}

///|
/// opened_chats.led.
fn add_led_column(db : @sql.Db) -> Unit raise {
  add_column(db, "opened_chats", "led", "INTEGER")
}

///|
/// thread_sessions.left_at.
fn add_left_column(db : @sql.Db) -> Unit raise {
  add_column(db, "thread_sessions", "left_at", "INTEGER")
}

///|
/// jobs.size.
fn add_size_column(db : @sql.Db) -> Unit raise {
  add_column(db, "jobs", "size", "TEXT")
}

///|
/// The triggers that add a call to its session's totals and take one away, each by the calls it is (usage.calls).
let usage_totals_kept : String =
(
  $|
  $|CREATE TRIGGER usage_totals_add AFTER INSERT ON usage BEGIN
  $|  INSERT INTO usage_totals (session, runtime, model, fast, calls, input, cache_read, cache_write, cache_write_long, output)
  $|  VALUES (NEW.session, NEW.runtime, COALESCE(NEW.model, ''), NEW.fast, NEW.calls, NEW.input, NEW.cache_read, NEW.cache_write, NEW.cache_write_long, NEW.output)
  $|  ON CONFLICT (session, runtime, model, fast) DO UPDATE SET calls = calls + excluded.calls, input = input + excluded.input, cache_read = cache_read + excluded.cache_read,
  $|    cache_write = cache_write + excluded.cache_write, cache_write_long = cache_write_long + excluded.cache_write_long, output = output + excluded.output;
  $|END;
  $|CREATE TRIGGER usage_totals_drop AFTER DELETE ON usage BEGIN
  $|  UPDATE usage_totals SET calls = calls - OLD.calls, input = input - OLD.input, cache_read = cache_read - OLD.cache_read, cache_write = cache_write - OLD.cache_write,
  $|    cache_write_long = cache_write_long - OLD.cache_write_long, output = output - OLD.output
  $|  WHERE session = OLD.session AND runtime = OLD.runtime AND model = COALESCE(OLD.model, '') AND fast = OLD.fast;
  $|END;
  $|
)

///|
let usage_totals : String =
(
  $|
  $|CREATE TABLE usage_totals (
  $|  session TEXT NOT NULL,
  $|  runtime TEXT NOT NULL,
  $|  model TEXT NOT NULL,
  $|  fast INTEGER NOT NULL,
  $|  calls INTEGER NOT NULL,
  $|  input INTEGER NOT NULL,
  $|  cache_read INTEGER NOT NULL,
  $|  cache_write INTEGER NOT NULL,
  $|  cache_write_long INTEGER NOT NULL,
  $|  output INTEGER NOT NULL,
  $|  PRIMARY KEY (session, runtime, model, fast)
  $|) WITHOUT ROWID;
  $|
)

///|
let usage_totals_normal : String =
(
  $|
  $|\{usage_totals_kept}
  $|CREATE TRIGGER usage_totals_grow AFTER UPDATE OF output ON usage WHEN NEW.output <> OLD.output BEGIN
  $|  UPDATE usage_totals SET output = output + NEW.output - OLD.output
  $|  WHERE session = NEW.session AND runtime = NEW.runtime AND model = COALESCE(NEW.model, '') AND fast = NEW.fast;
  $|END;
  $|
)

///|
/// The columns usage came with as the one record of what was spent (usage.calls, context, context_window), the
/// triggers made before them made anew to read them.
fn add_usage_columns(db : @sql.Db) -> Unit raise {
  if has(db, "usage", "calls") {
    return
  }
  immediate(db, () => if !has(db, "usage", "calls") {
    db.exec(
(
  $|ALTER TABLE usage ADD COLUMN calls INTEGER NOT NULL DEFAULT 1;
  $|        ALTER TABLE usage ADD COLUMN context INTEGER;
  $|        ALTER TABLE usage ADD COLUMN context_window INTEGER;
)
    )
    let made = (name : String) => some_row(
      db,
      "SELECT 1 FROM sqlite_master WHERE type = 'trigger' AND name = ?",
      params=[Json::string(name)],
    )
    if made("usage_totals_add") {
      db.exec("DROP TRIGGER usage_totals_add; DROP TRIGGER usage_totals_drop; \{usage_totals_kept}")
    }
    if made("usage_compactions_add") {
      db.exec("DROP TRIGGER usage_compactions_add; \{usage_compactions_kept}")
    }
  })
}

///|
/// An empty total installed; where calls predate it, the coverage marked (an incremental source follows, installed
/// after the detail structures). A new database uses the ordinary triggers.
fn add_usage_totals(db : @sql.Db) -> Unit raise {
  let made = () => exists(db, "table", "usage_totals")
  if made() {
    return
  }
  immediate(db, () => if !made() {
    let old = some_row(db, "SELECT 1 FROM usage LIMIT 1")
    db.exec(
(
  $|DROP TRIGGER IF EXISTS usage_totals_add; DROP TRIGGER IF EXISTS usage_totals_drop;
  $|        DROP TRIGGER IF EXISTS usage_totals_grow; \{usage_totals}
)
    )
    db.exec(
      if old {
        "CREATE TABLE usage_totals_incremental (id INTEGER PRIMARY KEY CHECK (id = 1)); INSERT INTO usage_totals_incremental VALUES (1);"
      } else {
        usage_totals_normal
      },
    )
  })
}

///|
/// The trigger that keeps the compactions as each main-thread call is recorded.
let usage_compactions_kept : String =
(
  $|
  $|CREATE TRIGGER usage_compactions_add AFTER INSERT ON usage WHEN NEW.subagent = 0 AND NEW.model IS NOT NULL BEGIN
  $|  INSERT INTO usage_compactions
  $|    SELECT NEW.at, NEW.model, p.context FROM (
  $|      SELECT b.context, b.profile, b.model FROM usage b
  $|      WHERE b.session = NEW.session AND b.subagent = 0 AND b.at < NEW.at ORDER BY b.at DESC LIMIT 1) p
  $|    WHERE p.context >= \{compacted_from} AND NEW.context * 2 < p.context AND p.profile IS NEW.profile AND p.model IS NEW.model;
  $|END;
  $|
)

///|
/// The old append-only compaction table, retained for older station processes.
let usage_compactions : String =
(
  $|
  $|CREATE TABLE usage_compactions (
  $|  at INTEGER NOT NULL,
  $|  model TEXT NOT NULL,
  $|  point INTEGER NOT NULL
  $|);
  $|CREATE INDEX usage_compactions_at ON usage_compactions (at);
  $|\{usage_compactions_kept}
)

///|
/// The old compatibility table made empty where it is not; old compactions never reconstructed.
fn add_usage_compactions(db : @sql.Db) -> Unit raise {
  let made = () => exists(db, "table", "usage_compactions")
  if made() {
    return
  }
  immediate(db, () => if !made() { db.exec(usage_compactions) })
}

///|
/// The first row of each of a session's threads by (session, thread, rowid); the earliest of those.
fn first_delivery_rowid(session : String) -> String {
(
  $|WITH RECURSIVE first_threads(thread) AS (
  $|  VALUES ((SELECT thread FROM deliveries INDEXED BY deliveries_session WHERE session = \{session} ORDER BY thread LIMIT 1))
  $|  UNION ALL
  $|  SELECT (SELECT thread FROM deliveries INDEXED BY deliveries_session WHERE session = \{session} AND thread > first_threads.thread ORDER BY thread LIMIT 1)
  $|    FROM first_threads WHERE thread IS NOT NULL
  $|)
  $|SELECT MIN((SELECT rowid FROM deliveries INDEXED BY deliveries_session WHERE session = \{session} AND thread = first_threads.thread ORDER BY rowid LIMIT 1))
  $|FROM first_threads WHERE thread IS NOT NULL
)
}

///|
/// A session's first delivery (schema.ts `firstDelivery`).
pub fn first_delivery(session : String) -> String {
(
  $|SELECT thread, n FROM deliveries WHERE rowid = (\{first_delivery_rowid(session)})
)
}

///|
let session_first_initial : String =
(
  $|WITH RECURSIVE first_sessions(session) AS (
  $|  VALUES ((SELECT session FROM deliveries INDEXED BY deliveries_session ORDER BY session LIMIT 1))
  $|  UNION ALL
  $|  SELECT (SELECT session FROM deliveries INDEXED BY deliveries_session WHERE session > first_sessions.session ORDER BY session LIMIT 1)
  $|    FROM first_sessions WHERE session IS NOT NULL
  $|)
  $|INSERT INTO session_first (session, thread, n)
  $|SELECT s.session, d.thread, d.n FROM first_sessions s
  $|CROSS JOIN deliveries d ON d.rowid = COALESCE(
  $|  (SELECT MIN(seq) FROM (SELECT rowid AS seq FROM deliveries INDEXED BY deliveries_session WHERE session = s.session LIMIT 65) HAVING COUNT(*) <= 64),
  $|  (SELECT rowid FROM deliveries WHERE rowid = (SELECT MIN(rowid) FROM deliveries) AND session = s.session),
  $|  (\{first_delivery_rowid("s.session")}))
  $|WHERE s.session IS NOT NULL
)

///|
let session_first_add : String =
(
  $|CREATE TRIGGER session_first_add AFTER INSERT ON deliveries BEGIN
  $|  -- REPLACE may remove the first delivery without firing DELETE triggers; its replacement has a new rowid.
  $|  UPDATE session_first SET (thread, n) = (\{first_delivery("NEW.session")})
  $|    WHERE session = NEW.session AND thread = NEW.thread AND n = NEW.n AND EXISTS
  $|      (SELECT 1 FROM (\{first_delivery("NEW.session")}) first WHERE first.thread IS NOT NEW.thread OR first.n IS NOT NEW.n);
  $|  INSERT INTO session_first SELECT NEW.session, NEW.thread, NEW.n
  $|    WHERE NOT EXISTS (SELECT 1 FROM session_first WHERE session = NEW.session);
  $|END;
)

///|
let session_first_drop : String =
(
  $|CREATE TRIGGER session_first_drop AFTER DELETE ON deliveries
  $|  WHEN EXISTS (SELECT 1 FROM session_first WHERE session = OLD.session AND thread = OLD.thread AND n = OLD.n) BEGIN
  $|  DELETE FROM session_first WHERE session = OLD.session;
  $|  INSERT INTO session_first (session, thread, n)
  $|    SELECT OLD.session, next.thread, next.n FROM (\{first_delivery("OLD.session")}) next
  $|    WHERE NOT EXISTS (SELECT 1 FROM session_first WHERE session = OLD.session);
  $|END;
)

///|
let entries_said_index : String = "CREATE INDEX IF NOT EXISTS entries_said ON entries (thread, n, author_kind, author, letter) WHERE kind = 'message' AND letter IS NULL"

///|
let thread_state_scan : String =
(
  $|INSERT INTO thread_state
  $|  SELECT thread, MAX(n), MAX(CASE WHEN kind = 'message' AND letter IS NULL THEN n END),
  $|    MIN(CASE WHEN kind = 'message' AND author_kind = 'person' THEN n END), COUNT(CASE WHEN kind = 'message' AND letter IS NOT NULL THEN 1 END)
  $|  FROM entries GROUP BY thread;
)

///|
pub let thread_state_seek : String =
(
  $|WITH RECURSIVE state_threads(thread) AS (
  $|  VALUES ((SELECT thread FROM entries ORDER BY thread LIMIT 1))
  $|  UNION ALL
  $|  SELECT (SELECT thread FROM entries WHERE thread > state_threads.thread ORDER BY thread LIMIT 1)
  $|    FROM state_threads WHERE thread IS NOT NULL
  $|)
  $|INSERT INTO thread_state (thread, last_n, said_n, person_n, letters)
  $|SELECT t.thread,
  $|  (SELECT e.n FROM entries AS e WHERE e.thread = t.thread ORDER BY e.n DESC LIMIT 1),
  $|  (SELECT e.n FROM entries AS e INDEXED BY entries_said WHERE e.thread = t.thread AND e.kind = 'message' AND e.letter IS NULL ORDER BY e.n DESC LIMIT 1),
  $|  (SELECT e.n FROM entries AS e INDEXED BY entries_people_by_n WHERE e.thread = t.thread AND e.kind = 'message' AND e.author_kind = 'person' ORDER BY e.n LIMIT 1),
  $|  (SELECT COUNT(*) FROM entries AS e INDEXED BY entries_letters WHERE e.thread = t.thread AND e.kind = 'message' AND e.letter IS NOT NULL)
  $|FROM state_threads t WHERE t.thread IS NOT NULL;
)

///|
fn list_state(thread_state : String) -> String {
(
  $|
  $|CREATE TABLE thread_state (
  $|  thread INTEGER PRIMARY KEY,
  $|  last_n INTEGER NOT NULL,
  $|  said_n INTEGER,
  $|  person_n INTEGER,
  $|  letters INTEGER NOT NULL
  $|);
  $|CREATE TABLE thread_people (
  $|  thread INTEGER NOT NULL,
  $|  author TEXT NOT NULL,
  $|  first_n INTEGER NOT NULL,
  $|  PRIMARY KEY (thread, author)
  $|) WITHOUT ROWID;
  $|CREATE TABLE session_first (
  $|  session TEXT PRIMARY KEY,
  $|  thread INTEGER NOT NULL,
  $|  n INTEGER NOT NULL
  $|) WITHOUT ROWID;
  $|\{thread_state}
  $|INSERT INTO thread_people
  $|  SELECT thread, author, MIN(n) FROM entries WHERE kind = 'message' AND author_kind = 'person' GROUP BY thread, author;
  $|\{session_first_initial};
  $|CREATE TRIGGER thread_state_add AFTER INSERT ON entries BEGIN
  $|  INSERT INTO thread_state VALUES (NEW.thread, NEW.n,
  $|      CASE WHEN NEW.kind = 'message' AND NEW.letter IS NULL THEN NEW.n END,
  $|      CASE WHEN NEW.kind = 'message' AND NEW.author_kind = 'person' THEN NEW.n END,
  $|      CASE WHEN NEW.kind = 'message' AND NEW.letter IS NOT NULL THEN 1 ELSE 0 END)
  $|  ON CONFLICT (thread) DO UPDATE SET
  $|    last_n = MAX(last_n, excluded.last_n),
  $|    said_n = CASE WHEN excluded.said_n IS NULL THEN said_n WHEN said_n IS NULL THEN excluded.said_n ELSE MAX(said_n, excluded.said_n) END,
  $|    person_n = CASE WHEN excluded.person_n IS NULL THEN person_n WHEN person_n IS NULL THEN excluded.person_n ELSE MIN(person_n, excluded.person_n) END,
  $|    letters = letters + excluded.letters;
  $|  INSERT INTO thread_people SELECT NEW.thread, NEW.author, NEW.n WHERE NEW.kind = 'message' AND NEW.author_kind = 'person'
  $|  ON CONFLICT (thread, author) DO UPDATE SET first_n = MIN(first_n, excluded.first_n);
  $|END;
  $|CREATE TRIGGER thread_state_drop AFTER DELETE ON entries BEGIN
  $|  DELETE FROM thread_state WHERE thread = OLD.thread;
  $|  DELETE FROM thread_people WHERE thread = OLD.thread;
  $|END;
  $|\{session_first_add}
  $|\{session_first_drop}
  $|
)
}

///|
/// The letters' own log.
let letters : String =
(
  $|
  $|CREATE TABLE letters (
  $|  thread INTEGER NOT NULL,
  $|  n INTEGER NOT NULL,
  $|  ts TEXT NOT NULL,
  $|  author_kind TEXT NOT NULL,
  $|  author TEXT NOT NULL,
  $|  text TEXT NOT NULL,
  $|  attachments TEXT,
  $|  at INTEGER NOT NULL,
  $|  letter TEXT NOT NULL,
  $|  PRIMARY KEY (thread, n)
  $|);
  $|CREATE TABLE letter_deliveries (
  $|  thread INTEGER NOT NULL,
  $|  n INTEGER NOT NULL,
  $|  session TEXT NOT NULL,
  $|  delivered_at INTEGER,
  $|  PRIMARY KEY (thread, n, session)
  $|);
  $|CREATE INDEX letter_deliveries_pending ON letter_deliveries (session) WHERE delivered_at IS NULL;
  $|
)

///|
/// The letters' own log made once.
fn add_letters(db : @sql.Db) -> Unit raise {
  let made = () => exists(db, "table", "letters")
  if made() {
    return
  }
  immediate(db, () => if !made() { db.exec(letters) })
}

///|
/// What JavaScript's trim() takes off a string's ends, for SQLite's trim(X, Y).
let trimmed : String = "char(9, 10, 11, 12, 13, 32, 160, 5760, 8192, 8193, 8194, 8195, 8196, 8197, 8198, 8199, 8200, 8201, 8202, 8232, 8233, 8239, 8287, 12288, 65279)"

///|
fn card_options(card : String, options : String) -> String {
(
  $|CASE
  $|  WHEN json_valid(\{card}) THEN CASE WHEN json_extract(\{card}, '$.type') = 'options' AND json_type(\{card}, '$.options') = 'array' THEN json_extract(\{card}, '$.options') END
  $|  WHEN json_valid(\{options}) AND json_type(\{options}) = 'array' THEN \{options} END
)
}

///|
fn card_labels(options_json : String) -> String {
(
  $|(SELECT json_group_array(label) FROM (
  $|  SELECT trim(CASE WHEN o.type = 'object' THEN CASE WHEN json_type(o.value, '$.label') = 'text' THEN json_extract(o.value, '$.label') END END, \{trimmed}) AS label
  $|  FROM json_each(\{options_json}) o) WHERE label IS NOT NULL AND label != '')
)
}

///|
fn said_label(labels : String, text : String) -> String {
(
  $|(\{text} IS NOT NULL AND EXISTS (SELECT 1 FROM json_each(\{labels}) l WHERE l.value = trim(\{text}, \{trimmed})))
)
}

///|
let card_outcomes_answered : String =
(
  $|CREATE TRIGGER card_outcomes_answered AFTER INSERT ON entries WHEN NEW.kind = 'message' AND NEW.author_kind = 'person' BEGIN
  $|  UPDATE card_outcomes SET answered = 1, said = \{said_label("card_outcomes.labels", "NEW.text")}
  $|  WHERE thread = NEW.thread AND n < NEW.n AND n > COALESCE((
  $|    SELECT p.n FROM entries p INDEXED BY entries_people_by_n
  $|    WHERE p.thread = NEW.thread AND p.kind = 'message' AND p.author_kind = 'person' AND p.n < NEW.n
  $|    ORDER BY p.n DESC LIMIT 1), -1) AND answered = 0;
  $|END;
)

///|
let card_outcomes : String =
(
  $|
  $|CREATE TABLE card_outcomes (
  $|  thread INTEGER NOT NULL,
  $|  n INTEGER NOT NULL,
  $|  author TEXT NOT NULL,
  $|  labels TEXT NOT NULL,
  $|  answered INTEGER NOT NULL,
  $|  said INTEGER NOT NULL,
  $|  PRIMARY KEY (thread, n)
  $|) WITHOUT ROWID;
  $|CREATE TRIGGER card_outcomes_asked AFTER INSERT ON entries
  $|  WHEN NEW.kind = 'message' AND NEW.author_kind = 'agent' AND (NEW.card IS NOT NULL OR NEW.options IS NOT NULL) BEGIN
  $|  INSERT OR REPLACE INTO card_outcomes
  $|    SELECT NEW.thread, NEW.n, NEW.author, \{card_labels("o.options")}, 0, 0 FROM (SELECT \{card_options("NEW.card", "NEW.options")} AS options) o
  $|    WHERE o.options IS NOT NULL;
  $|END;
  $|\{card_outcomes_answered}
  $|CREATE TRIGGER card_outcomes_dropped AFTER DELETE ON entries WHEN OLD.kind = 'message' AND OLD.author_kind = 'agent' BEGIN
  $|  DELETE FROM card_outcomes WHERE thread = OLD.thread AND n = OLD.n;
  $|END;
  $|
)

///|
/// Empty decision statistics and their triggers, old messages never reconstructed; their coverage marked missing where
/// messages are there already. An older database's answering trigger replaced by the bounded one.
fn add_card_outcomes(db : @sql.Db) -> Unit raise {
  let made = () => exists(db, "table", "card_outcomes")
  if !made() {
    immediate(db, () => if !made() {
      let old = some_row(db, "SELECT 1 FROM entries LIMIT 1")
      db.exec(card_outcomes)
      if old {
        db.exec("CREATE TABLE IF NOT EXISTS card_outcomes_incomplete (id INTEGER PRIMARY KEY)")
      }
    })
  }
  let bounded = () => sql_of(db, "trigger", "card_outcomes_answered").unwrap_or("").contains("INDEXED BY entries_people_by_n")
  if !bounded() {
    immediate(db, () => if !bounded() {
      db.exec("DROP TRIGGER IF EXISTS card_outcomes_answered; \{card_outcomes_answered}")
    })
  }
}

///|
let session_turns : String =
(
  $|
  $|CREATE TABLE session_turns (
  $|  session TEXT PRIMARY KEY,
  $|  n INTEGER NOT NULL
  $|) WITHOUT ROWID;
  $|CREATE TABLE session_turns_guard (
  $|  session TEXT PRIMARY KEY,
  $|  token TEXT NOT NULL,
  $|  boundary_at INTEGER NOT NULL,
  $|  boundary_rowid INTEGER NOT NULL
  $|) WITHOUT ROWID;
  $|CREATE TRIGGER session_turns_before_insert BEFORE INSERT ON turns BEGIN
  $|  DELETE FROM session_turns_guard WHERE session IN (SELECT session_key FROM turns WHERE id = NEW.id);
  $|  -- A replacement may delete its old row without firing DELETE triggers. Even an ignored conflict may safely leave
  $|  -- that session unknown; a later read will count it, rather than accepting a stale summary.
  $|  DELETE FROM session_turns WHERE session IN (SELECT session_key FROM turns WHERE id = NEW.id);
  $|END;
  $|CREATE TRIGGER session_turns_add AFTER INSERT ON turns BEGIN
  $|  -- Appends after a scan's current end are read later; they need not write the guard or restart the old scan.
  $|  DELETE FROM session_turns_guard WHERE session = NEW.session_key
  $|    AND (NEW.started_at, NEW.rowid) <= (boundary_at, boundary_rowid);
  $|  UPDATE session_turns SET n = n + 1 WHERE session = NEW.session_key;
  $|  INSERT INTO session_turns (session, n) SELECT NEW.session_key, 1
  $|    WHERE NOT EXISTS (SELECT 1 FROM session_turns WHERE session = NEW.session_key)
  $|      AND NOT EXISTS (SELECT 1 FROM turns INDEXED BY turns_by_session
  $|        WHERE session_key = NEW.session_key AND rowid != NEW.rowid LIMIT 1);
  $|END;
  $|CREATE TRIGGER session_turns_drop AFTER DELETE ON turns BEGIN
  $|  DELETE FROM session_turns_guard WHERE session = OLD.session_key;
  $|  UPDATE session_turns SET n = n - 1 WHERE session = OLD.session_key;
  $|  DELETE FROM session_turns WHERE session = OLD.session_key AND n <= 0;
  $|END;
  $|CREATE TRIGGER session_turns_move BEFORE UPDATE OF session_key, started_at, id ON turns
  $|  WHEN OLD.session_key IS NOT NEW.session_key OR OLD.started_at IS NOT NEW.started_at OR OLD.id IS NOT NEW.id BEGIN
  $|  DELETE FROM session_turns_guard WHERE session IN (OLD.session_key, NEW.session_key)
  $|    OR session IN (SELECT session_key FROM turns WHERE id = NEW.id AND rowid != OLD.rowid);
  $|  DELETE FROM session_turns WHERE session IN (OLD.session_key, NEW.session_key) AND OLD.session_key IS NOT NEW.session_key;
  $|  DELETE FROM session_turns WHERE session IN (SELECT session_key FROM turns WHERE id = NEW.id AND rowid != OLD.rowid);
  $|END;
  $|
)

///|
/// Turn counts installed without walking old turns under the startup write lock.
fn add_session_turns(db : @sql.Db) -> Unit raise {
  let made = () => exists(db, "table", "session_turns")
  if made() {
    return
  }
  immediate(db, () => if !made() { db.exec(session_turns) })
}

///|
let session_work : String =
(
  $|
  $|CREATE TABLE session_work (
  $|  session TEXT PRIMARY KEY,
  $|  ms INTEGER NOT NULL
  $|) WITHOUT ROWID;
  $|CREATE TABLE session_work_from (
  $|  id INTEGER PRIMARY KEY CHECK (id = 1),
  $|  at INTEGER NOT NULL
  $|);
  $|CREATE TRIGGER session_work_add AFTER INSERT ON turns WHEN NEW.ended_at > NEW.started_at BEGIN
  $|  INSERT INTO session_work VALUES (NEW.session_key, NEW.ended_at - NEW.started_at) ON CONFLICT (session) DO UPDATE SET ms = ms + excluded.ms;
  $|END;
  $|CREATE TRIGGER session_work_end AFTER UPDATE OF started_at, ended_at ON turns
  $|WHEN NEW.ended_at IS NOT OLD.ended_at OR NEW.started_at IS NOT OLD.started_at BEGIN
  $|  INSERT INTO session_work VALUES (NEW.session_key,
  $|      (CASE WHEN NEW.ended_at > NEW.started_at THEN NEW.ended_at - NEW.started_at ELSE 0 END)
  $|      - (CASE WHEN OLD.ended_at > OLD.started_at THEN OLD.ended_at - OLD.started_at ELSE 0 END))
  $|    ON CONFLICT (session) DO UPDATE SET ms = ms + excluded.ms;
  $|END;
  $|CREATE TRIGGER session_work_drop AFTER DELETE ON turns WHEN OLD.ended_at > OLD.started_at BEGIN
  $|  UPDATE session_work SET ms = ms - (OLD.ended_at - OLD.started_at) WHERE session = OLD.session_key;
  $|  DELETE FROM session_work WHERE session = OLD.session_key AND ms <= 0;
  $|END;
  $|
)

///|
/// The sessions' work, kept from `now` on: its tables and the triggers that keep it, nothing read.
fn add_session_work(db : @sql.Db, now : Int64) -> Unit raise {
  let made = () => exists(db, "table", "session_work_from")
  if made() {
    return
  }
  immediate(db, () => if !made() {
    db.exec(session_work)
    ignore(db.run("INSERT INTO session_work_from VALUES (1, ?)", [Json::number(now.to_double())]))
  })
}

///|
let pending_cards : String =
(
  $|
  $|CREATE TABLE pending_cards (
  $|  thread INTEGER PRIMARY KEY,
  $|  n INTEGER NOT NULL
  $|);
  $|CREATE TABLE pending_cards_from (
  $|  id INTEGER PRIMARY KEY CHECK (id = 1),
  $|  entry INTEGER NOT NULL
  $|);
  $|CREATE TRIGGER pending_cards_post AFTER INSERT ON entries
  $|WHEN NEW.kind = 'message' AND (NEW.card IS NOT NULL OR NEW.options IS NOT NULL) BEGIN
  $|  INSERT INTO pending_cards VALUES (NEW.thread, NEW.n) ON CONFLICT (thread) DO UPDATE SET n = excluded.n WHERE excluded.n > pending_cards.n;
  $|END;
  $|CREATE TRIGGER pending_cards_answered AFTER INSERT ON entries WHEN NEW.kind = 'message' AND NEW.author_kind = 'person' BEGIN
  $|  DELETE FROM pending_cards WHERE thread = NEW.thread AND n < NEW.n;
  $|END;
  $|CREATE TRIGGER pending_cards_closed AFTER INSERT ON closed_cards BEGIN
  $|  DELETE FROM pending_cards WHERE thread = NEW.thread AND n = NEW.n;
  $|END;
  $|CREATE TRIGGER pending_cards_gone AFTER DELETE ON threads BEGIN
  $|  DELETE FROM pending_cards WHERE thread = OLD.id;
  $|END;
  $|
)

///|
/// The cards chats wait on, kept from now on.
fn add_pending_cards(db : @sql.Db) -> Unit raise {
  let made = () => exists(db, "table", "pending_cards_from")
  if made() {
    return
  }
  immediate(db, () => if !made() {
    db.exec(pending_cards)
    db.exec("INSERT INTO pending_cards_from VALUES (1, COALESCE((SELECT MAX(rowid) FROM entries), 0))")
  })
}

///|
/// Whether a card is a system card, by the JSON of an entry's `card` column (card-kinds.ts `systemCardSql`).
pub fn system_card_sql(col : String) -> String {
  "(CASE WHEN \{col} IS NULL OR NOT json_valid(\{col}) THEN 0 ELSE COALESCE(json_extract(\{col}, '$.type') = 'login'" +
  " OR json_type(\{col}, '$.vault') = 'object' OR json_type(\{col}, '$.adb') = 'object'" +
  " OR json_type(\{col}, '$.rig') = 'object' OR json_type(\{col}, '$.signin') = 'object', 0) END)"
}

///|
let pending_system_cards : String =
(
  $|
  $|CREATE TABLE pending_system_cards (
  $|  thread INTEGER NOT NULL,
  $|  n INTEGER NOT NULL,
  $|  PRIMARY KEY (thread, n)
  $|) WITHOUT ROWID;
  $|INSERT OR IGNORE INTO pending_system_cards
  $|  SELECT p.thread, p.n FROM pending_cards p JOIN entries e ON e.thread = p.thread AND e.n = p.n
  $|  WHERE e.kind = 'message' AND \{system_card_sql("e.card")};
  $|DELETE FROM pending_cards WHERE EXISTS (SELECT 1 FROM pending_system_cards s WHERE s.thread = pending_cards.thread AND s.n = pending_cards.n);
  $|CREATE TRIGGER pending_system_cards_post AFTER INSERT ON entries
  $|WHEN NEW.kind = 'message' AND \{system_card_sql("NEW.card")} BEGIN
  $|  INSERT OR IGNORE INTO pending_system_cards VALUES (NEW.thread, NEW.n);
  $|END;
  $|CREATE TRIGGER pending_system_cards_closed AFTER INSERT ON closed_cards BEGIN
  $|  DELETE FROM pending_system_cards WHERE thread = NEW.thread AND n = NEW.n;
  $|END;
  $|CREATE TRIGGER pending_system_cards_gone AFTER DELETE ON threads BEGIN
  $|  DELETE FROM pending_system_cards WHERE thread = OLD.id;
  $|END;
  $|DROP TRIGGER IF EXISTS pending_cards_post;
  $|CREATE TRIGGER pending_cards_post AFTER INSERT ON entries
  $|WHEN NEW.kind = 'message' AND (NEW.card IS NOT NULL OR NEW.options IS NOT NULL) AND NOT \{system_card_sql("NEW.card")} BEGIN
  $|  INSERT INTO pending_cards VALUES (NEW.thread, NEW.n) ON CONFLICT (thread) DO UPDATE SET n = excluded.n WHERE excluded.n > pending_cards.n;
  $|END;
  $|DROP TRIGGER IF EXISTS pending_cards_answered;
  $|CREATE TRIGGER pending_cards_answered AFTER INSERT ON entries
  $|WHEN NEW.kind = 'message' AND NEW.author_kind = 'person' AND (SELECT surface FROM threads WHERE id = NEW.thread) = '\{stillfail_surface}' BEGIN
  $|  DELETE FROM pending_cards WHERE thread = NEW.thread AND n < NEW.n;
  $|END;
  $|CREATE TRIGGER pending_cards_delivered AFTER INSERT ON deliveries
  $|WHEN EXISTS (SELECT 1 FROM entries e WHERE e.thread = NEW.thread AND e.n = NEW.n AND e.kind = 'message' AND e.author_kind = 'person') BEGIN
  $|  DELETE FROM pending_cards WHERE thread = NEW.thread AND n < NEW.n;
  $|END;
  $|
)

///|
/// The system cards kept apart, from now on.
fn add_pending_system_cards(db : @sql.Db) -> Unit raise {
  let made = () => exists(db, "table", "pending_system_cards")
  if made() {
    return
  }
  immediate(db, () => if !made() { db.exec(pending_system_cards) })
}

///|
/// What is told as chats change is read by these, each lookup the size of what it finds.
fn add_tell_indexes(db : @sql.Db) -> Unit raise {
  add_said_index(db)
  add_agent_index(db)
  db.exec("CREATE INDEX IF NOT EXISTS turns_by_end ON turns (session_key, ended_at)")
  db.exec("CREATE INDEX IF NOT EXISTS sessions_put_away ON sessions (archived_at, key) WHERE archived_at IS NOT NULL")
  db.exec("CREATE INDEX IF NOT EXISTS threads_put_away ON threads (hidden_at, id) WHERE hidden_at IS NOT NULL")
  db.exec("CREATE INDEX IF NOT EXISTS sessions_models ON sessions (created_by, created_at, runtime, model)")
  add_effort_index(db)
}

///|
/// A large older store prepares the agent-message time lookup instead of indexing it under a writer lock.
fn add_agent_index(db : @sql.Db) -> Unit raise {
  let native = () => exists(db, "index", "entries_agent_at")
  if has_legacy_agent(db) || native() {
    return
  }
  let mut prepare = false
  immediate(db, () => if !has_legacy_agent(db) && !native() {
    if !some_row(db, "SELECT 1 FROM entries LIMIT 1 OFFSET 63") {
      db.exec("CREATE INDEX IF NOT EXISTS entries_agent_at ON entries (thread, at) WHERE kind = 'message' AND author_kind = 'agent'")
    } else {
      prepare = true
    }
  })
  if prepare {
    ignore(install_legacy_agent(db, prefer_native=true))
  }
}

///|
/// A native said index on a new or small store; an older large one answers from the old table while it is prepared.
fn add_said_index(db : @sql.Db) -> Unit raise {
  let native = () => exists(db, "index", "entries_said")
  if has_legacy_said(db) || native() {
    return
  }
  let mut prepare = false
  immediate(db, () => if !has_legacy_said(db) && !native() {
    if !some_row(db, "SELECT 1 FROM entries LIMIT 1 OFFSET 63") {
      db.exec(entries_said_index)
    } else {
      prepare = true
    }
  })
  if prepare {
    ignore(install_legacy_said(db, prefer_native=true))
  }
}

///|
/// The efforts index, on a new or small store only.
fn add_effort_index(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "index", "sessions_efforts")
  let small = () => !some_row(db, "SELECT 1 FROM sessions LIMIT 1 OFFSET 64")
  if installed() || !small() {
    return
  }
  immediate(db, () => if !installed() && small() {
    db.exec("CREATE INDEX IF NOT EXISTS sessions_efforts ON sessions (created_by, runtime, model, created_at, effort)")
  })
}

///|
/// The lists' kept state made once, with its triggers; the session's first-delivery triggers made bounded where they
/// were not.
fn add_list_state(db : @sql.Db) -> Unit raise {
  let made = () => exists(db, "table", "thread_state")
  let first_safe = (trigger : String) => sql_of(db, "trigger", trigger).unwrap_or("").contains("WITH RECURSIVE first_threads")
  if made() && first_safe("session_first_add") && first_safe("session_first_drop") {
    return
  }
  if !made() {
    db.exec(entries_said_index)
  }
  let has_index = (name : String) => exists(db, "index", name)
  immediate(db, () => if !made() {
    db.exec(
      list_state(
        if has_index("entries_people_by_n") && has_index("entries_letters") {
          thread_state_seek
        } else {
          thread_state_scan
        },
      ),
    )
  } else {
    if !first_safe("session_first_add") {
      db.exec("DROP TRIGGER IF EXISTS session_first_add; \{session_first_add}")
    }
    if !first_safe("session_first_drop") {
      db.exec("DROP TRIGGER IF EXISTS session_first_drop; \{session_first_drop}")
    }
  })
}

///|
/// The columns a station in several workspaces came with, and the indexes by workspace.
fn add_workspace_columns(db : @sql.Db) -> Unit raise {
  add_column(db, "sessions", "ws", "TEXT")
  add_column(db, "sessions", "came_from", "TEXT")
  add_column(db, "sessions", "began_on", "TEXT")
  add_column(db, "archive_policy", "ws", "TEXT")
  db.exec("CREATE INDEX IF NOT EXISTS sessions_by_connect ON sessions (connect, ws)")
  db.exec("CREATE INDEX IF NOT EXISTS sessions_ws ON sessions (key, ws)")
  db.exec("DROP INDEX IF EXISTS sessions_by_ws")
  db.exec("CREATE INDEX IF NOT EXISTS sessions_of_ws ON sessions (COALESCE(ws, ''), key)")
}
