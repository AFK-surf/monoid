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
  // Adjacent non-overlapping edits merge cleanly without reviving deleted lines.
  assert_eq(merge3("A\nB\nC\nD\n", "A'\nC\nD\n", "A\nB\nC'\nD\n"), Some("A'\nC'\nD\n"))
  // Condense-rebound regression: station A condenses 40 lines to 10, station B edits line 41 or appends -> no revival.
  let base_lines : Array[String] = []
  for i = 0; i < 40; i = i + 1 {
    base_lines.push("- rule \{i}")
  }
  base_lines.push("- tail")
  let condensed_lines : Array[String] = []
  for i = 0; i < 10; i = i + 1 {
    condensed_lines.push("- compact \{i}")
  }
  condensed_lines.push("- tail")
  let peer_lines = base_lines.copy()
  peer_lines[40] = "- tail updated"
  peer_lines.push("- appended")
  let expected_lines = condensed_lines.copy()
  expected_lines[10] = "- tail updated"
  expected_lines.push("- appended")
  assert_eq(
    merge3(base_lines.join("\n") + "\n", condensed_lines.join("\n") + "\n", peer_lines.join("\n") + "\n"),
    Some(expected_lines.join("\n") + "\n"),
  )
  // Overlapping conflict deduplicates shared non-fence content lines while preserving duplicate `}` inside code fences.
  let base_fence = "# s\n- keep\n- old\n```js\nfunction f() {\n  if (x) {\n  }\n}\n```\n"
  let newer_fence = "# s\n- keep\n- shared\n- newer\n```js\nfunction f() {\n  if (a) {\n  }\n}\n```\n"
  let older_fence = "# s\n- keep\n- shared\n- older\n```js\nfunction f() {\n  if (b) {\n  }\n}\n```\n"
  let merged_fence = merge3(base_fence, newer_fence, older_fence).unwrap()
  let mut shared_count = 0
  let mut brace_count = 0
  for line in lines_of(merged_fence) {
    if line == "- shared" {
      shared_count += 1
    }
    if line == "  }" || line == "}" {
      brace_count += 1
    }
  }
  assert_eq(shared_count, 1)
  assert_true(merged_fence.contains("- newer"))
  assert_true(merged_fence.contains("- older"))
  assert_eq(brace_count, 2)
}

///|
test "union_lines: each line once, one's alone marked with its station" {
  assert_eq(
    union_lines("# m\n- x\n- y\n", "# m\n- [ccvm] x\n- z\n1. n\n", Some("Mini"), Some("Studio")),
    "# m\n- x\n- [Mini] y\n- [Studio] z\n1. [Studio] n\n",
  )
  // Reordered paragraphs: shared lines emitted once and unmarked.
  let reordered = union_lines("- p2\n- p1\n- only-w\n", "- p1\n- p2\n- only-l\n", Some("W"), Some("L"))
  assert_eq(reordered, "- p2\n- p1\n- [W] only-w\n- [L] only-l\n")
  // >3000-line LCS fallback: no 2x concatenation of shared lines.
  let w_many : Array[String] = []
  let l_many : Array[String] = []
  for i = 0; i < 3010; i = i + 1 {
    w_many.push("- rule \{i}")
  }
  for i = 3009; i >= 0; i = i - 1 {
    l_many.push("- rule \{i}")
  }
  l_many.push("- unique-l")
  let merged_many = union_lines(w_many.join("\n") + "\n", l_many.join("\n") + "\n", None, None)
  let merged_many_lines = lines_of(merged_many)
  // 3010 shared + 1 unique-l + trailing empty line = 3012
  assert_eq(merged_many_lines.length(), 3012)
  assert_true(merged_many.contains("- unique-l"))
}

///|
test "dedup_memory_lines: folds 8 repeated sections while preserving unique rules and code fences" {
  let parts : Array[String] = []
  for k = 0; k < 8; k = k + 1 {
    parts.push("# Global\n- shared rule A\n- shared rule B\n- unique \{k}\n")
  }
  parts.push("# Code\n```sh\nif true; then\n  echo ok\nfi\nif true; then\n  echo ok\nfi\n```\n")
  let raw = parts.join("\n")
  let deduped = dedup_memory_lines(raw)
  let mut shared_a = 0
  let mut global_h = 0
  let mut echo_ok = 0
  for line in lines_of(deduped) {
    if line == "- shared rule A" {
      shared_a += 1
    }
    if line == "# Global" {
      global_h += 1
    }
    if line == "  echo ok" {
      echo_ok += 1
    }
  }
  assert_eq(shared_a, 1)
  assert_eq(echo_ok, 2)
  for k = 0; k < 8; k = k + 1 {
    assert_true(deduped.contains("- unique \{k}"))
  }
  // Idempotent on second pass.
  assert_eq(dedup_memory_lines(deduped), deduped)
  // Purely duplicate repeated sections collapse heading to 1.
  let pure_dup = "# Global\n- shared rule A\n- shared rule B\n\n".repeat(8)
  assert_eq(dedup_memory_lines(pure_dup), "# Global\n- shared rule A\n- shared rule B\n")
  assert_true(global_h >= 1)
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
