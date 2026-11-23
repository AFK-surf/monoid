// A chat's Farview tab (farview.mbt) as one of the station's screens (src/browser/farview-screen.ts): people see and
// drive it from their app as they do a tab of Chrome. The host draws its pictures itself and serves them on its frame
// port, one connection a view: JSON lines each way, a picture's bytes right after the line that says it.
//
//   to the host:   {"size":{width,height,scale}}  the tab's viewport (CSS pixels; the last view's to say one wins)
//                  {"frame":{format:"jpeg",quality}}  a picture now, answered {"frame":{seq,width,height,format,bytes}}
//                  {"pointer":…} {"wheel":…} {"key":…} {"text":…}  a person's input: it takes the tab from an agent
//   from the host: {"changed":seq}  the picture changed (asked for then: nothing is polled)
//                  {"page":{url,title}} {"size":{…}} {"taken":"agent"|"person"}
//                  {"copied":text}  what a person's copy or cut on that view took
//                  {"openTab":url}  the page asked for a new tab (heard on the watch's connection alone); a window
//                                   with a handle (window.open, an OAuth popup) says its own id as `window`, this tab's
//                                   as `opener` and the opener's origin as `origin` (the new tab's FV_TAB_ID,
//                                   FV_OPENER_ID and FV_OPENER_ORIGIN: the two tabs talk through the profile)
//                  {"closeTab":true}  the page closed its tab (window.close() in a window a page opened)

///|
/// The viewport a tab is laid out at with no view saying one (a desktop's window): width, height, scale.
pub let default_size : (Double, Double, Double) = (1280.0, 800.0, 1.0)

///|
/// JPEG quality of the frames asked for: 82, as at 70 small text's edges rang (as the browser's cast, view.ts).
let jpeg_quality : Int = 82

///|
fn size_j(s : (Double, Double, Double)) -> J {
  jo([("width", jn(s.0)), ("height", jn(s.1)), ("scale", jn(s.2))])
}

///|
/// One connection to a host's frame port: its lines heard, a picture asked for and its bytes read.
pub struct FrameLink {
  priv net : FarviewNet
  priv mut link : TcpLink?
  priv mut buffer : Bytes
  /// The picture whose bytes come next, and who waits for it.
  priv mut pending : (J, @effect.Deferred[(J, Bytes)?])?
  priv asked : Array[@effect.Deferred[(J, Bytes)?]]
  priv mut closed : Bool
  priv mut writing : Later[Unit]
  priv waiting_writes : Array[Bytes]
  mut heard : (J) -> Unit
  mut ended : () -> Unit
}

///|
pub fn FrameLink::new(net : FarviewNet, port : Int) -> FrameLink {
  let f : FrameLink = {
    net,
    link: None,
    buffer: b"",
    pending: None,
    asked: [],
    closed: false,
    writing: Later::resolved(()),
    waiting_writes: [],
    heard: _ => (),
    ended: () => (),
  }
  (net.clock.spawn)(async fn() {
    let link = (net.connect)(port) catch {
      _ => {
        f.end()
        return
      }
    }
    if f.closed {
      (link.close)()
      return
    }
    f.link = Some(link)
    let held = f.waiting_writes.copy()
    f.waiting_writes.clear()
    for b in held {
      f.write(b)
    }
    while true {
      let chunk = (link.read)() catch { _ => None }
      match chunk {
        Some(c) => f.data(c)
        None => {
          f.end()
          return
        }
      }
    }
  })
  f
}

///|
fn FrameLink::write(self : FrameLink, b : Bytes) -> Unit {
  guard self.link is Some(link) else {
    self.waiting_writes.push(b)
    return
  }
  let before = self.writing
  self.writing = Later::start(self.net.clock, async fn() {
    before.wait() catch {
      _ => ()
    }
    (link.write)(b) catch {
      _ => ()
    }
  })
}

///|
pub fn FrameLink::send(self : FrameLink, message : J) -> Unit {
  if !self.closed {
    self.write(utf8(stringify(message) + "\n"))
  }
}

///|
/// A picture of the tab now; None when the connection ended first.
pub async fn FrameLink::picture(self : FrameLink) -> (J, Bytes)? {
  if self.closed {
    return None
  }
  let d : @effect.Deferred[(J, Bytes)?] = @effect.Deferred::new()
  self.asked.push(d)
  self.send(jo([("frame", jo([("format", js("jpeg")), ("quality", ji(jpeg_quality))]))]))
  d.wait() catch {
    _ => None
  }
}

