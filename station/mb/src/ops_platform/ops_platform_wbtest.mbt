///|
test "Node's path.win32 and the platform's readings" {
  inspect(win32_resolve(["c:/Users/x/../y/./z"], "C:\\"), content="c:\\Users\\y\\z")
  inspect(win32_relative("C:\\a\\b", "c:\\A\\x", "C:\\"), content="..\\x")
  inspect(win32_dirname("\\\\server\\share\\a"), content="\\\\server\\share\\")
  assert_eq(parse_u64("+12"), Some(12.0))
  assert_eq(pressure_of_level("2", available=Some(1.0), total=Some(100.0)), Some("critical"))
  inspect(proc_address("0100007F"), content="127.0.0.1")
}

///|
test "a command's output and the log as it may leave" {
  inspect(plain_text("\u{1b}[1;32mok\u{1b}[0m\r\nnext"), content="ok\nnext")
  assert_eq(urls_in("see https://a.b/c, then"), ["https://a.b/c"])
  assert_eq(device_code_in("your one-time code: ABCD-1234", []), Some("ABCD-1234"))
  inspect(scrub_text("alice@example.com at /Users/alice/x", ""), content="<email> at ~/x")
  inspect(sha1_hex(b"abc"), content="a9993e364706816aba3e25717850c26c9cd0d89d")
}
