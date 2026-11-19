// The harness's plain functions (`pure`): what the TypeScript exports of these parts that needs no world, asked by its
// name with its arguments as JSON (bytes as base64, a picture `{width, height, data}`).

///|
fn pixels_j(p : Pixels) -> J {
  jo([("width", ji(p.width)), ("height", ji(p.height)), ("data", js(b64(Bytes::from_array(p.data))))])
}

///|
fn pixels_from(j : J?) -> Pixels {
  let data = b64_of(get(j, "data"))
  {
    width: num(get(j, "width")).unwrap_or(0.0).to_int(),
    height: num(get(j, "height")).unwrap_or(0.0).to_int(),
    data: FixedArray::makei(data.length(), i => data[i]),
  }
}

///|
fn access_of(j : J?) -> ScreenAccess? {
  match j {
    Some(Obj(_) as a) =>
      Some(
        ScreenAccess::new(
          bool_of(get(Some(a), "capture")),
          bool_of(get(Some(a), "control")),
          unsupported=text(get(Some(a), "unsupported")),
          reason=text(get(Some(a), "reason")),
          app=text(get(Some(a), "app")),
          path=text(get(Some(a), "path")),
          asking=bool_of(get(Some(a), "asking")),
        ),
      )
    _ => None
  }
}

///|
fn Harness::pure(self : Harness, f : String, a : J) -> J raise {
  let arg = (k : String) => get(Some(a), k)
  let s = (k : String) => text(arg(k)).unwrap_or("")
  let n = (k : String) => num(arg(k)).unwrap_or(0.0)
  let io = self.io
  match f {
    "codecFor" => {
      let own = strs_of(arg("own")).filter_map(codec_of)
      match codec_for(view_options_of(arg("options").unwrap_or(Obj([]))), own) {
        Some(c) => js(c.name())
        None => Null
      }
    }
    "regionOf" =>
      match region_of(arg("v")) {
        Some(r) => r.to_j()
        None => Null
      }
    "clipFits" => jb(clip_fits(clip_of(arg("clip").unwrap_or(Null)).unwrap()))
    "windowsOf" => ja(windows_of(arg("v")).map(w => jo([("id", jn(w.id)), ("app", js(w.app)), ("title", js(w.title))])))
    "userTab" => jb(is_user_tab_id(s("s")))
    "viewOn" => {
      let v = arg("v")
      js(
        view_on(
          {
            id: text(get(v, "id")).unwrap_or(""),
            name: text(get(v, "name")).unwrap_or(""),
            control: bool_of(get(v, "control")),
            at: num(get(v, "at")).unwrap_or(0.0),
            device: text(get(v, "device")),
            self_: text(get(v, "self")),
            client: text(get(v, "client")),
            app: text(get(v, "app")),
            agent: bool_of(get(v, "agent")),
          },
          self.rpc.now,
        ),
      )
    }
    "accessShown" =>
      match access_shown(io.words, access_of(arg("access")), s("lang")) {
        Some(x) => x.to_j()
        None => Null
      }
    "addressShown" => jopt_s(address_shown(text(arg("address"))))
    "envelope" => envelope(s("out"), js_number_of(arg("status")))
    "treeText" => js(tree_text(arg("tree").unwrap_or(Obj([]))))
    "windowWords" => window_words(io, s("lang"))
    "filesWords" => files_words(io, s("lang"))
    "askWords" => ask_words(io, s("lang"))
    "helperClip" => js(b64(helper_clip(clip_of(arg("clip").unwrap_or(Null)).unwrap(), flags=num(arg("flags")).map(d => d.to_int()))))
    "helperMessage" => js(b64(helper_message(n("kind").to_int(), payload=b64_of(arg("payload")))))
    "localNetworkName" => js(local_network_name(s("execPath")))
    "grantState" => js(grant_state(arg("s").unwrap_or(Obj([])), s("grant")))
    "isGrant" => jb(is_grant(s("v")))
    "flagsOf" => ji(flags_of(n("mods").to_int()))
    "bitrateOf" => ji(bitrate_of(n("side").to_int()))
    "metaOf" => ji(meta_of(n("mods").to_int()))
    "nalsOf" => jstrs(nals_of(b64_of(arg("data"))).map(x => b64(x)))
    "avcCOf" =>
      match avcc_config_of(strs_of(arg("nals")).map(x => @base64.decode_lossy(x)[:])) {
        Some(b) => js(b64(b))
        None => Null
      }
    "avccOf" => js(b64(avcc_of(strs_of(arg("nals")).map(x => @base64.decode_lossy(x)[:]))))
    "sideOf" => ji(side_of(view_options_of(arg("options").unwrap_or(Obj([])))))
    "viewArgs" => {
      let v = view_args(view_options_of(arg("options").unwrap_or(Obj([]))))
      jsome([
        ("maxSide", Some(ji(v.max_side))),
        ("bitrate", Some(ji(v.bitrate))),
        ("fps", v.fps.map(jn)),
        ("wake", Some(jb(v.wake))),
      ])
    }
    "startOf" => opt_num(start_of(io, s("lines"), s("port")))
    "shownDevice" => jb(shown_device(s("serial")))
    "devicesOf" => jstrs(devices_of(s("lines")))
    "panelsOf" => ja(panels_of(s("dumpsys")).map(p => p.to_j()))
    "sizeOf" => sz(size_of(s("wm")))
    "panelOf" =>
      match panel_of(b64_of(arg("pdf"))) {
        Some(p) => p.to_j()
        None => Null
      }
    "displaysOf" =>
      ja(
        displays_of(arg("capabilities").unwrap_or(Null), arg("profile").unwrap_or(Null)).map(d => jo([
          ("chrome", js(d.chrome)),
          ("mask", jopt_s(d.mask)),
          ("width", jn(d.width)),
          ("height", jn(d.height)),
          ("scale", jn(d.scale)),
        ])),
      )
    "pageSize" =>
      match page_size(b64_of(arg("pdf"))) {
        Some(p) => sz(p)
        None => Null
      }
    "turned" => pixels_j(turned(pixels_from(arg("p")), n("turn").to_int()))
    "decode" => pixels_j(decode_png(b64_of(arg("png"))))
    "encodeDecoded" => pixels_j(decode_png(encode_png(pixels_from(arg("p")))))
    "bootedOf" => ja(booted_of(io, arg("listed").unwrap_or(Null)).map(b => b.to_j()))
    "runtimeName" => js(runtime_name(s("id")))
    "screenOf" => sz(screen_of(arg("capabilities").unwrap_or(Null)))
    "turnOf" => ji(turn_of(s("said"), s("panel")))
    "logOf" =>
      match log_of(s("line")) {
        Some((at, level, app, t)) => jo([("at", js(at)), ("level", js(level)), ("app", js(app)), ("text", js(t))])
        None => Null
      }
    "appsOf" => ja(apps_of(arg("installed").unwrap_or(Null), s("launchctl")).map(x => x.to_j()))
    "scaleOf" =>
      match scale_of(arg("told")) {
        Some(x) => x.to_j()
        None => Null
      }
    "resolutionOf" =>
      match resolution_of(arg("told")) {
        Some(x) => x.to_j()
        None => Null
      }
    "graphicalSession" =>
      match graphical_session(s("id"), n("uid").to_int(), s("text")) {
        Some(x) => x.to_j()
        None => Null
      }
    "keyTables" =>
      jo([
        ("mac", jo(mac_keycodes.iter().map(p => (p.0, ji(p.1))).collect())),
        ("win", jo(win_keys.iter().map(p => (p.0, jo([("scan", ji(p.1.scan)), ("ext", jb(p.1.ext)), ("vk", ji(p.1.vk))]))).collect())),
        ("sim", jo(sim_usages.iter().map(p => (p.0, ji(p.1))).collect())),
        ("android", jo(android_keycodes.iter().map(p => (p.0, ji(p.1))).collect())),
        ("evdev", jo(evdev.iter().map(p => (p.0, ji(p.1))).collect())),
      ])
    "localeCompare" => ji(locale_compare(s("a"), s("b")))
    _ => raise fail("no plain function \{f}")
  }
}

