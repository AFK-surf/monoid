// station/src/logins/index.ts: the station's logins to the command-line tools its agents use: each station logs in
// itself, the login landing in its own user's home and keychain (machine-wide: every chat's agent uses it); a person
// finishes it from their client, in their own browser. One way for every tool (用户定: no service supported one by
// one): the tool's own login command is run (run.mbt), and what it asks of a person is read from what it does. Only
// agents start one (用户定: nobody types a command), and the agent answers its prompts (Y/n, menus) through its `login`
// tool; a person does only the step that needs them, in their own browser. Nothing types a secret into it: a prompt
// read without echo is refused. Here: the logins under way and ended lately (their screens with them), and the record
// of those done through still.fail on this station (command, its chat, who finished it, when, how it ended:
// <data>/logins/history.json), which is all the station page lists.

///|
/// An ended login (and its screen) is kept in memory this long; its record stays in the history.
const KEPT_MS : Int = 600000

///|
/// How many ended logins are kept in memory at most.
const KEPT_MOST : Int = 20

///|
/// How many past logins the history keeps.
const HISTORY_MOST : Int = 50

///|
pub(all) struct Person {
  email : String
  name : String
}

///|
pub fn Person::to_json(self : Person) -> J {
  jo([("email", js(self.email)), ("name", js(self.name))])
}

///|
/// Who started a login: an agent (its session `chat`, its chat's title, in its chat's workspace; `by` its chat's
/// starter). One on another station of the workspace (its `login` tool's `station`): `peer`, that station and the
/// agent's session there.
pub(all) struct Starter {
  by : Person
  workspace : String?
  chat : String?
  chat_title : String?
  peer : (String, String)?
}

///|
priv struct Entry {
  run : LoginRun
  starter : Starter
  mut done_by : Person?
  screens : Listeners[(Screen) -> Unit]
}

///|
/// A file of the station's own, written whole (ops/files.ts PrivateFile): what was asked last written, one write at a
/// time.
priv struct PrivateFile {
  path : String
  mut latest : String?
  mut writing : @effect.Deferred[Unit]?
}

///|
/// What the logins ask of the station and the machine.
pub(all) struct LoginsIo {
  data : String
  /// The environment logins run in (the station's: the same home and keychain its agents use).
  env : () -> Env
  lang : () -> String
  /// A login's run's own asks (its clock is the logins' own).
  run : RunIo
  /// Where the stand-ins are made: mkdir -p.
  mkdir : async (String) -> Unit
  /// platform `makeCommandSoon(path, text)`.
  make_command : async (String, String) -> Unit
  /// writePrivateSoon: written whole (mode 0600), and its read.
  write_private : async (String, String) -> Unit
  /// The fibers' sleep.
  sleep : async (Int) -> Unit
  /// `Math.random().toString(36).slice(2, 6)`.
  random4 : () -> String
  relay : RelayIo
}

///|
pub struct Logins {
  priv io : LoginsIo
  priv pages : LoginPages?
  priv entries : Map[String, Entry]
  priv listeners : Listeners[(String) -> Unit]
  priv ended : Listeners[(J, Starter) -> Unit]
  /// The logins whose end was told (once each).
  priv ended_once : Map[String, Bool]
  /// The logins their agent's call waits on now (how many calls), told what they ask by that call's answer.
  priv heard : Map[String, Int]
  priv mut next : Int
  /// The record of logins done here, newest first: read once as it starts, written through.
  priv mut history : Array[J]
  priv history_file : PrivateFile
  /// Recorded before the file was read: written once it is, with what it kept.
  priv mut loaded : Bool
  priv ready : @effect.Deferred[Unit]
  priv timers : Array[() -> Unit]
}

///|
/// A login's tab in the station's browser (pages.mbt) is known by this.
fn page_key(id : String) -> String {
  "machine:" + id
}

///|
/// The page a login's browser step opens in the station's browser: the one its command opened, a device code's own
/// page, or the page to open; None when its step needs no browser now.
pub fn station_page(r : LoginRun) -> String? {
  if !r.active() || r.state == "verifying" {
    return None
  }
  let url = match r.step {
    Some("device") =>
      match r.code_url {
        Some(c) => Some(c)
        None => r.url
      }
    Some("loopback") | Some("open") => r.url
    _ => None
  }
  if @ops_platform.web_page(url) {
    url
  } else {
    None
  }
}

