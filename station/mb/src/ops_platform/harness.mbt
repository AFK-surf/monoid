// The tests' way in (test/mb-ops-platform.test.ts, through stillfail-reader `--builder harness-ops-platform`): a JSON
// line a case on stdin (`fn` names what is asked, the rest its arguments), a JSON line its outcome on stdout
// (`{"ok": …}` or `{"error": …}`). Each case is worked out on its own, but for the files a case names (a temporary
// directory of the test's), read and written through the shell as the program reads and writes them.

///|
fn pairs_json(a : Array[(Double, Double)]) -> Json {
  Json::array(a.map(p => Json::array([jn(p.0), jn(p.1)])))
}

///|
fn pair_s_json(a : Array[(String, String)]) -> Json {
  Json::array(a.map(p => Json::array([js(p.0), js(p.1)])))
}

///|
fn opt_pair(p : (Double, Double)?) -> Json {
  match p {
    Some((a, b)) => Json::array([jn(a), jn(b)])
    None => Json::null()
  }
}

///|
fn cmd_json(c : (String, Array[String])) -> Json {
  Json::array([js(c.0), jstrs(c.1)])
}

///|
fn opt_cmd(c : (String, Array[String])?) -> Json {
  match c {
    Some(x) => cmd_json(x)
    None => Json::null()
  }
}

///|
fn set_of(j : Json?) -> Array[String] {
  strs(j)
}

///|
fn joiner(c : Json) -> (Array[String]) -> String {
  match str_field(c, "join") {
    Some("win32") => win32_join
    _ => posix_join
  }
}

