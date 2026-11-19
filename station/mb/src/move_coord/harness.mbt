// The program's harness (reader `--builder harness-move-coord`): what station/test/mb-move-coord.test.ts holds these
// parts to the TypeScript of station/src/move/ with. A line a message both ways, JSON:
// - asked of the program: `{"cmd": name, "id": n, ...}`, answered `{"done": n, "ok": value}` or `{"done": n, "err":
//   {"kind", "message"}}`; each runs as a fiber of its own, so a part waiting on the test goes on as the test asks more;
// - what the program asks of the test (a part's world: its store, its other station, its clock): `{"call": name,
//   "id": m, "inst": instance, "args": [...]}`, answered `{"re": m, "ok": value}` or `{"re": m, "err": {...}}`;
// - told the test without an answer: `{"tell": name, ...}` (a timer armed or let go);
// - every message the test sends says its clock (`now`); a timer's coming due is the test's `fire`, a callback given
//   the test (`{"cb": id}`) is called by `cb`; `sync` is answered once nothing here can go on before the test answers.
// Files are the machine's own, through the shell, each write done before the next line is read.

///|
priv struct Rpc {
  host : @host.Host
  mut next : Int
  waiting : Map[Int, @effect.Deferred[J]]
  cbs : Map[Int, async (Array[J]) -> J]
  timers : Map[Int, async () -> Unit]
  mut now : Int64
  insts : Map[String, Inst]
  mut say : Say
}

///|
priv enum Inst {
  KSet(KeptSet)
  KMap(KeptMap)
  KLog(KeptLog)
  KLent(LentLog)
  ToldI(Told)
  Sched(Scheduler)
  Mod(Module, J)
  AccountsI(Accounts)
  ReposI(Repos)
  SettingsI(Settings)
  VaultI(Vault)
  JobsI(Jobs)
  SizesI(Sizes)
  MovesI(Moves, async (String, J, String?, Bytes_?) -> J)
}

///|
fn Rpc::send(self : Rpc, j : J) -> Unit {
  self.host.say(stringify(j))
}

///|
fn err_j(e : Error) -> J {
  jo([("kind", js(kind_of(e))), ("message", js(message_of(e)))])
}

///|
/// What the test is asked: `fn_` of `inst`, with `args`.
async fn Rpc::call(self : Rpc, inst : String, fn_ : String, args : Array[J]) -> J {
  self.next += 1
  let id = self.next
  let done = @effect.Deferred::new()
  self.waiting[id] = done
  self.send(
    jo([
      ("call", js(fn_)),
      ("id", ji(id)),
      ("inst", js(inst)),
      ("args", ja(args)),
    ]),
  )
  done.wait()
}

///|
/// `f` given the test to call (`{"cb": id}`).
fn Rpc::callback(self : Rpc, f : async (Array[J]) -> J) -> J {
  self.next += 1
  self.cbs[self.next] = f
  jo([("cb", ji(self.next))])
}

///|
/// The test's clock, as this program's parts see it.
fn Rpc::clock(self : Rpc, inst : String) -> Clock {
  {
    now: () => self.now,
    after: (ms, f) => {
      self.next += 1
      let id = self.next
      self.timers[id] = async fn() { f() }
      self.send(
        jo([
          ("tell", js("after")),
          ("inst", js(inst)),
          ("timer", ji(id)),
          ("ms", ji(ms)),
        ]),
      )
      () => {
        if self.timers.contains(id) {
          self.timers.remove(id)
          self.send(jo([("tell", js("cancel")), ("timer", ji(id))]))
        }
      }
    },
    every: (ms, f) => {
      self.next += 1
      let id = self.next
      self.timers[id] = f
      self.send(
        jo([
          ("tell", js("every")),
          ("inst", js(inst)),
          ("timer", ji(id)),
          ("ms", ji(ms)),
        ]),
      )
      () => {
        if self.timers.contains(id) {
          self.timers.remove(id)
          self.send(jo([("tell", js("cancel")), ("timer", ji(id))]))
        }
      }
    },
    spawn: f => ignore(self.host.rt.fork(f)),
  }
}

///|
/// The machine's files, each change done at once (what the harness's `sync` needs: no write left under way).
fn Rpc::disk(self : Rpc) -> Disk {
  let host = self.host
  let base = host_disk(host)
  {
    ..base,
    append: async fn(path, text) {
      let was = (base.read)(path).unwrap_or("")
      (base.write)(path, was + text)
    },
    spawn: f => ignore(host.rt.fork(f)),
  }
}

///|
fn Rpc::fs(self : Rpc, inst : String) -> Fs {
  let base = host_fs(self.host)
  {
    ..base,
    write_from: async fn(path, next) {
      let buf = @buffer.new()
      while true {
        match next() {
          Some(p) => buf.write_bytes(p)
          None => break
        }
      }
      ignore(self.call(inst, "fs.writeFrom", [js(path), js(@utf8.decode_lossy(buf.to_bytes()))]))
    },
  }
}

///|
fn strs(j : J?) -> Array[String] {
  arr(j).unwrap_or([]).filter_map(x => text(Some(x)))
}

///|
fn opt_text(j : J) -> String? {
  text(Some(j))
}

///|
fn need_list(j : J?) -> Array[Need] {
  arr(j).unwrap_or([]).map(need_of)
}

///|
fn opt_j(v : J?) -> J {
  match v {
    Some(x) => x
    None => Null
  }
}

///|
fn str_j(v : String?) -> J {
  match v {
    Some(s) => js(s)
    None => Null
  }
}

///|
fn waits_opt(j : J?) -> Waits? {
  match j {
    Some(Obj(_) as w) => Some(waits_of(w))
    _ => None
  }
}

///|
fn need_pair_j(p : (Need, Waits)) -> J {
  jo([("item", p.0.to_j()), ("waitsFor", p.1.to_j())])
}

///|
/// A page as the test gives it (`{keys, rows, handle}`): a session's row asked of the test by its handle.
fn Rpc::page(self : Rpc, inst : String, j : J) -> Page {
  let handle = get(Some(j), "handle").unwrap_or(Null)
  {
    keys: strs(get(Some(j), "keys")),
    rows: arr(get(Some(j), "rows")).unwrap_or([]),
    session: async fn(k) {
      match self.call(inst, "page.session", [handle, js(k)]) {
        Null => None
        r => Some(r)
      }
    },
    handle,
  }
}

///|
fn page_j(p : Page?) -> J {
  match p {
    Some(p) => p.handle
    None => Null
  }
}

///|
/// What the test's world answers as a function of `inst`'s (its name), each argument and answer JSON.
fn Rpc::dep(self : Rpc, inst : String, name : String) -> async (Array[J]) -> J {
  async fn(args) { self.call(inst, name, args) }
}

///|
fn Rpc::ask(self : Rpc, inst : String) -> Ask {
  {
    ask: async fn(station, request, bytes) {
      let b = match bytes {
        None => J::Null
        Some(FileBytes(path, offset, size)) =>
          jo([("file", js(path)), ("offset", jl(offset)), ("size", jl(size))])
        Some(Came(next)) => {
          let buf = @buffer.new()
          while true {
            match next() {
              Some(p) => buf.write_bytes(p)
              None => break
            }
          }
          jo([("text", js(@utf8.decode_lossy(buf.to_bytes())))])
        }
      }
      self.call(inst, "ask", [js(station), request, b])
    },
  }
}

///|
fn has(spec : J, name : String) -> Bool {
  strs(get(Some(spec), "has")).contains(name)
}

