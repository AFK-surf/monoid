// The lookups over entries an older large store prepares in bounded ranges instead of indexing them as it opens
// (station/src/store/legacy-edits-build.ts, legacy-said-build.ts, legacy-agent-build.ts, legacy-login-cards.ts): their
// tables and the writers that keep them, made empty here; the MoonBit builder (@legacy) fills them.

///|
let le_version : Int = 1

///|
/// Whether the older store's edit lookup is there, of this version (`hasLegacyEdits`).
pub fn has_legacy_edits(db : @sql.Db) -> Bool raise {
  if !exists(db, "table", "legacy_edit_meta") {
    return false
  }
  let m = first_row(db, "SELECT version,scanned,old_index FROM legacy_edit_meta WHERE id=1")
  if m is None ||
    !is_num(m, "version", le_version) ||
    !(is_num(m, "scanned", 0) || is_num(m, "scanned", 1)) ||
    !(is_num(m, "old_index", 0) || is_num(m, "old_index", 1)) {
    refuse("legacy edit lookup has an unsupported version")
  }
  true
}

///|
/// The view reads the prepared lookup: no native edit index, the lookup there.
pub fn uses_legacy_edits(db : @sql.Db) -> Bool raise {
  !exists(db, "index", "entries_edits") && has_legacy_edits(db)
}

///|
/// Whether the (thread, target) index older stations made is there and usable.
pub fn has_old_edit_index(db : @sql.Db) -> Bool raise {
  let columns = db.all(
    "SELECT name,coll FROM pragma_index_xinfo('entries_target') WHERE \"key\"=1 ORDER BY seqno",
    [],
  )
  let named = (i : Int, name : String) => columns[i].get("name") == Some(Json::string(name)) &&
    columns[i].get("coll") == Some(Json::string("BINARY"))
  if columns.length() != 2 || !named(0, "thread") || !named(1, "target") {
    return false
  }
  try {
    ignore(
      db.all("EXPLAIN QUERY PLAN SELECT MAX(n) FROM entries INDEXED BY entries_target WHERE thread=? AND target=?", [
        Json::number(0.0),
        Json::number(0.0),
      ]),
    )
    true
  } catch {
    _ => false
  }
}

///|
pub fn legacy_edits_use_old_index(db : @sql.Db) -> Bool raise {
  if !has_legacy_edits(db) {
    refuse("legacy edit lookup has not been installed")
  }
  is_num(first_row(db, "SELECT old_index FROM legacy_edit_meta WHERE id=1"), "old_index", 1)
}

///|
/// The latest edit of `target` in `thread` (SQL) by the prepared lookup (`legacyEditLatest`); `filter` a trusted SQL
/// predicate on entry alias x.
pub fn legacy_edit_latest(thread : String, target : String, filter : String, old_index : Bool) -> String {
  let eligible = if filter == "1" { "" } else { " AND (\{filter})" }
  let prepared_entry = if filter == "1" { "" } else { " CROSS JOIN entries x ON x.thread=s.thread AND x.n=s.n" }
  let witness = if old_index {
(
  $|witness AS MATERIALIZED (
  $|    SELECT x.n FROM entries x INDEXED BY entries_target WHERE x.thread=\{thread} AND x.target=\{target}\{eligible}
  $|      ORDER BY x.rowid DESC LIMIT 1
  $|  ), 
)
  } else {
    ""
  }
  let from_witness = if old_index { "witness w CROSS JOIN " } else { "" }
  let dirty_bound = if old_index { " AND t.n>=w.n" } else { "" }
  let prepared_bound = if old_index { "w.n" } else { "-9223372036854775808" }
  let witness_result = if old_index { "SELECT n FROM witness UNION ALL" } else { "" }
  let target_index = if old_index { " INDEXED BY entries_target" } else { "" }
(
  $|CASE WHEN (SELECT scanned FROM legacy_edit_meta WHERE id=1)=0 THEN
  $|    (SELECT x.n FROM entries x\{target_index} WHERE x.thread=\{thread} AND x.target=\{target}\{eligible}
  $|      ORDER BY x.n DESC LIMIT 1)
  $|  WHEN NOT EXISTS (SELECT 1 FROM legacy_edit_dirty LIMIT 1) THEN
  $|    (SELECT s.n FROM legacy_edit_build s\{prepared_entry}
  $|      WHERE s.thread=\{thread} AND s.target=\{target}\{eligible} ORDER BY s.n DESC LIMIT 1)
  $|  WHEN NOT EXISTS (SELECT 1 FROM legacy_edit_targets t WHERE t.thread=\{thread} AND t.target=\{target}) THEN
  $|    (SELECT s.n FROM legacy_edit_build s\{prepared_entry}
  $|      WHERE s.thread=\{thread} AND s.target=\{target}\{eligible}
  $|        AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  $|      ORDER BY s.n DESC LIMIT 1)
  $|  ELSE (WITH \{witness}dirty_latest AS MATERIALIZED (
  $|    SELECT x.n FROM \{from_witness}legacy_edit_meta m CROSS JOIN legacy_edit_targets t
  $|      CROSS JOIN entries x ON x.thread=t.thread AND x.n=t.n
  $|    WHERE m.id=1 AND m.scanned=1 AND t.thread=\{thread} AND t.target=\{target} AND x.target=t.target\{eligible}\{dirty_bound}
  $|    ORDER BY t.n DESC LIMIT 1
  $|  ) SELECT n FROM (
  $|    \{witness_result}
  $|    SELECT n FROM dirty_latest
  $|    UNION ALL
  $|    SELECT n FROM (SELECT s.n FROM \{from_witness}legacy_edit_meta m CROSS JOIN legacy_edit_build s\{prepared_entry}
  $|      WHERE m.id=1 AND m.scanned=1 AND s.thread=\{thread} AND s.target=\{target}\{eligible}
  $|        AND s.n>=COALESCE((SELECT n FROM dirty_latest),\{prepared_bound})
  $|        AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  $|      ORDER BY s.n DESC LIMIT 1)
  $|  ) ORDER BY n DESC LIMIT 1) END
)
}

