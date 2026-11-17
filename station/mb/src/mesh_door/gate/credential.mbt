// A member's credential, checked offline (station/src/mesh/credential.ts): an EdDSA JWT the control plane signed with
// one of the workspace's grant keys, for this workspace and the device at the other end, unexpired and not revoked.
// Which issuer and type it bears is the provider's (`Accepted`: still.fail cloud's unless told otherwise). The
// signature is checked by what the program is given (`Verify`: the shell's `crypto.verify`).

///|
/// `lock_device`: the device's base key and its proof for this endpoint, as its hello gave them. `home`: whether
/// `workspace` is the station's home one, as of the request (None: yes). `lock_id`: the device's id in the lock that
/// let it in, else its base key as its proof holds.
pub(all) struct Viewer {
  sub : String
  email : String
  name : String
  role : String
  workspace : String
  device : String
  lock_device : (String, String)?
  home : Bool?
  lock_id : String?
}

///|
pub(all) struct Admitted {
  viewer : Viewer
  exp : Int64
  iat : Int64
  sid : String
}

///|
pub(all) struct Revocation {
  kind : String
  id : String
  at : Int64
}

///|
/// Which member credentials a station takes.
pub(all) struct Accepted {
  issuers : Array[String]
  types : Array[String]
}

///|
pub let stillfail_credential : Accepted = {
  issuers: ["stillfail-cloud"],
  types: ["stillfail-member+jwt"],
}

///|
/// Whether `sig` is the Ed25519 key's (32 bytes) over `message`.
pub type Verify = (Bytes, Bytes, Bytes) -> Bool

///|
pub(all) suberror Refused {
  Refused(String)
}

///|
pub fn refused_words(e : Error) -> String? {
  match e {
    Refused(m) => Some(m)
    _ => None
  }
}

///|
/// base64url (no padding) decoded; None where it is not.
pub fn b64url(s : String) -> Bytes? {
  let t = s.replace_all(old="-", new="+").replace_all(old="_", new="/")
  let pad = match t.length() % 4 {
    2 => "=="
    3 => "="
    _ => ""
  }
  Some(@base64.decode(t + pad)) catch {
    _ => None
  }
}

///|
fn json_of_b64(s : String) -> Json? {
  match b64url(s) {
    Some(b) => Some(@json.parse(@utf8.decode_lossy(b))) catch { _ => None }
    None => None
  }
}

///|
fn text_of(claims : Json, k : String) -> String {
  match claims {
    Object(m) => match m.get(k) { Some(String(s)) => s; _ => "" }
    _ => ""
  }
}

///|
/// A non-negative integer of JSON, as `Number.isInteger(x) && x >= 0`.
fn whole_of(v : Json?) -> Int64? {
  match v {
    Some(Number(n, ..)) => if n == n.floor() && n.abs() < 9.0e15 { Some(n.to_int64()) } else { None }
    _ => None
  }
}

///|
/// The member a credential says, checked: of `workspace`, for `device`, signed by one of `keys` (a JWKS), unexpired at
/// `now` (unix seconds) and not revoked. Raises `Refused` why not.
pub fn verify_member(
  credential : String,
  keys : Json,
  workspace : String,
  device : String,
  revocations : Array[Revocation],
  now : Int64,
  verify : Verify,
  accepted? : Accepted = stillfail_credential,
) -> Admitted raise Refused {
  let parts = credential.split(".").map(p => p.to_owned()).collect()
  if parts.length() != 3 {
    raise Refused("malformed credential")
  }
  let (head, body, sig) = (parts[0], parts[1], parts[2])
  let header = match json_of_b64(head) {
    Some(h) => h
    None => raise Refused("malformed credential")
  }
  let typ = match header { { "typ": String(t), .. } => t; _ => "" }
  if !(header is { "alg": "EdDSA", .. }) || !accepted.types.contains(typ) {
    raise Refused("not a member's credential")
  }
  let kid = match header { { "kid": String(k), .. } => Some(k); _ => None }
  let list = match keys { { "keys": Array(a), .. } => a; _ => [] }
  let jwk = list.iter().find_first(k => match kid {
    None => true
    Some(id) => k is { "kid": String(x), .. } && x == id
  })
  guard jwk is Some(jwk) else { raise Refused("unknown credential key") }
  let x = match jwk { { "x": String(x), .. } => b64url(x); _ => None }
  let ok = match (x, b64url(sig)) {
    (Some(key), Some(s)) => key.length() == 32 && s.length() == 64 && verify(@utf8.encode("\{head}.\{body}"), key, s)
    _ => false
  }
  if !ok {
    raise Refused("credential signature invalid")
  }
  let claims = match json_of_b64(body) {
    Some(c) => c
    None => raise Refused("malformed credential")
  }
  if !accepted.issuers.contains(text_of(claims, "iss")) {
    raise Refused(
      if physical_equal(accepted, stillfail_credential) {
        "credential not issued by still.fail cloud"
      } else {
        "credential not issued by the control plane"
      },
    )
  }
  if text_of(claims, "ws") != workspace {
    raise Refused("credential is for another workspace")
  }
  if text_of(claims, "device") != device {
    raise Refused("credential is for another device")
  }
  let field = (k : String) => match claims { Object(m) => m.get(k); _ => None }
  let exp = match whole_of(field("exp")) { Some(e) if e >= 0L => e; _ => 0L }
  if exp <= now {
    raise Refused("credential expired")
  }
  let iat = match field("iat") {
    Some(Number(n, ..)) if n == n.floor() && n.abs() < 9.0e15 => n.to_int64()
    _ => 0L
  }
  let admitted : Admitted = {
    viewer: {
      sub: text_of(claims, "sub"),
      email: text_of(claims, "email"),
      name: text_of(claims, "name"),
      role: text_of(claims, "role"),
      workspace: text_of(claims, "ws"),
      device,
      lock_device: None,
      home: None,
      lock_id: None,
    },
    exp,
    iat,
    sid: text_of(claims, "sid"),
  }
  if revoked(admitted, revocations) {
    raise Refused("credential revoked")
  }
  admitted
}