///|
/// A module whose every function is the test's (`mod.<id>.<fn>` of `inst`), those it has as `spec` says.
fn Rpc::proxy_module(self : Rpc, inst : String, spec : J) -> Module {
  let id = text(get(Some(spec), "id")).unwrap_or("")
  let call = async fn(f : String, args : Array[J]) -> J {
    self.call(inst, "mod.\{id}.\{f}", args)
  }
  let bool_of = (j : J) => j is Bool(true)
  {
    id,
    needs: strs(get(Some(spec), "needs")),
    plan: async fn(ws, to, reads) {
      let r = match reads {
        Some(r) => {
          (r.load)()
          ja((r.loaded)().map(p => p.handle))
        }
        None => Null
      }
      arr(Some(call("plan", [js(ws), js(to), r]))).unwrap_or([])
    },
    move: async fn(item, to, progress, stopped_for) {
      let cb = self.callback(async fn(args) {
        progress(args.get(0).unwrap_or(Null))
        Null
      })
      ignore(
        call("move", [
          item,
          js(to),
          cb,
          match stopped_for {
            Some(w) => jo([("stoppedFor", w.to_j())])
            None => Null
          },
        ]),
      )
    },
    back: async fn(item, from, stopped_for) {
      ignore(
        call("back", [
          item,
          js(from),
          match stopped_for {
            Some(w) => jo([("stoppedFor", w.to_j())])
            None => Null
          },
        ]),
      )
    },
    state: async fn(item) { call("state", [item]) },
    usable_here: if has(spec, "usableHere") {
      Some(async fn(item) { bool_of(call("usableHere", [item])) })
    } else {
      None
    },
    usable_there: if has(spec, "usableThere") {
      Some(async fn(item) { bool_of(call("usableThere", [item])) })
    } else {
      None
    },
    can_lend: if has(spec, "canLend") {
      Some(async fn(item) { bool_of(call("canLend", [item])) })
    } else {
      None
    },
    lend: if has(spec, "lend") {
      Some(async fn(item, to, for_) {
        ignore(call("lend", [item, js(to), ja(for_.map(n => n.to_j()))]))
      })
    } else {
      None
    },
    lent_for: if has(spec, "lentFor") {
      Some(async fn(item, to, for_) {
        ignore(call("lentFor", [item, js(to), ja(for_.map(n => n.to_j()))]))
      })
    } else {
      None
    },
    left: if has(spec, "left") {
      Some(async fn(items) { ignore(call("left", [ja(items.map(n => n.to_j()))])) })
    } else {
      None
    },
    is_here: if has(spec, "isHere") {
      Some(async fn(item) { bool_of(call("isHere", [item])) })
    } else {
      None
    },
    abandon: if has(spec, "abandon") {
      Some(() => (self.clock(inst).spawn)(async fn() { ignore(call("abandon", [])) }))
    } else {
      None
    },
    ready: if has(spec, "ready") {
      Some(async fn(item, to) { opt_text(call("ready", [item, js(to)])) })
    } else {
      None
    },
    stop: if has(spec, "stop") {
      Some(async fn(item, w) { ignore(call("stop", [item, w.to_j()])) })
    } else {
      None
    },
    resume: if has(spec, "resume") {
      Some(async fn(item) { ignore(call("resume", [item])) })
    } else {
      None
    },
  }
}

///|
/// The plan's reads as the test gives them (`reads.pages`, `reads.worktrees` of `inst`).
fn Rpc::proxy_reads(self : Rpc, inst : String, ws : String) -> PlanReads {
  let pages : Array[Page] = []
  let done = Ref(false)
  let iterate = async fn(each : async (Page) -> Unit) -> Unit {
    let mut i = 0
    while true {
      if i > 0 {
        @effect.pause()
      }
      if i >= pages.length() {
        if done.val {
          return
        }
        let got = self.call(inst, "reads.page", [js(ws), ji(pages.length())])
        if got is Null {
          done.val = true
          return
        }
        pages.push(self.page(inst, got))
      }
      each(pages[i])
      i += 1
    }
  }
  {
    pages: iterate,
    load: async fn() { iterate(async fn(_) {  }) },
    loaded: () => pages,
    worktrees: async fn(dir) {
      arr(Some(self.call(inst, "reads.worktrees", [js(dir)])))
      .unwrap_or([])
      .map(r => (text(get(Some(r), "repo")).unwrap_or(""), text(get(Some(r), "url")).unwrap_or("")))
    },
  }
}

///|
fn Rpc::sched_deps(self : Rpc, inst : String, c : J, modules : Array[Module]) -> SchedulerDeps {
  let spec = get(Some(c), "deps").unwrap_or(jo([]))
  let on = (k : String) => strs(get(Some(spec), "has")).contains(k)
  let call = self.dep(inst, "")
  ignore(call)
  {
    data: text(get(Some(c), "data")).unwrap_or(""),
    disk: self.disk(),
    clock: self.clock(inst),
    say: self.say,
    modules,
    changed: if on("changed") {
      Some(() => (self.clock(inst).spawn)(async fn() { ignore(self.call(inst, "changed", [])) }))
    } else {
      None
    },
    progress: if on("progress") {
      Some((n, p) => (self.clock(inst).spawn)(async fn() {
        ignore(self.call(inst, "progress", [n.to_j(), p]))
      }))
    } else {
      None
    },
    tell_arrived: if on("tellArrived") {
      Some(async fn(to, n) { ignore(self.call(inst, "tellArrived", [js(to), n.to_j()])) })
    } else {
      None
    },
    now: if on("now") { Some(() => self.now.to_double()) } else { None },
    refusal: if on("refusal") {
      Some(async fn(ws, s) { opt_text(self.call(inst, "refusal", [js(ws), js(s)])) })
    } else {
      None
    },
    room_for_all: if on("roomForAll") {
      Some(async fn(ws, s, plan) { opt_text(self.call(inst, "roomForAll", [js(ws), js(s), plan])) })
    } else {
      None
    },
    hold: if on("hold") {
      Some(() => {
        self.next += 1
        let id = self.next
        self.send(jo([("tell", js("hold")), ("inst", js(inst)), ("hold", ji(id))]))
        () => self.send(jo([("tell", js("letGo")), ("inst", js(inst)), ("hold", ji(id))]))
      })
    } else {
      None
    },
    restarted: if on("restarted") {
      Some(() => text(get(Some(spec), "restarted")).unwrap_or(""))
    } else {
      None
    },
    reads: if on("reads") { Some(ws => self.proxy_reads(inst, ws)) } else { None },
    turn: if on("turn") {
      Some((b, s) => self.send(
        jo([("tell", js("turn")), ("inst", js(inst)), ("on", jb(b)), ("station", js(s))]),
      ))
    } else {
      None
    },
  }
}

///|
fn held_j(h : Held) -> J {
  let by = []
  for k, v in h.by_module {
    by.push((k, ja(v)))
  }
  let at = []
  for k, v in h.at {
    at.push((k, ji(v)))
  }
  let counts = []
  for k, v in h.counts {
    counts.push((k, jo([("done", ji(v.0)), ("total", ji(v.1)), ("cannot", ji(v.2))])))
  }
  jo([
    ("plan", h.plan),
    ("byModule", jo(by)),
    ("at", jo(at)),
    ("counts", jo(counts)),
  ])
}

///|
fn sel_of(j : J?) -> Selection {
  Selection::of(j.unwrap_or(jo([])))
}

///|
fn arg(c : J, i : Int) -> J {
  arr(get(Some(c), "args")).unwrap_or([]).get(i).unwrap_or(Null)
}

///|
fn arg_text(c : J, i : Int) -> String {
  text(Some(arg(c, i))).unwrap_or("")
}

///|
fn arg_opt(c : J, i : Int) -> String? {
  text(Some(arg(c, i)))
}