///|
let le_conflicts : String =
(
  $|SELECT e.thread,e.n FROM (
  $|  SELECT rowid AS id FROM entries WHERE thread=NEW.thread AND n=NEW.n
  $|  UNION SELECT rowid FROM entries INDEXED BY entries_ts WHERE NEW.ts IS NOT NULL AND thread=NEW.thread AND ts=NEW.ts
  $|  UNION SELECT rowid FROM entries WHERE rowid=NEW.rowid
  $|) p CROSS JOIN entries e ON e.rowid=p.id WHERE e.target IS NOT NULL
)

///|
let le_new_key : String = "SELECT NEW.thread AS thread,NEW.n AS n WHERE NEW.target IS NOT NULL"

///|
let le_old_key : String = "SELECT OLD.thread AS thread,OLD.n AS n WHERE OLD.target IS NOT NULL"

///|
let le_proposed : String = "SELECT NEW.thread AS thread,NEW.target AS target,NEW.n AS n WHERE NEW.target IS NOT NULL"

///|
let le_displaces_edit : String =
(
  $|(EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.n=NEW.n AND e.target IS NOT NULL)
  $|  OR (NEW.ts IS NOT NULL AND EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.ts=NEW.ts AND e.target IS NOT NULL))
  $|  OR EXISTS (SELECT 1 FROM entries e WHERE e.rowid=NEW.rowid AND e.target IS NOT NULL))
)

///|
fn le_mark(keys : String, include_proposed : Bool) -> String {
  let proposed = if include_proposed { "UNION \{le_proposed}" } else { "" }
(
  $|INSERT INTO legacy_edit_dirty(thread,n,old_target)
  $|  SELECT k.thread,k.n,e.target FROM (\{keys}) k LEFT JOIN entries e ON e.thread=k.thread AND e.n=k.n
  $|  WHERE k.thread IS NOT NULL AND k.n IS NOT NULL
  $|    AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=k.thread AND d.n=k.n);
  $|  INSERT INTO legacy_edit_targets(thread,target,n)
  $|    SELECT t.thread,t.target,t.n FROM (
  $|      SELECT e.thread,e.target,e.n FROM (\{keys}) k JOIN entries e ON e.thread=k.thread AND e.n=k.n
  $|        WHERE e.target IS NOT NULL
  $|      \{proposed}
  $|    ) t WHERE t.thread IS NOT NULL AND t.n IS NOT NULL AND t.target IS NOT NULL
  $|      AND NOT EXISTS (SELECT 1 FROM legacy_edit_targets x WHERE x.thread=t.thread AND x.target=t.target AND x.n=t.n);
)
}

///|
let le_mark_new : String =
(
  $|INSERT INTO legacy_edit_dirty(thread,n,old_target)
  $|  SELECT NEW.thread,NEW.n,e.target FROM (SELECT 1) x LEFT JOIN entries e ON e.thread=NEW.thread AND e.n=NEW.n
  $|  WHERE NEW.thread IS NOT NULL AND NEW.n IS NOT NULL
  $|    AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=NEW.thread AND d.n=NEW.n);
  $|  INSERT INTO legacy_edit_targets(thread,target,n) SELECT NEW.thread,NEW.target,NEW.n
  $|  WHERE NEW.thread IS NOT NULL AND NEW.n IS NOT NULL AND NEW.target IS NOT NULL
  $|    AND NOT EXISTS (SELECT 1 FROM legacy_edit_targets x WHERE x.thread=NEW.thread AND x.target=NEW.target AND x.n=NEW.n);
)

