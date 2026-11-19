// sessions/live-locator.ts and read/transcript.ts's hints: where a session's transcripts are, for the live view and its
// storage (`live.locate`), looked for off this program's loop by the program's own locator (`stillfail-reader --builder
// live-locator`, station/mb/src/locate) a batch of runtime sessions at a time; the hints of where a transcript was
// found (a Claude transcript elsewhere than its project's directory, a Codex rollout's path, the rollout a running thread
// said) kept here, given each batch and taken back from it where they still are what it was given. The locator let go
// after IDLE_MS idle, its lookups started again (RESTARTS at most) where the session or the profiles changed meanwhile.

///|
/// The rollout a running Codex thread said (transcript.ts `SaidRollout`): one kept is the same object while it stands.
priv struct SaidRollout {
  suffix : String
  mut seen : Bool
}

///|
/// What is known of where transcripts are (transcript.ts `elsewhere`, `rollouts`, `saidRollouts`), and who is told a
/// session's changed (`onTranscriptHintsChanged`).
priv struct TranscriptHints {
  elsewhere : Map[String, String?]
  rollouts : Map[String, String]
  said : Map[String, Map[String, SaidRollout]]
  listeners : Array[(Int, (String) -> Unit)]
  mut next : Int
}

///|
let transcript_hints : TranscriptHints = { elsewhere: {}, rollouts: {}, said: {}, listeners: [], next: 0 }

///|
fn TranscriptHints::changed(self : TranscriptHints, id : String) -> Unit {
  for l in self.listeners.copy() {
    (l.1)(id)
  }
}

///|
fn TranscriptHints::listen(self : TranscriptHints, f : (String) -> Unit) -> () -> Unit {
  self.next += 1
  let n = self.next
  self.listeners.push((n, f))
  () => {
    match self.listeners.search_by(l => l.0 == n) {
      Some(i) => ignore(self.listeners.remove(i))
      None => ()
    }
  }
}

///|
/// read/transcript.ts `rememberCodexRolloutLooking`: the rollout a running Codex thread said, kept under each of its
/// home's sessions directories as reached and as its links resolve (`dirs`), its path below them `suffix`; the same entry
/// for both, as transcript.ts keeps it.
fn remember_said_rollout(id : String, dirs : Array[String], suffix : String) -> Unit {
  let h = transcript_hints
  let kept = match h.said.get(id) {
    Some(m) => m
    None => {
      let m : Map[String, SaidRollout] = {}
      h.said[id] = m
      m
    }
  }
  let entry : SaidRollout = { suffix, seen: false }
  for dir in dirs {
    kept[dir] = entry
  }
  h.changed(id)
}

///|
/// One batch's hints (transcript.ts `transcriptLocationHints`): what is known for its sources now, whether that still
/// stands, and what the locator found merged where it does.
priv struct BatchHints {
  value : Json
  current : () -> Bool
  merge : (Json) -> Bool
}

