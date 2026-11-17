// station/src/terminals/link.ts: a terminal's runner, as the station holds it (native/runner `--pty`): the one
// connection a runner takes, its output as it comes, with its offsets, given to whoever listens, and what is asked of it
// (typing, a new size, the screen as it is). Its output is acknowledged as it comes, nothing kept: the runner's copy of
// the screen (`screen`) is what one who opens the terminal, or opens it again, is given, not the bytes since it began.

///|
/// Output from `at` (stdout's offset as the runner counts it).
pub(all) struct Out {
  at : Double
  bytes : Bytes
}

///|
/// The screen as it is, VT that makes it again in a new terminal of its size, and how much of the output made it.
pub(all) struct Shown {
  at : Double
  data : Bytes
  /// Its size, where the runner said one (`cols`, `rows`: numbers, as said).
  size : (Double, Double)?
}

///|
/// Its program's exit (`code`, `signal`: as the runner said them, `?? null`); a link ended with none is its runner gone.
pub(all) struct Ended {
  code : J
  signal : J
}

///|
pub fn Ended::to_json(self : Ended) -> J {
  jo([("code", self.code), ("signal", self.signal)])
}

///|
/// What the runner said: a line of JSON, or contiguous `out` chunks put together (runnerWire's).
pub(all) enum Said {
  Line(J)
  Output(Double, Bytes)
}

///|
/// What a link needs of a socket: the runner's, or a test's.
pub(all) struct Wire {
  write : (String) -> Unit
  end : () -> Unit
  on_line : ((Said) -> Unit) -> Unit
  on_close : (() -> Unit) -> Unit
}

///|
/// A runner's socket as runnerWire has it: what it writes, ends, whether it is writable, and what it is told.
pub(all) struct RunnerSocket {
  write : (String) -> Unit
  end : () -> Unit
  writable : () -> Bool
  on_data : ((Bytes) -> Unit) -> Unit
  on_close : (() -> Unit) -> Unit
  /// platform `runnerSaysLeave`: the runner is told `leave` before the socket ends (Windows' named pipes).
  says_leave : Bool
}

///|
/// The lines of a runner's socket, a read at a time (runnerWire's `data` handler): what is told of each read, contiguous
/// `out` chunks that came in it put together, a line that is not JSON passed over.
pub struct RunnerLines {
  priv mut carry : String
}

///|
pub fn RunnerLines::new() -> RunnerLines {
  { carry: "" }
}

///|
pub fn RunnerLines::read(self : RunnerLines, chunk : Bytes) -> Array[Said] {
  self.carry = self.carry + utf8_text(chunk)
  let told : Array[Said] = []
  let mut out_at = -1.0
  let mut out_end = -1.0
  let parts : Array[Bytes] = []
  let flush = () => {
    if parts.length() == 0 {
      return
    }
    let bytes = if parts.length() == 1 {
      parts[0]
    } else {
      let b = @buffer.new()
      for p in parts {
        b.write_bytes(p)
      }
      b.to_bytes()
    }
    parts.clear()
    told.push(Output(out_at, bytes))
    out_at = -1.0
    out_end = -1.0
  }
  while true {
    let i = match self.carry.find("\n") {
      Some(i) => i
      None => break
    }
    let line = self.carry.unsafe_substring(start=0, end=i)
    self.carry = self.carry.unsafe_substring(start=i + 1, end=self.carry.length())
    let message = parse(line) catch { _ => continue }
    if text(get(Some(message), "op")) == Some("out") &&
      text(get(Some(message), "stream")) == Some("out") &&
      num(get(Some(message), "at")) is Some(at) &&
      text(get(Some(message), "data")) is Some(data) {
      let bytes = from_base64(data)
      if parts.length() > 0 && at == out_end {
        parts.push(bytes)
        out_end += bytes.length().to_double()
      } else {
        flush()
        out_at = at
        out_end = at + bytes.length().to_double()
        parts.push(bytes)
      }
      continue
    }
    flush()
    told.push(Line(message))
  }
  flush()
  told
}

///|
/// runnerWire: a runner's socket, read as lines of JSON, coalescing contiguous `out` chunks that arrive in one read.
pub fn runner_wire(socket : RunnerSocket) -> Wire {
  let lines : Array[(Said) -> Unit] = []
  let closes : Array[() -> Unit] = []
  let reader = RunnerLines::new()
  (socket.on_data)(chunk => for m in reader.read(chunk) {
    for f in lines.copy() {
      f(m)
    }
  })
  (socket.on_close)(() => for f in closes.copy() {
    f()
  })
  {
    write: line => if (socket.writable)() { (socket.write)(line) },
    end: () => {
      if socket.says_leave && (socket.writable)() {
        (socket.write)(stringify(jo([("op", js("leave"))])) + "\n")
      }
      (socket.end)()
    },
    on_line: f => lines.push(f),
    on_close: f => closes.push(f),
  }
}

///|
priv enum LinkEnd {
  Running
  Over(Ended?)
}

///|
pub struct TerminalLink {
  priv wire : Wire
  priv listeners : Listeners[(Out) -> Unit]
  priv asked : Array[(Result[Shown, String]) -> Unit]
  priv ends : Listeners[(Ended?) -> Unit]
  /// Where the output is up to, as the runner counts it.
  priv mut at : Double
  priv mut ended : LinkEnd
}