///|
/// What a Slack login card shows of a login (sessions/hub.ts `logins.page`): the page a person opens and, for a device
/// code, the code they enter there; `paste` when that page gives a code to enter back on the card. None when its step
/// cannot be taken from Slack (a loopback one, nothing to open yet) or it ended.
pub fn slack_page(login : J) -> J? {
  let l = Some(login)
  if get(l, "endedAt") is Some(_) || text(get(l, "state")) == Some("verifying") {
    return None
  }
  let step = text(get(l, "step"))
  let url = match step {
    Some("device") =>
      match get(l, "codeUrl") {
        Some(Str(_) as c) => text(Some(c))
        _ => text(get(l, "url"))
      }
    Some("open") if get(l, "paste") is Some(Bool(true)) => text(get(l, "url"))
    _ => None
  }
  if !@ops_platform.web_page(url) {
    return None
  }
  let url = url.unwrap()
  let domain = match @ops_platform.domain_of(url) {
    Some(d) => d
    None => url
  }
  if step == Some("open") {
    return Some(jo([("url", js(url)), ("domain", js(domain)), ("paste", jb(true))]))
  }
  match get(l, "code") {
    Some(Str(c)) if c.length() > 0 =>
      Some(jo([("url", js(url)), ("domain", js(domain)), ("code", Str(c)), ("paste", jb(false))]))
    _ => None
  }
}

///|
pub async fn Logins::new(given : LoginsIo, pages? : LoginPages) -> Logins {
  // Every timer of the logins' and of their runs' is the logins' own (one Fibers): called off as they close.
  let timers : Array[() -> Unit] = []
  let io = {
    ..given,
    run: {
      ..given.run,
      after: (ms, f) => {
        let stop = (given.run.after)(ms, f)
        timers.push(stop)
        stop
      },
    },
  }
  let logins : Logins = {
    io,
    pages,
    entries: {},
    listeners: Listeners::new(),
    ended: Listeners::new(),
    ended_once: {},
    heard: {},
    next: 0,
    history: [],
    history_file: { path: io.data + "/logins/history.json", latest: None, writing: None },
    loaded: false,
    ready: @effect.Deferred::new(),
    timers,
  }
  (io.run.spawn)(async fn() {
    logins.load()
    logins.ready.succeed(()) |> ignore
  })
  // Its tab came or went (a person closed it): told again.
  match pages {
    Some(p) =>
      p.changes(key => if key.has_prefix("machine:") {
        let id = key.unsafe_substring(start=8, end=key.length())
        if logins.entries.contains(id) {
          logins.tell(id)
        }
      })
      |> ignore
    None => ()
  }
  logins
}

// ── what is told ──

///|
/// Hears each login that changed (its id).
pub fn Logins::changes(self : Logins, listener : (String) -> Unit) -> () -> Unit {
  let id = self.listeners.add(listener)
  () => self.listeners.delete(id)
}

///|
/// Hears each login that ends (done, failed, cancelled), with who started it.
pub fn Logins::on_ended(self : Logins, listener : (J, Starter) -> Unit) -> () -> Unit {
  let id = self.ended.add(listener)
  () => self.ended.delete(id)
}

///|
fn Logins::tell(self : Logins, id : String) -> Unit {
  self.listeners.each(l => l(id))
}

// ── the history ──

///|
/// Once the history kept before is read (the station waits for it before it serves).
pub async fn Logins::wait_ready(self : Logins) -> Unit {
  self.ready.wait()
}

///|
/// Once what was recorded is written down (or failed).
pub async fn Logins::written(self : Logins) -> Unit {
  self.ready.wait()
  match self.history_file.writing {
    Some(d) => d.wait()
    None => ()
  }
}

