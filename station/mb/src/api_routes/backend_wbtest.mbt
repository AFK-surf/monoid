// The routes' binary reads (a session file's part, a file whole, a stream's pieces, a reader's answer) asked through
// `Backend::ask_bytes`: given as they are where the station gives `call_bytes` (never base64 through `call`), and
// `call`'s `{"$bytes": base64}` decoded where it does not.

///|
/// `f` run to its end on a runtime of its own (it waits on nothing outside).
fn[X] bytes_ran(f : async () -> X) -> X {
  let rt = @effect.Runtime::new()
  let fiber = rt.fork(f)
  ignore(rt.run_ready())
  match fiber.poll() {
    Some(Succeeded(v)) => v
    Some(Failed(e)) => abort("it failed: \{e}")
    _ => abort("it did not end")
  }
}

///|
/// Every byte, 0x00 to 0xFF, twice: what a binary read must give back exactly.
fn every_byte() -> Bytes {
  Bytes::makei(512, i => (i % 256).to_byte())
}

///|
let binary_reads : Array[String] = [
  "drive/fs.readAt", "fs.readFile", "$stream.next", "readers.readBytes",
]

///|
priv struct BytesParts {
  calls : Array[String]
  byte_calls : Array[(String, Array[JV])]
  stream : Array[Bytes]
}

///|
fn bytes_parts(pieces : Array[Bytes]) -> BytesParts {
  { calls: [], byte_calls: [], stream: pieces }
}

///|
/// The JSON parts: a file opened, its size, closed; a binary read asked here fails the test when `direct`.
async fn BytesParts::call(
  self : BytesParts,
  name : String,
  args : Array[JV],
  direct : Bool,
) -> JV {
  self.calls.push(name)
  if direct && binary_reads.contains(name) {
    raise Thrown("Error", jobj([("message", js("\{name} asked through call"))]))
  }
  match name {
    "fs.open" => jref("fh:1")
    "fh:1.stat" => jobj([("size", jint(every_byte().length()))])
    "fh:1.close" => Null
    _ => match self.bytes(name, args) {
      Some(b) => jbytes(b)
      None => Null
    }
  }
}

///|
/// The binary parts, as the station gives them.
fn BytesParts::bytes(self : BytesParts, name : String, args : Array[JV]) -> Bytes? {
  self.byte_calls.push((name, args))
  match name {
    "drive/fs.readAt" => {
      let all = every_byte()
      let from = jnumber(args.get(1)).unwrap_or(0.0).to_int()
      let want = jnumber(args.get(2)).unwrap_or(0.0).to_int()
      Some(all[from:@cmp.minimum(from + want, all.length())].to_bytes())
    }
    "fs.readFile" | "readers.readBytes" => Some(every_byte())
    "$stream.next" =>
      if self.stream.length() > 0 {
        Some(self.stream.remove(0))
      } else {
        None
      }
    _ => None
  }
}

///|
/// An admin on these parts, the binary reads given as they are (`direct`) or only through `call`.
fn BytesParts::admin(self : BytesParts, direct : Bool) -> Admin {
  let backend = if direct {
    Backend::new(async fn(name, args) { self.call(name, args, true) }, call_bytes=async fn(
      name,
      args,
    ) {
      self.bytes(name, args)
    })
  } else {
    Backend::new(async fn(name, args) { self.call(name, args, false) })
  }
  Admin::new(
    backend,
    Setup::new(Words::new(Obj([]), Obj([])), "0.0.0", [], false, None, b"", "zh", []),
  )
}

///|
fn bytes_request() -> Request {
  Request::new(
    "GET",
    "/sessions/s1/messages",
    [],
    None,
    [],
    b"",
    jobj([("workspace", js("w1")), ("sub", js("u1")), ("email", js("u1@x")), ("name", js(""))]),
    "en",
  )
}

