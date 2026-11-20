// Conformance tests for `station/mb/src/packed` (Zstd Seekable Format v0.1.0 + workspace tar ask validation):
// empty archives, multi-frame & 32-bit boundary sizes, checksummed 12-byte entries,
// reserved descriptor bit rejection, truncated/tampered tables and headers without panics.

///|
fn make_checksum_table(frames : Array[(Int64, Int64, Int64)]) -> Bytes {
  let length = 8 + frames.length() * 12 + footer
  let out = FixedArray::make(length, b'\x00')
  put32(out, 0, skippable)
  put32(out, 4, (length - 8).to_int64())
  for i, f in frames {
    put32(out, 8 + i * 12, f.0)
    put32(out, 12 + i * 12, f.1)
    put32(out, 16 + i * 12, f.2)
  }
  let end = 8 + frames.length() * 12
  put32(out, end, frames.length().to_int64())
  out[end + 4] = b'\x80'
  put32(out, end + 5, seekable)
  Bytes::from_array(out)
}

///|
test "seekable format: empty archive, single zero-content frame, and many frames round-trip" {
  // 0 frames (empty archive)
  let empty = seek_table([])
  assert_eq(empty.length(), 17)
  guard table_length(17L, empty[8:]) is Some((len0, entry0)) else { fail("expected empty table") }
  assert_eq(len0, 17L)
  assert_eq(entry0, 8L)
  assert_eq(frames_in(17L, empty[:], entry0).map(fs => fs.length()), Some(0))

  // Single frame with 0 decompressed bytes
  let zf = seek_table([(9L, 0L)])
  let zsize = 9L + zf.length().to_int64()
  guard table_length(zsize, zf[zf.length() - footer:]) is Some((zlen, zent)) else { fail("expected table") }
  let zframes = frames_in(zsize, zf[:], zent).map(fs => fs.map(f => (f.at, f.packed, f.from, f.size)))
  assert_eq(zframes, Some([(0L, 9L, 0L, 0L)]))

  // 100 frames with varying sizes
  let pairs : Array[(Int64, Int64)] = []
  let mut total_packed = 0L
  let mut total_raw = 0L
  for i in 0..<100 {
    let p = (i * 13 + 7).to_int64()
    let r = (i * 97 + 1).to_int64()
    pairs.push((p, r))
    total_packed += p
    total_raw += r
  }
  let many = seek_table(pairs)
  let msize = total_packed + many.length().to_int64()
  guard table_length(msize, many[many.length() - footer:]) is Some((mlen, ment)) else { fail("expected many table") }
  assert_eq(mlen, many.length().to_int64())
  assert_eq(ment, 8L)
  guard frames_in(msize, many[:], ment) is Some(parsed) else { fail("expected parsed frames") }
  assert_eq(parsed.length(), 100)
  let last = parsed[99]
  assert_eq(last.at + last.packed, total_packed)
  assert_eq(last.from + last.size, total_raw)
}

///|
test "seekable format: 32-bit unsigned boundary sizes and 12-byte checksummed entries" {
  // Unsigned 32-bit max (0xffffffff) must not sign-extend to negative
  let big_packed = 0xffffffffL
  let big_raw = 0x80000001L
  let t = seek_table([(big_packed, big_raw)])
  let size = big_packed + t.length().to_int64()
  guard table_length(size, t[t.length() - footer:]) is Some((tlen, ent)) else { fail("expected big table") }
  assert_eq(tlen, 25L)
  let parsed = frames_in(size, t[:], ent).map(fs => fs.map(f => (f.at, f.packed, f.from, f.size)))
  assert_eq(parsed, Some([(0L, big_packed, 0L, big_raw)]))

  // 12-byte entries with checksum flag 0x80
  let ct = make_checksum_table([(12L, 100L, 0xdeadbeefL), (28L, 250L, 0xcafebabeL)])
  let csize = 40L + ct.length().to_int64()
  guard table_length(csize, ct[ct.length() - footer:]) is Some((clen, cent)) else { fail("expected checksum table") }
  assert_eq(clen, ct.length().to_int64())
  assert_eq(cent, 12L)
  let cframes = frames_in(csize, ct[:], cent).map(fs => fs.map(f => (f.at, f.packed, f.from, f.size)))
  assert_eq(cframes, Some([(0L, 12L, 0L, 100L), (12L, 28L, 100L, 250L)]))
}

