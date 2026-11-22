// A Codex app-server's output read here (`kind` "codex", agents.mbt): one process, a thread per session. What answers
// Node's requests, asks it something, is not JSON, or is a turn's error not retried is given Node as the line it is
// (codex.ts `Host.heard`); a turn's diff (`turn/diff/updated`, of which the station keeps nothing) is let go; each
// thread's notification Node said a session of (`codexThread`) is read here as the TypeScript station read it
// (station/codex: its live steps, the station's tools out of reach, a compaction, a turn's start and outcome) and told
// as that thread's events, its live steps held DELTAS_MS as Claude Code's are, and given its session's actor here once
// Node took them where Node says so (`route` with the thread, actors.mbt `routed`). A thread's turn's start and end are
// told with where they are in the output (a thread no session has, as `marks`): what a crash reads again begins there.
// While a station takes its sessions up, what comes for a thread not taken up yet is held for it (`orphans`) until Node
// says no more will be.
//
// Node says on stdin, besides agents.mbt's: `codexThread` (a session's thread, its live steps as Node has them),
// `codexDrop` (not its session's any more), `route` with `thread`, `orphans` (none held from now on), `codexReplay` and
// `codexReplayed` (what a crash reads again of an output, each thread's live steps as it comes to, told `replayed`).

///|
/// A thread a session has.
priv struct CodexThread {
  id : String
  live : @codex.Live
  /// its session's actor is in this program (`route`)
  mut routed : Bool
}

///|
/// What is had of an app-server's threads.
priv struct Codex {
  threads : Map[String, CodexThread]
  /// what came for a thread no session has yet, each line with where it begins and ends, while sessions are taken up
  mut orphans : Map[String, Array[(Bytes, Int64, Int64)]]?
  /// each thread's deltas held (`DELTAS_MS`)
  pending : Map[String, Array[@jsjson.JValue]]
}

///|
fn Codex::new() -> Codex {
  { threads: Map([]), orphans: None, pending: Map([]) }
}

///|
/// Each thread's live steps as they stand (`freeze`).
fn Codex::states(self : Codex) -> Json {
  let out : Map[String, Json] = {}
  for k, t in self.threads {
    out[k] = t.live.state().to_json()
  }
  Json::object(out)
}

///|
/// The most held for one thread not taken up yet (codex.ts `ORPHANS_MAX` before).
const ORPHANS_MOST : Int = 10_000

///|
/// A Codex app-server's turn's diff, whole each time it changes: the most of what it writes, of which the station keeps
/// nothing, let go as its line begins.
const DIFF : Bytes = b"{\"method\":\"turn/diff/updated\""

///|
/// What a line of an app-server's is.
priv enum CodexLine {
  /// Node's to read: an answer to its request, a request of the app-server's, what is not JSON, a turn's error
  Node
  /// nothing anyone reads
  Drop
  /// a thread's notification: its method, its params, the thread
  Notice(String, @jsjson.JValue, String)
}

///|
/// A line as codex.ts `Host.onLine` told them apart.
fn codex_line(line : Bytes) -> CodexLine {
  let v = @jsjson.parse(@utf8.decode_lossy(line)) catch { _ => return Node }
  let id = v.get("id")
  guard v.get("method") is Some(Str(method)) else {
    // (an answer: an integer id and no method)
    return match id {
      Some(Num(d)) if !d.is_nan() && !d.is_inf() && d == d.floor() => Node
      _ => Drop
    }
  }
  if id is Some(x) && !(x is Null) {
    return Node
  }
  let params = v.get("params").unwrap_or(Null)
  guard params.get("threadId") is Some(Str(thread)) else { return Drop }
  if method == "error" && !(params.get("willRetry") is Some(Bool(true))) {
    return Node
  }
  Notice(method, params, thread)
}

///|
/// A notification's events for its thread's session; a turn's start and end with where its line begins and ends in the
/// output (`at`; none for what was held for it before it was a session's: told then, `marks`).
fn codex_events(t : CodexThread, method : String, params : @jsjson.JValue, at : (Int64, Int64)?) -> Array[@jsjson.JValue] {
  let events = @codex.events(t.live, method, params)
  guard at is Some((from, to)) else { return events }
  events.map(e => match e {
    Obj(fields) if e.get("type") is Some(Str(k)) && (k == "turnStarted" || k == "turnEnded") =>
      Obj(fields + [("from", Num(from.to_double())), ("to", Num(to.to_double()))])
    e => e
  })
}

///|
fn strip_cr_bytes(line : Bytes) -> Bytes {
  if line.length() > 0 && line[line.length() - 1] == b'\r' {
    line[0:line.length() - 1].to_bytes()
  } else {
    line
  }
}

