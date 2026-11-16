// How fast each way brings a peer's replies, and what each peer's links carried today (speed.mbt). On the peer that
// answers by itself (stood_wbtest.mbt), the mesh on `[r1]` keeping in a store of the test's (addrs_wbtest.mbt).

///|
test "a day is counted from 1970 where the clock is, before it below 0; a way's cost is its round trip and what a typical reply takes at the speed seen" {
  assert_eq(local_day(0L, 0), 0L)
  assert_eq(local_day(86_399_999L, 0), 0L)
  assert_eq(local_day(86_400_000L, 0), 1L)
  assert_eq(local_day(-1L, 0), -1L)
  assert_eq(local_day(-86_400_000L, 0), -1L)
  assert_eq(local_day(-86_400_001L, 0), -2L)
  assert_eq(local_day(16L * 3_600_000L, 480), 1L)
  assert_eq(local_day(7L * 3_600_000L, -480), -1L)
  assert_eq(cost(30.0, None), 30.0)
  assert_eq(cost(30.0, Some(0.0)), 30.0)
  assert_eq(cost(30.0, Some(typical_bytes.to_double())), 1030.0)
}

///|
test "a speed seen is noted where its reply was long enough, the fastest held speed_fresh_ms, kept speed_kept_ms and in the store, read by a mesh made after; forgotten on another network" {
  let values : Map[String, Bytes] = Map([])
  let (stood, _) = Stood::with_peer()
  let mesh = stood.keeping(values)
  mesh.note_speed(peer, r1, speed_min_bytes - 1, 100)
  mesh.note_speed(peer, r1, speed_min_bytes, 0)
  assert_eq((mesh.speed(peer, r1), values.contains(speed_key)), (None, false))
  mesh.note_speed(peer, "https://r1.test", 1024 * 1024, 1000)
  stood.run()
  assert_eq(mesh.speed(peer, r1), Some(1048576.0))
  assert_eq(text_of_kept(values, key=speed_key), "{\"\{peer}\":{\"https://r1.test/\":{\"bps\":1048576,\"at\":0}}}")
  // Slower within speed_fresh_ms: the fastest holds; after it, the slower is how fast it is now.
  mesh.note_speed(peer, r1, speed_min_bytes, 1000)
  assert_eq(mesh.speed(peer, r1), Some(1048576.0))
  stood.rt.advance(speed_fresh_ms)
  mesh.note_speed(peer, r1, speed_min_bytes, 1000)
  assert_eq(mesh.speed(peer, r1), Some(524288.0))
  stood.run()
  // A mesh made after reads it; past speed_kept_ms it counts no more.
  let (again, _) = Stood::with_peer()
  again.rt.advance(speed_fresh_ms)
  let other = again.keeping(values)
  assert_eq(other.speed(peer, r1), Some(524288.0))
  again.rt.advance(speed_kept_ms)
  assert_eq(other.speed(peer, r1), None)
  // On another network: forgotten, and so kept.
  mesh.wake(network=true)
  stood.run()
  assert_eq((mesh.speed(peer, r1), text_of_kept(values, key=speed_key)), (None, "{}"))
  // What cannot be read is nothing.
  values[speed_key] = b"{\"\{peer}\":{\"x\":{\"bps\":\"fast\"}},\"y\":3}"
  let (third, _) = Stood::with_peer()
  assert_eq(third.keeping(values).speeds.length(), 0)
}

///|
test "the way requests go on found slower than it was taken to be: they move at once to one clearly better counting its speed" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(Map([]))
  far.lag[r1] = 30
  far.lag[r2] = 40
  ignore(stood.asked(mesh, theirs=[r2], off=["direct"], ms=40))
  stood.paths_of[far.conn_of(r1)] = [{ "id": "0", "selected": true, "relay": r1 }]
  stood.paths_of[far.conn_of(r2)] = [{ "id": "0", "selected": true, "relay": r2 }]
  stood.rt.advance(5 * (tick_ms + 40))
  assert_eq(mesh.on_way(), r1)
  // 512 KiB in 10 s: a typical reply takes 5 s through it, r2 now clearly better; moved, not after min_stay_ms.
  mesh.note_speed(peer, r1, speed_min_bytes, 10_000)
  assert_eq((mesh.on_way(), mesh.moves(peer), mesh.moved(peer)), (r2, 1, Some("r2.test")))
  assert_eq(mesh.score_of(here, mesh.live_ways(here)[0]).cost, 5030.0)
}