///|
pub fn TerminalLink::new(wire : Wire) -> TerminalLink {
  let link : TerminalLink = {
    wire,
    listeners: Listeners::new(),
    asked: [],
    ends: Listeners::new(),
    at: 0.0,
    ended: Running,
  }
  (wire.on_line)(m => link.take(m))
  // Gone without an exit: the runner went (killed); no more comes.
  (wire.on_close)(() => link.end(None))
  link.send(jo([("op", js("attach"))]))
  link
}

///|
fn TerminalLink::take(self : TerminalLink, said : Said) -> Unit {
  let (m, given) = match said {
    Line(m) => (m, None)
    Output(at, bytes) => (jo([("op", js("out")), ("stream", js("out")), ("at", jn(at))]), Some(bytes))
  }
  match text(get(Some(m), "op")) {
    Some("out") => {
      guard text(get(Some(m), "stream")) == Some("out") && num(get(Some(m), "at")) is Some(at) else { return }
      let bytes = match given {
        Some(b) => b
        None =>
          match text(get(Some(m), "data")) {
            Some(d) => from_base64(d)
            None => return
          }
      }
      self.at = at + bytes.length().to_double()
      // Nothing kept: what is shown again comes from the screen.
      self.send(jo([("op", js("ack")), ("out", jn(self.at)), ("err", ji(0))]))
      self.listeners.each(f => f({ at, bytes }))
    }
    Some("screen") =>
      if self.asked.length() > 0 {
        let ask = self.asked.remove(0)
        match (num(get(Some(m), "at")), text(get(Some(m), "data"))) {
          (Some(at), Some(data)) => {
            let size = match (get(Some(m), "cols"), get(Some(m), "rows")) {
              (Some(Num(c)), Some(Num(r))) => Some((c, r))
              _ => None
            }
            ask(Ok({ at, data: from_base64(data), size }))
          }
          // (one asked and answered by something it cannot read is never answered: as the TypeScript's)
          _ => ()
        }
      }
    Some("error") =>
      // What failed is the oldest thing asked that waits for an answer (the runner answers in order).
      if self.asked.length() > 0 {
        let ask = self.asked.remove(0)
        let error = match get(Some(m), "error") {
          None | Some(Null) => "the runner refused"
          Some(v) => js_string_of(v)
        }
        ask(Err(error))
      }
    Some("exit") =>
      self.end(Some({ code: or_null(get(Some(m), "code")), signal: or_null(get(Some(m), "signal")) }))
    _ => ()
  }
}

///|
fn TerminalLink::end(self : TerminalLink, ended : Ended?) -> Unit {
  if self.ended is Over(_) {
    return
  }
  self.ended = Over(ended)
  let asked = self.asked.copy()
  self.asked.clear()
  for ask in asked {
    ask(Err("the terminal ended"))
  }
  self.ends.each(f => f(ended))
}

///|
fn TerminalLink::send(self : TerminalLink, message : J) -> Unit {
  (self.wire.write)(stringify(message) + "\n")
}

///|
/// Its output as it comes, until the returned function is called.
pub fn TerminalLink::listen(self : TerminalLink, f : (Out) -> Unit) -> () -> Unit {
  let id = self.listeners.add(f)
  () => self.listeners.delete(id)
}

///|
/// Once it ended: its exit (None: its runner went without one).
pub fn TerminalLink::ended(self : TerminalLink, f : (Ended?) -> Unit) -> () -> Unit {
  match self.ended {
    Over(e) => {
      f(e)
      () => ()
    }
    Running => {
      let id = self.ends.add(f)
      () => self.ends.delete(id)
    }
  }
}

///|
pub fn TerminalLink::over(self : TerminalLink) -> Bool {
  self.ended is Over(_)
}

///|
/// The screen as it is now: asked at once (the runner answers in order), its answer what the returned wait gives.
pub fn TerminalLink::screen(self : TerminalLink) -> @effect.Deferred[Result[Shown, String]] {
  let answer : @effect.Deferred[Result[Shown, String]] = @effect.Deferred::new()
  if self.ended is Over(_) {
    answer.succeed(Err("the terminal ended")) |> ignore
    return answer
  }
  self.asked.push(r => answer.succeed(r) |> ignore)
  self.send(jo([("op", js("screen"))]))
  answer
}

///|
pub fn TerminalLink::type_(self : TerminalLink, bytes : Bytes) -> Unit {
  if bytes.length() > 0 {
    self.send(jo([("op", js("write")), ("data", js(base64_of(bytes)))]))
  }
}

///|
pub fn TerminalLink::resize(self : TerminalLink, cols : Int, rows : Int) -> Unit {
  self.send(jo([("op", js("resize")), ("cols", ji(cols)), ("rows", ji(rows))]))
}

///|
/// Ends its program (and what it started: its group), then lets the runner clean up.
pub fn TerminalLink::kill(self : TerminalLink) -> Unit {
  self.send(jo([("op", js("signal")), ("signal", js("KILL")), ("group", jb(true))]))
  self.send(jo([("op", js("done"))]))
}

///|
/// The station lets go (stopping, handing over): the runner keeps the terminal for the next one.
pub fn TerminalLink::detach(self : TerminalLink) -> Unit {
  (self.wire.end)()
}

///|
/// What of `out` is past `at`: the part of a piece the screen did not have yet (none where it had all of it).
pub fn past_screen(out : Out, at : Double) -> Bytes? {
  let end = out.at + out.bytes.length().to_double()
  if end <= at {
    return None
  }
  if out.at >= at {
    Some(out.bytes)
  } else {
    let from = (at - out.at).to_int()
    Some(out.bytes[from:].to_bytes())
  }
}