///|
let le_changed : String =
(
  $|OLD.thread IS NOT NEW.thread OR OLD.n IS NOT NEW.n OR OLD.rowid IS NOT NEW.rowid
  $|  OR OLD.target IS NOT NEW.target OR OLD.ts IS NOT NEW.ts
)

///|
/// The edit lookup's tables and writers, empty (`installLegacyEdits`); whether it is there after.
fn install_legacy_edits(db : @sql.Db, prefer_native? : Bool = false) -> Bool raise {
  if has_legacy_edits(db) {
    return true
  }
  if !exists(db, "index", "entries_ts") {
    refuse("legacy edit preparation requires entries_ts")
  }
  immediate(db, () => if !has_legacy_edits(db) && !(prefer_native && exists(db, "index", "entries_edits")) {
    let old_index = if has_old_edit_index(db) { 1 } else { 0 }
    db.exec(
(
  $|
  $|      CREATE TABLE legacy_edit_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,scanned INTEGER NOT NULL,old_index INTEGER NOT NULL,
  $|        cursor_thread INTEGER,cursor_n INTEGER,end_thread INTEGER,end_n INTEGER) WITHOUT ROWID;
  $|      INSERT INTO legacy_edit_meta VALUES(1,\{le_version},0,\{old_index},NULL,NULL,
  $|        (SELECT thread FROM entries ORDER BY thread DESC,n DESC LIMIT 1),
  $|        (SELECT n FROM entries ORDER BY thread DESC,n DESC LIMIT 1));
  $|      CREATE TABLE legacy_edit_build(thread INTEGER NOT NULL,target INTEGER NOT NULL,n INTEGER NOT NULL,
  $|        PRIMARY KEY(thread,target,n)) WITHOUT ROWID;
  $|      CREATE TABLE legacy_edit_dirty(thread INTEGER NOT NULL,n INTEGER NOT NULL,old_target INTEGER,
  $|        PRIMARY KEY(thread,n)) WITHOUT ROWID;
  $|      CREATE TABLE legacy_edit_targets(thread INTEGER NOT NULL,target INTEGER NOT NULL,n INTEGER NOT NULL,
  $|        PRIMARY KEY(thread,target,n)) WITHOUT ROWID;
  $|      CREATE INDEX legacy_edit_targets_by_key ON legacy_edit_targets(thread,n,target);
  $|      CREATE TRIGGER legacy_edit_before_insert BEFORE INSERT ON entries WHEN NEW.target IS NOT NULL BEGIN \{le_mark_new} END;
  $|      CREATE TRIGGER legacy_edit_before_insert_conflict BEFORE INSERT ON entries WHEN \{le_displaces_edit}
  $|        BEGIN \{le_mark(le_conflicts, false)} END;
  $|      CREATE TRIGGER legacy_edit_before_update BEFORE UPDATE ON entries WHEN (\{le_changed}) AND
  $|        (OLD.target IS NOT NULL OR NEW.target IS NOT NULL OR \{le_displaces_edit})
  $|        BEGIN \{le_mark(le_old_key + " UNION " + le_new_key + " UNION " + le_conflicts, true)} END;
  $|      CREATE TRIGGER legacy_edit_before_delete BEFORE DELETE ON entries WHEN OLD.target IS NOT NULL BEGIN \{le_mark(le_old_key, false)} END;
  $|    
)
    )
  })
  has_legacy_edits(db)
}

///|
let ls_version : Int = 1

///|
/// Whether this database uses the older store's said lookup (`hasLegacySaid`).
pub fn has_legacy_said(db : @sql.Db) -> Bool raise {
  if !exists(db, "view", "legacy_said") {
    return false
  }
  if !exists(db, "table", "legacy_said_meta") {
    refuse("legacy said view has no metadata")
  }
  let m = first_row(db, "SELECT version,scanned FROM legacy_said_meta WHERE id=1")
  if m is None || !is_num(m, "version", ls_version) || !(is_num(m, "scanned", 0) || is_num(m, "scanned", 1)) {
    refuse("legacy said view has an unsupported version")
  }
  true
}

