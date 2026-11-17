// What the endpoint is bound with, its relays told again, and the connections peers dial to it (bind.mbt). On the
// peer that answers by itself (stood_wbtest.mbt). The endpoint is handle 1; one bound anew is the next handle then.

///|
let r1 : String = "https://r1.test/"

///|
let r2 : String = "https://r2.test/"

///|
let r3 : String = "https://r3.test/"

///|
/// A mesh on `relays`, bound with `binding`.
fn Stood::made(self : Stood, relays : Array[String], binding? : Binding = Binding::none(), relay_only? : Bool = false) -> Mesh raise {
  let made = self.go(() => Mesh::make(
    self.shell.val.unwrap(),
    { get: _ => Some(Bytes::make(32, b'\x01')), set: (_, _) => () },
    { alpn: "test/1", relays, relay_only, says: None, refusal: None },
    binding~,
  ))
  guard made.poll() is Some(Succeeded(mesh)) else { fail("the mesh was not made: \{self.said.join(", ")}") }
  mesh
}

///|
/// A mesh that takes connections on "pair/1".
fn taking() -> (Stood, Peer, Mesh) raise {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.made([r1], binding={ lookup: false, takes: ["pair/1"], entries: [] })
  (stood, far, mesh)
}

///|
/// The same, and a connection a peer dialled, taken: its handle at the shell too.
fn taken() -> (Stood, Peer, Mesh, Incoming, Int) raise {
  let (stood, far, mesh) = taking()
  let asking = stood.go(() => mesh.incoming())
  let conn = far.comes("pair/1")
  guard gave(asking) is Some(incoming) else { fail("no connection was given") }
  (stood, far, mesh, incoming, conn)
}

///|
/// The handle of a taken connection at the stood-in shell.
fn Incoming::conn_handle(self : Incoming) -> Int {
  handle_of({ "id": self.conn })
}

///|
/// One entry to `r1`, told apart by `n`.
fn entry(n : Int) -> Array[RelayEntry] {
  [{ entry: "https://e\{n}.test/", relay: r1 }]
}

///|
/// A mesh that takes connections on "pair/1" whose endpoint is taken for stuck: a dial ran out of time unanswered,
/// so the next link binds it anew. The peer answers dials again.
fn taking_stuck() -> (Stood, Peer, Mesh) raise {
  let (stood, far, mesh) = taking()
  far.away = true
  let failing = stood.go(() => mesh.link(peer, Source::new().gives()))
  stood.rt.advance(connect_timeout_ms)
  guard ended_as(failing) == "mesh: " + say("no_answer") && mesh.stuck else { fail("the endpoint is not taken for stuck") }
  far.away = false
  (stood, far, mesh)
}

// ── what it is bound with ──

///|
test "an endpoint is bound as it always was where its program says nothing more, and with what it says where it says any: peers looked up, the protocols it takes in hex, its relays' entries" {
  let (stood, _) = Stood::with_peer()
  ignore(stood.mesh())
  assert_eq(stood.binds, ["{\"relayUrls\":[],\"relayOnly\":true,\"lookup\":false}"])
  let entries : Array[RelayEntry] = [{ entry: "https://e1.test/", relay: r1 }]
  let (stood, _) = Stood::with_peer()
  ignore(stood.made([r1, r2], binding={ lookup: true, takes: ["pair/1", "é"], entries }))
  assert_eq(stood.binds, [
    "{\"relayUrls\":[\"https://r1.test/\",\"https://r2.test/\"],\"relayOnly\":false,\"lookup\":true,\"alpns\":[\"706169722f31\",\"c3a9\"],\"relayEntries\":[{\"entry\":\"https://e1.test/\",\"relay\":\"https://r1.test/\"}]}",
  ])
  // Looked up only where there is somewhere to go by it: not through relays alone, not with no relay.
  let (stood, _) = Stood::with_peer()
  ignore(stood.made([r1], binding={ lookup: true, takes: [], entries: [] }, relay_only=true))
  assert_eq(stood.binds, ["{\"relayUrls\":[\"https://r1.test/\"],\"relayOnly\":true,\"lookup\":false}"])
  let (stood, _) = Stood::with_peer()
  ignore(stood.made([], binding={ lookup: true, takes: [], entries: [] }))
  assert_eq(stood.binds, ["{\"relayUrls\":[],\"relayOnly\":false,\"lookup\":false}"])
  // What it was given is its own from there: its program's arrays, changed after, change nothing of it.
  let (stood, _) = Stood::with_peer()
  let relays = [r1]
  let entries = entry(1)
  let mesh = stood.made(relays, binding={ lookup: false, takes: [], entries })
  relays[0] = r2
  entries[0] = { entry: "https://e9.test/", relay: r1 }
  mesh.retune([r1], entries=entry(1))
  stood.run()
  assert_eq((stood.said, mesh.relays), (["iroh.bind 0"], [r1]))
  assert_true(mesh.entries == entry(1))
  let again = entry(2)
  mesh.retune([r1], entries=again)
  again[0] = { entry: "https://e9.test/", relay: r1 }
  stood.run()
  assert_true(mesh.entries == entry(2))
  assert_eq(stood.entries, ["[{\"entry\":\"https://e2.test/\",\"relay\":\"https://r1.test/\"}]"])
  let told = [r3]
  mesh.retune(told)
  told[0] = r1
  stood.run()
  assert_eq((mesh.relays, stood.binds.length()), ([r3], 2))
  assert_true(stood.binds[1].contains("\"relayUrls\":[\"https://r3.test/\"]") && !stood.binds[1].contains("relayEntries"))
}

// ── the relays told again ──

///|
test "relays told again as they are: nothing is asked; their entries alone changed: the endpoint is told them, and its links stay" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.made([r1])
  let link = stood.opened(mesh, Source::new().gives())
  let said = stood.said.length()
  mesh.retune([r1])
  stood.run()
  assert_eq(stood.said.length(), said)
  let entries : Array[RelayEntry] = [{ entry: "https://e1.test/", relay: r1 }]
  mesh.retune([r1], entries~)
  stood.run()
  assert_eq(stood.entries, ["[{\"entry\":\"https://e1.test/\",\"relay\":\"https://r1.test/\"}]"])
  assert_eq((stood.times("iroh.setRelayEntries 1"), stood.binds.length(), far.closes.length()), (1, 1, 0))
  assert_true(link.usable() && mesh.current(peer) is Some(now) && physical_equal(now, link))
  // The same again: nothing. None again: told none.
  mesh.retune([r1], entries=[{ entry: "https://e1.test/", relay: r1 }])
  stood.run()
  assert_eq(stood.times("iroh.setRelayEntries 1"), 1)
  mesh.retune([r1])
  stood.run()
  assert_eq(stood.entries.length(), 2)
  assert_eq(stood.entries[1], "[]")
  // A mesh closed is told nothing.
  assert_eq(ended_as(stood.go(() => mesh.close())), "ok")
  let said = stood.said.length()
  mesh.retune([r2])
  stood.run()
  assert_eq(stood.said.length(), said)
  assert_true(!mesh.rebinding && !mesh.retuned)
}

