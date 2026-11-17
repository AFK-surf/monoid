// A build of the two indexes of what the workspace's stations gave, as the TypeScript station made it
// (station/test/reference/comma-stats.ts CommaStats #applyBuild, #apply): the age index prepared a batch a turn, then
// both indexes written in one transaction. Node drives the turns (it knows whether the read is still valid, and waits
// out a database another process holds); a build's rows and its turns' count are kept here between them.

///|
/// A writer that keeps committing while the old rows are classified can keep dirtying them indefinitely. After several
/// such turns, the still-dirty rows are applied with the original predicate instead of never finishing the build.
const ACTIVE_REPAIR_TURNS : Int32 = 4

///|
pub struct Build {
  stats : Rows
  tasks : Rows
  unread : Array[Array[Int32]]
  from_day : Array[Int32]
  mut version : Int64?
  mut active_turns : Int32
}

///|
/// The rows of `stations` (what each station gave) from `from_day` on; `unread`, the stations that did not answer,
/// whose rows stay as they were.
pub fn Build::new(
  stations : @jsjson.JValue,
  unread : @jsjson.JValue,
  from_day : Array[Int32],
) -> Build raise {
  let stats = Rows::new()
  let tasks = Rows::new()
  guard stations is Arr(given) else {
    raise Failure("stations is not iterable")
  }
  for s in given {
    stats_rows_of(stats, s, from_day)
    task_rows_of(tasks, s)
  }
  let skipped = match unread {
    Arr(items) =>
      items.filter_map(i => if i is Str(s) { Some(s) } else { None })
    _ => []
  }
  { stats, tasks, unread: skipped, from_day, version: None, active_turns: 0, }
}

///|
/// `!skipped.has(row.station ?? "")`.
fn Build::read(self : Build, row : @jsjson.JValue) -> Bool raise {
  let station = match row {
    Null => raise Failure("Cannot read properties of null (reading 'station')")
    Obj(_) => row.get("station")
    _ => None
  }
  let s = match station {
    None | Some(Null) => []
    Some(Str(s)) => s
    Some(_) => return true
  }
  !self.unread.iter().any(u => equal_units(u, s))
}

///|
/// `row.day !== undefined && row.day >= fromDay`, as JavaScript compares what it is.
fn Build::recent(self : Build, row : @jsjson.JValue) -> Bool raise {
  let day = match row {
    Null => raise Failure("Cannot read properties of null (reading 'day')")
    Obj(_) => row.get("day")
    _ => None
  }
  match day {
    None => false
    Some(Str(d)) => compare_units(d, self.from_day) >= 0
    Some(Arr(_) as v) | Some(Obj(_) as v) =>
      compare_units(@jsjson.js_string(v), self.from_day) >= 0
    // (a number, a boolean or null against a date is NaN's comparison)
    Some(_) => false
  }
}

///|
/// The rows written where they changed, in one transaction: a usage row of these days no longer given is tombstoned,
/// and so is a chat no longer among them, but not one of a station not read this time. Where `indexed`, the age index
/// gives the rows that may be tombstoned, and the build is not written (None) if it is no longer ready in this
/// transaction with at most `dirty` rows to check (None: any). (Stats, tasks) changed.
pub fn Build::apply(
  self : Build,
  db : @sql.Db,
  indexed : Bool,
  dirty : Int32?,
) -> (Int32, Int32)? raise {
  // (the write taken first: begun deferred, its read then write was refused at once while the process beside it wrote)
  db.exec("BEGIN IMMEDIATE")
  try {
    // Recheck in this transaction's snapshot. If preparation is no longer usable, classify again without writing a
    // partial build; any dirty rows allowed here are included and checked by the original predicate.
    if indexed && !stats_age_ready(db, dirty) {
      db.exec("ROLLBACK")
      return None
    }
    let stats = write(
      db,
      "stats_index",
      self.stats,
      row => self.recent(row) && self.read(row),
      kept?=if indexed {
        Some(stats_age_candidates(db, self.from_day))
      } else {
        None
      },
    )
    let tasks = write(db, "task_index", self.tasks, row => self.read(row))
    db.exec("COMMIT")
    Some((stats, tasks))
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
/// One turn of a build: a batch of the age index prepared, and the build written once it is ready. Some(changed) once
/// written, None for another turn. A database another process holds raises (`@sql.busy`): Node waits and asks again.
pub fn Build::turn(self : Build, db : @sql.Db) -> (Int32, Int32)? raise {
  install_stats_age(db)
  let ready = stats_age_ready(db, Some(0)) || stats_age_step(db).1
  // Apply as soon as a batch has caught up. Yielding here would let a steady older writer dirty one row on every turn
  // and keep the build waiting even though each batch had finished all of its work.
  let mut dirty : Int32? = Some(0)
  if !ready && stats_age_ready(db, None) {
    let current = int_or(
      db.all("PRAGMA data_version", [])[0].get("data_version"),
      0,
    )
    self.active_turns = if self.version is Some(v) && v != current {
      self.active_turns + 1
    } else {
      0
    }
    self.version = Some(current)
    // Unchanged old rows still use the index; a sustained writer's remaining dirty rows are read as before.
    if self.active_turns >= ACTIVE_REPAIR_TURNS {
      dirty = None
    }
  } else if !ready {
    self.version = None
    self.active_turns = 0
  }
  if ready || dirty is None {
    self.apply(db, true, dirty)
  } else {
    None
  }
}
