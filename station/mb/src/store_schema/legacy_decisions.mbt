// The decision checks' lookups by time and by session, and the archive policy's by workspace, on an older populated
// store (station/src/store/legacy-decision-time.ts, legacy-decision-session.ts, archive-policy-index.ts): a native
// index on a small or new one; on a larger one empty lookups and their writers, filled later in bounded batches.

///|
let dt_version : Int = 1

///|
pub let decision_time_index : String = "CREATE INDEX IF NOT EXISTS decision_checks_lately ON decision_checks (created_at, session)"

///|
/// Whether the older store's time lookup is there, of this version (legacy-decision-time.ts `hasLegacyDecisionTime`).
pub fn has_legacy_decision_time(db : @sql.Db) -> Bool raise {
  if !exists(db, "table", "legacy_decision_time_meta") {
    return false
  }
  if !exists(db, "table", "legacy_decision_time") {
    refuse("legacy decision-time metadata has no lookup")
  }
  let row = first_row(db, "SELECT version,complete FROM legacy_decision_time_meta WHERE id=1")
  if row is None || !is_num(row, "version", dt_version) || !(is_num(row, "complete", 0) || is_num(row, "complete", 1)) {
    refuse("legacy decision-time lookup has an unsupported version")
  }
  true
}

///|
fn dt_reconcile(ids : String) -> String {
(
  $|DELETE FROM legacy_decision_time WHERE id IN (\{ids});
  $|  INSERT INTO legacy_decision_time(id,created_at,session)
  $|    SELECT id,created_at,session FROM decision_checks WHERE id IN (\{ids});
)
}

///|
let dt_legacy_schema : String =
(
  $|
  $|  CREATE TABLE legacy_decision_time_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,
  $|    complete INTEGER NOT NULL,cursor INTEGER,end_id INTEGER) WITHOUT ROWID;
  $|  INSERT INTO legacy_decision_time_meta VALUES(1,\{dt_version},0,NULL,(SELECT MAX(id) FROM decision_checks));
  $|  CREATE TABLE legacy_decision_time(id INTEGER PRIMARY KEY,created_at INTEGER NOT NULL,session TEXT NOT NULL);
  $|  CREATE INDEX legacy_decision_time_at ON legacy_decision_time(created_at,session);
  $|  CREATE TRIGGER legacy_decision_time_insert AFTER INSERT ON decision_checks BEGIN
  $|    INSERT INTO legacy_decision_time(id,created_at,session)
  $|      SELECT id,created_at,session FROM decision_checks WHERE id=NEW.id
  $|      ON CONFLICT(id) DO UPDATE SET created_at=excluded.created_at,session=excluded.session;
  $|  END;
  $|  CREATE TRIGGER legacy_decision_time_update AFTER UPDATE OF id,created_at,session ON decision_checks
  $|    WHEN OLD.id IS NOT NEW.id OR OLD.created_at IS NOT NEW.created_at OR OLD.session IS NOT NEW.session
  $|    BEGIN \{dt_reconcile("OLD.id,NEW.id")} END;
  $|  CREATE TRIGGER legacy_decision_time_delete AFTER DELETE ON decision_checks BEGIN \{dt_reconcile("OLD.id")} END;
)

///|
/// Chosen while holding the writer lock (legacy-decision-time.ts `installDecisionTimeIndex`).
fn install_decision_time_index(db : @sql.Db, share_session? : Bool = false) -> Unit raise {
  let native = () => exists(db, "index", "decision_checks_lately")
  if native() || has_legacy_decision_time(db) {
    return
  }
  immediate(db, () => if !native() && !has_legacy_decision_time(db) {
    if !some_row(db, "SELECT 1 FROM decision_checks LIMIT 1 OFFSET 63") {
      db.exec(decision_time_index)
    } else {
      db.exec(dt_legacy_schema)
      if share_session &&
        !exists(db, "index", "decision_checks_session") &&
        !exists(db, "table", "legacy_decision_session_meta") {
        db.exec("CREATE INDEX legacy_decision_time_by_session ON legacy_decision_time(session)")
      }
    }
  })
}

