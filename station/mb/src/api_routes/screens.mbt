// The screens members see and drive (admin.ts): the list, a browser's tab opened or closed, a link opened, reloaded,
// back and forth, put to sleep, a view ended or made to only look; a simulator's logs, apps, settings, its case's
// pictures, a screenshot, what Device Hub does of a device, its movie, an app installed and relaunched.

///|
fn screen_args(said : JV) -> Array[(String, String)] {
  jfields(said.get("args")).map(f => (f.0, js_string(Some(f.1))))
}

///|
/// What the screens refused, in the asker's words; None for anything else.
fn Admin::screen_refused(self : Admin, e : Error, lang : String) -> Answer? {
  match thrown_as(e, "ScreenRefused") {
    Some(said) =>
      Some(
        error(
          status_of(said),
          self.tr(lang, js_string(said.get("key")), args=screen_args(said)),
        ),
      )
    None => None
  }
}

///|
fn screen_refusal(status : Int32, key : String) -> Thrown {
  Thrown(
    "ScreenRefused",
    jobj([("status", jint(status)), ("key", js(key)), ("message", js(key))]),
  )
}

///|
/// A failure's last line (simctl's own: what is before it is the command it ran).
fn last_said_line(message : String) -> String {
  let lines = message
    .split("\n")
    .map(l => trim_js(l.to_string()))
    .filter(l => l != "")
    .collect()
  lines.last().unwrap_or("")
}

///|
fn byte_of(r : Request) -> JV {
  let name = r.who_str("name")
  js(if name == "" { r.email() } else { name })
}

///|
async fn Admin::screen_debug(
  self : Admin,
  r : Request,
  raw : String,
  answer : async (String) -> JV,
) -> Answer {
  if read_only(r.viewer) {
    return error(403, "a read-only member does not read an app's logs")
  }
  guard decode_uri_component(raw) is Some(id) else {
    return error(404, self.tr(r.lang, "station.screen.notFound"))
  }
  try {
    let debug = ref_of(self.backend.ask("screens.debugOf", [js(id)])).unwrap_or(
      "",
    )
    ok(answer(debug))
  } catch {
    e =>
      match self.screen_refused(e, r.lang) {
        Some(a) => a
        None =>
          error(
            502,
            self.tr(r.lang, "station.screen.debugFailed", args=[
              ("said", last_said_line(message_of(e))),
            ]),
          )
      }
  }
}

///|
async fn Admin::act_screen(
  self : Admin,
  r : Request,
  raw : String,
  act : async (String) -> Unit,
) -> Answer {
  guard decode_uri_component(raw) is Some(id) else {
    return error(404, self.tr(r.lang, "station.screen.notFound"))
  }
  try {
    act(id)
    json(200, "{}")
  } catch {
    e =>
      match self.screen_refused(e, r.lang) {
        Some(a) => a
        None =>
          error(
            502,
            self.tr(r.lang, "station.screen.failed", args=[
              ("said", message_of(e)),
            ]),
          )
      }
  }
}

///|
async fn Admin::screen_views(
  self : Admin,
  r : Request,
  raw : String,
  act : async (String) -> JV,
) -> Answer {
  try {
    guard decode_uri_component(raw) is Some(id) else {
      raise Thrown("URIError", jobj([("message", js("URI malformed"))]))
    }
    ok(act(id))
  } catch {
    e =>
      match self.screen_refused(e, r.lang) {
        Some(a) => a
        None =>
          if thrown_as(e, "URIError") is Some(_) {
            error(404, self.tr(r.lang, "station.screen.notFound"))
          } else {
            raise e
          }
      }
  }
}

