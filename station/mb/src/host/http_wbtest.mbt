///|
/// The shell's `fetch` as a test has it: each call given an id, answered `after` ms on with `said` and `body`; what was
/// asked, and the ids cancelled.
struct FakeFetch {
  after : Int
  said : Json
  body : Bytes?
  asked : Array[Json]
  cancelled : Array[Int64]
  mut next : Int64
}

///|
fn FakeFetch::new(after : Int, said : Json, body : Bytes?) -> FakeFetch {
  { after, said, body, asked: [], cancelled: [], next: 0L }
}

///|
fn FakeFetch::fetch(self : FakeFetch, timeout_ms : Int?) -> async () -> FetchResponse {
  async fn() {
    fetch_by(
      async fn(args, _body, called) {
        self.next += 1L
        called(self.next)
        self.asked.push(args)
        @effect.sleep(self.after)
        (self.said, self.body)
      },
      id => self.cancelled.push(id),
      { "url": "https://example.test/" },
      None,
      timeout_ms,
    )
  }
}

///|
let answer : Json = { "status": 201, "headers": [["content-type", "text/plain"], ["x-one", "1"]] }

///|
test "fetch: its status, headers and body; nothing cancelled" {
  let fake = FakeFetch::new(5, answer, Some(b"hi"))
  let rt = @effect.Runtime::new()
  let f = rt.fork(fake.fetch(Some(100)))
  rt.advance(10)
  guard f.poll() is Some(Succeeded(r)) else { fail("not answered") }
  assert_eq(r.status, 201)
  assert_eq(r.text(), "hi")
  assert_eq(r.header("Content-Type"), Some("text/plain"))
  assert_eq(r.header("X-ONE"), Some("1"))
  assert_eq(r.header("x-two"), None)
  assert_eq(r.redirected, false)
  assert_eq(fake.cancelled, [])
}

///|
test "fetch: an answer the shell had by a redirect followed says so" {
  let fake = FakeFetch::new(1, { "status": 200, "redirected": true }, Some(b"there"))
  let rt = @effect.Runtime::new()
  let f = rt.fork(fake.fetch(None))
  rt.advance(5)
  guard f.poll() is Some(Succeeded(r)) else { fail("not answered") }
  assert_eq((r.status, r.redirected, r.text()), (200, true, "there"))
}

///|
test "fetch: no body is an empty one" {
  let fake = FakeFetch::new(1, { "status": 204 }, None)
  let rt = @effect.Runtime::new()
  let f = rt.fork(fake.fetch(None))
  rt.advance(5)
  guard f.poll() is Some(Succeeded(r)) else { fail("not answered") }
  assert_eq(r.status, 204)
  assert_eq(r.headers, [])
  assert_eq(r.body, b"")
  assert_eq(fake.cancelled, [])
}

///|
test "fetch: its deadline passed, FetchTimeout, the shell's call cancelled" {
  let fake = FakeFetch::new(1000, answer, Some(b"late"))
  let rt = @effect.Runtime::new()
  let f = rt.fork(fake.fetch(Some(50)))
  rt.advance(60)
  match f.poll() {
    Some(Failed(FetchTimeout)) => ()
    other => fail("not timed out: \{other is None}")
  }
  assert_eq(fake.cancelled, [1L])
  rt.advance(2000)
  assert_eq(fake.cancelled, [1L])
}

///|
test "fetch: interrupted, the shell's call cancelled" {
  let fake = FakeFetch::new(1000, answer, None)
  let rt = @effect.Runtime::new()
  let f = rt.fork(fake.fetch(None))
  rt.advance(10)
  assert_eq(fake.cancelled, [])
  f.interrupt()
  rt.advance(10)
  assert_true(f.poll() is Some(Interrupted))
  assert_eq(fake.cancelled, [1L])
}

///|
test "fetch: interrupted from outside its deadline, cancelled once" {
  let fake = FakeFetch::new(1000, answer, None)
  let rt = @effect.Runtime::new()
  let f = rt.fork(fake.fetch(Some(500)))
  rt.advance(10)
  f.interrupt()
  rt.advance(1000)
  assert_true(f.poll() is Some(Interrupted))
  assert_eq(fake.cancelled, [1L])
}

///|
test "fetch_args: forwards non-empty proxy and ca_pem, omits empty or None" {
  let with_both = fetch_args(
    "https://example.test/v1/admin/me",
    "GET",
    [],
    None,
    None,
    None,
    None,
    Some("http://127.0.0.1:8080"),
    Some("-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----\n"),
  )
  assert_true(with_both is { "proxy": String("http://127.0.0.1:8080"), "caPem": String(_), .. })

  let with_empty = fetch_args(
    "https://example.test/v1/admin/me",
    "GET",
    [],
    None,
    None,
    None,
    None,
    Some(""),
    Some(""),
  )
  match with_empty {
    Object(m) => {
      assert_true(m.get("proxy") is None)
      assert_true(m.get("caPem") is None)
    }
    _ => fail("expected object")
  }
}
