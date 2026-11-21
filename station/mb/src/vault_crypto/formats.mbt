// The vault's formats (station/src/vault/crypto.ts, 实现约定): what is signed and by whom, the seal a key or secret is
// sent in, an item's ciphertext and the recovery key. The same bytes as the station's and the core's
// (station/test/fixtures/vault-vectors.json); which versions may follow which are the rules' (rules/src/vault, rules.mbt).

///|
/// What each kind of record is signed under.
pub let tag_box : String = "stillfail-vault-box/1"

///|
pub let tag_vault : String = "stillfail-vault/1"

///|
pub let tag_item : String = "stillfail-vault-item/1"

///|
pub let tag_grant : String = "stillfail-vault-grant/1"

///|
pub let tag_deny : String = "stillfail-vault-deny/1"

///|
pub let tag_browse : String = "stillfail-vault-browse/1"

///|
/// How long a grant lasts, shortest first: one use, an hour, or the chat until it is archived.
pub let scopes : Array[String] = ["once", "hour", "chat"]

///|
fn index_of(xs : Array[String], x : String) -> Int {
  for i, y in xs {
    if y == x {
      return i
    }
  }
  -1
}

///|
/// Whether a grant may last as long as `scope` for an item that allows `lasts` at most (None: any). `lasts` as JS reads
/// it: a value that is no scope allows nothing.
pub fn allows(lasts : Json?, scope : Json?) -> Bool {
  let at = match scope {
    Some(String(s)) => index_of(scopes, s)
    _ => -1
  }
  let most = match lasts {
    None | Some(Null) => 2
    Some(String(s)) => index_of(scopes, s)
    _ => -1
  }
  at >= 0 && at <= most
}

///|
/// The seal's context for a vault key, wrapped to a device or to the recovery key.
pub fn key_context(ws : String, vault : String, epoch : Int64) -> String {
  "stillfail-vault-key/1\u{0}\{ws}\u{0}\{vault}\u{0}\{epoch}"
}

///|
/// An item's ciphertext's additional data.
pub fn item_context(ws : String, vault : String, id : String, version : Int64, epoch : Int64) -> String {
  "stillfail-vault-item/1\u{0}\{ws}\u{0}\{vault}\u{0}\{id}\u{0}\{version}\u{0}\{epoch}"
}

///|
/// The seal's context for a secret granted to one request.
pub fn grant_context(ws : String, request : String) -> String {
  "stillfail-vault-grant/1\u{0}\{ws}\u{0}\{request}"
}

///|
/// The seal's context for a secret an agent asks to keep, sealed to one of its owner's devices.
pub fn save_context(ws : String, request : String) -> String {
  "stillfail-vault-save/1\u{0}\{ws}\u{0}\{request}"
}

///|
/// The record without its `sig`, as `const { sig: _, ...rest } = o` leaves it.
fn without_sig(o : Json) -> Json {
  match o {
    Object(m) => {
      let rest : Map[String, Json] = Map([])
      for k, v in m {
        if k != "sig" {
          rest[k] = v
        }
      }
      Json::object(rest)
    }
    _ => o
  }
}

///|
/// The bytes a record's signature is over: its tag, a NUL, then the SHA-256 (32 raw bytes) of the record without `sig`
/// in canonical form; refused for what has no canonical form (a number not a safe integer).
pub fn signed_bytes(c : Crypto, o : Json, tag : String) -> Bytes raise {
  let text = @form.canonical(without_sig(o))
  tagged(c, tag, text)
}

///|
fn tagged(c : Crypto, tag : String, text : String) -> Bytes raise Refused {
  let head = utf8(tag + "\u{0}")
  let sum = c.sha256(utf8(text))
  concat(head, sum)
}

///|
/// A signing key's algorithm and public bytes by its id (`ed25519:<hex>`, `p256:<base64url of the uncompressed point>`).
fn public_key(id : String) -> (String, Bytes)? {
  if id.has_prefix("ed25519:") {
    let h = id.unsafe_substring(start=8, end=id.length())
    if hex_of_length(h, 32) {
      return Some(("Ed25519", unhex(h)))
    }
  }
  if id.has_prefix("p256:") {
    let point = unb64(id.unsafe_substring(start=5, end=id.length()))
    if point.length() == 65 && point[0] == b'\x04' {
      return Some(("ES256", point))
    }
  }
  None
}

///|
/// Whether `sig` (`{key, alg, sig}`: Ed25519 in hex, ES256 as base64url P1363) is its key's over `bytes`.
pub fn sig_over(c : Crypto, sig : Json?, bytes : BytesView) -> Bool {
  guard sig is Some(Object(s)) else { return false }
  guard s.get("sig") is Some(String(sg)) else { return false }
  guard s.get("key") is Some(String(key)) else { return false }
  guard public_key(key) is Some((alg, pub_)) else { return false }
  guard s.get("alg") is Some(String(a)) && a == alg else { return false }
  let signature = if alg == "Ed25519" { unhex(sg) } else { unb64(sg) }
  c.verify(alg, pub_, signature, bytes)
}

///|
/// Whether `o.sig` is its key's signature over `o` under `tag` (which key may sign is the caller's to check).
pub fn signed_ok(c : Crypto, o : Json, tag : String) -> Bool {
  let sig = match o {
    Object(m) => m.get("sig")
    _ => None
  }
  let bytes = signed_bytes(c, o, tag) catch { _ => return false }
  sig_over(c, sig, bytes)
}

