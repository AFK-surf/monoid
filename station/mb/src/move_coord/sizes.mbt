// What a move would send of each chat, in bytes, known before it starts (station/src/move/sizes.ts; move/AGENTS.md):
// each session's room and transcripts sized by the move's own gathering walk (carry.ts `sizesSoon`), kept a line a
// session (`move/sizes.log`) against the session as it was then (its `stamp`). A session whose stamp differs from its
// line's, or with none, is measured again by one pass in the background, a batch at a time.

///|
pub let sizes_batch : Int = 50

///|
pub let size_most : Int = 500_000

///|
/// A session sized (carry.ts `Sized`): its bytes (at least, where not `complete`), its room and transcripts.
pub(all) struct Sized {
  key : String
  bytes : Double
  complete : Bool
  room : String?
  transcripts : Array[String]
}

///|
pub fn Sized::of(j : J) -> Sized {
  {
    key: text(get(Some(j), "key")).unwrap_or(""),
    bytes: num(get(Some(j), "bytes")).unwrap_or(0.0),
    complete: is_true(get(Some(j), "complete")),
    room: text(get(Some(j), "room")),
    transcripts: arr(get(Some(j), "transcripts")).unwrap_or([]).filter_map(x => text(Some(x))),
  }
}

///|
pub(all) struct SizesDeps {
  data : String
  disk : Disk
  measure : async (Array[String]) -> Array[Sized]
  gone : (async (String) -> Bool)?
  say : Say
  clock : Clock
}

///|
/// What a set of chats would send, as far as it is known.
pub(all) struct Sum {
  bytes : Double
  known : Int
  of : Int
  measuring : Int
  at_least : Bool
}

///|
pub struct Sizes {
  priv d : SizesDeps
  priv log : KeptLog
  /// The sessions to measure (the stamp each was seen with), in the order they were first seen stale.
  priv stale : Map[String, String]
  priv keys_of : Map[String, Array[String]]
  priv mut pass : @effect.Deferred[Unit]?
  priv mut quiet : Bool
  /// The sessions measured so far (a test's).
  mut measured : Int
}

///|
pub fn Sizes::new(d : SizesDeps) -> Sizes {
  {
    d,
    log: KeptLog::new(d.disk, @nodepath.join("/", [d.data, "move", "sizes.log"])),
    stale: {},
    keys_of: {},
    pass: None,
    quiet: false,
    measured: 0,
  }
}

///|
/// What a plan read of chat `id`: its sessions, each with its stamp.
pub fn Sizes::seen(self : Sizes, id : String, sessions : Array[(String, String)]) -> Unit {
  self.keys_of[id] = sessions.map(s => s.0)
  for s in sessions {
    let line = self.log.get(s.0)
    if text(get(line, "stamp")) == Some(s.1) {
      self.stale.remove(s.0)
    } else {
      self.stale[s.0] = s.1
    }
  }
}

///|
/// A plan read ended: what it found stale measured, at rest.
pub fn Sizes::read(self : Sizes) -> Unit {
  if !self.quiet {
    self.start()
  }
}

///|
pub fn Sizes::set_quiet(self : Sizes, on : Bool) -> Unit {
  self.quiet = on
}

///|
fn Sizes::start(self : Sizes) -> Unit {
  if self.stale.length() > 0 && self.pass is None {
    let done = @effect.Deferred::new()
    self.pass = Some(done)
    (self.d.clock.spawn)(async fn() {
      self.run() catch {
        e =>
          self.d.say.log(
            "warn",
            "the chats' sizing stopped",
            jo([("error", js(message_of(e)))]),
          )
      }
      ignore(done.succeed(()))
    })
  }
}

///|
/// What is stale measured now, a turn under way or not, and ended.
pub async fn Sizes::settled(self : Sizes) -> Unit {
  self.start()
  while self.pass is Some(p) {
    p.wait()
  }
}