///|
async fn Rpc::sched_call(self : Rpc, s : Scheduler, c : J) -> J {
  let m = text(get(Some(c), "method")).unwrap_or("")
  match m {
    "plan" => s.plan(arg_text(c, 0), arg_text(c, 1))
    "planShown" => s.plan_shown(arg_text(c, 0), arg_text(c, 1))
    "move" => s.move_soon(arg_text(c, 0), arg_text(c, 1), sel_of(Some(arg(c, 2))), arg_opt(c, 3)).wait()
    "back" => s.back_soon(arg_text(c, 0), arg_text(c, 1), sel_of(Some(arg(c, 2))), arg_opt(c, 3)).wait()
    "moveSoon" => {
      let d = s.move_soon(arg_text(c, 0), arg_text(c, 1), sel_of(Some(arg(c, 2))), arg_opt(c, 3))
      self.keep_turn(d)
    }
    "backSoon" => {
      let d = s.back_soon(arg_text(c, 0), arg_text(c, 1), sel_of(Some(arg(c, 2))), arg_opt(c, 3))
      self.keep_turn(d)
    }
    "start" => {
      s.start()
      Null
    }
    "settleStopped" =>
      ja(s.settle_stopped(from?=arg_opt(c, 0), module?=arg_opt(c, 1)).map(n => n.to_j()))
    "noteStopped" => {
      s.note_stopped(
        need_of(arg(c, 0)),
        waits_of(arg(c, 1)),
        arg_text(c, 2),
        hold=!(arg(c, 3) is Bool(false)),
      )
      Null
    }
    "forget" => {
      s.forget(need_list(Some(arg(c, 0))))
      Null
    }
    "arrived" => ja(s.arrived(need_of(arg(c, 0))).map(n => n.to_j()))
    "stopTurn" => jb(s.stop_turn(arg_opt(c, 0)))
    "stopping" => jb(s.stopping())
    "busy" => jb(s.busy())
    "current" =>
      match s.current_item() {
        Some(n) => n
        None => Null
      }
    "last" => opt_j(s.last(arg_text(c, 0)))
    "stopped" => ja(s.stopped_list().map(need_pair_j))
    "hasStopped" => jb(s.has_stopped(at?=arg_opt(c, 0)))
    "waitsOn" => jb(s.waits_on(arg_text(c, 0)))
    "held" =>
      match s.held(arg_text(c, 0), arg_text(c, 1)) {
        Some(h) => held_j(h)
        None => Null
      }
    "nowOf" => s.now_of(arg(c, 0))
    "settle" => {
      s.settle()
      s.written()
      Null
    }
    "stoppedLooked" => ji(s.stopped_looked())
    "view" => {
      let o = arg(c, 0)
      let held = s.held(text(get(Some(o), "ws")).unwrap_or(""), text(get(Some(o), "to")).unwrap_or(""))
      let plan = match held {
        Some(h) => h.plan
        None => s.plan(text(get(Some(o), "ws")).unwrap_or(""), text(get(Some(o), "to")).unwrap_or(""))
      }
      move_view(
        plan,
        s.module_ids(),
        s.stopped_list(),
        module?=text(get(Some(o), "module")),
        after?=text(get(Some(o), "after")),
        limit=num(get(Some(o), "limit")).map(d => d.to_int()).unwrap_or(move_page),
        last?=s.last(text(get(Some(o), "ws")).unwrap_or("")),
        stopping=s.stopping(),
        current?=s.current(),
        held?=held.map(h => (s, h)),
      )
    }
    _ => raise Failed("no scheduler method \{m}")
  }
}

///|
/// A turn begun and not waited on: its id, whose `turn.wait` is its outcome.
fn Rpc::keep_turn(self : Rpc, d : @effect.Deferred[J]) -> J {
  self.next += 1
  let id = self.next
  self.cbs[id] = async fn(_) { d.wait() }
  ji(id)
}

///|
fn Rpc::kept_call(self : Rpc, inst : Inst, c : J) -> J raise {
  let m = text(get(Some(c), "method")).unwrap_or("")
  match inst {
    KSet(k) =>
      match m {
        "values" => jstrs(k.values())
        "has" => jb(k.has(arg_text(c, 0)))
        "size" => ji(k.size())
        _ => raise Failed("async")
      }
    KMap(k) =>
      match m {
        "get" => opt_j(k.get(arg_text(c, 0)))
        "entries" => ja(k.entries().map(p => ja([js(p.0), p.1])))
        _ => raise Failed("async")
      }
    KLog(k) =>
      match m {
        "get" => opt_j(k.get(arg_text(c, 0)))
        "has" => jb(k.has(arg_text(c, 0)))
        "values" => ja(k.values())
        "keys" => jstrs(k.keys())
        "size" => ji(k.size())
        _ => raise Failed("async")
      }
    KLent(k) =>
      match m {
        "get" => opt_j(k.get(arg_text(c, 0)))
        "entries" => ja(k.entries().map(p => ja([js(p.0), p.1])))
        "sharesFor" => jstrs(k.shares_for(arg_text(c, 0)))
        "forCount" => ji(k.for_count(arg_text(c, 0)))
        "base" => opt_j(k.base(arg_text(c, 0)))
        _ => raise Failed("async")
      }
    _ => raise Failed("not kept")
  }
}

///|
async fn Rpc::kept_async(self : Rpc, inst : Inst, c : J) -> J {
  let m = text(get(Some(c), "method")).unwrap_or("")
  match (try Ok(self.kept_call(inst, c)) catch { e => Err(e) }) {
    Ok(v) => return v
    Err(Failed("async")) => ()
    Err(e) => raise e
  }
  match inst {
    KSet(k) =>
      match m {
        "add" => k.add(arg_text(c, 0))
        "delete" => k.delete(arg_text(c, 0))
        _ => raise Failed("no such method \{m}")
      }
    KMap(k) =>
      match m {
        "set" => k.set(arg_text(c, 0), arg(c, 1))
        "delete" => k.delete(arg_text(c, 0))
        _ => raise Failed("no such method \{m}")
      }
    KLog(k) =>
      match m {
        "set" => k.set(arg_text(c, 0), arg(c, 1))
        "delete" => k.delete(arg_text(c, 0))
        "many" =>
          k.many(
            arr(Some(arg(c, 0)))
            .unwrap_or([])
            .map(p => {
              let a = arr(Some(p)).unwrap_or([])
              (
                text(a.get(0)).unwrap_or(""),
                match a.get(1) {
                  None => None
                  Some(v) => Some(v)
                },
              )
            }),
          )
        "written" => k.written()
        _ => raise Failed("no such method \{m}")
      }
    KLent(k) =>
      match m {
        "setBase" => k.set_base(arg_text(c, 0), arg(c, 1))
        "set" => k.set(arg_text(c, 0), arg(c, 1))
        "lentFor" => k.lent_for(arg_text(c, 0), arg_text(c, 1))
        "unlent" => k.unlent(arg_text(c, 0), arg_text(c, 1))
        "delete" => k.delete(arg_text(c, 0))
        "written" => k.written()
        _ => raise Failed("no such method \{m}")
      }
    _ => raise Failed("not kept")
  }
  Null
}

///|
fn Rpc::inst(self : Rpc, c : J) -> Inst raise {
  let name = text(get(Some(c), "inst")).unwrap_or("")
  match self.insts.get(name) {
    Some(i) => i
    None => raise Failed("no instance \{name}")
  }
}

