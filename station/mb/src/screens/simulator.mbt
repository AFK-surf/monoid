// The iOS Simulators booted on this Mac as screen sources (`simulator:<udid>`; src/screens/simulator.ts): people see
// and drive one from their app as they do the desktop, agents with the `computer` tool. still.fail Helper's
// `simulator.view` reads the device's framebuffer and posts touches, keys and buttons to it; nothing of macOS's is
// granted for it, and Simulator.app need not run.
//
// Which are booted is CoreSimulator's own simctl's (`simctl list`), looked at again when CoreSimulator rewrites a
// device's device.plist or the list of devices changes, and as the screens are asked for.

///|
/// A booted device as simctl lists it: `booted_at` its `lastUsedAt` (ms), which CoreSimulator sets as it boots.
pub(all) struct Booted {
  udid : String
  name : String
  runtime : String
  type_ : String
  booted_at : Double?
}

///|
pub fn Booted::to_j(self : Booted) -> J {
  jsome([
    ("udid", Some(js(self.udid))),
    ("name", Some(js(self.name))),
    ("runtime", Some(js(self.runtime))),
    ("type", Some(js(self.type_))),
    ("bootedAt", self.booted_at.map(jn)),
  ])
}

///|
/// `/^[0-9A-F-]{36}$/i`.
fn is_udid(s : String) -> Bool {
  if s.length() != 36 {
    return false
  }
  for c in s {
    if !((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f') || c == '-') {
      return false
    }
  }
  true
}

///|
/// The booted devices of `simctl list -j devices`: each with its runtime's name.
pub fn booted_of(io : Io, listed : J) -> Array[Booted] {
  guard get(Some(listed), "devices") is Some(Obj(ps)) else { return [] }
  let out = []
  for p in ps {
    let runtime = @jsjson.sanitize_str(p.0)
    guard p.1 is Arr(list) else { continue }
    for d in list {
      if text(get(Some(d), "state")) != Some("Booted") {
        continue
      }
      guard text(get(Some(d), "udid")) is Some(udid) && is_udid(udid) else { continue }
      let at = match text(get(Some(d), "lastUsedAt")) {
        Some(s) => (io.os.date_parse)(s)
        None => @double.not_a_number
      }
      out.push({
        udid,
        name: text(get(Some(d), "name")).unwrap_or(udid),
        runtime: runtime_name(runtime),
        type_: text(get(Some(d), "deviceTypeIdentifier")).unwrap_or(""),
        booted_at: if at.is_finite() { Some(at) } else { None },
      })
    }
  }
  out
}

///|
/// "com.apple.CoreSimulator.SimRuntime.iOS-26-2" → "iOS 26.2".
pub fn runtime_name(id : String) -> String {
  // (one made for one device has that after it: iOS-27-2-iPhone19-4)
  let mut from = 0
  while true {
    let i = match id.unsafe_substring(start=from, end=id.length()).find("SimRuntime.") {
      Some(i) => from + i
      None => return id
    }
    from = i + 1
    let cs = id.to_array()
    let mut at = i + 11
    let os_start = at
    while at < cs.length() && ((cs[at] >= 'A' && cs[at] <= 'Z') || (cs[at] >= 'a' && cs[at] <= 'z')) {
      at += 1
    }
    if at == os_start || at >= cs.length() || cs[at] != '-' {
      continue
    }
    let os = String::from_array(cs[os_start:at])
    at += 1
    let v_start = at
    let digit = (k : Int) => k < cs.length() && cs[k] >= '0' && cs[k] <= '9'
    if !digit(at) {
      continue
    }
    while digit(at) {
      at += 1
    }
    while at < cs.length() && cs[at] == '-' && digit(at + 1) {
      at += 1
      while digit(at) {
        at += 1
      }
    }
    let version = String::from_array(cs[v_start:at])
    let rest_ok = at == cs.length() ||
      (cs[at] == '-' && at + 1 < cs.length() && ((cs[at + 1] >= 'A' && cs[at + 1] <= 'Z') || (cs[at + 1] >= 'a' && cs[at + 1] <= 'z')))
    if !rest_ok {
      continue
    }
    let name = if os == "xrOS" { "visionOS" } else { os }
    return "\{name} \{version.replace_all(old="-", new=".")}"
  }
  id
}

///|
/// A device type's main screen in pixels, as its capabilities.plist says it (0×0 when it does not).
pub fn screen_of(capabilities : J) -> (Double, Double) {
  let d = get(get(Some(capabilities), "capabilities"), "ScreenDimensionsCapability")
  match (get(d, "main-screen-width"), get(d, "main-screen-height")) {
    (Some(Num(w)), Some(Num(h))) if w > 0.0 && h > 0.0 => (w, h)
    _ => (0.0, 0.0)
  }
}

///|
/// CoreSimulator's simctl, not Xcode's (`xcrun simctl`), which may ask for an administrator's password first.
pub const SIMCTL : String = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"

///|
/// A command run as simulator.ts runs one: a minute at most, its failure said with what it said.
pub fn sim_run(io : Io) -> Run {
  {
    run: async fn(file, args) {
      (io.procs.exec)(file, args, ExecOptions::new(timeout=Some(60000.0), max_buffer=Some((16 << 20).to_double()))) catch {
        ExecFailed(signal~, code~, stderr~, ..) => {
          let why = match signal {
            Some(s) => s
            None =>
              match code {
                Null => ""
                c => js_string(c)
              }
          }
          raise fail(slice_units("\{file} \{args.join(" ")}: \{why} \{trim_js(stderr)}", 0, 500))
        }
        e => raise e
      }
    },
  }
}

///|
/// A device type as its bundle says it: its screen, panels and case.
struct Typed {
  mut size : (Double, Double)
  mut panels : Array[Panel]
  mut chrome : Array[ChromeSource]
}

///|
/// The booted simulators, each a source in `add`'s screens while it is booted (simulator.ts `Simulators`).
pub struct Simulators {
  priv io : Io
  priv add : (ScreenSource) -> (() -> Unit)
  priv helper : HelperApp?
  priv run : Run
  priv devices : String
  priv listed : Map[String, (Simulator, () -> Unit)]
  priv types : Map[String, Typed]
  priv watchers : Map[String, () -> Unit]
  priv mut looking : @effect.Deferred[Unit]?
  priv mut again : Bool
  priv mut soon : (() -> Unit)?
  priv mut closed : Bool
  priv mut said : Bool
}

///|
pub fn Simulators::new(
  io : Io,
  add : (ScreenSource) -> (() -> Unit),
  helper : HelperApp?,
  devices? : String? = None,
  run? : Run? = None,
) -> Simulators {
  {
    io,
    add,
    helper,
    run: run.unwrap_or(sim_run(io)),
    devices: devices.unwrap_or(pj([(io.os.homedir)(), "Library/Developer/CoreSimulator/Devices"])),
    listed: {},
    types: {},
    watchers: {},
    looking: None,
    again: false,
    soon: None,
    closed: false,
    said: false,
  }
}

///|
/// Follows the devices' changes (none where there are no simulators), and looks once.
pub async fn Simulators::start(self : Simulators) -> Unit {
  if self.helper is None {
    return
  }
  self.follow()
  self.refresh()
}

///|
/// The booted devices looked at again (one look at a time; one asked meanwhile is made after it).
pub async fn Simulators::refresh(self : Simulators) -> Unit {
  if self.helper is None || self.closed {
    return
  }
  match self.looking {
    Some(d) => {
      self.again = true
      d.wait()
      return
    }
    None => ()
  }
  let d : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.looking = Some(d)
  (self.io.spawn)(async fn() {
    let r = try Ok(self.look()) catch { e => Err(e) }
    self.looking = None
    if self.again {
      self.again = false
      self.io.go(async fn() { self.refresh() })
    }
    match r {
      Ok(_) => ignore(d.succeed(()))
      Err(e) => ignore(d.fail(e))
    }
  })
  d.wait()
}

///|
async fn Simulators::look(self : Simulators) -> Unit {
  let booted = try {
    booted_of(self.io, parse((self.run.run)(SIMCTL, ["list", "-j", "devices"])))
  } catch {
    e => {
      // No Xcode (no CoreSimulator), or CoreSimulator too busy to answer: what is listed stays, said once.
      if !self.said {
        self.io.log.info("screens", "simctl did not list the simulators", fields=jo([("error", js(slice_units(message_of(e), 0, 300)))]))
      }
      self.said = true
      return
    }
  }
  if self.closed {
    return
  }
  let now = booted.map(b => b.udid)
  for udid in self.listed.keys().collect() {
    if now.contains(udid) {
      continue
    }
    let (source, remove) = self.listed.get(udid).unwrap()
    self.listed.remove(udid)
    remove()
    source.gone()
  }
  for b in booted {
    if self.listed.contains(b.udid) {
      continue
    }
    let typed = self.typed(b.type_)
    let source = Simulator::new(self.io, b, self.helper.unwrap(), typed.size, simctl=Some(self.run), panels=typed.panels, chrome=typed.chrome)
    if self.closed || self.listed.contains(b.udid) {
      continue
    }
    self.listed[b.udid] = (source, (self.add)(source.source()))
  }
  self.follow()
}

///|
/// A device type's screen in pixels, panels and case, read from its bundle once.
async fn Simulators::typed(self : Simulators, type_ : String) -> Typed {
  match self.types.get(type_) {
    Some(known) => return known
    None => ()
  }
  let typed = { size: (0.0, 0.0), panels: [], chrome: [] }
  try {
    let types = arr(get(Some(parse((self.run.run)(SIMCTL, ["list", "-j", "devicetypes"]))), "devicetypes")).unwrap_or([])
    let bundle = match types.search_by(t => text(get(Some(t), "identifier")) == Some(type_)) {
      Some(i) => string_or_none(get(Some(types[i]), "bundlePath"))
      None => None
    }
    match bundle {
      Some(bundle) => {
        let capabilities = parse(
          (self.run.run)("plutil", ["-convert", "json", "-o", "-", pj([bundle, "Contents/Resources/capabilities.plist"])]),
        )
        typed.size = screen_of(capabilities)
        let dir = pj([bundle, "Contents/Resources"])
        let masks = (self.io.fs.readdir)(dir).map(e => e.name).filter(f => f.has_suffix(".pdf") && !f.has_prefix("sensor_bar"))
        let panels = @effect.all(masks.map(f => async fn() { panel_of((self.io.fs.read)(pj([dir, f]))) }))
        typed.panels = panels.filter_map(p => p)
        let profile = parse((self.run.run)("plutil", ["-convert", "json", "-o", "-", pj([dir, "profile.plist"])]))
        let sensor = text(get(Some(profile), "sensorBarImage"))
        let cases = @effect.all(displays_of(capabilities, profile).map(d => async fn() { chrome_of(self.io, d, dir, sensor) }))
        typed.chrome = cases.filter_map(c => c)
      }
      None => ()
    }
  } catch {
    _ => ()
  }
  self.types[type_] = typed
  typed
}

///|
/// A string that is truthy (`if (bundle)`).
fn string_or_none(v : J?) -> String? {
  match text(v) {
    Some(s) if s != "" => Some(s)
    _ => None
  }
}

///|
/// Watches the devices' folder (a device made or deleted) and each device's (its device.plist rewritten as it boots or
/// shuts down).
async fn Simulators::follow(self : Simulators) -> Unit {
  if self.closed {
    return
  }
  let dirs = [self.devices]
  let entries = (self.io.fs.readdir)(self.devices) catch {
    // No devices' folder (no simulators): nothing to watch.
    _ => return
  }
  for e in entries {
    if e.dir && is_udid(e.name) {
      let d = pj([self.devices, e.name])
      if !dirs.contains(d) {
        dirs.push(d)
      }
    }
  }
  if self.closed {
    return
  }
  for dir in self.watchers.keys().collect() {
    if dirs.contains(dir) {
      continue
    }
    (self.watchers.get(dir).unwrap())()
    self.watchers.remove(dir)
  }
  for dir in dirs {
    if self.watchers.contains(dir) {
      continue
    }
    let close_ref : Ref[() -> Unit] = Ref(() => ())
    let close = (self.io.fs.watch)(
      dir,
      name => if dir == self.devices ||
        (match name {
          None => true
          Some(n) => n.has_prefix("device.plist")
        }) {
        self.changed()
      },
      () => {
        (close_ref.val)()
        self.watchers.remove(dir)
      },
    ) catch {
      _ => continue
    }
    close_ref.val = close
    self.watchers[dir] = close
  }
}

///|
/// Something changed on disk: looked at once it settles (a boot rewrites device.plist a few times).
fn Simulators::changed(self : Simulators) -> Unit {
  match self.soon {
    Some(f) => f()
    None => ()
  }
  self.soon = Some(
    (self.io.clock.after)(300.0, () => {
      self.soon = None
      self.io.go(async fn() { self.refresh() })
    }),
  )
}

///|
/// The station stopping: nothing followed, every source gone.
pub fn Simulators::close(self : Simulators) -> Unit {
  self.closed = true
  match self.soon {
    Some(f) => f()
    None => ()
  }
  for w in self.watchers.values() {
    w()
  }
  self.watchers.clear()
  for l in self.listed.values() {
    (l.1)()
    l.0.gone()
  }
  self.listed.clear()
}

///|
/// One booted simulator: a view is a connection to the helper's `simulator.view` (simulator.ts `Simulator`).
pub struct Simulator {
  id : String
  /// Its apps' logs and their restart, for a person debugging one.
  priv mut debug_ : SimDebug?
  poses : Bool
  panels : Array[Panel]
  chrome : Array[ChromeSource]
  priv io : Io
  priv device : Booted
  priv helper : HelperApp
  priv simctl : Run
  priv listed_at : Double
  priv size_ : (Double, Double)
  priv views : Array[HelperView]
}

///|
pub fn Simulator::new(
  io : Io,
  device : Booted,
  helper : HelperApp,
  size : (Double, Double),
  simctl? : Run? = None,
  panels? : Array[Panel] = [],
  chrome? : Array[ChromeSource] = [],
) -> Simulator {
  let simctl = simctl.unwrap_or(sim_run(io))
  let s = {
    id: "simulator:\{device.udid}",
    debug_: None,
    poses: device.type_.has_suffix(".iPhone-Duo"),
    panels,
    chrome,
    io,
    device,
    helper,
    simctl,
    listed_at: io.clock.ms(),
    size_: size,
    views: [],
  }
  s.debug_ = Some(SimDebug::new(io, SIMCTL, device.udid, simctl, async fn() { s.picture() }))
  s
}

///|
pub fn Simulator::debug(self : Simulator) -> SimDebug {
  self.debug_.unwrap()
}

///|
pub fn Simulator::title(self : Simulator) -> String {
  "\{self.device.name} · \{self.device.runtime}"
}

///|
pub fn Simulator::since(self : Simulator) -> Double {
  self.device.booted_at.unwrap_or(self.listed_at)
}

///|
/// Shut down from a person's app: it leaves the list as CoreSimulator says it shut down.
pub async fn Simulator::discard(self : Simulator) -> Unit {
  ignore((self.simctl.run)(SIMCTL, ["shutdown", self.device.udid]))
}

///|
pub fn Simulator::size(self : Simulator) -> (Double, Double) {
  self.size_
}

///|
pub async fn Simulator::open(self : Simulator, options : ViewOptions) -> HelperView {
  // H.264 (the helper's encoder; H.265 where asked and this Mac has it), else a JPEG a picture.
  guard codec_for(options, [H265, H264, Jpeg]) is Some(codec) else {
    raise self.io.refused(415, "station.screen.codec", args=jo([("codec", js("H.264, JPEG"))]))
  }
  let op = jsome([
    ("op", Some(js("simulator.view"))),
    ("udid", Some(js(self.device.udid))),
    ("codec", Some(js(codec.name()))),
    ("maxWidth", Some(jn(options.max_width))),
    ("maxHeight", Some(jn(options.max_height))),
    ("bitrate", options.bitrate.map(b => jn(js_round(b)))),
    ("fps", options.fps.map(jn)),
  ])
  let socket = self.helper.connect(op)
  let view_ref : Ref[HelperView?] = Ref(None)
  let view = HelperView::new(
    self.io,
    codec,
    sock_pipe(socket),
    () => match view_ref.val {
      Some(v) =>
        match self.views.search_by(x => physical_equal(x, v)) {
          Some(i) => ignore(self.views.remove(i))
          None => ()
        }
      None => ()
    },
    input=Some(SimInput::new().input_ops()),
    capture="CoreSimulator",
  )
  view_ref.val = Some(view)
  self.views.push(view)
  try {
    ignore(view.ready.wait())
    view
  } catch {
    error => {
      view.close()
      self.io.log.warn("screens", "a simulator's view did not open", fields=jo([("udid", js(self.device.udid)), ("error", js(message_of(error)))]))
      raise self.io.refused(503, "station.screen.failed", args=jo([("said", js(message_of(error)))]))
    }
  }
}

///|
/// Its screen as a view has it, as large as the device's own: a view of its own for one picture.
async fn Simulator::picture(self : Simulator) -> Bytes {
  let (width, height) = self.size_
  let view = self.open(
    ViewOptions::new(if width == 0.0 { 4096.0 } else { width }, if height == 0.0 { 4096.0 } else { height }, [Jpeg]),
  )
  let r = try Ok(view.next()) catch { e => Err(e) }
  view.close()
  match r {
    Ok(Some(frame)) => frame.data
    Ok(None) => raise fail("the simulator's view ended")
    Err(e) => raise e
  }
}

///|
/// It shut down (or the station stops): its views end.
pub fn Simulator::gone(self : Simulator) -> Unit {
  self.debug().close()
  for v in self.views.copy() {
    v.close()
  }
}

///|
pub fn Simulator::source(self : Simulator) -> ScreenSource {
  {
    ..ScreenSource::bare(self.id, SimulatorKind, () => self.title(), () => self.size(), async fn(o) { self.open(o).view() }),
    peek: true,
    debug: Some(self.debug()),
    poses: self.poses,
    panels: Some(self.panels),
    chrome: Some(self.chrome),
    since: Some(() => Some(self.since())),
    discard: Some(async fn() { self.discard() }),
  }
}
