// The program's harness (reader `--builder harness-browser`): what station/test/mb-browser.test.ts holds these parts
// to the TypeScript of station/src/browser/ with. A line a message both ways, JSON:
// - asked of the program: `{"cmd": name, "id": n, ...}`, answered `{"done": n, "ok": value}` or `{"done": n, "err":
//   {"kind", "message", "status"?}}`; each runs as a fiber of its own, so a part waiting on the test goes on as the test
//   asks more;
// - what the program asks of the test (a part's world: a DevTools connection's answers, the Chrome host, a sign-in
//   form's wait): `{"call": name, "id": m, "inst": instance, "args": [...]}`, answered `{"re": m, "ok": value}` or
//   `{"re": m, "err": {...}}`; a DevTools command is asked as it is sent (`cdp.send`, its connection the instance);
// - told the test without an answer: `{"tell": name, "inst", "args"}` (a timer armed or let go, a screen added or taken
//   away, what a part told its station: a view's size, a tab's use, a log line);
// - every message the test sends says its clock (`now`); a timer's coming due is the test's `fire`; `sync` is answered
//   once nothing here can go on before the test answers.
// Files are the machine's own, through the shell; a Farview tab's ports the test's own on 127.0.0.1.

///|
priv struct HCdp {
  id : String
  listeners : Array[(Int, (CdpEvent) -> Unit)]
  mut next : Int
  mut gone : Bool
  done : @effect.Deferred[Unit]
}

///|
priv enum Inst {
  GateI(Gate, Map[String, String])
  OwnersI(Owners)
  KeysI(Authenticators)
  ViewI(TabView)
  SViewI(ScreenView)
  StationI(StationBrowser, Ref[String?])
  BrowsersI(Browsers, Ref[String?])
  FormI(SignInForm)
  SourceI(ScreenSource)
  FvScreenI(FarviewScreen)
  LinkI(FrameLink)
  PassI(Pass, Ref[Bool], Ref[Bool])
  ToolI(BrowserTool)
  WatchI(() -> Unit)
  StateI(BrowserState)
}

///|
priv struct Rpc {
  host : @host.Host
  mut next : Int
  waiting : Map[Int, @effect.Deferred[J]]
  timers : Map[Int, async () -> Unit]
  mut now : Double
  insts : Map[String, Inst]
  cdps : Map[String, HCdp]
  mut cdp_seq : Int
  mut inst_seq : Int
  /// The files' calls the shell has not answered yet, and who waits for there to be none (`sync`).
  mut pending : Int
  calm : Array[@effect.Deferred[Unit]]
}

///|
fn Rpc::send(self : Rpc, j : J) -> Unit {
  self.host.say(stringify(j))
}

///|
fn err_j(e : Error) -> J {
  let fs : Array[(String, J)] = [("kind", js(kind_of(e))), ("message", js(message_of(e)))]
  match e {
    ScreenRefused(status, key) => {
      fs.push(("status", ji(status)))
      fs.push(("key", js(key)))
    }
    FsError(code, _) => fs.push(("code", js(code)))
    _ => ()
  }
  jo(fs)
}

///|
/// What the test is asked, sent now; its answer later.
fn Rpc::ask_now(self : Rpc, inst : String, name : String, args : Array[J]) -> @effect.Deferred[J] {
  self.next += 1
  let id = self.next
  let done = @effect.Deferred::new()
  self.waiting[id] = done
  self.send(jo([("call", js(name)), ("id", ji(id)), ("inst", js(inst)), ("args", ja(args))]))
  done
}

///|
async fn Rpc::ask(self : Rpc, inst : String, name : String, args : Array[J]) -> J {
  self.ask_now(inst, name, args).wait()
}

///|
fn Rpc::tell(self : Rpc, inst : String, name : String, args : Array[J]) -> Unit {
  self.send(jo([("tell", js(name)), ("inst", js(inst)), ("args", ja(args))]))
}

///|
/// The test's clock, as this program's parts see it.
fn Rpc::clock(self : Rpc, inst : String) -> Clock {
  {
    now: () => self.now,
    after: (ms, f) => {
      self.next += 1
      let id = self.next
      self.timers[id] = f
      self.send(jo([("tell", js("after")), ("inst", js(inst)), ("timer", ji(id)), ("ms", jn(ms))]))
      () => if self.timers.contains(id) {
        self.timers.remove(id)
        self.send(jo([("tell", js("cancel")), ("timer", ji(id))]))
      }
    },
    spawn: f => ignore(
      self.host.rt.fork(async fn() {
        f() catch {
          _ => ()
        }
      }),
    ),
    sleep: async fn(ms) {
      ignore(self.ask(inst, "sleep", [jn(ms)]))
    },
  }
}

///|
fn Rpc::log(self : Rpc, inst : String) -> Log {
  {
    info: (part, what, f) => self.tell(inst, "log", [js("info"), js(part), js(what), f]),
    warn: (part, what, f) => self.tell(inst, "log", [js("warn"), js(part), js(what), f]),
  }
}

///|
/// A DevTools connection whose answers are the test's (`cdp.send`), its events given by `emit`.
fn Rpc::cdp(self : Rpc, id : String) -> Cdp {
  let c : HCdp = { id, listeners: [], next: 0, gone: false, done: @effect.Deferred::new() }
  self.cdps[id] = c
  {
    post: (method, params, session) => {
      if c.gone {
        let d : @effect.Deferred[J] = @effect.Deferred::new()
        ignore(d.fail(fail_("closed")))
        return Later::of(d)
      }
      Later::of(
        self.ask_now(id, "cdp.send", [
          js(method),
          params,
          match session {
            Some(s) => js(s)
            None => Null
          },
        ]),
      )
    },
    on: listener => {
      c.next += 1
      let me = c.next
      c.listeners.push((me, listener))
      () => match c.listeners.search_by(l => l.0 == me) {
        Some(i) => ignore(c.listeners.remove(i))
        None => ()
      }
    },
    closed: async fn() { c.done.wait() catch { _ => () } },
    close: () => if !c.gone {
      c.gone = true
      ignore(c.done.succeed(()))
      self.tell(id, "cdp.closed", [])
    },
  }
}

