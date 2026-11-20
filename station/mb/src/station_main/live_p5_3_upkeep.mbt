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
/// Shared clones untouched for this long may be reclaimed on low disk (sessions/lifecycle.ts `REPO_IDLE_MS`).
let p53_repo_idle_ms : Double = 14.0 * 24.0 * 3600000.0

///|
let p53_repo_git_timeout_ms : Int = 15000

///|
/// Orphaned session rooms older than 24 hours are removed by Upkeep (ops/storage.ts `ORPHAN_ROOM_MS`).
let p53_orphan_room_ms : Double = 24.0 * 3600000.0

///|
/// How often Upkeep scans for orphaned session rooms (once per day; also runs on the first round after startup).
let p53_orphan_room_every_ms : Double = 24.0 * 3600000.0

///|
let p53_orphan_room_max : Int = 32

///|
let p53_orphan_walk_max_ms : Double = 10000.0

///|
/// Orphaned Claude/Codex UUID transcripts older than 7 days may be reclaimed under low disk.
let p53_orphan_transcript_ms : Double = 7.0 * 24.0 * 3600000.0

///|
/// Minimum interval between full low-disk reclamation passes (30 minutes).
let p53_relieve_full_every_ms : Double = 30.0 * 60000.0

///|
let p53_orphan_transcript_max : Int = 64

///|
let p53_orphan_walk_max_entries : Int = 10000

///|
/// Time budget for a full low-disk orphan transcript scan (2 minutes); stops and logs if exceeded.
let p53_orphan_transcript_full_max_ms : Double = 2.0 * 60000.0

///|
priv struct P53Upkeep {
  bus : LiveBus
  jobs : P53Jobs
  remote : P53Remote
  mut tier : String
  mut running : Bool
  mut last_orphan_rooms_at : Double?
  mut last_full_relieve_at : Double?
}

///|
fn P53Upkeep::new(bus : LiveBus, jobs : P53Jobs, remote : P53Remote) -> P53Upkeep {
  { bus, jobs, remote, tier: "ok", running: false, last_orphan_rooms_at: None, last_full_relieve_at: None }
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
  note("repo worktrees", async fn() {
    Json::array(p53_prune_repo_worktrees(host, data).map(jstr))
  })
  let run_orphan_rooms = match self.last_orphan_rooms_at {
    None => true
    Some(last) => now - last >= p53_orphan_room_every_ms
  }
  if run_orphan_rooms {
    self.last_orphan_rooms_at = Some(now)
    note("orphan session rooms", async fn() {
      Json::array(self.prune_orphan_rooms(now).map(jstr))
    })
  }
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
    Some((left, _)) if left < p53_disk_low(total) => {
      let low = p53_disk_low(total)
      let due = match self.last_full_relieve_at {
        None => true
        Some(prev) => now - prev >= p53_relieve_full_every_ms
      }
      if due {
        ignore(bus.hub_relieve_idle_rebuildable(now, low_bytes=low, full=true) catch {
          e => {
            slice_log("warn", "hub", "cleaning rebuildable files of idle sessions failed", jobj_of([("error", jstr(p53_words(e)))]))
            Json::null()
          }
        })
        bus.hub_relieve_archived(low_bytes=low, full=true) catch {
          e => slice_log("warn", "hub", "making room on the disk failed", jobj_of([("error", jstr(p53_words(e)))]))
        }
        ignore(self.relieve_orphan_transcripts(now, low, full=true) catch {
          e => {
            slice_log("warn", "hub", "reclaiming orphan transcripts failed", jobj_of([("error", jstr(p53_words(e)))]))
            []
          }
        })
        ignore(self.relieve_repos(now, low, full=true) catch {
          e => {
            slice_log("warn", "hub", "reclaiming unused shared clones failed", jobj_of([("error", jstr(p53_words(e)))]))
            []
          }
        })
        self.last_full_relieve_at = Some(wall_ms().to_double())
      }
    }
    _ => ()
  }
  jobj_of([("tier", jstr(self.tier)), ("free", jn(free)), ("total", jn(total))])
}

///|
fn p53_inside(path : String, dir : String) -> Bool {
  path != dir && path.has_prefix(dir + sep())
}

///|
fn p53_safe_url(url : String) -> String {
  match url.find("://") {
    None => url
    Some(scheme_end) => {
      let scheme = url[:scheme_end + 3].to_owned()
      let rest = url[scheme_end + 3:].to_owned()
      let slash = rest.find("/").unwrap_or(rest.length())
      let auth = rest[:slash].to_owned()
      match auth.rev_find("@") {
        None => url
        Some(at) => {
          let lower = scheme.to_lower()
          if lower == "http://" || lower == "https://" {
            scheme + rest[at + 1:].to_owned()
          } else {
            let user_part = auth[:at].to_owned()
            match user_part.find(":") {
              Some(colon) => scheme + user_part[:colon].to_owned() + "@" + rest[at + 1:].to_owned()
              None => url
            }
          }
        }
      }
    }
  }
}