///|
/// One workspace the station is in, as a credential is checked against it.
pub(all) struct Membership {
  workspace : String
  revocations : Array[Revocation]
}

///|
/// The workspace a credential names, as it says (unchecked).
pub fn claimed_ws(credential : String) -> String {
  let parts = credential.split(".").map(p => p.to_owned()).collect()
  match json_of_b64(parts.get(1).unwrap_or("")) {
    Some({ "ws": String(ws), .. }) => ws
    _ => ""
  }
}

///|
/// A credential for any of the workspaces the station is in, checked as `verify_member` does against that workspace's
/// revocations, with that workspace's keys (`keys` of it).
pub fn verify_member_of(
  credential : String,
  keys : (String) -> Json,
  memberships : Array[Membership],
  device : String,
  now : Int64,
  verify : Verify,
  accepted? : Accepted = stillfail_credential,
) -> Admitted raise Refused {
  let ws = claimed_ws(credential)
  let of = match memberships.iter().find_first(m => m.workspace == ws) {
    Some(m) => Some(m)
    None => memberships.get(0)
  }
  let workspace = match of { Some(m) => m.workspace; None => "" }
  verify_member(
    credential,
    keys(workspace),
    workspace,
    device,
    match of { Some(m) => m.revocations; None => [] },
    now,
    verify,
    accepted~,
  )
}

///|
/// Roles that may read but not write.
pub let read_only_roles : Array[String] = ["viewer"]

///|
pub fn read_only(role : String) -> Bool {
  read_only_roles.contains(role)
}

///|
/// Who manages the station itself: an owner or admin of any workspace it is in.
pub fn manages_station(role : String) -> Bool {
  role == "owner" || role == "admin"
}

///|
/// Taken back: its account's (`sub`) or session's (`sid`) credentials issued up to `at`.
pub fn revoked(admitted : Admitted, revocations : Array[Revocation]) -> Bool {
  revocations.iter().any(r => admitted.iat <= r.at &&
    ((r.kind == "sub" && r.id == admitted.viewer.sub) || (r.kind == "sid" && r.id == admitted.sid)))
}

///|
/// A viewer as the TypeScript says one (only what it has).
pub fn Viewer::to_json(self : Viewer) -> Json {
  let m : Map[String, Json] = {
    "sub": Json::string(self.sub),
    "email": Json::string(self.email),
    "name": Json::string(self.name),
    "role": Json::string(self.role),
    "workspace": Json::string(self.workspace),
    "device": Json::string(self.device),
  }
  if self.lock_device is Some((base, proof)) {
    m["lockDevice"] = { "base": Json::string(base), "proof": Json::string(proof) }
  }
  if self.home is Some(h) {
    m["home"] = Json::boolean(h)
  }
  if self.lock_id is Some(id) {
    m["lockId"] = Json::string(id)
  }
  Json::object(m)
}

///|
pub fn Viewer::from_json(j : Json) -> Viewer {
  let s = (k : String) => match j { Object(m) => match m.get(k) { Some(String(v)) => v; _ => "" }; _ => "" }
  {
    sub: s("sub"),
    email: s("email"),
    name: s("name"),
    role: s("role"),
    workspace: s("workspace"),
    device: s("device"),
    lock_device: match j {
      { "lockDevice": { "base": String(b), "proof": String(p), .. }, .. } => Some((b, p))
      _ => None
    },
    home: match j { { "home": True, .. } => Some(true); { "home": False, .. } => Some(false); _ => None },
    lock_id: match j { { "lockId": String(id), .. } => Some(id); _ => None },
  }
}

///|
pub fn Admitted::to_json(self : Admitted) -> Json {
  {
    "viewer": self.viewer.to_json(),
    "exp": Json::number(self.exp.to_double()),
    "iat": Json::number(self.iat.to_double()),
    "sid": Json::string(self.sid),
  }
}

///|
pub fn Admitted::from_json(j : Json) -> Admitted {
  let n = (k : String) => match j { Object(m) => match m.get(k) { Some(Number(v, ..)) => v.to_int64(); _ => 0L }; _ => 0L }
  {
    viewer: Viewer::from_json(match j { { "viewer": v, .. } => v; _ => Json::null() }),
    exp: n("exp"),
    iat: n("iat"),
    sid: match j { { "sid": String(s), .. } => s; _ => "" },
  }
}

///|
pub fn Viewer::with_role(self : Viewer, role : String) -> Viewer {
  { ..self, role, }
}