///|
async fn Logins::load(self : Logins) -> Unit {
  let mut kept : Array[J] = []
  let read = try {
    let text = (self.io.run.read_file)(self.history_file.path)
    Some(parse(text))
  } catch {
    _ => None
  }
  match read {
    Some(Arr(items)) =>
      kept = items.filter(l => get(Some(l), "id") is Some(Str(_)))
    _ => ()
  }
  let recorded = self.history.map(l => text(get(Some(l), "id")).unwrap_or(""))
  let merged = self.history.copy()
  for l in kept {
    if !recorded.contains(text(get(Some(l), "id")).unwrap_or("")) {
      merged.push(l)
    }
  }
  self.history = merged[:@cmp.minimum(merged.length(), HISTORY_MOST)].to_array()
  self.loaded = true
  if recorded.length() > 0 {
    self.write_history()
  }
}

///|
/// The logins done through still.fail on this station, newest first: how each ended, no page, code or output. Each
/// named by its command, as one under way is.
pub fn Logins::history(self : Logins) -> Array[J] {
  self.history.map(l => match get(Some(l), "command") {
    Some(Arr(words)) => set_key(l, "name", js(@ops_platform.program_of(words.map(w => js_string_of(w)))))
    _ => l
  })
}

///|
/// `{ ...o, [k]: v }`: in its place where `o` has it, else last.
fn set_key(o : J, k : String, v : J) -> J {
  let u = k
  match o {
    Obj(ps) => {
      let out = ps.copy()
      match out.search_by(p => p.0 == u) {
        Some(i) => out[i] = (u, v)
        None => out.push((u, v))
      }
      Obj(out)
    }
    _ => Obj([(u, v)])
  }
}

///|
fn Logins::record(self : Logins, login : J) -> Unit {
  let l = Some(login)
  let ps : Array[(String, J)] = [
    ("id", or_null(get(l, "id"))),
    ("name", or_null(get(l, "name"))),
    ("command", or_null(get(l, "command"))),
    ("state", or_null(get(l, "state"))),
    ("waiting", jb(false)),
    ("by", or_null(get(l, "by"))),
  ]
  for k in ["workspace", "chat", "chatTitle", "doneBy"] {
    match get(l, k) {
      Some(v) => ps.push((k, v))
      None => ()
    }
  }
  ps.push(("startedAt", or_null(get(l, "startedAt"))))
  ps.push(("expiresAt", or_null(get(l, "expiresAt"))))
  match get(l, "endedAt") {
    Some(v) => ps.push(("endedAt", v))
    None => ()
  }
  if get(l, "timedOut") is Some(Bool(true)) {
    ps.push(("timedOut", jb(true)))
  }
  let kept = jo(ps)
  let id = text(get(l, "id"))
  let rest = self.history.filter(h => text(get(Some(h), "id")) != id)
  let all = [kept]
  all.append(rest)
  self.history = all[:@cmp.minimum(all.length(), HISTORY_MOST)].to_array()
  if self.loaded {
    self.write_history()
  }
}

///|
fn Logins::write_history(self : Logins) -> Unit {
  let f = self.history_file
  f.latest = Some(pretty(ja(self.history)) + "\n")
  if f.writing is Some(_) {
    return
  }
  let writing : @effect.Deferred[Unit] = @effect.Deferred::new()
  f.writing = Some(writing)
  (self.io.run.spawn)(async fn() {
    try {
      while f.latest is Some(data) {
        f.latest = None
        (self.io.write_private)(f.path, data)
      }
    } catch {
      e => {
        f.latest = None
        (self.io.run.log)("a login was not recorded", jo([("error", js(error_message(e)))]))
      }
    }
    f.writing = None
    writing.succeed(()) |> ignore
  })
}

// ── logins ──

///|
/// Those under way, then those ended: kept in memory as they are (with their pages and outcome), then the history's.
pub fn Logins::logins(self : Logins) -> Array[J] {
  self.sweep()
  let all = self.entries.values().collect()
  let live = all.filter(e => e.run.active()).map(e => self.shown(e))
  let ended = all.filter(e => !e.run.active())
  ended.rev_in_place()
  live.append(ended.map(e => self.shown(e)))
  for h in self.history() {
    match text(get(Some(h), "id")) {
      Some(id) if self.entries.contains(id) => ()
      _ => live.push(h)
    }
  }
  live
}

///|
/// Who started a login under way or ended lately (None: none such, or put away).
pub fn Logins::starter_of(self : Logins, id : String) -> Starter? {
  self.entries.get(id).map(e => e.starter)
}

