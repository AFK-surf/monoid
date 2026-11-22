// Upstream Node.js test/parallel/test-path-*.js conformance tests for @nodepath.
// Contract note: @nodepath exposes join, dirname, basename, with_extension, relative_parts,
// and is_absolute (matching Node's path.posix / path.win32 semantics for those APIs).

///|
test "conformance: Node.js path.posix.join upstream vectors" {
  let cases : Array[(Array[String], String)] = [
    ([".", "x/b", "..", "/b/c.js"], "x/b/c.js"),
    ([], "."),
    (["/.", "x/b", "..", "/b/c.js"], "/x/b/c.js"),
    (["/foo", "../../../bar"], "/bar"),
    (["foo", "../../../bar"], "../../bar"),
    (["foo/", "../../../bar"], "../../bar"),
    (["foo/x", "../../../bar"], "../bar"),
    (["foo/x", "./bar"], "foo/x/bar"),
    (["foo/x/", "./bar"], "foo/x/bar"),
    (["foo/x/", ".", "bar"], "foo/x/bar"),
    (["./"], "./"),
    ([".", "./"], "./"),
    ([".", ".", "."], "."),
    ([".", "./", "."], "."),
    ([".", "/./", "."], "."),
    ([".", "/////./", "."], "."),
    (["."], "."),
    (["", "."], "."),
    (["", "foo"], "foo"),
    (["foo", "/bar"], "foo/bar"),
    (["", "/foo"], "/foo"),
    (["", "", "/foo"], "/foo"),
    (["", "", "foo"], "foo"),
    (["foo", ""], "foo"),
    (["foo/", ""], "foo/"),
    (["foo", "", "/bar"], "foo/bar"),
    (["./", "..", "/foo"], "../foo"),
    (["./", "..", "..", "/foo"], "../../foo"),
    ([".", "..", "..", "/foo"], "../../foo"),
    (["", "..", "..", "/foo"], "../../foo"),
    (["/"], "/"),
    (["/", "."], "/"),
    (["/", ".."], "/"),
    (["/", "..", ".."], "/"),
    ([""], "."),
    (["", ""], "."),
    ([" /foo"], " /foo"),
    ([" ", "foo"], " /foo"),
    ([" ", "."], " "),
    ([" ", "/"], " /"),
    ([" ", ""], " "),
    (["/", "foo"], "/foo"),
    (["/", "/foo"], "/foo"),
    (["/", "//foo"], "/foo"),
    (["/", "", "/foo"], "/foo"),
    (["", "/", "foo"], "/foo"),
    (["", "/", "/foo"], "/foo"),
    // Dotfiles and special dot names
    (["a", ".bashrc"], "a/.bashrc"),
    (["a", "..b"], "a/..b"),
    (["a", ".a."], "a/.a."),
    (["a", "..."], "a/..."),
  ]
  for c in cases {
    assert_eq(@nodepath.join("/", c.0), c.1)
  }
}

///|
test "conformance: Node.js path.win32.join upstream vectors (UNC, drive-relative, non-drive colon)" {
  let cases : Array[(Array[String], String)] = [
    // UNC paths: .. must not escape above \\host\share\
    (["\\\\host\\share"], "\\\\host\\share\\"),
    (["\\\\host\\share\\"], "\\\\host\\share\\"),
    (["\\\\host\\share", ".."], "\\\\host\\share\\"),
    (["\\\\host\\share", "..", "x"], "\\\\host\\share\\x"),
    (["\\\\host\\share\\a", "..\\..\\b"], "\\\\host\\share\\b"),
    (["//host/share", "a/b"], "\\\\host\\share\\a\\b"),
    (["//host/share/a", "..", "..", "b"], "\\\\host\\share\\b"),
    // Leading separators that only meet at join boundary do NOT become UNC
    (["\\", "a"], "\\a"),
    (["\\\\", "a"], "\\a"),
    (["\\", "\\a"], "\\a"),
    (["/", "a"], "\\a"),
    (["//", "a"], "\\a"),
    (["///", "a"], "\\a"),
    // Drive-relative vs drive-absolute paths
    (["C:"], "C:."),
    (["C:", ""], "C:."),
    (["C:", "."], "C:\\"),
    (["C:", ".."], "C:\\"),
    (["C:", "a"], "C:\\a"),
    (["C:a", ".."], "C:."),
    (["C:a\\", ".."], "C:."),
    (["C:a", "..\\..\\b"], "C:..\\b"),
    (["C:\\", ".."], "C:\\"),
    (["C:\\a", "..\\..\\b"], "C:\\b"),
    (["C:\\a\\b\\", ".."], "C:\\a"),
    (["C:\\a", "."], "C:\\a"),
    (["C:\\a\\"], "C:\\a\\"),
    (["c:/a/b/", "c"], "c:\\a\\b\\c"),
    // Non-drive letter before ':' is NOT a Windows drive
    (["1:\\foo", "bar"], ".\\1:\\foo\\bar"),
    (["1:", "bar"], ".\\1:\\bar"),
    ([":\\foo", "bar"], ".\\:\\foo\\bar"),
    (["a:b", "c"], "a:b\\c"),
    // Relative & trailing slashes
    (["a", "..", ".."], ".."),
    ([".", "a"], "a"),
    (["", ""], "."),
    (["a\\b", "c\\"], "a\\b\\c\\"),
    (["a/b/", ""], "a\\b\\"),
  ]
  for c in cases {
    assert_eq(@nodepath.join("\\", c.0), c.1)
  }
}

