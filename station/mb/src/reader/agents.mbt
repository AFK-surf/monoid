// The Claude Code processes' output read here (and a Codex app-server's: agents_codex.mbt), not by the station's Node (`--sessions`): Node starts each process under
// its runner (station/src/agents/runner.ts) and tells this program to attach to the runner's socket, which it reads as
// station/src/agents/runner.ts `RunnerConnection` does (its messages a line of JSON each, stdout and stderr in base64,
// from where the last station acknowledged). Each line of stdout is a frame of Claude Code's stream-json, which it
// reads as station/src/agents/claude.ts does (`heard`: the live steps, the station's tools out of reach, a token asked
// for, what it does to the turn: station/mb/src/claude) and tells Node what that comes to: the runtime's events, where
// the turn stands, up to where it read. Node acknowledges each once its session took them, and only then is the line
// acknowledged to the runner, so a station that crashes reads again exactly what no session took.
//
// Node says on stdin, a line of JSON each: `wall` (its clock), `attach` (a session's runner: its socket, the turn and
// the live steps as Node knows them), `ack` (what of a session's Node took), `write` (a line to its stdin), `signal`,
// `begin` (a prompt's turn begun: `compact` for a /compact), `keep`, `route`, `aborting`, `renewed`, `done` (read to the end: its runner
// may go), `detach` (let go for the next station; `leave`: the runner asked to close, a pipe's), `freeze` and `thaw` (its lines held while the station hands over).
// It says on stdout `lines` (a session's events, its turn, up to where), `exit` (how its process ended, its last lines
// of stderr, the one it ended without a newline too), `closed` (the runner's socket closed with no exit said: what it
// read told before it, and its last lines of stderr), `left` (let go), `frozen` (each session's turn
// and live steps as they stand).

///|
priv struct Hosted {
  n : Int
  mut conn : Json
  /// what is written to the runner, in order (None: its side closed after)
  outq : @effect.Queue[Bytes?]
  turn : @claude.Turn
  live : @claude.Live
  calls : Array[String]
  /// what is held of each stream's line not ended yet
  out_part : @pieces.Pieces
  err_part : @pieces.Pieces
  /// where each stream's next line starts, as the runner counts bytes (-1: not said yet)
  mut out_at : Int64
  mut err_at : Int64
  mut acked_out : Int64
  /// up to where Node took what it was told (said, or a batch taken): what the runner is told once no batch kept
  /// before it waits (`advance_ack`)
  mut acked_to : Int64
  /// the end of what was last told Node in a message (where a batch told next begins)
  mut told_out : Int64
  mut acked_err : Int64
  /// the end of the last line told Node
  mut told : Int64
  /// how its lines are read: Claude Code's frames ("claude"), or a Codex app-server's JSON-RPC ("codex",
  /// agents_codex.mbt)
  kind : String
  /// a Codex app-server's threads (agents_codex.mbt)
  codex : Codex
  /// a DeepSeek Harness', Cursor's or an ACP runtime's session (agents_own.mbt)
  mut own : Own?
  /// up to where of stdout the runner may give the disk back, told with each ack (runner.ts `keep`)
  mut keep : Int64?
  /// lines that came while frozen, each with where it ends
  held : Array[(Bytes, Int64)]
  mut frozen : Bool
  /// What a step writes as it goes (the model's words, its thinking, a call's input), held a while and told Node as
  /// one (`DELTAS_MS`): up to where of stdout it was read, and whether its telling is under way
  mut pending : Array[@jsjson.JValue]
  mut pending_to : Int64
  /// the code units of the words held (`DELTAS_MOST`)
  mut pending_units : Int
  mut later : Bool
  mut left : Bool
  mut exited : Bool
  /// its socket closed with no end told: kept only until Node took, or let go, the batches told it last (`gone`)
  mut closed : Bool
  stderr : Array[String]
  /// its session's actor is in this program (Node said `route`): what it reads is told Node as a batch, kept here
  /// until Node says it took it (`routed`, actors.mbt), then given that actor here, not by Node
  mut routed : Bool
  batches : Map[Int, (Array[@jsjson.JValue], Int64)]
  /// a Codex app-server's batches' threads (each batch one thread's)
  batch_threads : Map[Int, String]
  /// where what each batch was told with begins (`told_out` as it was told)
  batch_before : Map[Int, Int64]
}

