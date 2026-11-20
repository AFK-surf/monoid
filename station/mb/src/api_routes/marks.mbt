// What a viewer marks on chats and sessions, written straight to the store (routes/marks.ts): read positions, names,
// pins, keeping, dismissing, closing a card, widget states.

///|
const WIDGET_STATE_MAX : Int32 = 16384

///|
const WIDGET_MODEL_MAX : Int32 = 4000

///|
/// A name given by hand (`title`): trimmed, at most 80 characters; none or empty is null.
fn title_of(i : JV) -> JV {
  let t = match i.get("title") {
    Some(Str(t)) => trim_js(t)
    _ => ""
  }
  if t == "" {
    Null
  } else {
    js(chars(t, 80))
  }
}

///|
/// What of a widget's state is for the agent: its modelContent, cut.
fn widget_model(state : JV) -> JV {
  guard state is (Obj(_) | Arr(_)) && jhas(state, "modelContent") else {
    return Null
  }
  match state.get("modelContent") {
    Some(Null) | None => Null
    Some(Str(s)) => js(chars(s, WIDGET_MODEL_MAX))
    Some(m) => js(chars(stringify(m), WIDGET_MODEL_MAX))
  }
}

///|
/// A whole number from JSON, at least `min`.
fn whole(v : JV?, min : Double) -> Double? {
  match v {
    Some(Num(n)) if is_integer(n) && n >= min => Some(n)
    _ => None
  }
}

///|
/// Answered by the store, its refusals as `{error}`; 503 while there is no store.
async fn Admin::store_write(self : Admin, f : async () -> Answer) -> Answer {
  if !self.setup.has("store") {
    return error(503, "station starting")
  }
  f() catch {
    e =>
      match refused_of(e) {
        Some((status, message)) => error(status, message)
        None => error(500, message_of(e))
      }
  }
}

///|
fn Admin::marks_routes(self : Admin) -> Array[Route] {
  let session = async fn(key : String) {
    if self.store("getSession", [js(key)]) is Null {
      raise Refused(404, "unknown session \{key}")
    }
  }
  [
    route("POST", "^\\/*sessions\\/+([^/]+)\\/+title(?:\\/.*)?$", async fn(
      r,
      m,
    ) {
      self.store_write(async fn() {
        let i = input(r)
        let key = segment(m[0].unwrap())
        session(key)
        let name = title_of(i)
        let anchor = match self.store("conversationOf", [js(key)]) {
          Str(c) if c != "" => c
          _ => key
        }
        ignore(self.store("setTitle", [js(anchor), name]))
        // Once the session has a chat of its own, the list names it by that chat: the chat takes the name too.
        let home = self.store("homeChat", [js(anchor)])
        if !(home is Null) {
          ignore(
            self.store("setThreadTitle", [
              home.get("id").unwrap_or(jundef),
              name,
            ]),
          )
        }
        ok(jobj([("ok", jbool(true))]))
      })
    }),
    route("PUT", "^\\/*sessions\\/+([^/]+)\\/+widget-state(?:\\/.*)?$", async fn(
      r,
      m,
    ) {
      self.store_write(async fn() {
        let i = input(r)
        let key = segment(m[0].unwrap())
        session(key)
        let path = text_of(i.get("path"))
        if path == "" {
          raise Refused(400, "path is required")
        }
        let state = i.get("state").unwrap_or(Null)
        let text = stringify(state)
        if utf8(text).length() > WIDGET_STATE_MAX {
          raise Refused(400, "widget state is over \{WIDGET_STATE_MAX} bytes")
        }
        ignore(
          self.store("putWidgetState", [
            js(key),
            js(path),
            js(text),
            widget_model(state),
          ]),
        )
        ok(jobj([("ok", jbool(true))]))
      })
    }),
  ] +
  ["PUT", "DELETE"].map(verb => {
    route(verb, "^\\/*sessions\\/+([^/]+)\\/+pin(?:\\/.*)?$", async fn(r, m) {
      self.store_write(async fn() {
        let key = segment(m[0].unwrap())
        session(key)
        let anchor = match self.store("conversationOf", [js(key)]) {
          Str(c) if c != "" => c
          _ => key
        }
        ignore(
          self.store("setPin", [js(r.email()), js(anchor), jbool(verb == "PUT")]),
        )
        ok(jobj([("session", js(anchor)), ("pinned", jbool(verb == "PUT"))]))
      })
    })
  }) +
  [
    route("DELETE", "^\\/*threads\\/+([^/]+)\\/+keep(?:\\/.*)?$", async fn(
      r,
      m,
    ) {
      self.store_write(async fn() {
        let t = self.thread_there(segment(m[0].unwrap()))
        ignore(
          self.store("unkeepChat", [
            js(r.email()),
            t.get("id").unwrap_or(jundef),
          ]),
        )
        ok(jobj([("kept", jbool(false))]))
      })
    }),
    route(
      "PUT",
      "^\\/*threads\\/+([^/]+)\\/+(read|hidden|muted|title|keep|dismissed|closed-card)(?:\\/.*)?$",
      async fn(r, m) {
        self.store_write(async fn() {
          self.mark(r, segment(m[0].unwrap()), m[1].unwrap())
        })
      },
    ),
  ]
}

