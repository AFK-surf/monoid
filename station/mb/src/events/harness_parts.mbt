// The overview's, the status's and the host's asks of the harness (harness.mbt), each on a world of the test's as
// station/test/mb-events.test.ts makes the same for the TypeScript station.

///|
/// files.rs `clean` on Unix (platform/unix.ts): absolute, `.` and `..` worked out.
fn unix_clean(path : String) -> String {
  let out : Array[String] = []
  for part in path.split("/") {
    let part = part.to_string()
    if part == "" || part == "." {
      continue
    }
    if part == ".." {
      let _ = out.pop()
    } else {
      out.push(part)
    }
  }
  "/" + out.join("/")
}

///|
fn obj_field(v : J?, name : String) -> J? {
  match v {
    Some(v) =>
      match v.get(name) {
        Some(Null) | None => None
        Some(x) => Some(x)
      }
    None => None
  }
}

///|
/// GET /overview on a world: each `overview` step's answer, in turn.
fn overview_harness(ask : J) -> J {
  let w = World::new(ask.get("world").unwrap_or(jo([])))
  let kept = OverviewKept::new()
  let reads : Array[J] = []
  let readable : Array[String] = strings_of(w.field("readable"))
  let accounts_field = (name : String) => obj_field(w.field("accounts"), name)
  let mut accounts_ready = accounts_field("ready") is Some(Bool(true))
  fn make() -> OverviewDeps {
    let d : OverviewDeps = {
      config: () => w.field("config").unwrap_or(Null),
      session_counts: (_, ids) => {
        reads.push(ja([js("counts"), ja(ids)]))
        match w.field("counts") {
          Some(Obj(_) as c) => {
            let by : Map[String, Double] = Map([])
            if c.get("byConnect") is Some(Obj(entries)) {
              for e in entries {
                if e.1 is Num(n) {
                  by[@jsjson.raw_text(e.0)] = n
                }
              }
            }
            Some((num_prop(c, "total").unwrap_or(0.0), by))
          }
          _ => None
        }
      },
      wait_for_session_counts: match w.field("countsAfterWait") {
        None => None
        Some(after) =>
          Some(k => {
            reads.push(ja([js("waitCounts")]))
            let ready = truthy(Some(after))
            if ready {
              w.set(jo([("counts", after)]))
            }
            w.later(() => k(ready))
          })
      },
      hub_processes: () => {
        match w.field("hubProcesses") {
          Some(Arr(items)) =>
            items.map(p => (string_of(at(p, 0)), string_of(at(p, 1))))
          _ => []
        }
      },
      session_ws: key => {
        match w.sessions.get(key) {
          Some(s) => Some(s.get("ws").unwrap_or(Null))
          None => None
        }
      },
      list_processes: () => {
        match w.field("processes") {
          Some(Arr(items)) => items
          _ => []
        }
      },
      data_dir: str_prop(w.data, "dataDir").unwrap_or("/data"),
      group_memory: (pgids, k) => {
        reads.push(ja([js("memory"), ja(pgids)]))
        let memory : Map[String, Double] = Map([])
        if w.field("memory") is Some(Obj(entries)) {
          for e in entries {
            if e.1 is Num(n) {
              memory[@jsjson.raw_text(e.0)] = n
            }
          }
        }
        w.later(() => k(memory))
      },
      disk_room: (_, k) => {
        let room = if w.field("testHost") is Some(Bool(true)) {
          jo([
            ("freeBytes", jn(50_000_000_000)),
            ("totalBytes", jn(100_000_000_000)),
          ])
        } else {
          match w.field("statfs") {
            Some(Obj(_) as st) => {
              let f = (name : String) => num_prop(st, name).unwrap_or(0.0)
              jo([
                ("freeBytes", jn(f("bavail") * f("bsize"))),
                ("totalBytes", jn(f("blocks") * f("bsize"))),
              ])
            }
            _ => Null
          }
        }
        w.later(() => k(room))
      },
      store_now: () => w.now,
      binding: id => obj_field(w.field("bindings"), id).unwrap_or(Null),
      connect_kind: kind => {
        match obj_field(w.field("connectKinds"), kind) {
          None => None
          Some(own) =>
            Some({
              shown: c => {
                with_prop(
                  own.get("shown").unwrap_or(jo([])),
                  "name",
                  js("\{kind}:\{string_of(c.get("id"))}"),
                )
              },
              connection: _ => {
                match own.get("connection") {
                  Some(Null) | None => None
                  Some(x) => Some(x)
                }
              },
            })
        }
      },
      accounts: match w.field("accounts") {
        Some(Obj(_)) =>
          Some({
            homes_read_soon: if accounts_field("homes") is Some(Bool(true)) {
              Some(k => {
                reads.push(ja([js("homes")]))
                w.later(k)
              })
            } else {
              None
            },
            profiles_view: _ => accounts_field("profiles").unwrap_or(ja([])),
            logins_view: _ => accounts_field("logins").unwrap_or(ja([])),
            api_providers: () => {
              accounts_field("apiProviders").unwrap_or(ja([]))
            },
            machine_logins: () => {
              accounts_field("machineLogins").unwrap_or(ja([]))
            },
            decision_models: () => {
              accounts_field("decisionModels").unwrap_or(ja([]))
            },
            automatic_decisions_view: (viewer, visible, title) => {
              reads.push(ja([js("decisions"), js(viewer.email)]))
              if !accounts_ready {
                return None
              }
              let checks = match accounts_field("checks") {
                Some(Arr(items)) => items
                _ => []
              }
              Some(
                jo([
                  ("canEdit", Bool(manages_station(viewer.role))),
                  ("rule", accounts_field("rule").unwrap_or(Null)),
                  (
                    "recent",
                    ja(
                      checks
                      .filter(c => visible(c.get("session").unwrap_or(Null)))
                      .map(c => {
                        jopt([
                          ("session", c.get("session")),
                          (
                            "title",
                            Some(js(title(string_of(c.get("session"))))),
                          ),
                          ("option", c.get("option")),
                        ])
                      }),
                    ),
                  ),
                ]),
              )
            },
          })
        _ => None
      },
      updates: match w.field("updates") {
        Some(Obj(_) as u) =>
          Some(lang => obj_field(Some(u), lang).unwrap_or(ja([])))
        _ => None
      },
      slack_identities: email => {
        obj_field(w.field("slack"), email).unwrap_or(ja([]))
      },
      root_view: (path, k) => {
        let view = match obj_field(w.field("roots"), path) {
          Some(v) => v
          None =>
            jo([
              ("path", js(path)),
              ("name", js(path)),
              ("state", js("missing")),
            ])
        }
        w.later(() => k(view))
      },
      homedir: str_prop(w.data, "homedir").unwrap_or("/home"),
      has_spotlight: w.field("spotlight") is Some(Bool(true)),
      permissions: match w.field("permissions") {
        None => None
        Some(p) => Some(_ => Some(p))
      },
      cloud_state: () => {
        match w.field("cloud") {
          Some(Null) | None => None
          Some(c) => Some(c)
        }
      },
      membership: ws => obj_field(w.field("memberships"), ws),
      reached: () => w.field("reached") is Some(Bool(true)),
      catalog: () => w.field("catalog").unwrap_or(jo([])),
      decisions_version: () => w.field("decisionsVersion").unwrap_or(jn(0)),
      policy_checks: match w.field("policyChecks") {
        None => None
        Some(_) =>
          Some((since, _, k) => {
            reads.push(ja([js("policyChecks"), jn(since)]))
            let checks = w.field("policyChecks").unwrap_or(Null)
            w.later(() => k(checks))
          })
      },
      policy_view: (ws, mine, title, _, checks) => {
        let key = match ws {
          Str(_) => string_of(Some(ws))
          _ => ""
        }
        let policy = obj_field(w.field("policyOf"), key).unwrap_or(jo([]))
        let saved = obj_field(w.field("policySaved"), key)
        let counted = checks.unwrap_or(
          jo([("options", jo([])), ("checked", jn(0)), ("failed", jn(0))]),
        )
        let options = match policy.get("options") {
          Some(Arr(items)) => items
          _ => []
        }
        jo([
          ("text", policy.get("policy").unwrap_or(Null)),
          (
            "options",
            ja(
              options.map(o => {
                let one = obj_field(
                  counted.get("options"),
                  string_of(o.get("id")),
                )
                let count = match one {
                  Some(c) => c.get("count").unwrap_or(Null)
                  None => jn(0)
                }
                let chats = match one {
                  Some(c) =>
                    match c.get("chats") {
                      Some(Arr(items)) => items
                      _ => []
                    }
                  None => []
                }
                let shown = chats
                  .filter(c => mine(c.get("session").unwrap_or(Null)))
                  .map(c => {
                    let session = c.get("session").unwrap_or(Null)
                    let mut out = jopt([
                      ("session", c.get("session")),
                      ("title", Some(js(title(string_of(Some(session)))))),
                    ])
                    if c is Obj(entries) {
                      for e in entries {
                        if @jsjson.raw_text(e.0) != "session" {
                          out = with_prop(out, @jsjson.raw_text(e.0), e.1)
                        }
                      }
                    }
                    out
                  })
                with_prop(with_prop(o, "count", count), "chats", ja(shown))
              }),
            ),
          ),
          ("days", jn(view_days)),
          ("checked", counted.get("checked").unwrap_or(Null)),
          ("failed", counted.get("failed").unwrap_or(Null)),
          ("edited", Bool(saved is Some(_))),
          (
            "change",
            match saved {
              None => Null
              Some(s) => {
                let change = s.get("change").unwrap_or(jo([]))
                let by = obj_field(Some(change), "by")
                let by_shown = match by {
                  Some(b) if text_of(b.get("kind")) == Some("agent") => {
                    let session = string_of(b.get("session"))
                    jo([
                      ("kind", js("agent")),
                      ("session", b.get("session").unwrap_or(Null)),
                      ("title", js(title(session))),
                      (
                        "runtime",
                        obj_field(w.sessions.get(session), "runtime").unwrap_or(
                          Null,
                        ),
                      ),
                    ])
                  }
                  _ =>
                    jo([
                      ("kind", js("person")),
                      ("email", obj_field(by, "email").unwrap_or(Null)),
                      ("name", obj_field(by, "name").unwrap_or(Null)),
                    ])
                }
                jopt([
                  ("at", change.get("at")),
                  ("summary", change.get("summary")),
                  ("by", Some(by_shown)),
                ])
              }
            },
          ),
        ])
      },
      prepare_decision_sessions: k => {
        reads.push(ja([js("prepareDecisions")]))
        accounts_ready = true
        w.later(k)
      },
      prepare_session_chat_names: if w.field("chatNames") is Some(Bool(true)) {
        Some((missing, k) => {
          reads.push(ja([js("prepareNames"), ja(missing.map(js))]))
          readable.append(missing)
          w.later(k)
        })
      } else {
        None
      },
      session_there: key => w.sessions.contains(key),
      chat_readable: key => readable.contains(key),
      chat_title: key => {
        match w.sessions.get(key) {
          Some(s) =>
            match s.get("title") {
              Some(Null) | None => key
              Some(t) => string_of(Some(t))
            }
          None => key
        }
      },
      rooted: p => p.has_prefix("/"),
      clean: unix_clean,
      built_at: num_prop(w.data, "builtAt"),
    }
    d
  }

  let out = []
  guard ask.get("script") is Some(Arr(steps)) else { return ja([]) }
  for step in steps {
    match str_prop(step, "do").unwrap_or("") {
      "world" => {
        let set = step.get("set").unwrap_or(jo([]))
        w.set(set)
        if obj_field(Some(set), "accounts") is Some(a) {
          accounts_ready = a.get("ready") is Some(Bool(true))
        }
        if set.get("readable") is Some(_) {
          readable.clear()
          readable.append(strings_of(set.get("readable")))
        }
      }
      "advance" => w.now = w.now + num_prop(step, "ms").unwrap_or(0.0)
      // (whether the next overview gives the decisions it keeps, judged as the station's overview judges it before
      // asking their parts: OverviewKept::decisions_fresh, on this world's version, config, models and time)
      "fresh" => {
        let viewer = Viewer::of(step.get("viewer").unwrap_or(jo([])))
        let fresh = kept.decisions_fresh(
          viewer,
          w.field("decisionsVersion").unwrap_or(jn(0)),
          w.field("config").unwrap_or(Null),
          accounts_field("decisionModels").unwrap_or(ja([])),
          w.now,
        )
        reads.push(ja([js("fresh"), Bool(fresh)]))
      }
      "overview" => {
        let viewer = Viewer::of(step.get("viewer").unwrap_or(jo([])))
        let got : Ref[J] = { val: Null, }
        overview(make(), kept, viewer, str_prop(step, "lang").unwrap_or("zh"), r => {
          got.val = match r {
            Ok(v) => jo([("value", v)])
            Err(why) => jo([("error", js(why))])
          }
        })
        w.drain()
        out.push(got.val)
      }
      _ => ()
    }
  }
  jo([("answers", ja(out)), ("reads", ja(reads))])
}