///|
/// Every binary read, through `a`: a part from 3, the file whole, the stream's pieces, a reader's answer.
fn bytes_read_all(a : Admin) -> (Bytes, Bytes, Array[Bytes], Bytes) {
  bytes_ran(async fn() {
    let part = a.range_answer("/f.bin", "application/octet-stream", 3.0, 300.0)
    let whole = a.read_file("/f.bin")
    let next = a.stream_of(jobj([("$stream", jint(7))]))
    let pieces = []
    while next() is Some(p) {
      pieces.push(p)
    }
    let read = a.read(bytes_request(), "messages", jobj([]))
    (part.whole().unwrap_or(b""), whole, pieces, read.whole().unwrap_or(b""))
  })
}

///|
test "binary reads are given as they are where the station gives call_bytes" {
  let all = every_byte()
  let parts = bytes_parts([all[0:256].to_bytes(), all[256:].to_bytes()])
  let (part, whole, pieces, read) = bytes_read_all(parts.admin(true))
  assert_eq(part, all[3:303].to_bytes())
  assert_eq(whole, all)
  assert_eq(pieces, [all[0:256].to_bytes(), all[256:].to_bytes()])
  assert_eq(read, all)
  // (the JSON parts only: the file opened, its size, closed; no binary read through `call`)
  for c in parts.calls {
    assert_true(!binary_reads.contains(c), msg="\{c} asked through call")
  }
  assert_eq(parts.calls, ["fs.open", "fh:1.stat", "fh:1.close"])
  assert_eq(parts.byte_calls.map(c => c.0), [
    "drive/fs.readAt", "fs.readFile", "$stream.next", "$stream.next", "$stream.next",
    "readers.readBytes",
  ])
  // (the part asked of the handle `fs.open` gave, from 3, as much as there is)
  assert_eq(ref_of(parts.byte_calls[0].1[0]), Some("fh:1"))
  assert_eq(jnumber(parts.byte_calls[0].1.get(1)), Some(3.0))
  assert_eq(jnumber(parts.byte_calls[0].1.get(2)), Some(300.0))
  // (the reader asked as before: its op, its arguments, the request's language, its options)
  assert_eq(js_string(parts.byte_calls[5].1.get(0)), "messages")
  assert_eq(js_string(parts.byte_calls[5].1.get(2)), "en")
}

///|
test "binary reads still decode call's base64 where the station gives no call_bytes" {
  let all = every_byte()
  let parts = bytes_parts([all[0:256].to_bytes(), all[256:].to_bytes()])
  let (part, whole, pieces, read) = bytes_read_all(parts.admin(false))
  assert_eq(part, all[3:303].to_bytes())
  assert_eq(whole, all)
  assert_eq(pieces, [all[0:256].to_bytes(), all[256:].to_bytes()])
  assert_eq(read, all)
  assert_eq(parts.calls, [
    "fs.open", "fh:1.stat", "drive/fs.readAt", "fh:1.close", "fs.readFile", "$stream.next",
    "$stream.next", "$stream.next", "readers.readBytes",
  ])
}

///|
test "ask_bytes: call_bytes's answer as it is, null through call as none" {
  let parts = bytes_parts([])
  let direct = Backend::new(async fn(name, args) { parts.call(name, args, true) }, call_bytes=async fn(
    name,
    args,
  ) {
    parts.bytes(name, args)
  })
  let plain = Backend::new(async fn(name, args) { parts.call(name, args, false) })
  let (a, b, c, d) = bytes_ran(async fn() {
    (
      direct.ask_bytes("fs.readFile", [js("/f.bin")]),
      direct.ask_bytes("$stream.next", [jint(1)]),
      plain.ask_bytes("fs.readFile", [js("/f.bin")]),
      plain.ask_bytes("$stream.next", [jint(1)]),
    )
  })
  assert_eq(a, Some(every_byte()))
  assert_eq(b, None)
  assert_eq(c, Some(every_byte()))
  assert_eq(d, None)
  assert_eq(parts.calls, ["fs.readFile", "$stream.next"])
}
