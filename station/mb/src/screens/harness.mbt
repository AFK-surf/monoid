// The harness's commands (reader `--builder harness-screens`): what station/test/mb-screens.test.ts asks of these
// parts, the same asked of the TypeScript of station/src/screens/ and src/helper/. `{"cmd": name, "id": n, …}`,
// answered `{"done": n, "ok": value}` or `{"done": n, "err": error}`, each on a fiber of its own (a part waiting on
// its world goes on as the test asks more): `world` (what the machine says of itself, the station's words), `pure`
// (one of the parts' plain functions), `new` (a part made, named `inst`), `call` (one of a part's methods, its result
// named `as` where it is a part again), `sync` (answered once nothing here can go on before the world answers).

///|
priv enum Inst {
  IHub(ScreenHub)
  ISource(ScreenSource)
  IView(ScreenView)
  IHelperView(HelperView)
  IHelper(HelperApp)
  IGrants(HelperGrants)
  IFiles(HelperFiles)
  IHfs(HelperFs)
  IDesktop(Desktop)
  IWindows(WindowsDesktop)
  ISims(Simulators)
  IDebug(SimDebug)
  IChrome(ChromeSource)
  IAndroids(AndroidScreens)
  IX11(X11Desktop)
  IGst(LinuxGstDesktop)
  ILinuxNative(LinuxNativeDesktop)
  ILinux(LinuxDesktop)
  ITools(LinuxScreenTools)
  IMac(MacInput)
  IWinIn(WinInput)
  ILinuxIn(LinuxInput)
  ISimIn(SimInput)
  IAndIn(AndroidInput)
  IScrcpy(ScrcpyStream)
  IPeek(PeekCount)
  ISock(Sock)
}

///|
priv struct Harness {
  rpc : Rpc
  /// The ports, made again as the world says what the machine is (`world`).
  mut io : Io
  insts : Map[String, Inst]
}

///|
fn Harness::cb(self : Harness, name : String) -> () -> Unit {
  () => self.rpc.tell("cb", [("cb", js(name))])
}

///|
fn Harness::cb_with(self : Harness, name : String, v : J) -> Unit {
  self.rpc.tell("cb", [("cb", js(name)), ("value", v)])
}

///|
fn Harness::inst(self : Harness, name : String) -> Inst raise {
  match self.insts.get(name) {
    Some(i) => i
    None => raise fail("no part named \{name}")
  }
}

///|
fn sz(s : (Double, Double)) -> J {
  jo([("width", jn(s.0)), ("height", jn(s.1))])
}

///|
fn opt_j(v : J?) -> J {
  v.unwrap_or(Null)
}

///|
fn strs_of(j : J?) -> Array[String] {
  arr(j).unwrap_or([]).filter_map(x => text(Some(x)))
}

///|
fn bool_of(j : J?) -> Bool {
  j is Some(Bool(true))
}

///|
fn Harness::env_arg(self : Harness, j : J?) -> Env {
  match j {
    Some(Obj(_) as o) => Env::of_j(o)
    _ => (self.io.os.env)()
  }
}

///|
fn Harness::helper_of(self : Harness, j : J?) -> HelperApp? raise {
  match text(j) {
    Some(name) =>
      match self.inst(name) {
        IHelper(h) => Some(h)
        _ => raise fail("\{name} is no helper")
      }
    None => None
  }
}

///|
fn Harness::reach(self : Harness) -> async () -> String? {
  async fn() { text(Some(self.rpc.call("reach", []))) }
}

