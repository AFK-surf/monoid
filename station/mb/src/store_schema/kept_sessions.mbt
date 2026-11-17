// What the database keeps of sessions and jobs as they are written, whichever station writes them: the running
// watches and other jobs (station/src/store/watch-jobs.ts, active-jobs.ts), a workspace's sessions at work
// (workspace-activity.ts), the waits to take up after a restart (recover-waits.ts, awake-waits.ts), the overview's
// counts (session-counts.ts), the session list (session-list-index.ts), a session's bindings
// (session-bindings-index.ts), the archive marks (archive-mark-index.ts), up jobs by session and by workspace
// (session-up-jobs.ts, workspace-up-jobs.ts), a job's chat's first member (job-name-first.ts) and the tasks other
// stations ran here (remote-runs.ts). Each installed empty, with its writers; an older store's rows are brought over
// by the MoonBit builders in bounded batches.

///|
let active_watches_at_install : String = "SELECT id, session_key, token FROM jobs INDEXED BY jobs_state WHERE state = 'running' AND watch <> 0"

///|
let active_job_null_id : String = "SELECT 1 FROM jobs INDEXED BY sqlite_autoindex_jobs_1 WHERE id IS NULL AND state = 'running' LIMIT 1"

///|
/// A small old database can still install immediately (watch-jobs.ts `activeJobsFitAtOpen`).
pub fn active_jobs_fit_at_open(db : @sql.Db) -> Bool raise {
  !some_row(db, "SELECT 1 FROM jobs INDEXED BY jobs_state WHERE state = 'running' LIMIT 1 OFFSET 64") &&
  !some_row(db, active_job_null_id)
}

///|
/// Whether an older store's active jobs are being prepared (`activeJobsUpgradePending`).
pub fn active_jobs_upgrade_pending(db : @sql.Db) -> Bool raise {
  if !some_row(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'active_job_upgrade'") {
    return false
  }
  some_row(db, "SELECT 1 FROM active_job_upgrade WHERE id = 1 AND complete = 0")
}

///|
/// The running watches with their writers (`installActiveWatches`).
fn install_active_watches(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "active_watch_jobs")
  if installed() {
    return
  }
  if active_jobs_upgrade_pending(db) || !active_jobs_fit_at_open(db) {
    return
  }
  immediate(db, () => if !installed() && !active_jobs_upgrade_pending(db) && active_jobs_fit_at_open(db) {
    db.exec(
(
  $|
  $|      CREATE TABLE active_watch_jobs (job TEXT PRIMARY KEY, session TEXT NOT NULL, token TEXT NOT NULL UNIQUE) WITHOUT ROWID;
  $|      CREATE INDEX active_watch_jobs_session ON active_watch_jobs (session);
  $|      CREATE TRIGGER active_watch_job_add AFTER INSERT ON jobs
  $|        WHEN (NEW.state = 'running' AND NEW.watch <> 0)
  $|          OR EXISTS (SELECT 1 FROM active_watch_jobs WHERE job = NEW.id OR token = NEW.token) BEGIN
  $|        DELETE FROM active_watch_jobs WHERE job = NEW.id OR token = NEW.token;
  $|        INSERT INTO active_watch_jobs SELECT NEW.id, NEW.session_key, NEW.token WHERE NEW.state = 'running' AND NEW.watch <> 0;
  $|      END;
  $|      CREATE TRIGGER active_watch_job_change AFTER UPDATE OF id, session_key, state, watch, token ON jobs
  $|        WHEN (OLD.id IS NOT NEW.id OR OLD.session_key IS NOT NEW.session_key OR OLD.state IS NOT NEW.state
  $|          OR OLD.watch IS NOT NEW.watch OR OLD.token IS NOT NEW.token)
  $|          AND ((OLD.state = 'running' AND OLD.watch <> 0) OR (NEW.state = 'running' AND NEW.watch <> 0)
  $|            OR EXISTS (SELECT 1 FROM active_watch_jobs WHERE job = NEW.id OR token = NEW.token)) BEGIN
  $|        DELETE FROM active_watch_jobs WHERE job IN (OLD.id, NEW.id) OR token = NEW.token;
  $|        INSERT INTO active_watch_jobs SELECT NEW.id, NEW.session_key, NEW.token WHERE NEW.state = 'running' AND NEW.watch <> 0;
  $|      END;
  $|      CREATE TRIGGER active_watch_job_drop AFTER DELETE ON jobs WHEN OLD.state = 'running' AND OLD.watch <> 0 BEGIN
  $|        DELETE FROM active_watch_jobs WHERE job = OLD.id;
  $|      END;
  $|      INSERT INTO active_watch_jobs \{active_watches_at_install};
  $|    
)
    )
  })
}

///|
let other_jobs_at_install : String = "SELECT session_key, id FROM jobs INDEXED BY jobs_state WHERE state = 'running' AND watch = 0"

///|
/// The remote queue's index on the other active jobs, where they are few (`installRemoteQueueIndex`).
fn install_remote_queue_index(db : @sql.Db) -> Unit raise {
  let index = () => exists(db, "index", "active_other_remote_jobs")
  let table = () => exists(db, "table", "active_other_jobs")
  let preparing = () => exists(db, "table", "active_remote_job_meta")
  let small = () => !some_row(db, "SELECT 1 FROM active_other_jobs LIMIT 1 OFFSET 64")
  if index() || !table() || preparing() || !small() {
    return
  }
  immediate(db, () => if !index() && table() && !preparing() && small() {
    db.exec(
(
  $|CREATE INDEX active_other_remote_jobs ON active_other_jobs (job)
  $|      WHERE job >= 'remote_' AND job < 'remote`'
)
    )
  })
}

///|
/// The jobs running without watch, with their writers (`installOtherActiveJobs`).
fn install_other_active_jobs(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "active_other_jobs")
  if installed() {
    return
  }
  if active_jobs_upgrade_pending(db) || !active_jobs_fit_at_open(db) {
    return
  }
  immediate(db, () => if !installed() && !active_jobs_upgrade_pending(db) && active_jobs_fit_at_open(db) {
    db.exec(
(
  $|
  $|      CREATE TABLE active_other_jobs (session TEXT NOT NULL, job TEXT NOT NULL, PRIMARY KEY (session, job)) WITHOUT ROWID;
  $|      CREATE TABLE active_other_replaced (session TEXT NOT NULL, job TEXT NOT NULL, PRIMARY KEY (session, job)) WITHOUT ROWID;
  $|      CREATE TRIGGER active_other_job_before_add BEFORE INSERT ON jobs
  $|        WHEN EXISTS (SELECT 1 FROM active_other_replaced)
  $|          OR EXISTS (SELECT 1 FROM jobs WHERE id = NEW.id OR token = NEW.token) BEGIN
  $|        DELETE FROM active_other_replaced WHERE session IS NOT NULL;
  $|        INSERT INTO active_other_replaced
  $|          SELECT session_key, id FROM jobs WHERE (id = NEW.id OR token = NEW.token) AND state = 'running' AND watch = 0;
  $|      END;
  $|      CREATE TRIGGER active_other_job_add AFTER INSERT ON jobs
  $|        WHEN (NEW.state = 'running' AND NEW.watch = 0) OR EXISTS (SELECT 1 FROM active_other_replaced) BEGIN
  $|        DELETE FROM active_other_jobs WHERE (session, job) IN (SELECT session, job FROM active_other_replaced);
  $|        DELETE FROM active_other_replaced WHERE session IS NOT NULL;
  $|        INSERT INTO active_other_jobs SELECT NEW.session_key, NEW.id WHERE NEW.state = 'running' AND NEW.watch = 0;
  $|      END;
  $|      CREATE TRIGGER active_other_job_before_change BEFORE UPDATE OF id, session_key, state, watch, token ON jobs
  $|        WHEN OLD.id IS NOT NEW.id OR OLD.token IS NOT NEW.token OR EXISTS (SELECT 1 FROM active_other_replaced) BEGIN
  $|        DELETE FROM active_other_replaced WHERE session IS NOT NULL;
  $|        INSERT INTO active_other_replaced SELECT session_key, id FROM jobs
  $|          WHERE (OLD.id IS NOT NEW.id OR OLD.token IS NOT NEW.token) AND id <> OLD.id
  $|            AND (id = NEW.id OR token = NEW.token) AND state = 'running' AND watch = 0;
  $|      END;
  $|      CREATE TRIGGER active_other_job_change AFTER UPDATE OF id, session_key, state, watch, token ON jobs
  $|        WHEN ((OLD.id IS NOT NEW.id OR OLD.session_key IS NOT NEW.session_key OR OLD.state IS NOT NEW.state
  $|          OR OLD.watch IS NOT NEW.watch) AND ((OLD.state = 'running' AND OLD.watch = 0) OR (NEW.state = 'running' AND NEW.watch = 0)))
  $|          OR EXISTS (SELECT 1 FROM active_other_replaced) BEGIN
  $|        DELETE FROM active_other_jobs WHERE (session = OLD.session_key AND job = OLD.id)
  $|          OR (session, job) IN (SELECT session, job FROM active_other_replaced);
  $|        DELETE FROM active_other_replaced WHERE session IS NOT NULL;
  $|        INSERT INTO active_other_jobs SELECT NEW.session_key, NEW.id WHERE NEW.state = 'running' AND NEW.watch = 0;
  $|      END;
  $|      CREATE TRIGGER active_other_job_drop AFTER DELETE ON jobs WHEN OLD.state = 'running' AND OLD.watch = 0 BEGIN
  $|        DELETE FROM active_other_jobs WHERE session = OLD.session_key AND job = OLD.id;
  $|      END;
  $|      INSERT INTO active_other_jobs \{other_jobs_at_install};
  $|    
)
    )
  })
}