///|
test "entries the shell cannot be told: everything on the endpoint is let go of and it is bound anew with them; told so after it was bound anew otherwise, nothing more" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.made([r1])
  let link = stood.opened(mesh, Source::new().gives())
  stood.no_entries = true
  mesh.retune([r1], entries=[{ entry: "https://e1.test/", relay: r1 }])
  stood.run()
  assert_eq((far.closes, stood.binds.length(), stood.times("iroh.close 1")), (["2 closed"], 2, 1))
  assert_true(stood.binds[1].contains("\"relayEntries\":[{\"entry\":\"https://e1.test/\",\"relay\":\"https://r1.test/\"}]"))
  assert_true(!link.usable() && mesh.current(peer) is None && mesh.endpoint_handle() != 1)
  // The shell's refusal comes after the relays were told again and the endpoint bound on them: that bind carried
  // the entries, and nothing more is done.
  let (stood, _) = Stood::with_peer()
  let mesh = stood.made([r1])
  stood.holding = "iroh.setRelayEntries"
  mesh.retune([r1], entries=[{ entry: "https://e1.test/", relay: r1 }])
  stood.run()
  mesh.retune([r2], entries=[{ entry: "https://e2.test/", relay: r2 }])
  stood.run()
  assert_eq((stood.binds.length(), mesh.endpoint_handle()), (2, 2))
  stood.refuse("iroh.setRelayEntries", "no such op")
  assert_eq((stood.binds.length(), mesh.endpoint_handle(), stood.times("iroh.close 2")), (2, 2, 0))
  // And after the endpoint was bound anew for being stuck, with those entries: the one asked is no more, the one
  // there has them, and its link stays.
  let (stood, far) = Stood::with_peer()
  let mesh = stood.made([r1])
  far.away = true
  let failing = stood.go(() => mesh.link(peer, Source::new().gives()))
  stood.rt.advance(connect_timeout_ms)
  assert_eq((ended_as(failing), mesh.stuck), ("mesh: " + say("no_answer"), true))
  stood.holding = "iroh.setRelayEntries"
  mesh.retune([r1], entries=[{ entry: "https://e1.test/", relay: r1 }])
  stood.run()
  far.away = false
  let link = stood.opened(mesh, Source::new().gives())
  assert_eq(stood.binds.length(), 2)
  assert_true(stood.binds[1].contains("e1.test"))
  stood.refuse("iroh.setRelayEntries", "no such op")
  assert_eq((stood.binds.length(), far.closes.length()), (2, 0))
  assert_true(link.usable())
}

///|
test "entries told again while the shell is told the ones before: one telling at a time, in the order told, those told over never asked; a refusal of ones no more wanted lets go of nothing" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.made([r1])
  let link = stood.opened(mesh, Source::new().gives())
  stood.holding = "iroh.setRelayEntries"
  for n in 1..<4 {
    mesh.retune([r1], entries=entry(n))
    stood.run()
  }
  assert_eq(stood.times("iroh.setRelayEntries 1"), 1)
  // The first refused: the ones wanted now are others, and nothing is let go of for it. The second's turn: told
  // over, never asked. The third is.
  stood.refuse("iroh.setRelayEntries", "no such op")
  assert_eq((stood.times("iroh.setRelayEntries 1"), far.closes.length(), stood.binds.length()), (2, 0, 1))
  assert_true(stood.entries[1].contains("e3.test") && link.usable() && !mesh.retuned)
  // And that one refused: those are the ones wanted, so the endpoint is bound anew with them.
  stood.refuse("iroh.setRelayEntries", "no such op")
  assert_eq((stood.times("iroh.setRelayEntries 1"), far.closes.length(), stood.binds.length()), (2, 1, 2))
  assert_true(stood.binds[1].contains("e3.test") && !link.usable() && !mesh.retuned)
}

///|
test "entries told while the endpoint is being bound anew for being stuck, and that bind failing: the endpoint stays without them, and is bound with them by the next link that finds nothing on it" {
  // Told while the shell binds.
  let (stood, _, mesh) = taking_stuck()
  stood.holding = "iroh.bind"
  let dialling = stood.go(() => mesh.link(peer, Source::new().gives()))
  mesh.retune([r1], entries=entry(1))
  stood.run()
  assert_eq((stood.entries.length(), stood.binds.length(), mesh.retuned), (0, 2, true))
  stood.holding = ""
  stood.refuse("iroh.bind", "no socket")
  assert_true(gave(dialling).usable())
  assert_eq((mesh.endpoint_handle(), mesh.retuned, stood.entries.length()), (1, true, 0))
  mesh.drop_link(peer)
  stood.rt.advance(rebind_ms)
  assert_true(stood.opened(mesh, Source::new().gives()).usable())
  assert_eq((stood.binds.length(), mesh.retuned, stood.times("iroh.close 1")), (3, false, 1))
  assert_true(stood.binds[2].contains("e1.test"))
  // Its turn at the shell come while the shell binds (the ones before were being told): the same.
  let (stood, _, mesh) = taking_stuck()
  stood.holding = "iroh.setRelayEntries"
  mesh.retune([r1], entries=entry(1))
  stood.run()
  mesh.retune([r1], entries=entry(2))
  stood.run()
  stood.holding = "iroh.bind"
  let dialling = stood.go(() => mesh.link(peer, Source::new().gives()))
  assert_eq((stood.binds.length(), mesh.retuned), (2, false))
  stood.give("iroh.setRelayEntries", {})
  assert_eq((stood.times("iroh.setRelayEntries 1"), mesh.retuned), (1, true))
  stood.holding = ""
  stood.refuse("iroh.bind", "no socket")
  assert_true(gave(dialling).usable())
  assert_eq((mesh.endpoint_handle(), mesh.retuned), (1, true))
  // And the shell's refusal of them come while the shell binds: nothing is let go of under that bind.
  let (stood, far, mesh) = taking_stuck()
  stood.holding = "iroh.setRelayEntries"
  mesh.retune([r1], entries=entry(1))
  stood.run()
  stood.holding = "iroh.bind"
  let dialling = stood.go(() => mesh.link(peer, Source::new().gives()))
  stood.refuse("iroh.setRelayEntries", "no such op")
  assert_eq((stood.binds.length(), mesh.retuned, ended_as(dialling)), (2, true, "waiting"))
  stood.holding = ""
  stood.refuse("iroh.bind", "no socket")
  assert_true(gave(dialling).usable())
  assert_eq((mesh.endpoint_handle(), mesh.retuned, far.closes.length()), (1, true, 0))
}

///|
test "other relays told with nothing on the endpoint: it is bound anew on them at once, 5 s since the last time or not, the one before closed once, and the next link is dialled through them" {
  let (stood, _) = Stood::with_peer()
  let mesh = stood.made([r1])
  mesh.retune([r2, r3])
  stood.run()
  assert_eq((stood.binds.length(), stood.times("iroh.close 1"), mesh.endpoint_handle()), (2, 1, 2))
  assert_eq(stood.binds[1], "{\"relayUrls\":[\"https://r2.test/\",\"https://r3.test/\"],\"relayOnly\":false,\"lookup\":false}")
  mesh.retune([r3])
  stood.run()
  assert_eq((stood.binds.length(), stood.times("iroh.close 2"), mesh.endpoint_handle(), mesh.retuned), (3, 1, 3, false))
  let link = stood.opened(mesh, Source::new().gives())
  assert_true(link.usable())
  assert_eq((stood.times("iroh.connect 3"), stood.addrs), (1, ["{\"id\":\"\{peer}\",\"relays\":[\"https://r3.test/\"]}"]))
  assert_eq((stood.times("iroh.close 1"), stood.binds.length()), (1, 3))
}