///|
/// The newest current changed message, then the prepared arm from it (`legacySaidLatest`); `except` a trigger's row.
pub fn legacy_said_latest(except? : String) -> String {
  let except_entry = match except {
    Some(e) => " AND e.n != \{e}"
    None => ""
  }
  let except_prepared = match except {
    Some(e) => " AND s.n != \{e}"
    None => ""
  }
(
  $|WITH dirty_latest AS MATERIALIZED (
  $|    SELECT e.n,e.author_kind,e.author FROM legacy_said_meta m CROSS JOIN legacy_said_dirty d
  $|      CROSS JOIN entries e ON e.thread=d.thread AND e.n=d.n
  $|    WHERE m.id=1 AND m.scanned=1 AND d.thread=?1 AND e.kind='message' AND e.letter IS NULL\{except_entry}
  $|    ORDER BY d.n DESC LIMIT 1
  $|  )
  $|  SELECT n,author_kind,author FROM dirty_latest
  $|  UNION ALL
  $|  SELECT n,author_kind,author FROM (
  $|    SELECT s.n,s.author_kind,s.author FROM legacy_said_meta m CROSS JOIN legacy_said_build s
  $|    WHERE m.id=1 AND m.scanned=1 AND s.thread=?1\{except_prepared}
  $|      AND s.n >= COALESCE((SELECT n FROM dirty_latest), -9223372036854775808)
  $|      AND NOT EXISTS (SELECT 1 FROM legacy_said_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  $|    ORDER BY s.n DESC LIMIT 1
  $|  )
  $|  UNION ALL
  $|  SELECT n,author_kind,author FROM (
  $|    SELECT e.n,e.author_kind,e.author FROM legacy_said_meta m CROSS JOIN entries e
  $|    WHERE m.id=1 AND m.scanned=0 AND e.thread=?1 AND e.kind='message' AND e.letter IS NULL\{except_entry}
  $|    ORDER BY e.n DESC LIMIT 1
  $|  )
  $|  ORDER BY n DESC LIMIT 1
)
}

///|
let ls_conflicts : String =
(
  $|SELECT e.thread,e.n FROM (
  $|  SELECT rowid AS id FROM entries WHERE thread=NEW.thread AND n=NEW.n
  $|  UNION SELECT rowid FROM entries INDEXED BY entries_ts WHERE NEW.ts IS NOT NULL AND thread=NEW.thread AND ts=NEW.ts
  $|  UNION SELECT rowid FROM entries WHERE rowid=NEW.rowid
  $|) p CROSS JOIN entries e ON e.rowid=p.id WHERE e.kind='message' AND e.letter IS NULL
)

///|
fn ls_mark(keys : String) -> String {
(
  $|INSERT INTO legacy_said_dirty(thread,n)
  $|  SELECT k.thread,k.n FROM (\{keys}) k WHERE NOT EXISTS
  $|    (SELECT 1 FROM legacy_said_dirty d WHERE d.thread=k.thread AND d.n=k.n);
)
}

///|
let ls_new_key : String = "SELECT NEW.thread AS thread,NEW.n AS n WHERE NEW.kind='message' AND NEW.letter IS NULL"

///|
let ls_old_key : String = "SELECT OLD.thread AS thread,OLD.n AS n WHERE OLD.kind='message' AND OLD.letter IS NULL"

///|
let ls_changed : String =
(
  $|OLD.thread IS NOT NEW.thread OR OLD.n IS NOT NEW.n OR OLD.rowid IS NOT NEW.rowid
  $|  OR OLD.kind IS NOT NEW.kind OR OLD.letter IS NOT NEW.letter OR OLD.author_kind IS NOT NEW.author_kind
  $|  OR OLD.author IS NOT NEW.author OR OLD.ts IS NOT NEW.ts
)

///|
/// The said lookup's tables, writers and view, empty (`installLegacySaid`); whether it is there after.
fn install_legacy_said(db : @sql.Db, prefer_native? : Bool = false) -> Bool raise {
  if exists(db, "table", "legacy_said_meta") {
    if !has_legacy_said(db) {
      refuse("legacy said metadata has no view")
    }
    return true
  }
  if !exists(db, "index", "entries_ts") {
    refuse("legacy said preparation requires entries_ts")
  }
  immediate(db, () => if !exists(db, "table", "legacy_said_meta") &&
    !(prefer_native && exists(db, "index", "entries_said")) {
    db.exec(
(
  $|
  $|      CREATE TABLE legacy_said_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,scanned INTEGER NOT NULL,
  $|        cursor_thread INTEGER,cursor_n INTEGER,end_thread INTEGER,end_n INTEGER) WITHOUT ROWID;
  $|      INSERT INTO legacy_said_meta VALUES(1,\{ls_version},0,NULL,NULL,
  $|        (SELECT thread FROM entries ORDER BY thread DESC,n DESC LIMIT 1),
  $|        (SELECT n FROM entries ORDER BY thread DESC,n DESC LIMIT 1));
  $|      CREATE TABLE legacy_said_build(thread INTEGER NOT NULL,n INTEGER NOT NULL,author_kind TEXT NOT NULL,author TEXT NOT NULL,
  $|        PRIMARY KEY(thread,n)) WITHOUT ROWID;
  $|      CREATE TABLE legacy_said_dirty(thread INTEGER NOT NULL,n INTEGER NOT NULL,PRIMARY KEY(thread,n)) WITHOUT ROWID;
  $|      CREATE TRIGGER legacy_said_before_insert BEFORE INSERT ON entries BEGIN \{ls_mark(ls_new_key + " UNION " + ls_conflicts)} END;
  $|      CREATE TRIGGER legacy_said_before_update BEFORE UPDATE ON entries
  $|        WHEN \{ls_changed} BEGIN \{ls_mark(ls_old_key + " UNION " + ls_new_key + " UNION " + ls_conflicts)} END;
  $|      CREATE TRIGGER legacy_said_before_delete BEFORE DELETE ON entries BEGIN \{ls_mark(ls_old_key)} END;
  $|      CREATE VIEW legacy_said AS
  $|        SELECT e.thread,e.n,e.author_kind,e.author FROM legacy_said_meta m CROSS JOIN entries e
  $|          WHERE m.id=1 AND m.scanned=0 AND e.kind='message' AND e.letter IS NULL
  $|        UNION ALL
  $|        SELECT s.thread,s.n,s.author_kind,s.author FROM legacy_said_meta m CROSS JOIN legacy_said_build s
  $|          WHERE m.id=1 AND m.scanned=1
  $|            AND NOT EXISTS (SELECT 1 FROM legacy_said_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  $|        UNION ALL
  $|        SELECT d.thread,d.n,e.author_kind,e.author FROM legacy_said_meta m CROSS JOIN legacy_said_dirty d
  $|          CROSS JOIN entries e ON e.thread=d.thread AND e.n=d.n
  $|          WHERE m.id=1 AND m.scanned=1 AND e.kind='message' AND e.letter IS NULL;
  $|    
)
    )
  })
  let installed = has_legacy_said(db)
  if !installed && exists(db, "table", "legacy_said_meta") {
    refuse("legacy said metadata has no view")
  }
  installed
}

///|
let la_version : Int = 1

///|
/// Whether the older store's agent-message time lookup is there (`hasLegacyAgent`).
pub fn has_legacy_agent(db : @sql.Db) -> Bool raise {
  if !exists(db, "table", "legacy_agent_meta") {
    return false
  }
  let m = first_row(db, "SELECT version,scanned FROM legacy_agent_meta WHERE id=1")
  if m is None || !is_num(m, "version", la_version) || !(is_num(m, "scanned", 0) || is_num(m, "scanned", 1)) {
    refuse("legacy agent lookup has an unsupported version")
  }
  true
}

///|
let la_conflicts : String =
(
  $|SELECT e.thread,e.n FROM (
  $|  SELECT rowid AS id FROM entries WHERE thread=NEW.thread AND n=NEW.n
  $|  UNION SELECT rowid FROM entries INDEXED BY entries_ts WHERE NEW.ts IS NOT NULL AND thread=NEW.thread AND ts=NEW.ts
  $|  UNION SELECT rowid FROM entries WHERE rowid=NEW.rowid
  $|) p CROSS JOIN entries e ON e.rowid=p.id WHERE e.kind='message' AND e.author_kind='agent'
)

///|
let la_new_key : String = "SELECT NEW.thread AS thread,NEW.n AS n WHERE NEW.kind='message' AND NEW.author_kind='agent'"

///|
let la_old_key : String = "SELECT OLD.thread AS thread,OLD.n AS n WHERE OLD.kind='message' AND OLD.author_kind='agent'"

///|
let la_new_agent : String = "NEW.kind='message' AND NEW.author_kind='agent'"

///|
let la_old_agent : String = "OLD.kind='message' AND OLD.author_kind='agent'"

///|
let la_displaces_agent : String =
(
  $|(EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.n=NEW.n
  $|    AND e.kind='message' AND e.author_kind='agent')
  $|  OR (NEW.ts IS NOT NULL AND EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.ts=NEW.ts
  $|    AND e.kind='message' AND e.author_kind='agent'))
  $|  OR EXISTS (SELECT 1 FROM entries e WHERE e.rowid=NEW.rowid AND e.kind='message' AND e.author_kind='agent'))
)

