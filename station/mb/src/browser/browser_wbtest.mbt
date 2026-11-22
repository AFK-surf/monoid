// The browser's parts on the runtime's virtual clock, with files in memory and a machine of the test's own: what
// station/test/mb-browser.test.ts does not hold to the TypeScript (Chrome started and ended as a process, Farview's
// hosts started, numbered, taken up and ended, a release unpacked), and the functions of no state on vectors Node gave.

///|
fn vclock(rt : @effect.Runtime) -> Clock {
  {
    now: () => rt.now().to_double(),
    after: (ms, f) => {
      let fiber = rt.fork(async fn() {
        @effect.sleep(if ms > 0.0 { ms.to_int() } else { 0 })
        f() catch {
          _ => ()
        }
      })
      () => fiber.interrupt()
    },
    spawn: f => ignore(
      rt.fork(async fn() {
        f() catch {
          _ => ()
        }
      }),
    ),
    sleep: async fn(ms) { @effect.sleep(ms.to_int()) },
  }
}

///|
/// Files in memory: each file's text, and the directories there.
priv struct Mem {
  files : Map[String, String]
  dirs : Map[String, Unit]
}

///|
fn Mem::parent_there(self : Mem, path : String) -> Bool {
  let d = @nodepath.dirname("/", path)
  d == "/" || self.dirs.contains(d)
}

///|
fn Mem::mkdirs(self : Mem, path : String) -> Unit {
  let mut p = path
  while p != "/" && p != "." && p != "" {
    self.dirs[p] = ()
    p = @nodepath.dirname("/", p)
  }
}

///|
fn Mem::files(self : Mem) -> Files {
  let enoent = (path : String) => FsError("ENOENT", "ENOENT: no such file or directory '\{path}'")
  {
    read: async fn(path) { self.files.get(path) },
    write_private: async fn(path, t) {
      self.mkdirs(@nodepath.dirname("/", path))
      self.files[path] = t
    },
    write: async fn(path, t, _) {
      if !self.parent_there(path) {
        raise enoent(path)
      }
      self.files[path] = t
    },
    create: async fn(path, t) {
      if !self.parent_there(path) {
        raise enoent(path)
      }
      self.files[path] = t
    },
    rename: async fn(from, to) {
      if !self.parent_there(to) {
        raise enoent(to)
      }
      match self.files.get(from) {
        Some(t) => {
          self.files.remove(from)
          self.files[to] = t
        }
        None => {
          guard self.dirs.contains(from) else { raise enoent(from) }
          let moved = []
          for k, v in self.files {
            if k.has_prefix(from + "/") {
              moved.push((k, v))
            }
          }
          for m in moved {
            self.files.remove(m.0)
            self.files[to + slice(m.0, from.length())] = m.1
          }
          let ds = []
          for k, _ in self.dirs {
            if k == from || k.has_prefix(from + "/") {
              ds.push(k)
            }
          }
          for d in ds {
            self.dirs.remove(d)
            self.dirs[to + slice(d, from.length())] = ()
          }
        }
      }
    },
    unlink: async fn(path) {
      guard self.files.contains(path) else { raise enoent(path) }
      self.files.remove(path)
    },
    mkdir: async fn(path, _) { self.mkdirs(path) },
    rm: async fn(path, _) {
      self.files.remove(path)
      let fs = []
      for k, _ in self.files {
        if k.has_prefix(path + "/") {
          fs.push(k)
        }
      }
      for k in fs {
        self.files.remove(k)
      }
      let ds = []
      for k, _ in self.dirs {
        if k == path || k.has_prefix(path + "/") {
          ds.push(k)
        }
      }
      for d in ds {
        self.dirs.remove(d)
      }
    },
    readdir: async fn(path) {
      guard self.dirs.contains(path) else { raise enoent(path) }
      let out = []
      let take = (k : String) => if k.has_prefix(path + "/") {
        let rest = slice(k, path.length() + 1)
        let name = match rest.split("/").next() {
          Some(n) => n.to_string()
          None => rest
        }
        if !out.contains(name) {
          out.push(name)
        }
      }
      for k, _ in self.files {
        take(k)
      }
      for k, _ in self.dirs {
        take(k)
      }
      out
    },
    exists: async fn(path) { self.files.contains(path) || self.dirs.contains(path) },
    mtime: async fn(path) {
      guard self.files.contains(path) else { raise enoent(path) }
      7.0
    },
  }
}

///|
fn mem() -> Mem {
  { files: {}, dirs: {} }
}