///|
test "other relays told with links on the endpoint: each is let go of with the reason given, its holder told, an opening's asker told closed, a connection taken closed; the endpoint is bound only as their ends are told, and a link asked for meanwhile waits and is dialled on the new one" {
  let (stood, far, mesh, incoming, conn) = taken()
  far.lingers = true
  let one = Source::new(of="a")
  let a = stood.opened(mesh, one.gives(), scope="one")
  far.away = true
  let asking = stood.go(() => mesh.link(peer, Source::new(of="b").gives(), scope="two"))
  let told = stood.go(() => mesh.replaced(a))
  let ended = stood.go(() => incoming.closed())
  assert_eq((ended_as(asking), ended_as(told), stood.held.length()), ("waiting", "waiting", 1))
  mesh.retune([r2], reason="gone")
  stood.run()
  // Let go of, in that step: the link closed with the reason, the dial given up, the connection taken closed.
  assert_eq(far.closes, ["\{a.conn_handle()} gone", "\{conn} gone"])
  assert_eq((ended_as(told), ended_as(asking), stood.held.length()), ("ok", "mesh: " + say("closed"), 0))
  assert_true(!a.usable() && mesh.current(peer, scope="one") is None && mesh.links.length() == 0)
  // Their ends are not told yet: nothing is bound, and a link asked for waits, dialling nothing.
  far.away = false
  let again = stood.go(() => mesh.link(peer, one.gives(), scope="one"))
  assert_eq((stood.binds.length(), far.dials.length(), ended_as(again), ended_as(ended)), (1, 2, "waiting", "waiting"))
  // Told: bound on the new relays, the one before closed once, and the link dialled on the new one through them.
  far.told()
  assert_eq((stood.binds.length(), stood.times("iroh.close 1"), ended_as(ended)), (2, 1, "ok"))
  assert_true(stood.binds[1].contains("\"relayUrls\":[\"https://r2.test/\"]"))
  let link = gave(again)
  assert_true(link.usable() && !physical_equal(link, a))
  // (each closed once, and once more to be forgotten as its end was told)
  assert_eq((stood.times("conn.close \{a.conn_handle()}"), stood.times("conn.close \{conn}")), (2, 2))
  assert_eq(stood.times("iroh.connect \{mesh.endpoint_handle()}"), 1)
  assert_eq(stood.addrs[stood.addrs.length() - 1], "{\"id\":\"\{peer}\",\"relays\":[\"https://r2.test/\"]}")
  assert_eq((mesh.incomings.length(), mesh.retuned), (0, false))
}

///|
test "other relays told with a link another took the place of still open: it is closed with the reason in that step too, not when its time to stay runs out" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.made([r1])
  let old = stood.opened(mesh, Source::new().gives())
  // Its peer gone from under it, and a wake: the new link wins the race and takes its place, the old one staying
  // open `retire_ms`.
  far.lose(old.conn_handle())
  mesh.wake()
  stood.run()
  guard mesh.current(peer) is Some(now) && !physical_equal(now, old) else { fail("the new link did not take the place") }
  assert_eq((mesh.live.length(), far.closes.length()), (2, 0))
  mesh.retune([r2], reason="gone")
  stood.run()
  assert_eq(far.closes, ["\{old.conn_handle()} gone", "\{now.conn_handle()} gone"])
  assert_eq((stood.binds.length(), stood.times("iroh.close 1"), mesh.live.length(), mesh.retuned), (2, 1, 0, false))
}

///|
test "an endpoint not yet on the relays told is as one taken for stuck to whoever asks for a link: nothing new is dialled on it while what is on it ends by itself, and it is bound as that ends" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.made([r1])
  stood.holding = "iroh.bind"
  mesh.retune([r2])
  stood.run()
  stood.holding = ""
  stood.refuse("iroh.bind", "no socket")
  assert_eq((mesh.endpoint_handle(), mesh.retuned, mesh.stuck), (1, true, false))
  // No bind is to be tried for 5 s: a link asked for is dialled on the endpoint as it is.
  far.away = true
  let under = stood.go(() => mesh.link(peer, Source::new(of="a").gives(), scope="one"))
  assert_eq((stood.times("iroh.connect 1"), mesh.held.length()), (1, 0))
  // 5 s on, that dial still under way: one asked for in another scope waits, dialling nothing.
  stood.rt.advance(rebind_ms)
  far.away = false
  let other = stood.go(() => mesh.link(peer, Source::new(of="b").gives(), scope="two"))
  assert_eq((stood.times("iroh.connect 1"), stood.binds.length(), mesh.held.length(), ended_as(other)), (1, 2, 1, "waiting"))
  // The dial fails (not for no answer: the endpoint is not taken for stuck): nothing is on it, and it is bound on
  // the relays told, the one that waited dialled on the new one through them.
  stood.refuse("iroh.connect", "no route")
  assert_eq((ended_as(under), mesh.stuck), ("mesh: " + say("unreached"), false))
  assert_true(gave(other).usable())
  assert_eq((stood.binds.length(), stood.times("iroh.close 1"), stood.times("iroh.connect 1"), mesh.retuned), (3, 1, 1, false))
  assert_eq(stood.addrs[stood.addrs.length() - 1], "{\"id\":\"\{peer}\",\"relays\":[\"https://r2.test/\"]}")
}

///|
test "other relays told while a link asked for waits to dial (the endpoint taken for stuck, an opening still under way): the opening is given up, and the one that waited is dialled on the endpoint bound, through the new relays" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.made([r1])
  far.away = true
  let first = stood.go(() => mesh.link(peer, Source::new(of="a").gives(), scope="one"))
  stood.rt.advance(5_000)
  let under = stood.go(() => mesh.link(peer, Source::new(of="b").gives(), scope="two"))
  stood.rt.advance(5_000)
  assert_eq((ended_as(first), mesh.stuck, mesh.settling()), ("mesh: " + say("no_answer"), true, true))
  let waiting = stood.go(() => mesh.link(peer, Source::new(of="a").gives(), scope="one"))
  assert_eq((mesh.held.length(), stood.times("iroh.connect 1")), (1, 2))
  far.away = false
  mesh.retune([r2])
  stood.run()
  assert_eq((ended_as(under), stood.binds.length(), stood.times("iroh.close 1")), ("mesh: " + say("closed"), 2, 1))
  assert_true(gave(waiting).usable())
  assert_eq((stood.times("iroh.connect 1"), mesh.held.length(), mesh.retuned, mesh.stuck), (2, 0, false, false))
  assert_eq(stood.addrs[stood.addrs.length() - 1], "{\"id\":\"\{peer}\",\"relays\":[\"https://r2.test/\"]}")
}

///|
test "relays told again while the shell binds: it binds once more, on those, before anyone goes on; then each endpoint before is closed, once" {
  let (stood, _) = Stood::with_peer()
  let mesh = stood.made([r1])
  stood.holding = "iroh.bind"
  mesh.retune([r2])
  stood.run()
  let asking = stood.go(() => mesh.link(peer, Source::new().gives()))
  // Their entries alone, while the shell binds: the endpoint on its way out is told nothing, and the bind after is
  // with them.
  mesh.retune([r2], entries=[{ entry: "https://e2.test/", relay: r2 }])
  stood.run()
  assert_eq((stood.binds.length(), stood.held.length(), ended_as(asking), stood.entries.length()), (2, 1, "waiting", 0))
  // The first answered (handle 2): it is the mesh's, and one more is asked, on what is wanted now.
  stood.bound()
  assert_eq((stood.binds.length(), stood.times("iroh.close 1"), mesh.endpoint_handle(), ended_as(asking)), (3, 0, 2, "waiting"))
  assert_true(stood.binds[2].contains("\"relayUrls\":[\"https://r2.test/\"]") && stood.binds[2].contains("e2.test"))
  // Other relays, while the shell binds that one: one more again.
  mesh.retune([r3], entries=[{ entry: "https://e3.test/", relay: r3 }])
  stood.run()
  stood.bound()
  assert_eq((stood.binds.length(), stood.times("iroh.close 2"), mesh.endpoint_handle(), ended_as(asking)), (4, 0, 3, "waiting"))
  assert_true(stood.binds[3].contains("\"relayUrls\":[\"https://r3.test/\"]") && stood.binds[3].contains("e3.test"))
  stood.holding = ""
  stood.bound()
  assert_eq((stood.times("iroh.close 3"), mesh.endpoint_handle(), stood.times("iroh.connect 4"), mesh.retuned), (1, 4, 1, false))
  assert_eq((stood.times("iroh.close 1"), stood.times("iroh.close 2"), stood.times("iroh.close 4")), (1, 1, 0))
  assert_true(gave(asking).usable())
  assert_eq(stood.entries.length(), 0)
}

