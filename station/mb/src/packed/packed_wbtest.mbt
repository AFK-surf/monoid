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

///|
/// A workspace's asks, as the shell is asked them (client/shell `tar.pack`, `tar.unpack`, `tar.file`; station/test/
/// mb-packed.test.ts holds what it does to the TypeScript it replaced).
test "a workspace's asks: the shell's op and what it is given, what is missing refused" {
  let call = (op : String, ask : Json) => {
    let (shell, args) = workspace_call(op, ask) catch { Failed(m) => ("refused", { "why": Json::string(m) }) }
    Json::array([Json::string(shell), Json::object(args)]).stringify()
  }
  inspect(
    call("workspace.pack", { "dir": "/r/workspace", "out": "/r/w.writing", "id": 1 }),
    content=(
      #|["tar.pack",{"dir":"/r/workspace","out":"/r/w.writing"}]
    ),
  )
  inspect(
    call("workspace.unpack", { "path": "/r/a.tar.zst", "dest": "/r/stage" }),
    content=(
      #|["tar.unpack",{"path":"/r/a.tar.zst","dest":"/r/stage"}]
    ),
  )
  inspect(
    call("workspace.unpack", { "path": "/r/a.tar.zst", "dest": "/r/stage", "prefix": "uploads" }),
    content=(
      #|["tar.unpack",{"path":"/r/a.tar.zst","dest":"/r/stage","prefix":"uploads"}]
    ),
  )
  inspect(
    call("workspace.file", { "path": "/r/a.tar.zst", "wanted": ["uploads", "截图 1.png"], "out": "/r/a.reading-1" }),
    content=(
      #|["tar.file",{"path":"/r/a.tar.zst","wanted":["uploads","截图 1.png"],"out":"/r/a.reading-1"}]
    ),
  )
  inspect(
    call("workspace.pack", { "dir": "/r/workspace" }),
    content=(
      #|["refused",{"why":"no out"}]
    ),
  )
  inspect(
    call("workspace.unpack", { "path": "/r/a", "dest": "/r/s", "prefix": 1 }),
    content=(
      #|["refused",{"why":"no prefix"}]
    ),
  )
  inspect(
    call("workspace.file", { "path": "/r/a", "wanted": ["uploads", 1], "out": "/r/o" }),
    content=(
      #|["refused",{"why":"no wanted"}]
    ),
  )
  inspect(
    call("workspace.copy", { "path": "/r/a" }),
    content=(
      #|["refused",{"why":"no such ask"}]
    ),
  )
}
