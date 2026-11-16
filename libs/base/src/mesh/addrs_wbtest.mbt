// Where a peer said a device dials it straight, and where its program says a peer is (addrs.mbt). On the peer that
// answers by itself (stood_wbtest.mbt), with a store of the test's own.

///|
/// A store of the test's: the device's key kept already, everything else in `values`, which the test reads.
fn kept_store(values : Map[String, Bytes]) -> Store {
  {
    get: key => if key == device_key { Some(Bytes::make(32, b'\x01')) } else { values.get(key) },
    set: (key, value) => values[key] = value,
  }
}

///|
/// A mesh on `[r1]` (bind_wbtest.mbt) keeping in `values`.
fn Stood::keeping(
  self : Stood,
  values : Map[String, Bytes],
  relay_only? : Bool = false,
  addresses? : String = addresses_key,
) -> Mesh raise {
  let made = self.go(() => Mesh::make(
    self.shell.val.unwrap(),
    kept_store(values),
    { alpn: "test/1", relays: [r1], relay_only, says: None, refusal: None },
    addresses~,
  ))
  guard made.poll() is Some(Succeeded(mesh)) else { fail("the mesh was not made: \{self.said.join(", ")}") }
  mesh
}

///|
/// The peer answers a link's first line saying `said` beside `"ok":true` (its pings `{"ok":true}`).
fn Peer::saying(self : Peer, said : String) -> Unit {
  self.answers = (_, hello) => Some(if hello { "{\"ok\":true\{said}}" } else { "{\"ok\":true}" })
}

///|
fn text_of_kept(values : Map[String, Bytes], key? : String = addresses_key) -> String raise {
  guard values.get(key) is Some(bytes) else { fail("nothing kept under \{key}") }
  @utf8.decode(bytes)
}

///|
/// What the endpoint `endpoint` is told of the peer: its relays, and its addresses where any.
fn told_addr(endpoint : Int, relays : Array[String], ips : Array[String]) -> String {
  let addr : Map[String, Json] = { "id": Json::string(peer), "relays": strings(relays) }
  if ips.length() > 0 {
    addr["ips"] = strings(ips)
  }
  "\{endpoint} \{Json::object(addr).stringify()}"
}

///|
test "an address is a.b.c.d:port as the TypeScript mesh takes one, 8 of a kind at most; what is kept and cannot be read is nothing" {
  for good in ["10.0.0.2:4000", "192.168.001.255:65535", "1.2.3.4:0", "999.1.1.1:99999"] {
    assert_true(is_ip_port(good), msg=good)
  }
  for bad in [
    "", "10.0.0.2", "10.0.0.2:", ":4000", "10.0.0:4000", "10.0.0.2.5:4000", "1000.0.0.2:4000", "10.0.0.2:123456",
    "[::1]:4000", "fe80::1:4000", "host.lan:4000", "10.0.0.2:40a0", " 10.0.0.2:4000", "10..0.2:4000",
  ] {
    assert_false(is_ip_port(bad), msg=bad)
  }
  let many = Json::array((0).until(12).map(i => Json::string("10.0.0.\{i}:1")).collect())
  assert_eq(addrs_of({ "lan": many }, "lan").length(), 8)
  assert_eq(addrs_of({ "lan": ["10.0.0.1:1", 5, "h:1", "10.0.0.2:2"] }, "lan"), ["10.0.0.1:1", "10.0.0.2:2"])
  assert_eq(addrs_of({ "lan": "10.0.0.1:1" }, "lan"), [])
  assert_eq(addrs_of(Json::array([]), "lan"), [])
  // Kept: what is not an object of places is nothing, and so is a place that keeps no address left.
  for kept in [b"", b"not json", b"[1]", b"\"x\"", b"\xff\xfe", b"{\"p\":{\"lan\":[\"h:1\"]}}"] {
    assert_eq(said_of(Some(kept)).length(), 0)
  }
  let read = said_of(Some(b"{\"p\":{\"lan\":[\"h:1\",\"10.0.0.1:1\"],\"tailnet\":7},\"q\":3}"))
  assert_eq(read.length(), 1)
  assert_eq(read.get("p").map(said => (said.lan, said.tailnet)), Some((["10.0.0.1:1"], [])))
}