///|
test "other relays told with only a connection a peer dialled on the endpoint: bound as that one's end is told; and a connection asked for while the shell binds is asked of the endpoint that comes" {
  let (stood, far, mesh, _, conn) = taken()
  far.lingers = true
  mesh.retune([r2])
  stood.run()
  assert_eq((far.closes, stood.binds.length()), (["\{conn} closed"], 1))
  stood.holding = "iroh.bind"
  far.told()
  assert_eq((stood.binds.length(), stood.held.length()), (2, 1))
  let asking = stood.go(() => mesh.incoming())
  assert_eq((ended_as(asking), stood.times("iroh.accept 1")), ("waiting", 1))
  stood.holding = ""
  stood.bound()
  let now = mesh.endpoint_handle()
  assert_eq((stood.times("iroh.accept 1"), stood.times("iroh.accept \{now}"), stood.times("iroh.close 1"), ended_as(asking)), (1, 1, 1, "waiting"))
}

///|
test "an endpoint that could not be bound on the relays told stays the one it was, and is bound by the next link that finds nothing on it, 5 s later at the soonest" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.made([r1])
  stood.holding = "iroh.bind"
  mesh.retune([r2])
  stood.run()
  stood.refuse("iroh.bind", "no socket")
  assert_eq((mesh.endpoint_handle(), stood.times("iroh.close 1"), mesh.retuned), (1, 0, true))
  // A link asked for at once is dialled on the endpoint as it is, through the new relays.
  stood.holding = ""
  let link = stood.opened(mesh, Source::new().gives())
  assert_eq((stood.binds.length(), stood.times("iroh.connect 1")), (2, 1))
  assert_eq(stood.addrs, ["{\"id\":\"\{peer}\",\"relays\":[\"https://r2.test/\"]}"])
  // 5 s later, with that link on it, nothing is bound; let go of and its end told, the next link binds it.
  stood.rt.advance(rebind_ms)
  mesh.drop_link(peer)
  stood.run()
  assert_true(!link.usable())
  assert_true(stood.opened(mesh, Source::new().gives()).usable())
  assert_eq((stood.binds.length(), stood.times("iroh.close 1"), mesh.retuned, far.dials.length()), (3, 1, false, 2))
}

///|
test "the mesh closed while relays told again wait for a link's end, and while the shell binds for them: whoever waits is told closed, and each endpoint there is is closed once" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.made([r1])
  far.lingers = true
  ignore(stood.opened(mesh, Source::new().gives()))
  mesh.retune([r2])
  stood.run()
  let asking = stood.go(() => mesh.link(peer, Source::new().gives()))
  assert_eq((ended_as(asking), stood.binds.length()), ("waiting", 1))
  assert_eq(ended_as(stood.go(() => mesh.close())), "ok")
  assert_eq((ended_as(asking), stood.binds.length(), stood.times("iroh.close 1")), ("mesh: " + say("closed"), 1, 1))
  // While the shell binds: the close waits for its answer, and closes both.
  let (stood, _) = Stood::with_peer()
  let mesh = stood.made([r1])
  stood.holding = "iroh.bind"
  mesh.retune([r2])
  stood.run()
  let closing = stood.go(() => mesh.close())
  assert_eq(ended_as(closing), "waiting")
  stood.holding = ""
  stood.bound()
  assert_eq((ended_as(closing), stood.times("iroh.close 1"), stood.times("iroh.close 2"), stood.binds.length()), ("ok", 1, 1, 2))
}

// ── the connections peers dial ──

///|
test "a mesh that takes no connection asks the shell for none; one that does is given the next a peer dials, with its peer and its protocol, and that is no link" {
  let (stood, _) = Stood::with_peer()
  let mesh = stood.made([r1])
  assert_true(gave(stood.go(() => mesh.incoming())) is None)
  assert_eq(stood.times("iroh.accept 1"), 0)
  let (stood, far, mesh) = taking()
  let asking = stood.go(() => mesh.incoming())
  assert_eq((ended_as(asking), stood.times("iroh.accept 1")), ("waiting", 1))
  let conn = far.comes("pair/1")
  guard gave(asking) is Some(incoming) else { fail("no connection was given") }
  assert_eq((incoming.peer, incoming.alpn), ("ef".repeat(32), "pair/1"))
  assert_eq((mesh.links.length(), mesh.live.length(), mesh.incomings.length()), (0, 0, 1))
  assert_true(mesh.current("ef".repeat(32)) is None && !mesh.standing("ef".repeat(32)))
  // Nothing was asked of it but whose it is and its end.
  assert_eq((stood.times("conn.closed \{conn}"), stood.times("conn.openBi \{conn}"), stood.times("conn.acceptBi \{conn}")), (1, 0, 0))
}

///|
test "its first stream's first line, and the stream from there: what came after the line first, what goes back as written; asked once; closed by its program, it is let go of as its end is told" {
  let (stood, far, mesh, incoming, conn) = taken()
  let reading = stood.go(() => incoming.first())
  assert_eq(ended_as(reading), "waiting")
  let stream = far.open(conn)
  far.sends(stream, b"{\"t\":\"hel")
  assert_eq(ended_as(reading), "waiting")
  far.sends(stream, b"lo\"}\nmore")
  let (line, inbound) = gave(reading)
  assert_eq(line, "{\"t\":\"hello\"}")
  assert_true(gave(stood.go(() => inbound.take())) == Some(b"more"))
  assert_eq(ended_as(stood.go(() => inbound.out.write(b"{\"t\":\"ok\"}\n"))), "ok")
  assert_true(far.got(stream) == b"{\"t\":\"ok\"}\n")
  assert_true(ended_as(stood.go(() => incoming.first())).has_prefix("invalid_params: "))
  assert_eq(far.closes.length(), 0)
  let ended = stood.go(() => incoming.closed())
  incoming.close(reason="done")
  stood.run()
  assert_eq((far.closes, ended_as(ended), mesh.incomings.length()), (["\{conn} done"], "ok", 0))
  assert_true(stood.forgot.contains(conn))
}

///|
test "a peer nobody knows is held to a time and a length: no stream, or no line, within 30 s, a line too long, the connection ended, the asker gone: each closes the connection" {
  // No stream in 30 s.
  let (stood, far, _, incoming, conn) = taken()
  let reading = stood.go(() => incoming.first())
  stood.rt.advance(first_ms - 1)
  assert_eq((ended_as(reading), far.closes.length()), ("waiting", 0))
  stood.rt.advance(1)
  assert_eq((ended_as(reading), far.closes), ("mesh: " + say("no_answer"), ["\{conn} closed"]))
  // A stream, and no line's end in the time given.
  let (stood, far, _, incoming, conn) = taken()
  let reading = stood.go(() => incoming.first(within=2_000))
  far.sends(far.open(conn), b"{\"t\":")
  stood.rt.advance(1_999)
  assert_eq(ended_as(reading), "waiting")
  stood.rt.advance(1)
  assert_eq((ended_as(reading), far.closes), ("mesh: " + say("no_answer"), ["\{conn} closed"]))
  // A line longer than is kept of one: 16 bytes here, 64 KiB unless said.
  assert_eq((first_ms, max_head), (30_000, 65_536))
  let (stood, far, _, incoming, conn) = taken()
  let reading = stood.go(() => incoming.first(most=16))
  let stream = far.open(conn)
  far.sends(stream, b"0123456789abcdef")
  assert_eq(ended_as(reading), "waiting")
  far.sends(stream, b"g")
  assert_eq((ended_as(reading), far.closes), ("mesh: " + say("head_too_long"), ["\{conn} closed"]))
  // Its peer ends it first.
  let (stood, far, mesh, incoming, conn) = taken()
  let reading = stood.go(() => incoming.first())
  far.end(conn, "bye")
  assert_eq((ended_as(reading), mesh.incomings.length()), (cut_said, 0))
  // The asker gives up while it waits for the line: the shell's read goes on, and the connection is closed.
  let (stood, far, _, incoming, conn) = taken()
  let reading = stood.go(() => incoming.first())
  far.sends(far.open(conn), b"{")
  reading.interrupt()
  stood.run()
  assert_eq((ended_as(reading), far.closes), ("interrupted", ["\{conn} closed"]))
}

