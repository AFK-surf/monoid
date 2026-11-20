// What grows by itself held to its bound (station/src/ops/storage.ts `Upkeep`), and the disk of the station's data
// getting full (ops/disk.ts, sessions/agents.ts `relieving`), as parts of the station; and a workspace's size watched
// against its soft limit (jobs/workspace-size.ts `WorkspaceWatch`). Every UPKEEP_EVERY_MS (the first UPKEEP_FIRST_MS
// after the start): the station's log and the update's cut where they are (`rotate_in_place`: never renamed, other
// processes append to them), the runners left by processes gone (the hub's), the jobs' logs and the files of jobs long
// over, the rooms of other stations' sessions (unused for IDLE_MS, then over their budget), the database's log past
// WAL_CAP written into it, the thumbnails held to THUMBS_CAP, half-done downloads, old copies of the config, readings
// of transcripts gone. Every DISK_EVERY_MS (DISK_SOFT_EVERY_MS under its soft mark) the disk: under the soft mark what is
// made again when asked for goes sooner and the mirrors of other stations' tasks not in use, under DISK_LOW_BYTES the
// workspaces of archived chats before their time (the hub's `relieveArchived`).

///|
let p53_disk_low_bytes : Double = 20.0 * 1073741824.0

///|
let p53_disk_soft_bytes : Double = 30.0 * 1073741824.0

///|
let p53_disk_every_ms : Int = 300000

///|
let p53_disk_soft_every_ms : Int = 30000

///|
let p53_upkeep_every_ms : Int = 600000

///|
let p53_upkeep_first_ms : Int = 120000

///|
let p53_mib : Double = 1048576.0

///|
let p53_station_log_cap : Double = 64.0 * 1048576.0

///|
let p53_update_log_cap : Double = 16.0 * 1048576.0

///|
let p53_wal_cap : Double = 128.0 * 1048576.0

///|
let p53_thumbs_cap : Double = 512.0 * 1048576.0

///|
let p53_config_backups_kept : Int = 3

///|
let p53_node_part_ms : Double = 24.0 * 3600000.0

///|
let p53_board_files_gone_ms : Double = 24.0 * 3600000.0

///|
priv struct P53Upkeep {
  bus : LiveBus
  jobs : P53Jobs
  remote : P53Remote
  mut tier : String
  mut running : Bool
}

///|
fn P53Upkeep::new(bus : LiveBus, jobs : P53Jobs, remote : P53Remote) -> P53Upkeep {
  { bus, jobs, remote, tier: "ok", running: false }
}

///|
/// Where a disk with `free` of `total` bytes free stands (ops/disk.ts `diskTier`).
fn p53_disk_tier(free : Double, total : Double) -> String {
  if free < p53_disk_low(total) {
    return "low"
  }
  if free < p53_disk_soft(total) {
    "soft"
  } else {
    "ok"
  }
}

///|
/// The low mark of a disk of `total` bytes (ops/disk.ts `diskLow`): a tenth of it where that is less.
fn p53_disk_low(total : Double) -> Double {
  if total / 10.0 < p53_disk_low_bytes {
    total / 10.0
  } else {
    p53_disk_low_bytes
  }
}

///|
/// The soft mark of a disk of `total` bytes (ops/disk.ts `diskSoft`).
fn p53_disk_soft(total : Double) -> Double {
  if total / 10.0 > p53_disk_soft_bytes {
    total / 10.0
  } else {
    p53_disk_soft_bytes
  }
}

///|
fn P53Upkeep::attach(self : P53Upkeep) -> Unit {
  let bus = self.bus
  fork_bg(bus.host, "upkeep", async fn() {
    @effect.sleep(p53_upkeep_first_ms) // timer: a sample of this machine (its disk)
    while !bus.stopped.is_done() {
      ignore(self.pass())
      @effect.sleep(p53_upkeep_every_ms) // timer: a sample of this machine (its disk)
    }
  })
  fork_bg(bus.host, "disk", async fn() {
    @effect.sleep(p53_disk_every_ms) // timer: a sample of this machine (its disk)
    while !bus.stopped.is_done() {
      ignore(self.relieving())
      let every = if self.tier == "ok" { p53_disk_every_ms } else { p53_disk_soft_every_ms }
      @effect.sleep(every) // timer: a sample of this machine (its disk)
    }
  })
}