///|
fn Admin::screens_routes(self : Admin) -> Array[Route] {
  if !self.setup.has("screens") {
    return []
  }
  let s = async fn(call : String, args : Array[JV]) -> JV {
    self.backend.ask("screens." + call, args)
  }
  let body_of = (r : Request) => {
    parse(if r.text() == "" { "{}" } else { r.text() })
  }
  let sim = (path : String, act : async (String, JV) -> Unit) => {
    route("POST", "^/screens/([^/]+)/\{path}$", async fn(r, m) {
      self.screen_debug(r, m[0].unwrap(), async fn(d) {
        act(d, body_of(r))
        Obj([])
      })
    })
  }
  [
    route("GET", "^\\/screens$", async fn(r, _) {
      ignore(s("refresh", []))
      ok(s("listed", [js(r.lang)]))
    }),
    route("POST", "^\\/screens\\/browser$", async fn(r, _) {
      self.open_browser_screen(r)
    }),
    // A person closes one (a tab of the browser): it leaves the list as it goes.
    route("POST", "^\\/screens\\/([^/]+)\\/close$", async fn(r, m) {
      self.act_screen(r, m[0].unwrap(), async fn(id) {
        ignore(s("closeScreen", [js(id)]))
      })
    }),
    route("POST", "^\\/screens\\/([^/]+)\\/open-url$", async fn(r, m) {
      self.open_screen_url(r, m[0].unwrap())
    }),
    route("POST", "^\\/screens\\/([^/]+)\\/reload$", async fn(r, m) {
      self.act_screen(r, m[0].unwrap(), async fn(id) {
        ignore(s("reloadScreen", [js(id)]))
      })
    }),
    route("POST", "^\\/screens\\/([^/]+)\\/back$", async fn(r, m) {
      self.act_screen(r, m[0].unwrap(), async fn(id) {
        ignore(s("historyScreen", [js(id), jint(-1)]))
      })
    }),
    route("POST", "^\\/screens\\/([^/]+)\\/forward$", async fn(r, m) {
      self.act_screen(r, m[0].unwrap(), async fn(id) {
        ignore(s("historyScreen", [js(id), jint(1)]))
      })
    }),
    route("POST", "^\\/screens\\/([^/]+)\\/sleep$", async fn(r, m) {
      self.act_screen(r, m[0].unwrap(), async fn(id) {
        ignore(s("sleepScreen", [js(id)]))
      })
    }),
    route("POST", "^\\/screens\\/([^/]+)\\/views\\/end$", async fn(r, m) {
      self.screen_views(r, m[0].unwrap(), async fn(id) {
        jobj([("ended", s("endViews", [js(id), byte_of(r)]))])
      })
    }),
    route("POST", "^\\/screens\\/([^/]+)\\/views\\/([^/]+)\\/end$", async fn(
      r,
      m,
    ) {
      self.screen_views(r, m[0].unwrap(), async fn(id) {
        let view = uri_part(m[1].unwrap())
        ignore(s("endView", [js(id), js(view), byte_of(r)]))
        Obj([])
      })
    }),
    route("POST", "^\\/screens\\/([^/]+)\\/views\\/([^/]+)\\/watch$", async fn(
      r,
      m,
    ) {
      self.screen_views(r, m[0].unwrap(), async fn(id) {
        let view = uri_part(m[1].unwrap())
        ignore(s("watchOnly", [js(id), js(view)]))
        Obj([])
      })
    }),
    // A person debugging an app on a simulator: its apps' logs (a poll, `after` from the last answer's `next`).
    route("GET", "^\\/screens\\/([^/]+)\\/logs$", async fn(r, m) {
      self.screen_debug(r, m[0].unwrap(), async fn(d) {
        let after = js_number(r.param("after").unwrap_or("undefined"))
        let n = if after.is_nan() { 0.0 } else { @cmp.maximum(0.0, after) }
        self.backend.ask(d + ".logs", [jnum(if n == 0.0 { 0.0 } else { n })])
      })
    }),
    route("GET", "^\\/screens\\/([^/]+)\\/apps$", async fn(r, m) {
      self.screen_debug(r, m[0].unwrap(), async fn(d) {
        jobj([("apps", self.backend.ask(d + ".apps", []))])
      })
    }),
    route("GET", "^\\/screens\\/([^/]+)\\/settings$", async fn(r, m) {
      self.screen_debug(r, m[0].unwrap(), async fn(d) {
        self.backend.ask(d + ".settings", [])
      })
    }),
    route("POST", "^\\/screens\\/([^/]+)\\/settings$", async fn(r, m) {
      self.screen_debug(r, m[0].unwrap(), async fn(d) {
        let b = body_of(r)
        match (field_of(Some(b), "name"), field_of(Some(b), "value")) {
          (Some(Str(name)), Some(Str(value))) =>
            if !is_truthy(
                Some(self.backend.ask(d + ".setSetting", [js(name), js(value)])),
              ) {
              raise screen_refusal(400, "station.screen.noSetting")
            }
          _ => raise screen_refusal(400, "station.screen.noSetting")
        }
        self.backend.ask(d + ".settings", [])
      })
    }),
    route("GET", "^\\/screens\\/([^/]+)\\/chrome\\/(\\d)\\/(\\d)$", async fn(
      r,
      m,
    ) {
      guard decode_uri_component(m[0].unwrap()) is Some(id) else {
        return error(404, self.tr(r.lang, "station.screen.notFound"))
      }
      ok(
        s("chromeOf", [
          js(id),
          jnum(js_number(m[1].unwrap())),
          jnum(js_number(m[2].unwrap())),
        ]),
      ) catch {
        e =>
          match self.screen_refused(e, r.lang) {
            Some(a) => a
            None => {
              let lines = message_of(e)
                .split("\n")
                .map(l => l.to_string())
                .collect()
              error(
                502,
                self.tr(r.lang, "station.screen.debugFailed", args=[
                  ("said", lines.last().unwrap_or("")),
                ]),
              )
            }
          }
      }
    }),
    route("POST", "^\\/screens\\/([^/]+)\\/screenshot$", async fn(r, m) {
      self.screen_debug(r, m[0].unwrap(), async fn(d) {
        let png = bytes_of(self.backend.ask(d + ".screenshot", [])).unwrap_or(
          b"",
        )
        jobj([("png", js(@base64.encode(png)))])
      })
    }),
    // What a person does of a device as Device Hub would, each with what it is told.
    sim("location", async fn(d, said) {
      let at = field_of(Some(said), "at")
      match at {
        None | Some(Str(_)) => ()
        _ => raise screen_refusal(400, "station.screen.badPlace")
      }
      let given = match at {
        Some(Str(_) as a) => a
        _ => Null
      }
      if !is_truthy(Some(self.backend.ask(d + ".location", [given]))) {
        raise screen_refusal(400, "station.screen.badPlace")
      }
    }),
    sim("status-bar", async fn(d, said) {
      ignore(
        self.backend.ask(d + ".statusBar", [
          jbool(field_of(Some(said), "tidy") is Some(Bool(true))),
        ]),
      )
    }),
    sim("biometrics", async fn(d, said) {
      guard field_of(Some(said), "what") is Some(Str(what)) else {
        raise screen_refusal(400, "station.screen.noSetting")
      }
      if !is_truthy(Some(self.backend.ask(d + ".biometrics", [js(what)]))) {
        raise screen_refusal(400, "station.screen.noSetting")
      }
    }),
    sim("uninstall", async fn(d, said) {
      guard field_of(Some(said), "app") is Some(Str(app)) else {
        raise screen_refusal(404, "station.screen.noApp")
      }
      if !is_truthy(Some(self.backend.ask(d + ".uninstall", [js(app)]))) {
        raise screen_refusal(404, "station.screen.noApp")
      }
    }),
    sim("record", async fn(d, said) {
      let panel = match field_of(Some(said), "panel") {
        Some(Str("inner" | "cover") as p) => p
        _ => Null
      }
      ignore(self.backend.ask(d + ".recordStart", [panel]))
    }),
    sim("push", async fn(d, said) {
      guard field_of(Some(said), "app") is Some(Str(app)) &&
        field_of(Some(said), "text") is Some(Str(text)) else {
        raise screen_refusal(404, "station.screen.noApp")
      }
      if !is_truthy(Some(self.backend.ask(d + ".push", [js(app), js(text)]))) {
        raise screen_refusal(404, "station.screen.noApp")
      }
    }),
    // Its movie, the drive's way for the viewer to download (none: nothing was going on).
    route("POST", "^\\/screens\\/([^/]+)\\/record\\/stop$", async fn(r, m) {
      self.screen_debug(r, m[0].unwrap(), async fn(d) {
        let movie = self.backend.ask(d + ".recordStop", [])
        if nullish(movie) {
          Obj([])
        } else {
          movie
        }
      })
    }),
    route("POST", "^\\/screens\\/([^/]+)\\/install$", async fn(r, m) {
      self.screen_debug(r, m[0].unwrap(), async fn(d) {
        let app = match field_of(Some(body_of(r)), "path") {
          Some(Str(p)) => self.backend.ask(d + ".install", [js(p)])
          _ => Null
        }
        if app is Null {
          raise screen_refusal(400, "station.screen.notAnApp")
        }
        jobj([("app", app)])
      })
    }),
    route("POST", "^\\/screens\\/([^/]+)\\/relaunch$", async fn(r, m) {
      self.screen_debug(r, m[0].unwrap(), async fn(d) {
        guard field_of(Some(body_of(r)), "app") is Some(Str(app)) else {
          raise screen_refusal(404, "station.screen.noApp")
        }
        if !is_truthy(Some(self.backend.ask(d + ".relaunch", [js(app)]))) {
          raise screen_refusal(404, "station.screen.noApp")
        }
        Obj([])
      })
    }),
  ]
}