///|
pub fn Logins::get(self : Logins, id : String) -> J? {
  self.sweep()
  match self.entries.get(id) {
    Some(e) => Some(self.shown(e))
    None =>
      for h in self.history() {
        if text(get(Some(h), "id")) == Some(id) {
          break Some(h)
        }
      } nobreak {
        None
      }
  }
}

///|
/// The words of a command the agent gave: a line split as a shell would, or its words (None: no command).
fn words_of(command : J) -> Array[String]? {
  match command {
    Str(u) => @ops_platform.command_words(u)
    Arr(items) => {
      let out = []
      for w in items {
        match w {
          Str(u) if u.length() > 0 => out.push(u)
          _ => return None
        }
      }
      Some(out)
    }
    _ => None
  }
}

///|
fn Logins::running(self : Logins, words : Array[String]) -> Entry? {
  let key = words.join("\u{0}")
  for _, e in self.entries {
    if e.run.active() && e.run.command.join("\u{0}") == key {
      return Some(e)
    }
  }
  None
}

///|
/// `n.toString(36)` of a whole number.
fn base36(n : Double) -> String {
  if n <= 0.0 {
    return "0"
  }
  let digits = "0123456789abcdefghijklmnopqrstuvwxyz"
  let out : Array[Char] = []
  let mut v = n.floor()
  while v >= 1.0 {
    let d = (v - (v / 36.0).floor() * 36.0).to_int()
    out.push(digits.get_char(d).unwrap())
    v = (v / 36.0).floor()
  }
  out.rev_in_place()
  String::from_array(out)
}

///|
/// A login started: a command (words, or a line split as a shell would). One under way for the same command is given
/// rather than another. Raises Refused when it cannot be.
pub async fn Logins::start(self : Logins, command : J, starter : Starter) -> J {
  let lang = (self.io.lang)()
  let words = match words_of(command) {
    Some(w) if w.length() > 0 && !w.contains("") && w.join(" ").length() <= 2000 => w
    _ => raise Refused(400, (self.io.run.tr)(lang, "station.machineLogin.badCommand", {}))
  }
  match self.running(words) {
    Some(e) => return self.shown(e)
    None => ()
  }
  self.next += 1
  let id = base36((self.io.run.now)()) + base36(self.next.to_double()) + (self.io.random4)()
  let dir = self.io.data + "/run/logins"
  let shims = self.shims()
  (self.io.mkdir)(dir)
  // (one started meanwhile for the same command is given rather than another)
  match self.running(words) {
    Some(e) => return self.shown(e)
    None => ()
  }
  let env = (self.io.env)()
  let holder : Ref[Entry?] = Ref(None)
  let run = LoginRun::new(
    {
      id,
      command: words,
      env,
      cwd: match (self.io.run.home)(env) {
        Some(h) => h
        None => self.io.data
      },
      shims,
      opened: dir + "/" + id + ".opened",
      lang,
      changed: () => match holder.val {
        Some(entry) => {
          if !entry.run.active() {
            self.ended_now(entry)
          }
          self.tell(id)
        }
        None => ()
      },
      drawn: () => match holder.val {
        Some(entry) => {
          let screen = entry.run.screen()
          entry.screens.each(s => s(screen))
        }
        None => ()
      },
    },
    self.io.run,
  )
  let entry : Entry = { starter, screens: Listeners::new(), run, done_by: None }
  holder.val = Some(entry)
  self.entries[id] = entry
  run.start()
  self.shown(entry)
}

///|
fn Logins::ended_now(self : Logins, entry : Entry) -> Unit {
  let id = entry.run.id
  if self.ended_once.contains(id) {
    return
  }
  self.ended_once[id] = true
  match self.pages {
    Some(p) => p.close(page_key(id))
    None => ()
  }
  let shown = self.shown(entry)
  self.record(shown)
  self.ended.each(l => l(shown, entry.starter))
  // Let go of a while after (its screen with it): its record stays.
  (self.io.run.after)(KEPT_MS, () => match self.entries.get(id) {
    Some(e) if !e.run.active() => {
      e.run.close()
      self.entries.remove(id)
      self.ended_once.remove(id)
    }
    _ => ()
  })
  |> ignore
}

