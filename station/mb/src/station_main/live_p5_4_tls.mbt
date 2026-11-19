// The vault proxy's HTTPS (vault/proxy.ts: Node's `tls` and `https` there): a TLS 1.3 server (RFC 8446) on a
// CONNECT's stream, showing the leaf the proxy made for the host (signed by its CA), the key shared by X25519 (the
// shell's) or P-256 (live_p5_4_crypto.mbt), records sealed by ChaCha20-Poly1305 (the shell's) or AES-128-GCM (here);
// the HTTP/1.1 requests inside it given to the proxy's `forward` and sent on to the host by the shell's `fetch` (its
// roots: the web's, as Node's are), what comes back written in records. No resumption, no early data, no
// HelloRetryRequest: a client that shares no key of X25519 or P-256 at first is refused with an alert.

// ── AES-128 and GCM ──

///|
let p54_sbox : FixedArray[Int] = {
  let s = FixedArray::make(256, 0)
  // (the S-box from GF(2^8)'s inverses and the affine map)
  let mut p = 1
  let mut q = 1
  while true {
    p = p ^ ((p << 1) & 0xff) ^ (if (p & 0x80) != 0 { 0x1b } else { 0 })
    q = q ^ (q << 1)
    q = q ^ (q << 2)
    q = q ^ (q << 4)
    q = q & 0xff
    if (q & 0x80) != 0 {
      q = q ^ 0x09
    }
    let rot = (x : Int, n : Int) => ((x << n) | (x >> (8 - n))) & 0xff
    s[p] = q ^ rot(q, 1) ^ rot(q, 2) ^ rot(q, 3) ^ rot(q, 4) ^ 0x63
    if p == 1 {
      break
    }
  }
  s[0] = 0x63
  s
}

///|
fn p54_xtime(x : Int) -> Int {
  ((x << 1) ^ (if (x & 0x80) != 0 { 0x1b } else { 0 })) & 0xff
}

///|
/// AES-128's round keys (11 of 16 bytes).
fn p54_aes_keys(key : Bytes) -> FixedArray[Int] {
  let w = FixedArray::make(176, 0)
  for i in 0..<16 {
    w[i] = key[i].to_int()
  }
  let mut rcon = 1
  for i in 4..<44 {
    let t = [w[4 * (i - 1)], w[4 * (i - 1) + 1], w[4 * (i - 1) + 2], w[4 * (i - 1) + 3]]
    if i % 4 == 0 {
      let t0 = t[0]
      t[0] = p54_sbox[t[1]] ^ rcon
      t[1] = p54_sbox[t[2]]
      t[2] = p54_sbox[t[3]]
      t[3] = p54_sbox[t0]
      rcon = p54_xtime(rcon)
    }
    for j in 0..<4 {
      w[4 * i + j] = w[4 * (i - 4) + j] ^ t[j]
    }
  }
  w
}

///|
fn p54_aes_block(w : FixedArray[Int], input : Bytes) -> Bytes {
  let s = FixedArray::makei(16, i => input[i].to_int() ^ w[i])
  for round in 1..=10 {
    let t = FixedArray::make(16, 0)
    // SubBytes and ShiftRows
    for c in 0..<4 {
      for r in 0..<4 {
        t[4 * c + r] = p54_sbox[s[4 * ((c + r) % 4) + r]]
      }
    }
    // MixColumns (not in the last round)
    if round != 10 {
      for c in 0..<4 {
        let a0 = t[4 * c]
        let a1 = t[4 * c + 1]
        let a2 = t[4 * c + 2]
        let a3 = t[4 * c + 3]
        let all = a0 ^ a1 ^ a2 ^ a3
        t[4 * c] = a0 ^ all ^ p54_xtime(a0 ^ a1)
        t[4 * c + 1] = a1 ^ all ^ p54_xtime(a1 ^ a2)
        t[4 * c + 2] = a2 ^ all ^ p54_xtime(a2 ^ a3)
        t[4 * c + 3] = a3 ^ all ^ p54_xtime(a3 ^ a0)
      }
    }
    for i in 0..<16 {
      s[i] = t[i] ^ w[16 * round + i]
    }
  }
  Bytes::makei(16, i => s[i].to_byte())
}

