///|
test "path helpers handle Windows drive paths and backslashes" {
  // abspath
  assert_eq(
    abspath("D:/a/repo/apps/demo/mbui.json"),
    "D:/a/repo/apps/demo/mbui.json",
  )
  assert_eq(abspath("D:\\a\\b\\..\\c"), "D:/a/c")
  assert_eq(abspath("D:/a/../.."), "D:/")
  assert_eq(abspath("/a/b/../c"), "/a/c")

  // join
  assert_eq(join("D:/x", "C:/y"), "C:/y")
  assert_eq(join("D:\\x", "C:\\y"), "C:\\y")
  assert_eq(join("D:/x/", "y"), "D:/x/y")
  assert_eq(join("D:\\x\\", "y"), "D:\\x\\y")
  assert_eq(join("D:/x", "y"), "D:/x/y")

  // dirname
  assert_eq(dirname("D:/a"), "D:/")
  assert_eq(dirname("D:\\a"), "D:/")
  assert_eq(dirname("D:/a/b"), "D:/a")
  assert_eq(dirname("D:\\a\\b"), "D:/a")
  assert_eq(dirname("/a"), "")
  assert_eq(dirname("a"), "")

  // basename
  assert_eq(basename("D:/a/mbui.json"), "mbui.json")
  assert_eq(basename("D:\\a\\b\\mbui.json"), "mbui.json")
  assert_eq(basename("mbui.json"), "mbui.json")
}
