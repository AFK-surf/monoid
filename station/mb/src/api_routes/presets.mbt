// A workspace's presets (routes/presets.ts) and the models a person starred (routes/stars.ts): what an app from
// before asks and answers as before (GET, POST, PUT, DELETE /presets), what a core of now carries of its person's
// (GET /presets/kept, /presets/others, PUT /presets/kept), the repositories cloned for them (POST /presets/clone,
// DELETE /presets/clones/:id); GET /stars and PUT /stars, merged model by model and told to that person's devices.

///|
const CARRIED_MOST : Int32 = 100

///|
fn ws_of(r : Request) -> JV {
  r.ws_or_null()
}

///|
fn preset_asker(r : Request) -> JV {
  let field = (k : String) => {
    match r.who(k) {
      None | Some(Null) => js("")
      Some(v) => v
    }
  }
  jobj([("sub", field("sub")), ("email", field("email"))])
}

///|
/// A preset's body, or the refusal it is (`invalid JSON`).
fn preset_body(r : Request) -> JV raise Thrown {
  match body_or_empty(r) {
    Some(v) => v
    None => raise Thrown("Error", jobj([("message", js("invalid JSON"))]))
  }
}

///|
fn preset_failed(e : Error) -> Answer {
  match thrown_as(e, "NoPreset") {
    Some(_) => error(404, message_of(e))
    None => error(400, message_of(e))
  }
}

///|
async fn Admin::presets_changed(self : Admin) -> Unit {
  if self.setup.has("events") {
    self.backend.tell("events.presetsChanged", [])
  }
}

