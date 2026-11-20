// station/src/ops/storage.ts: what the station keeps in its data directory, each top-level name with its class, and
// the upkeep that holds what grows by itself to its bounds.

///|
let mib : Double = 1048576.0


///|
let day_ms : Double = 86400000.0

///|
pub let station_log_cap : Double = 64.0 * mib

///|
pub let update_log_cap : Double = 16.0 * mib

///|
pub let job_log_cap : Double = 64.0 * mib

///|
pub let wal_cap : Double = 128.0 * mib

///|
pub let thumbs_cap : Double = 512.0 * mib

///|
pub let config_backups_kept : Int = 3

///|
pub let node_part_ms : Double = day_ms

///|
/// storage.ts `BOARD_FILES_GONE_MS`.
pub let board_files_gone_ms : Double = day_ms

///|
pub let upkeep_every_ms : Double = 600000.0

///|
pub let upkeep_first_ms : Double = 120000.0

///|
/// storage.ts `StorageEntry`.
pub(all) struct StorageEntry {
  name : String
  class : String
  what : String
  max_bytes : Double?
  max_age_ms : Double?
  reclaim : String?
}

///|
pub fn StorageEntry::to_json(self : StorageEntry) -> Json {
  let m : Map[String, Json] = { "name": js(self.name), "class": js(self.class), "what": js(self.what) }
  match self.max_bytes {
    Some(b) => m["maxBytes"] = jn(b)
    None => ()
  }
  match self.max_age_ms {
    Some(a) => m["maxAgeMs"] = jn(a)
    None => ()
  }
  match self.reclaim {
    Some(r) => m["reclaim"] = js(r)
    None => ()
  }
  Json::object(m)
}

///|
fn se(
  name : String,
  class : String,
  what : String,
  max_bytes? : Double,
  max_age_ms? : Double,
  reclaim? : String,
) -> StorageEntry {
  { name, class, what, max_bytes, max_age_ms, reclaim }
}