///|
/// A module of this package made with every function of its world the test's (of `inst`).
fn Rpc::make_module(self : Rpc, inst : String, c : J) -> Inst raise {
  let kind = text(get(Some(c), "kind")).unwrap_or("")
  let data = text(get(Some(c), "data")).unwrap_or("")
  let here = text(get(Some(c), "here")).unwrap_or("")
  let call = self.dep(inst, "")
  ignore(call)
  let d = (name : String) => self.dep(inst, name)
  let ask_j = async fn(s : String, r : J) -> J { (self.ask(inst).ask)(s, r, None) }
  let random = (n : Int) => text(Some(self.host_random_or_test(inst, n))).unwrap_or("")
  let names = get(Some(c), "names")
  let name = fn(id : String) -> String {
    match text(get(names, id)) {
      Some(n) => n
      None => slice_to(id, 12)
    }
  }
  let told = match get(Some(c), "told") {
    Some(Str(_) as t) =>
      match self.insts.get(text(Some(t)).unwrap_or("")) {
        Some(ToldI(t)) => Some(t)
        _ => None
      }
    _ => None
  }
  match kind {
    "accounts" => {
      let a = accounts_module({
        used: async fn(ws) {
          arr(Some(d("used")([js(ws)])))
          .unwrap_or([])
          .map(p => {
            let pa = arr(Some(p)).unwrap_or([])
            (
              text(pa.get(0)).unwrap_or(""),
              match pa.get(1) {
                None | Some(Null) => None
                Some(v) => Some(v)
              },
            )
          })
        },
        shared: async fn(id) { d("shared")([js(id)]) is Bool(true) },
        move_profile: async fn(id, to) { d("moveProfile")([js(id), js(to)]) },
        present: if has(c, "present") {
          Some(async fn(id) { opt_text(d("present")([js(id)])) })
        } else {
          None
        },
        ask: ask_j,
        here: () => here,
        data: if data == "" { None } else { Some(data) },
        profile: if has(c, "profile") {
          Some(async fn(id) {
            match d("profile")([js(id)]) {
              Null => None
              v => Some(v)
            }
          })
        } else {
          None
        },
        share_moves: if has(c, "shareMoves") {
          Some({
            move: async fn(id, to, made) {
              let cb = self.callback(async fn(args) {
                made(text(args.get(0)).unwrap_or(""))
                Null
              })
              d("share.move")([js(id), js(to), cb])
            },
            unshare: async fn(share, stations) {
              d("share.unshare")([js(share), jstrs(stations)]) is Bool(true)
            },
            lend: if has(c, "lend") {
              Some(async fn(id, to) {
                let r = d("share.lend")([js(id), js(to)])
                (
                  text(get(Some(r), "share")).unwrap_or(""),
                  is_true(get(Some(r), "made")),
                  is_true(get(Some(r), "widened")),
                )
              })
            } else {
              None
            },
            unlend: Some(async fn(share, to, made, widened) {
              ignore(d("share.unlend")([js(share), js(to), jb(made), jb(widened)]))
            }),
            uses_there: if has(c, "usesThere") {
              Some(async fn(to, share) {
                num(Some(d("share.usesThere")([js(to), js(share)]))).map(n => n.to_int())
              })
            } else {
              None
            },
            handed_on: if has(c, "handedOn") {
              Some(async fn(to, pid) { strs(Some(d("share.handedOn")([js(to), js(pid)]))) })
            } else {
              None
            },
          })
        } else {
          None
        },
        disk: self.disk(),
        clock: self.clock(inst),
        say: self.say,
      })
      AccountsI(a)
    }
    "chats" => {
      let hand = self.proxy_handover(inst)
      let m = chats_module({
        store: {
          handed_to: async fn(k) {
            match d("store.handedTo")([js(k)]) {
              Null => None
              v => Some(v)
            }
          },
          jobs_mark_of: async fn(keys) {
            arr(Some(d("store.jobsMarkOf")([jstrs(keys)])))
            .unwrap_or([])
            .map(p => {
              let a = arr(Some(p)).unwrap_or([])
              (text(a.get(0)).unwrap_or(""), text(a.get(1)).unwrap_or(""))
            })
          },
          get_session: async fn(k) {
            match d("store.getSession")([js(k)]) {
              Null => None
              v => Some(v)
            }
          },
        },
        handover: hand,
        hub: {
          hold_chat: async fn(k, why, notice) {
            ignore(d("hub.holdChat")([js(k), js(why), js(notice())]))
          },
          release_chat: async fn(k) { d("hub.releaseChat")([js(k)]) is Bool(true) },
          busy: if has(c, "busy") {
            Some(async fn(k) { d("hub.busy")([js(k)]) is Bool(true) })
          } else {
            None
          },
        },
        name: Some(name),
        keep_jobs: async fn(keys, why) { ignore(d("jobs.keep")([jstrs(keys), js(why)])) },
        start_kept: async fn(keys) { ignore(d("jobs.startKept")([jstrs(keys)])) },
        ask: ask_j,
        told,
        here: () => here,
        kind_of: async fn(id) {
          match d("kindOf")([js(id)]) {
            Obj(_) as k => Some((text(get(Some(k), "kind")).unwrap_or(""), text(get(Some(k), "mode")).unwrap_or("")))
            _ => None
          }
        },
        vaults_of: async fn(keys, ws) {
          let r = d("vaultsOf")([jstrs(keys), js(ws)])
          let out : Map[String, Array[String]] = {}
          for k in keys_of(r) {
            out[k] = strs(get(Some(r), k))
          }
          out
        },
        wait: if has(c, "wait") {
          Some(() => is_true(get(Some(c), "waitValue")))
        } else {
          None
        },
        reads: ws => self.proxy_reads(inst, ws),
        sizes: match get(Some(c), "sizes") {
          Some(Str(_) as t) =>
            match self.insts.get(text(Some(t)).unwrap_or("")) {
              Some(SizesI(s)) => Some(s)
              _ => None
            }
          _ => None
        },
        random,
        say: self.say,
      })
      Mod(m, c)
    }
    "connects" => {
      let m = connects_module({
        own: async fn(ws) {
          arr(Some(d("own")([js(ws)])))
          .unwrap_or([])
          .map(x => {
            id: text(get(Some(x), "id")).unwrap_or(""),
            name: text(get(Some(x), "name")).unwrap_or(""),
            kind: text(get(Some(x), "kind")).unwrap_or(""),
            mode: text(get(Some(x), "mode")).unwrap_or(""),
          })
        },
        chats_of: async fn(id) { strs(Some(d("chatsOf")([js(id)]))) },
        kind_of: if has(c, "kindOf") {
          Some(async fn(id) {
            match d("kindOf")([js(id)]) {
              Obj(_) as k => Some((text(get(Some(k), "kind")).unwrap_or(""), text(get(Some(k), "mode")).unwrap_or("")))
              _ => None
            }
          })
        } else {
          None
        },
        keys_of: if has(c, "keysOf") {
          Some(async fn(id) { strs(Some(d("keysOf")([js(id)]))) })
        } else {
          None
        },
        runs_on: async fn(id) { opt_text(d("runsOn")([js(id)])) },
        move: async fn(id, to, awaiting) { ignore(d("move")([js(id), js(to), jstrs(awaiting)])) },
        ask: ask_j,
        here: () => here,
      })
      Mod(m, c)
    }
    "jobs" =>
      JobsI(
        Jobs::new({
          data,
          disk: self.disk(),
          up: async fn(keys, ws) {
            arr(
              Some(
                d("up")([
                  match keys {
                    Some(k) => jstrs(k)
                    None => Null
                  },
                  str_j(ws),
                ]),
              ),
            ).unwrap_or([])
          },
          stop: async fn(id, why) { ignore(d("stop")([js(id), js(why)])) },
          start: async fn(j) { ignore(d("start")([j])) },
          chat_of: async fn(s) { text(Some(d("chatOf")([js(s)]))).unwrap_or(s) },
          ask: ask_j,
          here: () => here,
          clock: self.clock(inst),
          say: self.say,
        }),
      )
    "repos" =>
      ReposI(
        Repos::new({
          data,
          repos_dir: text(get(Some(c), "reposDir")).unwrap_or(""),
          workspaces: async fn(ws) { strs(Some(d("workspaces")([js(ws)]))) },
          git: async fn(dir, args) {
            text(Some(d("git")([js(dir), jstrs(args)]))).unwrap_or("")
          },
          ask: self.ask(inst),
          here: () => here,
          after: if has(c, "after") { Some(self.clock(inst).after) } else { None },
          name: Some(name),
          told,
          remove: if has(c, "remove") {
            Some(async fn(dir) { ignore(d("remove")([js(dir)])) })
          } else {
            None
          },
          fs: self.fs(inst),
          disk: self.disk(),
          clock: self.clock(inst),
          random,
          say: self.say,
        }),
      )
    "settings" =>
      SettingsI(
        Settings::new({
          data,
          config: {
            raw: async fn() { d("config.raw")([]) },
            update_soon: async fn(op) { ignore(d("config.update")([op])) },
          },
          ask: ask_j,
          disk: self.disk(),
          say: self.say,
        }),
      )
    "vault" =>
      VaultI(
        Vault::new({
          data,
          owners: async fn(ws) { strs(Some(d("owners")([js(ws)]))) },
          stores: self.proxy_stores(inst),
          ask: ask_j,
          disk: self.disk(),
        }),
      )
    "sizes" =>
      SizesI(
        Sizes::new({
          data,
          disk: self.disk(),
          measure: async fn(keys) {
            arr(Some(d("measure")([jstrs(keys)]))).unwrap_or([]).map(Sized::of)
          },
          gone: if has(c, "gone") {
            Some(async fn(k) { d("gone")([js(k)]) is Bool(true) })
          } else {
            None
          },
          say: self.say,
          clock: self.clock(inst),
        }),
      )
    _ => raise Failed("no module kind \{kind}")
  }
}

///|
fn Rpc::host_random_or_test(self : Rpc, inst : String, n : Int) -> J {
  ignore(inst)
  js((host_random(self.host))(n))
}

///|
fn Rpc::proxy_stores(self : Rpc, inst : String) -> VaultStores {
  let d = (name : String) => self.dep(inst, name)
  let opt = (v : J) => match v {
    Null => None
    x => Some(x)
  }
  {
    plain_items: async fn(ws, owner) { arr(Some(d("plain.items")([js(ws), js(owner)]))).unwrap_or([]) },
    plain_item: async fn(ws, id) { opt(d("plain.item")([js(ws), js(id)])) },
    plain_put: async fn(i) { ignore(d("plain.put")([i])) },
    plain_forget: async fn(ws, id) { ignore(d("plain.forget")([js(ws), js(id)])) },
    vaults: async fn(ws) { arr(Some(d("vaults.vaults")([js(ws)]))).unwrap_or([]) },
    vault: async fn(ws, id) { opt(d("vaults.vault")([js(ws), js(id)])) },
    items: async fn(ws, v) { arr(Some(d("vaults.items")([js(ws), js(v)]))).unwrap_or([]) },
    item: async fn(ws, v, id) { opt(d("vaults.item")([js(ws), js(v), js(id)])) },
    put_vault: async fn(v) { ignore(d("vaults.putVault")([v])) },
    put_item: async fn(i) { ignore(d("vaults.putItem")([i])) },
    forget_item: async fn(ws, v, id) { ignore(d("vaults.forgetItem")([js(ws), js(v), js(id)])) },
    forget_vault: async fn(ws, id) { ignore(d("vaults.forgetVault")([js(ws), js(id)])) },
  }
}