///|
/// Lines of an app-server's stdout, each with where it ends: what they come to told Node, its threads' deltas held, or
/// acknowledged at once where they say nothing and nothing told is waiting.
fn Agents::codex_heard(self : Agents, h : Hosted, lines : Array[(Bytes, Int64)]) -> Unit {
  let c = h.codex
  let end = lines[lines.length() - 1].1
  let node : Array[(Bytes, Int64, Int64)] = []
  let marks : Array[@jsjson.JValue] = []
  let fresh : Map[String, Array[@jsjson.JValue]] = {}
  for l in lines {
    let line = strip_cr_bytes(l.0)
    let from = l.1 - (l.0.length() + 1).to_int64()
    if line.length() >= DIFF.length() && line[0:DIFF.length()] == DIFF[:] {
      continue
    }
    match codex_line(line) {
      Node => node.push((line, from, l.1))
      Drop => ()
      Notice(method, params, thread) => {
        let key = thread
        match c.threads.get(key) {
          Some(t) => {
            let events = codex_events(t, method, params, Some((from, l.1)))
            if events.length() > 0 {
              match fresh.get(key) {
                Some(all) => all.append(events)
                None => fresh[key] = events
              }
            }
          }
          None => {
            let m = method
            if m == "turn/started" || m == "turn/completed" {
              marks.push(Arr([Str(thread), Num(if m == "turn/started" { 1.0 } else { 0.0 }), Num(from.to_double()), Num(l.1.to_double())]))
            }
            if c.orphans is Some(o) {
              match o.get(key) {
                Some(held) => if held.length() < ORPHANS_MOST { held.push((line, from, l.1)) }
                None => o[key] = [(line, from, l.1)]
              }
            }
          }
        }
      }
    }
  }
  if node.length() == 0 && marks.length() == 0 && fresh.length() == 0 {
    if c.pending.length() > 0 {
      h.pending_to = end
      h.told = end
      return
    }
    if h.told <= h.acked_out {
      h.acked_out = end
      h.acked_to = end
      h.told = end
      h.told_out = end
      self.ack(h)
      return
    }
  } else if node.length() == 0 && marks.length() == 0 && fresh.values().all(events => events.iter().all(is_delta)) {
    // (only what steps wrote: held, told with what comes next or once DELTAS_MS is over)
    for k, events in fresh {
      match c.pending.get(k) {
        Some(held) => merge_into(held, events)
        None => {
          let held = []
          merge_into(held, events)
          c.pending[k] = held
        }
      }
      h.pending_units += units_of(events)
    }
    h.pending_to = end
    h.told = end
    if h.pending_units >= DELTAS_MOST {
      self.codex_flush(h)
    } else {
      self.soon(h)
    }
    return
  }
  let groups = self.held_out(h)
  for k, events in fresh {
    match groups.get(k) {
      Some(held) => merge_into(held, events)
      None => {
        let all = []
        merge_into(all, events)
        groups[k] = all
      }
    }
  }
  h.told = end
  self.codex_tell(h, end, node, marks, groups)
}

///|
/// What is held of each thread, taken out to be told.
fn Agents::held_out(self : Agents, h : Hosted) -> Map[String, Array[@jsjson.JValue]] {
  ignore(self)
  let groups : Map[String, Array[@jsjson.JValue]] = {}
  for k, events in h.codex.pending {
    groups[k] = events
  }
  h.codex.pending.clear()
  h.pending_units = 0
  groups
}

///|
/// What is held told Node now.
fn Agents::codex_flush(self : Agents, h : Hosted) -> Unit {
  if h.codex.pending.length() == 0 || h.left {
    return
  }
  let groups = self.held_out(h)
  self.codex_tell(h, h.pending_to, [], [], groups)
}

///|
/// Told Node, up to `to`: the lines it reads (`lines`, their bytes after it, each with where it begins and ends), the
/// turns' starts and ends of threads no session has (`marks`: the thread, 1 for a start, where it begins and ends), and
/// each thread's events with its live steps as they stand after them, kept as a batch for its actor where it is routed.
fn Agents::codex_tell(
  self : Agents,
  h : Hosted,
  to : Int64,
  node : Array[(Bytes, Int64, Int64)],
  marks : Array[@jsjson.JValue],
  groups : Map[String, Array[@jsjson.JValue]],
) -> Unit {
  let u = (s : String) => s
  let body = @buffer.new()
  let at = []
  for l in node {
    at.push("[\{l.1},\{l.2},\{l.0.length()}]")
    body.write_bytes(l.0)
  }
  let threads : Array[@jsjson.JValue] = []
  for k, events in groups {
    guard h.codex.threads.get(k) is Some(t) && events.length() > 0 else { continue }
    let fields : Array[(String, @jsjson.JValue)] = [(u("thread"), Str(t.id)), (u("events"), Arr(events)), (u("live"), t.live.state())]
    if t.routed {
      // (each thread's a batch of its own, all told with this line: each lets go of itself only once taken)
      let b = self.keep_batch(h, events, to)
      h.batch_threads[b] = k
      fields.push((u("batch"), Num(b.to_double())))
    }
    threads.push(Obj(fields))
  }
  h.told_out = to
  let bytes = body.to_bytes()
  // (one line put together once as its bytes: a thread's write of MBs is not copied again into it)
  let line = @buffer.new(size_hint=4096 + units_of_groups(groups))
  line.write_string_utf8("{\"lines\":\{h.n},\"to\":\{to},\"at\":[\{at.join(",")}],\"bytes\":\{bytes.length()},\"marks\":")
  @jsjson.write_utf8(line, Arr(marks))
  line.write_string_utf8(",\"threads\":")
  @jsjson.write_utf8(line, Arr(threads))
  line.write_byte(b'}')
  self.host.say_bytes(line.to_bytes())
  self.host.out(bytes)
}

