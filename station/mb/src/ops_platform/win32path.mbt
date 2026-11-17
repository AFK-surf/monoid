// Node's path.win32 (lib/path.js, Node 24) as platform/windows.ts uses it: resolve, normalize, join, dirname,
// isAbsolute, relative. Windows' paths whatever runs it, so its parts are held to Node's on every machine. `cwd` is
// what process.cwd() would say, where a path is relative.

///|
fn wsep(c : Int) -> Bool {
  c == 47 || c == 92
}

///|
fn device_root(c : Int) -> Bool {
  is_alpha(c)
}

///|
/// Node's normalizeString: `.` and `..` worked out, separators made `sep`.
fn normalize_string(path : String, allow_above_root : Bool, sep : String, is_sep : (Int) -> Bool) -> String {
  let mut res = ""
  let mut last_segment_length = 0
  let mut last_slash = -1
  let mut dots = 0
  let mut code = 0
  let n = path.length()
  for i in 0..=n {
    if i < n {
      code = cu(path, i)
    } else if is_sep(code) {
      break
    } else {
      code = 47
    }
    if is_sep(code) {
      if last_slash == i - 1 || dots == 1 {
        ()
      } else if dots == 2 {
        if res.length() < 2 ||
          last_segment_length != 2 ||
          cu(res, res.length() - 1) != 46 ||
          cu(res, res.length() - 2) != 46 {
          if res.length() > 2 {
            let last_slash_index = last_index_of(res, sep)
            if last_slash_index == -1 {
              res = ""
              last_segment_length = 0
            } else {
              res = sub(res, 0, last_slash_index)
              last_segment_length = res.length() - 1 - last_index_of(res, sep)
            }
            last_slash = i
            dots = 0
            continue
          } else if res.length() != 0 {
            res = ""
            last_segment_length = 0
            last_slash = i
            dots = 0
            continue
          }
        }
        if allow_above_root {
          res = if res.length() > 0 { res + sep + ".." } else { ".." }
          last_segment_length = 2
        }
      } else {
        if res.length() > 0 {
          res = res + sep + sub(path, last_slash + 1, i)
        } else {
          res = sub(path, last_slash + 1, i)
        }
        last_segment_length = i - last_slash - 1
      }
      last_slash = i
      dots = 0
    } else if code == 46 && dots != -1 {
      dots += 1
    } else {
      dots = -1
    }
  }
  res
}

///|
/// path.win32.isAbsolute.
pub fn win32_is_absolute(path : String) -> Bool {
  let len = path.length()
  if len == 0 {
    return false
  }
  let code = cu(path, 0)
  wsep(code) || (len > 2 && device_root(code) && cu(path, 1) == 58 && wsep(cu(path, 2)))
}

///|
/// A UNC root (`\\server\share`) at the start of `path` (both its first characters separators): its device and where
/// it ends; None where it is not one.
fn unc_root(path : String) -> (String, Int, Bool)? {
  let len = path.length()
  let mut j = 2
  let mut last = j
  while j < len && !wsep(cu(path, j)) {
    j += 1
  }
  if j < len && j != last {
    let first = sub(path, last, j)
    last = j
    while j < len && wsep(cu(path, j)) {
      j += 1
    }
    if j < len && j != last {
      last = j
      while j < len && !wsep(cu(path, j)) {
        j += 1
      }
      if j == len || j != last {
        if first != "." && first != "?" {
          return Some(("\\\\" + first + "\\" + sub(path, last, j), j, j == len))
        }
        return Some(("\\\\" + first, 4, false))
      }
    }
  }
  None
}

///|
/// path.win32.resolve(path), relative to `cwd`.
pub fn win32_resolve(paths : Array[String], cwd : String) -> String {
  let mut resolved_device = ""
  let mut resolved_tail = ""
  let mut resolved_absolute = false
  let mut i = paths.length() - 1
  while i >= -1 {
    let path = if i >= 0 {
      paths[i]
    } else if resolved_device == "" {
      cwd
    } else {
      let p = cwd
      if lower(sub(p, 0, 2)) != lower(resolved_device) && p.length() > 2 && cu(p, 2) == 92 {
        resolved_device + "\\"
      } else {
        p
      }
    }
    i -= 1
    let len = path.length()
    let mut root_end = 0
    let mut device = ""
    let mut is_abs = false
    if len == 0 {
      continue
    }
    let code = cu(path, 0)
    if len == 1 {
      if wsep(code) {
        root_end = 1
        is_abs = true
      }
    } else if wsep(code) {
      is_abs = true
      if wsep(cu(path, 1)) {
        match unc_root(path) {
          Some((d, e, _)) => {
            device = d
            root_end = e
          }
          None => ()
        }
      } else {
        root_end = 1
      }
    } else if device_root(code) && cu(path, 1) == 58 {
      device = sub(path, 0, 2)
      root_end = 2
      if len > 2 && wsep(cu(path, 2)) {
        is_abs = true
        root_end = 3
      }
    }
    if device.length() > 0 {
      if resolved_device.length() > 0 {
        if lower(device) != lower(resolved_device) {
          continue
        }
      } else {
        resolved_device = device
      }
    }
    if resolved_absolute {
      if resolved_device.length() > 0 {
        break
      }
    } else {
      resolved_tail = sub(path, root_end, len) + "\\" + resolved_tail
      resolved_absolute = is_abs
      if is_abs && resolved_device.length() > 0 {
        break
      }
    }
  }
  resolved_tail = normalize_string(resolved_tail, !resolved_absolute, "\\", wsep)
  if resolved_absolute {
    resolved_device + "\\" + resolved_tail
  } else {
    let s = resolved_device + resolved_tail
    if s == "" {
      "."
    } else {
      s
    }
  }
}

