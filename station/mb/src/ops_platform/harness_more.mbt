// The harness's cases of the later parts: what resources, search and read work out (`more_case`), and what reads and
// writes files through the shell (`io_case`).

///|
fn more_case(c : Json) -> Json raise {
  let f = str_or(c, "fn", "")
  let s = (name : String) => str_or(c, name, "")
  let n = (name : String) => num_field(c, name).unwrap_or(0.0)
  let onum = (name : String) => match field(c, name) {
    Some(Number(v, ..)) => Some(v)
    _ => None
  }
  match f {
    // storage.ts
    "storageManifest" => Json::array(storage_manifest.map(e => e.to_json()))
    "storageEntry" =>
      match storage_entry(s("name")) {
        Some(e) => e.to_json()
        None => Json::null()
      }
    "rotatePlan" => opt_n(rotate_plan(n("size"), n("cap"), n("keep")))
    "keepNewestPlan" => {
      let dated = match field(c, "dated") {
        Some(Array(a)) => a.map(d => (str_or(d, "n", ""), num_field(d, "at").unwrap_or(0.0)))
        _ => []
      }
      jstrs(keep_newest_plan(dated, int_field(c, "kept", 0)))
    }
    "capPlan" => {
      let files = match field(c, "files") {
        Some(Array(a)) => a.map(d => (str_or(d, "path", ""), num_field(d, "bytes").unwrap_or(0.0), num_field(d, "at").unwrap_or(0.0)))
        _ => []
      }
      let (gone, freed) = cap_plan(files, n("max"))
      { "gone": jstrs(gone), "freed": jn(freed) }
    }
    "upkeepSaid" => match upkeep_said(field(c, "did").unwrap_or(Json::null())) {
      Some(j) => j
      None => Json::null()
    }
    "upkeepRound" => jstrs(upkeep_round(bool_field(c, "runners"), bool_field(c, "jobs"), bool_field(c, "remote"), bool_field(c, "checkpoint")))
    "walPast" => jb(wal_past(onum("size")))
    // places.ts
    "placeRefused" =>
      js(
        place_refused(the_catalog(), s("code"), s("path"), s("lang"), bool_field(c, "agent"), n("timeoutMs"), s("machine"), (lang, path) => unreadable_dir_message(
          the_catalog(),
          lang,
          path,
          strs(field(c, "argv")),
          bool_field(c, "folderPermissions"),
          posix_join,
        )),
      )
    "placeNeeds" =>
      js(place_needs(the_catalog(), s("grant"), s("top"), s("window"), s("path"), s("lang"), bool_field(c, "agent"), s("machine")))
    "placeDirAnswer" =>
      match place_answer(s("stdout")) {
        None => { "error": js("couldn't check \{s("dir")}: no answer") }
        Some(a) =>
          match place_dir_answer(a, s("dir")) {
            Ok(l) => { "ok": l.to_json() }
            Err(e) => { "error": js(e) }
          }
      }
    "placeCopyAnswer" => js(match place_answer(s("stdout")) {
      Some(a) => place_copy_answer(a)
      None => "error"
    })
    "placeMachine" => js(place_machine(s("hostname")))
    "placeLookKey" => js(place_look_key(s("path"), s("lang"), bool_field(c, "agent"), bool_field(c, "self")))
    // shell-path.ts
    "probeEnv" => env_json(probe_env(env_of(field(c, "env"))))
    "shellProbeArgs" => jstrs(shell_probe_args(bool_field(c, "login")))
    "shellPathOf" =>
      match shell_path_of(s("output"), s("marker"), int_field(c, "code", 0)) {
        Some(a) => jstrs(a)
        None => Json::null()
      }
    "shellKeptKey" => js(shell_kept_key(match field(c, "parts") { Some(Array(a)) => a; _ => [] }, env_of(field(c, "env"))))
    "withShellCommand" => {
      let has_in = strs(field(c, "has"))
      let found = (e : Array[(String, String)]) => split_on(env_get(e, "PATH").unwrap_or(""), ":").iter().any(d => has_in.contains(d))
      let saved = match field(c, "saved") {
        Some(Array(_)) as a => Some(strs(a))
        _ => None
      }
      let shells = field(c, "shellDirs")
      env_json(
        with_shell_command(
          s("name"),
          env_of(field(c, "env")),
          found,
          saved,
          unix_append_path,
          match field(c, "shell") { Some(String(x)) => Some(x); _ => None },
          login => match shells {
            Some(Object(_) as sh) =>
              match field(sh, if login { "login" } else { "plain" }) {
                Some(Array(_)) as a => Some(strs(a))
                _ => None
              }
            _ => None
          },
          unix_prepend_path,
        ),
      )
    }
    // telemetry.ts and log-export.ts
    "scrubPaths" => js(scrub_paths(s("text"), s("home")))
    "scrubMessage" => js(scrub_message(s("text"), s("home")))
    "scrubText" => js(scrub_text(s("text"), s("home")))
    "scrubValue" => scrub_value(s("key"), field(c, "value").unwrap_or(Json::null()), s("home"))
    "attribute" => attribute(s("key"), field(c, "value").unwrap_or(Json::null()))
    "logRecord" => {
      let l = log_line_of(field(c, "line").unwrap_or(Json::null()))
      log_record(l.ms, l.level, l.at, l.message, l.fields, s("home"))
    }
    "errorEvent" =>
      error_event(
        s("log"),
        match field(c, "error") { Some(String(e)) => Some(e); _ => None },
        match field(c, "station") { Some(String(e)) => Some(e); _ => None },
        s("anonymous"),
        match field(c, "release") { Some(String(e)) => Some(e); _ => None },
        s("home"),
        n("now"),
      )
    "builtKey" => built_key(match field(c, "text") { Some(String(t)) => Some(t); _ => None })
    "logExport" => {
      let e = LogExport::new(s("home"))
      let sent = []
      for step in arr(field(c, "steps")) {
        match str_or(step, "do", "") {
          "configure" => {
            e.configured = true
            if field(step, "os") is Some(String(os)) {
              e.describe(os~, arch=str_or(step, "arch", ""), runtime=str_or(step, "runtime", ""), role=str_or(step, "role", ""))
            }
          }
          "add" => e.add(log_line_of(field(step, "line").unwrap_or(Json::null())), bool_field(step, "enabled"))
          "addMany" => {
            let l = log_line_of(field(step, "line").unwrap_or(Json::null()))
            for _ in 0..<int_field(step, "count", 0) {
              e.add(l, true)
            }
          }
          "send" => {
            let statuses = nums(field(step, "statuses"))
            let mut k = 0
            let bodies = e.send_all(
              bool_field(step, "enabled"),
              match field(step, "station") { Some(String(x)) => Some(x); _ => None },
              str_or(step, "version", ""),
              num_field(step, "now").unwrap_or(0.0),
              _ => {
                let st = statuses.get(k)
                k += 1
                match st {
                  Some(v) if v >= 0.0 => Some(v)
                  _ => None
                }
              },
            )
            sent.push(jstrs(bodies))
          }
          _ => ()
        }
      }
      { "sent": Json::array(sent), "waiting": ji(e.waiting.length()), "dropped": ji(e.dropped) }
    }
    "logRefused" => jb(log_refused(onum("status")))
    // forewarn.ts
    "forewarn" => {
      let f = Forewarn::new()
      let opt = (j : Json, k : String) => match field(j, k) {
        Some(Number(v, ..)) => Some(v)
        _ => None
      }
      Json::array(
        arr(field(c, "steps")).map(step => {
          let l = field(step, "look").unwrap_or(Json::null())
          let look : ForewarnLook = {
            disk_free: opt(l, "diskFree"),
            disk_total: opt(l, "diskTotal"),
            wal_bytes: num_field(l, "walBytes").unwrap_or(0.0),
            open_fds: opt(l, "openFds").map(n => n.to_int()),
            rss: opt(l, "rss"),
            relay_conflict: bool_field(l, "relayConflict"),
          }
          Json::array(
            f
            .look(look, num_field(step, "now").unwrap_or(0.0))
            .map(w => { "at": js(w.at), "message": js(w.message), "fields": w.fields }),
          )
        }),
      )
    }
    // self-memory.ts
    "limits" => { "soft": jn(soft_limit_of(n("total"))), "hardRss": jn(hard_rss_of(n("total"))), "hardFront": jn(hard_front_of(n("total"))) }
    "selfMemory" => {
      let m = SelfMemory::new(n("total"), n("startedAt"), field(c, "options").unwrap_or(Json::object(Map([]))))
      let out = []
      let mut trims = 0.0
      let mut evicts = 0.0
      for x in arr(field(c, "samples")) {
        let v = m.sample(
          num_field(x, "now").unwrap_or(0.0),
          num_field(x, "rss").unwrap_or(0.0),
          num_field(x, "heap").unwrap_or(0.0),
          num_field(x, "children").unwrap_or(0.0),
          match field(x, "front") { Some(Number(f, ..)) => Some(f); _ => None },
          match field(x, "pressure") { Some(String(p)) => Some(p); _ => None },
          () => {
            trims += 1.0
            trims
          },
          if bool_field(c, "evict") {
            Some(() => {
              evicts += 1.0
              evicts
            })
          } else {
            None
          },
          bool_field(c, "restartFront"),
          bool_field(c, "launcher"),
          bool_field(x, "handoverFails"),
        )
        out.push(v)
      }
      Json::array(out)
    }
    // awake.ts
    "awakeWorking" => {
      let turns = match field(c, "turns") {
        Some(Object(m)) => m
        _ => Map([])
      }
      let jobs = match field(c, "jobs") {
        Some(Array(a)) => a.map(j => (str_or(j, "sessionKey", ""), num_field(j, "startedAt").unwrap_or(0.0)))
        _ => []
      }
      jb(
        awake_working(
          bool_field(c, "anyRunning"),
          match field(c, "awakeWait") { Some(True) => Some(true); Some(False) => Some(false); _ => None },
          jobs,
          strs(field(c, "live")),
          keys => keys.filter_map(k => match turns.get(k) {
            Some(Object(_) as t) =>
              Some((
                k,
                match field(t, "declared") { Some(String(d)) => Some(d); _ => None },
                match field(t, "endedAt") { Some(Number(e, ..)) => Some(e); _ => None },
                match field(t, "waitSeconds") { Some(Number(w, ..)) => Some(w); _ => None },
              ))
            _ => None
          }),
          n("now"),
        ),
      )
    }
    "awake" => {
      let a = Awake::new()
      Json::array(
        (match field(c, "checks") { Some(Array(x)) => x; _ => [] }).map(x => opt_s(
          a.check(num_field(x, "now").unwrap_or(0.0), bool_field(x, "working"), bool_field(c, "canHold")),
        )),
      )
    }
    // heap.ts and links.ts
    "heapNames" => jstrs(heap_old_snapshots(strs(field(c, "names"))))
    "heapSnapshotPath" => js(heap_snapshot_path(s("dir"), n("now")))
    "heapCommandEnd" => {
      let (said, code) = heap_command_end(match field(c, "answer") { Some(Null) | None => None; Some(a) => Some(a) })
      Json::array([js(said), ji(code)])
    }
    "linkStandIn" =>
      js(link_stand_in(bool_field(c, "junction"), bool_field(c, "copy"), match field(c, "target") { Some(String(t)) => Some(t); _ => None }))
    _ => more_read_case(c)
  }
}

