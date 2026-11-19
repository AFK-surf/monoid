// Paths made as Node's path.join makes them (posix's, or win32's when the separator is `\`), for what the station's
// programs give back to the TypeScript station to compare with its own.

///|
fn is_sep(c : Int, win : Bool) -> Bool {
  c == '/' || (win && c == '\\')
}

///|
fn is_alpha(c : Int) -> Bool {
  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}

///|
fn is_drive(path : String) -> Bool {
  path.length() >= 2 && is_alpha(path.unsafe_get(0).to_int()) && path.unsafe_get(1).to_int() == ':'
}

///|
/// Node's path.join: the parts joined, then normalized.
pub fn join(sep : String, parts : Array[String]) -> String {
  let given = parts.filter(p => p != "")
  let mut joined = given.join(sep)
  if sep == "\\" && given.length() > 0 {
    joined = not_a_share(given[0], joined)
  }
  normalize(sep, if joined == "" { "." } else { joined })
}

///|
/// path.win32.join's: separators that only met where the parts were joined (`\` and `a`) make no share (`\\a`), so
/// the leading ones are made one unless the first part began a share itself.
fn not_a_share(first : String, joined : String) -> String {
  let n = first.length()
  let mut leading = 0
  if n > 0 && is_sep(first.unsafe_charcode_at(0), true) {
    leading = 1
    if n > 1 && is_sep(first.unsafe_charcode_at(1), true) {
      leading = 2
      if n > 2 {
        if !is_sep(first.unsafe_charcode_at(2), true) {
          return joined
        }
        leading = 3
      }
    }
  }
  while leading < joined.length() && is_sep(joined.unsafe_charcode_at(leading), true) {
    leading += 1
  }
  if leading >= 2 {
    "\\" + joined.view(start_offset=leading).to_string()
  } else {
    joined
  }
}

///|
/// Node's path.normalize: `.` and `..` taken out by name, repeated separators made one, the trailing one kept.
fn normalize(sep : String, path : String) -> String {
  let win = sep == "\\"
  let n = path.length()
  if n == 0 {
    return "."
  }
  let mut device = ""
  let mut is_abs = false
  let mut at = 0
  if win {
    if is_sep(path.unsafe_get(0).to_int(), true) {
      is_abs = true
      if n >= 2 && is_sep(path.unsafe_get(1).to_int(), true) {
        // UNC root: \\host\share (only when char 2 is not a separator and two non-empty segments follow)
        if n > 2 && !is_sep(path.unsafe_get(2).to_int(), true) {
          let mut j = 2
          while j < n && !is_sep(path.unsafe_get(j).to_int(), true) {
            j += 1
          }
          let host = path.exact_view(start=2, end=j).to_owned()
          let sep_start = j
          while j < n && is_sep(path.unsafe_get(j).to_int(), true) {
            j += 1
          }
          if j > sep_start && j < n {
            let share_start = j
            while j < n && !is_sep(path.unsafe_get(j).to_int(), true) {
              j += 1
            }
            let share = path.exact_view(start=share_start, end=j).to_owned()
            device = "\\\\" + host + "\\" + share
            at = j
          } else {
            at = 2
          }
        } else {
          at = 2
        }
      } else {
        at = 1
      }
    } else if is_drive(path) {
      device = path.exact_view(end=2).to_owned()
      if n > 2 && is_sep(path.unsafe_get(2).to_int(), true) {
        is_abs = true
        at = 3
      } else {
        at = 2
      }
    }
  } else if path.unsafe_get(0).to_int() == '/' {
    is_abs = true
    at = 1
  }
  let parts : Array[String] = []
  let mut start = at
  for i = at; i <= n; i = i + 1 {
    if i < n && !is_sep(path.unsafe_get(i).to_int(), win) {
      continue
    }
    let part = path.exact_view(start=start, end=i).to_owned()
    start = i + 1
    if part == "" || part == "." {
      continue
    }
    if part == ".." {
      if parts.length() > 0 && parts[parts.length() - 1] != ".." {
        ignore(parts.pop())
      } else if !is_abs {
        parts.push(part)
      }
      continue
    }
    parts.push(part)
  }
  let mut tail = parts.join(sep)
  let trailing = n > 0 && is_sep(path.unsafe_get(n - 1).to_int(), win)
  if tail == "" && !is_abs {
    tail = "."
  }
  if tail != "" && trailing {
    tail = tail + sep
  }
  if win && device == "" && !is_abs {
    // Node's path.win32.normalize prefixes `.\` when the first segment of a relative path ends with `:`
    let first_end = match tail.find("\\") {
      Some(i) => i
      None => tail.length()
    }
    if first_end > 0 && tail.unsafe_get(first_end - 1).to_int() == ':' {
      tail = ".\\" + tail
    }
  }
  if device == "" {
    if is_abs { sep + tail } else { tail }
  } else if is_abs {
    device + "\\" + tail
  } else {
    device + tail
  }
}


