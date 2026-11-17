// A conservative index of the days in Comma's stored statistics, as the TypeScript station kept it
// (station/test/reference/comma-stats-age.ts, the same tables, triggers and statements): rebuilt in bounded batches,
// every writer, an older station's during a handover too, marking the rows it changed for reclassification.

///|
/// Dirty rows and rows whose day is not a string are always checked by the original predicate. A missing day or a
/// removed row cannot satisfy it. String days use the first ten UTF-16 code units: fromDay is always ten ASCII units.
const STRING : Int32 = 1

///|
const OMIT : Int32 = 2

///|
const OTHER : Int32 = 3

///|
const LARGE_STRING : Int32 = 4

///|
const LARGE_OMIT : Int32 = 5

///|
const BATCH_BYTES : Int32 = 262144

///|
const MIN_OMITTED : Int32 = 256

///|
const LARGE_BYTES : Int32 = 1024

///|
/// A column's integer (a rowid, a count): none where it is null.
fn int_of(v : Json?) -> Int64? {
  match v {
    Some(Number(n, repr~)) =>
      match repr {
        Some(text) =>
          Some(@string.parse_int64(text)) catch {
            _ => Some(n.to_int64())
          }
        None => Some(n.to_int64())
      }
    _ => None
  }
}

///|
fn int_or(v : Json?, fallback : Int64) -> Int64 {
  int_of(v).unwrap_or(fallback)
}

///|
fn jint(v : Int64) -> Json {
  Json::number(v.to_double(), repr=v.to_string())
}

///|
fn jint_opt(v : Int64?) -> Json {
  match v {
    Some(x) => jint(x)
    None => Json::null()
  }
}

///|
/// The compared ISO date contains only +, -, and digits. Code units outside that span are folded to one ASCII byte on
/// either side without changing their order relative to a date; padding is below every character in an ISO date.
fn day_key(day : Array[Int32]) -> String {
  let out = StringBuilder()
  for i in 0..<10 {
    let unit = if i < day.length() { day[i] } else { 0 }
    let c = if unit < 43 { 33 } else if unit > 57 { 126 } else { unit }
    out.write_char(c.unsafe_to_char())
  }
  out.to_string()
}

///|
fn classify(json : @jsjson.JValue?, large : Bool) -> (Int32, String) {
  match json {
    // (`row.day` of null throws: the original reader sees and reports it)
    None | Some(Null) => (OTHER, "")
    Some(Obj(_) as row) =>
      match row.get("day") {
        None => (if large { LARGE_OMIT } else { OMIT }, "")
        Some(Str(day)) =>
          (if large { LARGE_STRING } else { STRING }, day_key(day))
        Some(_) => (OTHER, "")
      }
    Some(_) => (if large { LARGE_OMIT } else { OMIT }, "")
  }
}

///|
fn schema_version(db : @sql.Db) -> Int64 raise {
  int_or(db.all("PRAGMA schema_version", [])[0].get("schema_version"), 0)
}

