// computer (station/src/tools/computer.ts): the agents operate the station's screens themselves: a screenshot of one
// (a JPEG, the source's own frame), and a person's input on it (clicks, drags, the wheel, keys, text), given in the
// screenshot's pixels and posted as the screen contract's 0..1. A session keeps one view of a screen open while it
// uses it (closed after IDLE_MS unused), joined to the screen's people as "agent: <its chat>". A person driving the
// screen at that moment has it: the agent's input is refused until they leave it. On the desktop an agent also reads
// an app's window as its accessibility tree (`tree`) and acts on its elements by ref.
//
// The screens are the screen hub's (`hub`: `list`, `get`, `people`, `openAs`, `refresh`, `whenStopping`), a source's
// methods by its reference (`size`, `title`, `access`, `ui`), a view's (`next`, `input`, `close`); its timers are
// `Timers`'.

///|
pub let shot_max : Int = 1280

///|
pub let idle_ms : Double = 60000.0

///|
pub let settle_ms : Double = 500.0

///|
pub let first_ms : Double = 10000.0

///|
pub let wait_max : Double = 30000.0

///|
pub let drag_steps : Int = 8

///|
pub let tree_settle_ms : Double = 200.0

///|
pub let scroll_unit_px : Double = 100.0

///|
/// Where the timers are: `later(ms, f)` runs `f` once `ms` have passed, and gives what calls it off.
pub struct Timers {
  later : async (Double, async () -> Unit) -> (() -> Unit)
}

///|
pub fn Timers::new(
  later : async (Double, async () -> Unit) -> (() -> Unit),
) -> Timers {
  { later, }
}

///|
/// The runtime's own clock.
pub fn Timers::wall() -> Timers {
  {
    later: (ms, f) => {
      let cancelled = Ref::new(false)
      ignore(
        @effect.runtime().fork(name="computer timer", async fn() {
          @effect.sleep(ms.to_int())
          if !cancelled.val {
            f()
          }
        }),
      )
      () => cancelled.val = true
    },
  }
}

///|
/// A point of a screenshot `size` pixels large, as the contract's 0..1 (clamped to the frame).
pub fn to_unit(x : Double, y : Double, w : Double, h : Double) -> (Double, Double) {
  let unit = (v : Double, of : Double) => if of > 0.0 {
    let r = v / of
    if r < 0.0 {
      0.0
    } else if r > 1.0 {
      1.0
    } else {
      r
    }
  } else {
    0.0
  }
  (unit(x, w), unit(y, h))
}

///|
let mod_bits : Array[(String, Int)] = [
  ("alt", 1),
  ("ctrl", 2),
  ("meta", 4),
  ("shift", 8),
]

///|
fn mod_bit(m : String) -> Int {
  for p in mod_bits {
    if p.0 == m {
      return p.1
    }
  }
  0
}

///|
fn mod_name(m : String) -> String? {
  match m {
    "cmd" | "command" | "meta" | "super" | "win" | "⌘" => Some("meta")
    "ctrl" | "control" | "⌃" => Some("ctrl")
    "alt" | "option" | "opt" | "⌥" => Some("alt")
    "shift" | "⇧" => Some("shift")
    _ => None
  }
}

///|
fn mod_key(m : String) -> (String, String) {
  match m {
    "alt" => ("Alt", "AltLeft")
    "ctrl" => ("Control", "ControlLeft")
    "meta" => ("Meta", "MetaLeft")
    _ => ("Shift", "ShiftLeft")
  }
}

///|
fn named_key(name : String) -> (String, String)? {
  match name {
    "enter" | "return" => Some(("Enter", "Enter"))
    "tab" => Some(("Tab", "Tab"))
    "escape" | "esc" => Some(("Escape", "Escape"))
    "backspace" => Some(("Backspace", "Backspace"))
    "delete" | "del" => Some(("Delete", "Delete"))
    "space" => Some((" ", "Space"))
    "up" | "arrowup" => Some(("ArrowUp", "ArrowUp"))
    "down" | "arrowdown" => Some(("ArrowDown", "ArrowDown"))
    "left" | "arrowleft" => Some(("ArrowLeft", "ArrowLeft"))
    "right" | "arrowright" => Some(("ArrowRight", "ArrowRight"))
    "home" => Some(("Home", "Home"))
    "end" => Some(("End", "End"))
    "pageup" => Some(("PageUp", "PageUp"))
    "pagedown" => Some(("PageDown", "PageDown"))
    "insert" => Some(("Insert", "Insert"))
    _ => None
  }
}

///|
/// The keys of a US keyboard's punctuation, by what they type (unshifted, shifted).
let punctuation : Array[(String, String, String)] = [
  ("-", "_", "Minus"),
  ("=", "+", "Equal"),
  ("[", "{", "BracketLeft"),
  ("]", "}", "BracketRight"),
  ("\\", "|", "Backslash"),
  (";", ":", "Semicolon"),
  ("'", "\"", "Quote"),
  (",", "<", "Comma"),
  (".", ">", "Period"),
  ("/", "?", "Slash"),
  ("`", "~", "Backquote"),
  ("1", "!", "Digit1"),
  ("2", "@", "Digit2"),
  ("3", "#", "Digit3"),
  ("4", "$", "Digit4"),
  ("5", "%", "Digit5"),
  ("6", "^", "Digit6"),
  ("7", "&", "Digit7"),
  ("8", "*", "Digit8"),
  ("9", "(", "Digit9"),
  ("0", ")", "Digit0"),
]