///|
fn wa_active(key : String) -> String {
(
  $|EXISTS (SELECT 1 FROM sessions z WHERE z.key = \{key} AND (z.running = 1
  $|  OR EXISTS (SELECT 1 FROM deliveries d INDEXED BY deliveries_pending WHERE d.session = z.key AND d.delivered_at IS NULL)
  $|  OR EXISTS (SELECT 1 FROM letter_deliveries d INDEXED BY letter_deliveries_pending WHERE d.session = z.key AND d.delivered_at IS NULL)))
)
}

///|
fn wa_identity(key : String) -> String {
(
  $|SELECT s.ws, s.key FROM sessions s WHERE s.key = \{key} AND s.ws IS NOT NULL
)
}

///|
fn wa_add(key : String) -> String {
(
  $|INSERT INTO workspace_activity (ws, session)
  $|  SELECT s.ws, s.key FROM sessions s WHERE s.key = \{key} AND s.ws IS NOT NULL AND \{wa_active("s.key")}
  $|    AND NOT EXISTS (SELECT 1 FROM workspace_activity a WHERE a.ws = s.ws AND a.session = s.key);
)
}

///|
fn wa_remove_idle(key : String) -> String {
(
  $|DELETE FROM workspace_activity WHERE (ws, session) IN (\{wa_identity(key)}) AND NOT \{wa_active(key)};
)
}

///|
let wa_clean_replaced : String =
(
  $|DELETE FROM workspace_activity
  $|  WHERE (ws, session) IN (SELECT ws, session FROM workspace_activity_replaced)
  $|    AND NOT EXISTS (SELECT 1 FROM sessions s WHERE s.key = workspace_activity.session
  $|      AND s.ws = workspace_activity.ws AND \{wa_active("s.key")});
  $|  DELETE FROM workspace_activity_replaced WHERE session IS NOT NULL;
)

///|
let wa_stage_replaced : String =
(
  $|DELETE FROM workspace_activity_replaced WHERE session IS NOT NULL;
  $|  INSERT INTO workspace_activity_replaced
  $|    SELECT a.ws, a.session FROM workspace_activity a
  $|    WHERE (a.ws, a.session) IN (
  $|      SELECT s.ws, s.key FROM sessions s WHERE s.ws IS NOT NULL AND (s.key = NEW.key OR s.token = NEW.token)
  $|    );
)

///|
let wa_first_running : String = "SELECT key AS session FROM sessions INDEXED BY sessions_running WHERE running = 1 ORDER BY key LIMIT 1"

///|
let wa_first_message : String = "SELECT session FROM deliveries INDEXED BY deliveries_pending WHERE delivered_at IS NULL ORDER BY session LIMIT 1"

///|
let wa_first_letter : String = "SELECT session FROM letter_deliveries INDEXED BY letter_deliveries_pending WHERE delivered_at IS NULL ORDER BY session LIMIT 1"

///|
/// A workspace's sessions at work, kept by the database (`installWorkspaceActivity`).
fn install_workspace_activity(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "workspace_activity_meta")
  if installed() {
    return
  }
  let per_table = joined(
    ["deliveries", "letter_deliveries"].mapi((i, table) => {
(
  $|
  $|        CREATE TRIGGER workspace_activity_\{i}_add AFTER INSERT ON \{table} BEGIN
  $|          \{wa_remove_idle("NEW.session")}
  $|          \{wa_add("NEW.session")}
  $|        END;
  $|        CREATE TRIGGER workspace_activity_\{i}_change AFTER UPDATE OF thread, n, session, delivered_at ON \{table}
  $|          WHEN OLD.thread IS NOT NEW.thread OR OLD.n IS NOT NEW.n OR OLD.session IS NOT NEW.session OR OLD.delivered_at IS NOT NEW.delivered_at BEGIN
  $|          \{wa_remove_idle("OLD.session")}
  $|          \{wa_remove_idle("NEW.session")}
  $|          \{wa_add("OLD.session")}
  $|          \{wa_add("NEW.session")}
  $|        END;
  $|        CREATE TRIGGER workspace_activity_\{i}_drop AFTER DELETE ON \{table} BEGIN
  $|          \{wa_remove_idle("OLD.session")}
  $|        END;
  $|      
)
    }),
    "\n",
  )
  immediate(db, () => if !installed() {
    db.exec(
(
  $|
  $|      CREATE TABLE workspace_activity (ws TEXT NOT NULL, session TEXT NOT NULL,
  $|        PRIMARY KEY (ws, session)) WITHOUT ROWID;
  $|      CREATE TABLE workspace_activity_replaced (ws TEXT NOT NULL, session TEXT NOT NULL,
  $|        PRIMARY KEY (ws, session)) WITHOUT ROWID;
  $|      CREATE TABLE workspace_activity_meta (id INTEGER PRIMARY KEY CHECK (id = 1), cursor TEXT, complete INTEGER NOT NULL) WITHOUT ROWID;
  $|      INSERT INTO workspace_activity_meta (id, cursor, complete) SELECT 1, NULL,
  $|        NOT (EXISTS (\{wa_first_running}) OR EXISTS (\{wa_first_message}) OR EXISTS (\{wa_first_letter}));
  $|
  $|      CREATE TRIGGER workspace_activity_before_session_add BEFORE INSERT ON sessions BEGIN \{wa_stage_replaced} END;
  $|      CREATE TRIGGER workspace_activity_session_add AFTER INSERT ON sessions BEGIN
  $|        \{wa_clean_replaced}
  $|        \{wa_add("NEW.key")}
  $|      END;
  $|      CREATE TRIGGER workspace_activity_before_session_change BEFORE UPDATE OF key, token ON sessions
  $|        WHEN OLD.key IS NOT NEW.key OR OLD.token IS NOT NEW.token BEGIN \{wa_stage_replaced} END;
  $|      CREATE TRIGGER workspace_activity_session_change AFTER UPDATE OF key, token, ws, running ON sessions
  $|        WHEN OLD.key IS NOT NEW.key OR OLD.token IS NOT NEW.token OR OLD.ws IS NOT NEW.ws OR OLD.running IS NOT NEW.running BEGIN
  $|        \{wa_clean_replaced}
  $|        DELETE FROM workspace_activity WHERE ws = OLD.ws AND session = OLD.key
  $|          AND (OLD.key IS NOT NEW.key OR OLD.ws IS NOT NEW.ws OR NOT \{wa_active("NEW.key")});
  $|        \{wa_add("NEW.key")}
  $|      END;
  $|      CREATE TRIGGER workspace_activity_session_drop AFTER DELETE ON sessions BEGIN
  $|        DELETE FROM workspace_activity WHERE ws = OLD.ws AND session = OLD.key;
  $|      END;
  $|      \{per_table}
  $|    
)
    )
  })
}

///|
let half_safe : String = "2251799813685247"

///|
let second_limit : String = "2251799813685"

///|
let uncertain : String = "-9007199254740991"

///|
let rw_deadline : String =
(
  $|CASE WHEN typeof(t.ended_at) = 'integer' AND t.ended_at BETWEEN -\{half_safe} AND \{half_safe}
  $|  AND (t.wait_seconds IS NULL OR (typeof(t.wait_seconds) = 'integer' AND t.wait_seconds BETWEEN -\{second_limit} AND \{second_limit}))
  $|  THEN t.ended_at + COALESCE(t.wait_seconds, 0) * 1000 ELSE \{uncertain} END
)

///|
fn rw_awake_deadline(key : String) -> String {
(
  $|(SELECT \{rw_deadline} FROM sessions s
  $|  CROSS JOIN turns t ON t.rowid = (SELECT rowid FROM turns INDEXED BY turns_by_session
  $|    WHERE session_key = s.key ORDER BY started_at DESC, rowid DESC LIMIT 1)
  $|  WHERE s.key = \{key} AND s.archived_at IS NULL AND s.running != 1 AND t.ended_at IS NOT NULL AND t.declared = 'waiting')
)
}

///|
fn rw_sync_awake_wait(key : String, guard_ : String) -> String {
(
  $|UPDATE session_recover_waits SET awake_deadline = \{rw_awake_deadline(key)}
  $|  WHERE session = \{key} AND (\{guard_}) AND awake_deadline IS NOT \{rw_awake_deadline(key)};
)
}

///|
fn rw_reconcile_awake_waits(stage : String) -> String {
(
  $|UPDATE session_recover_waits
  $|  SET awake_deadline = \{rw_awake_deadline("session_recover_waits.session")}
  $|  WHERE session IN (SELECT session FROM \{stage}) AND awake_deadline IS NOT \{rw_awake_deadline("session_recover_waits.session")};
)
}

///|
let rw_awake_wait_triggers : String =
(
  $|
  $|  CREATE TRIGGER session_awake_insert AFTER INSERT ON session_recover_waits BEGIN
  $|    \{rw_sync_awake_wait("NEW.session", "1")}
  $|    INSERT INTO session_awake_deadlines (deadline, session)
  $|      SELECT awake_deadline, session FROM session_recover_waits WHERE session = NEW.session AND awake_deadline IS NOT NULL
  $|        AND NOT EXISTS (SELECT 1 FROM session_awake_deadlines WHERE deadline = awake_deadline AND session = NEW.session);
  $|  END;
  $|  CREATE TRIGGER session_awake_update AFTER UPDATE OF session, awake_deadline ON session_recover_waits
  $|    WHEN OLD.session IS NOT NEW.session OR OLD.awake_deadline IS NOT NEW.awake_deadline BEGIN
  $|    DELETE FROM session_awake_deadlines WHERE deadline = OLD.awake_deadline AND session = OLD.session;
  $|    INSERT INTO session_awake_deadlines (deadline, session)
  $|      SELECT NEW.awake_deadline, NEW.session WHERE NEW.awake_deadline IS NOT NULL
  $|        AND NOT EXISTS (SELECT 1 FROM session_awake_deadlines WHERE deadline = NEW.awake_deadline AND session = NEW.session);
  $|  END;
  $|  CREATE TRIGGER session_awake_delete AFTER DELETE ON session_recover_waits WHEN OLD.awake_deadline IS NOT NULL BEGIN
  $|    DELETE FROM session_awake_deadlines WHERE deadline = OLD.awake_deadline AND session = OLD.session;
  $|  END;
)

