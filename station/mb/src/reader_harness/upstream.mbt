// Line-delimited JSON harness (`--builder harness-upstream`) for station/test/mb-upstream-corpora.test.ts.
// Runs official upstream test corpora (JSONTestSuite, Node path, WPT URL, Wycheproof, PNGSuite)
// directly against MoonBit replacements.

///|
fn u_string_of_u16(arr : Array[Json]) -> String {
  let sb = StringBuilder::new(size_hint=arr.length())
  for x in arr {
    match x {
      Number(n, ..) => sb.write_char(n.to_int().unsafe_to_char())
      _ => ()
    }
  }
  sb.to_string()
}

///|
fn u_url_json(u : @cloud_net.Url) -> Json {
  {
    "href": Json::string(u.href()),
    "origin": Json::string(u.origin()),
    "protocol": Json::string(u.scheme + ":"),
    "username": Json::string(u.username),
    "password": Json::string(u.password),
    "hostname": Json::string(u.hostname()),
    "port": Json::string(match u.port { Some(p) => p.to_string(); None => "" }),
    "pathname": Json::string(u.path),
    "search": Json::string(u.search()),
    "hash": Json::string(u.hash()),
  }
}

///|
async fn upstream_eval(host : @host.Host, ask : Json) -> Json {
  let op = std_str(ask, "op")
  match op {
    "json.parse_u16" => {
      let s = match std_at(ask, "u16") {
        Some(Array(xs)) => u_string_of_u16(xs)
        _ => std_str(ask, "raw")
      }
      try {
        let v = @jsjson.parse(s)
        { "ok": Json::boolean(true), "out": Json::string(@jsjson.stringify(v)) }
      } catch {
        e => { "ok": Json::boolean(false), "err": Json::string(e.to_string()) }
      }
    }
    "path.join" => Json::string(@nodepath.join(std_str(ask, "sep"), std_strs(ask, "parts")))
    "path.dirname" => Json::string(@nodepath.dirname(std_str(ask, "sep"), std_str(ask, "path")))
    "path.basename" => Json::string(@nodepath.basename(std_str(ask, "sep"), std_str(ask, "path")))
    "path.is_absolute" => Json::boolean(@nodepath.is_absolute(std_str(ask, "sep"), std_str(ask, "path")))
    "path.with_extension" =>
      Json::string(@nodepath.with_extension(std_str(ask, "sep"), std_str(ask, "path"), std_str(ask, "ext")))
    "path.relative_parts" =>
      match @nodepath.relative_parts(std_str(ask, "sep"), std_str(ask, "path")) {
        Some(parts) => Json::array(parts.map(Json::string(_)))
        None => Json::null()
      }
    "url.parse" =>
      match @cloud_net.parse_url(std_str(ask, "raw")) {
        Some(u) => u_url_json(u)
        None => Json::null()
      }
    "url.encode_uri_component" => Json::string(@url.encode_uri_component(std_str(ask, "s")))
    "url.encode_uri_component_strict" => std_opt_str(@url.encode_uri_component_strict(std_str(ask, "s")))
    "url.encode_uri" => Json::string(@url.encode_uri(std_str(ask, "s")))
    "url.decode_uri_component" => std_opt_str(@url.decode_uri_component(std_str(ask, "s")))
    "url.percent_decode_lossy" => {
      let plus = match std_at(ask, "plus_space") {
        Some(True) => true
        _ => false
      }
      Json::string(@url.percent_decode_lossy(std_str(ask, "s"), plus_space=plus))
    }
    _ => @station_main.upstream_op(host, ask)
  }
}

///|
async fn harness_upstream(host : @host.Host) -> Unit {
  while host.line() is Some(line) {
    if line == "" {
      continue
    }
    let ask = @json.parse(line) catch { _ => Json::null() }
    let id = std_at(ask, "id").unwrap_or(Json::null())
    let value = upstream_eval(host, ask)
    host.say(Json::object({ "id": id, "value": value }).stringify())
  }
}
