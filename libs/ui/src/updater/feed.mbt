// Release feed parsing, Ed25519 signature verification, URL resolution, and delta selection.

///|
#derive(Eq, Debug)
pub(all) struct RawArtifact {
  sha256 : String
  size : Int64
}

///|
#derive(Eq, Debug)
pub(all) struct FeedDelta {
  from : Int
  file : String
  sha256 : String
  size : Int64
}

///|
#derive(Eq, Debug)
pub(all) struct SignedBlock {
  key : String
  release : String
  signature : String
}

///|
#derive(Eq, Debug)
pub(all) struct ReleaseFeed {
  version : String
  version_code : Int
  file : String
  sha256 : String
  size : Int64
  raw : RawArtifact?
  deltas : Array[FeedDelta]
  signed : SignedBlock?
}

///|
fn is_lower_hex64(s : String) -> Bool {
  if s.length() != 64 {
    return false
  }
  for i in 0..<64 {
    let c = s.unsafe_get(i).to_int()
    let ok = (c >= 48 && c <= 57) || (c >= 97 && c <= 102)
    if !ok {
      return false
    }
  }
  true
}

///|
fn is_safe_rel_path(path : String) -> Bool {
  if path.length() == 0 || path.has_prefix("/") {
    return false
  }
  for i in 0..<path.length() {
    let c = path.unsafe_get(i).to_int()
    let ok = (c >= 65 && c <= 90) ||
      (c >= 97 && c <= 122) ||
      (c >= 48 && c <= 57) ||
      c == 46 ||
      c == 95 ||
      c == 47 ||
      c == 45
    if !ok {
      return false
    }
  }
  for seg in path.split("/") {
    let s = seg.to_owned()
    if s == "" || s == ".." {
      return false
    }
  }
  true
}

///|
fn path_basename(path : String) -> String {
  match path.rev_find("/") {
    Some(i) => path.exact_view(start=i + 1).to_owned()
    None => path
  }
}

