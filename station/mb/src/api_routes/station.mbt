// The station's own settings and business, each its route file's: the agents' variables (routes/agent-env.ts), the
// device tools' access (routes/tools.ts), sending its log (routes/diagnostics.ts), what macOS lets its Helper do
// (routes/permissions.ts), its updates (routes/updates.ts), its network and restart (routes/network.ts), the
// workspaces it is in (routes/workspaces.ts), its copies and retirement (routes/copies.ts), chats shared with other
// workspaces (routes/xshare.ts), a link's preview (routes/links.ts) and the overview.

///|
/// `v?.[k]` of what JSON.parse gave: an object's field, nothing of anything else.
fn field_of(v : JV?, k : String) -> JV? {
  match v {
    Some(Obj(_) as o) => o.get(k)
    _ => None
  }
}

///|
/// `{...v}` of a value the station kept: an object's fields, an array's by index, nothing of anything else.
fn spread_of(v : JV?) -> JV {
  match v {
    Some(Obj(_) as o) => o
    Some(Arr(_) as a) => arr_as_object(a)
    _ => Obj([])
  }
}

///|
const MOST_VARS : Int32 = 64

///|
const MOST_VALUE : Int32 = 4096

///|
async fn Admin::agent_env(self : Admin, raw : JV) -> JV {
  self.backend.ask("ops/agent-env.agentEnv", [raw])
}

///|
/// The variables as the pages show them, by name: a secret's value masked.
async fn Admin::agent_env_view(self : Admin, raw : JV) -> JV {
  let env = jfields(Some(self.agent_env(raw))).copy()
  env.sort_by((a, b) => js_compare(a.0, b.0))
  let out = []
  for e in env {
    let (key, value) = e
    if is_truthy(
        Some(self.backend.ask("ops/agent-env.secretValue", [js(key), value])),
      ) {
      out.push(
        jobj([
          ("key", js(key)),
          ("value", self.backend.ask("ops/agent-env.maskValue", [value])),
          ("secret", jbool(true)),
        ]),
      )
    } else {
      out.push(
        jobj([("key", js(key)), ("value", value), ("secret", jbool(false))]),
      )
    }
  }
  jarr(out)
}

///|
fn Admin::agent_env_routes(self : Admin) -> Array[Route] {
  [
    route("PUT", "^\\/agent-env$", async fn(r, _) {
      if !manages_station(r.viewer) {
        return error(403, self.tr(r.lang, "station.agentEnv.managersOnly"))
      }
      let body = match body_or_empty(r) {
        None => return error(400, "invalid JSON")
        Some(Obj(_) as o) => o
        Some(_) => Obj([])
      }
      let before = self.agent_env(self.config_raw())
      // As written (`text`, a .env file's lines): all of them, a secret left masked kept as it was; else a patch.
      let mut next = JV::Obj([])
      match (body.get("text"), body.get("env")) {
        (Some(Str(text)), _) => {
          let read = self.backend.ask("ops/agent-env.parseEnvText", [
            js(text),
            before,
          ])
          if jhas(read, "why") {
            let line = js_string(read.get("line"))
            let words = match jstr(read.get("why")) {
              Some("tooMany") =>
                self.tr(r.lang, "station.agentEnv.tooMany", args=[
                  ("most", MOST_VARS.to_string()),
                ])
              Some("badName") =>
                self.tr(r.lang, "station.agentEnv.badName", args=[
                  ("line", line),
                  (
                    "name",
                    match read.get("name") {
                      None | Some(Null) => ""
                      Some(n) => js_string(Some(n))
                    },
                  ),
                ])
              Some("tooLong") =>
                self.tr(r.lang, "station.agentEnv.tooLong", args=[
                  ("line", line),
                  ("most", MOST_VALUE.to_string()),
                ])
              _ =>
                self.tr(r.lang, "station.agentEnv.notPair", args=[
                  ("line", line),
                ])
            }
            return error(400, words)
          }
          next = read
        }
        (_, Some(Obj(patch))) => {
          next = spread_of(Some(before))
          for p in patch {
            let (key, value) = p
            if !re("^[A-Za-z_][A-Za-z0-9_]*$").matches(key) {
              return error(400, "invalid environment variable name \{key}")
            }
            match value {
              Null => next = jdel(next, key)
              Str(_) => next = jset(next, key, value)
              _ =>
                return error(400, "env.\{key}: a string, or null to remove it")
            }
          }
        }
        _ =>
          return error(
            400, "text: the variables as NAME=value lines; or env: a map of variables to a value, or null to remove one",
          )
      }
      let given = next
      self.config_update(raw => {
        if jfields(Some(given)).length() > 0 {
          jset(raw, "agentEnv", given)
        } else {
          jdel(raw, "agentEnv")
        }
      }) catch {
        e => return error(400, message_of(e))
      }
      let after = self.agent_env(self.config_raw())
      if stringify(after) != stringify(before) {
        self.log(
          "info",
          "agent-env",
          "the agents' variables changed",
          jobj([
            ("names", jarr(jfields(Some(after)).map(f => js(f.0)))),
            ("by", js(r.email())),
          ]),
        )
        self.backend.tell("hub.everyChanged", [])
      }
      self.overview_changed()
      ok(jobj([("env", self.agent_env_view(self.config_raw()))]))
    }),
  ]
}

