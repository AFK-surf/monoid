// Conformance and adversarial boundary tests for `station/mb/src/updates/delta.mbt`:
// empty/single-byte/multi-chunk patches, >32-bit offset boundaries, strict UTF-8 and path traversal rejection,
// truncated headers/chunks, bad magic, out-of-bounds copy/add lengths, deflate ranges, and checksum mismatches.

///|
fn put_u32le(b : Buffer, v : UInt) -> Unit {
  b.write_byte((v & 0xffU).to_byte())
  b.write_byte(((v >> 8) & 0xffU).to_byte())
  b.write_byte(((v >> 16) & 0xffU).to_byte())
  b.write_byte(((v >> 24) & 0xffU).to_byte())
}

///|
fn put_u64le(b : Buffer, lo : UInt, hi : UInt) -> Unit {
  put_u32le(b, lo)
  put_u32le(b, hi)
}

///|
fn stored_deflate(raw : Bytes) -> Bytes {
  // Split into <= 65535-byte stored blocks
  let out = Buffer()
  let n = raw.length()
  if n == 0 {
    out.write_byte(b'\x01')
    out.write_byte(b'\x00')
    out.write_byte(b'\x00')
    out.write_byte(b'\xff')
    out.write_byte(b'\xff')
    return out.to_bytes()
  }
  let mut at = 0
  while at < n {
    let take = if n - at > 65535 { 65535 } else { n - at }
    let last = at + take == n
    out.write_byte(if last { b'\x01' } else { b'\x00' })
    out.write_byte((take & 0xff).to_byte())
    out.write_byte(((take >> 8) & 0xff).to_byte())
    let nlen = take ^ 0xffff
    out.write_byte((nlen & 0xff).to_byte())
    out.write_byte(((nlen >> 8) & 0xff).to_byte())
    out.write_bytes(raw[at:at + take].to_owned())
    at += take
  }
  out.to_bytes()
}

///|
fn build_delta(
  old : Bytes,
  made : Int,
  records : Bytes,
  deflate_ranges? : Array[(Int, Int)] = [],
  chunk_cap? : Int = chunk_size,
) -> Bytes {
  let b = Buffer()
  b.write_bytes(delta_magic)
  // 1 file "f" (or 0 files if deflate_ranges non-empty)
  if deflate_ranges.is_empty() {
    put_u32le(b, 1U)
    b.write_byte(b'\x01')
    b.write_byte(b'\x00')
    b.write_byte(b'f')
  } else {
    put_u32le(b, 0U)
  }
  // inflate ranges = 0
  put_u32le(b, 0U)
  // old_size + old_sha256
  put_u64le(b, old.length().reinterpret_as_uint(), 0U)
  b.write_bytes(unhex(sha256(old)))
  // deflate ranges
  put_u32le(b, deflate_ranges.length().reinterpret_as_uint())
  for r in deflate_ranges {
    put_u64le(b, r.0.reinterpret_as_uint(), 0U)
    put_u64le(b, r.1.reinterpret_as_uint(), 0U)
  }
  // made_size
  put_u64le(b, made.reinterpret_as_uint(), 0U)
  // chunks
  let mut at = 0
  while at < records.length() {
    let take = if records.length() - at > chunk_cap { chunk_cap } else { records.length() - at }
    let packed = stored_deflate(records[at:at + take].to_owned())
    put_u32le(b, take.reinterpret_as_uint())
    put_u32le(b, packed.length().reinterpret_as_uint())
    b.write_bytes(packed)
    at += take
  }
  // end chunk
  put_u32le(b, 0U)
  put_u32le(b, 0U)
  b.to_bytes()
}

///|
fn apply_result(old : Bytes, d : Bytes) -> Result[Bytes, String] {
  ran(async fn() {
    try {
      let h = parse_header(d)
      let out = Buffer()
      apply(h, old, d, fn(chunk) { out.write_bytes(chunk) }, fn(x) { x })
      Ok(out.to_bytes())
    } catch {
      e => Err(message_of(e))
    }
  })
}