///|
/// What needs the world but is no part: a movie turned, a session's environment, agent-desktop started.
async fn Harness::worldly(self : Harness, f : String, a : J) -> J {
  let arg = (k : String) => get(Some(a), k)
  let s = (k : String) => text(arg(k)).unwrap_or("")
  match f {
    "turnMovie" => jb(turn_movie(self.io, s("file"), num(arg("turn")).unwrap_or(0.0).to_int()))
    "desktopEnvironment" => desktop_environment(self.io, self.env_arg(arg("base"))).to_j()
    "processUi" => process_ui(self.io, s("binary"))(strs_of(arg("args")))
    "install" => {
      let (path, replaced) = install(self.io, s("app"), s("dir"))
      jo([("path", js(path)), ("replaced", jb(replaced))])
    }
    "chromeOf" => {
      let d = arg("display")
      let display = {
        chrome: text(get(d, "chrome")).unwrap_or(""),
        mask: text(get(d, "mask")),
        width: num(get(d, "width")).unwrap_or(0.0),
        height: num(get(d, "height")).unwrap_or(0.0),
        scale: num(get(d, "scale")).unwrap_or(1.0),
      }
      match chrome_of(self.io, display, s("bundle"), text(arg("sensor")), root=s("root"), how=Some({ cache: s("cache"), draw: (sips(self.io)).draw })) {
        Some(c) => {
          ignore(self.keep(a, IChrome(c)))
          c.to_j()
        }
        None => Null
      }
    }
    "executable" => jopt_s(executable(self.io, s("name"), self.env_arg(arg("env"))))
    "emulatorStart" => opt_num(emulator_start(self.io, s("serial")))
    "hostFs" => self.host_fs(arr(arg("ops")).unwrap_or([]))
    "helperApp" => jopt_s(helper_app(self.io, self.env_arg(arg("env"))))
    "uiBinary" => jopt_s(ui_binary(self.io, self.env_arg(arg("env"))))
    "screenBinary" => jopt_s(screen_binary(self.io, self.env_arg(arg("env"))))
    _ => raise fail("no worldly \{f}")
  }
}

