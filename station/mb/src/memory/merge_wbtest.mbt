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
  // Lossless code-file conflict (P0-1): merge3 keeps all closing braces/fi from both sides without dropping code lines.
  let code_base = "function f() {\n  return 0;\n}\n"
  let code_w = "function f() {\n  if (a) {\n    return 1;\n  }\n}\n"
  let code_l = "function f() {\n  if (b) {\n    return 2;\n  }\n}\n"
  let merged_code = merge3(code_base, code_w, code_l).unwrap()
  let mut close_braces = 0
  for line in lines_of(merged_code) {
    if line == "  }" {
      close_braces += 1
    }
  }
  assert_eq(close_braces, 2)
}

///|
test "union_lines: each line once, lossless on code, preserves trailing newline on >3000 fallback" {
  assert_eq(
    union_lines("# m\n- x\n- y\n", "# m\n- [ccvm] x\n- z\n1. n\n", Some("Mini"), Some("Studio")),
    "# m\n- x\n- [Mini] y\n- [Studio] z\n1. [Studio] n\n",
  )
  // P1-1: task checkboxes [ ] / [x] / [X] are never mistaken for station marks, and fenced lines stay untouched.
  assert_eq(
    union_lines("- [ ] release\n```\n- [ccvm] keep\n```\n", "- [x] release\n```\n- [ccvm] keep\n```\n", Some("W"), Some("L")),
    "- [W] [ ] release\n- [L] [x] release\n```\n- [ccvm] keep\n```\n",
  )
  // P0-1: union_lines is lossless for code files (never drops `fi` / `}`).
  let sh_w = "if a; then\n  echo 1\nfi\n"
  let sh_l = "if b; then\n  echo 2\nfi\n"
  let sh_u = union_lines(sh_w, sh_l, None, None)
  let mut fi_count = 0
  for line in lines_of(sh_u) {
    if line == "fi" {
      fi_count += 1
    }
  }
  assert_true(fi_count >= 1)
  // P2-1: when pairs == [] and newer has no trailing newline, older's trailing newline is preserved.
  let no_nl = union_lines("alpha", "beta\n\n\ngamma\n", None, None)
  assert_eq(no_nl, "alpha\nbeta\n\ngamma\n")
  // Reordered paragraphs + >3000 fallback deduplicate cleanly once passed through dedup_memory_lines.
  let reordered = dedup_memory_lines(union_lines("- p2\n- p1\n- only-w\n", "- p1\n- p2\n- only-l\n", Some("W"), Some("L")))
  assert_eq(reordered, "- p2\n- p1\n- [W] only-w\n- [L] only-l\n")
  let w_many : Array[String] = []
  let l_many : Array[String] = []
  for i = 0; i < 3010; i = i + 1 {
    w_many.push("- rule \{i}")
  }
  for i = 3009; i >= 0; i = i - 1 {
    l_many.push("- rule \{i}")
  }
  l_many.push("- unique-l")
  let merged_many = dedup_memory_lines(union_lines(w_many.join("\n") + "\n", l_many.join("\n") + "\n", None, None))
  // 3010 shared + 1 blank separator + 1 unique-l + trailing empty line = 3013 (3011 non-empty lines, zero 2x duplication)
  assert_eq(lines_of(merged_many).length(), 3013)
  assert_true(merged_many.contains("- unique-l"))
}

///|
test "dedup_memory_lines: folds 8 repeated sections while preserving structure, scopes, checkboxes, and nested headings" {
  let parts : Array[String] = []
  for k = 0; k < 8; k = k + 1 {
    parts.push("# Global\n- shared rule A\n- shared rule B\n- unique \{k}\n")
  }
  parts.push("# Code\n```sh\nif true; then\n  echo ok\nfi\nif true; then\n  echo ok\nfi\n```\n")
  let raw = parts.join("\n")
  let deduped = dedup_memory_lines(raw)
  let mut shared_a = 0
  let mut echo_ok = 0
  for line in lines_of(deduped) {
    if line == "- shared rule A" {
      shared_a += 1
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
  assert_eq(dedup_memory_lines(deduped), deduped)
  // Purely duplicate repeated sections collapse heading to 1.
  let pure_dup = "# Global\n- shared rule A\n- shared rule B\n\n".repeat(8)
  assert_eq(dedup_memory_lines(pure_dup), "# Global\n- shared rule A\n- shared rule B\n")
  // P0-2: tables, thematic breaks, and distinct heading scopes are preserved.
  let md_struct = "## A\n| k | v |\n|---|---|\n| 1 | 2 |\n***\n___\n- - -\n- 无\n\n## B\n| k | v |\n|---|---|\n| 3 | 4 |\n***\n- 无\n"
  assert_eq(dedup_memory_lines(md_struct), md_struct)
  // P1-1: checkboxes [ ] and [x] stay distinct.
  let tasks = "- [ ] 发版\n- [x] 发版\n- [ ] 发版\n"
  assert_eq(dedup_memory_lines(tasks), "- [ ] 发版\n- [x] 发版\n")
  // P1-2: nested subheadings with new content keep parent heading; without new content collapse whole subtree.
  let nested_new = "## A\n### S\n- x\n## B\n- z\n## A\n### S\n- y\n"
  assert_eq(dedup_memory_lines(nested_new), nested_new)
  let nested_dup = "## A\n### S\n- x\n## B\n- z\n## A\n### S\n- x\n"
  assert_eq(dedup_memory_lines(nested_dup), "## A\n### S\n- x\n## B\n- z\n")
  // P2-2: inline ```x``` and 4-space indented fence do not flip fence state.
  let inline_fence = "```x```\n- dup\n- dup\n    ```\n- dup2\n- dup2\n"
  assert_eq(dedup_memory_lines(inline_fence), "```x```\n- dup\n    ```\n- dup2\n")
  assert_eq(dedup_memory_lines(dedup_memory_lines(inline_fence)), dedup_memory_lines(inline_fence))
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