///|
fn FrameLink::data(self : FrameLink, chunk : Bytes) -> Unit {
  self.buffer = if self.buffer.length() == 0 { chunk } else { self.buffer + chunk }
  while true {
    match self.pending {
      Some((header, resolve)) => {
        let n = js_num(at(Some(header), "bytes"))
        if self.buffer.length().to_double() < n {
          return
        }
        let k = n.to_int()
        let data = self.buffer[0:k].to_bytes()
        self.buffer = self.buffer[k:].to_bytes()
        self.pending = None
        ignore(resolve.succeed(Some((header, data))))
        continue
      }
      None => ()
    }
    let mut nl = -1
    for i in 0..<self.buffer.length() {
      if self.buffer[i] == b'\n' {
        nl = i
        break
      }
    }
    if nl < 0 {
      return
    }
    let line = from_utf8(self.buffer[0:nl].to_bytes())
    self.buffer = self.buffer[nl + 1:].to_bytes()
    let message = parse(line) catch { _ => continue }
    match at(Some(message), "frame") {
      Some(Obj(_) | Arr(_) as header) => {
        let resolve = if self.asked.length() > 0 { Some(self.asked.remove(0)) } else { None }
        if !(js_num(at(Some(header), "bytes")) >= 0.0) {
          match resolve {
            Some(r) => ignore(r.succeed(None))
            None => ()
          }
          continue
        }
        self.pending = Some((header, resolve.unwrap_or(@effect.Deferred::new())))
        continue
      }
      _ => ()
    }
    (self.heard)(message)
  }
}

///|
fn FrameLink::end(self : FrameLink) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  match self.pending {
    Some((_, r)) => ignore(r.succeed(None))
    None => ()
  }
  self.pending = None
  let asked = self.asked.copy()
  self.asked.clear()
  for r in asked {
    ignore(r.succeed(None))
  }
  (self.ended)()
}

///|
pub fn FrameLink::close(self : FrameLink) -> Unit {
  match self.link {
    Some(l) => (l.close)()
    None => ()
  }
  self.end()
}

///|
/// `Math.round(n * 100) / 100`.
fn round2(n : Double) -> Double {
  js_round(n * 100.0) / 100.0
}

///|
/// A person's input as the host takes it: the view's 0..1 of the screen made the pictures' pixels (W·S × H·S) for a
/// pointer, CSS pixels of the viewport for a wheel.
pub fn input_of(e : J, size : (Double, Double, Double)) -> J? {
  let ev = Some(e)
  let (w, h, s) = size
  let field = (k : String) => match at(ev, k) {
    Some(v) => [(k, v)]
    None => []
  }
  match text(at(ev, "t")) {
    "pointer" =>
      Some(
        jo([
          (
            "pointer",
            jo(
              (match at(ev, "kind") {
                Some(k) => [("type", k)]
                None => []
              }) +
              [
                ("x", jn(round2(js_num(at(ev, "x")) * w * s))),
                ("y", jn(round2(js_num(at(ev, "y")) * h * s))),
                ("button", ji(0)),
              ] +
              field("buttons"),
            ),
          ),
        ]),
      )
    "wheel" =>
      Some(
        jo([
          (
            "wheel",
            jo(
              [("x", jn(round2(js_num(at(ev, "x")) * w))), ("y", jn(round2(js_num(at(ev, "y")) * h)))] +
              field("dx") +
              field("dy"),
            ),
          ),
        ]),
      )
    "key" =>
      Some(
        jo([
          (
            "key",
            jo(
              (match at(ev, "kind") {
                Some(k) => [("type", k)]
                None => []
              }) +
              field("key") +
              field("code") +
              field("mods"),
            ),
          ),
        ]),
      )
    "text" => Some(jo(field("text")))
    _ => None
  }
}

///|
/// The viewport a view asks for: its viewer's own screen where it says one (a phone), else what fits its bounds.
pub fn size_for(o : ViewOptions) -> (Double, Double, Double) {
  match o.fit {
    Some((w, h, s)) if w > 0.0 && h > 0.0 => return (js_round(w), js_round(h), if s > 0.0 { s } else { 1.0 })
    _ => ()
  }
  let a = o.max_width / default_size.0
  let b = o.max_height / default_size.1
  let k = if a.is_nan() || b.is_nan() {
    @double.not_a_number
  } else {
    let m = if a < b { a } else { b }
    if m < 1.0 {
      m
    } else {
      1.0
    }
  }
  if k >= 1.0 || !(k > 0.0) {
    default_size
  } else {
    (default_size.0, default_size.1, k)
  }
}

