// A connection's two halves and a listener's loop, over whatever transport a program gives them (its read, write,
// half close and close; its accept), on `@effect`, with no transport of their own. What each holds:
//   - `Socket`: its handle is closed once, and only once, whatever ends it: both halves done (the peer's end read and
//     its own end sent, in either order), a read, a write or a half close failing, or `destroy`; and closed whole
//     even where the fiber that ends it is being interrupted. A half-closed connection nobody closes is never left.
//   - `Listener`: a failure to accept that passes (too many open files, a connection reset before it was taken) is
//     told and tried again after a pause, never the end of the loop; only what the program calls fatal, or its close,
//     ends it. What serves each connection runs in the scope given, and what it fails with is told, never a defect.
//   - `pipe_duplex`: two sockets' bytes each way until both ends are done, an end passed on as a half close, either
//     failing ending both; nothing it does fails or is a defect, and both are closed as it returns, interrupted too.

///|
/// A write on a socket closed already (`Socket::destroy`, or ended by both its halves).
pub(all) suberror SocketClosed

///|
pub impl Show for SocketClosed with output(_, logger) {
  logger.write_string("the socket is closed")
}

///|
/// A connection: its transport's read (`None` at the peer's end), write, half close (no more writes; reads go on)
/// and close.
pub struct Socket {
  priv read_of : async () -> Bytes?
  priv write_of : async (Bytes) -> Unit
  priv end_write_of : async () -> Unit
  priv close_of : async () -> Unit
  /// The peer's end was read (or the socket closed): nothing more is read.
  priv mut read_over : Bool
  /// Its own end was sent (or the socket closed): nothing more is written.
  priv mut sent_end : Bool
  priv mut closed : Bool
}

///|
pub fn Socket::new(
  read~ : async () -> Bytes?,
  write~ : async (Bytes) -> Unit,
  end_write~ : async () -> Unit,
  close~ : async () -> Unit,
) -> Socket {
  {
    read_of: read,
    write_of: write,
    end_write_of: end_write,
    close_of: close,
    read_over: false,
    sent_end: false,
    closed: false,
  }
}

///|
/// What the peer sent next; `None` at its end, and once the socket is closed. A failure closes the socket and is
/// raised; the peer's end with its own end sent already closes it too.
pub async fn Socket::read(self : Socket) -> Bytes? {
  if self.closed || self.read_over {
    return None
  }
  let got = match (try Ok((self.read_of)()) catch { e => Err(e) }) {
    Ok(got) => got
    Err(e) => {
      self.destroy()
      raise e
    }
  }
  guard got is Some(_) else {
    self.read_over = true
    if self.sent_end {
      self.destroy()
    }
    return None
  }
  got
}

///|
/// `data` to the peer. A failure closes the socket and is raised; on a socket closed, or whose end was sent,
/// `SocketClosed`.
pub async fn Socket::write(self : Socket, data : Bytes) -> Unit {
  if self.closed || self.sent_end {
    raise SocketClosed
  }
  if (try Ok((self.write_of)(data)) catch { e => Err(e) }) is Err(e) {
    self.destroy()
    raise e
  }
}

///|
/// Its own end, sent once (more do nothing): with the peer's end read already, the socket is closed. A failure
/// closes the socket and is raised.
pub async fn Socket::end_write(self : Socket) -> Unit {
  if self.sent_end || self.closed {
    return
  }
  self.sent_end = true
  if (try Ok((self.end_write_of)()) catch { e => Err(e) }) is Err(e) {
    self.destroy()
    raise e
  }
  if self.read_over {
    self.destroy()
  }
}

///|
/// Closes it, once (more do nothing): its transport's close runs whole even where this fiber is being interrupted,
/// and what that close fails with is let go (the handle is gone either way).
pub async fn Socket::destroy(self : Socket) -> Unit noraise {
  if self.closed {
    return
  }
  self.closed = true
  self.read_over = true
  self.sent_end = true
  @effect.uninterruptible(() => (self.close_of)() catch { _ => () }) catch {
    _ => ()
  }
}

///|
pub fn Socket::is_closed(self : Socket) -> Bool {
  self.closed
}

///|
/// What takes connections: its transport's accept (`None` once it takes no more) and close.
pub struct Listener[C] {
  priv accept_of : async () -> C?
  priv close_of : async () -> Unit
  /// Whether a failure to accept ends the loop; any other is tried again after `retry_ms`.
  priv is_fatal : (Error) -> Bool
  priv retry_ms : Int
  priv mut closed : Bool
}

///|
pub fn[C] Listener::new(
  accept~ : async () -> C?,
  close~ : async () -> Unit,
  is_fatal? : (Error) -> Bool = _ => false,
  retry_ms? : Int = 100,
) -> Listener[C] {
  { accept_of: accept, close_of: close, is_fatal, retry_ms, closed: false }
}

///|
/// Takes connections until the transport takes no more, a failure to accept is fatal or the listener is closed: each
/// served by `on_conn` in a fiber of `scope`, what that fails with told to `on_error`. A failure to accept is told to
/// `on_error` too, and one that is not fatal tried again after `retry_ms`.
pub async fn[C] Listener::serve(
  self : Listener[C],
  scope : @effect.Scope,
  on_conn : async (C) -> Unit,
  on_error? : (Error) -> Unit = _ => (),
) -> Unit {
  while !self.closed {
    let got = (self.accept_of)() catch {
      e => {
        on_error(e)
        if self.closed || (self.is_fatal)(e) {
          return
        }
        // timer: a retry after a failure to accept (too many open files, a connection reset as it was taken)
        @effect.sleep(self.retry_ms)
        continue
      }
    }
    guard got is Some(conn) else { return }
    ignore(
      scope.fork(() => {
        on_conn(conn) catch {
          e => on_error(e)
        }
      }),
    )
  }
}

///|
/// Closes it, once (more do nothing): `serve` takes no more, and the transport's close runs whole even where this
/// fiber is being interrupted, what it fails with let go.
pub async fn[C] Listener::close(self : Listener[C]) -> Unit noraise {
  if self.closed {
    return
  }
  self.closed = true
  @effect.uninterruptible(() => (self.close_of)() catch { _ => () }) catch {
    _ => ()
  }
}

///|
/// `from`'s bytes to `to` until `from`'s end, passed on as `to`'s half close; whether it got there without a failure.
async fn pump(from : Socket, to : Socket) -> Bool noraise {
  try {
    while from.read() is Some(data) {
      to.write(data)
    }
    to.end_write()
    true
  } catch {
    _ => false
  }
}

///|
/// `a`'s bytes to `b` and `b`'s to `a` until both ends are done, each end passed on as the other's half close. Either
/// way failing closes both, which ends the other way; nothing it does fails or is a defect, and both are closed as it
/// returns, as it is interrupted too.
pub async fn pipe_duplex(a : Socket, b : Socket) -> Unit noraise {
  @effect.scoped(scope => {
    scope.add_finalizer(() => {
      a.destroy()
      b.destroy()
    })
    let broke : @effect.Deferred[Unit] = @effect.Deferred::new()
    let way = (from : Socket, to : Socket) => async fn() {
      if !pump(from, to) {
        a.destroy()
        b.destroy()
        ignore(broke.succeed(()))
      }
    }
    let ab = scope.fork(way(a, b), name="pipe a to b")
    let ba = scope.fork(way(b, a), name="pipe b to a")
    @effect.race(
      async fn() {
        ignore(ab.wait())
        ignore(ba.wait())
      },
      async fn() { broke.wait() },
    )
  }) catch {
    _ => ()
  }
}