///|
/// An ASCII letter alone: `/^[a-z]$/i`.
fn is_letter(s : String) -> Bool {
  s.length() == 1 &&
  {
    let c = s.unsafe_charcode_at(0)
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
  }
}

///|
fn key_of(name : String, shift : Bool) -> (String, String) raise Failed {
  match named_key(lower(name)) {
    Some(k) => return k
    None => ()
  }
  // /^f([1-9]|1[0-9]|20)$/i
  if name.length() >= 2 && (name.has_prefix("f") || name.has_prefix("F")) {
    let n = slice(name, 1)
    if n.iter().all(c => c >= '0' && c <= '9') && !n.has_prefix("0") {
      let v = @api_routes.js_number(n)
      if v >= 1.0 && v <= 20.0 && n.length() <= 2 {
        return ("F\{n}", "F\{n}")
      }
    }
  }
  if is_letter(name) {
    return (if shift { upper(name) } else { lower(name) }, "Key\{upper(name)}")
  }
  for p in punctuation {
    if p.0 == name || p.1 == name {
      return (if shift { p.1 } else { name }, p.2)
    }
  }
  if code_point_count(name) == 1 {
    return (name, "")
  }
  raise Failed(
    "key: unknown key \{quoted(name)} (e.g. Enter, Tab, Escape, Backspace, Delete, Space, Up, Down, Left, Right, Home, End, PageUp, PageDown, F1-F20, a letter, a digit)",
  )
}

///|
fn key_event(kind : String, key : String, code : String, mods : Int) -> JV {
  jobj([
    ("t", js("key")),
    ("kind", js(kind)),
    ("key", js(key)),
    ("code", js(code)),
    ("mods", jint(mods)),
  ])
}

///|
/// A key or a combination ("cmd+shift+t", "Enter", "ctrl+Left") as the contract's key events.
pub fn key_presses(combo : String, extra? : Array[String] = []) -> Array[JV] raise Failed {
  let parts = split(combo, "+").map(trim_js)
  // "+" or "cmd++" (the plus key) leaves empty parts.
  if combo == "+" || combo.has_suffix("++") {
    let n = parts.length()
    let keep = if n >= 2 { parts[0:n - 2].to_array() } else { [] }
    parts.clear()
    for p in keep {
      parts.push(p)
    }
    parts.push("+")
  }
  let name = match parts.pop() {
    Some(n) => n
    None => ""
  }
  if name == "" {
    raise Failed("key: no key in \{quoted(combo)}")
  }
  let held : Array[String] = []
  for m in [..extra, ..parts] {
    match mod_name(lower(m)) {
      None =>
        raise Failed("key: \{quoted(m)} is no modifier (cmd, ctrl, alt, shift)")
      Some(md) => if !held.contains(md) { held.push(md) }
    }
  }
  // A shifted character ("?", "+") is its key with shift.
  if punctuation.iter().any(p => p.1 == name) && !held.contains("shift") {
    held.push("shift")
  }
  let shift = held.contains("shift")
  let (k, code) = key_of(name, shift)
  let out = []
  let mut mods = 0
  for m in held {
    mods = mods | mod_bit(m)
    let (mk, mc) = mod_key(m)
    out.push(key_event("down", mk, mc, mods))
  }
  out.push(key_event("down", k, code, mods))
  out.push(key_event("up", k, code, mods))
  let rev = held.copy()
  rev.rev_in_place()
  for m in rev {
    mods = mods & mod_bit(m).lnot()
    let (mk, mc) = mod_key(m)
    out.push(key_event("up", mk, mc, mods))
  }
  out
}

///|
/// What typing `text` sends: the text, with Enter pressed for each newline.
pub fn typing(text : String) -> Array[JV] raise Failed {
  let out = []
  let lines = split(replace_all(replace_all(text, "\r\n", "\n"), "\r", "\n"), "\n")
  for i, line in lines {
    if i > 0 {
      for e in key_presses("Enter") {
        out.push(e)
      }
    }
    // At most what a person's view may send at once.
    let mut at = 0
    while at < line.length() {
      out.push(jobj([("t", js("text")), ("text", js(slice(line, at, to=at + 1000)))]))
      at += 1000
    }
  }
  out
}

///|
fn button_bit(b : String) -> Int {
  match b {
    "left" => 1
    "right" => 2
    _ => 4
  }
}

///|
fn pointer(kind : String, x : Double, y : Double, buttons : Int) -> JV {
  jobj([
    ("t", js("pointer")),
    ("kind", js(kind)),
    ("x", jnum(x)),
    ("y", jnum(y)),
    ("buttons", jint(buttons)),
  ])
}

///|
/// A click at (x, y) (0..1): there, the button down and up (twice for a double click).
pub fn clicking(x : Double, y : Double, button : String, double : Bool) -> Array[JV] {
  let bit = button_bit(button)
  let once = [pointer("down", x, y, bit), pointer("up", x, y, 0)]
  [pointer("move", x, y, 0), ..once, ..(if double { once } else { [] })]
}