///|
fn opt_str_field(c : Json, name : String) -> String? {
  match field(c, name) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn catalog_of(c : Json) -> Catalog {
  Catalog::from_json(field(c, "zh").unwrap_or(Json::null()), field(c, "en").unwrap_or(Json::null()))
}

///|
/// The catalog the cases are given once (`catalog`), kept for those after.
let kept_catalog : Ref[Catalog?] = { val: None }

///|
fn the_catalog() -> Catalog {
  match kept_catalog.val {
    Some(c) => c
    None => Catalog::from_json(Json::null(), Json::null())
  }
}

///|
fn args_map(c : Json) -> Map[String, Json] {
  match field(c, "args") {
    Some(Object(m)) => m
    _ => Map([])
  }
}

///|
fn product_arg(c : Json) -> Product {
  match str_field(c, "origin") {
    Some(o) if o != "" => product_of(o)
    _ => stillfail_product
  }
}

///|
/// What a case asks of the pure parts.
fn pure_case(c : Json) -> Json raise {
  let f = str_or(c, "fn", "")
  let s = (name : String) => str_or(c, name, "")
  let n = (name : String) => num_field(c, name).unwrap_or(0.0)
  let onum = (name : String) => match field(c, name) {
    Some(Number(v, ..)) => Some(v)
    _ => None
  }
  let env = () => env_of(field(c, "env"))
  match f {
    // platform/text.ts
    "trim" => js(rtrim(s("s")))
    "splitWords" => jstrs(split_words(s("s")))
    "firstWord" => js(first_word(s("s")))
    "parseU64" => opt_n(parse_u64(s("s")))
    "parseF64" => opt_n(parse_f64(s("s")))
    "pressureOfAvailable" => opt_s(pressure_of_available(onum("available"), onum("total")))
    "pressureOfLevel" => opt_s(pressure_of_level(s("level"), available=onum("available"), total=onum("total")))
    "parsePs" => Json::array(parse_ps(s("text")).map(p => p.to_json()))
    "parseTopMem" => pairs_json(parse_top_mem(s("text")))
    "fieldOrNull" => opt_n(field_or_null(s("text"), s("label")))
    "procStatTicks" => opt_pair(proc_stat_ticks(s("text")))
    "parseLsof" => jstrs(parse_lsof(s("text"), n("port")))
    "idleOfIoreg" => opt_n(idle_of_ioreg(s("text")))
    "parseMounts" => jstrs(parse_mounts(s("text")))
    "cpuShare" => {
      let a = nums(field(c, "a"))
      let b = nums(field(c, "b"))
      opt_n(cpu_share((a[0], a[1]), (b[0], b[1])))
    }
    "treeOf" => {
      let table = match field(c, "table") {
        Some(Array(a)) => a.map(process_info_of)
        _ => []
      }
      Json::array(tree_of(table).map(t => Json::array([jn(t.0), Json::array(t.1.map(jn))])))
    }
    // win32 paths
    "win32" => {
      let cwd = s("cwd")
      let p = s("path")
      {
        "resolve": js(win32_resolve([p], cwd)),
        "normalize": js(win32_normalize(p)),
        "dirname": js(win32_dirname(p)),
        "isAbsolute": jb(win32_is_absolute(p)),
        "join": js(win32_join(strs(field(c, "parts")))),
        "relative": js(win32_relative(p, s("to"), cwd)),
      }
    }
    "posix" => {
      let p = s("path")
      {
        "normalize": js(posix_normalize(p)),
        "join": js(posix_join(strs(field(c, "parts")))),
        "resolve": js(posix_resolve([p], s("cwd"))),
      }
    }
    // platform/unix.ts
    "backgroundedOn" => cmd_json(backgrounded_on(background_of(field(c, "how").unwrap_or(Json::null())), s("program"), strs(field(c, "args"))))
    "backgroundFound" => {
      let there = set_of(field(c, "there"))
      let links = env_of(field(c, "real"))
      match background_found(bool_field(c, "mac"), p => there.contains(p), p => env_get(links, p)) {
        Taskpolicy => { "kind": "taskpolicy" }
        Ionice(i, ni) => { "kind": "ionice", "ionice": js(i), "nice": js(ni) }
        Nice(ni) => { "kind": "nice", "nice": js(ni) }
        NoWrapper => { "kind": "none" }
      }
    }
    "unixClean" => js(unix_clean(s("path")))
    "startTimeOfEtime" => opt_n(start_time_of_etime(s("text"), n("now")))
    "macMemoryOf" => {
      let swap = opt_str_field(c, "swap")
      mac_memory_of(opt_str_field(c, "total"), opt_str_field(c, "vm"), () => swap).to_json()
    }
    "linuxSample" => {
      let (m, model, up) = linux_sample(s("info"), s("cpus"), s("up"))
      { "memory": m.to_json(), "cpuModel": js(model), "uptimeSec": jn(up) }
    }
    "macBootAndFootprint" => {
      let (up, bytes) = mac_boot_and_footprint(opt_str_field(c, "boot"), opt_str_field(c, "footprint"), n("now"))
      { "uptimeSec": jn(up), "footprint": opt_n(bytes) }
    }
    "quoted" => js(sh_quoted(s("word")))
    "descendants" => Json::array(descendants_of(s("text"), n("pid")).map(jn))
    "procAddress" => js(proc_address(s("hex")))
    "procListeningSockets" => pair_s_json(proc_listening_sockets(strs(field(c, "tables")), n("port")))
    "socketInode" => opt_s(socket_inode(s("target")))
    "tcpPortInodes" => jstrs(tcp_port_inodes(strs(field(c, "tables")), n("port").to_int()))
    "lsofPids" => Json::array(lsof_pids(s("text"), n("own")).map(jn))
    "groupMemoryOfPs" => pairs_json(group_memory_of_ps(s("text"), nums(field(c, "pgids"))))
    "inTerminal" =>
      opt_cmd(
        in_terminal(
          bool_field(c, "mac"),
          opt_str_field(c, "script"),
          s("program"),
          strs(field(c, "args")),
          n("cols").to_int(),
          n("rows").to_int(),
        ),
      )
    "unixPaths" => {
      let p = s("path")
      let d = s("dir")
      {
        "within": jb(unix_within(p, d)),
        "join": js(unix_join(d, p)),
        "relativeIn": opt_s(unix_relative_in(d, p)),
      }
    }
    "unixNativeCache" => js(unix_native_cache(bool_field(c, "mac"), env(), s("home")))
    "unixPrependPath" => env_json(unix_prepend_path(env(), s("dir")))
    "unixAppendPath" => {
      let e = env()
      unix_append_path(e, s("dir"))
      env_json(e)
    }
    "unixLowered" => cmd_json(unix_lowered(s("program"), strs(field(c, "args")), n("by").to_int(), bool_field(c, "nice")))
    "unixFlushing" => cmd_json(unix_flushing(bool_field(c, "mac"), s("dir")))
    "unixAgyStaging" => opt_s(unix_agy_staging(env(), s("url")))
    "unixNodeBuild" =>
      match unix_node_build(s("version"), s("platform"), s("arch")) {
        Some(b) => b.to_json()
        None => Json::null()
      }
    "unixAgyBuild" => opt_s(unix_agy_build(s("platform"), s("arch"), bool_field(c, "musl")))
    "unixBrowserPlaces" => {
      let found = env_of(field(c, "found"))
      jstrs(unix_browser_places(bool_field(c, "mac"), env(), name => env_get(found, name)))
    }
    "lsofCwds" => Json::array(lsof_cwds(s("text")).map(p => Json::array([jn(p.0), js(p.1)])))
    "psCommands" => jstrs(ps_commands(s("text")))
    "echoesOf" => {
      let r = echoes_of(s("tty"), opt_str_field(c, "stty"))
      match r {
        Some(b) => jb(b)
        None => Json::null()
      }
    }
    "unixLauncherSignal" => opt_s(unix_launcher_signal(s("op")))
    "unixOs" => js(unix_os(s("platform")))
    "unixUserShell" => opt_s(unix_user_shell(env(), opt_str_field(c, "userHome"), opt_str_field(c, "userShell")))
    "unixIsLauncher" => jb(unix_is_launcher(s("command")))
    "unixHoldAwake" => opt_cmd(unix_hold_awake(bool_field(c, "mac"), s("why"), n("pid").to_int(), bool_field(c, "inhibit")))
    "unixInstalls" => unix_installs()
    "unixInstallerShell" => js(unix_installer_shell)
    // platform/windows.ts
    "winPathOf" => js(win_path_of(env()))
    "cmdPath" =>
      match win_cmd_path(s("path"), env()) {
        Ok(p) => { "ok": js(p) }
        Err(e) => { "error": js(e) }
      }
    "wingetPackage" => opt_s(winget_package(s("real")))
    "winCommandCandidates" =>
      match win_command_candidates(s("name"), env(), s("delim"), joiner(c)) {
        Some(a) => jstrs(a)
        None => Json::null()
      }
    "shellCandidates" =>
      Json::array(
        shell_candidates(env(), strs(field(c, "dirs")), bool_field(c, "saved")).map(x => match x.beside {
          Some(b) => { "path": js(x.path), "beside": js(b) }
          None => { "path": js(x.path) }
        }),
      )
    "gitShell" => {
      let there = set_of(field(c, "there"))
      opt_s(git_shell(env(), p => there.contains(p)))
    }
    "gitShellSoon" => {
      let there = set_of(field(c, "there"))
      let saved = match field(c, "saved") {
        Some(Array(_)) as a => Some(strs(a))
        _ => None
      }
      opt_s(git_shell_soon(env(), saved, p => there.contains(p)))
    }
    "readShim" => shim_json(read_shim(s("text")))
    "shimOf" => shim_of(s("path"), s("text"))
    "winRunnableOf" => {
      let shim = match field(c, "shim") {
        Some(Object(_) as sh) => Some((str_or(sh, "file", ""), strs(field(sh, "args"))))
        _ => None
      }
      match win_runnable_of(s("file"), strs(field(c, "args")), env(), opt_str_field(c, "comSpec"), shim) {
        Ok(j) => { "ok": j }
        Err(e) => { "error": js(e) }
      }
    }
    "winBrowserPlaces" => jstrs(win_browser_places(env()))
    "winGroupMemory" => pairs_json(win_group_memory(s("text"), nums(field(c, "pgids"))))
    "savedPathOf" => jstrs(saved_path_of(env_of(field(c, "machine")), env_of(field(c, "user")), env()))
    "windowsUpdateScript" => js(windows_update_script(s("runDir"), env(), s("task")))
    "windowsRegisterScript" =>
      js(windows_register_script(s("hidden"), s("ps1"), s("runDir"), s("task"), bool_field(c, "admin")))
    "windowsTaskOf" => {
      let (task, admin) = windows_task_of(opt_str_field(c, "kept"), data_dir=opt_str_field(c, "dataDir").unwrap_or(""))
      { "task": js(task), "admin": jb(admin) }
    }
    "winDrives" => {
      let there = set_of(field(c, "there"))
      Json::array(win_drives(p => there.contains(p)).map(d => { "name": js(d.0), "path": js(d.1) }))
    }
    "winPrependPath" => env_json(win_prepend_path(env(), s("dir"), s("delim")))
    "winAppendPath" => {
      let e = env()
      win_append_path(e, s("dir"), s("delim"))
      env_json(e)
    }
    "winPaths" => {
      let p = s("path")
      let d = s("dir")
      let cwd = s("cwd")
      {
        "clean": js(win_clean(p, cwd)),
        "key": js(lower(p)),
        "within": jb(win_within(p, d)),
        "isRootName": jb(win_is_root_name(p)),
        "rooted": jb(win_rooted(p)),
        "join": js(win_join(d, p)),
        "relativeIn": opt_s(win_relative_in(d, p, cwd)),
        "isDrivePath": jb(win_is_drive_path(p)),
      }
    }
    "winNativeCache" => js(win_native_cache(env(), s("home"), joiner(c)))
    "winCommandCmd" => js(win_command_cmd(s("path"), opt_str_field(c, "shell"), bool_field(c, "noop")))
    "netstatPortPids" => Json::array(netstat_port_pids(s("text"), n("port"), n("own")).map(jn))
    "netstatListening" => jstrs(netstat_listening(s("text"), nums(field(c, "pids")), n("port")))
    "winIsLauncher" => jb(win_is_launcher(s("name")))
    "winNodeBuild" =>
      match win_node_build(s("version"), s("arch"), opt_str_field(c, "systemRoot")) {
        Some(b) => b.to_json()
        None => Json::null()
      }
    "winAgyStaging" => opt_s(win_agy_staging(env(), joiner(c)))
    "winShimUpdate" => {
      let there = set_of(field(c, "there"))
      win_shim_update(s("onPath"), s("real"), s("pkg"), s("winget"), p => there.contains(p), opt_str_field(c, "npm"))
    }
    "winInstalls" => win_installs()
    // ops/paths.ts and the small ones
    "paths" => {
      let p = plat_of(c)
      let path = s("path")
      let dir = s("dir")
      {
        "segments": jstrs(segments(p, path)),
        "cleanPosix": js(clean_posix(p, path)),
        "clean": js(clean_path(p, path)),
        "samePath": jb(same_path(p, path, dir)),
        "within": jb(within(p, path, dir)),
        "inside": jb(inside(p, path, dir)),
        "fileName": opt_s(file_name(p, path)),
        "anyBaseName": js(any_base_name(path)),
        "joinPath": js(join_path(p, dir, path)),
        "relativeParts": match relative_parts(p, path) {
          Some(a) => jstrs(a)
          None => Json::null()
        },
      }
    }
    "portable" => { "name": jb(portable_name(s("name"))), "component": js(portable_component(s("name"))) }
    "stationVersion" => opt_s(station_version(opt_str_field(c, "build")))
    "versionOf" => js(version_of(strs(field(c, "args")), opt_str_field(c, "appBuild"), opt_str_field(c, "ownBuild")))
    "own" => {
      let o = Own::new(s("data"), s("config"))
      for more in arr(field(c, "more")) {
        let m = strs(Some(more))
        o.add(() => m)
      }
      { "more": jstrs(o.more()), "paths": jstrs(o.paths()) }
    }
    "unanswered" =>
      jb(unanswered(bool_field(c, "isError"), s("name"), bool_field(c, "typeError"), s("message"), s("code")))
    "disk" => {
      let tier = disk_tier(n("free"), n("total"))
      { "soft": jn(disk_soft(n("total"))), "tier": js(tier), "every": jn(disk_every(tier)) }
    }
    "agentNice" => ji(agent_nice(opt_str_field(c, "given")))
    "heldBy" => {
      let texts = match field(c, "texts") {
        Some(Array(a)) =>
          a.map(t => match t {
            String(x) => Some(x)
            _ => None
          })
        _ => []
      }
      let alive = nums(field(c, "alive"))
      opt_n(held_by(texts, n("self"), p => alive.contains(p)))
    }
    "waits" => {
      let w = no_waits()
      match field(c, "waits") {
        Some(Array(a)) =>
          for x in a {
            let ms = num_field(x, "ms").unwrap_or(0.0)
            let who = str_or(x, "who", "")
            waited(w, ms, () => who)
          }
        _ => ()
      }
      { "waits": w.to_json(), "longest": js(longest_waits(w, most=int_field(c, "most", 3))) }
    }
    "askedBy" => js(asked_by(opt_str_field(c, "stack")))
    "stillOurs" => jb(still_ours(onum("started"), n("startedAt"), bool_field(c, "outlives"), bool_field(c, "alive")))
    "endGroupLooks" => ji(end_group_looks(n("grace")))
    // i18n.ts and model-name.ts
    "langOf" => js(lang_of(opt_str_field(c, "locale")))
    "productOf" => js(product_of(s("origin")).name)
    "branded" => js(branded(s("text"), product_of(s("origin"))))
    "tr" => js(tr(the_catalog(), s("lang"), s("key"), args_map(c), product=product_arg(c)))
    "modelName" => js(model_name(s("id")))
    "makerOf" => opt_s(maker_of(s("model")))
    // agent-env.ts
    "agentEnv" => env_json(agent_env(field(c, "raw").unwrap_or(Json::null())))
    "checkAgentEnv" => opt_s(check_agent_env(field(c, "set")))
    "parseEnvText" => parse_env_text(s("text"), env_of(field(c, "kept")))
    "maskValue" => js(mask_value(s("value")))
    "secretValue" => jb(secret_value(s("key"), s("value")))
    "keepLocal" => env_json(keep_local(env()))
    "startEnv" => env_json(start_env(env(), field(c, "raw").unwrap_or(Json::null()), strs(field(c, "scrubbed"))))
    "proxyEnv" =>
      match proxy_env(env()) {
        Some(e) => env_json(e)
        None => Json::null()
      }
    // launcher.ts, restart.ts, previous.ts, health.ts
    "launcherArgs" => launcher_args(strs(field(c, "args"))).to_json()
    "launcherSaid" => {
      let a = launcher_args(strs(field(c, "args")))
      let out = []
      for x in arr(field(c, "said")) {
        let said = match str_or(x, "op", "") {
          "ready" => Ready(str_or(x, "version", ""))
          "serving" => Serving(str_or(x, "name", ""), num_field(x, "port").unwrap_or(0.0))
          "taking" => Taking
          "failed" => Failed(str_or(x, "why", ""))
          "drained" => Drained(str_or(x, "how", ""))
          "carry" => Carry(field(x, "what").unwrap_or(Json::null()))
          "heartbeat" => Heartbeat
          _ => RestartFront
        }
        out.push(opt_s(said_line(a, said)))
      }
      Json::array(out)
    }
    "launcherTold" => {
      let r = ControlReader::new()
      let box_ = CarriedBox::new()
      let ops = []
      let take_at = int_field(c, "takeAt", -1)
      for i, chunk in strs(field(c, "chunks")) {
        if i == take_at {
          box_.take()
        }
        for t in r.feed(chunk) {
          match t {
            Carried(what) => box_.told(what)
            _ => ()
          }
          ops.push(told_json(t))
        }
      }
      if take_at >= strs(field(c, "chunks")).length() {
        box_.take()
      }
      { "told": Json::array(ops), "taken": Json::array(box_.taken), "left": js(r.carry) }
    }
    "restarterPid" => {
      let launchers = nums(field(c, "launchers"))
      opt_n(restarter_pid(opt_str_field(c, "text"), p => launchers.contains(p)))
    }
    "pageRestart" => js(page_restart(bool_field(c, "handover"), bool_field(c, "restartFront")))
    "previousPid" => opt_n(previous_pid(opt_str_field(c, "text"), n("self")))
    "healthOf" =>
      match health_of(field(c, "h").unwrap_or(Json::null())) {
        Some(h) => h
        None => Json::null()
      }
    "workingOf" => {
      let h = match field(c, "health") {
        Some(Null) | None => None
        Some(x) => health_of(x)
      }
      working_of(bool_field(c, "running"), h, bool_field(c, "healthAlive"), bool_field(c, "online"), bool_field(c, "conflict"), n("now"))
    }
    "healthText" => js(health_text(field(c, "health").unwrap_or(Json::null())))
    // files.ts and log.ts
    "dataDir" => js(data_dir(strs(field(c, "args")), opt_str_field(c, "envData"), s("home")))
    "ownData" => jb(own_data(plat_of(c), s("data"), s("home"), joiner(c)))
    "rememberedMcpPort" => opt_n(remembered_mcp_port(opt_str_field(c, "text")))
    "portsToTry" => Json::array(ports_to_try(onum("named"), onum("remembered"), n("usual"), bool_field(c, "own")).map(jn))
    "positionals" => jstrs(positionals(strs(field(c, "args")), strs(field(c, "valued"))))
    "flag" => opt_s(flag(strs(field(c, "args")), s("name")))
    "unreadableDirMessage" =>
      js(
        unreadable_dir_message(
          the_catalog(),
          s("lang"),
          s("dir"),
          strs(field(c, "argv")),
          bool_field(c, "folderPermissions"),
          joiner(c),
        ),
      )
    "invalidJsonMessage" => js(invalid_json_message(the_catalog(), s("lang"), s("path"), s("program")))
    "isoTime" => js(iso_time(n("ms")))
    "logLine" => js(log_line(n("now"), s("level"), s("at"), s("message"), field(c, "fields")))
    "errorHeard" => {
      let (log, error) = error_heard(s("message"), field(c, "fields"))
      Json::array([js(log), opt_s(error)])
    }
    // command-output.ts and loopback.ts
    "plainText" => js(plain_text(s("text")))
    "unwrapped" => js(unwrapped(s("text"), n("cols").to_int()))
    "urlsIn" => jstrs(urls_in(s("text")))
    "loopbackOf" =>
      match loopback_of(s("url")) {
        Some(l) => l.to_json()
        None => Json::null()
      }
    "domainOf" => opt_s(domain_of(s("url")))
    "deviceCodeIn" => opt_s(device_code_in(s("said"), strs(field(c, "opened"))))
    "deviceUrls" => {
      let (url, code_url) = device_urls(strs(field(c, "urls")), s("code"))
      { "url": opt_s(url), "codeUrl": opt_s(code_url) }
    }
    "asksEnter" => jb(asks_enter(s("line")))
    "saysDone" => jb(says_done(s("text")))
    "storesSecret" => jb(stores_secret(s("name")))
    "prompts" => jb(prompts(s("line")))
    "secretAsked" => jb(secret_asked(s("line")))
    "assignmentsOf" => {
      let (e, rest) = assignments_of(strs(field(c, "words")), opt_str_field(c, "home"))
      { "env": env_json(e), "rest": jstrs(rest) }
    }
    "programOf" => js(program_of(strs(field(c, "words"))))
    "commandWords" =>
      match command_words(s("line")) {
        Some(w) => jstrs(w)
        None => Json::null()
      }
    "webPage" => jb(web_page(opt_str_field(c, "url")))
    "langOfBrowser" => js(lang_of_browser(opt_str_field(c, "said"), opt_str_field(c, "accept")))
    "moved" =>
      js(moved(s("path"), opt_str_field(c, "query"), s("origin"), s("workspace"), s("station")))
    "loopbackAnswer" =>
      loopback_answer(
        the_catalog(),
        s("path"),
        opt_str_field(c, "query"),
        bool_field(c, "ready"),
        match field(c, "place") {
          Some(Null) | None => None
          Some(p) => Some(p)
        },
        s("lang"),
      )
    _ => more_case(c)
  }
}

///|
/// One case's outcome.
fn harness_case(host : @host.Host, c : Json) -> Json {
  if str_field(c, "fn") == Some("catalog") {
    kept_catalog.val = Some(catalog_of(c))
    return { "ok": Json::null() }
  }
  try {
    match io_case(host, c) {
      Some(j) => { "ok": j }
      None => { "ok": pure_case(c) }
    }
  } catch {
    e => { "error": js(err_text(e)) }
  }
}

///|
/// The harness: cases a line each, answered a line each, until stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  while true {
    guard host.line() is Some(line) else { break }
    let answer = match (try Some(@json.parse(line)) catch { _ => None }) {
      Some(c) => harness_case(host, c)
      None => { "error": "not JSON" }
    }
    host.say(answer.stringify())
  }
}
