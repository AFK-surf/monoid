///|
fn sf_push_u16(out : Array[Byte], v : Int) -> Unit {
  out.push(((v >> 8) & 0xFF).to_byte())
  out.push((v & 0xFF).to_byte())
}

///|
fn sf_push_u32(out : Array[Byte], v : Int) -> Unit {
  out.push(((v >> 24) & 0xFF).to_byte())
  out.push(((v >> 16) & 0xFF).to_byte())
  out.push(((v >> 8) & 0xFF).to_byte())
  out.push((v & 0xFF).to_byte())
}

///|
fn sf_push_tag(out : Array[Byte], s : String) -> Unit {
  for c in s {
    out.push((c.to_int() & 0xFF).to_byte())
  }
}

///|
fn sf_minimal_ttf(family : String) -> Bytes {
  let head : Array[Byte] = Array::make(54, b'\x00')
  head[1] = b'\x01'
  head[12] = b'\x5F'
  head[13] = b'\x0F'
  head[14] = b'\x3C'
  head[15] = b'\xF5'
  head[18] = b'\x03'
  head[19] = b'\xE8'
  let hhea : Array[Byte] = Array::make(36, b'\x00')
  hhea[1] = b'\x01'
  hhea[35] = b'\x01'
  let maxp : Array[Byte] = []
  sf_push_u32(maxp, 0x00010000)
  sf_push_u16(maxp, 1)
  let os2 : Array[Byte] = Array::make(78, b'\x00')
  os2[1] = b'\x02'
  os2[4] = b'\x01'
  os2[5] = b'\x90'
  os2[7] = b'\x05'
  let str_bytes : Array[Byte] = []
  for c in family {
    sf_push_u16(str_bytes, c.to_int())
  }
  let name : Array[Byte] = []
  sf_push_u16(name, 0)
  sf_push_u16(name, 2)
  sf_push_u16(name, 30)
  sf_push_u16(name, 3)
  sf_push_u16(name, 1)
  sf_push_u16(name, 0x0409)
  sf_push_u16(name, 1)
  sf_push_u16(name, str_bytes.length())
  sf_push_u16(name, 0)
  sf_push_u16(name, 3)
  sf_push_u16(name, 1)
  sf_push_u16(name, 0x0409)
  sf_push_u16(name, 6)
  sf_push_u16(name, str_bytes.length())
  sf_push_u16(name, 0)
  for b in str_bytes {
    name.push(b)
  }
  let tables : Array[(String, Array[Byte])] = [("OS/2", os2), ("head", head), ("hhea", hhea), ("maxp", maxp), ("name", name)]
  let out : Array[Byte] = []
  let nt = tables.length()
  sf_push_u32(out, 0x00010000)
  sf_push_u16(out, nt)
  sf_push_u16(out, 0)
  sf_push_u16(out, 0)
  sf_push_u16(out, 0)
  let mut off = 12 + nt * 16
  for t in tables {
    sf_push_tag(out, t.0)
    sf_push_u32(out, 0)
    sf_push_u32(out, off)
    sf_push_u32(out, t.1.length())
    off += (t.1.length() + 3) & -4
  }
  for t in tables {
    for b in t.1 {
      out.push(b)
    }
    while out.length() % 4 != 0 {
      out.push(b'\x00')
    }
  }
  Bytes::from_array(out)
}

///|
test "svg_fonts_for hits on identical references, appends strictly growing prefixes, and rebuilds on same-length swap" {
  let prev = svg_fonts.val
  svg_fonts.val = None
  defer {
    svg_fonts.val = prev
  }
  let f0 = sf_minimal_ttf("AlphaSans")
  let f1 = sf_minimal_ttf("BetaMono")
  let f2 = sf_minimal_ttf("GammaCjk")

  // 1. Initial load builds FontDb with [f0, f1].
  let (db1, own1) = svg_fonts_for([f0, f1])
  assert_eq(db1.faces().length(), 2)
  assert_eq(own1, "AlphaSans")

  // 2. Identical references hit cache and return the exact same FontDb instance.
  let (db2, own2) = svg_fonts_for([f0, f1])
  assert_true(physical_equal(db1, db2))
  assert_eq(own2, "AlphaSans")

  // 3. Strict prefix append reuses the same FontDb instance and appends only the new face.
  let (db3, own3) = svg_fonts_for([f0, f1, f2])
  assert_true(physical_equal(db1, db3))
  assert_eq(db3.faces().length(), 3)
  assert_eq(own3, "AlphaSans")

  // 4. Same-length swap with a different Bytes reference rebuilds FontDb instead of reusing stale faces.
  let f0_copy = sf_minimal_ttf("DeltaSans")
  let (db4, own4) = svg_fonts_for([f0_copy, f1, f2])
  assert_false(physical_equal(db3, db4))
  assert_eq(db4.faces().length(), 3)
  assert_eq(own4, "DeltaSans")
}