///|
/// A step of it, said where it held something to its bound, its failure said and passed over (`#step`).
async fn P53Upkeep::step(self : P53Upkeep, what : String, did : Json, f : async () -> Json) -> Unit {
  ignore(self)
  let out = try { Ok(f()) } catch { e => Err(e) }
  match out {
    Ok(v) => {
      let counted = match v {
        True => true
        Number(n, ..) => n > 0.0
        Array(xs) => xs.length() > 0
        _ => false
      }
      if counted {
        slice_log("info", "upkeep", "held to its bound", jobj_of([("what", jstr(what)), ("did", v)]))
      }
      ignore(did)
    }
    Err(e) => slice_log("warn", "upkeep", "not held to its bound", jobj_of([("what", jstr(what)), ("error", jstr(p53_words(e)))]))
  }
}

///|
/// One round (ops/storage.ts `Upkeep.#round`): what it held to its bound, by step.
async fn P53Upkeep::pass(self : P53Upkeep) -> Json {
  if self.running {
    return jobj_of([("running", jb(true))])
  }
  self.running = true
  defer {
    self.running = false
  }
  let bus = self.bus
  let host = bus.host
  let data = bus.data
  let now = wall_ms().to_double()
  let out : Map[String, Json] = Map([])
  let at = (parts : Array[String]) => @nodepath.join(sep(), [data] + parts)
  let note = async fn(what : String, f : async () -> Json) {
    self.step(what, Json::null(), async fn() {
      let v = f()
      out[what] = v
      v
    })
  }
  note("station log", async fn() { jb(@jobs_host.rotate_in_place(host, at(["stillfail.log"]), p53_station_log_cap)) })
  note("update log", async fn() { jb(@jobs_host.rotate_in_place(host, at(["run", "update.log"]), p53_update_log_cap)) })
  note("runners", async fn() { bus.hub_sweep_runners(now) })
  note("jobs", async fn() {
    let (capped, collected) = self.jobs.upkeep(now)
    jobj_of([("capped", ji(capped)), ("collected", Json::array(collected.map(jstr)))])
  })
  note("remote", async fn() {
    let total = match disk_of(data) {
      Some((_, t)) => Some(t)
      None => None
    }
    let (expired, freed) = self.remote.upkeep(now, total)
    jobj_of([("expired", ji(expired)), ("freed", jn(freed))])
  })
  note("database log", async fn() {
    let wal = at(["stillfail.db-wal"])
    let before = p53_size_of(host, wal)
    if before <= p53_wal_cap {
      return jb(false)
    }
    bus.db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    let after = p53_size_of(host, wal)
    slice_log("warn", "upkeep", "the database's log grew past its bound: written into the database", jobj_of([("before", jn(before)), ("after", jn(after))]))
    jb(true)
  })
  self.renewables(now, p53_thumbs_cap, p53_node_part_ms, note)
  note("board files", async fn() {
    Json::array(p53_gone_board_files(host, at(["board-files"]), p53_board_files_gone_ms, now).map(jstr))
  })
  let (free, total) = disk_of(data).unwrap_or((-1.0, -1.0))
  out["free"] = jn(free)
  out["total"] = jn(total)
  Json::object(out)
}

///|
/// What is made again when asked for (ops/storage.ts `renewables`): the thumbnails held to `thumbs`, half-done
/// downloads older than `parts_ms`, old copies of the config, readings of transcripts gone.
async fn P53Upkeep::renewables(
  self : P53Upkeep,
  now : Double,
  thumbs : Double,
  parts_ms : Double,
  note : async (String, async () -> Json) -> Unit,
) -> Unit {
  let host = self.bus.host
  let data = self.bus.data
  let at = (parts : Array[String]) => @nodepath.join(sep(), [data] + parts)
  note("thumbs", async fn() { jn(p53_cap_by_age(host, at(["thumbs"]), thumbs)) })
  note("node parts", async fn() { Json::array(p53_remove_stale(host, at(["node"]), ".part-", parts_ms, now).map(jstr)) })
  note("config backups", async fn() { Json::array(p53_keep_newest(host, data, "config.json.bak-", p53_config_backups_kept).map(jstr)) })
  note("transcript marks", async fn() { Json::array(p53_orphan_marks(host, at(["transcript-marks"])).map(jstr)) })
}

