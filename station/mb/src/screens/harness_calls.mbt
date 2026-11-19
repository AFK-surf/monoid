// The harness's parts made and asked (`new`, `call`): each kind of part, as the TypeScript's is made and asked.

///|
fn Harness::watcher(self : Harness, spec : J) -> Watcher {
  let name = text(get(Some(spec), "name")).unwrap_or("")
  let label = text(get(Some(spec), "label")).unwrap_or(name)
  Watcher::new(
    name,
    bool_of(get(Some(spec), "control")),
    state => self.cb_with("\{label}.tell", state),
    device=text(get(Some(spec), "device")),
    self_=text(get(Some(spec), "self")),
    client=text(get(Some(spec), "client")),
    app=text(get(Some(spec), "app")),
    agent=bool_of(get(Some(spec), "agent")),
    end=if bool_of(get(Some(spec), "end")) { Some(by => self.cb_with("\{label}.end", js(by))) } else { None },
    watch_only=if bool_of(get(Some(spec), "watchOnly")) {
      Some(by => self.cb_with("\{label}.watchOnly", jopt_s(by)))
    } else {
      None
    },
  )
}

///|
async fn Harness::make(self : Harness, kind : String, a : J) -> Inst {
  let arg = (k : String) => get(Some(a), k)
  let name = text(arg("inst")).unwrap_or(kind)
  match kind {
    "hub" =>
      IHub(
        ScreenHub::new(
          self.io,
          drop=match arg("drop") {
            Some(Str(_) as d) => Some(() => text(Some(d)))
            Some(Null) => Some(() => None)
            _ => None
          },
        ),
      )
    "fakeSource" => ISource(self.fake_source(arg("spec").unwrap_or(Obj([]))))
    "helperView" => {
      let socket = Sock::create(self.io, Unix(text(arg("path")).unwrap_or("/view.sock")))
      let input = match text(arg("input")) {
        Some("win") => WinInput::new().input_ops()
        Some("sim") => SimInput::new().input_ops()
        _ => MacInput::new().input_ops()
      }
      IHelperView(
        HelperView::new(
          self.io,
          codec_of(text(arg("codec")).unwrap_or("h264")).unwrap_or(H264),
          sock_pipe(socket),
          self.cb("\{name}.gone"),
          input=Some(input),
          capture=text(arg("capture")).unwrap_or("ScreenCaptureKit"),
          audio=bool_of(arg("audio")),
          mic=bool_of(arg("mic")),
        ),
      )
    }
    "helper" =>
      IHelper(
        HelperApp::new(
          self.io,
          text(arg("app")).unwrap_or(""),
          text(arg("dir")).unwrap_or(""),
          on_back=if bool_of(arg("onBack")) { Some(self.cb("\{name}.back")) } else { None },
        ),
      )
    "grants" => {
      let helper = self.helper_of(arg("helper")).unwrap()
      IGrants(
        HelperGrants::new(
          self.io,
          helper,
          self.reach(),
          folders=!(arg("folders") is Some(Bool(false))),
          volumes=text(arg("volumes")).unwrap_or("/Volumes"),
        ),
      )
    }
    "files" => {
      let helper = self.helper_of(arg("helper")).unwrap()
      let grants = match text(arg("grants")) {
        Some(g) =>
          match self.inst(g) {
            IGrants(x) => Some(x)
            _ => None
          }
        None => None
      }
      IFiles(HelperFiles::new(self.io, helper, self.cb("\{name}.changed"), self.reach(), grants~))
    }
    "desktop" => {
      let helper = self.helper_of(arg("helper"))
      let grants = match text(arg("grants")) {
        Some(g) =>
          match self.inst(g) {
            IGrants(x) => Some(x)
            _ => None
          }
        None => None
      }
      IDesktop(
        Desktop::new(self.io, {
          supported: bool_of(arg("supported")),
          helper,
          grants,
          reach: self.reach(),
          changed: self.cb("\{name}.changed"),
          title: match text(arg("title")) {
            Some(t) => Some(() => t)
            None => None
          },
          lang: match text(arg("lang")) {
            Some(l) => Some(() => l)
            None => None
          },
          synthetic: text(arg("synthetic")),
        }),
      )
    }
    "windows" =>
      IWindows(
        WindowsDesktop::new(self.io, {
          binary: text(arg("binary")),
          ui: text(arg("ui")),
          changed: self.cb("\{name}.changed"),
          title: match text(arg("title")) {
            Some(t) => Some(() => t)
            None => None
          },
          start: None,
        }),
      )
    "simulators" => {
      let hub = match self.inst(text(arg("hub")).unwrap_or("hub")) {
        IHub(h) => h
        _ => raise fail("no hub")
      }
      ISims(Simulators::new(self.io, s => hub.add(s), self.helper_of(arg("helper")), devices=text(arg("devices"))))
    }
    "androids" => {
      let hub = match self.inst(text(arg("hub")).unwrap_or("hub")) {
        IHub(h) => h
        _ => raise fail("no hub")
      }
      let adb = text(arg("adb"))
      IAndroids(AndroidScreens::new(self.io, s => hub.add(s), () => hub.changed(), () => adb, file=text(arg("file")), look_again=num(arg("lookAgain"))))
    }
    "tools" => ITools(LinuxScreenTools::new(self.io, text(arg("data")).unwrap_or("")))
    "x11" => {
      let tools = match text(arg("tools")) {
        Some(t) =>
          match self.inst(t) {
            ITools(x) => Some(x)
            _ => None
          }
        None => None
      }
      IX11(
        X11Desktop::new(self.io, {
          changed: self.cb("\{name}.changed"),
          title: match text(arg("title")) {
            Some(t) => Some(() => t)
            None => None
          },
          tools,
          env: match arg("env") {
            Some(Obj(_) as e) => Some(Env::of_j(e))
            _ => None
          },
          ffmpeg: text(arg("ffmpeg")),
          xdotool: text(arg("xdotool")),
          prepare_wait_ms: num(arg("prepareWaitMs")),
        }),
      )
    }
    "gst" =>
      IGst(
        LinuxGstDesktop::new(self.io, {
          changed: self.cb("\{name}.changed"),
          env: self.env_arg(arg("env")),
          mode: text(arg("mode")),
          title: match text(arg("title")) {
            Some(t) => Some(() => t)
            None => None
          },
          python: text(arg("python")),
          helper: text(arg("helper")),
          consent_wait_ms: num(arg("consentWaitMs")),
        }),
      )
    "linux" =>
      ILinux(
        LinuxDesktop::new(self.io, {
          data: text(arg("data")).unwrap_or(""),
          changed: self.cb("\{name}.changed"),
          title: match text(arg("title")) {
            Some(t) => Some(() => t)
            None => None
          },
          env: match arg("env") {
            Some(Obj(_) as e) => Some(Env::of_j(e))
            _ => None
          },
          discover: None,
        }),
      )
    "macInput" => IMac(MacInput::new())
    "winInput" => IWinIn(WinInput::new())
    "simInput" => ISimIn(SimInput::new())
    "androidInput" => IAndIn(AndroidInput::new())
    "scrcpy" =>
      IScrcpy(
        ScrcpyStream::new(size => self.cb_with("\{name}.session", sz(size)), p => self.cb_with(
          "\{name}.packet",
          jo([("config", jb(p.config)), ("key", jb(p.key)), ("pts", js(p.pts.to_string())), ("data", js(b64(p.data)))]),
        )),
      )
    "peeks" => IPeek(PeekCount::new(most=num(arg("most")).map(d => d.to_int()).unwrap_or(PEEKS_MOST)))
    _ => raise fail("no part \{kind}")
  }
}

