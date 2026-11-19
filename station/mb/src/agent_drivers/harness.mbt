// What station/test/mb-agent-drivers.test.ts gives the same inputs as the TypeScript it replaces (reader `--builder
// harness-agent-drivers`): a JSON line a case on stdin, a JSON line its outcome on stdout (`{"ok": …}` or
// `{"error": …}`). Each case is worked out whole on its own (its files in memory, its processes, its runners' sockets,
// its program, its clock), so its outcome is a function of what it was given alone.

///|
fn ok_of(v : JValue) -> JValue {
  obj([("ok", v)])
}

///|
fn arg(c : JValue, i : Int) -> JValue {
  match arr_at(Some(c), "args") {
    Some(a) if i < a.length() => a[i]
    _ => Null
  }
}

///|
fn arg_s(c : JValue, i : Int) -> String {
  str_of(Some(arg(c, i))).unwrap_or("")
}

///|
fn arg_opt(c : JValue, i : Int) -> String? {
  str_of(Some(arg(c, i)))
}

///|
fn opt_json(v : String?) -> JValue {
  opt_s(v)
}

///|
/// A pure function of the drivers by its TypeScript name, on its arguments.
fn pure_case(c : JValue) -> JValue raise {
  match str_at(Some(c), "fn").unwrap_or("") {
    "runtimeKind" => opt_json(runtime_kind(Some(arg(c, 0))))
    "runtimeLabel" => s(runtime_label(arg_s(c, 0)))
    "unreachable" => b(tools_unreachable(arg_s(c, 0)))
    "stationTool" => b(station_tool(arg_s(c, 0)))
    "failureOf" => {
      let w = arg(c, 1)
      s(
        failure_of(
          arg_s(c, 0),
          auth_codes=strings_in(get(Some(w), "authCodes")),
          auth=strings_in(get(Some(w), "auth")),
          limit_codes=strings_in(get(Some(w), "limitCodes")),
          limit=strings_in(get(Some(w), "limit")),
        ),
      )
    }
    "failureRest" => s(failure_rest(arg_s(c, 0)))
    "modelLimitOf" => opt_json(model_limit_of(arg_s(c, 0)))
    "chars" => s(chars(arg_s(c, 0), num_of(Some(arg(c, 1))).unwrap_or(0.0).to_int()))
    "keyPart" => s(key_part(arg_s(c, 0)))
    "runnerId" => s(runner_id(arg_s(c, 0), arg_s(c, 1)))
    "peerHttpBase" => s(peer_http_base(arg_s(c, 0)))
    "isTerminalRunner" => b(is_terminal_runner(arg_s(c, 0)))
    "describeExit" => {
      let e = arg(c, 0)
      s(describe_exit(num_at(Some(e), "code").map(x => x.to_int()), str_at(Some(e), "signal")))
    }
    "mcpUrlOf" => opt_json(mcp_url_of(strings_in(Some(arg(c, 0)))))
    "userMessage" => s(user_message(arg_s(c, 0)))
    "hooksOf" => hooks_of(arr_of(Some(arg(c, 0))).unwrap_or([]))
    "backgroundOf" => background_of(arg(c, 0))
    "toolsLostIn" => {
      let calls : Array[String] = []
      arr(arr_of(Some(arg(c, 0))).unwrap_or([]).map(f => opt_json(tools_lost_in(f, calls))))
    }
    "claudeProject" => opt_json(claude_project(arg_s(c, 0)))
    "sortPaths" => {
      let paths = strings_in(Some(arg(c, 0)))
      paths.sort_by(compare_paths)
      strs(paths)
    }
    "hostSkillsOff" => skills_off(strings_in(Some(arg(c, 0))))
    "userAgentVersion" => opt_json(user_agent_version(Some(arg(c, 0))))
    "versionIn" => opt_json(version_in(arg_s(c, 0)))
    "modelCatalog" => {
      let catalog = ModelCatalog::new()
      for page in arr_of(Some(arg(c, 0))).unwrap_or([]) {
        catalog.take_page(Some(page))
      }
      catalog.to_json()
    }
    "agyEmailIn" => opt_json(agy_email_in(arg_s(c, 0)))
    "goKeyringValue" => s(go_keyring_value(arg_s(c, 0)))
    "agyTokenReady" => b(agy_token_ready(arg_s(c, 0), bool_of(arg(c, 1))))
    "agyCompany" => b(agy_company(arg_s(c, 0)))
    "agyPlan" => opt_json(agy_plan(arg_opt(c, 0), company=bool_of(arg(c, 1))))
    "agyPlanIn" => opt_json(agy_plan_in(arg_s(c, 0), enterprise=bool_of(arg(c, 1))))
    "agyExpiryIn" => d(agy_expiry_in(arg_s(c, 0)))
    "agyLentFile" => s(agy_lent_file(arg(c, 0)))
    "noticeFailure" => opt_json(agy_notice_failure(arg_s(c, 0)))
    "classifyFailure" => s(agy_classify_failure(arg_s(c, 0)))
    "agyBaseModel" => {
      let (model, effort) = agy_base_model(arg_s(c, 0))
      match effort {
        Some(e) => obj([("model", s(model)), ("effort", s(e))])
        None => obj([("model", s(model))])
      }
    }
    "agyTierIn" => opt_json(agy_tier_in(Some(arg(c, 0))))
    "agyCatalog" => agy_catalog(strings_in(Some(arg(c, 0))), arg_opt(c, 1))
    "agyVariant" =>
      opt_json(agy_variant(arg_s(c, 0), arg_opt(c, 1), strings_in(Some(arg(c, 2))), arg_opt(c, 3)))
    "agyModels" => strs(agy_models(Some(arg(c, 0))))
    "turnUsage" => turn_usage(Some(arg(c, 0))).unwrap_or(Null)
    "agyOpening" => agy_opening(arg_s(c, 0))
    "agySessionId" => b(agy_session_id(arg_s(c, 0)))
    "rpc" => s(rpc(arg_s(c, 0), arg_s(c, 1), arg(c, 2)))
    "mcpServers" => mcp_servers(arg_s(c, 0), arg_s(c, 1))
    "errorText" => s(error_text(Some(arg(c, 0))))
    "lines" => {
      let lines = Lines::new()
      arr(
        arr_of(Some(arg(c, 0)))
        .unwrap_or([])
        .map(chunk => {
          let bytes = @base64.decode_lossy(str_of(Some(chunk)).unwrap_or(""))
          strs(lines.take(bytes).map(l => @base64.encode(l)))
        }),
      )
    }
    "runnerReady" =>
      (try runner_ready(arg_s(c, 0), arg_s(c, 1)) catch {
        e => return obj([("error", s(words_of(e)))])
      }).json
    "runnerArgs" => {
      let m = World::from_case(obj([])).machine()
      let pty = match arg(c, 6) {
        Obj(_) as p =>
          Some((num_at(Some(p), "cols").unwrap_or(0.0).to_int(), num_at(Some(p), "rows").unwrap_or(0.0).to_int()))
        _ => None
      }
      strs(runner_args(m, arg_s(c, 0), arg_s(c, 1), arg_s(c, 2), arg_s(c, 3), strings_in(Some(arg(c, 4))), pty?=pty))
    }
    other => raise Failed("no such function: \{other}")
  }
}