///|
let access_levels : Array[String] = ["off", "read", "full"]

///|
let read_ops : Array[String] = [
  "fs.read", "fs.list", "fs.stat", "runtime.probe", "process.list", "process.tail",
  "session.status",
]

///|
fn tools_view(access : JV) -> JV {
  jobj([
    ("access", access),
    ("levels", jstrs(access_levels)),
    ("read_ops", jstrs(read_ops)),
    (
      "about",
      jobj([
        ("off", js("The control plane's agents cannot use this machine.")),
        (
          "read",
          js(
            "Agents can read every file this machine's user can read, except the station's own data, and see processes, runtimes and chat states.",
          ),
        ),
        (
          "full",
          js(
            "Agents can also run commands, write files, manage processes and start chats as this machine's user.",
          ),
        ),
      ]),
    ),
  ])
}

///|
fn Admin::tools_routes(self : Admin) -> Array[Route] {
  [
    route("GET", "^\\/tools\\/access$", async fn(_r, _) {
      let access = match
        field_of(field_of(Some(self.config_raw()), "tools"), "access") {
        Some(Str("off" | "read" | "full") as a) => a
        _ => js("off")
      }
      ok(tools_view(access))
    }),
    route("PUT", "^\\/tools\\/access$", async fn(r, _) {
      if !manages_station(r.viewer) {
        return error(
          403, "only the workspace's owners and admins set the device tools' access",
        )
      }
      let asked = match body_or_empty(r) {
        None => return error(400, "invalid JSON")
        v => field_of(v, "access")
      }
      guard asked is Some(Str(a)) && access_levels.contains(a) else {
        return error(400, "access is one of \{access_levels.join(", ")}")
      }
      self.config_update(raw => {
        jset(raw, "tools", jset(spread_of(raw.get("tools")), "access", js(a)))
      }) catch {
        e => return error(400, message_of(e))
      }
      self.overview_changed()
      ok(tools_view(js(a)))
    }),
  ]
}

///|
fn diagnostics_view(raw : JV) -> JV {
  jobj([
    (
      "logs",
      jbool(
        !(field_of(field_of(Some(raw), "telemetry"), "logs")
        is Some(Bool(false))),
      ),
    ),
  ])
}

///|
fn Admin::diagnostics_routes(self : Admin) -> Array[Route] {
  [
    route("PUT", "^\\/diagnostics\\/settings$", async fn(r, _) {
      if !manages_station(r.viewer) {
        return error(403, self.tr(r.lang, "station.context.managersOnly"))
      }
      let on = match body_or_empty(r) {
        None => return error(400, "invalid JSON")
        v => field_of(v, "logs")
      }
      guard on is Some(Bool(on)) else {
        return error(400, "logs is true or false")
      }
      self.config_update(raw => {
        let mut telemetry = spread_of(raw.get("telemetry"))
        telemetry = if on {
          jdel(telemetry, "logs")
        } else {
          jset(telemetry, "logs", jbool(false))
        }
        if jfields(Some(telemetry)).length() > 0 {
          jset(raw, "telemetry", telemetry)
        } else {
          jdel(raw, "telemetry")
        }
      })
      // Said before it stops: the last line sent says who turned it off.
      self.log(
        "info",
        "diagnostics",
        "sending the station's log set",
        jobj([("on", jbool(on)), ("by", js(r.email()))]),
      )
      self.overview_changed()
      ok(diagnostics_view(self.config_raw()))
    }),
  ]
}

