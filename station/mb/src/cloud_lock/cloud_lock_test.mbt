// What of the lock runs without a shell: the bytes as Node has them, JSON as JavaScript writes it, entries' shapes and
// hashes, cloud.json's text, the builds a request says. The rest is held to the TypeScript by
// station/test/mb-cloud-lock.test.ts through the reader (`--builder harness-cloud-lock`).

///|
test "sha256 and UTF-8 as Node has them" {
  assert_eq(@cloud_lock.sha256_hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  assert_eq(@cloud_lock.sha256_hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  // (a lone surrogate as U+FFFD, as Buffer.from encodes it)
  let lone = StringBuilder()
  lone.write_char('a')
  lone.write_char((0xd800).unsafe_to_char())
  lone.write_char('b')
  assert_eq(@cloud_lock.hex_of(@cloud_lock.utf8_of(lone.to_string())), "61efbfbd62")
  assert_eq(@cloud_lock.hex_of(@cloud_lock.utf8_of("😀中")), "f09f9880e4b8ad")
  let long = StringBuilder()
  for _ in 0..<200 {
    long.write_string("x")
  }
  assert_eq(
    @cloud_lock.sha256_hex(long.to_string()),
    @cloud_lock.sha256_hex_bytes(@cloud_lock.utf8_of(long.to_string())),
  )
}

///|
test "hex and base64 read as Buffer reads them" {
  assert_eq(@cloud_lock.hex_of(@cloud_lock.hex_bytes("0aFfzz12")), "0aff")
  assert_eq(@cloud_lock.hex_of(@cloud_lock.hex_bytes("abc")), "ab")
  assert_eq(@cloud_lock.hex_of(@cloud_lock.b64_bytes("_-8=AAAA")), "ffef")
  assert_eq(@cloud_lock.hex_of(@cloud_lock.b64_bytes("/+8")), "ffef")
  assert_eq(@cloud_lock.b64url_of(b"\xff\xef\x01"), "_-8B")
  assert_eq(@cloud_lock.b64url_of(b"\xff"), "_w")
  assert_true(@cloud_lock.is_hex32("ab".repeat(32)))
  assert_false(@cloud_lock.is_hex32("AB".repeat(32)))
}

///|
test "JSON as JavaScript writes it: integer-like keys first, a stable sort, code-unit order" {
  let v = @cloud_lock.parse("{\"b\":1,\"10\":2,\"2\":3,\"a\":[1.5,\"\\u00e9\"]}").unwrap()
  assert_eq(@cloud_lock.stringify(v), "{\"2\":3,\"10\":2,\"b\":1,\"a\":[1.5,\"é\"]}")
  assert_eq(@cloud_lock.stringify_pretty(@cloud_lock.parse("{\"a\":[1]}").unwrap()), "{\n  \"a\": [\n    1\n  ]\n}")
  let xs = [(2, "a"), (1, "b"), (2, "c"), (1, "d")]
  @cloud_lock.stable_sort(xs, (a, b) => a.0 - b.0)
  assert_eq(xs, [(1, "b"), (1, "d"), (2, "a"), (2, "c")])
  assert_true(@cloud_lock.js_compare("Z", "a") < 0)
  assert_true(@cloud_lock.js_compare("ab", "a") > 0)
}

///|
test "an entry's shape and hash" {
  let e = @cloud_lock.parse(
    "{\"v\":1,\"ws\":\"W\",\"seq\":0,\"prev\":null,\"at\":1000,\"kind\":\"genesis\",\"body\":{\"b\":1,\"a\":2},\"sig\":{\"key\":\"k\",\"alg\":\"Ed25519\",\"sig\":\"s\"}}",
  ).unwrap()
  assert_true(@cloud_lock.as_entry(e) is Some(_))
  // what is hashed: everything but the signature, canonical
  assert_eq(
    @cloud_lock.entry_hash(e),
    @cloud_lock.sha256_hex(
      "stillfail-lock/1\n{\"at\":1000,\"body\":{\"a\":2,\"b\":1},\"kind\":\"genesis\",\"prev\":null,\"seq\":0,\"v\":1,\"ws\":\"W\"}",
    ),
  )
  let bad = @cloud_lock.parse("{\"v\":1,\"ws\":\"W\",\"seq\":0,\"prev\":null,\"at\":1.5,\"kind\":\"x\",\"body\":{},\"sig\":{\"key\":\"k\",\"alg\":\"Ed25519\",\"sig\":\"s\"}}").unwrap()
  assert_true(@cloud_lock.as_entry(bad) is None)
  assert_true((try Ok(@cloud_lock.entry_hash(bad)) catch { e => Err(e) }) is Err(_))
  assert_eq(@cloud_lock.lower_role("owner", "member"), "member")
  assert_eq(@cloud_lock.lower_role("owner", "god"), "viewer")
  assert_eq(@cloud_lock.short_code("00".repeat(32)).length(), 7)
}

///|
test "cloud.json's text, its fields in the Rust struct's order" {
  let s : @cloud_lock.CloudState = {
    fields: Map([
      ("rig_due", Json::boolean(true)),
      ("peers", Json::array([])),
      ("origin", Json::string("o")),
      ("joined", Json::array([])),
      ("station", Json::string("s")),
    ]),
  }
  assert_eq(@cloud_lock.state_text(s), "{\n  \"origin\": \"o\",\n  \"station\": \"s\",\n  \"peers\": [],\n  \"rig_due\": true\n}")
  assert_eq(@cloud_lock.joined_of(Some(@cloud_lock.parse("[{\"workspace\":\"J\",\"locked\":true},{\"workspace\":\"\"}]").unwrap())).length(), 1)
}

///|
test "the build a request says" {
  assert_eq(@cloud_lock.build_of(Some(" 9244 ")), Some(9244))
  assert_eq(@cloud_lock.build_of(Some("0.1.9275")), Some(9275))
  assert_eq(@cloud_lock.build_of(Some("1.1.9275")), None)
  assert_eq(@cloud_lock.build_of(Some("x")), None)
  assert_eq(@cloud_lock.build_of(None), None)
}

///|
test "device builds: kept as the build rises or the day changes" {
  let b = @cloud_lock.DeviceBuilds::new(None, 100.0)
  b.saw("d", Some(9000), 100.0)
  b.saw("d", Some(8000), 200.0)
  b.saw("e", None, 100.0)
  assert_eq(
    @cloud_lock.stringify(b.of(["d", "e", "f"])),
    "{\"since\":100,\"devices\":{\"d\":{\"build\":9000,\"at\":100},\"e\":{\"build\":-1,\"at\":100}}}",
  )
  b.saw("d", Some(8000), 100000.0)
  assert_eq(@cloud_lock.stringify(b.of(["d"])), "{\"since\":100,\"devices\":{\"d\":{\"build\":9000,\"at\":100000}}}")
}