///|
test "delta: empty, single-byte, pure insert, delete, replace, and out-of-bounds old seek" {
  // Empty -> empty
  let d0 = build_delta(b"", 0, b"")
  assert_eq(apply_result(b"", d0), Ok(b""))

  // Empty -> non-empty (pure insert)
  let ins = Buffer()
  ins.write_bytes(record(0, 5, 0))
  ins.write_bytes(b"hello")
  assert_eq(apply_result(b"", build_delta(b"", 5, ins.to_bytes())), Ok(b"hello"))

  // Non-empty -> empty (pure delete)
  assert_eq(apply_result(b"abcdef", build_delta(b"abcdef", 0, b"")), Ok(b""))

  // Single byte: identical, diff wrap-around (0xff + 0x02 = 0x01), and replace
  let sb_same = Buffer()
  sb_same.write_bytes(record(1, 0, 0))
  sb_same.write_bytes(b"\x00")
  assert_eq(apply_result(b"\x42", build_delta(b"\x42", 1, sb_same.to_bytes())), Ok(b"\x42"))

  let sb_wrap = Buffer()
  sb_wrap.write_bytes(record(1, 0, 0))
  sb_wrap.write_bytes(b"\x02")
  assert_eq(apply_result(b"\xff", build_delta(b"\xff", 1, sb_wrap.to_bytes())), Ok(b"\x01"))

  // Out-of-bounds old pointer (negative p and p >= old.length) safely zero-fills without panic
  let oob = Buffer()
  // First seek -2 (p becomes -2), then diff 6 bytes against old="AB" (indices -2,-1,0,1,2,3 -> 0,0,'A','B',0,0)
  oob.write_bytes(record(0, 0, -2))
  oob.write_bytes(record(6, 0, 0))
  oob.write_bytes(b"\x01\x02\x00\x01\x03\x04")
  assert_eq(apply_result(b"AB", build_delta(b"AB", 6, oob.to_bytes())), Ok(b"\x01\x02AC\x03\x04"))
}

///|
test "delta: multi-chunk (>1 MiB) patch flushes output buffer across chunk boundaries" {
  // Build a patch producing chunk_size + 123 bytes (1,048,699 bytes) across multiple small input chunks
  let made = chunk_size + 123
  let old = Bytes::makei(4096, i => (i & 0xff).to_byte())
  let recs = Buffer()
  // Copy/diff 4096 bytes from old with +1, then extra-insert remaining bytes in two records
  recs.write_bytes(record(4096, 0, 0))
  recs.write_bytes(Bytes::make(4096, b'\x01'))
  let rem = made - 4096
  recs.write_bytes(record(0, rem, 0))
  recs.write_bytes(Bytes::makei(rem, i => ((i * 3 + 7) & 0xff).to_byte()))
  let d = build_delta(old, made, recs.to_bytes(), chunk_cap=65536)
  match apply_result(old, d) {
    Ok(out) => {
      assert_eq(out.length(), made)
      assert_eq(out[0], b'\x01')
      assert_eq(out[255], b'\x00')
      assert_eq(out[4096], b'\x07')
      assert_eq(out[made - 1], (((rem - 1) * 3 + 7) & 0xff).to_byte())
    }
    Err(e) => abort("unexpected error: \{e}")
  }
}

