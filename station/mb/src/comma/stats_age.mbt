// A conservative index of the days in Comma's stored statistics (station/src/comma/stats-age.ts). It is rebuilt in
// bounded batches, and every writer, including an older station during handover, marks changed rows for
// reclassification.
//
// Dirty rows and rows whose day is not a string are always checked by the original JavaScript predicate. A missing day
// or a removed row cannot satisfy it. String days use the first ten UTF-16 code units: fromDay is always ten ASCII units.

///|
const STRING : Int = 1

///|
const OMIT : Int = 2

///|
const OTHER : Int = 3

///|
const LARGE_STRING : Int = 4

///|
const LARGE_OMIT : Int = 5

///|
const BATCH_BYTES : Int = 262144

///|
const MIN_OMITTED : Int = 256

///|
const LARGE_BYTES : Int = 1024 // BATCH_BYTES / MIN_OMITTED

///|
/// The compared ISO date contains only +, -, and digits. Code units outside that span can be folded to one ASCII byte
/// on either side without changing their order relative to a date; padding is below every character in an ISO date.
pub fn day_key(day : String) -> String {
  let out = StringBuilder::new()
  for i in 0..<10 {
    let unit = if i < day.length() { day.unsafe_charcode_at(i) } else { 0 }
    let c = if unit < 43 { 33 } else if unit > 57 { 126 } else { unit }
    out.write_char(c.unsafe_to_char())
  }
  out.to_string()
}

///|
/// What a stored row's JSON says of its day: its kind and its key.
pub fn classify(json : String, large : Bool) -> (Int, String) {
  let row = try {
    Some(parse_json(json))
  } catch {
    _ => None
  }
  match row {
    // (null's .day is a TypeError, caught: the original reader must still see it)
    None | Some(Null) => (OTHER, "")
    Some(r) =>
      match prop(Some(r), "day") {
        None => (if large { LARGE_OMIT } else { OMIT }, "")
        Some(Str(u)) => (if large { LARGE_STRING } else { STRING }, day_key(u))
        Some(_) => (OTHER, "")
      }
  }
}

///|
fn sql_one(db : @sql.Db, sql : String, params : Array[Json]) -> Map[String, Json]? raise {
  let rows = db.all(sql, params)
  if rows.length() == 0 {
    None
  } else {
    Some(rows[0])
  }
}

///|
fn schema_version(db : @sql.Db) -> Double raise {
  match sql_one(db, "PRAGMA schema_version", []) {
    Some(row) => col_num(row, "schema_version").unwrap_or(0.0)
    None => 0.0
  }
}

///|
/// A row's number, null where it is none.
fn num_or_null(n : Double?) -> Json {
  match n {
    Some(v) => Json::number(v)
    None => Json::null()
  }
}