///|
priv struct Agents {
  host : @host.Host
  sessions : Map[Int, Hosted]
  /// the wall's time when Node last said it, and this clock's then
  mut wall : Double
  mut at : Int64
  mut next_batch : Int
  /// a Codex app-server's output read again after a crash (`codexReplay`): each thread's live steps as they come to
  replays : Map[Int, Map[String, @codex.Live]]
}

///|
fn Agents::now(self : Agents) -> Double {
  self.wall + (@host.now() - self.at).to_double()
}

///|
///|
fn Agents::new(host : @host.Host) -> Agents {
  { host, sessions: Map([]), wall: 0.0, at: @host.now(), next_batch: 0, replays: Map([]) }
}

///|
fn number(v : Json?) -> Int? {
  match v {
    Some(Number(n, ..)) => Some(n.to_int())
    _ => None
  }
}

///|
fn Agents::told(self : Agents, line : String) -> Unit {
  // (each key looked up in turn: one match of several keys' map patterns made a tree of every way they can be, 125 MB
  // of C for this function alone, which the C compiler did not get through)
  let said = @json.parse(line) catch { _ => return }
  guard said is Object(m) else { return }
  let num = (k : String) => match m.get(k) {
    Some(Number(v, ..)) => Some(v)
    _ => None
  }
  let text = (k : String) => match m.get(k) {
    Some(String(v)) => Some(v)
    _ => None
  }
  if num("wall") is Some(w) {
    self.wall = w
    self.at = @host.now()
  }
  if num("codexReplay") is Some(id) {
    if m.get("notices") is Some(Array(notices)) {
      self.replay(id.to_int(), notices)
    }
    return
  }
  if num("codexReplayed") is Some(id) {
    return self.replayed(id.to_int())
  }
  if num("attach") is Some(n) && text("socket") is Some(socket) {
    let turn = turn_of(m.get("turn"))
    let live = match m.get("live") {
      Some(Null) | None => @claude.Live::new()
      Some(state) if text("kind") is (None | Some("claude")) => @claude.Live::of_state(@jsjson.JValue::of_json(state))
      Some(_) => @claude.Live::new()
    }
    // (taken in now: what Node says of it next is had in order, whenever its socket opens)
    let kind = match text("kind") {
      Some("codex" as k) | Some("dsh" as k) | Some("cursor" as k) | Some("acp" as k) | Some("pi" as k) => k
      _ => "claude"
    }
    let h = hosted(n.to_int(), if kind == "claude" { turn } else { @claude.Turn::new() }, if kind == "claude" { live } else { @claude.Live::new() }, kind~)
    h.routed = m.get("routed") is Some(True)
    h.own = own_of(kind, m)
    if m.get("orphans") is Some(True) {
      h.codex.orphans = Some(Map([]))
    }
    self.sessions[h.n] = h
    ignore(self.host.rt.fork_daemon("agent", on_error=e => @host.note("agent failed: \{e}"), () => self.attach(h, socket)))
  }
  if num("freeze") is Some(id) {
    let states : Map[String, Json] = {}
    let only = match m.get("only") {
      Some(Array(ns)) => ns.filter_map(x => match x { Number(k, ..) => Some(k.to_int()); _ => None })
      _ => []
    }
    for k, h in self.sessions {
      if !only.contains(k) {
        continue
      }
      // (what it holds told first: the state said next is of all it read)
      self.flush(h)
      h.frozen = true
      states[k.to_string()] = if h.kind == "codex" {
        Json::object({ "threads": h.codex.states() })
      } else if h.own is Some(own) {
        Json::object({ "turn": to_json(own.turn()), "live": to_json(own.state()) })
      } else {
        Json::object({
          "turn": turn_json(h.turn),
          "live": h.live.state().to_json(),
        })
      }
    }
    self.host.say(({ "frozen": Json::number(id), "states": Json::object(states) } : Json).stringify())
    return
  }
  if num("ownReplay") is Some(id) {
    let at = num("at").unwrap_or(0.0).to_int64()
    let path = text("path").unwrap_or("")
    let kind = text("kind").unwrap_or("claude")
    ignore(self.host.rt.fork_daemon("agent replay", on_error=e => @host.note("agent replay failed: \{e}"), () => self.own_replay(id.to_int(), kind, path, at, m)))
    return
  }
  let ops = [
    "ack", "write", "signal", "begin", "aborting", "renewed", "done", "detach", "thaw", "keep", "route", "codexThread",
    "codexDrop", "orphans", "acpSession", "acpOpened", "acpPrompt", "acpInject",
  ]
  guard ops.iter().find_first(k => num(k) is Some(_)) is Some(op) else { return }
  guard self.sessions.get(num(op).unwrap().to_int()) is Some(h) else { return }
  // (its socket closed: Node let it go after what it took, the rest of what was told it let go with it, `gone`)
  if h.closed && (op == "done" || op == "detach") {
    h.batches.clear()
    h.batch_threads.clear()
    h.batch_before.clear()
    self.gone(h)
    return
  }
  match op {
    "ack" => if num("to") is Some(to) { self.acked(h, to.to_int64()) }
    "route" => {
      let on = m.get("on") is Some(True)
      match text("thread") {
        Some(thread) => self.route_thread(h, thread, on)
        None => {
          h.routed = on
          if !h.routed {
            h.batches.clear()
            h.batch_threads.clear()
            h.batch_before.clear()
            self.advance_ack(h)
            self.gone(h)
          }
        }
      }
    }
    "codexThread" => if text("id") is Some(thread) { self.add_thread(h, thread, m.get("live"), routed=m.get("routed") is Some(True)) }
    "codexDrop" => if text("id") is Some(thread) { self.drop_thread(h, thread) }
    "orphans" => if m.get("on") is Some(False) { self.orphans_off(h) }
    "write" => if text("line") is Some(t) { self.write(h, t) }
    "signal" =>
      if text("name") is Some(signal) {
        self.send(h, { "op": "signal", "signal": Json::string(signal), "group": true })
      }
    "begin" if h.own is Some(own) => self.own_begin(h, own)
    "acpSession" | "acpOpened" | "acpPrompt" | "acpInject" => self.acp_told(h, op, m)
    "aborting" if h.own is Some(own) => own.aborting()
    "begin" => {
      h.turn.renewed = Some(false)
      h.turn.busy = true
      if m.get("compact") is Some(True) {
        h.turn.compacting = Some(true)
        h.turn.compact_error = None
      }
    }
    "aborting" => h.turn.aborting = true
    "renewed" => h.turn.renewed = Some(true)
    "keep" => if num("at") is Some(at) { h.keep = Some(at.to_int64()) }
    "done" => {
      self.send(h, { "op": "done" })
      self.end(h)
    }
    "detach" => {
      h.frozen = true
      h.left = true
      h.held.clear()
      // (a pipe has no closing of one side: the runner is asked to close once it read to here, runner.ts `detach`)
      if m.get("leave") is Some(True) {
        self.send(h, { "op": "leave" })
      }
      self.end(h)
    }
    "thaw" => {
      h.frozen = false
      let held = h.held.copy()
      h.held.clear()
      if held.length() > 0 {
        self.heard(h, held)
      }
    }
    _ => ()
  }
}

