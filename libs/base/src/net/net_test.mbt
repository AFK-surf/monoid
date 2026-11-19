// The sockets, the listener and the pipe over a transport of the test's (`Wire`: what the peer sends, queued by the
// test; what was written, ended and closed, counted), on a runtime of the test's own clock: nothing waits on real
// time. What each holds is in net.mbt's head; above all that a handle is closed exactly once, however it ends.

///|
priv suberror Fault {
  Fault(String)
}

///|
impl Show for Fault with output(self, logger) {
  let Fault(words) = self
  logger.write_string(words)
}

///|
priv enum Piece {
  Chunk(Bytes)
  End
  Broken
}

///|
priv struct Wire {
  incoming : @effect.Queue[Piece]
  written : Array[Bytes]
  mut ended : Int
  mut closes : Int
  /// How many closes ran to their end (a close waits on `gate` where there is one).
  mut closed_whole : Int
  mut fail_write : Bool
  mut fail_end : Bool
  mut gate : @effect.Deferred[Unit]?
}

///|
fn Wire::new() -> Wire {
  {
    incoming: @effect.Queue::unbounded(),
    written: [],
    ended: 0,
    closes: 0,
    closed_whole: 0,
    fail_write: false,
    fail_end: false,
    gate: None,
  }
}

///|
fn Wire::send(self : Wire, piece : Piece) -> Unit {
  ignore(self.incoming.try_offer(piece))
}

///|
/// A socket on it: a close wakes a read waiting on it with a failure, as a transport's does.
fn Wire::socket(self : Wire) -> @net.Socket {
  @net.Socket::new(
    read=async fn() {
      match self.incoming.take() {
        Chunk(b) => Some(b)
        End => None
        Broken => raise Fault("connection reset")
      }
    },
    write=fn(b) raise {
      if self.fail_write {
        raise Fault("broken pipe")
      }
      self.written.push(b)
    },
    end_write=fn() raise {
      if self.fail_end {
        raise Fault("not connected")
      }
      self.ended += 1
    },
    close=async fn() {
      self.closes += 1
      self.incoming.shutdown()
      if self.gate is Some(gate) {
        gate.wait()
      }
      self.closed_whole += 1
    },
  )
}

///|
/// `f` run in a fiber of `rt`, and everything ready after it.
fn run(rt : @effect.Runtime, f : async () -> Unit) -> @effect.Fiber[Unit] {
  let fiber = rt.fork(f)
  ignore(rt.run_ready())
  fiber
}

///|
test "the peer's end read, then its own sent: closed once" {
  let rt = @effect.Runtime::new()
  let w = Wire::new()
  let s = w.socket()
  w.send(Chunk(b"hi"))
  w.send(End)
  let got : Array[Bytes] = []
  ignore(
    run(rt, async fn() {
      while s.read() is Some(b) {
        got.push(b)
      }
    }),
  )
  assert_eq(got, [b"hi"])
  // (half closed: writes go on)
  assert_eq(w.closes, 0)
  assert_false(s.is_closed())
  ignore(
    run(rt, async fn() {
      s.write(b"back")
      s.end_write()
      s.end_write()
    }),
  )
  assert_eq(w.written, [b"back"])
  assert_eq(w.ended, 1)
  assert_eq(w.closes, 1)
  assert_true(s.is_closed())
  let after : Ref[Bytes?] = Ref(Some(b""))
  ignore(
    run(rt, async fn() {
      s.destroy()
      after.val = s.read()
    }),
  )
  assert_eq(after.val, None)
  assert_eq(w.closes, 1)
  assert_eq(rt.defects, [])
}

///|
test "its own end sent, then the peer's read: closed once" {
  let rt = @effect.Runtime::new()
  let w = Wire::new()
  let s = w.socket()
  let said : Array[String] = []
  ignore(
    run(rt, async fn() {
      s.end_write()
      s.write(b"late") catch {
        e => said.push(e.to_string())
      }
    }),
  )
  assert_eq(w.ended, 1)
  assert_eq(w.written, [])
  assert_eq(said, ["the socket is closed"])
  assert_eq(w.closes, 0)
  let ended = Ref(false)
  ignore(run(rt, async fn() { ended.val = s.read() is None }))
  // (the read waits for the peer)
  assert_false(ended.val)
  w.send(End)
  ignore(rt.run_ready())
  assert_true(ended.val)
  assert_eq(w.closes, 1)
  assert_true(s.is_closed())
  ignore(run(rt, async fn() { s.destroy() }))
  assert_eq(w.closes, 1)
  assert_eq(rt.defects, [])
}