///|
/// A drag from `from` to `to` (0..1): the button down there, DRAG_STEPS moves with it held, released at `to`.
pub fn dragging(
  fx : Double,
  fy : Double,
  tx : Double,
  ty : Double,
  button : String,
) -> Array[JV] {
  let bit = button_bit(button)
  let out = [pointer("move", fx, fy, 0), pointer("down", fx, fy, bit)]
  for i in 1..=drag_steps {
    let f = i.to_double() / drag_steps.to_double()
    out.push(pointer("move", fx + (tx - fx) * f, fy + (ty - fy) * f, bit))
  }
  out.push(pointer("up", tx, ty, 0))
  out
}

///|
/// A session's view of one screen while it uses it: the frames drained as they come, the newest kept.
struct AgentView {
  session : String
  id : String
  source : Source
  name : String
  view : JV
  mut latest : JV?
  mut width : Double?
  mut height : Double?
  mut codec : String?
  waiters : Array[@effect.Deferred[Bool]]
  mut ended : Bool
  mut idle : () -> Unit
}

///|
/// The agents' hands on the station's screens: their views, by session and screen.
pub struct Computer {
  c : Ctx
  hub : String
  base : String
  name : String
  timers : Timers
  views : Map[String, AgentView]
  opening : Map[String, @effect.Deferred[Result[AgentView, Error]]]
  trees : Map[String, (String, String, String)]
}

///|
/// `hub` the screens' hub, `base` this station's place in its control plane's pages, `name` what a session's view is
/// named among the screen's people.
pub async fn Computer::new(
  c : Ctx,
  hub? : String = "screens",
  base? : String = "base",
  name? : String = "agentName",
  timers? : Timers = Timers::wall(),
) -> Computer {
  let computer = {
    c,
    hub,
    base,
    name,
    timers,
    views: Map::new(),
    opening: Map::new(),
    trees: Map::new(),
  }
  c.b.tell("\{hub}.whenStopping", [jobj([("$fn", jbool(true))])])
  computer
}

///|
fn Computer::view_call(self : Computer, v : AgentView, method : String) -> String {
  ignore(self)
  "\{ref_of(v.view).unwrap_or("")}.\{method}"
}

///|
/// Used now: it closes IDLE_MS from now, unless used again.
async fn Computer::touch(self : Computer, v : AgentView) -> Unit {
  (v.idle)()
  v.idle = (self.timers.later)(idle_ms, () => self.close_view(v))
}

///|
async fn Computer::close_view(self : Computer, v : AgentView) -> Unit {
  if v.ended {
    return
  }
  v.ended = true
  (v.idle)()
  self.c.b.tell(self.view_call(v, "close"), []) catch {
    _ => ()
  }
  for w in v.waiters {
    ignore(w.succeed(false))
  }
  v.waiters.clear()
  let key = "\{v.session}\n\{v.id}"
  match self.views.get(key) {
    Some(have) if physical_equal(have, v) => self.views.remove(key)
    _ => ()
  }
}

///|
async fn Computer::pump(self : Computer, v : AgentView) -> Unit {
  while !v.ended {
    let frame = self.c.b.ask(self.view_call(v, "next"), []) catch {
      error => {
        self.c.b.log(
          "warn",
          "computer",
          "a screen's frame was not had",
          jobj([("screen", js(v.id)), ("error", js(message_of(error)))]),
        )
        Null
      }
    }
    if v.ended {
      return
    }
    if frame is Null || is_undef(frame) {
      return self.close_view(v)
    }
    match frame.get("config") {
      Some(Obj(_) as config) => {
        v.width = finite(config.get("width"))
        v.height = finite(config.get("height"))
        v.codec = jstr(config.get("codec"))
      }
      _ => ()
    }
    v.latest = Some(frame)
    let waiting = v.waiters.copy()
    v.waiters.clear()
    for w in waiting {
      ignore(w.succeed(true))
    }
  }
}

///|
/// The newest frame, waiting up to FIRST_MS for the first: its data, size and codec.
async fn Computer::frame(
  self : Computer,
  v : AgentView,
) -> (JV, Double, Double, String) {
  if v.latest is None && !v.ended {
    let d : @effect.Deferred[Bool] = @effect.Deferred::new()
    let stop = (self.timers.later)(first_ms, () => ignore(d.succeed(false)))
    v.waiters.push(d)
    ignore(d.wait())
    stop()
  }
  if v.ended {
    raise Failed(
      "The screen \{v.id} went away (closed, or the station's browser stopped): call `screen` for those there are now.",
    )
  }
  match (v.latest, v.width, v.height) {
    (Some(f), Some(w), Some(h)) => (f, w, h, v.codec.unwrap_or(""))
    _ =>
      raise Failed(
        "The screen \{v.id} showed nothing within \{num_text(first_ms / 1000.0)} s; try again.",
      )
  }
}

///|
/// The views open now, as `session screen`.
pub fn Computer::open(self : Computer) -> Array[String] {
  let out = []
  for _, v in self.views {
    out.push("\{v.session} \{v.id}")
  }
  out
}

///|
/// A session ended: its views close.
pub async fn Computer::close_session(self : Computer, session : String) -> Unit {
  let views = []
  for _, v in self.views {
    if v.session == session {
      views.push(v)
    }
  }
  for v in views {
    self.close_view(v)
  }
  let keys = []
  for k, _ in self.trees {
    if k.has_prefix("\{session}\n") {
      keys.push(k)
    }
  }
  for k in keys {
    self.trees.remove(k)
  }
}

