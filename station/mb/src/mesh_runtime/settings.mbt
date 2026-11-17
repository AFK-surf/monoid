// The mesh's settings and how its endpoint is bound (station/src/mesh/settings.ts, mesh.ts `applyNetwork`,
// native.ts `bindStation`): the congestion controller a station's config chooses (an absent choice keeps the stable
// default), followed on a running endpoint for the connections made from then on; and what the station's
// environment adds to a bind: a fixed UDP address (`STILLFAIL_MESH_BIND_ADDR`) and the DSCP every iroh packet of it is
// marked with (`STILLFAIL_MESH_DSCP`, #6871), anything not a number refused here, one outside 1 to 63 by the bind
// itself (the shell's `iroh.bind`, the addon's): never a station silently unmarked.

///|
/// `congestionOf`: "bbr" where the config says so, else "cubic".
pub fn congestion_of(raw : Json?) -> String {
  match raw {
    Some(Object(m)) =>
      match m.get("network") {
        Some(Object(n)) if n.get("congestion") is Some(String("bbr")) => "bbr"
        _ => "cubic"
      }
    _ => "cubic"
  }
}

///|
/// `checkNetwork`: why the config's `network` (None: not said) is refused, None where it is taken.
pub fn check_network(raw : Json?) -> String? {
  match raw {
    None | Some(Null) => None
    Some(Object(m)) =>
      match m.get("congestion") {
        None | Some(String("cubic")) | Some(String("bbr")) => None
        Some(_) => Some("network.congestion: expected cubic or bbr")
      }
    Some(_) => Some("network: expected an object")
  }
}

///|
/// `networkView`.
pub fn network_view(raw : Json?) -> Json {
  jobj([("congestion", jstr(congestion_of(raw)))])
}

///|
/// The congestion controller a running endpoint is on, followed as the config changes (`applyNetwork`).
pub struct NetworkFollow {
  mut congestion : String
  /// Sets the endpoint's (`Endpoint.setCongestion`); what it raises is said, the endpoint left as it was.
  set : (String) -> Unit raise
  said : (String, String, Json) -> Unit
}

///|
/// Following the config as it is now; `said`: a line of the log (level, words, what with them).
pub fn NetworkFollow::new(
  raw : Json?,
  set : (String) -> Unit raise,
  said : (String, String, Json) -> Unit,
) -> NetworkFollow {
  { congestion: congestion_of(raw), set, said }
}

///|
/// The config changed (its whole text, read again).
pub fn NetworkFollow::told(self : NetworkFollow, raw : Json?) -> Unit {
  let next = congestion_of(raw)
  if next == self.congestion {
    return
  }
  self.congestion = next
  (self.set)(next) catch {
    e =>
      (self.said)("warn", "congestion controller not changed", jobj([("error", jstr(message_of(e)))]))
  }
  (self.said)("info", "congestion controller for new connections", jobj([("congestion", jstr(next))]))
}

///|
/// An error's words, as `(e as Error).message` has them.
pub fn message_of(e : Error) -> String {
  match e {
    Failure(m) => m
    _ => @door.message_of(e)
  }
}

///|
/// Whether `s` is 1 to 3 ASCII digits (`/^[0-9]{1,3}$/`).
fn dscp_word(s : String) -> Bool {
  let n = s.length()
  if n < 1 || n > 3 {
    return false
  }
  for i in 0..<n {
    if !is_digit(s.code_unit_at(i).to_int()) {
      return false
    }
  }
  true
}

///|
/// The bind of the station's endpoint (`bindStation`): `options` with the station's environment's address and DSCP
/// added, the variables as the process has them (None: not set). What is no DSCP fails with the words the TypeScript
/// says; one outside 1..=63 is the bind's own refusal.
pub fn bind_station(options : Json, bind_addr : String?, dscp : String?) -> Json raise Failure {
  if dscp is Some(d) && !dscp_word(d) {
    raise Failure("STILLFAIL_MESH_DSCP must be a DSCP, 1 to 63, not \{js_quote(d)}")
  }
  let m : Map[String, Json] = Map([])
  if options is Object(o) {
    for k, v in o {
      m[k] = v
    }
  }
  // (`bindAddr: undefined` is said by no JSON)
  match bind_addr {
    Some(a) => m["bindAddr"] = jstr(a)
    None => m.remove("bindAddr")
  }
  if dscp is Some(d) {
    m["dscp"] = jnum(js_number(d))
  }
  Json::object(m)
}

///|
/// Whether a bind's DSCP is one the bind takes (the shell's `mark_with_dscp`: 1 to 63; none said is none).
pub fn dscp_taken(dscp : Json?) -> Bool {
  match dscp {
    None | Some(Null) => true
    Some(Number(n, ..)) => js_is_integer(n) && n >= 1.0 && n <= 63.0
    _ => false
  }
}
