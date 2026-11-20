// Upstream official test corpora harness operations for station_main crypto (live_p5_4_tls.mbt,
// live_p5_4_crypto.mbt) and media PNG decoding (media/thumbs.mbt).
// Used only by `stillfail-reader-harness --builder harness-upstream`.

///|
fn up_at(ask : Json, k : String) -> Json? {
  match ask {
    Object(m) => m.get(k)
    _ => None
  }
}

///|
fn up_str(ask : Json, k : String) -> String {
  match up_at(ask, k) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn up_unhex(h : String) -> Bytes {
  if h == "" {
    b""
  } else {
    @vault_crypto.unhex(h)
  }
}

///|
/// Strict RSASSA-PKCS1-v1_5 verification using live_p5_4_crypto's BigInt, hash and DigestInfo primitives.
fn p54_rsa_pkcs1_verify(host : @host.Host, n_bytes : Bytes, e_bytes : Bytes, hash : String, msg : Bytes, sig : Bytes) -> Bool {
  let n = p54_big(n_bytes)
  let e = p54_big(e_bytes)
  if n <= 0N || e <= 0N {
    return false
  }
  let k = (n.bit_length() + 7) / 8
  if sig.length() != k {
    return false
  }
  let s = p54_big(sig)
  if s >= n {
    return false
  }
  let di = try p54_digest_info(hash) catch { _ => return false }
  let digest = try p54_hash(host, hash, msg) catch { _ => return false }
  let t = p54_cat([di, digest])
  if k < t.length() + 11 {
    return false
  }
  let expected_em = p54_cat([b"\x00\x01", Bytes::make(k - t.length() - 3, b'\xff'), b"\x00", t])
  let actual = s.pow(e, modulus=n)
  actual == p54_big(expected_em)
}

///|
pub async fn upstream_op(host : @host.Host, ask : Json) -> Json {
  match up_str(ask, "op") {
    "crypto.gcm_seal" => {
      let key = up_unhex(up_str(ask, "key"))
      let iv = up_unhex(up_str(ask, "iv"))
      let aad = up_unhex(up_str(ask, "aad"))
      let plain = up_unhex(up_str(ask, "plain"))
      if key.length() != 16 || iv.length() != 12 {
        return { "ok": Json::boolean(false), "err": Json::string("invalid key or iv length") }
      }
      let sealed = p54_gcm_seal(key, iv, aad, plain)
      let ct = p54_sub(sealed, 0, sealed.length() - 16)
      let tag = p54_sub(sealed, sealed.length() - 16, sealed.length())
      { "ok": Json::boolean(true), "ct": Json::string(@drive.hex(ct)), "tag": Json::string(@drive.hex(tag)) }
    }
    "crypto.gcm_open" => {
      let key = up_unhex(up_str(ask, "key"))
      let iv = up_unhex(up_str(ask, "iv"))
      let aad = up_unhex(up_str(ask, "aad"))
      let ct = up_unhex(up_str(ask, "ct"))
      let tag = up_unhex(up_str(ask, "tag"))
      if tag.length() != 16 {
        return { "ok": Json::boolean(false) }
      }
      match p54_gcm_open(key, iv, aad, p54_cat([ct, tag])) {
        Some(p) => { "ok": Json::boolean(true), "plain": Json::string(@drive.hex(p)) }
        None => { "ok": Json::boolean(false) }
      }
    }
    "crypto.p256_public" => {
      let d = up_unhex(up_str(ask, "d"))
      try {
        let pub_ = p54_p256_public(d)
        { "ok": Json::boolean(true), "pub": Json::string(@drive.hex(pub_)) }
      } catch {
        e => { "ok": Json::boolean(false), "err": Json::string(said_of(e)) }
      }
    }
    "crypto.p256_shared" => {
      let d = up_unhex(up_str(ask, "d"))
      let peer = up_unhex(up_str(ask, "peer"))
      try {
        let shared = p54_p256_shared(d, peer)
        { "ok": Json::boolean(true), "shared": Json::string(@drive.hex(shared)) }
      } catch {
        e => { "ok": Json::boolean(false), "err": Json::string(said_of(e)) }
      }
    }
    "crypto.p256_sign" => {
      let d = up_unhex(up_str(ask, "d"))
      let msg = up_unhex(up_str(ask, "msg"))
      try {
        let pub_ = p54_p256_public(d)
        let raw = p54_ecdsa_raw(host, d, pub_, msg)
        let der = p54_der_seq([p54_der_uint(p54_sub(raw, 0, 32)), p54_der_uint(p54_sub(raw, 32, 64))])
        { "ok": Json::boolean(true), "raw": Json::string(@drive.hex(raw)), "der": Json::string(@drive.hex(der)), "pub": Json::string(@drive.hex(pub_)) }
      } catch {
        e => { "ok": Json::boolean(false), "err": Json::string(said_of(e)) }
      }
    }
    "crypto.p256_verify_der" => {
      let pub_ = up_unhex(up_str(ask, "pub"))
      let sig = up_unhex(up_str(ask, "sig"))
      let msg = up_unhex(up_str(ask, "msg"))
      let ok = @vault_crypto.Crypto::of_host(host).verify("ES256-der", pub_, sig, msg)
      { "ok": Json::boolean(ok) }
    }
    "crypto.rsa_verify" => {
      let n = up_unhex(up_str(ask, "n"))
      let e = up_unhex(up_str(ask, "e"))
      let hash = up_str(ask, "hash")
      let msg = up_unhex(up_str(ask, "msg"))
      let sig = up_unhex(up_str(ask, "sig"))
      let ok = p54_rsa_pkcs1_verify(host, n, e, hash, msg, sig)
      { "ok": Json::boolean(ok) }
    }
    "crypto.rsa_sign" => {
      let n = up_unhex(up_str(ask, "n"))
      let e = up_unhex(up_str(ask, "e"))
      let d = up_unhex(up_str(ask, "d"))
      let hash = up_str(ask, "hash")
      let msg = up_unhex(up_str(ask, "msg"))
      try {
        let sig = p54_rsa_sign(host, [n, e, d], hash, msg)
        { "ok": Json::boolean(true), "sig": Json::string(@drive.hex(sig)) }
      } catch {
        err => { "ok": Json::boolean(false), "err": Json::string(said_of(err)) }
      }
    }
    "png.decode" => {
      let raw = up_unhex(up_str(ask, "hex"))
      match @media.decode_image(raw) {
        Some(img) => {
          let px_bytes = Bytes::from_fixedarray(img.px)
          {
            "ok": Json::boolean(true),
            "w": Json::number(img.w.to_double()),
            "h": Json::number(img.h.to_double()),
            "sha256": Json::string(@hash.sha256_hex(px_bytes)),
          }
        }
        None => { "ok": Json::boolean(false) }
      }
    }
    other => { "unknown": Json::string(other) }
  }
}
