// Global bootstrap metadata only, as mesh/global-relays.ts reads it. Reject the
// whole frame before applying any roster, lock or persisted-state side effect.

///|
fn mesh_way(way : String) -> Bool {
  way.has_prefix("mesh:") && hex64(way.substring(start=5))
}

///|
fn mesh_ip_host(host : ArrayView[Char]) -> Bool {
  if host.iter().any(c => c == ':') {
    let mut end = host.length()
    for i in 0..<host.length() {
      if host[i] == '%' {
        end = i
        let zone = host[i + 1:]
        if zone.length() == 0 || !zone.iter().all(c =>
          is_alpha(c) || is_digit(c) || c == '-' || c == '.' || c == ':') {
          return false
        }
        break
      }
    }
    return ipv6_parse(host[:end]) is Some(_)
  }
  let parts = split_dots(host)
  parts.length() == 4 && parts.iter().all(part => {
    if part.length() == 0 || part.length() > 3 ||
      !part.iter().all(is_digit) || (part.length() > 1 && part[0] == '0') {
      return false
    }
    let mut value = 0
    for c in part { value = value * 10 + c.to_int() - '0'.to_int() }
    value <= 255
  })
}

///|
fn mesh_ip_address(raw : String) -> Bool {
  let cs = raw.to_array()
  let mut colon = -1
  for i in 0..<cs.length() { if cs[i] == ':' { colon = i } }
  if colon < 1 || colon + 1 == cs.length() { return false }
  let port = cs[colon + 1:]
  if !port.iter().all(is_digit) { return false }
  let mut value = 0
  for c in port {
    value = value * 10 + c.to_int() - '0'.to_int()
    if value > 65535 { return false }
  }
  if value == 0 { return false }
  let host = cs[:colon]
  if host[0] == '[' {
    host.length() > 2 && host[host.length() - 1] == ']' &&
      !host[1:host.length() - 1].iter().any(c => c == ']') &&
      mesh_ip_host(host[1:host.length() - 1])
  } else {
    !host.iter().any(c => c == ':') && mesh_ip_host(host)
  }
}

///|
fn global_mesh_relays(raw : Json?) -> Array[Json]? {
  if raw is None { return Some([]) }
  guard raw is Some(Array(rows)) && rows.length() <= 32 else { return None }
  let seen : Array[String] = []
  let out : Array[Json] = []
  for row in rows {
    guard text_of(field(row, "node")) is Some(node) && hex64(node) &&
      !seen.contains(node) else { return None }
    guard text_of(field(row, "name")) is Some(name) && name.to_array().length() <= 40
      else { return None }
    guard safe_int(field(row, "generation")) is Some(generation) && generation >= 1L
      else { return None }
    guard safe_int(field(row, "revision")) is Some(revision) && revision >= 1L
      else { return None }
    let address = field(row, "address").unwrap_or(Json::null())
    guard text_of(field(address, "id")) == Some(node) &&
      field(address, "addrs") is Some(Array(addrs)) && addrs.length() <= 8
      else { return None }
    seen.push(node)
    let normalized : Array[Json] = []
    for addr in addrs {
      guard addr is Object(fields) && fields.length() == 1 else { return None }
      match (fields.get("Ip"), fields.get("Relay")) {
        (Some(String(ip)), _) => {
          if !mesh_ip_address(ip) { return None }
          normalized.push({ "Ip": Json::string(ip) })
        }
        (_, Some(String(relay))) if relay.length() <= 2048 => {
          guard parse_url(relay) is Some(url) &&
            (url.scheme == "https" || url.scheme == "http") &&
            url.username == "" && url.password == "" &&
            url.query.unwrap_or("") == "" && url.fragment.unwrap_or("") == ""
            else { return None }
          normalized.push({ "Relay": Json::string(url.href()) })
        }
        _ => return None
      }
    }
    out.push({
      "node": Json::string(node), "name": Json::string(name),
      "generation": int_json(generation), "revision": int_json(revision),
      "address": { "id": Json::string(node), "addrs": Json::array(normalized) },
    })
  }
  Some(out)
}
