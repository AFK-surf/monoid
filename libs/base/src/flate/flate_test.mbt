// Inflate against what Node's zlib makes (stored, fixed and dynamic blocks, more than one block, zlib's and gzip's
// wrappings, a gzip head saying all it may, gzips one after another), and refusing what is damaged; deflate in one
// piece and a piece at a time read back whole, over the window's slide and past 64 KiB; Adler-32 against zlib's. On
// both targets.

///|
fn hex(s : String) -> Bytes {
  @codec.hex_decode(s).unwrap()
}

///|
/// The text Node deflated for the vectors below: 940 bytes.
fn fox() -> Bytes {
  let s = StringBuilder()
  for _ in 0..<20 {
    s.write_string("The quick brown fox jumps over the lazy dog. ")
  }
  s.write_string("Pack my box with five dozen liquor jugs!")
  @utf8.encode(s.to_string())
}

///|
/// `n` bytes of 16 letters, drawn by a congruence Node draws by too: little repeats, so many literals.
fn drawn(n : Int) -> Bytes {
  let mut s = 1
  Bytes::makei(n, _ => {
    s = (s * 75 + 74) % 65537
    (97 + s % 16).to_byte()
  })
}

///|
/// `n` bytes no match shortens much, a byte each from a congruence of 32 bits.
fn noise(n : Int) -> Bytes {
  let mut s = 0x12345678U
  Bytes::makei(n, _ => {
    s = s * 1664525U + 1013904223U
    (s >> 24).to_byte()
  })
}

///|
/// `data` deflated with a `Deflater` given it in pieces of `size`.
fn streamed(data : Bytes, size : Int) -> Bytes {
  let d = @flate.Deflater::new()
  let out = Buffer()
  let mut at = 0
  while at < data.length() {
    let end = if at + size < data.length() { at + size } else { data.length() }
    out.write_bytesview(d.push(data[at:end]))
    at = end
  }
  out.write_bytesview(d.finish())
  out.to_bytes()
}

///|
let fox_dynamic : String = "edcbb90180201005d156be0d588b010da022a0c02aa75abd5b8421f1bc1146e12a763930476a011bddd88b3f13a8aa88ccd9c9f7c14a7a84e8b8e38effc69364e71fcc8c9acd069bad8ad3ab029cbd0a457e751a3e"

///|
test "inflate reads Node's stored, fixed and dynamic blocks" {
  assert_eq(@flate.inflate(hex("010d00f2ff68656c6c6f2c2073746f726564")), Some(b"hello, stored"))
  assert_eq(@flate.inflate(hex("cb48cdc9c957c8409000")), Some(b"hello hello hello"))
  assert_eq(@flate.inflate(hex(fox_dynamic)), Some(fox()))
  assert_eq(@flate.inflate(hex(fox_dynamic), size=940), Some(fox()))
  assert_eq(@flate.inflate(hex(fox_dynamic), size=1), Some(fox()))
  // Node's empty deflate: one fixed block of its end alone
  assert_eq(@flate.inflate(hex("0300")), Some(b""))
}

///|
test "inflate reads Node's dynamic blocks one after another" {
  // deflateRawSync(drawn(1200), { memLevel: 1 }): more than one dynamic block, the first not the last
  let multi = [
    "0ccb3902c0300803b0b75220053b1cff9fda4d8bce8332db477aaa4453a86710a695797b6e629cd3317e72619388f9c58a4a6806dd37",
    "fdbf8b6d8a5e16695d6174f481ca6260be51c5c5a5f2354dddbb94045ae363700c6e00884118362b7040690bc9feafab94a765074a3d",
    "58c796e5f6aea614eb4abb32b6a885e6bc56c1603e4bd34fe0b27136eadd93bad94cd6a84feeb0a1ac687f083d626ef77d460dc6ba16",
    "22466f0c3e8bca69026f75f05340264900c420087cab5b349118ff7f1ae74a1534808454ec088591e92373eda116e32e635ff98405f4",
    "c63ec8b0c9abca1db746e00ca1f98fed859ce81680b7f9713a76523d39e560d6ba2d06ffa5585779afcba4f0ee1bd09082b8fe7855fa",
    "18a2931b8081100882b1722d983bff974960a4e9f209c642fc8205e081534f344f369baf7aa260c29b020d9804dc90c07af7daf7b631",
    "1f84ed41549d68ab5d5932775d0568ef682154d60efbaea3870a5a8ca3109fb79ca4d0ab48d35cfa2924730400421006be15390495e3",
    "ffd566eb1484999458df4db35b1e9fd5a91e971bffdf34dccf9356f3cad0dd724452a38e238af2931e2bc8618888c445f733b0e40b11",
    "97d5eb1f4b39b57292da345930aac263ee02e5a12d40150c6e0fda8bc25eae29a5e88f6232370220066160ad061b7cfcfd4727870430",
    "1ab41bc1dd57e7f13acc999c80263181b38f504616f5d8a1326c358b8ea38c5e6ac6fe0271dcba7209b480525820112e5b04022cbc43",
    "e9983d59c6d6f952c90a046b9368cd7384c5ba1b346c6063b7b612b928e1b2bea04ed11ec8bb7f8ec91c09821804626f75db800faeff",
    "47dbb3194586905e20c83148efd163c29a8ffa3c535319eab5c9f45273ecc9bdb588acb65d9d0924ab88cd6ee2ade5f5ff7652552cd1",
    "7da25ccdd3af8216dec267ef199f2e23c659acc31453eeb6a1284e04079bc42b3c9521a46ba30aa793bff53ebf0aca250b6010848167",
    "15e4674bf5feab8e5b16bc4026893aed32aafd4d02c50e8d11576e8ec5b4ebdbdb318fdfa471fca13a2ccadc801b3519e1ef24e04744",
    "afced9d352325af15d8d6a585fb7c45e8f2c3084f891a01f2ae044746be3b9fd",
  ]
  let deflated = hex(multi.join(""))
  assert_eq(deflated[0].to_int() & 7, 4)
  assert_eq(@flate.inflate(deflated), Some(drawn(1200)))
  assert_eq(@codec.crc32(drawn(1200)), 0xe28e3c56U)
}

