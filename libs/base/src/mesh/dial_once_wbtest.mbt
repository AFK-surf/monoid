// A connection dialled once on a protocol of its program's (dial_once.mbt), on the peer that answers by itself
// (stood_wbtest.mbt). The device's endpoint is handle 1, the one bound for the dial 2, its connection 3.

///|
/// A mesh on `r1` with an entry to it, as `Stood::made`.
fn dialling() -> (Stood, Peer, Mesh) raise {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.made([r1], binding={ lookup: true, takes: [], entries: entry(1) })
  (stood, far, mesh)
}

///|
/// The same, and a connection dialled once on "side/1", handed out.
fn dialled_once() -> (Stood, Peer, Mesh, Outgoing) raise {
  let (stood, far, mesh) = dialling()
  let out = gave(stood.go(() => mesh.dial_once(peer, "side/1")))
  (stood, far, mesh, out)
}

///|
/// Whether endpoint `end` and connection `conn` were both closed to be forgotten, and the mesh keeps none dialled.
fn Stood::let_go_of(self : Stood, mesh : Mesh, end : Int, conn : Int) -> Bool {
  self.forgot_ends.contains(end) && self.forgot.contains(conn) && mesh.outgoings.length() == 0
}

///|
test "dialled once: on an endpoint bound for it alone with a key of its own, on the mesh's relays and the caller's, its protocol as written; streams both ways; closed, both let go of, the device's endpoint untouched" {
  let (stood, far, mesh) = dialling()
  mesh.add_addr(peer, ips=["10.0.0.9:7"])
  let out = gave(stood.go(() => mesh.dial_once(peer, "side/1", relays=[r2, r1])))
  assert_eq((out.peer, out.alpn), (peer, "side/1"))
  // A key drawn for it: 32 bytes, not the device's.
  assert_eq(stood.bind_keys.length(), 2)
  assert_eq(stood.bind_keys[1].length(), 32)
  assert_true(stood.bind_keys[1] != stood.bind_keys[0])
  // Bound on the mesh's relays, then the caller's, each once; their entries; looked up as the mesh is; taking none.
  assert_eq(
    stood.binds[1],
    (
      {
        "relayUrls": [r1, r2],
        "relayOnly": false,
        "lookup": true,
        "relayEntries": [{ "entry": "https://e1.test/", "relay": r1 }],
      } : Json
    ).stringify(),
  )
  // Dialled on that endpoint, its protocol's bytes as the shell takes a dial's, where the peer is dialled straight.
  assert_eq(stood.times("iroh.connect 2"), 1)
  assert_true(stood.dial_alpns[0] == @utf8.encode("side/1"))
  assert_eq(stood.addrs[0], ({ "id": peer, "relays": [r1, r2], "ips": ["10.0.0.9:7"] } : Json).stringify())
  assert_eq(mesh.outgoings.length(), 1)
  // The peer's stream, taken, and one opened from here: each read and written as a taken connection's are.
  let s1 = far.open(3)
  far.sends(s1, b"hi")
  let theirs = gave(stood.go(() => out.accept())).unwrap()
  assert_eq(theirs.handle(), s1)
  assert_true(gave(stood.go(() => theirs.take())) == Some(b"hi"))
  let ours = gave(stood.go(() => out.open()))
  assert_eq(ended_as(stood.go(() => ours.out.write(b"ask"))), "ok")
  assert_true(far.got(ours.handle()) == b"ask")
  far.sends(ours.handle(), b"answer")
  assert_true(gave(stood.go(() => ours.take())) == Some(b"answer"))
  // Closed: the peer told why, the connection and its endpoint closed to be forgotten, the device's left be.
  let ended = stood.go(() => out.closed())
  out.close(reason="done")
  stood.run()
  assert_eq(gave(ended).reason, "done")
  assert_eq(far.closes, ["3 done"])
  assert_true(stood.let_go_of(mesh, 2, 3))
  assert_false(stood.unbound.contains(1))
  // Closed again, or asked after: nothing more of the shell.
  out.close()
  stood.run()
  assert_eq((stood.times("conn.close 3"), stood.times("iroh.close 2")), (1, 1))
  assert_true(gave(stood.go(() => out.accept())) is None)
  assert_true(ended_as(stood.go(() => out.open())).has_prefix("mesh: "))
}