///|
fn Admin::network_routes(self : Admin) -> Array[Route] {
  [
    route("PUT", "^\\/network\\/settings$", async fn(r, _) {
      if !manages_station(r.viewer) {
        return error(403, self.tr(r.lang, "station.network.managersOnly"))
      }
      guard body_json(r) is Some(body) else {
        return error(400, "invalid JSON")
      }
      let mut set = JV::Obj([])
      if body is (Obj(_) | Arr(_)) && jhas(body, "congestion") {
        match body.get("congestion") {
          Some(Str("cubic" | "bbr") as c) => set = jset(set, "congestion", c)
          _ => return error(400, "congestion: expected cubic or bbr")
        }
      }
      if jfields(Some(set)).length() == 0 {
        return error(400, "expected congestion")
      }
      let given = set
      self.config_update(raw => {
        jset(raw, "network", jspread(spread_of(raw.get("network")), given))
      })
      self.overview_changed()
      ok(self.backend.ask("mesh/settings.networkView", [self.config_raw()]))
    }),
    // The station started again: its launcher hands over to a new process.
    route("POST", "^\\/station\\/restart$", async fn(r, _) {
      if !manages_station(r.viewer) {
        return error(403, self.tr(r.lang, "station.restart.managersOnly"))
      }
      let go = if self.setup.has("restart") {
        self.backend.ask("restart", [])
      } else {
        Null
      }
      guard ref_of(go) is Some(go) else {
        return error(409, self.tr(r.lang, "station.restart.cannot"))
      }
      self.log(
        "info",
        "restart",
        "asked from the station's page",
        jobj([("by", js(r.email()))]),
      )
      // The old process serves on (this answer too) until the new one has taken over.
      self.backend.tell(go, [])
      ok(jobj([("restarting", jbool(true))]), status=202)
    }),
  ]
}

///|
fn Admin::permissions_routes(self : Admin) -> Array[Route] {
  let refused = (status : Int32, key : String, lang : String) => {
    json(status, stringify(jobj([("error", js(self.tr(lang, key)))])))
  }
  [
    route("POST", "^\\/permissions\\/request$", async fn(r, _) {
      let grant = field_of(body_or_empty(r), "grant").unwrap_or(jundef)
      if !(self.backend.ask("helper/grants.isGrant", [grant]) is Bool(true)) {
        return refused(400, "station.permissions.unknown", r.lang)
      }
      try {
        let words = self.backend.ask("helper/files.askWords", [js(r.lang)])
        let got = self.backend.ask("grants.request", [grant, words, jbool(true)])
        if got.get("window") == Some(js("none")) {
          return refused(503, "station.permissions.none", r.lang)
        }
        ok(
          jobj([
            ("window", got.get("window").unwrap_or(jundef)),
            ("screen", got.get("screen").unwrap_or(jundef)),
          ]).filter_undef(),
        )
      } catch {
        e =>
          match thrown_as(e, "GrantRefused") {
            Some(said) => {
              let key = js_string(said.get("key"))
              let status = if key == "station.permissions.noHelper" {
                503
              } else if key == "station.permissions.unknown" {
                400
              } else {
                409
              }
              refused(status, key, r.lang)
            }
            None => raise e
          }
      }
    }),
  ]
}