///|
/// Ended logins past what is kept: the oldest go.
fn Logins::sweep(self : Logins) -> Unit {
  let ended = self.entries.values().filter(e => !e.run.active()).collect()
  let n = @cmp.maximum(0, ended.length() - KEPT_MOST)
  for k in 0..<n {
    ended[k].run.close()
    self.entries.remove(ended[k].run.id)
  }
}

///|
fn Logins::entry(self : Logins, id : String) -> Entry raise Refused {
  match self.entries.get(id) {
    Some(e) => e
    None => raise Refused(404, self.words("station.machineLogin.unknown"))
  }
}

///|
fn Logins::words(self : Logins, key : String, args? : Map[String, String] = {}) -> String {
  (self.io.run.tr)((self.io.lang)(), key, args)
}

///|
/// Cancelled: by a person (`by`, from their client), or by its agent.
pub fn Logins::cancel(self : Logins, id : String, by? : Person) -> J raise Refused {
  let e = self.entry(id)
  if e.run.active() && by is Some(_) {
    e.done_by = by
  }
  e.run.cancel()
  self.shown(e)
}

///|
/// Typed into its terminal by its agent (its `login` tool): `text`, or `key`. Never into a prompt that reads without
/// echo: a secret is nobody's to type here.
pub fn Logins::input(self : Logins, id : String, text? : J, key? : J) -> Unit raise Refused {
  let e = self.entry(id)
  if !e.run.active() {
    raise Refused(409, self.words("station.machineLogin.ended"))
  }
  if e.run.secret() {
    raise Refused(
      409,
      "this command asks for a secret (a password or token, read without echo): nothing is typed into it here. Use the tool's browser or device-code login instead (gh auth login --web, az login --use-device-code…), or tell the person this tool cannot be logged in this way",
    )
  }
  match (key, text) {
    (Some(Str(k)), _) => {
      let name = k
      if key_code(name) is None {
        raise Refused(400, "key: one of " + keys.map(k => k.0).join(", "))
      }
      e.run.input(key=name)
    }
    (_, Some(Str(t))) => {
      if t.length() > 10000 {
        raise Refused(413, "too much text")
      }
      e.run.input(text=t)
    }
    _ => raise Refused(400, "text or key")
  }
}

///|
fn has_line_break(s : String) -> Bool {
  s.contains("\r") || s.contains("\n")
}

///|
/// What its page gave (a code), entered by the person `by` from their card, and Enter: only while it waits for one.
pub fn Logins::answer(self : Logins, id : String, given : J?, by? : Person) -> J raise Refused {
  let e = self.entry(id)
  if !e.run.active() {
    raise Refused(409, self.words("station.machineLogin.ended"))
  }
  if !e.run.paste {
    raise Refused(409, "this login does not wait for a code from its page")
  }
  if e.run.state == "verifying" {
    raise Refused(409, "its code was entered: it is being checked")
  }
  let t = match given {
    Some(Str(u)) if @jscase.trim(u) != "" => u
    _ => raise Refused(400, "text")
  }
  if t.length() > 10000 || has_line_break(@jscase.trim(t)) {
    raise Refused(400, "one line of text")
  }
  e.run.input(text=@jscase.trim(t))
  e.run.input(key="Enter")
  e.run.answered_now()
  if by is Some(_) {
    e.done_by = by
  }
  self.shown(e)
}

///|
/// Its agent says it waits for what its page gives (a code to paste back), entered by the person on their card; or
/// that it no longer does. Only once it has given a page to open, and never at a prompt that reads a secret.
pub fn Logins::paste(self : Logins, id : String, on : Bool) -> J raise Refused {
  let e = self.entry(id)
  if !e.run.active() {
    raise Refused(409, self.words("station.machineLogin.ended"))
  }
  if !e.run.ask_paste(on) {
    raise Refused(
      409,
      if e.run.secret() {
        "it waits on a prompt read without echo (a password or token): nobody enters a secret here"
      } else {
        "paste: only once it has given a page to open, with no device code or loopback (step open): the person opens it and enters what it gives"
      },
    )
  }
  self.shown(e)
}

///|
/// Waits until the command has gone quiet (what it waits on is known), it ended, or `ms` passed.
pub async fn Logins::settle(self : Logins, id : String, ms : Int) -> J? {
  let waits = self.settle_start(id)
  self.settle_finish(id, waits, ms)
}