///|
/// The hand-over of one chat as the test's world has it (`handover.*` of `inst`).
fn Rpc::proxy_handover(self : Rpc, inst : String) -> HandoverPort {
  let d = (name : String) => self.dep(inst, "handover.\{name}")
  let opt = (v : J) => match v {
    Null => None
    x => Some(x)
  }
  let accounts_of = (v : J) => arr(Some(v))
    .unwrap_or([])
    .map(p => {
      let a = arr(Some(p)).unwrap_or([])
      (
        text(a.get(0)).unwrap_or(""),
        match a.get(1) {
          None | Some(Null) => None
          Some(x) => Some(x)
        },
      )
    })
  {
    together: async fn(k, page) { strs(Some(d("together")([js(k), page_j(page)]))) },
    chat_of: async fn(k) { text(Some(d("chatOf")([js(k)]))).unwrap_or(k) },
    accounts_of: async fn(keys, page) { accounts_of(d("accountsOf")([jstrs(keys), page_j(page)])) },
    past_left: async fn(accounts, keys, page) {
      strs(
        Some(
          d("pastLeft")([
            ja(accounts.map(a => ja([js(a.0), opt_j(a.1)]))),
            jstrs(keys),
            page_j(page),
          ]),
        ),
      )
    },
    check: async fn(k, to, planning, page) {
      opt_text(d("check")([js(k), js(to), jb(planning), page_j(page)]))
    },
    coming_in: async fn(ws) {
      arr(Some(d("comingIn")([js(ws)]))).unwrap_or([]).map(x => strs(Some(x)))
    },
    abandon: () => (self.clock(inst).spawn)(async fn() { ignore(d("abandon")([])) }),
    hand_over: async fn(k, to, wait, progress, stopped_for) {
      let cb = match progress {
        Some(p) =>
          self.callback(async fn(args) {
            p(args.get(0).unwrap_or(Null))
            Null
          })
        None => Null
      }
      d("handOver")([
        js(k),
        js(to),
        jb(wait),
        cb,
        match stopped_for {
          Some(w) => w.to_j()
          None => Null
        },
      ])
    },
    arrived: async fn(k, ms) { d("arrived")([js(k), ji(ms)]) is Bool(true) },
    out_of: async fn(k) { opt(d("outOf")([js(k)])) },
    coming_from: async fn(k) { opt_text(d("comingFrom")([js(k)])) },
    waits_for_turn: async fn(o) { d("waitsForTurn")([o]) is Bool(true) },
    start: async fn() { ignore(d("start")([])) },
    close: async fn() { ignore(d("close")([])) },
    settle: async fn() { ignore(d("settle")([])) },
    loaded_within: async fn() { ignore(d("loadedWithin")([])) },
    answer: async fn(peer, request, ws, bytes) {
      ignore(bytes)
      d("answer")([js(peer), request, str_j(ws)])
    },
    reached: peer => (self.clock(inst).spawn)(async fn() { ignore(d("reached")([js(peer)])) }),
  }
}

///|
async fn Rpc::module_call(self : Rpc, m : Module, c : J) -> J {
  let meth = text(get(Some(c), "method")).unwrap_or("")
  let item = arg(c, 0)
  let progress = (p : J) => (self.clock("").spawn)(async fn() {
    ignore(self.call(text(get(Some(c), "inst")).unwrap_or(""), "progress", [p]))
  })
  let stopped_for = waits_opt(get(Some(arg(c, 2)), "stoppedFor"))
  match meth {
    "plan" => {
      let reads = match arg(c, 2) {
        Bool(true) => Some(self.proxy_reads(text(get(Some(c), "inst")).unwrap_or(""), arg_text(c, 0)))
        _ => None
      }
      ja((m.plan)(arg_text(c, 0), arg_text(c, 1), reads))
    }
    "move" => {
      (m.move)(item, arg_text(c, 1), progress, stopped_for)
      Null
    }
    "back" => {
      (m.back)(item, arg_text(c, 1), stopped_for)
      Null
    }
    "state" => (m.state)(item)
    "usableHere" => jb(match m.usable_here { Some(f) => f(item); None => false })
    "usableThere" => jb(match m.usable_there { Some(f) => f(item); None => false })
    "canLend" => jb(match m.can_lend { Some(f) => f(item); None => false })
    "lend" => {
      (m.lend.unwrap())(item, arg_text(c, 1), need_list(Some(arg(c, 2))))
      Null
    }
    "lentFor" => {
      (m.lent_for.unwrap())(item, arg_text(c, 1), need_list(Some(arg(c, 2))))
      Null
    }
    "left" => {
      (m.left.unwrap())(need_list(Some(arg(c, 0))))
      Null
    }
    "isHere" => jb(match m.is_here { Some(f) => f(item); None => false })
    "abandon" => {
      match m.abandon {
        Some(f) => f()
        None => ()
      }
      Null
    }
    "ready" => str_j(match m.ready { Some(f) => f(item, arg_text(c, 1)); None => None })
    "stop" => {
      (m.stop.unwrap())(item, waits_of(arg(c, 1)))
      Null
    }
    "resume" => {
      (m.resume.unwrap())(item)
      Null
    }
    _ => raise Failed("no module method \{meth}")
  }
}

///|
async fn Rpc::told_call(self : Rpc, t : Told, c : J) -> J {
  let inst = text(get(Some(c), "inst")).unwrap_or("")
  match text(get(Some(c), "method")).unwrap_or("") {
    "asked" => {
      let request = arg(c, 2)
      t.asked(arg_text(c, 0), arg_text(c, 1), () => (request, None), progress=p => (self.clock(inst).spawn)(async fn() {
        ignore(self.call(inst, "progress", [p]))
      }))
    }
    "heard" => t.heard(arg_text(c, 0), arg(c, 1))
    "letGo" => {
      t.let_go(arg_text(c, 0), arg_text(c, 1), Failed(arg_text(c, 2)))
      Null
    }
    "reached" => {
      t.reached(arg_text(c, 0))
      Null
    }
    "run" => {
      let work = arg_text(c, 2)
      let measured = arg(c, 3) is Bool(true)
      let step = arg_text(c, 1)
      let origin = arg_text(c, 0)
      if measured {
        t.run(
          origin,
          step,
          async fn(progress) {
            let cb = self.callback(async fn(args) {
              progress(args.get(0).unwrap_or(Null))
              Null
            })
            match self.call(inst, "work", [js(work), cb]) {
              Null => None
              v => Some(v)
            }
          },
          measure=async fn() { self.call(inst, "measure", [js(work)]) },
        )
      } else {
        t.run(origin, step, async fn(progress) {
          let cb = self.callback(async fn(args) {
            progress(args.get(0).unwrap_or(Null))
            Null
          })
          match self.call(inst, "work", [js(work), cb]) {
            Null => None
            v => Some(v)
          }
        })
      }
    }
    "settle" => {
      t.settle()
      Null
    }
    "close" => {
      t.close()
      Null
    }
    m => raise Failed("no told method \{m}")
  }
}

