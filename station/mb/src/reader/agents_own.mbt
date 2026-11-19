// A DeepSeek Harness, Cursor, ACP runtime's or Pi's process read here (`kind` "dsh", "cursor", "acp", "pi": agents.mbt),
// each a session of its own: its lines read as the TypeScript station read them (station/dsh, station/cursor, station/acp;
// Pi's RPC, which no TypeScript read before, station/pi:
// the live steps, the turn's start and end with its outcome, the station's tools out of reach, what the station keeps
// of an ACP runtime's transcript), told as Claude Code's are (the steps' words held DELTAS_MS, a batch given its
// session's actor here once Node took it), and the lines that answer Node's requests or ask something of it given Node
// as they are (`lines` with their bytes after it). What a crash reads again of a process's output is read here too
// (`ownReplay`), Claude Code's as well: the session, the turn and the live steps it comes to, told `ownReplayed`.
//
// Node says on stdin, besides agents.mbt's: `begin` (a prompt of its own given: the turn is asked for, with the model),
// `acpSession` (the session's id, as the runtime named it), `acpOpened` (it is open: what it says of its past before
// is no turn), `acpPrompt` (a prompt, its id and its words), `acpInject` (a prompt put in the running turn: `takeOver`
// where it is the one whose answer ends the turn), `ownReplay` (a runner's output to read again up to `at`).

///|
priv enum Own {
  Dsh(@dsh.Session)
  Cursor(@cursor.Session)
  Acp(@acp.Session)
  Pi(@pi.Session)
}

///|
fn to_json(v : @jsjson.JValue) -> Json {
  v.to_json()
}

///|
fn of_json(v : Json?) -> @jsjson.JValue? {
  match v {
    None | Some(Null) => None
    Some(x) => Some(@jsjson.JValue::of_json(x))
  }
}

///|
/// The session `attach` says (its turn and live steps as Node has them: none for one starting).
fn own_of(kind : String, m : Map[String, Json]) -> Own? {
  let turn = of_json(m.get("turn"))
  let live = of_json(m.get("live"))
  match kind {
    "dsh" =>
      Some(
        Dsh(@dsh.Session::new(@dsh.Turn::of_json(turn.unwrap_or(Null)), @dsh.Live::of_state(live.unwrap_or(Null)))),
      )
    "cursor" =>
      Some(
        Cursor(
          @cursor.Session::new(@cursor.Turn::of_json(turn.unwrap_or(Null)), @cursor.Live::of_state(live.unwrap_or(Null))),
        ),
      )
    "acp" => {
      let flavor = match m.get("flavor") {
        Some(String(f)) => f
        _ => "grok"
      }
      let kept = m.get("kept") is Some(True)
      Some(Acp(if live is Some(_) { @acp.Session::of_state(flavor, kept~, turn, live) } else { @acp.Session::new(flavor, kept~) }))
    }
    "pi" => Some(Pi(@pi.Session::new(@pi.Turn::of_json(turn.unwrap_or(Null)), @pi.Live::of_state(live.unwrap_or(Null)))))
    _ => None
  }
}

///|
fn Own::turn(self : Own) -> @jsjson.JValue {
  match self {
    Dsh(s) => s.turn.json()
    Cursor(s) => s.turn.json()
    Acp(s) => s.turn.json()
    Pi(s) => s.turn.json()
  }
}

///|
/// What a station taking it up goes on from (its snapshot's live steps; an ACP session's whole reading).
fn Own::state(self : Own) -> @jsjson.JValue {
  match self {
    Dsh(s) => s.live.state()
    Cursor(s) => s.live.state()
    Acp(s) => s.state()
    Pi(s) => s.live.state()
  }
}

///|
fn Own::aborting(self : Own) -> Unit {
  match self {
    Dsh(s) => s.turn.aborting = true
    Cursor(s) => s.turn.aborting = true
    Acp(s) => s.turn.aborting = true
    Pi(s) => s.turn.aborting = true
  }
}

///|
fn Own::cut_short(self : Own) -> Array[@jsjson.JValue] {
  match self {
    Dsh(s) => s.cut_short()
    Cursor(s) => s.cut_short()
    Acp(s) => s.cut_short()
    Pi(s) => s.cut_short()
  }
}