///|
/// Runs `f` on by itself (the logins' fibers).
pub fn Logins::spawn(self : Logins, f : async () -> Unit) -> Unit {
  (self.io.run.spawn)(f)
}

///|
/// What `settle` sets going before it waits (its call counted as heard, the next quiet asked for).
pub fn Logins::settle_start(self : Logins, id : String) -> @effect.Deferred[Unit]? {
  match self.entries.get(id) {
    Some(e) => {
      self.heard[id] = self.heard.get(id).unwrap_or(0) + 1
      Some(e.run.next_quiet())
    }
    None => None
  }
}

///|
/// The rest of `settle`.
pub async fn Logins::settle_finish(
  self : Logins,
  id : String,
  waits : @effect.Deferred[Unit]?,
  ms : Int,
) -> J? {
  match waits {
    Some(quiet) => {
      @effect.race(async fn() { quiet.wait() }, async fn() { (self.io.sleep)(ms) }) catch {
        _ => ()
      }
      let n = self.heard.get(id).unwrap_or(1) - 1
      if n > 0 {
        self.heard[id] = n
      } else {
        self.heard.remove(id)
      }
    }
    None => ()
  }
  self.get(id)
}

///|
/// Whether its agent's call waits on it now (settle): what it asks is told in that call's answer, not a notice.
pub fn Logins::heard(self : Logins, id : String) -> Bool {
  self.heard.contains(id)
}

///|
/// Its page opened in the station's browser for the person `by` (who goes on to finish it there): the screen of its
/// tab, the one open already if there is one.
pub async fn Logins::open_page(self : Logins, id : String, by? : Person) -> String {
  let e = self.entry(id)
  if !e.run.active() {
    raise Refused(409, self.words("station.machineLogin.ended"))
  }
  guard self.pages is Some(pages) && pages.can() else {
    raise Refused(501, self.words("station.loginPage.noBrowser"))
  }
  let url = station_page(e.run)
  let open = pages.screen_of(page_key(id))
  if url is None && open is None {
    raise Refused(409, self.words("station.loginPage.nothing"))
  }
  let screen = pages.open(page_key(id), url.unwrap_or("about:blank")) catch {
    error => raise Refused(502, self.words("station.loginPage.failed", args={ "error": error_message(error) }))
  }
  // Ended meanwhile: its tab goes too.
  if !e.run.active() {
    pages.close(page_key(id))
    raise Refused(409, self.words("station.machineLogin.ended"))
  }
  if by is Some(_) {
    e.done_by = by
  }
  screen
}

///|
/// Its screen as its agent reads it.
pub fn Logins::screen(self : Logins, id : String) -> Screen? {
  self.entries.get(id).map(e => e.run.screen())
}

///|
/// Whether it has asked a person for a browser step at some point.
pub fn Logins::had_browser_step(self : Logins, id : String) -> Bool {
  match self.entries.get(id) {
    Some(e) => e.run.had_browser_step
    None => false
  }
}

///|
/// The browser's callback, from the client of the person `by`, relayed to the command.
pub async fn Logins::callback(self : Logins, id : String, callback : Callback, by? : Person) -> Answered {
  let e = self.entry(id)
  let answered = relay(e.run, self.io.relay, callback)
  if by is Some(_) {
    e.done_by = by
  }
  answered
}

///|
/// Its terminal: now, and each time it changes, until the returned function is called.
pub fn Logins::follow(self : Logins, id : String, send : (Screen) -> Unit) -> () -> Unit {
  guard self.entries.get(id) is Some(e) else { return () => () }
  let k = e.screens.add(send)
  send(e.run.screen())
  () => e.screens.delete(k)
}

