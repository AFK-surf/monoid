// The world an event stream's script is played on (harness.mbt; station/test/mb-events.test.ts makes the same for the
// TypeScript station): what the store and readers say, a clock of the test's, and answers given after what is being
// done now, as an async function's are.

///|
priv struct Timer {
  mut due : Double
  mut seq : Int32
  period : Double?
  f : () -> Unit
  mut live : Bool
}

///|
priv struct World {
  mut sessions : Map[String, J]
  mut threads : J
  mut jobs : J
  mut data : J
  mut now : Double
  timers : Array[Timer]
  mut timer_seq : Int32
  tasks : Array[() -> Unit]
  immediates : Array[() -> Unit]
  reads : Array[J]
  live : Map[String, Array[(Int32, (J) -> Unit)]]
  logins : Map[String, Array[(Int32, (Screen) -> Unit)]]
  held_pending : Array[(Result[J, String]) -> Unit]
  mut listener_seq : Int32
  /// The store's changes, told the events (a change the world makes as a summary is read: `duringSummary`).
  mut changed : (J) -> Unit
}

///|
fn World::new(data : J) -> World {
  let w = {
    sessions: Map([]),
    threads: jo([]),
    jobs: jo([]),
    data: jo([]),
    now: num_prop(data, "now").unwrap_or(0.0),
    timers: [],
    timer_seq: 0,
    tasks: [],
    immediates: [],
    reads: [],
    live: Map([]),
    logins: Map([]),
    held_pending: [],
    listener_seq: 0,
    changed: _ => (),
  }
  w.set(data)
  w
}

///|
/// What the world says, changed by `data`'s properties (each whole).
fn World::set(self : World, data : J) -> Unit {
  guard data is Obj(entries) else { return }
  for e in entries {
    self.data = with_prop(self.data, @jsjson.raw_text(e.0), e.1)
  }
  if self.data.get("sessions") is Some(Obj(sessions)) {
    self.sessions = Map([])
    for s in sessions {
      self.sessions[@jsjson.raw_text(s.0)] = s.1
    }
  }
  self.threads = self.data.get("threads").unwrap_or(jo([]))
  self.jobs = self.data.get("jobs").unwrap_or(jo([]))
}

///|
fn World::field(self : World, name : String) -> J? {
  self.data.get(name)
}

///|
fn World::seen_store(self : World) -> SeenStore {
  {
    session_ws: key => {
      match self.sessions.get(key) {
        Some(s) => Some(s.get("ws").unwrap_or(Null))
        None => None
      }
    },
    thread_sessions: id => strings_of(self.threads.get(num_text(id))),
    job_session: id => text_of(self.jobs.get(id)),
    session_there: key => self.sessions.contains(key),
    thread_there: id => self.threads.get(num_text(id)) is Some(_),
    handed_to: key => {
      match self.field("handed") {
        Some(h) =>
          match h.get(key) {
            Some(Null) | None => None
            Some(v) => Some(v)
          }
        None => None
      }
    },
  }
}

///|
/// An answer given after what is done now (a promise's).
fn World::later(self : World, f : () -> Unit) -> Unit {
  self.tasks.push(f)
}

///|
/// Until nothing is left to do: what was answered, then what waited for after it (setImmediate), one at a time.
fn World::drain(self : World) -> Unit {
  while true {
    if self.tasks.length() > 0 {
      let f = self.tasks.remove(0)
      f()
    } else if self.immediates.length() > 0 {
      let f = self.immediates.remove(0)
      f()
    } else {
      break
    }
  }
}

///|
fn World::schedule(
  self : World,
  ms : Double,
  period : Double?,
  f : () -> Unit,
) -> () -> Unit {
  self.timer_seq += 1
  let t = { due: self.now + ms, seq: self.timer_seq, period, f, live: true, }
  self.timers.push(t)
  () => t.live = false
}

///|
/// The clock moved on to `to`: each timer due by then in the order it is due, at its time.
fn World::advance(self : World, to : Double) -> Unit {
  while true {
    let mut next : Timer? = None
    for t in self.timers {
      if t.live && t.due <= to {
        match next {
          Some(n) if n.due < t.due || (n.due == t.due && n.seq < t.seq) => ()
          _ => next = Some(t)
        }
      }
    }
    guard next is Some(t) else { break }
    self.now = t.due
    match t.period {
      Some(p) => {
        self.timer_seq += 1
        t.due = t.due + p
        t.seq = self.timer_seq
      }
      None => t.live = false
    }
    (t.f)()
    self.drain()
  }
  self.now = to
  let live = self.timers.filter(t => t.live)
  self.timers.clear()
  self.timers.append(live)
}

