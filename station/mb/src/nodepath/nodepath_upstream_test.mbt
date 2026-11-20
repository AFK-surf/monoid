// Upstream nodejs/node test/parallel/test-path-*.js (commit 3c26849e1724c8789d8789229e3051f4e8110198, MIT)
// regression tests for @nodepath (including POSIX //a dirname, CVE-2024-36139, CVE-2025-27210).
// Full matrix is also cross-checked live against node:path.{posix,win32} in station/test/mb-upstream-corpora.test.ts.

///|
test "upstream Node test-path-dirname: POSIX double-slash preservation" {
  assert_eq(@nodepath.dirname("/", "//a"), "//")
  assert_eq(@nodepath.dirname("/", "//a/"), "//")
  assert_eq(@nodepath.dirname("/", "///a"), "//")
  assert_eq(@nodepath.dirname("/", "////a"), "///")
  assert_eq(@nodepath.dirname("/", "////"), "/")
  assert_eq(@nodepath.dirname("/", "/a"), "/")
  assert_eq(@nodepath.dirname("/", "//a/b"), "//a")
}

///|
test "upstream Node test-path-join: Win32 CVE-2024-36139 and CVE-2025-27210" {
  // CVE-2024-36139: relative path normalizing to drive/colon prefix must get `.\` prefix
  assert_eq(@nodepath.join("\\", ["./upload", "/../C:/Windows"]), ".\\C:\\Windows")
  assert_eq(@nodepath.join("\\", ["upload", "../", "C:foo"]), ".\\C:foo")
  assert_eq(@nodepath.join("\\", ["test/..", "??/D:/Test"]), ".\\??\\D:\\Test")
  assert_eq(@nodepath.join("\\", ["test", "..", "D:"]), ".\\D:")
  assert_eq(@nodepath.join("\\", ["test", "..", "D:\\"]), ".\\D:\\")
  assert_eq(@nodepath.join("\\", ["test", "..", "D:foo"]), ".\\D:foo")
  // CVE-2025-27210: Windows reserved device names with `:` skip normalization in join
  assert_eq(
    @nodepath.join("\\", ["\\fileserver\\public\\uploads", "CON:..\\..\\..\\private\\db.conf"]),
    "\\fileserver\\public\\uploads\\CON:..\\..\\..\\private\\db.conf",
  )
  assert_eq(
    @nodepath.join("\\", ["\\server\\share", "COM1:"]),
    "\\server\\share\\COM1:",
  )
  assert_eq(
    @nodepath.join("\\", ["\\server\\share", "path", "LPT1:"]),
    "\\server\\share\\path\\LPT1:",
  )
}