///|
/// Creates only empty structures; no old statistics are read here. The triggers are in the transaction of the cursor.
pub fn install_stats_age(db : @sql.Db) -> Unit raise {
  let installed = () => {
    db
    .all(
      "SELECT 1 AS one FROM sqlite_master WHERE type = 'table' AND name = 'comma_stats_age_progress'",
      [],
    )
    .length() >
    0
  }
  if installed() {
    return
  }
  db.exec("BEGIN IMMEDIATE")
  try {
    if !installed() {
      db.exec(
        (
          #|CREATE TABLE comma_stats_age (id INTEGER PRIMARY KEY, generation INTEGER NOT NULL, kind INTEGER NOT NULL, day TEXT NOT NULL);
          #|CREATE INDEX comma_stats_age_day ON comma_stats_age (generation, kind, day, id);
          #|CREATE TABLE comma_stats_age_progress (id INTEGER PRIMARY KEY CHECK (id = 1), cursor INTEGER, last INTEGER,
          #|  done INTEGER NOT NULL, generation INTEGER NOT NULL, schema_version INTEGER NOT NULL);
          #|INSERT INTO comma_stats_age_progress SELECT 1, NULL, MAX(rowid), MAX(rowid) IS NULL, 1, 0 FROM stats_index;
          #|
          #|-- An ignored conflicting insert still makes the existing row dirty; an implicit REPLACE can remove its old rowid
          #|-- without firing a DELETE trigger. Dirty orphan rows are removed by the batch reader.
          #|CREATE TRIGGER comma_stats_age_before_insert BEFORE INSERT ON stats_index BEGIN
          #|  UPDATE comma_stats_age SET generation = (SELECT generation FROM comma_stats_age_progress WHERE id = 1), kind = 0, day = '' WHERE id IN
          #|    (SELECT rowid FROM stats_index WHERE key = NEW.key OR rowid = NEW.rowid);
          #|END;
          #|CREATE TRIGGER comma_stats_age_insert AFTER INSERT ON stats_index BEGIN
          #|  INSERT INTO comma_stats_age (id, generation, kind, day)
          #|    VALUES (NEW.rowid, (SELECT generation FROM comma_stats_age_progress WHERE id = 1), 0, '')
          #|    ON CONFLICT (id) DO UPDATE SET generation = excluded.generation, kind = 0, day = '';
          #|END;
          #|CREATE TRIGGER comma_stats_age_before_update BEFORE UPDATE OF rowid, _rowid_, oid, key, json ON stats_index BEGIN
          #|  -- An ignored update leaves its old row in place; a REPLACE can implicitly remove another row without a
          #|  -- DELETE trigger. Mark both for repair instead of removing the old entry before the update succeeds.
          #|  UPDATE comma_stats_age SET generation = (SELECT generation FROM comma_stats_age_progress WHERE id = 1), kind = 0, day = '' WHERE id = OLD.rowid OR id IN
          #|    (SELECT rowid FROM stats_index WHERE key = NEW.key OR rowid = NEW.rowid);
          #|END;
          #|CREATE TRIGGER comma_stats_age_update AFTER UPDATE OF rowid, _rowid_, oid, key, json ON stats_index BEGIN
          #|  DELETE FROM comma_stats_age WHERE id = OLD.rowid AND OLD.rowid <> NEW.rowid;
          #|  INSERT INTO comma_stats_age (id, generation, kind, day)
          #|    VALUES (NEW.rowid, (SELECT generation FROM comma_stats_age_progress WHERE id = 1), 0, '')
          #|    ON CONFLICT (id) DO UPDATE SET generation = excluded.generation, kind = 0, day = '';
          #|END;
          #|CREATE TRIGGER comma_stats_age_restore AFTER UPDATE OF removed ON stats_index
          #|  WHEN OLD.removed <> 0 AND NEW.removed = 0 BEGIN
          #|  INSERT INTO comma_stats_age (id, generation, kind, day)
          #|    VALUES (NEW.rowid, (SELECT generation FROM comma_stats_age_progress WHERE id = 1), 0, '')
          #|    ON CONFLICT (id) DO UPDATE SET generation = excluded.generation, kind = 0, day = '';
          #|END;
          #|CREATE TRIGGER comma_stats_age_delete AFTER DELETE ON stats_index BEGIN
          #|  DELETE FROM comma_stats_age WHERE id = OLD.rowid;
          #|END;
        ),
      )
      ignore(
        db.run(
          "UPDATE comma_stats_age_progress SET schema_version = ? WHERE id = 1",
          [jint(schema_version(db))],
        ),
      )
    }
    db.exec("COMMIT")
  } catch {
    e => {
      db.exec("ROLLBACK") catch {
        _ => ()
      }
      raise e
    }
  }
}

///|
/// A JSON body as node:sqlite gave it to JSON.parse: text as it is, a blob as String(Uint8Array) says it.
fn body_text(v : Json?) -> (String, Int32) {
  match v {
    Some(String(s)) => (s, utf8_length(s))
    Some(Array(bytes)) => {
      let out = StringBuilder()
      for i, b in bytes {
        if i > 0 {
          out.write_char(',')
        }
        out.write_string(int_or(Some(b), 0).to_string())
      }
      (out.to_string(), bytes.length())
    }
    Some(Number(_, ..) as n) => (n.stringify(), n.stringify().length())
    _ => ("null", 4)
  }
}

///|
fn parsed(text : String) -> @jsjson.JValue? {
  Some(@jsjson.parse(text)) catch {
    _ => None
  }
}