///|
/// Node took what was read of it up to `to`: what was told it before is let go, and the runner told so.
/// Node said so only after every batch of what it took up to there that it took was said taken (`routed`, on stdin
/// before it), so a batch up to there still kept is one it did not take.
fn Agents::acked(self : Agents, h : Hosted, to : Int64) -> Unit {
  let done = h.batches.iter().filter_map(kv => if kv.1.1 <= to { Some(kv.0) } else { None }).collect()
  for k in done {
    h.batches.remove(k)
    h.batch_threads.remove(k)
    h.batch_before.remove(k)
  }
  if to > h.acked_to {
    h.acked_to = to
  }
  self.advance_ack(h)
  self.gone(h)
}

///|
/// The runner told what was taken: up to where Node took, but never past where a batch still kept begins (another
/// thread's of the same output, its `routed` on its way: a batch taken lets go of itself only).
fn Agents::advance_ack(self : Agents, h : Hosted) -> Unit {
  let mut limit = h.acked_to
  for _, before in h.batch_before {
    if before < limit {
      limit = before
    }
  }
  if limit > h.acked_out {
    h.acked_out = limit
    self.ack(h)
  }
}

///|
/// What is told Node of process `h` from where it was last told up to `to`, kept as batch `k` for its actor.
fn Agents::keep_batch(self : Agents, h : Hosted, events : Array[@jsjson.JValue], to : Int64) -> Int {
  let k = self.next_batch
  self.next_batch += 1
  h.batches[k] = (events, to)
  h.batch_before[k] = h.told_out
  k
}