///|
/// What a page's new tab is to the tab that asked for it: the new window's id, the asking tab's, and its origin (""
/// each: a tab of its own, no handle to it).
pub(all) struct OpenTabMeta {
  window : String
  opener : String
  origin : String
}

///|
pub fn OpenTabMeta::to_j(self : OpenTabMeta) -> J {
  let out = []
  for kv in [("window", self.window), ("opener", self.opener), ("origin", self.origin)] {
    if kv.1 != "" {
      out.push((kv.0, js(kv.1)))
    }
  }
  jo(out)
}

///|
/// The new tab an `openTab` line asks for: its address and what links it to the tab that asked (None: no such line).
pub fn open_tab_of(m : J) -> (String, OpenTabMeta)? {
  let str_of = (k : String) => match at(Some(m), k) {
    Some(Str(u)) => @jsjson.sanitize_str(u)
    _ => ""
  }
  let url = str_of("openTab")
  guard url != "" else { return None }
  Some((url, { window: str_of("window"), opener: str_of("opener"), origin: str_of("origin") }))
}

///|
/// What a page of a Farview tab is at: its address and title.
pub(all) struct FramePage {
  url : String
  title : String
}

///|
pub struct FarviewScreen {
  id : String
  priv session : String
  priv port : Int
  priv net : FarviewNet
  priv log : Log
  priv mut page_ : FramePage
  priv mut size_ : (Double, Double, Double)
  priv mut watch_ : FrameLink?
  priv views : Array[FarviewView]
  priv mut closed : Bool
  mut changed : () -> Unit
  /// Hears each new tab the page asks for, by its address and what links it to this tab.
  mut opened : (String, OpenTabMeta) -> Unit
  /// Hears the page close its tab (window.close() in a window a page opened).
  mut closed_by_page : () -> Unit
}

///|
/// `n`: which of its chat's tabs (0 its first, whose id is the chat's alone).
pub fn FarviewScreen::new(session : String, port : Int, n : Int, net : FarviewNet, log : Log) -> FarviewScreen {
  {
    id: "browser:fv_\{chat_dir(session)}" + (if n != 0 { "_\{n}" } else { "" }),
    session,
    port,
    net,
    log,
    page_: { url: "", title: "" },
    size_: default_size,
    watch_: None,
    views: [],
    closed: false,
    changed: () => (),
    opened: (_, _) => (),
    closed_by_page: () => (),
  }
}

///|
/// Hears the tab's page and size on a connection of its own while the host runs.
pub fn FarviewScreen::watch(self : FarviewScreen) -> Unit {
  if self.closed || self.watch_ is Some(_) {
    return
  }
  let link = FrameLink::new(self.net, self.port)
  link.heard = m => self.watch_heard(m)
  link.ended = () => match self.watch_ {
    Some(w) if physical_equal(w, link) => self.watch_ = None
    _ => ()
  }
  self.watch_ = Some(link)
}

///|
/// A line the watch's connection heard: what every connection hears, and the page's asks of whoever holds its tab (a
/// new tab, its own closed), said on every connection and taken on this one alone.
fn FarviewScreen::watch_heard(self : FarviewScreen, m : J) -> Unit {
  self.heard(m)
  match open_tab_of(m) {
    Some((url, meta)) => (self.opened)(url, meta)
    None => ()
  }
  if at(Some(m), "closeTab") is Some(Bool(true)) {
    (self.closed_by_page)()
  }
}

///|
pub fn FarviewScreen::heard(self : FarviewScreen, m : J) -> Unit {
  let mv = Some(m)
  match at(mv, "page") {
    Some(Obj(_) | Arr(_) as p) => {
      let str_field = (k : String) => match at(Some(p), k) {
        None | Some(Null) => ""
        v => js_str(v)
      }
      let page : FramePage = { url: str_field("url"), title: str_field("title") }
      if page.url != self.page_.url || page.title != self.page_.title {
        self.page_ = page
        (self.changed)()
      }
    }
    _ => ()
  }
  match at(mv, "size") {
    Some(Obj(_) | Arr(_) as s) => {
      let w = js_num(at(Some(s), "width"))
      let h = js_num(at(Some(s), "height"))
      if w > 0.0 && h > 0.0 {
        let sc = js_num(at(Some(s), "scale"))
        self.size_ = (w, h, if sc > 0.0 { sc } else { self.size_.2 })
      }
    }
    _ => ()
  }
}

///|
pub fn FarviewScreen::page(self : FarviewScreen) -> FramePage {
  self.page_
}

///|
pub fn FarviewScreen::title(self : FarviewScreen) -> String {
  if self.page_.title != "" {
    self.page_.title
  } else if self.page_.url != "" {
    self.page_.url
  } else {
    "Farview"
  }
}