///|
let la_proposed_time : String = "SELECT NEW.thread AS thread,NEW.at AS at,NEW.n AS n WHERE NEW.kind='message' AND NEW.author_kind='agent'"

///|
fn la_mark(keys : String, proposed : Bool) -> String {
  let proposed = if proposed { "UNION \{la_proposed_time}" } else { "" }
(
  $|INSERT INTO legacy_agent_dirty(thread,n,old_at)
  $|  SELECT k.thread,k.n,e.at FROM (\{keys}) k LEFT JOIN entries e ON e.thread=k.thread AND e.n=k.n
  $|    AND e.kind='message' AND e.author_kind='agent'
  $|  WHERE NOT EXISTS (SELECT 1 FROM legacy_agent_dirty d WHERE d.thread=k.thread AND d.n=k.n);
  $|  INSERT INTO legacy_agent_times(thread,at,n)
  $|    SELECT t.thread,t.at,t.n FROM (
  $|      SELECT e.thread,e.at,e.n FROM (\{keys}) k JOIN entries e ON e.thread=k.thread AND e.n=k.n
  $|        WHERE e.kind='message' AND e.author_kind='agent'
  $|      \{proposed}
  $|    ) t WHERE NOT EXISTS (SELECT 1 FROM legacy_agent_times x WHERE x.thread=t.thread AND x.at=t.at AND x.n=t.n);
)
}