///|
fn status_input(v : J) -> StatusInput {
  {
    version: str_prop(v, "version").unwrap_or(""),
    cloud: v.get("cloud"),
    reached: v.get("reached") is Some(Bool(true)),
    running: match v.get("running") {
      Some(Arr(items)) => items
      _ => []
    },
    processes: match v.get("processes") {
      Some(Arr(items)) =>
        items.map(p => (string_of(at(p, 0)), string_of(at(p, 1))))
      _ => []
    },
    waiting: match v.get("waiting") {
      Some(Arr(items)) => items
      _ => []
    },
    health: v.get("health"),
  }
}

///|
/// The local status: what each input makes, how each request is routed, and a watch's lines.
fn status_harness(ask : J) -> J raise {
  let inputs = match ask.get("inputs") {
    Some(Arr(items)) => items
    _ => []
  }
  let routes = match ask.get("routes") {
    Some(Arr(items)) => items
    _ => []
  }
  let w = World::new(jo([]))
  let current : Ref[J?] = { val: None, }
  let teller = StatusTeller::new(
    () => {
      match current.val {
        Some(Null) | None => None
        Some(i) => Some(status_of(status_input(i)))
      }
    },
    (ms, f) => w.schedule(ms, None, f),
  )
  let heard : Map[String, StringBuilder] = Map([])
  let stops : Map[String, () -> Unit] = Map([])
  let answers = []
  guard ask.get("script") is Some(Arr(steps)) else { fail("no script") }
  for step in steps {
    match str_prop(step, "do").unwrap_or("") {
      "set" => current.val = step.get("input")
      "changed" => teller.changed()
      "advance" => w.advance(w.now + num_prop(step, "ms").unwrap_or(0.0))
      "ask" => {
        let name = str_prop(step, "name").unwrap_or("")
        let lines = StringBuilder::new()
        heard[name] = lines
        let (status, kind, body, stop) = teller.answer(
          route_of(str_prop(step, "method"), str_prop(step, "url")),
          text => lines.write_string(text),
        )
        lines.write_string(body)
        if stop is Some(s) {
          stops[name] = s
        }
        answers.push(
          jo([
            ("name", js(name)),
            ("status", jn(status.to_double())),
            ("type", js(kind)),
          ]),
        )
      }
      "leave" =>
        if stops.get(str_prop(step, "name").unwrap_or("")) is Some(s) {
          s()
        }
      "close" => teller.close()
      _ => ()
    }
    w.drain()
  }
  jo([
    ("statuses", ja(inputs.map(i => status_of(status_input(i))))),
    (
      "routes",
      ja(
        routes.map(r => {
          js(
            match route_of(text_of(at(r, 0)), text_of(at(r, 1))) {
              Status => "status"
              Watch => "watch"
              Health => "health"
              NotFound => "null"
            },
          )
        }),
      ),
    ),
    ("answers", ja(answers)),
    ("heard", jo(heard.iter().map(p => (p.0, js(p.1.to_string()))).to_array())),
  ])
}