///|
/// storage.ts `STORAGE_MANIFEST`.
pub let storage_manifest : Array[StorageEntry] = [
  se("stillfail.db", "authoritative", "everything lasting (store/store.ts)"),
  se("stillfail.db-wal", "bounded-ephemeral", "the database's log", max_bytes=wal_cap, reclaim="Upkeep walCheckpoint"),
  se("stillfail.db-shm", "bounded-ephemeral", "the database's shared memory index (SQLite's, a few MB)", max_bytes=64.0 * mib, reclaim="SQLite"),
  se("stillfail.log", "bounded-ephemeral", "the station's log (launchd, systemd)", max_bytes=station_log_cap, reclaim="Upkeep rotateInPlace"),
  se("stillfail.log.1", "bounded-ephemeral", "the station's log before its last cut", max_bytes=station_log_cap, reclaim="Upkeep rotateInPlace"),
  se("stillfail.log.1.tmp", "bounded-ephemeral", "a cut of the log being written", max_bytes=station_log_cap, reclaim="Upkeep rotateInPlace"),
  se("config.json", "authoritative", "the station's settings"),
  se("config.json.bak-*", "bounded-ephemeral", "settings as they were before a change", reclaim="Upkeep: the newest \{config_backups_kept} kept"),
  se("presence.json", "bounded-ephemeral", "whether the station is online (older stations)", max_bytes=mib),
  se("model-catalog.json", "bounded-ephemeral", "the models' catalog as last read", max_bytes=16.0 * mib),
  se("repo-index.json", "bounded-ephemeral", "the repositories found on the machine", max_bytes=64.0 * mib),
  se("remote-connects.json", "authoritative", "connects of other stations (connects/keys.ts)"),
  se("comma-tasks.json", "authoritative", "Comma's tasks"),
  se("comma-stats.db", "authoritative", "Comma's statistics"),
  se("comma-stats.db-*", "authoritative", "Comma's statistics' log and shared memory"),
  se("comma-indexes", "authoritative", "Comma's indexes"),
  se("feishu-threads.json", "authoritative", "Feishu's threads"),
  se("feishu-registrations.json", "authoritative", "Feishu's registrations"),
  se("group-threads.json", "authoritative", "what the group connects heard of their IM servers"),
  se("windows.json", "authoritative", "Windows' install settings"),
  se("uninstalled", "authoritative", "taken away here, its data kept (stillfail uninstall, the app's 卸载本机 Station; an install removes it)"),
  se("drive-grant.key", "authoritative", "the drive's grant key"),
  se("app", "authoritative", "the station's release"),
  se("node", "authoritative", "the station's Node (its half-done downloads, .part-*, held by Upkeep)", max_age_ms=node_part_ms, reclaim="Upkeep staleNodeParts"),
  se("bin", "authoritative", "commands installed for the station"),
  se("ca", "authoritative", "certificates the station trusts"),
  se("runtimes", "authoritative", "agent runtimes installed by the station"),
  se("screen-tools", "authoritative", "tools a screen needs (Linux)"),
  se("helper", "authoritative", "still.fail Helper"),
  se("browser", "authoritative", "the station's own Chrome profiles (sign-ins)"),
  se("shells", "authoritative", "the agents' shells' settings"),
  se("shell", "authoritative", "the agents' shell's settings"),
  se("transcripts", "authoritative", "the agents' transcripts", reclaim="sessions/lifecycle.ts deleteSession (exclusive), ops/storage.ts relieveOrphanTranscripts (low disk only)"),
  se("transcripts-segmented", "authoritative", "transcripts put away in segments (sessions/cold.ts)"),
  se("sessions", "session-bound", "each chat's workspace", reclaim="sessions/lifecycle.ts expireArchived, packUnfinishedArchived, cleanIdleRebuildable, relieveIdleRebuildable, relieveArchived; Upkeep pruneOrphanRooms"),
  se("archive", "authoritative", "chats put away (store/archive.ts)"),
  se("uploads", "authoritative", "files sent in chats"),
  se(
    "board-files",
    "authoritative",
    "the files of people's drafts of 待派发 (sessions/board-drafts.ts; those of a draft started or deleted, .gone, a day more, held by Upkeep)",
    max_age_ms=board_files_gone_ms,
    reclaim="Upkeep goneBoardFiles",
  ),
  se("homes", "authoritative", "the runtimes' homes (accounts' sign-ins, their settings)", reclaim="sessions/lifecycle.ts deleteSession (exclusive transcripts), ops/storage.ts relieveOrphanTranscripts (low disk only)"),
  se("repos", "session-bound", "the repositories' shared clones", reclaim="sessions/lifecycle.ts relieveRepos (low disk only)"),
  se("agent", "authoritative", "the agents' memory and skills"),
  se("share", "authoritative", "the memory's versions shared between stations"),
  se("xshare", "authoritative", "chats shared with other workspaces"),
  se("mesh", "authoritative", "the station's key and what the cloud said"),
  se("vault", "authoritative", "the vault's state"),
  se("logins", "authoritative", "logins in progress and kept"),
  se("replica", "authoritative", "this station's copies off the machine (replica/)"),
  se("replicas", "authoritative", "other stations' copies kept here (replica/)"),
  se("restore", "authoritative", "a lost station's copy being taken back"),
  se("rig", "authoritative", "a station that only runs tasks: its grants"),
  se("move", "session-bound", "items moving to or from another station (move/)", reclaim="move/"),
  se("drive-transfers", "session-bound", "the drive's transfers", reclaim="drive/"),
  se("workspace-limits", "authoritative", "sizes of the workspaces measured"),
  se("resources", "bounded-ephemeral", "resource samples", max_bytes=64.0 * mib),
  se("Trash", "authoritative", "files the drive put in the trash"),
  se("run", "bounded-ephemeral", "what runs (runners, pids, sockets, the update's log)", reclaim="Upkeep: runner sweep, update.log cut"),
  se("jobs", "bounded-ephemeral", "jobs' logs and exit files", max_age_ms=14.0 * day_ms, reclaim="jobs/jobs.ts capLogs, collect"),
  se("remote", "session-bound", "other stations' tasks here and tasks started from here", reclaim="jobs/remote.ts sweep, relieve, budget, expire"),
  se("thumbs", "bounded-ephemeral", "thumbnails of images", max_bytes=thumbs_cap, reclaim="Upkeep capByAge"),
  se("transcript-marks", "bounded-ephemeral", "where transcripts' entries are (read/transcripts.ts)", reclaim="Upkeep orphanMarks"),
]