///|
/// GF(2^128)'s product (GCM's bit order).
fn p54_gmul(x : (UInt64, UInt64), y : (UInt64, UInt64)) -> (UInt64, UInt64) {
  let mut zh = 0UL
  let mut zl = 0UL
  let mut vh = y.0
  let mut vl = y.1
  for i in 0..<128 {
    let bit = if i < 64 { (x.0 >> (63 - i)) & 1UL } else { (x.1 >> (127 - i)) & 1UL }
    if bit == 1UL {
      zh = zh ^ vh
      zl = zl ^ vl
    }
    let lsb = vl & 1UL
    vl = (vl >> 1) | (vh << 63)
    vh = vh >> 1
    if lsb == 1UL {
      vh = vh ^ 0xe100000000000000UL
    }
  }
  (zh, zl)
}

///|
fn p54_u64s(b : Bytes, at : Int) -> (UInt64, UInt64) {
  let get = (o : Int) => {
    let mut v = 0UL
    for i in 0..<8 {
      let at_ = at + o + i
      v = (v << 8) | (if at_ < b.length() { b[at_].to_uint64() } else { 0UL })
    }
    v
  }
  (get(0), get(8))
}

///|
fn p54_ghash(h : (UInt64, UInt64), aad : Bytes, c : Bytes) -> Bytes {
  let mut y = (0UL, 0UL)
  for part in [aad, c] {
    let mut at = 0
    while at < part.length() {
      let x = p54_u64s(part, at)
      y = p54_gmul((y.0 ^ x.0, y.1 ^ x.1), h)
      at += 16
    }
  }
  y = p54_gmul((y.0 ^ (aad.length().to_uint64() * 8UL), y.1 ^ (c.length().to_uint64() * 8UL)), h)
  Bytes::makei(16, i => if i < 8 { (y.0 >> (56 - 8 * i)).to_byte() } else { (y.1 >> (120 - 8 * i)).to_byte() })
}

///|
fn p54_ctr(w : FixedArray[Int], iv : Bytes, from : Int, data : Bytes) -> Bytes {
  let out = FixedArray::make(data.length(), b'\x00')
  let mut counter = from
  let mut at = 0
  while at < data.length() {
    let block = p54_cat([iv, Bytes::from_array([(counter >> 24).to_byte(), (counter >> 16).to_byte(), (counter >> 8).to_byte(), counter.to_byte()])])
    let ks = p54_aes_block(w, block)
    for i in 0..<16 {
      if at + i < data.length() {
        out[at + i] = data[at + i] ^ ks[i]
      }
    }
    counter += 1
    at += 16
  }
  Bytes::from_fixedarray(out)
}

///|
fn p54_gcm_seal(key : Bytes, nonce : Bytes, aad : Bytes, plain : Bytes) -> Bytes {
  let w = p54_aes_keys(key)
  let h = p54_u64s(p54_aes_block(w, Bytes::make(16, b'\x00')), 0)
  let c = p54_ctr(w, nonce, 2, plain)
  let s = p54_ghash(h, aad, c)
  let j0 = p54_aes_block(w, p54_cat([nonce, b"\x00\x00\x00\x01"]))
  p54_cat([c, Bytes::makei(16, i => s[i] ^ j0[i])])
}

///|
fn p54_gcm_open(key : Bytes, nonce : Bytes, aad : Bytes, sealed : Bytes) -> Bytes? {
  if sealed.length() < 16 {
    return None
  }
  let w = p54_aes_keys(key)
  let h = p54_u64s(p54_aes_block(w, Bytes::make(16, b'\x00')), 0)
  let c = p54_sub(sealed, 0, sealed.length() - 16)
  let tag = p54_sub(sealed, sealed.length() - 16, sealed.length())
  let s = p54_ghash(h, aad, c)
  let j0 = p54_aes_block(w, p54_cat([nonce, b"\x00\x00\x00\x01"]))
  let mut diff = 0
  for i in 0..<16 {
    diff = diff | (tag[i] ^ s[i] ^ j0[i]).to_int()
  }
  if diff != 0 {
    return None
  }
  Some(p54_ctr(w, nonce, 2, c))
}

// ── the key schedule ──

///|
fn p54_expand_label(host : @host.Host, secret : Bytes, label : String, context : Bytes, len : Int) -> Bytes {
  let l = @utf8.encode("tls13 " + label)
  let info = p54_cat([
    Bytes::from_array([(len >> 8).to_byte(), len.to_byte(), l.length().to_byte()]),
    l,
    Bytes::make(1, context.length().to_byte()),
    context,
  ])
  // (HKDF-Expand: what is asked here is at most one block of SHA-256)
  p54_sub(p54_hmac256(host, secret, p54_cat([info, b"\x01"])), 0, len)
}

