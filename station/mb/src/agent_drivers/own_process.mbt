// own-process.ts: a runtime that runs each session in a process of its own (Claude Code, the ACP runtimes): the
// sessions a driver has, starting a process and taking one up, its lines held while the station hands over, its
// requests waiting for their answers, what the program tells of it, the process going away (a turn running fails as
// exited, then the session closes), letting it go. What a runtime is told and says is each driver's (its hooks).

///|
/// How long a runtime has to answer a request of ours.
let answer_ms = 120000.0

///|
/// A session's requests waiting for their answers, by the id each was sent with (`Waiting`).
pub struct Waiting {
  lp : Loop
  waits : Array[(String, (JValue) -> Unit, (Error) -> Unit)]
}

///|
pub fn Waiting::new(lp : Loop) -> Waiting {
  { lp, waits: [] }
}

///|
/// The answer to request `id`: one `refused` makes an error of rejects, and so does none within `ms`.
pub fn Waiting::wait(
  self : Waiting,
  id : String,
  refused : (JValue) -> Error?,
  late? : String,
  ms? : Double = answer_ms,
) -> Later[JValue] {
  let out = Later::new(self.lp)
  let seconds = ms / 1000.0
  let said = if seconds == seconds.floor() {
    seconds.to_int64().to_string()
  } else {
    seconds.to_string()
  }
  let cancel = self.lp.after(ms, () => self.fail(id, Failed(late.unwrap_or("no answer to \{id} in \{said} s"))))
  ignore(self.drop(id))
  self.waits.push((
    id,
    answer => {
      cancel()
      match refused(answer) {
        None => out.resolve(answer)
        Some(e) => out.reject(e)
      }
    },
    e => {
      cancel()
      out.reject(e)
    },
  ))
  out
}

///|
pub fn Waiting::drop(self : Waiting, id : String) -> ((JValue) -> Unit, (Error) -> Unit)? {
  match self.waits.search_by(w => w.0 == id) {
    Some(i) => {
      let w = self.waits.remove(i)
      Some((w.1, w.2))
    }
    None => None
  }
}

///|
/// An answer came: whether it was waited for.
pub fn Waiting::answer(self : Waiting, id : JValue?, answer : JValue) -> Bool {
  guard str_of(id) is Some(key) else { return false }
  match self.drop(key) {
    Some((answered, _)) => {
      answered(answer)
      true
    }
    None => false
  }
}

///|
pub fn Waiting::fail(self : Waiting, id : String, e : Error) -> Unit {
  match self.drop(id) {
    Some((_, failed)) => failed(e)
    None => ()
  }
}

///|
pub fn Waiting::fail_all(self : Waiting, e : Error) -> Unit {
  let waits = self.waits.copy()
  self.waits.clear()
  for w in waits {
    (w.2)(e)
  }
}

///|
/// What a driver's session does its own way (`OwnProcessSession`'s abstract parts and hooks).
pub struct OwnHooks {
  /// a line the program gives Node to read: an answer to a request of ours, or a request of the runtime's
  heard : (String) -> Unit
  /// an event the program said for the session's owner itself (true: taken here)
  took : (JValue) -> Bool
  /// what is being written of it on the disk, done (none: nothing is)
  settled : () -> Later[Unit]?
  /// its process went away during a turn
  cut_short : (String) -> Unit
  /// the program attached to its process (again)
  attached : () -> Unit
}

///|
/// A session of a runtime in a process of its own (`OwnProcessSession`): its turn as the JSON a snapshot says.
pub struct OwnSession {
  lp : Loop
  kind : String
  mut proc : Proc?
  mut session_id : String
  /// busy, aborting, closed and each runtime's own
  mut turn : JValue
  mut live_state : JValue
  events : (JValue) -> Unit
  waiting : Waiting
  mut tools_url : String?
  mut hooks : OwnHooks
  /// the driver lets go of it (`forget`)
  mut forget : () -> Unit
}

///|
pub fn no_hooks() -> OwnHooks {
  { heard: _ => (), took: _ => false, settled: () => None, cut_short: _ => (), attached: () => () }
}

///|
pub fn OwnSession::new(
  lp : Loop,
  kind : String,
  session_id : String,
  turn : JValue,
  events : (JValue) -> Unit,
  live? : JValue = Null,
) -> OwnSession {
  {
    lp,
    kind,
    proc: None,
    session_id,
    turn,
    live_state: live,
    events,
    waiting: Waiting::new(lp),
    tools_url: None,
    hooks: no_hooks(),
    forget: () => (),
  }
}