///|
/// The events of batch `k` of process `n`, which Node took (`routed`), let go here: none when it was not kept (told
/// by a program before this one).
fn Agents::take(self : Agents, n : Int, k : Int) -> (Array[@jsjson.JValue], Int64)? {
  guard self.sessions.get(n) is Some(h) else { return None }
  guard h.batches.get(k) is Some(batch) else { return None }
  h.batches.remove(k)
  h.batch_threads.remove(k)
  h.batch_before.remove(k)
  if batch.1 > h.acked_to {
    h.acked_to = batch.1
  }
  self.advance_ack(h)
  self.gone(h)
  Some(batch)
}

///|
/// A process whose socket closed let go once no batch told Node of it waits to be taken.
fn Agents::gone(self : Agents, h : Hosted) -> Unit {
  if h.closed && h.batches.is_empty() && self.sessions.get(h.n) is Some(now) && physical_equal(now, h) {
    self.sessions.remove(h.n)
  }
}

///|
fn Agents::send(self : Agents, h : Hosted, message : Json) -> Unit {
  ignore(self)
  ignore(h.outq.try_offer(Some(@utf8.encode(message.stringify() + "\n"))))
}

///|
/// Its side of the runner's socket closed: the runner reads to there and closes it too.
fn Agents::end(self : Agents, h : Hosted) -> Unit {
  ignore(self)
  ignore(h.outq.try_offer(None))
}

///|
fn Agents::write(self : Agents, h : Hosted, text : String) -> Unit {
  ignore(self)
  // (the runner's message put together once as its bytes: a prompt of MBs is not copied again as a string, its base64
  // and its JSON)
  let line = @utf8.encode(text)
  let message = @buffer.new(size_hint=line.length() / 3 * 4 + 64)
  message.write_string_utf8("{\"op\":\"write\",\"data\":\"")
  @pieces.base64_into(message, line, if text.has_suffix("\n") { b"" } else { b"\n" })
  message.write_string_utf8("\"}\n")
  ignore(h.outq.try_offer(Some(message.to_bytes())))
}

///|
/// What of its output was taken said to the runner, which sends a next station only the rest.
fn Agents::ack(self : Agents, h : Hosted) -> Unit {
  if h.left {
    return
  }
  let ack : Map[String, Json] = {
    "op": "ack",
    "out": Json::number(h.acked_out.to_double()),
    "err": Json::number(h.acked_err.to_double()),
  }
  if h.keep is Some(k) {
    ack["keep"] = Json::number(k.to_double())
  }
  self.send(h, Json::object(ack))
}

///|
fn hosted(n : Int, turn : @claude.Turn, live : @claude.Live, kind~ : String) -> Hosted {
  {
    n,
    kind,
    codex: Codex::new(),
    own: None,
    keep: None,
    conn: Json::null(),
    outq: @effect.Queue::unbounded(),
    turn,
    live,
    calls: [],
    out_part: @pieces.Pieces::new(),
    err_part: @pieces.Pieces::new(),
    out_at: -1L,
    err_at: -1L,
    acked_out: 0L,
    acked_to: 0L,
    told_out: 0L,
    acked_err: 0L,
    told: 0L,
    held: [],
    frozen: false,
    pending: [],
    pending_to: 0L,
    pending_units: 0,
    later: false,
    left: false,
    exited: false,
    closed: false,
    stderr: [],
    routed: false,
    batches: Map([]),
    batch_threads: Map([]),
    batch_before: Map([]),
  }
}

