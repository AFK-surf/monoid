// station/src/terminals/terminals.ts: the station's terminals, a person's shell on this machine, opened from the app
// (步骤 2b of the terminal; the user, 2026-11-14). Each is a runner's (`--pty`, link.mbt), so it outlives the station
// restarting as an agent does; who may open one is who may make an agent run anything here: every member but a
// read-only one, who only looks (station AGENTS.md: no permission system; the user, 2026-11-14: 「所有成员都能开」).
// One view types into a terminal at a time, any number look, as a screen's (screens/hub.ts `drive`): asking 接管
// takes it, and the one who had it is told.
//
// A view is a stream on a member's link (mesh/serve.ts, this part's `terminal` requests): its head line
// `{terminal: {cols, rows, control?, taken?, cwd?, chat?}}` on POST /admin/api/terminals/<id>/view (`new` opens one),
// answered 200 `application/x-stillfail-terminal`, then frames both ways as a screen's (mesh/screens.ts `frame`: a
// kind byte, its payload's length in 4 bytes, the payload). Station → client: `screen` (VT that makes the screen as
// it is in a new terminal of its size, first, and again as the size changes), `out` (what the program wrote since),
// `state` (JSON: the terminal's id, size and folder, whether this view types, who does, who looks, its exit once it
// ended). Client → station: `input` (bytes typed, as its terminal encodes them), `resize` (JSON `{cols, rows}`: the
// typing view's alone), `control` (只看 or 接管 without opening the stream again).
//
// What the TypeScript ran on in one turn of its loop (what a view sets going before its first wait: the runner asked
// for the screen, told the size) runs here before the fiber waits too, so the runner is asked in the same order.

///|
pub const TERMINAL_TYPE : String = "application/x-stillfail-terminal"

///|
pub const KIND_SCREEN : Int = 1

///|
pub const KIND_OUT : Int = 2

///|
pub const KIND_STATE : Int = 3

///|
pub const KIND_INPUT : Int = 16

///|
pub const KIND_RESIZE : Int = 17

///|
pub const KIND_CONTROL : Int = 18

///|
/// A client's frame: what is typed at once, or a size.
pub const MAX_IN : Int = 65536

///|
/// How many terminals a station keeps at once.
pub const MOST : Int = 16

///|
const COLS_LO : Int = 2

///|
const COLS_HI : Int = 1000

///|
const ROWS_LO : Int = 1

///|
const ROWS_HI : Int = 500

///|
/// A member as a view is given them (mesh/credential.ts Viewer: what of it a terminal reads).
pub(all) struct Viewer {
  name : String
  email : String
  role : String
  workspace : String
  device : String
}

///|
/// `readOnly(viewer)`: a read-only member (credential.ts READ_ONLY_ROLES).
pub fn read_only(role : String) -> Bool {
  role == "viewer"
}

///|
/// A member's stream (mesh/native.ts Stream: what a view uses of it).
pub(all) struct Stream {
  read : async () -> Bytes?
  write : async (Bytes) -> Unit
  finish : async () -> Unit
}

///|
/// What opens a terminal: where its runner starts it, as whom, how large. `workspace`: the opener's; only its
/// members see the terminal.
pub(all) struct Opening {
  cols : Int
  rows : Int
  cwd : String?
  chat : String?
  by : String
  by_email : String?
  workspace : String
}

///|
/// What is kept of a terminal beside its runner, so a station after this one says the same of it.
pub(all) struct TerminalMeta {
  by : String
  by_email : String?
  at : Double
  cwd : String
  chat : String?
  workspace : String
}

///|
/// The meta as it is written (`JSON.stringify(meta)`).
pub fn TerminalMeta::to_json(self : TerminalMeta) -> J {
  let ps = [("by", js(self.by)), ("at", jn(self.at)), ("cwd", js(self.cwd))]
  if self.by_email is Some(email) {
    ps.push(("byEmail", js(email)))
  }
  if self.chat is Some(c) {
    ps.push(("chat", js(c)))
  }
  ps.push(("workspace", js(self.workspace)))
  jo(ps)
}