///|
pub async fn Computer::close_all(self : Computer) -> Unit {
  let views = []
  for _, v in self.views {
    views.push(v)
  }
  for v in views {
    self.close_view(v)
  }
}

///|
/// The link a person opens the screen with, and what to do with it.
async fn Computer::hand_over(self : Computer, id : String) -> String {
  match self.c.b.ask(self.base, []) {
    Str(base) =>
      "A person can do it on this screen from their still.fail app: \{base}/screen/\{encode_component(id)} — post that link on a line of its own (it shows as the screen's card) with chat_post kind=need_human, saying what to do there, and end your turn."
    _ => "A person can open this screen from the still.fail app (this station's control plane has no pages to link to); ask in the chat with chat_post kind=need_human."
  }
}

///|
/// The people driving `id` now, other than the agents' own views.
async fn Computer::persons(self : Computer, id : String) -> Array[String] {
  let b = self.c.b
  let views = jitems(b.ask("\{self.hub}.people", [js(id)]).get("views")).filter(v => truthy(
      v.get("control"),
    ) &&
    !truthy(v.get("agent")))
  let out = []
  for v in views {
    out.push("\{js_string(v.get("name"))} (\{said_text(b.ask("screens/hub.viewOn", [v]))})")
  }
  out
}

///|
/// What to tell the person holding `id` for the agent to go on.
async fn Computer::let_go_words(self : Computer, id : String) -> String {
  let page = match self.c.b.ask(self.base, []) {
    Str(base) => "the station's page (\{base})"
    _ => "the station's page in the still.fail app"
  }
  "Ask them in the chat to leave it to you, naming that device: they close \{id} there, or from any device disconnect that view or make it watch-only, under Screens on \{page}. If a person has asked you to take over, the `screen` tool's action take_control makes it so."
}

///|
/// accessShown(access, "en")?.message.
async fn Computer::access_message(self : Computer, access : JV) -> String? {
  let shown = self.c.b.ask("screens/hub.accessShown", [access, js("en")])
  match shown {
    Obj(_) if !is_undef(shown) => jstr(shown.get("message"))
    _ => None
  }
}