///|
test "a reply timed as it is read: once it brought speed_min_bytes, how fast its way brought bytes since it began is noted, its first piece the start" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(Map([]))
  let link = stood.opened(mesh, Source::new().gives())
  far.opens = _ => Some(replied(200, b""))
  let (reply, _) = gave(stood.go(() => link.duplex("GET", "/x")))
  let timed = mesh.timed(peer, r1, reply)
  let reading = stood.go(() => timed.rest())
  far.sends(4, Bytes::make(1000, b'a'))
  stood.run()
  stood.rt.advance(400)
  far.sends(4, Bytes::make(256 * 1024, b'b'))
  stood.run()
  assert_eq(mesh.speed(peer, r1), None)
  stood.rt.advance(100)
  far.sends(4, Bytes::make(256 * 1024, b'c'))
  stood.run()
  // 512 KiB in 500 ms.
  assert_eq(mesh.speed(peer, r1), Some(1048576.0))
  far.finish(4)
  stood.run()
  assert_eq(ended_as(reading), "ok")
}

///|
test "what a peer's links carried today, in every scope, counted as asked, every tally_every_ms while one is open, and as one is let go of; kept by day, none yesterday's" {
  let values : Map[String, Bytes] = Map([])
  let (stood, _) = Stood::with_peer()
  let mesh = stood.keeping(values)
  let a = stood.opened(mesh, Source::new().gives())
  let b = stood.opened(mesh, Source::new(of="a").gives(), scope="s")
  stood.rx[a.conn_handle()] = 1000.0
  stood.tx[a.conn_handle()] = 500.0
  stood.rx[b.conn_handle()] = 10.0
  assert_eq(mesh.today(peer), (1010L, 500L))
  stood.rx[a.conn_handle()] = 1500.0
  stood.rt.advance(tally_every_ms)
  assert_eq(text_of_kept(values, key=net_day_key), "{\"\{peer}\":{\"day\":0,\"rx\":1510,\"tx\":500}}")
  // Let go of: what it carried since is counted first.
  stood.rx[b.conn_handle()] = 30.0
  mesh.drop_link(peer, scope="s")
  assert_eq(mesh.today(peer), (1530L, 500L))
  // The next day: what is carried from then is that day's.
  stood.rt.advance(86_400_000 - tally_every_ms)
  stood.rx[a.conn_handle()] = 1600.0
  assert_eq(mesh.today(peer), (100L, 0L))
  stood.rt.advance(tally_every_ms)
  assert_eq(text_of_kept(values, key=net_day_key), "{\"\{peer}\":{\"day\":1,\"rx\":100,\"tx\":0}}")
  // None open: nothing is counted on a timer any more.
  mesh.drop_link(peer)
  stood.rt.advance(tally_every_ms)
  assert_false(mesh.tallying)
  // A mesh made after reads what was kept.
  let (again, _) = Stood::with_peer()
  again.rt.advance(86_400_000)
  assert_eq(again.keeping(values).today(peer), (100L, 0L))
}

///|
test "how a link runs: its way, its relay's host, its round trip, what it carried, the packets of the way in use" {
  let (stood, _) = Stood::with_peer()
  let mesh = stood.keeping(Map([]))
  let link = stood.opened(mesh, Source::new().gives())
  assert_eq(link.net(), { path: None, relay: None, rtt_ms: None, rx_bytes: 0L, tx_bytes: 0L, packets: None })
  stood.rx[link.conn_handle()] = 2048.0
  stood.tx[link.conn_handle()] = 1024.0
  stood.paths_of[link.conn_handle()] = [
    { "id": "1", "selected": false, "relay": Json::null(), "ip": "10.0.0.2:1" },
    {
      "id": "3",
      "selected": true,
      "relay": "https://r1.test:8443/",
      "rttMs": 12.5,
      "txPackets": 10,
      "lostPackets": 1,
    },
  ]
  assert_eq(link.net(), {
    path: Some("relay"),
    relay: Some("r1.test:8443"),
    rtt_ms: Some(12.5),
    rx_bytes: 2048L,
    tx_bytes: 1024L,
    packets: Some({ path: "3", sent: 10L, lost: 1L }),
  })
  stood.paths_of[link.conn_handle()] = [{ "id": 4, "selected": true, "relay": Json::null(), "ip": "10.0.0.2:1" }]
  assert_eq(link.net().path, Some("direct"))
  assert_eq(link.net().packets, Some({ path: "4", sent: 0L, lost: 0L }))
}