///|
let la_mark_new : String =
(
  $|INSERT INTO legacy_agent_dirty(thread,n,old_at)
  $|  SELECT NEW.thread,NEW.n,e.at FROM (SELECT 1) x LEFT JOIN entries e ON e.thread=NEW.thread AND e.n=NEW.n
  $|    AND e.kind='message' AND e.author_kind='agent'
  $|  WHERE NOT EXISTS (SELECT 1 FROM legacy_agent_dirty d WHERE d.thread=NEW.thread AND d.n=NEW.n);
  $|  INSERT INTO legacy_agent_times(thread,at,n) SELECT NEW.thread,NEW.at,NEW.n
  $|  WHERE NOT EXISTS (SELECT 1 FROM legacy_agent_times x WHERE x.thread=NEW.thread AND x.at=NEW.at AND x.n=NEW.n);
)

///|
let la_changed : String =
(
  $|OLD.thread IS NOT NEW.thread OR OLD.n IS NOT NEW.n OR OLD.rowid IS NOT NEW.rowid
  $|  OR OLD.kind IS NOT NEW.kind OR OLD.author_kind IS NOT NEW.author_kind OR OLD.at IS NOT NEW.at OR OLD.ts IS NOT NEW.ts
)

///|
/// The agent lookup's tables and writers, empty (`installLegacyAgent`); whether it is there after.
fn install_legacy_agent(db : @sql.Db, prefer_native? : Bool = false) -> Bool raise {
  if has_legacy_agent(db) {
    return true
  }
  if !exists(db, "index", "entries_ts") {
    refuse("legacy agent preparation requires entries_ts")
  }
  immediate(db, () => if !has_legacy_agent(db) && !(prefer_native && exists(db, "index", "entries_agent_at")) {
    db.exec(
(
  $|
  $|      CREATE TABLE legacy_agent_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,scanned INTEGER NOT NULL,
  $|        cursor_thread INTEGER,cursor_n INTEGER,end_thread INTEGER,end_n INTEGER) WITHOUT ROWID;
  $|      INSERT INTO legacy_agent_meta VALUES(1,\{la_version},0,NULL,NULL,
  $|        (SELECT thread FROM entries ORDER BY thread DESC,n DESC LIMIT 1),
  $|        (SELECT n FROM entries ORDER BY thread DESC,n DESC LIMIT 1));
  $|      CREATE TABLE legacy_agent_build(thread INTEGER NOT NULL,at INTEGER NOT NULL,n INTEGER NOT NULL,
  $|        PRIMARY KEY(thread,at,n)) WITHOUT ROWID;
  $|      CREATE TABLE legacy_agent_dirty(thread INTEGER NOT NULL,n INTEGER NOT NULL,old_at INTEGER,
  $|        PRIMARY KEY(thread,n)) WITHOUT ROWID;
  $|      CREATE TABLE legacy_agent_times(thread INTEGER NOT NULL,at INTEGER NOT NULL,n INTEGER NOT NULL,
  $|        PRIMARY KEY(thread,at,n)) WITHOUT ROWID;
  $|      CREATE INDEX legacy_agent_times_by_key ON legacy_agent_times(thread,n,at);
  $|      CREATE TRIGGER legacy_agent_before_insert BEFORE INSERT ON entries WHEN \{la_new_agent} BEGIN \{la_mark_new} END;
  $|      CREATE TRIGGER legacy_agent_before_insert_conflict BEFORE INSERT ON entries WHEN \{la_displaces_agent}
  $|        BEGIN \{la_mark(la_conflicts, false)} END;
  $|      CREATE TRIGGER legacy_agent_before_update BEFORE UPDATE ON entries WHEN (\{la_changed}) AND
  $|        ((\{la_old_agent}) OR (\{la_new_agent}) OR \{la_displaces_agent})
  $|        BEGIN \{la_mark(la_old_key + " UNION " + la_new_key + " UNION " + la_conflicts, true)} END;
  $|      CREATE TRIGGER legacy_agent_before_delete BEFORE DELETE ON entries WHEN \{la_old_agent} BEGIN \{la_mark(la_old_key, false)} END;
  $|    
)
    )
  })
  has_legacy_agent(db)
}