///|
/// The machine's own files through the shell's (`host_io`), each op's answer or its failure's code.
async fn Harness::host_fs(self : Harness, ops : Array[J]) -> J {
  let io = host_io(self.rpc.host, self.io.procs, self.io.os, self.io.words)
  let out = []
  for op in ops {
    let s = (k : String) => text(get(Some(op), k)).unwrap_or("")
    let n = (k : String) => num(get(Some(op), k)).unwrap_or(0.0)
    let b = (k : String) => get(Some(op), k) is Some(Bool(true))
    let r = try {
      match s("op") {
        "read" => js(b64((io.fs.read)(s("path"))))
        "write" => {
          (io.fs.write)(s("path"), b64_of(get(Some(op), "data")), num(get(Some(op), "mode")).map(d => d.to_int()))
          Null
        }
        "access" => jb((io.fs.access)(s("path"), n("mode").to_int()))
        "readdir" => ja((io.fs.readdir)(s("path")).map(e => jo([("name", js(e.name)), ("dir", jb(e.dir))])))
        "mkdir" => {
          (io.fs.mkdir)(s("path"), b("recursive"), None)
          Null
        }
        "mkdtemp" => {
          let made = (io.fs.mkdtemp)(s("prefix"))
          jb(made.has_prefix(s("prefix")) && made.length() == s("prefix").length() + 6)
        }
        "rename" => {
          (io.fs.rename)(s("from"), s("to"))
          Null
        }
        "rm" => {
          (io.fs.rm)(s("path"), b("recursive"), b("force"))
          Null
        }
        "unlink" => {
          (io.fs.unlink)(s("path"))
          Null
        }
        "stat" => stat_j((io.fs.stat)(s("path")))
        "lstat" => stat_j((io.fs.lstat)(s("path")))
        "copyTree" => {
          (io.fs.copy_tree)(s("from"), s("to"))
          Null
        }
        "readAt" => js(b64((io.fs.read_at)(s("path"), n("offset"), n("length").to_int())))
        "writeAt" => {
          (io.fs.write_at)(s("path"), n("offset"), b64_of(get(Some(op), "data")))
          Null
        }
        "create" => {
          (io.fs.create)(s("path"))
          Null
        }
        "append" => {
          (io.fs.append)(s("path"), b64_of(get(Some(op), "data")))
          Null
        }
        "exists" => jb((io.fs.exists_sync)(s("path")))
        "readSync" => jopt_s((io.fs.read_sync)(s("path")))
        o => raise fail("no op \{o}")
      }
    } catch {
      e => jo([("err", js(text(field_of(e, "code")).unwrap_or("?")))])
    }
    out.push(r)
  }
  ja(out)
}