///|
test "inflate_at says where the deflated bytes end" {
  let wrapped = hex("aabb" + fox_dynamic + "ccdd")
  let (out, end) = @flate.inflate_at(wrapped, 2).unwrap()
  assert_eq(out, fox())
  assert_eq(end, wrapped.length() - 2)
  assert_eq(@flate.inflate_at(wrapped, -1), None)
  assert_eq(@flate.inflate_at(wrapped, wrapped.length() + 1), None)
  // a stored block's bytes taken as they are, then what follows told
  let stored = hex("010d00f2ff68656c6c6f2c2073746f726564ff")
  assert_eq(@flate.inflate_at(stored, 0), Some((b"hello, stored", stored.length() - 1)))
}

///|
test "zlib's and gzip's wrappings as Node makes them" {
  let z = hex("789c" + fox_dynamic + "eb6551a6")
  assert_eq(@flate.zlib_decompress(z), Some(fox()))
  assert_eq(@flate.adler32(fox()), 0xeb6551a6U)
  let g = hex("1f8b0800000000000013" + fox_dynamic + "e0a8b68bac030000")
  assert_eq(@flate.gunzip(g), Some(fox()))
  assert_eq(@codec.crc32(fox()), 0x8bb6a8e0U)
  // a head with an extra field, a name, a comment and its own CRC-16
  let full = hex(
    "1f8b081e000000000003040041420200662e747874006120636f6d6d656e74006e4acb4bcc4d4d010087cce07105000000",
  )
  assert_eq(@flate.gunzip(full), Some(b"named"))
  // two gzips one after another are what both hold, padding after them let be
  let two = "1f8b0800000000000013cbcf4bd50100622d1a2a040000001f8b08000000000000132b29cf0700668aca1103000000"
  assert_eq(@flate.gunzip(hex(two)), Some(b"one,two"))
  assert_eq(@flate.gunzip(hex(two + "00000000")), Some(b"one,two"))
  // what is not padding is read as a gzip, as Node reads it, and refused
  assert_eq(@flate.gunzip(hex(two + "74")), None)
  assert_eq(@flate.gunzip(hex(two + "1f8b08")), None)
}

///|
test "Adler-32 against zlib's, a piece at a time, past the sums' bound" {
  assert_eq(@flate.adler32(b""), 1U)
  assert_eq(@flate.adler32(b"a"), 0x00620062U)
  assert_eq(@flate.adler32(b"Wikipedia"), 0x11E60398U)
  // (the Adler-32 Node's zlib.deflateSync puts after 100,000 bytes of 0xFF: sums kept past 32 bits would be wrong)
  let big = Bytes::make(100000, b'\xff')
  assert_eq(@flate.adler32(big), 0x149a302cU)
  for size in [1, 777, 5552, 5553, 65536] {
    let mut a = 1U
    let mut at = 0
    while at < big.length() {
      let end = if at + size < big.length() { at + size } else { big.length() }
      a = @flate.adler32_update(a, big[at:end])
      at = end
    }
    assert_eq(a, 0x149a302cU)
  }
}

///|
test "inflate refuses what is damaged, cut short or reaches back past its start" {
  // nothing, a block of the reserved kind, a stored length whose complement disagrees
  assert_eq(@flate.inflate(b""), None)
  assert_eq(@flate.inflate(hex("07")), None)
  assert_eq(@flate.inflate(hex("010d00f2fe68656c6c6f2c2073746f726564")), None)
  // stored bytes cut short
  assert_eq(@flate.inflate(hex("010d00f2ff68656c6c6f")), None)
  // a dynamic stream cut anywhere
  let d = hex(fox_dynamic)
  for n in 0..<d.length() {
    assert_eq(@flate.inflate(d[:n]), None)
  }
  // the last block never comes: a stored block not the last, then nothing
  assert_eq(@flate.inflate(hex("000000ffff")), None)
  // a fixed block whose first symbol is a match at distance 1 with nothing made yet
  assert_eq(@flate.inflate(hex("030200")), None)
  // a dynamic head over-subscribing its code lengths' code (every one of 19 a length of 1)
  assert_eq(@flate.inflate(hex("05e0932449922449920000000000")), None)
}