///|
/// A line's events, and whether Node reads the line.
fn Own::line(self : Own, v : @jsjson.JValue, now : () -> Double) -> (Array[@jsjson.JValue], Bool) {
  match self {
    Dsh(s) => {
      let said = s.line(v)
      (said.events, said.node)
    }
    Cursor(s) => {
      let said = s.line(v)
      (said.events, said.node)
    }
    Acp(s) => {
      let said = s.line(v, now)
      (said.events, said.node)
    }
    Pi(s) => {
      let said = s.line(v)
      (said.events, said.node)
    }
  }
}

///|
/// A turn's start and end said with the turn as it left it (what Node's session keeps of it).
fn with_turn(e : @jsjson.JValue, turn : @jsjson.JValue) -> @jsjson.JValue {
  match e {
    Obj(fields) if e.get("type") is Some(Str(t)) && (t == @jsjson.units("turnStarted") || t == @jsjson.units("turnEnded")) =>
      Obj(fields + [(@jsjson.units("turn"), turn)])
    _ => e
  }
}

///|
/// Lines of its stdout, each with where it ends: what they come to told Node, the steps' words held, or acknowledged
/// at once where they say nothing and nothing told is waiting (as agents.mbt `heard` does Claude Code's).
fn Agents::own_heard(self : Agents, h : Hosted, own : Own, lines : Array[(Bytes, Int64)]) -> Unit {
  let before = @jsjson.stringify(own.turn())
  let events : Array[@jsjson.JValue] = []
  let node : Array[(Bytes, Int64, Int64)] = []
  for l in lines {
    let line = strip_cr_bytes(l.0)
    let from = l.1 - (l.0.length() + 1).to_int64()
    let v = @jsjson.parse(@utf8.decode_lossy(line)) catch { _ => continue }
    let (said, to_node) = own.line(v, () => self.now())
    if to_node {
      node.push((line, from, l.1))
    }
    if said.length() > 0 {
      let turn = own.turn()
      for e in said {
        events.push(with_turn(e, turn))
      }
    }
  }
  let end = lines[lines.length() - 1].1
  let turn = own.turn()
  let same = @jsjson.stringify(turn) == before && node.length() == 0
  // (only what steps wrote: held, told with what comes next or once DELTAS_MS is over)
  if same && events.length() > 0 && events.iter().all(is_delta) {
    merge_into(h.pending, events)
    h.pending_units += units_of(events)
    h.pending_to = end
    h.told = end
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
  self.tell(h, end, turn, all, node~)
}

///|
/// Events of Node's doing (a prompt given, one put in the turn): told now, after what was held.
fn Agents::own_now(self : Agents, h : Hosted, own : Own, events : Array[@jsjson.JValue]) -> Unit {
  if events.length() == 0 || h.left {
    return
  }
  let all = h.pending
  h.pending = []
  h.pending_units = 0
  merge_into(all, events)
  self.tell(h, h.told, own.turn(), all)
}

///|
/// A prompt of Node's given (`begin`): DeepSeek Harness' and Pi's turn is asked for, Cursor's runs; all with the model.
fn Agents::own_begin(self : Agents, h : Hosted, own : Own) -> Unit {
  let events = match own {
    Dsh(s) => s.prompted()
    Cursor(s) => s.prompted()
    Pi(s) => s.prompted()
    Acp(_) => []
  }
  self.own_now(h, own, events)
}

///|
/// What Node says of an ACP session (`acpSession`, `acpOpened`, `acpPrompt`, `acpInject`).
fn Agents::acp_told(self : Agents, h : Hosted, op : String, m : Map[String, Json]) -> Unit {
  guard h.own is Some(Acp(s) as own) else { return }
  let text = (k : String) => match m.get(k) {
    Some(String(v)) => @jsjson.units(v)
    _ => []
  }
  match op {
    "acpSession" => s.session = text("id")
    "acpOpened" => s.loading = false
    "acpPrompt" => self.own_now(h, own, s.prompted(text("owner"), text("text")))
    "acpInject" => self.own_now(h, own, s.injected(text("id"), m.get("takeOver") is Some(True), text("text")))
    _ => ()
  }
}

///|
/// How much of an output is read at once again (process.ts `READ_CHUNK` before).
const REPLAY_CHUNK : Int = 1048576

///|
/// What a station that crashed had read of a process's output (its runner's file at `path`, up to `at`), read again:
/// what it comes to told Node (`ownReplayed`), as each driver's `crashed` read it before. Where the runner gave the disk
/// back (what was acknowledged long before) it reads as zeros, skipped with the line it cut (process.ts `bytesWithin`).
async fn Agents::own_replay(self : Agents, id : Int, kind : String, path : String, at : Int64, m : Map[String, Json]) -> Unit {
  let now = () => self.now()
  let claude_turn = @claude.Turn::new()
  let claude_live = @claude.Live::new()
  let dsh = @dsh.Replay::new()
  let cursor = @cursor.Replay::new()
  let pi = @pi.Replay::new()
  let flavor = match m.get("flavor") {
    Some(String(f)) => f
    _ => "grok"
  }
  let from_id = match m.get("resume") {
    Some(String(r)) => @jsjson.units(r)
    _ => []
  }
  let acp = @acp.Replay::new(flavor, kept=m.get("kept") is Some(True), from_id)
  let feed = (line : Bytes) => {
    let v = @jsjson.parse(@utf8.decode_lossy(strip_cr_bytes(line))) catch { _ => return }
    match kind {
      "claude" => {
        ignore(claude_live.feed(v, now))
        @claude.on_frame(v, claude_turn, _ => (), () => (), now, _ => ())
      }
      "dsh" => dsh.line(v)
      "cursor" => cursor.line(v)
      "acp" => acp.line(v)
      "pi" => pi.line(v)
      _ => ()
    }
  }
  let mut pieces = @pieces.Pieces::new()
  let mut pos = 0L
  while pos < at {
    let length = if at - pos < REPLAY_CHUNK.to_int64() { at - pos } else { REPLAY_CHUNK.to_int64() }
    // (read off this program's thread, client/shell's `fs.*`: a slow disk holds no other session read here meanwhile)
    let read = try {
      let (json, _) = self.host.shell("fs.bytes", { "path": Json::string(path), "from": Json::number(pos.to_double()), "length": Json::number(length.to_double()) })
      Some(json)
    } catch {
      _ => None
    }
    let bytes = match read {
      Some(String(hex)) => @hex.decode(hex) catch { _ => b"" }
      Some({ "value": String(hex), .. }) => @hex.decode(hex) catch { _ => b"" }
      _ => b""
    }
    if bytes.length() == 0 {
      break
    }
    let mut skip = 0
    if bytes[0] == b'\x00' {
      while skip < bytes.length() && bytes[skip] == b'\x00' {
        skip += 1
      }
      pieces = @pieces.Pieces::new()
    }
    for line in pieces.lines(if skip == 0 { bytes } else { bytes[skip:].to_bytes() }) {
      feed(line)
    }
    pos += bytes.length().to_int64()
    // (the others' turn between pieces: an output of MBs is not read as one wait of every session here)
    @effect.sleep(0)
  }
  let said : Map[String, Json] = { "ownReplayed": Json::number(id.to_double()) }
  let text = (s : Array[Int]?) => match s {
    Some(v) => Json::string(@jsjson.raw_text(v))
    None => Json::null()
  }
  match kind {
    "claude" => {
      said["turn"] = turn_json(claude_turn)
      said["live"] = to_json(claude_live.state())
    }
    "dsh" => {
      said["session"] = text(dsh.session)
      said["turn"] = to_json(dsh.turn.json())
      said["live"] = to_json(dsh.live.state())
    }
    "cursor" => {
      said["session"] = text(cursor.session)
      said["turn"] = to_json(cursor.turn.json())
      said["live"] = to_json(cursor.live.state())
    }
    "pi" => {
      said["session"] = Json::null()
      said["turn"] = to_json(pi.session.turn.json())
      said["live"] = to_json(pi.session.live.state())
    }
    "acp" => {
      let usages = acp.finish(now)
      let s = acp.session()
      said["session"] = Json::string(@jsjson.raw_text(s.session))
      said["turn"] = to_json(s.turn.json())
      said["live"] = to_json(s.state())
      said["opened"] = match acp.opened() {
        Some(o) => to_json(o)
        None => Json::null()
      }
      said["usages"] = Json::array(usages.map(to_json))
    }
    _ => ()
  }
  self.host.say(Json::object(said).stringify())
}
