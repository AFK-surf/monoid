// The harness's cases of resources, search and read.

///|
fn table_of(j : Json?) -> Array[ProcessInfo]? {
  match j {
    Some(Array(a)) => Some(a.map(process_info_of))
    _ => None
  }
}

///|
fn runners_of(j : Json?) -> Array[Runner] {
  match j {
    Some(Array(a)) =>
      a.map(r => {
        runner: num_field(r, "runner").unwrap_or(0.0),
        pid: num_field(r, "pid").unwrap_or(0.0),
        session: match field(r, "session") { Some(String(s)) => Some(s); _ => None },
      })
    _ => []
  }
}

///|
fn pid_pairs(j : Json?) -> Array[(Double, String)]? {
  match j {
    Some(Array(a)) =>
      Some(
        a.filter_map(x => match x {
          Array([Number(p, ..), String(l)]) => Some((p, l))
          _ => None
        }),
      )
    _ => None
  }
}

///|
/// What a case says each process is whose, as `whoseOf` is given it.
fn whose_case(c : Json, table : Array[ProcessInfo]) -> Map[Double, Whose] {
  let jobs = match field(c, "jobs") {
    Some(Array(a)) => a.map(j => (str_or(j, "session", ""), num_field(j, "pgid").unwrap_or(0.0)))
    _ => []
  }
  let apps = strs(field(c, "apps"))
  let places = match field(c, "places") {
    Some(Array(a)) => a.map(p => (str_or(p, "dir", ""), str_or(p, "session", "")))
    _ => []
  }
  let owners = match field(c, "owners") {
    Some(Object(_)) as o => Some(env_of(o))
    _ => None
  }
  whose_of(
    table,
    jobs,
    cmd => apps.iter().any(a => has(cmd, a)),
    nums(field(c, "self")),
    runners_of(field(c, "runners")),
    pid_pairs(field(c, "args")),
    () => places,
    if bool_field(c, "inArguments") {
      Some(_ => owners)
    } else {
      None
    },
  )
}

///|
fn whose_json(m : Map[Double, Whose]) -> Json {
  let out = []
  for k, w in m {
    out.push(Json::array([jn(k), { "key": js(w.key), "kind": js(w.kind), "session": opt_s(w.session) }]))
  }
  Json::array(out)
}