///|
test "a peer's answer says where it is dialled straight: on the link, kept by place, told to the endpoint; and a mesh made after on the same store dials there at once" {
  let values : Map[String, Bytes] = Map([])
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(values)
  far.saying(",\"lan\":[\"192.168.1.5:7000\",\"[::1]:7000\",\"box.lan:1\"],\"tailnet\":[\"100.64.0.9:7000\"]")
  let link = stood.opened(mesh, Source::new().gives(), scope="s")
  assert_eq((link.lan(), link.tailnet()), (["192.168.1.5:7000"], ["100.64.0.9:7000"]))
  assert_eq((mesh.lan(peer, scope="s"), mesh.tailnet(peer, scope="s")), (["192.168.1.5:7000"], ["100.64.0.9:7000"]))
  // (another scope of the same peer said nothing yet)
  assert_eq(mesh.lan(peer), [])
  assert_eq(
    text_of_kept(values),
    "{\"s/\{peer}\":{\"lan\":[\"192.168.1.5:7000\"],\"tailnet\":[\"100.64.0.9:7000\"]}}",
  )
  assert_eq(stood.added, [told_addr(1, [r1], ["192.168.1.5:7000", "100.64.0.9:7000"])])
  // The first dial knew none of it.
  assert_eq(stood.addrs, ["{\"id\":\"\{peer}\",\"relays\":[\"https://r1.test/\"]}"])
  // Said the same again (the link opened anew): nothing more is written, the endpoint told again.
  values.clear()
  mesh.drop_link(peer, scope="s")
  ignore(stood.opened(mesh, Source::new().gives(), scope="s"))
  assert_eq((values.length(), stood.added.length()), (0, 2))
  assert_eq(stood.addrs[1], "{\"id\":\"\{peer}\",\"relays\":[\"https://r1.test/\"],\"ips\":[\"192.168.1.5:7000\",\"100.64.0.9:7000\"]}")
  // A mesh made on what was kept: the place's addresses known before any link, and its first dial given them.
  let kept : Map[String, Bytes] = Map([])
  kept[addresses_key] = @utf8.encode("{\"s/\{peer}\":{\"lan\":[\"192.168.1.5:7000\"],\"tailnet\":[]},\"broken\":{}}")
  let (stood, _) = Stood::with_peer()
  let mesh = stood.keeping(kept)
  assert_eq((mesh.lan(peer, scope="s"), mesh.tailnet(peer, scope="s")), (["192.168.1.5:7000"], []))
  ignore(stood.opened(mesh, Source::new().gives(), scope="s"))
  assert_eq(stood.addrs, ["{\"id\":\"\{peer}\",\"relays\":[\"https://r1.test/\"],\"ips\":[\"192.168.1.5:7000\"]}"])
  // It answered nothing of where it is this time: forgotten, and what is kept says so.
  assert_eq((mesh.lan(peer, scope="s"), text_of_kept(kept)), ([], "{}"))
  assert_eq(stood.added, [])
}

///|
test "kept under the key its program names; malformed there, the mesh is made all the same; a refusal says nothing of where the peer is" {
  let values : Map[String, Bytes] = Map([])
  values["mine"] = b"{\"\{peer}\":"
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(values, addresses="mine")
  assert_eq(mesh.said.length(), 0)
  far.answers = (_, hello) => Some(
    if hello {
      "{\"error\":\"nope\",\"reason\":\"no\",\"lan\":[\"10.0.0.2:1\"]}"
    } else {
      "{\"ok\":true}"
    },
  )
  let link = stood.opened(mesh, Source::new().gives())
  assert_eq((link.lan(), mesh.lan(peer), stood.added), ([], [], []))
  far.saying(",\"lan\":[\"10.0.0.2:1\"]")
  ignore(stood.opened(mesh, Source::new().gives()))
  assert_eq(text_of_kept(values, key="mine"), "{\"\{peer}\":{\"lan\":[\"10.0.0.2:1\"],\"tailnet\":[]}}")
  assert_false(values.contains(addresses_key))
}