///|
fn Admin::presets_routes(self : Admin) -> Array[Route] {
  let clones = if self.setup.has("hub.clones") {
    [
      route("POST", "^\\/presets\\/clone$", async fn(r, _) {
        if read_only(r.viewer) {
          return json(
            403,
            stringify(
              jobj([
                ("error", js(self.tr(r.lang, "station.presets.clone.readOnly"))),
              ]),
            ),
          )
        }
        try {
          let given = jget(Some(preset_body(r)), "url").unwrap_or(jundef)
          let changed = self.callback(async fn(_) { self.presets_changed() })
          ok(
            self.backend.ask("hub.clones.start", [
              ws_of(r),
              given,
              js(r.email()),
              changed,
            ]),
          )
        } catch {
          e =>
            match thrown_as(e, "NoCloneUrl") {
              Some(_) =>
                json(
                  400,
                  stringify(
                    jobj([
                      (
                        "error",
                        js(self.tr(r.lang, "station.presets.clone.invalid")),
                      ),
                    ]),
                  ),
                )
              None => preset_failed(e)
            }
        }
      }),
      route("DELETE", "^\\/presets\\/clones\\/([A-Za-z0-9_-]+)$", async fn(
        r,
        m,
      ) {
        if read_only(r.viewer) {
          return json(
            403,
            stringify(
              jobj([
                ("error", js(self.tr(r.lang, "station.presets.clone.readOnly"))),
              ]),
            ),
          )
        }
        let id = m[0].unwrap()
        if !(self.backend.ask("hub.clones.drop", [ws_of(r), js(id)])
          is Bool(true)) {
          return error(404, "no clone \{id}")
        }
        ok(jobj([("ok", jbool(true))]))
      }),
    ]
  } else {
    []
  }
  [
    route("GET", "^\\/presets$", async fn(r, _) {
      let list = self.backend.ask("hub.presets.listed", [ws_of(r)])
      let all = self.backend.ask("hub.presets.list", [ws_of(r)])
      let dir = self.backend.ask("hub.reposDir", [])
      let repos = if self.setup.has("hub.repoIndex") {
        let changed = self.callback(async fn(_) { self.presets_changed() })
        let got = self.backend.ask("hub.repoIndex.repos", [changed])
        if nullish(got) {
          jarr([])
        } else {
          got
        }
      } else {
        jarr([])
      }
      let here = self.callback(async fn(_) {  })
      let offered = self.backend.ask("sessions/presets.candidates", [
        dir, all, repos, here,
      ])
      let cl = if self.setup.has("hub.clones") {
        self.backend.ask("hub.clones.list", [ws_of(r)])
      } else {
        jarr([])
      }
      ok(jobj([("presets", list), ("candidates", offered), ("clones", cl)]))
    }),
    route("GET", "^\\/presets\\/kept$", async fn(r, _) {
      ok(
        jobj([
          (
            "records",
            self.backend.ask("hub.presets.kept", [ws_of(r), preset_asker(r)]),
          ),
        ]),
      )
    }),
    route("GET", "^\\/presets\\/others$", async fn(r, _) {
      ok(
        jobj([
          (
            "records",
            self.backend.ask("hub.presets.others", [ws_of(r), preset_asker(r)]),
          ),
        ]),
      )
    }),
    route("PUT", "^\\/presets\\/kept$", async fn(r, _) {
      if r.body.length() > 1000000 {
        return error(
          413,
          "request too large: at most \{CARRIED_MOST} records and a megabyte at a time",
        )
      }
      let given = try {
        let b = preset_body(r)
        if nullish(b) {
          None
        } else {
          b.get("records")
        }
      } catch {
        e => return preset_failed(e)
      }
      guard given is Some(Arr(records) as given) else {
        return error(400, "records: a list of presets' records")
      }
      if records.length() > CARRIED_MOST {
        return error(413, "at most \{CARRIED_MOST} records at a time")
      }
      let who = preset_asker(r)
      if who.get("sub") == Some(js("")) {
        return error(403, "records are taken only from a person's own devices")
      }
      let carried = self.backend.ask("hub.presets.carry", [ws_of(r), who, given])
      if is_truthy(carried.get("changed")) {
        self.log(
          "info",
          "presets",
          "records carried here",
          jobj([
            ("by", js(r.email())),
            ("given", jint(records.length())),
            ("refused", jint(jitems(carried.get("refused")).length())),
          ]),
        )
        self.presets_changed()
      }
      ok(
        jobj([
          ("records", carried.get("records").unwrap_or(jundef)),
          ("refused", carried.get("refused").unwrap_or(jundef)),
        ]).filter_undef(),
      )
    }),
  ] +
  clones +
  [
    route("POST", "^\\/presets$", async fn(r, _) {
      try {
        let sub = match r.who("sub") {
          None | Some(Null) => js("")
          Some(v) => v
        }
        let p = self.backend.ask("hub.presets.add", [
          ws_of(r),
          preset_body(r),
          js(r.email()),
          sub,
        ])
        self.log(
          "info",
          "presets",
          "preset made",
          jobj([
            ("id", p.get("id").unwrap_or(jundef)),
            ("dirs", jint(jitems(p.get("dirs")).length())),
            ("by", js(r.email())),
          ]).filter_undef(),
        )
        self.presets_changed()
        ok(p)
      } catch {
        e => preset_failed(e)
      }
    }),
    route("PUT", "^\\/presets\\/([A-Za-z0-9_-]+)$", async fn(r, m) {
      try {
        let p = self.backend.ask("hub.presets.put", [
          ws_of(r),
          js(m[0].unwrap()),
          preset_body(r),
          preset_asker(r),
        ])
        self.log(
          "info",
          "presets",
          "preset changed",
          jobj([("id", p.get("id").unwrap_or(jundef)), ("by", js(r.email()))]).filter_undef(),
        )
        self.presets_changed()
        ok(p)
      } catch {
        e => preset_failed(e)
      }
    }),
    route("DELETE", "^\\/presets\\/([A-Za-z0-9_-]+)$", async fn(r, m) {
      try {
        self.backend.tell("hub.presets.delete", [
          ws_of(r),
          js(m[0].unwrap()),
          preset_asker(r),
        ])
        self.log(
          "info",
          "presets",
          "preset removed",
          jobj([("id", js(m[0].unwrap())), ("by", js(r.email()))]),
        )
        self.presets_changed()
        ok(jobj([("ok", jbool(true))]))
      } catch {
        e => preset_failed(e)
      }
    }),
  ]
}