///|
/// path.win32.normalize.
pub fn win32_normalize(path : String) -> String {
  let len = path.length()
  if len == 0 {
    return "."
  }
  let mut root_end = 0
  let mut device : String? = None
  let mut is_abs = false
  let code = cu(path, 0)
  if len == 1 {
    return if code == 47 { "\\" } else { path }
  }
  if wsep(code) {
    is_abs = true
    if wsep(cu(path, 1)) {
      match unc_root(path) {
        Some((d, e, whole)) =>
          if whole {
            return d + "\\"
          } else {
            device = Some(d)
            root_end = e
          }
        None => ()
      }
    } else {
      root_end = 1
    }
  } else if device_root(code) && cu(path, 1) == 58 {
    device = Some(sub(path, 0, 2))
    root_end = 2
    if len > 2 && wsep(cu(path, 2)) {
      is_abs = true
      root_end = 3
    }
  }
  let mut tail = if root_end < len {
    normalize_string(sub(path, root_end, len), !is_abs, "\\", wsep)
  } else {
    ""
  }
  if tail.length() == 0 && !is_abs {
    tail = "."
  }
  if tail.length() > 0 && wsep(cu(path, len - 1)) {
    tail = tail + "\\"
  }
  if !is_abs && device is None && has(path, ":") {
    if tail.length() >= 2 && device_root(cu(tail, 0)) && cu(tail, 1) == 58 {
      return ".\\" + tail
    }
    let mut index = index_of(path, ":")
    while index != -1 {
      if index == len - 1 || wsep(cu(path, index + 1)) {
        return ".\\" + tail
      }
      index = index_of(path, ":", from=index + 1)
    }
  }
  match device {
    None => if is_abs { "\\" + tail } else { tail }
    Some(d) => if is_abs { d + "\\" + tail } else { d + tail }
  }
}

///|
/// path.win32.join.
pub fn win32_join(args : Array[String]) -> String {
  let mut joined : String? = None
  let mut first = ""
  for arg in args {
    if arg.length() > 0 {
      match joined {
        None => {
          joined = Some(arg)
          first = arg
        }
        Some(j) => joined = Some(j + "\\" + arg)
      }
    }
  }
  guard joined is Some(j) else { return "." }
  let mut joined = j
  let mut needs_replace = true
  let mut slash_count = 0
  if wsep(cu(first, 0)) {
    slash_count += 1
    let first_len = first.length()
    if first_len > 1 && wsep(cu(first, 1)) {
      slash_count += 1
      if first_len > 2 {
        if wsep(cu(first, 2)) {
          slash_count += 1
        } else {
          needs_replace = false
        }
      }
    }
  }
  if needs_replace {
    while slash_count < joined.length() && wsep(cu(joined, slash_count)) {
      slash_count += 1
    }
    if slash_count >= 2 {
      joined = "\\" + sub(joined, slash_count, joined.length())
    }
  }
  win32_normalize(joined)
}