///|
test "seekable format: corrupted, truncated, tampered, and reserved-bit inputs safely return None" {
  let good = seek_table([(10L, 20L), (30L, 40L)])
  let good_size = 40L + good.length().to_int64()
  let good_foot = good[good.length() - footer:]

  // Every reserved bit (bits 0..6) in descriptor byte must be rejected
  for bit in 0..<7 {
    let arr = good_foot.to_owned().to_array()
    arr[4] = (1 << bit).to_byte()
    let bad = Bytes::from_array(FixedArray::from_array(arr))
    assert_eq(table_length(good_size, bad[:]), None)
    // Also with checksum bit 0x80 set
    arr[4] = (0x80 | (1 << bit)).to_byte()
    let bad2 = Bytes::from_array(FixedArray::from_array(arr))
    assert_eq(table_length(1000L, bad2[:]), None)
  }

  // Flipping any byte of the 4-byte seekable magic rejects the footer
  for i in 5..<9 {
    let arr = good_foot.to_owned().to_array()
    arr[i] = (arr[i].to_int() ^ 0x01).to_byte()
    let bad = Bytes::from_array(FixedArray::from_array(arr))
    assert_eq(table_length(good_size, bad[:]), None)
  }

  // Short footers (0..8 bytes) never panic
  for n in 0..<footer {
    assert_eq(table_length(good_size, good_foot[:n]), None)
  }

  // Claimed frame count = 0xffffffff exceeds file size -> None without overflow
  let huge = good_foot.to_owned().to_array()
  huge[0] = b'\xff'
  huge[1] = b'\xff'
  huge[2] = b'\xff'
  huge[3] = b'\xff'
  assert_eq(table_length(100000L, Bytes::from_array(FixedArray::from_array(huge))[:]), None)

  // frames_in rejects tampered skippable magic, tampered frame size, truncated table, and size mismatch
  for n in 0..<17 {
    assert_true(frames_in(good_size, good[:n], 8L) is None)
  }
  let bad_magic = good.to_array()
  bad_magic[0] = b'\x00'
  assert_true(frames_in(good_size, Bytes::from_array(FixedArray::from_array(bad_magic))[:], 8L) is None)

  let bad_len = good.to_array()
  bad_len[4] = (bad_len[4].to_int() + 1).to_byte()
  assert_true(frames_in(good_size, Bytes::from_array(FixedArray::from_array(bad_len))[:], 8L) is None)

  assert_true(frames_in(good_size - 1L, good[:], 8L) is None)
  assert_true(frames_in(good_size + 1L, good[:], 8L) is None)

  // stored() on short slices (0..4 bytes) and tampered magic/descriptor
  for n in 0..<5 {
    assert_false(stored(b"\x28\xb5\x2f\xfd\xe0"[:n]))
  }
  assert_true(stored(b"\x28\xb5\x2f\xfd\xe0\x00\x00"[:]))
}

///|
test "workspace_call validates required fields and rejects bad types" {
  let err_of = (op : String, ask : Json) => try {
    ignore(workspace_call(op, ask))
    ""
  } catch {
    Failed(m) => m
  }
  assert_eq(err_of("workspace.pack", { "out": "/o" }), "no dir")
  assert_eq(err_of("workspace.unpack", { "dest": "/d" }), "no path")
  assert_eq(err_of("workspace.unpack", { "path": "/p" }), "no dest")
  assert_eq(err_of("workspace.unpack", { "path": "/p", "dest": "/d", "prefix": Json::null() }), "")
  assert_eq(err_of("workspace.file", { "path": "/p", "out": "/o" }), "no wanted")
  assert_eq(err_of("workspace.file", { "path": "/p", "wanted": [], "out": "/o" }), "")
  assert_eq(err_of("workspace.file", { "path": "/p", "wanted": ["a"] }), "no out")
}
