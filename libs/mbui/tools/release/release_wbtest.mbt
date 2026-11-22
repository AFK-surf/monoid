// Whitebox tests for release tool: Ed25519/PEM, RFC 1951 deflate, SFDELTA1 bsdiff, feed, publish.

///|
test "ed25519 rfc8032 keygen sign verify and pkcs8 pem" {
  // RFC 8032 Section 7.1 Test 1
  let seed1 = hex_decode_exact(
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
  ).unwrap()
  let pk1 = ed25519_public_key(seed1)
  assert_eq(
    hex_encode(pk1),
    "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
  )
  let sig1 = ed25519_sign(seed1, b"")
  assert_eq(
    hex_encode(sig1),
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155" +
    "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
  )
  assert_true(ed25519_verify(pk1, b"", sig1))

  // RFC 8032 Section 7.1 Test 2
  let seed2 = hex_decode_exact(
    "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
  ).unwrap()
  let pk2 = ed25519_public_key(seed2)
  assert_eq(
    hex_encode(pk2),
    "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
  )
  let sig2 = ed25519_sign(seed2, b"\x72")
  assert_eq(
    hex_encode(sig2),
    "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da" +
    "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
  )
  assert_true(ed25519_verify(pk2, b"\x72", sig2))
  assert_false(ed25519_verify(pk2, b"\x73", sig2))

  // PKCS#8 PEM round-trip
  let pem = encode_pkcs8_pem(seed1)
  assert_true(pem.contains("-----BEGIN PRIVATE KEY-----"))
  match decode_private_key(pem) {
    Ok(decoded) => assert_eq(hex_encode(decoded), hex_encode(seed1))
    Err(e) => fail("pem decode failed: \{e}")
  }
  // Raw base64 32-byte seed decode
  match decode_private_key(base64_encode(seed2)) {
    Ok(decoded) => assert_eq(hex_encode(decoded), hex_encode(seed2))
    Err(e) => fail("raw seed decode failed: \{e}")
  }
}

///|
/// Minimal raw RFC 1951 fixed/stored inflater for whitebox round-trip verification.
fn test_inflate_raw(data : Bytes) -> Bytes {
  let out : Array[Byte] = []
  let mut pos = 0
  let mut bits = 0
  let mut nbits = 0
  let get_bits = fn(k : Int) -> Int {
    while nbits < k {
      bits = bits | (data[pos].to_int() << nbits)
      pos += 1
      nbits += 8
    }
    let v = bits & ((1 << k) - 1)
    bits = bits >> k
    nbits -= k
    v
  }
  let get_rev = fn(k : Int) -> Int {
    let mut r = 0
    for _ in 0..<k {
      r = (r << 1) | get_bits(1)
    }
    r
  }
  let mut done = false
  while !done {
    let bfinal = get_bits(1)
    let btype = get_bits(2)
    done = bfinal == 1
    if btype == 0 {
      pos -= nbits / 8
      bits = 0
      nbits = 0
      let len = data[pos].to_int() | (data[pos + 1].to_int() << 8)
      pos += 4
      for i in 0..<len {
        out.push(data[pos + i])
      }
      pos += len
    } else if btype == 1 {
      while true {
        // Decode fixed Huffman literal/length symbol
        let c7 = get_rev(7)
        let sym = if c7 <= 23 {
          256 + c7
        } else {
          let c8 = (c7 << 1) | get_bits(1)
          if c8 >= 48 && c8 <= 191 {
            c8 - 48
          } else if c8 >= 192 && c8 <= 199 {
            280 + (c8 - 192)
          } else {
            let c9 = (c8 << 1) | get_bits(1)
            144 + (c9 - 400)
          }
        }
        if sym < 256 {
          out.push(sym.to_byte())
        } else if sym == 256 {
          break
        } else {
          let li = sym - 257
          let length = len_base[li] +
            (if len_extra[li] > 0 { get_bits(len_extra[li]) } else { 0 })
          let di = get_rev(5)
          let dist = dist_base[di] +
            (if dist_extra[di] > 0 { get_bits(dist_extra[di]) } else { 0 })
          for _ in 0..<length {
            let b = out[out.length() - dist]
            out.push(b)
          }
        }
      }
    } else {
      break
    }
  }
  Bytes::makei(out.length(), fn(i) { out[i] })
}

///|
test "deflate_raw compresses repetitive data and round-trips cleanly" {
  let sb = StringBuilder()
  for i in 0..<200 {
    sb.write_string("hello world delta stream block \{i % 7}\n")
  }
  let raw = @utf8.encode(sb.to_string())
  let packed = deflate_raw(raw)
  assert_true(packed.length() < raw.length() / 2)
  let inflated = test_inflate_raw(packed)
  assert_eq(sha256_hex(inflated), sha256_hex(raw))
  assert_eq(inflated.length(), raw.length())

  // Empty data
  let empty_packed = deflate_raw(b"")
  assert_eq(test_inflate_raw(empty_packed).length(), 0)
}

///|
fn read_i64_le(b : Bytes, at : Int) -> Int64 {
  let mut u = 0UL
  for k in 0..<8 {
    u = u | (b[at + k].to_uint64() << (8 * k))
  }
  u.reinterpret_as_int64()
}

