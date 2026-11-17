// The per-chat lookups an older store prepares instead of indexing its whole history as it opens: people's messages
// by time (station/src/store/legacy-people-since.ts) and closed cards (legacy-closed-cards.ts).

///|
let pt_version : Int = 1

///|
fn has_native_people_since(db : @sql.Db) -> Bool raise {
  exists(db, "index", "entries_people_since")
}

///|
fn has_legacy_people_since(db : @sql.Db) -> Bool raise {
  if !exists(db, "table", "legacy_people_time_meta") {
    return false
  }
  let row = first_row(db, "SELECT version FROM legacy_people_time_meta WHERE id=1")
  if row is None || !is_num(row, "version", pt_version) {
    refuse("legacy people-time lookup has an unsupported version")
  }
  true
}

///|
fn pt_candidates(p : String) -> String {
(
  $|SELECT rowid AS id FROM entries WHERE thread=\{p}.thread AND n=\{p}.n
  $|  UNION SELECT rowid FROM entries INDEXED BY entries_ts WHERE \{p}.ts IS NOT NULL AND thread=\{p}.thread AND ts=\{p}.ts
  $|  UNION SELECT rowid FROM entries WHERE rowid=\{p}.rowid
)
}

///|
fn pt_remove(p : String) -> String {
(
  $|DELETE FROM legacy_people_time_rows WHERE thread=\{p}.thread AND n=\{p}.n;
  $|  DELETE FROM legacy_people_time_rows WHERE source_rowid=\{p}.rowid;
  $|  DELETE FROM legacy_people_time_rows WHERE \{p}.ts IS NOT NULL AND thread=\{p}.thread AND ts=\{p}.ts;
)
}

///|
fn pt_add(ids : String) -> String {
(
  $|INSERT INTO legacy_people_time_rows(source_rowid,thread,n,at,ts)
  $|  SELECT e.rowid,e.thread,e.n,e.at,e.ts FROM (\{ids}) p CROSS JOIN entries e ON e.rowid=p.id
  $|  WHERE e.kind='message' AND e.author_kind='person'
  $|    AND EXISTS (SELECT 1 FROM legacy_people_time_scopes s WHERE s.thread=e.thread)
  $|    AND NOT EXISTS (SELECT 1 FROM legacy_people_time_rows k WHERE k.source_rowid=e.rowid)
  $|    AND NOT EXISTS (SELECT 1 FROM legacy_people_time_rows k WHERE k.thread=e.thread AND k.n=e.n);
)
}

///|
let pt_changed : String =
(
  $|OLD.thread IS NOT NEW.thread OR OLD.n IS NOT NEW.n OR OLD.rowid IS NOT NEW.rowid
  $|  OR OLD.ts IS NOT NEW.ts OR OLD.at IS NOT NEW.at OR OLD.kind IS NOT NEW.kind OR OLD.author_kind IS NOT NEW.author_kind
)

