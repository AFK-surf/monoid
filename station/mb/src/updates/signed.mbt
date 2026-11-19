// signed.ts: the station's releases are signed (scripts/release-sign.ts): what still.fail cloud serves as
// releases/station.json (station-beta.json) carries, beside the version it always said, `release`: the release's own
// words (its build, and the sha256 and size of each platform's archive and of the Node binary each runs on), and
// `signature`: Ed25519 over those words' bytes, by the key `key` names. A station updates only to a release whose words
// verify, and only to a newer build than its own (back to the stable channel from the beta excepted, which a person
// asks for).

///|
/// A key's name in what it signed: the first 16 hex digits of the sha256 of its raw bytes.
pub fn key_id(raw : String) -> String {
  slice(sha256_hex(base64_bytes(raw)), 0, end=16)
}

///|
/// `trustedKeys(env)`: the keys this station takes, by id (release_keys, and STILLFAIL_RELEASE_KEYS' comma-separated
/// ones: a test's own releases').
pub fn trusted_keys(env_keys : String?) -> Array[(String, String)] {
  let all = release_keys.filter(k => !starts_with(k, "__"))
  for k in split(env_keys.unwrap_or(""), ",") {
    let t = trim(k)
    if t != "" {
      all.push(t)
    }
  }
  let out : Array[(String, String)] = []
  for k in all {
    let id = key_id(k)
    match out.search_by(p => p.0 == id) {
      Some(i) => out[i] = (id, k)
      None => out.push((id, k))
    }
  }
  out
}

///|
/// JavaScript's `String(v)` of a JSON value (what a RegExp's `test` makes of what it is given).
pub fn js_string(j : J) -> String {
  @jsjson.jval_js_str(Some(j))
}

///|
/// `String(v)` of a value that may be absent (`undefined`).
fn js_string_opt(j : J?) -> String {
  match j {
    Some(v) => js_string(v)
    None => "undefined"
  }
}

///|
/// `SHA.test(v ?? "")`.
fn sha_test(j : J?) -> Bool {
  match j {
    None | Some(Null) => false
    Some(v) => is_sha(js_string(v))
  }
}

///|
fn unverified(message : String) -> Error {
  thrown("Unverified", message)
}

///|
/// The words `signed` carries (`release`, base64), once its `signature` verifies by the key `key` names, one of
/// `trusted`. Raises Unverified otherwise.
pub async fn verify_signed(w : World, signed : J, trusted : Array[(String, String)]) -> J {
  let (release, signature) = match (get(Some(signed), "release"), get(Some(signed), "signature")) {
    (Some(Str(r)), Some(Str(s))) => (@jsjson.sanitize_str(r), @jsjson.sanitize_str(s))
    _ => raise unverified("the release is not signed")
  }
  let k = get(Some(signed), "key")
  let key = match k {
    Some(Str(u)) =>
      match trusted.search_by(p => p.0 == @jsjson.sanitize_str(u)) {
        Some(i) => Some(trusted[i].1)
        None => None
      }
    _ => None
  }
  guard key is Some(key) else {
    raise unverified("the release is signed by a key this station does not take (\{js_string_opt(k)})")
  }
  let words = base64_bytes(release)
  let good = (w.verify)(base64_bytes(key), base64_bytes(signature), words) catch {
    _ => false
  }
  if !good {
    raise unverified("the release's signature does not verify")
  }
  parse(utf8_text(words)) catch {
    _ => raise unverified("the release's words are not JSON")
  }
}

///|
/// `/^0\.\d+\.<build>$/` of `version`.
fn version_says(version : String, build : String) -> Bool {
  if !starts_with(version, "0.") || !ends_with(version, "." + build) {
    return false
  }
  let mid = slice(version, 2, end=version.length() - build.length() - 1)
  all_digits(mid)
}

///|
/// The builds of a release's words as pairs (Object.entries: an array's by its indices).
fn entries(j : J) -> Array[(String, J)] {
  match j {
    Obj(ps) => ps.map(p => (@jsjson.sanitize_str(p.0), p.1))
    Arr(xs) => xs.mapi((i, x) => (i.to_string(), x))
    _ => []
  }
}

///|
/// The release a feed says, verified: its signature by one of the keys, its words well formed and the version they
/// say the one the feed says. Raises Unverified otherwise.
pub async fn verify_feed(w : World, feed_said : J, trusted : Array[(String, String)]) -> J {
  let r = verify_signed(w, feed_said, trusted)
  let builds = get(Some(r), "builds")
  let well = (get(Some(r), "kind") is Some(Str(u)) && @jsjson.sanitize_str(u) == "stillfail-station-release") &&
    (get(Some(r), "version") is Some(Str(_))) &&
    is_safe_integer(get(Some(r), "build")) &&
    (builds is Some(Obj(_)) || builds is Some(Arr(_)))
  if !well {
    raise unverified("the release's words are not a station release")
  }
  let version = text(get(Some(r), "version")).unwrap()
  let build = num_text(num(get(Some(r), "build")).unwrap())
  let fed = get(Some(feed_said), "version")
  let feed_differs = match fed {
    None => false
    Some(Str(u)) => @jsjson.sanitize_str(u) != version
    Some(_) => true
  }
  if !version_says(version, build) || feed_differs {
    raise unverified("the feed's version is not the signed one")
  }
  for e in entries(builds.unwrap()) {
    let (p, b) = e
    let bad = "the release's \{p} build is not well formed"
    if !sha_test(get(Some(b), "sha256")) || !sha_test(get(Some(b), "nodeSha256")) || !is_safe_integer(get(Some(b), "size")) {
      raise unverified(bad)
    }
    // The raw form's words, said together or not at all.
    let raw_sha = get(Some(b), "rawSha256")
    let raw_size = get(Some(b), "rawSize")
    if (raw_sha is Some(_) || raw_size is Some(_)) &&
      (!sha_test(raw_sha) || !is_safe_integer(raw_size) || num(raw_size).unwrap() < 0.0) {
      raise unverified(bad)
    }
  }
  r
}

///|
/// A release's build number.
pub fn release_build(r : J) -> Double {
  num(get(Some(r), "build")).unwrap_or(0.0)
}

///|
pub fn release_version(r : J) -> String {
  text(get(Some(r), "version")).unwrap_or("")
}

///|
/// Whether going from the release built `current` (from `installed`'s channel) to `release` on `channel` is allowed:
/// a newer build, the same one again, or an older one only back from the beta to the stable channel.
pub fn allowed(release : J, current : Double?, channel : String, installed : String?) -> Bool {
  match current {
    None => true
    Some(c) =>
      if release_build(release) >= c {
        true
      } else {
        channel == "stable" && installed == Some("beta")
      }
  }
}

///|
/// What the installer is told to check, for this machine's build of `release`.
pub fn expected(release : J, platform : String?) -> J raise {
  let b = match platform {
    Some(p) =>
      match get(Some(release), "builds") {
        Some(Obj(_) as o) => o.get(p)
        Some(Arr(xs)) => {
          let i = (try @string.parse_int(p) catch { _ => -1 })
          if i >= 0 && i < xs.length() && i.to_string() == p {
            Some(xs[i])
          } else {
            None
          }
        }
        _ => None
      }
    None => None
  }
  if !truthy(b) {
    raise unverified("the release has no build for \{platform.unwrap_or("this machine")}")
  }
  b.unwrap()
}

///|
pub fn sha256(b : Bytes) -> String {
  sha256_hex(b)
}
