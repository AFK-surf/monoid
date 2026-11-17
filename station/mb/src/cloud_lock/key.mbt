// The station's key (station/src/cloud/key.ts): <data>/mesh/secret.key, 32 raw bytes (an Ed25519 seed), made on first
// use; its public half, hex, the station's id; what it signs, signed by the shell (`ed25519.sign`). And what the
// station posts to its control plane signed with it (station/src/cloud/signed.ts).

///|
pub struct StationKey {
  seed : Bytes
  /// The station's id: its public key, hex.
  id : String
  priv host : @host.Host
}

///|
fn ed_sign(host : @host.Host, seed : Bytes, message : Bytes) -> (String, String) raise Failure {
  let answer = host.shell_sync("ed25519.sign", { "seed": Json::string(hex_of(seed)), "message": Json::string(hex_of(message)) }) catch {
    e => raise Failed(e.to_string())
  }
  match answer {
    { "publicKey": String(k), "signature": String(s), .. } => (k, s)
    { "error": String(e), .. } => raise Failed(e)
    _ => raise Failed("the shell signed nothing")
  }
}

///|
/// The key of a seed (key.ts `new StationKey`): raises where it is not 32 bytes.
pub fn StationKey::new(host : @host.Host, seed : Bytes) -> StationKey raise Failure {
  if seed.length() != 32 {
    raise Failed("the station's key is not 32 bytes")
  }
  let (id, _) = ed_sign(host, seed, b"")
  { seed, id, host }
}

///|
/// Signed, hex (key.ts `sign`): of the message's UTF-8.
pub fn StationKey::sign(self : StationKey, message : String) -> String raise Failure {
  ed_sign(self.host, self.seed, utf8_of(message)).1
}

///|
/// <data>/mesh.
pub fn mesh_dir(data : String) -> String {
  join([data, "mesh"])
}

///|
/// The station's key, made on first use (key.ts `loadKey`).
pub async fn load_key(host : @host.Host, data : String) -> StationKey raise Failure {
  let disk : Disk = { host, }
  let path = join([mesh_dir(data), "secret.key"])
  if disk.bytes(path) is Some(seed) {
    return StationKey::new(host, seed)
  }
  let random = host.shell_sync("crypto.random", { "bytes": 32 }) catch { e => raise Failed(e.to_string()) }
  guard random is String(h) else { raise Failed("no random bytes") }
  let seed = hex_bytes(h)
  disk.put(path, seed)
  StationKey::new(host, seed)
}

///|
/// What a request the station signs says of itself (signed.ts): the headers and the body.
pub(all) struct SignedRequest {
  url : String
  headers : Array[(String, String)]
  body : String
}

///|
/// The body's sha256 under "<tag>:<origin>:<station>:<ts>:<digest>", in the x-stillfail-* headers (signed.ts
/// `signedPost`), `ts` the station's clock (unix seconds); raises where the station is in no control plane (`name`
/// it).
pub fn signed_request(state : CloudState?, key : StationKey, path : String, tag : String, value : Json, ts : Double, name? : String = "still.fail cloud") -> SignedRequest raise Failure {
  guard state is Some(s) else { raise Failed("this station is not in \{name}") }
  let body = stringify(value)
  let t = ts.to_int64().to_string()
  let signature = key.sign("\{tag}:\{s.text("origin")}:\{s.text("station")}:\{t}:\{sha256_hex(body)}")
  {
    url: s.text("origin") + path,
    headers: [
      ("content-type", "application/json"),
      ("x-stillfail-station", s.text("station")),
      ("x-stillfail-ts", t),
      ("x-stillfail-signature", signature),
    ],
    body,
  }
}

///|
/// A signed POST through `request` (the caller's transport: its status and text), its answer as JSON (none for an
/// empty one); raises what the plane answered where it is no success (signed.ts `signedPost`).
pub async fn signed_post(
  state : CloudState?,
  key : StationKey,
  path : String,
  tag : String,
  value : Json,
  ts : Double,
  request : async (SignedRequest) -> (Int, String) raise,
  name? : String = "still.fail cloud",
) -> Json raise Failure {
  let r = signed_request(state, key, path, tag, value, ts, name~)
  let (status, text) = request(r) catch { e => raise Failed(e.to_string()) }
  if status < 200 || status > 299 {
    raise Failed("\{name} answered \{status}: \{text}")
  }
  if text == "" {
    return Json::null()
  }
  match parse(text) {
    Some(v) => v
    None => raise Failed("Unexpected token in JSON")
  }
}