///|
/// A station's moves whose world is the test's (`inst`): its store, hub, hand-over, connects, jobs, profiles, its
/// other stations, as `c` says it has them.
fn Rpc::make_moves(self : Rpc, inst : String, c : J) -> Inst raise {
  let d = (name : String) => self.dep(inst, name)
  let opt = (v : J) => match v {
    Null => None
    x => Some(x)
  }
  let here = text(get(Some(c), "here"))
  let home = text(get(Some(c), "home"))
  let rosters = get(Some(c), "rosters")
  let roster = fn(ws : String) -> Array[RosterEntry]? {
    match get(rosters, ws) {
      Some(Arr(xs)) =>
        Some(
          xs.map(x => {
            id: text(get(Some(x), "id")).unwrap_or(""),
            name: text(get(Some(x), "name")).unwrap_or(""),
            tasks: is_true(get(Some(x), "tasks")),
          }),
        )
      _ => None
    }
  }
  let page_of = (v : J) => self.page(inst, v)
  let on = Ref(!(get(Some(c), "on") is Some(Bool(false))))
  let store : MovesStore = {
    subscribe: Some(f => {
      let cb = self.callback(async fn(args) {
        f(text(args.get(0)).unwrap_or(""))
        Null
      })
      (self.clock(inst).spawn)(async fn() { ignore(d("store.subscribe")([cb])) })
    }),
    handed_to: async fn(k) { opt(d("store.handedTo")([js(k)])) },
    get_session: async fn(k) { opt(d("store.getSession")([js(k)])) },
    jobs_mark_of: async fn(keys) {
      arr(Some(d("store.jobsMarkOf")([jstrs(keys)])))
      .unwrap_or([])
      .map(p => {
        let a = arr(Some(p)).unwrap_or([])
        (text(a.get(0)).unwrap_or(""), text(a.get(1)).unwrap_or(""))
      })
    },
    live_sessions_on: async fn(pid, n) { strs(Some(d("store.liveSessionsOn")([js(pid), ji(n)]))) },
    live_of: async fn(keys) { strs(Some(d("store.liveOf")([jstrs(keys)]))) },
    jobs_up_of: async fn(keys) { arr(Some(d("store.jobsUpOf")([jstrs(keys)]))).unwrap_or([]) },
    sessions_of_connect: async fn(id, n, after) {
      strs(Some(d("store.sessionsOfConnect")([js(id), ji(n), js(after)])))
    },
    session_page: async fn(keys) { page_of(d("store.sessionPage")([jstrs(keys)])) },
    handed_chats: async fn(after, n) {
      arr(Some(d("store.handedChats")([js(after), ji(n)]))).unwrap_or([])
    },
    list_bindings: async fn() {
      arr(Some(d("store.listBindings")([])))
      .unwrap_or([])
      .map(p => {
        let a = arr(Some(p)).unwrap_or([])
        (text(a.get(0)).unwrap_or(""), strs(a.get(1)))
      })
    },
  }
  let made : Ref[HandoverPort?] = Ref(None)
  let deps : MovesDeps = {
    data: text(get(Some(c), "data")).unwrap_or(""),
    here: () => here,
    home: () => home,
    roster,
    ask: self.ask(inst),
    clock: self.clock(inst),
    disk: self.disk(),
    fs: self.fs(inst),
    say: self.say,
    random: n => text(Some(self.host_random_or_test(inst, n))).unwrap_or(""),
    store,
    hub: {
      hold_chat: async fn(k, why, notice) {
        ignore(d("hub.holdChat")([js(k), js(why), js(notice())]))
      },
      release_chat: async fn(k) { d("hub.releaseChat")([js(k)]) is Bool(true) },
      busy: Some(async fn(k) { d("hub.busy")([js(k)]) is Bool(true) }),
    },
    handover: hooks => {
      let cb = (f : async (Array[J]) -> J) => self.callback(f)
      let given = jo([
        ("jobsOf", cb(async fn(a) { ja((hooks.jobs_of)(strs(a.get(0)))) })),
        ("jobsStop", cb(async fn(a) {
          (hooks.jobs_stop)(strs(a.get(0)), text(a.get(1)).unwrap_or(""))
          Null
        })),
        ("jobsStart", cb(async fn(a) {
          (hooks.jobs_start)(a.get(0).unwrap_or(Null))
          Null
        })),
        ("accountOf", cb(async fn(a) { opt_j((hooks.account_of)(text(a.get(0)).unwrap_or(""))) })),
        ("accountHere", cb(async fn(a) { str_j((hooks.account_here)(a.get(0).unwrap_or(Null))) })),
        ("accountPresent", cb(async fn(a) { jb((hooks.account_present)(text(a.get(0)).unwrap_or(""))) })),
        ("arrivedStopped", cb(async fn(a) {
          (hooks.arrived_stopped)(strs(a.get(0)), waits_of(a.get(1).unwrap_or(jo([]))), text(a.get(2)).unwrap_or(""))
          Null
        })),
        ("shown", cb(async fn(a) {
          (hooks.shown)(strs(a.get(0)), text(a.get(1)))
          Null
        })),
        ("went", cb(async fn(a) {
          (hooks.went)(strs(a.get(0)))
          Null
        })),
        ("bindingsOf", cb(async fn(a) { (hooks.bindings_of)(strs(a.get(0))) })),
        ("admits", cb(async fn(a) { jb((hooks.admits)(text(a.get(0)).unwrap_or(""), text(a.get(1)).unwrap_or(""))) })),
      ])
      (self.clock(inst).spawn)(async fn() { ignore(d("handover.make")([given])) })
      let port = self.proxy_handover(inst)
      made.val = Some(port)
      port
    },
    connects: if has(c, "connects") {
      Some({
        kind_of: async fn(id) {
          match d("connects.kindOf")([js(id)]) {
            Obj(_) as k => Some((text(get(Some(k), "kind")).unwrap_or(""), text(get(Some(k), "mode")).unwrap_or("")))
            _ => None
          }
        },
        own_in: async fn(ws) {
          arr(Some(d("connects.ownIn")([js(ws)])))
          .unwrap_or([])
          .map(x => {
            id: text(get(Some(x), "id")).unwrap_or(""),
            name: text(get(Some(x), "name")).unwrap_or(""),
            kind: text(get(Some(x), "kind")).unwrap_or(""),
            mode: text(get(Some(x), "mode")).unwrap_or(""),
          })
        },
        moved_away: None,
        runs_on: async fn(id) { opt_text(d("connects.runsOn")([js(id)])) },
        move: async fn(id, to, awaiting) { ignore(d("connects.move")([js(id), js(to), jstrs(awaiting)])) },
        arrived: Some(async fn(keys) { ignore(d("connects.arrived")([jstrs(keys)])) }),
      })
    } else {
      None
    },
    jobs: {
      up: async fn(keys, ws) {
        arr(
          Some(
            d("jobs.up")([
              match keys {
                Some(k) => jstrs(k)
                None => Null
              },
              str_j(ws),
            ]),
          ),
        ).unwrap_or([])
      },
      stop: async fn(id, why) { ignore(d("jobs.stop")([js(id), js(why)])) },
      start: async fn(j) { ignore(d("jobs.start")([j])) },
      stop_named: async fn(s, n) { ignore(d("jobs.stopNamed")([js(s), js(n)])) },
    },
    profiles: async fn() { arr(Some(d("profiles")([]))).unwrap_or([]) },
    move_profile: async fn(id, to) { d("moveProfile")([id.map(js).unwrap_or(Null), js(to)]) },
    share_moves: if has(c, "shareMoves") {
      Some({
        move: async fn(id, to, made_) {
          let cb = self.callback(async fn(args) {
            made_(text(args.get(0)).unwrap_or(""))
            Null
          })
          d("share.move")([js(id), js(to), cb])
        },
        unshare: async fn(share, stations) { d("share.unshare")([js(share), jstrs(stations)]) is Bool(true) },
        lend: Some(async fn(id, to) {
          let r = d("share.lend")([js(id), js(to)])
          (text(get(Some(r), "share")).unwrap_or(""), is_true(get(Some(r), "made")), is_true(get(Some(r), "widened")))
        }),
        unlend: Some(async fn(share, to, made_, widened) {
          ignore(d("share.unlend")([js(share), js(to), jb(made_), jb(widened)]))
        }),
        uses_there: None,
        handed_on: None,
      })
    } else {
      None
    },
    sessions_in: async fn(ws, after, n) { page_of(d("sessionsIn")([js(ws), js(after), ji(n)])) },
    repos_dir: text(get(Some(c), "reposDir")).unwrap_or(""),
    remove: None,
    room: Some(async fn() { d("room")([]) }),
    git: Some(async fn(dir, args) { text(Some(d("git")([js(dir), jstrs(args)]))).unwrap_or("") }),
    changed: Some(() => self.send(jo([("tell", js("changed")), ("inst", js(inst))]))),
    config: Some({
      raw: async fn() { d("config.raw")([]) },
      update_soon: async fn(op) { ignore(d("config.update")([op])) },
    }),
    vault: Some({
      owners: async fn(ws) { strs(Some(d("vault.owners")([js(ws)]))) },
      grant_owners: async fn(keys) {
        let r = d("vault.grantOwners")([jstrs(keys)])
        let out : Map[String, Array[String]] = {}
        for k in keys_of(r) {
          out[k] = strs(get(Some(r), k))
        }
        out
      },
      stores: self.proxy_stores(inst),
    }),
    move_on: Some(() => on.val),
    plan_page: num(get(Some(c), "planPage")).map(n => n.to_int()),
    clones_elsewhere: Some(async fn() { strs(Some(d("clonesElsewhere")([]))) }),
    hold: () => {
      self.next += 1
      let id = self.next
      self.send(jo([("tell", js("hold")), ("inst", js(inst)), ("hold", ji(id))]))
      () => self.send(jo([("tell", js("letGo")), ("inst", js(inst)), ("hold", ji(id))]))
    },
    replica: {
      moved: (path, from, to) => moved_path(path, from, to),
      carried_to: (path, from, to, room) => {
        ignore(room)
        moved_path(path, from, to)
      },
      floor_of: total => {
        let floor_min = 20.0 * 1024.0 * 1024.0 * 1024.0
        let share = (total.unwrap_or(0.0) * 0.1).floor()
        if share > floor_min { share } else { floor_min }
      },
      room_here: async fn() { d("room")([]) },
      sizes: async fn(keys, sizing) {
        arr(Some(d("sizes")([jstrs(keys), sizing]))).unwrap_or([]).map(Sized::of)
      },
    },
  }
  let m = Moves::new(deps)
  ignore(made)
  let answers = m.answers(peer => text(get(Some(c), "notIn")) != Some(peer))
  MovesI(m, answers)
}

