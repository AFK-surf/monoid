// The merges' own cases, as test/reference/memory-merge.ts says them (station/test/mb-memory-merge.test.ts holds the
// program to it on many more, through the program).

///|
test "is_text: UTF-8 with no NUL, nothing Buffer would replace" {
  assert_true(is_text(b""))
  assert_true(is_text(b"a\n\xe4\xb8\xad\xf0\x9f\x98\x80"))
  assert_true(is_text(b"\xef\xbb\xbf\xef\xbf\xbd"))
  assert_false(is_text(b"a\x00"))
  assert_false(is_text(b"\xed\xa0\x80"))
  assert_false(is_text(b"\xc0\xaf"))
  assert_false(is_text(b"\xe0\x80\xaf"))
  assert_false(is_text(b"\xf0\x8f\xbf\xbf"))
  assert_false(is_text(b"\xe4\xb8"))
  assert_false(is_text(b"\xf4\x90\x80\x80"))
  assert_false(is_text(b"\x80"))
}

///|
test "matches: the longest, its ties broken as the TypeScript broke them" {
  assert_eq(matches(["a", "b"], ["b", "a"]), Some([(1, 0)]))
  assert_eq(matches(["a", "b", "c", "a", "b", "c"], ["c", "b", "a", "c", "b", "a"]), Some([(2, 0), (4, 1), (5, 3)]))
  let many = Array::makei(3001, fn(i) { "a\{i}" })
  assert_eq(matches(many, ["b"]), None)
}

///|
test "merge3: what each changed taken, both kept where both changed, the newer first" {
  assert_eq(merge3("a\nb\nc\n", "A\nb\nc\n", "a\nb\nC\n"), Some("A\nb\nC\n"))
  assert_eq(merge3("- one\n", "- one\n- mine\n", "- one\n- theirs\n"), Some("- one\n- mine\n- theirs\n"))
  assert_eq(merge3("a\nb\nc", "a\nc", "a\nB\nc"), Some("a\nB\nc"))
}

///|
test "union_lines: each line once, one's alone marked with its station" {
  assert_eq(
    union_lines("# m\n- x\n- y\n", "# m\n- [ccvm] x\n- z\n1. n\n", Some("Mini"), Some("Studio")),
    "# m\n- x\n- [Mini] y\n- [Studio] z\n1. [Studio] n\n",
  )
}

///|
test "station_tag and conflict_path: letters and digits of every script kept" {
  assert_eq(station_tag("Mini 1 ✓ 中"), "Mini-1-中")
  assert_eq(station_tag("😀"), "station")
  assert_eq(station_tag("x²"), "x²")
  assert_eq(station_tag("a".repeat(50)), "a".repeat(40))
  assert_eq(conflict_path("skills/a/SKILL.md", "Mini 1"), "skills/a/SKILL.conflict-Mini-1.md")
  assert_eq(conflict_path("skills/a/run", "ccvm"), "skills/a/run.conflict-ccvm")
  assert_eq(conflict_path("skills/a/.env", "ccvm"), "skills/a/.env.conflict-ccvm")
}

///|
test "alike: half the lines of the shorter, past the front matter" {
  assert_true(alike("---\nname: a\n---\n- one\n- two\n", "---\nname: b\n---\n- one\n- three\n"))
  assert_false(alike("x\n", "y\n"))
}

///|
test "portable_name: a name every system keeps" {
  assert_true(portable_name("proj"))
  assert_true(portable_name("中文技能"))
  assert_false(portable_name(".hidden"))
  assert_false(portable_name("trail."))
  assert_false(portable_name("a:b"))
  assert_false(portable_name("CON"))
  assert_false(portable_name("com1.txt"))
  assert_true(portable_name("com10"))
  assert_false(portable_name("x".repeat(256)))
}

///|
test "aside_of: the station a skill kept apart says it is of" {
  assert_eq(aside_of("---\nname: s-Mini1\ndescription: [Mini1] own\n---\nbody", "s-Mini1"), Some("Mini1"))
  assert_eq(aside_of("---\nname: other\ndescription: [Mini1] own\n---\n", "s-Mini1"), None)
  assert_eq(aside_of("no front", "s"), None)
}
