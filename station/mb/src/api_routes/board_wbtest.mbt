// Native MoonBit whitebox tests for /board/drafts, /board/files, and /board/stage routes (board.mbt).

///|
priv struct BoardParts {
  calls : Array[(String, Array[JV])]
}

///|
fn BoardParts::admin(self : BoardParts) -> Admin {
  Admin::new(
    Backend::new(async fn(name, args) {
      self.calls.push((name, args))
      match name {
        "hub.boardDrafts.said" => {
          let sub = js_string(args.get(1))
          let drafts = if sub == "u1" {
            jarr([jobj([("id", js("new:board-1")), ("rev", jint(1))])])
          } else {
            jarr([])
          }
          jobj([("drafts", drafts), ("files", jarr([]))])
        }
        "hub.boardDrafts.carry" =>
          match args.get(2) {
            Some(Arr(items)) => {
              for item in items {
                if js_string(item.get("id")) == "boom" {
                  raise Thrown("Error", jobj([("message", js("disk full"))]))
                }
              }
              jobj([
                ("drafts", Arr(items)),
                ("files", jstrs(["f1"])),
                ("changed", jbool(items.length() > 0)),
              ])
            }
            _ => raise Thrown("DraftRefusal", jobj([("message", js("drafts: a list of drafts"))]))
          }
        "hub.boardDrafts.keep" => {
          let draft = js_string(args.get(2))
          let file = js_string(args.get(3))
          let path = js_string(args.get(4))
          if draft != "new:board-1" || path == "" {
            raise Thrown("DraftRefusal", jobj([("message", js("no such draft or file"))]))
          }
          jobj([("files", jstrs([file]))])
        }
        "hub.boardDrafts.bytes" => {
          let draft = js_string(args.get(2))
          let file = js_string(args.get(3))
          if draft == "new:board-1" && file == "f1" {
            // base64("png!") == "cG5nIQ=="
            jobj([("type", js("image/png")), ("bytes", jobj([("$bytes", js("cG5nIQ=="))]))])
          } else {
            Null
          }
        }
        "hub.boardDrafts.stage" => {
          let draft = js_string(args.get(2))
          let file = js_string(args.get(3))
          let file_name = js_string(args.get(4))
          if draft == "new:board-1" && file == "f1" {
            jobj([("name", js(file_name)), ("path", js("/data/uploads/x-a.png")), ("size", jint(4))])
          } else {
            Null
          }
        }
        "events.tell" => Null
        _ => Null
      }
    }),
    Setup::new(Words::new(Obj([]), Obj([])), "0.0.0", [], false, None, b"", "zh", []),
  )
}

///|
fn board_ask_raw(
  a : Admin,
  verb : String,
  path : String,
  query? : Array[(String, String)] = [],
  body? : Bytes = b"",
  sub? : String = "u1",
) -> Answer {
  let r = Request::new(
    verb,
    path,
    query,
    None,
    [],
    body,
    jobj([("workspace", js("w1")), ("sub", js(sub)), ("email", js("u1@x")), ("name", js(""))]),
    "en",
  )
  vault_ran(async fn() { a.handle(r) })
}