///|
/// The walk's and the follow's cases: the visit says, by an entry's path relative to its root, what to do (`skip`,
/// `stop`); the watch fails for the paths `failing` names (with their codes).
fn walk_case(fs : Fs, c : Json) -> Json raise {
  let skips = strs(field(c, "skip"))
  let stops = strs(field(c, "stop"))
  let visited = []
  let errors = []
  let crossed = []
  let o : WalkOptions = {
    ..WalkOptions::default(() => 0.0),
    same_device: match field(c, "sameDevice") { Some(False) => false; _ => true },
    max_entries: int_field(c, "maxEntries", walk_max_entries),
    max_depth: int_field(c, "maxDepth", walk_max_depth),
    stat: bool_field(c, "stat"),
    follow_root: bool_field(c, "followRoot"),
    follow_links: bool_field(c, "followLinks"),
    on_error: (p, op) => errors.push(Json::array([js(p), js(op)])),
    on_crossed: e => crossed.push(js(e.path)),
  }
  let r = walk_bounded(
    fs,
    strs(field(c, "roots")),
    e => {
      visited.push(e.to_json())
      let key = e.root + ":" + e.rel
      if stops.contains(key) {
        Stop
      } else if skips.contains(key) {
        Skip
      } else {
        Go
      }
    },
    o,
  )
  { "result": r.to_json(), "visited": Json::array(visited), "errors": Json::array(errors), "crossed": Json::array(crossed) }
}