///|
/// Classifies at most `limit` old or dirty rows and about BATCH_BYTES of JSON in one transaction, orphaned rows left by
/// REPLACE too. A single larger row still has to be read whole; no batch collects several such bodies.
/// (visited, done).
pub fn stats_age_step(db : @sql.Db, limit~ : Int32 = 64) -> (Int32, Bool) raise {
  if limit < 1 {
    raise Failure("statistics age batch must be positive")
  }
  db.exec("BEGIN IMMEDIATE")
  try {
    let progress = () => {
      db.all(
        "SELECT cursor, last, done, generation, schema_version FROM comma_stats_age_progress WHERE id = 1",
        [],
      )[0]
    }
    let mut state = progress()
    let schema = schema_version(db)
    if int_or(state.get("schema_version"), 0) != schema {
      // VACUUM can renumber stats_index rowids without firing triggers. An unrelated schema change is harmless but
      // indistinguishable here, so invalidate the old generation and rescan under the writer lock in bounded steps.
      ignore(
        db.run(
          (
            #|UPDATE comma_stats_age_progress SET cursor = NULL, last = (SELECT MAX(rowid) FROM stats_index),
            #|  done = NOT EXISTS (SELECT 1 FROM stats_index), generation = generation + 1, schema_version = ? WHERE id = 1
          ),
          [jint(schema)],
        ),
      )
      state = progress()
    }
    let generation = int_or(state.get("generation"), 0)
    let put =
      #|INSERT INTO comma_stats_age (id, generation, kind, day) VALUES (?, ?, ?, ?)
      #|  ON CONFLICT (id) DO UPDATE SET generation = excluded.generation, kind = excluded.kind, day = excluded.day
    let mut visited = 0
    let mut bytes = 0
    let add = (id : Int64) => {
      let row = db.all(
          "SELECT removed = 0 AS active, CASE WHEN removed = 0 THEN json ELSE NULL END AS json FROM stats_index WHERE rowid = ?",
          [jint(id)],
        )[0]
      if int_or(row.get("active"), 0) == 0L {
        ignore(
          db.run(put, [
            jint(id),
            jint(generation),
            Json::number(OMIT.to_double()),
            Json::string(""),
          ]),
        )
        return
      }
      let (text, size) = body_text(row.get("json"))
      bytes += size
      let (kind, day) = classify(parsed(text), size >= LARGE_BYTES)
      ignore(
        db.run(put, [
          jint(id),
          jint(generation),
          Json::number(kind.to_double()),
          Json::string(day),
        ]),
      )
    }
    if int_or(state.get("done"), 0) == 0L {
      let cursor = int_of(state.get("cursor"))
      let last = jint_opt(int_of(state.get("last")))
      let rows = match cursor {
        None =>
          db.all(
            "SELECT rowid AS id FROM stats_index WHERE rowid <= ? ORDER BY rowid LIMIT ?",
            [last, Json::number(limit.to_double())],
          )
        Some(c) =>
          db.all(
            "SELECT rowid AS id FROM stats_index WHERE rowid > ? AND rowid <= ? ORDER BY rowid LIMIT ?",
            [jint(c), last, Json::number(limit.to_double())],
          )
      }
      for row in rows {
        if visited > 0 && bytes >= BATCH_BYTES {
          break
        }
        add(int_or(row.get("id"), 0))
        visited += 1
      }
      let at = if visited > 0 {
        int_of(rows[visited - 1].get("id"))
      } else {
        cursor
      }
      ignore(
        db.run(
          "UPDATE comma_stats_age_progress SET cursor = ?, done = ? WHERE id = 1",
          [
            jint_opt(at),
            Json::number(
              if visited == rows.length() && rows.length() < limit {
                1.0
              } else {
                0.0
              },
            ),
          ],
        ),
      )
    } else {
      // Give stale generations part of every batch. A busy old writer can otherwise keep supplying dirty rows and
      // prevent the previous generation from ever being discarded after a VACUUM.
      let half = if limit / 2 < 1 { 1 } else { limit / 2 }
      let stale = db.all(
        (
          #|SELECT id FROM comma_stats_age INDEXED BY comma_stats_age_day
          #|  WHERE generation < ? ORDER BY generation, kind, day, id LIMIT ?
        ),
        [jint(generation), Json::number(half.to_double())],
      )
      for row in stale {
        ignore(
          db.run("DELETE FROM comma_stats_age WHERE id = ?", [
            jint(int_or(row.get("id"), 0)),
          ]),
        )
        visited += 1
      }
      let rows = db.all(
        (
          #|SELECT a.id, s.rowid AS present FROM comma_stats_age a INDEXED BY comma_stats_age_day
          #|  LEFT JOIN stats_index s ON s.rowid = a.id WHERE a.generation = ? AND a.kind = 0 ORDER BY a.day, a.id LIMIT ?
        ),
        [jint(generation), Json::number((limit - visited).to_double())],
      )
      for row in rows {
        if visited > 0 && bytes >= BATCH_BYTES {
          break
        }
        let id = int_or(row.get("id"), 0)
        if int_of(row.get("present")) is None {
          ignore(db.run("DELETE FROM comma_stats_age WHERE id = ?", [jint(id)]))
        } else {
          add(id)
        }
        visited += 1
      }
    }
    let done = stats_age_ready(db, Some(0))
    db.exec("COMMIT")
    (visited, done)
  } catch {
    e => {
      db.exec("ROLLBACK") catch {
        _ => ()
      }
      raise e
    }
  }
}