///|
/// Create only empty structures. No old statistics are read here. Triggers are in the same transaction as the cursor.
pub fn install_stats_age(db : @sql.Db) -> Unit raise {
  let installed = () => sql_one(
    db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'comma_stats_age_progress'", [],
  )
    is Some(_)
  if installed() {
    return
  }
  db.exec("BEGIN IMMEDIATE")
  try {
    if !installed() {
      db.exec(
        #|
        #|      CREATE TABLE comma_stats_age (id INTEGER PRIMARY KEY, generation INTEGER NOT NULL, kind INTEGER NOT NULL, day TEXT NOT NULL);
        #|      CREATE INDEX comma_stats_age_day ON comma_stats_age (generation, kind, day, id);
        #|      CREATE TABLE comma_stats_age_progress (id INTEGER PRIMARY KEY CHECK (id = 1), cursor INTEGER, last INTEGER,
        #|        done INTEGER NOT NULL, generation INTEGER NOT NULL, schema_version INTEGER NOT NULL);
        #|      INSERT INTO comma_stats_age_progress SELECT 1, NULL, MAX(rowid), MAX(rowid) IS NULL, 1, 0 FROM stats_index;
        #|
        #|      -- An ignored conflicting insert still makes the existing row dirty; an implicit REPLACE can remove its old rowid
        #|      -- without firing a DELETE trigger. Dirty orphan rows are removed by the batch reader.
        #|      CREATE TRIGGER comma_stats_age_before_insert BEFORE INSERT ON stats_index BEGIN
        #|        UPDATE comma_stats_age SET generation = (SELECT generation FROM comma_stats_age_progress WHERE id = 1), kind = 0, day = '' WHERE id IN
        #|          (SELECT rowid FROM stats_index WHERE key = NEW.key OR rowid = NEW.rowid);
        #|      END;
        #|      CREATE TRIGGER comma_stats_age_insert AFTER INSERT ON stats_index BEGIN
        #|        INSERT INTO comma_stats_age (id, generation, kind, day)
        #|          VALUES (NEW.rowid, (SELECT generation FROM comma_stats_age_progress WHERE id = 1), 0, '')
        #|          ON CONFLICT (id) DO UPDATE SET generation = excluded.generation, kind = 0, day = '';
        #|      END;
        #|      CREATE TRIGGER comma_stats_age_before_update BEFORE UPDATE OF rowid, _rowid_, oid, key, json ON stats_index BEGIN
        #|        -- An ignored update leaves its old row in place; a REPLACE can implicitly remove another row without a
        #|        -- DELETE trigger. Mark both for repair instead of removing the old entry before the update succeeds.
        #|        UPDATE comma_stats_age SET generation = (SELECT generation FROM comma_stats_age_progress WHERE id = 1), kind = 0, day = '' WHERE id = OLD.rowid OR id IN
        #|          (SELECT rowid FROM stats_index WHERE key = NEW.key OR rowid = NEW.rowid);
        #|      END;
        #|      CREATE TRIGGER comma_stats_age_update AFTER UPDATE OF rowid, _rowid_, oid, key, json ON stats_index BEGIN
        #|        DELETE FROM comma_stats_age WHERE id = OLD.rowid AND OLD.rowid <> NEW.rowid;
        #|        INSERT INTO comma_stats_age (id, generation, kind, day)
        #|          VALUES (NEW.rowid, (SELECT generation FROM comma_stats_age_progress WHERE id = 1), 0, '')
        #|          ON CONFLICT (id) DO UPDATE SET generation = excluded.generation, kind = 0, day = '';
        #|      END;
        #|      CREATE TRIGGER comma_stats_age_restore AFTER UPDATE OF removed ON stats_index
        #|        WHEN OLD.removed <> 0 AND NEW.removed = 0 BEGIN
        #|        INSERT INTO comma_stats_age (id, generation, kind, day)
        #|          VALUES (NEW.rowid, (SELECT generation FROM comma_stats_age_progress WHERE id = 1), 0, '')
        #|          ON CONFLICT (id) DO UPDATE SET generation = excluded.generation, kind = 0, day = '';
        #|      END;
        #|      CREATE TRIGGER comma_stats_age_delete AFTER DELETE ON stats_index BEGIN
        #|        DELETE FROM comma_stats_age WHERE id = OLD.rowid;
        #|      END;
        #|
        ,
      )
      let schema = schema_version(db)
      db.run("UPDATE comma_stats_age_progress SET schema_version = ? WHERE id = 1", [Json::number(schema)])
      |> ignore
    }
    db.exec("COMMIT")
  } catch {
    e => {
      db.exec("ROLLBACK")
      raise e
    }
  }
}

///|
priv struct Progress {
  cursor : Double?
  last : Double?
  done : Double
  generation : Double
  schema_version : Double
}

///|
fn read_progress(db : @sql.Db) -> Progress raise {
  match
    sql_one(
      db, "SELECT cursor, last, done, generation, schema_version FROM comma_stats_age_progress WHERE id = 1", [],
    ) {
    Some(row) =>
      {
        cursor: col_num(row, "cursor"),
        last: col_num(row, "last"),
        done: col_num(row, "done").unwrap_or(0.0),
        generation: col_num(row, "generation").unwrap_or(0.0),
        schema_version: col_num(row, "schema_version").unwrap_or(0.0),
      }
    None => raise fail_("Cannot read properties of undefined (reading 'schema_version')")
  }
}

