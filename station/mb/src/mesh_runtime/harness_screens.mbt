// A screen's view in the harness (station/test/mb-mesh-runtime.test.ts plays the same world to the TypeScript's
// `answerScreen`): a hub, a source and its view of the test's, each doing only what the test says, on a clock of the
// view's own. Every call the view makes of them, every byte it writes and every line it says is kept, and given the
// test after each step it says (`screen` `{op}`).

///|
priv struct ScreenWorld {
  rt : @effect.Runtime
  conf : Json
  calls : Array[Json]
  writes : Array[Json]
  logs : Array[Json]
  mut finished : Bool
  mut done : Bool
  mut error : String?
  mut write_fails : Bool
  frames : Array[Json]
  mut next_waiting : @effect.Deferred[Json]?
  audio : Array[Json]
  mut audio_waiting : @effect.Deferred[Json]?
  reads : Array[Bytes?]
  mut read_waiting : @effect.Deferred[Bytes?]?
  stopped : @effect.Deferred[Unit]
  listeners : Map[String, (Json) -> Unit]
  watchers : Array[() -> Unit]
  stoppers : Array[() -> Unit]
  mut joined : Watcher?
  mut title : String
  mut site : String?
  mut address : String?
  mut gone : Bool
  mut paths : Json
  words : Map[String, String]
}

///|
fn cfg(w : ScreenWorld, path : Array[String]) -> Json? {
  let mut v = Some(w.conf)
  for k in path {
    v = v.bind(x => field(x, k))
  }
  v
}

///|
fn has(w : ScreenWorld, path : Array[String]) -> Bool {
  cfg(w, path) is Some(True)
}

///|
fn opt_str(v : String?) -> Json {
  match v {
    Some(s) => jstr(s)
    None => Json::null()
  }
}

///|
fn ScreenWorld::call(self : ScreenWorld, what : Array[Json]) -> Unit {
  self.calls.push(Json::array(what))
}

///|
/// The next of what the test gives a queue, waited for where none is there yet.
async fn take_given(queue : Array[Json], set : (@effect.Deferred[Json]?) -> Unit) -> Json {
  if queue.length() > 0 {
    return queue.remove(0)
  }
  let d : @effect.Deferred[Json] = @effect.Deferred::new()
  set(Some(d))
  d.wait()
}

///|
fn give(queue : Array[Json], waiting : @effect.Deferred[Json]?, set : (@effect.Deferred[Json]?) -> Unit, v : Json) -> Unit {
  match waiting {
    Some(d) => {
      set(None)
      ignore(d.succeed(v))
    }
    None => queue.push(v)
  }
}

///|
fn frame_of(f : Json) -> ScreenFrame {
  let config = match field(f, "config") {
    Some(Object(_) as c) =>
      Some({
        codec: str_of(field(c, "codec")).unwrap_or(""),
        width: num_of(field(c, "width")).unwrap_or(0.0),
        height: num_of(field(c, "height")).unwrap_or(0.0),
        description: match field(c, "description") {
          Some(String(_)) as d => Some(hex_arg(d))
          _ => None
        },
        region: match field(c, "region") {
          Some(Object(_) as r) =>
            Some({
              x: num_of(field(r, "x")).unwrap_or(0.0),
              y: num_of(field(r, "y")).unwrap_or(0.0),
              w: num_of(field(r, "w")).unwrap_or(0.0),
              h: num_of(field(r, "h")).unwrap_or(0.0),
            })
          _ => None
        },
      })
    _ => None
  }
  { config, key: field(f, "key") is Some(True), ts: num_of(field(f, "ts")).unwrap_or(0.0), data: hex_arg(field(f, "data")) }
}

///|
fn refused_of(r : Json) -> Error {
  ScreenRefused(
    num_of(field(r, "status")).unwrap_or(0.0).to_int(),
    str_of(field(r, "key")).unwrap_or(""),
    field(r, "args").unwrap_or(jobj([])),
    match field(r, "access") {
      None | Some(Null) => None
      a => a
    },
  )
}

///|
fn watch_port(w : ScreenWorld, name : String) -> (((Json) -> Unit) -> () -> Unit)? {
  if !has(w, ["view", name]) {
    return None
  }
  Some(f => {
    w.listeners[name] = f
    () => {
      w.call([jstr("un:\{name}")])
      w.listeners.remove(name)
    }
  })
}