///|
/// The config a script holds from one case to the next, and what it told meanwhile.
let held_config : Ref[ConfigFile?] = { val: None }

///|
let held_told : Array[Json] = []

///|
fn io_case(host : @host.Host, c : Json) -> Json? raise {
  let fs = Fs::new(host)
  let s = (name : String) => str_or(c, name, "")
  match str_or(c, "fn", "") {
    "walk" => Some(walk_case(fs, c))
    "follow" => {
      let into = strs(field(c, "into"))
      let failing = env_of(field(c, "failing"))
      let root = s("root")
      let tree = FollowedTree::new(root, rel => into.contains(rel), int_field(c, "most", 100), path => env_get(failing, path))
      let scans : Array[Json] = []
      for _ in 0..<int_field(c, "scans", 1) {
        let r = tree.scan(fs)
        scans.push({ "failed": opt_s(r.failed), "over": jb(r.over), "watched": jstrs(tree.watches.copy()) })
      }
      Some(Json::array(scans))
    }
    "followedChange" =>
      Some(js(followed_change(s("rel"), match field(c, "name") { Some(String(x)) => Some(x); _ => None })))
    "treeBytes" => {
      let (bytes, entries, partial) = tree_bytes(fs, s("path"), int_field(c, "most", 1000000), () => 0.0)
      Some({ "bytes": jn(bytes), "entries": ji(entries), "partial": jb(partial) })
    }
    "rotateInPlace" =>
      Some(jb(rotate_in_place(fs, s("path"), num_field(c, "cap").unwrap_or(0.0), num_field(c, "keep").unwrap_or(0.0))))
    "keepNewest" => Some(jstrs(keep_newest(fs, s("dir"), s("prefix"), int_field(c, "kept", 0))))
    "removeStale" =>
      Some(jstrs(remove_stale(fs, s("dir"), s("prefix"), num_field(c, "maxAgeMs").unwrap_or(0.0), num_field(c, "now").unwrap_or(0.0))))
    "capByAge" => Some(jn(cap_by_age(fs, s("dir"), num_field(c, "max").unwrap_or(0.0))))
    "orphanMarks" => Some(jstrs(orphan_marks(fs, s("dir"))))
    "placeFollow" | "placeWalk" => {
      let locked = env_of(field(c, "locked"))
      let helper = strs(field(c, "helper"))
      let lock = (p : String) => {
        for l in locked {
          if p == l.0 || starts(p, l.0 + "/") {
            return Some((l.1, helper.contains(l.1)))
          }
        }
        None
      }
      let look = if str_or(c, "fn", "") == "placeFollow" {
        place_follow(fs, s("path"), s("cwd"), lock)
      } else {
        place_walk(fs, s("path"), s("cwd"), lock)
      }
      Some(look.to_json())
    }
    "heapTake" => Some(jb(heap_take(fs, s("dir"), int_field(c, "pid", 0))))
    "storeReads" => {
      let db = @sql.Db::attach(host, s("db"), wait=250)
      defer db.close()
      let out : Json = {
        "session": match store_session(db, s("session")) { Some(r) => r; None => Json::null() },
        "thread": match store_thread(db, num_field(c, "thread").unwrap_or(0.0)) { Some(r) => r; None => Json::null() },
        "members": Json::array(store_thread_sessions(db, num_field(c, "thread").unwrap_or(0.0))),
        "withCards": Json::array(threads_with_cards(db, nums(field(c, "threads"))).map(jn)),
      }
      Some(out)
    }
    "searchWalk" | "transcriptOf" | "outputAt" | "logTail" | "lookAnswer" | "forgetMarks" => read_io_case(fs, c)
    "configRelease" => {
      held_config.val = None
      Some(Json::null())
    }
    "config" => {
      let refused = strs(field(c, "refuse"))
      let cfg = match held_config.val {
        Some(h) if bool_field(c, "hold") => h
        _ => {
          let made = try ConfigFile::new(fs, s("data"), match field(c, "envConfig") { Some(String(x)) => Some(x); _ => None }, s("invalid")) catch {
            e => return Some({ "error": js(err_text(e)) })
          }
          made.check = (raw, _) => {
            match raw {
              Object(m) =>
                for k in refused {
                  if m.contains(k) {
                    return Some("refused: \{k}")
                  }
                }
              _ => ()
            }
            None
          }
          made.listen(v => held_told.push(v))
          if bool_field(c, "hold") {
            held_config.val = Some(made)
          }
          made
        }
      }
      let out = []
      for step in arr(field(c, "steps")) {
        let r : Json = try {
          match str_or(step, "do", "") {
            "raw" => { "ok": cfg.raw() }
            "update" => { "ok": cfg.update(config_edit(field(step, "set").unwrap_or(Json::null()))) }
            _ => { "ok": Json::null() }
          }
        } catch {
          e => { "error": js(err_text(e)) }
        }
        out.push(r)
      }
      let told = held_told.copy()
      held_told.clear()
      Some({ "steps": Json::array(out), "told": Json::array(told) })
    }
    _ => None
  }
}