///|
fn rw_wanted(key : String) -> String {
(
  $|EXISTS (SELECT 1 FROM sessions s WHERE s.key = \{key} AND s.archived_at IS NULL AND s.running != 1)
  $|  AND EXISTS (SELECT 1 FROM turns t WHERE t.rowid = (SELECT rowid FROM turns INDEXED BY turns_by_session
  $|    WHERE session_key = \{key} ORDER BY started_at DESC, rowid DESC LIMIT 1)
  $|    AND t.ended_at IS NOT NULL AND (t.declared = 'waiting' OR (t.outcome = 'failed' AND substr(t.detail, 1, 11) = 'rate_limit:')))
)
}

///|
fn rw_remove(key : String, guard_ : String) -> String {
(
  $|DELETE FROM session_recover_waits WHERE session = \{key} AND (\{guard_}) AND NOT (\{rw_wanted(key)});
)
}

///|
fn rw_add(key : String, guard_ : String) -> String {
(
  $|INSERT INTO session_recover_waits (session, awake_deadline) SELECT \{key}, \{rw_awake_deadline(key)} WHERE (\{guard_}) AND \{rw_wanted(key)}
  $|  AND NOT EXISTS (SELECT 1 FROM session_recover_waits WHERE session = \{key});
)
}

///|
fn rw_sync(key : String, guard_ : String) -> String {
(
  $|\{rw_remove(key, guard_)} \{rw_add(key, guard_)} \{rw_sync_awake_wait(key, guard_)}
)
}

///|
fn rw_reconcile(stage : String) -> String {
(
  $|DELETE FROM session_recover_waits WHERE session IN (SELECT session FROM \{stage})
  $|    AND NOT (\{rw_wanted("session_recover_waits.session")});
  $|  INSERT INTO session_recover_waits (session, awake_deadline) SELECT r.session, \{rw_awake_deadline("r.session")} FROM \{stage} r WHERE \{rw_wanted("r.session")}
  $|    AND NOT EXISTS (SELECT 1 FROM session_recover_waits w WHERE w.session = r.session);
  $|  \{rw_reconcile_awake_waits(stage)}
  $|  DELETE FROM \{stage} WHERE session IS NOT NULL;
)
}

///|
/// Sessions whose last turn may need taking up after a restart, and their expiries (`installRecoverWaits`).
fn install_recover_waits(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "session_recover_wait_meta")
  let awake_installed = () => exists(db, "table", "session_awake_wait_meta")
  if installed() && awake_installed() {
    return
  }
  immediate(db, () => {
    if !installed() {
      db.exec(
(
  $|
  $|      CREATE TABLE session_recover_waits (session TEXT PRIMARY KEY, awake_deadline INTEGER) WITHOUT ROWID;
  $|      CREATE TABLE session_recover_turn_stage (session TEXT PRIMARY KEY) WITHOUT ROWID;
  $|      CREATE TABLE session_recover_session_stage (session TEXT PRIMARY KEY) WITHOUT ROWID;
  $|      CREATE TABLE session_recover_wait_meta (id INTEGER PRIMARY KEY CHECK (id = 1), cursor TEXT, complete INTEGER NOT NULL);
  $|      INSERT INTO session_recover_wait_meta VALUES (1, NULL, NOT EXISTS (SELECT 1 FROM sessions LIMIT 1));
  $|    
)
      )
    }
    if !awake_installed() {
      if !columns(db, "session_recover_waits").contains("awake_deadline") {
        db.exec("ALTER TABLE session_recover_waits ADD COLUMN awake_deadline INTEGER")
      }
      db.exec(
(
  $|
  $|      CREATE TABLE session_awake_deadlines (deadline INTEGER NOT NULL, session TEXT NOT NULL, PRIMARY KEY (deadline, session)) WITHOUT ROWID;
  $|      CREATE TABLE session_awake_wait_meta (id INTEGER PRIMARY KEY CHECK (id = 1), cursor TEXT, complete INTEGER NOT NULL);
  $|      INSERT INTO session_awake_wait_meta VALUES (1, NULL,
  $|        (SELECT complete FROM session_recover_wait_meta WHERE id = 1) AND NOT EXISTS (SELECT 1 FROM session_recover_waits LIMIT 1));
  $|      \{rw_awake_wait_triggers}
  $|
  $|      DROP TRIGGER IF EXISTS session_recover_before_turn_add;
  $|      DROP TRIGGER IF EXISTS session_recover_turn_add;
  $|      DROP TRIGGER IF EXISTS session_recover_before_turn_move;
  $|      DROP TRIGGER IF EXISTS session_recover_turn_change;
  $|      DROP TRIGGER IF EXISTS session_recover_turn_drop;
  $|      DROP TRIGGER IF EXISTS session_recover_before_session_add;
  $|      DROP TRIGGER IF EXISTS session_recover_session_add;
  $|      DROP TRIGGER IF EXISTS session_recover_before_session_move;
  $|      DROP TRIGGER IF EXISTS session_recover_session_change;
  $|      DROP TRIGGER IF EXISTS session_recover_session_drop;
  $|
  $|      CREATE TRIGGER session_recover_before_turn_add BEFORE INSERT ON turns BEGIN
  $|        DELETE FROM session_recover_turn_stage WHERE session IS NOT NULL;
  $|        INSERT INTO session_recover_turn_stage SELECT session_key FROM turns WHERE id = NEW.id;
  $|      END;
  $|      CREATE TRIGGER session_recover_turn_add AFTER INSERT ON turns BEGIN
  $|        \{rw_sync("NEW.session_key", "1")}
  $|        \{rw_reconcile("session_recover_turn_stage")}
  $|      END;
  $|      CREATE TRIGGER session_recover_before_turn_move BEFORE UPDATE OF id ON turns WHEN OLD.id IS NOT NEW.id BEGIN
  $|        DELETE FROM session_recover_turn_stage WHERE session IS NOT NULL;
  $|        INSERT INTO session_recover_turn_stage SELECT session_key FROM turns WHERE id = NEW.id AND rowid != OLD.rowid;
  $|      END;
  $|      CREATE TRIGGER session_recover_turn_change AFTER UPDATE OF id, session_key, started_at, ended_at, outcome, detail, declared, wait_seconds ON turns
  $|        WHEN OLD.id IS NOT NEW.id OR OLD.session_key IS NOT NEW.session_key OR OLD.started_at IS NOT NEW.started_at
  $|          OR OLD.ended_at IS NOT NEW.ended_at OR OLD.outcome IS NOT NEW.outcome OR OLD.detail IS NOT NEW.detail
  $|          OR OLD.declared IS NOT NEW.declared OR OLD.wait_seconds IS NOT NEW.wait_seconds BEGIN
  $|        \{rw_sync("OLD.session_key", "1")}
  $|        \{rw_sync("NEW.session_key", "OLD.session_key IS NOT NEW.session_key")}
  $|        \{rw_reconcile("session_recover_turn_stage")}
  $|      END;
  $|      CREATE TRIGGER session_recover_turn_drop AFTER DELETE ON turns BEGIN \{rw_sync("OLD.session_key", "1")} END;
  $|
  $|      CREATE TRIGGER session_recover_before_session_add BEFORE INSERT ON sessions BEGIN
  $|        DELETE FROM session_recover_session_stage WHERE session IS NOT NULL;
  $|        INSERT INTO session_recover_session_stage SELECT key FROM sessions WHERE key = NEW.key OR token = NEW.token;
  $|      END;
  $|      CREATE TRIGGER session_recover_session_add AFTER INSERT ON sessions BEGIN
  $|        \{rw_sync("NEW.key", "1")}
  $|        \{rw_reconcile("session_recover_session_stage")}
  $|      END;
  $|      CREATE TRIGGER session_recover_before_session_move BEFORE UPDATE OF key, token ON sessions
  $|        WHEN OLD.key IS NOT NEW.key OR OLD.token IS NOT NEW.token BEGIN
  $|        DELETE FROM session_recover_session_stage WHERE session IS NOT NULL;
  $|        INSERT INTO session_recover_session_stage SELECT key FROM sessions
  $|          WHERE (key = NEW.key OR token = NEW.token) AND key != OLD.key;
  $|      END;
  $|      CREATE TRIGGER session_recover_session_change AFTER UPDATE OF key, token, archived_at, running ON sessions
  $|        WHEN OLD.key IS NOT NEW.key OR OLD.token IS NOT NEW.token OR OLD.archived_at IS NOT NEW.archived_at OR OLD.running IS NOT NEW.running BEGIN
  $|        \{rw_sync("OLD.key", "1")}
  $|        \{rw_sync("NEW.key", "OLD.key IS NOT NEW.key")}
  $|        \{rw_reconcile("session_recover_session_stage")}
  $|      END;
  $|      CREATE TRIGGER session_recover_session_drop AFTER DELETE ON sessions BEGIN
  $|        DELETE FROM session_recover_waits WHERE session = OLD.key;
  $|      END;
  $|    
)
      )
    }
  })
}

///|
let sc_version : Int = 1

///|
fn sc_kind(row : String) -> String {
  "CASE WHEN \{row}.ws IS NULL THEN 0 ELSE 1 END"
}

///|
fn sc_ws(row : String) -> String {
  "COALESCE(\{row}.ws, '')"
}

///|
fn sc_group(row : String) -> String {
  "kind = \{sc_kind(row)} AND ws = \{sc_ws(row)} AND connect = \{row}.connect"
}