///|
/// Removes stale, unlocked git worktree registrations in `<data>/repos/*/.git/worktrees/*`
/// whose literal `gitdir` target lies under `<data>/sessions` and no longer exists (ops/storage.ts `pruneRepoWorktrees`).
async fn p53_prune_repo_worktrees(host : @host.Host, data : String) -> Array[String] {
  guard p53_realpath(host, @nodepath.join(sep(), [data, "repos"])) is Some(real_repos) else { return [] }
  let raw_sessions = @nodepath.join(sep(), [data, "sessions"])
  let real_sessions = p53_realpath(host, raw_sessions)
  let gone : Array[String] = []
  for repo_name in p53_names(host, real_repos) {
    if repo_name.has_prefix(".") {
      continue
    }
    let repo_path = @nodepath.join(sep(), [real_repos, repo_name])
    if jtext(p53_lstat(host, repo_path), "kind") != Some("dir") {
      continue
    }
    let wt_root = @nodepath.join(sep(), [repo_path, ".git", "worktrees"])
    if jtext(p53_lstat(host, wt_root), "kind") != Some("dir") {
      continue
    }
    for wt_name in p53_names(host, wt_root) {
      let admin_dir = @nodepath.join(sep(), [wt_root, wt_name])
      if jtext(p53_lstat(host, admin_dir), "kind") != Some("dir") {
        continue
      }
      if jtext(p53_lstat(host, @nodepath.join(sep(), [admin_dir, "locked"])), "kind") is Some(_) {
        continue
      }
      let raw_target = (host.read_text(@nodepath.join(sep(), [admin_dir, "gitdir"])) catch { _ => None })
        .unwrap_or("")
        .trim()
        .to_string()
      if raw_target == "" || !@nodepath.is_absolute(sep(), raw_target) {
        continue
      }
      let target = @nodepath.join(sep(), [raw_target])
      let under = p53_inside(target, raw_sessions) ||
        (match real_sessions {
          Some(rs) => p53_inside(target, rs)
          None => false
        })
      if !under {
        continue
      }
      if jtext(p53_lstat(host, target), "kind") is Some(_) {
        continue
      }
      p53_remove(host, admin_dir)
      if jtext(p53_lstat(host, admin_dir), "kind") is None {
        gone.push(repo_name + "/" + wt_name)
      }
    }
  }
  gone
}

///|
async fn p53_run_repo_git(host : @host.Host, dir : String, args : Array[String]) -> (Bool, String) {
  let pairs = [
    ("GIT_TERMINAL_PROMPT", "0"),
    ("GIT_SSH_COMMAND", "ssh -oBatchMode=yes -oStrictHostKeyChecking=accept-new"),
  ]
  let git = find_command("git", pairs).unwrap_or("git")
  let full = ["-C", dir] + args
  let proc = spawn(host, git, full, env=pairs, stdout=Piped, stderr=Ignored) catch {
    _ => return (false, "")
  }
  let late = Ref(false)
  let killer = host.rt.fork(name="repo git check deadline", async fn() {
    @effect.sleep(p53_repo_git_timeout_ms) // timer: a deadline to a process (git check given p53_repo_git_timeout_ms at most)
    late.val = true
    ignore(kill(proc.pid, "SIGKILL"))
  })
  let (code, _, out, _) = proc.finished()
  killer.interrupt()
  (!late.val && code == Some(0), @utf8.decode_lossy(out))
}

///|
async fn p53_repo_last_touched_ms(host : @host.Host, repo_path : String) -> Double? {
  let mut latest : Double? = None
  for rel in [".git/HEAD", ".git/FETCH_HEAD", ".git/index", ".git/logs/HEAD"] {
    let p = @nodepath.join(sep(), [repo_path, rel])
    match (try { Ok(host.shell("fs.meta", { "path": Json::string(p) })) } catch { e => Err(e) }) {
      Ok((m, _)) =>
        match jnum_of(m, "mtimeMs") {
          Some(at) =>
            match latest {
              None => latest = Some(at)
              Some(cur) if at > cur => latest = Some(at)
              _ => ()
            }
          None => ()
        }
      Err(_) => ()
    }
  }
  latest
}