///|
/// Classify at most limit old or dirty rows and about BATCH_BYTES of JSON in one transaction, including orphaned rows
/// left by REPLACE. A single larger row still has to be read whole; no batch collects several such bodies.
pub fn stats_age_step(db : @sql.Db, limit? : Int = 64) -> (Int, Bool) raise {
  if limit < 1 {
    raise Thrown("RangeError", "statistics age batch must be positive")
  }
  db.exec("BEGIN IMMEDIATE")
  try {
    let mut state = read_progress(db)
    let schema = schema_version(db)
    if state.schema_version != schema {
      // VACUUM can renumber stats_index rowids without firing triggers. An unrelated schema change is harmless but
      // indistinguishable here, so invalidate the old generation and rescan under the writer lock in bounded steps.
      db.run(
        (
          #|UPDATE comma_stats_age_progress SET cursor = NULL, last = (SELECT MAX(rowid) FROM stats_index),
          #|        done = NOT EXISTS (SELECT 1 FROM stats_index), generation = generation + 1, schema_version = ? WHERE id = 1
        ),
        [Json::number(schema)],
      )
      |> ignore
      state = read_progress(db)
    }
    let put =
      #|INSERT INTO comma_stats_age (id, generation, kind, day) VALUES (?, ?, ?, ?)
      #|      ON CONFLICT (id) DO UPDATE SET generation = excluded.generation, kind = excluded.kind, day = excluded.day
    let mut visited = 0
    let mut bytes = 0
    let body = "SELECT removed = 0 AS active, CASE WHEN removed = 0 THEN json ELSE NULL END AS json FROM stats_index WHERE rowid = ?"
    let generation = state.generation
    let add = (id : Double) => {
      let row = match sql_one(db, body, [Json::number(id)]) {
        Some(r) => r
        None => raise fail_("Cannot read properties of undefined (reading 'active')")
      }
      if col_num(row, "active") == Some(0.0) {
        db.run(put, [Json::number(id), Json::number(generation), Json::number(OMIT.to_double()), Json::string("")])
        |> ignore
        return
      }
      let size = match row.get("json") {
        Some(Array(items)) => items.length()
        _ => byte_length(col_json_text(row, "json"))
      }
      bytes += size
      let (kind, day) = classify(col_json_text(row, "json"), size >= LARGE_BYTES)
      db.run(put, [Json::number(id), Json::number(generation), Json::number(kind.to_double()), bind_text(day)])
      |> ignore
    }
    if state.done == 0.0 {
      let rows = match state.cursor {
        None =>
          db.all("SELECT rowid AS id FROM stats_index WHERE rowid <= ? ORDER BY rowid LIMIT ?", [
            num_or_null(state.last),
            Json::number(limit.to_double()),
          ])
        Some(c) =>
          db.all("SELECT rowid AS id FROM stats_index WHERE rowid > ? AND rowid <= ? ORDER BY rowid LIMIT ?", [
            Json::number(c),
            num_or_null(state.last),
            Json::number(limit.to_double()),
          ])
      }
      for row in rows {
        if visited > 0 && bytes >= BATCH_BYTES {
          break
        }
        add(col_num(row, "id").unwrap_or(0.0))
        visited += 1
      }
      let cursor = if visited > 0 { col_num(rows[visited - 1], "id") } else { state.cursor }
      db.run("UPDATE comma_stats_age_progress SET cursor = ?, done = ? WHERE id = 1", [
        num_or_null(cursor),
        Json::number(if visited == rows.length() && rows.length() < limit { 1.0 } else { 0.0 }),
      ])
      |> ignore
    } else {
      let remove = "DELETE FROM comma_stats_age WHERE id = ?"
      // Give stale generations part of every batch. A busy old writer can otherwise keep supplying dirty rows and
      // prevent the previous generation from ever being discarded after a VACUUM.
      let stale =
        #|SELECT id FROM comma_stats_age INDEXED BY comma_stats_age_day
        #|        WHERE generation < ? ORDER BY generation, kind, day, id LIMIT ?
      let half = if limit / 2 < 1 { 1 } else { limit / 2 }
      for row in db.all(stale, [Json::number(generation), Json::number(half.to_double())]) {
        db.run(remove, [Json::number(col_num(row, "id").unwrap_or(0.0))]) |> ignore
        visited += 1
      }
      let dirty =
        #|SELECT a.id, s.rowid AS present FROM comma_stats_age a INDEXED BY comma_stats_age_day
        #|        LEFT JOIN stats_index s ON s.rowid = a.id WHERE a.generation = ? AND a.kind = 0 ORDER BY a.day, a.id LIMIT ?
      let rows = db.all(dirty, [Json::number(generation), Json::number((limit - visited).to_double())])
      for row in rows {
        if visited > 0 && bytes >= BATCH_BYTES {
          break
        }
        let id = col_num(row, "id").unwrap_or(0.0)
        if col_num(row, "present") is None {
          db.run(remove, [Json::number(id)]) |> ignore
        } else {
          add(id)
        }
        visited += 1
      }
    }
    let done = stats_age_ready(db, max_dirty=Some(0))
    db.exec("COMMIT")
    (visited, done)
  } catch {
    e => {
      db.exec("ROLLBACK")
      raise e
    }
  }
}