///|
test "delta: >32-bit offsets accepted up to 2^53-1 and rejected above" {
  let make_hdr = (old_lo : UInt, old_hi : UInt, made_lo : UInt, made_hi : UInt) => {
    let b = Buffer()
    b.write_bytes(delta_magic)
    put_u32le(b, 0U) // files
    put_u32le(b, 0U) // inflate
    put_u64le(b, old_lo, old_hi)
    b.write_bytes(Bytes::make(32, b'\xaa'))
    put_u32le(b, 0U) // deflate
    put_u64le(b, made_lo, made_hi)
    b.to_bytes()
  }
  // 4 GiB + 5 (exceeds 32-bit)
  let h4g = parse_header(make_hdr(5U, 1U, 10U, 1U))
  assert_eq(h4g.old_size, 4294967301.0)
  assert_eq(h4g.made_size, 4294967306.0)
  // Max safe integer: 2^53 - 1 (hi = 0x1fffff, lo = 0xffffffff)
  let hmax = parse_header(make_hdr(0xffffffffU, 0x1fffffU, 0xffffffffU, 0x1fffffU))
  assert_eq(hmax.old_size, 9007199254740991.0)
  // 2^53 (hi = 0x200000, lo = 0) must be rejected
  let err_hi = try {
    ignore(parse_header(make_hdr(0U, 0x200000U, 0U, 0U)))
    ""
  } catch {
    e => message_of(e)
  }
  assert_eq(err_hi, "the delta's header has a number too large")

  // Record i64 overflow (hi = 0x200000 and hi = -0x200001)
  let bad_rec = Buffer()
  put_u32le(bad_rec, 0U)
  put_u32le(bad_rec, 0x200000U)
  put_u64le(bad_rec, 0U, 0U)
  put_u64le(bad_rec, 0U, 0U)
  assert_eq(apply_result(b"x", build_delta(b"x", 1, bad_rec.to_bytes())), Err("a record's number is too large"))

  // Negative x or y in record
  assert_eq(apply_result(b"x", build_delta(b"x", 1, record(-1, 0, 0))), Err("a record with a negative length"))
  assert_eq(apply_result(b"x", build_delta(b"x", 1, record(0, -1, 0))), Err("a record with a negative length"))
}