///|
fn sc_total(row : String) -> String {
  "kind = \{sc_kind(row)} AND ws = \{sc_ws(row)}"
}

///|
let sc_add : String =
(
  $|UPDATE session_count_groups SET n = n + 1 WHERE \{sc_group("NEW")};
  $|  INSERT INTO session_count_groups (kind, ws, connect, n)
  $|    SELECT \{sc_kind("NEW")}, \{sc_ws("NEW")}, NEW.connect, 1
  $|    WHERE NOT EXISTS (SELECT 1 FROM session_count_groups WHERE \{sc_group("NEW")});
  $|  UPDATE session_count_totals SET n = n + 1 WHERE \{sc_total("NEW")};
  $|  INSERT INTO session_count_totals (kind, ws, n)
  $|    SELECT \{sc_kind("NEW")}, \{sc_ws("NEW")}, 1
  $|    WHERE NOT EXISTS (SELECT 1 FROM session_count_totals WHERE \{sc_total("NEW")});
)

///|
let sc_remove : String =
(
  $|UPDATE session_count_groups SET n = n - 1 WHERE \{sc_group("OLD")};
  $|  DELETE FROM session_count_groups WHERE \{sc_group("OLD")} AND n = 0;
  $|  UPDATE session_count_totals SET n = n - 1 WHERE \{sc_total("OLD")};
  $|  DELETE FROM session_count_totals WHERE \{sc_total("OLD")} AND n = 0;
)

///|
fn sc_displaced(key : String, token : String, rowid : String) -> String {
(
  $|SELECT key FROM sessions WHERE key = \{key}
  $|  UNION SELECT key FROM sessions WHERE token = \{token}
  $|  UNION SELECT key FROM sessions WHERE rowid = \{rowid}
)
}

///|
fn sc_stage(old : Bool) -> String {
  let union_old = if old { "UNION SELECT OLD.key" } else { "" }
(
  $|DELETE FROM session_count_replaced;
  $|  INSERT INTO session_count_replaced (session)
  $|    \{sc_displaced("NEW.key", "NEW.token", "NEW.rowid")}
  $|    \{union_old};
)
}

///|
let sc_reconcile : String =
(
  $|DELETE FROM session_count_seen
  $|  WHERE session IN (SELECT session FROM session_count_replaced)
  $|    AND NOT EXISTS (SELECT 1 FROM sessions s WHERE s.key = session_count_seen.session
  $|      AND s.connect IS session_count_seen.connect AND s.ws IS session_count_seen.ws);
  $|  INSERT INTO session_count_seen (session, connect, ws)
  $|    SELECT s.key, s.connect, s.ws FROM session_count_replaced r CROSS JOIN sessions s ON s.key = r.session
  $|    WHERE NOT EXISTS (SELECT 1 FROM session_count_seen c WHERE c.session = s.key);
  $|  DELETE FROM session_count_replaced;
)

///|
fn sc_see(key : String) -> String {
(
  $|INSERT INTO session_count_seen (session, connect, ws)
  $|  SELECT s.key, s.connect, s.ws FROM sessions s WHERE s.key = \{key}
  $|    AND NOT EXISTS (SELECT 1 FROM session_count_seen c WHERE c.session = s.key);
)
}

///|
/// Whether the overview's counts are whole, of this version (`sessionCountsReady`).
fn session_counts_ready(db : @sql.Db) -> Bool raise {
  let meta = first_row(db, "SELECT version, complete FROM session_count_meta WHERE id = 1")
  if meta is None {
    refuse("session count index version marker is missing")
  }
  if !is_num(meta, "version", sc_version) {
    refuse("session count index version \{shown(meta, "version", "undefined")} is incompatible with \{sc_version}")
  }
  is_num(meta, "complete", 1)
}

///|
/// The overview's counts (`installSessionCounts`).
fn install_session_counts(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "session_count_meta")
  if installed() {
    ignore(session_counts_ready(db))
    return
  }
  immediate(db, () => if !installed() {
    db.exec(
(
  $|
  $|      CREATE TABLE session_count_meta (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL, last_rowid INTEGER,
  $|        end_rowid INTEGER, complete INTEGER NOT NULL) WITHOUT ROWID;
  $|      INSERT INTO session_count_meta (id, version, last_rowid, end_rowid, complete)
  $|        SELECT 1, \{sc_version}, NULL, (SELECT rowid FROM sessions ORDER BY rowid DESC LIMIT 1),
  $|          NOT EXISTS (SELECT 1 FROM sessions LIMIT 1);
  $|      CREATE TABLE session_count_seen (session TEXT PRIMARY KEY, connect TEXT NOT NULL, ws TEXT) WITHOUT ROWID;
  $|      CREATE TABLE session_count_replaced (session TEXT PRIMARY KEY) WITHOUT ROWID;
  $|      CREATE TABLE session_count_totals (kind INTEGER NOT NULL, ws TEXT NOT NULL, n INTEGER NOT NULL,
  $|        PRIMARY KEY (kind, ws)) WITHOUT ROWID;
  $|      CREATE TABLE session_count_groups (kind INTEGER NOT NULL, ws TEXT NOT NULL, connect TEXT NOT NULL, n INTEGER NOT NULL,
  $|        PRIMARY KEY (kind, ws, connect)) WITHOUT ROWID;
  $|
  $|      CREATE TRIGGER session_count_seen_add AFTER INSERT ON session_count_seen BEGIN \{sc_add} END;
  $|      CREATE TRIGGER session_count_seen_drop AFTER DELETE ON session_count_seen BEGIN \{sc_remove} END;
  $|      CREATE TRIGGER session_count_before_add BEFORE INSERT ON sessions BEGIN \{sc_stage(false)} END;
  $|      CREATE TRIGGER session_count_add AFTER INSERT ON sessions BEGIN \{sc_reconcile} \{sc_see("NEW.key")} END;
  $|      CREATE TRIGGER session_count_before_change BEFORE UPDATE ON sessions
  $|        WHEN OLD.key IS NOT NEW.key OR OLD.token IS NOT NEW.token OR OLD.rowid IS NOT NEW.rowid
  $|          OR OLD.connect IS NOT NEW.connect OR OLD.ws IS NOT NEW.ws BEGIN \{sc_stage(true)} END;
  $|      CREATE TRIGGER session_count_change AFTER UPDATE ON sessions
  $|        WHEN OLD.key IS NOT NEW.key OR OLD.token IS NOT NEW.token OR OLD.rowid IS NOT NEW.rowid
  $|          OR OLD.connect IS NOT NEW.connect OR OLD.ws IS NOT NEW.ws BEGIN \{sc_reconcile} \{sc_see("NEW.key")} END;
  $|      CREATE TRIGGER session_count_drop AFTER DELETE ON sessions BEGIN
  $|        DELETE FROM session_count_seen WHERE session = OLD.key;
  $|      END;
  $|    
)
    )
  } else {
    ignore(session_counts_ready(db))
  })
}

///|
let sl_version : Int = 1

///|
fn sl_kind(row : String) -> String {
  "CASE WHEN \{row}.ws IS NULL THEN 0 ELSE 1 END"
}

///|
fn sl_scope(row : String) -> String {
  "COALESCE(\{row}.ws, '')"
}

///|
fn sl_archive(row : String) -> String {
  "(\{row}.archived_at IS NOT NULL)"
}

///|
fn sl_values(row : String) -> String {
  "\{row}.key, \{sl_kind(row)}, \{sl_scope(row)}, \{sl_archive(row)}, \{row}.connect"
}

///|
fn sl_displaced(key : String, token : String, rowid : String) -> String {
(
  $|SELECT \{sl_values("s")} FROM sessions s WHERE s.key = \{key}
  $|  UNION SELECT \{sl_values("s")} FROM sessions s WHERE s.token = \{token}
  $|  UNION SELECT \{sl_values("s")} FROM sessions s WHERE s.rowid = \{rowid}
)
}

///|
fn sl_stage(old : Bool) -> String {
  let union_old = if old { "UNION SELECT \{sl_values("OLD")}" } else { "" }
(
  $|DELETE FROM session_list_replaced;
  $|  INSERT INTO session_list_replaced (session, kind, ws, archived, connect) \{sl_displaced("NEW.key", "NEW.token", "NEW.rowid")}
  $|    \{union_old};
)
}

///|
fn sl_matches(index : String, row : String) -> String {
(
  $|\{index}.kind = \{sl_kind(row)} AND \{index}.ws = \{sl_scope(row)}
  $|  AND \{index}.archived = \{sl_archive(row)} AND \{index}.connect = \{row}.connect AND \{index}.session = \{row}.key
)
}

///|
fn sl_see(key : String) -> String {
(
  $|INSERT INTO session_list_rows (session, kind, ws, archived, connect)
  $|  SELECT \{sl_values("s")} FROM sessions s WHERE s.key = \{key}
  $|    AND NOT EXISTS (SELECT 1 FROM session_list_rows i WHERE \{sl_matches("i", "s")});
)
}

///|
let sl_reconcile : String =
(
  $|DELETE FROM session_list_rows WHERE (kind, ws, archived, connect, session) IN
  $|    (SELECT kind, ws, archived, connect, session FROM session_list_replaced)
  $|  AND NOT EXISTS (SELECT 1 FROM sessions s WHERE s.key = session_list_rows.session AND \{sl_matches("session_list_rows", "s")});
  $|  INSERT INTO session_list_rows (session, kind, ws, archived, connect)
  $|    SELECT \{sl_values("s")} FROM session_list_replaced r
  $|    CROSS JOIN sessions s ON s.key = r.session
  $|    WHERE NOT EXISTS (SELECT 1 FROM session_list_rows i WHERE \{sl_matches("i", "s")});
  $|  DELETE FROM session_list_replaced;
)

