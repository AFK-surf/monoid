// relays (station/src/tools/relays.ts): the agents' hand on the relays of their chat's workspace (mesh/ways.ts):
// listed, added, taken away. Nobody approves a relay (the user, 2026-11-11); one is added only once this station
// reached it as a relay. What the ways keep is mesh/ways.ts's (`addRelay`, `removeRelay`, `relayUrl`, `stillFails`;
// a refusal `WaysRefusal`), the ways themselves `relays.ways` (null before the station is in a workspace), whose
// `view` and `cloud` are parts.

///|
pub let max_own_relays : Int = 4

///|
/// What reaching a relay found: it answered as one (its round trip), or why it is none.
pub(all) enum Probed {
  Reached(Double)
  Not(String)
}

///|
/// Whether `url` is a relay this station reaches (relays.ts `probeRelay`): its https answers `/ping` (twice, the
/// second timed) and refuses `/relay` asked without the relay's handshake. Each ask is `fetch` (`{status}`), the clock
/// `ops/fibers.wall.now`.
pub async fn probe_relay(b : ToolsBackend, url : String) -> Probed {
  let mut end = url.length()
  while end > 0 && url.unsafe_charcode_at(end - 1) == '/' {
    end -= 1
  }
  let base = slice(url, 0, to=end)
  let status = (r : JV) => match r.get("status") {
    Some(Num(n)) => n
    _ => 0.0
  }
  try {
    let first = b.ask("fetch", [js("\{base}/ping")])
    let s = status(first)
    if !(s >= 200.0 && s <= 299.0) {
      return Not("\{base}/ping answered \{num_text(s)}: not a relay")
    }
    let start = jnumber(Some(b.ask("ops/fibers.wall.now", []))).unwrap_or(0.0)
    ignore(b.ask("fetch", [js("\{base}/ping")]))
    let ms = jnumber(Some(b.ask("ops/fibers.wall.now", []))).unwrap_or(0.0) - start
    let relay = b.ask("fetch", [js("\{base}/relay")])
    let rs = status(relay)
    if rs != 400.0 && rs != 426.0 {
      return Not(
        "\{base}/relay answered \{num_text(rs)}, not a relay's refusal of a plain request",
      )
    }
    Reached(ms)
  } catch {
    e => {
      let said = match e {
        @api_routes.Thrown(_, said) => Some(said)
        _ => None
      }
      let cause = jget(said, "cause")
      let why = match jget(cause, "code") {
        Some(c) if !(c is Null) && !is_undef(c) => js_string(Some(c))
        _ =>
          match jget(cause, "message") {
            Some(m) if !(m is Null) && !is_undef(m) => js_string(Some(m))
            _ => message_of(e)
          }
      }
      Not("\{base} not reached from this station: \{why}")
    }
  }
}

///|
/// The tool: the ways (`ways`), the workspace a session is in (`workspaceOf`), who a session's change is said to be by
/// (`by`), which optional mesh callbacks are present (`mesh_list`, `enroll`, `revoke`), and how a relay is reached
/// (`probe`: none, `probe_relay`).
pub fn relay_tools(
  c : Ctx,
  deps? : String = "relays",
  mesh_list? : Bool = false,
  enroll? : Bool = false,
  revoke? : Bool = false,
  probe? : (async (String) -> Probed)? = None,
) -> Array[Tool] {
  let b = c.b
  let probe = match probe {
    Some(p) => p
    None => url => probe_relay(b, url)
  }
  let decl = c.decl("relays")
  [
    Tool::new(decl, (session, args, _) => {
      let ways = b.ask("\{deps}.ways", [])
      let ws = b.ask("\{deps}.workspaceOf", [js(session)])
      if ways is Null || !truthy(Some(ws)) {
        raise Failed("this station is in no workspace")
      }
      let ways_ref = ref_of(ways).unwrap_or("ways")
      let cloud = jref("\{ways_ref}.cloud")
      let action = args.get("action")
      let list = async fn() -> Array[(String, JV)] {
        let v = b.ask("\{ways_ref}.view", [ws])
        let still = b.ask("mesh/ways.stillFails", [cloud])
        [
          ("workspace", ws),
          ("own", field(v, "relays")),
          ("still_fail", still),
          ("off", field(v, "off")),
        ]
      }
      if action is Some(Str("list")) {
        let fields = list()
        if mesh_list {
          fields.push(("mesh", b.ask("\{deps}.meshList", [ws])))
        }
        return stringify(jobj(fields))
      }
      if action is Some(Str("revoke")) {
        if !revoke {
          raise Failed("mesh relay revocation is not available on this station")
        }
        let node = match args.get("node") {
          Some(Str(node)) if node.length() == 64 &&
            node.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) => node
          _ => raise Failed("node must be a mesh relay public key from list")
        }
        return stringify(b.ask("\{deps}.revoke", [ws, js(node)]))
      }
      if action is Some(Str("enroll")) {
        if !enroll {
          raise Failed("mesh relay enrollment is not available on this station")
        }
        let name = match args.get("name") {
          Some(Str(name)) => name
          _ => raise Failed("name is required for mesh relay enrollment")
        }
        return stringify(b.ask("\{deps}.enroll", [
          ws, js(name), b.ask("\{deps}.by", [js(session)]),
        ]))
      }
      let raw = text(args.get("url"))
      if action is Some(Str("add")) {
        let origin = match b.ask("\{ways_ref}.cloud.state", []) {
          Obj(_) as s if !is_undef(s) =>
            match s.get("origin") {
              Some(Str(o)) => o
              _ => ""
            }
          _ => ""
        }
        let url = match
          @cloud_net.relay_url(
            Json::string(raw),
            insecure=origin.has_prefix("http:"),
          ) {
          Some(u) => u
          None =>
            raise Failed(
              "url: https://host[:port][/path], with no account, query or fragment",
            )
        }
        let ms = match probe(url) {
          Not(why) => raise Failed("not added: \{why}")
          Reached(ms) => ms
        }
        b.tell("mesh/ways.addRelay", [
          ways,
          ws,
          js(url),
          b.ask("\{deps}.by", [js(session)]),
        ]) catch {
          e =>
            match thrown_as(e, "WaysRefusal") {
              Some(_) => raise Failed("not added: \{message_of(e)}")
              None => raise e
            }
        }
        return stringify(
          jobj([("added", js(url)), ("round_trip_ms", jnum(ms)), ..list()]),
        )
      }
      if action is Some(Str("remove")) {
        b.tell("mesh/ways.removeRelay", [ways, ws, js(raw)]) catch {
          e =>
            match thrown_as(e, "WaysRefusal") {
              Some(_) => raise Failed("not removed: \{message_of(e)}")
              None => raise e
            }
        }
        let removed = match @cloud_net.relay_url(Json::string(raw), insecure=true) {
          Some(u) => js(u)
          None => js(raw)
        }
        return stringify(jobj([("removed", removed), ..list()]))
      }
      raise Failed("action: list, add, remove, enroll or revoke")
    }),
  ]
}
