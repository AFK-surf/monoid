// The usage counter's reads (station/src/usage/counter.ts `UsageCounter`'s `#read`), here for the MoonBit program
// (reader `--builder usage-counter`): Node asks a read (its sessions, or those that ran since the last sweep), with
// where the transcripts are (the data directory, the profiles' homes) and the transcripts' places Node knows of
// (read/transcript.ts `TranscriptLocationHints`); this finds their transcripts, reads each from where the last read
// stopped and records its calls in the station's database, and answers how many were new, of which sessions and from
// when, which Node tells (store `usageChanged`). Where each transcript was read to is kept here between reads, as
// Node kept it, and read again from the database by a program started again.

///|
/// counter.ts SKEW_MS.
let skew_ms : Double = 5000.0

///|
/// counter.ts MARGIN_MS.
let margin_ms : Double = 60000.0

///|
/// counter.ts WRITE_BATCH.
let write_batch : Int = 64

///|
/// counter.ts `CountedFile`: a transcript's saved position, its boundary and the bytes before it.
priv struct Counted {
  session : String?
  offset : Double
  model : String?
  speed : String?
  cutoff : Double?
  anchor : String?
  path : String
}

///|
/// A session as the counter takes it (store.ts `SessionRow`).
priv struct Session {
  key : String
  runtime : String
  cwd : String?
  workspace : String
  runtime_session_id : String?
  running : Bool
  created_at : Double
}

///|
/// A transcript's runtime session (store.ts `runtimeSessionSources`).
priv struct Source {
  id : String
  runtime : String
}

///|
pub struct Counter {
  priv host : @host.Host
  priv db : @sql.Db
  priv sep : String
  priv finder : @locate.Finder
  priv schema : Schema
  /// Positions of transcripts this counter has needed, read from the store by path and kept as it writes them.
  priv mut files : Map[String, Counted]?
  /// Codex's path for a runtime session, by session.
  priv codex_paths : Map[String, Map[String, String]]
  /// What the read under way found and has not written yet, with each one's session and position.
  priv mut pending : Array[(Write, String, Counted)]
  priv mut pending_calls : Int
  /// The sessions the read under way recorded new calls of (in order), and when the earliest was made.
  priv counted : Array[String]
  priv mut from : Double
  /// The read under way times again the calls from then on (ms) of what each transcript it reads had been read of
  /// before its calls were timed (`timed_again`); none, it times only what it reads anew.
  priv mut time_from : Double?
}

///|
pub fn Counter::new(host : @host.Host, db : @sql.Db, sep : String) -> Counter {
  {
    host,
    db,
    sep,
    finder: @locate.Finder::new(host, sep),
    schema: { compact: false, incremental: None },
    files: None,
    codex_paths: Map([]),
    pending: [],
    pending_calls: 0,
    counted: [],
    from: @double.infinity,
    time_from: None,
  }
}

///|
fn Counter::join(self : Counter, parts : Array[String]) -> String {
  @nodepath.join(self.sep, parts)
}

///|
fn session_of(r : Map[String, Json]) -> Session {
  {
    key: text_of(field(r, "key")).unwrap_or(""),
    runtime: text_of(field(r, "runtime")).unwrap_or(""),
    cwd: text_of(field(r, "cwd")),
    workspace: text_of(field(r, "workspace")).unwrap_or(""),
    runtime_session_id: text_of(field(r, "runtime_session_id")),
    running: num_of(field(r, "running")) == Some(1.0),
    created_at: num_of(field(r, "created_at")).unwrap_or(0.0),
  }
}

///|
/// store.ts `runtimeSessionSources`: each recorded transcript's runtime, in conversation order, its current last.
fn Counter::sources(self : Counter, s : Session) -> Array[Source] raise {
  let rows = self.db.all(
    (
      #|SELECT r.id, COALESCE(r.runtime, s.original_runtime, s.runtime) AS runtime, r.profile
      #|      FROM sessions s CROSS JOIN runtime_sessions r ON r.session_key = s.key WHERE s.key = ? ORDER BY r.at, r.rowid
    ),
    [Json::string(s.key)],
  )
  let sources = rows.map(r => ({ id: text_of(field(r, "id")).unwrap_or(""), runtime: text_of(field(r, "runtime")).unwrap_or("") } : Source))
  guard s.runtime_session_id is Some(current) else { return sources }
  let entry = match sources.search_by(x => x.id == current) {
    Some(i) => sources[i]
    None => { id: current, runtime: s.runtime }
  }
  let out = sources.filter(x => x.id != current)
  out.push(entry)
  out
}