///|
fn ScreenWorld::view(self : ScreenWorld) -> ScreenViewPort {
  let w = self
  let v = (name : String) => has(w, ["view", name])
  {
    next: async fn() -> ScreenFrame? {
      w.call([jstr("next")])
      let e = take_given(w.frames, d => w.next_waiting = d)
      match e {
        { "frame": f, .. } => Some(frame_of(f))
        { "refused": r, .. } => raise refused_of(r)
        { "error": String(m), .. } => raise Failure(m)
        _ => None
      }
    },
    next_audio: if v("audio") {
      Some(async fn() -> AudioPacket? {
        let e = take_given(w.audio, d => w.audio_waiting = d)
        match e {
          { "audio": a, .. } =>
            Some({ ts: num_of(field(a, "ts")).unwrap_or(0.0), data: hex_arg(field(a, "data")), codec: str_of(field(a, "codec")).unwrap_or("") })
          { "error": String(m), .. } => raise Failure(m)
          _ => None
        }
      })
    } else {
      None
    },
    keyframe: () => w.call([jstr("keyframe")]),
    input: async fn(e) {
      w.call([jstr("input"), e])
      if has(w, ["view", "inputFails"]) {
        raise Failure("input refused")
      }
    },
    rate: if v("rate") { Some(r => w.call([jstr("rate"), jnum(r)])) } else { None },
    bounds: if v("bounds") {
      Some((mw, mh, region) => w.call(
        match region {
          Some(r) => [jstr("bounds"), jnum(mw), jnum(mh), r.to_json()]
          None => [jstr("bounds"), jnum(mw), jnum(mh)]
        },
      ))
    } else {
      None
    },
    regions: if v("regionsSaid") { Some(() => has(w, ["view", "regions"])) } else { None },
    video: if cfg(w, ["view", "video"]) is Some(x) { Some(() => Some(x)) } else { None },
    why: if v("whySaid") { Some(() => str_of(cfg(w, ["view", "why"]))) } else { None },
    close: () => {
      w.call([jstr("close")])
      // (a pending next resolves null, and its sound)
      if w.next_waiting is Some(d) {
        w.next_waiting = None
        ignore(d.succeed(Json::null()))
      }
      if w.audio_waiting is Some(d) {
        w.audio_waiting = None
        ignore(d.succeed(Json::null()))
      }
    },
    set_clipboard: if v("setClipboard") {
      Some(async fn(clip, paste) { w.call([jstr("setClipboard"), clip_json(clip), Json::boolean(paste)]) })
    } else {
      None
    },
    watch_clipboard: if v("watchClipboard") {
      Some(f => {
        w.listeners["clip"] = c => f(clip_arg(Some(c)))
        () => {
          w.call([jstr("un:watchClipboard")])
          w.listeners.remove("clip")
        }
      })
    } else {
      None
    },
    watch_cursor: watch_port(w, "watchCursor"),
    // (the pictures it has, by shape: hex)
    cursor_image: if cfg(w, ["view", "cursorImages"]) is Some(Object(_)) {
      Some(shape => match cfg(w, ["view", "cursorImages", shape]) {
        Some(String(_)) as h => Some(hex_arg(h))
        _ => None
      })
    } else {
      None
    },
    watch_turn: watch_port(w, "watchTurn"),
    watch_windows: watch_port(w, "watchWindows"),
    window: if v("window") { Some(id => w.call([jstr("window"), opt_json(id)])) } else { None },
    reveal: if v("reveal") { Some(async fn(p) { w.call([jstr("reveal"), jstr(p)]) }) } else { None },
    watch_login: watch_port(w, "watchLogin"),
    fill: if v("fill") { Some(async fn(f) { w.call([jstr("fill"), f]) }) } else { None },
    watch_passkey: watch_port(w, "watchPasskey"),
    passkey: if v("passkey") { Some(async fn(a) { w.call([jstr("passkey"), a]) }) } else { None },
    watch_child: if v("watchChild") {
      Some(f => {
        w.listeners["watchChild"] = s => f(str_of(Some(s)).unwrap_or(""))
        () => {
          w.call([jstr("un:watchChild")])
          w.listeners.remove("watchChild")
        }
      })
    } else {
      None
    },
    // (the TypeScript's fake hears a text's mark in its clip, a picture's not)
    set_clipboard_marked: if v("setClipboard") {
      Some(async fn(clip, paste, mark) {
        let shown = match (clip, clip_json(clip), privacy_name(mark)) {
          (Text(_), Object(m), Some(p)) => {
            m["privacy"] = jstr(p)
            Json::object(m)
          }
          (_, j, _) => j
        }
        w.call([jstr("setClipboard"), shown, Json::boolean(paste)])
      })
    } else {
      None
    },
    watch_clipboard_marked: if v("watchClipboard") {
      Some(f => {
        w.listeners["clip"] = c => {
          let mark = match field(c, "privacy") {
            Some(String("concealed")) => 1
            Some(String("transient")) => 2
            Some(String("auto")) => 3
            _ => 0
          }
          f(clip_arg(Some(c)), mark)
        }
        () => {
          w.call([jstr("un:watchClipboard")])
          w.listeners.remove("clip")
        }
      })
    } else {
      None
    },
    watch_pointer_lock: watch_port(w, "watchPointerLock").map(watch => (k : (Bool) -> Unit) => watch(j => k(j is True))),
    watch_mic: watch_port(w, "watchMic"),
    feed_mic: if v("feedMic") {
      Some((pcm, epoch) => w.call([jstr("feedMic"), jstr(@hex.encode(pcm[:])), jnum(epoch.to_double())]))
    } else {
      None
    },
  }
}