///|
let legacy_people_time_schema : String =
(
  $|
  $|CREATE TABLE legacy_people_time_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL) WITHOUT ROWID;
  $|INSERT INTO legacy_people_time_meta VALUES(1,\{pt_version});
  $|CREATE TABLE legacy_people_time_scopes(thread INTEGER PRIMARY KEY,last_n INTEGER,end_n INTEGER,complete INTEGER NOT NULL) WITHOUT ROWID;
  $|CREATE TABLE legacy_people_time_rows(source_rowid INTEGER PRIMARY KEY,thread INTEGER NOT NULL,n INTEGER NOT NULL,at INTEGER NOT NULL,ts TEXT);
  $|CREATE UNIQUE INDEX legacy_people_time_by_entry ON legacy_people_time_rows(thread,n);
  $|CREATE INDEX legacy_people_time_by_at ON legacy_people_time_rows(thread,at);
  $|CREATE INDEX legacy_people_time_by_ts ON legacy_people_time_rows(thread,ts) WHERE ts IS NOT NULL;
  $|CREATE TRIGGER legacy_people_time_insert AFTER INSERT ON entries WHEN
  $|  EXISTS (SELECT 1 FROM legacy_people_time_scopes WHERE thread=NEW.thread)
  $|  OR EXISTS (SELECT 1 FROM legacy_people_time_rows WHERE source_rowid=NEW.rowid) BEGIN
  $|  \{pt_remove("NEW")}
  $|  \{pt_add(pt_candidates("NEW"))}
  $|END;
  $|CREATE TRIGGER legacy_people_time_update AFTER UPDATE ON entries WHEN (\{pt_changed}) AND (
  $|  EXISTS (SELECT 1 FROM legacy_people_time_scopes WHERE thread IN (OLD.thread,NEW.thread))
  $|  OR EXISTS (SELECT 1 FROM legacy_people_time_rows WHERE source_rowid=NEW.rowid)) BEGIN
  $|  \{pt_remove("OLD")}
  $|  \{pt_remove("NEW")}
  $|  \{pt_add(pt_candidates("OLD") + " UNION " + pt_candidates("NEW"))}
  $|END;
  $|CREATE TRIGGER legacy_people_time_delete AFTER DELETE ON entries WHEN
  $|  EXISTS (SELECT 1 FROM legacy_people_time_scopes WHERE thread=OLD.thread)
  $|  OR EXISTS (SELECT 1 FROM legacy_people_time_rows WHERE source_rowid=OLD.rowid) BEGIN
  $|  \{pt_remove("OLD")}
  $|  \{pt_add(pt_candidates("OLD"))}
  $|END;
  $|CREATE TRIGGER legacy_people_time_drop_thread AFTER DELETE ON threads
  $|WHEN NOT EXISTS (SELECT 1 FROM entries WHERE thread=OLD.id LIMIT 1) BEGIN
  $|  DELETE FROM legacy_people_time_scopes WHERE thread=OLD.id;
  $|END;
)

///|
/// A new or small store keeps the native index; a large old one prepares only requested chats.
fn install_people_since_index(db : @sql.Db) -> Unit raise {
  if has_native_people_since(db) || has_legacy_people_since(db) {
    return
  }
  immediate(db, () => if !has_native_people_since(db) && !has_legacy_people_since(db) {
    if !some_row(db, "SELECT 1 FROM entries LIMIT 1 OFFSET 63") {
      db.exec("CREATE INDEX IF NOT EXISTS entries_people_since ON entries (thread, at) WHERE author_kind = 'person' AND kind = 'message'")
    } else {
      db.exec(legacy_people_time_schema)
    }
  })
}

///|
let cc_version : Int = 1

///|
fn has_native_closed_cards(db : @sql.Db) -> Bool raise {
  exists(db, "index", "closed_cards_thread_at")
}

///|
fn has_legacy_closed_cards(db : @sql.Db) -> Bool raise {
  if !exists(db, "table", "legacy_closed_meta") {
    return false
  }
  let row = first_row(db, "SELECT version FROM legacy_closed_meta WHERE id=1")
  if row is None || !is_num(row, "version", cc_version) {
    refuse("legacy closed-card lookup has an unsupported version")
  }
  true
}

///|
fn cc_candidates(p : String) -> String {
(
  $|SELECT rowid AS id FROM closed_cards WHERE thread=\{p}.thread AND n=\{p}.n
  $|  UNION SELECT rowid FROM closed_cards WHERE rowid=\{p}.rowid
)
}

///|
fn cc_remove(p : String) -> String {
(
  $|DELETE FROM legacy_closed_cards WHERE thread=\{p}.thread AND n=\{p}.n;
  $|  DELETE FROM legacy_closed_cards WHERE source_rowid=\{p}.rowid;
)
}