///|
/// `*` standing for any run of characters (storage.ts `globRegExp`).
fn glob_match(glob : String, name : String) -> Bool {
  let parts = split_on(glob, "*")
  if parts.length() == 1 {
    return glob == name
  }
  if !starts(name, parts[0]) {
    return false
  }
  let mut at = parts[0].length()
  for i in 1..<(parts.length() - 1) {
    let k = index_of(name, parts[i], from=at)
    if k < 0 {
      return false
    }
    at = k + parts[i].length()
  }
  let last = parts[parts.length() - 1]
  name.length() - last.length() >= at && ends(name, last) &&
  // `.` in a regular expression matches no line terminator.
  !any_unit(sub(name, parts[0].length(), name.length() - last.length()), c => c == 10 || c == 13 || c == 0x2028 || c == 0x2029)
}

///|
/// storage.ts `storageEntry`.
pub fn storage_entry(name : String) -> StorageEntry? {
  for e in storage_manifest {
    if has(e.name, "*") {
      if glob_match(e.name, name) {
        return Some(e)
      }
    } else if e.name == name {
      return Some(e)
    }
  }
  None
}

///|
/// storage.ts `used`: what a file takes on the disk, its blocks where told, else its size.
pub fn used_bytes(blocks : Double?, size : Double) -> Double {
  match blocks {
    Some(b) if b >= 0.0 => b * 512.0
    _ => size
  }
}

///|
/// storage.ts `treeBytes`: how much of the disk a tree takes, as a bounded walk finds it.
pub fn tree_bytes(fs : Fs, path : String, most : Int, now : () -> Double) -> (Double, Int, Bool) raise {
  let mut bytes = 0.0
  let o = { ..WalkOptions::default(now), stat: true, max_entries: most, max_depth: 256, max_duration_ms: 60000.0 }
  let walked = walk_bounded(
    fs,
    [path],
    e => {
      match e.stats {
        Some(s) => bytes += used_bytes(None, s.size)
        None => ()
      }
      Go
    },
    o,
  )
  (bytes, walked.visited, walked.truncated)
}

///|
/// storage.ts `rotateInPlace`'s plan: whether a log of `size` is cut at `cap`, and from where its last `keep` bytes
/// are copied.
pub fn rotate_plan(size : Double, cap : Double, keep : Double) -> Double? {
  if size <= cap {
    None
  } else {
    let from = size - keep
    Some(if from > 0.0 { from } else { 0.0 })
  }
}

///|
/// storage.ts `rotateInPlace` on Unix: the log's last `keep` bytes to `<path>.1` (through `.1.tmp`), then the file cut
/// to nothing where it is, its inode the same (`: >`, as an O_APPEND writer's next write lands at its new end). Whether
/// it was cut.
pub fn rotate_in_place(fs : Fs, path : String, cap : Double, keep : Double) -> Bool raise {
  guard fs.meta(path) is Some((size, _, _)) else { return false }
  guard rotate_plan(size, cap, keep) is Some(_) else { return false }
  let tmp = path + ".1.tmp"
  let script = "tail -c \"$3\" \"$1\" > \"$2\" && chmod 600 \"$2\" && mv -f \"$2\" \"$1.1\" && : > \"$1\""
  match fs.run("/bin/sh", ["-c", script, "sh", path, tmp, num_text(keep)], timeout_ms=60000) {
    Some(_) => true
    None => {
      fs.remove(tmp)
      raise Failure("\{path} was not cut")
    }
  }
}

