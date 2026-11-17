// Paths made as Node's path.join makes them (posix's, or win32's when the separator is `\`), for what the station's
// programs give back to the TypeScript station to compare with its own.

///|
fn is_sep(c : Int, win : Bool) -> Bool {
  c == '/' || (win && c == '\\')
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
  let mut root = ""
  let mut at = 0
  if win && n >= 2 && path.unsafe_charcode_at(1) == ':' {
    root = path.exact_view(end=2).to_owned()
    at = 2
    if n > 2 && is_sep(path.unsafe_charcode_at(2), true) {
      root = root + "\\"
      at = 3
    }
  } else if win && n >= 2 && is_sep(path.unsafe_charcode_at(0), true) && is_sep(path.unsafe_charcode_at(1), true) {
    root = "\\\\"
    at = 2
  } else if n > 0 && is_sep(path.unsafe_charcode_at(0), win) {
    root = sep
    at = 1
  }
  let absolute = root != "" && (root.length() != 2 || !win || root == "\\\\")
  let parts : Array[String] = []
  let mut start = at
  for i = at; i <= n; i = i + 1 {
    if i < n && !is_sep(path.unsafe_charcode_at(i), win) {
      continue
    }
    let part = path.view(start_offset=start, end_offset=i).to_owned()
    start = i + 1
    if part == "" || part == "." {
      continue
    }
    if part == ".." {
      if parts.length() > 0 && parts[parts.length() - 1] != ".." {
        ignore(parts.pop())
      } else if !absolute {
        parts.push(part)
      }
      continue
    }
    parts.push(part)
  }
  let body = parts.join(sep)
  let trailing = n > at && is_sep(path.unsafe_charcode_at(n - 1), win) && body != ""
  let out = root + body + (if trailing { sep } else { "" })
  if out == "" {
    "."
  } else {
    out
  }
}


///|
/// How long the root of `path` is (Node's path.parse's root): `/` on POSIX; on Windows a drive (`C:`, `C:\`), a share
/// (`\\server\share\`) or a leading separator.
fn root_length(path : String, win : Bool) -> Int {
  let n = path.length()
  if !win {
    return if n > 0 && path.unsafe_charcode_at(0) == '/' { 1 } else { 0 }
  }
  if n >= 2 && path.unsafe_charcode_at(1) == ':' {
    return if n > 2 && is_sep(path.unsafe_charcode_at(2), true) { 3 } else { 2 }
  }
  if n == 0 || !is_sep(path.unsafe_charcode_at(0), true) {
    return 0
  }
  if n >= 2 && is_sep(path.unsafe_charcode_at(1), true) {
    // (a share: two names after the separators, its root ending after the second's separator)
    let mut i = 2
    let mut names = 0
    while i < n && names < 2 {
      let start = i
      while i < n && !is_sep(path.unsafe_charcode_at(i), true) {
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
  while i >= root && is_sep(path.unsafe_charcode_at(i), win) {
    i -= 1
  }
  while i >= root && !is_sep(path.unsafe_charcode_at(i), win) {
    i -= 1
  }
  if i < root {
    return if root > 0 { path.view(end_offset=root).to_string() } else { "." }
  }
  path.view(end_offset=i).to_string()
}

///|
/// Node's path.basename: the last part, its trailing separators left out ("" for a root).
pub fn basename(sep : String, path : String) -> String {
  let win = sep == "\\"
  let root = root_length(path, win)
  let mut end = path.length()
  while end > root && is_sep(path.unsafe_charcode_at(end - 1), win) {
    end -= 1
  }
  let mut start = end
  while start > root && !is_sep(path.unsafe_charcode_at(start - 1), win) {
    start -= 1
  }
  path.view(start_offset=start, end_offset=end).to_string()
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