///|
fn bool_of(v : JValue) -> Bool {
  v is Bool(true)
}

///|
/// A runner's connection: attached, the script heard, then what the case does (`RunnerConnection`).
fn runner_conn_case(c : JValue) -> JValue {
  let world = World::from_case(c)
  let m = world.machine()
  let info : RunnerInfo = { json: get(Some(c), "info").unwrap_or(obj([])) }
  let lines = []
  let conn = RunnerConnection::open(m, info, (stream, text, from, to) => {
    lines.push(arr([s(stream), s(text), n(from), n(to)]))
    done(m.lp)
  })
  let exit : Ref[JValue] = Ref(Null)
  conn.exited.on(r => match r {
    Ok(e) =>
      exit.val = obj([
        ("code", match e.code {
          Some(x) => n(x)
          None => Null
        }),
        ("signal", opt_s(e.signal)),
      ])
    Err(_) => ()
  })
  match num_at(Some(c), "keep") {
    Some(k) => conn.keep_from(k.to_int())
    None => ()
  }
  m.lp.run()
  for act in arr_at(Some(c), "acts").unwrap_or([]) {
    match str_at(Some(act), "do") {
      Some("write") => conn.write(str_at(Some(act), "text").unwrap_or(""))
      Some("closeStdin") => conn.close_stdin()
      Some("signal") =>
        conn.signal(str_at(Some(act), "signal").unwrap_or("TERM"), group=!(bool_at(Some(act), "group") == Some(false)))
      Some("done") => conn.finish()
      Some("detach") => conn.detach() |> ignore
      _ => ()
    }
    m.lp.run()
  }
  let told = match world.sockets.search_by(x => x.path == info.socket()) {
    Some(i) => world.sockets[i].told
    None => []
  }
  obj([("lines", arr(lines)), ("exit", exit.val), ("told", arr(told))])
}