///|
/// Signs `o` (without its `sig`) under `tag` with the Ed25519 `seed`: the record with its `sig`. (The station signs
/// nothing of a vault's: this is for tests and the harness.)
pub fn sign_ed25519(c : Crypto, o : Json, tag : String, seed : BytesView) -> Json raise {
  let bytes = signed_bytes(c, o, tag)
  let signed = match (c.ask)("ed25519.sign", Json::object({ "seed": j(seed), "message": j(bytes) })) {
    Ok({ "publicKey": String(k), "signature": String(s), .. }) => (k, s)
    Ok(_) => raise Refused("ed25519.sign: no signature")
    Err(e) => raise Refused("ed25519.sign: \{e}")
  }
  let m : Map[String, Json] = Map([])
  match without_sig(o) {
    Object(rest) => for k, v in rest { m[k] = v }
    _ => ()
  }
  m["sig"] = Json::object({ "key": Json::string("ed25519:" + signed.0), "alg": Json::string("Ed25519"), "sig": Json::string(signed.1) })
  Json::object(m)
}

///|
/// A box key's raw bytes from `x25519:<hex>`; None when it is not one.
pub fn box_bytes(pub_ : String) -> Bytes? {
  guard pub_.has_prefix("x25519:") && hex_of_length(pub_.unsafe_substring(start=7, end=pub_.length()), 32) else {
    return None
  }
  Some(unhex(pub_.unsafe_substring(start=7, end=pub_.length())))
}

///|
/// The public half of a raw X25519 private key, as `x25519:<hex>`.
pub fn box_public(c : Crypto, sk : BytesView) -> String raise Refused {
  "x25519:" + hex(c.x25519_public(sk))
}

///|
/// A fresh box key pair: its public half (`x25519:<hex>`) and its private 32 bytes.
pub fn new_box_pair(c : Crypto) -> (String, Bytes) raise Refused {
  let sk = c.random(32)
  (box_public(c, sk), sk)
}

///|
let seal_info : String = "stillfail-vault-seal/1"

///|
let nonce0 : Bytes = Bytes::make(12, b'\x00')

///|
fn concat(a : BytesView, b : BytesView) -> Bytes {
  let out : Array[Byte] = []
  for x in a {
    out.push(x)
  }
  for x in b {
    out.push(x)
  }
  Bytes::from_array(out)
}

///|
fn seal_key(c : Crypto, shared : BytesView, eph : BytesView, to : BytesView) -> Bytes raise Refused {
  c.hkdf(shared, concat(eph, to), utf8(seal_info), 32)
}

///|
/// `plain` sealed to the box key `pub_` under `context`, with this ephemeral private key (tests pin it; else random):
/// the ephemeral public half, then ChaCha20-Poly1305 under HKDF(X25519, eph ‖ to) with a nonce of zeros, base64url.
pub fn seal_with(c : Crypto, pub_ : String, plain : BytesView, context : String, eph : BytesView) -> String raise Refused {
  guard box_bytes(pub_) is Some(to) else { raise Refused("not an x25519 key") }
  let eph_pub = c.x25519_public(eph)
  let shared = c.x25519(eph, to)
  let body = c.chacha_seal(seal_key(c, shared, eph_pub, to), nonce0, utf8(context), plain)
  b64url(concat(eph_pub, body))
}

///|
/// `plain` sealed to the box key `pub_` under `context`: only that key's holder opens it, and only under that context.
pub fn seal(c : Crypto, pub_ : String, plain : BytesView, context : String) -> String raise Refused {
  seal_with(c, pub_, plain, context, c.random(32))
}

///|
/// What `seal` sealed to `priv`'s public half under `context`; refused when it is not.
pub fn open_seal(c : Crypto, sk : BytesView, boxed : String, context : String) -> Bytes raise Refused {
  let b = unb64(boxed)
  if b.length() < 48 {
    raise Refused("not a seal")
  }
  let eph_pub = b[0:32]
  let shared = c.x25519(sk, eph_pub)
  let key = seal_key(c, shared, eph_pub, c.x25519_public(sk))
  match c.chacha_open(key, nonce0, utf8(context), b[32:]) {
    Some(plain) => plain
    None => raise Refused("does not open")
  }
}

///|
/// An item's ciphertext: a 12-byte nonce, then ChaCha20-Poly1305 under the vault key with `context` as additional data.
pub fn encrypt_with(c : Crypto, key : BytesView, plain : BytesView, context : String, nonce : BytesView) -> String raise Refused {
  b64url(concat(nonce, c.chacha_seal(key, nonce, utf8(context), plain)))
}

///|
/// What `encrypt_with` made; refused when the key or context is not its.
pub fn decrypt(c : Crypto, key : BytesView, ct : String, context : String) -> Bytes raise Refused {
  let b = unb64(ct)
  if b.length() < 28 {
    raise Refused("not an item's ciphertext")
  }
  match c.chacha_open(key, b[0:12], utf8(context), b[12:]) {
    Some(plain) => plain
    None => raise Refused("does not open")
  }
}

///|
/// The recovery key pair from the 32 bytes the 24 recovery words hold: its public half and its private bytes.
pub fn recovery_pair(c : Crypto, entropy : BytesView) -> (String, Bytes) raise Refused {
  let sk = c.hkdf(entropy, b"", utf8("stillfail-vault-recovery/1"), 32)
  (box_public(c, sk), sk)
}