///|
let lc_version : Int = 1

///|
/// Whether the older store's login-card lookup is there (`hasLegacyLoginCards`).
pub fn has_legacy_login_cards(db : @sql.Db) -> Bool raise {
  if !exists(db, "table", "login_card_meta") {
    return false
  }
  let m = first_row(db, "SELECT version,scanned FROM login_card_meta WHERE id=1")
  if m is None || !is_num(m, "version", lc_version) || !(is_num(m, "scanned", 0) || is_num(m, "scanned", 1)) {
    refuse("legacy login-card lookup has an unsupported version")
  }
  true
}

///|
fn lc_insert_keys(ids : String) -> String {
(
  $|INSERT INTO login_card_keys(login,thread,n,entry_rowid,ts)
  $|  SELECT k.login,k.thread,k.n,k.entry_rowid,k.ts FROM (
  $|    WITH RECURSIVE targets AS (
  $|      SELECT e.thread,e.n,e.rowid AS entry_rowid,e.ts,lower(e.card) AS rest
  $|      FROM (\{ids}) p CROSS JOIN entries e ON e.rowid=p.id
  $|      WHERE e.kind='message' AND e.author_kind='agent' AND e.card LIKE '%"login"%'
  $|    ), fragments(thread,n,entry_rowid,ts,rest) AS (
  $|      SELECT thread,n,entry_rowid,ts,rest FROM targets
  $|      UNION ALL
  $|      SELECT thread,n,entry_rowid,ts,substr(rest,instr(rest,'"login":"')+9)
  $|      FROM fragments WHERE instr(rest,'"login":"')>0
  $|    ), tails AS (
  $|      SELECT thread,n,entry_rowid,ts,substr(rest,instr(rest,'"login":"')+9) AS tail
  $|      FROM fragments WHERE instr(rest,'"login":"')>0
  $|    ), tokens AS (
  $|      SELECT thread,n,entry_rowid,ts,substr(tail,1,instr(tail,'"')-1) AS login
  $|      FROM tails WHERE instr(tail,'"')>0
  $|    )
  $|    SELECT DISTINCT login,thread,n,entry_rowid,ts FROM tokens
  $|    WHERE length(login) BETWEEN 1 AND 40 AND login NOT GLOB '*[^0-9a-z]*'
  $|  ) k WHERE NOT EXISTS (SELECT 1 FROM login_card_keys x WHERE x.login=k.login AND x.thread=k.thread AND x.n=k.n);
)
}

///|
fn lc_ids_for(prefix : String) -> String {
(
  $|SELECT rowid AS id FROM entries WHERE thread=\{prefix}.thread AND n=\{prefix}.n
  $|  UNION SELECT rowid FROM entries WHERE rowid=\{prefix}.rowid
  $|  UNION SELECT rowid FROM entries WHERE \{prefix}.ts IS NOT NULL AND thread=\{prefix}.thread AND ts=\{prefix}.ts
)
}

///|
fn lc_candidates_for(prefix : String) -> String {
(
  $|(login_card_keys.thread=\{prefix}.thread AND login_card_keys.n=\{prefix}.n)
  $|  OR login_card_keys.entry_rowid=\{prefix}.rowid OR (\{prefix}.ts IS NOT NULL AND login_card_keys.thread=\{prefix}.thread AND login_card_keys.ts=\{prefix}.ts)
)
}

///|
fn lc_has_candidates(prefix : String) -> String {
(
  $|EXISTS(SELECT 1 FROM login_card_keys WHERE \{lc_candidates_for(prefix)})
)
}

///|
let lc_new_card : String =
(
  $|NEW.kind='message' AND NEW.author_kind='agent' AND NEW.card LIKE '%"login"%'
)