///|
fn World::read(
  self : World,
  op : String,
  args : J,
  k : (Result[String, String]) -> Unit,
) -> Unit {
  self.reads.push(ja([js(op), args]))
  let got : Result[String, String] = match op {
    "summary" => {
      let key = str_prop(args, "key").unwrap_or("")
      if self.field("duringSummary") is Some(d) && d.get(key) is Some(change) {
        self.data = without(self.data, "duringSummary")
        (self.changed)(change)
      }
      match self.field("summaries") {
        Some(s) =>
          match s.get(key) {
            Some(Str(_) as f) if text_of(Some(f)) == Some("fail") =>
              Err("summary failed")
            Some(v) => Ok(stringify(v))
            None => Ok(stringify(jo([("key", js(key))])))
          }
        None => Ok(stringify(jo([("key", js(key))])))
      }
    }
    "job" => {
      let id = string_of(args.get("id"))
      match self.field("jobsRead") {
        Some(j) =>
          match j.get(id) {
            Some(v) => Ok(stringify(v))
            None => Err("no job \{id}")
          }
        None => Err("no job \{id}")
      }
    }
    "sharedOf" =>
      if self.field("sharedFails") is Some(Bool(true)) {
        Err("sharedOf failed")
      } else {
        let rows = match self.field("shared") {
          Some(Arr(rows)) => rows
          _ => []
        }
        match args.get("sessions") {
          Some(Null) => Ok(stringify(jo([("rows", ja(rows)), ("scope", Null)])))
          _ => {
            let ids = strings_of(args.get("sessions"))
            match args.get("threads") {
              Some(Arr(threads)) =>
                for t in threads {
                  ids.push(@jsjson.raw_text(@jsjson.js_string(t)))
                }
              _ => ()
            }
            let found = rows.filter(r => ids.contains(string_of(r.get("id"))))
            Ok(stringify(jo([("rows", ja(found)), ("scope", ja(ids.map(js)))])))
          }
        }
      }
    _ => Err(op)
  }
  self.later(() => k(got))
}

///|
fn World::overview(self : World, viewer : Viewer, lang : String) -> J {
  let key = "\{viewer.email}|\{lang}"
  match self.field("overviews") {
    Some(o) =>
      match o.get(key) {
        Some(v) => v
        None => jo([("viewer", js(viewer.email)), ("lang", js(lang))])
      }
    None => jo([("viewer", js(viewer.email)), ("lang", js(lang))])
  }
}

///|
/// The events' deps on this world.
fn World::deps(self : World) -> Deps {
  let store = self.seen_store()
  {
    read: (op, args, k) => self.read(op, args, k),
    said: (_, entries, lang) => {
      if entries.iter().any(e => has(e, "boom")) {
        return Err("said failed")
      }
      Ok(
        entries.map(e => {
          jopt([
            ("n", e.get("n")),
            ("text", e.get("text")),
            ("lang", Some(js(lang))),
          ])
        }),
      )
    },
    host: k => {
      let h = self.field("host")
      self.later(() => {
        k(
          match h {
            Some(Str(_) as f) if text_of(Some(f)) == Some("fail") => None
            Some(v) => Some(v)
            None => Some(Null)
          },
        )
      })
    },
    job_log: id => {
      match self.field("logs") {
        Some(l) if has(l, id) => Some("/nonexistent-stillfail-events/\{id}")
        _ => None
      }
    },
    log_now: (id, _, k) => {
      let got = match self.field("logs") {
        Some(l) =>
          match l.get(id) {
            Some(Null) | None => None
            Some(v) => Some(v)
          }
        None => None
      }
      // (awaited after a `.catch`: a turn more than a promise's `.then`)
      self.later(() => self.later(() => k(got)))
    },
    live: Some((key, from, last, send, brief) => {
      self.reads.push(
        ja([
          js("live"),
          js(key),
          jn(from),
          match last {
            Some(l) => jn(l)
            None => Null
          },
          Bool(brief),
        ]),
      )
      self.listener_seq += 1
      let id = self.listener_seq
      let list = match self.live.get(key) {
        Some(l) => l
        None => {
          let l = []
          self.live[key] = l
          l
        }
      }
      list.push((id, send))
      Some(() => {
        let kept = list.filter(p => p.0 != id)
        list.clear()
        list.append(kept)
      })
    }),
    held: Some(() => strings_of(self.field("held"))),
    held_now: Some((keys, k) => {
      self.reads.push(ja([js("heldNow"), ja(keys.map(js))]))
      self.held_pending.push(k)
    }),
    session_exists: key => self.sessions.contains(key),
    live_seen: Some((viewer, key) => {
      match self.sessions.get(key) {
        Some(s) => sees(viewer, s.get("ws").unwrap_or(Null))
        None => false
      }
    }),
    overview: Some((viewer, lang, k) => {
      self.reads.push(ja([js("overview"), js(viewer_key(viewer, lang))]))
      let value = self.overview(viewer, lang)
      self.later(() => k(Ok(value)))
    }),
    process_state: Some(key => {
      match self.field("states") {
        Some(s) => str_prop(s, key)
        None => None
      }
    }),
    followed: Some(() => self.reads.push(ja([js("followed")]))),
    seen: Some((viewer, of) => seen_of(store, viewer, of)),
    login_screen: Some((id, send) => {
      self.listener_seq += 1
      let lid = self.listener_seq
      let list = match self.logins.get(id) {
        Some(l) => l
        None => {
          let l = []
          self.logins[id] = l
          l
        }
      }
      list.push((lid, send))
      Some(() => {
        let kept = list.filter(p => p.0 != lid)
        list.clear()
        list.append(kept)
      })
    }),
    in_vault: Some((viewer, vault) => {
      match self.field("vaults") {
        Some(v) => strings_of(v.get(vault)).contains(viewer.email)
        None => false
      }
    }),
    now: () => self.now,
    after: (ms, f) => self.schedule(ms, None, f),
    every: (ms, f) => self.schedule(ms, Some(ms), f),
    immediate: f => self.immediates.push(f),
    watch: (_, _) => None,
    warn: (_, _) => (),
  }
}