///|
fn settle(lp : Loop, steps : Array[Double]) -> Unit {
  lp.run()
  for ms in steps {
    lp.advance(lp.now + ms)
  }
}

///|
fn runner_case(c : JValue) -> JValue raise {
  let world = World::from_case(c)
  let m = world.machine()
  let data = str_at(Some(c), "data").unwrap_or("")
  let result : Ref[JValue] = Ref(Null)
  let take = (r : Result[JValue, Error]) => result.val = match r {
    Ok(v) => ok_of(v)
    Err(e) => obj([("error", s(words_of(e)))])
  }
  let info : RunnerInfo = { json: get(Some(c), "info").unwrap_or(obj([])) }
  match str_at(Some(c), "op").unwrap_or("") {
    "liveRunners" =>
      live_runners(m, data, strict=is_true(Some(c), "strict"))
      .map(found => arr(found.map(x => x.json)))
      .on(take)
    "runnerOf" =>
      runner_of(m, data, str_at(Some(c), "id").unwrap_or(""))
      .map(x => match x {
        Some(i) => i.json
        None => Null
      })
      .on(take)
    "findRunner" =>
      find_runner(m, data, str_at(Some(c), "id").unwrap_or(""))
      .map(x => match x {
        Some(i) => i.json
        None => Null
      })
      .on(take)
    "liveRunner" => live_runner(m, info).map(x => b(x)).on(take)
    "sweep" => {
      let orphans = strings_in(get(Some(c), "orphans"))
      let asked = []
      sweep_runners(m, data, num_at(Some(c), "now").unwrap_or(0.0), orphan=i => {
        asked.push(i.id())
        Later::ok(m.lp, orphans.contains(i.id()))
      })
      .map(gone => obj([("gone", strs(gone)), ("asked", strs(asked))]))
      .on(take)
    }
    "ackedOffset" =>
      acked_offset(m, info, str_at(Some(c), "out").unwrap_or(""))
      .map(r => arr([
        n(r.0),
        match r.1 {
          Some(k) => n(k)
          None => Null
        },
      ]))
      .on(take)
    "endRunner" => {
      let only = match get(Some(c), "only") {
        Some(Obj(_) as o) => Some(RunnerInfo::{ json: o })
        _ => None
      }
      end_runner(m, data, str_at(Some(c), "id").unwrap_or(""), "label", only?)
      .map(x => b(x))
      .on(take)
    }
    "bytesWithin" =>
      bytes_within(
        m,
        str_at(Some(c), "file").unwrap_or(""),
        num_at(Some(c), "start").unwrap_or(0.0).to_int(),
        num_at(Some(c), "end").unwrap_or(0.0).to_int(),
        chunk=num_at(Some(c), "chunk").unwrap_or(1048576.0).to_int(),
      )
      .map(lines => arr(lines.map(l => arr([s(@base64.encode(l.0)), n(l.1)]))))
      .on(take)
    other => raise Failed("no such case: \{other}")
  }
  settle(m.lp, [400.0, 150.0, 2000.0, 1000.0, 3000.0])
  let told = arr(world.sockets.map(x => obj([("path", s(x.path)), ("told", arr(x.told))])))
  let root = str_at(Some(c), "dump")
  spread([
    result.val,
    obj([
      ("told", told),
      (
        "fs",
        match root {
          Some(r) => world.fs.dump(r)
          None => Null
        },
      ),
    ]),
  ])
}