///|
fn p54_extract(host : @host.Host, salt : Bytes, ikm : Bytes) -> Bytes {
  p54_hmac256(host, salt, ikm)
}

///|
/// One direction's record protection: its suite, key, iv and sequence number.
priv struct P54Seal {
  suite : Int
  key : Bytes
  iv : Bytes
  mut seq : UInt64
}

///|
fn p54_seal_of(host : @host.Host, suite : Int, secret : Bytes) -> P54Seal {
  let klen = if suite == 0x1301 { 16 } else { 32 }
  {
    suite,
    key: p54_expand_label(host, secret, "key", b"", klen),
    iv: p54_expand_label(host, secret, "iv", b"", 12),
    seq: 0UL,
  }
}

///|
fn P54Seal::nonce(self : P54Seal) -> Bytes {
  Bytes::makei(12, i => if i < 4 { self.iv[i] } else { self.iv[i] ^ (self.seq >> (8 * (11 - i))).to_byte() })
}

///|
/// A record of `type_` sealed: its outer header and what is sealed.
fn P54Seal::seal(self : P54Seal, host : @host.Host, type_ : Int, body : Bytes) -> Bytes raise {
  let inner = p54_cat([body, Bytes::make(1, type_.to_byte())])
  let len = inner.length() + 16
  let aad = Bytes::from_array([b'\x17', b'\x03', b'\x03', (len >> 8).to_byte(), len.to_byte()])
  let nonce = self.nonce()
  self.seq += 1UL
  let sealed = if self.suite == 0x1301 {
    p54_gcm_seal(self.key, nonce, aad, inner)
  } else {
    @vault_crypto.Crypto::of_host(host).chacha_seal(self.key, nonce, aad, inner)
  }
  p54_cat([aad, sealed])
}

///|
/// A sealed record opened: its inner type and what it holds.
fn P54Seal::open(self : P54Seal, host : @host.Host, header : Bytes, sealed : Bytes) -> (Int, Bytes) raise {
  let nonce = self.nonce()
  self.seq += 1UL
  let plain = if self.suite == 0x1301 {
    p54_gcm_open(self.key, nonce, header, sealed)
  } else {
    @vault_crypto.Crypto::of_host(host).chacha_open(self.key, nonce, header, sealed)
  }
  guard plain is Some(p) else { raise Failure("a record does not open (bad_record_mac)") }
  let mut end = p.length()
  while end > 0 && p[end - 1] == b'\x00' {
    end -= 1
  }
  if end == 0 {
    raise Failure("a record with no type")
  }
  (p[end - 1].to_int(), p54_sub(p, 0, end - 1))
}

// ── the connection ──

///|
/// The TLS contexts the proxy made (`tls_context`): its leaf's key and the chain shown, by handle.
let p54_tls_contexts : Map[String, (@vault_service.KeyRef, Array[Bytes])] = Map([])

///|
/// A context made: the leaf's key (PKCS#8 PEM, held here) and its chain's PEMs.
async fn p54_tls_context(host : @host.Host, key_pem : String, chain_pem : String) -> String {
  let ops = p54_key_ops(host)
  guard (ops.1)(key_pem) is Some(key) else { raise Failure("the leaf's key is unreadable") }
  let certs = []
  let mut rest = chain_pem
  while p54_pem_parts(rest) is Some((_, der)) {
    certs.push(der)
    match rest.find("-----END ") {
      Some(i) =>
        rest = match rest[i + 9:].find("-----") {
          Some(j) => rest[i + 9 + j + 5:].to_owned()
          None => ""
        }
      None => break
    }
  }
  let handle = "tls\{p54_tls_contexts.length() + 1}"
  p54_tls_contexts[handle] = (key, certs)
  handle
}

///|
/// The bytes of a stream, read as they are asked for.
priv struct P54Reader {
  read : async () -> Bytes?
  buf : @buffer.Buffer
  mut have : Bytes
}

///|
async fn P54Reader::take(self : P54Reader, n : Int) -> Bytes? {
  while self.have.length() < n {
    guard (self.read)() is Some(more) else { return None }
    self.have = p54_cat([self.have, more])
  }
  let out = p54_sub(self.have, 0, n)
  self.have = p54_sub(self.have, n, self.have.length())
  Some(out)
}

