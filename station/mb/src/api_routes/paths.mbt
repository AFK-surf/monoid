// Paths as the station checks them (station/src/ops/paths.ts on a Unix machine: `/` separates, compared as they are).

///|
/// files.rs `clean`: absolute, `.` and `..` worked out lexically.
pub fn clean(path : String) -> String {
  let out : Array[String] = []
  for part in path.split("/") {
    let part = part.to_string()
    if part == "" || part == "." {
      continue
    }
    if part == ".." {
      ignore(out.pop())
    } else {
      out.push(part)
    }
  }
  "/" + out.join("/")
}

///|
pub fn same_path(a : String, b : String) -> Bool {
  a == b
}

///|
/// `path` is `dir` or under it.
pub fn within(path : String, dir : String) -> Bool {
  dir == "/" || path == dir || path.has_prefix(dir + "/")
}

///|
/// Under `dir`, and not `dir` itself.
pub fn inside(path : String, dir : String) -> Bool {
  !same_path(path, dir) && within(path, dir)
}

///|
/// Path::file_name: the last part; none for `..` or the root.
pub fn file_name(path : String) -> String? {
  let parts = path
    .split("/")
    .map(p => p.to_string())
    .filter(p => p != "" && p != ".")
    .collect()
  match parts.last() {
    None => None
    Some("..") => None
    Some(last) => Some(last)
  }
}

///|
/// node:path `join` (POSIX): the parts joined by `/`, normalized; "." for nothing.
pub fn join(parts : Array[String]) -> String {
  let given = parts.filter(p => p != "")
  if given.length() == 0 {
    return "."
  }
  normalize(given.join("/"))
}

///|
/// node:path `normalize` (POSIX).
pub fn normalize(path : String) -> String {
  if path == "" {
    return "."
  }
  let absolute = path.has_prefix("/")
  let trailing = path.has_suffix("/")
  let out : Array[String] = []
  for part in path.split("/") {
    let part = part.to_string()
    if part == "" || part == "." {
      continue
    }
    if part == ".." {
      if out.length() > 0 && out[out.length() - 1] != ".." {
        ignore(out.pop())
      } else if !absolute {
        out.push("..")
      }
    } else {
      out.push(part)
    }
  }
  let mut joined = out.join("/")
  if joined == "" && !absolute {
    joined = "."
  }
  if joined != "" && trailing {
    joined = joined + "/"
  }
  if absolute {
    "/" + joined
  } else {
    joined
  }
}

///|
/// node:path `dirname` (POSIX).
pub fn dirname(path : String) -> String {
  if path == "" {
    return "."
  }
  let absolute = path.unsafe_charcode_at(0) == '/'
  let mut end = -1
  let mut matched_slash = true
  let mut i = path.length() - 1
  while i >= 1 {
    if path.unsafe_charcode_at(i) == '/' {
      if !matched_slash {
        end = i
        break
      }
    } else {
      matched_slash = false
    }
    i -= 1
  }
  if end == -1 {
    return if absolute { "/" } else { "." }
  }
  if absolute && end == 1 {
    return "//"
  }
  path.unsafe_substring(start=0, end~)
}

///|
/// A name that is one file or directory on every machine a station runs on (paths.ts `portableName`).
pub fn portable_name(name : String) -> Bool {
  if name == "" || name.has_prefix(".") {
    return false
  }
  for i in 0..<name.length() {
    let c = name.unsafe_charcode_at(i)
    if c < 0x20 ||
      c == '<' ||
      c == '>' ||
      c == ':' ||
      c == '"' ||
      c == '/' ||
      c == '\\' ||
      c == '|' ||
      c == '?' ||
      c == '*' {
      return false
    }
  }
  if name.has_suffix(".") || name.has_suffix(" ") {
    return false
  }
  if re("^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(\\.|$)", flags="i").matches(
      name,
    ) {
    return false
  }
  utf8(name).length() <= 255
}