///|
test "GET and PUT /board/drafts" {
  let parts : BoardParts = { calls: [] }
  let admin = parts.admin()
  // GET /board/drafts
  let ok_get = board_ask_raw(admin, "GET", "/board/drafts")
  assert_eq(ok_get.status, 200)
  assert_eq(ok_get.text(), "{\"drafts\":[{\"id\":\"new:board-1\",\"rev\":1}],\"files\":[]}")
  let no_sub_get = board_ask_raw(admin, "GET", "/board/drafts", sub="")
  assert_eq(no_sub_get.status, 403)
  // PUT /board/drafts changed -> strips `changed` and emits events.tell
  let carried = board_ask_raw(
    admin,
    "PUT",
    "/board/drafts",
    body=utf8("{\"drafts\":[{\"id\":\"new:board-2\",\"rev\":1}]}"),
  )
  assert_eq(carried.status, 200)
  assert_eq(carried.text(), "{\"drafts\":[{\"id\":\"new:board-2\",\"rev\":1}],\"files\":[\"f1\"]}")
  assert_eq(parts.calls.filter(c => c.0 == "events.tell").length(), 1)
  // PUT /board/drafts unchanged -> no extra events.tell
  let unchanged = board_ask_raw(admin, "PUT", "/board/drafts", body=utf8("{\"drafts\":[]}"))
  assert_eq(unchanged.status, 200)
  assert_eq(unchanged.text(), "{\"drafts\":[],\"files\":[\"f1\"]}")
  assert_eq(parts.calls.filter(c => c.0 == "events.tell").length(), 1)
  // Refusal (400), unexpected error (500), bad JSON / non-object (400), no person (403), too large (413)
  assert_eq(board_ask_raw(admin, "PUT", "/board/drafts", body=utf8("{\"drafts\":1}")).status, 400)
  let boom = board_ask_raw(admin, "PUT", "/board/drafts", body=utf8("{\"drafts\":[{\"id\":\"boom\"}]}"))
  assert_eq(boom.status, 500)
  assert_true(boom.text().contains("disk full"))
  assert_eq(board_ask_raw(admin, "PUT", "/board/drafts", body=utf8("{")).status, 400)
  assert_eq(board_ask_raw(admin, "PUT", "/board/drafts", body=utf8("[1]")).status, 400)
  assert_eq(board_ask_raw(admin, "PUT", "/board/drafts", body=utf8("{\"drafts\":[]}"), sub="").status, 403)
  let big = Bytes::make(4194305, b'x')
  assert_eq(board_ask_raw(admin, "PUT", "/board/drafts", body=big).status, 413)
}

///|
test "POST/GET /board/files and POST /board/stage" {
  let parts : BoardParts = { calls: [] }
  let admin = parts.admin()
  // POST /board/files
  let kept = board_ask_raw(
    admin,
    "POST",
    "/board/files",
    body=utf8("{\"draft\":\"new:board-1\",\"file\":\"f1\",\"path\":\"/data/uploads/a.png\"}"),
  )
  assert_eq(kept.status, 200)
  assert_eq(kept.text(), "{\"files\":[\"f1\"]}")
  assert_eq(
    board_ask_raw(admin, "POST", "/board/files", body=utf8("{\"draft\":\"new:board-9\",\"file\":3}")).status,
    400,
  )
  assert_eq(board_ask_raw(admin, "POST", "/board/files", body=utf8("{")).status, 400)
  assert_eq(board_ask_raw(admin, "POST", "/board/files", body=utf8("{}"), sub="").status, 403)
  // GET /board/files
  let read_ok = board_ask_raw(admin, "GET", "/board/files", query=[("draft", "new:board-1"), ("file", "f1")])
  assert_eq(read_ok.status, 200)
  assert_eq(read_ok.headers.get("content-type"), Some("image/png"))
  assert_eq(read_ok.headers.get("cache-control"), Some("no-store"))
  assert_eq(read_ok.text(), "png!")
  assert_eq(board_ask_raw(admin, "GET", "/board/files", query=[("draft", "new:board-1")]).status, 404)
  assert_eq(board_ask_raw(admin, "GET", "/board/files", sub="").status, 403)
  // POST /board/stage
  let staged = board_ask_raw(
    admin,
    "POST",
    "/board/stage",
    body=utf8("{\"draft\":\"new:board-1\",\"file\":\"f1\",\"name\":\"a.png\"}"),
  )
  assert_eq(staged.status, 200)
  assert_eq(staged.text(), "{\"name\":\"a.png\",\"path\":\"/data/uploads/x-a.png\",\"size\":4}")
  assert_eq(
    board_ask_raw(admin, "POST", "/board/stage", body=utf8("{\"draft\":\"new:board-1\",\"file\":\"f2\"}")).status,
    404,
  )
  assert_eq(board_ask_raw(admin, "POST", "/board/stage", body=utf8("{")).status, 400)
  assert_eq(board_ask_raw(admin, "POST", "/board/stage", body=utf8("{}"), sub="").status, 403)
}