///|
/// The ids a case's drivers take in turn (`uuid`).
fn ids_of(c : JValue) -> Ids {
  let ids = strings_in(get(Some(c), "ids"))
  let at = Ref(0)
  {
    next: () => {
      let i = at.val
      at.val += 1
      if i < ids.length() {
        ids[i]
      } else {
        "id-\{i}"
      }
    },
  }
}

///|
/// What a case says of its profiles: each one's variables for a runtime and Codex's overrides, by its id.
fn profiles_of(c : JValue) -> ProfileSays {
  let said = get(Some(c), "profiles")
  {
    env: (p, runtime) => string_entries(get(get(get(said, profile_id(p)), "env"), runtime)),
    codex_overrides: p => arr_at(get(said, profile_id(p)), "codexOverrides")
      .unwrap_or([])
      .map(x => match x {
        Arr([Str(k), Str(v), ..]) => (@jsjson.sanitize_str(k), @jsjson.sanitize_str(v))
        _ => ("", "")
      }),
  }
}

///|
fn words_of_case(c : JValue) -> Words {
  let w = get(Some(c), "words")
  {
    repo_rules_command: str_at(w, "repoRules").unwrap_or(""),
    agy_repo_rules_command: str_at(w, "agyRepoRules").unwrap_or(""),
    subagent_hook_command: str_at(w, "subagentHook").unwrap_or(""),
    speaks: strings_in(get(w, "speaks")),
    speaks_writing: str_at(w, "speaksWriting").unwrap_or(""),
  }
}

///|
/// A token a case's renewer gives, each in turn: `{token, expiresAt}`, or `{error, refused}` it fails with.
fn renewer_of(lp : Loop, given : Array[JValue], asked : Array[JValue], name : String) -> Renew {
  let at = Ref(0)
  rejected => {
    asked.push(obj([("renewer", s(name)), ("rejected", opt_s(rejected))]))
    let i = at.val
    at.val += 1
    let g = if i < given.length() {
      given[i]
    } else if given.length() > 0 {
      given[given.length() - 1]
    } else {
      obj([("error", s("no token"))])
    }
    match str_at(Some(g), "error") {
      Some(e) =>
        Later::fail(lp, if is_true(Some(g), "refused") { RenewRefused(e) } else { Failed(e) })
      None =>
        Later::ok(lp, (str_at(Some(g), "token").unwrap_or(""), num_at(Some(g), "expiresAt").unwrap_or(0.0)))
    }
  }
}

///|
/// What a scenario's steps came to.
priv struct Trace {
  results : Array[JValue]
  events : Array[JValue]
  asked : Array[JValue]
}

///|
fn result_json(r : Result[JValue, Error]) -> JValue {
  match r {
    Ok(v) => ok_of(v)
    Err(Said(k)) => obj([("said", s(k))])
    Err(e) => obj([("error", s(words_of(e)))])
  }
}

///|
/// A scenario's steps, one after another, each settled before the next; what the program heard of each.
fn run_steps(
  c : JValue,
  world : World,
  program : FakeProgram,
  trace : Trace,
  step : (JValue, Int, (JValue) -> Unit) -> Later[JValue] raise,
) -> Unit {
  let lp = world.lp
  let opened = Ref(0)
  for st in arr_at(Some(c), "steps").unwrap_or([]) {
    let what = str_at(Some(st), "do").unwrap_or("")
    let result : Ref[JValue] = Ref(obj([("pending", b(true))]))
    let later = match what {
      "hear" =>
        match program.proc_of(num_at(Some(st), "proc").unwrap_or(0.0).to_int()) {
          Some(p) => {
            program.hear(p, get(Some(st), "heard").unwrap_or(obj([])))
            Later::ok(lp, JValue::Null)
          }
          None => Later::fail(lp, Failed("no process"))
        }
      "exit" =>
        match program.proc_of(num_at(Some(st), "proc").unwrap_or(0.0).to_int()) {
          Some(p) =>
            program
            .exit(
              p,
              num_at(Some(st), "code").map(x => x.to_int()),
              str_at(Some(st), "signal"),
              str_at(Some(st), "stderr").unwrap_or(""),
            )
            .map(_ => JValue::Null)
          None => Later::fail(lp, Failed("no process"))
        }
      "advance" => {
        lp.advance(lp.now + num_at(Some(st), "ms").unwrap_or(0.0))
        Later::ok(lp, JValue::Null)
      }
      _ => {
        let k = opened.val
        if what == "open" || what == "adopt" || what == "catalog" {
          opened.val += 1
        }
        let events = (e : JValue) => trace.events.push(obj([("s", n(k)), ("e", e)]))
        try step(st, k, events) catch {
          e => Later::fail(lp, e)
        }
      }
    }
    later.on(r => result.val = result_json(r))
    lp.run()
    trace.results.push(result.val)
  }
  lp.run()
}

