// node:path's POSIX functions, as the tools use them (join, resolve, dirname, basename, isAbsolute).

///|
pub fn path_is_absolute(p : String) -> Bool {
  p.has_prefix("/")
}

///|
/// path.normalize's segments: `.` and empty ones dropped, `..` taking one back (kept at a relative path's start).
fn normalize_segments(p : String, absolute : Bool) -> Array[String] {
  let out : Array[String] = []
  for seg in split(p, "/") {
    if seg == "" || seg == "." {
      continue
    }
    if seg == ".." {
      if out.length() > 0 && out[out.length() - 1] != ".." {
        ignore(out.pop())
      } else if !absolute {
        out.push("..")
      }
      continue
    }
    out.push(seg)
  }
  out
}

///|
/// path.normalize.
pub fn path_normalize(p : String) -> String {
  @nodepath.join("/", [p])
}

///|
/// path.join.
pub fn path_join(parts : Array[String]) -> String {
  @nodepath.join("/", parts)
}

///|
/// path.resolve, from `base` (an absolute directory: the process's own working directory is never read here).
pub fn path_resolve(base : String, parts : Array[String]) -> String {
  let mut resolved = ""
  let mut absolute = false
  let all = [base, ..parts]
  let mut i = all.length() - 1
  while i >= 0 && !absolute {
    let p = all[i]
    if p != "" {
      resolved = if resolved == "" { p } else { p + "/" + resolved }
      absolute = path_is_absolute(p)
    }
    i -= 1
  }
  let segs = normalize_segments(resolved, absolute)
  if absolute {
    "/" + segs.join("/")
  } else if segs.length() == 0 {
    "."
  } else {
    segs.join("/")
  }
}

///|
/// path.dirname.
pub fn path_dirname(p : String) -> String {
  if p == "" {
    return "."
  }
  let has_root = p.unsafe_charcode_at(0) == '/'
  let mut end = -1
  let mut matched_slash = true
  let mut i = p.length() - 1
  while i >= 1 {
    if p.unsafe_charcode_at(i) == '/' {
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
    return if has_root { "/" } else { "." }
  }
  if has_root && end == 1 {
    return "//"
  }
  slice(p, 0, to=end)
}

///|
/// path.basename.
pub fn path_basename(p : String) -> String {
  @nodepath.basename("/", p)
}
