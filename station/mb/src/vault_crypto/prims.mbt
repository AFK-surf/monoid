// The primitives the vault's formats are made of, the shell's (client/shell `crypto.*`, answered at once on this thread):
// SHA-256, HKDF-SHA256, X25519, ChaCha20-Poly1305, random bytes and the lock's signatures (Ed25519, ES256). What is
// put together of them (the seal, an item's ciphertext, what is signed) is here, in formats.mbt.

///|
/// What failed in a primitive (a key of the wrong length, a low-order point): never a secret in its words.
pub suberror Refused {
  Refused(String)
}

///|
pub impl Show for Refused with output(self, logger) {
  match self {
    Refused(m) => logger.write_string(m)
  }
}

///|
/// The shell asked at once: its answer's value, or why not. A test gives its own.
pub(all) struct Crypto {
  ask : (String, Json) -> Result[Json, String]
}

///|
/// The shell's primitives as `host` has them.
pub fn Crypto::of_host(host : @host.Host) -> Crypto {
  {
    ask: (op, args) => {
      Ok(host.shell_sync(op, args)) catch {
        e => Err(e.to_string())
      }
    },
  }
}

///|
fn Crypto::bytes(self : Crypto, op : String, args : Map[String, Json]) -> Bytes raise Refused {
  match (self.ask)(op, Json::object(args)) {
    Ok(String(h)) => unhex(h)
    Ok(_) => raise Refused("\{op}: no bytes")
    Err(e) => raise Refused("\{op}: \{e}")
  }
}

///|
fn j(b : BytesView) -> Json {
  Json::string(hex(b))
}

///|
pub fn Crypto::sha256(self : Crypto, data : BytesView) -> Bytes raise Refused {
  self.bytes("crypto.sha256", { "data": j(data) })
}

///|
pub fn Crypto::hkdf(self : Crypto, ikm : BytesView, salt : BytesView, info : BytesView, length : Int) -> Bytes raise Refused {
  self.bytes("crypto.hkdfSha256", { "ikm": j(ikm), "salt": j(salt), "info": j(info), "length": Json::number(length.to_double()) })
}

///|
/// The public half of an X25519 private key (32 bytes).
pub fn Crypto::x25519_public(self : Crypto, sk : BytesView) -> Bytes raise Refused {
  self.bytes("crypto.x25519Public", { "priv": j(sk) })
}

///|
/// X25519 of `priv` and `pub`; refused where the secret would be zeros (as node:crypto's diffieHellman refuses it).
pub fn Crypto::x25519(self : Crypto, sk : BytesView, pub_ : BytesView) -> Bytes raise Refused {
  self.bytes("crypto.x25519", { "priv": j(sk), "pub": j(pub_) })
}

///|
/// ChaCha20-Poly1305: the ciphertext and its 16-byte tag.
pub fn Crypto::chacha_seal(self : Crypto, key : BytesView, nonce : BytesView, aad : BytesView, plain : BytesView) -> Bytes raise Refused {
  self.bytes("crypto.chachaSeal", { "key": j(key), "nonce": j(nonce), "aad": j(aad), "plain": j(plain) })
}

///|
/// What `chacha_seal` sealed; None where it does not open (another key, nonce or additional data, or changed).
pub fn Crypto::chacha_open(self : Crypto, key : BytesView, nonce : BytesView, aad : BytesView, boxed : BytesView) -> Bytes? raise Refused {
  match (self.ask)("crypto.chachaOpen", Json::object({ "key": j(key), "nonce": j(nonce), "aad": j(aad), "sealed": j(boxed) })) {
    Ok(String(h)) => Some(unhex(h))
    Ok(Null) => None
    Ok(_) => raise Refused("crypto.chachaOpen: no bytes")
    Err(e) => raise Refused("crypto.chachaOpen: \{e}")
  }
}

///|
/// `n` random bytes, from the system's source.
pub fn Crypto::random(self : Crypto, n : Int) -> Bytes raise Refused {
  self.bytes("crypto.random", { "bytes": Json::number(n.to_double()) })
}

///|
/// Whether `signature` is `key`'s over `message`: `alg` Ed25519 (a 32-byte key) or ES256 (an uncompressed P-256 point,
/// r‖s); false for anything else.
pub fn Crypto::verify(self : Crypto, alg : String, key : BytesView, signature : BytesView, message : BytesView) -> Bool {
  match (self.ask)("crypto.verify", Json::object({ "alg": Json::string(alg), "key": j(key), "signature": j(signature), "message": j(message) })) {
    Ok(True) => true
    _ => false
  }
}