///|
fn session_list_ready(db : @sql.Db) -> Bool raise {
  let meta = first_row(db, "SELECT version, complete FROM session_list_meta WHERE id = 1")
  if meta is None {
    refuse("session list index version marker is missing")
  }
  if !is_num(meta, "version", sl_version) {
    refuse("session list index version \{shown(meta, "version", "undefined")} is incompatible with \{sl_version}")
  }
  is_num(meta, "complete", 1)
}

///|
/// The session list's candidates by workspace and archive state (`installSessionListIndex`).
fn install_session_list_index(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "session_list_meta")
  if installed() {
    ignore(session_list_ready(db))
    return
  }
  immediate(db, () => if !installed() {
    db.exec(
(
  $|
  $|      CREATE TABLE session_list_meta (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL, last_rowid INTEGER,
  $|        end_rowid INTEGER, complete INTEGER NOT NULL) WITHOUT ROWID;
  $|      INSERT INTO session_list_meta (id, version, last_rowid, end_rowid, complete)
  $|        SELECT 1, \{sl_version}, NULL, (SELECT rowid FROM sessions ORDER BY rowid DESC LIMIT 1),
  $|          NOT EXISTS (SELECT 1 FROM sessions LIMIT 1);
  $|      CREATE TABLE session_list_rows (kind INTEGER NOT NULL, ws TEXT NOT NULL, archived INTEGER NOT NULL,
  $|        connect TEXT NOT NULL, session TEXT NOT NULL, PRIMARY KEY (kind, ws, archived, connect, session)) WITHOUT ROWID;
  $|      CREATE INDEX session_list_connect ON session_list_rows (archived, connect, kind, ws, session);
  $|      CREATE TABLE session_list_replaced (session TEXT PRIMARY KEY, kind INTEGER NOT NULL, ws TEXT NOT NULL,
  $|        archived INTEGER NOT NULL, connect TEXT NOT NULL) WITHOUT ROWID;
  $|      CREATE TRIGGER session_list_before_add BEFORE INSERT ON sessions BEGIN \{sl_stage(false)} END;
  $|      CREATE TRIGGER session_list_add AFTER INSERT ON sessions BEGIN \{sl_reconcile} \{sl_see("NEW.key")} END;
  $|      CREATE TRIGGER session_list_before_change BEFORE UPDATE ON sessions
  $|        WHEN OLD.key IS NOT NEW.key OR OLD.token IS NOT NEW.token OR OLD.rowid IS NOT NEW.rowid
  $|          OR OLD.connect IS NOT NEW.connect OR OLD.ws IS NOT NEW.ws
  $|          OR (OLD.archived_at IS NULL) IS NOT (NEW.archived_at IS NULL) BEGIN \{sl_stage(true)} END;
  $|      CREATE TRIGGER session_list_change AFTER UPDATE ON sessions
  $|        WHEN OLD.key IS NOT NEW.key OR OLD.token IS NOT NEW.token OR OLD.rowid IS NOT NEW.rowid
  $|          OR OLD.connect IS NOT NEW.connect OR OLD.ws IS NOT NEW.ws
  $|          OR (OLD.archived_at IS NULL) IS NOT (NEW.archived_at IS NULL) BEGIN \{sl_reconcile} \{sl_see("NEW.key")} END;
  $|      CREATE TRIGGER session_list_drop AFTER DELETE ON sessions BEGIN
  $|        DELETE FROM session_list_rows WHERE \{sl_matches("session_list_rows", "OLD")};
  $|      END;
  $|    
)
    )
  } else {
    ignore(session_list_ready(db))
  })
}

///|
let sb_version : Int = 1

///|
fn sb_displaced(connect : String, rowid : String) -> String {
(
  $|SELECT b.rowid, b.session_key, b.connect FROM bindings b
  $|  WHERE \{connect} IS NOT NULL AND b.connect = \{connect}
  $|  UNION SELECT b.rowid, b.session_key, b.connect FROM bindings b WHERE b.rowid = \{rowid}
)
}

///|
fn sb_stage(old : Bool) -> String {
  let union_old = if old { "UNION SELECT OLD.rowid, OLD.session_key, OLD.connect" } else { "" }
(
  $|DELETE FROM session_binding_replaced;
  $|  INSERT INTO session_binding_replaced (binding_rowid, session, connect) \{sb_displaced("NEW.connect", "NEW.rowid")}
  $|    \{union_old};
)
}

///|
fn sb_see(rowid : String) -> String {
(
  $|INSERT INTO session_binding_rows (session, binding_rowid, connect)
  $|  SELECT b.session_key, b.rowid, b.connect FROM bindings b WHERE b.rowid = \{rowid}
  $|    AND NOT EXISTS (SELECT 1 FROM session_binding_rows i WHERE i.session = b.session_key AND i.binding_rowid = b.rowid);
)
}

///|
let sb_reconcile : String =
(
  $|DELETE FROM session_binding_rows WHERE (session, binding_rowid) IN
  $|    (SELECT session, binding_rowid FROM session_binding_replaced)
  $|  AND NOT EXISTS (SELECT 1 FROM bindings b WHERE b.rowid = session_binding_rows.binding_rowid
  $|    AND b.session_key = session_binding_rows.session AND b.connect IS session_binding_rows.connect);
  $|  INSERT INTO session_binding_rows (session, binding_rowid, connect)
  $|    SELECT b.session_key, b.rowid, b.connect FROM session_binding_replaced r CROSS JOIN bindings b ON b.rowid = r.binding_rowid
  $|    WHERE NOT EXISTS (SELECT 1 FROM session_binding_rows i WHERE i.session = b.session_key AND i.binding_rowid = b.rowid);
  $|  DELETE FROM session_binding_replaced;
)

///|
fn session_bindings_ready(db : @sql.Db) -> Bool raise {
  let meta = first_row(db, "SELECT version, complete FROM session_binding_meta WHERE id = 1")
  if meta is None {
    refuse("session binding index version marker is missing")
  }
  if !is_num(meta, "version", sb_version) {
    refuse("session binding index version \{shown(meta, "version", "undefined")} is incompatible with \{sb_version}")
  }
  is_num(meta, "complete", 1)
}

///|
/// A session's connection bindings by session (`installSessionBindingsIndex`).
fn install_session_bindings_index(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "session_binding_meta")
  if installed() {
    ignore(session_bindings_ready(db))
    return
  }
  immediate(db, () => if !installed() {
    db.exec(
(
  $|
  $|      CREATE TABLE session_binding_meta (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL, last_rowid INTEGER,
  $|        end_rowid INTEGER, complete INTEGER NOT NULL) WITHOUT ROWID;
  $|      INSERT INTO session_binding_meta (id, version, last_rowid, end_rowid, complete)
  $|        SELECT 1, \{sb_version}, NULL, (SELECT rowid FROM bindings ORDER BY rowid DESC LIMIT 1),
  $|          NOT EXISTS (SELECT 1 FROM bindings LIMIT 1);
  $|      CREATE TABLE session_binding_rows (session TEXT NOT NULL, binding_rowid INTEGER NOT NULL, connect TEXT,
  $|        PRIMARY KEY (session, binding_rowid)) WITHOUT ROWID;
  $|      CREATE TABLE session_binding_replaced (binding_rowid INTEGER PRIMARY KEY, session TEXT NOT NULL, connect TEXT);
  $|      CREATE TRIGGER session_binding_before_add BEFORE INSERT ON bindings BEGIN \{sb_stage(false)} END;
  $|      CREATE TRIGGER session_binding_add AFTER INSERT ON bindings BEGIN \{sb_reconcile} \{sb_see("NEW.rowid")} END;
  $|      CREATE TRIGGER session_binding_before_change BEFORE UPDATE ON bindings
  $|        WHEN OLD.rowid IS NOT NEW.rowid OR OLD.connect IS NOT NEW.connect OR OLD.session_key IS NOT NEW.session_key
  $|        BEGIN \{sb_stage(true)} END;
  $|      CREATE TRIGGER session_binding_change AFTER UPDATE ON bindings
  $|        WHEN OLD.rowid IS NOT NEW.rowid OR OLD.connect IS NOT NEW.connect OR OLD.session_key IS NOT NEW.session_key
  $|        BEGIN \{sb_reconcile} \{sb_see("NEW.rowid")} END;
  $|      CREATE TRIGGER session_binding_drop AFTER DELETE ON bindings BEGIN
  $|        DELETE FROM session_binding_rows WHERE session = OLD.session_key AND binding_rowid = OLD.rowid;
  $|      END;
  $|    
)
    )
  } else {
    ignore(session_bindings_ready(db))
  })
}

///|
let am_version : Int = 1