///|
pub fn FarviewScreen::size(self : FarviewScreen) -> (Double, Double) {
  (js_round(self.size_.0 * self.size_.2), js_round(self.size_.1 * self.size_.2))
}

///|
pub fn FarviewScreen::site(self : FarviewScreen) -> String? {
  match url_of(self.page_.url) {
    Some(u) => {
      let h = url_host(u)
      if h == "" {
        None
      } else {
        Some(h)
      }
    }
    None => None
  }
}

///|
pub fn FarviewScreen::address(self : FarviewScreen) -> String {
  if self.page_.url != "" {
    self.page_.url
  } else {
    "about:blank"
  }
}

///|
pub fn FarviewScreen::viewing(self : FarviewScreen) -> Int {
  self.views.filter(v => !v.peek).length()
}

///|
pub fn FarviewScreen::open(self : FarviewScreen, options : ViewOptions) -> FarviewView raise {
  if self.closed {
    raise fail_("This chat's browser was closed.")
  }
  if !options.codecs.contains("jpeg") {
    raise fail_("This tab is sent as pictures (JPEG), which this app does not take.")
  }
  let view_ref : Ref[FarviewView?] = Ref(None)
  let view = FarviewView::new(self, FrameLink::new(self.net, self.port), options, () => match view_ref.val {
    Some(v) =>
      match self.views.search_by(x => physical_equal(x, v)) {
        Some(i) => ignore(self.views.remove(i))
        None => ()
      }
    None => ()
  })
  view_ref.val = Some(view)
  self.views.push(view)
  view
}

///|
pub fn FarviewScreen::close(self : FarviewScreen) -> Unit {
  self.closed = true
  match self.watch_ {
    Some(w) => w.close()
    None => ()
  }
  for v in self.views.copy() {
    v.close()
  }
}

///|
/// The tab as one of the screens.
pub fn FarviewScreen::source(self : FarviewScreen) -> ScreenSource {
  {
    id: self.id,
    kind: "browser",
    peek: () => true,
    title: () => self.title(),
    site: () => self.site(),
    address: () => self.address(),
    size: () => self.size(),
    clipboard: () => ["text"],
    opened_by: () => Some(self.session),
    open: async fn(o) { self.open(o).as_view() },
    open_url: None,
    reload: None,
    back: None,
    forward: None,
    discard: None,
    sleep: None,
    user_tab: false,
    popup: false,
    sleeping: () => false,
    farview: true,
  }
}

///|
pub struct FarviewView {
  peek : Bool
  priv link : FrameLink
  priv screen : FarviewScreen
  priv gone : () -> Unit
  priv mut size_ : (Double, Double, Double)
  /// Who hears what this view's person copies on the tab.
  priv mut copied : (Int, (Clip) -> Unit)?
  priv mut copied_id : Int
  /// The newest picture the host said it has, and the one last sent.
  priv mut seq : Double
  priv mut sent : Double
  priv mut config : (String, Double, Double)?
  priv mut wake : @effect.Deferred[Unit]?
  priv mut closed : Bool
  priv mut ts : Double
}

///|
fn FarviewView::new(screen : FarviewScreen, link : FrameLink, o : ViewOptions, gone : () -> Unit) -> FarviewView {
  let v : FarviewView = {
    peek: o.peek,
    link,
    screen,
    gone,
    size_: size_for(o),
    copied: None,
    copied_id: 0,
    seq: 1.0,
    sent: 0.0,
    config: None,
    wake: None,
    closed: false,
    ts: 0.0,
  }
  link.heard = m => {
    let mv = Some(m)
    screen.heard(m)
    match (at(mv, "copied"), v.copied) {
      (Some(Str(u)), Some((_, f))) if u.length() > 0 && utf8(@jsjson.sanitize_str(u)).length() <= clip_text_max =>
        f({ type_: "text", text: @jsjson.sanitize_str(u) })
      _ => ()
    }
    match at(mv, "changed") {
      Some(Num(n)) if n > v.seq => v.seq = n
      _ => ()
    }
    // (the host tells the tab's viewport, never this view's scale: its pictures stay at the scale it asked, and a
    // person's pointer is of them. Taken as 1, every tap of a 2x view landed at half its place)
    match at(mv, "size") {
      Some(Obj(_) | Arr(_) as s) => {
        let w = js_num(at(Some(s), "width"))
        let h = js_num(at(Some(s), "height"))
        if w > 0.0 && h > 0.0 {
          v.size_ = (w, h, v.size_.2)
        }
      }
      _ => ()
    }
    v.poke()
  }
  link.ended = () => v.close()
  // A preview looks at the tab as it is laid out; a view lays it out for its viewer.
  if !v.peek {
    link.send(jo([("size", size_j(v.size_))]))
  }
  v
}

