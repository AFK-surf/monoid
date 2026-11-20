// The log of what a station tells everyone (station/src/api/event-log.ts `EventLog`): each event its number in it,
// kept a while; a stream goes on from the last id a client heard (`<run>.<n>`), or is told it missed something.

///|
/// What is kept at most: an hour, 20,000 events, 8 MiB of their text (event-log.ts KEPT_MS, KEPT_MOST, KEPT_BYTES).
pub let kept_ms : Double = 3_600_000.0

///|
pub let kept_most : Int32 = 20_000

///|
pub let kept_bytes : Int32 = 8 * 1024 * 1024

///|
/// An event of the log: its number, whom it was for (the teller's `To`, as data), as it goes out ("" once the thing
/// it said whole was said again), when, and the thing it says whole.
pub(all) struct Logged {
  n : Double
  to : J
  mut text : String
  at : Double
  of : String?
}

///|
pub struct EventLog {
  run : String
  mut seq : Double
  mut kept : Array[Logged]
  mut bytes : Int32
  mut forgotten : Double
  latest : Map[String, Logged]
  ms : Double
  most : Int32
  most_bytes : Int32
}

///|
pub fn EventLog::new(
  run : String,
  ms~ : Double = kept_ms,
  most~ : Int32 = kept_most,
  bytes~ : Int32 = kept_bytes,
) -> EventLog {
  {
    run,
    seq: 0,
    kept: [],
    bytes: 0,
    forgotten: 0,
    latest: Map([]),
    ms,
    most,
    most_bytes: bytes,
  }
}

///|
fn is_hex(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  for c in s {
    if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
      return false
    }
  }
  true
}

///|
fn is_safe_integer(v : J?) -> Double? {
  match v {
    Some(Num(d)) if @jsjson.is_safe_integer(d) => Some(d)
    _ => None
  }
}

