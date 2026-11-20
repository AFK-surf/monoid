// Connections in memory, two ends of one (a test's network, and what a bridge to another program stands on): streams
// opened on one end are accepted on the other, each a pipe both ways, written bytes read in order, a finish read as
// the end, a reset failing the other end's reads and writes, a close failing every stream and ending the accepting.

///|
priv enum Piece {
  Data(Bytes)
  Fin
  Reset(Int)
  Lost
}

///|
/// One way of a stream.
priv struct Pipe {
  pieces : @effect.Queue[Piece]
  mut done : Bool
  /// What its writer is told once it is taken to its end, or its reader stopped it.
  stopped : @effect.Deferred[Int?]
}

///|
fn Pipe::new() -> Pipe {
  { pieces: @effect.Queue::unbounded(), done: false, stopped: @effect.Deferred::new() }
}

///|
/// The two ends' state.
struct Wire {
  mut closed : (Int, Int, String)?
  ends : Array[End]
}

///|
priv struct End {
  id : String
  alpn : String
  coming : @effect.Queue[Stream?]
  pipes : Array[Pipe]
  closed : @effect.Deferred[String]
  mut reason : (String, String)?
  mut answers : Bool
}

///|
fn End::stream(_self : End, wire : Wire, from : Pipe, to : Pipe) -> Stream {
  let lost = () => match wire.closed {
    Some(_) => true
    None => false
  }
  {
    read: async fn() -> Bytes? {
      if from.done {
        return None
      }
      match from.pieces.take() {
        Data(b) => Some(b)
        Fin => {
          from.done = true
          ignore(from.stopped.succeed(None))
          None
        }
        Reset(code) => {
          from.done = true
          raise WireError("stream reset (\{code})")
        }
        Lost => {
          from.done = true
          raise WireError("connection lost")
        }
      }
    },
    write: fn(b : Bytes) raise {
      if lost() {
        raise WireError("connection lost")
      }
      if to.stopped.is_done() {
        raise WireError("stream stopped by peer")
      }
      ignore(to.pieces.try_offer(Data(b)))
    },
    finish: fn() raise {
      if lost() {
        raise WireError("connection lost")
      }
      ignore(to.pieces.try_offer(Fin))
    },
    stopped: async fn() -> Int? { to.stopped.wait() },
    reset: fn(code : Int) {
      ignore(to.pieces.try_offer(Reset(code)))
      ignore(from.stopped.succeed(Some(code)))
      ignore(to.stopped.succeed(Some(code)))
      ignore(from.pieces.try_offer(Reset(code)))
    },
    media_datagrams: None,
  }
}

///|
fn Wire::close(self : Wire, by : Int, code : Int, reason : String) -> Unit {
  guard self.closed is None else { return }
  self.closed = Some((by, code, reason))
  for i, e in self.ends {
    e.reason = Some(if i == by { ("local", reason) } else { ("application", reason) })
    ignore(e.coming.try_offer(None))
    for p in e.pipes {
      ignore(p.pieces.try_offer(Lost))
      ignore(p.stopped.succeed(None))
    }
    ignore(e.closed.succeed(reason))
  }
}

///|
pub fn Wire::connection(self : Wire, me : Int) -> Connection {
  let end = self.ends[me]
  let other = self.ends[1 - me]
  {
    remote_id: () => other.id,
    alpn: () => end.alpn,
    via: () => None,
    paths: None,
    accept_bi: async fn() -> Stream? {
      if self.closed is Some(_) {
        return None
      }
      match end.coming.take() {
        None => {
          ignore(end.coming.try_offer(None))
          None
        }
        s => s
      }
    },
    open_bi: fn() -> Stream raise {
      if self.closed is Some(_) {
        raise WireError("connection lost")
      }
      let out = Pipe::new()
      let back = Pipe::new()
      end.pipes.push(back)
      other.pipes.push(out)
      ignore(other.coming.try_offer(Some(other.stream(self, out, back))))
      end.stream(self, back, out)
    },
    answers: Some(fn(_ms : Int) -> Bool { self.closed is None && other.answers }),
    stats: None,
    close: (code, reason) => self.close(me, code, reason),
    is_closed: () => self.closed is Some(_),
    closed: async fn() -> String { end.closed.wait() },
    close_reason: Some(() => end.reason),
    handed: None,
  }
}

///|
/// A connection in memory between `a` and `b` (their endpoint ids), speaking `alpn`: what `a` dialled, and what `b`
/// accepted.
pub fn pair(a : String, b : String, alpn? : String = "") -> (Connection, Connection) {
  let w = link(a, b, alpn~)
  (w.connection(0), w.connection(1))
}

///|
/// A connection in memory between `a` (0, who dialled) and `b` (1), its two ends `Wire::connection` of each.
pub fn link(a : String, b : String, alpn? : String = "") -> Wire {
  let mk = (id : String) => {
    id,
    alpn,
    coming: @effect.Queue::unbounded(),
    pipes: [],
    closed: @effect.Deferred::new(),
    reason: None,
    answers: true,
  }
  { closed: None, ends: [mk(a), mk(b)] }
}

///|
/// Whether end `who` answers when the other asks whether it is there (a process killed with it open does not).
pub fn Wire::set_answers(self : Wire, who : Int, answers : Bool) -> Unit {
  self.ends[who].answers = answers
}

///|
/// How a connection in memory closed (the code and reason its closer said), as seen from either end: None while open.
pub fn closed_with(conn : Connection) -> (String, String)? {
  match conn.close_reason {
    Some(f) => f()
    None => None
  }
}


///|
/// Who closed it (0 or 1), with what code and reason; None while open.
pub fn Wire::closed_by(self : Wire) -> (Int, Int, String)? {
  self.closed
}
