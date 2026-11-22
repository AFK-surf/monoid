// What the live parts of P5-4 (the vault, the drive, the screens and the Helper, the browser, the phones and devices,
// the terminals and logins) share in the station's process: JSON between the two codecs the packages use (`Json`,
// the station's; `@jsjson.JValue`, JavaScript's), a call's arguments, the session a tool's call is of, the clock's
// `after`, the machine's processes followed as events (sys.mbt `spawn`) and a stream the shell opened.

///|
/// The session a tool is called for (the door's context: `session`, as the agents' side gives it).
fn p54_session(context : Json) -> String {
  jtext(context, "session").unwrap_or("")
}

///|
/// An error's words, without its kind's name where it says only that.
fn p54_message(e : Error) -> String {
  match e {
    Failure(m) => m
    BusError(m) => m
    SysError(m) => m
    _ => "\{e}"
  }
}

///|
/// A child of this process, its output and end given as they come (sys.mbt `spawn`, its events taken on a fiber).
priv struct P54Child {
  proc : Proc
  mut ended : (Int?, String?)?
  mut running : Bool
}

///|
/// `program` started, `out`, `err` and `close` called as it says and ends (Node's `spawn` with its events).
fn p54_spawn(
  host : @host.Host,
  program : String,
  args : Array[String],
  env? : Array[(String, String)],
  cwd? : String,
  stdin_piped? : Bool = true,
  group? : Bool = false,
  out? : (Bytes) -> Unit = _ => (),
  err? : (Bytes) -> Unit = _ => (),
  close? : (Int?, String?) -> Unit = (_, _) => (),
) -> P54Child raise SysError {
  let proc = spawn(host, program, args, env?, cwd?, stdin_piped~, stdout=Piped, stderr=Piped, group~)
  let child = { proc, ended: None, running: true }
  fork_bg(host, "child \{program}", async fn() {
    while true {
      match proc.events.take() {
        Out(b) => out(b)
        Err(b) => err(b)
        Exit(code, signal) => {
          child.ended = Some((code, signal))
          child.running = false
          close(code, signal)
          return
        }
      }
    }
  })
  child
}

///|
/// A stream the shell opened (`unix.open`, `tcp.open`): its bytes as they come, written, closed.
priv struct P54Conn {
  host : @host.Host
  id : Json
  mut closed : Bool
}

///|
async fn p54_unix_open(host : @host.Host, path : String) -> P54Conn {
  { host, id: host.unix_open(path).id, closed: false }
}

///|
async fn p54_tcp_open(host : @host.Host, port : Int) -> P54Conn {
  { host, id: host.tcp_open(port).id, closed: false }
}

///|
/// What came next on it; None at its end.
async fn P54Conn::read(self : P54Conn) -> Bytes? {
  if self.closed {
    return None
  }
  self.host.tcp_read(self.id) catch {
    _ => None
  }
}

///|
async fn P54Conn::write(self : P54Conn, b : Bytes) -> Unit {
  self.host.tcp_write(self.id, b)
}

///|
fn P54Conn::close(self : P54Conn) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  let host = self.host
  let id = self.id
  ignore(host.rt.fork_quiet(name="conn close", async fn() { host.tcp_close(id) }))
}

///|
/// Writes in their order, none waiting on the caller: a queue taken by a fiber of its own.
fn P54Conn::writer(self : P54Conn) -> (Bytes) -> Unit {
  let q : @effect.Queue[Bytes] = @effect.Queue::unbounded()
  fork_bg(self.host, "conn writes", async fn() {
    while !self.closed {
      let b = q.take()
      self.write(b) catch {
        _ => {
          self.close()
          return
        }
      }
    }
  })
  b => ignore(q.try_offer(b))
}
