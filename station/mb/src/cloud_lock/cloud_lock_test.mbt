// Native tests for cloud_lock: bytes, JS-compatible JSON, entry shapes and hashes, cloud.json text,
// build parsing, device builds, lock state machine and pin/lease calculations.

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
      ("rig_due", Json::array([Json::string("ws1")])),
      ("peers", Json::array([])),
      ("origin", Json::string("o")),
      ("joined", Json::array([])),
      ("station", Json::string("s")),
    ]),
  }
  assert_eq(@cloud_lock.state_text(s), "{\n  \"origin\": \"o\",\n  \"station\": \"s\",\n  \"peers\": [],\n  \"rig_due\": [\n    \"ws1\"\n  ]\n}")
  assert_eq(@cloud_lock.joined_of(Some(@cloud_lock.parse("[{\"workspace\":\"J\",\"locked\":true},{\"workspace\":\"\"}]").unwrap())).length(), 1)
}

///|
test "cloud.json workspace_emoji and workspace_icon serialization and joined_of filtering" {
  let s : @cloud_lock.CloudState = {
    fields: Map([
      ("origin", Json::string("https://app.still.fail")),
      ("station", Json::string("st1")),
      ("workspace", Json::string("w1")),
      ("workspace_name", Json::string("Home")),
      ("workspace_emoji", Json::string("🚀")),
      ("workspace_icon", Json::string("glyph:rocket")),
      ("name", Json::string("mac-1")),
      ("peers", Json::array([])),
      ("revocations", Json::array([])),
    ]),
  }
  let txt = @cloud_lock.state_text(s)
  assert_true(txt.contains("\"workspace_name\": \"Home\",\n  \"workspace_emoji\": \"🚀\",\n  \"workspace_icon\": \"glyph:rocket\",\n  \"name\": \"mac-1\""))
  // Empty strings are omitted by state_text
  let s_empty : @cloud_lock.CloudState = {
    fields: Map([
      ("workspace", Json::string("w1")),
      ("workspace_name", Json::string("Home")),
      ("workspace_emoji", Json::string("")),
      ("workspace_icon", Json::string("")),
      ("name", Json::string("mac-1")),
    ]),
  }
  let txt_empty = @cloud_lock.state_text(s_empty)
  assert_false(txt_empty.contains("workspace_emoji"))
  assert_false(txt_empty.contains("workspace_icon"))
  // joined_of keeps non-empty emoji/icon and omits empty or non-string values
  let joined = @cloud_lock.joined_of(
    Some(
      @cloud_lock.parse(
        "[{\"workspace\":\"j1\",\"workspace_name\":\"Lab\",\"workspace_emoji\":\"🧪\",\"workspace_icon\":\"glyph:beaker\",\"name\":\"s1\"},{\"workspace\":\"j2\",\"workspace_name\":\"Bare\",\"workspace_emoji\":\"\",\"workspace_icon\":123,\"name\":\"s2\"}]",
      ).unwrap(),
    ),
  )
  assert_eq(joined.length(), 2)
  assert_eq(@cloud_lock.stringify(joined[0]), "{\"workspace\":\"j1\",\"workspace_name\":\"Lab\",\"workspace_emoji\":\"🧪\",\"workspace_icon\":\"glyph:beaker\",\"name\":\"s1\",\"peers\":[],\"revocations\":[]}")
  assert_eq(@cloud_lock.stringify(joined[1]), "{\"workspace\":\"j2\",\"workspace_name\":\"Bare\",\"name\":\"s2\",\"peers\":[],\"revocations\":[]}")
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

///|
test "lock state machine: genesis, web device 30-day lease cap, and admit" {
  let ok_crypto : @cloud_lock.Crypto = { verify: (_, _, _, _) => true }
  let dev_a = "aa".repeat(32)
  let dev_web = "bb".repeat(32)
  let key_a = "ed25519:" + "11".repeat(32)
  let sig_a : Json = { "key": Json::string(key_a), "alg": "Ed25519", "sig": "22".repeat(64) }
  let gen : Json = {
    "v": 1,
    "ws": "w1",
    "seq": 0,
    "prev": Json::null(),
    "at": 1000,
    "kind": "genesis",
    "body": {
      "owner": "u1",
      "origins": ["https://app.still.fail"],
      "rp_id": "app.still.fail",
      "members": [{ "sub": "u1", "email": "u1@x.com", "role": "owner" }],
      "devices": [{ "id": Json::string(dev_a), "sub": "u1", "kind": "app", "label": "Mac", "sign_key": Json::string(key_a) }],
      "passkeys": [],
      "stations": [],
    },
    "sig": sig_a,
  }
  let s0 = @cloud_lock.genesis(ok_crypto, gen)
  assert_eq(s0.seq, 0.0)
  assert_true(@cloud_lock.signer(s0, key_a, Some(1000.0)) is Some(_))
  // Admitting the owner's app device succeeds; unknown endpoint is refused
  let (d0, r0) = @cloud_lock.admit(ok_crypto, s0, { sub: "u1", endpoint: dev_a, base: None, proof: None }, 1000.0)
  assert_eq(d0.id, dev_a)
  assert_eq(r0, "owner")
  assert_true((try Ok(@cloud_lock.admit(ok_crypto, s0, { sub: "u1", endpoint: dev_web, base: None, proof: None }, 1000.0)) catch { e => Err(e) }) is Err(_))
  // A web device with exp > at + 30 days is refused; within 30 days is accepted and expires past exp
  let too_long : Json = {
    "v": 1,
    "ws": "w1",
    "seq": 1,
    "prev": Json::string(s0.head),
    "at": 2000,
    "kind": "device",
    "body": { "id": Json::string(dev_web), "sub": "u1", "kind": "web", "label": "Web", "exp": 2000.0 + @cloud_lock.web_device_secs + 1.0 },
    "sig": sig_a,
  }
  assert_true((try Ok(@cloud_lock.apply(ok_crypto, s0, too_long, Some(2000.0))) catch { e => Err(e) }) is Err(_))
  let ok_web : Json = {
    "v": 1,
    "ws": "w1",
    "seq": 1,
    "prev": Json::string(s0.head),
    "at": 2000,
    "kind": "device",
    "body": { "id": Json::string(dev_web), "sub": "u1", "kind": "web", "label": "Web", "exp": 5000 },
    "sig": sig_a,
  }
  let s1 = @cloud_lock.apply(ok_crypto, s0, ok_web, Some(2000.0))
  let (dw, _) = @cloud_lock.admit(ok_crypto, s1, { sub: "u1", endpoint: dev_web, base: None, proof: None }, 4999.0)
  assert_eq(dw.kind, "web")
  assert_true((try Ok(@cloud_lock.admit(ok_crypto, s1, { sub: "u1", endpoint: dev_web, base: None, proof: None }, 5000.0)) catch { e => Err(e) }) is Err(_))
}

///|
test "admit_personal accepts own app device and refuses wrong sub or bad proof" {
  let ok_crypto : @cloud_lock.Crypto = { verify: (_, _, _, _) => true }
  let bad_crypto : @cloud_lock.Crypto = { verify: (_, _, _, _) => false }
  let dev = "cc".repeat(32)
  let lock : Json = {
    "ws": "w1",
    "genesis": "",
    "members": { "u1": { "sub": "u1", "email": "u1@x.com", "role": "admin" } },
    "devices": {
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc": {
        "id": Json::string(dev),
        "sub": "u1",
        "kind": "app",
        "label": "Phone",
        "sign_key": "ed25519:abc",
        "own": true,
      },
    },
    "signKeys": {},
  }
  let (id, role, sign_key) = @cloud_lock.admit_personal(ok_crypto, lock, { sub: "u1", endpoint: dev, base: None, proof: None })
  assert_eq(id, dev)
  assert_eq(role, "admin")
  assert_eq(sign_key, Some("ed25519:abc"))
  // Wrong member sub is refused
  assert_true((try Ok(@cloud_lock.admit_personal(ok_crypto, lock, { sub: "u2", endpoint: dev, base: None, proof: None })) catch { e => Err(e) }) is Err(_))
  // Base key with invalid endpoint proof is refused
  assert_true((try Ok(@cloud_lock.admit_personal(bad_crypto, lock, { sub: "u1", endpoint: "dd".repeat(32), base: Some(dev), proof: Some("00".repeat(64)) })) catch { e => Err(e) }) is Err(_))
}

///|
test "personal_vault_lock preserves member roles and defaults unknown roles to member" {
  let ok_crypto : @cloud_lock.Crypto = { verify: (_, _, _, _) => true }
  let emails = Map([("u1", "u1@x.com"), ("u2", "u2@x.com"), ("u3", "u3@x.com")])
  let roles = Map([("u1", "owner"), ("u2", "admin"), ("u3", "bogus")])
  let lock = @cloud_lock.personal_vault_lock(ok_crypto, "w1", [], emails, [], [], (_, _) => false, roles~)
  let role_of = (sub : String) => match lock {
    { "members": Object(ms), .. } =>
      match ms.get(sub) {
        Some({ "role": String(r), .. }) => r
        _ => ""
      }
    _ => ""
  }
  assert_eq(role_of("u1"), "owner")
  assert_eq(role_of("u2"), "admin")
  assert_eq(role_of("u3"), "member")
}