///|
async fn Computer::view(
  self : Computer,
  session : String,
  source : Source,
) -> AgentView {
  let key = "\{session}\n\{source.id}"
  match self.views.get(key) {
    Some(have) =>
      if !have.ended && have.source.ref_ == source.ref_ {
        return have
      } else {
        self.close_view(have)
      }
    None => ()
  }
  match self.opening.get(key) {
    Some(d) =>
      match d.wait() {
        Ok(v) => return v
        Err(e) => raise e
      }
    None => ()
  }
  let d = @effect.Deferred::new()
  self.opening[key] = d
  let made = try {
    Ok(self.open_view(session, source, key))
  } catch {
    e => Err(e)
  }
  self.opening.remove(key)
  ignore(d.succeed(made))
  match made {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
async fn Computer::open_view(
  self : Computer,
  session : String,
  source : Source,
  key : String,
) -> AgentView {
  let b = self.c.b
  let view = {
    // Among the screen's people while it is open (closing it leaves).
    let who = b.ask(self.name, [js(session)])
    b.ask("\{self.hub}.openAs", [
      js(source.id),
      jobj([
        ("maxWidth", jint(shot_max)),
        ("maxHeight", jint(shot_max)),
        ("codecs", jstrs(["jpeg"])),
      ]),
      jobj([("name", who), ("control", jbool(true))]),
    ])
  } catch {
    error =>
      match thrown_as(error, "ScreenRefused") {
        Some(said) => {
          let status = jnumber(said.get("status"))
          if status == Some(415.0) || status == Some(400.0) {
            raise Failed(
              "The screen \{source.id} does not send pictures an agent can take on this station (it sends no JPEG): update the station.",
            )
          }
          let access = self.access_message(field(said, "access"))
          let words = match access {
            Some(m) if m != "" => m
            _ => refused_words(self.c, said)
          }
          raise Failed("\{words}\n\{self.hand_over(source.id)}")
        }
        None =>
          raise Failed(
            "The screen \{source.id} could not be opened: \{message_of(error)}",
          )
      }
  }
  // Gone while it opened.
  let again = b.ask("\{self.hub}.get", [js(source.id)])
  if !(ref_of(again) == ref_of(source.ref_)) {
    b.tell("\{ref_of(view).unwrap_or("")}.close", [])
    raise Failed(
      "The screen \{source.id} went away: call `screen` for those there are now.",
    )
  }
  let name = said_text(b.ask(self.name, [js(session)]))
  let v : AgentView = {
    session,
    id: source.id,
    source,
    name,
    view,
    latest: None,
    width: None,
    height: None,
    codec: None,
    waiters: [],
    ended: false,
    idle: () => (),
  }
  self.views[key] = v
  self.touch(v)
  ignore(
    @effect.runtime().fork(name="computer view", async fn() {
      self.pump(v) catch {
        _ => ()
      }
    }),
  )
  v
}

///|
async fn Computer::sleep(self : Computer, ms : Double) -> Unit {
  if ms <= 0.0 {
    return
  }
  let d : @effect.Deferred[Unit] = @effect.Deferred::new()
  ignore((self.timers.later)(ms, () => ignore(d.succeed(()))))
  d.wait()
}

///|
fn clamp_wait(v : JV?, default : Double) -> Double {
  match finite(v) {
    Some(n) => if n < 0.0 { 0.0 } else if n > wait_max { wait_max } else { n }
    None => default
  }
}

///|
fn action_enum() -> Array[String] {
  [
    "screenshot", "tree", "click", "move", "drag", "scroll", "type", "set", "key", "wait",
  ]
}

///|
/// An input action's events, given the screenshot's size, and what it says it did.
priv struct Plan {
  events : (Double, Double) -> Array[JV] raise Failed
  said : String
}

///|
fn plan_of(action : String, args : JV) -> Plan raise Failed {
  let point = (x : JV?, y : JV?, what : String) => match (finite(x), finite(y)) {
    (Some(x), Some(y)) => (x, y)
    _ =>
      raise Failed(
        "\{action}: \{what} needs numbers x and y (pixels of the latest screenshot)",
      )
  }
  let inside = (p : (Double, Double), w : Double, h : Double) => {
    if p.0 < 0.0 || p.1 < 0.0 || p.0 > w || p.1 > h {
      raise Failed(
        "\{action}: (\{num_text(p.0)}, \{num_text(p.1)}) is outside the screenshot (\{num_text(w)}×\{num_text(h)}); take a screenshot and give a point on it",
      )
    }
    to_unit(p.0, p.1, w, h)
  }
  let button = () => match args.get("button") {
    None => "left"
    Some(x) if is_undef(x) => "left"
    Some(Str("left")) => "left"
    Some(Str("right")) => "right"
    Some(Str("middle")) => "middle"
    _ => raise Failed("\{action}: button is left, right or middle")
  }
  let at = (p : (Double, Double)) => "(\{num_text(p.0)}, \{num_text(p.1)})"
  match action {
    "click" => {
      let p = point(args.get("x"), args.get("y"), "the point")
      let b = button()
      let double = is_true(args.get("double"))
      {
        events: (w, h) => {
          let u = inside(p, w, h)
          clicking(u.0, u.1, b, double)
        },
        said: "\{if double { "Double-clicked" } else { "Clicked" }}\{if b == "left" { "" } else { " (\{b})" }} at \{at(p)}.",
      }
    }
    "move" => {
      let p = point(args.get("x"), args.get("y"), "the point")
      {
        events: (w, h) => {
          let u = inside(p, w, h)
          [pointer("move", u.0, u.1, 0)]
        },
        said: "Moved the pointer to \{at(p)}.",
      }
    }
    "drag" => {
      let pair = (v : JV?, what : String) => match v {
        Some(Arr(items)) => point(items.get(0), items.get(1), what)
        _ => point(None, None, what)
      }
      let from = pair(args.get("from"), "from: [x, y]")
      let to = pair(args.get("to"), "to: [x, y]")
      let b = button()
      {
        events: (w, h) => {
          let f = inside(from, w, h)
          let t = inside(to, w, h)
          dragging(f.0, f.1, t.0, t.1, b)
        },
        said: "Dragged from \{at(from)} to \{at(to)}.",
      }
    }
    "scroll" => {
      let p = point(args.get("x"), args.get("y"), "the point")
      let dx = finite(args.get("dx")).unwrap_or(0.0)
      let dy = finite(args.get("dy")).unwrap_or(0.0)
      if dx == 0.0 && dy == 0.0 {
        raise Failed("scroll: give dx and/or dy (pixels; dy > 0 scrolls down)")
      }
      let clamp = (v : Double) => if v < -10000.0 {
        -10000.0
      } else if v > 10000.0 {
        10000.0
      } else {
        v
      }
      {
        events: (w, h) => {
          let u = inside(p, w, h)
          [
            pointer("move", u.0, u.1, 0),
            jobj([
              ("t", js("wheel")),
              ("x", jnum(u.0)),
              ("y", jnum(u.1)),
              ("dx", jnum(clamp(dx))),
              ("dy", jnum(clamp(dy))),
            ]),
          ]
        },
        said: "Scrolled by (\{num_text(dx)}, \{num_text(dy)}) at \{at(p)}.",
      }
    }
    "type" => {
      guard args.get("text") is Some(Str(t)) && t != "" else {
        raise Failed("type: text is required")
      }
      let events = typing(t)
      { events: (_, _) => events, said: "Typed \{shown_text(t)}." }
    }
    "key" => {
      guard args.get("key") is Some(Str(k)) && trim_js(k) != "" else {
        raise Failed("key: key is required (e.g. Enter, cmd+c)")
      }
      let mods = strings_of(args.get("mods"))
      let events = key_presses(trim_js(k), extra=mods)
      {
        events: (_, _) => events,
        said: "Pressed \{[..mods, trim_js(k)].join("+")}.",
      }
    }
    _ => raise Failed("unknown action \{action}")
  }
}

///|
/// `JSON.stringify(text.length > 80 ? `${text.slice(0, 80)}…` : text)`.
fn shown_text(t : String) -> String {
  quoted(if t.length() > 80 { slice(t, 0, to=80) + "…" } else { t })
}

///|
/// One call of the tool: what it did, and the screenshot after it.
pub async fn Computer::act(
  self : Computer,
  session : String,
  args : JV,
) -> ToolReply {
  let b = self.c.b
  let action = match args.get("action") {
    Some(Str(a)) if a != "" => a
    _ => "screenshot"
  }
  if !action_enum().contains(action) {
    raise Failed("unknown action \{action}: \{action_enum().join(", ")}")
  }
  let id = match args.get("screen") {
    Some(Str(s)) => trim_js(s)
    _ => ""
  }
  let there = async fn() -> String {
    let ids = jitems(Some(b.ask("\{self.hub}.list", []))).map(s => js_string(s.get("id"))).join(", ")
    if ids == "" {
      "none"
    } else {
      ids
    }
  }
  if id == "" {
    raise Failed(
      "screen is required: the id of one of this station's screens (\{there()}); the `screen` tool lists them.",
    )
  }
  guard source_of(b, self.hub, id) is Some(source) else {
    raise Failed("no screen \{id} on this station (it has: \{there()})")
  }
  if action == "tree" ||
    action == "set" ||
    trimmed(args.get("ref")) != "" ||
    (action == "key" && trimmed(args.get("app")) != "") {
    return self.by_tree(session, source, action, args)
  }
  let acting = action != "screenshot" && action != "wait"
  // What the input will be, checked before anything is opened or sent.
  let plan = if acting { Some(plan_of(action, args)) } else { None }
  if acting {
    let persons = self.persons(id)
    if persons.length() > 0 {
      raise Failed(
        "\{persons.join(", ")} \{if persons.length() > 1 { "are" } else { "is" }} controlling \{id} right now, so your input was not sent: do not fight them. Wait and take a screenshot later (`screen` shows who is on it). \{self.let_go_words(id)}",
      )
    }
  }
  if source.has_access {
    b.tell("\{self.hub}.refresh", [])
    let access = b.ask(source.call("access"), [])
    if acting && truthy(access.get("capture")) && !truthy(access.get("control")) {
      raise Failed(
        "\{self.access_message(access).unwrap_or("")}\nYour input was not sent.\n\{self.hand_over(id)}",
      )
    }
  }
  let view = self.view(session, source)
  self.touch(view)
  let mut did = ""
  match plan {
    Some(plan) => {
      let (_, w, h, _) = self.frame(view)
      let events = (plan.events)(w, h)
      for e in events {
        b.tell(self.view_call(view, "input"), [e])
      }
      did = plan.said
    }
    None =>
      if action == "wait" {
        let ms = clamp_wait(args.get("ms"), 1000.0)
        self.sleep(ms)
        did = "Waited \{num_text(js_round(ms))} ms."
      }
  }
  self.touch(view)
  let shoot = action == "screenshot" ||
    action == "wait" ||
    !is_false(args.get("screenshot"))
  if !shoot {
    return {
      content: [Text(if did == "" { "Done." } else { did })],
      is_error: false,
    }
  }
  if acting {
    self.sleep(clamp_wait(args.get("wait"), settle_ms))
  }
  let (frame, w, h, codec) = self.frame(view)
  self.touch(view)
  if codec != "jpeg" {
    raise Failed(
      "The screen \{id} sent \{if codec == "" { "no" } else { codec }} pictures, not JPEG: an agent cannot take them on this station yet (update the station).",
    )
  }
  let described = self.described(source, w, h, view)
  let lines = [did, described].filter(s => s != "")
  let data = @api_routes.bytes_of(frame.get("data").unwrap_or(Null)).unwrap_or(b"")
  {
    content: [Text(lines.join("\n")), Image(@base64.encode(data), "image/jpeg")],
    is_error: false,
  }
}

///|
/// What a screenshot is: its screen, its size and how its pixels map to the screen's, and who else is on it.
async fn Computer::described(
  self : Computer,
  source : Source,
  w : Double,
  h : Double,
  view : AgentView,
) -> String {
  let b = self.c.b
  let real = b.ask(source.call("size"), [])
  let rw = jnumber(real.get("width")).unwrap_or(0.0)
  let scale = if rw > 0.0 && w > 0.0 { rw / w } else { 1.0 }
  let scaled = num_text(fixed_number(scale, 3))
  let title = b.ask(source.call("title"), [])
  let lines = [
    "\{source.id} \{stringify(title)}: screenshot \{num_text(w)}×\{num_text(h)} px (scale \{scaled}: 1 screenshot px = \{scaled} screen px). Give x/y in this screenshot's pixels.",
  ]
  let people = strings_of(b.ask("\{self.hub}.people", [js(source.id)]).get("viewers")).filter(n => n !=
    view.name)
  if people.length() > 0 {
    lines.push("Also on this screen: \{people.join(", ")}.")
  }
  lines.join("\n")
}

///|
/// agent-desktop's envelope: its data, or what it said went wrong as the agent reads it.
fn answered(envelope : JV, what : String) -> JV raise Failed {
  if envelope.get("ok") is Some(Bool(true)) {
    return match envelope.get("data") {
      None | Some(Null) => jobj([])
      Some(d) if is_undef(d) => jobj([])
      Some(d) => d
    }
  }
  let e = match envelope.get("error") {
    Some(Obj(_) as e) => e
    _ => jobj([])
  }
  let or = (k : String, d : String) => match e.get(k) {
    None | Some(Null) => d
    Some(x) if is_undef(x) => d
    x => js_string(x)
  }
  let lines = ["\{what}: \{or("code", "ERROR")}: \{or("message", "agent-desktop failed")}"]
  match e.get("suggestion") {
    Some(Str(s)) if s != "" => lines.push(s)
    _ => ()
  }
  match e.get("details") {
    Some(d) if !is_undef(d) => lines.push("Details: \{stringify(d)}")
    _ => ()
  }
  match jget(jget(Some(e), "disposition"), "retry") {
    Some(Str("safe")) => lines.push("It was not done; it is safe to try again.")
    Some(Str("unsafe")) =>
      lines.push("It may have been done: read the tree before doing it again.")
    _ => ()
  }
  raise Failed(lines.join("\n"))
}

///|
/// An app's tree (`tree`), or an action on one of its elements by ref, answered with its tree again.
async fn Computer::by_tree(
  self : Computer,
  session : String,
  source : Source,
  action : String,
  args : JV,
) -> ToolReply {
  let b = self.c.b
  let id = source.id
  if !source.has_ui {
    raise Failed(
      "The screen \{id} has no accessibility trees: use screenshots and coordinates there (trees are the desktop's).",
    )
  }
  if source.has_access {
    b.tell("\{self.hub}.refresh", [])
    let access = b.ask(source.call("access"), [])
    if !truthy(access.get("control")) {
      let words = match self.access_message(access) {
        Some(m) => m
        None => "The screen \{id} cannot be driven now."
      }
      raise Failed("\{words}\n\{self.hand_over(id)}")
    }
  }
  let ui = async fn(cmd : Array[String]) -> JV {
    b.ask(source.call("ui"), [jstrs(cmd)]) catch {
      error => {
        let why = match thrown_as(error, "ScreenRefused") {
          Some(said) =>
            match self.access_message(field(said, "access")) {
              Some(m) => m
              None => message_of(error)
            }
          None => message_of(error)
        }
        raise Failed("The screen \{id}'s apps could not be read: \{why}")
      }
    }
  }
  let key = "\{session}\n\{id}"
  let latest = self.trees.get(key)
  let ref_ = trimmed(args.get("ref"))
  // A ref as agent-desktop takes it: its snapshot's (`@s1:e12`), the latest tree's for a bare one.
  let qualified = () => {
    if ref_.has_prefix("@") {
      return ref_
    }
    let bare = ref_.has_prefix("e") &&
      ref_.length() > 1 &&
      slice(ref_, 1).iter().all(c => c >= '0' && c <= '9')
    if !bare {
      raise Failed("\{action}: ref is an element's ref from the latest tree, e.g. e12")
    }
    match latest {
      None => raise Failed("\{action}: no tree read yet on \{id}: call action=tree with app first")
      Some((snapshot, _, _)) => "@\{snapshot}:\{ref_}"
    }
  }
  if action == "tree" {
    let app = trimmed(args.get("app"))
    let window = trimmed(args.get("window"))
    if app == "" && ref_ == "" {
      return {
        content: [Text(apps_said(answered(ui(["list-apps"]), "apps")))],
        is_error: false,
      }
    }
    let at = if ref_ == "" {
      ("", app, window)
    } else {
      let (s, a, w) = latest.unwrap_or(("", app, window))
      (s, if app != "" { app } else { a }, w)
    }
    let root = if ref_ == "" { None } else { Some(qualified()) }
    return {
      content: [
        Text(self.read_tree(key, at, ui, root, is_true(args.get("skeleton")))),
      ],
      is_error: false,
    }
  }
  let (cmd, said) = match action {
    "click" => {
      let btn = match args.get("button") {
        None => "left"
        Some(x) if is_undef(x) => "left"
        Some(Str("left")) => "left"
        Some(Str("right")) => "right"
        _ => raise Failed("click: by ref, button is left or right")
      }
      let double = is_true(args.get("double"))
      let verb = if btn == "right" {
        "right-click"
      } else if double {
        "double-click"
      } else {
        "click"
      }
      (
        [verb, qualified()],
        "\{if btn == "right" { "Right-clicked" } else if double { "Double-clicked" } else { "Clicked" }} \{ref_}.",
      )
    }
    "type" | "set" => {
      let t = match args.get("text") {
        Some(Str(t)) if !(action == "type" && t == "") => t
        _ => raise Failed("\{action}: text is required")
      }
      let cmd = if action == "type" {
        ["type", qualified(), t]
      } else {
        ["set-value", qualified(), t]
      }
      let shown = shown_text(t)
      (
        cmd,
        if action == "type" {
          "Typed \{shown} into \{ref_}."
        } else {
          "Set \{ref_} to \{shown}."
        },
      )
    }
    "scroll" => {
      let dx = finite(args.get("dx")).unwrap_or(0.0)
      let dy = finite(args.get("dy")).unwrap_or(0.0)
      if dx == 0.0 && dy == 0.0 {
        raise Failed("scroll: give dx and/or dy (pixels; dy > 0 scrolls down)")
      }
      let vertical = dy.abs() >= dx.abs()
      let along = if vertical { dy } else { dx }
      let direction = if vertical {
        if dy > 0.0 {
          "down"
        } else {
          "up"
        }
      } else if dx > 0.0 {
        "right"
      } else {
        "left"
      }
      let amount = {
        let a = js_round(along.abs() / scroll_unit_px)
        let a = if a > 50.0 { 50.0 } else { a }
        if a < 1.0 {
          1.0
        } else {
          a
        }
      }
      (
        ["scroll", qualified(), "--direction", direction, "--amount", num_text(amount)],
        "Scrolled \{ref_} \{direction} by \{num_text(amount)}.",
      )
    }
    "key" => {
      let combo = trimmed(args.get("key"))
      if combo == "" {
        raise Failed("key: key is required (e.g. Enter, cmd+c)")
      }
      let mods = strings_of(args.get("mods"))
      let keys = [..mods, combo].join("+")
      let app = trimmed(args.get("app"))
      (["press", keys, "--app", app], "Pressed \{keys} in \{app}.")
    }
    _ =>
      raise Failed(
        "\{action}: not by ref (by ref: click, type, set, scroll; key with app)",
      )
  }
  ignore(answered(ui(cmd), action))
  // The app read again: its own tree, or the one named (key's).
  let again = if action == "key" {
    let app = trimmed(args.get("app"))
    match latest {
      Some((_, a, _)) as l if a == app => l
      _ => Some(("", app, ""))
    }
  } else {
    latest
  }
  match again {
    None => return { content: [Text(said)], is_error: false }
    Some(_) if is_false(args.get("tree")) =>
      return { content: [Text(said)], is_error: false }
    Some(at) => {
      self.sleep(clamp_wait(args.get("wait"), tree_settle_ms))
      {
        content: [Text("\{said}\n\{self.read_tree(key, at, ui, None, false)}")],
        is_error: false,
      }
    }
  }
}

///|
/// An app's window read (or the part under `root`), kept as the session's latest tree: what an agent reads.
async fn Computer::read_tree(
  self : Computer,
  key : String,
  at : (String, String, String),
  ui : async (Array[String]) -> JV,
  root : String?,
  skeleton : Bool,
) -> String {
  let (_, app, window) = at
  let cmd = ["snapshot", "--compact"]
  if app != "" {
    cmd.push("--app")
    cmd.push(app)
  }
  if window != "" {
    cmd.push("--window-id")
    cmd.push(window)
  }
  match root {
    Some(r) => {
      cmd.push("--root")
      cmd.push(r)
    }
    None => ()
  }
  if skeleton {
    cmd.push("--skeleton")
  }
  let data = answered(ui(cmd), "tree")
  let or_none = (v : JV?) => match v {
    None | Some(Null) => None
    Some(x) if is_undef(x) => None
    Some(x) => Some(x)
  }
  let snapshot = match or_none(data.get("snapshot_id")) {
    Some(s) => js_string(Some(s))
    None => ""
  }
  let win = match or_none(data.get("window")) {
    Some(w) => w
    None => jobj([])
  }
  let win_id = or_none(jget(Some(win), "id"))
  let data_app = or_none(data.get("app"))
  self.trees[key] = (
    snapshot,
    match data_app {
      Some(a) => js_string(Some(a))
      None => app
    },
    match win_id {
      Some(w) => js_string(Some(w))
      None => window
    },
  )
  let app_shown = match data_app {
    Some(a) => js_string(Some(a))
    None => app
  }
  let title = match or_none(jget(Some(win), "title")) {
    Some(t) => t
    None => js("")
  }
  let under = match root {
    Some(r) if r != "" => ", under \{slice(r, last_index_of(r, ":") + 1)}"
    _ => ""
  }
  let partial = if data.get("complete") is Some(Bool(false)) {
    " (not all of it: read a part with ref)"
  } else {
    ""
  }
  let head = "\{app_shown} window \{match win_id { Some(w) => js_string(Some(w)); None => "?" }} \{stringify(title)}\{under}\{partial}. Act on an element by its ref (ref: \"e12\")."
  let tree = match or_none(data.get("tree")) {
    Some(t) => t
    None => jobj([])
  }
  "\{head}\n\{said_text(self.c.b.ask("screens/ui.treeText", [tree]))}"
}

///|
/// The apps running that people use: those agent-desktop says are in the foreground, else all but the background ones.
fn apps_said(data : JV) -> String {
  let apps = jitems(data.get("apps")).filter(a => a.get("name") is Some(Str(n)) &&
    n != "")
  let foreground = apps.filter(a => a.get("presentation") is Some(Str("foreground")))
  let chosen = if foreground.length() > 0 {
    foreground
  } else {
    apps.filter(a => !(a.get("presentation") is Some(Str("background"))))
  }
  let shown : Array[String] = []
  for a in chosen {
    let n = js_string(a.get("name"))
    if !shown.contains(n) {
      shown.push(n)
    }
  }
  "Apps running (give one as app with action=tree): \{if shown.length() == 0 { "none" } else { shown.join(", ") }}"
}

///|
/// The tool. `run` gives the text alone (for a caller without images); the endpoint calls `content`.
pub fn computer_tools(computer : Computer) -> Array[Tool] {
  [
    Tool::new(
      computer.c.decl("computer"),
      (session, args, _) => {
        let r = computer.act(session, args)
        r.content
        .map(c => match c {
          Text(t) => t
          Image(_, mime) => "[\{mime} screenshot]"
        })
        .join("\n")
      },
      content=(session, args) => computer.act(session, args),
    ),
  ]
}