///|
async fn Agents::attach(self : Agents, h : Hosted, socket : String) -> Unit {
  let n = h.n
  let opened = try { Ok(self.host.unix_open(socket)) } catch { e => Err(e) }
  guard opened is Ok(opened) else {
    self.sessions.remove(n)
    self.host.say(({ "closed": Json::number(n.to_double()) } : Json).stringify())
    return
  }
  h.conn = opened.id
  let socket = opened.socket
  // (what is written to it, one at a time in order)
  ignore(
    self.host.rt.fork_quiet(name="agent write", () => {
      // (attached first: what Node said meanwhile comes after)
      socket.write(@utf8.encode(({ "op": "attach" } : Json).stringify() + "\n")) catch {
        _ => ()
      }
      while (try { h.outq.take() } catch { _ => None }) is Some(bytes) {
        socket.write(bytes) catch { _ => () }
      }
      socket.end_write() catch { _ => () }
    }),
  )
  // (the runner's messages, each a line: only what a read brought is looked through for their ends)
  let carry = @pieces.Pieces::new()
  while true {
    let read = try { Ok(socket.read()) } catch { e => Err(e) }
    guard read is Ok(Some(bytes)) && bytes.length() > 0 else { break }
    for line in carry.lines(bytes) {
      let message = @json.parse(@utf8.decode_lossy(line)) catch { _ => Json::null() }
      if !h.left {
        self.message(h, message)
      }
    }
  }
  socket.destroy()
  if h.left || h.exited {
    self.sessions.remove(n)
  }
  if h.left {
    self.host.say(({ "left": Json::number(n.to_double()) } : Json).stringify())
  } else if !h.exited {
    // Its runner gone with no end told (killed, or the machine's memory short): what was read of it is told first, as
    // an end told is (`exit`), and its last words with it. Not where it is held for a handover: the station taking it
    // over reads on from what was acknowledged, and its turn goes on there.
    if !h.frozen {
      self.flush(h)
      self.cut_short(h)
    }
    stderr_rest(h)
    self.host.say(({ "closed": Json::number(n.to_double()), "stderr": Json::string(h.stderr.join("\n")) } : Json).stringify())
    // (what was told it in a batch is given its actor once Node says it took it: `take`)
    h.closed = true
    self.gone(h)
  } else {
    self.host.say(({ "ended": Json::number(n.to_double()) } : Json).stringify())
  }
}

///|
/// A message of the runner's.
fn Agents::message(self : Agents, h : Hosted, message : Json) -> Unit {
  match message {
    { "op": "out", "stream": String(stream), "at": Number(at, ..), "data": String(data), .. } => {
      let bytes = @base64.decode(data) catch { _ => return }
      let err = stream == "err"
      if err && h.err_at < 0L {
        h.err_at = at.to_int64()
      } else if !err && h.out_at < 0L {
        h.out_at = at.to_int64()
      }
      // (a line of hundreds of MB comes in thousands of pieces: each looked through once, the line put together once)
      let lines = []
      for line in (if err { h.err_part } else { h.out_part }).lines(bytes) {
        if err {
          h.err_at = h.err_at + (line.length() + 1).to_int64()
        } else {
          h.out_at = h.out_at + (line.length() + 1).to_int64()
        }
        lines.push((line, if err { h.err_at } else { h.out_at }))
      }
      if err {
        for l in lines {
          said_on_stderr(h, l.0)
          h.acked_err = l.1
        }
        if lines.length() > 0 && h.told <= h.acked_out {
          self.ack(h)
        }
      } else {
        if lines.length() == 0 {
          return
        }
        if h.frozen {
          h.held.append(lines)
        } else {
          self.heard(h, lines)
        }
      }
    }
    { "op": "exit", .. } => {
      self.flush(h)
      // (what a turn running had open ends with its process: its steps, what was being said)
      self.cut_short(h)
      // (its last words, where it ended before their newline: often why a runtime that would not start ended)
      stderr_rest(h)
      h.exited = true
      self.host.say(
        ({
          "exit": Json::number(h.n.to_double()),
          "code": message.value("code").unwrap_or(Json::null()),
          "signal": message.value("signal").unwrap_or(Json::null()),
          "stderr": Json::string(h.stderr.join("\n")),
        } : Json).stringify(),
      )
    }
    _ => ()
  }
}

///|
/// A line of its stderr kept, the last 3 of them told with its end (each of 300 characters at most).
fn said_on_stderr(h : Hosted, line : Bytes) -> Unit {
  let text = @jscase.trim(strip_cr(@utf8.decode_lossy(line)))
  if text != "" {
    h.stderr.push(text.view(end_offset=if text.length() > 300 { 300 } else { text.length() }).to_string())
    while h.stderr.length() > 3 {
      ignore(h.stderr.remove(0))
    }
  }
}

///|
/// What its stderr ended with and no newline after, kept as its last line.
fn stderr_rest(h : Hosted) -> Unit {
  if h.err_part.rest() is Some(line) {
    said_on_stderr(h, line)
  }
}