///|
fn transcript_location_hints(data : String, profiles : Array[(String, String)], sources : Array[Json]) -> BatchHints {
  let h = transcript_hints
  let claude : Array[String] = []
  let codex : Map[String, String] = {}
  let reported : Array[String] = []
  for source in sources {
    let runtime = jtext(source, "runtime").unwrap_or("")
    let id = jtext(source, "id").unwrap_or("")
    if runtime != "claude" && runtime != "codex" {
      continue
    }
    let dirs = [path([data, "transcripts", runtime]), ..profiles.map(p => path([p.1, @locate.transcript_dir(runtime)]))]
    for dir in dirs {
      let key = "\{dir}\u{0}\{id}"
      if runtime == "claude" {
        if !claude.contains(key) {
          claude.push(key)
        }
      } else {
        codex[key] = id
      }
    }
    if runtime == "codex" && !reported.contains(id) {
      reported.push(id)
    }
  }
  let before_elsewhere : Map[String, String?] = {}
  for key in claude {
    match h.elsewhere.get(key) {
      Some(p) => before_elsewhere[key] = p
      None => ()
    }
  }
  let before_rollouts : Map[String, String] = {}
  for key, _ in codex {
    match h.rollouts.get(key) {
      Some(p) => before_rollouts[key] = p
      None => ()
    }
  }
  let before_said : Map[String, Map[String, SaidRollout]] = {}
  let before_seen : Map[String, Map[String, Bool]] = {}
  for id in reported {
    let dirs = h.said.get(id).map(m => m.copy()).unwrap_or({})
    before_said[id] = dirs
    let seen : Map[String, Bool] = {}
    for dir, entry in dirs {
      seen[dir] = entry.seen
    }
    before_seen[id] = seen
  }
  let value : Json = {
    "elsewhere": Json::array(
      before_elsewhere.to_array().map(kv => Json::array([Json::string(kv.0), jopt(kv.1)])),
    ),
    "rollouts": Json::array(before_rollouts.to_array().map(kv => Json::array([Json::string(kv.0), Json::string(kv.1)]))),
    "said": Json::array(
      before_said
      .to_array()
      .map(kv => Json::array([
        Json::string(kv.0),
        Json::array(
          kv.1
          .to_array()
          .map(d => Json::array([
            Json::string(d.0),
            { "suffix": Json::string(d.1.suffix), "seen": Json::boolean(d.1.seen) },
          ])),
        ),
      ])),
    ),
  }
  let current = () => {
    for key in claude {
      if before_elsewhere.get(key) != h.elsewhere.get(key) {
        return false
      }
    }
    for key, _ in codex {
      if before_rollouts.get(key) != h.rollouts.get(key) {
        return false
      }
    }
    for id in reported {
      let before = before_said[id]
      let now = h.said.get(id)
      let n = match now {
        Some(m) => m.length()
        None => 0
      }
      if n != before.length() {
        return false
      }
      for dir, entry in before {
        match now {
          Some(m) =>
            match m.get(dir) {
              Some(e) if physical_equal(e, entry) && before_seen[id].get(dir) == Some(entry.seen) => ()
              _ => return false
            }
          None => return false
        }
      }
    }
    true
  }
  let merge = (found : Json) => {
    if !current() {
      return false
    }
    for pair in jitems(jfield(found, "rollouts")) {
      guard pair is Array([String(key), String(p)]) else { continue }
      match codex.get(key) {
        Some(id) if h.rollouts.get(key) != Some(p) => {
          h.rollouts[key] = p
          h.changed(id)
        }
        _ => ()
      }
    }
    for said in jitems(jfield(found, "said")) {
      guard said is Array([String(id), Array(dirs)]) else { continue }
      for d in dirs {
        guard d is Array([String(dir), entry]) else { continue }
        match before_said.get(id).bind(m => m.get(dir)) {
          Some(old) if Some(old.suffix) == jtext(entry, "suffix") && jfield(entry, "seen") is True && !old.seen => {
            old.seen = true
            h.changed(id)
          }
          _ => ()
        }
      }
    }
    true
  }
  { value, current, merge }
}

///|
let live_locator_idle_ms : Int = 60000

///|
let live_locator_restarts : Int = 3

///|
/// A lookup under way (live-locator.ts `Pending`).
priv struct LocatePending {
  id : Int
  key : String
  mut profiles : Array[(String, String)]
  mut attempts : Int
  mut paths : Array[Json]
  ids : Array[String]
  mut stale : Bool
  mut hints : BatchHints?
  mut batch : Array[Json]
  done : @effect.Deferred[Result[Json, String]]
}

///|
/// The live view's locator (live-locator.ts `LiveLocator`): its program while it runs, the lookups under way.
priv struct LiveLocator {
  host : @host.Host
  argv0 : String
  data : String
  session : (String) -> Json
  profiles : () -> Array[(String, String)]
  mut proc : Proc?
  active : Map[Int, LocatePending]
  mut next : Int
  mut idle : @effect.Fiber[Unit]?
  unlisten : () -> Unit
}

///|
fn LiveLocator::new(
  host : @host.Host,
  argv0 : String,
  data : String,
  session : (String) -> Json,
  profiles : () -> Array[(String, String)],
) -> LiveLocator {
  let active : Map[Int, LocatePending] = {}
  let unlisten = transcript_hints.listen(id => for _, r in active {
    if r.ids.contains(id) {
      r.stale = true
    }
  })
  { host, argv0, data, session, profiles, proc: None, active, next: 0, idle: None, unlisten }
}