///|
fn ScreenWorld::source(self : ScreenWorld) -> ScreenSourcePort {
  let w = self
  let s = (name : String) => has(w, ["source", name])
  {
    kind: str_of(cfg(w, ["source", "kind"])).unwrap_or("browser"),
    title: () => w.title,
    open: async fn(options) {
      w.call([jstr("open"), options])
      match cfg(w, ["view", "refuse"]) {
        Some(Object(_) as r) => raise refused_of(r)
        _ => ()
      }
      if str_of(cfg(w, ["view", "fail"])) is Some(m) {
        raise Failure(m)
      }
      if s("goneWhileOpening") {
        w.gone = true
      }
      w.view()
    },
    access: match cfg(w, ["source", "access"]) {
      Some(a) => Some(() => Some(a))
      None => None
    },
    clipboard: match cfg(w, ["source", "clipboard"]) {
      Some(Array(_) as types) => Some(() => strs(Some(types)))
      _ => None
    },
    reveal: s("reveal"),
    peek: s("peek"),
    open_url: s("openUrl"),
    user_tab: s("userTab"),
    sleeping: if cfg(w, ["source", "sleeping"]) is Some(_) { Some(() => s("sleeping")) } else { None },
    site: if s("hasSite") { Some(() => w.site) } else { None },
    address: if s("hasAddress") { Some(() => w.address) } else { None },
    scale: match cfg(w, ["source", "scale"]) {
      Some(v) => Some(async fn() -> Json? { Some(v) })
      None => None
    },
    set_scale: if s("setScale") {
      Some(async fn(p) {
        w.call([jstr("setScale"), jnum(p)])
        if s("setFails") {
          raise Failure("not that one")
        }
        jobj([("percent", jnum(p))])
      })
    } else {
      None
    },
    resolution: match cfg(w, ["source", "resolution"]) {
      Some(v) => Some(async fn() -> Json? { Some(v) })
      None => None
    },
    set_resolution: if s("setResolution") {
      Some(async fn(width, height) {
        w.call([jstr("setResolution"), jnum(width), jnum(height)])
        if s("setFails") {
          raise Failure("not that one")
        }
        jobj([("width", jnum(width)), ("height", jnum(height))])
      })
    } else {
      None
    },
  }
}

///|
/// The words a test gave (its `tr`'s templates, by `lang\0key`), `{name}` filled as i18n.ts `fill` does.
fn ScreenWorld::tr(self : ScreenWorld, lang : String, key : String, args : Json) -> String {
  words_tr(self.words, lang, key, args)
}

///|
fn words_tr(words : Map[String, String], lang : String, key : String, args : Json) -> String {
  let text = match words.get("\{lang}\u{0}\{key}") {
    Some(t) => t
    None => key
  }
  guard args is Object(m) && m.length() > 0 && text.contains("{") else { return text }
  let out = StringBuilder()
  let n = text.length()
  let mut i = 0
  while i < n {
    let c = text.code_unit_at(i).to_int()
    if c == 0x7b {
      let mut j = i + 1
      while j < n {
        let d = text.code_unit_at(j).to_int()
        if !((d >= 0x41 && d <= 0x5a) || (d >= 0x61 && d <= 0x7a) || is_digit(d) || d == 0x5f) {
          break
        }
        j += 1
      }
      if j < n && text.code_unit_at(j).to_int() == 0x7d {
        let name = text.clamped_view(start=i + 1, end=j).to_owned()
        match m.get(name) {
          Some(v) => {
            out.write_string(
              match v {
                String(s) => s
                Number(x, ..) => js_num(x)
                True => "true"
                False => "false"
                Null => "null"
                other => js_string_of(other)
              },
            )
            i = j + 1
            continue
          }
          None => ()
        }
      }
    }
    out.write_char(c.unsafe_to_char())
    i += 1
  }
  out.to_string()
}