///|
test "a read, a write or a half close failing closes it once, and is raised" {
  let rt = @effect.Runtime::new()
  let said : Array[String] = []
  let read = Wire::new()
  let r = read.socket()
  read.send(Broken)
  let write = Wire::new()
  let w = write.socket()
  write.fail_write = true
  let end = Wire::new()
  let e = end.socket()
  end.fail_end = true
  ignore(
    run(rt, async fn() {
      ignore(r.read()) catch {
        err => said.push("read: \{err}")
      }
      w.write(b"x") catch {
        err => said.push("write: \{err}")
      }
      e.end_write() catch {
        err => said.push("end: \{err}")
      }
      r.destroy()
      w.destroy()
      e.destroy()
    }),
  )
  assert_eq(said.length(), 3)
  assert_eq([read.closes, write.closes, end.closes], [1, 1, 1])
  assert_true(r.is_closed() && w.is_closed() && e.is_closed())
  assert_eq(rt.defects, [])
}

///|
test "a read interrupted leaves it open; destroyed meanwhile it is closed once" {
  let rt = @effect.Runtime::new()
  let w = Wire::new()
  let s = w.socket()
  let reader = run(rt, async fn() { ignore(s.read()) })
  ignore(run(rt, async fn() { ignore(reader.interrupt_and_wait()) }))
  assert_true(reader.is_done())
  assert_eq(w.closes, 0)
  ignore(run(rt, async fn() { s.destroy() }))
  assert_eq(w.closes, 1)
  // A read waiting as another fiber destroys it is woken, its failure raised.
  let v = Wire::new()
  let t = v.socket()
  let woke : Array[String] = []
  ignore(
    run(rt, async fn() {
      ignore(t.read()) catch {
        _ => woke.push("failed")
      }
    }),
  )
  ignore(run(rt, async fn() { t.destroy() }))
  assert_eq(woke, ["failed"])
  assert_eq(v.closes, 1)
  assert_eq(rt.defects, [])
}

///|
test "a destroy interrupted as its close runs closes it whole, once" {
  let rt = @effect.Runtime::new()
  let w = Wire::new()
  let gate : @effect.Deferred[Unit] = @effect.Deferred::new()
  w.gate = Some(gate)
  let s = w.socket()
  let destroying = run(rt, async fn() { s.destroy() })
  assert_eq(w.closes, 1)
  assert_eq(w.closed_whole, 0)
  destroying.interrupt()
  ignore(rt.run_ready())
  // (the close goes on through the interruption)
  assert_eq(w.closed_whole, 0)
  ignore(gate.succeed(()))
  ignore(rt.run_ready())
  assert_true(destroying.is_done())
  assert_eq(w.closes, 1)
  assert_eq(w.closed_whole, 1)
  ignore(run(rt, async fn() { s.destroy() }))
  assert_eq(w.closes, 1)
  assert_eq(rt.defects, [])
}

///|
test "a listener goes on past failures to accept that pass, and serves what comes" {
  let rt = @effect.Runtime::new()
  let calls = Ref(0)
  let coming : @effect.Queue[Int?] = @effect.Queue::unbounded()
  let listener : @net.Listener[Int] = @net.Listener::new(
    accept=async fn() {
      calls.val += 1
      if calls.val <= 3 {
        raise Fault("EMFILE")
      }
      coming.take()
    },
    close=fn() { () },
  )
  let errors : Array[String] = []
  let served : Array[Int] = []
  let serving = run(rt, async fn() {
    listener.serve(
      rt.root(),
      fn(conn) raise {
        if conn == 2 {
          raise Fault("served badly")
        }
        served.push(conn)
      },
      on_error=e => errors.push(e.to_string()),
    )
  })
  assert_eq(errors.length(), 1)
  rt.advance(99)
  ignore(rt.run_ready())
  assert_eq(calls.val, 1)
  rt.advance(1)
  ignore(rt.run_ready())
  assert_eq(calls.val, 2)
  rt.advance(100)
  ignore(rt.run_ready())
  rt.advance(100)
  ignore(rt.run_ready())
  assert_eq(calls.val, 4)
  assert_eq(errors.length(), 3)
  ignore(coming.try_offer(Some(1)))
  ignore(coming.try_offer(Some(2)))
  ignore(coming.try_offer(Some(3)))
  ignore(rt.run_ready())
  assert_eq(served, [1, 3])
  assert_eq(errors.length(), 4)
  assert_false(serving.is_done())
  ignore(coming.try_offer(None))
  ignore(rt.run_ready())
  assert_true(serving.is_done())
  assert_eq(rt.defects, [])
}