///|
/// storage.ts `keepNewest`'s choice: of `dated` (a name, its mtime), all but the `kept` newest.
pub fn keep_newest_plan(dated : Array[(String, Double)], kept : Int) -> Array[String] {
  let sorted = stable_sort(dated, (a, b) => {
    let d = b.1 - a.1
    if d > 0.0 {
      1
    } else if d < 0.0 {
      -1
    } else {
      0
    }
  })
  if sorted.length() <= kept {
    []
  } else {
    sorted[kept:].to_owned().map(d => d.0)
  }
}

///|
/// storage.ts `keepNewest`: of the files in `dir` named `prefix…`, all but the `kept` newest removed; the names removed.
pub fn keep_newest(fs : Fs, dir : String, prefix : String, kept : Int) -> Array[String] raise {
  let names = fs.names(dir).unwrap_or([]).filter(n => starts(n, prefix))
  let dated = names.map(n => (
    n,
    match fs.meta(posix_join([dir, n])) {
      Some((_, at, _)) => at
      None => 0.0
    },
  ))
  let gone = keep_newest_plan(dated, kept)
  for n in gone {
    try fs.remove(posix_join([dir, n]), recursive=true) catch {
      _ => ()
    }
  }
  gone
}

///|
/// storage.ts `removeStale`: what in `dir` starts with `prefix` and has not changed for `max_age_ms` before `now`.
pub fn remove_stale(fs : Fs, dir : String, prefix : String, max_age_ms : Double, now : Double) -> Array[String] raise {
  let gone = []
  for n in fs.names(dir).unwrap_or([]) {
    if !starts(n, prefix) {
      continue
    }
    guard fs.lstat(posix_join([dir, n])) is Some(st) else { continue }
    if now - st.mtime_ms < max_age_ms {
      continue
    }
    try fs.remove(posix_join([dir, n]), recursive=true) catch {
      _ => ()
    }
    gone.push(n)
  }
  gone
}

///|
/// Pure selection for `gone_board_files`: given `(person, draft, [(file, mtime_ms)])` under `<person>/.gone/<draft>`,
/// returns `(gone_labels_sorted, empty_draft_dirs)`.
fn gone_board_files_plan(
  entries : Array[(String, String, Array[(String, Double)])],
  max_age_ms : Double,
  now : Double,
) -> (Array[String], Array[(String, String)]) {
  let gone = []
  let empty_dirs = []
  for entry in entries {
    let (person, draft, files) = entry
    let mut left = files.length()
    for f in files {
      if now - f.1 < max_age_ms {
        continue
      }
      gone.push(person + "/" + draft + "/" + f.0)
      left -= 1
    }
    if left == 0 {
      empty_dirs.push((person, draft))
    }
  }
  gone.sort_by(units_order)
  (gone, empty_dirs)
}

///|
/// storage.ts `goneBoardFiles`: the files of drafts of 待派发 started or deleted (`dir` is board-files:
/// <person>/.gone/<draft>/<file>) put aside `max_age_ms` or longer before `now`, removed, and a draft's folder left
/// empty: the files removed, as <person>/<draft>/<file>, sorted.
pub fn gone_board_files(fs : Fs, dir : String, max_age_ms : Double, now : Double) -> Array[String] raise {
  let entries = []
  for person in fs.names(dir).unwrap_or([]) {
    let aside = posix_join([dir, person, ".gone"])
    for draft in fs.names(aside).unwrap_or([]) {
      guard fs.names(posix_join([aside, draft])) is Some(files) else { continue }
      let dated = []
      for f in files {
        guard fs.lstat(posix_join([aside, draft, f])) is Some(st) else { continue }
        dated.push((f, st.mtime_ms))
      }
      entries.push((person, draft, dated))
    }
  }
  let (gone, empty_dirs) = gone_board_files_plan(entries, max_age_ms, now)
  for label in gone {
    let parts = split_on(label, "/")
    if parts.length() == 3 {
      try fs.remove(posix_join([dir, parts[0], ".gone", parts[1], parts[2]]), recursive=true) catch {
        _ => ()
      }
    }
  }
  for d in empty_dirs {
    try fs.remove(posix_join([dir, d.0, ".gone", d.1]), recursive=true) catch {
      _ => ()
    }
  }
  gone
}