///|
fn cc_add(ids : String) -> String {
(
  $|INSERT INTO legacy_closed_cards(thread,at,source_rowid,n)
  $|  SELECT c.thread,c.at,c.rowid,c.n FROM (\{ids}) p CROSS JOIN closed_cards c ON c.rowid=p.id
  $|  WHERE EXISTS (SELECT 1 FROM legacy_closed_scopes s WHERE s.thread=c.thread)
  $|    AND NOT EXISTS (SELECT 1 FROM legacy_closed_cards k WHERE k.thread=c.thread AND k.n=c.n);
)
}

///|
let cc_changed : String =
(
  $|OLD.thread IS NOT NEW.thread OR OLD.n IS NOT NEW.n OR OLD.at IS NOT NEW.at OR OLD.rowid IS NOT NEW.rowid
)

///|
let legacy_closed_schema : String =
(
  $|
  $|CREATE TABLE legacy_closed_meta (id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL) WITHOUT ROWID;
  $|INSERT INTO legacy_closed_meta VALUES(1,\{cc_version});
  $|CREATE TABLE legacy_closed_scopes (thread INTEGER PRIMARY KEY,last_n INTEGER,end_n INTEGER,complete INTEGER NOT NULL) WITHOUT ROWID;
  $|CREATE TABLE legacy_closed_cards (source_rowid INTEGER PRIMARY KEY,thread INTEGER NOT NULL,n INTEGER NOT NULL,at INTEGER NOT NULL);
  $|CREATE UNIQUE INDEX legacy_closed_by_entry ON legacy_closed_cards(thread,n);
  $|CREATE INDEX legacy_closed_by_time ON legacy_closed_cards(thread,at);
  $|CREATE TRIGGER legacy_closed_insert AFTER INSERT ON closed_cards BEGIN
  $|  \{cc_remove("NEW")}
  $|  \{cc_add(cc_candidates("NEW"))}
  $|END;
  $|CREATE TRIGGER legacy_closed_update AFTER UPDATE ON closed_cards WHEN \{cc_changed} BEGIN
  $|  \{cc_remove("OLD")}
  $|  \{cc_remove("NEW")}
  $|  \{cc_add(cc_candidates("OLD") + " UNION " + cc_candidates("NEW"))}
  $|END;
  $|CREATE TRIGGER legacy_closed_delete AFTER DELETE ON closed_cards BEGIN
  $|  \{cc_remove("OLD")}
  $|  \{cc_add(cc_candidates("OLD"))}
  $|END;
)

///|
let closed_drop_thread : String =
(
  $|CREATE TRIGGER legacy_closed_drop_thread AFTER DELETE ON threads
  $|  WHEN NOT EXISTS (SELECT 1 FROM closed_cards WHERE thread=OLD.id LIMIT 1) BEGIN
  $|    DELETE FROM legacy_closed_scopes WHERE thread=OLD.id;
  $|  END;
)

///|
/// Stores that already prepared this lookup need the cleanup trigger too, where its metadata is of this version.
fn needs_closed_cleanup(db : @sql.Db) -> Bool raise {
  if !exists(db, "table", "legacy_closed_meta") ||
    exists(db, "trigger", "legacy_closed_drop_thread") ||
    !exists(db, "table", "threads") ||
    !exists(db, "table", "legacy_closed_scopes") {
    return false
  }
  is_num(first_row(db, "SELECT version FROM legacy_closed_meta WHERE id=1"), "version", cc_version)
}

///|
/// The native index on small or upgraded stores, both choices checked again under the writer lock.
fn install_closed_cards_index(db : @sql.Db) -> Unit raise {
  if (has_native_closed_cards(db) || has_legacy_closed_cards(db)) && !needs_closed_cleanup(db) {
    return
  }
  immediate(db, () => {
    if !has_native_closed_cards(db) && !has_legacy_closed_cards(db) {
      if !some_row(db, "SELECT 1 FROM closed_cards LIMIT 1 OFFSET 63") {
        db.exec("CREATE INDEX IF NOT EXISTS closed_cards_thread_at ON closed_cards (thread, at)")
      } else {
        db.exec(legacy_closed_schema)
      }
    }
    if needs_closed_cleanup(db) {
      db.exec(closed_drop_thread)
    }
  })
}
