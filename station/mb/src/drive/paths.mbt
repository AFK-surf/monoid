// The machine's paths as the station's platform has them (platform.paths, node:path, os.homedir, os.tmpdir,
// platform.disks): POSIX's, or Windows' (`\` and `/`, drives and shares, case aside, resolved from the working folder).
// Which is the machine's, unless a test says otherwise (`path_mode`, to hold Windows' on any machine).

///|
/// Whose paths: POSIX's, or Windows' with the folder a path with no drive is resolved from.
pub(all) enum PathMode {
  Posix
  Win(String)
} derive(Show, Eq)

///|
extern "C" fn cwd_ffi() -> Bytes = "sfd_cwd"

///|
/// process.cwd().
pub fn cwd() -> String {
  @utf8.decode_lossy(cwd_ffi())
}

///|
/// The paths the drive goes by: the machine's.
pub let path_mode : Ref[PathMode] = {
  val: if is_windows() {
    Win(cwd())
  } else {
    Posix
  },
}

///|
/// `f` with the paths of `mode` (a test's), the machine's again after.
pub fn[T] with_paths(mode : PathMode, f : () -> T raise) -> T raise {
  let was = path_mode.val
  path_mode.val = mode
  defer {
    path_mode.val = was
  }
  f()
}

///|
fn win_mode() -> String? {
  match path_mode.val {
    Win(c) => Some(c)
    Posix => None
  }
}

///|
/// node:path's separator.
pub fn sep() -> String {
  if win_mode() is Some(_) {
    "\\"
  } else {
    "/"
  }
}

///|
/// node:path's join.
pub fn join(parts : Array[String]) -> String {
  @nodepath.join(sep(), parts)
}

///|
/// node:path's dirname.
pub fn dirname(path : String) -> String {
  @nodepath.dirname(sep(), path)
}

///|
/// node:path's basename.
pub fn basename(path : String) -> String {
  @nodepath.basename(sep(), path)
}

///|
/// platform.paths.key: what a path is compared by (Windows' case aside).
pub fn path_key(path : String) -> String {
  if win_mode() is Some(_) {
    path.to_lower()
  } else {
    path
  }
}

///|
/// platform.paths.within.
pub fn within(path : String, dir : String) -> Bool {
  if win_mode() is Some(_) {
    @ops_platform.win_within(path, dir)
  } else {
    dir == "/" || path == dir || path.has_prefix(dir + "/")
  }
}

///|
/// platform.paths.rooted.
pub fn rooted(path : String) -> Bool {
  if win_mode() is Some(_) {
    @ops_platform.win_rooted(path)
  } else {
    path.has_prefix("/")
  }
}

///|
/// platform.paths.clean.
pub fn clean(path : String) -> String {
  if win_mode() is Some(c) {
    return @ops_platform.win_clean(path, c)
  }
  let out : Array[String] = []
  for part in path.split("/") {
    let part = part.to_string()
    if part == "" || part == "." {
      continue
    }
    if part == ".." {
      out.pop() |> ignore
    } else {
      out.push(part)
    }
  }
  "/" + out.join("/")
}

///|
/// platform.paths.relativeIn.
pub fn relative_in(root : String, path : String) -> String? {
  if win_mode() is Some(c) {
    return @ops_platform.win_relative_in(root, path, c)
  }
  if path == root {
    return Some("")
  }
  let prefix = if root.has_suffix("/") { root } else { root + "/" }
  if path.has_prefix(prefix) {
    Some(path.unsafe_substring(start=prefix.length(), end=path.length()))
  } else {
    None
  }
}

///|
fn is_sep_char(c : Int) -> Bool {
  c == '/' || (win_mode() is Some(_) && c == '\\')
}