///|
fn FarviewView::poke(self : FarviewView) -> Unit {
  match self.wake {
    Some(w) => {
      self.wake = None
      ignore(w.succeed(()))
    }
    None => ()
  }
}

///|
pub async fn FarviewView::next(self : FarviewView) -> Frame? {
  while !self.closed && self.seq <= self.sent {
    let d : @effect.Deferred[Unit] = @effect.Deferred::new()
    self.wake = Some(d)
    d.wait() catch {
      _ => ()
    }
  }
  if self.closed {
    return None
  }
  let asked = self.seq
  guard self.link.picture() is Some((header, data)) else { return None }
  let hseq = js_num(at(Some(header), "seq"))
  let said = if hseq.is_nan() || hseq == 0.0 { asked } else { hseq }
  self.sent = if asked > said || said.is_nan() { asked } else { said }
  let width = {
    let w = js_num(at(Some(header), "width"))
    if w.is_nan() || w == 0.0 {
      0.0
    } else {
      w
    }
  }
  let height = {
    let h = js_num(at(Some(header), "height"))
    if h.is_nan() || h == 0.0 {
      0.0
    } else {
      h
    }
  }
  let mut config = None
  let changed = match self.config {
    None => true
    Some((_, w, h)) => w != width || h != height
  }
  if changed {
    self.config = Some(("jpeg", width, height))
    config = self.config
  }
  // ts in microseconds, rising: the order pictures were taken in is all a JPEG view goes by.
  self.ts += 1.0
  Some({ config, key: true, ts: self.ts, data })
}

///|
pub fn FarviewView::keyframe(self : FarviewView) -> Unit {
  if self.sent >= self.seq {
    self.sent = self.seq - 1.0
  }
  self.poke()
}

///|
pub fn FarviewView::input(self : FarviewView, event : J) -> Unit {
  match input_of(event, self.size_) {
    Some(m) => self.link.send(m)
    None => ()
  }
}

///|
/// A paste: the text put where the tab's focus is, as typed (the host has no clipboard of its own).
pub fn FarviewView::set_clipboard(self : FarviewView, clip : Clip, paste : Bool) -> Unit {
  if clip.type_ == "text" && paste && clip.text != "" {
    self.link.send(jo([("text", js(clip.text))]))
  }
}

///|
pub fn FarviewView::watch_clipboard(self : FarviewView, heard : (Clip) -> Unit) -> () -> Unit {
  self.copied_id += 1
  let me = self.copied_id
  self.copied = Some((me, heard))
  () => match self.copied {
    Some((id, _)) if id == me => self.copied = None
    _ => ()
  }
}

///|
pub fn FarviewView::bounds(self : FarviewView, max_width : Double, max_height : Double) -> Unit {
  if self.peek {
    return
  }
  let size = size_for({ codecs: ["jpeg"], max_width, max_height, peek: false, fit: None, passkeys: None, quality: None })
  if size.0 == self.size_.0 && size.1 == self.size_.1 && size.2 == self.size_.2 {
    return
  }
  self.size_ = size
  self.link.send(jo([("size", size_j(size))]))
}

///|
pub fn FarviewView::close(self : FarviewView) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  self.link.close()
  (self.gone)()
  self.poke()
  (self.screen.log.info)("browser", "a view of a chat's Farview ended", fields([("screen", js(self.screen.id))]))
}

///|
pub fn FarviewView::as_view(self : FarviewView) -> ScreenView {
  {
    next: async fn() { self.next() },
    keyframe: () => self.keyframe(),
    input: async fn(e) { self.input(e) },
    set_clipboard: async fn(c, p) { self.set_clipboard(c, p) },
    watch_clipboard: f => self.watch_clipboard(f),
    watch_login: _ => () => (),
    fill: async fn(_) { () },
    watch_passkey: _ => () => (),
    passkey: async fn(_) { () },
    bounds: (w, h) => self.bounds(w, h),
    rate: None,
    video: () => jo([("capture", js("Farview"))]),
    viewport: () => (self.size_.0, self.size_.1),
    watch_child: _ => () => (),
    close: () => self.close(),
    peek: self.peek,
  }
}

///|
/// Who hears the tab's page change (nobody in the station yet: its screen's title is read as it is listed).
pub fn FarviewScreen::on_changed(self : FarviewScreen, f : () -> Unit) -> Unit {
  self.changed = f
}