///|
test "the wrappings refuse a check that fails, a head not theirs and what is cut short" {
  let z = hex("789c" + fox_dynamic + "eb6551a6")
  let bad_adler = hex("789c" + fox_dynamic + "eb6551a7")
  assert_eq(@flate.zlib_decompress(bad_adler), None)
  assert_eq(@flate.zlib_decompress(z[:z.length() - 1]), None)
  assert_eq(@flate.zlib_decompress(hex("789d" + fox_dynamic + "eb6551a6")), None)
  assert_eq(@flate.zlib_decompress(hex("79dc" + fox_dynamic + "eb6551a6")), None)
  // a preset dictionary (FDICT) is not taken
  assert_eq(@flate.zlib_decompress(hex("78bb")), None)
  assert_eq(@flate.zlib_decompress(b""), None)
  let g = "1f8b0800000000000013" + fox_dynamic
  assert_eq(@flate.gunzip(hex(g + "e0a8b68bac030000")), Some(fox()))
  assert_eq(@flate.gunzip(hex(g + "e1a8b68bac030000")), None)
  assert_eq(@flate.gunzip(hex(g + "e0a8b68bad030000")), None)
  assert_eq(@flate.gunzip(hex(g + "e0a8b68bac0300")), None)
  assert_eq(@flate.gunzip(hex("1f8b0900000000000013" + fox_dynamic + "e0a8b68bac030000")), None)
  assert_eq(@flate.gunzip(hex("1f8b0820000000000013" + fox_dynamic + "e0a8b68bac030000")), None)
  assert_eq(@flate.gunzip(b""), None)
  // a head's own CRC-16 wrong, and a name with no end
  let full = "1f8b081e000000000003040041420200662e747874006120636f6d6d656e74006e4acb4bcc4d4d010087cce07105000000"
  let full = hex(full)
  assert_eq(@flate.gunzip(full), Some(b"named"))
  let wrong = Bytes::makei(full.length(), i => if i == 33 { full[i] ^ b'\x01' } else { full[i] })
  assert_eq(@flate.gunzip(wrong), None)
  assert_eq(@flate.gunzip(hex("1f8b0808000000000003662e747874")), None)
}

///|
test "deflate's bytes inflate back whole, whatever they are" {
  let cases : Array[Bytes] = [
    b"",
    b"a",
    b"hello hello hello",
    fox(),
    drawn(1200),
    Bytes::make(100000, b'z'),
    noise(5000),
    noise(70000),
    drawn(150000),
  ]
  for data in cases {
    let d = @flate.deflate(data)
    assert_eq(@flate.inflate(d), Some(data))
    assert_eq(@flate.zlib_decompress(@flate.zlib_compress(data)), Some(data))
    assert_eq(@flate.gunzip(@flate.gzip(data)), Some(data))
  }
  // what repeats is made much smaller, what does not grows by little more than stored blocks' heads
  assert_true(@flate.deflate(Bytes::make(100000, b'z')).length() < 1000)
  assert_true(@flate.deflate(fox()).length() < 200)
  assert_true(@flate.deflate(noise(70000)).length() <= 70000 + 5 * 2 + 1)
  // nothing is one fixed block of its end alone, as Node's
  assert_eq(@flate.deflate(b""), hex("0300"))
}

///|
test "a Deflater given pieces makes a stream that inflates whole, past 64 KiB and the window's slides" {
  let data = Buffer()
  data.write_bytesview(drawn(40000))
  data.write_bytesview(Bytes::make(30000, b'q'))
  data.write_bytesview(noise(20000))
  data.write_bytesview(drawn(40000))
  let data = data.to_bytes()
  for size in [1000, 4096, 32768, 65535, 65536, 100000, 200000] {
    let s = streamed(data, size)
    assert_eq(@flate.inflate(s), Some(data))
  }
  // what was given is made as it is given: each piece inflates so far without the end
  let d = @flate.Deflater::new()
  let first = d.push(fox())
  let more = d.push(fox())
  let end = d.finish()
  assert_true(more.length() < 40)
  let whole = Buffer()
  whole.write_bytesview(first)
  whole.write_bytesview(more)
  whole.write_bytesview(end)
  let twice = Buffer()
  twice.write_bytesview(fox())
  twice.write_bytesview(fox())
  assert_eq(@flate.inflate(whole.to_bytes()), Some(twice.to_bytes()))
  // nothing is made of nothing, nor after the end
  assert_eq(d.push(fox()), b"")
  assert_eq(d.finish(), b"")
  let e = @flate.Deflater::new()
  assert_eq(e.push(b""), b"")
  assert_eq(e.finish(), hex("0300"))
}