///|
test "a dial given addresses does not wait to be on a relay; one that goes unanswered there is kept by those addresses, and a link made lets go of it" {
  let kept : Map[String, Bytes] = Map([])
  kept[addresses_key] = @utf8.encode("{\"\{peer}\":{\"lan\":[\"10.0.0.2:1\"],\"tailnet\":[\"100.64.0.2:1\"]}}")
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(kept)
  stood.on_relay = false
  far.away = true
  let opening = stood.go(() => mesh.link(peer, Source::new().gives()))
  stood.rt.advance(connect_timeout_ms - 1)
  assert_eq(ended_as(opening), "waiting")
  stood.rt.advance(1)
  assert_eq(ended_as(opening), "mesh: " + say("no_answer"))
  assert_eq(mesh.unanswered_at.get({ scope: "", peer }), Some("10.0.0.2:1 100.64.0.2:1"))
  // A place with nothing said waits for a relay first (`onto_max_ms`), as before.
  let (other, far2) = Stood::with_peer()
  let plain = other.keeping(Map([]))
  other.on_relay = false
  far2.away = true
  let waiting = other.go(() => plain.link(peer, Source::new().gives()))
  other.rt.advance(connect_timeout_ms)
  assert_eq(ended_as(waiting), "waiting")
  other.rt.advance(onto_max_ms)
  assert_eq(ended_as(waiting), "mesh: " + say("no_answer"))
  assert_eq(plain.unanswered_at.length(), 0)
  // The peer answers again: the endpoint taken for stuck is bound anew and dialled on; the link lets go of it.
  far.away = false
  stood.on_relay = true
  ignore(stood.opened(mesh, Source::new().gives()))
  assert_eq(mesh.unanswered_at.length(), 0)
}

///|
test "through relays alone no address is given to a dial nor told the endpoint; what its program says of a peer is told without them" {
  let kept : Map[String, Bytes] = Map([])
  kept[addresses_key] = @utf8.encode("{\"\{peer}\":{\"lan\":[\"10.0.0.2:1\"],\"tailnet\":[]}}")
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(kept, relay_only=true)
  far.saying(",\"lan\":[\"10.0.0.3:1\"]")
  ignore(stood.opened(mesh, Source::new().gives()))
  assert_eq(stood.addrs, ["{\"id\":\"\{peer}\",\"relays\":[\"https://r1.test/\"]}"])
  // (kept all the same: an endpoint on its relays alone is no reason to forget where a peer is)
  assert_eq(mesh.lan(peer), ["10.0.0.3:1"])
  assert_eq(stood.added, [])
  mesh.add_addr(peer, relays=[r2], ips=["10.0.0.4:1"])
  assert_eq(stood.added, [told_addr(1, [r2], [])])
}

///|
test "where its program says a peer is: told the endpoint at once, replaced as it says again (where it was), and told each endpoint bound after it, the one bound for other relays and the one bound for being stuck" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(Map([]))
  mesh.add_addr(peer, relays=[r2], ips=["10.0.0.4:1"])
  mesh.add_addr("ee".repeat(32))
  mesh.add_addr(peer, ips=["10.0.0.5:1"])
  assert_eq(stood.added, [
    told_addr(1, [r2], ["10.0.0.4:1"]),
    "1 {\"id\":\"\{"ee".repeat(32)}\",\"relays\":[]}",
    told_addr(1, [], ["10.0.0.5:1"]),
  ])
  stood.added.clear()
  // Bound on other relays: the new endpoint (2) is told what is known, as it now is.
  mesh.retune([r3])
  stood.run()
  assert_eq(stood.added, [told_addr(2, [], ["10.0.0.5:1"]), "2 {\"id\":\"\{"ee".repeat(32)}\",\"relays\":[]}"])
  stood.added.clear()
  // Said while the endpoint is being bound anew: kept, and told the one that comes, not the one that goes.
  stood.holding = "iroh.bind"
  mesh.retune([r1])
  stood.run()
  mesh.add_addr(peer, ips=["10.0.0.6:1"])
  assert_eq(stood.added, [])
  stood.holding = ""
  stood.bound()
  assert_eq(stood.added, [told_addr(3, [], ["10.0.0.6:1"]), "3 {\"id\":\"\{"ee".repeat(32)}\",\"relays\":[]}"])
  stood.added.clear()
  // Bound anew for being stuck (a dial unanswered, then the next link): told again.
  far.away = true
  let opening = stood.go(() => mesh.link(peer, Source::new().gives()))
  stood.rt.advance(connect_timeout_ms)
  assert_eq(ended_as(opening), "mesh: " + say("no_answer"))
  far.away = false
  stood.rt.advance(rebind_ms)
  ignore(stood.opened(mesh, Source::new().gives()))
  assert_eq(stood.added, [told_addr(4, [], ["10.0.0.6:1"]), "4 {\"id\":\"\{"ee".repeat(32)}\",\"relays\":[]}"])
  // Closed, nothing more is told.
  stood.added.clear()
  ignore(stood.go(() => mesh.close()))
  mesh.add_addr(peer, ips=["10.0.0.7:1"])
  assert_eq(stood.added, [])
}
