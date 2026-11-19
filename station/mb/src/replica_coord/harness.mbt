// This package asked line by line (reader `--builder harness-replica-coord`), as station/test/mb-replica-coord.test.ts
// asks the TypeScript's (station/src/replica) on the same files and the same station:
// - `{op: "init", data, sep, lang, words, now}`: the World (its words, its clock at `now`);
// - `{op: "set", key, value}`: what the station's parts read at once (`here`, `home`, `places`, `rosters`);
// - `{op: "make", id, part, deps}`: a part made (`copies`, `retire`, `asks`, `handover`), `deps` its settings;
// - `{op: "call", id, part, method, args, body}`: one of its methods, answered `{id, value, body}` or `{id, error}`;
// - `{op: "fn", id, name, args}`: a function of the package (what is held to its TypeScript as it is);
// - `{op: "advance", id, ms}`: the clock moved, its timers due fired in order; `{op: "settle", id}`: what the program
//   set going done;
// - `{ret: n, value, body}` or `{ret: n, throw: {kind, message, code}}`: what the station answered of what this asked it,
//   `{call: n, name, args, body}` on stdout (`ask` another station, `store.*`, `hub.*`...); what it is only told,
//   `{tell: name, args}`; its log, `{log: level, part, words, fields}`.

///|
priv struct Timer {
  due : Double
  n : Int
  f : () -> Unit
  mut off : Bool
}

///|
priv struct Harness {
  host : @host.Host
  waiting : Map[Int, @effect.Deferred[Result[(J, Bytes?), Error]]]
  mut next : Int
  mut now : Double
  timers : Array[Timer]
  mut timer_n : Int
  mut holds : Int
  state : Map[String, J]
  mut fs : Fs
  words : Ref[@session_chats.Words]
  lang : Ref[String]
  mut going : Int
  idle : Array[@effect.Deferred[Unit]]
  copies : Ref[Copies?]
  retire : Ref[Retire?]
  asks : Ref[RetireAsks?]
  handover : Ref[Handover?]
}

///|
fn jc(v : Json) -> J {
  match v {
    Null => Null
    True => Bool(true)
    False => Bool(false)
    Number(n, ..) => Num(n)
    String(s) => js(s)
    Array(xs) => Arr(xs.map(jc))
    Object(m) => Obj(m.iter().map(e => (e.0, jc(e.1))).collect())
  }
}

///|
fn say(h : Harness, v : J) -> Unit {
  h.host.say(stringify(v))
}

///|
fn b64(b : Bytes) -> J {
  js(@base64.encode(b))
}

///|
fn unb64(v : J?) -> Bytes? {
  match v {
    Some(Str(u)) => Some(@base64.decode(@jsjson.sanitize_str(u))) catch { _ => None }
    _ => None
  }
}