///|
test "addresses as Node reads them" {
  assert_eq(normalize_browser_url("mail.proton.me"), Some("https://mail.proton.me/"))
  assert_eq(normalize_browser_url("localhost:3000/app"), Some("http://localhost:3000/app"))
  assert_eq(normalize_browser_url("alice@proton.me"), None)
  assert_eq(normalize_browser_url("javascript:alert(1)"), None)
  assert_eq(normalize_browser_url("see https://github.com/foo/bar, and more."), Some("https://github.com/foo/bar"))
  assert_eq(address_or_search("what is 1+1"), Some("https://www.google.com/search?q=what%20is%201%2B1"))
  assert_eq(site_of_browser_url("https://A.test:8443/x?y"), Some("a.test:8443"))
  assert_eq(persistable_browser_url("about:blank"), None)
  let p = session_path("chat:c-1")
  assert_eq(p, "/browser/Y2hhdDpjLTE")
  assert_eq(session_of_path(p + "/?x=1"), Some("chat:c-1"))
  assert_eq(session_of_path("/browser/YR"), None)
}

///|
test "keys, pictures, digests and Farview's wire" {
  assert_eq(key_code("a", "KeyA"), 65)
  assert_eq(key_code("F5", "F5"), 116)
  assert_eq(
    stringify(key_event(jo([("t", js("key")), ("kind", js("down")), ("key", js("z")), ("code", js("KeyZ")), ("mods", ji(12))]))),
    "{\"type\":\"rawKeyDown\",\"key\":\"z\",\"code\":\"KeyZ\",\"modifiers\":12,\"windowsVirtualKeyCode\":90,\"nativeVirtualKeyCode\":90,\"commands\":[\"redo\"]}",
  )
  let jpeg = b"\xff\xd8\xff\xc0\x00\x11\x08\x02\xd0\x05\x00\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01"
  assert_eq(jpeg_size(jpeg), Some((1280, 720)))
  assert_eq(sha256_of(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  assert_eq(chat_dir("chat:a").length(), 24)
  let wire = encode_ask(Act("type", "[x]", "é"))
  assert_eq(wire.length(), 4 + 1 + 5 + 4 + 3)
  assert_eq(decode_answer(b"\x42\x04hi").map(a => stringify(a.to_j())), Some("{\"kind\":\"value\",\"value\":\"hi\"}"))
  assert_eq(gh_source("gh:a/b@t/n"), Some(("a/b", "t", "n")))
}

///|
test "the gate puts the chat's context on a new tab, opened behind, and refuses another's" {
  let g = Gate::new({ context: "C1", context_of: _ => None, opened: None, used: None, act: None })
  let up = g.from_client("{\"id\":1,\"method\":\"Target.createTarget\",\"params\":{\"url\":\"https://a/\"}}").up
  assert_eq(
    up,
    [
      "{\"id\":1,\"method\":\"Target.createTarget\",\"params\":{\"url\":\"https://a/\",\"browserContextId\":\"C1\",\"newWindow\":true,\"background\":true}}",
    ],
  )
  let down = g.from_client("{\"id\":2,\"method\":\"Storage.getCookies\",\"params\":{\"browserContextId\":\"C2\"}}").down
  assert_eq(down, ["{\"id\":2,\"error\":{\"code\":-32601,\"message\":\"No such browser context of this chat's.\"}}"])
}

///|
test "a DevTools connection: a command answered by its id, Chrome's error said, events heard, its end failing what waits" {
  let rt = @effect.Runtime::new()
  let clock = vclock(rt)
  let sent = []
  let link = CdpLink::new({ send: t => sent.push(t), close: () => () }, clock)
  let cdp = link.cdp()
  let got : Ref[String] = Ref("")
  let failed : Ref[String] = Ref("")
  let heard = []
  ignore((cdp.on)(e => heard.push(e.method)))
  ignore(
    rt.fork(async fn() {
      got.val = stringify(cdp.ask("Browser.getVersion"))
      ignore(cdp.ask("Bad.method", session="S")) catch {
        e => failed.val = message_of(e)
      }
      ignore(cdp.ask("Late")) catch {
        e => failed.val = failed.val + " / " + message_of(e)
      }
    }),
  )
  rt.advance(1)
  assert_eq(sent, ["{\"id\":1,\"method\":\"Browser.getVersion\",\"params\":{}}"])
  link.heard("{\"id\":1,\"result\":{\"product\":\"Chrome\"}}")
  link.heard("{\"method\":\"Target.targetCreated\",\"params\":{}}")
  rt.advance(1)
  assert_eq(got.val, "{\"product\":\"Chrome\"}")
  assert_eq(sent[1], "{\"id\":2,\"method\":\"Bad.method\",\"params\":{},\"sessionId\":\"S\"}")
  link.heard("{\"id\":2,\"error\":{\"message\":\"no such method\",\"data\":\"x\"}}")
  rt.advance(1)
  link.ended()
  rt.advance(1)
  assert_eq(failed.val, "no such method: x / the browser's DevTools connection closed")
  assert_eq(heard, ["Target.targetCreated"])
}

///|
test "a DevTools socket that opens only after the time given is closed at once, one in time kept open" {
  let rt = @effect.Runtime::new()
  let clock = vclock(rt)
  let closed = []
  let opened = []
  let open = async fn(url : String, _link : CdpLink) -> CdpSocket {
    // (the late one answers after the 10 s given, the other at once)
    if url == "ws://late" {
      @effect.sleep(cdp_open_ms.to_int() + 5000)
    }
    opened.push(url)
    { send: _ => (), close: () => closed.push(url) }
  }
  let failed : Ref[String] = Ref("")
  ignore(
    rt.fork(async fn() {
      ignore(connect_cdp("ws://late", open, clock)) catch {
        e => failed.val = message_of(e)
      }
    }),
  )
  let kept : Ref[Cdp?] = Ref(None)
  ignore(rt.fork(async fn() { kept.val = Some(connect_cdp("ws://soon", open, clock)) }))
  rt.advance(cdp_open_ms.to_int() + 1)
  assert_eq(failed.val, "the browser's DevTools did not answer at ws://late")
  assert_eq(opened, ["ws://soon"])
  assert_true(kept.val is Some(_))
  assert_eq(closed, [])
  rt.advance(5000)
  assert_eq(opened, ["ws://soon", "ws://late"])
  assert_eq(closed, ["ws://late"])
}

///|
/// A machine of the test's own for Chrome: what it started, signalled and ended; a Chrome that says its port in
/// DevToolsActivePort and names itself headless until it is given an agent.
fn chrome_machine(m : Mem, rt : @effect.Runtime, started : Array[Array[String]], ended : Array[Int]) -> Machine {
  let alive : Map[Int, Unit] = {}
  let agent : Ref[String] = Ref("Mozilla/5.0 HeadlessChrome/156.0")
  {
    now: () => rt.now().to_double(),
    sleep: async fn(ms) { @effect.sleep(ms.to_int()) },
    browsers: () => ["/chrome"],
    browsers_soon: async fn() { ["/chrome"] },
    has_display: () => false,
    start_lasting: (_, args, _, _) => {
      started.push(args)
      let pid = 40 + started.length()
      alive[pid] = ()
      for a in args {
        if a.has_prefix("--user-agent=") {
          agent.val = slice(a, 13)
        }
      }
      m.files["/d/browser/profile/DevToolsActivePort"] = "9222\n/devtools/browser/b\{started.length()}"
      { pid: Some(pid), ended: () => None }
    },
    start_time_of: async fn(_) { Some(1000.0) },
    group_alive: pid => alive.contains(pid),
    end_group: async fn(pid, _) {
      ended.push(pid)
      alive.remove(pid)
    },
    signal_group: (pid, _) => alive.remove(pid),
    free: async fn(_) { true },
    version: async fn(_) {
      match m.files.get("/d/browser/profile/DevToolsActivePort") {
        Some(t) =>
          match parse_active_port(t) {
            Some((_, path)) => Some(("ws://127.0.0.1:9222" + path, agent.val))
            None => None
          }
        None => None
      }
    },
    answers: async fn(_) { false },
    connect: async fn(_) { raise fail_("no DevTools here") },
  }
}

///|
test "Chrome started headless on a profile of its own, started again with its headful agent, kept in state.json, found again, ended" {
  let rt = @effect.Runtime::new()
  let m = mem()
  let started = []
  let ended = []
  let host = chrome_host("/d/browser", chrome_machine(m, rt, started, ended), m.files(), vclock(rt), Log::silent())
  let got : Ref[Running?] = Ref(None)
  let found : Ref[Running?] = Ref(None)
  ignore(rt.fork(async fn() { got.val = Some((host.launch)()) }))
  rt.advance(20_000)
  guard got.val is Some(r) else { fail("not started") }
  assert_eq(r.user_agent, "Mozilla/5.0 Chrome/156.0")
  assert_eq(r.port, 9222)
  assert_eq(started.length(), 2)
  assert_true(started[1].contains("--user-agent=Mozilla/5.0 Chrome/156.0"))
  assert_true(started[0].contains("--headless=new"))
  assert_true(started[0].contains("--screen-info={2880x1800}"))
  assert_true(!chrome_args("/p", 0, false).iter().any(a => a.has_prefix("--screen-info")))
  assert_eq(ended, [41])
  let state = parse(m.files.get("/d/browser/state.json").unwrap())
  assert_eq(text(at_path(Some(state), ["headlessAgent", "agent"])), "Mozilla/5.0 Chrome/156.0")
  assert_eq(js_num(at(Some(state), "port")), 9222.0)
  ignore(rt.fork(async fn() { found.val = (host.find)() }))
  rt.advance(10)
  guard found.val is Some(f) else { fail("not found") }
  assert_eq(f.pid, Some(42))
  assert_eq(f.ws, "ws://127.0.0.1:9222/devtools/browser/b2")
  ignore(rt.fork(async fn() { (host.kill)(f) }))
  rt.advance(10_000)
  assert_eq(ended, [41, 42])
  let after = parse(m.files.get("/d/browser/state.json").unwrap())
  assert_true(at(Some(after), "running") is None)
  assert_true(at(Some(after), "headlessAgent") is Some(_))
}

///|
/// A machine of the test's own for Farview's hosts: each started writes its host.json in its state directory.
fn farview_machine(
  m : Mem,
  rt : @effect.Runtime,
  started : Array[String],
  alive : Map[Int, Unit],
  envs? : Map[String, Map[String, String]] = {},
) -> Machine {
  {
    ..chrome_machine(m, rt, [], []),
    start_lasting: (_, args, cwd, env) => {
      let pid = 500 + started.length()
      started.push("\{cwd} \{args.join(" ")}")
      alive[pid] = ()
      let dir = env.search_by(e => e.0 == "FV_STATE_DIR").map(i => env[i].1).unwrap_or(cwd)
      envs[dir] = Map::from_array(env.filter(e => e.0.has_prefix("FV_TAB_") || e.0.has_prefix("FV_OPENER_")))
      m.files[dir + "/host.json"] = "{\"pid\":\{pid},\"port\":\{pid + 1000},\"agent\":\{pid + 2000},\"frame\":\{pid + 3000}}"
      { pid: Some(pid), ended: () => None }
    },
    group_alive: pid => alive.contains(pid),
    end_group: async fn(pid, _) { alive.remove(pid) },
    answers: async fn(port) { alive.contains(port - 2000) },
  }
}

///|
fn farview_tabs(
  m : Mem,
  rt : @effect.Runtime,
  started : Array[String],
  screens : Array[String],
  alive? : Map[Int, Unit] = {},
  connect? : async (Int) -> TcpLink,
  envs? : Map[String, Map[String, String]] = {},
) -> FarviewTabs {
  m.files["/fv/bin/host.exe"] = "#!"
  m.mkdirs("/fv/bin")
  let clock = vclock(rt)
  let connect = match connect {
    Some(c) => c
    None => async fn(_) { raise fail_("no host here") }
  }
  FarviewTabs::new({
    dir: "/data/browser/farview",
    config: () => Some({
      dir: "/fv",
      host: "/fv/bin/host.exe",
      agent: "/fv/bin/agent.exe",
      engine: "chrome",
      sessions: ["chat:a"],
      release: None,
    }),
    screens: Some({
      add: s => {
        screens.push("+" + s.id)
        () => screens.push("-" + s.id)
      },
      changed: None,
      set_browser: None,
    }),
    fetch: async fn(_) { None },
    sources: _ => [],
    machine: farview_machine(m, rt, started, alive, envs~),
    files: m.files(),
    net: { connect, clock },
    release_io: { write_bytes: async fn(_, _) { () }, untar: async fn(_, _) { () }, random_hex: n => "0".repeat(n * 2) },
    log: Log::silent(),
    env: [("HOME", "/home")],
  })
}

///|
test "a chat's Farview: its first tab started as it asks, more numbered after them, one closed, all stopped, taken up by the next station process, gone with the chat" {
  let rt = @effect.Runtime::new()
  let m = mem()
  let started = []
  let screens = []
  let alive : Map[Int, Unit] = {}
  let fv = farview_tabs(m, rt, started, screens, alive~)
  let chat = "/data/browser/farview/" + chat_dir("chat:a")
  assert_true(fv.active_for("chat:a"))
  assert_true(!fv.active_for("chat:b"))
  let out : Ref[String] = Ref("")
  ignore(
    rt.fork(async fn() {
      let s = fv.endpoint("chat:a")
      let t = fv.open("chat:a", "https://b.test/")
      out.val = "\{s.running} \{t.info.id} \{t.agent}"
    }),
  )
  rt.advance(1000)
  let id = "fv_" + chat_dir("chat:a")
  assert_eq(out.val, "true \{id}_1 2501")
  assert_eq(started, ["\{chat}/tabs/0 --tab 0 about:blank", "\{chat}/tabs/1 --tab 0 https://b.test/"])
  assert_eq(m.files.get(chat + "/session"), Some("chat:a"))
  assert_eq(fv.tabs("chat:a").map(t => t.info.id), [id, id + "_1"])
  assert_eq(fv.agent_port("chat:a"), Some(2500))
  assert_eq(fv.client_port("browser:" + id), Some(1500))
  let refused : Ref[String] = Ref("")
  ignore(
    rt.fork(async fn() {
      fv.close_tab("chat:a", id) catch {
        e => refused.val = message_of(e)
      }
      fv.close_tab("chat:a", "browser:" + id + "_1")
    }),
  )
  rt.advance(10)
  assert_eq(refused.val, "the chat's first tab stays: `stop` closes the browser")
  assert_eq(fv.tabs("chat:a").length(), 1)
  assert_true(!m.dirs.contains(chat + "/tabs/1"))
  // the next station process takes the first tab up as it starts
  fv.close()
  let next = farview_tabs(m, rt, started, screens, alive~)
  ignore(rt.fork(async fn() { next.resume() }))
  rt.advance(10)
  assert_eq(next.tabs("chat:a").map(t => t.info.id), [id])
  assert_eq(started.length(), 2)
  ignore(rt.fork(async fn() { next.choose("chat:a", "chrome") }))
  rt.advance(10)
  assert_eq(m.files.get(chat + "/engine"), Some("chrome"))
  assert_true(!next.active_for("chat:a"))
  assert_eq(next.tabs("chat:a").length(), 0)
  ignore(rt.fork(async fn() { next.close_of("chat:a") }))
  rt.advance(10)
  assert_true(!m.dirs.contains(chat))
  assert_true(!m.files.contains(chat + "/session"))
  assert_eq(screens, [
    "+browser:" + id,
    "+browser:" + id + "_1",
    "-browser:" + id + "_1",
    "-browser:" + id,
    "+browser:" + id,
    "-browser:" + id,
  ])
}

///|
test "a page's popup is a tab told its window id, its opener and its origin; a page that closes its tab has it closed, never the chat's first; one closed while no station held it is not taken up" {
  let rt = @effect.Runtime::new()
  let m = mem()
  let started = []
  let screens = []
  let alive : Map[Int, Unit] = {}
  let envs : Map[String, Map[String, String]] = {}
  let fv = farview_tabs(m, rt, started, screens, alive~, envs~)
  let chat = "/data/browser/farview/" + chat_dir("chat:a")
  let id = "fv_" + chat_dir("chat:a")
  let screen_of = (n : Int) => fv.hosts.get("chat:a").unwrap().get(n).unwrap().screen
  ignore(
    rt.fork(async fn() {
      ignore(fv.endpoint("chat:a"))
      ignore(fv.open("chat:a", "https://popup.test/"))
    }),
  )
  rt.advance(1000)
  // each tab's id among the profile's is its screen's; a tab of its own has no opener
  assert_eq(envs.get(chat + "/tabs/0"), Some({ "FV_TAB_ID": id }))
  assert_eq(envs.get(chat + "/tabs/1"), Some({ "FV_TAB_ID": id + "_1" }))
  // a page opens a window it holds: its tab told the window's id, the opener's and the opener's origin
  screen_of(1).watch_heard(
    parse(
      "{\"openTab\":\"https://oauth.test/\",\"window\":\"w_popup\",\"opener\":\"\{id}_1\",\"origin\":\"https://popup.test\"}",
    ),
  )
  rt.advance(1000)
  assert_eq(
    envs.get(chat + "/tabs/2"),
    Some({ "FV_TAB_ID": "w_popup", "FV_OPENER_ID": id + "_1", "FV_OPENER_ORIGIN": "https://popup.test" }),
  )
  assert_eq(fv.tabs("chat:a").map(t => t.info.id), [id, id + "_1", id + "_2"])
  // its page closes it (window.close(), its OAuth done): closed, its host ended and its directory gone
  let popup_pid = fv.hosts.get("chat:a").unwrap().get(2).unwrap().file.pid
  screen_of(2).watch_heard(parse("{\"closeTab\":true}"))
  rt.advance(10)
  assert_eq(fv.tabs("chat:a").map(t => t.info.id), [id, id + "_1"])
  assert_true(!alive.contains(popup_pid))
  assert_true(!m.dirs.contains(chat + "/tabs/2"))
  // a first tab whose page closes it stays
  screen_of(0).watch_heard(parse("{\"closeTab\":true}"))
  rt.advance(10)
  assert_eq(fv.tabs("chat:a").map(t => t.info.id), [id, id + "_1"])
  // a tab its page closed as no station process held it (its host.json says so): ended and gone as the next one
  // starts, never one of its screens again
  let pid1 = fv.hosts.get("chat:a").unwrap().get(1).unwrap().file.pid
  fv.close()
  m.files[chat + "/tabs/1/host.json"] = "{\"pid\":\{pid1},\"port\":\{pid1 + 1000},\"agent\":\{pid1 + 2000},\"frame\":\{pid1 + 3000},\"closed\":true}"
  let next = farview_tabs(m, rt, started, screens, alive~, envs~)
  ignore(rt.fork(async fn() { next.resume() }))
  rt.advance(10)
  assert_eq(next.tabs("chat:a").map(t => t.info.id), [id])
  assert_true(!alive.contains(pid1))
  assert_true(!m.dirs.contains(chat + "/tabs/1"))
  assert_eq(started.length(), 3)
}

///|
test "a frame port's openTab says a page's new tab and what links it to its opener" {
  let shown = (s : String) => match open_tab_of(parse(s)) {
    Some((url, meta)) => url + " " + stringify(meta.to_j())
    None => "none"
  }
  assert_eq(shown("{\"openTab\":\"https://a.test/\"}"), "https://a.test/ {}")
  assert_eq(
    shown("{\"openTab\":\"https://a.test/\",\"window\":\"w_1\",\"opener\":\"fv_x\",\"origin\":\"https://o.test\"}"),
    "https://a.test/ {\"window\":\"w_1\",\"opener\":\"fv_x\",\"origin\":\"https://o.test\"}",
  )
  assert_eq(shown("{\"openTab\":\"https://a.test/\",\"window\":\"\",\"opener\":3}"), "https://a.test/ {}")
  assert_eq(shown("{\"openTab\":\"\"}"), "none")
  assert_eq(shown("{\"page\":{}}"), "none")
  assert_eq(host_file_of(Some(parse("{\"pid\":1,\"port\":2,\"agent\":3,\"frame\":4,\"closed\":true}"))).map(f => f.closed), Some(true))
  assert_eq(host_file_of(Some(parse("{\"pid\":1,\"port\":2,\"agent\":3,\"frame\":4}"))).map(f => f.closed), Some(false))
}

///|
test "the browser tool gives a chat Farview's ways where it is its browser" {
  let rt = @effect.Runtime::new()
  let m = mem()
  let fv = farview_tabs(m, rt, [], [])
  let tools = browser_tools(
    {
      endpoint: async fn(_) { BrowserStatus::off() },
      tabs: _ => [],
      status: _ => BrowserStatus::off(),
      stop: async fn(_) { () },
    },
    farview=fv,
  )
  let said = []
  ignore(
    rt.fork(async fn() {
      for args in [
        jo([]),
        jo([("action", js("open")), ("url", js("https://c.test/"))]),
        jo([("action", js("status"))]),
        jo([("action", js("close"))]),
        jo([("action", js("bogus"))]),
      ] {
        said.push((tools[0].run)("chat:a", args) catch { e => "refused: " + message_of(e) })
      }
    }),
  )
  rt.advance(1000)
  assert_true(said[0].has_prefix("This chat's browser runs: Farview"))
  assert_eq(said[1], "Opened fv_\{chat_dir("chat:a")}_1 on https://c.test/. Drive it with: `/fv/bin/agent.exe 127.0.0.1 2501 <step>...`")
  assert_eq(said[2], "Running: Farview, 2 tab(s), agent port 2500, 0 view(s) by people.")
  assert_eq(said[3], "refused: close: say which tab (`tab`, an id from tabs)")
  assert_eq(said[4], "refused: unknown action bogus: endpoint, tabs, open, close, status or stop")
}

///|
test "a release refused where its digest is not the release's, unpacked from the next source, moved where it is kept" {
  let rt = @effect.Runtime::new()
  let m = mem()
  let good = b"the tarball"
  let release : FarviewRelease = { rev: "0123456789abcdef", sha256: sha256_of(good) }
  let io : ReleaseIo = {
    write_bytes: async fn(path, b) { m.files[path] = from_utf8(b) },
    untar: async fn(_, out) {
      m.mkdirs(out + "/farview-macos-arm64/bin")
      m.files[out + "/farview-macos-arm64/bin/host.exe"] = "#!"
    },
    random_hex: n => "a".repeat(n * 2),
  }
  let said : Ref[String] = Ref("")
  let dir = "/cache/farview/0123456789ab-darwin-arm64"
  ignore(
    rt.fork(async fn() {
      unpack_release(dir, "darwin-arm64", release, ["https://none/x"], async fn(_) { None }, m.files(), io) catch {
        e => said.val = message_of(e)
      }
      unpack_release(
        dir,
        "darwin-arm64",
        release,
        ["https://bad/x", "https://good/x"],
        async fn(url) { if url.contains("good") { Some(good) } else { Some(b"other") } },
        m.files(),
        io,
      )
    }),
  )
  rt.advance(10)
  assert_eq(
    said.val,
    "Farview's release farview-darwin-arm64-0123456789ab.tar.gz could not be downloaded (https://none/x): say where an unpacked one is in config.json `browser.farview`, or `browser.farview: false` for Chrome alone.",
  )
  assert_eq(m.files.get(dir + "/bin/host.exe"), Some("#!"))
  // (nothing left of its work beside it)
  let left = []
  for k, _ in m.files {
    if k.contains(".farview-") {
      left.push(k)
    }
  }
  assert_eq(left, [])
}

///|
test "a sign-in driven: an account and a password typed and sent, then a code it was not given" {
  let rt = @effect.Runtime::new()
  let step = Ref(0)
  let marked = Ref(false)
  let typed = []
  let form : SignInForm = {
    host: async fn() { "a.test" },
    url: async fn() { "https://a.test/\{step.val}" },
    on: async fn(site) { site == "a.test" },
    look: async fn() {
      if step.val == 0 {
        { username: true, password: true, code: false, blocked: false }
      } else {
        { username: false, password: false, code: true, blocked: false }
      }
    },
    type_: async fn(kind, value) {
      typed.push("\{kind}=\{value}")
      true
    },
    enter: async fn() {
      step.val += 1
      marked.val = false
    },
    press: async fn() { false },
    mark: async fn() { marked.val = true },
    marked: async fn() { marked.val },
    close: () => (),
  }
  let got : Ref[String] = Ref("")
  let used = []
  ignore(
    rt.fork(async fn() {
      let d = drive(form, "a.test", { username: Some("alice"), password: Some("pw"), code: None }, used, async fn(_) { () })
      got.val = stringify(d.to_j())
    }),
  )
  rt.advance(10)
  assert_eq(got.val, "{\"state\":\"code\"}")
  assert_eq(typed, ["username=alice", "password=pw"])
  assert_eq(used, ["username", "password"])
}

///|
test "Windows paths go by their own separator: a drive's, a share's, one of `\\` alone" {
  assert_eq(sep_of("C:\\data\\browser"), "\\")
  assert_eq(sep_of("\\\\host\\share\\x"), "\\")
  assert_eq(sep_of("data\\browser"), "\\")
  assert_eq(sep_of("/data/browser"), "/")
  assert_eq(sep_of("a\\b/c"), "/")
  assert_eq(join("C:\\data\\browser", "state.json"), "C:\\data\\browser\\state.json")
  assert_eq(pdirname("C:\\data\\accounts\\x\\state.json"), "C:\\data\\accounts\\x")
  assert_eq(pdirname("/d/browser/state.json"), "/d/browser")
  assert_eq(pjoin(["C:\\cache\\farview\\x", ".."]), "C:\\cache\\farview")
  let release : FarviewRelease = { rev: "0123456789abcdef", sha256: "" }
  assert_eq(farview_cache_dir("C:\\Users\\a\\cache", "win32-x64", release), "C:\\Users\\a\\cache\\farview\\0123456789ab-win32-x64")
  let cfg = farview_config(Some(parse("{\"browser\":{\"farview\":\"C:\\\\fv\"}}")), "win32-x64", [], "C:\\cache").unwrap()
  assert_eq(cfg.host, "C:\\fv\\bin\\host.exe")
  assert_eq(cfg.agent, "C:\\fv\\bin\\agent.exe")
}

///|
/// An agent port as a Farview host's (its wire's asks read, each answered): a page's PublicKeyCredential there where
/// `authenticator`, the profile's passkeys kept in `kept`; what was asked written down by kind.
fn agent_link(authenticator : Bool, kept : Array[Passkey], asked : Array[String]) -> async (Int) -> TcpLink {
  async fn(_) {
    let out : Array[Bytes] = []
    let answer = (v : String) => {
      let body = @buffer.new()
      varint(body, kind_value)
      wire_str(body, v)
      let b = body.to_bytes()
      let framed = @buffer.new()
      let n = b.length()
      framed.write_byte((n >> 24).to_byte())
      framed.write_byte(((n >> 16) & 0xff).to_byte())
      framed.write_byte(((n >> 8) & 0xff).to_byte())
      framed.write_byte((n & 0xff).to_byte())
      framed.write_bytes(b)
      out.push(framed.to_bytes())
    }
    {
      write: async fn(b) {
        let r : WireReader = { b: b[4:].to_bytes(), i: 0 }
        let kind = r.int()
        if kind == kind_eval {
          asked.push("eval")
          answer(if authenticator { "true" } else { "false" })
        } else if kind == kind_passkeys {
          let verb = r.string()
          let arg = r.string()
          asked.push("passkeys \{verb}")
          match verb {
            "get" => answer(stringify(ja(kept.filter(p => arg == "" || of_sites(p.rp_id, [arg])).map(p => p.to_j()))))
            "set" => {
              guard parse(arg) is Arr(list) else { return }
              for j in list {
                guard passkey_of(Some(j)) is Some(p) else { continue }
                match kept.search_by(q => q.credential_id == p.credential_id) {
                  Some(i) => kept[i] = p
                  None => kept.push(p)
                }
              }
              answer("ok: \{list.length()} set")
            }
            _ => {
              let left = kept.filter(p => !of_sites(p.rp_id, [arg]))
              kept.clear()
              kept.append(left)
              answer("ok")
            }
          }
        } else if kind == kind_cookies {
          let verb = r.string()
          asked.push("cookies \{verb}")
          answer(if verb == "get" { "[]" } else { "ok" })
        }
      },
      read: async fn() { if out.length() > 0 { Some(out.remove(0)) } else { None } },
      close: () => (),
    }
  }
}

///|
test "a sign-in's passkeys go into a chat's Farview profile and come out with its cookies; a host with no authenticator is asked none" {
  let keys = [
    passkey_of(Some(parse("{\"credentialId\":\"Y3JlZC1h\",\"rpId\":\"github.com\",\"privateKey\":\"cGs=\",\"userHandle\":\"dQ==\",\"signCount\":3}"))).unwrap(),
    passkey_of(Some(parse("{\"credentialId\":\"Y3JlZC1i\",\"rpId\":\"login.example.com\",\"privateKey\":\"cGs=\",\"signCount\":0}"))).unwrap(),
  ]
  let ids = (l : Array[Passkey]) => l.map(p => p.credential_id).join(",")
  for authenticator in [true, false] {
    let rt = @effect.Runtime::new()
    let m = mem()
    let kept : Array[Passkey] = []
    let asked : Array[String] = []
    let fv = farview_tabs(m, rt, [], [], connect=agent_link(authenticator, kept, asked))
    let got : Ref[String] = Ref("")
    ignore(
      rt.fork(async fn() {
        let before = fv.passkeys("chat:a")
        fv.put_passkeys("chat:a", keys)
        let after = fv.passkeys("chat:a")
        let (cookies, taken) = fv.take_out("chat:a", ["github.com"])
        let left = fv.passkeys("chat:a")
        got.val = "\{ids(before)}|\{ids(after)}|\{cookies.length()} \{ids(taken)}|\{ids(left)}"
      }),
    )
    rt.advance(1000)
    if authenticator {
      assert_eq(got.val, "|Y3JlZC1h,Y3JlZC1i|0 Y3JlZC1h|Y3JlZC1i")
      assert_eq(asked, [
        "eval", "passkeys get", "passkeys set", "passkeys get", "cookies get", "passkeys get", "passkeys clear", "passkeys get",
      ])
    } else {
      // (asked once whether it has one, then nothing of passkeys)
      assert_eq(got.val, "||0 |")
      assert_eq(asked, ["eval", "cookies get"])
    }
  }
}