///|
test "conformance: Node.js path.posix and path.win32 dirname/basename/isAbsolute vectors" {
  // POSIX dirname / basename / isAbsolute
  let posix_cases : Array[(String, String, String, Bool)] = [
    ("", ".", "", false),
    (".", ".", ".", false),
    ("..", ".", "..", false),
    ("/", "/", "", true),
    ("//", "/", "", true),
    ("///", "/", "", true),
    ("/a", "/", "a", true),
    ("/a/", "/", "a", true),
    ("///a", "//", "a", true),
    ("//a/b", "//a", "b", true),
    ("/a/b", "/a", "b", true),
    ("/a/b/", "/a", "b", true),
    ("a/b", "a", "b", false),
    ("a//b", "a/", "b", false),
    (".bashrc", ".", ".bashrc", false),
    ("/.bashrc", "/", ".bashrc", true),
    ("a/.bashrc", "a", ".bashrc", false),
    ("a/..b", "a", "..b", false),
    ("a/.a.", "a", ".a.", false),
    ("a/.", "a", ".", false),
    ("a/..", "a", "..", false),
    ("C:\\a", ".", "C:\\a", false),
  ]
  for c in posix_cases {
    assert_eq(@nodepath.dirname("/", c.0), c.1)
    assert_eq(@nodepath.basename("/", c.0), c.2)
    assert_eq(@nodepath.is_absolute("/", c.0), c.3)
  }
  // Win32 dirname / basename / isAbsolute
  let win_cases : Array[(String, String, String, Bool)] = [
    ("", ".", "", false),
    (".", ".", ".", false),
    ("..", ".", "..", false),
    ("/", "/", "", true),
    ("\\", "\\", "", true),
    ("//", "/", "", true),
    ("\\\\", "\\", "", true),
    ("///", "/", "", true),
    ("\\\\\\", "\\", "", true),
    ("a", ".", "a", false),
    ("/a", "/", "a", true),
    ("\\a", "\\", "a", true),
    ("/a/", "/", "a", true),
    ("\\a\\", "\\", "a", true),
    ("a/b", "a", "b", false),
    ("a//b", "a/", "b", false),
    ("a\\b", "a", "b", false),
    ("a\\\\b", "a\\", "b", false),
    ("C:", "C:", "", false),
    ("C:\\", "C:\\", "", true),
    ("C:/", "C:/", "", true),
    ("C:a", "C:", "a", false),
    ("C:\\a", "C:\\", "a", true),
    ("C:\\a\\b", "C:\\a", "b", true),
    ("C:a\\b", "C:a", "b", false),
    ("C:a\\b\\", "C:a", "b", false),
    // Non-drive colon is not a root
    ("1:", ".", "1:", false),
    ("1:\\a", "1:", "a", false),
    ("1:\\a\\b", "1:\\a", "b", false),
    (":a", ".", ":a", false),
    (":\\a", ":", "a", false),
    // UNC paths: basename of \\srv\share is "share" in Node path.win32!
    ("\\\\srv", "\\", "srv", true),
    ("\\\\srv\\", "\\", "srv", true),
    ("\\\\srv\\share", "\\\\srv\\share", "share", true),
    ("\\\\srv\\share\\", "\\\\srv\\share\\", "share", true),
    ("\\\\srv\\share\\a", "\\\\srv\\share\\", "a", true),
    ("\\\\srv\\share\\a\\b", "\\\\srv\\share\\a", "b", true),
    ("//srv/share", "//srv/share", "share", true),
    ("//srv/share/", "//srv/share/", "share", true),
    ("//srv/share/a", "//srv/share/", "a", true),
    // Dotfiles
    (".bashrc", ".", ".bashrc", false),
    ("/.bashrc", "/", ".bashrc", true),
    ("a/.bashrc", "a", ".bashrc", false),
    ("a/..b", "a", "..b", false),
    ("a/.", "a", ".", false),
    ("a/..", "a", "..", false),
  ]
  for c in win_cases {
    assert_eq(@nodepath.dirname("\\", c.0), c.1)
    assert_eq(@nodepath.basename("\\", c.0), c.2)
    assert_eq(@nodepath.is_absolute("\\", c.0), c.3)
  }
}
