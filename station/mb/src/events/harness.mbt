// The program's side of station/test/mb-events.test.ts (reader `--builder harness-events`): each line an ask
// `{op, …}`, answered with a line of what this package makes of it, which the test holds to what the TypeScript
// station makes of the same. An event stream's script is played on a world of the test's (world.mbt): its clock, its
// readers' answers given after what is done now, as a promise's are.

///|
pub async fn harness(host : @host.Host) -> Unit {
  while host.line() is Some(line) {
    if line == "" {
      continue
    }
    let ask = parse(line).unwrap_or(Null)
    let answer = answer_of(ask) catch {
      e => jo([("error", js(e.to_string()))])
    }
    host.say(stringify(answer))
  }
}

///|
fn strings_of(v : J?) -> Array[String] {
  match v {
    Some(Arr(items)) => items.map(i => string_of(Some(i)))
    _ => []
  }
}

///|
fn pairs_of(v : J?) -> Array[(String, String)] {
  match v {
    Some(Arr(items)) =>
      items.map(p => (string_of(at(p, 0)), string_of(at(p, 1))))
    Some(Obj(entries)) =>
      entries.map(e => (@jsjson.raw_text(e.0), string_of(Some(e.1))))
    _ => []
  }
}

///|
fn answer_of(ask : J) -> J raise {
  match str_prop(ask, "op").unwrap_or("") {
    "events" =>
      play(
        ask.get("script").unwrap_or(Arr([])),
        ask.get("world").unwrap_or(jo([])),
      )
    "log" => log_script(ask)
    "compat-frame" => {
      let supported = client_runtimes(pairs_of(ask.get("headers")))
      js(compat_frame(str_prop(ask, "text").unwrap_or(""), supported))
    }
    "compat-answer" => {
      let a = ask.get("answer").unwrap_or(jo([]))
      let out = runtime_compatible(
        str_prop(ask, "path").unwrap_or(""),
        pairs_of(ask.get("headers")),
        str_prop(ask, "body").unwrap_or(""),
        str_prop(ask, "lang").unwrap_or("zh"),
        {
          status: num_prop(a, "status").unwrap_or(200.0).to_int(),
          headers: pairs_of(a.get("headers")),
          body: str_prop(a, "body").unwrap_or(""),
        },
      )
      jo([
        ("status", jn(out.status.to_double())),
        ("headers", jo(out.headers.map(h => (h.0, js(h.1))))),
        ("body", js(out.body)),
      ])
    }
    "view" => {
      let supported = client_runtimes(pairs_of(ask.get("headers")))
      match
        runtime_view(
          ask.get("type").unwrap_or(Null),
          ask.get("value"),
          supported,
        ) {
        Omit => jo([("omit", Bool(true))])
        Value(v) => jopt([("value", v)])
      }
    }
    "query" => {
      let world = World::new(ask.get("world").unwrap_or(jo([])))
      let viewer = Viewer::of(ask.get("viewer").unwrap_or(jo([])))
      let (asked, _) = asked_of(
        pairs_of(ask.get("query")),
        viewer,
        k => world.sessions.contains(k),
        Some(world.seen_store()),
      )
      jo([
        ("host", Bool(asked.host)),
        (
          "live",
          ja(
            asked.live.map(l => {
              ja([
                js(l.0),
                jn(l.1),
                match l.2 {
                  Some(n) => jn(n)
                  None => Null
                },
              ])
            }),
          ),
        ),
        ("logs", ja(asked.logs.map(l => ja([js(l.0), jn(l.1.to_double())])))),
        (
          "since",
          match asked.since {
            Some(s) => js(s)
            None => Null
          },
        ),
        ("brief", Bool(asked.brief)),
        ("logins", ja(asked.logins.map(js))),
        ("running", Bool(asked.running)),
      ])
    }
    "seen" => {
      let world = World::new(ask.get("world").unwrap_or(jo([])))
      let viewer = Viewer::of(ask.get("viewer").unwrap_or(jo([])))
      let store = world.seen_store()
      let paths = strings_of(ask.get("paths"))
      jo([
        (
          "elsewhere",
          ja(
            paths.map(p => {
              match elsewhere(store, p, viewer) {
                Some(s) => js(s)
                None => Null
              }
            }),
          ),
        ),
        ("went", ja(paths.map(p => went(store, p, viewer).unwrap_or(Null)))),
      ])
    }
    "oldest" => {
      let builds = strings_of(ask.get("builds"))
      jo([
        (
          "buildOf",
          ja(
            builds.map(b => {
              match build_of(Some(b)) {
                Some(n) => jn(n)
                None => Null
              }
            }),
          ),
        ),
        (
          "tooOld",
          ja(
            builds.map(b => {
              Bool(
                core_too_old(
                  [("Stillfail-Build", js(b))],
                  oldest=num_prop(ask, "oldest")
                    .unwrap_or(oldest_core.to_double())
                    .to_int(),
                ),
              )
            }),
          ),
        ),
      ])
    }
    "numbers" => ja(strings_of(ask.get("texts")).map(t => jn(js_number(t))))
    "overview" => overview_harness(ask)
    "status" => status_harness(ask)
    "host" => host_harness(ask)
    other => fail("no op \{other}")
  }
}

///|
/// An EventLog played: appends, takes, a handover, by a script of the test's.
fn log_script(ask : J) -> J {
  let keeps = ask.get("keeps").unwrap_or(jo([]))
  let ms = num_prop(keeps, "ms").unwrap_or(kept_ms)
  let most = num_prop(keeps, "most").map(d => d.to_int()).unwrap_or(kept_most)
  let bytes = num_prop(keeps, "bytes")
    .map(d => d.to_int())
    .unwrap_or(kept_bytes)
  let mut log = EventLog::new(
    str_prop(ask, "run").unwrap_or("ab"),
    ms~,
    most~,
    bytes~,
  )
  let out = []
  guard ask.get("script") is Some(Arr(steps)) else { return ja([]) }
  for step in steps {
    let now = num_prop(step, "now").unwrap_or(0.0)
    match str_prop(step, "do").unwrap_or("") {
      "append" => {
        let logged = log.append(
          str_prop(step, "event").unwrap_or("e"),
          stringify(step.get("data").unwrap_or(Null)),
          step.get("to").unwrap_or(jo([])),
          now,
          of?=str_prop(step, "of"),
        )
        out.push(js(logged.text))
      }
      "has" => out.push(Bool(log.has(str_prop(step, "since").unwrap_or(""))))
      "after" =>
        out.push(
          ja(
            log
            .after(str_prop(step, "since").unwrap_or(""))
            .map(e => js(e.text)),
          ),
        )
      "at" => out.push(js(log.at()))
      "clear" => log.clear()
      "state" => out.push(log.state())
      "kept" => out.push(log.kept())
      "from" =>
        out.push(
          try {
            log = EventLog::from(
              step.get("kept").unwrap_or(log.kept()),
              now,
              ms~,
              most~,
              bytes~,
            )
            js("ok")
          } catch {
            _ => js("not a log")
          },
        )
      _ => ()
    }
  }
  ja(out)
}
