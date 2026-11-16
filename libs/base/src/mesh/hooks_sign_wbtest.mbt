// What a program asks of the mesh beside its links (hooks.mbt): a slow read's other way and when, its time as a
// ping; signing with the device key, by the shell or here; Opus; the device key taken over.

///|
test "the device key signs: by the shell where it signs, else here, RFC 8032's signatures either way" {
  let kept : Map[String, Bytes] = Map([])
  let (stood, _) = Stood::with_peer()
  let made = stood.go(() => Mesh::make(
    stood.shell.val.unwrap(),
    {
      get: key => if key == device_key { Some(unhex(rfc8032[1].0)) } else { kept.get(key) },
      set: (key, value) => kept[key] = value,
    },
    { alpn: "test/1", relays: [r1], relay_only: false, says: None, refusal: None },
  ))
  guard made.poll() is Some(Succeeded(mesh)) else { fail("the mesh was not made") }
  let (public_key, signature) = mesh.sign(unhex(rfc8032[1].1))
  assert_eq((hex_of(public_key), hex_of(signature)), (rfc8032[1].2, rfc8032[1].3))
  // The shell signs: asked the seed and the message in hex, and what it answers is given.
  stood.signs = Some({ "publicKey": "aa".repeat(32), "signature": "bb".repeat(64) })
  let (public_key, signature) = mesh.sign(b"\x72")
  assert_eq((public_key, signature), (Bytes::make(32, b'\xaa'), Bytes::make(64, b'\xbb')))
  assert_eq(stood.sign_asks, ["{\"seed\":\"\{rfc8032[1].0}\",\"message\":\"72\"}"])
  // What it answers that is not a key and a signature: signed here.
  stood.signs = Some({ "publicKey": "zz", "signature": "bb" })
  assert_eq(hex_of(mesh.sign(b"\x72").1), rfc8032[1].3)
  // A signature checked: here where the shell has no `crypto.verify`, by the shell where it has, asked in hex.
  let (key, message, signature) = (unhex(rfc8032[2].2), unhex(rfc8032[2].1), unhex(rfc8032[2].3))
  assert_true(mesh.verify(key, message, signature))
  assert_false(mesh.verify(key, b"\x00", signature))
  stood.verifies = Some(Json::boolean(false))
  assert_false(mesh.verify(key, message, signature))
  assert_eq(stood.verify_asks, [
    "{\"alg\":\"Ed25519\",\"key\":\"\{rfc8032[2].2}\",\"signature\":\"\{rfc8032[2].3}\",\"message\":\"af82\"}",
  ])
  stood.verifies = Some(Json::boolean(true))
  assert_true(mesh.verify(key, b"\x00", signature))
  // What it answers that is no yes or no: checked here.
  stood.verifies = Some(Json::null())
  assert_false(mesh.verify(key, b"\x00", signature))
  // Opus: where the shell says the endpoint decodes it.
  assert_false(mesh.decodes_opus())
  stood.opus = Some(true)
  assert_true(mesh.decodes_opus())
}

///|
test "a slow read's other way: the best other way answering, going another way; how long a read waits before it is asked there; a read's time counted as a ping" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(Map([]))
  far.lag[r1] = 1200
  far.lag[r2] = 40
  ignore(stood.asked(mesh, theirs=[r2], off=["direct"], ms=1200))
  assert_eq(mesh.on_way(), r2)
  guard mesh.current(peer) is Some(cur) else { fail("no link") }
  guard mesh.live_ways(here).iter().find_first(way => way.link.pin == Some(r1)) is Some(slow) else { fail("no r1 way") }
  // Not pinged yet: the floor.
  assert_eq(mesh.hedge_after(cur), hedge_floor_ms)
  stood.rt.advance(3 * (tick_ms + 1200))
  assert_true(mesh.standby(cur) is Some(link) && physical_equal(link, slow.link))
  assert_true(mesh.standby(slow.link) is Some(link) && physical_equal(link, cur))
  assert_eq(mesh.hedge_after(cur), hedge_floor_ms)
  assert_eq(mesh.hedge_after(slow.link), 1200)
  // A read on r1 outran by 2 000 ms: one more sample of it.
  let samples = slow.link.samples
  mesh.outran(slow.link, 2000)
  assert_eq(slow.link.samples, samples + 1)
  assert_eq(slow.link.srtt, 1200.0 * 0.875 + 2000.0 * 0.125)
  // A way missing its pings is no standby.
  far.deaf.clear()
  slow.link.missed = 1
  assert_true(mesh.standby(cur) is None)
}

///|
test "a device key taken over: kept, the endpoint bound anew with it and told where peers are, everything on the one before let go of; the same key again, nothing; one not 32 bytes, refused" {
  let kept : Map[String, Bytes] = Map([])
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(kept)
  far.lag[r1] = 10
  far.lag[r2] = 20
  ignore(stood.asked(mesh, theirs=[r2], off=["direct"], ms=20))
  mesh.add_addr("ee".repeat(32), ips=["10.0.0.9:1"])
  let pinned = [stood.endpoint_on(r1), stood.endpoint_on(r2)]
  guard mesh.current(peer) is Some(before) else { fail("no link") }
  let told = stood.go(() => mesh.replaced(before))
  assert_eq(ended_as(stood.go(() => mesh.migrate(b"short"))), "invalid_params: " + say("bad_device_key"))
  assert_eq(ended_as(stood.go(() => mesh.migrate(Bytes::make(32, b'\x01')))), "ok")
  assert_eq(stood.binds.length(), 3)
  assert_eq(ended_as(stood.go(() => mesh.migrate(Bytes::make(32, b'\x02')))), "ok")
  assert_eq((stood.binds.length(), stood.bind_keys[3]), (4, Bytes::make(32, b'\x02')))
  assert_eq(kept.get(device_key), Some(Bytes::make(32, b'\x02')))
  assert_eq(mesh.secret, Bytes::make(32, b'\x02'))
  assert_eq(ended_as(told), "ok")
  assert_true(mesh.current(peer) is None && mesh.open_ways().length() == 0)
  assert_true(far.closes.iter().all(close => close.has_suffix("device key replaced")) && far.closes.length() >= 2)
  for endpoint in [1, ..pinned] {
    assert_eq(stood.times("iroh.close \{endpoint}"), 1)
  }
  let endpoint = handle_of({ "id": mesh.endpoint })
  assert_true(stood.added.contains("\{endpoint} {\"id\":\"\{"ee".repeat(32)}\",\"relays\":[],\"ips\":[\"10.0.0.9:1\"]}"))
  // The next link is dialled on the new endpoint.
  far.lag.clear()
  ignore(stood.asked(mesh))
  assert_eq(mesh.on_way(), r1)
  assert_eq(stood.times("iroh.close \{endpoint}"), 0)
}