///|
fn ticks_of(v : J?) -> Ticks? {
  match v {
    Some(Arr([Num(b), Num(t)])) => Some({ busy: b, total: t, })
    _ => None
  }
}

///|
/// The machine's sample on a world: each step's answer and when it came.
fn host_harness(ask : J) -> J raise {
  let w = World::new(ask.get("world").unwrap_or(jo([])))
  let ticks_given = Ref(0)
  let reads : Array[J] = []
  let delayed = (name : String, give : () -> Unit) => {
    let delay = num_prop(w.data, name + "Delay").unwrap_or(0.0)
    if delay > 0.0 {
      let _ = w.schedule(delay, None, give)
    } else {
      w.later(give)
    }
  }
  let deps : HostDeps = {
    test_host: () => w.field("testHost") is Some(Bool(true)),
    now: () => w.now,
    after: (ms, f) => w.schedule(ms, None, f),
    cpu_ticks: k => {
      let all = match w.field("ticks") {
        Some(Arr(items)) => items
        _ => []
      }
      let i = ticks_given.val
      ticks_given.val += 1
      let t = if all.length() == 0 {
        None
      } else {
        ticks_of(Some(all[if i < all.length() { i } else { all.length() - 1 }]))
      }
      reads.push(ja([js("ticks"), jn(w.now)]))
      delayed("ticks", () => k(t))
    },
    sample: k => {
      reads.push(ja([js("sample"), jn(w.now)]))
      let s = w.field("sample").unwrap_or(jo([]))
      delayed("sample", () => k(s))
    },
    statfs: (_, k) => {
      let st = match w.field("statfs") {
        Some(Obj(_) as s) => Some(s)
        _ => None
      }
      w.later(() => k(st))
    },
    hostname: () => str_prop(w.data, "hostname").unwrap_or(""),
    parallelism: () => num_prop(w.data, "cpus").unwrap_or(1.0).to_int(),
    loadavg: () => {
      match w.field("loadavg") {
        Some(Arr(items)) =>
          items.map(l => {
            match l {
              Num(n) => n
              _ => 0.0
            }
          })
        _ => [0.0, 0.0, 0.0]
      }
    },
    arch: str_prop(w.data, "arch").unwrap_or(""),
    os: () => str_prop(w.data, "os").unwrap_or(""),
    gpus_read: k => {
      reads.push(ja([js("gpus"), jn(w.now)]))
      let g = match w.field("gpus") {
        Some(Null) | None => None
        Some(g) => Some(g)
      }
      delayed("gpus", () => k(g))
    },
    gpus_cached: Some(() => {
      match w.field("gpusCached") {
        Some(Null) | None => None
        Some(g) => Some(g)
      }
    }),
  }
  let host = Host::new(deps, str_prop(w.data, "dataDir").unwrap_or("/data"))
  let out = []
  let mut following : (() -> Unit)? = None
  guard ask.get("script") is Some(Arr(steps)) else { fail("no script") }
  for step in steps {
    let name = str_prop(step, "name").unwrap_or("")
    match str_prop(step, "do").unwrap_or("") {
      "world" => w.set(step.get("set").unwrap_or(jo([])))
      "advance" => {
        let ms = num_prop(step, "ms").unwrap_or(0.0)
        let chunk = num_prop(step, "step").unwrap_or(ms)
        let mut left = ms
        while left > 0.0 {
          let d = if chunk < left { chunk } else { left }
          w.advance(w.now + d)
          w.drain()
          left -= d
        }
      }
      "sample" =>
        host.sample(v => {
          out.push(jo([("name", js(name)), ("at", jn(w.now)), ("value", v)]))
        })
      "recent" =>
        host.recent_busy(v => {
          out.push(jo([("name", js(name)), ("at", jn(w.now)), ("value", v)]))
        })
      "info" => {
        let last = match step.get("last") {
          Some(Obj(_) as l) =>
            Some({
              at: num_prop(l, "at").unwrap_or(0.0),
              ticks: ticks_of(l.get("ticks")).unwrap(),
            })
          _ => None
        }
        host_info(deps, str_prop(w.data, "dataDir").unwrap_or("/data"), last, (
          info,
          seen,
          needs,
        ) => {
          out.push(
            jo([
              ("name", js(name)),
              ("at", jn(w.now)),
              (
                "value",
                jo([
                  ("info", info),
                  (
                    "seen",
                    match seen {
                      Some(s) =>
                        jo([
                          ("at", jn(s.at)),
                          ("ticks", ja([jn(s.ticks.busy), jn(s.ticks.total)])),
                        ])
                      None => Null
                    },
                  ),
                  ("needsTicks", Bool(needs)),
                ]),
              ),
            ]),
          )
        })
      }
      "follow" =>
        following = Some(host.follow((ms, f) => w.schedule(ms, Some(ms), f)))
      "unfollow" => if following is Some(stop) { stop() }
      _ => ()
    }
    w.drain()
  }
  jo([("answers", ja(out)), ("reads", ja(reads))])
}