///|
/// A client of the script: what its stream said, its answer.
priv struct Heard {
  text : StringBuilder
  mut answer : J
  mut stream : Stream?
}

///|
fn last_id(text : String) -> String? {
  let mut found = None
  for line in text.split("\n") {
    if line.has_prefix("id: ") {
      found = Some(line.view(start_offset=4).to_string())
    }
  }
  found
}

///|
/// An event stream's script played (the test's `play`): what each client heard, the answers, what was read and the
/// handovers.
fn play(script : J, data : J) -> J raise {
  let world = World::new(data)
  let run = str_prop(data, "run").unwrap_or("0a0b0c0d")
  let mut events = Events::new(world.deps(), run)
  world.changed = c => events.store_changed(c)
  let heard : Map[String, Heard] = Map([])
  let order = []
  let handed : Array[J] = []
  let mut last_handed : String? = None
  let mut take_from : Int32? = None
  guard script is Arr(steps) else { fail("no script") }
  for step in steps {
    let what = str_prop(step, "do").unwrap_or("")
    match what {
      "world" => world.set(step.get("set").unwrap_or(jo([])))
      "open" => {
        let name = str_prop(step, "name").unwrap_or("")
        let viewer = Viewer::of(step.get("viewer").unwrap_or(jo([])))
        let since = match step.get("since") {
          Some(Obj(_) as s) =>
            match heard.get(str_prop(s, "heard").unwrap_or("")) {
              Some(h) => last_id(h.text.to_string())
              None => None
            }
          Some(Str(_) as s) => text_of(Some(s))
          _ => None
        }
        let live = match step.get("live") {
          Some(Arr(items)) =>
            items.map(i => {
              (
                string_of(at(i, 0)),
                match at(i, 1) {
                  Some(Num(n)) => n
                  _ => 0.0
                },
                match at(i, 2) {
                  Some(Num(n)) => Some(n)
                  _ => None
                },
              )
            })
          _ => []
        }
        let logs = match step.get("logs") {
          Some(Arr(items)) =>
            items.map(i => {
              (
                string_of(at(i, 0)),
                match at(i, 1) {
                  Some(Num(n)) => n.to_int()
                  _ => 200
                },
              )
            })
          _ => []
        }
        let asked = {
          host: step.get("host") is Some(Bool(true)),
          live,
          logs,
          since,
          brief: step.get("brief") is Some(Bool(true)),
          logins: strings_of(step.get("logins")),
          running: step.get("running") is Some(Bool(true)),
        }
        let h = { text: StringBuilder::new(), answer: Null, stream: None, }
        heard[name] = h
        order.push(name)
        let runtimes = match step.get("runtimes") {
          Some(Str(_) as r) => Some(text_of(Some(r)).unwrap())
          _ => None
        }
        let supported = client_runtimes(
          match runtimes {
            Some(r) => [(runtimes_header, r)]
            None => []
          },
        )
        let compat = if takes_every(supported) {
          None
        } else {
          Some(CompatStream::new(supported))
        }
        events.open(
          viewer,
          @jscase.trim(str_prop(step, "lang").unwrap_or("zh")),
          asked,
          got => {
            match got {
              Ok(answer) => {
                h.answer = jo([
                  ("headers", jo(answer.headers.map(p => (p.0, js(p.1))))),
                ])
                h.stream = Some(answer.stream)
                answer.stream.relay(
                  piece => {
                    match compat {
                      Some(c) =>
                        for p in c.push(piece) {
                          h.text.write_string(p)
                        }
                      None => h.text.write_string(piece)
                    }
                  },
                  () => {
                    if compat is Some(c) && c.end() is Some(rest) {
                      h.text.write_string(rest)
                    }
                  },
                )
              }
              Err(_) => h.answer = jo([("error", Bool(true))])
            }
          },
        )
      }
      "close" =>
        if heard.get(str_prop(step, "name").unwrap_or(""))
          is Some({ stream: Some(s), .. }) {
          s.close()
        }
      "change" => events.store_changed(step.get("change").unwrap_or(jo([])))
      "overviewChanged" => events.overview_changed()
      "rowsChanged" =>
        events.rows_changed(
          str_prop(step, "viewer"),
          made=step.get("made") is Some(Bool(true)),
        )
      "screens" => {
        let by = step.get("byLang").unwrap_or(jo([]))
        events.screens(lang => by.get(lang).unwrap_or(Null))
      }
      "tell" =>
        events.tell(
          str_prop(step, "event").unwrap_or(""),
          step.get("data").unwrap_or(Null),
          str_prop(step, "of").unwrap_or(""),
          step.get("to").unwrap_or(jo([])),
        )
      "machineLogins" =>
        events.machine_logins(
          step.get("data").unwrap_or(Null),
          step.get("limited").unwrap_or(Null),
          str_prop(step, "of").unwrap_or(""),
        )
      "presets" => events.presets_changed()
      "heldTold" =>
        events.held_told(
          str_prop(step, "key").unwrap_or(""),
          step.get("message").unwrap_or(jo([])),
        )
      "heldNow" => {
        let now = step.get("now").unwrap_or(jo([]))
        let pending = world.held_pending.copy()
        world.held_pending.clear()
        for k in pending {
          world.later(() => {
            k(
              if step.get("fail") is Some(Bool(true)) {
                Err("failed")
              } else {
                Ok(now)
              },
            )
          })
        }
      }
      "live" => {
        let key = str_prop(step, "key").unwrap_or("")
        let message = step.get("message").unwrap_or(jo([]))
        if world.live.get(key) is Some(list) {
          for p in list.copy() {
            (p.1)(message)
          }
        }
      }
      "login" => {
        let id = str_prop(step, "id").unwrap_or("")
        let s = step.get("screen").unwrap_or(jo([]))
        let screen = {
          rows: strings_of(s.get("rows")),
          cursor: s.get("cursor").unwrap_or(Null),
          echo: s.get("echo") is Some(Bool(true)),
          live: s.get("live") is Some(Bool(true)),
        }
        if world.logins.get(id) is Some(list) {
          for p in list.copy() {
            (p.1)(screen)
          }
        }
      }
      "advance" => {
        let ms = num_prop(step, "ms").unwrap_or(0.0)
        let chunk = num_prop(step, "step").unwrap_or(1000.0)
        let mut left = ms
        while left > 0.0 {
          let d = if chunk < left { chunk } else { left }
          world.advance(world.now + d)
          world.drain()
          left -= d
        }
      }
      "handover" => {
        let pid = num_prop(step, "pid").unwrap_or(0.0).to_int()
        events.hand_over(pid, out => {
          match out {
            Written(text) => {
              last_handed = Some(text)
              handed.push(js(text))
            }
            Removed => {
              last_handed = None
              handed.push(Null)
            }
            Nothing => handed.push(Null)
          }
        })
      }
      "restart" => {
        events = Events::new(
          world.deps(),
          str_prop(step, "run").unwrap_or(run),
          taking=true,
        )
        world.changed = c => events.store_changed(c)
        take_from = num_prop(step, "from").map(d => d.to_int())
      }
      "gone" => {
        // (the file is read once and removed: what is handed over is taken up by one process alone)
        let text = last_handed
        last_handed = None
        events.take_up(text, from?=take_from)
      }
      other => fail("no step \{other}")
    }
    world.drain()
  }
  jo([
    (
      "streams",
      jo(order.map(n => (n, js(heard.get(n).unwrap().text.to_string())))),
    ),
    ("answers", jo(order.map(n => (n, heard.get(n).unwrap().answer)))),
    ("reads", ja(world.reads)),
    ("handed", ja(handed)),
    ("at", js(events.log.at())),
  ])
}