///|
/// Where a runtime's transcripts are: the shared place, then each profile's home's (counter.ts `ways`).
fn Counter::ways(self : Counter, data : String, homes : Array[String], runtime : String) -> Array[String] {
  let out = [self.join([data, "transcripts", runtime])]
  for home in homes {
    out.push(self.join([home, @locate.transcript_dir(runtime)]))
  }
  out
}

///|
/// counter.ts `readBefore`'s `position`: a transcript's saved position by its path.
fn Counter::position(self : Counter, known : Map[String, Counted], name : String) -> Counted? raise {
  if known.get(name) is Some(c) {
    return Some(c)
  }
  let file = usage_file(self.db, name)
  let counter = counter_file(self.db, name)
  if file is None && counter is None {
    return None
  }
  let f = file.unwrap_or({ session: None, offset: 0.0, model: None, speed: None })
  let saved : Counted = {
    session: f.session,
    offset: f.offset,
    model: f.model,
    speed: f.speed,
    cutoff: counter.map(c => c.cutoff),
    anchor: match counter {
      Some(c) => c.anchor
      None => None
    },
    path: name,
  }
  known[name] = saved
  Some(saved)
}

///|
/// counter.ts `readBefore`: how far a transcript was read, however it was reached then (one read through a home's own
/// directory before is reached through the shared place once that is a link there).
fn Counter::read_before(
  self : Counter,
  known : Map[String, Counted],
  data : String,
  homes : Array[String],
  path : String,
  runtime : String,
) -> Counted? raise {
  if self.position(known, path) is Some(had) {
    return Some(had)
  }
  let roots = self.ways(data, homes, runtime)
  guard roots.search_by(r => path.has_prefix(r + self.sep)) is Some(i) else { return None }
  let rest = path.view(start_offset=roots[i].length()).to_owned()
  for r in roots {
    if self.position(known, r + rest) is Some(was) {
      return Some(was)
    }
  }
  None
}

///|
/// counter.ts `#flush`: what the read gathered written in one transaction; how many calls were new. Not written (a
/// failure): the positions kept here are let go, so that the next read goes on from the database's.
fn Counter::flush(self : Counter) -> Int raise {
  let pending = self.pending
  self.pending = []
  self.pending_calls = 0
  let recorded = record_all(self.db, self.schema, pending.map(p => p.0)) catch {
    e => {
      self.files = None
      raise e
    }
  }
  let mut added = 0
  for i, p in pending {
    if self.files is Some(files) {
      files[p.0.path] = p.2
    }
    if p.0.changed.val != @double.infinity {
      if !self.counted.contains(p.1) {
        self.counted.push(p.1)
      }
      if p.0.changed.val < self.from {
        self.from = p.0.changed.val
      }
    }
    added += recorded[i]
  }
  added
}

///|
/// The turns calls from `from` until `until` were made in (store/usage.ts `usageTurns`), each with when it began.
fn Counter::turns(self : Counter, session : String, from : Double, until : Double) -> Array[(Double, For)] raise {
  let got = @readops.usage_turns(self.db, { "session": Json::string(session), "from": Json::number(from), "until": Json::number(until) })
  guard got is Array(items) else { return [] }
  items.map(t => {
    let of = match t {
      { "of": Object(o), .. } => o
      _ => Map([])
    }
    let started = match t {
      { "startedAt": Number(s, ..), .. } => s
      _ => 0.0
    }
    (started, { turn: field(of, "turn"), person: field(of, "person"), thread: field(of, "thread"), profile: field(of, "profile") })
  })
}

///|
/// Whether a put-away transcript was read to its end already, with nothing left to write of it: put away, it is not
/// written again (only restored, and so no longer put away), so its last bytes are not decompressed again to be
/// compared with its anchor (each read of a station's every archive did, its end segment unpacked each time). One
/// still lacking its boundary, its anchor or its place, or of a runtime whose calls are not timed whose `,,,` is still
/// to be written, goes on as before.
fn read_out(archived : Bool, was : Counted?, sized : Double, path : String, time_from : Double?, runtime : String) -> Bool {
  guard archived && was is Some(w) else { return false }
  let to_time = time_from is Some(_) &&
    w.offset > 0.0 &&
    ((w.speed is None && !is_timed_runtime(runtime)) ||
      (is_timed_runtime(runtime) && needs_timing(runtime, w.speed)))
  sized == w.offset && w.cutoff is Some(_) && w.anchor is Some(_) && w.path == path && !to_time
}

