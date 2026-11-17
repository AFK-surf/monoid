// The cryptography the rules ask of the station (station/src/cloud/lock.ts `crypto`: sha256Hex, sigValid, validKeyId,
// endpointProof, taggedSigValid), a signature checked by the shell (`crypto.verify`: libcrux's Ed25519 and P-256, as
// native/mesh `verify` checks them for the TypeScript station) and SHA-256 here.

///|
/// How a signature is checked: `alg` "Ed25519", "ES256" or "ES256-der", the key's bytes (Ed25519's 32, P-256's
/// uncompressed point), the signature and the message.
pub(all) struct Crypto {
  verify : (String, Bytes, Bytes, Bytes) -> Bool
}

///|
/// The shell's check (`crypto.verify`), on this program's host.
pub fn Crypto::of_host(host : @host.Host) -> Crypto {
  {
    verify: (alg, key, signature, message) => {
      let args : Json = {
        "alg": Json::string(alg),
        "key": Json::string(hex_of(key)),
        "signature": Json::string(hex_of(signature)),
        "message": Json::string(hex_of(message)),
      }
      match (try Ok(host.shell_sync("crypto.verify", args)) catch { e => Err(e) }) {
        Ok(True) => true
        _ => false
      }
    },
  }
}

///|
/// P-256's prime, its curve's `b`.
let p256_p : @bigint.BigInt = @bigint.BigInt::from_string(
  "ffffffff00000001000000000000000000000000ffffffffffffffffffffffff",
  radix=16,
)

///|
let p256_b : @bigint.BigInt = @bigint.BigInt::from_string(
  "5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b",
  radix=16,
)

///|
fn big_of(b : BytesView) -> @bigint.BigInt {
  if b.length() == 0 {
    return 0N
  }
  @bigint.BigInt::from_string(hex_of(b), radix=16)
}

///|
/// Whether 64 bytes (x then y) are a point of P-256 (what node's createPublicKey refuses otherwise).
fn on_p256(xy : BytesView) -> Bool {
  let x = big_of(xy[0:32])
  let y = big_of(xy[32:64])
  if x >= p256_p || y >= p256_p {
    return false
  }
  let lhs = y * y % p256_p
  let rhs = ((x * x % p256_p * x - x * 3N + p256_b) % p256_p + p256_p) % p256_p
  lhs == rhs
}

///|
/// A signing key by its id (lock.ts `publicKey`): "Ed25519" and its 32 bytes, or "ES256" and its uncompressed point;
/// raises where it is none.
fn public_key(id : String) -> (String, Bytes) raise Failure {
  if id.has_prefix("ed25519:") {
    let hex = id.unsafe_substring(start=8, end=id.length())
    if is_hex32(hex) {
      return ("Ed25519", hex_bytes(hex))
    }
  }
  if id.has_prefix("p256:") {
    let point = b64_bytes(id.unsafe_substring(start=5, end=id.length()))
    if point.length() != 65 || point[0] != b'\x04' {
      raise Failed("not a P-256 key")
    }
    if !on_p256(point[1:65]) {
      raise Failed("not a P-256 key")
    }
    return ("ES256", point)
  }
  raise Failed("unknown key kind")
}

///|
/// Whether `id` is a signing key's id (lock.ts `validKeyId`).
pub fn Crypto::valid_key(_self : Crypto, id : String) -> Bool {
  if id.length() > 200 {
    return false
  }
  (try Ok(public_key(id)) catch { e => Err(e) }) is Ok(_)
}

///|
/// Whether `signature` is the key `id`'s over `message` (lock.ts `signatureOk`; `der`: a P-256 one DER-encoded).
pub fn Crypto::signature_ok(self : Crypto, id : String, signature : Bytes, message : Bytes, der? : Bool = false) -> Bool raise Failure {
  let (alg, key) = public_key(id)
  let a = if alg == "Ed25519" {
    "Ed25519"
  } else if der {
    "ES256-der"
  } else {
    "ES256"
  }
  (self.verify)(a, key, signature, message)
}

///|
/// What a device or app key signs for an entry (lock.ts `signedBytes`).
pub fn signed_bytes(hash : String) -> Bytes {
  concat([utf8_of("stillfail-lock/1 sig\u0000"), hex_bytes(hash)])
}

