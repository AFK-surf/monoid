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