///|
/// counter.ts `#readFile`: one transcript of `session` read on from where it was left, its calls recorded a part at a
/// time; how many were new.
async fn Counter::read_file(
  self : Counter,
  path : String,
  runtime : String,
  subagent : Bool,
  session : Session,
  was : Counted?,
  since : Double,
) -> Int raise {
  let host = self.host
  // A transcript may have been put away after its turn ended but before its last new calls were read.
  let archived = put_away(host, path)
  let size = if archived {
    match (try Ok(written_length(host, packed(path))) catch { e => Err(e) }) {
      Ok(Some(n)) => n
      _ =>
        match unpacked_length(host, packed(path)) {
          Some(n) => n
          None => return 0
        }
    }
  } else {
    match size_of(host, path) {
      Some(n) => n
      None => return 0
    }
  }
  let sized = size.to_double()
  if read_out(archived, was, sized, path, self.time_from, runtime) {
    return 0
  }
  let mut anchor : Bytes = b""
  let shortened = match was {
    Some(w) => sized < w.offset
    None => false
  }
  if !shortened && was is Some(w) {
    guard anchor_at(host, path, w.offset.to_int64(), archived) is Some(found) else { return 0 }
    anchor = found
  }
  let replaced = match was {
    Some(w) =>
      shortened ||
      (match w.anchor {
        Some(a) => hex_of(anchor[:]) != a
        None => false
      })
    None => false
  }
  let before : File = match was {
    Some(w) if replaced => { session: w.session, offset: 0.0, model: None, speed: None }
    Some(w) => { session: w.session, offset: w.offset, model: w.model, speed: w.speed }
    None => { session: None, offset: 0.0, model: None, speed: None }
  }
  if replaced {
    anchor = b""
  }
  let mut cutoff = match was {
    Some(w) => w.cutoff
    None => None
  }
  let anchor_missing = match was {
    Some(w) => w.anchor is None
    None => false
  }
  let other_path = match was {
    Some(w) => w.path != path
    None => true
  }
  if replaced || cutoff is None || anchor_missing || other_path {
    let at = if replaced { sized } else { cutoff.unwrap_or(sized) }
    cutoff = Some(begin_counter_file(self.db, path, before, at, hex_of(anchor[:]), replaced).cutoff)
  }
  let cut = cutoff.unwrap()
  if self.files is Some(files) {
    files[path] = {
      session: before.session,
      offset: before.offset,
      model: before.model,
      speed: before.speed,
      cutoff: Some(cut),
      anchor: Some(hex_of(anchor[:])),
      path,
    }
  }
  // Read before calls were timed, of a runtime whose calls are not timed (a chat that left Claude Code or Codex):
  // nothing to time, kept so, its reading on as it is.
  if self.time_from is Some(_) &&
    was is Some(w) &&
    w.speed is None &&
    !replaced &&
    before.offset > 0.0 &&
    sized == before.offset &&
    !is_timed_runtime(runtime) {
    let db = self.db
    db.exec("BEGIN IMMEDIATE")
    errdefer (db.exec("ROLLBACK") catch { _ => () })
    ignore(
      db.run("UPDATE usage_files SET speed = ?1 WHERE (path = ?2 OR path = ?3) AND offset = ?4", [
        Json::string(",,,"),
        Json::string(path),
        Json::string(w.path),
        Json::number(before.offset),
      ]),
    )
    db.exec("COMMIT")
    if self.files is Some(files) {
      for name in [path, w.path] {
        if files.get(name) is Some(f) {
          files[name] = { ..f, speed: Some(",,,") }
        }
      }
    }
  }
  let state : CallState = { model: before.model, codex_id: None, window: None, speed: speed_of(before.speed) }
  // Read before its calls were timed: those from `time_from` on timed now, its reading on from where that left.
  if self.time_from is Some(time_from) &&
    was is Some(w) &&
    is_timed_runtime(runtime) &&
    needs_timing(runtime, w.speed) &&
    !replaced &&
    before.offset > 0.0 {
    state.speed = self.timed_again(path, w.path, runtime, subagent, session.key, before.offset, cut, time_from)
    // (none found to time, kept as `,,,` or `v1:`: read as none (`speed_of`), and not timed again at the next start)
    let saved_speed = kept_speed_for(runtime, state.speed)
    if self.files is Some(files) {
      if files.get(path) is Some(f) {
        files[path] = { ..f, speed: Some(saved_speed) }
      }
      if w.path != path && files.get(w.path) is Some(f) {
        files[w.path] = { ..f, speed: Some(saved_speed) }
      }
    }
  }
  if archived && !replaced && sized == before.offset {
    return 0
  }
  // A session created after the counter began can have its first call timestamped just before that boundary.
  let first_new_at = if session.created_at >= since { min_d(since, session.created_at - skew_ms) } else { since }
  let mut added = 0
  let known_suffix_from = before.offset
  // A Codex transcript's id is in its first line: read again for a file read on from the middle (only where there is
  // something to read, as counter.ts reads it with the first part).
  if runtime == "codex" && (archived || sized != before.offset) {
    state.codex_id = codex_meta(host, path)
  }
  // Each part recorded as it is read, before the next is read.
  read_from(host, path, before.offset.to_int64(), part => {
    for section in sections_of(part, cut) {
      let (bytes, from, offset, followed) = section
      let next_anchor = if bytes.length() >= anchor_bytes {
        bytes[bytes.length() - anchor_bytes:].to_bytes()
      } else {
        let both = @buffer.new()
        both.write_bytes(anchor[:])
        both.write_bytesview(bytes)
        let all = both.to_bytes()
        if all.length() > anchor_bytes {
          all[all.length() - anchor_bytes:].to_bytes()
        } else {
          all
        }
      }
      let model_before = state.model
      let speed_before = Some(kept_speed_for(runtime, state.speed))
      let from_known_suffix = was is Some(_) && !replaced && from.to_double() >= known_suffix_from
      let calls = calls_of(runtime, bytes, subagent, state).filter(c => c.at >= session.created_at - skew_ms &&
        (followed || c.at >= first_new_at || from_known_suffix))
      let mut lo_at = @double.infinity
      let mut hi_at = @double.neg_infinity
      for c in calls {
        lo_at = min_d(lo_at, c.at)
        hi_at = max_d(hi_at, c.at)
      }
      let of = if calls.length() == 0 { [] } else { self.turns(session.key, lo_at, hi_at) }
      let with_for = calls.map(c => {
        // The turn it was made in: the last to start before it (the first, for one before them all).
        let mut lo = 0
        let mut hi = of.length()
        while lo < hi {
          let mid = (lo + hi) >> 1
          if of[mid].0 <= c.at {
            lo = mid + 1
          } else {
            hi = mid
          }
        }
        (c, of[if lo - 1 > 0 { lo - 1 } else { 0 }].1)
      })
      let saved_anchor_hex = hex_of(anchor[:])
      let next_anchor_hex = hex_of(next_anchor[:])
      let total = if with_for.length() > 1 { with_for.length() } else { 1 }
      for i = 0; i < total; i = i + write_batch {
        let complete = i + write_batch >= with_for.length()
        let file : File = {
          session: Some(session.key),
          offset: if complete { offset.to_double() } else { from.to_double() },
          model: if complete { state.model } else { model_before },
          speed: if complete { Some(kept_speed_for(runtime, state.speed)) } else { speed_before },
        }
        let end = if i + write_batch < with_for.length() { i + write_batch } else { with_for.length() }
        let batch = if i < end { with_for[i:end].to_array() } else { [] }
        let saved_anchor = if complete { next_anchor_hex } else { saved_anchor_hex }
        let write : Write = {
          path,
          file,
          runtime,
          calls: batch,
          min_new_at: if followed { None } else { Some(first_new_at) },
          changed: Ref(@double.infinity),
          cutoff: cut,
          anchor: saved_anchor,
        }
        self.pending.push((
          write,
          session.key,
          {
            session: file.session,
            offset: file.offset,
            model: file.model,
            speed: file.speed,
            cutoff: Some(cut),
            anchor: Some(saved_anchor),
            path,
          },
        ))
        self.pending_calls += batch.length()
        if self.pending_calls >= write_batch {
          added += self.flush()
        }
      }
      anchor = next_anchor
    }
  })
  added
}