///|
/// A source made up by the test (its spec: what it says, what it has), every act it takes told.
fn Harness::fake_source(self : Harness, spec : J) -> ScreenSource {
  let id = text(get(Some(spec), "id")).unwrap_or("fake")
  let has = (k : String) => bool_of(get(Some(spec), k))
  let act = (name : String) => Some(async fn() { self.cb_with("\{id}.\{name}", Null) })
  let title = text(get(Some(spec), "title")).unwrap_or(id)
  let size = (num(get(Some(spec), "width")).unwrap_or(0.0), num(get(Some(spec), "height")).unwrap_or(0.0))
  let kind = match text(get(Some(spec), "kind")) {
    Some("browser") => BrowserKind
    Some("simulator") => SimulatorKind
    _ => DesktopKind
  }
  let view = (options : ViewOptions) => {
    ignore(options)
    let ended = Ref(false)
    ScreenView::bare(
      async fn() {
        self.cb_with("\{id}.next", Null)
        None
      },
      () => self.cb_with("\{id}.keyframe", Null),
      async fn(e) { self.cb_with("\{id}.input", e.to_j()) },
      () => if !ended.val {
        ended.val = true
        self.cb_with("\{id}.close", Null)
      },
    )
  }
  {
    ..ScreenSource::bare(id, kind, () => title, () => size, async fn(o) {
      self.cb_with("\{id}.open", jo([("maxWidth", jn(o.max_width)), ("maxHeight", jn(o.max_height))]))
      view(o)
    }),
    access: match get(Some(spec), "access") {
      Some(Obj(_) as a) =>
        Some(() => ScreenAccess::new(
          bool_of(get(Some(a), "capture")),
          bool_of(get(Some(a), "control")),
          unsupported=text(get(Some(a), "unsupported")),
          reason=text(get(Some(a), "reason")),
          app=text(get(Some(a), "app")),
          path=text(get(Some(a), "path")),
          asking=bool_of(get(Some(a), "asking")),
        ))
      _ => None
    },
    clipboard: match get(Some(spec), "clipboard") {
      Some(Arr(_) as c) => Some(() => strs_of(Some(c)))
      _ => None
    },
    reveal: has("reveal"),
    peek: has("peek"),
    farview: has("farview"),
    opened_by: match text(get(Some(spec), "openedBy")) {
      Some(b) => Some(() => Some(b))
      None => None
    },
    user_tab: has("userTab"),
    sleeping: if get(Some(spec), "sleeping") is Some(_) { Some(() => has("sleeping")) } else { None },
    site: match text(get(Some(spec), "site")) {
      Some(s) => Some(() => Some(s))
      None => None
    },
    open_url: if has("openUrl") { Some(async fn(u) { self.cb_with("\{id}.openUrl", js(u)) }) } else { None },
    reload: if has("reload") { act("reload") } else { None },
    back: if has("back") { act("back") } else { None },
    forward: if has("forward") { act("forward") } else { None },
    sleep: if has("sleep") { act("sleep") } else { None },
    discard: if has("discard") { act("discard") } else { None },
    since: match num(get(Some(spec), "since")) {
      Some(s) => Some(() => Some(s))
      None => None
    },
    poses: has("poses"),
    panels: match arr(get(Some(spec), "panels")) {
      Some(ps) =>
        Some(
          ps.map(p => {
            width: num(get(Some(p), "width")).unwrap_or(0.0),
            height: num(get(Some(p), "height")).unwrap_or(0.0),
            corners: arr(get(Some(p), "corners")).unwrap_or([]).filter_map(c => num(Some(c))),
          }),
        )
      None => None
    },
  }
}

///|
fn Harness::source_of(self : Harness, i : Inst) -> ScreenSource? {
  match i {
    ISource(s) => Some(s)
    IDesktop(d) => Some(d.source())
    IWindows(w) => Some(w.source())
    IX11(x) => Some(x.source())
    IGst(g) => Some(g.source())
    ILinuxNative(n) => Some(n.source())
    ILinux(l) => Some(l.source())
    _ => None
  }
}

///|
fn Harness::keep(self : Harness, args : J, i : Inst) -> J {
  match text(get(Some(args), "as")) {
    Some(name) => {
      self.insts[name] = i
      js(name)
    }
    None => Null
  }
}

///|
fn chrome_pictures_j(p : ChromePictures) -> J {
  p.to_j()
}