///|
/// A new connection, its id the next of the program's, the test asked first whether it opens.
async fn Rpc::connect(self : Rpc, inst : String, args : Array[J]) -> Cdp {
  self.cdp_seq += 1
  let id = "cdp\{self.cdp_seq}"
  ignore(self.ask(inst, "connect", [js(id)] + args))
  self.cdp(id)
}

///|
/// The screens, as the test is told of them: each source kept here by its id (`screen` calls reach it).
fn Rpc::screens(self : Rpc, inst : String, changed : Bool) -> Screens {
  {
    add: source => {
      self.insts[source.id] = SourceI(source)
      self.tell(inst, "screens.add", [js(source.id)])
      () => self.tell(inst, "screens.remove", [js(source.id)])
    },
    changed: if changed {
      Some(() => self.tell(inst, "screens.changed", []))
    } else {
      None
    },
    set_browser: Some(b => self.tell(inst, "screens.browser", [jb(b is Some(_))])),
  }
}

///|
/// The machine's files; with `held`, a file read is the test's to answer (`files.read`), so it answers once what is
/// to come before it came.
fn Rpc::files(self : Rpc, inst : String, held : Bool) -> Files {
  let f = host_files(self.host)
  let files : Files = {
    read: async fn(p) { self.counted(async fn() { (f.read)(p) }) },
    write_private: async fn(p, t) { self.counted(async fn() { (f.write_private)(p, t) }) },
    write: async fn(p, t, m) { self.counted(async fn() { (f.write)(p, t, m) }) },
    create: async fn(p, t) { self.counted(async fn() { (f.create)(p, t) }) },
    rename: async fn(a, b) { self.counted(async fn() { (f.rename)(a, b) }) },
    unlink: async fn(p) { self.counted(async fn() { (f.unlink)(p) }) },
    mkdir: async fn(p, m) { self.counted(async fn() { (f.mkdir)(p, m) }) },
    rm: async fn(p, r) { self.counted(async fn() { (f.rm)(p, r) }) },
    readdir: async fn(p) { self.counted(async fn() { (f.readdir)(p) }) },
    exists: async fn(p) { self.counted(async fn() { (f.exists)(p) }) },
    mtime: async fn(p) { self.counted(async fn() { (f.mtime)(p) }) },
  }
  if !held {
    return files
  }
  { ..files, read: async fn(path) { str_of(Some(self.ask(inst, "files.read", [js(path)]))) } }
}