///|
/// As JavaScript's sort() compares strings: by their UTF-16 code units (MoonBit's compare puts the shorter first).
fn units_order(a : String, b : String) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let d = a.unsafe_charcode_at(i) - b.unsafe_charcode_at(i)
    if d != 0 {
      return d
    }
  }
  a.length() - b.length()
}

///|
/// storage.ts `capByAge`'s choice: of `files` (a path, its bytes, its mtime), those to remove, the longest unchanged
/// first, until they are `max_bytes` together; and the bytes freed.
pub fn cap_plan(files : Array[(String, Double, Double)], max_bytes : Double) -> (Array[String], Double) {
  let mut total = files.fold(init=0.0, (n, f) => n + f.1)
  if total <= max_bytes {
    return ([], 0.0)
  }
  let sorted = stable_sort(files, (a, b) => {
    let d = a.2 - b.2
    if d > 0.0 {
      1
    } else if d < 0.0 {
      -1
    } else {
      0
    }
  })
  let gone = []
  let mut freed = 0.0
  for f in sorted {
    if total <= max_bytes {
      break
    }
    gone.push(f.0)
    total -= f.1
    freed += f.1
  }
  (gone, freed)
}

///|
/// storage.ts `capByAge`: the files of `dir` taken down to `max_bytes` together; the bytes freed.
pub fn cap_by_age(fs : Fs, dir : String, max_bytes : Double) -> Double raise {
  guard fs.readdir(dir) is Some(names) else { return 0.0 }
  let files = []
  for d in names {
    if d.1 != "file" {
      continue
    }
    let path = posix_join([dir, d.0])
    match fs.lstat(path) {
      Some(st) => files.push((path, used_bytes(None, st.size), st.mtime_ms))
      None => ()
    }
  }
  let (gone, freed) = cap_plan(files, max_bytes)
  for p in gone {
    try fs.remove(p) catch {
      _ => ()
    }
  }
  freed
}

///|
/// storage.ts `orphanMarks`: the readings kept of transcripts gone (or that do not read), removed; their names.
pub fn orphan_marks(fs : Fs, dir : String) -> Array[String] raise {
  let gone = []
  for n in fs.names(dir).unwrap_or([]) {
    if !ends(n, ".json") {
      continue
    }
    let file = posix_join([dir, n])
    let path = match fs.read(file) {
      Some(t) =>
        match js_parse(t) {
          Some(j) =>
            match field(j, "state") {
              Some(st) => str_field(st, "path")
              None => None
            }
          None => None
        }
      None => None
    }
    let there = match path {
      Some(p) => fs.kind(p) is Some(_)
      None => false
    }
    if there {
      continue
    }
    try fs.remove(file) catch {
      _ => ()
    }
    gone.push(n)
  }
  gone
}

///|
/// storage.ts `Upkeep #step`: whether what a step did is said (true, a list not empty, a number over 0).
pub fn upkeep_said(did : Json) -> Json? {
  match did {
    True => Some(jb(true))
    Array(a) if a.length() > 0 => Some(ji(a.length()))
    Number(n, ..) if n > 0.0 => Some(jn(n))
    _ => None
  }
}

///|
/// storage.ts `Upkeep`'s round: its steps in order, those whose parts are given.
pub fn upkeep_round(runners : Bool, jobs : Bool, remote : Bool, checkpoint : Bool) -> Array[String] {
  let out = ["station log", "update log"]
  if runners {
    out.push("runners")
  }
  if jobs {
    out.push("jobs")
  }
  if remote {
    out.push("remote")
  }
  if checkpoint {
    out.push("database log")
  }
  out.push_iter(["thumbs", "node parts", "config backups", "transcript marks", "board files"].iter())
  out
}

///|
/// storage.ts `walCheckpoint`'s choice: whether the database's log of `size` bytes is written into the database.
pub fn wal_past(size : Double?) -> Bool {
  size.unwrap_or(0.0) > wal_cap
}