///|
/// What stops a read of what was read before at its end.
priv suberror ReadEnough

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
impl Show for ReadEnough with output(self, logger) {
  match self {
    ReadEnough => logger.write_string("the read reached where it was read to before")
  }
}

///|
/// reference `timedAgain`: a transcript read again up to `upto`, where it was read to before its calls were timed:
/// each of its calls made from `time_from` on given the time it took (only longer, never a call more), `write_batch`
/// calls a write so that no write holds the database long, and where its reading of that stands kept with its position
/// (at `path` and at `was_path`, where it was read before through another place) in the last. Where its reading stands
/// at `upto`.
async fn Counter::timed_again(
  self : Counter,
  path : String,
  was_path : String,
  runtime : String,
  subagent : Bool,
  session : String,
  upto : Double,
  cut : Double,
  time_from : Double,
) -> Speed raise {
  let state : CallState = {
    model: None,
    codex_id: if runtime == "codex" { codex_meta(self.host, path) } else { None },
    window: None,
    speed: no_speed(),
  }
  let timed : Array[(String, Double, Double)] = []
  read_from(self.host, path, 0L, part => {
    for section in sections_of(part, cut) {
      let (bytes, from, offset, _) = section
      if from.to_double() >= upto {
        raise ReadEnough
      }
      let upto_here = if offset.to_double() > upto { bytes[0:(upto - from.to_double()).to_int()] } else { bytes }
      for c in calls_of(runtime, upto_here, subagent, state) {
        if c.gen_ms > 0.0 && c.at >= time_from {
          timed.push((c.id, c.at, c.gen_ms))
        }
      }
    }
  }) catch {
    ReadEnough => ()
    e => raise e
  }
  let saved_speed = kept_speed_for(runtime, state.speed)
  let db = self.db
  let mut earliest = @double.infinity
  let total = if timed.length() > 1 { timed.length() } else { 1 }
  for i = 0; i < total; i = i + write_batch {
    let end = if i + write_batch < timed.length() { i + write_batch } else { timed.length() }
    db.exec("BEGIN IMMEDIATE")
    errdefer (db.exec("ROLLBACK") catch { _ => () })
    for j in i..<end {
      let (id, at, gen_ms) = timed[j]
      let changed = db.run(
        (
          #|UPDATE usage SET gen_ms = ?2, gen_output = CASE WHEN ?2 > 0 THEN output ELSE 0 END
          #|  WHERE id = ?1 AND gen_ms < ?2
        ),
        [Json::string(id), Json::number(gen_ms)],
      )
      if changed > 0 && at < earliest {
        earliest = at
      }
    }
    if i + write_batch >= timed.length() {
      ignore(
        db.run("UPDATE usage_files SET speed = ?1 WHERE (path = ?2 OR path = ?3) AND offset = ?4", [
          Json::string(saved_speed),
          Json::string(path),
          Json::string(was_path),
          Json::number(upto),
        ]),
      )
    }
    db.exec("COMMIT")
  }
  if earliest != @double.infinity {
    if !self.counted.contains(session) {
      self.counted.push(session)
    }
    if earliest < self.from {
      self.from = earliest
    }
  }
  state.speed
}