///|
fn more_read_case(c : Json) -> Json raise {
  let f = str_or(c, "fn", "")
  let s = (name : String) => str_or(c, name, "")
  let n = (name : String) => num_field(c, name).unwrap_or(0.0)
  match f {
    // resources
    "appBundles" => {
      let plists = env_of(field(c, "plists"))
      let b = AppBundles::new()
      jb_arr(strs(field(c, "commands")).map(cmd => b.is_app(cmd, p => env_get(plists, p))))
    }
    "parseArgs" => Json::array(parse_args(s("text")).map(p => Json::array([jn(p.0), js(p.1)])))
    "parseNettop" => Json::array(parse_nettop(s("text")).map(p => Json::array([jn(p.0), { "in": jn(p.1), "out": jn(p.2) }])))
    "programsIn" => {
      let (bytes, count) = programs_in(table_of(field(c, "table")), nums(field(c, "pids")))
      { "bytes": jn(bytes), "count": ji(count) }
    }
    "frontIn" =>
      opt_n(front_in(table_of(field(c, "table")), match field(c, "launcher") { Some(Number(l, ..)) => Some(l); _ => None }, n("self")))
    "whoseOf" => whose_json(whose_case(c, table_of(field(c, "table")).unwrap_or([])))
    "resourceLooks" => {
      let w = ResourceWatch::new()
      for look in arr(field(c, "looks")) {
        let at = num_field(look, "at").unwrap_or(0.0)
        let table = table_of(field(look, "table"))
        let whose = whose_case(look, table.unwrap_or([]))
        let runners = runners_of(field(look, "runners"))
        let own = []
        for r in runners {
          own.push(r.runner)
          own.push(r.pid)
        }
        let usage = match field(look, "usage") {
          Some(Object(_) as u) => u
          _ => Json::object(Map([]))
        }
        let traffic = match field(look, "traffic") {
          Some(Array(a)) =>
            Some(a.map(t => (num_field(t, "pid").unwrap_or(0.0), num_field(t, "in").unwrap_or(0.0), num_field(t, "out").unwrap_or(0.0))))
          _ => None
        }
        w.look(
          w.fresh(at),
          at,
          table,
          whose,
          own,
          pids => pids.map(p => match field(usage, num_text(p)) {
            Some(Object(_) as u) =>
              Some({
                cpu_ns: num_field(u, "cpuNs").unwrap_or(0.0),
                footprint: num_field(u, "footprint").unwrap_or(0.0),
                disk_read: num_field(u, "diskRead"),
                disk_written: num_field(u, "diskWritten"),
              })
            _ => None
          }),
          traffic,
        )
      }
      w.snapshot()
    }
    "endChoice" => {
      let table = table_of(field(c, "table"))
      let whose = whose_case(c, table.unwrap_or([]))
      let own = []
      for r in runners_of(field(c, "runners")) {
        own.push(r.runner)
        own.push(r.pid)
      }
      match end_choice(table, n("pid"), s("session"), whose, own) {
        Ok(name) => { "name": js(name) }
        Err(e) => { "refused": js(e) }
      }
    }
    "ticksOfStat" => opt_n(ticks_of_stat(s("text")))
    "footprintOfStatus" => opt_n(footprint_of_status(s("text")))
    "diskOfIo" =>
      match disk_of_io(s("text")) {
        Some((r, w)) => { "diskRead": jn(r), "diskWritten": jn(w) }
        None => Json::null()
      }
    "linuxUsage" =>
      linux_usage(
        match field(c, "stat") { Some(String(x)) => Some(x); _ => None },
        match field(c, "status") { Some(String(x)) => Some(x); _ => None },
        match field(c, "io") { Some(String(x)) => Some(x); _ => None },
        num_field(c, "tick").unwrap_or(1.0e7),
      )
    // search
    "spotlightQuery" => opt_s(spotlight_query(strs(field(c, "words")), bool_field(c, "content")))
    "noisy" => jb(noisy(s("path"), s("home")))
    "mdfindArgs" => jstrs(mdfind_args(s("query"), strs(field(c, "within"))))
    "mdfindPaths" => jstrs(mdfind_paths(strs(field(c, "chunks")), int_field(c, "most", 0)))
    "textName" => jb(text_name(s("name")))
    "fileHits" => {
      let stats = match field(c, "stats") {
        Some(Object(m)) => m
        _ => Map([])
      }
      file_hits(
        strs(field(c, "found")),
        strs(field(c, "words")),
        s("home"),
        bool_field(c, "writer"),
        strs(field(c, "pinned")),
        strs(field(c, "protect")),
        bool_field(c, "personal"),
        int_field(c, "limit", 8),
        bool_field(c, "left"),
        p => match stats.get(p) {
          Some(Object(_) as st) => Some((bool_field(st, "dir"), num_field(st, "size").unwrap_or(0.0), num_field(st, "at").unwrap_or(0.0)))
          _ => None
        },
      )
    }
    "spotlightAsks" => Json::array(spotlight_asks(strs(field(c, "words")), bool_field(c, "writer"), s("home"), strs(field(c, "open"))))
    "guardedTops" => jstrs(guarded_tops(bool_field(c, "writer"), s("home"), strs(field(c, "kept"))))
    "fileSearchKey" =>
      js(file_search_key(strs(field(c, "words")), s("workspace"), bool_field(c, "home"), bool_field(c, "writer"), int_field(c, "limit", 0), bool_field(c, "personal"), strs(field(c, "roots"))))
    "fileSearchReuse" =>
      jb(file_search_reuse(match field(c, "age") { Some(Number(a, ..)) => Some(a); _ => None }, bool_field(c, "again"), bool_field(c, "guessed")))
    "turns" => {
      let t = Turns::new()
      Json::array(
        (match field(c, "steps") { Some(Array(a)) => a; _ => [] }).map(step => match str_or(step, "do", "") {
          "ask" =>
            t.ask(int_field(step, "id", 0), match field(step, "typist") { Some(String(x)) => Some(x); _ => None }, str_or(step, "typed", ""))
          "done" =>
            match t.done(int_field(step, "id", 0)) {
              Some(next) => ji(next)
              None => Json::null()
            }
          _ => {
            t.expire(int_field(step, "id", 0))
            Json::null()
          }
        }),
      )
    }
    "skillSelection" =>
      match skill_selection(field(c, "args").unwrap_or(Json::null())) {
        Ok((name, file)) => { "name": js(name), "file": js(file) }
        Err(e) => { "error": js(e) }
      }
    "formatSkill" =>
      match format_skill(field(c, "catalog").unwrap_or(Json::null()), s("name"), s("file")) {
        Ok(t) => { "ok": js(t) }
        Err(e) => { "error": js(e) }
      }
    "skillWorkspace" =>
      opt_s(skill_workspace(match field(c, "workspace") { Some(String(x)) => Some(x); _ => None }, match field(c, "home") { Some(String(x)) => Some(x); _ => None }))
    "skillStation" => {
      let stations = match field(c, "stations") {
        Some(Array(a)) => a.map(x => (str_or(x, "id", ""), str_or(x, "name", ""), bool_field(x, "here")))
        _ => []
      }
      match skill_station(match field(c, "asked") { Some(String(x)) => Some(x); _ => None }, stations) {
        Ok(w) => { "ok": js(w) }
        Err(e) => { "error": js(e) }
      }
    }
    "searchPlan" =>
      search_plan(
        bool_field(c, "files"),
        match field(c, "kinds") { Some(Array(_)) as k => Some(strs(k)); _ => None },
        match field(c, "limit") { Some(Number(l, ..)) => Some(l.to_int()); _ => None },
        match field(c, "offset") { Some(Number(o, ..)) => Some(o.to_int()); _ => None },
      )
    "searchStations" => search_stations(field(c, "roster").unwrap_or(Json::null()), s("station"))
    "searchWorkspaceOf" =>
      search_workspace_of(match field(c, "ws") { Some(String(x)) => Some(x); _ => None }, match field(c, "home") { Some(String(x)) => Some(x); _ => None })
    // read
    "configTeams" => Json::array(config_teams(field(c, "raw").unwrap_or(Json::null())).map(p => Json::array([js(p.0), team_json(p.1)])))
    "remoteTeams" => Json::array(remote_teams(field(c, "raw").unwrap_or(Json::null())).map(p => Json::array([js(p.0), team_json(p.1)])))
    "allTeams" =>
      Json::array(all_teams(field(c, "config").unwrap_or(Json::null()), field(c, "remote").unwrap_or(Json::null())).map(p => Json::array([js(p.0), team_json(p.1)])))
    "teamIn" => {
      let all = all_teams(field(c, "config").unwrap_or(Json::null()), field(c, "remote").unwrap_or(Json::null()))
      match team_in(all, s("connect")) {
        Some(t) => team_json(t)
        None => Json::null()
      }
    }
    "knownPerson" =>
      known_person(field(c, "config").unwrap_or(Json::null()), field(c, "remote").unwrap_or(Json::null()), field(c, "books").unwrap_or(Json::null()), s("connect"), s("user"))
    "viewsConfig" => views_config(field(c, "raw").unwrap_or(Json::null()))
    "authorName" => {
      let members = match field(c, "members") {
        Some(Array(a)) => a.map(m => (str_or(m, "session", ""), str_or(m, "connect", "")))
        _ => []
      }
      let connects = match field(c, "connects") {
        Some(Array(a)) => a.map(x => (str_or(x, "id", ""), str_or(x, "name", "")))
        _ => []
      }
      let people = match field(c, "people") {
        Some(Object(m)) => m
        _ => Map([])
      }
      let (name, picture) = author_name(
        s("kind"),
        s("author"),
        match field(c, "surface") { Some(String(x)) => Some(x); _ => None },
        members,
        match field(c, "sessionConnect") { Some(String(x)) => Some(x); _ => None },
        match field(c, "sessionTitle") { Some(String(x)) => Some(x); _ => None },
        connects,
        env_of(field(c, "names")),
        match field(c, "admin") { Some(String(x)) => Some(x); _ => None },
        (connect, user) => people.get(connect + "/" + user).unwrap_or(Json::null()),
      )
      { "name": opt_s(name), "picture": opt_s(picture) }
    }
    "machineRoots" => {
      let (claude, codex) = machine_roots(match field(c, "home") { Some(String(x)) => Some(x); _ => None }, match field(c, "codexHome") { Some(String(x)) => Some(x); _ => None })
      { "claude": js(claude), "codex": js(codex) }
    }
    "extension" => opt_s(extension(s("name")))
    "rolloutOf" => jb(rollout_of(s("path"), s("id")))
    "rustLines" => jstrs(rust_lines(s("text")))
    "markFile" => js(transcript_mark_file(transcript_marks_dir(s("data")), s("path")))
    "modelPrice" => {
      @readops.learn_catalog(field(c, "catalog").unwrap_or(Json::null()))
      match model_price(s("model")) {
        Some((i, o, r)) => { "input": jn(i), "output": jn(o), "cacheRead": jn(r) }
        None => Json::null()
      }
    }
    "sessionUsage" => {
      @readops.learn_catalog(field(c, "catalog").unwrap_or(Json::null()))
      session_usage(match field(c, "groups") { Some(Array(a)) => a; _ => [] })
    }
    "usageNow" => {
      @readops.learn_catalog(field(c, "catalog").unwrap_or(Json::null()))
      usage_now(
        match field(c, "groups") { Some(Array(a)) => a; _ => [] },
        match field(c, "contexts") { Some(Array(a)) => a; _ => [] },
        match field(c, "since") { Some(Number(x, ..)) => Some(x); _ => None },
        match field(c, "saved") { Some(Null) | None => None; Some(x) => Some(x) },
      )
    }
    _ => raise Failure("no such case: \{f}")
  }
}

///|
fn jb_arr(a : Array[Bool]) -> Json {
  Json::array(a.map(jb))
}

///|
/// The read cases on files.
fn read_io_case(fs : Fs, c : Json) -> Json? raise {
  let s = (name : String) => str_or(c, name, "")
  match str_or(c, "fn", "") {
    "searchWalk" => {
      let (paths, left) = search_walk(fs, strs(field(c, "tops")), strs(field(c, "words")), strs(field(c, "skip")), int_field(c, "most", 1000), 3000.0, () => 0.0)
      Some({ "paths": jstrs(paths), "left": jb(left) })
    }
    "transcriptOf" => Some(opt_s(transcript_of(fs, s("claude"), s("codex"), s("runtime"), s("id"))))
    "outputAt" => Some(opt_n(output_at(fs, s("path"))))
    "logTail" => Some(js(log_tail(fs, s("path"), int_field(c, "lines", 0))))
    "lookAnswer" => Some(look_answer(fs, field(c, "look").unwrap_or(Json::null())))
    "forgetMarks" => {
      forget_marks(fs, s("dir"), strs(field(c, "paths")))
      Some(Json::null())
    }
    _ => None
  }
}