fn p53_is_recoverable_remote_url(raw : String) -> Bool {
  let url = raw.trim().to_owned()
  if url == "" {
    return false
  }
  let lower = url.to_lower()
  if lower.has_prefix("file:") ||
    url.has_prefix("/") ||
    url.has_prefix("./") ||
    url.has_prefix("../") ||
    url == "." ||
    url == ".." ||
    url.has_prefix("\\\\") {
    return false
  }
  // Windows drive path (e.g. C:\foo or C:/foo)
  if url.length() >= 3 && url.unsafe_charcode_at(1) == ':' &&
    (url.unsafe_charcode_at(2) == '\\' || url.unsafe_charcode_at(2) == '/') {
    return false
  }
  if lower.has_prefix("https://") || lower.has_prefix("http://") || lower.has_prefix("ssh://") || lower.has_prefix("git://") {
    return match url.find("://") {
      Some(i) => {
        let rest = url[i + 3:].to_owned()
        match rest.find("/") {
          Some(s) => s > 0 && s + 1 < rest.length()
          None => false
        }
      }
      None => false
    }
  }
  // SCP-style user@host:path
  match (url.find("@"), url.find(":")) {
    (Some(at), Some(colon)) if at > 0 && colon > at + 1 && colon + 1 < url.length() =>
      !url[colon + 1:].to_owned().has_prefix(":")
    _ => false
  }
}

///|
/// Strictly reads a JSON object file: None if absent, Some(Ok(map)) if valid object, Some(Err(())) if present but
/// unreadable or invalid JSON / non-object (so callers fail closed).
async fn p53_read_json_object_strict(host : @host.Host, path : String) -> Result[Map[String, Json], Unit]? {
  if jtext(p53_lstat(host, path), "kind") is None {
    return None
  }
  match (host.read_text(path) catch { _ => None }) {
    None => Some(Err(()))
    Some(text) => {
      let parsed = @json.parse(text) catch { _ => return Some(Err(())) }
      match parsed {
        Object(m) => Some(Ok(m))
        _ => Some(Err(()))
      }
    }
  }
}