///|
fn scenario_json(world : World, program : FakeProgram, trace : Trace, c : JValue) -> JValue {
  obj([
    ("results", arr(trace.results)),
    ("events", arr(trace.events)),
    ("starts", arr(program.starts)),
    ("posts", arr(program.posts)),
    ("replays", arr(program.replays)),
    ("asked", arr(trace.asked)),
    (
      "fs",
      match str_at(Some(c), "dump") {
        Some(r) => world.fs.dump(r)
        None => Null
      },
    ),
  ])
}

///|
fn raw_env_of(c : JValue) -> Env {
  Env::new(string_entries(get(Some(c), "env")))
}

///|
/// Claude Code's driver through a case's steps.
fn claude_case(c : JValue) -> JValue {
  let world = World::from_case(c)
  let m = world.machine()
  let lp = m.lp
  let program = FakeProgram::new(lp, c)
  let procs = program.procs_record(m, c)
  let trace = { results: [], events: [], asked: [] }
  let logins_c = get(Some(c), "logins")
  let borrowed = strings_in(get(logins_c, "borrowed"))
  let logins = {
    machine_token: renewer_of(lp, arr_at(logins_c, "machine").unwrap_or([]), trace.asked, "machine"),
    subscription_token: if get(logins_c, "subscription") is Some(_) {
      let r = renewer_of(lp, arr_at(logins_c, "subscription").unwrap_or([]), trace.asked, "subscription")
      Some(_ => r)
    } else {
      None
    },
    lent_borrowed: Some(p => borrowed.contains(profile_id(p))),
    lent_token: Some({
      let r = renewer_of(lp, arr_at(logins_c, "lent").unwrap_or([]), trace.asked, "lent")
      _ => r
    }),
    has_keychain: false,
    stub_dir: () => Later::ok(lp, ""),
    take_back: _ => done(lp),
    take_back_missing: _ => Later::ok(lp, false),
  }
  let driver = ClaudeDriver::new(
    m,
    str_at(Some(c), "data").unwrap_or(""),
    procs,
    command=str_at(Some(c), "command").unwrap_or("claude"),
    raw_env_of(c),
    words_of_case(c),
    profiles_of(c),
    logins,
    ids_of(c),
  )
  let sessions : Array[ClaudeSession] = []
  let session = (st : JValue) => sessions[num_at(Some(st), "s").unwrap_or(0.0).to_int()]
  run_steps(c, world, program, trace, (st, _, events) => {
    let options = get(Some(st), "options").unwrap_or(obj([]))
    match str_at(Some(st), "do").unwrap_or("") {
      "open" =>
        driver
        .open(options, events)
        .map(x => {
          sessions.push(x)
          s(x.own.session_id)
        })
      "adopt" =>
        driver
        .adopt(options, get(Some(st), "snapshot"), events)
        .map(x => {
          sessions.push(x)
          obj([
            ("id", s(x.own.session_id)),
            ("busy", b(x.own.busy())),
            ("mcpUrl", opt_s(x.own.tools_url)),
          ])
        })
      "prompt" => session(st).prompt(str_at(Some(st), "text").unwrap_or("")).map(_ => JValue::Null)
      "compact" => session(st).compact().map(_ => JValue::Null)
      "steer" => session(st).steer(str_at(Some(st), "text").unwrap_or("")).map(x => b(x))
      "backgroundTools" => session(st).background_tools().map(_ => JValue::Null)
      "abort" => session(st).abort().map(_ => JValue::Null)
      "retune" => Later::ok(lp, b(session(st).retune(options)))
      "background" => Later::ok(lp, session(st).background())
      "snapshot" => Later::ok(lp, session(st).snapshot())
      "dispose" => session(st).dispose().map(_ => JValue::Null)
      "detach" => {
        session(st).detach()
        Later::ok(lp, JValue::Null)
      }
      "busy" => Later::ok(lp, b(session(st).own.busy()))
      "mcpUrl" => Later::ok(lp, opt_s(session(st).own.tools_url))
      "ownedRunners" => Later::ok(lp, strs(driver.own.owned_runners()))
      "shutdown" => driver.own.shutdown().map(_ => JValue::Null)
      other => raise Failed("no such step: \{other}")
    }
  })
  scenario_json(world, program, trace, c)
}