///|
/// node:path's parse(path).root: `/` on POSIX; on Windows a drive (`E:\`, `E:`), a share (`\\server\share\`) or a
/// leading separator.
pub fn root_of(path : String) -> String {
  let n = path.length()
  if win_mode() is None {
    return if n > 0 && path.unsafe_charcode_at(0) == '/' { "/" } else { "" }
  }
  if n >= 2 && path.unsafe_charcode_at(1) == ':' {
    let end = if n > 2 && is_sep_char(path.unsafe_charcode_at(2)) { 3 } else { 2 }
    return path.unsafe_substring(start=0, end~)
  }
  if n == 0 || !is_sep_char(path.unsafe_charcode_at(0)) {
    return ""
  }
  if n >= 2 && is_sep_char(path.unsafe_charcode_at(1)) {
    let mut i = 2
    let mut names = 0
    while i < n && names < 2 {
      let start = i
      while i < n && !is_sep_char(path.unsafe_charcode_at(i)) {
        i += 1
      }
      if i == start {
        return path.unsafe_substring(start=0, end=1)
      }
      names += 1
      if names < 2 {
        if i == n {
          return path.unsafe_substring(start=0, end=1)
        }
        i += 1
      }
    }
    if names == 2 {
      return path.unsafe_substring(start=0, end=if i < n { i + 1 } else { i })
    }
  }
  path.unsafe_substring(start=0, end=1)
}

///|
/// A path's parts, split at `/` and `\` (drive.ts `crumbs`), none empty.
pub fn split_parts(path : String) -> Array[String] {
  let out = []
  let mut start = 0
  for i = 0; i <= path.length(); i = i + 1 {
    if i == path.length() ||
      path.unsafe_charcode_at(i) == '/' ||
      path.unsafe_charcode_at(i) == '\\' {
      if i > start {
        out.push(path.unsafe_substring(start~, end=i))
      }
      start = i + 1
    }
  }
  out
}

///|
/// os.homedir(): on Windows USERPROFILE (else HOME, else `C:\`), elsewhere HOME.
pub fn homedir() -> String {
  if win_mode() is Some(_) {
    return match env("USERPROFILE") {
      Some(v) if v != "" => v
      _ =>
        match env("HOME") {
          Some(v) if v != "" => v
          _ => "C:\\"
        }
    }
  }
  env("HOME").unwrap_or("/")
}

///|
fn first_env(names : Array[String]) -> String? {
  for n in names {
    match env(n) {
      Some(v) if v != "" => return Some(v)
      _ => ()
    }
  }
  None
}

///|
/// os.tmpdir(): POSIX's TMPDIR, TMP or TEMP (else /tmp), its last `/` taken off; Windows' TEMP or TMP (else the
/// system's own temp), its last `\` taken off but a drive's root's.
pub fn tmpdir() -> String {
  if win_mode() is Some(_) {
    let given = match first_env(["TEMP", "TMP"]) {
      Some(v) => v
      None => first_env(["SystemRoot", "windir"]).unwrap_or("") + "\\temp"
    }
    return if given.length() > 1 &&
      (given.has_suffix("\\") || given.has_suffix("/")) &&
      !given.has_suffix(":\\") &&
      !given.has_suffix(":/") {
      given.unsafe_substring(start=0, end=given.length() - 1)
    } else {
      given
    }
  }
  let given = first_env(["TMPDIR", "TMP", "TEMP"]).unwrap_or("/tmp")
  if given.length() > 1 && given.has_suffix("/") {
    given.unsafe_substring(start=0, end=given.length() - 1)
  } else {
    given
  }
}

///|
/// platform.disks: Windows' drives there (`C:` to `Z:`); elsewhere what is in /Volumes, /media/<user> and /mnt, each
/// by name, but hidden ones.
pub fn disks(home : String) -> Array[(String, String)] {
  let found = []
  if win_mode() is Some(_) {
    for l in "CDEFGHIJKLMNOPQRSTUVWXYZ" {
      let path = "\{l}:\\"
      match attempt(() => stat(path)) {
        Ok(s) if s.dir => found.push(("\{l}:", path))
        _ => ()
      }
    }
    return found
  }
  for mounts in ["/Volumes", join(["/media", basename(home)]), "/mnt"] {
    let listed = match attempt(() => names(mounts)) {
      Ok(n) => n
      Err(_) => []
    }
    for name in stable_sort(listed, collate) {
      if !name.has_prefix(".") {
        found.push((name, join([mounts, name])))
      }
    }
  }
  found
}