///|
/// The next record: its type, its header and its body.
async fn P54Reader::record(self : P54Reader) -> (Int, Bytes, Bytes)? {
  guard self.take(5) is Some(h) else { return None }
  let len = (h[3].to_int() << 8) | h[4].to_int()
  if len > 18432 {
    raise Failure("a record too long")
  }
  guard self.take(len) is Some(body) else { return None }
  Some((h[0].to_int(), h, body))
}

///|
fn p54_u16(n : Int) -> Bytes {
  Bytes::from_array([(n >> 8).to_byte(), n.to_byte()])
}

///|
fn p54_u24(n : Int) -> Bytes {
  Bytes::from_array([(n >> 16).to_byte(), (n >> 8).to_byte(), n.to_byte()])
}

///|
fn p54_hs(type_ : Int, body : Bytes) -> Bytes {
  p54_cat([Bytes::make(1, type_.to_byte()), p54_u24(body.length()), body])
}

///|
fn p54_alert(desc : Int) -> Bytes {
  Bytes::from_array([b'\x15', b'\x03', b'\x03', b'\x00', b'\x02', b'\x02', desc.to_byte()])
}

///|
/// A TLS 1.3 server's side on a stream (`read`, `write`): the handshake, then each application message given to
/// `serve`, which writes back through what it is given; ends where either side does.
async fn p54_tls_serve(
  host : @host.Host,
  context : String,
  read : async () -> Bytes?,
  write : async (Bytes) -> Unit,
  serve : async (async () -> Bytes?, async (Bytes) -> Unit) -> Unit,
) -> Unit {
  guard p54_tls_contexts.get(context) is Some((key, chain)) else { raise Failure("no such TLS context") }
  let r : P54Reader = { read, buf: @buffer.new(), have: b"" }
  // ClientHello (it may come over several records)
  guard r.record() is Some((22, _, first)) else { raise Failure("no ClientHello") }
  let mut hello = first
  if hello.length() < 4 || hello[0] != b'\x01' {
    write(p54_alert(10))
    raise Failure("not a ClientHello")
  }
  let hlen = (hello[1].to_int() << 16) | (hello[2].to_int() << 8) | hello[3].to_int()
  while hello.length() < 4 + hlen {
    guard r.record() is Some((22, _, more)) else { raise Failure("the ClientHello cut short") }
    hello = p54_cat([hello, more])
  }
  let ch = p54_sub(hello, 0, 4 + hlen)
  let b = p54_sub(ch, 4, ch.length())
  let mut at = 2 + 32
  let sid_len = b[at].to_int()
  let session_id = p54_sub(b, at + 1, at + 1 + sid_len)
  at += 1 + sid_len
  let cs_len = (b[at].to_int() << 8) | b[at + 1].to_int()
  let suites = []
  for i in 0..<(cs_len / 2) {
    suites.push((b[at + 2 + 2 * i].to_int() << 8) | b[at + 3 + 2 * i].to_int())
  }
  at += 2 + cs_len
  at += 1 + b[at].to_int()
  let ext_end = at + 2 + ((b[at].to_int() << 8) | b[at + 1].to_int())
  at += 2
  let mut tls13 = false
  let mut sigs_ok = false
  let mut x25519 : Bytes? = None
  let mut p256 : Bytes? = None
  let mut http11 = false
  let mut alpn = false
  while at + 4 <= ext_end {
    let t = (b[at].to_int() << 8) | b[at + 1].to_int()
    let l = (b[at + 2].to_int() << 8) | b[at + 3].to_int()
    let d = p54_sub(b, at + 4, at + 4 + l)
    at += 4 + l
    match t {
      43 =>
        for i in 0..<(d[0].to_int() / 2) {
          if d[1 + 2 * i] == b'\x03' && d[2 + 2 * i] == b'\x04' {
            tls13 = true
          }
        }
      13 => {
        let n = (d[0].to_int() << 8) | d[1].to_int()
        for i in 0..<(n / 2) {
          if d[2 + 2 * i] == b'\x04' && d[3 + 2 * i] == b'\x03' {
            sigs_ok = true
          }
        }
      }
      51 => {
        let n = (d[0].to_int() << 8) | d[1].to_int()
        let mut j = 2
        while j + 4 <= 2 + n {
          let g = (d[j].to_int() << 8) | d[j + 1].to_int()
          let kl = (d[j + 2].to_int() << 8) | d[j + 3].to_int()
          let k = p54_sub(d, j + 4, j + 4 + kl)
          if g == 0x001d && kl == 32 {
            x25519 = Some(k)
          } else if g == 0x0017 && kl == 65 {
            p256 = Some(k)
          }
          j += 4 + kl
        }
      }
      16 => {
        alpn = true
        let n = (d[0].to_int() << 8) | d[1].to_int()
        let mut j = 2
        while j < 2 + n {
          let pl = d[j].to_int()
          if @utf8.decode_lossy(p54_sub(d, j + 1, j + 1 + pl)) == "http/1.1" {
            http11 = true
          }
          j += 1 + pl
        }
      }
      _ => ()
    }
  }
  let suite = if suites.contains(0x1303) { 0x1303 } else if suites.contains(0x1301) { 0x1301 } else { 0 }
  if !tls13 || !sigs_ok || suite == 0 || (alpn && !http11) {
    write(p54_alert(40))
    raise Failure("the client asks for what this proxy does not speak")
  }
  // the key shared
  let crypto = @vault_crypto.Crypto::of_host(host)
  let (group, our_public, shared) = match (x25519, p256) {
    (Some(peer), _) => {
      let sk = @drive.random_bytes(32)
      (0x001d, crypto.x25519_public(sk), crypto.x25519(sk, peer))
    }
    (None, Some(peer)) => {
      let d = p54_p256_new_scalar()
      (0x0017, p54_p256_public(d), p54_p256_shared(d, peer))
    }
    _ => {
      write(p54_alert(40))
      raise Failure("no key share of X25519 or P-256")
    }
  }
  let sh = p54_hs(
    2,
    p54_cat([
      b"\x03\x03",
      @drive.random_bytes(32),
      Bytes::make(1, session_id.length().to_byte()),
      session_id,
      p54_u16(suite),
      b"\x00",
      p54_u16(6 + 4 + 4 + our_public.length()),
      b"\x00\x2b\x00\x02\x03\x04",
      b"\x00\x33",
      p54_u16(4 + our_public.length()),
      p54_u16(group),
      p54_u16(our_public.length()),
      our_public,
    ]),
  )
  let transcript = @buffer.new()
  transcript.write_bytes(ch)
  transcript.write_bytes(sh)
  let th = () => p54_sha256(host, transcript.to_bytes())
  let zero = Bytes::make(32, b'\x00')
  let early = p54_extract(host, zero, zero)
  let empty_hash = p54_sha256(host, b"")
  let hs_secret = p54_extract(host, p54_expand_label(host, early, "derived", empty_hash, 32), shared)
  let c_hs = p54_expand_label(host, hs_secret, "c hs traffic", th(), 32)
  let s_hs = p54_expand_label(host, hs_secret, "s hs traffic", th(), 32)
  let server_hs = p54_seal_of(host, suite, s_hs)
  let client_hs = p54_seal_of(host, suite, c_hs)
  let out = @buffer.new()
  out.write_bytes(b"\x16\x03\x03")
  out.write_bytes(p54_u16(sh.length()))
  out.write_bytes(sh)
  if session_id.length() > 0 {
    out.write_bytes(b"\x14\x03\x03\x00\x01\x01")
  }
  // EncryptedExtensions, Certificate, CertificateVerify, Finished
  let ee = if alpn {
    let proto = b"\x08http/1.1"
    let list = p54_cat([p54_u16(proto.length()), proto])
    p54_hs(8, p54_cat([p54_u16(4 + list.length()), b"\x00\x10", p54_u16(list.length()), list]))
  } else {
    p54_hs(8, b"\x00\x00")
  }
  transcript.write_bytes(ee)
  let certs = @buffer.new()
  for c in chain {
    certs.write_bytes(p54_u24(c.length()))
    certs.write_bytes(c)
    certs.write_bytes(b"\x00\x00")
  }
  let cert = p54_hs(11, p54_cat([b"\x00", p54_u24(certs.length()), certs.to_bytes()]))
  transcript.write_bytes(cert)
  let signed = p54_cat([Bytes::make(64, b'\x20'), @utf8.encode("TLS 1.3, server CertificateVerify"), b"\x00", th()])
  let signature = ((p54_key_ops(host)).5)(key, "sha256", signed)
  let cv = p54_hs(15, p54_cat([b"\x04\x03", p54_u16(signature.length()), signature]))
  transcript.write_bytes(cv)
  let s_finished_key = p54_expand_label(host, s_hs, "finished", b"", 32)
  let fin = p54_hs(20, p54_hmac256(host, s_finished_key, th()))
  transcript.write_bytes(fin)
  for m in [ee, cert, cv, fin] {
    out.write_bytes(server_hs.seal(host, 22, m))
  }
  write(out.to_bytes())
  // the application's keys, from the transcript to the server's Finished
  let master = p54_extract(host, p54_expand_label(host, hs_secret, "derived", empty_hash, 32), zero)
  let c_ap = p54_expand_label(host, master, "c ap traffic", th(), 32)
  let s_ap = p54_expand_label(host, master, "s ap traffic", th(), 32)
  let expected = p54_hmac256(host, p54_expand_label(host, c_hs, "finished", b"", 32), th())
  // the client's Finished (a ChangeCipherSpec of its own passed over)
  while true {
    guard r.record() is Some((type_, header, body)) else { raise Failure("the client left in the handshake") }
    if type_ == 20 {
      continue
    }
    if type_ != 23 {
      raise Failure("the client said no (an alert in the handshake)")
    }
    let (inner, m) = client_hs.open(host, header, body)
    if inner == 21 {
      raise Failure("the client said no (an alert in the handshake)")
    }
    if inner != 22 || m.length() < 4 || m[0] != b'\x14' || p54_sub(m, 4, m.length()) != expected {
      write(server_hs.seal(host, 21, b"\x02\x33"))
      raise Failure("the client's Finished does not check")
    }
    break
  }
  let server_ap = p54_seal_of(host, suite, s_ap)
  let client_ap = p54_seal_of(host, suite, c_ap)
  let ended = Ref(false)
  let app_read = async fn() -> Bytes? {
    while !ended.val {
      guard r.record() is Some((type_, header, body)) else { return None }
      if type_ != 23 {
        continue
      }
      let (inner, m) = client_ap.open(host, header, body)
      match inner {
        23 => return Some(m)
        21 => {
          ended.val = true
          return None
        }
        // (a NewSessionTicket or KeyUpdate of the client's: none asked of a server here)
        _ => continue
      }
    }
    None
  }
  let app_write = async fn(data : Bytes) {
    let mut at = 0
    while at < data.length() {
      let end = if at + 16384 < data.length() { at + 16384 } else { data.length() }
      write(server_ap.seal(host, 23, p54_sub(data, at, end)))
      at = end
    }
  }
  serve(app_read, app_write)
  write(server_ap.seal(host, 21, b"\x01\x00")) catch {
    _ => ()
  }
}