///|
/// JavaScript's truthiness.
pub fn is_truthy(v : JV?) -> Bool {
  match v {
    None | Some(Null) | Some(Bool(false)) => false
    Some(Num(n)) => !(n == 0.0 || n.is_nan())
    Some(Str(s)) => s != ""
    Some(v) => !is_undef(v)
  }
}

///|
const STARS_BODY_MOST : Int32 = 262144

///|
/// A person's stars as last read or written: read by its key once.
async fn Admin::stars_read(self : Admin, ws : JV, sub : JV) -> JV {
  let at = "\{js_string(Some(ws))}\u{0}\{js_string(Some(sub))}"
  match self.state.stars.get(at) {
    Some(s) => s
    None => {
      let text = self.backend.ask("hub.store.modelStars", [ws, sub])
      let stars = try {
        if text is Null {
          JV::Obj([])
        } else {
          self.backend.ask("core/preset-records.starsOf", [
            parse(js_string(Some(text))),
          ])
        }
      } catch {
        e => {
          self.log(
            "warn",
            "stars",
            "a person's stars kept here do not read; taken as none",
            jobj([("error", js(message_of(e)))]),
          )
          Obj([])
        }
      }
      self.state.stars[at] = stars
      stars
    }
  }
}

///|
fn Admin::stars_routes(self : Admin) -> Array[Route] {
  [
    route("GET", "^\\/stars$", async fn(r, _) {
      if !is_truthy(r.who("sub")) {
        return error(403, "stars are a person's own")
      }
      ok(
        jobj([
          (
            "stars",
            self.stars_read(
              r.who("workspace").unwrap_or(jundef),
              r.who("sub").unwrap(),
            ),
          ),
        ]),
      )
    }),
    route("PUT", "^\\/stars$", async fn(r, _) {
      if !is_truthy(r.who("sub")) {
        return error(403, "stars are a person's own")
      }
      if r.body.length() > STARS_BODY_MOST {
        return error(413, "request too large")
      }
      let given = try {
        let parsed = match body_or_empty(r) {
          Some(v) => v
          None =>
            raise Thrown("SyntaxError", jobj([("message", js("invalid JSON"))]))
        }
        let stars = if nullish(parsed) {
          jundef
        } else {
          parsed.get("stars").unwrap_or(jundef)
        }
        self.backend.ask("core/preset-records.starsOf", [stars])
      } catch {
        e =>
          return error(
            400,
            match thrown_as(e, "RecordRefusal") {
              Some(_) => message_of(e)
              None => "invalid JSON"
            },
          )
      }
      let ws = r.who("workspace").unwrap_or(jundef)
      let sub = r.who("sub").unwrap()
      let was = self.stars_read(ws, sub)
      let now = self.backend.ask("core/preset-records.mergeStars", [was, given])
      let a = self.backend.ask("core/preset-records.canonical", [now])
      let b = self.backend.ask("core/preset-records.canonical", [was])
      if a != b {
        self.backend.tell("hub.store.putModelStars", [
          ws,
          sub,
          js(stringify(now)),
        ])
        self.state.stars["\{js_string(Some(ws))}\u{0}\{js_string(Some(sub))}"] = now
        if self.setup.has("events") {
          let wsv = if is_undef(ws) { jundef } else { ws }
          self.backend.tell("events.tell", [
            js("stars"),
            jobj([("workspace", wsv)]).filter_undef(),
            js("stars\u{0}\{js_string(Some(ws))}\u{0}\{js_string(Some(sub))}"),
            jobj([("workspace", wsv), ("subs", jarr([sub]))]).filter_undef(),
          ])
        }
      }
      ok(jobj([("stars", now)]))
    }),
  ]
}