///|
/// The writers of one kind of mark, pins or kept chats (archive-mark-index.ts `triggers`).
fn archive_mark_triggers(kind : String) -> String {
  let (source, key, rows, staged) = if kind == "pins" {
    ("pins", "session", "archive_pin_rows", "archive_pin_replaced")
  } else {
    ("kept_chats", "thread", "archive_keep_rows", "archive_keep_replaced")
  }
  let prefix = if kind == "pins" { "archive_pin" } else { "archive_keep" }
  let displaced =
(
  $|SELECT rowid, \{key} FROM \{source} WHERE viewer = NEW.viewer AND \{key} = NEW.\{key}
  $|    UNION SELECT rowid, \{key} FROM \{source} WHERE rowid = NEW.rowid
)
  let stage = (update : Bool) => {
    let union_old = if update { "UNION SELECT OLD.rowid, OLD.\{key}" } else { "" }
(
  $|DELETE FROM \{staged}; INSERT INTO \{staged} (position, value) \{displaced}
  $|    \{union_old};
)
  }
  let reconcile =
(
  $|DELETE FROM \{rows} WHERE (\{key}, position) IN (SELECT value, position FROM \{staged})
  $|      AND NOT EXISTS (SELECT 1 FROM \{source} s WHERE s.rowid = \{rows}.position AND s.\{key} IS \{rows}.\{key});
  $|    INSERT INTO \{rows} (\{key}, position) SELECT s.\{key}, s.rowid FROM \{staged} r CROSS JOIN \{source} s ON s.rowid = r.position
  $|      WHERE NOT EXISTS (SELECT 1 FROM \{rows} i WHERE i.\{key} IS s.\{key} AND i.position = s.rowid);
  $|    DELETE FROM \{staged};
)
  let see =
(
  $|INSERT INTO \{rows} (\{key}, position) SELECT s.\{key}, s.rowid FROM \{source} s WHERE s.rowid = NEW.rowid
  $|    AND NOT EXISTS (SELECT 1 FROM \{rows} i WHERE i.\{key} IS s.\{key} AND i.position = s.rowid);
)
  let changed =
(
  $|OLD.rowid IS NOT NEW.rowid OR OLD.viewer IS NOT NEW.viewer OR OLD.\{key} IS NOT NEW.\{key}
)
  let written =
(
  $|
  $|    CREATE TRIGGER \{prefix}_before_add BEFORE INSERT ON \{source} BEGIN \{stage(false)} END;
  $|    CREATE TRIGGER \{prefix}_add AFTER INSERT ON \{source} BEGIN \{reconcile} \{see} END;
  $|    CREATE TRIGGER \{prefix}_before_change BEFORE UPDATE ON \{source} WHEN \{changed} BEGIN \{stage(true)} END;
  $|    CREATE TRIGGER \{prefix}_change AFTER UPDATE ON \{source} WHEN \{changed} BEGIN \{reconcile} \{see} END;
  $|    CREATE TRIGGER \{prefix}_drop AFTER DELETE ON \{source} BEGIN
  $|      DELETE FROM \{rows} WHERE \{key} IS OLD.\{key} AND position = OLD.rowid;
  $|    END;
)
  written
}

///|
/// Whether every kind of mark is prepared, of this version (`archiveMarksReady`).
fn archive_marks_ready(db : @sql.Db) -> Bool raise {
  let rows = db.all(
    "SELECT kind, version, CAST(last_rowid AS TEXT) AS last_rowid,\n    CAST(end_rowid AS TEXT) AS end_rowid, complete FROM archive_mark_meta ORDER BY kind",
    [],
  )
  if rows.length() != 2 ||
    rows[0].get("kind") != Some(Json::string("kept")) ||
    rows[1].get("kind") != Some(Json::string("pins")) {
    refuse("archive mark index version marker is missing")
  }
  for row in rows {
    if !is_num(Some(row), "version", am_version) {
      refuse("archive mark index version \{shown(Some(row), "version", "undefined")} is incompatible with \{am_version}")
    }
  }
  rows.iter().all(row => is_num(Some(row), "complete", 1))
}

///|
/// The marks that keep a chat out of automatic archive, by the chat (`installArchiveMarkIndex`).
fn install_archive_mark_index(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "archive_mark_meta")
  if installed() {
    ignore(archive_marks_ready(db))
    return
  }
  let version = am_version
  immediate(db, () => if !installed() {
    db.exec(
(
  $|
  $|      CREATE TABLE archive_mark_meta (kind TEXT PRIMARY KEY, version INTEGER NOT NULL, last_rowid INTEGER,
  $|        end_rowid INTEGER, complete INTEGER NOT NULL) WITHOUT ROWID;
  $|      INSERT INTO archive_mark_meta SELECT 'pins', \{version}, NULL, (SELECT rowid FROM pins ORDER BY rowid DESC LIMIT 1),
  $|        NOT EXISTS (SELECT 1 FROM pins LIMIT 1);
  $|      INSERT INTO archive_mark_meta SELECT 'kept', \{version}, NULL, (SELECT rowid FROM kept_chats ORDER BY rowid DESC LIMIT 1),
  $|        NOT EXISTS (SELECT 1 FROM kept_chats LIMIT 1);
  $|      CREATE TABLE archive_pin_rows (session TEXT NOT NULL, position INTEGER NOT NULL, PRIMARY KEY (session, position)) WITHOUT ROWID;
  $|      CREATE TABLE archive_keep_rows (thread INTEGER NOT NULL, position INTEGER NOT NULL, PRIMARY KEY (thread, position)) WITHOUT ROWID;
  $|      CREATE TABLE archive_pin_replaced (position INTEGER PRIMARY KEY, value TEXT NOT NULL);
  $|      CREATE TABLE archive_keep_replaced (position INTEGER PRIMARY KEY, value INTEGER NOT NULL);
  $|      \{archive_mark_triggers("pins")}
  $|      \{archive_mark_triggers("kept")}
  $|    
)
    )
  } else {
    ignore(archive_marks_ready(db))
  })
}

///|
let su_version : Int = 1

///|
fn su_up(name : String) -> String {
(
  $|(\{name}.state = 'running' OR (\{name}.state = 'exited' AND \{name}.port IS NOT NULL))
)
}

///|
let su_changed : String =
(
  $|OLD.rowid IS NOT NEW.rowid OR OLD.id IS NOT NEW.id OR OLD.token IS NOT NEW.token
  $|  OR OLD.session_key IS NOT NEW.session_key OR \{su_up("OLD")} IS NOT \{su_up("NEW")}
  $|  OR EXISTS (SELECT 1 FROM session_up_job_replaced)
)

///|
fn su_displaced(id : String, token : String, rowid : String) -> String {
(
  $|SELECT j.rowid, j.session_key FROM jobs j WHERE j.id = \{id}
  $|  UNION SELECT j.rowid, j.session_key FROM jobs j WHERE j.token = \{token}
  $|  UNION SELECT j.rowid, j.session_key FROM jobs j WHERE j.rowid = \{rowid}
)
}

///|
fn su_conflict(id : String, token : String, rowid : String) -> String {
(
  $|SELECT 1 FROM jobs WHERE id = \{id} OR token = \{token} OR rowid = \{rowid}
)
}

///|
fn su_stage(old : Bool) -> String {
  let union_old = if old { "UNION SELECT OLD.rowid, OLD.session_key" } else { "" }
(
  $|DELETE FROM session_up_job_replaced;
  $|  INSERT INTO session_up_job_replaced (job_rowid, session) \{su_displaced("NEW.id", "NEW.token", "NEW.rowid")}
  $|    \{union_old};
)
}

///|
fn su_see(rowid : String) -> String {
(
  $|INSERT INTO session_up_job_rows (session, job_rowid)
  $|  SELECT j.session_key, j.rowid FROM jobs j WHERE j.rowid = \{rowid} AND \{su_up("j")}
  $|    AND NOT EXISTS (SELECT 1 FROM session_up_job_rows i WHERE i.session = j.session_key AND i.job_rowid = j.rowid);
)
}

///|
let su_reconcile : String =
(
  $|DELETE FROM session_up_job_rows WHERE (session, job_rowid) IN
  $|    (SELECT session, job_rowid FROM session_up_job_replaced)
  $|    AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.rowid = session_up_job_rows.job_rowid
  $|      AND j.session_key = session_up_job_rows.session AND \{su_up("j")});
  $|  INSERT INTO session_up_job_rows (session, job_rowid)
  $|    SELECT j.session_key, j.rowid FROM session_up_job_replaced r CROSS JOIN jobs j ON j.rowid = r.job_rowid
  $|    WHERE \{su_up("j")} AND NOT EXISTS (SELECT 1 FROM session_up_job_rows i
  $|      WHERE i.session = j.session_key AND i.job_rowid = j.rowid);
  $|  DELETE FROM session_up_job_replaced;
)

///|
/// Whether the up jobs' index is fresh (all of it) or the session's are prepared (`sessionUpJobsReady`).
fn session_up_jobs_ready(db : @sql.Db, session : String) -> Bool raise {
  let meta = first_row(db, "SELECT version, fresh FROM session_up_job_meta WHERE id = 1")
  if meta is None || !is_num(meta, "version", su_version) {
    refuse("session up jobs index version \{shown(meta, "version", "missing")} is incompatible with \{su_version}")
  }
  if is_num(meta, "fresh", 1) {
    return true
  }
  is_num(
    first_row(db, "SELECT complete FROM session_up_job_scopes WHERE session = ?", params=[Json::string(session)]),
    "complete",
    1,
  )
}