///|
/// path.win32.dirname.
pub fn win32_dirname(path : String) -> String {
  let len = path.length()
  if len == 0 {
    return "."
  }
  let mut root_end = -1
  let mut offset = 0
  let code = cu(path, 0)
  if len == 1 {
    return if wsep(code) { path } else { "." }
  }
  if wsep(code) {
    root_end = 1
    offset = 1
    if wsep(cu(path, 1)) {
      let mut j = 2
      let mut last = j
      while j < len && !wsep(cu(path, j)) {
        j += 1
      }
      if j < len && j != last {
        last = j
        while j < len && wsep(cu(path, j)) {
          j += 1
        }
        if j < len && j != last {
          last = j
          while j < len && !wsep(cu(path, j)) {
            j += 1
          }
          if j == len {
            return path
          }
          if j != last {
            root_end = j + 1
            offset = j + 1
          }
        }
      }
    }
  } else if device_root(code) && cu(path, 1) == 58 {
    root_end = if len > 2 && wsep(cu(path, 2)) { 3 } else { 2 }
    offset = root_end
  }
  let mut end = -1
  let mut matched_slash = true
  let mut i = len - 1
  while i >= offset {
    if wsep(cu(path, i)) {
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
    if root_end == -1 {
      return "."
    }
    end = root_end
  }
  sub(path, 0, end)
}

///|
/// path.win32.relative.
pub fn win32_relative(from : String, to : String, cwd : String) -> String {
  if from == to {
    return ""
  }
  let from_orig = win32_resolve([from], cwd)
  let to_orig = win32_resolve([to], cwd)
  if from_orig == to_orig {
    return ""
  }
  let from = lower(from_orig)
  let to = lower(to_orig)
  if from == to {
    return ""
  }
  if from_orig.length() != from.length() || to_orig.length() != to.length() {
    let from_split = split_on(from_orig, "\\")
    let to_split = split_on(to_orig, "\\")
    if from_split[from_split.length() - 1] == "" {
      from_split.pop() |> ignore
    }
    if to_split[to_split.length() - 1] == "" {
      to_split.pop() |> ignore
    }
    let from_len = from_split.length()
    let to_len = to_split.length()
    let length = @cmp.minimum(from_len, to_len)
    let mut i = 0
    while i < length {
      if lower(from_split[i]) != lower(to_split[i]) {
        break
      }
      i += 1
    }
    if i == 0 {
      return to_orig
    } else if i == length {
      if to_len > length {
        return to_split[i:].to_owned().join("\\")
      }
      if from_len > length {
        return "..\\".repeat(from_len - 1 - i) + ".."
      }
      return ""
    }
    return "..\\".repeat(from_len - i) + to_split[i:].to_owned().join("\\")
  }
  let mut from_start = 0
  while from_start < from.length() && cu(from, from_start) == 92 {
    from_start += 1
  }
  let mut from_end = from.length()
  while from_end - 1 > from_start && cu(from, from_end - 1) == 92 {
    from_end -= 1
  }
  let from_len = from_end - from_start
  let mut to_start = 0
  while to_start < to.length() && cu(to, to_start) == 92 {
    to_start += 1
  }
  let mut to_end = to.length()
  while to_end - 1 > to_start && cu(to, to_end - 1) == 92 {
    to_end -= 1
  }
  let to_len = to_end - to_start
  let length = @cmp.minimum(from_len, to_len)
  let mut last_common_sep = -1
  let mut i = 0
  while i < length {
    let from_code = cu(from, from_start + i)
    if from_code != cu(to, to_start + i) {
      break
    } else if from_code == 92 {
      last_common_sep = i
    }
    i += 1
  }
  if i != length {
    if last_common_sep == -1 {
      return to_orig
    }
  } else {
    if to_len > length {
      if cu(to, to_start + i) == 92 {
        return sub(to_orig, to_start + i + 1, to_orig.length())
      }
      if i == 2 {
        return sub(to_orig, to_start + i, to_orig.length())
      }
    }
    if from_len > length {
      if cu(from, from_start + i) == 92 {
        last_common_sep = i
      } else if i == 2 {
        last_common_sep = 3
      }
    }
    if last_common_sep == -1 {
      last_common_sep = 0
    }
  }
  let mut out = ""
  let mut k = from_start + last_common_sep + 1
  while k <= from_end {
    if k == from_end || cu(from, k) == 92 {
      out = out + (if out.length() == 0 { ".." } else { "\\.." })
    }
    k += 1
  }
  to_start += last_common_sep
  if out.length() > 0 {
    return out + sub(to_orig, to_start, to_end)
  }
  if to_start < to_orig.length() && cu(to_orig, to_start) == 92 {
    to_start += 1
  }
  sub(to_orig, to_start, to_end)
}

// ── POSIX ────────────────────────────────────────────────────────────────────────────────────────────────────────

///|
fn psep(c : Int) -> Bool {
  c == 47
}

///|
/// path.posix.join.
pub fn posix_join(args : Array[String]) -> String {
  let parts = args.filter(a => a != "")
  if parts.is_empty() {
    return "."
  }
  posix_normalize(parts.join("/"))
}

///|
/// path.posix.normalize.
pub fn posix_normalize(path : String) -> String {
  if path == "" {
    return "."
  }
  let is_abs = cu(path, 0) == 47
  let trailing = cu(path, path.length() - 1) == 47
  let mut p = normalize_string(path, !is_abs, "/", psep)
  if p == "" {
    if is_abs {
      return "/"
    }
    return if trailing { "./" } else { "." }
  }
  if trailing {
    p = p + "/"
  }
  if is_abs {
    "/" + p
  } else {
    p
  }
}

///|
/// path.posix.resolve, relative to `cwd`.
pub fn posix_resolve(paths : Array[String], cwd : String) -> String {
  let mut resolved = ""
  let mut absolute = false
  let mut i = paths.length() - 1
  while i >= -1 && !absolute {
    let path = if i >= 0 { paths[i] } else { cwd }
    i -= 1
    if path == "" {
      continue
    }
    resolved = path + "/" + resolved
    absolute = cu(path, 0) == 47
  }
  let r = normalize_string(resolved, !absolute, "/", psep)
  if absolute {
    "/" + r
  } else if r == "" {
    "."
  } else {
    r
  }
}

///|
/// path.posix.basename.
pub fn posix_basename(path : String) -> String {
  @nodepath.basename("/", path)
}

///|
/// path.posix.dirname.
pub fn posix_dirname(path : String) -> String {
  @nodepath.dirname("/", path)
}