///|
async fn Harness::call(self : Harness, name : String, f : String, a : J) -> J {
  let arg = (k : String) => get(Some(a), k)
  let s = (k : String) => text(arg(k)).unwrap_or("")
  let n = (k : String) => num(arg(k)).unwrap_or(0.0)
  let i = self.inst(name)
  match i {
    IHub(hub) =>
      match f {
        "add" => {
          let src = match self.source_of(self.inst(s("source"))) {
            Some(x) => x
            None => raise fail("no source")
          }
          let remove = hub.add(src)
          self.insts["\{s("source")}.remove"] = IView(ScreenView::bare(async fn() { None }, () => (), async fn(_) { () }, remove))
          Null
        }
        "remove" => {
          match self.insts.get("\{s("source")}.remove") {
            Some(IView(v)) => (v.close)()
            _ => ()
          }
          Null
        }
        "list" => jstrs(hub.list().map(x => x.id))
        "get" =>
          match hub.get(s("id")) {
            Some(src) => self.keep(a, ISource(src))
            None => Null
          }
        "watch" => {
          ignore(hub.watch(list => self.cb_with("\{name}.watch", jstrs(list.map(x => x.id)))))
          Null
        }
        "onChange" => {
          ignore(hub.on_change(() => self.cb_with("\{name}.change", Null)))
          Null
        }
        "changed" => {
          hub.changed()
          Null
        }
        "refresher" => {
          let label = s("label")
          ignore(hub.refresher(async fn() { self.cb_with("\{label}.refresh", Null) }))
          Null
        }
        "refresh" => {
          hub.refresh()
          Null
        }
        "people" => hub.people(s("id"))
        "join" => {
          let leave = hub.join(s("id"), self.watcher(arg("watcher").unwrap_or(Obj([]))))
          self.insts[s("as")] = IView(ScreenView::bare(async fn() { None }, () => (), async fn(_) { () }, leave))
          Null
        }
        "leave" => {
          match self.insts.get(s("view")) {
            Some(IView(v)) => (v.close)()
            _ => ()
          }
          Null
        }
        "endView" => {
          hub.end_view(s("id"), s("view"), s("by"))
          Null
        }
        "watchOnly" => {
          hub.watch_only(s("id"), s("view"))
          Null
        }
        "mayDrive" => jb(hub.may_drive(s("id"), s("device"), bool_of(arg("taken"))))
        "drive" => {
          let (control, took) = hub.drive(s("id"), s("device"), bool_of(arg("taken")), s("by"))
          jo([("control", jb(control)), ("took", jstrs(took))])
        }
        "takeControl" => ji(hub.take_control(s("id"), by=text(arg("by"))))
        "endViews" => ji(hub.end_views(s("id"), s("by")))
        "openAs" => {
          let view = hub.open_as(s("id"), view_options_of(arg("options").unwrap_or(Obj([]))), s("name"), bool_of(arg("control")))
          self.keep(a, IView(view))
        }
        "whenStopping" => {
          let label = s("label")
          ignore(hub.when_stopping(() => self.cb_with("\{label}.stop", Null)))
          Null
        }
        "close" => {
          hub.close()
          Null
        }
        "closeScreen" => {
          hub.close_screen(s("id"))
          Null
        }
        "setBrowser" => {
          match arg("browser") {
            Some(Obj(_) as b) => {
              let available = bool_of(get(Some(b), "available"))
              hub.set_browser(
                Some({
                  available: () => available,
                  open_user_tab: async fn(url, id) {
                    self.cb_with("browser.open", jo([("url", js(url)), ("id", jopt_s(id))]))
                    "browser:\{id.unwrap_or("u_000000000000")}"
                  },
                }),
              )
            }
            _ => hub.set_browser(None)
          }
          Null
        }
        "openBrowser" => js(hub.open_browser(s("url"), id=text(arg("id"))))
        "openUrl" => {
          hub.open_url(s("id"), s("url"))
          Null
        }
        "reloadScreen" => {
          hub.reload_screen(s("id"))
          Null
        }
        "historyScreen" => {
          hub.history_screen(s("id"), n("delta").to_int())
          Null
        }
        "sleepScreen" => {
          hub.sleep_screen(s("id"))
          Null
        }
        "debugOf" => self.keep(a, IDebug(hub.debug_of(s("id"))))
        "chromeOf" => chrome_pictures_j(hub.chrome_of(s("id"), n("panel").to_int(), n("turn")))
        "listed" => hub.listed(s("lang"))
        _ => raise fail("a hub has no \{f}")
      }
    ISource(src) => self.source_call(src, f, a)
    IView(v) => self.view_call(name, v, f, a)
    IHelperView(v) =>
      match f {
        "ready" => v.ready.wait()
        "hasAudio" => jb(v.has_audio())
        _ => self.view_call(name, v.view(), f, a)
      }
    IHelper(h) =>
      match f {
        "request" => h.request(arg("op").unwrap_or(Obj([])))
        "connect" => self.keep(a, ISock(h.connect(arg("op").unwrap_or(Obj([])))))
        "pid" => opt_num(h.pid())
        "restarted" => {
          h.restarted(n("pid"))
          Null
        }
        "ensure" => {
          h.ensure()
          Null
        }
        "back" => {
          h.back()
          Null
        }
        "quit" => {
          h.quit()
          Null
        }
        "listen" => {
          ignore(h.listen(e => self.cb_with("\{name}.event", e)))
          Null
        }
        "onBack" => {
          ignore(h.on_back(self.cb("\{name}.back")))
          Null
        }
        "ui" => helper_ui(h)(strs_of(arg("args")))
        _ => raise fail("a helper has no \{f}")
      }
    IGrants(g) =>
      match f {
        "status" => opt_j(g.status())
        "refresh" => {
          g.refresh(force=bool_of(arg("force")))
          Null
        }
        "state" => js(g.state(s("grant")))
        "view" => opt_j(g.view())
        "show" => js(g.show(s("grant"), arg("words").unwrap_or(Obj([])), paths=arg("paths"), again=bool_of(arg("again"))))
        "request" => {
          let (window, screen) = g.request(s("grant"), arg("words").unwrap_or(Obj([])), again=bool_of(arg("again")))
          jo([("window", js(window)), ("screen", jb(screen))])
        }
        "onChange" => {
          ignore(g.on_change(self.cb("\{name}.change")))
          Null
        }
        _ => raise fail("grants have no \{f}")
      }
    IFiles(fl) =>
      match f {
        "known" =>
          match fl.known(s("top")) {
            Some((grant, state)) => jo([("grant", js(grant)), ("state", js(state))])
            None => Null
          }
        "check" => {
          fl.check(strs_of(arg("tops")))
          Null
        }
        "ask" => js(fl.ask(s("grant"), s("top")))
        "search" => jstrs(fl.search(s("top"), s("query"), n("most"), strs_of(arg("protect"))))
        "request" => fl.request(arg("op").unwrap_or(Obj([])))
        "fs" => self.keep(a, IHfs(fl.fs(strs_of(arg("roots")), strs_of(arg("protect")))))
        _ => raise fail("files have no \{f}")
      }
    IHfs(h) =>
      match f {
        "list" => {
          let (entries, more) = h.list(s("dir"), n("most"))
          jo([
            (
              "entries",
              ja(entries.map(e => jo([
                ("name", js(e.name)),
                ("link", jb(e.link)),
                ("real", js(e.real)),
                (
                  "stat",
                  match e.stat {
                    Some(st) => stat_j(st)
                    None => Null
                  },
                ),
              ]))),
            ),
            ("more", jb(more)),
          ])
        }
        "names" => jstrs(h.names(s("dir")))
        "stat" => stat_j(h.stat(s("path")))
        "lstat" => stat_j(h.lstat(s("path")))
        "real" => js(h.real(s("path")))
        "read" => {
          let (bytes, size, mtime) = h.read(s("path"), n("offset"), n("length"))
          jo([("bytes", js(b64(bytes))), ("size", jn(size)), ("mtimeMs", jn(mtime))])
        }
        "readAll" => js(b64(h.read_all(s("path"))))
        "copyTo" => {
          h.copy_to(s("path"), s("to"))
          Null
        }
        "write" => {
          let w = arg("w").unwrap_or(Obj([]))
          let (size, short) = h.write(s("path"), {
            create: bool_of(get(Some(w), "create")),
            offset: num(get(Some(w), "offset")).unwrap_or(0.0),
            data: b64_of(get(Some(w), "data")),
            at_least: num(get(Some(w), "atLeast")),
            truncate: num(get(Some(w), "truncate")),
            sync: bool_of(get(Some(w), "sync")),
          })
          jsome([("size", Some(jn(size))), ("short", if short { Some(jb(true)) } else { None })])
        }
        "rename" => {
          h.rename(s("from"), s("to"))
          Null
        }
        "mkdir" => {
          h.mkdir(s("path"), bool_of(arg("recursive")))
          Null
        }
        "remove" => {
          h.remove(s("path"))
          Null
        }
        "trash" => jopt_s(h.trash(s("path")))
        "unlink" => {
          h.unlink(s("path"))
          Null
        }
        _ => raise fail("an fs has no \{f}")
      }
    IDesktop(d) =>
      match f {
        "refresh" => {
          d.refresh(force=bool_of(arg("force")))
          Null
        }
        "helperBack" => {
          d.helper_back()
          Null
        }
        "close" => {
          d.close()
          Null
        }
        _ => self.source_call(d.source(), f, a)
      }
    IWindows(w) =>
      match f {
        "refresh" => {
          w.refresh(force=bool_of(arg("force")))
          Null
        }
        "close" => {
          w.close()
          Null
        }
        _ => self.source_call(w.source(), f, a)
      }
    ISims(sims) =>
      match f {
        "start" => {
          sims.start()
          Null
        }
        "refresh" => {
          sims.refresh()
          Null
        }
        "close" => {
          sims.close()
          Null
        }
        _ => raise fail("simulators have no \{f}")
      }
    IDebug(d) => self.debug_call(d, f, a)
    IChrome(c) =>
      match f {
        "told" => c.told().to_j()
        "source" => c.to_j()
        "pictures" => pictures_of(self.io, c, n("turn").to_int(), how=Some({ cache: s("cache"), draw: (sips(self.io)).draw })).to_j()
        _ => raise fail("a chrome has no \{f}")
      }
    IAndroids(x) =>
      match f {
        "start" => {
          x.start()
          Null
        }
        "refresh" => {
          x.refresh()
          Null
        }
        "close" => {
          x.close()
          Null
        }
        _ => raise fail("androids have no \{f}")
      }
    IX11(x) =>
      match f {
        "refresh" => {
          x.refresh(force=bool_of(arg("force")))
          Null
        }
        "close" => {
          x.close()
          Null
        }
        _ => self.source_call(x.source(), f, a)
      }
    IGst(g) =>
      match f {
        "refresh" => {
          g.refresh(force=bool_of(arg("force")))
          Null
        }
        "close" => {
          g.close()
          Null
        }
        _ => self.source_call(g.source(), f, a)
      }
    ILinux(l) =>
      match f {
        "refresh" => {
          l.refresh(force=bool_of(arg("force")))
          Null
        }
        "close" => {
          l.close()
          Null
        }
        _ => self.source_call(l.source(), f, a)
      }
    ITools(t) =>
      match f {
        "prepared" =>
          match t.prepared(self.env_arg(arg("env"))) {
            Some(p) => jo([("ffmpeg", js(p.ffmpeg)), ("xdotool", js(p.xdotool)), ("env", p.env.to_j())])
            None => Null
          }
        "canPrepare" => jb(t.can_prepare(self.env_arg(arg("env"))))
        "prepare" => {
          t.prepare(self.env_arg(arg("env")))
          Null
        }
        "close" => {
          t.close()
          Null
        }
        _ => raise fail("tools have no \{f}")
      }
    IMac(m) =>
      match f {
        "ops" => ja(m.ops(input_of(arg("event").unwrap_or(Null)).unwrap(), n("now")))
        "release" => ja(m.release())
        _ => raise fail("no \{f}")
      }
    IWinIn(w) =>
      match f {
        "ops" => ja(w.ops(input_of(arg("event").unwrap_or(Null)).unwrap()))
        "release" => ja(w.release())
        _ => raise fail("no \{f}")
      }
    ISimIn(si) =>
      match f {
        "ops" => ja(si.ops(input_of(arg("event").unwrap_or(Null)).unwrap()))
        _ => raise fail("no \{f}")
      }
    IAndIn(ai) =>
      match f {
        "messages" => {
          let size = arg("size")
          jstrs(
            ai.messages(input_of(arg("event").unwrap_or(Null)).unwrap(), (num(get(size, "width")).unwrap_or(0.0), num(get(size, "height")).unwrap_or(0.0))).map(m => b64(m)),
          )
        }
        _ => raise fail("no \{f}")
      }
    IScrcpy(st) =>
      match f {
        "heard" => {
          st.heard(b64_of(arg("data")))
          Null
        }
        _ => raise fail("no \{f}")
      }
    IPeek(p) =>
      match f {
        "take" => jb(p.take())
        "free" => {
          p.free()
          Null
        }
        "running" => ji(p.running())
        _ => raise fail("no \{f}")
      }
    ISock(sock) =>
      match f {
        "write" => {
          sock.write(b64_of(arg("data")))
          Null
        }
        "destroy" => {
          sock.destroy()
          Null
        }
        _ => raise fail("no \{f}")
      }
  }
}