///|
/// A session's running jobs and services waiting to restart (`installSessionUpJobs`).
fn install_session_up_jobs(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "session_up_job_meta")
  if installed() {
    ignore(session_up_jobs_ready(db, ""))
    return
  }
  immediate(db, () => if !installed() {
    db.exec(
(
  $|
  $|      CREATE TABLE session_up_job_meta (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL, fresh INTEGER NOT NULL) WITHOUT ROWID;
  $|      INSERT INTO session_up_job_meta SELECT 1, \{su_version},
  $|        NOT EXISTS (SELECT 1 FROM jobs INDEXED BY jobs_state WHERE state = 'running')
  $|        AND NOT EXISTS (SELECT 1 FROM jobs INDEXED BY jobs_up WHERE state = 'exited' AND port IS NOT NULL);
  $|      CREATE TABLE session_up_job_scopes (session TEXT PRIMARY KEY, last_rowid INTEGER, end_rowid INTEGER, complete INTEGER NOT NULL) WITHOUT ROWID;
  $|      CREATE TABLE session_up_job_rows (session TEXT NOT NULL, job_rowid INTEGER NOT NULL, PRIMARY KEY (session, job_rowid)) WITHOUT ROWID;
  $|      CREATE TABLE session_up_job_replaced (job_rowid INTEGER PRIMARY KEY, session TEXT NOT NULL);
  $|      CREATE TRIGGER session_up_job_before_add BEFORE INSERT ON jobs
  $|        WHEN EXISTS (SELECT 1 FROM session_up_job_replaced)
  $|          OR EXISTS (\{su_conflict("NEW.id", "NEW.token", "NEW.rowid")})
  $|        BEGIN \{su_stage(false)} END;
  $|      CREATE TRIGGER session_up_job_add AFTER INSERT ON jobs
  $|        WHEN \{su_up("NEW")} OR EXISTS (SELECT 1 FROM session_up_job_replaced)
  $|        BEGIN \{su_reconcile} \{su_see("NEW.rowid")} END;
  $|      CREATE TRIGGER session_up_job_before_change BEFORE UPDATE ON jobs
  $|        WHEN \{su_changed}
  $|        BEGIN \{su_stage(true)} END;
  $|      CREATE TRIGGER session_up_job_change AFTER UPDATE ON jobs
  $|        WHEN \{su_changed}
  $|        BEGIN \{su_reconcile} \{su_see("NEW.rowid")} END;
  $|      CREATE TRIGGER session_up_job_drop AFTER DELETE ON jobs WHEN \{su_up("OLD")} BEGIN
  $|        DELETE FROM session_up_job_rows WHERE session = OLD.session_key AND job_rowid = OLD.rowid;
  $|      END;
  $|    
)
    )
  } else {
    ignore(session_up_jobs_ready(db, ""))
  })
}

///|
let wu_version : Int = 1

///|
fn wu_up(row : String) -> String {
(
  $|(\{row}.state = 'running' OR (\{row}.state = 'exited' AND \{row}.port IS NOT NULL))
)
}

///|
fn wu_odd(session : String, ws : String) -> String {
(
  $|(typeof(\{session}) <> 'text'
  $|  OR instr(CAST(\{session} AS BLOB), x'00') > 0 OR \{session} GLOB '*[^ -~]*'
  $|  OR (\{ws} IS NOT NULL AND (typeof(\{ws}) <> 'text' OR instr(CAST(\{ws} AS BLOB), x'00') > 0
  $|    OR \{ws} GLOB '*[^ -~]*')))
)
}

///|
fn wu_fields(session : String, ws : String) -> String {
(
  $|CASE WHEN \{wu_odd(session, ws)} THEN 2 WHEN \{ws} IS NULL THEN 1 ELSE 0 END,
  $|  CASE WHEN \{wu_odd(session, ws)} OR \{ws} IS NULL THEN '' ELSE \{ws} END
)
}

///|
let wu_conflict : String =
(
  $|ON CONFLICT(session) DO UPDATE SET scope=excluded.scope, ws=excluded.ws
  $|  WHERE scope IS NOT excluded.scope OR ws IS NOT excluded.ws
)

///|
fn wu_put(session : String) -> String {
(
  $|INSERT INTO workspace_up_sessions(session,scope,ws)
  $|  SELECT x.session, \{wu_fields("x.session", "s.ws")} FROM (SELECT \{session} AS session) x
  $|  LEFT JOIN sessions s ON s.key=x.session
  $|  WHERE EXISTS (SELECT 1 FROM session_up_job_rows u WHERE u.session=x.session) \{wu_conflict};
)
}

///|
let wu_refresh_staged : String =
(
  $|DELETE FROM workspace_up_sessions WHERE session IN (SELECT session FROM workspace_up_session_replaced)
  $|    AND NOT EXISTS (SELECT 1 FROM session_up_job_rows u WHERE u.session=workspace_up_sessions.session);
  $|  INSERT INTO workspace_up_sessions(session,scope,ws)
  $|    SELECT r.session, \{wu_fields("r.session", "s.ws")} FROM workspace_up_session_replaced r
  $|    LEFT JOIN sessions s ON s.key=r.session
  $|    WHERE EXISTS (SELECT 1 FROM session_up_job_rows u WHERE u.session=r.session) \{wu_conflict};
)

///|
let wu_displaced : String =
(
  $|SELECT s.key FROM sessions s WHERE (s.key=NEW.key OR s.token=NEW.token OR s.rowid=NEW.rowid)
  $|  AND EXISTS (SELECT 1 FROM workspace_up_sessions p WHERE p.session=s.key)
)

///|
let wu_clear_staged : String = "DELETE FROM workspace_up_session_replaced WHERE session IS NOT NULL;"

///|
fn workspace_up_jobs_ready(db : @sql.Db) -> Bool raise {
  let meta = first_row(db, "SELECT version,ready FROM workspace_up_meta WHERE id=1")
  if meta is None || !is_num(meta, "version", wu_version) {
    refuse("workspace up jobs index version \{shown(meta, "version", "missing")} is incompatible with \{wu_version}")
  }
  is_num(meta, "ready", 1)
}

///|
/// A workspace's sessions with jobs up, its writers installed without scanning old jobs (`installWorkspaceUpJobs`).
fn install_workspace_up_jobs(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "workspace_up_meta")
  if installed() {
    ignore(workspace_up_jobs_ready(db))
    return
  }
  immediate(db, () => if !installed() {
    db.exec(
(
  $|
  $|      CREATE TABLE workspace_up_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,phase INTEGER NOT NULL,
  $|        last_port,last_rowid INTEGER,running_end INTEGER,guard_end INTEGER,guard_last INTEGER,port_batches INTEGER NOT NULL,
  $|        ready INTEGER NOT NULL) WITHOUT ROWID;
  $|      INSERT INTO workspace_up_meta SELECT 1,\{wu_version},0,NULL,NULL,
  $|        (SELECT rowid FROM jobs INDEXED BY jobs_state WHERE state='running' ORDER BY rowid DESC LIMIT 1),
  $|        (SELECT rowid FROM jobs INDEXED BY jobs_state WHERE state='exited' ORDER BY rowid DESC LIMIT 1),NULL,0,
  $|        (SELECT fresh FROM session_up_job_meta WHERE id=1)=1 AND NOT EXISTS (SELECT 1 FROM session_up_job_rows LIMIT 1);
  $|      CREATE TABLE workspace_up_sessions(session TEXT PRIMARY KEY,scope INTEGER NOT NULL,ws TEXT NOT NULL) WITHOUT ROWID;
  $|      CREATE INDEX workspace_up_sessions_scope ON workspace_up_sessions(scope,ws,session);
  $|      CREATE TABLE workspace_up_session_replaced(session TEXT PRIMARY KEY) WITHOUT ROWID;
  $|
  $|      CREATE TRIGGER workspace_up_row_add AFTER INSERT ON session_up_job_rows
  $|      WHEN NOT EXISTS (SELECT 1 FROM workspace_up_sessions WHERE session=NEW.session)
  $|      BEGIN \{wu_put("NEW.session")} END;
  $|      CREATE TRIGGER workspace_up_row_drop AFTER DELETE ON session_up_job_rows
  $|      WHEN NOT EXISTS (SELECT 1 FROM session_up_job_rows WHERE session=OLD.session)
  $|      BEGIN DELETE FROM workspace_up_sessions WHERE session=OLD.session; END;
  $|      CREATE TRIGGER workspace_up_before_session_add BEFORE INSERT ON sessions
  $|      WHEN EXISTS (SELECT 1 FROM workspace_up_session_replaced) OR EXISTS (\{wu_displaced})
  $|      BEGIN \{wu_clear_staged} INSERT OR IGNORE INTO workspace_up_session_replaced \{wu_displaced}; END;
  $|      CREATE TRIGGER workspace_up_after_session_add AFTER INSERT ON sessions
  $|      BEGIN \{wu_refresh_staged} \{wu_put("NEW.key")} \{wu_clear_staged} END;
  $|      -- A workspace-only change cannot displace another session; the after trigger can refresh it directly.
  $|      CREATE TRIGGER workspace_up_before_session_change BEFORE UPDATE ON sessions
  $|      WHEN OLD.rowid IS NOT NEW.rowid OR OLD.key IS NOT NEW.key OR OLD.token IS NOT NEW.token
  $|      BEGIN \{wu_clear_staged}
  $|        INSERT OR IGNORE INTO workspace_up_session_replaced SELECT OLD.key
  $|          WHERE EXISTS (SELECT 1 FROM workspace_up_sessions WHERE session=OLD.key);
  $|        INSERT OR IGNORE INTO workspace_up_session_replaced \{wu_displaced};
  $|      END;
  $|      CREATE TRIGGER workspace_up_after_session_change AFTER UPDATE ON sessions
  $|      WHEN OLD.rowid IS NOT NEW.rowid OR OLD.key IS NOT NEW.key OR OLD.token IS NOT NEW.token OR OLD.ws IS NOT NEW.ws
  $|      BEGIN \{wu_refresh_staged} \{wu_put("NEW.key")} \{wu_clear_staged} END;
  $|      CREATE TRIGGER workspace_up_after_session_drop AFTER DELETE ON sessions
  $|      WHEN EXISTS (SELECT 1 FROM workspace_up_sessions WHERE session=OLD.key)
  $|      BEGIN \{wu_put("OLD.key")} END;
  $|
  $|      
)
    )
    if !workspace_up_jobs_ready(db) {
      db.exec(
(
  $|CREATE TRIGGER workspace_up_copy_moved AFTER UPDATE OF state,port ON jobs
  $|        WHEN \{wu_up("NEW")}
  $|        BEGIN INSERT INTO session_up_job_rows(session,job_rowid)
  $|          SELECT NEW.session_key,NEW.rowid WHERE NOT EXISTS
  $|            (SELECT 1 FROM session_up_job_rows WHERE session=NEW.session_key AND job_rowid=NEW.rowid); END;
)
      )
    }
  } else {
    ignore(workspace_up_jobs_ready(db))
  })
}

///|
let jn_version : Int = 1