///|
test "dialled once with no answer in time: given up at the shell, its endpoint closed to be forgotten, nothing kept; asked of a peer that is no id, or with no protocol, nothing is bound" {
  let (stood, far, mesh) = dialling()
  far.away = true
  let dialling = stood.go(() => mesh.dial_once(peer, "side/1", within=2_000))
  stood.rt.advance(1_999)
  assert_eq(ended_as(dialling), "waiting")
  stood.rt.advance(1)
  assert_eq(ended_as(dialling), "mesh: " + say("no_answer"))
  // (given up: the stood-in shell refuses the held dial, so none is left)
  assert_false(stood.held.iter().any(call => call.1 == "iroh.connect"))
  assert_true(stood.forgot_ends.contains(2) && mesh.outgoings.length() == 0)
  assert_false(stood.unbound.contains(1))
  // The shell refusing the dial: unreached, and let go of the same.
  far.away = false
  stood.holding = "iroh.connect"
  let refused = stood.go(() => mesh.dial_once(peer, "side/1"))
  stood.refuse("iroh.connect", "no route")
  assert_eq(ended_as(refused), "mesh: " + say("unreached"))
  assert_true(stood.forgot_ends.contains(3))
  stood.holding = ""
  let binds = stood.binds.length()
  assert_true(ended_as(stood.go(() => mesh.dial_once("nope", "side/1"))).has_prefix("invalid_params: "))
  assert_true(ended_as(stood.go(() => mesh.dial_once(peer, ""))).has_prefix("invalid_params: "))
  assert_eq(stood.binds.length(), binds)
}

///|
test "dialled once and cut by its caller, while the shell binds or while it dials: the bind is waited for, the dial given up, the endpoint closed to be forgotten, a connection that comes after closed too" {
  // Cut while the shell binds: it binds all the same, and what it binds is closed as it comes.
  let (stood, _, mesh) = dialling()
  stood.holding = "iroh.bind"
  let cutting = stood.go(() => mesh.dial_once(peer, "side/1"))
  cutting.interrupt()
  stood.run()
  assert_eq(ended_as(cutting), "waiting")
  stood.holding = ""
  stood.bound()
  assert_eq(ended_as(cutting), "interrupted")
  assert_eq(stood.times("iroh.connect 2"), 0)
  assert_true(stood.forgot_ends.contains(2) && mesh.outgoings.length() == 0)
  // Cut while it dials: given up at the shell.
  let (stood, far, mesh) = dialling()
  far.away = true
  let cutting = stood.go(() => mesh.dial_once(peer, "side/1"))
  cutting.interrupt()
  stood.run()
  assert_eq(ended_as(cutting), "interrupted")
  assert_false(stood.held.iter().any(call => call.1 == "iroh.connect"))
  assert_true(stood.forgot_ends.contains(2) && mesh.outgoings.length() == 0)
  // Cut in the turn its connection comes: whichever runs first, the connection is closed to be forgotten too.
  let (stood, far, mesh) = dialling()
  far.away = true
  let cutting = stood.go(() => mesh.dial_once(peer, "side/1"))
  stood.dial_answered()
  cutting.interrupt()
  stood.run()
  assert_eq(ended_as(cutting), "interrupted")
  assert_true(stood.let_go_of(mesh, 2, 3))
}

///|
test "dialled once and the mesh closed: one under way fails as closed and its endpoint goes; one handed out is told its end, its streams' askers told none, both let go of; one ended by its peer is let go of then" {
  // Under way.
  let (stood, far, mesh) = dialling()
  far.away = true
  let dialling = stood.go(() => mesh.dial_once(peer, "side/1"))
  assert_eq(ended_as(stood.go(() => mesh.close())), "ok")
  assert_eq(ended_as(dialling), "mesh: " + say("closed"))
  assert_true(stood.forgot_ends.contains(2) && stood.forgot_ends.contains(1))
  assert_false(stood.held.iter().any(call => call.1 == "iroh.connect"))
  assert_true(ended_as(stood.go(() => mesh.dial_once(peer, "side/1"))) == "mesh: " + say("closed"))
  // Handed out.
  let (stood, _, mesh, out) = dialled_once()
  let accepting = stood.go(() => out.accept())
  let ended = stood.go(() => out.closed())
  assert_eq(ended_as(stood.go(() => mesh.close())), "ok")
  assert_eq(gave(ended).kind, "local")
  assert_true(gave(accepting) is None)
  assert_true(stood.let_go_of(mesh, 2, 3))
  assert_eq((stood.times("conn.close 3"), stood.times("iroh.close 2")), (1, 1))
  // Ended by its peer: let go of as that is told, the mesh's close asking nothing more of it.
  let (stood, far, mesh, out) = dialled_once()
  far.end(3, "bye")
  assert_eq(gave(stood.go(() => out.closed())).reason, "bye")
  assert_true(out.ended() && stood.let_go_of(mesh, 2, 3))
  assert_eq(ended_as(stood.go(() => mesh.close())), "ok")
  assert_eq((stood.times("conn.close 3"), stood.times("iroh.close 2")), (1, 1))
  // Closed by its program in the turn the mesh closes, at whichever turn: each let go of once.
  for late in 0..<4 {
    let (stood, _, mesh, out) = dialled_once()
    let closing = stood.start(() => {
      for _ in 0..<late {
        @effect.pause()
      }
      mesh.close()
    })
    out.close()
    stood.run()
    assert_eq(ended_as(closing), "ok")
    assert_true(stood.let_go_of(mesh, 2, 3))
    assert_eq((stood.times("conn.close 3"), stood.times("iroh.close 2")), (1, 1))
  }
}
