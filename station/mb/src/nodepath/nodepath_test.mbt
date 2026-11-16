///|
/// Node's path.posix.join and path.win32.join on the same parts (their answers as node gave them).
test "joined as Node joins" {
  let posix = [
    (["/a/b", "c"], "/a/b/c"),
    (["/a/b/", "c"], "/a/b/c"),
    (["/a//b", "./c"], "/a/b/c"),
    (["/a/b", "../c"], "/a/c"),
    (["a", "..", ".."], ".."),
    (["/", "..", "x"], "/x"),
    (["/a/b", "c/"], "/a/b/c/"),
    (["", ""], "."),
    (["/x", "grok/sessions"], "/x/grok/sessions"),
    (["rel/./x", "y"], "rel/x/y"),
  ]
  for c in posix {
    assert_eq(@nodepath.join("/", c.0), c.1)
  }
  let win = [
    (["C:\\a\\b", "c"], "C:\\a\\b\\c"),
    (["C:/a/b/", "c"], "C:\\a\\b\\c"),
    (["C:\\a", "..\\..\\b"], "C:\\b"),
    (["\\\\srv\\share\\x", "y"], "\\\\srv\\share\\x\\y"),
    (["C:", "x"], "C:\\x"),
    (["C:\\a\\b", "grok/sessions"], "C:\\a\\b\\grok\\sessions"),
    // (no share made of separators that met where the parts were joined)
    (["\\", "a"], "\\a"),
    (["\\\\", "a"], "\\a"),
    (["/", "/a"], "\\a"),
    (["a", "\\\\b"], "a\\b"),
  ]
  for c in win {
    assert_eq(@nodepath.join("\\", c.0), c.1)
  }
}

///|
/// Node's path.posix and path.win32 dirname and basename, and station/src/jobs/remote.ts `withExtension` on each (their
/// answers as node gave them).
test "dirname, basename and with_extension as Node has them" {
  let posix = [
    ("/a/b", "/a", "b", "/a/b.t.tmp"),
    ("/a/b/", "/a", "b", "/a/b.t.tmp"),
    ("/", "/", "", "/.t.tmp"),
    ("a", ".", "a", "a.t.tmp"),
    ("a//b", "a/", "b", "a/b.t.tmp"),
    ("/a", "/", "a", "/a.t.tmp"),
    ("", ".", "", ".t.tmp"),
    ("a/b/c.json", "a/b", "c.json", "a/b/c.t.tmp"),
  ]
  for c in posix {
    assert_eq((@nodepath.dirname("/", c.0), @nodepath.basename("/", c.0), @nodepath.with_extension("/", c.0, "t.tmp")), (c.1, c.2, c.3))
  }
  let win = [
    ("C:\\a\\b", "C:\\a", "b", "C:\\a\\b.t.tmp"),
    ("C:\\", "C:\\", "", "C:\\.t.tmp"),
    ("C:", "C:", "", "C:\\.t.tmp"),
    ("C:foo", "C:", "foo", "C:\\foo.t.tmp"),
    ("\\\\srv\\share\\x", "\\\\srv\\share\\", "x", "\\\\srv\\share\\x.t.tmp"),
    ("a\\b/c", "a\\b", "c", "a\\b\\c.t.tmp"),
    ("\\a", "\\", "a", "\\a.t.tmp"),
    ("C:/x/y/", "C:/x", "y", "C:\\x\\y.t.tmp"),
    ("a", ".", "a", "a.t.tmp"),
    ("", ".", "", ".t.tmp"),
    // (a record of the remote tasks' as Windows has it: never `./C:\…`, which the POSIX-only one made of it)
    ("C:\\data\\remote\\used\\x.json", "C:\\data\\remote\\used", "x.json", "C:\\data\\remote\\used\\x.t.tmp"),
  ]
  for c in win {
    assert_eq((@nodepath.dirname("\\", c.0), @nodepath.basename("\\", c.0), @nodepath.with_extension("\\", c.0, "t.tmp")), (c.1, c.2, c.3))
  }
}

///|
/// station/src/ops/paths.ts `relativeParts` as the POSIX and the Windows platform have it (station/test/paths.test.ts).
test "relative parts as the station's paths take them" {
  assert_eq(@nodepath.relative_parts("/", "a/b"), Some(["a", "b"]))
  assert_eq(@nodepath.relative_parts("/", "./a//b/"), Some([".", "a", "", "b", ""]))
  assert_eq(@nodepath.relative_parts("/", "a\\b"), Some(["a\\b"]))
  assert_eq(@nodepath.relative_parts("/", "..\\..\\x"), Some(["..\\..\\x"]))
  assert_eq(@nodepath.relative_parts("/", "C:x"), Some(["C:x"]))
  for p in ["", "/a", "a/../b", "..", "a/.."] {
    assert_eq(@nodepath.relative_parts("/", p), None)
  }
  assert_eq(@nodepath.relative_parts("\\", "a\\b/c"), Some(["a", "b", "c"]))
  assert_eq(@nodepath.relative_parts("\\", ".\\a"), Some([".", "a"]))
  // (a way out of the transfer's root on a Windows station: up, a drive, a share, a stream, the root)
  for p in ["", "..\\..\\x", "a\\..\\..\\b", "a/..\\b", "C:\\x", "C:x", "c:/x", "\\\\srv\\share\\x", "\\x", "/x", "a:stream", "..", "a\\.."] {
    assert_eq(@nodepath.relative_parts("\\", p), None)
  }
}

///|
/// Node's path.posix.isAbsolute and path.win32.isAbsolute (a task's `dir` and `back` on the station that sends it).
test "absolute as Node has it" {
  for c in [("/a", true), ("a", false), ("", false), ("C:\\a", false), ("\\a", false)] {
    assert_eq(@nodepath.is_absolute("/", c.0), c.1)
  }
  for c in [("/a", true), ("\\a", true), ("C:\\a", true), ("c:/a", true), ("C:a", false), ("C:", false), ("a\\b", false), ("", false), ("1:\\a", false)] {
    assert_eq(@nodepath.is_absolute("\\", c.0), c.1)
  }
}