///|
async fn Harness::debug_call(self : Harness, d : SimDebug, f : String, a : J) -> J {
  let arg = (k : String) => get(Some(a), k)
  let s = (k : String) => text(arg(k)).unwrap_or("")
  match f {
    "logs" => {
      let (next, lines) = d.logs(num(arg("after")).unwrap_or(0.0))
      jo([("next", ji(next)), ("lines", ja(lines.map(l => l.to_j())))])
    }
    "apps" => ja(d.apps().map(x => x.to_j()))
    "relaunch" => jb(d.relaunch(s("app")))
    "settings" => d.settings()
    "setSetting" => jb(d.set_setting(s("name"), s("value")))
    "openUrl" => jb(d.open_url(s("url")))
    "location" => jb(d.location(text(arg("at"))))
    "statusBar" => {
      d.status_bar(bool_of(arg("tidy")))
      Null
    }
    "push" => jb(d.push(s("app"), s("text")))
    "installFolder" => js(d.install_folder())
    "install" => jopt_s(d.install(s("path")))
    "uninstall" => jb(d.uninstall(s("app")))
    "biometrics" => jb(d.biometrics(s("what")))
    "recordStart" => {
      d.record_start(text(arg("panel")))
      Null
    }
    "recording" => jb(d.recording())
    "recordStop" =>
      match d.record_stop() {
        Some((root, path)) => jo([("root", js(root)), ("path", js(path))])
        None => Null
      }
    "screenshot" => js(b64(d.screenshot()))
    "close" => {
      d.close()
      Null
    }
    _ => raise fail("a debug has no \{f}")
  }
}