///|
/// Reclaims unreferenced shared clones in `<data>/repos` when disk is below `low` (when `full` is true, reclaims
/// all eligible clones without stopping early when `free >= low`).
async fn P53Upkeep::relieve_repos(self : P53Upkeep, now : Double, low : Double, full? : Bool = false) -> Array[String] {
  let bus = self.bus
  let host = bus.host
  let data = bus.data
  let below_low = () => match disk_of(data) {
    Some((free, _)) => free < low
    None => false
  }
  if !full && !below_low() {
    return []
  }
  if bus.hub_clones_active() {
    return []
  }
  ignore(p53_prune_repo_worktrees(host, data))
  let raw_repos = @nodepath.join(sep(), [data, "repos"])
  guard p53_realpath(host, raw_repos) is Some(real_repos) else { return [] }

  // Gather referenced paths: presets across all workspaces, all session rows (plus preset copies of unarchived
  // sessions), active jobs, move/repos.json. Fail closed if any reference file exists but is unreadable or invalid.
  let refs : Array[String] = []
  let add_ref = async fn(p : String) {
    if p == "" {
      return
    }
    let norm = @nodepath.join(sep(), [p])
    if !refs.contains(norm) {
      refs.push(norm)
    }
    match p53_realpath(host, p) {
      Some(r) if !refs.contains(r) => refs.push(r)
      _ => ()
    }
  }
  let agent_home = bus_agent_home(bus)
  let preset_homes : Array[String] = [agent_home]
  let ws_dir = @nodepath.join(sep(), [agent_home, "workspaces"])
  for ws in p53_names(host, ws_dir) {
    let p = @nodepath.join(sep(), [ws_dir, ws])
    if jtext(p53_lstat(host, p), "kind") == Some("dir") {
      preset_homes.push(p)
    }
  }
  for home in preset_homes {
    match p53_read_json_object_strict(host, @nodepath.join(sep(), [home, "presets.json"])) {
      None => ()
      Some(Err(_)) => return []
      Some(Ok(m)) =>
        match m.get("presets") {
          None | Some(Null) => ()
          Some(Array(presets)) =>
            for preset in presets {
              for d in jitems(jfield(preset, "dirs")) {
                match jtext(d, "path") {
                  Some(p) => add_ref(p)
                  None => ()
                }
              }
            }
          Some(_) => return []
        }
    }
  }
  let mut after_key = ""
  while true {
    let page = bus.store.session_paths_page(Json::string(after_key), 200) catch { _ => return [] }
    if page.length() == 0 {
      break
    }
    for row in page {
      let ws = jtext(row, "workspace").unwrap_or("")
      if ws != "" {
        add_ref(ws)
      }
      match jtext(row, "cwd") {
        Some(c) => add_ref(c)
        None => ()
      }
      if ws != "" && jfield(row, "archivedAt") == Json::null() {
        match p53_read_json_object_strict(host, @nodepath.join(sep(), [ws, @session_chats.copy_file])) {
          None => ()
          Some(Err(_)) => return []
          Some(Ok(m)) =>
            match m.get("dirs") {
              Some(Array(dirs)) =>
                for d in dirs {
                  let elsewhere = jtext(d, "elsewhere").unwrap_or("")
                  if elsewhere == "" {
                    match jtext(d, "path") {
                      Some(p) => add_ref(p)
                      None => ()
                    }
                  }
                }
              _ => ()
            }
        }
      }
      after_key = jtext(row, "key").unwrap_or(after_key)
    }
  }
  let jobs_up = bus.store.jobs_up() catch { _ => return [] }
  for job in jobs_up {
    match jtext(job, "cwd") {
      Some(c) => add_ref(c)
      None => ()
    }
  }
  match p53_read_json_object_strict(host, @nodepath.join(sep(), [data, "move", "repos.json"])) {
    None => ()
    Some(Err(_)) => return []
    Some(Ok(m)) =>
      for _, entry in m {
        match jtext(entry, "dir") {
          Some(d) => add_ref(d)
          None => ()
        }
      }
  }

  let candidates : Array[(String, String, Double)] = []
  for name in p53_names(host, real_repos) {
    if name.has_prefix(".") {
      continue
    }
    let repo_path = @nodepath.join(sep(), [real_repos, name])
    let raw_path = @nodepath.join(sep(), [raw_repos, name])
    if jtext(p53_lstat(host, repo_path), "kind") != Some("dir") {
      continue
    }
    if !p53_worktrees_empty(host, repo_path) {
      continue
    }
    if refs.iter().any(r => p53_within(repo_path, r) || p53_within(raw_path, r)) {
      continue
    }
    match p53_repo_last_touched_ms(host, repo_path) {
      Some(at) if now - at >= p53_repo_idle_ms => candidates.push((name, repo_path, at))
      _ => ()
    }
  }
  candidates.sort_by((a, b) => a.2.compare(b.2))

  let removed : Array[String] = []
  for cand in candidates {
    if (!full && !below_low()) || bus.hub_clones_active() {
      break
    }
    let (name, repo_path, orig_mtime) = cand
    let (rem_ok, rem_out) = p53_run_repo_git(host, repo_path, ["remote"])
    if !rem_ok {
      continue
    }
    let remotes : Array[String] = rem_out
      .split("\n")
      .map(s => s.trim().to_owned())
      .filter(s => s != "")
      .collect()
    if remotes.length() == 0 {
      continue
    }
    let primary = if remotes.contains("origin") { "origin" } else { remotes[0] }
    let (url_ok, url_out) = p53_run_repo_git(host, repo_path, ["remote", "get-url", primary])
    let remote_url = url_out.trim().to_owned()
    if !url_ok || !p53_is_recoverable_remote_url(remote_url) {
      continue
    }
    let (rev_ok, rev_out) = p53_run_repo_git(host, repo_path, ["rev-list", "--count", "--all", "HEAD", "--not", "--remotes"])
    if !rev_ok || rev_out.trim().to_owned() != "0" {
      continue
    }
    let (stash_ok, stash_out) = p53_run_repo_git(host, repo_path, ["for-each-ref", "refs/stash"])
    if !stash_ok || stash_out.trim().to_owned() != "" {
      continue
    }
    let (status_ok, status_out) = p53_run_repo_git(host, repo_path, ["--no-optional-locks", "status", "--porcelain", "--untracked-files=normal"])
    if !status_ok || status_out != "" {
      continue
    }
    // Re-check worktrees (fail closed on read error) and mtime right before deletion.
    if !p53_worktrees_empty(host, repo_path) {
      continue
    }
    if p53_repo_last_touched_ms(host, repo_path) != Some(orig_mtime) {
      continue
    }
    if (!full && !below_low()) || bus.hub_clones_active() {
      break
    }
    let (freed, _, _) = @ops_platform.tree_bytes(@ops_platform.Fs::new(host), repo_path, 1_000_000, () => wall_ms().to_double()) catch {
      _ => (0.0, 0, false)
    }
    p53_remove(host, repo_path)
    slice_log(
      "info",
      "hub",
      "reclaimed unused shared clone",
      jobj_of([("path", jstr(repo_path)), ("remote", jstr(p53_safe_url(remote_url))), ("freed", jn(freed))]),
    )
    removed.push(name)
  }
  removed
}