///|
fn lc_remove_stale(which : String) -> String {
(
  $|DELETE FROM login_card_keys WHERE (\{which}) AND NOT EXISTS (
  $|  SELECT 1 FROM entries e WHERE e.rowid=login_card_keys.entry_rowid AND e.thread=login_card_keys.thread
  $|    AND e.n=login_card_keys.n AND e.ts IS login_card_keys.ts AND e.kind='message' AND e.author_kind='agent'
  $|    AND e.card LIKE '%"login":"' || login_card_keys.login || '"%');
)
}

///|
let legacy_login_card_schema : String =
(
  $|
  $|CREATE TABLE login_card_keys(login TEXT NOT NULL,thread INTEGER NOT NULL,n INTEGER NOT NULL,entry_rowid INTEGER NOT NULL,ts TEXT,
  $|  PRIMARY KEY(login,thread,n)) WITHOUT ROWID;
  $|CREATE INDEX login_card_keys_by_entry ON login_card_keys(thread,n,login);
  $|CREATE INDEX login_card_keys_by_rowid ON login_card_keys(entry_rowid,login);
  $|CREATE INDEX login_card_keys_by_ts ON login_card_keys(thread,ts,login) WHERE ts IS NOT NULL;
  $|CREATE TRIGGER login_card_keys_insert AFTER INSERT ON entries WHEN (\{lc_new_card}) OR \{lc_has_candidates("NEW")} BEGIN
  $|  \{lc_remove_stale(lc_candidates_for("NEW"))}
  $|  \{lc_insert_keys(lc_ids_for("NEW"))}
  $|END;
  $|CREATE TRIGGER login_card_keys_update_same AFTER UPDATE ON entries WHEN OLD.thread IS NEW.thread AND OLD.n IS NEW.n
  $|  AND OLD.rowid IS NEW.rowid AND OLD.ts IS NEW.ts AND (OLD.kind IS NOT NEW.kind
  $|  OR OLD.author_kind IS NOT NEW.author_kind OR OLD.card IS NOT NEW.card) AND ((\{lc_new_card}) OR \{lc_has_candidates("NEW")}) BEGIN
  $|  \{lc_remove_stale("(login_card_keys.thread=NEW.thread AND login_card_keys.n=NEW.n)")}
  $|  \{lc_insert_keys("SELECT rowid AS id FROM entries WHERE thread=NEW.thread AND n=NEW.n")}
  $|END;
  $|CREATE TRIGGER login_card_keys_update_moved AFTER UPDATE ON entries WHEN (OLD.thread IS NOT NEW.thread OR OLD.n IS NOT NEW.n
  $|  OR OLD.rowid IS NOT NEW.rowid OR OLD.ts IS NOT NEW.ts) AND ((\{lc_new_card}) OR \{lc_has_candidates("OLD")} OR \{lc_has_candidates("NEW")}) BEGIN
  $|  \{lc_remove_stale(lc_candidates_for("OLD") + " OR " + lc_candidates_for("NEW"))}
  $|  \{lc_insert_keys(lc_ids_for("OLD") + " UNION " + lc_ids_for("NEW"))}
  $|END;
  $|CREATE TRIGGER login_card_keys_delete AFTER DELETE ON entries WHEN \{lc_has_candidates("OLD")} BEGIN
  $|  \{lc_remove_stale(lc_candidates_for("OLD"))}
  $|  \{lc_insert_keys(lc_ids_for("OLD"))}
  $|END;
)

///|
/// The login-card lookup's keys and writers, the last old login card's place found by the native index where there is
/// one (`installLegacyLoginCards`); whether it is there after.
fn install_legacy_login_cards(db : @sql.Db) -> Bool raise {
  if has_legacy_login_cards(db) {
    return true
  }
  immediate(db, () => {
    let indexed = exists(db, "index", "entries_login_cards")
    if !has_legacy_login_cards(db) {
      let from = if indexed {
(
  $|FROM entries INDEXED BY entries_login_cards WHERE card LIKE '%"login"%'
)
      } else {
        "FROM entries WHERE 1"
      }
      db.exec(legacy_login_card_schema)
      db.exec(
(
  $|CREATE TABLE login_card_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,scanned INTEGER NOT NULL,
  $|        end_thread INTEGER,end_n INTEGER,cursor_thread INTEGER,cursor_n INTEGER,offset INTEGER) WITHOUT ROWID;
  $|        INSERT INTO login_card_meta VALUES(1,\{lc_version},NOT EXISTS(SELECT 1 \{from} LIMIT 1),
  $|          (SELECT thread \{from} ORDER BY thread DESC,n DESC LIMIT 1),
  $|          (SELECT n \{from} ORDER BY thread DESC,n DESC LIMIT 1),NULL,NULL,NULL);
)
      )
    }
  })
  has_legacy_login_cards(db)
}
