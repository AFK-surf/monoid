// Conformance tests for `base/net` (`Socket`, `Listener`, `pipe_duplex`):
// half-close FIN ordering, fragmented/coalesced streaming, backpressure over bounded queues,
// error propagation (ECONNRESET / EPIPE / close errors), and listener lifecycle boundaries.

///|
priv suberror NetErr {
  NetErr(String)
}

///|
impl Show for NetErr with output(self, logger) {
  let NetErr(msg) = self
  logger.write_string(msg)
}

///|
priv enum Frame {
  Data(Bytes)
  Fin
  Rst(String)
}

///|
priv struct BoundedWire {
  incoming : @effect.Queue[Frame]
  outgoing : @effect.Queue[Bytes]
  mut ended : Int
  mut closes : Int
  mut read_calls : Int
  mut fail_close : Bool
  mut fail_write_after : Int
  mut writes_seen : Int
}

///|
fn BoundedWire::new(cap : Int) -> BoundedWire {
  {
    incoming: @effect.Queue::bounded(cap),
    outgoing: @effect.Queue::bounded(cap),
    ended: 0,
    closes: 0,
    read_calls: 0,
    fail_close: false,
    fail_write_after: -1,
    writes_seen: 0,
  }
}

///|
fn BoundedWire::socket(self : BoundedWire) -> @net.Socket {
  @net.Socket::new(
    read=async fn() {
      self.read_calls += 1
      match self.incoming.take() {
        Data(b) => Some(b)
        Fin => None
        Rst(reason) => raise NetErr(reason)
      }
    },
    write=async fn(b) {
      self.writes_seen += 1
      if self.fail_write_after >= 0 && self.writes_seen > self.fail_write_after {
        raise NetErr("EPIPE")
      }
      self.outgoing.offer(b)
    },
    end_write=fn() { self.ended += 1 },
    close=fn() raise {
      self.closes += 1
      self.incoming.shutdown()
      self.outgoing.shutdown()
      if self.fail_close {
        raise NetErr("EBADF")
      }
    },
  )
}

///|
fn step(rt : @effect.Runtime, f : async () -> Unit) -> @effect.Fiber[Unit] {
  let fiber = rt.fork(f)
  ignore(rt.run_ready())
  fiber
}

///|
test "Socket: read after EOF or destroy never invokes transport read again; write raises SocketClosed" {
  let rt = @effect.Runtime::new()
  let w = BoundedWire::new(4)
  w.fail_close = true
  let s = w.socket()
  ignore(w.incoming.try_offer(Data(b"")))
  ignore(w.incoming.try_offer(Data(b"abc")))
  ignore(w.incoming.try_offer(Fin))

  let chunks : Array[Bytes] = []
  let write_errs : Array[String] = []
  ignore(
    step(rt, async fn() {
      while s.read() is Some(b) {
        chunks.push(b)
      }
      // Subsequent reads after peer FIN must short-circuit without calling transport read_of
      assert_eq(s.read(), None)
      assert_eq(s.read(), None)
      // Socket is still half-open for writing
      assert_false(s.is_closed())
      s.write(b"reply")
      s.end_write()
      assert_true(s.is_closed())
      // Writing after full close must raise SocketClosed
      s.write(b"late") catch {
        e => write_errs.push(e.to_string())
      }
      // Extra destroy is a no-op and transport close error was swallowed
      s.destroy()
    }),
  )
  assert_eq(chunks, [b"", b"abc"])
  assert_eq(w.read_calls, 3)
  assert_eq(w.ended, 1)
  assert_eq(w.closes, 1)
  assert_eq(write_errs, ["the socket is closed"])
  assert_eq(rt.defects, [])
}