///|
/// counter.ts `sectionsOf`: a line already begun at the cutoff belongs to the old part; complete later lines belong to
/// the followed suffix. Each: its bytes, where it begins and ends, whether it is followed.
fn sections_of(part : Part, cutoff : Double) -> Array[(BytesView, Int64, Int64, Bool)] {
  if part.offset.to_double() <= cutoff {
    return [(part.bytes, part.from, part.offset, false)]
  }
  if part.from.to_double() >= cutoff {
    return [(part.bytes, part.from, part.offset, true)]
  }
  let at = (cutoff.to_int64() - part.from).to_int()
  let end = if part.bytes[at - 1] == b'\n' {
    at
  } else {
    let mut i = at
    while i < part.bytes.length() && part.bytes[i] != b'\n' {
      i += 1
    }
    // (indexOf's -1 + 1: none found is 0)
    if i < part.bytes.length() {
      i + 1
    } else {
      0
    }
  }
  let old = part.bytes[0:end]
  let next = part.bytes[end:]
  let out = [(old, part.from, part.from + end.to_int64(), false)]
  if end < part.bytes.length() {
    out.push((next, part.from + end.to_int64(), part.offset, true))
  }
  out
}

///|
///|
/// The sessions run since `?` with a transcript read before its calls were timed, of those that ran a runtime whose
/// calls are timed (reference `UNTIMED_SESSIONS`). Kept scoped to `claude`/`codex` legacy NULL rows; `agy` timing
/// backfill uses the separate bounded `recent_timing_candidates` path below so this query is not widened.
let untimed_sessions : String =
  #|SELECT DISTINCT u.session AS session_key FROM usage_files u JOIN sessions s ON s.key = u.session
  #|  WHERE u.speed IS NULL AND u.offset > 0
  #|    AND (s.runtime IN ('claude', 'codex') OR s.original_runtime IN ('claude', 'codex')
  #|      OR EXISTS (SELECT 1 FROM runtime_sessions r WHERE r.session_key = s.key AND r.runtime IN ('claude', 'codex')))
  #|    AND EXISTS (SELECT 1 FROM turns t INDEXED BY turns_by_session
  #|      WHERE t.session_key = u.session AND (t.ended_at IS NULL OR t.ended_at >= ?))