///|
/// What a device's base key signs to say an endpoint is its own in a workspace (lock.ts `endpointBytes`).
pub fn endpoint_bytes(ws : String, endpoint : String) -> Bytes {
  utf8_of("stillfail-lock-endpoint/1\u0000\{ws}\u0000\{endpoint}")
}

///|
fn sig_text(sig : Json, k : String) -> String raise Failure {
  match get(sig, k) {
    Some(String(s)) => s
    _ => raise Failed("not a string")
  }
}

///|
/// Whether `sig` is the key's over the entry `hash`; a passkey's also on one of `origins` for `rp_id` (lock.ts
/// `sigValid`).
pub fn Crypto::sig_ok(self : Crypto, sig : Json, hash : String, origins : Array[String], rp_id : String, passkey : Bool) -> Bool {
  let checked = try {
    let key = sig_text(sig, "key")
    let (alg, _) = public_key(key)
    let said = match get(sig, "alg") {
      Some(String(s)) => Some(s)
      _ => None
    }
    if said == Some("webauthn") {
      if !passkey || alg != "ES256" {
        return false
      }
      let client = b64_bytes(sig_text(sig, "client_data"))
      let data = match parse(@utf8.decode_lossy(client)) {
        Some(d) => d
        None => return false
      }
      let challenge = b64url_of(hex_bytes(hash))
      if text_at(data, "type") != Some("webauthn.get") || text_at(data, "challenge") != Some(challenge) {
        return false
      }
      match text_at(data, "origin") {
        Some(o) => if !origins.contains(o) { return false }
        None => return false
      }
      let auth = b64_bytes(sig_text(sig, "authenticator_data"))
      if auth.length() < 37 || hex_of(auth[0:32]) != hex_of(sha256(utf8_of(rp_id))) || (auth[32].to_int() & 1) == 0 {
        return false
      }
      return self.signature_ok(key, b64_bytes(sig_text(sig, "sig")), concat([auth, sha256(client)]), der=true)
    }
    if said != Some(alg) || passkey {
      return false
    }
    let s = sig_text(sig, "sig")
    self.signature_ok(key, if alg == "Ed25519" { hex_bytes(s) } else { b64_bytes(s) }, signed_bytes(hash))
  } catch {
    _ => false
  }
  checked
}

///|
/// Whether a device's base key says `endpoint` is its own in workspace `ws` (lock.ts `endpointProof`).
pub fn Crypto::endpoint_ok(self : Crypto, ws : String, base : String, endpoint : String, proof : String) -> Bool {
  is_hex32(base) &&
  (try Ok(self.signature_ok("ed25519:" + base, hex_bytes(proof), endpoint_bytes(ws, endpoint))) catch { e => Err(e) }) is Ok(true)
}

///|
/// Whether `sig` (hex) is `key`'s over `tag`, a NUL and the 32 bytes of `digest` (lock.ts `taggedSigValid`).
pub fn Crypto::tagged_ok(self : Crypto, key : String, sig : String, tag : String, digest : String) -> Bool {
  if !is_hex32(digest) || !key.has_prefix("ed25519:") || !is_hex32(key.unsafe_substring(start=8, end=key.length())) {
    return false
  }
  (try Ok(self.signature_ok(key, hex_bytes(sig), concat([utf8_of(tag + "\u0000"), hex_bytes(digest)]))) catch { e => Err(e) }) is Ok(true)
}

///|
pub impl @lock.Crypto for Crypto with sha256_hex(_self, s) {
  sha256_hex(s)
}

///|
pub impl @lock.Crypto for Crypto with sig_valid(self, sig, hash, origins, rp_id, passkey) {
  self.sig_ok(sig, hash, origins, rp_id, passkey)
}

///|
pub impl @lock.Crypto for Crypto with valid_key_id(self, id) {
  self.valid_key(id)
}

///|
pub impl @lock.Crypto for Crypto with endpoint_proof(self, ws, base, endpoint, proof) {
  self.endpoint_ok(ws, base, endpoint, proof)
}

///|
pub impl @lock.Crypto for Crypto with tagged_sig_valid(self, key, sig, tag, digest) {
  self.tagged_ok(key, sig, tag, digest)
}
