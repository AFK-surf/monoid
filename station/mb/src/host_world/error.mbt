// Shared host-adaptation primitives for station packages on `@host.Host` (client/shell's `fs.*`, `ws.*`,
// `crypto.*` and `@effect.Runtime` timers/daemons).

///|
/// Extract a readable message from an error raised by `@host.Host::shell` or `shell_sync`.
pub fn shell_error_msg(e : Error) -> String {
  match e {
    @wire.ShellError(m) => m
    _ => e.to_string()
  }
}

///|
/// Map a Rust `io::Error` message (`… (os error N)` on Unix or Windows, or text fallback) to a Node-style
/// POSIX error code (`ENOENT`, `EEXIST`, `EACCES`, `EISDIR`, `ENOTDIR`, `ENOTEMPTY`, `EPERM`, or `EIO`).
pub fn os_code(message : String) -> String {
  let codes : Array[(String, String)] = [
    ("(os error 2)", "ENOENT"),
    ("(os error 17)", "EEXIST"),
    ("(os error 13)", "EACCES"),
    ("(os error 21)", "EISDIR"),
    ("(os error 20)", "ENOTDIR"),
    ("(os error 39)", "ENOTEMPTY"),
    ("(os error 66)", "ENOTEMPTY"),
    ("(os error 1)", "EPERM"),
    // Windows
    ("(os error 3)", "ENOENT"),
    ("(os error 5)", "EACCES"),
    ("(os error 80)", "EEXIST"),
    ("(os error 183)", "EEXIST"),
    ("(os error 145)", "ENOTEMPTY"),
  ]
  for c in codes {
    if message.contains(c.0) {
      return c.1
    }
  }
  if message.contains("No such file") || message.contains("cannot find the ") {
    return "ENOENT"
  }
  if message.contains("exists") {
    return "EEXIST"
  }
  if message.contains("denied") {
    return "EACCES"
  }
  "EIO"
}

///|
/// Format a Node-style ENOENT error message.
pub fn enoent_msg(op : String, path : String) -> String {
  "ENOENT: no such file or directory, \{op} '\{path}'"
}

///|
/// Format a Node-style EEXIST error message.
pub fn eexist_msg(op : String, path : String) -> String {
  "EEXIST: file already exists, \{op} '\{path}'"
}

///|
/// Decode a hex string into bytes via `@codec.hex_decode`, returning empty bytes if invalid.
pub fn hex_bytes(hex : String) -> Bytes {
  @codec.hex_decode(hex).unwrap_or(b"")
}