///|
/// Can a reader use the index, with at most max_dirty rows that still need the original predicate? None allows all
/// dirty rows.
pub fn stats_age_ready(db : @sql.Db, max_dirty? : Int? = Some(64)) -> Bool raise {
  let progress = match
    sql_one(db, "SELECT done, generation, schema_version FROM comma_stats_age_progress WHERE id = 1", []) {
    Some(row) => row
    None => raise fail_("Cannot read properties of undefined (reading 'done')")
  }
  let schema = schema_version(db)
  if col_num(progress, "done") != Some(1.0) || col_num(progress, "schema_version") != Some(schema) {
    return false
  }
  let generation = Json::number(col_num(progress, "generation").unwrap_or(0.0))
  if sql_one(
      db, "SELECT 1 FROM comma_stats_age INDEXED BY comma_stats_age_day WHERE generation < ? LIMIT 1", [generation],
    )
    is Some(_) {
    return false
  }
  match max_dirty {
    None => true
    Some(m) =>
      sql_one(
        db, "SELECT 1 FROM comma_stats_age INDEXED BY comma_stats_age_day WHERE generation = ? AND kind = 0 LIMIT 1 OFFSET ?",
        [generation, Json::number(m.to_double())],
      )
      is None
  }
}

///|
/// Select and order rowids before fetching the JSON bodies. Sorting whole bodies can dominate a build when nearly all
/// statistics are recent. The day index still finds the candidates, and rowid order keeps tombstone revisions stable.
pub let stats_age_candidates_sql : String =
  #|SELECT s.rowid AS id, CAST(s.key AS BLOB) AS key, s.json AS json
  #|  FROM stats_index s WHERE s.rowid IN (
  #|  SELECT a.id FROM comma_stats_age a INDEXED BY comma_stats_age_day
  #|    WHERE a.generation = (SELECT generation FROM comma_stats_age_progress WHERE id = 1) AND a.kind IN (0, 3)
  #|  UNION ALL
  #|  SELECT a.id FROM comma_stats_age a INDEXED BY comma_stats_age_day
  #|    WHERE a.generation = (SELECT generation FROM comma_stats_age_progress WHERE id = 1) AND a.kind IN (1, 4) AND a.day >= ?
  #|) AND s.removed = 0 ORDER BY s.rowid

///|
/// A row an index keeps, as a build compares it: its key's bytes and its JSON.
pub(all) struct Kept {
  key : Bytes
  json : String
}

///|
fn kept_of(row : Map[String, Json]) -> Kept {
  { key: col_bytes(row, "key").unwrap_or(b""), json: col_json_text(row, "json") }
}

///|
/// The caller checks readiness in the same transaction: a VACUUM or schema change makes the old rowids unusable.
pub fn stats_age_candidates(db : @sql.Db, from_day : String) -> Array[Kept] raise {
  let day = bind_text(day_key(from_day))
  let generation = "(SELECT generation FROM comma_stats_age_progress WHERE id = 1)"
  // With very little old history, the joins and sort can cost more than reading it. One large omitted body or 256
  // small ones make the index worthwhile. Both probes seek only into the day index and have a fixed result bound.
  let large = sql_one(
    db,
    "SELECT 1 FROM comma_stats_age INDEXED BY comma_stats_age_day WHERE generation = \{generation} AND kind = 5\n    UNION ALL SELECT 1 FROM comma_stats_age INDEXED BY comma_stats_age_day WHERE generation = \{generation} AND kind = 4 AND day < ? LIMIT 1",
    [day],
  )
  let omitted = match large {
    Some(r) => Some(r)
    None =>
      sql_one(
        db,
        "SELECT 1 FROM comma_stats_age INDEXED BY comma_stats_age_day WHERE generation = \{generation} AND kind = 2\n    UNION ALL SELECT 1 FROM comma_stats_age INDEXED BY comma_stats_age_day WHERE generation = \{generation} AND kind = 1 AND day < ? LIMIT 1 OFFSET ?",
        [day, Json::number((MIN_OMITTED - 1).to_double())],
      )
  }
  if omitted is None {
    return db.all("SELECT CAST(key AS BLOB) AS key, json FROM stats_index WHERE removed = 0", []).map(kept_of)
  }
  db.all(stats_age_candidates_sql, [day]).map(kept_of)
}