///|
async fn Sizes::run(self : Sizes) -> Unit {
  let before = self.measured
  defer {
    self.pass = None
  }
  while self.stale.length() > 0 {
    let batch = []
    for k, v in self.stale {
      if batch.length() >= sizes_batch {
        break
      }
      batch.push((k, v))
    }
    let got = (self.d.measure)(batch.map(b => b.0)) catch {
      e => {
        self.d.say.log(
          "warn",
          "chats' sizes not measured",
          jo([("sessions", ji(batch.length())), ("error", js(message_of(e)))]),
        )
        []
      }
    }
    let by_key : Map[String, Sized] = {}
    for s in got {
      by_key[s.key] = s
    }
    let lines : Array[(String, J?)] = []
    for b in batch {
      let (key, stamp) = b
      if self.stale.get(key) == Some(stamp) {
        self.stale.remove(key)
      }
      let s = match by_key.get(key) {
        Some(s) => s
        None => continue
      }
      self.measured += 1
      lines.push((
        key,
        Some(
          jo([
            ("bytes", jn(s.bytes)),
            ("complete", jb(s.complete)),
            ("stamp", js(stamp)),
            (
              "room",
              match s.room {
                Some(r) => js(r)
                None => Null
              },
            ),
            ("transcripts", jstrs(s.transcripts)),
          ]),
        ),
      ))
    }
    self.log.many(lines) catch {
      e =>
        self.d.say.log(
          "warn",
          "chats' sizes not kept",
          jo([("error", js(message_of(e)))]),
        )
    }
  }
  if !self.quiet && self.d.gone is Some(gone) {
    let gone_keys = []
    for k in self.log.keys() {
      if gone(k) {
        gone_keys.push(k)
      }
    }
    self.log.many(gone_keys.map(k => (k, None))) catch {
      _ => ()
    }
  }
  self.d.say.log(
    "info",
    "chats' sizes measured",
    jo([("sessions", ji(self.measured - before))]),
  )
}

///|
/// The sessions of chat `id` as the last plan named them.
pub fn Sizes::keys_of(self : Sizes, id : String) -> Array[String] {
  self.keys_of.get(id).unwrap_or([id])
}

///|
pub fn Sizes::line(self : Sizes, key : String) -> J? {
  self.log.get(key)
}

///|
/// Where chat `id`'s sessions' things are, for the other station's sizing of its own (carry.ts `SizedPlaces`).
pub fn Sizes::places_of(self : Sizes, id : String) -> Array[J] {
  let out = []
  for key in self.keys_of(id) {
    match self.log.get(key) {
      Some(l) =>
        out.push(
          jo([
            ("key", js(key)),
            ("room", get(Some(l), "room").unwrap_or(Null)),
            ("transcripts", get(Some(l), "transcripts").unwrap_or(ja([]))),
          ]),
        )
      None => ()
    }
  }
  out
}

///|
/// What chats `ids` would send, as far as it is known.
pub fn Sizes::sum(self : Sizes, ids : Array[String]) -> Sum {
  let mut bytes = 0.0
  let mut known = 0
  let mut measuring = 0
  let mut at_least = false
  for id in ids {
    let keys = self.keys_of(id)
    if keys.iter().any(k => self.stale.contains(k) || self.log.get(k) is None) {
      measuring += 1
      continue
    }
    known += 1
    for k in keys {
      let l = self.log.get(k)
      bytes += num(get(l, "bytes")).unwrap_or(0.0)
      if !is_true(get(l, "complete")) {
        at_least = true
      }
    }
  }
  { bytes, known, of: ids.length(), measuring, at_least }
}

///|
pub fn Sum::to_j(self : Sum) -> J {
  jo([
    ("bytes", jn(self.bytes)),
    ("known", ji(self.known)),
    ("of", ji(self.of)),
    ("measuring", ji(self.measuring)),
    ("atLeast", jb(self.at_least)),
  ])
}