///|
test "an asker that gives up waiting for a connection loses none: the shell is asked once, and the connection that wait brings is the next asker's; a shell that takes none says so" {
  let (stood, far, mesh) = taking()
  let first = stood.go(() => mesh.incoming())
  let second = stood.go(() => mesh.incoming())
  first.interrupt()
  stood.run()
  assert_eq((ended_as(first), ended_as(second), stood.times("iroh.accept 1")), ("interrupted", "waiting", 1))
  second.interrupt()
  stood.run()
  // Nobody asks: the connection that comes is kept, one at most, the shell asked for no second.
  let conn = far.comes("pair/1")
  assert_eq((stood.times("iroh.accept 1"), mesh.incomings.length()), (1, 0))
  guard gave(stood.go(() => mesh.incoming())) is Some(incoming) else { fail("no connection was given") }
  assert_eq((incoming.conn_handle(), stood.times("iroh.accept 1")), (conn, 1))
  // A shell that says the endpoint takes none any more, the endpoint still the mesh's: none will come, and it is
  // not asked again.
  let ending = stood.go(() => mesh.incoming())
  stood.give("iroh.accept", { "end": true })
  assert_true(gave(ending) is None)
  assert_eq(stood.times("iroh.accept 1"), 2)
  // A shell that takes none (a page's) fails the op: said to whoever asked.
  let asking = stood.go(() => mesh.incoming())
  stood.refuse("iroh.accept", "a page's shell has no iroh.accept")
  assert_eq(ended_as(asking), "host: a page's shell has no iroh.accept")
}

///|
test "the endpoint bound anew with the wait for a connection out: the wait ends with the old one and is asked again of the new; a connection nobody took goes with the old one; one taken keeps the endpoint from being bound anew" {
  // Stuck, the wait out on endpoint 1; the next link binds endpoint 2.
  let (stood, far, mesh) = taking()
  far.away = true
  let failing = stood.go(() => mesh.link(peer, Source::new().gives()))
  stood.rt.advance(connect_timeout_ms)
  assert_eq((ended_as(failing), mesh.stuck), ("mesh: " + say("no_answer"), true))
  let asking = stood.go(() => mesh.incoming())
  far.away = false
  assert_true(stood.opened(mesh, Source::new().gives()).usable())
  assert_eq((mesh.endpoint_handle(), stood.times("iroh.accept 1"), stood.times("iroh.accept 2"), ended_as(asking)), (2, 1, 1, "waiting"))
  let conn = far.comes("pair/1")
  assert_true(gave(asking) is Some(incoming) && incoming.conn_handle() == conn)
  // A connection the wait brought that nobody took: closed to be forgotten as the endpoint under it is.
  let (stood, far, mesh) = taking()
  let asking = stood.go(() => mesh.incoming())
  asking.interrupt()
  stood.run()
  let kept = far.comes("pair/1")
  mesh.retune([r2])
  stood.run()
  assert_eq((mesh.endpoint_handle(), stood.times("conn.close \{kept}"), far.closes), (kept + 1, 1, ["\{kept} closed"]))
  assert_true(stood.forgot.contains(kept))
  let again = stood.go(() => mesh.incoming())
  assert_eq((ended_as(again), stood.times("iroh.accept \{kept + 1}")), ("waiting", 1))
  // One taken is on the endpoint: taken for stuck, it is not bound anew while that has not ended.
  let (stood, far, mesh, incoming, _) = taken()
  far.away = true
  let failing = stood.go(() => mesh.link(peer, Source::new().gives()))
  stood.rt.advance(connect_timeout_ms)
  assert_eq((ended_as(failing), mesh.stuck, mesh.idle()), ("mesh: " + say("no_answer"), true, false))
  let dialling = stood.go(() => mesh.link(peer, Source::new().gives()))
  assert_eq((stood.binds.length(), stood.times("iroh.connect 1"), ended_as(dialling)), (1, 2, "waiting"))
  stood.rt.advance(connect_timeout_ms)
  incoming.close()
  stood.run()
  assert_true(mesh.idle())
  far.away = false
  assert_true(stood.opened(mesh, Source::new().gives()).usable())
  assert_eq(stood.binds.length(), 2)
}

///|
test "the mesh closed: whoever waits for a connection is told none comes, at whichever turn; one taken is told its end and closed, its wait for a line failing as cut" {
  let (stood, far, mesh, incoming, conn) = taken()
  let waiting = stood.go(() => mesh.incoming())
  let reading = stood.go(() => incoming.first())
  let ended = stood.go(() => incoming.closed())
  assert_eq(ended_as(stood.go(() => mesh.close())), "ok")
  assert_true(gave(waiting) is None)
  assert_true(gave(ended).kind == "local")
  assert_eq((ended_as(reading), far.closes, mesh.incomings.length()), (cut_said, ["\{conn} closed"], 0))
  assert_true(gave(stood.go(() => mesh.incoming())) is None)
  // Asked for in the turn the mesh closes, before the mesh's wait took a step.
  for late in 0..<6 {
    let (stood, _, mesh) = taking()
    let asking = stood.start(() => mesh.incoming())
    let closing = stood.start(() => {
      for _ in 0..<late {
        @effect.pause()
      }
      mesh.close()
    })
    stood.run()
    assert_eq(ended_as(closing), "ok")
    assert_true(gave(asking) is None)
    assert_eq((mesh.incomings.length(), stood.times("iroh.close 1")), (0, 1))
  }
  // And closed at each turn from a connection's coming on: either none is handed out, or the one that is is told
  // its end.
  let handed = Ref(0)
  let none = Ref(0)
  for late in 0..<8 {
    let (stood, far, mesh) = taking()
    let asking = stood.go(() => mesh.incoming())
    stood.last += 1
    far.conns[stood.last] = []
    stood.answered("iroh.accept", { "id": Json::number(stood.last.to_double()), "alpn": Json::string(hex("pair/1")) })
    let closing = stood.start(() => {
      for _ in 0..<late {
        @effect.pause()
      }
      mesh.close()
    })
    stood.run()
    assert_eq((ended_as(closing), mesh.incomings.length(), stood.times("iroh.close 1")), ("ok", 0, 1))
    match gave(asking) {
      Some(incoming) => {
        handed.val += 1
        assert_true(gave(stood.go(() => incoming.closed())).kind == "local")
      }
      None => none.val += 1
    }
  }
  assert_true(handed.val > 0 && none.val > 0)
}