///|
/// Codex's driver through a case's steps.
fn codex_case(c : JValue) -> JValue {
  let world = World::from_case(c)
  let m = world.machine()
  let lp = m.lp
  let program = FakeProgram::new(lp, c)
  let procs = program.procs_record(m, c)
  let trace = { results: [], events: [], asked: [] }
  let w = get(Some(c), "world")
  let borrowed = strings_in(get(w, "borrowed"))
  let skills = strings_in(get(w, "skills"))
  let speeds = get(w, "speeds")
  let fasts = get(w, "fasts")
  let current = get(w, "currentProfiles")
  let lent_until = Ref(num_at(w, "lentUntil").unwrap_or(0.0))
  let world_ = {
    raw_env: raw_env_of(c),
    agent_env: () => string_entries(get(w, "agentEnv")),
    walk_skills: _ => Later::ok(lp, skills),
    host_skills: str_at(w, "hostSkills").unwrap_or(""),
    ca_bundle: str_at(w, "caBundle").unwrap_or(ca_bundle),
    fast: Some(t => bool_at(fasts, t)),
    speed: Some(t => str_at(speeds, t)),
    current_profile: match current {
      Some(Obj(_)) => Some(id => get(current, id))
      _ => None
    },
    lent_borrowed: Some(p => borrowed.contains(profile_id(p))),
    lent_write: Some(p => {
      trace.asked.push(obj([("lentWrite", s(profile_id(p)))]))
      Later::ok(lp, lent_until.val)
    }),
    installed_version: () => {
      trace.asked.push(obj([("installed", b(true))]))
      Later::ok(lp, str_at(w, "installed"))
    },
    missing_host: (command, env) => {
      trace.asked.push(obj([("missingHost", s(command)), ("CODEX_HOME", opt_s(env.get("CODEX_HOME")))]))
      Later::ok(lp, is_true(w, "missingHost"))
    },
    incomplete_installation: () => trace.asked.push(obj([("incomplete", b(true))])),
    link_auth: _ => done(lp),
    remember_rollout: (_, _, _) => (),
    update_matches: _ => Later::ok(lp, false),
    taken_up: None,
    taking: () => trace.asked.push(obj([("taking", b(true))])),
    output_limit: num_at(w, "outputLimit").unwrap_or(output_limit.to_double()).to_int(),
    take_up_bytes: num_at(w, "takeUpBytes").unwrap_or(take_up_bytes.to_double()).to_int(),
    warm_ms: num_at(w, "warmMs").unwrap_or(warm_ms),
  }
  let driver = CodexDriver::new(
    m,
    str_at(Some(c), "data").unwrap_or(""),
    procs,
    command=str_at(Some(c), "command").unwrap_or("codex"),
    world_,
    profiles_of(c),
    words_of_case(c),
  )
  let sessions : Array[CodexSession] = []
  let session = (st : JValue) => sessions[num_at(Some(st), "s").unwrap_or(0.0).to_int()]
  run_steps(c, world, program, trace, (st, _, events) => {
    let options = get(Some(st), "options").unwrap_or(obj([]))
    let profile = get(Some(st), "profile").unwrap_or(Null)
    match str_at(Some(st), "do").unwrap_or("") {
      "open" =>
        driver
        .open(options, events)
        .map(x => {
          sessions.push(x)
          s(x.thread_id)
        })
      "adopt" =>
        driver
        .adopt(options, get(Some(st), "snapshot"), events)
        .map(x => {
          sessions.push(x)
          obj([("id", s(x.thread_id)), ("busy", b(x.busy)), ("mcpUrl", opt_s(x.tools_url))])
        })
      "prompt" => session(st).prompt(str_at(Some(st), "text").unwrap_or("")).map(_ => JValue::Null)
      "compact" => session(st).compact().map(_ => JValue::Null)
      "steer" => session(st).steer(str_at(Some(st), "text").unwrap_or("")).map(x => b(x))
      "abort" => session(st).abort().map(_ => JValue::Null)
      "retune" => Later::ok(lp, b(session(st).retune(options)))
      "snapshot" => Later::ok(lp, session(st).snapshot())
      "dispose" => session(st).dispose().map(_ => JValue::Null)
      "detach" => {
        session(st).detach()
        Later::ok(lp, JValue::Null)
      }
      "busy" => Later::ok(lp, b(session(st).busy))
      "version" => Later::ok(lp, opt_s(session(st).host.version))
      "models" => driver.models(profile).map(x => x.to_json())
      "rateLimits" => driver.rate_limits(profile)
      "resetQuota" => driver.reset_quota(profile, str_at(Some(st), "key").unwrap_or(""))
      "renewLogin" => driver.renew_login(str_at(Some(st), "profileId").unwrap_or("")).map(x => b(x))
      "loginChanged" => driver.login_changed(str_at(Some(st), "profileId").unwrap_or("")).map(_ => JValue::Null)
      "runtimeChanged" =>
        driver
        .runtime_changed(replaced=is_true(Some(st), "replaced"), drain_busy=is_true(Some(st), "drainBusy"))
        .map(_ => JValue::Null)
      "evictIdle" => driver.evict_idle().map(x => n(x))
      "ownedRunners" => Later::ok(lp, strs(driver.owned_runners()))
      "shutdown" => driver.shutdown(again=is_true(Some(st), "again")).map(_ => JValue::Null)
      other => raise Failed("no such step: \{other}")
    }
  })
  scenario_json(world, program, trace, c)
}

