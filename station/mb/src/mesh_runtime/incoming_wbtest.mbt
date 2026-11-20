///|
test "a connection's streams come in the order its other end opened them" {
  let i = Incoming::new()
  let rt = @effect.Runtime::new()
  let taken : Array[Int64?] = []
  let destroyed : Array[Int64] = []
  let mk = (id : Int64) => {
    let sock : Sock = {
      read: async fn() -> Bytes? { None },
      write: async fn(_) {  },
      end: async fn() {  },
      destroy: () => destroyed.push(id),
    }
    ({ held: Held::new(sock), carry: b"", id } : Came)
  }
  let take = () => {
    ignore(rt.fork(() => taken.push(i.take().map(c => c.id))))
    ignore(rt.run_ready())
  }
  i.give(mk(1L), index=Some(1L))
  take()
  i.skip(0L)
  ignore(rt.run_ready())
  i.give(mk(3L), index=Some(3L))
  i.give(mk(9L), index=None)
  i.skip(2L)
  ignore(rt.run_ready())
  take()
  take()
  i.end()
  ignore(rt.run_ready())
  i.give(mk(4L), index=Some(4L))
  take()
  assert_eq(taken, [Some(1L), Some(9L), Some(3L), None])
  assert_eq(destroyed, [4L])
}

///|
test "FrontStream::as_stream forwards media_datagrams RPC to the front and parses true/false" {
  let rt = @effect.Runtime::new()
  let reply_q : @effect.Queue[Bytes?] = @effect.Queue::unbounded()
  let sent : Array[Json] = []
  let answers : Array[Bool] = [true, false]
  let control_sock : Sock = {
    read: async fn() -> Bytes? { reply_q.take() },
    write: async fn(b) {
      let line = @utf8.decode_lossy(b[:]).trim().to_owned()
      let req = @json.parse(line) catch { _ => Json::null() }
      sent.push(req)
      let id = field(req, "id").unwrap_or(Json::number(0.0))
      let ok = if answers.length() > 0 { answers.remove(0) } else { false }
      let resp : Json = { "id": id, "ok": Json::boolean(ok) }
      ignore(reply_q.try_offer(Some(@utf8.encode(resp.stringify() + "\n"))))
    },
    end: async fn() { ignore(reply_q.try_offer(None)) },
    destroy: () => ignore(reply_q.try_offer(None)),
  }
  let listen_closed = @effect.Deferred::new()
  let sockets : Sockets = {
    connect: async fn(_) { control_sock },
    listen: async fn(_) {
      {
        accept: async fn() -> Sock? {
          listen_closed.wait()
          None
        },
        close: () => ignore(listen_closed.succeed(())),
      }
    },
    remove: async fn(_) { () },
  }
  let stream_end = @effect.Deferred::new()
  let stream_sock : Sock = {
    read: async fn() -> Bytes? {
      stream_end.wait()
      None
    },
    write: async fn(_) { () },
    end: async fn() { ignore(stream_end.succeed(())) },
    destroy: () => ignore(stream_end.succeed(())),
  }
  let results : Array[Bool] = []
  let errors : Array[String] = []
  let said : Said = (_, _, _, _) => ()
  ignore(
    rt.fork(async fn() {
      try {
        let front = Front::open(sockets, "/tmp/front.sock", 1, rt, said)
        let fs = FrontStream::new(front, 42L, { held: Held::new(stream_sock), carry: b"", id: 42L }, true)
        let door_stream = fs.as_stream()
        guard door_stream.media_datagrams is Some(md) else {
          errors.push("missing media_datagrams")
          return
        }
        results.push(md(777.0))
        results.push(md(888.0))
        ignore(stream_end.succeed(()))
        front.close()
      } catch {
        e => errors.push("\{e}")
      }
    }),
  )
  ignore(rt.run_ready())
  assert_eq(errors, [])
  assert_eq(results, [true, false])
  assert_eq(sent.length(), 2)
  assert_eq(field(sent[0], "op"), Some(Json::string("mediaDatagrams")))
  assert_eq(field(sent[0], "stream"), Some(Json::number(42.0)))
  assert_eq(field(sent[0], "token"), Some(Json::number(777.0)))
  assert_eq(field(sent[1], "op"), Some(Json::string("mediaDatagrams")))
  assert_eq(field(sent[1], "stream"), Some(Json::number(42.0)))
  assert_eq(field(sent[1], "token"), Some(Json::number(888.0)))
}