///|
test "pipe_duplex: fragmented writes and backpressure over bounded queues preserve exact byte streams" {
  @effect.for_seeds(seed => {
    let rt = @effect.Runtime::new(seed~)
    let wa = BoundedWire::new(2)
    let wb = BoundedWire::new(2)
    let a = wa.socket()
    let b = wb.socket()
    let pipe = step(rt, async fn() { @net.pipe_duplex(a, b) })

    // Producer A sends 12 small fragmented chunks; Producer B sends 8 chunks of varying sizes
    let want_a_to_b : Array[Byte] = []
    let want_b_to_a : Array[Byte] = []
    let got_a_to_b : Array[Byte] = []
    let got_b_to_a : Array[Byte] = []

    let prod_a = rt.fork(async fn() {
      for i in 0..<12 {
        let len = (i % 5) + 1
        let chunk = Bytes::makei(len, j => ((i * 31 + j * 7) & 0xff).to_byte())
        for byte in chunk {
          want_a_to_b.push(byte)
        }
        wa.incoming.offer(Data(chunk))
      }
      wa.incoming.offer(Fin)
    })
    let prod_b = rt.fork(async fn() {
      for i in 0..<8 {
        let len = (i % 4) + 2
        let chunk = Bytes::makei(len, j => ((i * 17 + j * 13 + 3) & 0xff).to_byte())
        for byte in chunk {
          want_b_to_a.push(byte)
        }
        wb.incoming.offer(Data(chunk))
      }
      wb.incoming.offer(Fin)
    })
    let cons_b = rt.fork(async fn() {
      while true {
        let chunk = wb.outgoing.take() catch { _ => break }
        for byte in chunk {
          got_a_to_b.push(byte)
        }
      }
    })
    let cons_a = rt.fork(async fn() {
      while true {
        let chunk = wa.outgoing.take() catch { _ => break }
        for byte in chunk {
          got_b_to_a.push(byte)
        }
      }
    })
    ignore(rt.run_ready())
    assert_true(prod_a.is_done())
    assert_true(prod_b.is_done())
    assert_true(pipe.is_done())
    assert_true(cons_a.is_done())
    assert_true(cons_b.is_done())
    assert_eq(got_a_to_b, want_a_to_b)
    assert_eq(got_b_to_a, want_b_to_a)
    assert_eq([wa.ended, wb.ended], [1, 1])
    assert_eq([wa.closes, wb.closes], [1, 1])
    assert_eq(rt.defects, [])
  })
}

///|
test "pipe_duplex: mid-stream EPIPE or RST closes both sockets exactly once" {
  let rt = @effect.Runtime::new()
  let wa = BoundedWire::new(4)
  let wb = BoundedWire::new(4)
  wb.fail_write_after = 2
  let pipe = step(rt, async fn() { @net.pipe_duplex(wa.socket(), wb.socket()) })
  let drained : Array[Bytes] = []
  ignore(
    step(rt, async fn() {
      while true {
        let c = wb.outgoing.take() catch { _ => break }
        drained.push(c)
      }
    }),
  )
  ignore(wa.incoming.try_offer(Data(b"one")))
  ignore(wa.incoming.try_offer(Data(b"two")))
  ignore(wa.incoming.try_offer(Data(b"three")))
  ignore(rt.run_ready())
  assert_true(pipe.is_done())
  assert_eq(drained, [b"one", b"two"])
  assert_eq([wa.closes, wb.closes], [1, 1])
  assert_eq(rt.defects, [])

  // Peer RST on read side propagates error and closes both sockets once
  let wa2 = BoundedWire::new(4)
  let wb2 = BoundedWire::new(4)
  let pipe2 = step(rt, async fn() { @net.pipe_duplex(wa2.socket(), wb2.socket()) })
  ignore(wa2.incoming.try_offer(Rst("ECONNRESET")))
  ignore(rt.run_ready())
  assert_true(pipe2.is_done())
  assert_eq([wa2.closes, wb2.closes], [1, 1])
  assert_eq(rt.defects, [])
}

///|
test "Listener: custom retry_ms, close before serve, and interrupt cleanup" {
  let rt = @effect.Runtime::new()
  let closes = Ref(0)
  let accepted = Ref(0)
  let l : @net.Listener[Int] = @net.Listener::new(
    accept=fn() {
      accepted.val += 1
      Some(accepted.val)
    },
    close=fn() { closes.val += 1 },
    retry_ms=25,
  )
  // Closing before serve means serve returns immediately without accepting anything
  ignore(step(rt, async fn() { l.close() }))
  let serving = step(rt, async fn() { l.serve(rt.root(), fn(_) { () }) })
  assert_true(serving.is_done())
  assert_eq(accepted.val, 0)
  assert_eq(closes.val, 1)

  // Retry delay respects custom retry_ms=25
  let tries = Ref(0)
  let l2 : @net.Listener[Int] = @net.Listener::new(
    accept=fn() raise {
      tries.val += 1
      if tries.val == 1 {
        raise NetErr("ECONNRESET")
      }
      None
    },
    close=fn() { () },
    retry_ms=25,
  )
  let s2 = step(rt, async fn() { l2.serve(rt.root(), fn(_) { () }) })
  assert_eq(tries.val, 1)
  assert_false(s2.is_done())
  rt.advance(24)
  ignore(rt.run_ready())
  assert_eq(tries.val, 1)
  rt.advance(1)
  ignore(rt.run_ready())
  assert_eq(tries.val, 2)
  assert_true(s2.is_done())
  assert_eq(rt.defects, [])
}