///|
pub suberror NotALog {
  NotALog
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for NotALog with output(self, logger) {
  match self {
    NotALog => logger.write_string("not an event log")
  }
}

///|
/// event-log.ts `EventLog.from`: the log `kept` says (another process's), at `now`; raises on what is no log.
pub fn EventLog::from(
  kept : J,
  now : Double,
  ms~ : Double = kept_ms,
  most~ : Int32 = kept_most,
  bytes~ : Int32 = kept_bytes,
) -> EventLog raise NotALog {
  guard text_of(kept.get("run")) is Some(run) && is_hex(run) else {
    raise NotALog
  }
  guard is_safe_integer(kept.get("seq")) is Some(seq) else { raise NotALog }
  guard is_safe_integer(kept.get("forgotten")) is Some(forgotten) &&
    forgotten <= seq else {
    raise NotALog
  }
  guard kept.get("events") is Some(Arr(events)) else { raise NotALog }
  let log = EventLog::new(run, ms~, most~, bytes~)
  log.seq = seq
  log.forgotten = forgotten
  let mut last = forgotten
  for e in events {
    guard is_safe_integer(e.get("n")) is Some(n) && n > last && n <= seq else {
      raise NotALog
    }
    guard text_of(e.get("text")) is Some(text) else { raise NotALog }
    guard e.get("at") is Some(Num(at)) else { raise NotALog }
    last = n
    // (`of` as it was written: a string, or left out)
    let of = text_of(e.get("of"))
    let logged = { n, to: e.get("to").unwrap_or(Null), text, at, of, }
    log.kept.push(logged)
    log.bytes += text.length()
    if of is Some(thing) {
      log.latest[thing] = logged
    }
  }
  log.let_go(now)
  log
}

///|
/// What it keeps, for the log that goes on from it in the next process.
pub fn EventLog::kept(self : EventLog) -> J {
  jo([
    ("run", js(self.run)),
    ("seq", jn(self.seq)),
    ("forgotten", jn(self.forgotten)),
    (
      "events",
      ja(
        self.kept
        .filter(e => e.text != "")
        .map(e => {
          jopt([
            ("n", Some(jn(e.n))),
            ("to", Some(e.to)),
            ("text", Some(js(e.text))),
            ("at", Some(jn(e.at))),
            ("of", e.of.map(js)),
          ])
        }),
      ),
    ),
  ])
}

///|
/// event-log.ts `append`: an event at `now`, `data` already as JSON text; `of`, the thing it says whole.
pub fn EventLog::append(
  self : EventLog,
  event : String,
  data : String,
  to : J,
  now : Double,
  of? : String,
) -> Logged {
  self.seq += 1
  let n = self.seq
  let logged = {
    n,
    to,
    text: "id: \{self.run}.\{num_text(n)}\nevent: \{event}\ndata: \{data}\n\n",
    at: now,
    of,
  }
  if of is Some(thing) {
    if self.latest.get(thing) is Some(before) {
      self.bytes -= before.text.length()
      before.text = ""
    }
    self.latest[thing] = logged
  }
  self.kept.push(logged)
  self.bytes += logged.text.length()
  self.let_go(now)
  logged
}

///|
fn EventLog::let_go(self : EventLog, now : Double) -> Unit {
  let mut gone = 0
  while gone < self.kept.length() &&
        (
          self.kept.length() - gone > self.most ||
          self.bytes > self.most_bytes ||
          now - self.kept[gone].at > self.ms
        ) {
    self.bytes -= self.kept[gone].text.length()
    gone += 1
  }
  if gone > 0 {
    self.forgotten = self.kept[gone - 1].n
    self.kept = self.kept[gone:].to_array()
    let from = if self.kept.length() > 0 {
      self.kept[0].n
    } else {
      @double.infinity
    }
    let drop = []
    for thing, e in self.latest {
      if e.n < from {
        drop.push(thing)
      }
    }
    for thing in drop {
      self.latest.remove(thing)
    }
  }
}

///|
/// `/^([0-9a-f]+)\.(\d+)$/` of `since`, where it is this run's and not before what was let go.
fn EventLog::from_id(self : EventLog, since : String) -> Double? {
  guard since.rev_find(".") is Some(dot) else { return None }
  let run = since.view(end_offset=dot).to_string()
  let digits = since.view(start_offset=dot + 1).to_string()
  if !is_hex(run) || digits.length() == 0 {
    return None
  }
  let mut n = 0.0
  for c in digits {
    if c < '0' || c > '9' {
      return None
    }
    n = n * 10.0 + (c.to_int() - '0'.to_int()).to_double()
  }
  // (Number of a run of digits: past 2^53 as JavaScript rounds it)
  let n = @jsjson.parse(digits) catch { _ => Num(n) }
  guard n is Num(n) else { return None }
  if run == self.run && n >= self.forgotten {
    Some(n)
  } else {
    None
  }
}

///|
pub fn EventLog::has(self : EventLog, since : String) -> Bool {
  self.from_id(since) is Some(_)
}

///|
pub fn EventLog::after(self : EventLog, since : String) -> Array[Logged] {
  match self.from_id(since) {
    None => []
    Some(n) => self.kept.filter(e => e.n > n && e.text != "")
  }
}

///|
pub fn EventLog::at(self : EventLog) -> String {
  "\{self.run}.\{num_text(self.seq)}"
}

///|
pub fn EventLog::clear(self : EventLog) -> Unit {
  self.kept = []
  self.bytes = 0
  self.latest.clear()
  self.seq += 1
  self.forgotten = self.seq
}

///|
/// How it stands (`state`): run, forgotten, told, kept, bytes.
pub fn EventLog::state(self : EventLog) -> J {
  jo([
    ("run", js(self.run)),
    ("forgotten", jn(self.forgotten)),
    ("told", jn(self.seq)),
    ("kept", jn(self.kept.length().to_double())),
    ("bytes", jn(self.bytes.to_double())),
  ])
}