///|
/// Whether `<repo>/.git/worktrees` is absent or empty. Fails closed (returns false) on any read error so
/// `relieve_repos` skips the clone if `.git/worktrees` cannot be read.
async fn p53_worktrees_empty(host : @host.Host, repo_path : String) -> Bool {
  let wt_root = @nodepath.join(sep(), [repo_path, ".git", "worktrees"])
  if jtext(p53_lstat(host, wt_root), "kind") is None {
    return true
  }
  match host_readdir_names(host, wt_root) {
    Some(names) => names.length() == 0
    None => false
  }
}

///|
/// Whether any incoming handover (`<data>/replica/handover/in/*.json`) is currently in `coming` state.
async fn p53_has_incoming_handover(host : @host.Host, data : String) -> Bool {
  let in_dir = @nodepath.join(sep(), [data, "replica", "handover", "in"])
  for name in p53_names(host, in_dir) {
    if !name.has_suffix(".json") {
      continue
    }
    match p53_read_json_object_strict(host, @nodepath.join(sep(), [in_dir, name])) {
      None => ()
      Some(Err(_)) => return true
      Some(Ok(m)) =>
        if m.get("step") == Some(Json::string("coming")) {
          return true
        }
    }
  }
  false
}

///|
/// Removes orphaned `<data>/sessions/<connect>/<room>` directories older than `p53_orphan_room_ms` (24h)
/// that have no session row's workspace and no active job's cwd inside (ops/storage.ts `pruneOrphanRooms`).
async fn P53Upkeep::prune_orphan_rooms(self : P53Upkeep, now : Double) -> Array[String] {
  let bus = self.bus
  let host = bus.host
  let data = bus.data
  if p53_has_incoming_handover(host, data) {
    return []
  }
  let raw_sessions = @nodepath.join(sep(), [data, "sessions"])
  guard p53_realpath(host, raw_sessions) is Some(real_sessions) else { return [] }

  // Map every session workspace to its parent room directory (literal + realpath) for O(1) Set lookup;
  // keep active jobs' cwds in a small array for `p53_within` checks.
  let room_refs : Set[String] = Set::new()
  let job_cwds : Array[String] = []
  let add_room_ref = async fn(ws : String) {
    if ws == "" {
      return
    }
    let room = @nodepath.join(sep(), [@nodepath.dirname(sep(), ws)])
    room_refs.add(room)
    match p53_realpath(host, room) {
      Some(r) => room_refs.add(r)
      None => ()
    }
  }
  let mut after_key = ""
  while true {
    let page = bus.store.session_paths_page(Json::string(after_key), 200) catch { _ => return [] }
    if page.length() == 0 {
      break
    }
    for row in page {
      let ws = jtext(row, "workspace").unwrap_or("")
      if ws != "" {
        add_room_ref(ws)
      }
      after_key = jtext(row, "key").unwrap_or(after_key)
    }
  }
  let jobs_up = bus.store.jobs_up() catch { _ => return [] }
  for job in jobs_up {
    match jtext(job, "cwd") {
      Some(c) if c != "" => {
        job_cwds.push(@nodepath.join(sep(), [c]))
        match p53_realpath(host, c) {
          Some(r) => job_cwds.push(r)
          None => ()
        }
      }
      _ => ()
    }
  }

  let deadline = wall_ms().to_double() + p53_orphan_walk_max_ms
  let gone : Array[String] = []
  let cold_fs = p52_cold_files(bus)
  for connect in p53_names(host, real_sessions) {
    if gone.length() >= p53_orphan_room_max || wall_ms().to_double() >= deadline {
      break
    }
    if connect.has_prefix(".") {
      continue
    }
    let connect_path = @nodepath.join(sep(), [real_sessions, connect])
    if jtext(p53_lstat(host, connect_path), "kind") != Some("dir") {
      continue
    }
    for room in p53_names(host, connect_path) {
      if gone.length() >= p53_orphan_room_max || wall_ms().to_double() >= deadline {
        break
      }
      if room.has_prefix(".") {
        continue
      }
      let room_path = @nodepath.join(sep(), [connect_path, room])
      let raw_room_path = @nodepath.join(sep(), [raw_sessions, connect, room])
      let room_st = p53_lstat(host, room_path)
      if jtext(room_st, "kind") != Some("dir") {
        continue
      }
      let room_mtime = jnum_of(room_st, "mtimeMs").unwrap_or(now)
      let ws_mtime = jnum_of(p53_lstat(host, @nodepath.join(sep(), [room_path, "workspace"])), "mtimeMs").unwrap_or(0.0)
      let mtime = if ws_mtime > room_mtime { ws_mtime } else { room_mtime }
      if now - mtime < p53_orphan_room_ms {
        continue
      }
      if room_refs.contains(room_path) || room_refs.contains(raw_room_path) {
        continue
      }
      if job_cwds.iter().any(c => p53_within(room_path, c) || p53_within(raw_room_path, c)) {
        continue
      }
      let worktrees = cold_fs.collect_worktree_registrations(room_path) catch { _ => [] }
      cold_fs.unlock_worktrees(room_path) catch { _ => () }
      let removed = try {
        cold_fs.remove_tree(room_path, force=true)
        true
      } catch {
        _ => false
      }
      if removed {
        if worktrees.length() > 0 {
          let room_paths = if raw_room_path == room_path { [room_path] } else { [room_path, raw_room_path] }
          ignore(cold_fs.remove_worktree_registrations(worktrees, room_paths) catch { _ => [] })
        }
        gone.push("\{connect}/\{room}")
      }
    }
  }
  gone
}