///|
async fn Admin::mark(
  self : Admin,
  r : Request,
  raw : String,
  action : String,
) -> Answer {
  let t = self.thread_there(raw)
  let tid = t.get("id").unwrap_or(jundef)
  let viewer = js(r.email())
  match action {
    "hidden" | "muted" => {
      let v = input(r).get(action)
      guard v is Some(Bool(b)) else {
        raise Refused(400, "\{action} must be a boolean")
      }
      ignore(
        self.store(
          if action == "hidden" {
            "setChatHidden"
          } else {
            "setChatMuted"
          },
          [viewer, tid, jbool(b)],
        ),
      )
      ok(jobj([(action, jbool(b))]))
    }
    "read" => {
      guard whole(input(r).get("n"), 0.0) is Some(n) else {
        raise Refused(400, self.tr(r.lang, "station.admin.badN"))
      }
      ok(
        jobj([
          ("viewer", viewer),
          ("thread", tid),
          ("n", self.store("setRead", [viewer, tid, jnum(n)])),
        ]),
      )
    }
    // A chat named by hand; no name (or an empty one) names it by its first message again.
    "title" => {
      if jstr(t.get("surface")) != Some(STILLFAIL_SURFACE) {
        raise Refused(400, self.tr(r.lang, "station.admin.renameOnlyStillfail"))
      }
      ignore(self.store("setThreadTitle", [tid, title_of(input(r))]))
      self.thread_view(r, tid)
    }
    "keep" => {
      ignore(self.store("keepChat", [viewer, tid]))
      ok(jobj([("kept", jbool(true))]))
    }
    // A card (or a need) the viewer will not take up: off their list, on every device of theirs.
    "dismissed" => {
      guard whole(input(r).get("n"), 1.0) is Some(n) else {
        raise Refused(400, self.tr(r.lang, "station.admin.badN"))
      }
      let asked = jitems(
        Some(self.store("entriesBetween", [tid, jnum(n), jnum(n)])),
      ).get(0)
      let waiting = match asked {
        None => false
        Some(e) =>
          !is_undef(self.backend.ask("rows.cardOfEntry", [e])) ||
          e.get("authorKind") == Some(js("agent"))
      }
      if !waiting {
        raise Refused(404, self.tr(r.lang, "station.admin.nothingWaiting"))
      }
      ignore(self.store("dismiss", [viewer, tid, jnum(n)]))
      ok(jobj([("dismissed", jobj([("thread", tid), ("n", jnum(n))]))]))
    }
    // End this question without sending a message or starting an agent turn.
    _ => {
      let i = input(r)
      let n = match i.get("n") {
        Some(Num(n)) if is_safe_integer(n) && n > 0.0 => n
        _ => raise Refused(400, self.tr(r.lang, "station.admin.badN"))
      }
      let option = match i.get("option") {
        Some(Str(o)) => trim_js(o)
        _ => ""
      }
      if option == "" {
        raise Refused(400, self.tr(r.lang, "station.admin.badOption"))
      }
      // (a part's own card: who may choose on it is the part's to say, as this member)
      let asked = jitems(
        Some(self.store("entriesBetween", [tid, jnum(n), jnum(n)])),
      ).get(0)
      let card = match asked {
        None => jundef
        Some(e) => self.backend.ask("rows.cardOfEntry", [e])
      }
      let own = if nullish(card) || !self.setup.has("parts") {
        None
      } else {
        ref_of(self.backend.ask("parts.cardChoiceOf", [card]))
      }
      let at = jobj([
        ("thread", tid),
        ("n", jnum(n)),
        (
          "ts",
          match asked {
            Some(e) =>
              match e.get("ts") {
                Some(ts) if !nullish(ts) => ts
                _ => Null
              }
            None => Null
          },
        ),
      ])
      match own {
        Some(choice) => {
          let why = self.backend.ask(choice + ".may", [r.viewer, card, at])
          if !nullish(why) {
            raise Refused(403, js_string(Some(why)))
          }
        }
        None => ()
      }
      if !(self.store("closeCard", [
          viewer,
          tid,
          jnum(n),
          js(option),
          js(r.lang),
        ])
        is Bool(true)) {
        raise Refused(409, self.tr(r.lang, "station.admin.waitChanged"))
      }
      match own {
        Some(choice) =>
          self.backend.tell(choice + ".chosen", [r.viewer, card, js(option), at])
        None => ()
      }
      ignore(self.store("setRead", [viewer, tid, jnum(n)]))
      ok(jobj([("closedCard", jobj([("thread", tid), ("n", jnum(n))]))]))
    }
  }
}