///|
let recent_timing_page : Int = 256

///|
let recent_running_turns_sql : String =
  #|SELECT rowid, session_key FROM turns INDEXED BY turns_ended
  #|  WHERE ended_at IS NULL AND rowid > ? ORDER BY rowid LIMIT 256

///|
let recent_ended_first_sql : String =
  #|SELECT rowid, session_key, ended_at FROM turns INDEXED BY turns_ended
  #|  WHERE ended_at >= ? ORDER BY ended_at, rowid LIMIT 256

///|
let recent_ended_same_sql : String =
  #|SELECT rowid, session_key, ended_at FROM turns INDEXED BY turns_ended
  #|  WHERE ended_at = ? AND rowid > ? ORDER BY rowid LIMIT 256

///|
let recent_ended_after_sql : String =
  #|SELECT rowid, session_key, ended_at FROM turns INDEXED BY turns_ended
  #|  WHERE ended_at > ? ORDER BY ended_at, rowid LIMIT 256

///|
/// Recent timing candidates: distinct sessions with a running turn or a turn ended since `time_from`, paged over
/// `turns_ended` without scanning `usage_files` (each file is checked by path PK in `read_file`).
fn recent_timing_candidates(db : @sql.Db, time_from : Double) -> Array[String] raise {
  let out : Array[String] = []
  let seen : Set[String] = Set([])
  let add = (rows : Array[Map[String, Json]]) => {
    for r in rows {
      if text_of(field(r, "session_key")) is Some(k) && !seen.contains(k) {
        seen.add(k)
        out.push(k)
      }
    }
  }
  // 1. Running turns (`ended_at IS NULL`), paged by rowid.
  let mut run_rowid = 0.0
  while true {
    let rows = db.all(recent_running_turns_sql, [Json::number(run_rowid)])
    add(rows)
    if rows.length() < recent_timing_page {
      break
    }
    run_rowid = num_of(field(rows[rows.length() - 1], "rowid")).unwrap_or(run_rowid)
  }
  // 2. Ended turns (`ended_at >= time_from`), paged by exact (ended_at = ?, rowid > ?) then (ended_at > ?).
  let first = db.all(recent_ended_first_sql, [Json::number(time_from)])
  add(first)
  if first.length() < recent_timing_page {
    return out
  }
  let mut cursor_at = num_of(field(first[first.length() - 1], "ended_at")).unwrap_or(time_from)
  let mut cursor_rowid = num_of(field(first[first.length() - 1], "rowid")).unwrap_or(0.0)
  while true {
    let same = db.all(recent_ended_same_sql, [Json::number(cursor_at), Json::number(cursor_rowid)])
    add(same)
    if same.length() == recent_timing_page {
      cursor_rowid = num_of(field(same[same.length() - 1], "rowid")).unwrap_or(cursor_rowid)
      continue
    }
    let next = db.all(recent_ended_after_sql, [Json::number(cursor_at)])
    add(next)
    if next.length() < recent_timing_page {
      break
    }
    cursor_at = num_of(field(next[next.length() - 1], "ended_at")).unwrap_or(cursor_at)
    cursor_rowid = num_of(field(next[next.length() - 1], "rowid")).unwrap_or(0.0)
  }
  out
}