///|
fn Admin::updates_routes(self : Admin) -> Array[Route] {
  let answer = (f : async (Request) -> Unit) => {
    async fn(r : Request, _m : Array[String?]) -> Answer {
      try {
        if !manages_station(r.viewer) {
          raise Refused(
            403,
            self.tr(r.lang, "station.admin.updatesManagersOnly"),
          )
        }
        if !self.setup.has("agents.updates") {
          raise Refused(
            404,
            self.tr(r.lang, "station.admin.updatesUnavailable"),
          )
        }
        f(r) catch {
          e =>
            match refused_of(e) {
              Some(_) => raise e
              None => raise Refused(400, message_of(e))
            }
        }
        ok(self.backend.ask("updates.get", [js(r.lang)]))
      } catch {
        e =>
          match refused_of(e) {
            Some((status, message)) => error(status, message)
            None => error(500, message_of(e))
          }
      }
    }
  }
  [
    route(
      "POST",
      "^\\/updates\\/check$",
      answer(async fn(_r) { self.backend.tell("updates.check", []) }),
    ),
    // The station's update channel (stable or beta), set as someone asked.
    route(
      "POST",
      "^\\/updates\\/channel$",
      answer(async fn(r) {
        let asked = match input(r).get("channel") {
          Some(Str(s)) => s
          _ => ""
        }
        let channel = self.backend.ask("updates/versions.channelOfId", [
          js(asked),
        ])
        if channel is Null {
          raise Refused(400, self.tr(r.lang, "station.admin.badChannel"))
        }
        self.backend.tell("updates.setChannel", [channel, js(r.lang)])
      }),
    ),
    // The station updating itself or not, as someone asked: { on }.
    route(
      "POST",
      "^\\/updates\\/auto$",
      answer(async fn(r) {
        guard input(r).get("on") is Some(Bool(on)) else {
          raise Refused(400, self.tr(r.lang, "station.admin.badOn"))
        }
        self.backend.tell("updates.setAuto", [jbool(on), js(r.lang)])
      }),
    ),
    // One of them updated (or a runtime installed): { id }; the station put back to a release before it: { id, to }.
    route(
      "POST",
      "^\\/updates$",
      answer(async fn(r) {
        let asked = input(r)
        let id = match asked.get("id") {
          Some(Str(s)) => s
          _ => ""
        }
        let to = match asked.get("to") {
          None => None
          Some(Str(t)) => Some(t)
          Some(_) => raise Refused(400, self.tr(r.lang, "station.updates.badVersion"))
        }
        match asked.get("repair") {
          Some(Bool(true)) if id == "codex" =>
            self.backend.tell("updates.repairCodex", [js(r.lang)])
          None | Some(Bool(false)) =>
            self.backend.tell(
              "updates.update",
              match to {
                None => [js(id), js(r.lang)]
                Some(t) => [js(id), js(r.lang), js(t)]
              },
            )
          _ =>
            raise Refused(
              400,
              self.tr(r.lang, "station.updates.codexRepairUnavailable"),
            )
        }
      }),
    ),
  ]
}

///|
async fn Admin::workspaces_view(self : Admin, r : Request) -> JV {
  let manages = manages_station(r.viewer)
  let ws = r.who("workspace").unwrap_or(jundef)
  let listed = jitems(Some(self.backend.ask("cloud.memberships", [])))
    .filter(m => manages || m.get("workspace").unwrap_or(jundef) == ws)
    .map(m => {
      jobj([
        ("workspace", m.get("workspace").unwrap_or(jundef)),
        ("workspaceName", m.get("workspace_name").unwrap_or(jundef)),
        ("name", m.get("name").unwrap_or(jundef)),
        ("home", m.get("home").unwrap_or(jundef)),
      ]).filter_undef()
    })
  jobj([("workspaces", jarr(listed)), ("canJoin", jbool(manages))])
}

