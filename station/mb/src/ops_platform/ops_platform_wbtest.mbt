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

///|
test "a command on Windows is found with PATHEXT, never as the POSIX script beside it" {
  let env = [("Path", "C:\\npm;C:\\bin"), ("PATHEXT", ".COM;.EXE;.BAT;.CMD")]
  let join = (parts : Array[String]) => parts.join("\\")
  // npm's `codex` (a `#!/bin/sh` script) and `codex.cmd` side by side: the .cmd, which Windows runs.
  let files = ["C:\\npm\\codex", "C:\\npm\\codex.cmd", "C:\\bin\\git.exe"]
  let there = (p : String) => files.contains(p)
  assert_eq(win_find_command("codex", env, ";", join, there), Some("C:\\npm\\codex.cmd"))
  // A name with its extension already is found as it is.
  assert_eq(win_find_command("git.exe", env, ";", join, there), Some("C:\\bin\\git.exe"))
  assert_eq(win_find_command("git", env, ";", join, there), Some("C:\\bin\\git.exe"))
  // The script alone is no command on Windows.
  assert_eq(win_find_command("codex", env, ";", join, p => p == "C:\\npm\\codex"), None)
  // No PATH, nothing found.
  assert_eq(win_find_command("codex", [], ";", join, there), None)
}