///|
/// counter.ts `#read`: one read, of the sessions in `only`, or (none) of those that ran since the last sweep (`last`,
/// 0 before the first); what it answers Node.
pub async fn Counter::read(self : Counter, ask : Json) -> Json raise {
  let started = match ask {
    { "started": Number(s, ..), .. } => s
    _ => 0.0
  }
  let last = match ask {
    { "last": Number(l, ..), .. } => l
    _ => 0.0
  }
  let data = match ask {
    { "dataDir": String(d), .. } => d
    _ => fail("no data directory")
  }
  let homes = match ask {
    { "homes": Array(hs), .. } => hs.filter_map(h => if h is String(s) { Some(s) } else { None })
    _ => []
  }
  let only = match ask {
    { "only": Array(keys), .. } => Some(keys.filter_map(k => if k is String(s) { Some(s) } else { None }))
    _ => None
  }
  self.finder.use_hints(ask.value("hints").unwrap_or(Json::null()))
  self.time_from = match ask {
    { "timeFrom": Number(t, ..), .. } => Some(t)
    _ => None
  }
  let db = self.db
  let cursor = one(db, "SELECT since, through FROM usage_counter WHERE id = 1", [])
  let since = match cursor {
    Some(r) => num_of(field(r, "since")).unwrap_or(0.0)
    None => fail("no usage counter")
  }
  let through = num_of(field(cursor.unwrap(), "through")).unwrap_or(0.0)
  let wanted : Array[String] = []
  let seen_keys : Set[String] = Set([])
  let keys = match only {
    Some(ks) => ks
    None => {
      let base = if last != 0.0 { last } else { through }
      let from = max_d(since, base - margin_ms)
      db
      .all(
        "SELECT session_key FROM turns WHERE ended_at IS NULL UNION ALL SELECT session_key FROM turns WHERE ended_at >= ?",
        [Json::number(from)],
      )
      .filter_map(r => text_of(field(r, "session_key")))
    }
  }
  let recent_any = keys.length() > 0
  for k in keys {
    if !seen_keys.contains(k) {
      seen_keys.add(k)
      wanted.push(k)
    }
  }
  // Timing back (`time_from`), of all:
  // 1. Legacy `claude`/`codex` NULL rows via `untimed_sessions` (normal `wanted`).
  // 2. Bounded recent/running turn candidates via `turns_ended` for `agy`-only backfill, kept separate from `wanted`
  //    so non-agy sessions (e.g. Codex) never trigger transcript directory walks on startup.
  let agy_only_wanted : Array[String] = []
  if only is None && self.time_from is Some(tf) {
    for r in db.all(untimed_sessions, [Json::number(tf)]) {
      if text_of(field(r, "session_key")) is Some(k) && !seen_keys.contains(k) {
        seen_keys.add(k)
        wanted.push(k)
      }
    }
    for k in recent_timing_candidates(db, tf) {
      if !seen_keys.contains(k) {
        seen_keys.add(k)
        agy_only_wanted.push(k)
      }
    }
  }
  let sessions = if wanted.length() == 0 {
    []
  } else {
    db
    .all("SELECT * FROM sessions WHERE key IN (SELECT value FROM json_each(?))", [
      Json::string(Json::array(wanted.map(Json::string)).stringify()),
    ])
    .map(session_of)
  }
  let agy_only_sessions = if agy_only_wanted.length() == 0 {
    []
  } else {
    db
    .all("SELECT * FROM sessions WHERE key IN (SELECT value FROM json_each(?))", [
      Json::string(Json::array(agy_only_wanted.map(Json::string)).stringify()),
    ])
    .map(session_of)
  }
  let known = match self.files {
    Some(f) => f
    None => {
      let f = Map([])
      self.files = Some(f)
      f
    }
  }
  let mut added = 0
  self.counted.clear()
  self.from = @double.infinity
  self.pending = []
  self.pending_calls = 0
  let host = self.host
  // Claude Code: each session's project directory, in the shared transcripts and in any profile's own.
  let claude_roots = []
  let real_roots : Set[String] = Set([])
  for r in self.ways(data, homes, "claude") {
    if !is_dir(host, r) {
      continue
    }
    let real = canonical(host, r)
    if real_roots.contains(real) {
      continue
    }
    real_roots.add(real)
    claude_roots.push(r)
  }
  let seen_files : Set[String] = Set([])
  // A chat may have left a runtime while its final turn was still writing: each earlier segment counted with the
  // runtime that wrote it.
  for s in sessions {
    for source in self.sources(s) {
      let runtime = source.runtime
      if !@locate.runtime_kind(runtime) || runtime == s.runtime {
        continue
      }
      guard self.finder.transcript_path(runtime, data, homes, source.id, [], true) is Some(transcript) else { continue }
      let files = if runtime == "claude" {
        claude_files(host, self.sep, dirname(self.sep, transcript), Some(source.id))
      } else if runtime == "grok" {
        [(self.join([dirname(self.sep, transcript), "stillfail-usage.jsonl"]), false)]
      } else {
        [(transcript, false)]
      }
      for f in files {
        let (path, subagent) = f
        if runtime == "grok" && !exists(host, path) {
          continue
        }
        let real = canonical(host, path)
        if seen_files.contains(real) {
          continue
        }
        seen_files.add(real)
        added += self.read_file(path, runtime, subagent, s, self.read_before(known, data, homes, path, runtime), since)
      }
    }
  }
  for s in sessions {
    if s.runtime != "claude" {
      continue
    }
    let project = claude_project(s.cwd.unwrap_or(s.workspace))
    let only_id = if s.cwd is Some(_) { s.runtime_session_id } else { None }
    if s.cwd is Some(_) && only_id is None {
      continue
    }
    for root in claude_roots {
      for f in claude_files(host, self.sep, self.join([root, project]), only_id) {
        let (path, subagent) = f
        let real = canonical(host, path)
        if seen_files.contains(real) {
          continue
        }
        seen_files.add(real)
        added += self.read_file(path, "claude", subagent, s, self.read_before(known, data, homes, path, "claude"), since)
      }
    }
  }
  // Codex: its transcripts are kept by date, each matched to a session by its id.
  let found : Map[String, Session] = Map([])
  for s in sessions {
    if s.runtime != "codex" {
      continue
    }
    for source in self.sources(s) {
      if source.runtime != "codex" {
        continue
      }
      let id = source.id
      let paths = match self.codex_paths.get(s.key) {
        Some(p) => p
        None => {
          let p = Map([])
          self.codex_paths[s.key] = p
          p
        }
      }
      let mut had = paths.get(id)
      if had is Some(h) && !is_file(host, h) && !is_file(host, packed(h)) {
        paths.remove(id)
        had = None
      }
      // A running thread can report its path before it creates the file; earlier threads can still search history.
      let path = match had {
        Some(h) => Some(h)
        None => {
          let anywhere = !(s.running && s.runtime_session_id == Some(id))
          self.finder.transcript_path("codex", data, homes, id, [], anywhere)
        }
      }
      if path is Some(p) {
        paths[id] = p
        found[p] = s
      }
    }
  }
  for path, s in found {
    let file = self.read_before(known, data, homes, path, "codex")
    if file is Some(f) && f.session is Some(other) && other != s.key {
      continue
    }
    added += self.read_file(path, "codex", false, s, file, since)
  }
  // DeepSeek Harness, Grok Build (what the station kept of its turns beside each transcript), Cursor, Devin, Hermes,
  // Antigravity, Pi: each runtime session's own file.
  for s in sessions {
    let runtime = s.runtime
    if !["dsh", "grok", "cursor", "devin", "hermes", "agy", "pi"].contains(runtime) {
      continue
    }
    for source in self.sources(s) {
      if source.runtime != runtime {
        continue
      }
      let transcript = self.finder.transcript_path(runtime, data, homes, source.id, [], true)
      let path = match transcript {
        Some(t) if runtime == "grok" => Some(self.join([dirname(self.sep, t), "stillfail-usage.jsonl"]))
        other => other
      }
      guard path is Some(path) else { continue }
      if runtime == "grok" && !exists(host, path) {
        continue
      }
      let real = canonical(host, path)
      if seen_files.contains(real) {
        continue
      }
      seen_files.add(real)
      added += self.read_file(path, runtime, false, s, self.read_before(known, data, homes, path, runtime), since)
    }
  }
  // Antigravity startup timing backfill: only locate and read already-tracked `agy` sources that still need timing
  // for `agy_only_sessions`, so non-agy sessions never trigger Codex/Claude walks and untracked or already-upgraded
  // idle `agy` files never enter `read_file`.
  for s in agy_only_sessions {
    for source in self.sources(s) {
      if source.runtime != "agy" {
        continue
      }
      guard self.finder.transcript_path("agy", data, homes, source.id, [], true) is Some(path) else { continue }
      let was = self.read_before(known, data, homes, path, "agy")
      guard was is Some(w) && w.offset > 0.0 && needs_timing("agy", w.speed) else { continue }
      let real = canonical(host, path)
      if seen_files.contains(real) {
        continue
      }
      seen_files.add(real)
      added += self.read_file(path, "agy", false, s, was, since)
    }
  }
  added += self.flush()
  if only is None && recent_any {
    db.exec("BEGIN IMMEDIATE")
    errdefer (db.exec("ROLLBACK") catch { _ => () })
    ignore(db.run("UPDATE usage_counter SET through = MAX(through, ?) WHERE id = 1", [Json::number(started)]))
    db.exec("COMMIT")
  }
  {
    "added": Json::number(added.to_double()),
    "sessions": Json::array(self.counted.map(Json::string)),
    "from": if self.from == @double.infinity { Json::null() } else { Json::number(self.from) },
    "hints": self.finder.hints(),
  }
}
