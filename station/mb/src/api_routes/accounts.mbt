// The accounts' part of the admin API (routes/accounts.ts): profiles made, edited, checked, signed in and deleted;
// allowances read and reset; sign-ins for new profiles; the automatic decisions' settings; sharing a profile or a
// skill with the workspace's other stations. The station's logins to command-line tools (routes/logins.ts) and a
// sign-in asked of a person on its card (routes/signins.ts).

///|
fn station_ids(v : JV?) -> JV raise Refused {
  match v {
    None | Some(Null) => Null
    Some(Str("all")) => Null
    Some(Arr(items)) if items.all(x => {
        x is Str(s) && re("^[0-9a-f]{64}$").matches(s)
      }) => Arr(items)
    _ => raise Refused(400, "allow must be null or station ids")
  }
}

///|
fn idempotency_key(r : Request) -> String? {
  match header_of(r.headers, "idempotency-key") {
    Some(k) if k != "" && k.length() <= 200 => Some(k)
    _ => None
  }
}

///|
async fn Admin::accounts(self : Admin, call : String, args : Array[JV]) -> JV {
  self.backend.ask("accounts." + call, args)
}

///|
/// Answered by the accounts, their refusals as `{error}` with their status; 503 while there are none.
async fn Admin::accounts_answer(self : Admin, f : async () -> Answer) -> Answer {
  if !self.setup.has("agents.accounts") {
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
async fn Admin::overview_of(self : Admin, r : Request) -> JV {
  self.backend.ask("agents.overview", [r.viewer, js(r.lang)])
}

///|
fn login_code(i : JV) -> String {
  match i.get("code") {
    None | Some(Null) => ""
    Some(Str(s)) => s
    Some(v) => stringify(v)
  }
}

///|
async fn Admin::known_profile(self : Admin, id : String) -> String {
  let found = jitems(Some(self.accounts("profiles", [])))
    .iter()
    .any(p => p.get("id") == Some(js(id)))
  if !found {
    raise Refused(404, "unknown profile \{id}")
  }
  id
}

///|
fn Admin::accounts_routes(self : Admin) -> Array[Route] {
  let answer = (f : async (Request, Array[String?]) -> Answer) => {
    async fn(r : Request, m : Array[String?]) -> Answer {
      self.accounts_answer(async fn() { f(r, m) })
    }
  }
  let manager = (r : Request) => {
    if !manages_station(r.viewer) {
      raise Refused(403, self.tr(r.lang, "station.share.managersOnly"))
    }
  }
  let viewer_lang = (r : Request) => [r.viewer, js(r.lang)]
  [
    route(
      "POST",
      "^\\/profiles\\/machine$",
      answer(async fn(r, _) {
        let id = self.accounts("newMachineProfile", [input(r)] + viewer_lang(r))
        ok(jobj([("id", id), ("overview", self.overview_of(r))]))
      }),
    ),
    route(
      "POST",
      "^\\/profiles$",
      answer(async fn(r, _) {
        let id = self.accounts("newKeyedProfile", [input(r)] + viewer_lang(r))
        ok(jobj([("id", id), ("overview", self.overview_of(r))]))
      }),
    ),
    route(
      "POST",
      "^\\/logins$",
      answer(async fn(r, _) {
        ok(self.accounts("newLogin", [input(r)] + viewer_lang(r)))
      }),
    ),
    route(
      "PUT",
      "^\\/*automatic-decisions\\/*$",
      answer(async fn(r, _) {
        ignore(
          self.accounts("putAutomaticDecisions", [input(r)] + viewer_lang(r)),
        )
        ok(self.overview_of(r))
      }),
    ),
    route(
      "PUT",
      "^\\/*archiving\\/*$",
      answer(async fn(r, _) {
        ignore(self.accounts("putArchiving", [input(r)] + viewer_lang(r)))
        ok(self.overview_of(r))
      }),
    ),
    route(
      "PUT",
      "^\\/*auto-chats\\/*$",
      answer(async fn(r, _) {
        ignore(self.accounts("putAutoChats", [input(r)] + viewer_lang(r)))
        ok(self.overview_of(r))
      }),
    ),
    route(
      "PUT",
      "^\\/*automatic-decisions\\/+policy\\/*$",
      answer(async fn(r, _) {
        if r.who("home") is Some(Bool(false)) {
          self.joined_policy(r)
        } else {
          ignore(self.accounts("putArchivePolicy", [input(r)] + viewer_lang(r)))
        }
        ok(self.overview_of(r))
      }),
    ),
    route(
      "POST",
      "^\\/*automatic-decisions\\/+review\\/*$",
      answer(async fn(r, _) {
        let queued = self.accounts("reviewUndecided", viewer_lang(r))
        ok(jobj([("queued", queued), ("overview", self.overview_of(r))]))
      }),
    ),
    route(
      "POST",
      "^\\/*automatic-decisions\\/+refresh\\/*$",
      answer(async fn(r, _) {
        ignore(self.accounts("refreshDecisionModels", viewer_lang(r)))
        ok(self.overview_of(r))
      }),
    ),
    route(
      "PUT",
      "^\\/*profiles\\/+([^/]+)\\/*$",
      answer(async fn(r, m) {
        let profile = segment(m[0].unwrap())
        ignore(
          self.accounts("putProfile", [js(profile), input(r)] + viewer_lang(r)),
        )
        let answered = ok(self.overview_of(r))
        // Its new state is reported once known.
        self.later(async fn() { ignore(self.accounts("check", [js(profile)])) })
        answered
      }),
    ),
    route(
      "DELETE",
      "^\\/*profiles\\/+([^/]+)\\/*$",
      answer(async fn(r, m) {
        ignore(
          self.accounts(
            "deleteProfile",
            [js(segment(m[0].unwrap()))] + viewer_lang(r),
          ),
        )
        ok(self.overview_of(r))
      }),
    ),
    route(
      "GET",
      "^\\/*profiles\\/+pace\\/*$",
      answer(async fn(r, _) { ok(self.accounts("paceView", [r.viewer])) }),
    ),
    route(
      "POST",
      "^\\/*profiles\\/+([^/]+)\\/+check(?:\\/.*)?$",
      answer(async fn(r, m) {
        ok(self.accounts("check", [js(segment(m[0].unwrap())), js(r.lang)]))
      }),
    ),
    route(
      "GET",
      "^\\/*profiles\\/+([^/]+)\\/+fusion(?:\\/.*)?$",
      answer(async fn(_r, m) {
        ok(
          jobj([
            (
              "fusion",
              self.accounts("fusionView", [js(segment(m[0].unwrap()))]),
            ),
          ]),
        )
      }),
    ),
    route(
      "POST",
      "^\\/*profiles\\/+([^/]+)\\/+reset-quota(?:\\/.*)?$",
      answer(async fn(r, m) {
        guard idempotency_key(r) is Some(key) else {
          raise Refused(400, "reset requires an idempotency key")
        }
        // Which kind of the allowance's resets (`{reset}`), when it lists kinds.
        let t = r.text()
        let kind = match try_parse(if t == "" { "null" } else { t }) {
          Some(Obj(_) as o) =>
            match o.get("reset") {
              Some(Str(s)) if re("^[a-z]{1,20}$").matches(s) => js(s)
              _ => Null
            }
          _ => Null
        }
        ok(
          self.accounts("resetQuota", [
            js(segment(m[0].unwrap())),
            js(key),
            js(r.lang),
            kind,
          ]),
        )
      }),
    ),
    route(
      "POST",
      "^\\/*profiles\\/+([^/]+)\\/+quota(?:\\/.*)?$",
      answer(async fn(_r, m) {
        ok(self.accounts("askedQuota", [js(segment(m[0].unwrap()))]))
      }),
    ),
    route(
      "GET",
      "^\\/*profiles\\/+([^/]+)\\/+login(?:\\/.*)?$",
      answer(async fn(_r, m) {
        let profile = self.known_profile(segment(m[0].unwrap()))
        ok(jobj([("job", self.accounts("logins.get", [js(profile)]))]))
      }),
    ),
    route(
      "DELETE",
      "^\\/*profiles\\/+([^/]+)\\/+login(?:\\/.*)?$",
      answer(async fn(_r, m) {
        let profile = self.known_profile(segment(m[0].unwrap()))
        ignore(self.accounts("logins.cancel", [js(profile)]))
        ok(jobj([("job", self.accounts("logins.get", [js(profile)]))]))
      }),
    ),
    route(
      "POST",
      "^\\/*profiles\\/+([^/]+)\\/+login(?:\\/.*)?$",
      answer(async fn(r, m) {
        ok(
          jobj([
            (
              "job",
              self.accounts(
                "startLogin",
                [js(segment(m[0].unwrap()))] + viewer_lang(r),
              ),
            ),
          ]),
        )
      }),
    ),
    route(
      "POST",
      "^\\/*profiles\\/+([^/]+)\\/+login-code(?:\\/.*)?$",
      answer(async fn(r, m) {
        let code = login_code(input(r))
        let job = self.accounts("logins.submitCode", [
          js(segment(m[0].unwrap())),
          js(code),
          js(r.lang),
        ]) catch {
          e => raise Refused(400, message_of(e))
        }
        ok(jobj([("job", job)]))
      }),
    ),
    // Shared with the workspace's other stations, or no longer; moved to another station.
    route(
      "POST",
      "^\\/*profiles\\/+([^/]+)\\/+share\\/*$",
      answer(async fn(r, m) {
        if !self.setup.has("agents.sharing") {
          return error(503, "station starting")
        }
        manager(r)
        let body = input(r)
        let among = match body.get("among") {
          None | Some(Null) => JV::Null
          v => station_ids(v)
        }
        self.backend.tell("sharing.shareProfile", [
          js(segment(m[0].unwrap())),
          jbool(!(body.get("on") is Some(Bool(false)))),
          station_ids(body.get("allow")),
          among,
          js(r.email()),
        ]) catch {
          e =>
            match refused_of(e) {
              Some(_) => raise e
              None => raise Refused(409, message_of(e))
            }
        }
        ok(self.overview_of(r))
      }),
    ),
    route(
      "POST",
      "^\\/*profiles\\/+([^/]+)\\/+move\\/*$",
      answer(async fn(r, m) {
        if !self.setup.has("agents.sharing") {
          return error(503, "station starting")
        }
        manager(r)
        let to = match input(r).get("station") {
          Some(Str(s)) if re("^[0-9a-f]{64}$").matches(s) => s
          _ => raise Refused(400, "station must be a station id")
        }
        self.backend.tell("sharing.moveProfile", [
          js(segment(m[0].unwrap())),
          js(to),
          js(r.lang),
        ]) catch {
          e => raise Refused(409, message_of(e))
        }
        ok(self.overview_of(r))
      }),
    ),
    route(
      "POST",
      "^\\/*skills\\/+([^/]+)\\/+share\\/*$",
      answer(async fn(r, m) {
        if !self.setup.has("agents.sharing") {
          return error(503, "station starting")
        }
        manager(r)
        let body = input(r)
        let skill = segment(m[0].unwrap())
        if !portable_name(skill) {
          raise Refused(400, self.tr(r.lang, "station.share.skillName"))
        }
        try {
          let on = jbool(!(body.get("on") is Some(Bool(false))))
          self.backend.tell("sharing.shareSkill", [
            js(skill),
            on,
            station_ids(body.get("allow")),
          ])
        } catch {
          e => raise Refused(409, message_of(e))
        }
        ok(Obj([]))
      }),
    ),
    // A sign-in for a new profile: dropped, or given its code. Any other id is no route.
    route(
      "DELETE",
      "^\\/*logins\\/+([^/]+)\\/*$",
      answer(async fn(r, m) {
        let login = segment(m[0].unwrap())
        if !(self.accounts("hasPending", [js(login)]) is Bool(true)) {
          return no_route(r)
        }
        ignore(self.accounts("dropLogin", [js(login)]))
        ok(jobj([("ok", jbool(true))]))
      }),
    ),
    route(
      "POST",
      "^\\/*logins\\/+([^/]+)\\/+code(?:\\/.*)?$",
      answer(async fn(r, m) {
        let login = segment(m[0].unwrap())
        if !(self.accounts("hasPending", [js(login)]) is Bool(true)) {
          return no_route(r)
        }
        let code = login_code(input(r))
        let job = self.accounts("logins.submitCode", [
          js(login),
          js(code),
          js(r.lang),
        ]) catch {
          e => raise Refused(400, message_of(e))
        }
        ok(jobj([("job", job)]))
      }),
    ),
  ]
}

///|
/// The archive policy of the joined workspace the viewer is in, changed by one of its owners or admins.
async fn Admin::joined_policy(self : Admin, r : Request) -> Unit {
  if !manages_station(r.viewer) {
    raise Refused(403, self.tr(r.lang, "station.decisions.managersOnlyPolicy"))
  }
  if !self.setup.has("store") {
    raise Refused(503, "station starting")
  }
  let name = r.who_str("name")
  let changed = self.backend.ask("sessions/archive-policy.savePolicy", [
    jref("store"),
    input(r),
    jobj([
      ("kind", js("person")),
      ("email", js(r.email())),
      ("name", if name == "" { Null } else { js(name) }),
    ]),
    r.who("workspace").unwrap_or(jundef),
  ]) catch {
    e =>
      match refused_of(e) {
        Some(_) => raise e
        None => raise Refused(400, message_of(e))
      }
  }
  if !(changed is Null) {
    self.later(async fn() {
      ignore(self.backend.ask("sessions/review.reviewUndecided", [jref("hub")]))
    })
  }
}

///|
/// A login as a read-only member may see it: without its pages, codes and callbacks (logins/index.ts `limited`).
fn limited(login : JV) -> JV {
  match login {
    Obj(f) =>
      Obj(
        f.filter(p => {
          !["url", "callback", "code", "codeUrl", "error", "browser", "screen"].contains(
            p.0,
          )
        }),
      )
    _ => login
  }
}

///|
fn uri_part(s : String) -> String raise Thrown {
  match decode_uri_component(s) {
    Some(d) => d
    None => raise Thrown("URIError", jobj([("message", js("URI malformed"))]))
  }
}

///|
fn who_of(r : Request) -> JV {
  jobj([
    ("email", r.who("email").unwrap_or(jundef)),
    ("name", r.who("name").unwrap_or(jundef)),
  ]).filter_undef()
}

///|
fn Admin::logins_routes(self : Admin) -> Array[Route] {
  let answer = async fn(f : async () -> Answer) -> Answer {
    if !self.setup.has("logins") {
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
  let seen = (r : Request, login : JV) => {
    if read_only(r.viewer) {
      limited(login)
    } else {
      login
    }
  }
  [
    route("GET", "^\\/machine-logins\\/*$", async fn(r, _) {
      answer(async fn() {
        ok(
          jobj([
            (
              "logins",
              jarr(
                jitems(Some(self.backend.ask("logins.logins", []))).map(x => {
                  seen(r, x)
                }),
              ),
            ),
          ]),
        )
      })
    }),
    route("GET", "^\\/machine-logins\\/+([^/]+)\\/*$", async fn(r, m) {
      answer(async fn() {
        let found = self.backend.ask("logins.get", [js(uri_part(m[0].unwrap()))])
        if found is Null {
          error(404, "no such login")
        } else {
          ok(seen(r, found))
        }
      })
    }),
    route("DELETE", "^\\/machine-logins\\/+([^/]+)\\/*$", async fn(r, m) {
      answer(async fn() {
        ok(
          self.backend.ask("logins.cancel", [
            js(uri_part(m[0].unwrap())),
            who_of(r),
          ]),
        )
      })
    }),
    // What the login's page gave (a code), entered by the person: `{text}` → the login.
    route("POST", "^\\/machine-logins\\/+([^/]+)\\/+answer\\/*$", async fn(
      r,
      m,
    ) {
      answer(async fn() {
        if read_only(r.viewer) {
          raise Refused(403, "read-only")
        }
        let id = uri_part(m[0].unwrap())
        ok(
          seen(
            r,
            self.backend.ask("logins.answer", [
              js(id),
              input(r).get("text").unwrap_or(jundef),
              who_of(r),
            ]),
          ),
        )
      })
    }),
    // Started again from its card by the person, once it failed (ran out of time, say) → the new login.
    route("POST", "^\\/machine-logins\\/+([^/]+)\\/+again\\/*$", async fn(
      r,
      m,
    ) {
      answer(async fn() {
        if read_only(r.viewer) {
          raise Refused(403, "read-only")
        }
        let id = uri_part(m[0].unwrap())
        ok(seen(r, self.backend.ask("logins.again", [js(id), who_of(r)])))
      })
    }),
    // The browser's callback, from the client it came back to.
    route("POST", "^\\/machine-logins\\/+([^/]+)\\/+callback\\/*$", async fn(
      r,
      m,
    ) {
      answer(async fn() {
        let id = uri_part(m[0].unwrap())
        let body = input(r)
        let headers = match body.get("headers") {
          Some(Obj(f)) => JV::Obj(f.filter(p => p.1 is Str(_)))
          _ => JV::Obj([])
        }
        guard body.get("method") is Some(Str(method_)) &&
          body.get("path") is Some(Str(path)) else {
          raise Refused(400, "method and path")
        }
        let asked = jobj(
          [("method", js(method_)), ("path", js(path)), ("headers", headers)] +
          (match body.get("body") {
            Some(Str(b)) => [("body", js(b))]
            _ => []
          }),
        )
        ok(self.backend.ask("logins.callback", [js(id), asked, who_of(r)]))
      })
    }),
  ] +
  self.login_page_routes()
}

///|
/// A login's page opened in the station's own browser for the person asking: `{screen}`.
fn Admin::login_page_routes(self : Admin) -> Array[Route] {
  let answer = async fn(r : Request, f : async () -> JV) -> Answer {
    if read_only(r.viewer) {
      return error(403, "read-only")
    }
    ok(jobj([("screen", f())])) catch {
      e =>
        match refused_of(e) {
          Some((status, message)) => error(status, message)
          None => error(409, message_of(e))
        }
    }
  }
  [
    route("POST", "^\\/machine-logins\\/+([^/]+)\\/+browser\\/*$", async fn(
      r,
      m,
    ) {
      answer(r, async fn() {
        if !self.setup.has("logins") {
          raise Refused(503, "station starting")
        }
        self.backend.ask("logins.openPage", [
          js(uri_part(m[0].unwrap())),
          who_of(r),
        ])
      })
    }),
    route("POST", "^\\/*profiles\\/+([^/]+)\\/+login-browser\\/*$", async fn(
      r,
      m,
    ) {
      answer(r, async fn() {
        if !self.setup.has("agents.accounts") {
          raise Refused(503, "station starting")
        }
        let profile = uri_part(m[0].unwrap())
        let found = jitems(Some(self.accounts("profiles", [])))
          .iter()
          .any(p => p.get("id") == Some(js(profile)))
        if !found {
          raise Refused(404, "unknown profile \{profile}")
        }
        self.accounts("logins.openPage", [js(profile), js(r.lang)])
      })
    }),
    route("POST", "^\\/*logins\\/+([^/]+)\\/+browser\\/*$", async fn(r, m) {
      answer(r, async fn() {
        if !self.setup.has("agents.accounts") {
          raise Refused(503, "station starting")
        }
        let login = uri_part(m[0].unwrap())
        if !(self.accounts("hasPending", [js(login)]) is Bool(true)) {
          raise Refused(404, "no route \{r.verb} \{r.path}")
        }
        self.accounts("logins.openPage", [js(login), js(r.lang)])
      })
    }),
  ]
}

///|
fn signin_body(r : Request) -> JV {
  match body_or_empty(r) {
    Some(Obj(_) as o) => o
    Some(Arr(_) as a) => a
    _ => Obj([])
  }
}

///|
fn signin_answered(why : JV) -> Answer {
  if why is Null {
    ok(jobj([("ok", jbool(true))]))
  } else {
    json(409, stringify(jobj([("error", why), ("code", js("signin_refused"))])))
  }
}

///|
fn Admin::signins_routes(self : Admin) -> Array[Route] {
  let id = (r : Request) => {
    uri_part(
      r.path.split("/").map(p => p.to_string()).collect().get(3).unwrap_or(""),
    )
  }
  let who = (r : Request) => {
    [r.who("email").unwrap_or(jundef), r.who("workspace").unwrap_or(jundef)]
  }
  [
    route("POST", "^\\/browser\\/sign-ins\\/[^/]+\\/fill$", async fn(r, _) {
      let o = signin_body(r)
      let str = (k : String) => {
        match o.get(k) {
          Some(Str(s)) => [(k, js(s))]
          _ => []
        }
      }
      let given = jobj(
        str("username") +
        str("password") +
        str("code") +
        (match o.get("keep") {
          Some(Bool(b)) => [("keep", jbool(b))]
          _ => []
        }),
      )
      signin_answered(
        self.backend.ask("signIns.fill", who(r) + [js(id(r)), given]),
      )
    }),
    route("POST", "^\\/browser\\/sign-ins\\/[^/]+\\/self$", async fn(r, _) {
      let done = signin_body(r).get("done") is Some(Bool(true))
      signin_answered(
        self.backend.ask("signIns.self", who(r) + [js(id(r)), jbool(done)]),
      )
    }),
    route("POST", "^\\/browser\\/sign-ins\\/[^/]+\\/deny$", async fn(r, _) {
      signin_answered(self.backend.ask("signIns.deny", who(r) + [js(id(r))]))
    }),
  ]
}