///|
fn Admin::workspaces_routes(self : Admin) -> Array[Route] {
  [
    route("GET", "^\\/workspaces$", async fn(r, _) {
      ok(self.workspaces_view(r))
    }),
    route("POST", "^\\/workspaces\\/join$", async fn(r, _) {
      if !manages_station(r.viewer) {
        return error(
          403, "only the owners and admins of this station's workspaces add it to another workspace",
        )
      }
      let given = match body_or_empty(r) {
        None => return error(400, "invalid JSON")
        Some(v) => v
      }
      let token = field_of(Some(given), "token")
      let lock = field_of(Some(given), "lock")
      guard token is Some(Str(token)) && token != "" else {
        return error(400, "token is required")
      }
      match lock {
        None | Some(Null) => ()
        Some(Str(l)) if re("^[0-9a-f]{64}$").matches(l) => ()
        _ => return error(400, "lock: a lock's hash")
      }
      try {
        let joined = self.backend.ask("cli.joinWorkspace", [
          js(self.setup.data.unwrap_or("")),
          js(token),
          match lock {
            Some(Str(_) as l) => l
            _ => jundef
          },
          jobj([("cloud", jref("cloud"))]),
        ])
        self.backend.tell("cloud.reload", [jbool(true)])
        self.overview_changed()
        let shown = jobj([
          ("workspace", joined.get("workspace").unwrap_or(jundef)),
          ("workspaceName", joined.get("workspace_name").unwrap_or(jundef)),
          ("name", joined.get("name").unwrap_or(jundef)),
        ]).filter_undef()
        ok(jspread(jobj([("joined", shown)]), self.workspaces_view(r)))
      } catch {
        e => {
          // Joined, the lock it keeps there left as it is: what it is in now is read again.
          if thrown_as(e, "KeptLock") is Some(_) {
            self.backend.tell("cloud.reload", [jbool(true)])
            self.overview_changed()
          }
          error(409, message_of(e))
        }
      }
    }),
  ]
}

///|
fn copies_body(r : Request) -> JV? {
  match body_or_empty(r) {
    None => None
    Some(Null) => Some(Obj([]))
    v => v
  }
}

///|
fn Admin::copies_routes(self : Admin) -> Array[Route] {
  let managers = "only the workspace's owners and admins retire a station"
  let bus_refused = (e : Error) => {
    error(
      if thrown_as(e, "mesh/bus.Refused") is Some(_) {
        409
      } else {
        500
      },
      message_of(e),
    )
  }
  let ws = (r : Request) => r.who("workspace").unwrap_or(jundef)
  [
    route("POST", "^\\/retire$", async fn(r, _) {
      if !manages_station(r.viewer) {
        return error(403, managers)
      }
      if !self.setup.has("retire.starts") {
        return error(409, self.tr(r.lang, "station.retire.off"))
      }
      guard field_of(copies_body(r), "to") is Some(Str(to)) else {
        return error(400, "to is needed: the station the chats go to")
      }
      self.backend.tell("retire.retire", [ws(r), js(to), js(r.email())]) catch {
        e => return bus_refused(e)
      }
      ok(jobj([("retiring", jbool(true))]), status=202)
    }),
    route("GET", "^\\/retire\\/preview$", async fn(r, _) {
      if !manages_station(r.viewer) {
        return error(403, managers)
      }
      ok(self.backend.ask("retire.preview", [ws(r)])) catch {
        e => error(500, message_of(e))
      }
    }),
    route("DELETE", "^\\/retire$", async fn(r, _) {
      if !manages_station(r.viewer) {
        return error(403, managers)
      }
      self.backend.tell("retire.cancel", [ws(r)]) catch {
        e => return bus_refused(e)
      }
      ok(jobj([("ok", jbool(true))]))
    }),
    route("POST", "^\\/retire\\/again$", async fn(r, _) {
      if !manages_station(r.viewer) {
        return error(403, managers)
      }
      self.backend.tell("retire.again", [ws(r)]) catch {
        e => return bus_refused(e)
      }
      ok(jobj([("ok", jbool(true))]), status=202)
    }),
    route("POST", "^\\/copies\\/restore$", async fn(r, _) {
      if !manages_station(r.viewer) {
        return error(
          403, "only the workspace's owners and admins restore a lost station's chats",
        )
      }
      let b = copies_body(r)
      let from = field_of(b, "from")
      guard field_of(b, "station") is Some(Str(station)) &&
        field_of(b, "gen") is Some(Str(gen)) &&
        field_of(from, "station") is Some(Str(from_station)) else {
        return error(400, "station, gen and from: {station} are needed")
      }
      // (it goes on as the copy is brought; how far it is, the station's settings show)
      self.later(async fn() {
        self.backend.tell("copies.restore", [
          ws(r),
          js(station),
          js(gen),
          jobj([("station", js(from_station))]),
        ])
      })
      ok(jobj([("restoring", jbool(true))]), status=202)
    }),
  ]
}