///|
/// `path` as it is on this station: under `to` where it was under `from` (replica/restore.ts `moved`).
pub fn moved_path(path : String, from : String, to : String) -> String {
  if from == "" || from == to {
    return path
  }
  let f = if from.has_suffix("/") { slice(from, 0, from.length() - 1) } else { from }
  if path == f {
    return to
  }
  if path.has_prefix(f + "/") {
    return @nodepath.join("/", [to, slice_from(path, f.length() + 1)])
  }
  path
}

///|
async fn Rpc::moves_call(
  self : Rpc,
  m : Moves,
  answers : async (String, J, String?, Bytes_?) -> J,
  c : J,
) -> J {
  match text(get(Some(c), "method")).unwrap_or("") {
    "start" => {
      m.start()
      Null
    }
    "close" => {
      m.close()
      Null
    }
    "answer" => answers(arg_text(c, 0), arg(c, 1), arg_opt(c, 2), None)
    "heard" => {
      m.heard(arg_text(c, 0))
      Null
    }
    "loginsChanged" => {
      m.logins_changed()
      Null
    }
    "shareCameHome" => {
      m.share_came_home(arg_text(c, 0), arg_text(c, 1))
      Null
    }
    "refusal" => str_j(m.refusal(arg_text(c, 0), arg_text(c, 1), lang?=arg_opt(c, 2)))
    "roomForAll" => str_j(m.room_for_all(arg_text(c, 0), arg_text(c, 1), arg(c, 2)))
    "room" => m.room(arg_text(c, 0), arg_text(c, 1), strs(Some(arg(c, 2))))
    "setWait" => {
      m.set_wait(arg(c, 0) is Bool(true))
      Null
    }
    "settle" => {
      m.scheduler.settle()
      m.told.settle()
      m.scheduler.written()
      Null
    }
    "sizesSettled" => {
      m.sizes.settled()
      Null
    }
    "accountOf" => opt_j(account_of(Some(arg(c, 0)), arg_text(c, 1)))
    "accountHere" => str_j(m.account_here(arg(c, 0)))
    "ask" => m.ask(arg_text(c, 0), arg(c, 1), None)
    "scheduler" => self.sched_call(m.scheduler, arg(c, 0))
    "route" => {
      let r = arg(c, 0)
      let roster_ws = (ws : String) => (m.d.roster)(ws)
      let routes = move_routes({
        scheduler: m.scheduler,
        order: () => m.scheduler.module_ids(),
        home: m.d.home,
        station: (ws, v) => match roster_ws(ws) {
          Some(r) =>
            match r.search_by(x => x.id == v || x.name == v) {
              Some(i) => Some((r[i].id, false))
              None => None
            }
          None => None
        },
        here: m.d.here,
        rig: () => false,
        name: Some((ws, id) => match roster_ws(ws) {
          Some(r) =>
            match r.search_by(x => x.id == id) {
              Some(i) if r[i].name != "" => Some(r[i].name)
              _ => None
            }
          None => None
        }),
        refusal: async fn(ws, s, lang) { m.refusal(ws, s, lang~) },
        begun: None,
        say: self.say,
      })
      let req : MoveRequest = {
        method_: text(get(Some(r), "method")).unwrap_or("GET"),
        path: text(get(Some(r), "path")).unwrap_or(""),
        query: arr(get(Some(r), "query"))
          .unwrap_or([])
          .map(q => {
            let a = arr(Some(q)).unwrap_or([])
            (text(a.get(0)).unwrap_or(""), text(a.get(1)).unwrap_or(""))
          }),
        body: match get(Some(r), "body") {
          None | Some(Null) => ""
          Some(b) => stringify(b)
        },
        email: text(get(Some(r), "email")).unwrap_or(""),
        role: text(get(Some(r), "role")).unwrap_or("owner"),
        workspace: text(get(Some(r), "workspace")),
        lang: text(get(Some(r), "lang")).unwrap_or("en"),
      }
      match routes.search_by(x => x.method_ == req.method_ && (x.matches)(req.path)) {
        Some(i) => {
          let (status, body) = (routes[i].handle)(req)
          jo([("status", ji(status)), ("body", body)])
        }
        None => raise Failed("no route")
      }
    }
    meth => raise Failed("no moves method \{meth}")
  }
}