///|
pub async fn harness(host : @host.Host) -> Unit {
  let rpc : Rpc = {
    host,
    next: 0,
    waiting: {},
    timers: {},
    children: {},
    child_state: {},
    written: {},
    conns: {},
    conn_gone: {},
    watches: {},
    now: 0.0,
    us: 0.0,
    files: {},
    random: 0,
    catalog: None,
    os: Obj([]),
  }
  let h = { rpc, io: rpc.io(), insts: {} }
  while true {
    guard host.line() is Some(line) else { break }
    let c = parse(line) catch {
      _ => {
        rpc.send(jo([("error", js("not JSON"))]))
        continue
      }
    }
    match num(get(Some(c), "now")) {
      Some(t) => rpc.now = t
      None => ()
    }
    match num(get(Some(c), "us")) {
      Some(t) => rpc.us = t
      None => ()
    }
    match get(Some(c), "files") {
      Some(Obj(ps)) => {
        let m : Map[String, J] = Map::new()
        for p in ps {
          m[@jsjson.sanitize_str(p.0)] = p.1
        }
        rpc.files = m
      }
      _ => ()
    }
    match num(get(Some(c), "re")) {
      Some(id) => {
        match rpc.waiting.get(id.to_int()) {
          Some(d) => {
            rpc.waiting.remove(id.to_int())
            match get(Some(c), "err") {
              Some(e) => ignore(d.fail(world_error(e)))
              None => ignore(d.succeed(get(Some(c), "ok").unwrap_or(Null)))
            }
          }
          None => ()
        }
        continue
      }
      None => ()
    }
    if get(Some(c), "ev") is Some(_) {
      rpc.event(c)
      continue
    }
    let id = num(get(Some(c), "id")).unwrap_or(0.0).to_int()
    let cmd = text(get(Some(c), "cmd")).unwrap_or("")
    if cmd == "world" {
      rpc.os = get(Some(c), "os").unwrap_or(Obj([]))
      rpc.catalog = Some(@ops_platform.Catalog::from_json(core_json(get(Some(c), "zh").unwrap_or(Null)), core_json(get(Some(c), "en").unwrap_or(Null))))
      rpc.random = 0
      h.insts.clear()
      h.io = rpc.io()
      rpc.send(jo([("done", ji(id)), ("ok", Null)]))
      continue
    }
    ignore(
      host.rt.fork(async fn() {
        let answer = try {
          let ok = match cmd {
            "sync" => {
              while true {
                @effect.pause()
                if host.rt.idle() {
                  break
                }
              }
              J::Null
            }
            "pure" => h.pure(text(get(Some(c), "fn")).unwrap_or(""), get(Some(c), "args").unwrap_or(Obj([])))
            "worldly" => h.worldly(text(get(Some(c), "fn")).unwrap_or(""), get(Some(c), "args").unwrap_or(Obj([])))
            "new" => {
              let args = get(Some(c), "args").unwrap_or(Obj([]))
              let inst = h.make(text(get(Some(c), "kind")).unwrap_or(""), args)
              h.insts[text(get(Some(args), "inst")).unwrap_or("")] = inst
              Null
            }
            "call" =>
              h.call(
                text(get(Some(c), "inst")).unwrap_or(""),
                text(get(Some(c), "fn")).unwrap_or(""),
                get(Some(c), "args").unwrap_or(Obj([])),
              )
            _ => raise fail("no command \{cmd}")
          }
          jo([("done", ji(id)), ("ok", ok)])
        } catch {
          e => jo([("done", ji(id)), ("err", error_j(e))])
        }
        rpc.send(answer)
      }),
    )
  }
}