///|
fn ScreenWorld::hub(self : ScreenWorld, source : ScreenSourcePort) -> ScreenHubPort {
  let w = self
  let id = str_of(cfg(w, ["source", "id"])).unwrap_or("")
  {
    get: asked => if asked == id && !w.gone { Some(source) } else { None },
    drive: (asked, device, taken, by) => {
      w.call([jstr("drive"), jstr(asked), jstr(device), Json::boolean(taken), jstr(by)])
      (has(w, ["drive", "control"]), strs(cfg(w, ["drive", "took"])))
    },
    join: (asked, watcher) => {
      w.call([
        jstr("join"),
        jstr(asked),
        jobj([
          ("name", jstr(watcher.name)),
          ("device", jstr(watcher.device)),
          ("self", opt_str(watcher.self_)),
          ("client", opt_str(watcher.client)),
          ("app", opt_str(watcher.app)),
          ("control", Json::boolean(watcher.control)),
        ]),
      ])
      w.joined = Some(watcher)
      () => w.call([jstr("leave")])
    },
    watch: f => {
      w.watchers.push(f)
      () => {
        w.call([jstr("unwatch")])
        w.watchers.clear()
      }
    },
    when_stopping: f => {
      w.stoppers.push(f)
      () => {
        w.call([jstr("unstop")])
        w.stoppers.clear()
      }
    },
  }
}

///|
fn ScreenWorld::stream(self : ScreenWorld) -> @door.Stream {
  let w = self
  {
    read: async fn() -> Bytes? {
      if w.reads.length() > 0 {
        return w.reads.remove(0)
      }
      let d : @effect.Deferred[Bytes?] = @effect.Deferred::new()
      w.read_waiting = Some(d)
      d.wait()
    },
    write: async fn(b) {
      if w.write_fails {
        raise Failure("the stream is gone")
      }
      w.writes.push(hexj(b))
    },
    finish: async fn() { w.finished = true },
    stopped: async fn() -> Int? {
      w.stopped.wait()
      None
    },
    reset: async fn(_) {  },
  }
}

///|
fn ScreenWorld::client_gives(self : ScreenWorld, bytes : Bytes?) -> Unit {
  match self.read_waiting {
    Some(d) => {
      self.read_waiting = None
      ignore(d.succeed(bytes))
    }
    None => self.reads.push(bytes)
  }
}

///|
/// What the world came to since asked last, and what the test is told of it.
fn ScreenWorld::told(self : ScreenWorld) -> Json {
  let out = jobj([
    ("calls", Json::array(self.calls.copy())),
    ("writes", Json::array(self.writes.copy())),
    ("logs", Json::array(self.logs.copy())),
    ("finished", Json::boolean(self.finished)),
    ("done", Json::boolean(self.done)),
    ("error", opt_str(self.error)),
  ])
  self.calls.clear()
  self.writes.clear()
  self.logs.clear()
  out
}