///|
/// The disk looked at (sessions/agents.ts `relieving`): under its soft mark what is made again goes sooner and the
/// mirrors of other stations' tasks not in use; under DISK_LOW_BYTES the archived chats' workspaces, by the hub.
async fn P53Upkeep::relieving(self : P53Upkeep) -> Json {
  let bus = self.bus
  let now = wall_ms().to_double()
  let (free, total) = match disk_of(bus.data) {
    Some(d) => d
    None => {
      self.tier = "ok"
      return jobj_of([("tier", jstr("ok"))])
    }
  }
  self.tier = p53_disk_tier(free, total)
  if self.tier != "ok" {
    slice_log("warn", "upkeep", "the disk is getting full; making room", jobj_of([("free", jn(free)), ("total", jn(total)), ("tier", jstr(self.tier))]))
    self.renewables(now, p53_thumbs_cap / 4.0, 3600000.0, async fn(what, f) { self.step(what, Json::null(), f) })
    self.remote.relieve(now, p53_disk_soft(total))
  }
  match disk_of(bus.data) {
    Some((left, _)) if left < p53_disk_low(total) =>
      bus.hub_relieve_archived(low_bytes=p53_disk_low(total)) catch {
        e => slice_log("warn", "hub", "making room on the disk failed", jobj_of([("error", jstr(p53_words(e)))]))
      }
    _ => ()
  }
  jobj_of([("tier", jstr(self.tier)), ("free", jn(free)), ("total", jn(total))])
}

///|
/// A file's size, 0 where it is not there.
async fn p53_size_of(host : @host.Host, path : String) -> Double {
  match (try { Ok(host.shell("fs.meta", { "path": Json::string(path) })) } catch { e => Err(e) }) {
    Ok((m, _)) => jnum_of(m, "size").unwrap_or(0.0)
    Err(_) => 0.0
  }
}

///|
/// What is at a path, as `fs.lstat` says it: its kind, size and mtime.
async fn p53_lstat(host : @host.Host, path : String) -> Json {
  match (try { Ok(host.shell("fs.lstat", { "path": Json::string(path) })) } catch { e => Err(e) }) {
    Ok((m, _)) => m
    Err(_) => Json::null()
  }
}

///|
/// A directory's names, none where it is not read.
async fn p53_names(host : @host.Host, dir : String) -> Array[String] {
  host_readdir_names(host, dir).unwrap_or([])
}

///|
async fn p53_remove(host : @host.Host, path : String) -> Unit {
  host_remove_tree(host, path)
}

///|
/// The files of `dir` (not its directories) taken down to `most` together, the longest unchanged first (storage.ts
/// `capByAge`): the bytes freed.
async fn p53_cap_by_age(host : @host.Host, dir : String, most : Double) -> Double {
  let files = []
  for n in p53_names(host, dir) {
    let path = @nodepath.join(sep(), [dir, n])
    let st = p53_lstat(host, path)
    if jtext(st, "kind") == Some("file") {
      let blocks = jnum_of(st, "blocks")
      let bytes = match blocks {
        Some(b) if b >= 0.0 => b * 512.0
        _ => jnum_of(st, "size").unwrap_or(0.0)
      }
      files.push((path, bytes, jnum_of(st, "mtimeMs").unwrap_or(0.0)))
    }
  }
  let mut total = files.fold(init=0.0, (n, f) => n + f.1)
  if total <= most {
    return 0.0
  }
  files.sort_by((a, b) => a.2.compare(b.2))
  let mut freed = 0.0
  for f in files {
    if total <= most {
      break
    }
    p53_remove(host, f.0)
    total -= f.1
    freed += f.1
  }
  freed
}

///|
/// What in `dir` starts with `prefix` and has not changed for `most_ms` before `now`, removed (storage.ts
/// `removeStale`): the names removed.
async fn p53_remove_stale(host : @host.Host, dir : String, prefix : String, most_ms : Double, now : Double) -> Array[String] {
  let gone = []
  for n in p53_names(host, dir) {
    if !n.has_prefix(prefix) {
      continue
    }
    let st = p53_lstat(host, @nodepath.join(sep(), [dir, n]))
    match jnum_of(st, "mtimeMs") {
      Some(at) if now - at >= most_ms => {
        p53_remove(host, @nodepath.join(sep(), [dir, n]))
        gone.push(n)
      }
      _ => ()
    }
  }
  gone
}

