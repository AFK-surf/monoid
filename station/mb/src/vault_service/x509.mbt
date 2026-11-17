// The certificates the keeper's proxy shows (station/src/vault/x509.ts): its own CA, made once and kept in the
// station's data directory, and a short-lived certificate for each host a grant is for, signed by it. The DER is
// written here: ECDSA P-256 with SHA-256, and the extensions strict verifiers ask for (key identifiers, a critical
// basic constraint and key usage on the CA). The keys and their signatures are the machine's (machine.mbt).

///|
let day_ms : Double = 86400000.0

///|
fn der_length(n : Int) -> Bytes {
  if n < 0x80 {
    return Bytes::make(1, n.to_byte())
  }
  let bytes : Array[Byte] = []
  let mut v = n
  while v > 0 {
    bytes.insert(0, (v & 0xff).to_byte())
    v = v / 256
  }
  Bytes::from_array([(0x80 | bytes.length()).to_byte(), ..bytes])
}

///|
fn cat(parts : Array[Bytes]) -> Bytes {
  let b = Buffer()
  for p in parts {
    b.write_bytes(p)
  }
  b.to_bytes()
}

///|
fn tlv(tag : Int, content : Array[Bytes]) -> Bytes {
  let body = cat(content)
  cat([Bytes::make(1, tag.to_byte()), der_length(body.length()), body])
}

///|
fn der_seq(parts : Array[Bytes]) -> Bytes {
  tlv(0x30, parts)
}

///|
fn der_set(parts : Array[Bytes]) -> Bytes {
  tlv(0x31, parts)
}

///|
fn explicit(n : Int, parts : Array[Bytes]) -> Bytes {
  tlv(0xa0 + n, parts)
}

///|
fn octets(b : Bytes) -> Bytes {
  tlv(0x04, [b])
}

///|
fn der_bits(b : Bytes, unused? : Int = 0) -> Bytes {
  tlv(0x03, [Bytes::make(1, unused.to_byte()), b])
}

///|
let der_yes : Bytes = tlv(0x01, [b"\xff"])

///|
/// A non-negative INTEGER from its big-endian bytes.
fn der_integer(b : Bytes) -> Bytes {
  let mut i = 0
  while i < b.length() - 1 && b[i] == b'\x00' {
    i += 1
  }
  let v = sub(b, i, b.length())
  if v.length() > 0 && (v[0].to_int() & 0x80) != 0 {
    tlv(0x02, [b"\x00", v])
  } else {
    tlv(0x02, [v])
  }
}

///|
fn oid(dotted : String) -> Bytes {
  let ns = dotted.split(".").map(s => digits_int(s.to_string()).unwrap_or(0)).collect()
  let out : Array[Byte] = [(ns[0] * 40 + ns[1]).to_byte()]
  for k in 2..<ns.length() {
    let groups : Array[Int] = []
    let mut v = ns[k]
    while true {
      groups.insert(0, v % 128)
      if v < 128 {
        break
      }
      v = v / 128
    }
    for i, g in groups {
      out.push((if i < groups.length() - 1 { g | 0x80 } else { g }).to_byte())
    }
  }
  tlv(0x06, [Bytes::from_array(out)])
}

///|
/// UTCTime until 2050, GeneralizedTime after, as RFC 5280 has it.
fn der_time(ms : Double) -> Bytes {
  let iso = iso_ms(ms)
  let digits = replace_all(replace_all(replace_all(slice(iso, 0, b=19), "-", ""), ":", ""), "T", "")
  let year = digits_int(slice(iso, 0, b=4)).unwrap_or(0)
  if year < 2050 {
    tlv(0x17, [ascii(slice(digits, 2) + "Z")])
  } else {
    tlv(0x18, [ascii(digits + "Z")])
  }
}

///|
fn der_name(cn : String) -> Bytes {
  der_seq([der_set([der_seq([oid("2.5.4.3"), tlv(0x0c, [utf8_of(cn)])])])])
}

///|
fn extension(id : String, critical : Bool, value : Bytes) -> Bytes {
  der_seq(if critical { [oid(id), der_yes, octets(value)] } else { [oid(id), octets(value)] })
}

///|
fn ecdsa_sha256() -> Bytes {
  der_seq([oid("1.2.840.10045.4.3.2")])
}

///|
/// A P-256 key's SubjectPublicKeyInfo (id-ecPublicKey, prime256v1, its point).
fn spki(key : KeyRef) -> Bytes {
  der_seq([
    der_seq([oid("1.2.840.10045.2.1"), oid("1.2.840.10045.3.1.7")]),
    der_bits(key.public[0]),
  ])
}

///|
/// A key's identifier: the SHA-1 of its point, as RFC 5280 suggests.
async fn key_id(m : Machine, key : KeyRef) -> Bytes {
  (m.sha1)(key.public[0])
}

///|
/// A certificate for `key`'s public half named `cn`, signed with `issuer`'s key (its own when there is none).
async fn certificate(
  m : Machine,
  cn : String,
  key : KeyRef,
  issuer : (String, KeyRef)?,
  extensions : Array[Bytes],
  from : Double,
  to : Double,
) -> Bytes {
  let r = (m.random)(16)
  let serial = Bytes::makei(16, i => if i == 0 {
    (0x40 | (r[0].to_int() & 0x3f)).to_byte()
  } else {
    r[i]
  })
  let tbs = der_seq([
    explicit(0, [der_integer(b"\x02")]),
    der_integer(serial),
    ecdsa_sha256(),
    der_name(
      match issuer {
        Some((icn, _)) => icn
        None => cn
      },
    ),
    der_seq([der_time(from), der_time(to)]),
    der_name(cn),
    spki(key),
    explicit(3, [der_seq(extensions)]),
  ])
  let signer = match issuer {
    Some((_, k)) => k
    None => key
  }
  let signature = (m.sign)(signer, "sha256", tbs)
  der_seq([tbs, ecdsa_sha256(), der_bits(signature)])
}

///|
/// A new CA: its certificate's DER and its private key, good for ten years from `now`.
pub async fn make_ca(m : Machine, now : Double, cn : String) -> (Bytes, KeyRef) {
  let key = (m.p256_new)()
  let id = key_id(m, key)
  let extensions = [
    extension("2.5.29.19", true, der_seq([der_yes])),
    // digitalSignature, keyCertSign, cRLSign.
    extension("2.5.29.15", true, der_bits(b"\x86", unused=1)),
    extension("2.5.29.14", false, octets(id)),
  ]
  (
    certificate(m, cn, key, None, extensions, now - day_ms, now + 3650.0 * day_ms),
    key,
  )
}

///|
/// A certificate for `host` signed by `ca`, good for a week from `now`, with a key of its own.
pub async fn make_leaf(m : Machine, ca : (Bytes, KeyRef), ca_name : String, host : String, now : Double) -> (Bytes, KeyRef) {
  let key = (m.p256_new)()
  let extensions = [
    extension("2.5.29.19", true, der_seq([])),
    // digitalSignature.
    extension("2.5.29.15", true, der_bits(b"\x80", unused=7)),
    extension("2.5.29.37", false, der_seq([oid("1.3.6.1.5.5.7.3.1")])),
    extension("2.5.29.17", false, der_seq([tlv(0x82, [ascii(host)])])),
    extension("2.5.29.14", false, octets(key_id(m, key))),
    extension("2.5.29.35", false, der_seq([tlv(0x80, [key_id(m, ca.1)])])),
  ]
  (
    certificate(m, host, key, Some((ca_name, ca.1)), extensions, now - day_ms, now + 7.0 * day_ms),
    key,
  )
}