///|
/// A call of the files counted while the shell has it: `sync` is not answered before it is.
async fn[X] Rpc::counted(self : Rpc, f : async () -> X) -> X {
  self.pending += 1
  let r = attempt(f)
  self.pending -= 1
  if self.pending == 0 {
    let waiting = self.calm.copy()
    self.calm.clear()
    for d in waiting {
      ignore(d.succeed(()))
    }
  }
  match r {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
fn Rpc::random_hex(self : Rpc, n : Int) -> String {
  match (try Some(self.host.shell_sync("crypto.random", { "bytes": Json::number(n.to_double()) })) catch {
      _ => None
    }) {
    Some(String(s)) => s
    _ => "0".repeat(n * 2)
  }
}

///|
fn Rpc::uuid(self : Rpc) -> String {
  let h = self.random_hex(16)
  "\{slice(h, 0, b=8)}-\{slice(h, 8, b=12)}-4\{slice(h, 13, b=16)}-a\{slice(h, 17, b=20)}-\{slice(h, 20, b=32)}"
}

///|
fn Rpc::chrome(self : Rpc, inst : String, installed : Bool) -> ChromeHost {
  {
    find: async fn() {
      match self.ask(inst, "chrome.find", []) {
        Obj(_) as r => Some(Running::of_j(r))
        _ => None
      }
    },
    launch: async fn() { Running::of_j(self.ask(inst, "chrome.launch", [])) },
    installed: () => installed,
    kill: async fn(r) { ignore(self.ask(inst, "chrome.kill", [r.to_j()])) },
    connect: async fn(ws) { self.connect(inst, [js(ws)]) },
    state: None,
  }
}

///|
fn Rpc::frame_j(self : Rpc, f : Frame?) -> J {
  ignore(self)
  match f {
    None => Null
    Some(f) => {
      let fs : Array[(String, J)] = []
      match f.config {
        Some((codec, w, h)) => fs.push(("config", jo([("codec", js(codec)), ("width", jn(w)), ("height", jn(h))])))
        None => ()
      }
      fs.push(("key", jb(f.key)))
      fs.push(("ts", jn(f.ts)))
      fs.push(("data", js(@base64.encode(f.data))))
      jo(fs)
    }
  }
}

///|
fn Rpc::fresh_inst(self : Rpc, kind : String) -> String {
  self.inst_seq += 1
  "\{kind}\{self.inst_seq}"
}

///|
fn Rpc::browser_options(self : Rpc, inst : String, c : J, state_file : Ref[String?]) -> BrowserOptions {
  ignore(state_file)
  let cv = Some(c)
  {
    dir: text(at(cv, "dir")),
    chrome: self.chrome(inst, !(at(cv, "installed") is Some(Bool(false)))),
    screens: Some(self.screens(inst, !(at(cv, "changed") is Some(Bool(false))))),
    clock: self.clock(inst),
    idle_ms: num_of(at(cv, "idleMs")),
    user_tab_idle_ms: num_of(at(cv, "userTabIdleMs")),
    context_owner: None,
    used_tab: Some((s, t) => self.tell(inst, "usedTab", [js(s), js(t)])),
    files: self.files(inst, false),
    log: self.log(inst),
    uuid: () => self.uuid(),
    random_hex: n => self.random_hex(n),
    pid: @host.pid(),
  }
}

///|
fn strs(v : J?) -> Array[String] {
  arr(v).map(x => js_str(Some(x)))
}

///|
fn opt_str_j(s : String?) -> J {
  match s {
    Some(x) => js(x)
    None => Null
  }
}

///|
fn arg(c : J, i : Int) -> J? {
  at_i(at(Some(c), "args"), i)
}

///|
fn arg_s(c : J, i : Int) -> String {
  js_str(arg(c, i))
}

///|
fn passkeys_j(ps : Array[Passkey]) -> J {
  ja(ps.map(p => p.to_j()))
}

///|
fn passkeys_of(v : J?) -> Array[Passkey] {
  arr(v).filter_map(p => passkey_of(Some(p)))
}

///|
fn status_j(s : BrowserStatus) -> J {
  s.to_j()
}

///|
fn Rpc::view_j(self : Rpc, v : ScreenView) -> J {
  let id = self.fresh_inst("view")
  self.insts[id] = SViewI(v)
  js(id)
}

///|
fn Rpc::form_j(self : Rpc, f : SignInForm) -> J {
  let id = self.fresh_inst("form")
  self.insts[id] = FormI(f)
  js(id)
}

///|
fn Rpc::watch_j(self : Rpc, stop : () -> Unit) -> J {
  let id = self.fresh_inst("watch")
  self.insts[id] = WatchI(stop)
  js(id)
}

///|
/// A screen view's call (a tab's, a Farview tab's): `method` with `args`.
async fn Rpc::view_call(self : Rpc, inst : String, v : ScreenView, m : String, c : J) -> J {
  match m {
    "next" => self.frame_j((v.next)())
    "keyframe" => {
      (v.keyframe)()
      Null
    }
    "input" => {
      (v.input)(arg(c, 0).unwrap_or(Null))
      Null
    }
    "setClipboard" => {
      let clip = arg(c, 0)
      (v.set_clipboard)({ type_: text(at(clip, "type")), text: text(at(clip, "text")) }, is_true(arg(c, 1)))
      Null
    }
    "watchClipboard" =>
      self.watch_j((v.watch_clipboard)(clip => self.tell(inst, "clip", [
        jo([("type", js(clip.type_)), ("text", js(clip.text))]),
      ])))
    "watchLogin" => self.watch_j((v.watch_login)(l => self.tell(inst, "login", [l])))
    "fill" => {
      (v.fill)(arg(c, 0).unwrap_or(Null))
      Null
    }
    "watchPasskey" => self.watch_j((v.watch_passkey)(a => self.tell(inst, "passkey", [a])))
    "passkey" => {
      (v.passkey)(arg(c, 0).unwrap_or(Null))
      Null
    }
    "bounds" => {
      (v.bounds)(js_num(arg(c, 0)), js_num(arg(c, 1)))
      Null
    }
    "video" => (v.video)()
    "viewport" => {
      let (w, h) = (v.viewport)()
      jo([("width", jn(w)), ("height", jn(h))])
    }
    "watchChild" => self.watch_j((v.watch_child)(id => self.tell(inst, "child", [js(id)])))
    "close" => {
      (v.close)()
      Null
    }
    _ => raise fail_("no view call \{m}")
  }
}

///|
fn source_j(s : ScreenSource) -> J {
  let (w, h) = (s.size)()
  jo([
    ("id", js(s.id)),
    ("kind", js(s.kind)),
    ("title", js((s.title)())),
    ("site", opt_str_j((s.site)())),
    ("address", js((s.address)())),
    ("size", jo([("width", jn(w)), ("height", jn(h))])),
    ("peek", jb((s.peek)())),
    ("openedBy", opt_str_j((s.opened_by)())),
    ("userTab", jb(s.user_tab)),
    ("popup", jb(s.popup)),
    ("sleeping", jb((s.sleeping)())),
    ("farview", jb(s.farview)),
  ])
}

///|
async fn Rpc::source_call(self : Rpc, s : ScreenSource, m : String, c : J) -> J {
  let run = async fn(f : (async () -> Unit)?) -> J {
    match f {
      Some(g) => {
        g()
        Null
      }
      None => raise fail_("no \{m}")
    }
  }
  match m {
    "info" => source_j(s)
    "open" => self.view_j((s.open)(ViewOptions::of_j(arg(c, 0).unwrap_or(Null))))
    "openUrl" =>
      match s.open_url {
        Some(f) => {
          f(arg_s(c, 0))
          Null
        }
        None => raise fail_("no openUrl")
      }
    "reload" => run(s.reload)
    "back" => run(s.back)
    "forward" => run(s.forward)
    "discard" => run(s.discard)
    "sleep" => run(s.sleep)
    _ => raise fail_("no screen call \{m}")
  }
}

///|
fn form_values(v : J?) -> FormValues {
  { username: str_of(at(v, "username")), password: str_of(at(v, "password")), code: str_of(at(v, "code")) }
}

///|
async fn Rpc::form_call(self : Rpc, inst : String, f : SignInForm, m : String, c : J) -> J {
  match m {
    "host" => js((f.host)())
    "url" => js((f.url)())
    "on" => jb((f.on)(arg_s(c, 0)))
    "look" => (f.look)().to_j()
    "type" => jb((f.type_)(arg_s(c, 0), arg_s(c, 1)))
    "enter" => {
      (f.enter)()
      Null
    }
    "press" => jb((f.press)())
    "mark" => {
      (f.mark)()
      Null
    }
    "marked" => jb((f.marked)())
    "close" => {
      (f.close)()
      Null
    }
    "drive" => {
      let used = strs(arg(c, 2))
      let d = drive(f, arg_s(c, 0), form_values(arg(c, 1)), used, async fn(ms) {
        ignore(self.ask(inst, "wait", [jn(ms)]))
      })
      jo([("driven", d.to_j()), ("used", jsa(used))])
    }
    _ => raise fail_("no form call \{m}")
  }
}

///|
fn tabs_j(tabs : Array[TabInfo]) -> J {
  ja(tabs.map(t => t.to_j()))
}

///|
async fn Rpc::station_call(
  self : Rpc,
  inst : String,
  b : StationBrowser,
  state_file : Ref[String?],
  m : String,
  c : J,
) -> J {
  match m {
    "resume" => {
      b.resume()
      Null
    }
    "endpoint" => status_j(b.endpoint())
    "tabs" => tabs_j(b.tabs())
    "available" => jb(b.available())
    "openUserTab" => js(b.open_user_tab(arg_s(c, 0), id?=str_of(arg(c, 1))))
    "openTab" =>
      if is_true(arg(c, 1)) {
        js(b.open_tab(arg_s(c, 0), state_file=() => state_file.val))
      } else {
        js(b.open_tab(arg_s(c, 0)))
      }
    "setStateFile" => {
      state_file.val = str_of(arg(c, 0))
      Null
    }
    "send" => b.send(arg_s(c, 0), params=arg(c, 1).unwrap_or(Obj([])))
    "attach" => {
      let (cdp, session) = b.attach(arg_s(c, 0))
      let id = self.fresh_inst("attached")
      self.insts[id] = FormI(tab_form(cdp, session, arg_s(c, 0)))
      jo([("form", js(id)), ("session", js(session))])
    }
    "passkeys.read" => {
      let keys = b.passkeys()
      passkeys_j(
        match arg(c, 1) {
          Some(Arr(_)) => keys.read(arg_s(c, 0), sites=strs(arg(c, 1)))
          _ => keys.read(arg_s(c, 0))
        },
      )
    }
    "passkeys.put" => {
      b.passkeys().put(arg_s(c, 0), passkeys_of(arg(c, 1)))
      Null
    }
    "passkeys.has" => jb(b.passkeys().has(arg_s(c, 0), arg_s(c, 1)))
    "contextOf" => opt_str_j(b.context_of(arg_s(c, 0)))
    "tabUrl" => opt_str_j(b.tab_url(arg_s(c, 0)))
    "hasTab" => jb(b.has_tab(arg_s(c, 0)))
    "closeTab" => {
      b.close_tab(arg_s(c, 0))
      Null
    }
    "flushed" => {
      b.flushed()
      Null
    }
    "own" => {
      b.own(arg_s(c, 0), arg_s(c, 1))
      Null
    }
    "closeOf" => {
      b.close_of(arg_s(c, 0))
      Null
    }
    "status" => status_j(b.status())
    "used" => {
      b.used()
      Null
    }
    "stop" => {
      b.stop()
      Null
    }
    "close" => {
      b.close()
      Null
    }
    _ => raise fail_("no browser call \{m} (\{inst})")
  }
}

///|
async fn Rpc::browsers_call(self : Rpc, inst : String, b : Browsers, sf : Ref[String?], m : String, c : J) -> J {
  if m.has_prefix("station.") {
    return self.station_call(inst, b.station, sf, slice(m, 8), c)
  }
  match m {
    "context" => js(b.context(arg_s(c, 0)))
    "open" => {
      let (ws, gate) = b.open(arg_s(c, 0))
      let id = self.fresh_inst("gate")
      self.insts[id] = GateI(Gate::new(gate), {})
      jo([("ws", js(ws)), ("context", js(gate.context)), ("gate", js(id))])
    }
    "endpoint" => status_j(b.endpoint(arg_s(c, 0)))
    "tabs" => tabs_j(b.tabs(arg_s(c, 0)))
    "form" => self.form_j(b.form(arg_s(c, 0), arg_s(c, 1)))
    "status" => status_j(b.status(arg_s(c, 0)))
    "stop" => {
      b.stop(arg_s(c, 0))
      Null
    }
    "closeOf" => {
      b.close_of(arg_s(c, 0))
      Null
    }
    "cookies" => js(b.cookies(arg_s(c, 0), strs(arg(c, 1)), is_true(arg(c, 2))))
    "signIn" => {
      let d = arg(c, 1)
      b.sign_in(
        arg_s(c, 0),
        text(at(d, "request")),
        str_of(at(d, "workspace")),
        strs(at(d, "sites")),
        text(at(d, "cookies")),
        js_num(at(d, "until")),
      )
      Null
    }
    "extendSignIn" => {
      b.extend_sign_in(arg_s(c, 0), arg_s(c, 1), js_num(arg(c, 2)))
      Null
    }
    "resume" => {
      b.resume()
      Null
    }
    "passkeysAgain" => {
      b.passkeys_again()
      Null
    }
    "passkeysIn" => {
      let d = arg(c, 1)
      b.passkeys_in(arg_s(c, 0), strs(at(d, "sites")), text(at(d, "cookies")))
      Null
    }
    "used" => {
      match arg(c, 2) {
        Some(Str(u)) => b.used(arg_s(c, 0), arg_s(c, 1), url=@jsjson.text(u))
        _ => b.used(arg_s(c, 0), arg_s(c, 1))
      }
      Null
    }
    "close" => {
      b.close()
      Null
    }
    _ => raise fail_("no browsers call \{m}")
  }
}

///|
async fn Rpc::make(self : Rpc, c : J) -> J {
  let cv = Some(c)
  let inst = text(at(cv, "inst"))
  match text(at(cv, "kind")) {
    "gate" => {
      let contexts : Map[String, String] = {}
      for e in entries_of(at(cv, "contexts").unwrap_or(Obj([]))) {
        contexts[e.0] = js_str(Some(e.1))
      }
      let g = Gate::new({
        context: text(at(cv, "context")),
        context_of: id => contexts.get(id),
        opened: Some(id => self.tell(inst, "opened", [js(id)])),
        used: Some((id, url) => self.tell(inst, "used", [js(id), opt_str_j(url)])),
        act: None,
      })
      self.insts[inst] = GateI(g, contexts)
    }
    "owners" => {
      let o = Owners::new(text(at(cv, "dir")), self.files(inst, is_true(at(cv, "held"))), self.clock(inst), self.log(inst))
      self.insts[inst] = OwnersI(o)
    }
    "keys" => {
      let chats = strs(at(cv, "chats"))
      let k = Authenticators::new(
        self.cdp(text(at(cv, "cdp"))),
        ctx => chats.contains(ctx),
        on_changed=ctx => self.tell(inst, "changed", [js(ctx)]),
        clock=self.clock(inst),
        log=self.log(inst),
      )
      self.insts[inst] = KeysI(k)
    }
    "view" => {
      let own = strs(at(cv, "ownPasskey"))
      let v = TabView::new({
        cdp: self.cdp(text(at(cv, "cdp"))),
        session: text(at(cv, "session")),
        target_id: text(at(cv, "targetId")),
        now: () => self.now,
        sized: Some(s => self.tell(inst, "sized", [jo([("width", jn(s.0)), ("height", jn(s.1))])])),
        used: Some(() => self.tell(inst, "used", [])),
        ended: Some(() => self.tell(inst, "ended", [])),
        own_passkey: if at(cv, "ownPasskey") is Some(Arr(_)) {
          Some(rp => own.contains(rp))
        } else {
          None
        },
        uuid: () => self.uuid(),
        clock: self.clock(inst),
      })
      self.insts[inst] = ViewI(v)
    }
    "station" => {
      let sf = Ref(None)
      let o = self.browser_options(inst, c, sf)
      let owners = strs(at(cv, "contextOwners"))
      let o = if owners.length() > 0 {
        { ..o, context_owner: Some(ctx => match ctx { Some(x) if owners.contains(x) => Some("owner:" + x); _ => None }) }
      } else {
        o
      }
      self.insts[inst] = StationI(StationBrowser::new(o), sf)
    }
    "browsers" => {
      let sf = Ref(None)
      let b = Browsers::new(self.browser_options(inst, c, sf))
      b.on_taken_out((s, r, k, w) => self.tell(inst, "takenOut", [js(s), js(r), js(k), opt_str_j(w)]))
      b.on_fresh(s => self.tell(inst, "fresh", [js(s)]))
      b.on_resumed(s => self.tell(inst, "resumed", [js(s)]))
      b.on_used((s, h) => self.tell(inst, "used", [js(s), js(h)]))
      self.insts[inst] = BrowsersI(b, sf)
    }
    "tool" => {
      guard self.insts.get(text(at(cv, "browsers"))) is Some(BrowsersI(b, _)) else { raise fail_("no browsers") }
      let door = str_of(at(cv, "door"))
      self.insts[inst] = ToolI(browser_tools(b.tool_browsers(), door_url=() => door)[0])
    }
    "tabForm" => {
      let f = tab_form(self.cdp(text(at(cv, "cdp"))), text(at(cv, "session")), text(at(cv, "targetId")))
      self.insts[inst] = FormI(f)
    }
    "farviewForm" => {
      let f = farview_form(host_net(self.host, self.clock(inst)), js_num(at(cv, "port")).to_int())
      self.insts[inst] = FormI(f)
    }
    "frameLink" => {
      let l = FrameLink::new(host_net(self.host, self.clock(inst)), js_num(at(cv, "port")).to_int())
      l.heard = m => self.tell(inst, "heard", [m])
      l.ended = () => self.tell(inst, "ended", [])
      self.insts[inst] = LinkI(l)
    }
    "farviewScreen" => {
      let s = FarviewScreen::new(
        text(at(cv, "session")),
        js_num(at(cv, "port")).to_int(),
        js_num(at(cv, "n")).to_int(),
        host_net(self.host, self.clock(inst)),
        self.log(inst),
      )
      s.opened = url => self.tell(inst, "opened", [js(url)])
      self.insts[inst] = FvScreenI(s)
    }
    "pass" => {
      let client_open = Ref(true)
      let up_open = Ref(true)
      let end_ = (side : String, open : Ref[Bool]) => {
        send_text: t => self.tell(inst, "ws", [js(side), js(t)]),
        send_raw: (b, binary) => self.tell(inst, "raw", [js(side), js(@base64.encode(b)), jb(binary)]),
        is_open: () => open.val,
        connecting: () => false,
        close: () => {
          open.val = false
          self.tell(inst, "close", [js(side)])
        },
        terminate: () => {
          open.val = false
          self.tell(inst, "terminate", [js(side)])
        },
      }
      let contexts : Map[String, String] = {}
      for e in entries_of(at(cv, "contexts").unwrap_or(Obj([]))) {
        contexts[e.0] = js_str(Some(e.1))
      }
      let p = pass(
        end_("client", client_open),
        end_("upstream", up_open),
        Gate::new({ context: text(at(cv, "context")), context_of: id => contexts.get(id), opened: None, used: None, act: None }),
      )
      self.insts[inst] = PassI(p, client_open, up_open)
    }
    "state" =>
      self.insts[inst] = StateI(BrowserState::new(text(at(cv, "dir")), self.files(inst, false), self.clock(inst)))
    k => raise fail_("no kind \{k}")
  }
  Null
}

///|
async fn Rpc::call(self : Rpc, c : J) -> J {
  let cv = Some(c)
  let inst = text(at(cv, "inst"))
  let m = text(at(cv, "method"))
  guard self.insts.get(inst) is Some(i) else { raise fail_("no instance \{inst}") }
  match i {
    GateI(g, contexts) =>
      match m {
        "fromClient" => passed_j(g.from_client(arg_s(c, 0)))
        "wants" => jb(g.wants(arg_s(c, 0)))
        "fromChrome" => passed_j(g.from_chrome(arg_s(c, 0)))
        "context" => {
          contexts[arg_s(c, 0)] = arg_s(c, 1)
          Null
        }
        _ => raise fail_("no gate call \{m}")
      }
    OwnersI(o) =>
      match m {
        "ready" => {
          o.ready()
          Null
        }
        "written" => {
          o.written()
          Null
        }
        "of" => opt_str_j(o.of(arg_s(c, 0)))
        "set" => jb(o.set(arg_s(c, 0), arg_s(c, 1)))
        "drop" => {
          o.drop(arg_s(c, 0))
          Null
        }
        "keep" => {
          o.keep(strs(arg(c, 0)))
          Null
        }
        _ => raise fail_("no owners call \{m}")
      }
    KeysI(k) =>
      match m {
        "start" => {
          k.start()
          Null
        }
        "close" => {
          k.close()
          Null
        }
        "read" =>
          passkeys_j(
            match arg(c, 1) {
              Some(Arr(_)) => k.read(arg_s(c, 0), sites=strs(arg(c, 1)))
              _ => k.read(arg_s(c, 0))
            },
          )
        "put" => {
          k.put(arg_s(c, 0), passkeys_of(arg(c, 1)))
          Null
        }
        "takeOut" => passkeys_j(k.take_out(arg_s(c, 0), strs(arg(c, 1))))
        "has" => jb(k.has(arg_s(c, 0), arg_s(c, 1)))
        "forget" => {
          k.forget(arg_s(c, 0))
          Null
        }
        _ => raise fail_("no keys call \{m}")
      }
    ViewI(v) =>
      match m {
        "start" => {
          let o = ViewOptions::of_j(arg(c, 0).unwrap_or(Null))
          match arg(c, 1) {
            Some(Obj(_) as vp) => v.start(o, viewport=(js_num(at(Some(vp), "width")), js_num(at(Some(vp), "height"))))
            _ => v.start(o)
          }
          Null
        }
        _ => self.view_call(inst, v.as_view(), m, c)
      }
    SViewI(v) => self.view_call(inst, v, m, c)
    StationI(b, sf) => self.station_call(inst, b, sf, m, c)
    BrowsersI(b, sf) => self.browsers_call(inst, b, sf, m, c)
    FormI(f) => self.form_call(inst, f, m, c)
    SourceI(s) => self.source_call(s, m, c)
    FvScreenI(s) =>
      match m {
        "watch" => {
          s.watch()
          Null
        }
        "heard" => {
          s.heard(arg(c, 0).unwrap_or(Null))
          Null
        }
        "info" => {
          let (w, h) = s.size()
          jo([
            ("id", js(s.id)),
            ("title", js(s.title())),
            ("site", opt_str_j(s.site())),
            ("address", js(s.address())),
            ("size", jo([("width", jn(w)), ("height", jn(h))])),
            ("viewing", ji(s.viewing())),
            ("page", jo([("url", js(s.page().url)), ("title", js(s.page().title))])),
          ])
        }
        "open" => {
          let v = s.open(ViewOptions::of_j(arg(c, 0).unwrap_or(Null)))
          self.view_j(v.as_view())
        }
        "close" => {
          s.close()
          Null
        }
        _ => raise fail_("no farview screen call \{m}")
      }
    LinkI(l) =>
      match m {
        "send" => {
          l.send(arg(c, 0).unwrap_or(Null))
          Null
        }
        "picture" =>
          match l.picture() {
            Some((h, d)) => jo([("header", h), ("data", js(@base64.encode(d)))])
            None => Null
          }
        "close" => {
          l.close()
          Null
        }
        _ => raise fail_("no link call \{m}")
      }
    PassI(p, client_open, up_open) =>
      match m {
        "fromClient" => {
          p.from_client(utf8(arg_s(c, 0)), is_true(arg(c, 1)))
          Null
        }
        "fromChrome" => {
          p.from_chrome(utf8(arg_s(c, 0)), is_true(arg(c, 1)))
          Null
        }
        "end" => {
          p.end()
          Null
        }
        "open" => {
          client_open.val = !(arg(c, 0) is Some(Bool(false)))
          up_open.val = !(arg(c, 1) is Some(Bool(false)))
          Null
        }
        _ => raise fail_("no pass call \{m}")
      }
    ToolI(t) =>
      match m {
        "run" => js((t.run)(arg_s(c, 0), arg(c, 1).unwrap_or(Obj([]))))
        _ => raise fail_("no tool call \{m}")
      }
    WatchI(stop) => {
      stop()
      Null
    }
    StateI(s) =>
      match m {
        "read" => s.read()
        "change" => {
          let patch = arg(c, 0).unwrap_or(Obj([]))
          s.change(st => spread(spread(Obj([]), st), patch))
          Null
        }
        "written" => {
          s.written()
          Null
        }
        _ => raise fail_("no state call \{m}")
      }
  }
}

///|
fn passed_j(p : Passed) -> J {
  jo([("up", jsa(p.up)), ("down", jsa(p.down))])
}

///|
async fn Rpc::command(self : Rpc, c : J) -> J {
  let cv = Some(c)
  match text(at(cv, "cmd")) {
    "fn" => pure_case(text(at(cv, "name")), arr(at(cv, "args")))
    "new" => self.make(c)
    "call" => self.call(c)
    "fire" => {
      let id = js_num(at(cv, "timer")).to_int()
      match self.timers.get(id) {
        Some(f) => {
          self.timers.remove(id)
          f()
        }
        None => ()
      }
      Null
    }
    "emit" => {
      let id = text(at(cv, "cdp"))
      match self.cdps.get(id) {
        Some(h) => {
          let e : CdpEvent = {
            method: text(at(cv, "method")),
            params: at(cv, "params").unwrap_or(Obj([])),
            session_id: str_of(at(cv, "sessionId")),
          }
          for l in h.listeners.copy() {
            (l.1)(e)
          }
        }
        None => ()
      }
      Null
    }
    "cdpEnd" => {
      match self.cdps.get(text(at(cv, "cdp"))) {
        Some(h) =>
          if !h.gone {
            h.gone = true
            ignore(h.done.succeed(()))
          }
        None => ()
      }
      Null
    }
    "unpack" => {
      let r = at(cv, "release")
      let release : FarviewRelease = { rev: text(at(r, "rev")), sha256: text(at(r, "sha256")) }
      unpack_release(
        text(at(cv, "dir")),
        text(at(cv, "target")),
        release,
        strs(at(cv, "sources")),
        async fn(url) {
          match self.ask("unpack", "fetch", [js(url)]) {
            Str(u) => Some(@base64.decode(@jsjson.text(u)))
            _ => None
          }
        },
        self.files("unpack", false),
        host_release_io(self.host),
      )
      Null
    }
    "sync" => {
      while true {
        @effect.pause()
        if self.pending > 0 {
          let d : @effect.Deferred[Unit] = @effect.Deferred::new()
          self.calm.push(d)
          d.wait() catch {
            _ => ()
          }
          continue
        }
        if self.host.rt.idle() {
          break
        }
      }
      Null
    }
    k => raise fail_("no command \{k}")
  }
}

///|
fn view_options_j(v : J?) -> ViewOptions {
  ViewOptions::of_j(v.unwrap_or(Null))
}

///|
/// The functions of no state, by their TypeScript names.
fn pure_case(name : String, args : Array[J]) -> J raise {
  let a = (i : Int) => if i < args.length() { Some(args[i]) } else { None }
  let s = (i : Int) => js_str(a(i))
  match name {
    "extractFirstHttpUrl" => opt_str_j(extract_first_http_url(s(0)))
    "normalizeBrowserUrl" => opt_str_j(normalize_browser_url(s(0)))
    "addressOrSearch" => opt_str_j(address_or_search(s(0)))
    "siteOfBrowserUrl" => opt_str_j(site_of_browser_url(s(0)))
    "persistableBrowserUrl" => opt_str_j(persistable_browser_url(s(0)))
    "BLANK_PAGE" => js(blank_page)
    "sessionPath" => js(session_path(s(0)))
    "sessionOfPath" => opt_str_j(session_of_path(s(0)))
    "ofSites" => jb(of_sites(s(0), strs(a(1))))
    "allCookies" => ja(all_cookies(a(0)))
    "siteCookies" => ja(site_cookies(a(0), strs(a(1))))
    "stateOf" => state_of(s(0)).to_j()
    "keptOf" => {
      let st = a(0)
      js(kept_of({ cookies: arr(at(st, "cookies")), passkeys: passkeys_of(at(st, "passkeys")) }))
    }
    "expired" => ja(expired(arr(a(0))))
    "passkeyOf" =>
      match passkey_of(a(0)) {
        Some(p) => p.to_j()
        None => Null
      }
    "sitePasskeys" => passkeys_j(site_passkeys(passkeys_of(a(0)), strs(a(1))))
    "parseActivePort" =>
      match parse_active_port(s(0)) {
        Some((port, path)) => jo([("port", ji(port)), ("path", js(path))])
        None => Null
      }
    "chromeArgs" => {
      let o = a(0)
      jsa(
        chrome_args(
          text(at(o, "profile")),
          js_num(at(o, "port")).to_int(),
          is_true(at(o, "headless")),
          user_agent?=str_of(at(o, "userAgent")),
        ),
      )
    }
    "headfulAgent" => js(headful_agent(s(0)))
    "viewportOf" =>
      match viewport_of(a(0)) {
        Some((w, h)) => jo([("width", jn(w)), ("height", jn(h))])
        None => Null
      }
    "jpegSize" =>
      match jpeg_size(@base64.decode(s(0))) {
        Some((w, h)) => jo([("width", ji(w)), ("height", ji(h))])
        None => Null
      }
    "toViewport" => {
      let vp = a(2)
      let (x, y) = to_viewport(js_num(a(0)), js_num(a(1)), (js_num(at(vp, "width")), js_num(at(vp, "height"))))
      jo([("x", jn(x)), ("y", jn(y))])
    }
    "keyCode" => ji(key_code(s(0), s(1)))
    "keyEvent" => key_event(a(0).unwrap_or(Null))
    "COPY_HOOK" => js(copy_hook())
    "LOGIN_HOOK" => js(login_hook())
    "fillScript" => js(fill_script(str_of(a(0)), str_of(a(1))))
    "passkeyHook" => js(passkey_hook(s(0)))
    "sameClientData" => jb(same_client_data(s(0), s(1)))
    "rpFor" => jb(rp_for(s(0), s(1)))
    "hostOf" => js(host_of(s(0)))
    "FINDER" => js(finder())
    "LOOK_SCRIPT" => js(look_script())
    "pickScript" => js(pick_script(s(0)))
    "BUTTON_SCRIPT" => js(button_script)
    "MOVE_MS" => jn(move_ms)
    "markScript" => js(mark_script(s(0)))
    "BUTTON_MARK" => js(button_mark())
    "encodeAsk" => {
      let o = a(0)
      let ask = match text(at(o, "kind")) {
        "look" => Look
        "eval" => Eval(text(at(o, "script")))
        "cookies" => Cookies(text(at(o, "verb")), text(at(o, "arg")))
        "passkeys" => Passkeys(text(at(o, "verb")), text(at(o, "arg")))
        _ => Act(text(at(o, "verb")), text(at(o, "selector")), text(at(o, "text")))
      }
      js(@base64.encode(encode_ask(ask)))
    }
    "decodeAnswer" =>
      match decode_answer(@base64.decode(s(0))) {
        Some(answer) => answer.to_j()
        None => Null
      }
    "FARVIEW_RELEASES" =>
      jo(farview_releases().map(r => (r.0, jo([("rev", js(r.1.rev)), ("sha256", js(r.1.sha256))]))))
    "farviewAsset" => {
      let r = a(1)
      js(farview_asset(s(0), { rev: text(at(r, "rev")), sha256: text(at(r, "sha256")) }))
    }
    "farviewCacheDir" => {
      let r = a(2)
      js(farview_cache_dir(s(0), s(1), { rev: text(at(r, "rev")), sha256: text(at(r, "sha256")) }))
    }
    "farviewSources" => {
      let env : Map[String, String] = {}
      for e in entries_of(a(1).unwrap_or(Obj([]))) {
        match e.1 {
          Str(u) => env[e.0] = @jsjson.text(u)
          _ => ()
        }
      }
      jsa(farview_sources(s(0), env))
    }
    "ghSource" =>
      match gh_source(s(0)) {
        Some((repo, tag, n)) => jo([("repo", js(repo)), ("tag", js(tag)), ("name", js(n))])
        None => Null
      }
    "sha256" => js(sha256_of(@base64.decode(s(0))))
    "farviewConfig" => {
      let releases = entries_of(a(2).unwrap_or(Obj([]))).map(e => (
        e.0,
        { rev: text(at(Some(e.1), "rev")), sha256: text(at(Some(e.1), "sha256")) },
      ))
      match farview_config(a(0), s(1), releases, s(3)) {
        Some(cfg) => cfg.to_j()
        None => Null
      }
    }
    "farviewFor" => {
      let cfg = match a(0) {
        Some(Obj(_) as o) =>
          Some({
            dir: text(at(Some(o), "dir")),
            host: text(at(Some(o), "host")),
            agent: text(at(Some(o), "agent")),
            engine: text(at(Some(o), "engine")),
            sessions: strs(at(Some(o), "sessions")),
            release: None,
          })
        _ => None
      }
      jb(farview_for(cfg, s(1), str_of(a(2))))
    }
    "hostFileOf" =>
      match host_file_of(a(0)) {
        Some(f) => f.to_j()
        None => Null
      }
    "chatDir" => js(chat_dir(s(0)))
    "FIRST_PAGE" => js(first_page)
    "farviewHowTo" => {
      let o = a(0)
      let cfg : FarviewConfig = {
        dir: text(at(o, "dir")),
        host: text(at(o, "host")),
        agent: text(at(o, "agent")),
        engine: text(at(o, "engine")),
        sessions: strs(at(o, "sessions")),
        release: None,
      }
      let tabs = arr(a(1)).map(t => {
        let tv = Some(t)
        {
          info: {
            id: text(at(tv, "id")),
            title: text(at(tv, "title")),
            url: text(at(tv, "url")),
            attached: is_true(at(tv, "attached")),
            session: str_of(at(tv, "session")),
          },
          agent: js_num(at(tv, "agent")).to_int(),
        }
      })
      js(farview_how_to(cfg, tabs))
    }
    "inputOf" => {
      let sz = a(1)
      match input_of(a(0).unwrap_or(Null), (js_num(at(sz, "width")), js_num(at(sz, "height")), js_num(at(sz, "scale")))) {
        Some(m) => m
        None => Null
      }
    }
    "sizeFor" => {
      let (w, h, sc) = size_for(view_options_j(a(0)))
      jo([("width", jn(w)), ("height", jn(h)), ("scale", jn(sc))])
    }
    "DEFAULT_SIZE" => jo([("width", jn(default_size.0)), ("height", jn(default_size.1)), ("scale", jn(default_size.2))])
    "BROWSER" => browser_declaration()
    "sessionWs" => opt_str_j(session_ws(str_of(a(0)), s(1)))
    "howTo" => {
      let st = a(0)
      js(
        how_to(
          {
            running: is_true(at(st, "running")),
            http: str_of(at(st, "http")),
            ws: str_of(at(st, "ws")),
            binary: str_of(at(st, "binary")),
            headless: bool_of(at(st, "headless")),
            pid: None,
            tabs: None,
            viewing: None,
            last_use: None,
          },
          str_of(a(1)),
        ),
      )
    }
    "BEHIND" => jo(behind())
    _ => raise fail_("no function \{name}")
  }
}

///|
/// The harness: a message a line, until stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  let rpc : Rpc = {
    host,
    next: 0,
    waiting: {},
    timers: {},
    now: 0.0,
    insts: {},
    cdps: {},
    cdp_seq: 0,
    inst_seq: 0,
    pending: 0,
    calm: [],
  }
  while true {
    guard host.line() is Some(line) else { break }
    let c = parse(line) catch {
      _ => {
        rpc.send(jo([("error", js("not JSON"))]))
        continue
      }
    }
    let cv = Some(c)
    match num_of(at(cv, "now")) {
      Some(n) => rpc.now = n
      None => ()
    }
    match num_of(at(cv, "re")) {
      Some(id) => {
        match rpc.waiting.get(id.to_int()) {
          Some(d) => {
            rpc.waiting.remove(id.to_int())
            match at(cv, "err") {
              Some(e) => ignore(d.fail(Thrown(text(at(Some(e), "kind")), text(at(Some(e), "message")))))
              None => ignore(d.succeed(at(cv, "ok").unwrap_or(Null)))
            }
          }
          None => ()
        }
        continue
      }
      None => ()
    }
    let id = js_num(at(cv, "id")).to_int()
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