///|
/// The files of drafts of 待派发 started or deleted (<person>/.gone/<draft>/<file> of board-files) put aside `most_ms`
/// or longer before `now`, removed, and a draft's folder left empty (storage.ts `goneBoardFiles`).
async fn p53_gone_board_files(host : @host.Host, dir : String, most_ms : Double, now : Double) -> Array[String] {
  let gone = []
  for person in p53_names(host, dir) {
    let aside = @nodepath.join(sep(), [dir, person, ".gone"])
    for draft in p53_names(host, aside) {
      let files = p53_names(host, @nodepath.join(sep(), [aside, draft]))
      let mut left = files.length()
      for f in files {
        let path = @nodepath.join(sep(), [aside, draft, f])
        match jnum_of(p53_lstat(host, path), "mtimeMs") {
          Some(at) if now - at >= most_ms => {
            p53_remove(host, path)
            gone.push(person + "/" + draft + "/" + f)
            left -= 1
          }
          _ => ()
        }
      }
      if left == 0 {
        p53_remove(host, @nodepath.join(sep(), [aside, draft]))
      }
    }
  }
  gone.sort_by(p53_units_order)
  gone
}

///|
/// As JavaScript's sort() compares strings: by their UTF-16 code units (MoonBit's compare puts the shorter first).
fn p53_units_order(a : String, b : String) -> Int {
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
/// The newest `kept` of what in `dir` starts with `prefix`, the rest removed (storage.ts `keepNewest`).
async fn p53_keep_newest(host : @host.Host, dir : String, prefix : String, kept : Int) -> Array[String] {
  let dated = []
  for n in p53_names(host, dir) {
    if n.has_prefix(prefix) {
      dated.push((n, jnum_of(p53_lstat(host, @nodepath.join(sep(), [dir, n])), "mtimeMs").unwrap_or(0.0)))
    }
  }
  dated.sort_by((a, b) => b.1.compare(a.1))
  let gone = []
  for i, d in dated {
    if i >= kept {
      p53_remove(host, @nodepath.join(sep(), [dir, d.0]))
      gone.push(d.0)
    }
  }
  gone
}

///|
/// The readings kept of transcripts whose transcript is gone, and those that do not read, removed (storage.ts
/// `orphanMarks`).
async fn p53_orphan_marks(host : @host.Host, dir : String) -> Array[String] {
  let gone = []
  for n in p53_names(host, dir) {
    if !n.has_suffix(".json") {
      continue
    }
    let file = @nodepath.join(sep(), [dir, n])
    let path = match shell_read_text(host, file) {
      Some(t) =>
        match attempt(() => @json.parse(t)) {
          Ok(j) => jtext(jfield(j, "state"), "path")
          Err(_) => None
        }
      None => None
    }
    let there = match path {
      Some(p) => host_exists(host, p)
      None => false
    }
    if !there {
      p53_remove(host, file)
      gone.push(n)
    }
  }
  gone
}

// ── a workspace's size (jobs/workspace-size.ts) ──

///|
priv struct P53Watch {
  bus : LiveBus
  jobs : P53Jobs
  remote : P53Remote
  mut watch : @jobs_host.WorkspaceWatch?
  /// Done once the watch has read what it keeps (workspace-size.ts `ready`).
  made : @effect.Deferred[Unit]
}

///|
fn P53Watch::new(bus : LiveBus, jobs : P53Jobs, remote : P53Remote) -> P53Watch {
  { bus, jobs, remote, watch: None, made: @effect.Deferred::new() }
}

///|
/// Whether a session is at work now (its turn running, or a job of its up).
fn P53Watch::working(self : P53Watch, key : String) -> Bool {
  let row = bus_session_row(self.bus, key)
  jtrue(row, "running") || (self.bus.store.session_has_up_job(jstr(key)) catch { _ => Json::null() }) is True
}

///|
fn P53Watch::attach(self : P53Watch) -> Unit {
  let bus = self.bus
  fork_bg(bus.host, "workspace watch", async fn() {
    let me : Ref[@jobs_host.WorkspaceWatch?] = Ref(None)
    let watch = @jobs_host.WorkspaceWatch::new(bus.host, bus.data, {
      now: () => wall_ms().to_double(),
      readings: async fn() {
        let out = []
        let sessions = bus.store.running_sessions() catch { _ => [] }
        for s in sessions {
          let key = jtext_or_empty(s, "key")
          let path = jtext_or_empty(bus_session_row(bus, key), "workspace")
          if path == "" || path == "/" || path == homedir() {
            continue
          }
          let limit = match me.val {
            Some(w) => w.limit(key, "")
            None => @jobs_host.default_limit
          }
          match self.remote.reader.size(path, limit~) {
            Some(size) => out.push(@jobs_host.WorkspaceReading::{ session: key, station: "", name: "this station", path, bytes: size.bytes, complete: size.complete })
            None => ()
          }
        }
        out
      },
      working: key => self.working(key),
      notify: async fn(session, text) {
        bus.hub_notify(session~, text~)
      },
      warn: (message, detail) => slice_log("warn", "workspace-size", message, jobj_of([("detail", jstr(detail))])),
    }) catch {
      e => {
        slice_log("warn", "workspace-size", "the workspaces' sizes are not watched", jobj_of([("error", jstr(p53_words(e)))]))
        return
      }
    }
    me.val = Some(watch)
    self.watch = Some(watch)
    ignore(self.made.succeed(()))
    (bus.previous_gone)()
    ignore(watch.start(bus.host.rt))
  })
  bus.parts.tools([self.tool()])
  // (a deleted chat's limits are forgotten by P52::on_closed via `workspaceWatch.forget`; an archived chat keeps them)
}

///|
/// A chat's soft limit set, in whole GiB (workspace-size.ts `setLimit`, through `jobs_ask`): its bytes now.
async fn P53Watch::set_limit(self : P53Watch, session : String, station : String, gib : Double) -> Double {
  self.ready().set_limit(session, station, gib)
}

///|
/// workspace-size.ts `ready`: the watch, once it has read what it keeps.
async fn P53Watch::ready(self : P53Watch) -> @jobs_host.WorkspaceWatch {
  match self.watch {
    Some(w) => w
    None => {
      ignore(self.made.wait())
      match self.watch {
        Some(w) => w
        None => raise P53Error("the workspaces' sizes are not watched")
      }
    }
  }
}

///|
/// A chat's soft limit on a station (`limit`), in bytes.
async fn P53Watch::limit(self : P53Watch, session : String, station : String) -> Double {
  self.ready().limit(session, station)
}

///|
/// workspace_limit (tools/workspace-size.ts): the MCP token supplies the chat: a caller can change only its own
/// workspace's limit on a station it has used.
fn P53Watch::tool(self : P53Watch) -> PartTool {
  p53_tool(
    self.bus,
    "workspace_limit",
    "Read or change this chat's soft workspace-size limit on one station (10 GiB by default). When a working chat exceeds its limit, the station tells its agent and repeats hourly until it cleans up or raises the limit; it never deletes files or stops work for this.",
    jobj_of([
      ("type", jstr("object")),
      (
        "properties",
        jobj_of([
          ("station", jobj_of([("type", jstr("string")), ("description", jstr("A station this chat has used for its remote workspace there, by name or id; omit for this station."))])),
          ("limit_gib", jobj_of([("type", jstr("integer")), ("minimum", ji(1)), ("description", jstr("New soft limit in whole GiB; omit to read it."))])),
        ]),
      ),
      ("additionalProperties", jb(false)),
    ]),
    async fn(session, args) {
      let named = match jtext(args, "station") {
        Some(s) => s.trim_space().to_string()
        None => ""
      }
      let station = self.remote.workspace_station(session, named)
      let watch = self.ready()
      match jfield(args, "limit_gib") {
        Null => ()
        Number(n, ..) => ignore(watch.set_limit(session, station, n))
        _ => raise P53Error("limit_gib must be a positive whole number of GiB")
      }
      jobj_of([
        ("station", jstr(if station == "" { "this station" } else { station })),
        ("limit_gib", jn(watch.limit(session, station) / @jobs_host.gib_size)),
      ]).stringify()
    },
  )
}