///|
async fn Harness::call(self : Harness, name : String, args : Array[J], body? : Body) -> (J, Bytes?) {
  self.next += 1
  let n = self.next
  let done = @effect.Deferred::new()
  self.waiting[n] = done
  let fields = [("call", ji(n)), ("name", js(name)), ("args", ja(args))]
  match body {
    Some(b) => fields.push(("body", b64(b.whole(self.fs))))
    None => ()
  }
  say(self, jo(fields))
  match done.wait() {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
fn Harness::world(self : Harness) -> World {
  let h = self
  {
    host: h.host,
    fs: h.fs,
    call: async fn(name, args) { h.call(name, args).0 },
    ask_peer: async fn(station, request, body, itself) {
      let (v, b) = h.call("ask", [js(station), request, jb(itself)], body?)
      { value: v, body: b.map(x => Whole(x)) }
    },
    clock: {
      now: () => h.now,
      after: (ms, f) => {
        h.timer_n += 1
        let t : Timer = { due: h.now + (if ms > 0.0 { ms } else { 0.0 }), n: h.timer_n, f, off: false }
        h.timers.push(t)
        () => t.off = true
      },
    },
    log: (level, part, words, fields) => say(h, jo([("log", js(level)), ("part", js(part)), ("words", js(words)), ("fields", fields)])),
    words: h.words.val,
    lang: h.lang,
    fork: f => {
      h.going += 1
      ignore(
        h.host.rt.fork(async fn() {
          f() catch {
            e => say(h, jo([("log", js("defect")), ("part", js("harness")), ("words", js(message_of(e))), ("fields", Null)]))
          }
          h.going -= 1
          if h.going == 0 {
            let waiting = h.idle.copy()
            h.idle.clear()
            for d in waiting {
              ignore(d.succeed(()))
            }
          }
        }),
      )
    },
    tell: (name, args) => say(h, jo([("tell", js(name)), ("args", ja(args))])),
  }
}

///|
fn Harness::get(self : Harness, key : String) -> J {
  self.state.get(key).unwrap_or(Null)
}

///|
fn Harness::roster(self : Harness, ws : String) -> Array[Member]? {
  match at(self.get("rosters"), ws) {
    Some(Arr(xs)) => Some(xs.map(m => { id: text_at(m, "id"), name: text_at(m, "name"), tasks: yes_at(m, "tasks") }))
    _ => None
  }
}

///|
fn Harness::here(self : Harness) -> String? {
  str_of(Some(self.get("here")))
}

///|
fn Harness::home(self : Harness) -> String? {
  str_of(Some(self.get("home")))
}

///|
fn pairs_of(v : J) -> Array[(String, String)] {
  string_map(Some(v))
}

///|
fn Harness::work(self : Harness, w : World, deps : J) -> Work {
  if text_at(deps, "work") == "station" {
    {
      gather: async fn(data, db, ws, home, scratch, agent, keys) {
        w.part("work.gather", [js(data), js(db), js(ws), jb(home), js(scratch), jopt(agent), match keys { Some(k) => jstrs(k); None => Null }])
      },
      place: async fn(data, index, from, made, aside, placed, projects) {
        w.part("work.place", [js(data), js(index), js(from), jopt(made), jopt(aside), jopt(placed), jb(projects)])
      },
      preview: async fn(data, db, ws, home) { w.part("work.preview", [js(data), js(db), js(ws), jb(home)]) },
      drop: if yes_at(deps, "workDrop") { Some(async fn(id) { ignore(w.part("work.drop", [js(id)])) }) } else { None },
    }
  } else {
    let here = work_here(w.fs)
    {
      ..here,
      drop: if yes_at(deps, "workDrop") { Some(async fn(id) { ignore(w.part("work.drop", [js(id)])) }) } else { None },
    }
  }
}

///|
fn Harness::hold(self : Harness, w : World) -> () -> () -> Unit {
  let h = self
  () => {
    h.holds += 1
    let id = h.holds
    w.part_tell("hold", [ji(id)])
    () => w.part_tell("letGo", [ji(id)])
  }
}

///|
fn to_member_json(m : Member) -> J {
  jo([("id", js(m.id)), ("name", js(m.name))])
}

///|
async fn Harness::make(self : Harness, part : String, deps : J) -> Unit {
  let h = self
  let w = self.world()
  let data = text_at(deps, "data")
  match part {
    "copies" => {
      let d : CopiesDeps = {
        data,
        here: () => h.here(),
        places: () => h.get("places"),
        roster: ws => h.roster(ws),
        runner: {
          places: async fn(p) { ignore(w.part("runner.places", [p])) },
          pass: async fn(t) { w.part("runner.pass", [t]) },
          new_generations: async fn(a) { ignore(w.part("runner.newGenerations", [jn(a)])) },
          sources: async fn(hs) { w.part("runner.sources", [jstrs(hs)]) },
          close: async fn() { ignore(w.part("runner.close", [])) },
        },
        changed: () => w.part_tell("changed", []),
        restart: async fn() {
          if w.part("restart", []) is Bool(true) {
            Some(async fn() { ignore(w.part("restart.go", [])) })
          } else {
            None
          }
        },
        taking: Some(() => match h.retire.val {
          Some(r) => r.taking_now()
          None => []
        }),
      }
      h.copies.val = Some(Copies::new(w, d))
    }
    "retire" => {
      guard h.copies.val is Some(c) else { raise failed("copies first") }
      let jobs : RetireJobs? = if yes_at(deps, "jobs") {
        Some({
          start: async fn(s, j) { w.part("jobs.start", [js(s), j]) },
          running: async fn(s, n, c) { w.part("jobs.running", [js(s), js(n), js(c)]) is Bool(true) },
          say: async fn(s, t) { ignore(w.part("jobs.say", [js(s), js(t)])) },
        })
      } else {
        None
      }
      let d : RetireDeps = {
        data,
        here: () => h.here(),
        home: () => h.home(),
        roster: ws => h.roster(ws),
        copies: {
          settle_export: async fn() { c.settle_export() },
          bring_to: async fn(ws, peer) { c.bring_to(ws, peer) },
          take_over: async fn(ws, origin, gen, connects, ws_here) { c.take_over(ws, origin, gen, connects, ws_here) },
          formerly: () => c.was,
          restored: () => c.restored,
        },
        quiet: async fn(ws) { items(Some(w.part("quiet", [js(ws)]))) },
        unquiet: async fn(ws) { ignore(w.part("unquiet", [js(ws)])) },
        retired: async fn(ws) { ignore(w.part("retired", [js(ws)])) },
        accounts_own: async fn() { items(Some(w.part("accounts.own", []))).map(p => (text_at(p, "id"), text_at(p, "name"))) },
        accounts_move: async fn(id, to) { w.part("accounts.move", [js(id), js(to)]) },
        follow_accounts: Some(async fn(keys, map) {
          num_of(Some(w.part("followAccounts", [jstrs(keys), ja(map.map(p => ja([js(p.0), js(p.1)])))]))).unwrap_or(0.0).to_int()
        }),
        connects_of: async fn(ws) { strings_of(Some(w.part("connectsOf", [js(ws)]))) },
        bindings_of: async fn(cs) { pairs_of(w.part("bindingsOf", [jstrs(cs)])) },
        move_connects: async fn(ws, to) { ignore(w.part("moveConnects", [js(ws), js(to)])) },
        took: async fn(b, n) { ignore(w.part("took", [jo([("bindings", b), ("notes", n)])])) },
        repos_dir: text_at(deps, "reposDir"),
        room: async fn() {
          let r = w.part("room", [])
          (num_at(r, "free"), yes_at(r, "clones"))
        },
        has_git: async fn() { w.part("hasGit", []) is Bool(true) },
        git: async fn(dir, args) { text_at(w.part("git", [js(dir), jstrs(args)]), "out") },
        lack_most: num_at(deps, "lackMost").map(n => n.to_int()).unwrap_or(lack_most),
        work: h.work(w, deps),
        jobs_in: async fn(ws) { items(Some(w.part("jobsIn", [js(ws)]))) },
        connects_named: async fn(ws) { items(Some(w.part("connectsNamed", [js(ws)]))) },
        tell: if yes_at(deps, "tell") { Some(async fn(s, t) { ignore(w.part("tell", [js(s), js(t)])) }) } else { None },
        jobs,
        agent_home: Some(async fn(ws) { str_of(Some(w.part("agentHome", [js(ws)]))) }),
        drives: (station, session) => match h.asks.val {
          Some(a) => a.drives(station, session)
          None => false
        },
        of_workspace: Some(async fn(s, ws) { w.part("ofWorkspace", [js(s), js(ws)]) is Bool(true) }),
        hold: h.hold(w),
        changed: () => w.part_tell("changed", []),
        used: async fn(db, ws, home) { used_connects(w.fs, db, ws, home) },
      }
      h.retire.val = Some(Retire::new(w, d))
    }
    "asks" => {
      guard h.retire.val is Some(r) else { raise failed("retire first") }
      let d : AsksDeps = {
        data,
        here: () => h.here(),
        roster: ws => h.roster(ws),
        ws_of: async fn(s) { str_of(Some(w.part("wsOf", [js(s)]))) },
        card_post: async fn(s, text, card) {
          match w.part("cards.post", [js(s), js(text), card]) {
            Obj(_) as p => Some((num_at(p, "thread").unwrap_or(0.0), text_at(p, "ts")))
            _ => None
          }
        },
        card_state: async fn(s, t, ts) { text_at(jo([("s", w.part("cards.state", [js(s), jn(t), js(ts)]))]), "s") },
        notify: async fn(s, t) { ignore(w.part("notify", [js(s), js(t)])) },
        now: () => h.now,
        id: if yes_at(deps, "ids") {
          let n = Ref(0)
          Some(() => {
            n.val += 1
            "r_test\{n.val}"
          })
        } else {
          None
        },
        starts: yes_at(deps, "starts"),
        manages: v => text_at(v, "role") == "owner" || text_at(v, "role") == "admin",
      }
      h.asks.val = Some(RetireAsks::new(w, d, r))
    }
    "handover" => {
      let told : ToldSteps = {
        asked: async fn(to, key, make, progress) {
          let answer = w.ask(to, make())
          match progress {
            Some(p) => match at(answer, "progress") { Some(x) => p(x); None => () }
            None => ()
          }
          ignore(key)
          answer
        },
        run: async fn(_peer, _key, work, _measure) { work() },
        let_go: (to, key, words) => w.part_tell("told.letGo", [js(to), js(key), js(words)]),
        settle: async fn() { () },
      }
      let d : HandoverDeps = {
        data,
        here: () => h.here(),
        home: () => h.home(),
        roster: ws => h.roster(ws),
        connects: !yes_at(deps, "noConnects"),
        repos_dir: text_at(deps, "reposDir"),
        room: async fn() {
          let r = w.part("room", [])
          (num_at(r, "free"), num_at(r, "total"))
        },
        has_git: async fn() { w.part("hasGit", []) is Bool(true) },
        flush: if yes_at(deps, "flush") { Some(async fn(dir) { ignore(w.part("flush", [js(dir)])) }) } else { None },
        boot: () => num_at(h.get("boot"), "at").unwrap_or(0.0),
        git: if yes_at(deps, "git") { Some(async fn(dir, args) { text_at(w.part("git", [js(dir), jstrs(args)]), "out") }) } else { None },
        lack_most: num_at(deps, "lackMost").map(n => n.to_int()).unwrap_or(lack_most),
        hash_most: num_at(deps, "hashMost").unwrap_or(hash_most),
        pack_files: num_at(deps, "packFiles").map(n => n.to_int()),
        pack_bytes: num_at(deps, "packBytes"),
        work: h.work(w, deps),
        told,
        hold: Some(h.hold(w)),
        fail: if yes_at(deps, "fail") { Some(async fn(step) { ignore(w.part("fail", [js(step)])) }) } else { None },
        previous: None,
        previous_pid: None,
      }
      h.handover.val = Some(Handover::new(w, d))
    }
    _ => raise failed("no part \{part}")
  }
}

///|
fn arg(args : Array[J], i : Int) -> J {
  args.get(i).unwrap_or(Null)
}

///|
fn sarg(args : Array[J], i : Int) -> String {
  str_of(args.get(i)).unwrap_or("")
}

///|
fn opt_s(args : Array[J], i : Int) -> String? {
  str_of(args.get(i))
}

///|
async fn Harness::call_part(self : Harness, part : String, method : String, args : Array[J], body : Body?) -> (J, Body?) {
  let none = (v : J) => (v, None)
  match part {
    "copies" => {
      guard self.copies.val is Some(c) else { raise failed("no copies") }
      match method {
        "start" => none({ c.start(); Null })
        "close" => none({ c.close(); Null })
        "told" => none({ c.told(arg(args, 0)); Null })
        "settle" => none({ c.settle(); Null })
        "settleExport" => none({ c.settle_export(); Null })
        "placesChanged" => none({ c.places_changed(); Null })
        "now" => none(js(c.now(opt_s(args, 0), sarg(args, 1))))
        "heard" => none(jstrs(c.heard(sarg(args, 0), sarg(args, 1), strings_of(Some(arg(args, 2))))))
        "inWorkspace" => none(jb(c.in_workspace(sarg(args, 0), sarg(args, 1))))
        "answer" => {
          let a = c.answer(sarg(args, 0), arg(args, 1), body, opt_s(args, 2))
          (a.value, a.body)
        }
        "overview" => none(c.overview(sarg(args, 0), manage=arg(args, 1) is Bool(true)))
        "look" => none({ c.look(sarg(args, 0)); Null })
        "restorable" => none(ja(c.restorable(sarg(args, 0))))
        "formerly" => none(jstrs(c.was))
        "restored" => none(c.restored.unwrap_or(Null))
        "bringTo" => none(js(c.bring_to(sarg(args, 0), sarg(args, 1))))
        "takeOver" => {
          let extra = arg(args, 3)
          c.take_over(sarg(args, 0), sarg(args, 1), sarg(args, 2), string_map(at(extra, "connects")), str_at(extra, "ws"))
          none(Null)
        }
        "restore" => none({ c.restore(sarg(args, 0), sarg(args, 1), sarg(args, 2), text_at(arg(args, 3), "station")); Null })
        _ => raise failed("no copies.\{method}")
      }
    }
    "retire" => {
      guard self.retire.val is Some(r) else { raise failed("no retire") }
      match method {
        "start" => none({ r.start(); Null })
        "close" => none({ r.close(); Null })
        "settle" => none({ r.settle(); Null })
        "takingNow" => none(jstrs(r.taking_now()))
        "retire" => {
          let o = arg(args, 3)
          r.retire(sarg(args, 0), sarg(args, 1), sarg(args, 2), wait=yes_at(o, "wait"), driver=driver_of(at(o, "driver")))
          none(Null)
        }
        "cancel" => none({ r.cancel(sarg(args, 0)); Null })
        "again" => none({ r.again(sarg(args, 0), hand_over=!(at(arg(args, 1), "handOver") is Some(Bool(false)))); Null })
        "handOver" => none({ r.hand_over(sarg(args, 0), sarg(args, 1)); Null })
        "agentAsk" => none(r.agent_ask(sarg(args, 0), arg(args, 1)))
        "preview" => none(r.preview(sarg(args, 0)))
        "overview" => none(r.overview(sarg(args, 0)))
        "answer" => {
          guard self.copies.val is Some(c) else { raise failed("no copies") }
          none(r.answer((p, ws) => c.in_workspace(p, ws), sarg(args, 0), arg(args, 1), body, opt_s(args, 2)))
        }
        _ => raise failed("no retire.\{method}")
      }
    }
    "asks" => {
      guard self.asks.val is Some(a) else { raise failed("no asks") }
      match method {
        "tool" => none(a.tool(sarg(args, 0), arg(args, 1)))
        "settle" => none({ a.settle(); Null })
        "drives" => none(jb(a.drives(sarg(args, 0), sarg(args, 1))))
        "get" => none(a.get(sarg(args, 0)).unwrap_or(Null))
        "may" => {
          let at_ = arg(args, 2)
          none(jopt(a.may(arg(args, 0), arg(args, 1), num_at(at_, "thread").unwrap_or(0.0), text_at(at_, "ts"))))
        }
        "chosen" => {
          let at_ = arg(args, 3)
          a.chosen(arg(args, 0), arg(args, 1), sarg(args, 2), num_at(at_, "thread").unwrap_or(0.0), text_at(at_, "ts"))
          none(Null)
        }
        _ => raise failed("no asks.\{method}")
      }
    }
    "handover" => {
      guard self.handover.val is Some(h) else { raise failed("no handover") }
      match method {
        "start" => none({ h.start(); Null })
        "close" => none({ h.close(); Null })
        "settle" => none({ h.settle(); Null })
        "outs" => none(ja(h.outs_list()))
        "ins" => none(ja(h.ins_list()))
        "outOf" => none(h.out_of(sarg(args, 0)).unwrap_or(Null))
        "together" => none(jstrs(h.together(sarg(args, 0))))
        "chatOf" => none(js(h.chat_of(sarg(args, 0))))
        "check" => {
          let o = arg(args, 2)
          none(
            jopt(
              h.check(
                sarg(args, 0),
                sarg(args, 1),
                ignore_files=yes_at(o, "ignoreFiles"),
                planning=yes_at(o, "planning"),
                stopped_for=match at(o, "stoppedFor") {
                  Some(Obj(_) as s) => Some(s)
                  _ => None
                },
              ),
            ),
          )
        }
        "accountsOf" => none(jo(h.accounts_of(strings_of(Some(arg(args, 0))))))
        "handOver" => {
          let o = arg(args, 2)
          none(
            h.hand_over(sarg(args, 0), sarg(args, 1), wait=yes_at(o, "wait"), ignore_files=yes_at(o, "ignoreFiles"), stopped_for=match at(o, "stoppedFor") {
              Some(Obj(_) as s) => Some(s)
              _ => None
            }),
          )
        }
        "abandon" => none({ h.abandon(); Null })
        "reached" => none({ h.reached(sarg(args, 0)); Null })
        "comingIn" => none(ja(h.coming_in(sarg(args, 0)).map(jstrs)))
        "comingFrom" => none(jopt(h.coming_from(sarg(args, 0))))
        "arrived" => none(jb(h.arrived(sarg(args, 0), within_ms=num_of(args.get(1)))))
        "looked" => none(h.looked_at())
        "answer" => {
          let ws_peers = self.get("rosters")
          none(
            h.answer(
              (p, ws) => match at(ws_peers, ws) {
                Some(Arr(xs)) => xs.iter().any(m => text_at(m, "id") == p)
                _ => false
              },
              sarg(args, 0),
              arg(args, 1),
              body,
              opt_s(args, 2),
            ),
          )
        }
        _ => raise failed("no handover.\{method}")
      }
    }
    _ => raise failed("no part \{part}")
  }
}

///|
/// A function of the package, asked by its TypeScript name.
async fn Harness::function(self : Harness, name : String, args : Array[J]) -> J {
  let fs = self.fs
  match name {
    "keepers" => jstrs(keepers(sarg(args, 0), sarg(args, 1), strings_of(Some(arg(args, 2)))))
    "ranked" => jstrs(ranked(sarg(args, 0), sarg(args, 1), strings_of(Some(arg(args, 2)))))
    "asHead" => as_head(arg(args, 0)).unwrap_or(Null)
    "genMade" => jn(gen_made(sarg(args, 0)))
    "behind" => jb(behind(arg(args, 0), Held::of_json(arg(args, 1))))
    "holdsAll" => jb(holds_all(Held::of_json(arg(args, 0)), Held::of_json(arg(args, 1))))
    "moved" => js(moved(fs, sarg(args, 0), sarg(args, 1), sarg(args, 2)))
    "carriedTo" => js(carried_to(fs, sarg(args, 0), sarg(args, 1), sarg(args, 2), opt_s(args, 3)))
    "carriedPlace" => jb(carried_place(fs, sarg(args, 0), sarg(args, 1)))
    "cliKept" => jb(cli_kept(strings_of(Some(arg(args, 0)))))
    "listFile" => js(list_file(fs, sarg(args, 0), sarg(args, 1)))
    "connectsThere" => pairs_json(connects_there(strings_of(Some(arg(args, 0))), strings_of(Some(arg(args, 1))), sarg(args, 2), sarg(args, 3)))
    "mergePresets" => {
      let (file, taken) = merge_presets(arg(args, 0), arg(args, 1))
      jo([("file", file), ("taken", ji(taken))])
    }
    "jobWords" => js(job_words(items(Some(arg(args, 0)))))
    "movedNote" =>
      js(moved_note(fs, sarg(args, 0), sarg(args, 1), arg(args, 2), arg(args, 3), sarg(args, 4), sarg(args, 5), match arg(args, 6) { Arr(xs) => Some(xs); _ => None }))
    "movedHere" => js(moved_here(fs, sarg(args, 0), sarg(args, 1), sarg(args, 2), sarg(args, 3)))
    "floorOf" => jn(floor_of(num_of(args.get(0))))
    "afterOf" => after_of(sarg(args, 0), arg(args, 1))
    "newCtx" => new_ctx(arg(args, 0))
    "tell" => {
      let t = Told::nothing()
      let said = tell(t, arg(args, 0))
      jo([("said", jb(said)), ("told", t.to_json())])
    }
    "movedSaid" => {
      let job = arg(args, 1)
      js(moved_said(sarg(args, 0), text_at(job, "name"), num_at(job, "port"), str_at(job, "id"), opt_s(args, 2)))
    }
    "memoryMark" => js(memory_mark(sarg(args, 0)))
    "unanswered" => jb(unanswered(sarg(args, 0)))
    "base36" => js(base36(num_of(args.get(0)).unwrap_or(0.0)))
    "gb" => js(gb(num_of(args.get(0)).unwrap_or(0.0)))
    "mergeAgentHome" => {
      let from = arg(args, 4)
      merge_agent_home(fs, sarg(args, 0), arg(args, 1), sarg(args, 2), sarg(args, 3), text_at(from, "origin"), text_at(from, "name"), num_at(from, "at").unwrap_or(0.0)).to_json()
    }
    "sha256" => js(sha256_text(sarg(args, 0)))
    "folder.held" => FolderPlace::new(fs, sarg(args, 0)).held(sarg(args, 1), sarg(args, 2)).to_json()
    "folder.put" =>
      {
        FolderPlace::new(fs, sarg(args, 0)).put(sarg(args, 1), sarg(args, 2), sarg(args, 3), sarg(args, 4), sarg(args, 5), unb64(args.get(6)).unwrap_or(b""))
        Null
      }
    "folder.putFile" => {
      FolderPlace::new(fs, sarg(args, 0)).put_file(sarg(args, 1), sarg(args, 2), sarg(args, 3), sarg(args, 4))
      Null
    }
    "folder.drop" => {
      FolderPlace::new(fs, sarg(args, 0)).drop(sarg(args, 1), sarg(args, 2), sarg(args, 3), strings_of(Some(arg(args, 4))), strings_of(Some(arg(args, 5))))
      Null
    }
    "folder.origins" => origins_json(FolderPlace::new(fs, sarg(args, 0)).origins(sarg(args, 1)))
    "folder.pathOf" => jopt(FolderPlace::new(fs, sarg(args, 0)).path_of(sarg(args, 1), sarg(args, 2), opt_s(args, 3), sarg(args, 4)))
    "handOverFolders" => {
      let from = FolderPlace::new(fs, sarg(args, 0))
      let to = FolderPlace::new(fs, sarg(args, 1))
      jb(hand_over(from, to.place(), sarg(args, 2), sarg(args, 3)))
    }
    "level" => {
      // (a place a folder here, the own copy's batches and files as `own` says where they are)
      let place = FolderPlace::new(fs, sarg(args, 0)).place()
      let own = arg(args, 2)
      let dir = text_at(own, "dir")
      let sources = string_map(at(own, "sources"))
      let known = match arg(args, 3) {
        Obj(_) as k =>
          Some({
            gen: text_at(k, "gen"),
            batches: strings_of(at(k, "batches")),
            files: Map::from_array(strings_of(at(k, "files")).map(f => (f, true))),
            others: Map::from_array(strings_of(at(k, "others")).map(f => (f, true))),
            to: num_at(k, "to").unwrap_or(-1.0),
            made: num_at(k, "made").unwrap_or(-1.0),
          })
        _ => None
      }
      let done = level(
        place,
        sarg(args, 1),
        {
          head: at(own, "head").unwrap_or(Null),
          batch: async fn(name) { fs.files.read_bytes(fs.join([dir, name])).unwrap_or(b"") },
          sources: async fn(hashes) { sources.filter(s => hashes.contains(s.0)) },
        },
        known~,
      )
      match done {
        Behind => jo([("behind", jb(true))])
        Level(to, missing, k) => {
          let files = k.files.keys().collect()
          let others = k.others.keys().collect()
          jo([
            ("behind", jb(false)),
            ("to", jn(to)),
            ("missing", ji(missing)),
            (
              "known",
              jo([
                ("gen", js(k.gen)),
                ("batches", jstrs(k.batches)),
                ("files", jstrs(files)),
                ("others", jstrs(others)),
                ("to", jn(k.to)),
                ("made", jn(k.made)),
              ]),
            ),
          ])
        }
      }
    }
    "packBytes" => {
      let entries = items(Some(arg(args, 0))).map(e => { hash: text_at(e, "hash"), path: text_at(e, "path"), size: num_at(e, "size").unwrap_or(0.0) })
      let took = []
      let body = pack_bytes(fs, entries, arg(args, 1) is Bool(true), took, () => false)
      let bytes = body.whole(fs)
      jo([("bytes", b64(bytes)), ("took", ja(took.map(t => jo([("hash", js(t.hash)), ("path", js(t.path)), ("size", jn(t.size))]))))])
    }
    "receivePack" => {
      let o = arg(args, 2)
      receive_pack(fs, sarg(args, 0), Whole(unb64(args.get(1)).unwrap_or(b"")), {
        strict: yes_at(o, "strict"),
        flush: !(at(o, "flush") is Some(Bool(false))),
        name: str_at(o, "name"),
        count: num_at(o, "count").map(n => n.to_int()),
        on_file: None,
      })
      Null
    }
    "receiveFile" => {
      receive_file(fs, sarg(args, 0), sarg(args, 1), Whole(unb64(args.get(2)).unwrap_or(b"")))
      Null
    }
    "lackingIn" => jstrs(lacking_in(fs, sarg(args, 0), strings_of(Some(arg(args, 1)))))
    "sendGathered" => {
      // (the sending's other side the test's, each of its calls asked of it)
      let w = self.world()
      let o = arg(args, 1)
      let sending : Sending = {
        lacking: async fn(hashes, files) { w.part("sending.lacking", [jstrs(hashes), ja(files.map(f => f.to_json()))]) },
        put: async fn(hash, body, path, size) {
          let bytes = body.whole(fs)
          w.part("sending.put", [js(hash), b64(bytes), js(path), jn(size)])
        },
        put_pack: if yes_at(o, "packs") {
          Some(async fn(entries, body, strict) {
            let bytes = body.whole(fs)
            w.part("sending.putPack", [
              ja(entries.map(e => jo([("hash", js(e.hash)), ("path", js(e.path)), ("size", jn(e.size))]))),
              b64(bytes),
              jb(strict),
            ])
          })
        } else {
          None
        },
        took: Some(f => w.part_tell("sending.took", [jo([("hash", js(f.hash)), ("path", js(f.path)), ("size", jn(f.size))])])),
        pack_files: num_at(o, "packFiles").map(n => n.to_int()),
        pack_bytes: num_at(o, "packBytes"),
        most: num_at(o, "most").unwrap_or(2000.0).to_int(),
        stopping: () => false,
        total: b => w.part_tell("sending.total", [jn(b)]),
        done: b => w.part_tell("sending.done", [jn(b)]),
        adds: if yes_at(o, "adds") { Some(async fn(b) { ignore(w.part("sending.adds", [jn(b)])) }) } else { None },
      }
      jopt(send_gathered(fs, arg(args, 0), sending, yes_at(o, "strict"), jobs=items(at(o, "jobs")), indexed=yes_at(o, "indexed")))
    }
    "rebuildGits" => {
      let w = self.world()
      let o = arg(args, 4)
      let made = []
      let (m, f) = rebuild_gits(
        w,
        sarg(args, 0),
        sarg(args, 1),
        arg(args, 2),
        sarg(args, 3),
        async fn(dir, a) { text_at(w.part("git", [js(dir), jstrs(a)]), "out") },
        clone=!(at(o, "clone") is Some(Bool(false))),
        made=Some(async fn(g) { made.push(g.to_json()) }),
      )
      jo([("made", ji(m)), ("failed", ji(f)), ("gits", ja(made))])
    }
    "startCard" | "handOverCard" | "previewWords" | "statusWords" => {
      guard self.asks.val is Some(a) else { raise failed("asks first") }
      match name {
        "startCard" => js(a.start_card(sarg(args, 0), sarg(args, 1), arg(args, 2)))
        "handOverCard" => js(a.hand_over_card(sarg(args, 0), arg(args, 1)))
        "previewWords" => js(a.preview_words(arg(args, 0), sarg(args, 1)))
        _ => js(a.status_words(arg(args, 0)))
      }
    }
    _ => raise failed("no function \{name}")
  }
}

///|
fn error_json(e : Error) -> J {
  let fields = [("kind", js(kind_of(e))), ("message", js(message_of(e)))]
  let c = code_of(e)
  if c != "" {
    fields.push(("code", js(c)))
  }
  jo(fields)
}

///|
fn Harness::advance(self : Harness, ms : Double) -> Unit {
  let until = self.now + ms
  while true {
    let mut best : Timer? = None
    for t in self.timers {
      if t.off || t.due > until {
        continue
      }
      match best {
        Some(b) if b.due < t.due || (b.due == t.due && b.n < t.n) => ()
        _ => best = Some(t)
      }
    }
    guard best is Some(t) else { break }
    t.off = true
    if t.due > self.now {
      self.now = t.due
    }
    (t.f)()
  }
  self.now = until
  let left = self.timers.filter(t => !t.off)
  self.timers.clear()
  self.timers.push_iter(left.iter())
}

///|
/// Runs the harness till stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  let h : Harness = {
    host,
    waiting: {},
    next: 0,
    now: 0.0,
    timers: [],
    timer_n: 0,
    holds: 0,
    state: {},
    fs: Fs::new(host),
    words: Ref(@session_chats.Words::empty()),
    lang: Ref("en"),
    going: 0,
    idle: [],
    copies: Ref(None),
    retire: Ref(None),
    asks: Ref(None),
    handover: Ref(None),
  }
  say(h, jo([("ready", jb(true))]))
  while host.line() is Some(line) {
    let said = @jsjson.parse(line) catch { _ => continue }
    match at(said, "ret") {
      Some(Num(n)) => {
        match h.waiting.get(n.to_int()) {
          Some(done) => {
            h.waiting.remove(n.to_int())
            match at(said, "throw") {
              Some(t) => ignore(done.succeed(Err(Thrown(text_at(t, "kind"), t))))
              None => ignore(done.succeed(Ok((at(said, "value").unwrap_or(Null), unb64(at(said, "body"))))))
            }
          }
          None => ()
        }
        continue
      }
      _ => ()
    }
    let id = at(said, "id").unwrap_or(Null)
    let op = text_at(said, "op")
    let args = items(at(said, "args"))
    match op {
      "init" => {
        h.fs = Fs::new(host, sep=str_at(said, "sep").unwrap_or("/"))
        h.now = num_at(said, "now").unwrap_or(0.0)
        h.lang.val = str_at(said, "lang").unwrap_or("en")
        let words = at(said, "words").unwrap_or(Null)
        h.words.val = @session_chats.Words::new(at(words, "zh").unwrap_or(Obj([])), at(words, "en").unwrap_or(Obj([])))
        say(h, jo([("id", id), ("value", Null)]))
      }
      "set" => {
        h.state[text_at(said, "key")] = at(said, "value").unwrap_or(Null)
        say(h, jo([("id", id), ("value", Null)]))
      }
      "advance" => {
        h.advance(num_at(said, "ms").unwrap_or(0.0))
        say(h, jo([("id", id), ("value", jn(h.now))]))
      }
      _ =>
        ignore(
          host.rt.fork(name="harness ask", async fn() {
            let out = try {
              match op {
                "make" => {
                  h.make(text_at(said, "part"), at(said, "deps").unwrap_or(Obj([])))
                  jo([("id", id), ("value", Null)])
                }
                "call" => {
                  let body = unb64(at(said, "body")).map(b => Whole(b))
                  let (v, b) = h.call_part(text_at(said, "part"), text_at(said, "method"), args, body)
                  let fields = [("id", id), ("value", v)]
                  match b {
                    Some(x) => fields.push(("body", b64(x.whole(h.fs))))
                    None => ()
                  }
                  jo(fields)
                }
                "fn" => jo([("id", id), ("value", h.function(text_at(said, "name"), args))])
                "settle" => {
                  if h.going > 0 {
                    let d = @effect.Deferred::new()
                    h.idle.push(d)
                    d.wait()
                  }
                  jo([("id", id), ("value", Null)])
                }
                _ => raise failed("no op \{op}")
              }
            } catch {
              e => jo([("id", id), ("error", error_json(e))])
            }
            say(h, out)
          }),
        )
    }
    ignore(jc)
  }
}