///|
fn p53_is_hex(c : Int) -> Bool {
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

///|
fn p53_is_uuid(s : String) -> Bool {
  if s.length() != 36 {
    return false
  }
  for i = 0; i < 36; i = i + 1 {
    let c = s.unsafe_charcode_at(i)
    if i == 8 || i == 13 || i == 18 || i == 23 {
      if c != '-' {
        return false
      }
    } else if !p53_is_hex(c) {
      return false
    }
  }
  true
}

///|
/// Claude transcript candidate: after stripping `.zst` and `.jsonl`, stem must be an exact UUID.
fn p53_claude_uuid_id(name : String) -> String? {
  let base = if name.has_suffix(".zst") { name[:name.length() - 4].to_owned() } else { name }
  if !base.has_suffix(".jsonl") {
    return None
  }
  let stem = base[:base.length() - 6].to_owned()
  if p53_is_uuid(stem) {
    Some(stem)
  } else {
    None
  }
}

///|
/// Codex rollout candidate: `<uuid>.jsonl(.zst)` or `...-<uuid>.jsonl(.zst)`.
fn p53_codex_uuid_id(name : String) -> String? {
  let base = if name.has_suffix(".zst") { name[:name.length() - 4].to_owned() } else { name }
  if !base.has_suffix(".jsonl") {
    return None
  }
  let stem = base[:base.length() - 6].to_owned()
  if stem.length() == 36 && p53_is_uuid(stem) {
    return Some(stem)
  }
  if stem.length() > 37 && stem.unsafe_charcode_at(stem.length() - 37) == '-' {
    let cand = stem[stem.length() - 36:].to_owned()
    if p53_is_uuid(cand) {
      return Some(cand)
    }
  }
  None
}

///|
/// Bounded scan of a directory's newest mtime and total bytes. Returns None if truncated or unreadable
/// (treated as too fresh, never deleted).
async fn p53_bounded_dir_age_bytes(host : @host.Host, dir : String, deadline : Double) -> (Double, Double)? {
  let root_st = p53_lstat(host, dir)
  if jtext(root_st, "kind") != Some("dir") {
    return None
  }
  let mut newest = jnum_of(root_st, "mtimeMs").unwrap_or(0.0)
  let mut bytes = 0.0
  let queue : Array[(String, Int)] = [(dir, 0)]
  let mut qi = 0
  let mut visited = 0
  while qi < queue.length() {
    if visited >= 2000 || wall_ms().to_double() >= deadline {
      return None
    }
    let (cur, depth) = queue[qi]
    qi += 1
    let names = match host_readdir_names(host, cur) {
      Some(ns) => ns
      None => return None
    }
    for n in names {
      visited += 1
      if visited >= 2000 || wall_ms().to_double() >= deadline {
        return None
      }
      let p = @nodepath.join(sep(), [cur, n])
      let st = p53_lstat(host, p)
      let kind = jtext(st, "kind")
      if kind is None {
        return None
      }
      let m = jnum_of(st, "mtimeMs").unwrap_or(0.0)
      if m > newest {
        newest = m
      }
      if kind == Some("file") {
        let blocks = jnum_of(st, "blocks")
        bytes += match blocks {
          Some(b) if b >= 0.0 => b * 512.0
          _ => jnum_of(st, "size").unwrap_or(0.0)
        }
      } else if kind == Some("dir") {
        if depth >= 16 {
          return None
        }
        queue.push((p, depth + 1))
      }
    }
  }
  Some((newest, bytes))
}

///|
/// Low-disk reclamation of orphaned Claude (`<uuid>.jsonl(.zst)` + companion `<uuid>/`, or standalone `<uuid>/`
/// with no sibling `.jsonl(.zst)`) and Codex (`-<uuid>.jsonl(.zst)`) transcripts under `<data>` older than 7 days
/// (ops/storage.ts `relieveOrphanTranscripts`). Never deletes non-UUID files or directories (e.g. `memory/`).
async fn P53Upkeep::relieve_orphan_transcripts(
  self : P53Upkeep,
  now : Double,
  low : Double,
  full? : Bool = false,
) -> Array[String] {
  let bus = self.bus
  let host = bus.host
  let data = bus.data
  let below_low = () => match disk_of(data) {
    Some((free, _)) => free < low
    None => false
  }
  if !full && !below_low() {
    return []
  }
  guard p53_realpath(host, data) is Some(real_data) else { return [] }

  let budget_ms = if full { p53_orphan_transcript_full_max_ms } else { p53_orphan_walk_max_ms }
  let deadline = wall_ms().to_double() + budget_ms
  let gone : Array[String] = []
  let mut timed_out = false
  let mut visited = 0
  let check_deadline = () => {
    if wall_ms().to_double() >= deadline {
      timed_out = true
      true
    } else {
      false
    }
  }
  let hit_entries = () => !full && visited >= p53_orphan_walk_max_entries
  let hit_limit = () => !full && gone.length() >= p53_orphan_transcript_max
  let done_now = () => hit_limit() || check_deadline() || (!full && !below_low())

  let claude_roots : Array[String] = []
  let codex_roots : Array[String] = []
  let transcripts_dir = @nodepath.join(sep(), [real_data, "transcripts"])
  for name in p53_names(host, transcripts_dir) {
    if name != "claude" && name != "codex" {
      continue
    }
    let p = @nodepath.join(sep(), [transcripts_dir, name])
    if jtext(p53_lstat(host, p), "kind") != Some("dir") {
      continue
    }
    if name == "claude" {
      claude_roots.push(p)
    } else {
      codex_roots.push(p)
    }
  }

  let homes_dir = @nodepath.join(sep(), [real_data, "homes"])
  for home_name in p53_names(host, homes_dir) {
    if home_name.has_prefix(".") {
      continue
    }
    let home_path = @nodepath.join(sep(), [homes_dir, home_name])
    if jtext(p53_lstat(host, home_path), "kind") != Some("dir") {
      continue
    }
    guard p53_realpath(host, home_path) is Some(real_home) else { continue }
    if !p53_within(real_data, real_home) || real_home == real_data {
      continue
    }
    let proj = @nodepath.join(sep(), [real_home, "projects"])
    if jtext(p53_lstat(host, proj), "kind") == Some("dir") {
      claude_roots.push(proj)
    }
    let sess = @nodepath.join(sep(), [real_home, "sessions"])
    if jtext(p53_lstat(host, sess), "kind") == Some("dir") {
      codex_roots.push(sess)
    }
  }

  let safe_inside_data = async fn(p : String) -> Bool {
    let kind = jtext(p53_lstat(host, p), "kind")
    if kind != Some("file") && kind != Some("dir") {
      return false
    }
    match p53_realpath(host, p) {
      Some(r) => p53_within(real_data, r) && r != real_data
      None => false
    }
  }
  let rel_of = (p : String) => {
    let prefix = real_data + sep()
    if p.has_prefix(prefix) {
      p[prefix.length():].to_owned()
    } else {
      p
    }
  }

  // 1. Claude roots: <root>/<proj>/<uuid>.jsonl(.zst) + companion <uuid>/, or standalone <uuid>/ without main file.
  for root in claude_roots {
    if done_now() || hit_entries() {
      break
    }
    for proj in p53_names(host, root) {
      if done_now() || hit_entries() {
        break
      }
      if proj.has_prefix(".") {
        continue
      }
      let proj_path = @nodepath.join(sep(), [root, proj])
      if jtext(p53_lstat(host, proj_path), "kind") != Some("dir") {
        continue
      }
      let files : Array[(String, String, Double, Double)] = []
      let uuid_dirs : Array[(String, String)] = []
      let main_present : Set[String] = Set::new()
      for entry in p53_names(host, proj_path) {
        if hit_entries() || check_deadline() {
          break
        }
        visited += 1
        let p = @nodepath.join(sep(), [proj_path, entry])
        let st = p53_lstat(host, p)
        match jtext(st, "kind") {
          Some("file") =>
            match p53_claude_uuid_id(entry) {
              Some(cid) => {
                main_present.add(cid)
                let mtime = jnum_of(st, "mtimeMs").unwrap_or(now)
                let bytes = match jnum_of(st, "blocks") {
                  Some(b) if b >= 0.0 => b * 512.0
                  _ => jnum_of(st, "size").unwrap_or(0.0)
                }
                files.push((p, cid, mtime, bytes))
              }
              None => ()
            }
          Some("dir") if p53_is_uuid(entry) => uuid_dirs.push((p, entry))
          _ => ()
        }
      }
      for f in files {
        if done_now() {
          break
        }
        let (p, cid, mtime, bytes) = f
        if now - mtime < p53_orphan_transcript_ms {
          continue
        }
        let referenced = bus.store.transcript_referenced(Json::string("claude"), Json::string(cid), Json::string("")) catch { _ => return gone }
        if referenced || !safe_inside_data(p) {
          continue
        }
        p53_remove(host, p)
        if jtext(p53_lstat(host, p), "kind") is None {
          let rp = rel_of(p)
          slice_log("info", "hub", "reclaimed orphan transcript", jobj_of([("path", jstr(rp)), ("runtime", jstr("claude")), ("bytes", jn(bytes))]))
          gone.push(rp)
          let comp = @nodepath.join(sep(), [proj_path, cid])
          if safe_inside_data(comp) {
            match p53_bounded_dir_age_bytes(host, comp, deadline) {
              Some((newest, dbytes)) if now - newest >= p53_orphan_transcript_ms => {
                p53_remove(host, comp)
                if jtext(p53_lstat(host, comp), "kind") is None {
                  slice_log("info", "hub", "reclaimed orphan transcript", jobj_of([("path", jstr(rel_of(comp))), ("runtime", jstr("claude")), ("bytes", jn(dbytes))]))
                }
              }
              _ => ()
            }
          }
        }
      }
      for d in uuid_dirs {
        if done_now() {
          break
        }
        let (p, cid) = d
        if main_present.contains(cid) {
          continue
        }
        let referenced = bus.store.transcript_referenced(Json::string("claude"), Json::string(cid), Json::string("")) catch { _ => return gone }
        if referenced || !safe_inside_data(p) {
          continue
        }
        match p53_bounded_dir_age_bytes(host, p, deadline) {
          Some((newest, dbytes)) if now - newest >= p53_orphan_transcript_ms => {
            p53_remove(host, p)
            if jtext(p53_lstat(host, p), "kind") is None {
              let rp = rel_of(p)
              slice_log("info", "hub", "reclaimed orphan transcript", jobj_of([("path", jstr(rp)), ("runtime", jstr("claude")), ("bytes", jn(dbytes))]))
              gone.push(rp)
            }
          }
          _ => ()
        }
      }
    }
  }

  // 2. Codex roots: BFS up to depth 6 for *-<uuid>.jsonl(.zst)
  for root in codex_roots {
    if done_now() || hit_entries() {
      break
    }
    let queue : Array[(String, Int)] = [(root, 0)]
    let mut qi = 0
    while qi < queue.length() && !done_now() && !hit_entries() {
      let (dir, depth) = queue[qi]
      qi += 1
      for entry in p53_names(host, dir) {
        if done_now() || hit_entries() {
          break
        }
        visited += 1
        let p = @nodepath.join(sep(), [dir, entry])
        let st = p53_lstat(host, p)
        match jtext(st, "kind") {
          Some("dir") if depth < 6 && !entry.has_prefix(".") => queue.push((p, depth + 1))
          Some("file") => {
            let mtime = jnum_of(st, "mtimeMs").unwrap_or(now)
            if now - mtime < p53_orphan_transcript_ms {
              continue
            }
            guard p53_codex_uuid_id(entry) is Some(cid) else { continue }
            let referenced = bus.store.transcript_referenced(Json::string("codex"), Json::string(cid), Json::string("")) catch { _ => return gone }
            if referenced || !safe_inside_data(p) {
              continue
            }
            let bytes = match jnum_of(st, "blocks") {
              Some(b) if b >= 0.0 => b * 512.0
              _ => jnum_of(st, "size").unwrap_or(0.0)
            }
            p53_remove(host, p)
            if jtext(p53_lstat(host, p), "kind") is None {
              let rp = rel_of(p)
              slice_log("info", "hub", "reclaimed orphan transcript", jobj_of([("path", jstr(rp)), ("runtime", jstr("codex")), ("bytes", jn(bytes))]))
              gone.push(rp)
            }
          }
          _ => ()
        }
      }
    }
  }

  if full && timed_out {
    slice_log("info", "hub", "orphan transcript full scan reached time budget before finishing", jobj_of([("reclaimed", ji(gone.length())), ("budgetMs", jn(budget_ms))]))
  }
  gone
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