///|
/// What a turn running had open, ended with its process (DeepSeek Harness', Cursor's, an ACP runtime's): its steps,
/// what was being said, told after what it said before.
fn Agents::cut_short(self : Agents, h : Hosted) -> Unit {
  if h.own is Some(own) && !h.left {
    let events = own.cut_short()
    if events.length() > 0 {
      self.tell(h, h.told, own.turn(), events)
    }
  }
}

///|
fn strip_cr(s : String) -> String {
  if s.has_suffix("\r") {
    s.view(end_offset=s.length() - 1).to_string()
  } else {
    s
  }
}

///|
/// Lines of its stdout, each with where it ends: what they say told Node, or acknowledged at once where they say
/// nothing and nothing told is waiting.
fn Agents::heard(self : Agents, h : Hosted, lines : Array[(Bytes, Int64)]) -> Unit {
  if h.kind == "codex" {
    self.codex_heard(h, lines)
    return
  }
  if h.own is Some(own) {
    self.own_heard(h, own, lines)
    return
  }
  let before = @jsjson.stringify(turn_json_js(h.turn))
  let events : Array[@jsjson.JValue] = []
  for l in lines {
    let text = strip_cr(@utf8.decode_lossy(l.0))
    let frame = @jsjson.parse(text) catch { _ => continue }
    for e in h.live.feed(frame, () => self.now()) {
      events.push(@jsjson.JValue::Obj([("type", Str("live")), ("event", e)]))
    }
    if @claude.tools_lost_in(frame, h.calls) is Some(why) {
      events.push(Obj([("type", Str("toolsLost")), ("why", Str(why))]))
    }
    if renew_asked(frame) is Some(id) {
      events.push(Obj([("type", Str("renew")), ("requestId", Str(id))]))
    }
    @claude.on_frame(
      frame,
      h.turn,
      // (a turn's start and end said with the turn as it left it)
      e => events.push(
        match e {
          Obj(fields) if e.get("type") is Some(Str(t)) && (t == "turnStarted" || t == "turnEnded") =>
            Obj(fields + [("turn", turn_json_js(h.turn))])
          _ => e
        },
      ),
      () => self.write(h, interrupt_request(self.host)),
      () => self.now(),
      m => @host.note("agents: \{m}"),
    )
  }
  let end = lines[lines.length() - 1].1
  let turn = turn_json_js(h.turn)
  let same = @jsjson.stringify(turn) == before
  // (only what steps wrote: held, told with what comes next or once DELTAS_MS is over)
  if same && events.length() > 0 && events.iter().all(is_delta) {
    merge_into(h.pending, events)
    h.pending_units += units_of(events)
    h.pending_to = end
    h.told = end
    // (words past DELTAS_MOST told at once: a step's write of MBs is not held, nor joined again with each next)
    if h.pending_units >= DELTAS_MOST {
      self.flush(h)
    } else {
      self.soon(h)
    }
    return
  }
  if same && events.length() == 0 {
    if h.pending.length() > 0 {
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
  }
  let all = h.pending
  h.pending = []
  h.pending_units = 0
  merge_into(all, events)
  h.told = end
  self.tell(h, end, turn, all)
}

///|
/// The most code units of words held before they are told (`DELTAS_MS`): past it they are told at once, and two steps'
/// writes past it together are told as two.
const DELTAS_MOST : Int = 64 * 1024

///|
/// The code units of the words of deltas.
fn units_of(events : Array[@jsjson.JValue]) -> Int {
  let mut n = 0
  for e in events {
    if e.get("event") is Some(Obj(_) as ev) && ev.get("text") is Some(Str(t)) {
      n += t.length()
    }
  }
  n
}

///|
/// How long what steps write is held before Node is told it (it only counts how fast the model writes: sessions/live.ts
/// `counted`, the agent's last words: actor.ts `heard`).
const DELTAS_MS : Int = 200

///|
fn Agents::tell(
  self : Agents,
  h : Hosted,
  to : Int64,
  turn : @jsjson.JValue,
  events : Array[@jsjson.JValue],
  node~ : Array[(Bytes, Int64, Int64)] = [],
) -> Unit {
  let batch = if h.routed && events.length() > 0 {
    ",\"batch\":\{self.keep_batch(h, events, to)}"
  } else {
    ""
  }
  h.told_out = to
  // (one line put together once as its bytes: a step's write or a tool's output of MBs not copied again into it)
  let line = @buffer.new(size_hint=4096 + units_of(events))
  line.write_string_utf8("{\"lines\":\{h.n},\"to\":\{to},\"turn\":")
  @jsjson.write_utf8(line, turn)
  line.write_string_utf8(",\"events\":")
  @jsjson.write_utf8(line, Arr(events))
  // (the lines Node reads itself, their bytes after this line: each with where it begins and ends, and its length)
  let body = @buffer.new()
  if node.length() > 0 {
    let at = []
    for l in node {
      at.push("[\{l.1},\{l.2},\{l.0.length()}]")
      body.write_bytes(l.0)
    }
    line.write_string_utf8(",\"at\":[\{at.join(",")}],\"bytes\":\{body.length()}")
  }
  line.write_string_utf8("\{batch}}")
  self.host.say_bytes(line.to_bytes())
  if node.length() > 0 {
    self.host.out(body.to_bytes())
  }
}

///|
/// What is held told Node now.
fn Agents::flush(self : Agents, h : Hosted) -> Unit {
  if h.kind == "codex" {
    self.codex_flush(h)
    return
  }
  if h.pending.length() == 0 || h.left {
    return
  }
  let all = h.pending
  h.pending = []
  h.pending_units = 0
  let turn = match h.own {
    Some(own) => own.turn()
    None => turn_json_js(h.turn)
  }
  self.tell(h, h.pending_to, turn, all)
}

///|
fn Agents::soon(self : Agents, h : Hosted) -> Unit {
  if h.later {
    return
  }
  h.later = true
  ignore(
    self.host.rt.fork_daemon("agent deltas", on_error=e => @host.note("agent deltas failed: \{e}"), () => {
      @effect.sleep(DELTAS_MS)
      h.later = false
      self.flush(h)
    }),
  )
}

///|
fn is_delta(e : @jsjson.JValue) -> Bool {
  guard e.get("type") is Some(Str(t)) && t == "live" else { return false }
  guard e.get("event") is Some(Obj(_) as ev) else { return false }
  ev.get("kind") is Some(Str(k)) && k == "delta"
}

///|
/// `events` after `out`, a step's deltas one after another of the same field told as one: their words joined, or the
/// tokens a runtime counted for them added up.
fn merge_into(out : Array[@jsjson.JValue], events : Array[@jsjson.JValue]) -> Unit {
  let u = (s : String) => s
  for e in events {
    if is_delta(e) && out.last() is Some(last) && is_delta(last) {
      let a = last.get("event").unwrap()
      let b = e.get("event").unwrap()
      let tokens = (v : @jsjson.JValue) => match v.get("tokens") {
        Some(Num(n)) => Some(n)
        _ => None
      }
      let text = (v : @jsjson.JValue) => match v.get("text") {
        Some(Str(t)) => t
        _ => []
      }
      let same_step = a.get("id") is Some(Str(x)) && b.get("id") is Some(Str(y)) && x == y &&
        a.get("field") is Some(Str(f)) && b.get("field") is Some(Str(g)) && f == g &&
        // (none joined into words past DELTAS_MOST: each such write told as it came, not copied again)
        text(a).length() + text(b).length() <= DELTAS_MOST
      if same_step {
        match (tokens(a), tokens(b)) {
          (None, None) => {
            out[out.length() - 1] = Obj([
              (u("type"), Str(u("live"))),
              (u("event"), Obj([(u("kind"), Str(u("delta"))), (u("id"), a.get("id").unwrap()), (u("field"), a.get("field").unwrap()), (u("text"), Str(text(a) + text(b)))])),
            ])
            continue
          }
          (Some(x), Some(y)) if text(a).length() == 0 && text(b).length() == 0 => {
            out[out.length() - 1] = Obj([
              (u("type"), Str(u("live"))),
              (u("event"), Obj([(u("kind"), Str(u("delta"))), (u("id"), a.get("id").unwrap()), (u("field"), a.get("field").unwrap()), (u("text"), Str([])), (u("tokens"), Num(x + y))])),
            ])
            continue
          }
          _ => ()
        }
      }
    }
    out.push(e)
  }
}

///|
/// A frame asking for a new token (`oauth_token_refresh`): its request's id, as `String(frame.request_id ?? "")`.
fn renew_asked(frame : @jsjson.JValue) -> String? {
  guard frame is Obj(_) && frame.get("type") is Some(Str(t)) && t == "control_request" else { return None }
  guard frame.get("request") is Some(Obj(_) as r) && r.get("subtype") is Some(Str(s)) && s == "oauth_token_refresh" else {
    return None
  }
  match frame.get("request_id") {
    None | Some(Null) => Some([])
    Some(Str(s)) => Some(s)
    Some(v) => Some(@jsjson.stringify(v))
  }
}

///|
/// claude.ts `interruptRequest`.
fn interrupt_request(host : @host.Host) -> String {
  let answered = try { Some(host.shell_sync("crypto.random", { "bytes": 16 })) } catch { _ => None }
  let hex = match answered {
    Some(String(h)) if h.length() == 32 => h
    Some({ "value": String(h), .. }) if h.length() == 32 => h
    _ => "00000000000000000000000000000000"
  }
  let id = "\{hex.view(end_offset=8)}-\{hex.view(start_offset=8, end_offset=12)}-\{hex.view(start_offset=12, end_offset=16)}-\{hex.view(start_offset=16, end_offset=20)}-\{hex.view(start_offset=20)}"
  ({ "type": "control_request", "request_id": Json::string("interrupt-\{id}"), "request": { "subtype": "interrupt" } } : Json).stringify()
}

///|
/// The turn as claude.ts `ClaudeSnapshot.turn` says it.
fn turn_json_js(t : @claude.Turn) -> @jsjson.JValue {
  let u = (s : String) => s
  let fields : Array[(String, @jsjson.JValue)] = [
    (u("busy"), Bool(t.busy)),
    (u("aborting"), Bool(t.aborting)),
    (u("authFailure"), match t.auth_failure { Some(f) => Str(f); None => Null }),
  ]
  if t.renews is Some(r) {
    fields.push((u("renews"), Bool(r)))
  }
  if t.renewed is Some(r) {
    fields.push((u("renewed"), Bool(r)))
  }
  if t.tasks is Some(tasks) {
    fields.push((u("tasks"), Obj(tasks.map(e => {
      let k = e.1
      let task : Array[(String, @jsjson.JValue)] = [
        (u("id"), Str(k.id)),
        (u("kind"), Str(u(k.kind))),
        (u("description"), Str(k.description)),
        (u("background"), Bool(k.background)),
      ]
      if k.started_at is Some(at) {
        task.push((u("startedAt"), Num(at)))
      }
      (e.0, @jsjson.JValue::Obj(task))
    }))))
  }
  if t.compacting is Some(c) {
    fields.push((u("compacting"), Bool(c)))
  }
  match t.compact_error {
    Some(e) => fields.push((u("compactError"), Str(e)))
    None => if t.compacting is Some(_) { fields.push((u("compactError"), Null)) }
  }
  Obj(fields)
}

///|
fn turn_json(t : @claude.Turn) -> Json {
  turn_json_js(t).to_json()
}

///|
/// The turn Node said (a snapshot's, or what it read again after a crash).
fn turn_of(v : Json?) -> @claude.Turn {
  let t = @claude.Turn::new()
  guard v is Some(Object(m)) else { return t }
  let flag = (k : String) => match m.get(k) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
  let text = (k : String) => match m.get(k) {
    Some(String(s)) => Some(s)
    _ => None
  }
  t.busy = flag("busy").unwrap_or(false)
  t.aborting = flag("aborting").unwrap_or(false)
  t.auth_failure = text("authFailure")
  t.renews = flag("renews")
  t.renewed = flag("renewed")
  t.compacting = flag("compacting")
  t.compact_error = text("compactError")
  if m.get("tasks") is Some(Object(tasks)) {
    let kept = []
    for id, task in tasks {
      guard task is Object(k) else { continue }
      kept.push((id, @claude.Task::{
        id: match k.get("id") { Some(String(s)) => s; _ => id },
        kind: match k.get("kind") { Some(String("agent")) => "agent"; _ => "command" },
        description: match k.get("description") { Some(String(s)) => s; _ => "" },
        background: k.get("background") is Some(True),
        started_at: match k.get("startedAt") { Some(Number(n, ..)) => Some(n); _ => None },
      }))
    }
    t.tasks = Some(kept)
  }
  t
}