///|
pub fn OwnSession::flag(self : OwnSession, name : String) -> Bool {
  is_true(Some(self.turn), name)
}

///|
pub fn OwnSession::set_flag(self : OwnSession, name : String, v : JValue) -> Unit {
  self.turn = set(self.turn, name, v)
}

///|
pub fn OwnSession::busy(self : OwnSession) -> Bool {
  self.flag("busy")
}

///|
pub fn OwnSession::closed(self : OwnSession) -> Bool {
  self.flag("closed")
}

///|
pub fn OwnSession::p(self : OwnSession) -> Proc {
  self.proc.unwrap()
}

///|
/// The turn as the program is told it (`turnNow`): without `closed`.
pub fn OwnSession::turn_now(self : OwnSession) -> JValue {
  del(self.turn, "closed")
}

///|
/// The turn as the program says it (`take`), `closed` kept as it is here.
pub fn OwnSession::take(self : OwnSession, t : JValue?) -> Unit {
  guard t is Some(Obj(_) as turn) else { return }
  let closed = get(Some(self.turn), "closed").unwrap_or(Bool(false))
  self.turn = spread([turn, obj([("closed", closed)])])
}

///|
pub fn OwnSession::settled(self : OwnSession) -> Later[Unit]? {
  (self.hooks.settled)()
}

///|
/// What the program read of its lines (`heardHosted`): the lines it gives here, then its events in order, each turn's
/// end once what is written of the turn is.
pub fn OwnSession::heard_hosted(self : OwnSession, heard : Heard) -> HeardSaid {
  for line in heard.lines() {
    (self.hooks.heard)(line)
  }
  match self.told(heard, 0) {
    Some(writing) => Writing(writing)
    None => Took(false)
  }
}

///|
/// Its events from `from` on (`told`): none where all were told at once.
pub fn OwnSession::told(self : OwnSession, heard : Heard, from : Int) -> Later[Unit]? {
  let events = heard.events()
  for i in from..<events.length() {
    let e = events[i]
    if str_at(Some(e), "type") == Some("turnEnded") {
      match self.settled() {
        Some(writing) =>
          return Some(
            writing.bind(_ => {
              self.event(heard, e)
              match self.told(heard, i + 1) {
                Some(rest) => rest
                None => done(self.lp)
              }
            }),
          )
        None => ()
      }
    }
    self.event(heard, e)
  }
  self.take(heard.turn())
  self.settled()
}

///|
pub fn OwnSession::event(self : OwnSession, heard : Heard, e : JValue) -> Unit {
  if (self.hooks.took)(e) {
    return
  }
  let turn = get(Some(e), "turn")
  let mut event = del(e, "turn")
  if turn is Some(_) {
    self.take(turn)
  }
  if heard.routed() {
    event = set(event, "routed", Bool(true))
  }
  (self.events)(event)
}

///|
/// Its process went away (`exited`): a turn running fails as exited, then the session closes.
pub fn OwnSession::exited(self : OwnSession, said : String, stderr : String) -> Later[Unit] {
  let why = if stderr == "" { "" } else { ": \{stderr}" }
  self.set_flag("closed", Bool(true))
  self.waiting.fail_all(Failed("\{self.kind} exited (\{said})\{why}"))
  let busy = self.busy()
  self.set_flag("busy", Bool(false))
  if busy {
    (self.hooks.cut_short)(said)
  }
  let told = () => {
    if busy {
      (self.events)(
        obj([
          ("type", s("turnEnded")),
          (
            "outcome",
            obj([
              ("kind", s("failed")),
              ("reason", s("exited")),
              ("message", s("\{self.kind} exited (\{said}) during the turn\{why}")),
            ]),
          ),
        ]),
      )
    }
    (self.events)(obj([("type", s("closed")), ("why", s("\{self.kind} exited (\{said})\{why}"))]))
    (self.forget)()
  }
  match self.settled() {
    Some(w) => w.map(_ => told())
    None => {
      told()
      done(self.lp)
    }
  }
}

///|
/// A turn can be started now: else why not (`startable`).
pub fn OwnSession::startable(self : OwnSession) -> Unit raise {
  if self.closed() {
    raise Failed("\{self.kind} session is closed")
  }
  if self.busy() {
    raise Failed("a turn is already running")
  }
}

