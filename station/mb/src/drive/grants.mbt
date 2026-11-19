// What a station lets another one read of its drive for a member (grants.ts): a grant it signs when the member asks,
// which the member hands to the station the files go to. That station reads the files with it over the station
// transport (`drive.walk`, `drive.part`, `drive.release`), and this one checks its own signature, the workspace it was
// granted in, and that what is read is under the names granted, before it reads anything as that member would.
// A grant is a JavaScript object (its keys in the order it was made with), signed as JSON.stringify writes it.

///|
/// A grant is good for this long (grants.ts GRANT_MS).
pub let grant_ms : Double = 604800000.0

///|
/// Buffer's toString("base64url"): no padding.
pub fn base64url(b : Bytes) -> String {
  @codec.base64url_encode(b[:])
}

///|
/// Buffer.from(s, "base64url") (and "base64": both alphabets): what is no letter of them passed over, `=` ending it.
pub fn from_base64(s : String) -> Bytes {
  @codec.base64_decode_loose(s)
}

///|
fn unhex(s : String) -> Bytes {
  @codec.hex_decode(s).unwrap_or(b"")
}

///|
/// HMAC-SHA256 (RFC 2104).
pub fn hmac_sha256(key : Bytes, data : Bytes) -> Bytes {
  @hash.hmac_sha256(key[:], data[:])
}

///|
/// grants.ts `grantKey`: the station's key for its grants (`<data>/drive-grant.key`), made the first time.
pub fn grant_key(data : String) -> Bytes {
  let path = join([data, "drive-grant.key"])
  match attempt(() => read_all(path)) {
    Ok(k) if k.length() >= 32 => return k
    _ => ()
  }
  let key = random_bytes(32)
  write_private_bytes(path, key) catch {
    _ => ()
  }
  key
}

///|
/// grants.ts `sign`: the grant's JSON in base64url, `.`, its HMAC.
pub fn sign(key : Bytes, g : @jsjson.JValue) -> String {
  let body = base64url(@utf8.encode(@jsjson.stringify(g)))
  "\{body}.\{base64url(hmac_sha256(key, @utf8.encode(body)))}"
}

///|
fn jfield(v : @jsjson.JValue, name : String) -> @jsjson.JValue? {
  match v {
    Obj(_) => v.get(name)
    _ => None
  }
}

///|
/// A field of a JavaScript object as a string, where it is one.
pub fn jstr(v : @jsjson.JValue, name : String) -> String? {
  match jfield(v, name) {
    Some(Str(u)) => Some(@jsjson.sanitize_str(u))
    _ => None
  }
}

///|
pub fn jnum(v : @jsjson.JValue, name : String) -> Double? {
  match jfield(v, name) {
    Some(Num(n)) => Some(n)
    _ => None
  }
}

///|
pub fn jbool(v : @jsjson.JValue, name : String) -> Bool? {
  match jfield(v, name) {
    Some(Bool(b)) => Some(b)
    _ => None
  }
}

///|
/// JavaScript's truthiness of a field.
pub fn jtruthy(v : @jsjson.JValue, name : String) -> Bool {
  match jfield(v, name) {
    None | Some(Null) | Some(Bool(false)) => false
    Some(Num(n)) => n != 0.0 && n == n
    Some(Str(u)) => u.length() > 0
    _ => true
  }
}

///|
/// The names a grant gives (`names`), those that are strings.
pub fn grant_names(g : @jsjson.JValue) -> Array[String] {
  match jfield(g, "names") {
    Some(Arr(a)) => {
      let out = []
      for n in a {
        if n is Str(u) {
          out.push(@jsjson.sanitize_str(u))
        }
      }
      out
    }
    _ => []
  }
}

///|
/// grants.ts `verify`: what `grant` says, when this station signed it, it has not expired, and it was granted in
/// `workspace` (any where None).
pub fn verify(
  key : Bytes,
  grant : @jsjson.JValue?,
  workspace : String?,
  now : Double,
) -> @jsjson.JValue raise DriveError {
  let refuse = () => drive_error("permission", "that is not a grant of this station's")
  guard grant is Some(Str(u)) else { raise refuse() }
  let text = @jsjson.sanitize_str(u)
  let pieces = text.split(".").map(p => p.to_string()).to_array()
  let body = pieces[0]
  let sig = if pieces.length() > 1 { pieces[1] } else { "" }
  if body == "" || sig == "" {
    raise refuse()
  }
  let want = hmac_sha256(key, @utf8.encode(body))
  let got = from_base64(sig)
  if got != want {
    raise refuse()
  }
  let g = try @jsjson.parse(@utf8.decode_lossy(from_base64(body))) catch {
    _ => raise refuse()
  }
  if jnum(g, "v") != Some(1.0) || !(jfield(g, "names") is Some(Arr(_))) {
    raise refuse()
  }
  match jnum(g, "expires") {
    Some(e) if e < now => raise drive_error("permission", "that grant has expired")
    _ => ()
  }
  match workspace {
    Some(w) if jstr(g, "workspace") != Some(w) => raise refuse()
    _ => ()
  }
  g
}

///|
/// grants.ts `covers`: whether `path` (relative to the folder the names are in) is one of the names granted or under one.
pub fn covers(g : @jsjson.JValue, path : String) -> Bool {
  let parts = path.split("/").map(p => p.to_string()).to_array()
  grant_names(g).contains(parts[0]) &&
  !parts.iter().any(p => p == "" || p == "." || p == "..")
}
