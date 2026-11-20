// A person's drafts of 待派发 (routes/board.ts): GET and PUT /board/drafts, carried by their devices and told to their
// devices alone as they change (`boardDrafts`); a draft's files kept here (POST /board/files), read (GET
// /board/files) and copied among the uploads for the message that starts it (POST /board/stage). What is kept is the
// station's part's (sessions/board-drafts.ts, `hub.boardDrafts`).

///|
const BOARD_BODY_MOST : Int32 = 4194304

///|
const BOARD_OWN : String = "drafts are a person's own"

///|
/// A request's JSON object (`JSON.parse(… || "{}")`), None where it does not read or is no object.
fn board_body(r : Request) -> JV? {
  match body_or_empty(r) {
    Some(Obj(_) as v) => Some(v)
    _ => None
  }
}

///|
/// `typeof v === "string" ? v : ""`.
fn board_text(v : JV?) -> JV {
  match v {
    Some(Str(_) as s) => s
    _ => js("")
  }
}

///|
/// The person a request is of, and their workspace, as the routes give them to the part.
fn board_who(r : Request) -> (JV, JV) {
  (r.who("workspace").unwrap_or(jundef), r.who("sub").unwrap_or(jundef))
}

///|
/// A part's refusal of what was brought (a DraftRefusal) answered 400 with its words; anything else (the disk) 500.
fn board_refused(e : Error) -> Answer {
  match thrown_as(e, "DraftRefusal") {
    Some(_) => error(400, message_of(e))
    None => error(500, message_of(e))
  }
}

///|
fn Admin::board_routes(self : Admin) -> Array[Route] {
  [
    route("GET", "^\\/board\\/drafts$", async fn(r, _) {
      if !is_truthy(r.who("sub")) {
        return error(403, BOARD_OWN)
      }
      let (ws, sub) = board_who(r)
      ok(self.backend.ask("hub.boardDrafts.said", [ws, sub]))
    }),
    route("PUT", "^\\/board\\/drafts$", async fn(r, _) {
      if !is_truthy(r.who("sub")) {
        return error(403, BOARD_OWN)
      }
      if r.body.length() > BOARD_BODY_MOST {
        return error(413, "request too large")
      }
      guard board_body(r) is Some(b) else { return error(400, "invalid JSON") }
      let (ws, sub) = board_who(r)
      let carried = self.backend.ask("hub.boardDrafts.carry", [
        ws,
        sub,
        b.get("drafts").unwrap_or(jundef),
      ]) catch {
        e => return board_refused(e)
      }
      if is_truthy(carried.get("changed")) && self.setup.has("events") {
        let wsv = if is_undef(ws) { jundef } else { ws }
        self.backend.tell("events.tell", [
          js("boardDrafts"),
          jobj([("workspace", wsv)]).filter_undef(),
          js("boardDrafts\u{0}\{js_string(Some(ws))}\u{0}\{js_string(Some(sub))}"),
          jobj([("workspace", wsv), ("subs", jarr([sub]))]).filter_undef(),
        ])
      }
      let said = match carried {
        Obj(fields) => jobj(fields.filter(f => f.0 != "changed"))
        v => v
      }
      ok(said)
    }),
    route("POST", "^\\/board\\/files$", async fn(r, _) {
      if !is_truthy(r.who("sub")) {
        return error(403, BOARD_OWN)
      }
      guard board_body(r) is Some(b) else { return error(400, "invalid JSON") }
      let (ws, sub) = board_who(r)
      let kept = self.backend.ask("hub.boardDrafts.keep", [
        ws,
        sub,
        board_text(b.get("draft")),
        board_text(b.get("file")),
        board_text(b.get("path")),
      ]) catch {
        e => return board_refused(e)
      }
      ok(kept)
    }),
    route("GET", "^\\/board\\/files$", async fn(r, _) {
      if !is_truthy(r.who("sub")) {
        return error(403, BOARD_OWN)
      }
      let (ws, sub) = board_who(r)
      let got = self.backend.ask("hub.boardDrafts.bytes", [
        ws,
        sub,
        js(r.param("draft").unwrap_or("")),
        js(r.param("file").unwrap_or("")),
      ])
      if nullish(got) {
        return error(404, "no such file")
      }
      {
        status: 200,
        headers: {
          "content-type": js_string(got.get("type")),
          "cache-control": "no-store",
        },
        body: Whole(bytes_of(got.get("bytes").unwrap_or(Null)).unwrap_or(b"")),
      }
    }),
    route("POST", "^\\/board\\/stage$", async fn(r, _) {
      if !is_truthy(r.who("sub")) {
        return error(403, BOARD_OWN)
      }
      guard board_body(r) is Some(b) else { return error(400, "invalid JSON") }
      let (ws, sub) = board_who(r)
      let staged = self.backend.ask("hub.boardDrafts.stage", [
        ws,
        sub,
        board_text(b.get("draft")),
        board_text(b.get("file")),
        board_text(b.get("name")),
      ])
      if nullish(staged) {
        return error(404, "no such file")
      }
      ok(staged)
    }),
  ]
}