///|
/// live-location-protocol.ts `locationIdentity` of a session's row, compared with what the locator found it to be.
fn same_identity(found : Json, row : Json) -> Bool {
  match (found, row) {
    (Null, Null) => true
    (Object(_), Object(_)) => {
      let token = jtext(row, "token").unwrap_or("")
      let hash = @cloud_lock.hex_of(@cloud_lock.sha256(@utf8.encode(token)))
      ["runtime", "runtimeSessionId", "cwd", "workspace", "profile", "ws"].iter().all(k => jfield(found, k) == jfield(row, k)) &&
      jtext(found, "tokenHash") == Some(hash)
    }
    _ => false
  }
}

///|
fn LiveLocator::send(self : LiveLocator, message : Json) -> Unit {
  match self.proc {
    Some(p) => ignore(p.write(@utf8.encode(message.stringify() + "\n")))
    None => ()
  }
}

///|
/// Its program, started as it is first asked (`--builder live-locator`), its lines heard as they come.
fn LiveLocator::started(self : LiveLocator) -> Unit raise {
  match self.idle {
    Some(f) => {
      f.interrupt()
      self.idle = None
    }
    None => ()
  }
  if self.proc is Some(_) {
    return
  }
  let p = spawn(
    self.host,
    self.argv0,
    ["--builder", "live-locator", "--db", path([self.data, "stillfail.db"]), "--data", self.data, "--sep", sep()],
    stdin_piped=true,
    stdout=Piped,
  )
  self.proc = Some(p)
  ignore(
    self.host.rt.fork_daemon("live locator's lines", on_error=e => @host.note("live locator's lines failed: \{e}"), async fn() {
      let held = @buffer.Buffer()
      let mut ended = false
      while !ended {
        match p.events.take() {
          Out(b) => {
            held.write_bytes(b)
            let text = @utf8.decode_lossy(held.to_bytes())
            let lines = text.split("\n").map(l => l.to_owned()).collect()
            held.reset()
            held.write_bytes(@utf8.encode(lines[lines.length() - 1]))
            for line in lines[:lines.length() - 1] {
              match (try { Ok(@json.parse(line)) } catch { e => Err(e) }) {
                Ok(m) => self.heard(p, m)
                Err(_) => ()
              }
            }
          }
          Err(_) => ()
          Exit(code, _) => {
            ended = true
            match self.proc {
              Some(now) if physical_equal(now, p) =>
                self.retire("live locator exited (\{match code { Some(c) => c.to_string(); None => "null" }})")
              _ => ()
            }
          }
        }
      }
    }),
  )
}

///|
/// Every lookup under way failed with `why`, its program let go.
fn LiveLocator::retire(self : LiveLocator, why : String) -> Unit {
  let p = self.proc
  self.proc = None
  for _, r in self.active {
    ignore(r.done.succeed(Err(why)))
  }
  self.active.clear()
  match p {
    Some(p) => {
      p.end_input()
      ignore(kill(p.pid, "SIGKILL"))
    }
    None => ()
  }
}

///|
fn LiveLocator::ask(self : LiveLocator, r : LocatePending) -> Unit {
  r.profiles = (self.profiles)()
  r.paths = []
  r.ids.clear()
  r.stale = false
  r.hints = None
  r.batch = []
  self.send({
    "type": "locate",
    "id": ji(r.id),
    "key": Json::string(r.key),
    "profiles": Json::array(r.profiles.map(p => { "id": Json::string(p.0), "home": Json::string(p.1) })),
  })
}