///|
let ds_version : Int = 1

///|
pub let decision_session_index : String = "CREATE INDEX IF NOT EXISTS decision_checks_session ON decision_checks (session, id)"

///|
/// A session lookup's state (its `complete`), None where it is not there (legacy-decision-session.ts `sessionState`).
fn session_state(db : @sql.Db, table : String) -> Int? raise {
  if !exists(db, "table", "\{table}_meta") {
    return None
  }
  if !exists(db, "table", table) {
    refuse("legacy decision-session metadata has no lookup")
  }
  let row = first_row(db, "SELECT version,complete FROM \{table}_meta WHERE id=1")
  let complete = num(row, "complete")
  if row is None ||
    !is_num(row, "version", ds_version) ||
    !(
      complete == Some(0.0) ||
      complete == Some(1.0) ||
      (table == "legacy_decision_session_repair" && complete == Some(2.0))
    ) {
    refuse("legacy decision-session lookup has an unsupported version")
  }
  complete.map(c => c.to_int())
}

///|
fn has_session_lookup(db : @sql.Db, table : String) -> Bool raise {
  let state = session_state(db, table)
  state is Some(s) && s != 2 && exists(db, "index", "\{table}_by_session")
}

///|
pub fn has_legacy_decision_session(db : @sql.Db) -> Bool raise {
  has_session_lookup(db, "legacy_decision_session")
}

///|
pub fn has_decision_session_repair(db : @sql.Db) -> Bool raise {
  has_session_lookup(db, "legacy_decision_session_repair")
}

///|
/// A time lookup installed while both native indexes were missing carries the session index in the same table.
pub fn has_shared_decision_session(db : @sql.Db) -> Bool raise {
  if !exists(db, "index", "legacy_decision_time_by_session") {
    return false
  }
  if !has_legacy_decision_time(db) {
    refuse("shared decision-session index has no time lookup")
  }
  true
}

///|
fn ds_reconcile(ids : String) -> String {
(
  $|DELETE FROM legacy_decision_session WHERE id IN (\{ids});
  $|  INSERT INTO legacy_decision_session(id,session) SELECT id,session FROM decision_checks WHERE id IN (\{ids});
)
}

///|
let ds_schema : String =
(
  $|
  $|CREATE TABLE legacy_decision_session_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,
  $|  complete INTEGER NOT NULL,cursor INTEGER,end_id INTEGER) WITHOUT ROWID;
  $|INSERT INTO legacy_decision_session_meta VALUES(1,\{ds_version},0,NULL,(SELECT MAX(id) FROM decision_checks));
  $|CREATE TABLE legacy_decision_session(id INTEGER PRIMARY KEY,session TEXT NOT NULL);
  $|CREATE INDEX legacy_decision_session_by_session ON legacy_decision_session(session);
  $|CREATE TRIGGER legacy_decision_session_insert AFTER INSERT ON decision_checks BEGIN
  $|  INSERT INTO legacy_decision_session(id,session) SELECT id,session FROM decision_checks WHERE id=NEW.id
  $|  ON CONFLICT(id) DO UPDATE SET session=excluded.session;
  $|END;
  $|CREATE TRIGGER legacy_decision_session_update AFTER UPDATE OF id,session ON decision_checks
  $|  WHEN OLD.id IS NOT NEW.id OR OLD.session IS NOT NEW.session BEGIN \{ds_reconcile("OLD.id,NEW.id")} END;
  $|CREATE TRIGGER legacy_decision_session_delete AFTER DELETE ON decision_checks BEGIN \{ds_reconcile("OLD.id")} END;
)