///|
test "a listener ends at a fatal failure, and at its close" {
  let rt = @effect.Runtime::new()
  let calls = Ref(0)
  let fatal : @net.Listener[Int] = @net.Listener::new(
    accept=fn() raise {
      calls.val += 1
      raise Fault("bad descriptor")
    },
    close=fn() { () },
    is_fatal=e => e is Fault("bad descriptor"),
  )
  let errors : Array[String] = []
  let serving = run(rt, async fn() {
    fatal.serve(rt.root(), fn(_) { () }, on_error=e => errors.push(e.to_string()))
  })
  assert_true(serving.is_done())
  assert_eq(calls.val, 1)
  assert_eq(errors.length(), 1)
  // Closed as it waits to accept: its accept fails, and it ends.
  let waiting : @effect.Deferred[Int?] = @effect.Deferred::new()
  let closes = Ref(0)
  let closed : @net.Listener[Int] = @net.Listener::new(
    accept=async fn() { waiting.wait() },
    close=fn() {
      closes.val += 1
      ignore(waiting.fail(Fault("closed")))
    },
  )
  let serving = run(rt, async fn() { closed.serve(rt.root(), fn(_) { () }) })
  assert_false(serving.is_done())
  ignore(
    run(rt, async fn() {
      closed.close()
      closed.close()
    }),
  )
  assert_true(serving.is_done())
  assert_eq(closes.val, 1)
  assert_eq(rt.defects, [])
}

///|
/// Two wires piped, `a`'s pieces and `b`'s sent in an order of the seed's, each followed by what is ready.
fn piped(seed : Int, a_sends : Array[Piece], b_sends : Array[Piece]) -> (@effect.Runtime, Wire, Wire, @effect.Fiber[Unit]) {
  let rt = @effect.Runtime::new(seed~)
  let wa = Wire::new()
  let wb = Wire::new()
  let a = wa.socket()
  let b = wb.socket()
  let pipe = run(rt, async fn() { @net.pipe_duplex(a, b) })
  let mut i = 0
  let mut j = 0
  while i < a_sends.length() || j < b_sends.length() {
    if j >= b_sends.length() || (i < a_sends.length() && rt.rng.below(2) == 0) {
      wa.send(a_sends[i])
      i += 1
    } else {
      wb.send(b_sends[j])
      j += 1
    }
    ignore(rt.run_ready())
  }
  (rt, wa, wb, pipe)
}

///|
test "a pipe carries both ways and passes each end on, closing both once" {
  @effect.for_seeds(seed => {
    let (rt, wa, wb, pipe) = piped(seed, [Chunk(b"a1"), Chunk(b"a2"), End], [Chunk(b"b1"), End])
    assert_true(pipe.is_done())
    assert_eq(wb.written, [b"a1", b"a2"])
    assert_eq(wa.written, [b"b1"])
    assert_eq([wa.ended, wb.ended], [1, 1])
    assert_eq([wa.closes, wb.closes], [1, 1])
    assert_eq(rt.defects, [])
  })
}

///|
test "a pipe one side of which breaks closes both once, with no defect" {
  @effect.for_seeds(seed => {
    let (rt, wa, wb, pipe) = piped(seed, [Chunk(b"a1"), Broken], [Chunk(b"b1")])
    assert_true(pipe.is_done())
    assert_eq(wb.written, [b"a1"])
    assert_eq([wa.closes, wb.closes], [1, 1])
    assert_eq(rt.defects, [])
  })
}

///|
test "a pipe whose write fails closes both once, with no defect" {
  @effect.for_seeds(seed => {
    let rt = @effect.Runtime::new(seed~)
    let wa = Wire::new()
    let wb = Wire::new()
    wb.fail_write = true
    let pipe = run(rt, async fn() { @net.pipe_duplex(wa.socket(), wb.socket()) })
    wa.send(Chunk(b"a1"))
    ignore(rt.run_ready())
    assert_true(pipe.is_done())
    assert_eq([wa.closes, wb.closes], [1, 1])
    assert_eq(rt.defects, [])
  })
}

///|
test "a pipe interrupted closes both once, with no defect" {
  @effect.for_seeds(seed => {
    let (rt, wa, wb, pipe) = piped(seed, [Chunk(b"a1")], [Chunk(b"b1"), End])
    assert_false(pipe.is_done())
    assert_eq(wa.written, [b"b1"])
    assert_eq(wa.ended, 1)
    let exit : Ref[String] = Ref("")
    ignore(
      run(rt, async fn() {
        exit.val = if pipe.interrupt_and_wait() is Interrupted { "interrupted" } else { "ended" }
      }),
    )
    assert_eq(exit.val, "interrupted")
    assert_eq(wb.written, [b"a1"])
    assert_eq([wa.closes, wb.closes], [1, 1])
    assert_eq(rt.defects, [])
  })
}
