// A rig's forms (client/core-ts/src/rig-form.ts): what its person's device signs for it (a grant, one taken back, the
// settings, the rig taken into a workspace, made whole again, a device attached), their shapes, and the bytes signed
// for each: its tag, a NUL, then the SHA-256 of its body's canonical JSON (stillfail/rules/form `canonical`).

///|
pub let timeout_min : Double = 60.0

///|
pub let timeout_max : Double = 2592000.0

///|
/// `FULL_FOR`: how long a word that the rig is whole again holds (seconds).
pub let full_for : Double = 3600.0

///|
/// `TIMEOUT_DEFAULT`.
pub fn timeout_default() -> Json {
  jobj([("kind", jstr("idle")), ("seconds", jnum(3600.0))])
}

///|
let timeout_words : String = "timeout must be idle or fixed, in whole minutes from 1 minute to 30 days"

///|
/// Why `t` is no timeout a grant may have, or None: idle or fixed, whole minutes, a minute to 30 days.
pub fn timeout_refusal(t : Json?) -> String? {
  if !is_objectish(t) {
    return Some(timeout_words)
  }
  let kind = str_at(t, "kind")
  if !(kind == Some("idle") || kind == Some("fixed")) {
    return Some(timeout_words)
  }
  match get(t, "seconds") {
    Some(Number(n, ..)) if safe_int(n) && n >= timeout_min && n <= timeout_max && n % 60.0 == 0.0 => None
    _ => Some(timeout_words)
  }
}

///|
fn tag_of(kind : String) -> String {
  match kind {
    "grant" => "stillfail-rig-grant/1"
    "revoke" => "stillfail-rig-revoke/1"
    "settings" => "stillfail-rig-settings/1"
    "add" => "stillfail-rig-add/1"
    "full" => "stillfail-rig-full/1"
    "device" => "stillfail-rig-device/1"
    "join" => "stillfail-rig-join/1"
    _ => "undefined"
  }
}

///|
/// What is signed for a statement of `kind`: raises where the body is no canonical value.
pub fn signed_bytes(kind : String, body : Json) -> Bytes raise @cloud_lock.Failure {
  let text = @cloud_lock.canonical(body)
  let digest = @cloud_lock.sha256(@cloud_lock.utf8_of(text))
  let tag = @cloud_lock.utf8_of(tag_of(kind) + "\u0000")
  let out = @buffer.new(size_hint=tag.length() + digest.length())
  out.write_bytes(tag)
  out.write_bytes(digest)
  out.to_bytes()
}

///|
fn text_ok(v : Json?, max~ : Int = 512) -> Bool {
  match v {
    Some(String(s)) => s.length() <= max
    _ => false
  }
}

///|
fn time_ok(v : Json?) -> Bool {
  match v {
    Some(Number(n, ..)) => safe_int(n) && n >= 0.0
    _ => false
  }
}

///|
fn hex32_at(v : Json?) -> Bool {
  match v {
    Some(String(s)) => is_hex_text(s, 64)
    _ => false
  }
}

///|
/// `DEVICE_ID`: 16 hex digits.
pub fn device_id_ok(s : String) -> Bool {
  is_hex_text(s, 16)
}

///|
fn common_ok(b : Json?) -> Bool {
  is_objectish(b) &&
  (match get(b, "v") {
    Some(Number(n, ..)) => n == 1.0
    _ => false
  }) &&
  text_ok(get(b, "sub")) &&
  str_at(b, "sub") != Some("") &&
  text_ok(get(b, "ws"), max=64) &&
  str_at(b, "ws") != Some("") &&
  hex32_at(get(b, "rig")) &&
  time_ok(get(b, "at"))
}