///|
/// Rechecks both the row bound and another opener under the writer lock (`installDecisionSessionIndex`).
fn install_decision_session_index(db : @sql.Db) -> Unit raise {
  let native = () => exists(db, "index", "decision_checks_session")
  let available = () => native() ||
    has_legacy_decision_session(db) ||
    has_shared_decision_session(db) ||
    has_decision_session_repair(db)
  if available() || session_state(db, "legacy_decision_session_repair") == Some(2) {
    return
  }
  immediate(db, () => if !available() && session_state(db, "legacy_decision_session_repair") != Some(2) {
    if !some_row(db, "SELECT 1 FROM decision_checks LIMIT 1 OFFSET 63") {
      db.exec(decision_session_index)
    } else if session_state(db, "legacy_decision_session_repair") is Some(_) {
      db.exec(
(
  $|DROP TRIGGER IF EXISTS legacy_decision_session_repair_insert;
  $|          DROP TRIGGER IF EXISTS legacy_decision_session_repair_update;
  $|          DROP TRIGGER IF EXISTS legacy_decision_session_repair_delete;
  $|          UPDATE legacy_decision_session_repair_meta SET complete=2 WHERE id=1
)
      )
    } else if exists(db, "table", "legacy_decision_session_meta") {
      db.exec(ds_schema.replace_all(old="legacy_decision_session", new="legacy_decision_session_repair"))
    } else {
      db.exec(ds_schema)
    }
  })
}

///|
let ap_version : Int = 1

///|
/// Whether the older store's archive policy lookup is there, of this version.
pub fn has_legacy_archive_policy(db : @sql.Db) -> Bool raise {
  if !exists(db, "table", "archive_policy_lookup_meta") {
    return false
  }
  let row = first_row(db, "SELECT version,complete FROM archive_policy_lookup_meta WHERE id=1")
  if row is None || !is_num(row, "version", ap_version) || !(is_num(row, "complete", 0) || is_num(row, "complete", 1)) {
    refuse("archive policy lookup has an unsupported version")
  }
  true
}

///|
fn ap_reconcile(ids : String) -> String {
(
  $|DELETE FROM archive_policy_lookup WHERE id IN (\{ids});
  $|  INSERT INTO archive_policy_lookup(id,ws) SELECT id,ws FROM archive_policy WHERE id IN (\{ids});
)
}

///|
let ap_legacy_schema : String =
(
  $|
  $|  CREATE TABLE archive_policy_lookup_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,
  $|    complete INTEGER NOT NULL,cursor INTEGER,end_id INTEGER) WITHOUT ROWID;
  $|  INSERT INTO archive_policy_lookup_meta VALUES(1,\{ap_version},0,NULL,(SELECT MAX(id) FROM archive_policy));
  $|  CREATE TABLE archive_policy_lookup(id INTEGER PRIMARY KEY,ws TEXT);
  $|  -- id aliases rowid and is already the trailing key of this index.
  $|  CREATE INDEX archive_policy_lookup_ws ON archive_policy_lookup(ws);
  $|  CREATE TRIGGER archive_policy_lookup_insert AFTER INSERT ON archive_policy BEGIN \{ap_reconcile("NEW.id")} END;
  $|  CREATE TRIGGER archive_policy_lookup_update AFTER UPDATE OF id,ws ON archive_policy
  $|    WHEN OLD.id IS NOT NEW.id OR OLD.ws IS NOT NEW.ws BEGIN \{ap_reconcile("OLD.id,NEW.id")} END;
  $|  CREATE TRIGGER archive_policy_lookup_delete AFTER DELETE ON archive_policy BEGIN \{ap_reconcile("OLD.id")} END;
)

///|
/// Small and new stores a native index; a larger old one empty structures copied later (`installArchivePolicyIndex`).
fn install_archive_policy_index(db : @sql.Db) -> Unit raise {
  let native = () => exists(db, "index", "archive_policy_by_ws")
  if native() || has_legacy_archive_policy(db) {
    return
  }
  immediate(db, () => if !native() && !has_legacy_archive_policy(db) {
    if !some_row(db, "SELECT 1 FROM archive_policy LIMIT 1 OFFSET 63") {
      db.exec("CREATE INDEX IF NOT EXISTS archive_policy_by_ws ON archive_policy(ws)")
    } else {
      db.exec(ap_legacy_schema)
    }
  })
}