///|
/// Why a terminal was not opened, and the status a view is refused with.
pub suberror TerminalRefused {
  TerminalRefused(Int, String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for TerminalRefused with output(self, logger) {
  match self {
    TerminalRefused(_, m) => logger.write_string(m)
  }
}

///|
/// What the station gives the terminals: how one is started (its runner, its link), the folder one opens in when none
/// is asked, what is told as they change.
pub(all) struct TerminalDeps {
  /// Starts its runner (in `cwd`), keeps its meta, and links to it.
  start : async (String, Opening, String, TerminalMeta) -> TerminalLink
  home : String
  /// A chat's folder, if it is one of this station's.
  chat_dir : (String) -> String?
  changed : (String) -> Unit
  /// What is kept of an open terminal changed (its live folder after `cd`): written again.
  meta : ((String, TerminalMeta) -> Unit)?
  /// It left the list (ended, and no view is left on it): what was kept of it goes.
  gone : (String) -> Unit
  new_id : () -> String
  /// Whether a new one is opened here: a `beta` feature of the station's (features.ts `stationFeature("terminal")`);
  /// those open already are looked at and ended as before. None: always.
  offered : (() -> Bool)?
  /// The machine's time (`wall.now`).
  now : () -> Double
  /// What runs on by itself, as `void` a promise did.
  spawn : (async () -> Unit) -> Unit
  /// log.info(part, what, fields).
  log : (String, J) -> Unit
}

///|
/// A view on a terminal. `again`: gives it the screen anew (the size changed: its own terminal is made that size from
/// it).
priv struct View {
  id : Int
  name : String
  device : String
  mut types : Bool
  tell : (J) -> Unit
  mut again : () -> Unit
}

///|
priv struct Terminal {
  views : Map[Int, View]
  mut typing : Int?
  /// Its size, as the typing view last made it (one taken up from before: a usual one till a view says).
  mut size : (Int, Int)
  id : String
  link : TerminalLink
  by : String
  by_email : String?
  at : Double
  mut cwd : String
  /// An escape the shell's output ended in the middle of, read with what comes next (`oscCwd`'s tail).
  mut osc_tail : String
  chat : String?
  workspace : String
  mut ended : Ended?
}

///|
/// What is kept of it (its meta file).
fn Terminal::meta(self : Terminal) -> TerminalMeta {
  { by: self.by, by_email: self.by_email, at: self.at, cwd: self.cwd, chat: self.chat, workspace: self.workspace }
}

///|
/// What a terminal is said to be, to every member (GET /terminals, `terminals` on the event stream).
fn Terminal::shown(self : Terminal) -> J {
  let typing = match self.typing {
    None => J::Null
    Some(t) =>
      match self.views.get(t) {
        Some(v) => js(v.name)
        None => Null
      }
  }
  let looking = []
  for _, v in self.views {
    if Some(v.id) != self.typing {
      looking.push(js(v.name))
    }
  }
  let ps = [("id", js(self.id)), ("by", js(self.by)), ("at", jn(self.at)), ("cwd", js(self.cwd))]
  if self.by_email is Some(email) {
    ps.push(("byEmail", js(email)))
  }
  if self.chat is Some(c) && c != "" {
    ps.push(("chat", js(c)))
  }
  ps.push(("typing", typing))
  ps.push(("looking", ja(looking)))
  if self.link.over() {
    ps.push(("ended", ended_json(self.ended)))
  }
  jo(ps)
}

///|
fn ended_json(e : Ended?) -> J {
  match e {
    Some(e) => e.to_json()
    None => Null
  }
}

///|
pub struct Terminals {
  priv deps : TerminalDeps
  priv terminals : Map[String, Terminal]
  priv mut views : Int
}

///|
pub fn Terminals::new(deps : TerminalDeps) -> Terminals {
  { deps, terminals: {}, views: 0 }
}

///|
/// A workspace's (its members see them).
pub fn Terminals::list(self : Terminals, workspace : String) -> J {
  let out = []
  for _, t in self.terminals {
    if t.workspace == workspace {
      out.push(t.shown())
    }
  }
  ja(out)
}

///|
/// The workspaces that have one, for what is told as they change.
pub fn Terminals::workspaces(self : Terminals) -> Array[String] {
  let out : Array[String] = []
  for _, t in self.terminals {
    if !out.contains(t.workspace) {
      out.push(t.workspace)
    }
  }
  out
}

///|
/// One a runner kept from before this station (adopted as it starts); `size` as its runner said it.
pub fn Terminals::keep(
  self : Terminals,
  id : String,
  link : TerminalLink,
  meta : TerminalMeta,
  size : (J?, J?),
) -> Unit {
  let t : Terminal = {
    views: {},
    typing: None,
    size: (80, 24),
    id,
    link,
    by: meta.by,
    by_email: meta.by_email,
    at: meta.at,
    cwd: meta.cwd,
    osc_tail: "",
    chat: meta.chat,
    workspace: meta.workspace,
    ended: None,
  }
  if within(size.0, COLS_LO, COLS_HI) && within(size.1, ROWS_LO, ROWS_HI) {
    t.size = (int_of(size.0), int_of(size.1))
  }
  self.add(t)
}

///|
fn Terminals::add(self : Terminals, t : Terminal) -> Unit {
  self.terminals[t.id] = t
  // Its folder as the shell says it after each command (OSC 7, OSC 9;9), kept and told.
  t.link.listen(out => {
    let (cwd, tail) = osc_cwd(t.osc_tail + utf8_text(out.bytes))
    t.osc_tail = tail
    match cwd {
      Some(c) if c != t.cwd => {
        t.cwd = c
        match self.deps.meta {
          Some(f) => f(t.id, t.meta())
          None => ()
        }
        self.tell_all(t)
      }
      _ => ()
    }
  })
  |> ignore
  t.link.ended(e => {
    t.ended = e
    let (code, signal) = match e {
      Some(e) => (e.code, e.signal)
      None => (Null, Null)
    }
    (self.deps.log)("ended", jo([("id", js(t.id)), ("code", code), ("signal", signal)]))
    for _, v in t.views {
      (v.tell)(self.state(t, v))
    }
    // Its views say how it ended; it leaves the list once none is left.
    if t.views.length() == 0 {
      self.drop(t)
    }
    (self.deps.changed)(t.workspace)
  })
  |> ignore
  (self.deps.changed)(t.workspace)
}

///|
async fn Terminals::open(self : Terminals, o : Opening) -> Terminal {
  let mut live = 0
  for _, t in self.terminals {
    if !t.link.over() {
      live += 1
    }
  }
  if live >= MOST {
    raise TerminalRefused(429, "a station keeps \{MOST} terminals at most: end one first")
  }
  let cwd = match o.cwd {
    Some(c) => c
    None =>
      match o.chat {
        Some(c) if c != "" =>
          match (self.deps.chat_dir)(c) {
            Some(d) => d
            None => self.deps.home
          }
        _ => self.deps.home
      }
  }
  let id = (self.deps.new_id)()
  let at = (self.deps.now)()
  let chat = match o.chat {
    Some(c) if c != "" => Some(c)
    _ => None
  }
  let link = (self.deps.start)(id, o, cwd, { by: o.by, by_email: o.by_email, at, cwd, chat, workspace: o.workspace })
  let t : Terminal = {
    views: {},
    typing: None,
    size: (o.cols, o.rows),
    id,
    link,
    by: o.by,
    by_email: o.by_email,
    at,
    cwd,
    osc_tail: "",
    chat,
    workspace: o.workspace,
    ended: None,
  }
  let fields = [("id", js(id)), ("by", js(o.by)), ("cwd", js(cwd))]
  if chat is Some(c) {
    fields.push(("chat", js(c)))
  }
  (self.deps.log)("opened", jo(fields))
  self.add(t)
  t
}

///|
/// Ends it (its program and what it started), whoever asks.
pub fn Terminals::end(self : Terminals, id : String, by : String, workspace : String) -> Bool {
  guard self.terminals.get(id) is Some(t) && t.workspace == workspace else { return false }
  (self.deps.log)("ended by a member", jo([("id", js(id)), ("by", js(by))]))
  if t.link.over() {
    self.drop(t)
    (self.deps.changed)(t.workspace)
  } else {
    t.link.kill()
  }
  true
}

///|
fn Terminals::drop(self : Terminals, t : Terminal) -> Unit {
  match self.terminals.get(t.id) {
    Some(x) if physical_equal(x, t) => {
      self.terminals.remove(t.id)
      (self.deps.gone)(t.id)
    }
    _ => ()
  }
}

///|
/// The station stops or hands over: every runner keeps its terminal for the next one.
pub fn Terminals::detach(self : Terminals) -> Unit {
  for _, t in self.terminals {
    t.link.detach()
  }
}

///|
fn Terminals::state(self : Terminals, t : Terminal, v : View) -> J {
  ignore(self)
  let s = t.shown()
  let ps = [
    ("id", js(t.id)),
    ("types", jb(t.typing == Some(v.id))),
    ("typing", or_null(get(Some(s), "typing"))),
    ("looking", or_null(get(Some(s), "looking"))),
    ("cwd", js(t.cwd)),
    ("cols", ji(t.size.0)),
    ("rows", ji(t.size.1)),
    ("inband", jb(true)),
  ]
  if t.link.over() {
    ps.push(("ended", or_null(get(Some(s), "ended"))))
  }
  jo(ps)
}

///|
fn Terminals::tell_all(self : Terminals, t : Terminal) -> Unit {
  for _, v in t.views {
    (v.tell)(self.state(t, v))
  }
  (self.deps.changed)(t.workspace)
}

///|
/// The path's terminal: what `/admin/api/terminals/([^/?]+)/view` takes of it.
fn view_path(path : String) -> String? {
  let pre = "/admin/api/terminals/"
  let post = "/view"
  if !path.has_prefix(pre) || !path.has_suffix(post) || path.length() < pre.length() + post.length() + 1 {
    return None
  }
  let id = path.unsafe_substring(start=pre.length(), end=path.length() - post.length())
  if id.contains("/") || id.contains("?") {
    None
  } else {
    Some(id)
  }
}

///|
fn frame(kind : Int, payload : Bytes) -> Bytes {
  let b = @buffer.new()
  b.write_byte(kind.to_byte())
  let n = payload.length()
  b.write_byte(((n >> 24) & 0xff).to_byte())
  b.write_byte(((n >> 16) & 0xff).to_byte())
  b.write_byte(((n >> 8) & 0xff).to_byte())
  b.write_byte((n & 0xff).to_byte())
  b.write_bytes(payload)
  b.to_bytes()
}

///|
/// writeLine: a value as a line of JSON.
async fn write_line(stream : Stream, value : J) -> Unit {
  (stream.write)(utf8_of(stringify(value) + "\n"))
}

///|
/// The terminal a view asked for, as it is answered once found.
priv enum Found {
  Refuse(Int, String)
  Viewing(Terminal)
}

///|
/// A view of a terminal, for as long as its stream lasts.
pub async fn Terminals::answer(self : Terminals, stream : Stream, carry : Bytes, head : J, viewer : Viewer) -> Unit {
  let refuse = async fn(status : Int, error : String) {
    write_line(stream, jo([("status", ji(status)), ("headers", jo([("content-type", js("application/json"))]))]))
    (stream.write)(utf8_of(stringify(jo([("error", js(error))]))))
    (stream.finish)()
  }
  let method = match text(get(Some(head), "method")) {
    Some(m) => m.to_upper()
    None => "GET"
  }
  let found = match text(get(Some(head), "path")) {
    Some(p) => view_path(p)
    None => None
  }
  guard found is Some(which) && method == "POST" else {
    refuse(404, "a terminal is viewed with POST /admin/api/terminals/<id>/view")
    return
  }
  guard asked(get(Some(head), "terminal")) is Some(ask) else {
    refuse(400, "terminal: {cols \{COLS_LO}-\{COLS_HI}, rows \{ROWS_LO}-\{ROWS_HI}}")
    return
  }
  let name = if viewer.name != "" { viewer.name } else { viewer.email }
  let looks_only = read_only(viewer.role)
  let got = if which == "new" {
    if self.deps.offered is Some(offered) && !offered() {
      Refuse(404, "no route: terminals are opened on stations updated on the test channel alone")
    } else if looks_only {
      Refuse(403, "a read-only member does not open a terminal")
    } else {
      let opening : Opening = {
        cols: ask.cols,
        rows: ask.rows,
        cwd: ask.cwd,
        chat: ask.chat,
        by: name,
        by_email: Some(viewer.email),
        workspace: viewer.workspace,
      }
      match (try Ok(self.open(opening)) catch { e => Err(e) }) {
        Ok(t) => Viewing(t)
        Err(TerminalRefused(status, message)) => Refuse(status, message)
        Err(e) => Refuse(503, error_message(e))
      }
    }
  } else {
    let id = match @api_routes.decode_uri_component(which) {
      Some(id) => id
      // (decodeURIComponent's URIError, thrown out of the view as the TypeScript's)
      None => raise Failure("URI malformed")
    }
    match self.terminals.get(id) {
      Some(t) if t.workspace == viewer.workspace => Viewing(t)
      _ => Refuse(404, "no such terminal: it ended, or the station was set up anew")
    }
  }
  let terminal = match got {
    Refuse(status, message) => {
      refuse(status, message)
      return
    }
    Viewing(t) => t
  }
  // Whether it types: asked and let (not read-only); it takes the terminal from another only when asked to (接管), or
  // where none types now.
  let types = ask.control && !looks_only && (ask.taken || terminal.typing is None)
  // What is written to the stream, in turn; once one fails nothing more is.
  let writes : Array[@effect.Deferred[Unit]] = []
  let broken = Ref(false)
  let send = (kind : Int, payload : Bytes) => {
    let before = writes.last()
    let done : @effect.Deferred[Unit] = @effect.Deferred::new()
    writes.push(done)
    (self.deps.spawn)(async fn() {
      match before {
        Some(d) => d.wait() catch { _ => () }
        None => ()
      }
      if !broken.val {
        (stream.write)(frame(kind, payload)) catch {
          _ => broken.val = true
        }
      }
      done.succeed(()) |> ignore
    })
  }
  self.views += 1
  let view : View = {
    id: self.views,
    name,
    device: viewer.device,
    types,
    tell: state => send(KIND_STATE, utf8_of(stringify(state))),
    again: () => (),
  }
  write_line(stream, jo([("status", ji(200)), ("headers", jo([("content-type", js(TERMINAL_TYPE))]))])) catch {
    _ => return
  }
  // What comes before the screen is answered is kept, and given past where the screen is.
  let pending : Ref[Array[Out]?] = Ref(Some([]))
  let shown_at = Ref(0.0)
  let unlisten = terminal.link.listen(out => match pending.val {
    Some(p) => p.push(out)
    None =>
      match past_screen(out, shown_at.val) {
        Some(past) => send(KIND_OUT, past)
        None => ()
      }
  })
  let give_screen = () => {
    if pending.val is None {
      pending.val = Some([])
    }
    let asked_screen = terminal.link.screen()
    (self.deps.spawn)(async fn() {
      match asked_screen.wait() {
        Ok(shown) => {
          match shown.size {
            Some((c, r)) if terminal.typing is None &&
              within(Some(Num(c)), COLS_LO, COLS_HI) &&
              within(Some(Num(r)), ROWS_LO, ROWS_HI) &&
              (terminal.size.0.to_double() != c || terminal.size.1.to_double() != r) => {
              terminal.size = (c.to_int(), r.to_int())
              self.tell_all(terminal)
            }
            _ => ()
          }
          shown_at.val = shown.at
          send(KIND_SCREEN, shown.data)
        }
        // Ended meanwhile: its state says so.
        Err(_) => ()
      }
      // (where another answer gave what was kept already, none is kept: the TypeScript's stops there, its kept
      // list gone)
      match pending.val {
        Some(p) => {
          let kept = p.copy()
          p.clear()
          for out in kept {
            match past_screen(out, shown_at.val) {
              Some(past) => send(KIND_OUT, past)
              None => ()
            }
          }
          pending.val = None
        }
        None => ()
      }
    })
  }
  view.again = give_screen
  let took = match terminal.typing {
    Some(t) if types && t != view.id => terminal.views.get(t)
    _ => None
  }
  let others = terminal.views.values().collect()
  terminal.views[view.id] = view
  if types {
    terminal.typing = Some(view.id)
    if took is Some(prev) {
      (self.deps.log)("taken over", jo([("id", js(terminal.id)), ("by", js(name)), ("from", js(prev.name))]))
    }
    // The size is the typing view's: those already on it are given the screen at that size.
    terminal.size = (ask.cols, ask.rows)
    terminal.link.resize(ask.cols, ask.rows)
    for v in others {
      (v.again)()
    }
  }
  self.tell_all(terminal)
  // (its typing is read meanwhile: the screen is the runner's to answer, after what it was asked before)
  give_screen()
  let ended = terminal.link.ended(_ => self.tell_all(terminal))
  let frames = FrameIn::new(stream, carry)
  (try {
    while true {
      guard frames.next() is Some((kind, payload)) else { break }
      let typing = terminal.typing == Some(view.id)
      if kind == KIND_INPUT && typing {
        terminal.link.type_(payload)
      } else if kind == KIND_RESIZE && typing {
        guard size_of(payload) is Some((cols, rows)) else { continue }
        let changed = terminal.size.0 != cols || terminal.size.1 != rows
        terminal.size = (cols, rows)
        terminal.link.resize(cols, rows)
        self.tell_all(terminal)
        // Watchers are given the screen again at the new size; the typing view already resized its own terminal in
        // place.
        if changed {
          for _, v in terminal.views {
            if !physical_equal(v, view) {
              (v.again)()
            }
          }
        }
      } else if kind == KIND_CONTROL {
        guard control_of(payload) is Some(c) else { continue }
        if !c.control {
          if terminal.typing == Some(view.id) {
            terminal.typing = None
            view.types = false
            self.tell_all(terminal)
          }
        } else if !looks_only &&
          (c.taken || terminal.typing is None || terminal.typing == Some(view.id)) {
          let prev = match terminal.typing {
            Some(t) if t != view.id => terminal.views.get(t)
            _ => None
          }
          if prev is Some(p) {
            p.types = false
            (self.deps.log)("taken over", jo([("id", js(terminal.id)), ("by", js(name)), ("from", js(p.name))]))
          }
          terminal.typing = Some(view.id)
          view.types = true
          match c.size {
            Some((cols, rows)) if terminal.size.0 != cols || terminal.size.1 != rows => {
              terminal.size = (cols, rows)
              terminal.link.resize(cols, rows)
              for _, v in terminal.views {
                if !physical_equal(v, view) {
                  (v.again)()
                }
              }
            }
            _ => ()
          }
          self.tell_all(terminal)
        }
      }
    }
  } catch {
    // A frame too large, the stream broken: the view ends.
    _ => ()
  })
  unlisten()
  ended()
  terminal.views.remove(view.id)
  if terminal.typing == Some(view.id) {
    terminal.typing = None
  }
  if terminal.link.over() && terminal.views.length() == 0 {
    self.drop(terminal)
  }
  self.tell_all(terminal)
  for w in writes.copy() {
    w.wait() catch {
      _ => ()
    }
  }
  (stream.finish)() catch {
    _ => ()
  }
}

///|
fn error_message(e : Error) -> String {
  match e {
    Failure(m) => m
    TerminalRefused(_, m) => m
    _ => e.to_string()
  }
}

///|
/// A view's head (`terminal`): its size, whether it asks to type and to take the terminal, where a new one opens.
pub(all) struct Asked {
  cols : Int
  rows : Int
  control : Bool
  taken : Bool
  cwd : String?
  chat : String?
}

///|
pub fn Asked::to_json(self : Asked) -> J {
  let ps = [("cols", ji(self.cols)), ("rows", ji(self.rows)), ("control", jb(self.control)), ("taken", jb(self.taken))]
  if self.cwd is Some(c) {
    ps.push(("cwd", js(c)))
  }
  if self.chat is Some(c) {
    ps.push(("chat", js(c)))
  }
  jo(ps)
}

///|
pub fn asked(v : J?) -> Asked? {
  guard v is Some(Obj(_) | Arr(_)) else { return None }
  let cols = get(v, "cols")
  let rows = get(v, "rows")
  if !within(cols, COLS_LO, COLS_HI) || !within(rows, ROWS_LO, ROWS_HI) {
    return None
  }
  let text_of = (x : J?) => match x {
    Some(Str(u)) if u.length() > 0 && u.length() <= 4096 => Some(@jsjson.raw_text(u))
    _ => None
  }
  Some({
    cols: int_of(cols),
    rows: int_of(rows),
    control: !(get(v, "control") is Some(Bool(false))),
    taken: get(v, "taken") is Some(Bool(true)),
    cwd: text_of(get(v, "cwd")),
    chat: text_of(get(v, "chat")),
  })
}

///|
/// A `resize` frame's size, or None when it is none.
pub fn size_of(payload : Bytes) -> (Int, Int)? {
  let v = parse(utf8_text(payload)) catch { _ => return None }
  if within(get(Some(v), "cols"), COLS_LO, COLS_HI) && within(get(Some(v), "rows"), ROWS_LO, ROWS_HI) {
    Some((int_of(get(Some(v), "cols")), int_of(get(Some(v), "rows"))))
  } else {
    None
  }
}

///|
/// An in-band `control` frame (`只看` release or `接管` takeover).
pub(all) struct Control {
  control : Bool
  taken : Bool
  size : (Int, Int)?
}

///|
pub fn Control::to_json(self : Control) -> J {
  let ps = [("control", jb(self.control)), ("taken", jb(self.taken))]
  if self.size is Some((c, r)) {
    ps.push(("cols", ji(c)))
    ps.push(("rows", ji(r)))
  }
  jo(ps)
}

///|
pub fn control_of(payload : Bytes) -> Control? {
  let v = parse(utf8_text(payload)) catch { _ => return None }
  guard v is (Obj(_) | Arr(_)) && get(Some(v), "control") is Some(Bool(control)) else { return None }
  let has_size = within(get(Some(v), "cols"), COLS_LO, COLS_HI) && within(get(Some(v), "rows"), ROWS_LO, ROWS_HI)
  Some({
    control,
    taken: get(Some(v), "taken") is Some(Bool(true)),
    size: if has_size {
      Some((int_of(get(Some(v), "cols")), int_of(get(Some(v), "rows"))))
    } else {
      None
    },
  })
}

///|
/// Frames from a client, after what came with the head line (mesh/screens.ts FrameIn, with a terminal's bound).
priv struct FrameIn {
  mut carry : Bytes
  stream : Stream
}

///|
fn FrameIn::new(stream : Stream, carry : Bytes) -> FrameIn {
  { carry, stream }
}

///|
async fn FrameIn::next(self : FrameIn) -> (Int, Bytes)? {
  while true {
    let c = self.carry
    if c.length() >= 5 {
      let length = (c[1].to_uint() << 24) | (c[2].to_uint() << 16) | (c[3].to_uint() << 8) | c[4].to_uint()
      if length > MAX_IN.reinterpret_as_uint() {
        raise Failure("terminal frame too large")
      }
      let n = length.reinterpret_as_int()
      if c.length() >= 5 + n {
        let kind = c[0].to_int()
        let payload = c[5:5 + n].to_bytes()
        self.carry = c[5 + n:].to_bytes()
        return Some((kind, payload))
      }
    }
    match (self.stream.read)() {
      None => {
        if self.carry.length() == 0 {
          return None
        }
        raise Failure("stream ended inside a terminal frame")
      }
      Some(more) =>
        self.carry = if self.carry.length() == 0 {
          more
        } else {
          let b = @buffer.new()
          b.write_bytes(self.carry)
          b.write_bytes(more)
          b.to_bytes()
        }
    }
  }
  None
}

///|
/// How much of an unfinished escape is carried to the next chunk (terminals.ts OSC_MAX_TAIL).
const OSC_MAX_TAIL : Int = 2048

///|
fn osc_end(text : String, at : Int) -> Int? {
  if at < text.length() && osc_cu(text, at) == 0x07 {
    Some(at + 1)
  } else if at + 1 < text.length() && osc_cu(text, at) == 0x1b && osc_cu(text, at + 1) == '\\'.to_int() {
    Some(at + 2)
  } else {
    None
  }
}

///|
/// Where the run of what is neither BEL nor ESC from `at` ends.
fn osc_run(text : String, at : Int) -> Int {
  let mut i = at
  while i < text.length() && osc_cu(text, i) != 0x07 && osc_cu(text, i) != 0x1b {
    i += 1
  }
  i
}

///|
/// The live working directory the shell announced (`OSC 7` `file://host/path`, ConPTY's `OSC 9;9;path`), and an
/// unfinished escape's tail to put before the next chunk (terminals.ts `oscCwd`).
pub fn osc_cwd(text : String) -> (String?, String) {
  let mut cwd : String? = None
  let mut consumed = 0
  let n = text.length()
  let mut i = 0
  while i + 1 < n {
    if osc_cu(text, i) != 0x1b || osc_cu(text, i + 1) != ']'.to_int() {
      i += 1
      continue
    }
    let rest = text.unsafe_substring(start=i + 2, end=n)
    if rest.has_prefix("7;file://") {
      let host_end = {
        let mut j = i + 2 + 9
        while j < n && osc_cu(text, j) != '/'.to_int() && osc_cu(text, j) != 0x07 && osc_cu(text, j) != 0x1b {
          j += 1
        }
        j
      }
      if host_end < n && osc_cu(text, host_end) == '/'.to_int() {
        let path_end = osc_run(text, host_end)
        match osc_end(text, path_end) {
          Some(after) => {
            let raw = text.unsafe_substring(start=host_end, end=path_end)
            let mut decoded = @api_routes.decode_uri_component(raw).unwrap_or(raw)
            if decoded.length() >= 4 &&
              osc_cu(decoded, 0) == '/'.to_int() &&
              ((osc_cu(decoded, 1) | 0x20) >= 'a'.to_int() && (osc_cu(decoded, 1) | 0x20) <= 'z'.to_int()) &&
              osc_cu(decoded, 2) == ':'.to_int() &&
              (osc_cu(decoded, 3) == '\\'.to_int() || osc_cu(decoded, 3) == '/'.to_int()) {
              decoded = decoded.unsafe_substring(start=1, end=decoded.length())
            }
            if decoded != "" && decoded.length() <= 4096 {
              cwd = Some(decoded)
            }
            consumed = after
            i = after
            continue
          }
          None => ()
        }
      }
    } else if rest.has_prefix("9;9;") {
      let start = i + 2 + 4
      let end = osc_run(text, start)
      if end > start {
        match osc_end(text, end) {
          Some(after) => {
            let raw = text.unsafe_substring(start~, end~)
            let unquoted = if raw.length() >= 2 && raw.has_prefix("\"") && raw.has_suffix("\"") {
              raw.unsafe_substring(start=1, end=raw.length() - 1)
            } else {
              raw
            }
            if unquoted != "" && unquoted.length() <= 4096 {
              cwd = Some(unquoted)
            }
            consumed = after
            i = after
            continue
          }
          None => ()
        }
      }
    }
    i += 1
  }
  let rest = text.unsafe_substring(start=consumed, end=n)
  let mut esc = -1
  for k = rest.length() - 1; k >= 0; k = k - 1 {
    if osc_cu(rest, k) == 0x1b {
      esc = k
      break
    }
  }
  if esc < 0 || rest.length() - esc > OSC_MAX_TAIL {
    return (cwd, "")
  }
  let candidate = rest.unsafe_substring(start=esc, end=rest.length())
  let body = if candidate.length() >= 2 { candidate.unsafe_substring(start=2, end=candidate.length()) } else { "" }
  let plain = (s : String) => osc_run(s, 0) == s.length()
  let partial = candidate == "\u{1b}" ||
    (candidate.has_prefix("\u{1b}]") &&
    (body == "" ||
    body == "7" ||
    (body.has_prefix("7;") && plain(body)) ||
    body == "9" ||
    body == "9;9" ||
    (body.has_prefix("9;9;") && plain(body))))
  (cwd, if partial { candidate } else { "" })
}

///|
fn osc_cu(s : String, i : Int) -> Int {
  s.code_unit_at(i).to_int()
}