///|
fn json_str(obj : Map[String, Json], key : String) -> String? {
  match obj.get(key) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn json_pos_int64(obj : Map[String, Json], key : String) -> Int64? {
  match obj.get(key) {
    Some(Number(n, ..)) => {
      let i = n.to_int64()
      if n > 0.0 && i.to_double() == n && i < 9007199254740992L {
        Some(i)
      } else {
        None
      }
    }
    _ => None
  }
}

///|
fn json_pos_int(obj : Map[String, Json], key : String) -> Int? {
  match json_pos_int64(obj, key) {
    Some(i) if i <= 2147483647L => Some(i.to_int())
    _ => None
  }
}

///|
fn parse_raw_artifact(v : Json) -> RawArtifact? {
  match v {
    Object(obj) =>
      match (json_str(obj, "sha256"), json_pos_int64(obj, "size")) {
        (Some(sha), Some(sz)) if is_lower_hex64(sha) =>
          Some({ sha256: sha, size: sz })
        _ => None
      }
    _ => None
  }
}

///|
fn parse_signed_block(v : Json) -> SignedBlock? {
  match v {
    Object(obj) =>
      match (
        json_str(obj, "key"),
        json_str(obj, "release"),
        json_str(obj, "signature"),
      ) {
        (Some(key), Some(release), Some(signature)) if key != "" &&
          release != "" &&
          signature != "" => Some({ key, release, signature })
        _ => None
      }
    _ => None
  }
}

///|
/// Parse and validate a `latest.json` release feed.
pub fn parse_feed(json_text : String) -> Result[ReleaseFeed, String] {
  let root : Json = @json.parse(json_text) catch {
    _ => return Err("feed is not valid JSON")
  }
  let obj = match root {
    Object(m) => m
    _ => return Err("feed must be a JSON object")
  }
  let version = match json_str(obj, "version") {
    Some(s) if s != "" => s
    _ => return Err("feed missing valid version")
  }
  let version_code = match json_pos_int(obj, "versionCode") {
    Some(n) => n
    None => return Err("feed missing positive versionCode")
  }
  let file = match json_str(obj, "file") {
    Some(s) if is_safe_rel_path(s) => s
    _ => return Err("feed missing safe relative file path")
  }
  let sha256 = match json_str(obj, "sha256") {
    Some(s) if is_lower_hex64(s) => s
    _ => return Err("feed missing valid 64-hex sha256")
  }
  let size = match json_pos_int64(obj, "size") {
    Some(n) => n
    None => return Err("feed missing positive size")
  }
  let raw = match obj.get("raw") {
    Some(v) => parse_raw_artifact(v)
    None => None
  }
  let deltas : Array[FeedDelta] = []
  match obj.get("deltas") {
    Some(Array(items)) =>
      for item in items {
        match item {
          Object(d) =>
            match (
              json_pos_int(d, "from"),
              json_str(d, "file"),
              json_str(d, "sha256"),
              json_pos_int64(d, "size"),
            ) {
              (Some(from), Some(dfile), Some(dsha), Some(dsize)) =>
                deltas.push({ from, file: dfile, sha256: dsha, size: dsize })
              _ => ()
            }
          _ => ()
        }
      }
    _ => ()
  }
  let signed = match obj.get("signed") {
    Some(v) => parse_signed_block(v)
    None => None
  }
  Ok({ version, version_code, file, sha256, size, raw, deltas, signed })
}

///|
/// Verify a parsed feed's Ed25519 signature against `public_keys_b64`.
/// Returns the signed `raw` artifact metadata (if present in the signed payload).
pub fn verify_feed(
  feed : ReleaseFeed,
  public_keys_b64 : Array[String],
  expected_kind? : String = "",
) -> Result[RawArtifact?, String] {
  let signed = match feed.signed {
    Some(s) => s
    None => return Err("release is not signed")
  }
  let mut matched_pk : Bytes? = None
  for k in public_keys_b64 {
    match @codec.from_base64_exact(k) {
      Some(raw_pk) if raw_pk.length() == 32 && key_id(raw_pk) == signed.key => {
        matched_pk = Some(raw_pk)
        break
      }
      _ => ()
    }
  }
  let pk = match matched_pk {
    Some(p) => p
    None => return Err("release is signed by an untrusted key (\{signed.key})")
  }
  let release_bytes = match @codec.from_base64_exact(signed.release) {
    Some(b) => b
    None => return Err("signed release payload is not valid base64")
  }
  let sig_bytes = match @codec.from_base64_exact(signed.signature) {
    Some(b) => b
    None => return Err("signed signature is not valid base64")
  }
  if !verify_ed25519(pk, release_bytes, sig_bytes) {
    return Err("release signature verification failed")
  }
  let release_text = @utf8.decode_lossy(release_bytes[:])
  let r_json : Json = @json.parse(release_text) catch {
    _ => return Err("signed release payload is not valid JSON")
  }
  let r = match r_json {
    Object(m) => m
    _ => return Err("signed release payload must be a JSON object")
  }
  if expected_kind != "" {
    match json_str(r, "kind") {
      Some(k) if k == expected_kind => ()
      _ => return Err("signed release kind mismatch")
    }
  }
  match json_pos_int(r, "build") {
    Some(b) if b == feed.version_code => ()
    _ => return Err("signed release build does not match feed versionCode")
  }
  let base_file = path_basename(feed.file)
  match json_str(r, "file") {
    Some(f) if f == base_file => ()
    _ => return Err("signed release file does not match feed file")
  }
  match json_str(r, "sha256") {
    Some(s) if s == feed.sha256 => ()
    _ => return Err("signed release sha256 does not match feed sha256")
  }
  match json_pos_int64(r, "size") {
    Some(sz) if sz == feed.size => ()
    _ => return Err("signed release size does not match feed size")
  }
  let signed_raw = match r.get("raw") {
    Some(v) => parse_raw_artifact(v)
    None => None
  }
  Ok(signed_raw)
}

///|
/// Join `base_url` and a relative `file` path without duplicate slashes.
pub fn resolve_url(base_url : String, file : String) -> String {
  let mut b = base_url
  while b.has_suffix("/") {
    b = b.exact_view(end=b.length() - 1).to_owned()
  }
  let mut f = file
  while f.has_prefix("/") {
    f = f.exact_view(start=1).to_owned()
  }
  if b == "" {
    f
  } else if f == "" {
    b
  } else {
    b + "/" + f
  }
}

///|
fn json_escape(s : String) -> String {
  let sb = StringBuilder(capacity=s.length() + 2)
  sb.write_char('"')
  for c in s {
    match c {
      '"' => sb.write_string("\\\"")
      '\\' => sb.write_string("\\\\")
      '\n' => sb.write_string("\\n")
      '\r' => sb.write_string("\\r")
      '\t' => sb.write_string("\\t")
      _ => sb.write_char(c)
    }
  }
  sb.write_char('"')
  sb.to_string()
}

///|
/// Select the delta from `current_build` and format the JSON expected by `@hostapi.update_fetch`.
/// Returns `""` if no valid smaller delta is available.
pub fn pick_delta_json(
  feed : ReleaseFeed,
  current_build : Int,
  base_url : String,
  signed_raw? : RawArtifact? = None,
  use_signed_raw? : Bool = false,
) -> String {
  let makes = if use_signed_raw {
    signed_raw
  } else {
    match feed.raw {
      Some(r) => Some(r)
      None => Some({ sha256: feed.sha256, size: feed.size })
    }
  }
  let target = match makes {
    Some(m) if is_lower_hex64(m.sha256) && m.size > 0L => m
    _ => return ""
  }
  for d in feed.deltas {
    if d.from == current_build &&
      is_safe_rel_path(d.file) &&
      is_lower_hex64(d.sha256) &&
      d.size > 0L &&
      d.size < feed.size {
      let url = resolve_url(base_url, d.file)
      return "{\"url\":" +
        json_escape(url) +
        ",\"sha256\":" +
        json_escape(d.sha256) +
        ",\"size\":" +
        d.size.to_string() +
        ",\"makes_sha256\":" +
        json_escape(target.sha256) +
        ",\"makes_size\":" +
        target.size.to_string() +
        "}"
    }
  }
  ""
}