///|
fn Admin::xshare_routes(self : Admin) -> Array[Route] {
  let answer = async fn(f : async () -> JV) -> Answer {
    if !self.setup.has("agents.xshare") || !self.setup.has("store") {
      return error(503, "station starting")
    }
    ok(f()) catch {
      e =>
        match refused_of(e) {
          Some((status, message)) => error(status, message)
          None => error(400, message_of(e))
        }
    }
  }
  let str = (v : JV?) => {
    match v {
      Some(Str(s)) => js(s)
      _ => js("")
    }
  }
  [
    // Which other workspaces a chat is shared with (by its session key); `to: []` stops.
    route("PUT", "^\\/*sessions\\/+([^/]+)\\/+xshare(?:\\/.*)?$", async fn(
      r,
      m,
    ) {
      answer(async fn() {
        let key = segment(m[0].unwrap())
        // Its own chat on the pages, else the Slack thread it is in.
        let home = if self.store("getSession", [js(key)]) is Null {
          JV::Null
        } else {
          let own = self.store("homeChat", [js(key)])
          if !nullish(own) {
            own
          } else {
            match
              jitems(Some(self.store("sessionThreads", [js(key), jint(1)]))).get(
                0,
              ) {
              Some(t) =>
                match t.get("thread") {
                  Some(v) if !nullish(v) => v
                  _ => Null
                }
              None => Null
            }
          }
        }
        if home is Null {
          raise Refused(404, "no chat \{key} on this station")
        }
        if home.get("createdBy") != Some(js(r.email())) &&
          !manages_station(r.viewer) {
          raise Refused(
            403, "only the chat's starter or a workspace owner or admin may share it",
          )
        }
        let i = input(r)
        guard i.get("to") is Some(Arr(to)) else {
          raise Refused(400, "to: [{workspace, name, stations: [{id, name}]}]")
        }
        let targets = to.map(t => {
          jobj([
            ("workspace", str(field_of(Some(t), "workspace"))),
            ("name", str(field_of(Some(t), "name"))),
            ("stations", field_of(Some(t), "stations").unwrap_or(jundef)),
          ]).filter_undef()
        })
        let shared = self.backend.ask("xshare.share", [
          js(key),
          jarr(targets),
          jbool(i.get("write") is Some(Bool(true))),
          js(r.email()),
        ])
        jobj([("xshare", shared)])
      })
    }),
    // This workspace takes chats from that station of another workspace.
    route("PUT", "^\\/*xshare\\/+hosts(?:\\/.*)?$", async fn(r, _) {
      answer(async fn() {
        let i = input(r)
        self.backend.tell("xshare.trust", [
          str(i.get("workspace")),
          str(i.get("name")),
          str(i.get("station")),
          str(i.get("stationName")),
          if r.who("home") is Some(Bool(false)) {
            r.who("workspace").unwrap_or(jundef)
          } else {
            jundef
          },
        ])
        jobj([("ok", jbool(true))])
      })
    }),
  ]
}

///|
fn Admin::links_routes(self : Admin) -> Array[Route] {
  [
    route("GET", "^\\/link-preview$", async fn(r, _) {
      let url = r.param("url").unwrap_or("")
      if !re("^https?:\\/\\/", flags="i").matches(url) || url.length() > 4096 {
        return error(400, "an http(s) url is required")
      }
      let found = self.backend.ask("links/preview.linkPreview", [js(url)])
      ok(if nullish(found) { jobj([("kind", js("none"))]) } else { found })
    }),
  ]
}

///|
fn Admin::overview_routes(self : Admin) -> Array[Route] {
  [route("GET", "^\\/overview$", async fn(r, _) { ok(self.overview_of(r)) })]
}
