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
