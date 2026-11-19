// A failed directory exchange as scope-sync.ts `#pump` takes it: a peer from before the exchange is level until this
// station's word changes, a peer that does not answer is tried again from 5 s doubling to 10 min (said at INFO), and
// a failure of this station's own directory from 1 s doubling to 60 s (said at WARN).

///|
fn job_of() -> Job {
  {
    scope: "s",
    workspace: "w1",
    peer: "bb".repeat(32),
    done: "",
    running: false,
    wait: 0,
    cancel: None,
  }
}

///|
fn peer_waits(job : Job, n : Int, said : String) -> Array[Int] raise {
  let out = []
  for _ in 0..<n {
    guard job.failed("w", true, said) is Peer(ms) else { fail("not a peer's failure: \{said}") }
    out.push(ms)
  }
  out
}

///|
test "a station from before the exchange is level until this station's word changes" {
  for said in [
    "PeerRefused(\"session and task key are required (at most 256 / 128 bytes)\")",
    "Failure(\"Session and task key is required\")",
    "unsupported peer method",
    "unknown method: meshScopes.exchange",
    "no such method: the mesh directory is not available on this station",
  ] {
    let job = job_of()
    job.wait = 20_000
    guard job.failed("word-1", true, said) is Level else { fail("not level: \{said}") }
    assert_eq(job.done, "word-1")
    assert_eq(job.wait, 0)
  }
}

///|
test "a peer that does not answer is tried again from 5 s, doubling up to 10 min" {
  let job = job_of()
  assert_eq(peer_waits(job, 9, "mesh peer unreachable: timed out"), [
    5_000, 10_000, 20_000, 40_000, 80_000, 160_000, 320_000, 600_000, 600_000,
  ])
  // (not level: tried again with the same word)
  assert_eq(job.done, "")
}

///|
test "this station's own directory failing is tried again from 1 s, doubling up to 60 s" {
  let job = job_of()
  let waits = []
  for _ in 0..<8 {
    guard job.failed("w", false, "relay workspace removed") is Own(ms) else { fail("not this station's failure") }
    waits.push(ms)
  }
  assert_eq(waits, [1000, 2000, 4000, 8000, 16000, 32000, 60000, 60000])
  // (a refusal like an old peer's that is not the peer's call is this station's own)
  let own = job_of()
  guard own.failed("w", false, "session and task key are required") is Own(1000) else {
    fail("an own failure taken for an old peer")
  }
  assert_eq(own.done, "")
}

///|
test "a peer that answered again starts its backoff anew" {
  let job = job_of()
  ignore(peer_waits(job, 3, "connection lost"))
  assert_eq(job.wait, 20_000)
  // (an exchange that went through: pump sets done and wait = 0)
  job.wait = 0
  assert_eq(peer_waits(job, 1, "connection lost"), [5_000])
}

// A workspace's scope is one across still.fail's two origins (enrollment-door.ts `workspaceScope`), and an exchange asks
// a peer only for the nodes this station's roster has (scope-exchange.ts `exchangeSignedRecords`).

///|
fn plain_crypto() -> Crypto {
  {
    verify: fn(_k, _b, _s) { false },
    sign: fn(_t) { "" },
    sha256: b => hex_of(b[:]),
    random: n => Bytes::make(n, b'\x00'),
  }
}

///|
test "app.monoid.build and app.still.fail name one workspace's scope; another origin does not" {
  let c = plain_crypto()
  let still = workspace_scope(c, "https://app.still.fail", "w1")
  assert_eq(workspace_scope(c, "https://app.monoid.build", "w1"), still)
  assert_eq(workspace_scope(c, "https://app.monoid.build/", "w1"), still)
  assert_eq(workspace_scope(c, "https://app.still.fail//", "w1"), still)
  assert_true(workspace_scope(c, "https://example.test", "w1") != still)
  assert_true(workspace_scope(c, "https://app.monoid.build", "w2") != still)
}

///|
fn signed_of(node : String, revision : Int) -> Json {
  let body : Json = { "node": Json::string(node), "revision": Json::number(revision.to_double()) }
  { "body": Json::string(body.stringify()) }
}

///|
fn exchange_asking(admits : ((String) -> Bool)?) -> (Array[Array[String]], Array[Json]) raise {
  let admitted = "aa".repeat(32)
  let other = "cc".repeat(32)
  let asked : Array[Array[String]] = []
  let taken : Array[Json] = []
  let rt = @effect.Runtime::new()
  let send = async fn(req : Json) -> Json {
    let versions = Json::object(Map([(admitted, Json::number(1)), (other, Json::number(1))]))
    match field(req, "want") {
      Array(want) => {
        let ids = want.map(w => text(w).unwrap_or(""))
        asked.push(ids)
        { "versions": versions, "records": Json::array(ids.map(id => signed_of(id, 1))) }
      }
      _ => { "versions": versions, "records": Json::array([]) }
    }
  }
  let take = async fn(records : Array[Json]) { taken.append(records) }
  let done = rt.fork(async fn() {
    match admits {
      Some(a) => exchange_signed_records(() => [], take, send, "revision", admits=a)
      None => exchange_signed_records(() => [], take, send, "revision")
    }
  })
  rt.advance(1)
  guard done.poll() is Some(@effect.Succeeded(_)) else { fail("the exchange did not end well") }
  (asked, taken)
}

///|
test "a node on the peer's roster and not on this station's is not asked for; the admitted one is still taken" {
  let admitted = "aa".repeat(32)
  let (asked, taken) = exchange_asking(Some(id => id == admitted))
  assert_eq(asked, [[admitted]])
  assert_eq(taken.length(), 1)
  assert_eq(taken[0], signed_of(admitted, 1))
  // With nothing to admit by, every newer node is asked for, as before.
  let (all, _) = exchange_asking(None)
  assert_eq(all.length(), 1)
  assert_eq(all[0].length(), 2)
}