///|
fn alnum_dot_dash(c : Int) -> Bool {
  (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x2e || c == 0x2d
}

///|
fn hex_colon_dot(c : Int) -> Bool {
  (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46) || c == 0x3a || c == 0x2e
}

///|
/// `^[1-9][0-9]{0,4}$`.
fn port_text(s : String) -> Bool {
  if s.length() < 1 || s.length() > 5 {
    return false
  }
  for i in 0..<s.length() {
    let c = s.unsafe_charcode_at(i)
    if c < 0x30 || c > 0x39 || (i == 0 && c == 0x30) {
      return false
    }
  }
  true
}

///|
/// `/^(\[[0-9a-fA-F:.]+\]|[A-Za-z0-9.-]+):([1-9][0-9]{0,4})$/`.
fn tcp_target(t : String) -> Bool {
  if t.length() > 0 && t.unsafe_charcode_at(0) == 0x5b {
    let mut i = 1
    while i < t.length() && hex_colon_dot(t.unsafe_charcode_at(i)) {
      i += 1
    }
    if i == 1 || i >= t.length() || t.unsafe_charcode_at(i) != 0x5d {
      return false
    }
    if i + 1 >= t.length() || t.unsafe_charcode_at(i + 1) != 0x3a {
      return false
    }
    port_text(t.unsafe_substring(start=i + 2, end=t.length()))
  } else {
    let mut i = 0
    while i < t.length() && alnum_dot_dash(t.unsafe_charcode_at(i)) {
      i += 1
    }
    if i == 0 || i >= t.length() || t.unsafe_charcode_at(i) != 0x3a {
      return false
    }
    port_text(t.unsafe_substring(start=i + 1, end=t.length()))
  }
}

///|
/// `/^COM[0-9]+$/`.
fn com_port(t : String) -> Bool {
  if t.length() < 4 || !t.has_prefix("COM") {
    return false
  }
  for i in 3..<t.length() {
    let c = t.unsafe_charcode_at(i)
    if c < 0x30 || c > 0x39 {
      return false
    }
  }
  true
}

///|
/// Why `d` is no device, or None: a name, a kind, and a target of that kind (an adb serial, `host:port`, a path).
pub fn device_refusal(d : Json?) -> String? {
  guard is_objectish(d) && (match str_at(d, "id") { Some(id) => device_id_ok(id); None => false }) else {
    return Some("a device has an id of 16 hex digits")
  }
  if !text_ok(get(d, "name"), max=80) || js_trim(str_at(d, "name").unwrap_or("")) == "" {
    return Some("a device has a name, up to 80 characters")
  }
  let kind = str_at(d, "kind")
  if !(kind == Some("adb") || kind == Some("tcp") || kind == Some("serial")) {
    return Some("kind: adb, tcp or serial")
  }
  let target = str_at(d, "target").unwrap_or("")
  let spaced = {
    let mut found = false
    for i in 0..<target.length() {
      let c = target.unsafe_charcode_at(i)
      if js_space(c) || c == 0 {
        found = true
        break
      }
    }
    found
  }
  if !text_ok(get(d, "target"), max=256) || js_trim(target) == "" || spaced {
    return Some("target: what it is reached at, with no spaces")
  }
  if kind == Some("tcp") && !tcp_target(target) {
    return Some("a tcp device's target is host:port")
  }
  if kind == Some("tcp") {
    let port = match target.rev_find(":") {
      Some(i) => target.unsafe_substring(start=i + 1, end=target.length())
      None => target
    }
    let mut n = 0.0
    for i in 0..<port.length() {
      n = n * 10.0 + (port.unsafe_charcode_at(i) - 0x30).to_double()
    }
    if n > 65535.0 {
      return Some("a tcp device's port is 1 to 65535")
    }
  }
  if kind == Some("serial") && !target.has_prefix("/") && !com_port(target) {
    return Some("a serial device's target is its path (/dev/…) or COMn")
  }
  match get(d, "baud") {
    None => None
    Some(Number(n, ..)) if safe_int(n) && n >= 50.0 && n <= 4000000.0 => None
    Some(_) => Some("baud: 50 to 4000000")
  }
}

///|
/// Whether `signed` has the shape of a statement of `kind` (its signature is checked by who takes it).
pub fn well_formed(kind : String, signed : Json?) -> Bool {
  if !is_objectish(signed) {
    return false
  }
  let sig = get(signed, "sig")
  if !is_objectish(sig) || !text_ok(get(sig, "key"), max=200) || !text_ok(get(sig, "sig"), max=200) {
    return false
  }
  let b = get(signed, "body")
  if !common_ok(b) {
    return false
  }
  match kind {
    "grant" => {
      let device_ok = match get(b, "device") {
        None => true
        Some(String(d)) => device_id_ok(d)
        _ => false
      }
      hex32_at(get(b, "station")) &&
      text_ok(get(b, "session"), max=256) &&
      str_at(b, "session") != Some("") &&
      text_ok(get(b, "chat"), max=256) &&
      text_ok(get(b, "request"), max=128) &&
      str_at(b, "request") != Some("") &&
      text_ok(get(b, "title")) &&
      text_ok(get(b, "by")) &&
      timeout_refusal(get(b, "timeout")) is None &&
      time_ok(get(b, "exp")) &&
      num_at(b, "exp").unwrap_or(0.0) > num_at(b, "at").unwrap_or(0.0) &&
      num_at(b, "exp").unwrap_or(0.0) - num_at(b, "at").unwrap_or(0.0) <= timeout_max &&
      device_ok
    }
    "revoke" => text_ok(get(b, "request"), max=128) && str_at(b, "request") != Some("")
    "settings" => {
      let device_ok = match get(b, "device") {
        None => true
        Some(String(d)) => device_id_ok(d)
        _ => false
      }
      time_ok(get(b, "seq")) && bool_at(b, "open") is Some(_) && device_ok
    }
    "device" => device_refusal(get(b, "device")) is None && bool_at(b, "removed") is Some(_)
    // (`lock`: an entry of the workspace's lock to pin, rig-form.ts `AddBody`)
    "add" => get(b, "lock") is None || hex32_at(get(b, "lock"))
    "full" => true
    "join" =>
      text_ok(get(b, "token"), max=256) &&
      str_at(b, "token") != Some("") &&
      (get(b, "lock") is None || hex32_at(get(b, "lock")))
    _ => false
  }
}

///|
/// Until when a grant signed at `at` holds at the latest: a fixed one its length, an idle one 30 days.
pub fn latest(at : Double, timeout : Json?) -> Double {
  at +
  (if str_at(timeout, "kind") == Some("fixed") {
    num_at(timeout, "seconds").unwrap_or(0.0)
  } else {
    timeout_max
  })
}

///|
/// Whether `signed`'s signature is its key's over its body, as a statement of `kind` (rig/grants.ts `signatureHolds`).
pub fn signature_holds(crypto : @cloud_lock.Crypto, kind : String, signed : Json?) -> Bool {
  let sig = get(signed, "sig")
  let hex = str_at(sig, "sig").unwrap_or("")
  if !hex_pairs(hex) {
    return false
  }
  let key = match get(sig, "key") {
    Some(String(k)) => k
    _ => return false
  }
  let body = get(signed, "body").unwrap_or(Json::null())
  try crypto.signature_ok(key, @cloud_lock.hex_bytes(hex), signed_bytes(kind, body)) catch {
    _ => false
  }
}