///|
async fn Admin::open_browser_screen(self : Admin, r : Request) -> Answer {
  let given = match body_or_empty(r) {
    Some(Obj(_) as o) => o
    Some(Null) | None =>
      return error(400, self.tr(r.lang, "station.screen.badUrl"))
    Some(other) => other
  }
  guard field_of(Some(given), "url") is Some(Str(url)) else {
    return error(400, self.tr(r.lang, "station.screen.badUrl"))
  }
  let id = field_of(Some(given), "id")
  match id {
    None => ()
    Some(Str(i)) if re("^u_[0-9a-f]{12}$").matches(i) => ()
    _ => return error(400, "id: u_ and 12 hex digits")
  }
  try {
    let screen = self.backend.ask("screens.openBrowser", [
      js(url),
      id.unwrap_or(jundef),
    ])
    ok(jobj([("screen", screen)]))
  } catch {
    e =>
      match self.screen_refused(e, r.lang) {
        Some(a) => a
        None =>
          error(
            502,
            self.tr(r.lang, "station.screen.failed", args=[
              ("said", message_of(e)),
            ]),
          )
      }
  }
}

///|
async fn Admin::open_screen_url(
  self : Admin,
  r : Request,
  raw : String,
) -> Answer {
  if read_only(r.viewer) {
    return error(403, "a read-only member does not open a link on a screen")
  }
  guard decode_uri_component(raw) is Some(id) else {
    return error(404, self.tr(r.lang, "station.screen.notFound"))
  }
  let url = match body_or_empty(r) {
    None | Some(Null) =>
      return error(400, self.tr(r.lang, "station.screen.badUrl"))
    v => field_of(v, "url")
  }
  let source = self.backend.ask("screens.get", [js(id)])
  try {
    match url {
      Some(Str(_)) => ()
      _ => {
        if is_undef(source) {
          raise screen_refusal(404, "station.screen.notFound")
        }
        if is_undef(jget(Some(source), "openUrl").unwrap_or(jundef)) &&
          is_undef(jget(Some(source), "debug").unwrap_or(jundef)) {
          raise screen_refusal(405, "station.screen.noDebug")
        }
        raise screen_refusal(400, "station.screen.badUrl")
      }
    }
    ignore(self.backend.ask("screens.openUrl", [js(id), url.unwrap()]))
    json(200, "{}")
  } catch {
    e =>
      match self.screen_refused(e, r.lang) {
        Some(a) => a
        None =>
          if !is_undef(jget(Some(source), "debug").unwrap_or(jundef)) {
            error(
              502,
              self.tr(r.lang, "station.screen.debugFailed", args=[
                ("said", last_said_line(message_of(e))),
              ]),
            )
          } else {
            error(
              502,
              self.tr(r.lang, "station.screen.failed", args=[
                ("said", message_of(e)),
              ]),
            )
          }
      }
  }
}