///|
/// A login as clients have it (`limited`: as a read-only member may see it).
fn Logins::shown(self : Logins, e : Entry) -> J {
  let r = e.run
  let ps : Array[(String, J)] = [
    ("id", js(r.id)),
    ("name", js(@ops_platform.program_of(r.command))),
    ("command", jstrs(r.command)),
    ("state", js(r.state)),
  ]
  match r.step {
    Some(s) if s != "" => ps.push(("step", js(s)))
    _ => ()
  }
  ps.push(("waiting", jb(r.waiting)))
  if r.paste {
    ps.push(("paste", jb(true)))
  }
  ps.push(("by", e.starter.by.to_json()))
  for kv in [("workspace", e.starter.workspace), ("chat", e.starter.chat), ("chatTitle", e.starter.chat_title)] {
    match kv.1 {
      Some(v) if v != "" => ps.push((kv.0, js(v)))
      _ => ()
    }
  }
  match e.done_by {
    Some(p) => ps.push(("doneBy", p.to_json()))
    None => ()
  }
  ps.push(("startedAt", jn(r.started_at)))
  ps.push(("expiresAt", jn(r.expires_at)))
  match r.ended_at {
    Some(t) => ps.push(("endedAt", jn(t)))
    None => ()
  }
  if r.timed_out {
    ps.push(("timedOut", jb(true)))
  }
  match r.url {
    Some(u) if u != "" => {
      match @ops_platform.domain_of(u) {
        Some(d) if d != "" => ps.push(("domain", js(d)))
        _ => ()
      }
      ps.push(("url", js(u)))
    }
    _ => ()
  }
  match r.loopback {
    Some(l) => ps.push(("callback", loopback_json(l)))
    None => ()
  }
  match r.code {
    Some(c) if c != "" => ps.push(("code", js(c)))
    _ => ()
  }
  match r.code_url {
    Some(c) if c != "" => ps.push(("codeUrl", js(c)))
    _ => ()
  }
  match r.error {
    Some(c) if c != "" => ps.push(("error", js(c)))
    _ => ()
  }
  match self.pages {
    Some(pages) if r.active() => {
      let screen = pages.screen_of(page_key(r.id))
      match screen {
        Some(s) => ps.push(("screen", js(s)))
        None => ()
      }
      if (screen is Some(_) || station_page(r) is Some(_)) && pages.can() {
        ps.push(("browser", jb(true)))
      }
    }
    _ => ()
  }
  jo(ps)
}

///|
/// A login as a read-only member may see it.
pub fn limited(login : J) -> J {
  let drop = ["url", "callback", "code", "codeUrl", "error", "browser", "screen"]
  match login {
    Obj(ps) => Obj(ps.filter(p => !drop.contains(p.0)))
    other => other
  }
}

///|
/// The stand-ins for the browser (`browser` for BROWSER; `open`, `xdg-open` and `osascript` first on the command's
/// PATH): each writes the pages it is given to the file the login names, and does nothing else.
async fn Logins::shims(self : Logins) -> String {
  let dir = self.io.data + "/run/login-shims"
  (self.io.mkdir)(dir)
  let pages = "#!/bin/sh\n# A browser for a login command run by still.fail (station/src/logins): the page goes to the station.\n[ -n \"$STILLFAIL_LOGIN_OPENED\" ] || exit 0\nfor a in \"$@\"; do printf '%s\\n' \"$a\" >> \"$STILLFAIL_LOGIN_OPENED\"; done\nexit 0\n"
  // Python's opener before 3.14 says `open location "…"` on osascript's stdin.
  let osascript = "#!/bin/sh\n# osascript for a login command run by still.fail (station/src/logins): the page goes to the station.\n[ -n \"$STILLFAIL_LOGIN_OPENED\" ] || exit 0\nprintf '%s\\n' \"$*\" >> \"$STILLFAIL_LOGIN_OPENED\"\n[ -t 0 ] || cat >> \"$STILLFAIL_LOGIN_OPENED\"\nexit 0\n"
  // (each left alone where it is as it is to be: makeCommandSoon)
  for p in [("browser", pages), ("open", pages), ("xdg-open", pages), ("osascript", osascript)] {
    (self.io.make_command)(dir + "/" + p.0, p.1)
  }
  dir
}

///|
/// Every login ended (the station stopping: they end with it).
pub async fn Logins::close(self : Logins) -> Unit {
  for _, e in self.entries {
    e.run.close()
  }
  self.entries.clear()
  for t in self.timers.copy() {
    t()
  }
  self.timers.clear()
  self.written()
}

///|
/// What the login commands do not take from the station's environment: what would point a runtime elsewhere, and the
/// station's own.
pub let scrubbed : Array[String] = [
  "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "STILLFAIL_MESH_NATIVE", "STILLFAIL_RUNNER",
  "SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY",
]