///|
/// How long the root of `path` is (Node's path.parse's root): `/` on POSIX; on Windows a drive (`C:`, `C:\`), a share
/// (`\\server\share\`) or a leading separator.
fn root_length(path : String, win : Bool) -> Int {
  let n = path.length()
  if !win {
    return if n > 0 && path.unsafe_get(0).to_int() == '/' { 1 } else { 0 }
  }
  if is_drive(path) {
    return if n > 2 && is_sep(path.unsafe_get(2).to_int(), true) { 3 } else { 2 }
  }
  if n == 0 || !is_sep(path.unsafe_get(0).to_int(), true) {
    return 0
  }
  if n >= 2 && is_sep(path.unsafe_get(1).to_int(), true) {
    // (a share: two names after the separators, its root ending after the second's separator)
    let mut i = 2
    let mut names = 0
    while i < n && names < 2 {
      let start = i
      while i < n && !is_sep(path.unsafe_get(i).to_int(), true) {
        i += 1
      }
      if i == start {
        return 1
      }
      names += 1
      if names < 2 {
        if i == n {
          return 1
        }
        i += 1
      }
    }
    if names == 2 {
      return if i < n { i + 1 } else { i }
    }
  }
  1
}

///|
/// Node's path.dirname: the path up to its last part's separator (the root alone kept, `.` for none).
pub fn dirname(sep : String, path : String) -> String {
  let win = sep == "\\"
  let root = root_length(path, win)
  let mut i = path.length() - 1
  // (separators after the last part, then the last part)
  while i >= root && is_sep(path.unsafe_get(i).to_int(), win) {
    i -= 1
  }
  while i >= root && !is_sep(path.unsafe_get(i).to_int(), win) {
    i -= 1
  }
  if i < root {
    return if root > 0 { path.exact_view(end=root).to_owned() } else { "." }
  }
  path.exact_view(end=i).to_owned()
}

///|
/// Node's path.basename: the last part, its trailing separators left out ("" for a root).
pub fn basename(sep : String, path : String) -> String {
  let win = sep == "\\"
  // Node's path.win32.basename only skips a drive letter prefix (`C:`), not a UNC share (`\\srv\share` -> `share`).
  let start_min = if win && is_drive(path) { 2 } else { 0 }
  let mut end = path.length()
  while end > start_min && is_sep(path.unsafe_get(end - 1).to_int(), win) {
    end -= 1
  }
  let mut start = end
  while start > start_min && !is_sep(path.unsafe_get(start - 1).to_int(), win) {
    start -= 1
  }
  path.exact_view(start=start, end=end).to_owned()
}

///|
/// station/src/jobs/remote.ts `withExtension` (Path::with_extension): the file name's extension replaced (or added),
/// joined again as Node joins.
pub fn with_extension(sep : String, path : String, ext : String) -> String {
  let name = basename(sep, path)
  let stem = match name.rev_find(".") {
    Some(i) if i > 0 => name.view(end_offset=i).to_string()
    _ => name
  }
  join(sep, [dirname(sep, path), "\{stem}.\{ext}"])
}

///|
/// station/src/ops/paths.ts `relativeParts` on the station's system (`sep`): the components of a path given as relative
/// (None for one rooted: `/`; on Windows `\` too, a drive, a share or a stream, anything with a `:`), or with a `..`
/// among them. On Windows `/` and `\` both separate. `.` and empty components are the caller's to judge (kept).
pub fn relative_parts(sep : String, path : String) -> Array[String]? {
  let win = sep == "\\"
  if path == "" || path.has_prefix("/") || (win && (path.has_prefix("\\") || path.contains(":"))) {
    return None
  }
  let parts : Array[String] = []
  let mut start = 0
  for i = 0; i <= path.length(); i = i + 1 {
    if i < path.length() && !is_sep(path.unsafe_charcode_at(i), win) {
      continue
    }
    parts.push(path.view(start_offset=start, end_offset=i).to_string())
    start = i + 1
  }
  if parts.iter().any(p => p == "..") {
    return None
  }
  Some(parts)
}

///|
/// Node's path.isAbsolute: a leading separator (on Windows `/` or `\`), or on Windows a drive and a separator (`C:\`).
pub fn is_absolute(sep : String, path : String) -> Bool {
  let win = sep == "\\"
  let n = path.length()
  if n > 0 && is_sep(path.unsafe_charcode_at(0), win) {
    return true
  }
  if !win || n < 3 || path.unsafe_charcode_at(1) != ':' || !is_sep(path.unsafe_charcode_at(2), true) {
    return false
  }
  let c = path.unsafe_charcode_at(0)
  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}