///|
test "a connection that comes while the endpoint is being bound anew is not taken on the one that goes: where it goes the connection is closed to be forgotten and the endpoint bound is asked; where it stays the connection is handed out" {
  // Relays told again, a link's end not told yet: the endpoint is to go, and what comes to it meanwhile with it.
  let (stood, far, mesh) = taking()
  far.lingers = true
  ignore(stood.opened(mesh, Source::new().gives()))
  let asking = stood.go(() => mesh.incoming())
  mesh.retune([r2])
  stood.run()
  let conn = far.comes("pair/1")
  assert_eq((ended_as(asking), mesh.incomings.length(), stood.binds.length(), stood.times("conn.close \{conn}")), ("waiting", 0, 1, 0))
  far.told()
  let now = mesh.endpoint_handle()
  assert_eq((stood.binds.length(), stood.times("iroh.close 1"), ended_as(asking), mesh.retuned), (2, 1, "waiting", false))
  assert_eq((stood.times("conn.close \{conn}"), stood.forgot.contains(conn), mesh.incomings.length()), (1, true, 0))
  assert_eq((stood.times("iroh.accept 1"), stood.times("iroh.accept \{now}")), (1, 1))
  let next = far.comes("pair/1")
  assert_true(gave(asking) is Some(incoming) && incoming.conn_handle() == next)
  // Taken for stuck, the shell binding: the bind fails, the endpoint stays, and the connection is its asker's.
  let (stood, far, mesh) = taking_stuck()
  let asking = stood.go(() => mesh.incoming())
  stood.holding = "iroh.bind"
  let dialling = stood.go(() => mesh.link(peer, Source::new().gives()))
  let conn = far.comes("pair/1")
  assert_eq((ended_as(asking), mesh.incomings.length(), stood.binds.length()), ("waiting", 0, 2))
  stood.holding = ""
  stood.refuse("iroh.bind", "no socket")
  assert_true(gave(asking) is Some(incoming) && incoming.conn_handle() == conn)
  assert_eq((mesh.endpoint_handle(), stood.times("conn.close \{conn}"), stood.times("iroh.accept 1")), (1, 0, 1))
  assert_true(gave(dialling).usable())
  // The bind and the connection answered in one turn, either first: the endpoint goes, and the connection with it,
  // whichever fiber finds it; the asker asks the endpoint bound, once.
  for bind_first in [true, false] {
    let (stood, far, mesh) = taking_stuck()
    let asking = stood.go(() => mesh.incoming())
    stood.holding = "iroh.bind"
    let dialling = stood.go(() => mesh.link(peer, Source::new().gives()))
    stood.holding = ""
    let conn = stood.last + 1
    let endpoint = stood.last + 2
    stood.last += 2
    far.conns[conn] = []
    let bound = () => stood.answered("iroh.bind", { "id": Json::number(endpoint.to_double()) })
    let came = () => stood.answered("iroh.accept", { "id": Json::number(conn.to_double()), "alpn": Json::string(hex("pair/1")) })
    if bind_first {
      bound()
      came()
    } else {
      came()
      bound()
    }
    stood.run()
    assert_eq((mesh.endpoint_handle(), stood.times("iroh.close 1"), ended_as(asking), mesh.incomings.length()), (endpoint, 1, "waiting", 0))
    assert_eq((stood.times("conn.close \{conn}"), stood.forgot.contains(conn)), (1, true))
    assert_eq((stood.times("iroh.accept 1"), stood.times("iroh.accept \{endpoint}")), (1, 1))
    assert_true(gave(dialling).usable() && mesh.idle() == false)
    let next = far.comes("pair/1")
    assert_true(gave(asking) is Some(incoming) && incoming.conn_handle() == next)
  }
}

///|
test "a connection the wait brought that nobody took is closed to be forgotten as the mesh closes; one whose end was told is asked nothing more; a protocol the shell says that the endpoint takes none of is said as it came" {
  let (stood, far, mesh) = taking()
  let asking = stood.go(() => mesh.incoming())
  asking.interrupt()
  stood.run()
  let kept = far.comes("pair/1")
  assert_eq((mesh.incomings.length(), stood.times("conn.close \{kept}")), (0, 0))
  assert_eq(ended_as(stood.go(() => mesh.close())), "ok")
  assert_eq((stood.times("conn.close \{kept}"), stood.forgot.contains(kept), stood.times("iroh.close 1")), (1, true, 1))
  assert_true(stood.said.search("conn.close \{kept}").unwrap() < stood.said.search("iroh.close 1").unwrap())
  // Ended by its peer and let go of: its program's close after asks the shell nothing of it.
  let (stood, far, _, incoming, conn) = taken()
  far.end(conn, "bye")
  assert_eq((stood.times("conn.close \{conn}"), stood.forgot.contains(conn)), (1, true))
  incoming.close(reason="done")
  stood.run()
  assert_eq((stood.times("conn.close \{conn}"), far.closes.length()), (1, 0))
  let (stood, far, mesh) = taking()
  let asking = stood.go(() => mesh.incoming())
  ignore(far.comes("other/9"))
  assert_true(gave(asking) is Some(incoming) && incoming.alpn == hex("other/9"))
}

///|
/// The handle of a stream at the stood-in shell.
fn Inbound::handle(self : Inbound) -> Int {
  handle_of({ "id": self.stream.id })
}

///|
test "after its first stream, the streams its peer opens are taken one by one, each read and answered on its own; asked side by side, each asker gets its own; the first asked with none before is the first, and first after it is a mistake" {
  let (stood, far, _, incoming, conn) = taken()
  let reading = stood.go(() => incoming.first())
  far.sends(far.open(conn), b"{\"t\":\"hello\"}\n")
  assert_eq(gave(reading).0, "{\"t\":\"hello\"}")
  // Two ask at once: the shell is asked one wait at a time, the second asker's after the first's was answered.
  let one = stood.go(() => incoming.accept())
  let two = stood.go(() => incoming.accept())
  assert_eq((ended_as(one), ended_as(two), stood.times("conn.acceptBi \{conn}")), ("waiting", "waiting", 2))
  let s1 = far.open(conn)
  assert_eq((ended_as(two), stood.times("conn.acceptBi \{conn}")), ("waiting", 3))
  let s2 = far.open(conn)
  guard (gave(one), gave(two)) is (Some(first), Some(second)) else { fail("no stream was given") }
  assert_eq((first.handle(), second.handle()), (s1, s2))
  // Each its own: what its peer sends there, what goes back there.
  far.sends(s2, b"two")
  far.sends(s1, b"one")
  assert_true(gave(stood.go(() => first.take())) == Some(b"one"))
  assert_true(gave(stood.go(() => second.take())) == Some(b"two"))
  assert_eq(ended_as(stood.go(() => second.out.write(b"2"))), "ok")
  assert_eq(ended_as(stood.go(() => first.out.write(b"1"))), "ok")
  assert_true(far.got(s1) == b"1" && far.got(s2) == b"2")
  // The first asked by accept: its program reads it itself, and first is then its mistake.
  let (stood, far, _, incoming, conn) = taken()
  let taking = stood.go(() => incoming.accept())
  let s = far.open(conn)
  assert_true(gave(taking) is Some(inbound) && inbound.handle() == s)
  assert_true(ended_as(stood.go(() => incoming.first())).has_prefix("invalid_params: "))
  // An accept asked while first waits for its line waits for it, and is the stream after.
  let (stood, far, _, incoming, conn) = taken()
  let reading = stood.go(() => incoming.first())
  let after = stood.go(() => incoming.accept())
  let s1 = far.open(conn)
  assert_eq((ended_as(after), stood.times("conn.acceptBi \{conn}")), ("waiting", 1))
  far.sends(s1, b"hi\n")
  assert_eq((gave(reading).1.handle(), ended_as(after)), (s1, "waiting"))
  let s2 = far.open(conn)
  assert_true(gave(after) is Some(inbound) && inbound.handle() == s2)
}

///|
test "an asker of the next stream that gives up loses none: the shell is asked once, and the stream it brings is the next asker's; one nobody took is reset as the connection is closed or ends; one the shell brings after the end is reset there" {
  let (stood, far, _, incoming, conn) = taken()
  let asking = stood.go(() => incoming.accept())
  asking.interrupt()
  stood.run()
  assert_eq((ended_as(asking), stood.times("conn.acceptBi \{conn}")), ("interrupted", 1))
  let s = far.open(conn)
  assert_true(gave(stood.go(() => incoming.accept())) is Some(inbound) && inbound.handle() == s)
  assert_eq((stood.times("conn.acceptBi \{conn}"), stood.times("istream.reset \{s}")), (1, 0))
  // Brought for nobody, then the connection closed by its program: the stream is reset, its wait let go of.
  let asking = stood.go(() => incoming.accept())
  asking.interrupt()
  stood.run()
  let kept = far.open(conn)
  incoming.close()
  stood.run()
  assert_eq((stood.times("istream.reset \{kept}"), far.closes), (1, ["\{conn} closed"]))
  assert_true(gave(stood.go(() => incoming.accept())) is None)
  assert_eq(stood.times("conn.acceptBi \{conn}"), 2)
  // Brought for nobody, then the connection ended by its peer: reset as its end is told.
  let (stood, far, _, incoming, conn) = taken()
  let asking = stood.go(() => incoming.accept())
  asking.interrupt()
  stood.run()
  let kept = far.open(conn)
  far.end(conn, "bye")
  assert_eq(stood.times("istream.reset \{kept}"), 1)
  // An asker waiting as the connection ends is told none; the shell's wait, answered with a stream only after,
  // has it reset there.
  let (stood, far, _, incoming, conn) = taken()
  stood.holding = "conn.acceptBi"
  let asking = stood.go(() => incoming.accept())
  far.end(conn, "bye")
  assert_true(gave(asking) is None)
  stood.last += 1
  let late = stood.last
  stood.give("conn.acceptBi", { "id": Json::number(late.to_double()) })
  assert_eq(stood.times("istream.reset \{late}"), 1)
  assert_true(gave(stood.go(() => incoming.accept())) is None)
}

