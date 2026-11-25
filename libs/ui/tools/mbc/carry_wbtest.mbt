///|
fn carried_src(tail : String) -> Bytes {
  utf8(
    "#include \"moonbit.h\"\n\n" +
    "static struct { int32_t rc; uint32_t meta; uint8_t const data[5]; \n      } const moonbit_bytes_literal_1 =\n" +
    "         {\n           Moonbit_make_static_rc(moonbit_BLOCK_KIND_VAL_ARRAY), 4, 31, \n           139, 8, 255, 0\n         };\n\n" +
    "static struct { int32_t rc; uint32_t meta; uint8_t const data[2]; \n      } const moonbit_bytes_literal_11 =\n" +
    "         { Moonbit_make_static_rc(moonbit_BLOCK_KIND_VAL_ARRAY), 1, 7, 0};\n\n" +
    "static moonbit_bytes_t _M0a =\n         (moonbit_bytes_t)moonbit_bytes_literal_1.data;\n\n" +
    "static moonbit_bytes_t _M0ab =\n         (moonbit_bytes_t)moonbit_bytes_literal_11.data;\n\n" +
    tail,
  )
}

///|
test "a literal one global starts as goes to a file, and each read of the global asks for it; a smaller one stays" {
  let (c, files) = carry(carried_src("int f(void) { return g(_M0a) + g(_M0ab) + g(_M0a); }\n"), 4)
  assert_eq(files.length(), 1)
  assert_eq(files[0].1, b"\x00\x00\x00\x00\x00\x00\x00\x00\x1f\x8b\x08\xff\x00")
  let call = cat([b"mbui_carried(\"", files[0].0, b"\", 4)"])
  assert_eq(files[0].0, cat([sha1_hex(files[0].1, 16), b".bytes"]))
  assert_eq(count(c, call), 2)
  assert_eq(count(c, b"mbui_carried(char const* name, int32_t len);"), 1)
  assert_eq(count(c, b"moonbit_bytes_literal_1 "), 0)
  assert_eq(count(c, b"moonbit_bytes_literal_11"), 2)
  assert_eq(count(c, b"g(_M0ab)"), 1)
}

///|
test "a literal used in any other way stays as it was" {
  let uses = [
    // its global written, its address taken, the literal itself read
    "void f(void) { _M0a = g(); }\n", "void f(void) { g(&_M0a); }\n", "void f(void) { g(moonbit_bytes_literal_1.data); }\n",
  ]
  for u in uses {
    let src = carried_src(u)
    let (c, files) = carry(src, 4)
    assert_eq(files.length(), 0)
    assert_eq(c, src)
  }
}