///|
/// What a source is asked of, as any source is.
async fn Harness::source_call(self : Harness, s : ScreenSource, f : String, a : J) -> J {
  let arg = (k : String) => get(Some(a), k)
  match f {
    "id" => js(s.id)
    "kind" => js(s.kind.name())
    "title" => js((s.title)())
    "size" => sz((s.size)())
    "access" =>
      match s.access {
        Some(f) => f().to_j()
        None => Null
      }
    "clipboard" =>
      match s.clipboard {
        Some(f) => jstrs(f())
        None => Null
      }
    "flags" =>
      jsome([
        ("reveal", if s.reveal { Some(jb(true)) } else { None }),
        ("peek", if s.peek { Some(jb(true)) } else { None }),
        ("poses", if s.poses { Some(jb(true)) } else { None }),
        ("debug", if s.debug is Some(_) { Some(jb(true)) } else { None }),
        ("discard", if s.discard is Some(_) { Some(jb(true)) } else { None }),
        ("panels", s.panels.map(p => ja(p.map(x => x.to_j())))),
        ("chrome", s.chrome.map(c => ja(c.map(x => x.told().to_j())))),
      ])
    "open" => {
      let view = (s.open)(view_options_of(arg("options").unwrap_or(Obj([]))))
      self.keep(a, IView(view))
    }
    "discard" =>
      match s.discard {
        Some(f) => {
          f()
          Null
        }
        None => raise fail("no discard")
      }
    "since" =>
      match s.since {
        Some(f) => opt_num(f())
        None => Null
      }
    "scale" =>
      match s.scale {
        Some(f) =>
          match f() {
            Some(x) => x.to_j()
            None => Null
          }
        None => raise fail("no scale")
      }
    "setScale" =>
      match s.set_scale {
        Some(f) => f(num(arg("percent")).unwrap_or(0.0)).to_j()
        None => raise fail("no setScale")
      }
    "resolution" =>
      match s.resolution {
        Some(f) =>
          match f() {
            Some(x) => x.to_j()
            None => Null
          }
        None => raise fail("no resolution")
      }
    "setResolution" =>
      match s.set_resolution {
        Some(f) => f(num(arg("width")).unwrap_or(0.0), num(arg("height")).unwrap_or(0.0)).to_j()
        None => raise fail("no setResolution")
      }
    "ui" =>
      match s.ui {
        Some(f) => f(strs_of(arg("args")))
        None => raise fail("no ui")
      }
    "debug" =>
      match s.debug {
        Some(d) => self.keep(a, IDebug(d))
        None => Null
      }
    "chrome" =>
      match s.chrome {
        Some(cs) => {
          let i = num(arg("panel")).unwrap_or(0.0).to_int()
          if i < cs.length() {
            self.keep(a, IChrome(cs[i]))
          } else {
            Null
          }
        }
        None => Null
      }
    _ => raise fail("a source has no \{f}")
  }
}