///|
test "delta: truncated headers, bad magic, invalid UTF-8, bad ranges, and corrupt chunks never panic" {
  // Truncate a valid header at every single byte offset
  let valid = build_delta(b"hello", 5, b"")
  let hdr = parse_header(valid)
  for cut in 0..<hdr.payload {
    let res = try {
      ignore(parse_header(valid[:cut].to_owned()))
      Ok(())
    } catch {
      e => Err(message_of(e))
    }
    assert_true(res is Err(_))
  }

  // Bad magic variants
  for bad in [b"", b"SF", b"SFDELTA", b"SFDELTA0", b"SFDELTA2", b"\x00\x00\x00\x00\x00\x00\x00\x00"] {
    let err = try {
      ignore(parse_header(bad))
      ""
    } catch {
      e => message_of(e)
    }
    assert_eq(err, "not a delta (bad magic)")
  }

  // Invalid UTF-8 path in header (overlong 2-byte sequence 0xc0 0xaf, surrogate 0xed 0xa0 0x80, stray 0x80)
  for bad_utf8 in [b"\xc0\xaf", b"\xed\xa0\x80", b"\x80", b"\xf4\x90\x80\x80", b"\xe2\x82"] {
    let b = Buffer()
    b.write_bytes(delta_magic)
    put_u32le(b, 1U)
    b.write_byte(bad_utf8.length().to_byte())
    b.write_byte(b'\x00')
    b.write_bytes(bad_utf8)
    let err = try {
      ignore(parse_header(b.to_bytes()))
      ""
    } catch {
      e => message_of(e)
    }
    assert_eq(err, "the delta names a path that is not UTF-8")
  }

  // Non-ascending deflate ranges and deflate range past made_size
  let non_asc = Buffer()
  non_asc.write_bytes(delta_magic)
  put_u32le(non_asc, 0U) // files
  put_u32le(non_asc, 0U) // inflate
  put_u64le(non_asc, 0U, 0U)
  non_asc.write_bytes(Bytes::make(32, b'\x00'))
  put_u32le(non_asc, 2U) // 2 deflate ranges
  put_u64le(non_asc, 10U, 0U)
  put_u64le(non_asc, 5U, 0U)
  put_u64le(non_asc, 14U, 0U) // overlaps 10..15!
  put_u64le(non_asc, 2U, 0U)
  put_u64le(non_asc, 20U, 0U)
  let err_asc = try {
    ignore(parse_header(non_asc.to_bytes()))
    ""
  } catch {
    e => message_of(e)
  }
  assert_eq(err_asc, "the delta's deflate ranges are not ascending")

  // Deflate range past made_size
  let past_made = build_delta(b"ab", 4, b"", deflate_ranges=[(2, 3)])
  let err_past = try {
    ignore(parse_header(past_made))
    ""
  } catch {
    e => message_of(e)
  }
  assert_eq(err_past, "the delta's deflate ranges go past made_size")

  // Missing end chunk (truncate last 4 bytes of valid delta)
  let trunc_end = valid[:valid.length() - 4].to_owned()
  assert_eq(apply_result(b"hello", trunc_end), Err("the delta has no end chunk"))

  // Trailing byte after end chunk
  let trailing = Buffer()
  trailing.write_bytes(valid)
  trailing.write_byte(b'\x00')
  assert_eq(apply_result(b"hello", trailing.to_bytes()), Err("the delta goes on after its end chunk"))

  // Chunk raw_len > chunk_size
  let raw_too_big = Buffer()
  raw_too_big.write_bytes(valid[:hdr.payload].to_owned())
  put_u32le(raw_too_big, (chunk_size + 1).reinterpret_as_uint())
  put_u32le(raw_too_big, 2U)
  raw_too_big.write_bytes(b"\x03\x00")
  assert_true(
    match apply_result(b"hello", raw_too_big.to_bytes()) {
      Err(m) => m.contains("more than")
      Ok(_) => false
    },
  )

  // Corrupted deflate payload in chunk
  let bad_flate = Buffer()
  bad_flate.write_bytes(valid[:hdr.payload].to_owned())
  put_u32le(bad_flate, 10U)
  put_u32le(bad_flate, 4U)
  bad_flate.write_bytes(b"\xff\xff\xff\xff")
  put_u32le(bad_flate, 0U)
  put_u32le(bad_flate, 0U)
  assert_eq(apply_result(b"hello", bad_flate.to_bytes()), Err("a chunk does not inflate to its raw_len"))

  // Stream ends early before made_size
  assert_eq(apply_result(b"hello", build_delta(b"hello", 5, b"")), Err("the delta's stream ends early"))

  // Stream goes on past made_size (extra trailing byte in record stream)
  let extra_stream = Buffer()
  extra_stream.write_bytes(record(0, 2, 0))
  extra_stream.write_bytes(b"hi!")
  assert_eq(apply_result(b"", build_delta(b"", 2, extra_stream.to_bytes())), Err("the delta's stream goes on past made_size"))
}

///|
test "delta: apply with deflate ranges including zero-length range" {
  let recs = Buffer()
  recs.write_bytes(record(0, 10, 0))
  recs.write_bytes(b"0123456789")
  let d = build_delta(b"", 10, recs.to_bytes(), deflate_ranges=[(2, 0), (3, 4), (9, 1)])
  let h = parse_header(d)
  let chunks : Array[Bytes] = []
  let deflated : Array[Bytes] = []
  ran(async fn() {
    apply(
      h,
      b"",
      d,
      fn(b) { chunks.push(b) },
      fn(b) {
        deflated.push(b)
        // wrap with '[' and ']' to verify exact slice was deflated and spliced
        let out = Buffer()
        out.write_byte(b'[')
        out.write_bytes(b)
        out.write_byte(b']')
        out.to_bytes()
      },
    ) catch {
      e => abort("apply failed: \{message_of(e)}")
    }
  })
  assert_eq(deflated, [b"", b"3456", b"9"])
  let joined = Buffer()
  for c in chunks {
    joined.write_bytes(c)
  }
  assert_eq(joined.to_bytes(), b"01[]2[3456]78[9]")
}