///|
fn check_job_name_first(db : @sql.Db) -> Unit raise {
  let row = first_row(db, "SELECT version FROM job_name_first_meta WHERE id=1")
  if row is None || !is_num(row, "version", jn_version) {
    refuse("job name first index version \{shown(row, "version", "missing")} is incompatible with \{jn_version}")
  }
}

///|
/// One requested own chat per session with an up job (`installJobNameFirst`).
fn install_job_name_first(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "job_name_first_meta")
  if installed() {
    check_job_name_first(db)
    return
  }
  immediate(db, () => if !installed() {
    db.exec(
(
  $|
  $|      CREATE TABLE job_name_first_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL) WITHOUT ROWID;
  $|      INSERT INTO job_name_first_meta VALUES(1,\{jn_version});
  $|      CREATE TABLE job_name_first(owner TEXT PRIMARY KEY,thread INTEGER NOT NULL UNIQUE,best INTEGER,after_session TEXT,
  $|        through_session TEXT,restart INTEGER NOT NULL DEFAULT 0,ready INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
  $|      CREATE INDEX job_name_first_best ON job_name_first(best);
  $|
  $|      -- REPLACE can remove either of these old memberships without firing DELETE triggers in an older connection.
  $|      CREATE TRIGGER job_name_first_before_add BEFORE INSERT ON thread_sessions BEGIN
  $|        UPDATE job_name_first SET ready=0,restart=1 WHERE restart=0 AND best IN (
  $|          SELECT rowid FROM thread_sessions WHERE rowid=NEW.rowid
  $|          UNION SELECT rowid FROM thread_sessions WHERE thread=NEW.thread AND session=NEW.session);
  $|      END;
  $|      CREATE TRIGGER job_name_first_after_add AFTER INSERT ON thread_sessions BEGIN
  $|        UPDATE job_name_first SET best=NEW.rowid WHERE thread=NEW.thread AND restart=0 AND best IS NOT NEW.rowid
  $|          AND (best IS NULL OR (SELECT rowid FROM thread_sessions WHERE rowid IN (best,NEW.rowid)
  $|            ORDER BY joined_at,rowid LIMIT 1)=NEW.rowid);
  $|      END;
  $|      CREATE TRIGGER job_name_first_before_change BEFORE UPDATE ON thread_sessions
  $|      WHEN OLD.thread IS NOT NEW.thread OR OLD.session IS NOT NEW.session OR OLD.joined_at IS NOT NEW.joined_at OR OLD.rowid IS NOT NEW.rowid
  $|      BEGIN
  $|        UPDATE job_name_first SET ready=0,restart=1 WHERE restart=0 AND (best=OLD.rowid OR best IN (
  $|          SELECT rowid FROM thread_sessions WHERE rowid=NEW.rowid
  $|          UNION SELECT rowid FROM thread_sessions WHERE thread=NEW.thread AND session=NEW.session));
  $|      END;
  $|      CREATE TRIGGER job_name_first_after_change AFTER UPDATE ON thread_sessions
  $|      WHEN OLD.thread IS NOT NEW.thread OR OLD.session IS NOT NEW.session OR OLD.joined_at IS NOT NEW.joined_at OR OLD.rowid IS NOT NEW.rowid
  $|      BEGIN
  $|        UPDATE job_name_first SET best=NEW.rowid WHERE thread=NEW.thread AND restart=0 AND best IS NOT NEW.rowid
  $|          AND (best IS NULL OR (SELECT rowid FROM thread_sessions WHERE rowid IN (best,NEW.rowid)
  $|            ORDER BY joined_at,rowid LIMIT 1)=NEW.rowid);
  $|      END;
  $|      CREATE TRIGGER job_name_first_drop BEFORE DELETE ON thread_sessions BEGIN
  $|        UPDATE job_name_first SET ready=0,restart=1 WHERE best=OLD.rowid AND restart=0;
  $|      END;
  $|      -- A session can own at most one tracked chat, so finishing its final up job removes at most one row.
  $|      CREATE TRIGGER job_name_first_job_drop AFTER DELETE ON session_up_job_rows
  $|      WHEN NOT EXISTS (SELECT 1 FROM session_up_job_rows WHERE session=OLD.session LIMIT 1)
  $|      BEGIN DELETE FROM job_name_first WHERE owner=OLD.session; END;
  $|    
)
    )
  } else {
    check_job_name_first(db)
  })
}

///|
/// The workspace a remote task's session is of: the second colon-delimited part of its key.
fn rr_ws(name : String) -> String {
(
  $|(CASE WHEN instr(\{name}.session, ':') = 0 THEN '' ELSE
  $|  CASE WHEN instr(substr(\{name}.session, instr(\{name}.session, ':') + 1), ':') = 0
  $|    THEN substr(\{name}.session, instr(\{name}.session, ':') + 1)
  $|    ELSE substr(substr(\{name}.session, instr(\{name}.session, ':') + 1), 1,
  $|      instr(substr(\{name}.session, instr(\{name}.session, ':') + 1), ':') - 1) END END)
)
}

///|
let remote_runs_schema : String =
(
  $|
  $|CREATE TABLE remote_run_progress (id INTEGER PRIMARY KEY CHECK (id = 1), after_seq INTEGER, end_seq INTEGER, done INTEGER NOT NULL);
  $|INSERT INTO remote_run_progress SELECT 1, NULL, (SELECT MAX(rowid) FROM remote_runs), NOT EXISTS (SELECT 1 FROM remote_runs LIMIT 1);
  $|CREATE TABLE remote_run_lookup (ws TEXT NOT NULL, at INTEGER NOT NULL, seq INTEGER NOT NULL, job TEXT NOT NULL, session TEXT NOT NULL,
  $|  PRIMARY KEY (ws, at, seq)) WITHOUT ROWID;
  $|CREATE TABLE remote_run_by_time (at INTEGER NOT NULL, seq INTEGER NOT NULL, job TEXT NOT NULL, session TEXT NOT NULL,
  $|  PRIMARY KEY (at, seq)) WITHOUT ROWID;
  $|CREATE TABLE remote_run_by_job (job TEXT PRIMARY KEY, ws TEXT NOT NULL, at INTEGER NOT NULL, seq INTEGER NOT NULL) WITHOUT ROWID;
  $|CREATE TABLE remote_run_counts (ws TEXT PRIMARY KEY, n INTEGER NOT NULL) WITHOUT ROWID;
  $|CREATE TABLE remote_run_total (id INTEGER PRIMARY KEY CHECK (id = 1), n INTEGER NOT NULL);
  $|INSERT INTO remote_run_total VALUES (1, 0);
  $|CREATE TRIGGER remote_run_lookup_add AFTER INSERT ON remote_run_lookup BEGIN
  $|  INSERT INTO remote_run_by_time VALUES (NEW.at, NEW.seq, NEW.job, NEW.session);
  $|  INSERT INTO remote_run_by_job VALUES (NEW.job, NEW.ws, NEW.at, NEW.seq);
  $|  INSERT INTO remote_run_counts SELECT NEW.ws, 1 WHERE NEW.at >= 0
  $|    ON CONFLICT (ws) DO UPDATE SET n = n + 1;
  $|  UPDATE remote_run_total SET n = n + 1 WHERE id = 1 AND NEW.at >= 0;
  $|END;
  $|CREATE TRIGGER remote_run_lookup_drop AFTER DELETE ON remote_run_lookup BEGIN
  $|  DELETE FROM remote_run_by_time WHERE at = OLD.at AND seq = OLD.seq;
  $|  DELETE FROM remote_run_by_job WHERE job = OLD.job AND ws = OLD.ws AND at = OLD.at AND seq = OLD.seq;
  $|  UPDATE remote_run_counts SET n = n - 1 WHERE ws = OLD.ws AND OLD.at >= 0;
  $|  DELETE FROM remote_run_counts WHERE ws = OLD.ws AND n = 0;
  $|  UPDATE remote_run_total SET n = n - 1 WHERE id = 1 AND OLD.at >= 0;
  $|END;
  $|CREATE TRIGGER remote_run_add AFTER INSERT ON remote_runs BEGIN
  $|  -- SQLite's INSERT OR REPLACE can delete a conflicting old row without firing its delete trigger. Remove its indexed
  $|  -- copy by job before inserting the replacement; INSERT OR IGNORE never reaches this trigger on a conflict.
  $|  DELETE FROM remote_run_lookup WHERE (ws, at, seq) = (SELECT ws, at, seq FROM remote_run_by_job WHERE job = NEW.job);
  $|  INSERT OR IGNORE INTO remote_run_lookup VALUES (\{rr_ws("NEW")}, NEW.at, NEW.rowid, NEW.job, NEW.session);
  $|END;
  $|CREATE TRIGGER remote_run_drop AFTER DELETE ON remote_runs BEGIN
  $|  DELETE FROM remote_run_lookup WHERE ws = \{rr_ws("OLD")} AND at = OLD.at AND seq = OLD.rowid;
  $|END;
  $|CREATE TRIGGER remote_run_change AFTER UPDATE ON remote_runs BEGIN
  $|  DELETE FROM remote_run_lookup WHERE ws = \{rr_ws("OLD")} AND at = OLD.at AND seq = OLD.rowid;
  $|  DELETE FROM remote_run_lookup WHERE (ws, at, seq) = (SELECT ws, at, seq FROM remote_run_by_job WHERE job = NEW.job);
  $|  INSERT OR IGNORE INTO remote_run_lookup VALUES (\{rr_ws("NEW")}, NEW.at, NEW.rowid, NEW.job, NEW.session);
  $|END;
  $|
)

///|
/// The tasks another station's chats ran here: empty structures and their writers (`installRemoteRuns`).
fn install_remote_runs(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "remote_run_progress")
  if installed() {
    return
  }
  immediate(db, () => if !installed() { db.exec(remote_runs_schema) })
}