///|
test "a stream opened from this side of a connection a peer dialled: written and read as one the peer opened; given up while the shell opens it, what comes is reset; ended first, it fails as cut" {
  let (stood, far, _, incoming, conn) = taken()
  let reading = stood.go(() => incoming.first())
  far.sends(far.open(conn), b"hello\n")
  ignore(gave(reading))
  let opened = gave(stood.go(() => incoming.open()))
  assert_eq(stood.times("conn.openBi \{conn}"), 1)
  let s = opened.handle()
  assert_eq(ended_as(stood.go(() => opened.out.write(b"{\"t\":\"push\"}\nbody"))), "ok")
  assert_true(far.got(s) == b"body")
  far.sends(s, b"back")
  assert_true(gave(stood.go(() => opened.take())) == Some(b"back"))
  // Given up while the shell opens it: opened all the same, and reset as it comes.
  stood.holding = "conn.openBi"
  let asking = stood.go(() => incoming.open())
  asking.interrupt()
  stood.run()
  assert_eq(ended_as(asking), "interrupted")
  stood.last += 1
  let late = stood.last
  stood.give("conn.openBi", { "id": Json::number(late.to_double()) })
  assert_eq((stood.times("istream.reset \{late}"), stood.times("istream.write \{late}")), (1, 0))
  // The connection ending while one is opened: its asker is told so; asked after, it fails at once.
  let waiting = stood.go(() => incoming.open())
  far.end(conn, "bye")
  assert_eq(ended_as(waiting), cut_said)
  let after = stood.go(() => incoming.open())
  assert_true(ended_as(after).has_prefix("mesh: "))
  assert_eq(stood.times("conn.openBi \{conn}"), 3)
}

// ── connections dialled from the endpoint itself ──

///|
/// A mesh that takes no connection, and a connection it dialled from its endpoint to `peer` on "side/1", handed
/// out: its handle at the shell too.
fn connected() -> (Stood, Peer, Mesh, Incoming, Int) raise {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.made([r1])
  let incoming = gave(stood.go(() => mesh.connect(peer, "side/1")))
  (stood, far, mesh, incoming, incoming.conn_handle())
}

///|
test "connected from the endpoint itself: none bound for it, its protocol as written, the peer dialled straight where the caller and the mesh say, each once; handed out as one taken, no link, on the endpoint; streams both ways; closed, let go of, the endpoint left" {
  let (stood, far) = Stood::with_peer()
  // (it takes no connection itself: the peer's endpoint is the one to take the protocol)
  let mesh = stood.made([r1])
  mesh.add_addr(peer, ips=["10.0.0.9:7"])
  let ips = ["10.0.0.5:1", "10.0.0.9:7"]
  let connecting = stood.go(() => mesh.connect(peer, "side/1", ips~))
  // (what its program does to the array after is not the mesh's)
  ips.push("10.0.0.6:1")
  let incoming = gave(connecting)
  assert_eq((incoming.peer, incoming.alpn), (peer, "side/1"))
  // On the device's endpoint: nothing bound but it, dialled there with the protocol's bytes.
  assert_eq((stood.binds.length(), stood.times("iroh.connect 1")), (1, 1))
  assert_true(stood.dial_alpns[0] == @utf8.encode("side/1"))
  assert_eq(stood.addrs[0], ({ "id": peer, "relays": [r1], "ips": ["10.0.0.5:1", "10.0.0.9:7"] } : Json).stringify())
  let conn = incoming.conn_handle()
  // Kept as one taken: no link, no place, and on the endpoint while it is open.
  assert_eq((mesh.links.length(), mesh.live.length(), mesh.incomings.length(), mesh.idle()), (0, 0, 1, false))
  assert_true(mesh.current(peer) is None)
  // The peer's stream, taken; one opened from here: each read and written as a taken connection's are.
  let s1 = far.open(conn)
  far.sends(s1, b"hi")
  let theirs = gave(stood.go(() => incoming.accept())).unwrap()
  assert_eq(theirs.handle(), s1)
  assert_true(gave(stood.go(() => theirs.take())) == Some(b"hi"))
  let ours = gave(stood.go(() => incoming.open()))
  assert_eq(ended_as(stood.go(() => ours.out.write(b"ask"))), "ok")
  assert_true(far.got(ours.handle()) == b"ask")
  far.sends(ours.handle(), b"answer")
  assert_true(gave(stood.go(() => ours.take())) == Some(b"answer"))
  // Closed: the peer told why, the connection let go of as its end is told; the endpoint left be.
  let ended = stood.go(() => incoming.closed())
  incoming.close(reason="done")
  stood.run()
  assert_eq((far.closes, ended_as(ended), mesh.incomings.length()), (["\{conn} done"], "ok", 0))
  assert_true(stood.forgot.contains(conn) && mesh.idle())
  assert_false(stood.unbound.contains(1))
  assert_eq(stood.forgot_ends.length(), 0)
}

///|
test "connected with no answer in time: given up at the shell, nothing kept, the endpoint not taken for stuck; refused by the shell: unreached; a peer that is no id or no protocol: nothing dialled; held to relays: dialled through them alone" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.made([r1])
  far.away = true
  let connecting = stood.go(() => mesh.connect(peer, "side/1", within=2_000))
  // (on the endpoint while it dials: it is not bound anew under it)
  assert_eq((ended_as(connecting), mesh.idle()), ("waiting", false))
  stood.rt.advance(1_999)
  assert_eq(ended_as(connecting), "waiting")
  stood.rt.advance(1)
  assert_eq(ended_as(connecting), "mesh: " + say("no_answer"))
  assert_false(stood.held.iter().any(call => call.1 == "iroh.connect"))
  assert_eq((mesh.idle(), mesh.stuck, mesh.incomings.length()), (true, false, 0))
  // The shell refusing the dial.
  far.away = false
  stood.holding = "iroh.connect"
  let refused = stood.go(() => mesh.connect(peer, "side/1"))
  stood.refuse("iroh.connect", "no route")
  assert_eq(ended_as(refused), "mesh: " + say("unreached"))
  assert_true(mesh.idle())
  stood.holding = ""
  let dials = stood.times("iroh.connect 1")
  assert_true(ended_as(stood.go(() => mesh.connect("nope", "side/1"))).has_prefix("invalid_params: "))
  assert_true(ended_as(stood.go(() => mesh.connect(peer, ""))).has_prefix("invalid_params: "))
  assert_eq(stood.times("iroh.connect 1"), dials)
  // Held to relays: neither the caller's addresses nor the mesh's are told.
  let (stood, _) = Stood::with_peer()
  let mesh = stood.made([r1], relay_only=true)
  mesh.add_addr(peer, ips=["10.0.0.9:7"])
  ignore(gave(stood.go(() => mesh.connect(peer, "side/1", ips=["10.0.0.5:1"]))))
  assert_eq(stood.addrs[0], ({ "id": peer, "relays": [r1] } : Json).stringify())
}