///|
/// Stops hearing it, for a snapshot (`handOver`): where it stood then as the program said it.
pub fn OwnSession::hand_over(self : OwnSession) -> (JValue, JValue)? {
  (self.p().freeze)()
  self.set_flag("closed", Bool(true))
  (self.p().frozen_state)()
}

///|
/// What its process's lines are read with (`hostedOptions`).
pub fn OwnSession::hosted_options(
  self : OwnSession,
  label : String,
  kind : String,
  flavor? : String,
  kept? : Bool = false,
) -> HostedOptions {
  {
    label,
    kind,
    flavor,
    kept,
    orphans: false,
    heard: h => self.heard_hosted(h),
    attached: () => (self.hooks.attached)(),
    handed: () => (),
    exit: (said, stderr) => self.exited(said, stderr),
  }
}

///|
/// The session closed and let go (`dispose`): its process ended.
pub fn OwnSession::dispose(self : OwnSession) -> Later[Unit] {
  (self.forget)()
  self.set_flag("closed", Bool(true))
  self.waiting.fail_all(Failed("\{self.kind} session is closed"))
  (self.p().kill)(5000.0).bind(_ => match self.settled() {
    Some(w) => w
    None => done(self.lp)
  })
}

///|
/// Let go of without ending its process (`detach`).
pub fn OwnSession::detach(self : OwnSession) -> Unit {
  self.set_flag("closed", Bool(true))
  (self.forget)()
  (self.p().detach)()
}

///|
pub fn OwnSession::runner(self : OwnSession) -> String? {
  self.proc.map(p => p.info.id())
}

///|
/// What every driver of processes of their own does (`OwnProcessDriver`): its sessions, the runners it is starting or
/// taking up, starting one and taking one up.
pub struct OwnDriver {
  m : Machine
  data : String
  procs : Procs
  kind : String
  live : Array[OwnSession]
  claimed : Array[String]
}

///|
pub fn OwnDriver::new(m : Machine, data : String, procs : Procs, kind : String) -> OwnDriver {
  { m, data, procs, kind, live: [], claimed: [] }
}

///|
pub fn OwnDriver::forget(self : OwnDriver, session : OwnSession) -> Unit {
  match self.live.search_by(x => physical_equal(x, session)) {
    Some(i) => self.live.remove(i) |> ignore
    None => ()
  }
}

///|
pub fn OwnDriver::add(self : OwnDriver, session : OwnSession) -> Unit {
  if !self.live.iter().any(x => physical_equal(x, session)) {
    self.live.push(session)
  }
  session.forget = () => self.forget(session)
}

///|
/// The runner `id` is this driver's while `work` starts or takes up its process (`claiming`).
pub fn[T] OwnDriver::claiming(self : OwnDriver, id : String, work : () -> Later[T]) -> Later[T] {
  self.claimed.push(id)
  work().always(() => match self.claimed.search(id) {
    Some(i) => self.claimed.remove(i) |> ignore
    None => ()
  })
}

///|
/// The runners of the processes it holds now (`ownedRunners`), in the order they came.
pub fn OwnDriver::owned_runners(self : OwnDriver) -> Array[String] {
  let owned = self.claimed.copy()
  for session in self.live {
    match session.runner() {
      Some(id) if !owned.contains(id) => owned.push(id)
      _ => ()
    }
  }
  owned
}

///|
/// Starts the process of a session being opened (`start`).
pub fn OwnDriver::start(
  self : OwnDriver,
  session : OwnSession,
  key : String,
  cwd : String,
  command : String,
  args : Array[String],
  env : Env,
  options : HostedOptions,
) -> Later[Unit] {
  let id = runner_id(self.kind, key)
  self.claiming(id, () => (self.procs.start)(
      id,
      command,
      args,
      env,
      cwd,
      options,
      session.turn_now(),
    ).map(p => {
      session.proc = Some(p)
      self.add(session)
    }))
}

///|
/// What a driver's taking up asks of its runtime (`handedOver`, `crashed`, `hosting`, `replaying`).
pub struct Adopting {
  handed_over : (JValue, RunnerInfo) -> OwnSession
  crashed : (JValue, RunnerInfo) -> Later[OwnSession]
  hosting_kind : String
  flavor : String?
  kept : Bool
  replaying : JValue
  label : (OwnSession) -> String
  options_of : (OwnSession, String) -> HostedOptions
  adopted : (OwnSession) -> Later[Unit]
}