///|
/// Can a reader use the index, with at most `max_dirty` rows that still need the original predicate? None allows all
/// dirty rows.
pub fn stats_age_ready(db : @sql.Db, max_dirty : Int32?) -> Bool raise {
  let progress = db.all(
      "SELECT done, generation, schema_version FROM comma_stats_age_progress WHERE id = 1",
      [],
    )[0]
  let generation = int_or(progress.get("generation"), 0)
  if int_or(progress.get("done"), 0) != 1L ||
    int_or(progress.get("schema_version"), -1) != schema_version(db) {
    return false
  }
  if db
    .all(
      "SELECT 1 AS one FROM comma_stats_age INDEXED BY comma_stats_age_day WHERE generation < ? LIMIT 1",
      [jint(generation)],
    )
    .length() >
    0 {
    return false
  }
  match max_dirty {
    None => true
    Some(n) =>
      db
      .all(
        "SELECT 1 AS one FROM comma_stats_age INDEXED BY comma_stats_age_day WHERE generation = ? AND kind = 0 LIMIT 1 OFFSET ?",
        [jint(generation), Json::number(n.to_double())],
      )
      .length() ==
      0
  }
}

///|
/// A row a build may tombstone: its key's bytes and its JSON.
pub(all) struct Kept {
  key : Bytes
  json : Json?
}

///|
fn bytes_of(v : Json?) -> Bytes {
  match v {
    Some(Array(items)) =>
      Bytes::makei(items.length(), i => int_or(Some(items[i]), 0).to_byte())
    Some(String(s)) => @utf8.encode(s)
    _ => b""
  }
}

///|
fn kept_rows(rows : Array[Map[String, Json]]) -> Array[Kept] {
  rows.map(r => { key: bytes_of(r.get("key")), json: r.get("json"), })
}

///|
/// Select and order rowids before fetching the JSON bodies: sorting whole bodies can dominate a build when nearly all
/// statistics are recent. The day index still finds the candidates, and rowid order keeps tombstone revisions stable.
let stats_age_candidates_sql : String =
  #|SELECT s.rowid AS id, CAST(s.key AS BLOB) AS key, s.json AS json
  #|  FROM stats_index s WHERE s.rowid IN (
  #|  SELECT a.id FROM comma_stats_age a INDEXED BY comma_stats_age_day
  #|    WHERE a.generation = (SELECT generation FROM comma_stats_age_progress WHERE id = 1) AND a.kind IN (0, 3)
  #|  UNION ALL
  #|  SELECT a.id FROM comma_stats_age a INDEXED BY comma_stats_age_day
  #|    WHERE a.generation = (SELECT generation FROM comma_stats_age_progress WHERE id = 1) AND a.kind IN (1, 4) AND a.day >= ?
  #|) AND s.removed = 0 ORDER BY s.rowid

///|
/// The rows a build may tombstone of the days before `from_day`'s left out (the caller checks readiness in the same
/// transaction: a VACUUM or schema change makes the old rowids unusable).
pub fn stats_age_candidates(
  db : @sql.Db,
  from_day : Array[Int32],
) -> Array[Kept] raise {
  let day = Json::string(day_key(from_day))
  // With very little old history, the joins and sort can cost more than reading it. One large omitted body or 256
  // small ones make the index worthwhile. Both probes seek only into the day index and have a fixed result bound.
  let large = db.all(
    (
      #|SELECT 1 AS one FROM comma_stats_age INDEXED BY comma_stats_age_day WHERE generation = (SELECT generation FROM comma_stats_age_progress WHERE id = 1) AND kind = 5
      #|  UNION ALL SELECT 1 FROM comma_stats_age INDEXED BY comma_stats_age_day WHERE generation = (SELECT generation FROM comma_stats_age_progress WHERE id = 1) AND kind = 4 AND day < ? LIMIT 1
    ),
    [day],
  )
  let omitted = large.length() > 0 ||
    db
    .all(
      (
        #|SELECT 1 AS one FROM comma_stats_age INDEXED BY comma_stats_age_day WHERE generation = (SELECT generation FROM comma_stats_age_progress WHERE id = 1) AND kind = 2
        #|  UNION ALL SELECT 1 FROM comma_stats_age INDEXED BY comma_stats_age_day WHERE generation = (SELECT generation FROM comma_stats_age_progress WHERE id = 1) AND kind = 1 AND day < ? LIMIT 1 OFFSET ?
      ),
      [day, Json::number((MIN_OMITTED - 1).to_double())],
    )
    .length() >
    0
  if !omitted {
    return kept_rows(
      db.all(
        "SELECT CAST(key AS BLOB) AS key, json FROM stats_index WHERE removed = 0",
        [],
      ),
    )
  }
  kept_rows(db.all(stats_age_candidates_sql, [day]))
}
