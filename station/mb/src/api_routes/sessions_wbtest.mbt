// Native MoonBit whitebox tests for GET /sessions/:key/files thumb query routing (sessions.mbt).

///|
priv struct SessionFileParts {
  calls : Array[(String, Array[JV])]
}

///|
fn SessionFileParts::admin(self : SessionFileParts) -> Admin {
  Admin::new(
    Backend::new(async fn(name, args) {
      self.calls.push((name, args))
      match name {
        "store.getSession" => jobj([("workspace", js("/ws/s1"))])
        "fs.stat" =>
          match jstr(args.get(0)) {
            Some("/ws/s1/uploads/shot.png") =>
              jobj([("file", jbool(true)), ("size", jint(4))])
            Some("/data/thumbs/shot.jpg") =>
              jobj([("file", jbool(true)), ("size", jint(5))])
            Some("/data/thumbs/shot.p.jpg") =>
              jobj([("file", jbool(true)), ("size", jint(7))])
            _ =>
              raise Thrown(
                "Error",
                jobj([("code", js("ENOENT")), ("message", js("no such file"))]),
              )
          }
        "fs.readFile" =>
          match jstr(args.get(0)) {
            Some("/ws/s1/uploads/shot.png") => jbytes(b"ORIG")
            Some("/data/thumbs/shot.jpg") => jbytes(b"THUMB")
            Some("/data/thumbs/shot.p.jpg") => jbytes(b"PREVIEW")
            _ => Null
          }
        "drive/thumbs.dir" => js("/data/thumbs")
        "drive/thumbs.thumbnail" =>
          jobj([("path", js("/data/thumbs/shot.jpg")), ("type", js("image/jpeg"))])
        "drive/thumbs.preview" =>
          jobj([("path", js("/data/thumbs/shot.p.jpg")), ("type", js("image/jpeg"))])
        _ => Null
      }
    }),
    Setup::new(
      Words::new(Obj([]), Obj([])),
      "0.0.0",
      ["store"],
      false,
      Some("/data"),
      b"",
      "zh",
      [],
    ),
  )
}

///|
fn session_file_ask(a : Admin, query : Array[(String, String)]) -> Answer {
  let r = Request::new(
    "GET",
    "/sessions/s1/files",
    query,
    None,
    [],
    b"",
    jobj([("workspace", js("w1")), ("sub", js("u1")), ("email", js("u1@x")), ("name", js(""))]),
    "en",
  )
  bytes_ran(async fn() { a.handle(r) })
}

///|
test "GET /sessions/:key/files routes thumb=1 to thumbnail, thumb=2 to preview, and none to original" {
  // thumb=2 -> drive/thumbs.preview
  let p2 : SessionFileParts = { calls: [] }
  let a2 = session_file_ask(p2.admin(), [("name", "shot.png"), ("thumb", "2")])
  assert_eq(a2.status, 200)
  assert_eq(a2.headers.get("content-type"), Some("image/jpeg"))
  assert_eq(a2.text(), "PREVIEW")
  assert_eq(p2.calls.filter(c => c.0 == "drive/thumbs.preview").length(), 1)
  assert_eq(p2.calls.filter(c => c.0 == "drive/thumbs.thumbnail").length(), 0)

  // thumb=1 -> drive/thumbs.thumbnail
  let p1 : SessionFileParts = { calls: [] }
  let a1 = session_file_ask(p1.admin(), [("name", "shot.png"), ("thumb", "1")])
  assert_eq(a1.status, 200)
  assert_eq(a1.headers.get("content-type"), Some("image/jpeg"))
  assert_eq(a1.text(), "THUMB")
  assert_eq(p1.calls.filter(c => c.0 == "drive/thumbs.thumbnail").length(), 1)
  assert_eq(p1.calls.filter(c => c.0 == "drive/thumbs.preview").length(), 0)

  // no thumb -> original file directly
  let p0 : SessionFileParts = { calls: [] }
  let a0 = session_file_ask(p0.admin(), [("name", "shot.png")])
  assert_eq(a0.status, 200)
  assert_eq(a0.headers.get("content-type"), Some("image/png"))
  assert_eq(a0.text(), "ORIG")
  assert_eq(p0.calls.filter(c => c.0 == "drive/thumbs.thumbnail").length(), 0)
  assert_eq(p0.calls.filter(c => c.0 == "drive/thumbs.preview").length(), 0)
}