///|
/// Takes up a session whose process a runner kept (`adopt`): handed over with a snapshot, or after a crash.
pub fn OwnDriver::adopt(
  self : OwnDriver,
  key : String,
  snapshot : JValue?,
  events : (JValue) -> Unit,
  how : Adopting,
) -> Later[OwnSession] {
  let handed = match snapshot {
    Some(Obj(_) as j) => Some(j)
    _ => None
  }
  let id = match str_at(handed, "runner") {
    Some(r) => r
    None => runner_id(self.kind, key)
  }
  self.claiming(id, () => find_runner(self.m, self.data, id).bind(found => {
    guard found is Some(info) else {
      return Later::fail(self.m.lp, Failed("no runner keeps \{self.kind} for \{key}"))
    }
    let made = match handed {
      Some(h) => {
        self.m.log(
          "info",
          "agents::\{self.kind}",
          "taking up a \{self.kind} process handed over",
          obj([
            ("session", get(handed, "id").unwrap_or(Null)),
            ("pgid", n(info.pgid())),
            ("busy", b(is_true(get(handed, "turn"), "busy"))),
          ]),
        )
        Later::ok(self.m.lp, (how.handed_over)(h, info))
      }
      None => {
        let out = out_file(self.m, self.data, id)
        acked_offset(self.m, info, out).bind(offset => {
          let extra = match how.flavor {
            Some(f) =>
              spread([how.replaying, obj([("flavor", s(f)), ("kept", b(how.kept))])])
            None => how.replaying
          }
          (self.procs.replay_own)(how.hosting_kind, out, offset.0, extra)
          .bind(replayed => (how.crashed)(replayed, info))
          .bind(session => {
            // (one whose station went before its session was open is refused before it is held: own-process.ts
            // `adoptOn`)
            if (how.hosting_kind != "pi" && session.session_id == "") ||
              (how.hosting_kind != "claude" && offset.0 == 0) {
              return Later::fail(
                self.m.lp,
                Failed("\{self.kind} process for \{key} had not opened a session"),
              )
            }
            self.m.log(
              "info",
              "agents::\{self.kind}",
              "taking up a \{self.kind} process after a crash",
              obj([
                ("session", s(session.session_id)),
                ("pgid", n(info.pgid())),
                ("busy", b(session.busy())),
                ("from", n(offset.0)),
              ]),
            )
            if session.busy() {
              events(obj([("type", s("turnStarted"))]))
            }
            Later::ok(self.m.lp, session)
          })
        })
      }
    }
    made.bind(session => {
      session.proc = Some(
        (self.procs.adopt)(
          info,
          (how.options_of)(session, (how.label)(session)),
          session.turn_now(),
          session.live_state,
        ),
      )
      (how.adopted)(session).map(_ => {
        self.add(session)
        session
      })
    })
  }))
}

///|
pub fn OwnDriver::hosted(self : OwnDriver) -> Array[Proc] {
  self.live.filter_map(x => x.proc)
}

///|
/// Its processes' lines held while the station hands over (`freeze`).
pub fn OwnDriver::freeze(self : OwnDriver) -> Later[Unit] {
  (self.procs.freeze)(self.hosted())
}

///|
pub fn OwnDriver::thaw(self : OwnDriver) -> Unit {
  (self.procs.thaw)(self.hosted())
}

///|
/// Ends every process it started (`shutdown`).
pub fn OwnDriver::shutdown(self : OwnDriver, again? : Bool = false) -> Later[Unit] {
  let live = self.live.copy()
  self.live.clear()
  all(self.m.lp, live.map(x => x.dispose())).bind(_ => if again {
    done(self.m.lp)
  } else {
    (self.procs.close)()
  })
}

///|
/// Lets go of every process without ending them (`detach`).
pub fn OwnDriver::detach(self : OwnDriver) -> Unit {
  for session in self.live.copy() {
    session.detach()
  }
  self.live.clear()
}

///|
/// The address of the station's tools it was given (`mcpUrl`), as the driver that opened it says it.
pub fn OwnSession::set_tools_url(self : OwnSession, url : String?) -> Unit {
  self.tools_url = url
}