// ── HTTP/1.1 inside ──

///|
let p54_hop : Array[String] = [
  "connection", "keep-alive", "proxy-connection", "proxy-authorization", "proxy-authenticate", "te", "trailer", "transfer-encoding",
  "upgrade",
]

///|
/// The requests on an opened connection, each given to the proxy's `forward` and sent on, until the client ends it.
async fn p54_http_inside(
  host : @host.Host,
  target_host : String,
  target_port : Int,
  run : Int,
  forward : async (@vault_service.ForwardAsk) -> @vault_service.ForwardDecision,
  read : async () -> Bytes?,
  write : async (Bytes) -> Unit,
) -> Unit {
  let r : P54Reader = { read, buf: @buffer.new(), have: b"" }
  while true {
    // the head, to its blank line
    let mut head_end = -1
    while head_end < 0 {
      let text = r.have
      for i in 0..<(if text.length() >= 4 { text.length() - 3 } else { 0 }) {
        if text[i] == b'\r' && text[i + 1] == b'\n' && text[i + 2] == b'\r' && text[i + 3] == b'\n' {
          head_end = i
          break
        }
      }
      if head_end < 0 {
        guard (r.read)() is Some(more) else { return }
        r.have = p54_cat([r.have, more])
        if r.have.length() > 65536 {
          write(@utf8.encode("HTTP/1.1 431 Request Header Fields Too Large\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"))
          return
        }
      }
    }
    let head = @utf8.decode_lossy(p54_sub(r.have, 0, head_end))
    r.have = p54_sub(r.have, head_end + 4, r.have.length())
    let lines = head.split("\r\n").map(l => l.to_owned()).to_array()
    let first = lines[0].split(" ").map(x => x.to_owned()).to_array()
    guard first.length() >= 2 else { return }
    let verb = first[0]
    let target = first[1]
    let headers : Array[(String, Array[String])] = []
    for l in lines[1:] {
      match l.find(":") {
        Some(i) => {
          let k = l[:i].to_owned().to_lower()
          let v = l[i + 1:].to_owned().trim().to_owned()
          match headers.search_by(h => h.0 == k) {
            Some(j) => headers[j].1.push(v)
            None => headers.push((k, [v]))
          }
        }
        None => ()
      }
    }
    let value = (k : String) => headers.search_by(h => h.0 == k).map(j => headers[j].1.join(", "))
    // its body: by its length, or its chunks
    let body = @buffer.new()
    if value("transfer-encoding").map(v => v.to_lower().contains("chunked")).unwrap_or(false) {
      while true {
        let mut line_end = -1
        while line_end < 0 {
          for i in 0..<(if r.have.length() >= 2 { r.have.length() - 1 } else { 0 }) {
            if r.have[i] == b'\r' && r.have[i + 1] == b'\n' {
              line_end = i
              break
            }
          }
          if line_end < 0 {
            guard (r.read)() is Some(more) else { return }
            r.have = p54_cat([r.have, more])
          }
        }
        let size_text = @utf8.decode_lossy(p54_sub(r.have, 0, line_end)).split(";").next().unwrap_or("").to_owned()
        r.have = p54_sub(r.have, line_end + 2, r.have.length())
        let size = @bigint.BigInt::from_string(if size_text == "" { "0" } else { size_text.trim().to_owned() }, radix=16).to_int()
        guard r.take(size + 2) is Some(chunk) else { return }
        if size == 0 {
          break
        }
        body.write_bytes(p54_sub(chunk, 0, size))
      }
    } else {
      let n = match value("content-length") {
        Some(t) => @string.parse_int(t.trim().to_owned()) catch { _ => 0 }
        None => 0
      }
      if n > 0 {
        guard r.take(n) is Some(b) else { return }
        body.write_bytes(b)
      }
    }
    let close = value("connection").map(v => v.to_lower().contains("close")).unwrap_or(false)
    let decided = forward({ run, host: target_host, port: target_port, verb, path: target, headers })
    let answer = match decided {
      Forbid(status, text) => {
        let words = @utf8.encode(text)
        p54_cat([@utf8.encode("HTTP/1.1 \{status} Forbidden\r\ncontent-type: text/plain\r\ncontent-length: \{words.length()}\r\n\r\n"), words])
      }
      Forward(sent) => {
        let url = "https://\{target_host}\{if target_port == 443 { "" } else { ":" + target_port.to_string() }}\{target}"
        let url = match env_get("STILLFAIL_TEST_PROXY_UPSTREAM") {
          // (a test's upstream on this machine, of plain HTTP: the shell's roots are the web's, not a test's CA)
          Some(port) if port != "" => "http://127.0.0.1:\{port}\{target}"
          _ => url
        }
        let pairs = []
        for h in sent {
          if !p54_hop.contains(h.0) && h.0 != "content-length" {
            for v in h.1 {
              pairs.push((h.0, v))
            }
          }
        }
        let got = (try {
          Ok(host.fetch(url, method_=verb, headers=pairs, body=body.to_bytes()))
        } catch {
          e => Err(e)
        })
        match got {
          Ok(r) => {
            let (status, b) = (r.status, r.body)
            let out = StringBuilder::new()
            out.write_string("HTTP/1.1 \{status} \{reason(status)}\r\n")
            for h in r.headers {
              let (k, v) = h
              if !p54_hop.contains(k.to_lower()) && k.to_lower() != "content-length" {
                out.write_string("\{k}: \{v}\r\n")
              }
            }
            out.write_string("content-length: \{b.length()}\r\n")
            if close {
              out.write_string("connection: close\r\n")
            }
            out.write_string("\r\n")
            p54_cat([@utf8.encode(out.to_string()), b])
          }
          Err(e) => {
            let words = @utf8.encode("the vault's proxy could not reach \{target_host}: \{p54_message(e)}\n")
            p54_cat([@utf8.encode("HTTP/1.1 502 Bad Gateway\r\ncontent-type: text/plain\r\ncontent-length: \{words.length()}\r\n\r\n"), words])
          }
        }
      }
    }
    write(answer)
    if close {
      return
    }
  }
}