///|
/// Antigravity CLI's driver through a case's steps.
fn agy_case(c : JValue) -> JValue {
  let world = World::from_case(c)
  let m = world.machine()
  let lp = m.lp
  let program = FakeProgram::new(lp, c)
  let procs = program.procs_record(m, c)
  let trace = { results: [], events: [], asked: [] }
  let w = get(Some(c), "world")
  let borrowed = strings_in(get(w, "borrowed"))
  let lent = arr_at(w, "lent").unwrap_or([])
  let lent_at = Ref(0)
  let world_ = {
    raw_env: raw_env_of(c),
    has_keychain: false,
    keychain_read: () => Later::ok(lp, None),
    lent_borrowed: Some(p => borrowed.contains(profile_id(p))),
    lent_write: Some(p => {
      trace.asked.push(obj([("lentWrite", s(profile_id(p)))]))
      let i = lent_at.val
      lent_at.val += 1
      let g = if i < lent.length() { lent[i] } else { obj([("error", s("none lent"))]) }
      match str_at(Some(g), "error") {
        Some(e) => Later::fail(lp, Failed(e))
        None => {
          let home = profile_home(p)
          let text = str_at(Some(g), "file").unwrap_or("")
          m
          .make_dir(m.join([gemini_dir(m, home), "antigravity-cli"]))
          .bind(_ => m.write_file(agy_token(m, home), text, private=true))
          .map(_ => num_at(Some(g), "until").unwrap_or(0.0))
        }
      }
    }),
    run: (command, args, env, cwd, _) => {
      trace.asked.push(obj([("run", s(command)), ("args", strs(args)), ("env", env.to_json()), ("cwd", s(cwd))]))
      done(lp)
    },
    sleep: _ => done(lp),
  }
  let driver = AgyDriver::new(
    m,
    str_at(Some(c), "data").unwrap_or(""),
    procs,
    command=str_at(Some(c), "command").unwrap_or("agy"),
    world_,
    profiles_of(c),
    words_of_case(c),
    ids_of(c),
  )
  let sessions : Array[AgySession] = []
  let session = (st : JValue) => sessions[num_at(Some(st), "s").unwrap_or(0.0).to_int()]
  run_steps(c, world, program, trace, (st, _, events) => {
    let options = get(Some(st), "options").unwrap_or(obj([]))
    let profile = get(Some(st), "profile").unwrap_or(Null)
    match str_at(Some(st), "do").unwrap_or("") {
      "open" =>
        driver
        .open(options, events)
        .map(x => {
          sessions.push(x)
          s(x.acp.own.session_id)
        })
      "adopt" =>
        driver
        .adopt(options, get(Some(st), "snapshot"), events)
        .map(x => {
          sessions.push(x)
          obj([("id", s(x.acp.own.session_id)), ("busy", b(x.acp.own.busy())), ("mcpUrl", opt_s(x.acp.own.tools_url))])
        })
      "catalog" => driver.catalog(profile)
      "prompt" => session(st).acp.prompt(str_at(Some(st), "text").unwrap_or("")).map(_ => JValue::Null)
      "steer" => session(st).steer(str_at(Some(st), "text").unwrap_or("")).map(x => b(x))
      "abort" => session(st).acp.abort().map(_ => JValue::Null)
      "retune" => Later::ok(lp, b(session(st).retune(options)))
      "snapshot" => Later::ok(lp, session(st).acp.snapshot())
      "dispose" => session(st).acp.own.dispose().map(_ => JValue::Null)
      "detach" => {
        session(st).acp.own.detach()
        Later::ok(lp, JValue::Null)
      }
      "outlived" => Later::ok(lp, b(session(st).outlived()))
      "signInExpired" => Later::ok(lp, b(session(st).sign_in_expired()))
      "lentExpired" => Later::ok(lp, b(session(st).lent_expired()))
      "model" =>
        Later::ok(
          lp,
          obj([
            ("model", opt_s(session(st).acp.model)),
            ("current", opt_s(session(st).current_model_id)),
          ]),
        )
      "takeBack" => driver.take_back(profile_home(profile)).map(x => b(x))
      "renew" => driver.renew(profile_home(profile)).map(_ => JValue::Null)
      "bringIn" =>
        agy_bring_in(m, str_at(Some(st), "home").unwrap_or(""), str_at(Some(st), "id").unwrap_or("")).map(x => opt_s(x))
      "noteEmail" =>
        note_agy_email(m, profile_home(profile), str_at(Some(st), "text").unwrap_or("")).map(x => opt_s(x))
      "hooks" => driver.hooks(profile_home(profile)).map(_ => JValue::Null)
      "skills" => agy_skills(m, str_at(Some(st), "cwd").unwrap_or(""), str_at(Some(st), "skills")).map(_ => JValue::Null)
      "env" => Later::ok(lp, driver.env_for(options).to_json())
      "args" => Later::ok(lp, strs(agy_args(m, profile_home(profile))))
      "ownedRunners" => Later::ok(lp, strs(driver.own.owned_runners()))
      other => raise Failed("no such step: \{other}")
    }
  })
  scenario_json(world, program, trace, c)
}

///|
/// A case worked out whole: `{ok}` or `{error}`.
pub fn harness_case(text : String) -> String {
  let answer = try {
    let c = @jsjson.parse(text)
    let ok = match str_at(Some(c), "op").unwrap_or("") {
      "pure" => pure_case(c)
      "runnerConn" => runner_conn_case(c)
      "liveRunners" | "runnerOf" | "findRunner" | "liveRunner" | "sweep" | "ackedOffset" | "endRunner" | "bytesWithin" =>
        return @jsjson.stringify(runner_case(c))
      "claude" => claude_case(c)
      "codex" => codex_case(c)
      "agy" => agy_case(c)
      op => raise Failed("no such case: \{op}")
    }
    ok_of(ok)
  } catch {
    e => obj([("error", s(words_of(e)))])
  }
  @jsjson.stringify(answer)
}

///|
/// The program's harness: a case a line, answered a line each, until stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  while true {
    guard host.line() is Some(line) else { break }
    host.say(harness_case(line))
  }
}
