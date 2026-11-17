// Which control plane a station is enrolled in, and how each one is spoken to (station/src/cloud/provider.ts):
// still.fail cloud (the default, as it always was) or Comma. Only names, paths and signing tags differ; the scheme is
// one: Ed25519 over "<tag>:<origin>:<station>:<ts>[:<sha256 of the body>]" with the station's key, in x-<prefix>-*
// headers. cloud.json says which (`provider`, absent: still.fail).

///|
pub(all) enum Provider {
  Stillfail
  Comma
}

///|
pub let providers : Array[Provider] = [Stillfail, Comma]

///|
/// The provider cloud.json's `provider` says: `"comma"` is Comma, anything else still.fail.
pub fn provider_of(raw : Json?) -> Provider {
  match raw {
    Some(String("comma")) => Comma
    _ => Stillfail
  }
}

///|
pub fn Provider::name(self : Provider) -> String {
  match self {
    Stillfail => "stillfail"
    Comma => "comma"
  }
}

///|
/// Where traces and the log go, signed under each prefix's tag.
pub(all) struct Telemetry {
  path : String
  logs : String?
  prefixes : Array[String]
}

///|
/// Which member credentials a station takes.
pub(all) struct Accepted {
  issuers : Array[String]
  types : Array[String]
}

///|
pub(all) struct ProviderSpec {
  provider : Provider
  /// How it is named in logs and errors.
  name : String
  enroll_path : String
  enroll_prefixes : Array[String]
  join_path : String
  /// The presence WebSocket.
  connect_path : String
  connect_prefixes : Array[String]
  notify_path : String
  notify_tag : String
  /// None: the provider takes none.
  telemetry : Telemetry?
  /// `stations` appended to the origin where releases are under it (Comma's), none: the origin itself.
  release_under : String?
  credential : Accepted
  feedback : Bool
  pages : Bool
  tools : Bool
}

///|
pub let stillfail_spec : ProviderSpec = {
  provider: Stillfail,
  name: "still.fail cloud",
  enroll_path: "/v1/stations/enroll",
  enroll_prefixes: ["stillfail"],
  join_path: "/v1/stations/join",
  connect_path: "/v1/stations/connect",
  connect_prefixes: ["stillfail"],
  notify_path: "/v1/stations/notify",
  notify_tag: "stillfail-station-notify-v1",
  telemetry: Some({
    path: "/v1/telemetry/traces",
    logs: Some("/v1/telemetry/logs"),
    prefixes: ["stillfail"],
  }),
  release_under: None,
  credential: { issuers: ["stillfail-cloud"], types: ["stillfail-member+jwt"] },
  feedback: true,
  pages: true,
  tools: false,
}

///|
/// The Comma control plane (contract v1, §1–3, §6–7).
pub let comma_spec : ProviderSpec = {
  provider: Comma,
  name: "Comma",
  enroll_path: "/v1/comma/stations/enroll",
  enroll_prefixes: ["comma"],
  join_path: "/v1/comma/stations/join",
  connect_path: "/v1/comma/stations/connect",
  connect_prefixes: ["comma"],
  notify_path: "/v1/comma/stations/notify",
  notify_tag: "comma-station-notify-v1",
  // Comma takes no station traces yet (its tag, comma-station-telemetry-v1, is reserved).
  telemetry: None,
  release_under: Some("/stations"),
  credential: { issuers: ["comma"], types: ["comma-member+jwt"] },
  feedback: false,
  pages: false,
  tools: true,
}

///|
pub fn spec_of(provider : Provider) -> ProviderSpec {
  match provider {
    Comma => comma_spec
    Stillfail => stillfail_spec
  }
}

///|
/// Where releases are: `<base>/releases/station.json` and `<base>/install.sh`.
pub fn ProviderSpec::release_base(self : ProviderSpec, origin : String) -> String {
  match self.release_under {
    Some(under) => origin + under
    None => origin
  }
}

///|
/// Headers in the order they were first set (a JavaScript object's), a name set again keeping its place.
pub(all) struct Headers {
  pairs : Array[(String, String)]
}

///|
pub fn Headers::new() -> Headers {
  { pairs: [] }
}

///|
pub fn Headers::set(self : Headers, name : String, value : String) -> Unit {
  for i, p in self.pairs {
    if p.0 == name {
      self.pairs[i] = (name, value)
      return
    }
  }
  self.pairs.push((name, value))
}

///|
pub fn Headers::get(self : Headers, name : String) -> String? {
  for p in self.pairs {
    if p.0 == name {
      return Some(p.1)
    }
  }
  None
}

///|
pub fn Headers::to_json(self : Headers) -> Json {
  let m : Map[String, Json] = Map([])
  for p in self.pairs {
    m[p.0] = Json::string(p.1)
  }
  Json::object(m)
}

///|
/// The x-<prefix>-* headers of a request signed by `prefixes`: the station, the time, and each prefix's own signature
/// of `sign(prefix)`. The signing scheme every provider shares; Comma reads the still.fail header names (contract §1),
/// so its signature goes in them.
pub fn signed_headers(
  prefixes : Array[String],
  station : String,
  ts : Int64,
  sign : (String) -> String,
  extra? : Array[(String, String)] = [],
) -> Headers {
  let headers = Headers::new()
  for prefix in prefixes {
    let h = if prefix == "comma" { "stillfail" } else { prefix }
    headers.set("x-\{h}-station", station)
    headers.set("x-\{h}-ts", ts.to_string())
    headers.set("x-\{h}-signature", sign(prefix))
    for kv in extra {
      headers.set("x-\{h}-\{kv.0}", kv.1)
    }
  }
  headers
}