///|
fn test_apply_bsdiff(
  old_blob : Bytes,
  patch : Bytes,
  made_size : Int,
) -> Bytes raise {
  let out = FixedArray::make(made_size, b'\x00')
  let mut o = 0
  let mut p = 0L
  let mut at = 0
  while at < patch.length() {
    let x = read_i64_le(patch, at).to_int()
    let y = read_i64_le(patch, at + 8).to_int()
    let z = read_i64_le(patch, at + 16)
    at += 24
    for i in 0..<x {
      let old_b = if p >= 0L && p < old_blob.length().to_int64() {
        old_blob[p.to_int()].to_int()
      } else {
        0
      }
      out[o] = ((patch[at + i].to_int() + old_b) & 0xFF).to_byte()
      o += 1
      p += 1L
    }
    at += x
    for i in 0..<y {
      out[o] = patch[at + i]
      o += 1
    }
    at += y
    p += z
  }
  assert_eq(o, made_size)
  Bytes::makei(made_size, fn(i) { out[i] })
}

///|
test "bsdiff_stream and encode_sfdelta1 reconstruct target exactly" {
  let old_a = Bytes::makei(4096, fn(i) { ((i * 31 + 7) & 0xFF).to_byte() })
  let old_b = Bytes::makei(2048, fn(i) { ((i * 17 + 3) & 0xFF).to_byte() })
  // Build new target: old_a with small edits + inserted bytes + old_b
  let new_arr : Array[Byte] = []
  for i in 0..<4096 {
    let v = if i >= 1000 && i < 1020 { (i & 0xFF).to_byte() } else { old_a[i] }
    new_arr.push(v)
  }
  for i in 0..<64 {
    new_arr.push((0xA0 + (i & 0x1F)).to_byte())
  }
  for i in 0..<2048 {
    new_arr.push(old_b[i])
  }
  let new_bytes = Bytes::makei(new_arr.length(), fn(i) { new_arr[i] })

  // Direct bsdiff round-trip
  let old_concat = Bytes::makei(4096 + 2048, fn(i) {
    if i < 4096 {
      old_a[i]
    } else {
      old_b[i - 4096]
    }
  })
  let patch = bsdiff_stream(old_concat, new_bytes)
  let rebuilt = test_apply_bsdiff(old_concat, patch, new_bytes.length())
  assert_eq(sha256_hex(rebuilt), sha256_hex(new_bytes))

  // SFDELTA1 container check
  let delta = match encode_sfdelta1([("bin/app", old_a), ("res/data", old_b)], new_bytes) {
    Ok(d) => d
    Err(e) => fail("encode_sfdelta1 failed: \{e}")
  }
  // Magic is SFDELTA1 and delta is much smaller than new_bytes
  assert_eq(@utf8.decode_lossy(delta[0:8]), "SFDELTA1")
  assert_true(delta.length() < new_bytes.length() / 4)
}

///|
test "feed generation, verification, and ordered publish plan" {
  let seed = hex_decode_exact(
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
  ).unwrap()
  let pk_b64 = base64_encode(ed25519_public_key(seed))
  let art_bytes = Bytes::makei(1024, fn(i) { (i & 0xFF).to_byte() })
  let small_delta = b"delta-bytes"
  let big_delta = Bytes::makei(2048, fn(_) { b'\x01' })

  let (feed_json, warnings) = match build_feed_json_pure(
    "app-10.zip",
    art_bytes,
    "1.0.10",
    10,
    "desktop-mac",
    Some(seed),
    None,
    [(9, "9-to-10.delta", small_delta), (8, "8-to-10.delta", big_delta)],
  ) {
    Ok(v) => v
    Err(e) => fail("build_feed_json_pure failed: \{e}")
  }
  assert_eq(warnings.length(), 1)
  assert_true(feed_json.contains("9-to-10.delta"))
  assert_false(feed_json.contains("8-to-10.delta"))

  // Verify generated latest.json
  match verify_json_text(feed_json, pk_b64, "desktop-mac") {
    Ok(msg) => assert_true(msg.contains("verified app-10.zip"))
    Err(e) => fail("verify failed: \{e}")
  }
  // Wrong kind must fail
  assert_true(verify_json_text(feed_json, pk_b64, "desktop-win") is Err(_))

  // Ordered publish: latest.json MUST be last
  let ordered = ordered_publish_names(["latest.json", "app-10.zip", "9-to-10.delta"])
  assert_eq(ordered, ["9-to-10.delta", "app-10.zip", "latest.json"])

  // S3 publish plan puts latest.json last with no-cache and endpoint-url
  let s3_steps = match plan_publish_commands(
    "/rel",
    ordered,
    "s3",
    "s3://bucket/releases/",
    "",
    "https://r2.example.com",
  ) {
    Ok(s) => s
    Err(e) => fail("s3 plan failed: \{e}")
  }
  assert_eq(s3_steps.length(), 3)
  assert_true(s3_steps[0].contains("immutable"))
  assert_true(s3_steps[2].contains("latest.json"))
  assert_true(s3_steps[2].contains("no-cache"))
  assert_true(s3_steps[2].contains("--endpoint-url"))

  // GitHub publish plan puts latest.json last
  let gh_steps = match plan_publish_commands(
    "/rel",
    ordered,
    "github",
    "org/repo",
    "v1.0.10",
    "",
  ) {
    Ok(s) => s
    Err(e) => fail("gh plan failed: \{e}")
  }
  assert_eq(gh_steps.length(), 3)
  assert_true(gh_steps[2].contains("latest.json"))
  assert_true(gh_steps[2].contains("--repo"))
}