///|
/// What a view is asked of, as any view is.
async fn Harness::view_call(self : Harness, name : String, v : ScreenView, f : String, a : J) -> J {
  let arg = (k : String) => get(Some(a), k)
  match f {
    "next" =>
      match (v.next)() {
        Some(frame) => frame.to_j()
        None => Null
      }
    "nextAudio" =>
      match v.next_audio {
        Some(g) =>
          match g() {
            Some(x) => x.to_j()
            None => Null
          }
        None => raise fail("no nextAudio")
      }
    "keyframe" => {
      (v.keyframe)()
      Null
    }
    "input" => {
      (v.input)(input_of(arg("event").unwrap_or(Null)).unwrap())
      Null
    }
    "rate" => {
      match v.rate {
        Some(g) => g(num(arg("bits")).unwrap_or(0.0))
        None => raise fail("no rate")
      }
      Null
    }
    "bounds" => {
      match v.bounds {
        Some(g) => g(num(arg("maxWidth")).unwrap_or(0.0), num(arg("maxHeight")).unwrap_or(0.0), region_of(arg("region")))
        None => raise fail("no bounds")
      }
      Null
    }
    "regions" =>
      match v.regions {
        Some(g) => jb(g())
        None => Null
      }
    "video" =>
      match v.video {
        Some(g) => g().to_j()
        None => Null
      }
    "why" =>
      match v.why {
        Some(g) => jopt_s(g())
        None => Null
      }
    "close" => {
      (v.close)()
      Null
    }
    "setClipboard" => {
      match v.set_clipboard {
        Some(g) => g(clip_of(arg("clip").unwrap_or(Null)).unwrap(), bool_of(arg("paste")))
        None => raise fail("no setClipboard")
      }
      Null
    }
    "watchClipboard" =>
      match v.watch_clipboard {
        Some(g) => {
          let stop = g(c => self.cb_with("\{name}.clipboard", c.to_j()))
          self.insts["\{name}.unwatchClipboard"] = IView(ScreenView::bare(async fn() { None }, () => (), async fn(_) { () }, stop))
          Null
        }
        None => raise fail("no watchClipboard")
      }
    "watchCursor" =>
      match v.watch_cursor {
        Some(g) => {
          let stop = g(c => self.cb_with("\{name}.cursor", c.to_j()))
          self.insts["\{name}.unwatchCursor"] = IView(ScreenView::bare(async fn() { None }, () => (), async fn(_) { () }, stop))
          Null
        }
        None => raise fail("no watchCursor")
      }
    "cursorImage" =>
      match v.cursor_image {
        Some(g) =>
          match g(text(arg("shape")).unwrap_or("")) {
            Some(b) => js(b64(b))
            None => Null
          }
        None => raise fail("no cursorImage")
      }
    "watchTurn" =>
      match v.watch_turn {
        Some(g) => {
          let stop = g(t => self.cb_with("\{name}.turn", ji(t)))
          self.insts["\{name}.unwatchTurn"] = IView(ScreenView::bare(async fn() { None }, () => (), async fn(_) { () }, stop))
          Null
        }
        None => raise fail("no watchTurn")
      }
    "watchWindows" =>
      match v.watch_windows {
        Some(g) => {
          let stop = g(w => self.cb_with("\{name}.windows", w.to_j()))
          self.insts["\{name}.unwatchWindows"] = IView(ScreenView::bare(async fn() { None }, () => (), async fn(_) { () }, stop))
          Null
        }
        None => raise fail("no watchWindows")
      }
    "window" => {
      match v.window {
        Some(g) => g(num(arg("id")))
        None => raise fail("no window")
      }
      Null
    }
    "watchMic" =>
      match v.watch_mic {
        Some(g) => {
          let stop = g(m => self.cb_with("\{name}.mic", m.to_j()))
          self.insts["\{name}.unwatchMic"] = IView(ScreenView::bare(async fn() { None }, () => (), async fn(_) { () }, stop))
          Null
        }
        None => raise fail("no watchMic")
      }
    "feedMic" => {
      match v.feed_mic {
        Some(g) => g(b64_of(arg("pcm")), num(arg("epoch")).unwrap_or(0.0).to_uint64().to_uint())
        None => raise fail("no feedMic")
      }
      Null
    }
    "reveal" => {
      match v.reveal {
        Some(g) => g(text(arg("path")).unwrap_or(""))
        None => raise fail("no reveal")
      }
      Null
    }
    "has" =>
      jo([
        ("nextAudio", jb(v.next_audio is Some(_))),
        ("rate", jb(v.rate is Some(_))),
        ("bounds", jb(v.bounds is Some(_))),
        ("video", jb(v.video is Some(_))),
        ("why", jb(v.why is Some(_))),
        ("setClipboard", jb(v.set_clipboard is Some(_))),
        ("watchClipboard", jb(v.watch_clipboard is Some(_))),
        ("watchCursor", jb(v.watch_cursor is Some(_))),
        ("watchWindows", jb(v.watch_windows is Some(_))),
        ("reveal", jb(v.reveal is Some(_))),
      ])
    _ => raise fail("a view has no \{f}")
  }
}