///|
/// One message asked of the program, by its `cmd`.
async fn Rpc::command(self : Rpc, c : J) -> J {
  let cmd = text(get(Some(c), "cmd")).unwrap_or("")
  let inst_name = text(get(Some(c), "inst")).unwrap_or("")
  match cmd {
    "words" => {
      let read = (path : String) => match (host_disk(self.host).read)(path) {
        Some(t) => parse(t)
        None => raise Failed("no catalog at \{path}")
      }
      let w = @api_routes.Words::new(
        to_jv(read(text(get(Some(c), "zh")).unwrap_or(""))),
        to_jv(read(text(get(Some(c), "en")).unwrap_or(""))),
      )
      self.say = Say::of((lang, key, args) => w.tr(lang, key, args~), text(get(Some(c), "lang")).unwrap_or("zh"))
      Null
    }
    "cb" =>
      match self.cbs.get(num(get(Some(c), "cb")).unwrap_or(0.0).to_int()) {
        Some(f) => f(arr(get(Some(c), "args")).unwrap_or([]))
        None => raise Failed("no callback")
      }
    "fire" => {
      let id = num(get(Some(c), "timer")).unwrap_or(0.0).to_int()
      match self.timers.get(id) {
        Some(f) => {
          // (one that comes due once is let go as it fires)
          if is_true(get(Some(c), "once")) {
            self.timers.remove(id)
          }
          f()
        }
        None => ()
      }
      Null
    }
    "sync" => {
      while true {
        @effect.pause()
        if self.host.rt.idle() {
          break
        }
      }
      Null
    }
    "kept.new" => {
      let disk = self.disk()
      let path = text(get(Some(c), "path")).unwrap_or("")
      let from = text(get(Some(c), "from"))
      let i = match text(get(Some(c), "kind")).unwrap_or("") {
        "set" => KSet(KeptSet::new(disk, path))
        "map" => KMap(KeptMap::new(disk, path))
        "log" =>
          KLog(match from {
            Some(f) =>
              KeptLog::new(disk, path, from=(f, raw => keys_of(if raw is Obj(_) { raw } else { jo([]) }).map(k => (k, get(Some(raw), k).unwrap()))))
            None => KeptLog::new(disk, path)
          })
        "lent" => KLent(LentLog::new(disk, path, from.unwrap_or(path + ".json")))
        k => raise Failed("no kept kind \{k}")
      }
      self.insts[inst_name] = i
      Null
    }
    "kept" => self.kept_async(self.inst(c), c)
    "told.new" => {
      self.insts[inst_name] = ToldI(
        Told::new({
          clock: self.clock(inst_name),
          ask: self.ask(inst_name),
          hold: if is_true(get(Some(c), "hold")) {
            Some(() => {
              self.next += 1
              let id = self.next
              self.send(jo([("tell", js("hold")), ("inst", js(inst_name)), ("hold", ji(id))]))
              () => self.send(jo([("tell", js("letGo")), ("inst", js(inst_name)), ("hold", ji(id))]))
            })
          } else {
            None
          },
          say: self.say,
        }),
      )
      Null
    }
    "told" =>
      match self.inst(c) {
        ToldI(t) => self.told_call(t, c)
        _ => raise Failed("not a told")
      }
    "sched.new" => {
      let modules = arr(get(Some(c), "modules")).unwrap_or([]).map(spec => self.proxy_module(inst_name, spec))
      self.insts[inst_name] = Sched(Scheduler::new(self.sched_deps(inst_name, c, modules)))
      Null
    }
    "sched" =>
      match self.inst(c) {
        Sched(s) => self.sched_call(s, c)
        _ => raise Failed("not a scheduler")
      }
    "turn.wait" =>
      match self.cbs.get(num(get(Some(c), "turn")).unwrap_or(0.0).to_int()) {
        Some(f) => f([])
        None => raise Failed("no turn")
      }
    "mod.new" => {
      self.insts[inst_name] = self.make_module(inst_name, c)
      Null
    }
    "mod" => {
      let i = self.inst(c)
      let meth = text(get(Some(c), "method")).unwrap_or("")
      match (i, meth) {
        (ReposI(r), "answer") => r.answer(arg_text(c, 0), arg(c, 1), match arg(c, 2) {
          Str(u) => {
            let bytes = Ref(Some(@utf8.encode(@jsjson.sanitize_str(u))))
            Some(Came(async fn() {
              let b = bytes.val
              bytes.val = None
              b
            }))
          }
          _ => None
        })
        (SettingsI(s), "answer") => s.answer(arg_text(c, 0), arg(c, 1))
        (VaultI(v), "answer") => v.answer(arg(c, 0))
        (AccountsI(a), "cameHome") => {
          (a.came_home)(arg_text(c, 0), arg_text(c, 1))
          Null
        }
        (AccountsI(a), "lookAt") => {
          let said = match arg(c, 1) {
            Obj(_) as s => Some((text(get(Some(s), "share")).unwrap_or(""), num(get(Some(s), "uses")).unwrap_or(0.0).to_int()))
            _ => None
          }
          (a.look_at)(arg_text(c, 0), said)
          Null
        }
        (JobsI(j), "keep") => ja(j.keep(strs(Some(arg(c, 0))), arg_text(c, 1)))
        (JobsI(j), "startKept") => {
          j.start_kept(strs(Some(arg(c, 0))))
          Null
        }
        (SizesI(s), "seen") => {
          s.seen(arg_text(c, 0), arr(Some(arg(c, 1))).unwrap_or([]).map(p => {
            let a = arr(Some(p)).unwrap_or([])
            (text(a.get(0)).unwrap_or(""), text(a.get(1)).unwrap_or(""))
          }))
          Null
        }
        (SizesI(s), "read") => {
          s.read()
          Null
        }
        (SizesI(s), "settled") => {
          s.settled()
          Null
        }
        (SizesI(s), "quiet") => {
          s.set_quiet(arg(c, 0) is Bool(true))
          Null
        }
        (SizesI(s), "sum") => s.sum(strs(Some(arg(c, 0)))).to_j()
        (SizesI(s), "placesOf") => ja(s.places_of(arg_text(c, 0)))
        (SizesI(s), "line") => opt_j(s.line(arg_text(c, 0)))
        (SizesI(s), "measured") => ji(s.measured)
        (AccountsI(a), _) => self.module_call(a.module, c)
        (ReposI(r), _) => self.module_call(r.module(), c)
        (SettingsI(s), _) => self.module_call(s.module(), c)
        (VaultI(v), _) => self.module_call(v.module(), c)
        (JobsI(j), _) => self.module_call(j.module(), c)
        (Mod(m, _), _) => self.module_call(m, c)
        _ => raise Failed("no such module method \{meth}")
      }
    }
    "moves.new" => {
      self.insts[inst_name] = self.make_moves(inst_name, c)
      Null
    }
    "moves" =>
      match self.inst(c) {
        MovesI(m, answers) => self.moves_call(m, answers, c)
        _ => raise Failed("not a station's moves")
      }
    "view" => {
      let o = arg(c, 0)
      let names = get(Some(o), "names")
      move_view(
        get(Some(o), "plan").unwrap_or(jo([])),
        strs(get(Some(o), "order")),
        arr(get(Some(o), "stopped"))
        .unwrap_or([])
        .map(s => (need_of(get(Some(s), "item").unwrap_or(jo([]))), waits_of(get(Some(s), "waitsFor").unwrap_or(jo([]))))),
        module?=text(get(Some(o), "module")),
        after?=text(get(Some(o), "after")),
        limit=num(get(Some(o), "limit")).map(d => d.to_int()).unwrap_or(move_page),
        last?=match get(Some(o), "last") {
          None | Some(Null) => None
          Some(l) => Some(l)
        },
        stopping=is_true(get(Some(o), "stopping")),
        name=id => match text(get(names, id)) {
          Some(n) => n
          None => slice_to(id, 12)
        },
        current?=match get(Some(o), "current") {
          Some(Obj(_) as n) => Some(need_of(n))
          _ => None
        },
      )
    }
    "pure" => pure_case(arg(c, 0))
    _ => raise Failed("no such command \{cmd}")
  }
}

///|
/// The pure functions, each by its name.
fn pure_case(c : J) -> J raise {
  let a = (i : Int) => arr(get(Some(c), "args")).unwrap_or([]).get(i).unwrap_or(Null)
  let t = (i : Int) => text(Some(a(i))).unwrap_or("")
  match text(get(Some(c), "fn")).unwrap_or("") {
    "accountItemId" => js(account_item_id(t(0), match a(1) { Null => None; v => Some(v) }))
    "accountOf" => opt_j(account_of(Some(a(0)), t(1)))
    "shareRefusal" => str_j(share_refusal(Some(a(0))))
    "connectItemId" => js(connect_item_id(t(0), t(1)))
    "repoItemId" => js(repo_item_id(t(0)))
    "vaultItemId" => js(vault_item_id(t(0)))
    "jobItemId" => js(job_item_id(a(0)))
    "stampOf" => js(stamp_of(match a(0) { Null => None; v => Some(v) }, text(Some(a(1)))))
    "shortKey" => js(short_key(t(0)))
    "originUrl" => str_j(origin_url_of(t(0)))
    "unanswered" => jb(unanswered_words(t(0)))
    "isUnder" => jb(is_under(a(0), t(1)))
    "gb" => js(gb(num(Some(a(0))).unwrap_or(0.0)))
    "localeCompare" => ji(locale_compare(t(0), t(1)))
    "jsNumber" =>
      match js_number(t(0)) {
        Some(n) => jn(n)
        None => js("NaN")
      }
    f => raise Failed("no pure function \{f}")
  }
}

///|
fn to_jv(j : J) -> @api_routes.JV {
  @jsjson.JValue::of_js(j)
}

///|
/// The harness: a message a line, until stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  let rpc : Rpc = {
    host,
    next: 0,
    waiting: {},
    cbs: {},
    timers: {},
    now: 0L,
    insts: {},
    say: Say::of((_, k, _) => k, "zh"),
  }
  while true {
    guard host.line() is Some(line) else { break }
    let c = parse(line) catch {
      _ => {
        rpc.send(jo([("error", js("not JSON"))]))
        continue
      }
    }
    match num(get(Some(c), "now")) {
      Some(n) => rpc.now = n.to_int64()
      None => ()
    }
    match num(get(Some(c), "re")) {
      Some(id) => {
        match rpc.waiting.get(id.to_int()) {
          Some(d) => {
            rpc.waiting.remove(id.to_int())
            match get(Some(c), "err") {
              Some(e) =>
                ignore(
                  d.fail(
                    error_of(
                      text(get(Some(e), "kind")).unwrap_or("Error"),
                      text(get(Some(e), "message")).unwrap_or(""),
                    ),
                  ),
                )
              None => ignore(d.succeed(get(Some(c), "ok").unwrap_or(Null)))
            }
          }
          None => ()
        }
        continue
      }
      None => ()
    }
    let id = num(get(Some(c), "id")).unwrap_or(0.0).to_int()
    ignore(
      host.rt.fork(async fn() {
        let answer = match (try Ok(rpc.command(c)) catch { e => Err(e) }) {
          Ok(v) => jo([("done", ji(id)), ("ok", v)])
          Err(e) => jo([("done", ji(id)), ("err", err_j(e))])
        }
        rpc.send(answer)
      }),
    )
  }
}
