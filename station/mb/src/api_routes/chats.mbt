// The chat list and a chat's messages (routes/chats.ts: GET /chats, GET /threads/:id/entries), and its letters; and
// a list read again as what changed of it (routes/changed.ts: POST /changed/<list>).

///|
/// `page`: the archive a page at a time, from its first (`page=`) or on from where one ended.
fn chats_of(r : Request) -> JV {
  jobj(
    [
      ("viewer", r.viewer),
      ("archived", jbool(r.param("archived") == Some("1"))),
    ] +
    (match r.param("page") {
      Some(p) => [("page", js(p))]
      None => []
    }),
  )
}

///|
fn scoped(r : Request) -> JV {
  jobj([
    ("viewer", r.viewer),
    ("sessions", jstrs(r.params("session"))),
    (
      "threads",
      jarr(
        r
        .params("thread")
        .filter(id => re("^\\d+$").matches(id))
        .map(id => jnum(js_number(id))),
      ),
    ),
  ])
}

///|
/// A list read again as what changed of it: the client sends what it holds as each row's digest by its id.
pub async fn Admin::changed(
  self : Admin,
  r : Request,
  op : String,
  args : JV,
  id : String,
) -> Answer {
  if r.body.length() > 1000000 {
    return error(413, "request too large")
  }
  let held = match body_json(r) {
    Some(v) => jget(Some(v), "held")
    None => None
  }
  guard held is Some(Obj(_) as held) else {
    return error(400, "held: each held row's digest by its id")
  }
  let supported = client_runtimes(r.headers)
  self.read(
    r,
    "changed",
    jobj([
      ("op", js(op)),
      ("args", args),
      ("id", js(id)),
      ("held", held),
      ("runtimes", jstrs(supported)),
    ]),
  )
}

///|
fn Admin::chats_routes(self : Admin) -> Array[Route] {
  [
    route("GET", "^\\/chats$", async fn(r, _) {
      let some = r.query.iter().any(q => q.0 == "session" || q.0 == "thread")
      if r.param("marks") == Some("1") {
        let scope = if some {
          let s = scoped(r)
          jobj([
            ("sessions", s.get("sessions").unwrap()),
            ("threads", s.get("threads").unwrap()),
          ])
        } else {
          Null
        }
        return self.read(
          r,
          "chatMarks",
          jobj([
            ("viewer", r.viewer),
            ("scope", scope),
            ("own", jbool(r.param("own") == Some("1"))),
          ]),
        )
      }
      if r.param("shared") == Some("1") {
        return self.read(
          r,
          "sharedChats",
          if some {
            scoped(r)
          } else {
            jobj([("viewer", r.viewer), ("sessions", Null), ("threads", Null)])
          },
        )
      }
      if some {
        self.read(r, "chatRows", scoped(r))
      } else {
        self.read(r, "chats", chats_of(r))
      }
    }),
    route("POST", "^\\/changed\\/chats$", async fn(r, _) {
      self.changed(r, "chats", chats_of(r), "id")
    }),
    route("POST", "^\\/changed\\/shared$", async fn(r, _) {
      self.changed(
        r,
        "sharedChats",
        jobj([("viewer", r.viewer), ("sessions", Null), ("threads", Null)]),
        "id",
      )
    }),
    route("GET", "^\\/threads\\/([^/]+)\\/entries$", async fn(r, m) {
      let id = m[0].unwrap()
      if !signed_int.matches(id) {
        return error(404, "unknown thread \{id}")
      }
      self.read(
        r,
        "entries",
        jobj([
          ("viewer", r.viewer),
          ("thread", jnum(js_number(id))),
          ("params", query_json(r)),
        ]),
      )
    }),
    route("GET", "^\\/threads\\/([^/]+)\\/letters$", async fn(r, m) {
      let id = m[0].unwrap()
      if !signed_int.matches(id) {
        return error(404, "unknown thread \{id}")
      }
      self.read(
        r,
        "letters",
        jobj([
          ("viewer", r.viewer),
          ("thread", jnum(js_number(id))),
          ("params", query_json(r)),
        ]),
      )
    }),
  ]
}

///|
/// `r.query` as JSON (its pairs).
pub fn query_json(r : Request) -> JV {
  jarr(r.query.map(q => jarr([js(q.0), js(q.1)])))
}