///|
/// A session's thread (`codexThread`), its live steps as Node has them: what was held for it read now, as it came.
fn Agents::add_thread(self : Agents, h : Hosted, thread : String, state : Json?, routed? : Bool = false) -> Unit {
  let live = match state {
    Some(Null) | None => @codex.Live::new()
    Some(s) => @codex.Live::of_state(@jsjson.JValue::of_json(s))
  }
  let t = { id: thread, live, routed }
  h.codex.threads[thread] = t
  guard h.codex.orphans is Some(o) && o.get(thread) is Some(held) else { return }
  o.remove(thread)
  let events = []
  for l in held {
    if codex_line(l.0) is Notice(method, params, _) {
      events.append(codex_events(t, method, params, None))
    }
  }
  if events.length() == 0 {
    return
  }
  let groups = self.held_out(h)
  match groups.get(thread) {
    Some(all) => merge_into(all, events)
    None => {
      let all = []
      merge_into(all, events)
      groups[thread] = all
    }
  }
  self.codex_tell(h, h.told, [], [], groups)
}

///|
/// A thread no longer a session's: none of its events told from now on, nor kept for its actor.
fn Agents::drop_thread(self : Agents, h : Hosted, thread : String) -> Unit {
  self.route_thread(h, thread, false)
  h.codex.threads.remove(thread)
  h.codex.pending.remove(thread)
}

///|
/// Whether what a thread reads is given its session's actor here (`route`).
fn Agents::route_thread(self : Agents, h : Hosted, thread : String, on : Bool) -> Unit {
  ignore(self)
  if h.codex.threads.get(thread) is Some(t) {
    t.routed = on
  }
  if !on {
    let gone = h.batch_threads.iter().filter_map(kv => if kv.1 == thread { Some(kv.0) } else { None }).collect()
    for k in gone {
      h.batches.remove(k)
      h.batch_threads.remove(k)
      h.batch_before.remove(k)
    }
    self.advance_ack(h)
  }
}

///|
/// No more held for threads not taken up (its sessions are, or never will be): what was is let go.
fn Agents::orphans_off(self : Agents, h : Hosted) -> Unit {
  ignore(self)
  guard h.codex.orphans is Some(o) else { return }
  h.codex.orphans = None
  let mut dropped = 0
  for _, held in o {
    dropped += held.length()
  }
  if dropped > 0 {
    @host.note("agents::codex: notifications for threads nobody took up, dropped: \{o.length()} threads, \{dropped} notifications")
  }
}

///|
/// What a crash reads again of an app-server's output (codex.ts `takeUp`), each a thread's notification as what its live
/// steps are made of: its method, its thread, and an item's type and id.
fn Agents::replay(self : Agents, id : Int, notices : Array[Json]) -> Unit {
  let u = (s : String) => s
  let threads = match self.replays.get(id) {
    Some(t) => t
    None => {
      let t = Map([])
      self.replays[id] = t
      t
    }
  }
  for n in notices {
    guard n is Array([String(method), String(thread), ..] as parts) else { continue }
    let params : Array[(String, @jsjson.JValue)] = [(u("threadId"), Str(u(thread)))]
    if parts.length() >= 4 {
      let item = []
      for k, name in ["type", "id"] {
        match parts[2 + k] {
          String(s) => item.push((u(name), @jsjson.JValue::Str(u(s))))
          Number(d, ..) => item.push((u(name), Num(d)))
          _ => ()
        }
      }
      params.push((u("item"), Obj(item)))
    }
    let live = match threads.get(thread) {
      Some(l) => l
      None => {
        let l = @codex.Live::new()
        threads[thread] = l
        l
      }
    }
    ignore(live.feed(u(method), Obj(params)))
  }
}

///|
/// What was read again, told: each thread's live steps.
fn Agents::replayed(self : Agents, id : Int) -> Unit {
  let states : Map[String, Json] = {}
  if self.replays.get(id) is Some(threads) {
    for k, live in threads {
      states[k] = live.state().to_json()
    }
  }
  self.replays.remove(id)
  self.host.say(({ "replayed": Json::number(id.to_double()), "live": Json::object(states) } : Json).stringify())
}

///|
/// The code units of what threads' steps wrote (what a line telling them is about as long as).
fn units_of_groups(groups : Map[String, Array[@jsjson.JValue]]) -> Int {
  let mut n = 0
  for _, events in groups {
    n += units_of(events)
  }
  n
}
