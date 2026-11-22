// Which of the window thread's hangs are sent (reports.mbt's): in each ten minutes the first `hangs_most` at once, and
// of the rest the heaviest `hangs_most` (a stall before a late frame, the longer first) held and sent as the ten minutes
// end or the app is hidden; how many were sent of none, said with the summary. A phone slow throughout used to send its
// ten minutes' first twenty and nothing after, its stalls among them (2026-11-10: five stalls told by the summary,
// none sent).

///|
/// The ten minutes from `since` (the work clock's ms; below 0 none yet): how many were sent at once, the heaviest of
/// the rest held, and how many were let go since the last summary (with a bounded breakdown by page/trigger/top_kind).
struct HangGate {
  mut since : Double
  mut sent : Int
  held : Array[@ui.Hang]
  mut unsent : Int
  unsent_by : Map[String, Int]
}

///|
let hangs_most : Int = 20

///|
let hangs_span_ms : Double = 600000.0

///|
let unsent_by_most : Int = 16

///|
fn HangGate::new() -> HangGate {
  { since: -1.0, sent: 0, held: [], unsent: 0, unsent_by: Map([]) }
}

///|
fn hang_trigger_name(trigger : @ui.HangTrigger) -> String {
  match trigger {
    Stall => "stall"
    LateFrame => "late_frame"
    Blocking => "blocking"
  }
}

///|
fn hang_done_name(what : @ui.Done) -> String {
  match what {
    Event(name) => name
    Frame(_) => "frame"
    Present => "present"
    FrameEnd => "frame-end"
    Small(_, _) => "small"
  }
}

///|
fn HangGate::record_unsent(self : HangGate, h : @ui.Hang) -> Unit {
  let page = if h.page == "" { "-" } else { h.page }
  let trigger = hang_trigger_name(h.trigger)
  let top_kind = if h.contributors.is_empty() { "-" } else { hang_done_name(h.contributors[0].what) }
  let raw_key = "\{page}/\{trigger}/\{top_kind}"
  let key = if self.unsent_by.contains(raw_key) || self.unsent_by.length() < unsent_by_most {
    raw_key
  } else {
    "other"
  }
  self.unsent_by[key] = self.unsent_by.get(key).unwrap_or(0) + 1
}

///|
/// Whether `a` is heavier than `b`: a stall first, then the longer stall.
fn hang_heavier(a : @ui.Hang, b : @ui.Hang) -> Bool {
  let sa = a.trigger is Stall
  let sb = b.trigger is Stall
  if sa != sb {
    sa
  } else {
    a.stall_ms > b.stall_ms
  }
}

///|
/// Hang `h` found: what is sent now (the held ones first where its ten minutes are new, then it, while fewer than
/// `hangs_most` went at once).
fn HangGate::offer(self : HangGate, h : @ui.Hang) -> Array[@ui.Hang] {
  let out = []
  if self.since < 0.0 || h.end >= self.since + hangs_span_ms {
    out.append(self.held)
    self.held.clear()
    self.since = h.end
    self.sent = 0
  }
  if self.sent < hangs_most {
    self.sent += 1
    out.push(h)
  } else if self.held.length() < hangs_most {
    self.held.push(h)
  } else {
    // (the lightest held let go where `h` is heavier, else `h`)
    let mut light = 0
    for i in 1..<self.held.length() {
      if hang_heavier(self.held[light], self.held[i]) {
        light = i
      }
    }
    let dropped = if hang_heavier(h, self.held[light]) {
      let old = self.held[light]
      self.held[light] = h
      old
    } else {
      h
    }
    self.unsent += 1
    self.record_unsent(dropped)
  }
  out
}

///|
/// The app hidden (its summary told): the held ones, sent now, and how many were let go since the last summary.
fn HangGate::flush(self : HangGate) -> (Array[@ui.Hang], Int, Map[String, Int]) {
  let out = self.held.copy()
  self.held.clear()
  let unsent = self.unsent
  self.unsent = 0
  let unsent_by = self.unsent_by.copy()
  self.unsent_by.clear()
  (out, unsent, unsent_by)
}