///|
test "connected and cut by its caller, while it dials and in the turn its connection comes: the dial given up at the shell, a connection that comes closed to be forgotten, nothing kept, the endpoint free again" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.made([r1])
  far.away = true
  let cutting = stood.go(() => mesh.connect(peer, "side/1"))
  cutting.interrupt()
  stood.run()
  assert_eq(ended_as(cutting), "interrupted")
  assert_false(stood.held.iter().any(call => call.1 == "iroh.connect"))
  assert_eq((mesh.idle(), mesh.incomings.length()), (true, 0))
  // Cut in the turn its connection comes: whichever runs first, the connection is closed to be forgotten.
  let (stood, far) = Stood::with_peer()
  let mesh = stood.made([r1])
  far.away = true
  let cutting = stood.go(() => mesh.connect(peer, "side/1"))
  stood.dial_answered()
  cutting.interrupt()
  stood.run()
  assert_eq(ended_as(cutting), "interrupted")
  assert_true(stood.forgot.contains(stood.last))
  assert_eq((mesh.idle(), mesh.incomings.length()), (true, 0))
}

///|
test "connected as the endpoint is bound anew: asked while the shell binds, dialled on the endpoint that comes; bound anew under its dial, dialled again on the new one; taken for stuck with nothing on it, bound anew first" {
  // Asked while the shell binds for other relays: it waits, and dials on the one bound, through them.
  let (stood, _) = Stood::with_peer()
  let mesh = stood.made([r1])
  stood.holding = "iroh.bind"
  mesh.retune([r2])
  stood.run()
  let connecting = stood.go(() => mesh.connect(peer, "side/1"))
  assert_eq((ended_as(connecting), stood.times("iroh.connect 1")), ("waiting", 0))
  stood.holding = ""
  stood.bound()
  let incoming = gave(connecting)
  assert_eq((mesh.endpoint_handle(), stood.times("iroh.connect 2")), (2, 1))
  assert_eq(stood.addrs[0], ({ "id": peer, "relays": [r2] } : Json).stringify())
  assert_eq(mesh.incomings.length(), 1)
  assert_true(physical_equal(mesh.incomings[0], incoming))
  // Other relays told under its dial: the endpoint goes, the dial on it failing with it, and the one bound is dialled.
  let (stood, _) = Stood::with_peer()
  let mesh = stood.made([r1])
  stood.holding = "iroh.connect"
  let connecting = stood.go(() => mesh.connect(peer, "side/1"))
  assert_eq(stood.times("iroh.connect 1"), 1)
  mesh.retune([r2])
  stood.run()
  assert_eq((mesh.endpoint_handle(), stood.times("iroh.connect 2"), ended_as(connecting)), (2, 1, "waiting"))
  assert_true(stood.unbound.contains(1))
  stood.holding = ""
  stood.dialled()
  let incoming = gave(connecting)
  assert_eq((incoming.conn_handle(), mesh.incomings.length()), (3, 1))
  assert_eq(stood.addrs[1], ({ "id": peer, "relays": [r2] } : Json).stringify())
  // Its connection coming while the endpoint is being bound anew: closed to be forgotten (it is on the one that
  // goes), and the one bound dialled.
  let (stood, _) = Stood::with_peer()
  let mesh = stood.made([r1])
  stood.holding = "iroh.connect"
  let connecting = stood.go(() => mesh.connect(peer, "side/1"))
  stood.holding = "iroh.bind"
  mesh.retune([r2])
  stood.run()
  stood.dial_answered()
  stood.run()
  assert_eq((ended_as(connecting), mesh.incomings.length()), ("waiting", 0))
  assert_true(stood.forgot.contains(2))
  stood.holding = ""
  stood.bound()
  let incoming = gave(connecting)
  assert_eq((mesh.endpoint_handle(), stood.times("iroh.connect 3"), incoming.conn_handle()), (3, 1, 4))
  assert_eq(mesh.incomings.length(), 1)
  // Taken for stuck with nothing on it: bound anew before it dials, as a link does.
  let (stood, far) = Stood::with_peer()
  let mesh = stood.made([r1])
  far.away = true
  let failing = stood.go(() => mesh.link(peer, Source::new().gives()))
  stood.rt.advance(connect_timeout_ms)
  assert_eq((ended_as(failing), mesh.stuck), ("mesh: " + say("no_answer"), true))
  far.away = false
  let incoming = gave(stood.go(() => mesh.connect(peer, "side/1")))
  let endpoint = mesh.endpoint_handle()
  assert_eq((stood.binds.length(), mesh.stuck, stood.times("iroh.connect \{endpoint}")), (2, false, 1))
  assert_true(endpoint != 1 && stood.unbound.contains(1))
  assert_eq(incoming.peer, peer)
}

///|
test "connected and on the endpoint: taken for stuck, the endpoint is not bound anew under it; other relays told, it is closed with the reason and the endpoint bound as its end is told; the mesh closed, one under way fails as closed, one handed out is told its end and let go of" {
  // On the endpoint: a link that finds it stuck dials on it as it is.
  let (stood, far, mesh, incoming, _) = connected()
  far.away = true
  let failing = stood.go(() => mesh.link(peer, Source::new().gives()))
  stood.rt.advance(connect_timeout_ms)
  assert_eq((ended_as(failing), mesh.stuck, mesh.idle()), ("mesh: " + say("no_answer"), true, false))
  let dialling = stood.go(() => mesh.link(peer, Source::new().gives()))
  assert_eq((stood.binds.length(), stood.times("iroh.connect 1"), ended_as(dialling)), (1, 3, "waiting"))
  stood.rt.advance(connect_timeout_ms)
  incoming.close()
  stood.run()
  assert_true(mesh.idle())
  // Other relays told: closed with the reason, the endpoint bound as its end is told.
  let (stood, far, mesh, _, conn) = connected()
  mesh.retune([r2], reason="moved")
  stood.run()
  assert_eq((far.closes, mesh.incomings.length(), mesh.endpoint_handle()), (["\{conn} moved"], 0, conn + 1))
  assert_true(stood.forgot.contains(conn) && stood.unbound.contains(1))
  // The mesh closed under its dial.
  let (stood, far) = Stood::with_peer()
  let mesh = stood.made([r1])
  far.away = true
  let connecting = stood.go(() => mesh.connect(peer, "side/1"))
  assert_eq(ended_as(stood.go(() => mesh.close())), "ok")
  assert_eq(ended_as(connecting), "mesh: " + say("closed"))
  assert_false(stood.held.iter().any(call => call.1 == "iroh.connect"))
  assert_eq(ended_as(stood.go(() => mesh.connect(peer, "side/1"))), "mesh: " + say("closed"))
  // The mesh closed while it waits for the endpoint being bound anew.
  let (stood, _) = Stood::with_peer()
  let mesh = stood.made([r1])
  stood.holding = "iroh.bind"
  mesh.retune([r2])
  stood.run()
  let connecting = stood.go(() => mesh.connect(peer, "side/1"))
  let closing = stood.go(() => mesh.close())
  stood.holding = ""
  stood.bound()
  assert_eq((ended_as(closing), ended_as(connecting)), ("ok", "mesh: " + say("closed")))
  assert_eq(stood.said.filter(one => one.has_prefix("iroh.connect")).length(), 0)
  // Handed out: told its end, its streams' askers told none, let go of.
  let (stood, _, mesh, incoming, conn) = connected()
  let accepting = stood.go(() => incoming.accept())
  let ended = stood.go(() => incoming.closed())
  assert_eq(ended_as(stood.go(() => mesh.close())), "ok")
  assert_eq(gave(ended).kind, "local")
  assert_true(gave(accepting) is None)
  assert_true(stood.forgot.contains(conn) && mesh.incomings.length() == 0)
  assert_eq(stood.times("conn.close \{conn}"), 1)
}