///|
/// A view opened on a world the test says (`open`), its own runtime.
fn screen_open(conf : Json, words : Map[String, String]) -> ScreenWorld {
  let rt = @effect.Runtime::new()
  let w : ScreenWorld = {
    rt,
    conf,
    calls: [],
    writes: [],
    logs: [],
    finished: false,
    done: false,
    error: None,
    write_fails: false,
    frames: [],
    next_waiting: None,
    audio: [],
    audio_waiting: None,
    reads: [],
    read_waiting: None,
    stopped: @effect.Deferred::new(),
    listeners: Map([]),
    watchers: [],
    stoppers: [],
    joined: None,
    title: str_of(cfg_of(conf, ["source", "title"])).unwrap_or(""),
    site: str_of(cfg_of(conf, ["source", "site"])),
    address: str_of(cfg_of(conf, ["source", "address"])),
    gone: false,
    paths: cfg_of(conf, ["paths"]).unwrap_or(Json::null()),
    words,
  }
  let source = w.source()
  let hub = w.hub(source)
  let stream = w.stream()
  ignore(
    rt.fork(name="answer screen", () => {
      answer_screen(
        hub,
        stream,
        hex_arg(cfg(w, ["carry"])),
        cfg(w, ["head"]).unwrap_or(Json::null()),
        cfg(w, ["viewer"]).unwrap_or(Json::null()),
        () => !(cfg(w, ["up"]) is Some(False)),
        rt,
        (lang, key, args) => w.tr(lang, key, args),
        (level, part, words, with_) => w.logs.push(
          jobj([("level", jstr(level)), ("at", jstr(part)), ("words", jstr(words)), ("with", with_)]),
        ),
        paths=if cfg(w, ["paths"]) is Some(Array(_)) {
          Some(() => {
            w.call([jstr("paths")])
            arr(Some(w.paths)).map(LinkPath::of_json)
          })
        } else {
          None
        },
        media_datagrams=match cfg(w, ["mediaDatagrams"]) {
          Some(True) =>
            Some(async fn(token) {
              w.call([jstr("mediaDatagrams"), jnum(token)])
              true
            })
          Some(False) =>
            Some(async fn(token) {
              w.call([jstr("mediaDatagrams"), jnum(token)])
              false
            })
          _ => None
        },
      ) catch {
        e => w.error = Some(message_of(e))
      }
      w.done = true
    }),
  )
  ignore(rt.run_ready())
  w
}

///|
fn cfg_of(conf : Json, path : Array[String]) -> Json? {
  let mut v = Some(conf)
  for k in path {
    v = v.bind(x => field(x, k))
  }
  v
}

///|
/// One step the test says of a world (`{op, …}`).
fn ScreenWorld::step(self : ScreenWorld, a : Json) -> Unit {
  let w = self
  let call_listener = (name : String, v : Json) => if w.listeners.get(name) is Some(f) { f(v) }
  match str_of(field(a, "op")).unwrap_or("") {
    "client" => w.client_gives(Some(hex_arg(field(a, "bytes"))))
    "clientEnd" => w.client_gives(None)
    "frame" => give(w.frames, w.next_waiting, d => w.next_waiting = d, jobj([("frame", field(a, "frame").unwrap_or(Json::null()))]))
    "frameNull" => give(w.frames, w.next_waiting, d => w.next_waiting = d, Json::null())
    "frameRefused" => give(w.frames, w.next_waiting, d => w.next_waiting = d, jobj([("refused", field(a, "refused").unwrap_or(Json::null()))]))
    "frameError" => give(w.frames, w.next_waiting, d => w.next_waiting = d, jobj([("error", field(a, "error").unwrap_or(Json::null()))]))
    "audio" => give(w.audio, w.audio_waiting, d => w.audio_waiting = d, jobj([("audio", field(a, "audio").unwrap_or(Json::null()))]))
    "audioNull" => give(w.audio, w.audio_waiting, d => w.audio_waiting = d, Json::null())
    "clip" => call_listener("clip", field(a, "clip").unwrap_or(Json::null()))
    "listener" => call_listener(str_of(field(a, "name")).unwrap_or(""), field(a, "value").unwrap_or(Json::null()))
    "change" => {
      if field(a, "title") is Some(String(t)) {
        w.title = t
      }
      match field(a, "site") {
        Some(String(s)) => w.site = Some(s)
        Some(Null) => w.site = None
        _ => ()
      }
      match field(a, "address") {
        Some(String(s)) => w.address = Some(s)
        Some(Null) => w.address = None
        _ => ()
      }
      if field(a, "gone") is Some(True) {
        w.gone = true
      }
      for f in w.watchers.copy() {
        f()
      }
    }
    "stopping" =>
      for f in w.stoppers.copy() {
        f()
      }
    "watchOnly" => if w.joined is Some(j) { (j.watch_only)(str_of(field(a, "by"))) }
    "end" => if w.joined is Some(j) { (j.end)(str_of(field(a, "by")).unwrap_or("")) }
    "tell" => if w.joined is Some(j) { (j.tell)(field(a, "people").unwrap_or(Json::null())) }
    "stopped" => ignore(w.stopped.succeed(()))
    "writeFails" => w.write_fails = true
    "paths" => w.paths = field(a, "paths").unwrap_or(Json::array([]))
    "advance" => w.rt.advance(num_of(field(a, "ms")).unwrap_or(0.0).to_int())
    _ => ()
  }
  ignore(w.rt.run_ready())
}
