///|
/// What station/test/reference/packed.ts `seekTable` writes for these frames (station/test/mb-packed.test.ts holds the
/// program to it on many more).
test "the table: its skippable frame, each frame's sizes, the count and the seekable magic" {
  inspect(
    @hex.encode(seek_table([(10L, 20L), (0x01020304L, 0xfffffffeL)])),
    content="5e2a4d18190000000a0000001400000004030201feffffff0200000000b1ea928f",
  )
  inspect(@hex.encode(seek_table([])), content="5e2a4d18090000000000000000b1ea928f")
}

///|
test "a table read back: its frames where they are, a file it does not add up to none" {
  let table = seek_table([(10L, 20L), (30L, 40L)])
  let size = 40L + table.length().to_int64()
  let foot = table[table.length() - footer:]
  guard table_length(size, foot) is Some((length, entry)) else { fail("no table") }
  assert_eq(length, table.length().to_int64())
  assert_eq(entry, 8L)
  let listed = frames_in(size, table[:], entry).map(fs => fs.map(f => (f.at, f.packed, f.from, f.size)))
  assert_eq(listed, Some([(0L, 10L, 0L, 20L), (10L, 30L, 20L, 40L)]))
  assert_true(frames_in(size + 1L, table[:], entry) is None)
  // shorter than a table can be, a table longer than the file, a footer that is not one, its reserved bits set
  assert_eq(table_length(16L, foot), None)
  assert_eq(table_length(length - 1L, foot), None)
  let other = foot.to_owned().to_array()
  other[8] = b'\x00'
  assert_eq(table_length(size, Bytes::from_array(FixedArray::from_array(other))[:]), None)
  let reserved = foot.to_owned().to_array()
  reserved[4] = b'\x01'
  assert_eq(table_length(size, Bytes::from_array(FixedArray::from_array(reserved))[:]), None)
  // entries with checksums (12 bytes each)
  let wide = foot.to_owned().to_array()
  wide[4] = b'\x80'
  assert_eq(table_length(1000L, Bytes::from_array(FixedArray::from_array(wide))[:]), Some((8L + 2L * 12L + 9L, 12L)))
}

///|
test "a frame stored as it is: the frame magic and the descriptor of one segment with its size" {
  assert_true(stored(b"\x28\xb5\x2f\xfd\xe0"[:]))
  assert_false(stored(b"\x28\xb5\x2f\xfd\x24"[:]))
  assert_false(stored(b"\x28\xb5\x2f\xfc\xe0"[:]))
  assert_false(stored(b"\x28\xb5\x2f\xfd"[:]))
}