///|
fn LiveLocator::heard(self : LiveLocator, p : Proc, m : Json) -> Unit {
  guard self.proc is Some(now) && physical_equal(now, p) else { return }
  let id = match jfield(m, "id") {
    Number(n, ..) => n.to_int()
    _ => return
  }
  guard self.active.get(id) is Some(r) else { return }
  match jtext(m, "type").unwrap_or("") {
    "error" => self.retire(jtext(m, "error").unwrap_or("live locator failed"))
    "hints" => {
      r.batch = jitems(jfield(m, "sources"))
      let hints = transcript_location_hints(self.data, r.profiles, r.batch)
      r.hints = Some(hints)
      self.send({ "type": "hints", "id": ji(id), "hints": hints.value })
    }
    "batch" =>
      match r.hints {
        None => self.retire("live locator sent a batch without hints")
        Some(h) => {
          let accepted = (h.merge)(jfield(m, "hints"))
          if accepted {
            for x in jitems(jfield(m, "paths")) {
              r.paths.push(x)
            }
            for s in r.batch {
              match jtext(s, "id") {
                Some(i) if !r.ids.contains(i) => r.ids.push(i)
                _ => ()
              }
            }
          }
          r.hints = None
          self.send({ "type": "accepted", "id": ji(id), "accepted": Json::boolean(accepted) })
        }
      }
    "done" => {
      let profiles_now = (self.profiles)()
      let same_profiles = profiles_now.length() == r.profiles.length() &&
        profiles_now.iter().zip(r.profiles.iter()).all(pq => pq.0 == pq.1)
      let changed = r.stale || !same_identity(jfield(m, "identity"), (self.session)(r.key)) || !same_profiles
      if changed {
        r.attempts += 1
        if r.attempts > live_locator_restarts {
          self.retire("live transcript location kept changing")
          return
        }
        self.ask(r)
        return
      }
      self.active.remove(id)
      let found = match jfield(m, "runtime") {
        String(rt) if r.paths.length() > 0 =>
          ({ "runtime": Json::string(rt), "paths": Json::array(r.paths), "current": jfield(m, "current") } : Json)
        _ => Json::null()
      }
      ignore(r.done.succeed(Ok(found)))
      self.idle_soon()
    }
    _ => ()
  }
}

///|
/// Its program let go once nothing has been looked for IDLE_MS.
fn LiveLocator::idle_soon(self : LiveLocator) -> Unit {
  if self.active.length() > 0 || self.proc is None || self.idle is Some(_) {
    return
  }
  let p = self.proc
  self.idle = Some(
    self.host.rt.fork(name="live locator idle", async fn() {
      @effect.sleep(live_locator_idle_ms) // timer: a debounce of a burst (the locator let go idle)
      self.idle = None
      match (self.proc, p) {
        (Some(now), Some(was)) if physical_equal(now, was) && self.active.length() == 0 => {
          self.proc = None
          now.end_input()
          ignore(kill(now.pid, "SIGTERM"))
        }
        _ => ()
      }
    }),
  )
}

///|
/// live-locator.ts `locate`: where session `key`'s transcripts are (`{runtime, paths, current}`), null where it has
/// none.
async fn LiveLocator::locate(self : LiveLocator, key : String) -> Json {
  self.next += 1
  let r : LocatePending = {
    id: self.next,
    key,
    profiles: [],
    attempts: 0,
    paths: [],
    ids: [],
    stale: false,
    hints: None,
    batch: [],
    done: @effect.Deferred::new(),
  }
  self.started() catch {
    e => raise LiveError("the live locator did not start: \{said_of(e)}")
  }
  self.active[r.id] = r
  self.ask(r)
  match r.done.wait() {
    Ok(v) => v
    Err(why) => raise LiveError(why)
  }
}

///|
/// Its program let go where nothing is looked for (live-locator.ts `trimIdle`): 1 where it was, else 0.
fn LiveLocator::trim_idle(self : LiveLocator) -> Int {
  match self.proc {
    Some(p) if self.active.length() == 0 => {
      self.proc = None
      p.end_input()
      ignore(kill(p.pid, "SIGTERM"))
      1
    }
    _ => 0
  }
}

///|
fn LiveLocator::pid(self : LiveLocator) -> Int? {
  self.proc.map(p => p.pid)
}

///|
/// The locator ended with the station.
fn LiveLocator::close(self : LiveLocator) -> Unit {
  (self.unlisten)()
  self.retire("live locator stopped")
}
