// The station's settings a manager sets from the pages, each written to config.json and told as the overview changes:
// going on afresh once a cache is over (routes/context.ts), what the search finds (routes/search.ts), the network's
// congestion controller and the station's restart (routes/network.ts), the device tools (routes/tools.ts), the
// diagnostics (routes/diagnostics.ts), the agents' environment (routes/agent-env.ts).

///|
/// config.json as the station has it now.
async fn Admin::config_raw(self : Admin) -> JV {
  self.backend.ask("config.raw", [])
}

///|
/// config.json changed as `edit` changes it (ConfigFile `updateSoon`: the station's latest, written soon).
async fn Admin::config_update(self : Admin, edit : (JV) -> JV) -> Unit {
  let raw = self.config_raw()
  self.backend.tell("config.updateSoon", [edit(raw)])
}

///|
/// The overview changed (events `overviewChanged`).
async fn Admin::overview_changed(self : Admin) -> Unit {
  if self.setup.has("events") {
    self.backend.tell("events.overviewChanged", [])
  }
}

///|
/// The setting as the overview says it (routes/context.ts `contextView`).
async fn Admin::context_view(self : Admin, raw : JV) -> JV {
  let on = raw.get("afreshWhenCold") is Some(Bool(true))
  let above = self.backend.ask("core/cache-policy.afreshThreshold", [
    raw.get("afreshAbove").unwrap_or(jundef),
  ])
  jobj([("afreshWhenCold", jbool(on)), ("afreshAbove", above)])
}

///|
fn Admin::context_routes(self : Admin) -> Array[Route] {
  [
    route("PUT", "^\\/context\\/settings$", async fn(r, _) {
      if !manages_station(r.viewer) {
        return error(403, self.tr(r.lang, "station.context.managersOnly"))
      }
      let settings = match body_or_empty(r) {
        None => return error(400, "invalid JSON")
        Some(Obj(_) as o) => o
        Some(_) => return error(400, "expected an object")
      }
      let on = settings.get("afreshWhenCold")
      let above = settings.get("afreshAbove")
      if on is None && above is None {
        return error(400, "no context setting given")
      }
      match on {
        Some(Bool(_)) | None => ()
        _ => return error(400, "afreshWhenCold is true or false")
      }
      match above {
        None => ()
        Some(Num(n)) if !n.is_nan() && !n.is_inf() && n >= 0.0 => ()
        _ => return error(400, "afreshAbove is a nonnegative amount in USD")
      }
      // (client/core-ts/src/cache-policy.ts DEFAULT_AFRESH_ABOVE)
      let default_above = jnum(1.0)
      self.config_update(raw => {
        let mut raw = raw
        match on {
          Some(Bool(true)) => raw = jset(raw, "afreshWhenCold", jbool(true))
          Some(_) => raw = jdel(raw, "afreshWhenCold")
          None => ()
        }
        match above {
          Some(a) =>
            raw = if a == default_above {
              jdel(raw, "afreshAbove")
            } else {
              jset(raw, "afreshAbove", a)
            }
          None => ()
        }
        raw
      })
      self.log(
        "info",
        "context",
        "going on afresh once a cache is over set",
        jobj(
          (match on {
            Some(v) => [("on", v)]
            None => []
          }) +
          (match above {
            Some(v) => [("above", v)]
            None => []
          }) +
          [("by", js(r.email()))],
        ),
      )
      self.overview_changed()
      ok(self.context_view(self.config_raw()))
    }),
  ]
}

///|
/// What a viewer is asking as (routes/search.ts `askerOf`).
fn asker_of(viewer : JV) -> JV {
  jobj([
    ("workspace", jget(Some(viewer), "workspace").unwrap_or(jundef)),
    ("home", jbool(!(jget(Some(viewer), "home") is Some(Bool(false))))),
    ("scopes", if read_only(viewer) { jarr([]) } else { jstrs(["write"]) }),
  ]).filter_undef()
}

///|
let people_kinds : Array[String] = ["chat", "message", "job", "file"]

///|
fn count_param(v : String?, fallback : Double) -> Double {
  match v {
    Some(s) if re("^[0-9]{1,4}$").matches(s) => js_number(s)
    _ => fallback
  }
}

///|
fn Admin::search_routes(self : Admin) -> Array[Route] {
  [
    // Whether the machine's person's own mail, messages and the rest are found too: the station's managers say.
    route("PUT", "^\\/search\\/settings$", async fn(r, _) {
      if !manages_station(r.viewer) {
        return error(
          403, "only the workspace's owners and admins set what the station's search finds",
        )
      }
      let personal = match body_or_empty(r) {
        None => return error(400, "invalid JSON")
        Some(v) => if v is (Obj(_) | Arr(_)) { v.get("personal") } else { None }
      }
      guard personal is Some(Bool(p)) else {
        return error(400, "personal is true or false")
      }
      self.config_update(raw => {
        let search = match raw.get("search") {
          Some(Obj(_) as s) => s
          Some(Arr(_) as a) => jspread(Obj([]), arr_as_object(a))
          _ => Obj([])
        }
        jset(raw, "search", jset(search, "personal", jbool(p)))
      })
      self.overview_changed()
      ok(jobj([("personal", jbool(p))]))
    }),
    route("GET", "^\\/search$", async fn(r, _) {
      let q = r.param("q").unwrap_or("")
      if q.length() > 200 {
        return error(400, "a search is at most 200 characters")
      }
      let asked = r
        .param("kinds")
        .unwrap_or("")
        .split(",")
        .map(k => k.to_string())
        .filter(k => k != "")
        .collect()
      let kinds = if asked.length() > 0 {
        asked.filter(k => people_kinds.contains(k))
      } else {
        people_kinds
      }
      if kinds.length() == 0 {
        return ok(jobj([("groups", jarr([])), ("building", jbool(false))]))
      }
      let device = r.who_str("device")
      let asker = jspread(
        asker_of(r.viewer),
        jobj(
          (if device != "" { [("typist", js(device))] } else { [] }) +
          (if r.param("again") == Some("1") {
            [("again", jbool(true))]
          } else {
            []
          }),
        ),
      )
      let options = jobj(
        (if r.param("archived") == Some("1") {
          [("archived", jbool(true))]
        } else {
          []
        }) +
        [
          ("kinds", jstrs(kinds)),
          ("limit", jnum(count_param(r.param("limit"), 8.0))),
          ("offset", jnum(count_param(r.param("offset"), 0.0))),
        ],
      )
      ok(self.backend.ask("search.query", [js(q), asker, options])) catch {
        e => error(503, message_of(e))
      }
    }),
  ]
}

///|
/// An array spread into an object (`{...[a, b]}`: its indices as keys).
fn arr_as_object(a : JV) -> JV {
  let mut o = JV::Obj([])
  for i, v in jitems(Some(a)) {
    o = jset(o, i.to_string(), v)
  }
  o
}
