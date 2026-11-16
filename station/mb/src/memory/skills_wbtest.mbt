// A shared skill's own cases, as station/test/reference/share-skills.ts and Node say them (station/test/
// mb-share-skills.test.ts holds the program to it on many more, through the program).

///|
test "sha256_hex: as Node's digest, about each block's edge" {
  assert_eq(sha256_hex(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  assert_eq(sha256_hex(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  assert_eq(
    sha256_hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
  )
  let a = fn(n : Int) { Bytes::make(n, b'a') }
  assert_eq(sha256_hex(a(55)), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
  assert_eq(sha256_hex(a(64)), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
  assert_eq(sha256_hex(a(1000)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
}

///|
test "skill_hash: its paths in JavaScript's order, not MoonBit's" {
  let h = fn(s : String) { sha256_hex(@utf8.encode(s)) }
  let hashes : Map[String, String] = Map([])
  for p in [("b", "1"), ("a/x", "2"), ("é", "3"), ("😀", "4"), ("ｚ", "5"), ("SKILL.md", "6")] {
    hashes[p.0] = h(p.1)
  }
  assert_eq(skill_hash(hashes), "854015444e8edb102e46cf992e00781d3408eefffd139dbdfb207d4fd91e7c4a")
}

///|
test "base64_bytes: as Node's Buffer.from(…, \"base64\")" {
  let cases = [
    ("YQ==", b"a"),
    ("YQ", b"a"),
    ("YQ==YQ==", b"a"),
    ("Y Q = =", b"a"),
    ("YW Jj", b"abc"),
    ("Y*Q", b"a"),
    ("-_8", b"\xfb\xff"),
    ("a", b""),
    ("YWJjZA=", b"abcd"),
    ("YWJj=ZA", b"abc"),
    ("Y===", b""),
    ("=YQ", b""),
  ]
  for c in cases {
    assert_eq(base64_bytes(c.0), c.1)
  }
}

///|
test "skill_path: inside the skill, no `.` or empty component" {
  assert_eq(skill_path("/", "SKILL.md"), Some(["SKILL.md"]))
  assert_eq(skill_path("/", "a/b.md"), Some(["a", "b.md"]))
  assert_eq(skill_path("/", "a\\..\\b"), Some(["a\\..\\b"]))
  for bad in ["", "../escape", "/abs", "a//b", "./x", "a/./b", "a/", "a/../b"] {
    assert_eq(skill_path("/", bad), None)
  }
  for bad in ["C:\\x", "a\\..\\b", "\\x", "a\\\\b", "x:y"] {
    assert_eq(skill_path("\\", bad), None)
  }
  assert_eq(skill_path("\\", "a\\b/c"), Some(["a", "b", "c"]))
}

///|
test "skill_conflict_path: its station's first 12 characters" {
  assert_eq(skill_conflict_path("/", "/s/x", "0123456789abcdef"), "/s/x/SKILL.conflict-0123456789ab.md")
  assert_eq(skill_conflict_path("/", "/s/x", "ab"), "/s/x/SKILL.conflict-ab.md")
}
