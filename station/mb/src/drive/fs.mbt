// How the drive (drive.mbt) reaches the machine's files (fs.ts): directly, or, for the folders macOS keeps from a
// station launchd runs, through still.fail Helper, which holds the grants. The same few operations either way, on paths
// the drive has already checked (the helper checks them again against the roots it is told).

///|
/// A folder's entry (fs.ts `Listed`): whether it is a link, where it leads (links followed; itself when not a link),
/// and what is there (None: a link to nothing, one gone meanwhile, one leading where it may not).
pub(all) struct Listed {
  name : String
  link : Bool
  real : String
  stat : Stat?
} derive(Show)

///|
/// fs.ts `Fs`: the operations, directly or through still.fail Helper (`helper`).
pub(all) struct Fs {
  helper : Bool
  /// A folder's entries, at most `most` of them stated (the flag: there were more).
  list : (String, Int) -> (Array[Listed], Bool) raise
  names : (String) -> Array[String] raise
  stat : (String) -> Stat raise
  lstat : (String) -> Stat raise
  /// Links followed, as far as the path exists.
  real : (String) -> String raise
  /// `length` bytes from `offset`, with the file's size and mtimeMs; EISDIR for a folder.
  read : (String, Double, Double) -> (Bytes, Double, Double) raise
  read_all : (String) -> Bytes raise
  /// The file copied to `to`, a new file of the station's own.
  copy_to : (String, String) -> Unit raise
  write : (String, Write) -> Written raise
  rename : (String, String) -> Unit raise
  mkdir : (String, Bool) -> Unit raise
  /// A folder with all it holds; anything else (a link too) itself.
  remove : (String) -> Unit raise
  /// Put in the machine's trash: where it is there now, None where no trash takes it. (path, now, home)
  trash : (String, Double, String?) -> String? raise
  unlink : (String) -> Unit raise
}

///|
/// fs.ts `realOf`: links followed, as far as the path exists.
pub fn real_of(path : String) -> String {
  realpath(path) catch {
    _ => {
      let parent = dirname(path)
      if parent == path {
        path
      } else {
        join([real_of(parent), basename(path)])
      }
    }
  }
}

///|
/// Entries stated at once while listing (fs.ts AT_ONCE): the order is the listing's either way.
let at_once : Int = 64

///|
/// The machine's trash (platform's `trash`): Finder's on macOS, the freedesktop's elsewhere, none on Windows.
pub fn trash_kind() -> String? {
  if is_windows() {
    None
  } else if is_mac() {
    Some("finder")
  } else {
    Some("freedesktop")
  }
}

///|
fn stat_or_none(path : String) -> Stat? {
  Some(stat(path)) catch {
    _ => None
  }
}

///|
/// fs.ts `direct`: the station's own calls.
pub fn direct() -> Fs {
  {
    helper: false,
    list: fn(dir, most) {
      // The first by the order shown (folders first, then by name) when there are more than are listed.
      let dirents = stable_sort(readdir(dir), (a, b) => if a.is_dir != b.is_dir {
        if a.is_dir {
          -1
        } else {
          1
        }
      } else {
        collate(a.name, b.name)
      })
      let shown = if dirents.length() > most {
        dirents[0:most].to_array()
      } else {
        dirents
      }
      ignore(at_once)
      let entries = shown.map(d => {
        let path = join([dir, d.name])
        let real = if d.is_link { real_of(path) } else { path }
        { name: d.name, link: d.is_link, real, stat: stat_or_none(real) }
      })
      (entries, dirents.length() > shown.length())
    },
    names: path => names(path),
    stat: path => stat(path),
    lstat: path => lstat(path),
    real: path => real_of(path),
    read: (path, offset, length) => read_part(path, offset, length),
    read_all: path => read_all(path),
    copy_to: (path, to) => copy_file(path, to),
    write: (path, w) => write_part(path, w),
    rename: (from, to) => rename(from, to),
    mkdir: (path, recursive) => mkdir(path, recursive),
    remove: fn(path) {
      lstat(path) |> ignore
      rm(path)
    },
    trash: (path, now, home) => to_trash(path, trash_kind(), now, home),
    unlink: path => unlink(path),
  }
}

///|
fn lower(s : String) -> String {
  s.to_lower()
}

///|
/// Where a protected folder is (fs.ts `Where`): its top, and whether still.fail Helper opens it.
pub(all) struct Where {
  top : String
  helper : Bool
} derive(Show, Eq)

///|
priv enum Named {
  At(Where)
  Volume(String)
}

///|
/// fs.ts `byName`.
fn by_name(path : String, home : String, mounts : Array[String]) -> Named? {
  let low = lower(path)
  let under = (top : String) => {
    let t = lower(top)
    low == t || low.has_prefix(t + "/")
  }
  for name in ["Documents", "Desktop", "Downloads"] {
    let top = join([home, name])
    if under(top) {
      return Some(At({ top, helper: true }))
    }
  }
  for name in ["Library/Mobile Documents", "Library/CloudStorage"] {
    let top = join([home, name])
    if under(top) {
      return Some(At({ top, helper: false }))
    }
  }
  let mut mount : String? = None
  for m in mounts {
    let longer = match mount {
      None => m.length() > 0
      Some(x) => m.length() > x.length()
    }
    if !low.has_prefix("/volumes/") && under(m) && longer {
      mount = Some(m)
    }
  }
  if mount is Some(m) {
    return Some(At({ top: m, helper: true }))
  }
  if !low.has_prefix("/volumes/") {
    return None
  }
  let rest = low.unsafe_substring(start=9, end=low.length())
  let first = match rest.find("/") {
    Some(i) => rest.unsafe_substring(start=0, end=i)
    None => rest
  }
  if first == "" {
    return None
  }
  let parts = path.split("/").map(v => v.to_string()).to_array()
  Some(Volume("/Volumes/\{if parts.length() > 2 { parts[2] } else { "" }}"))
}

///|
/// What each place in /Volumes was when last looked at, and when (fs.ts `volumes`).
let volumes : Map[String, (Double, String)] = {}

///|
/// fs.ts VOLUME_FRESH_MS.
let volume_fresh_ms : Double = 2000.0

///|
/// The machine's clock for what is shared with other programs (ops/fibers.ts `wall`).
pub let wall_now : Ref[() -> Double] = { val: () => wall_clock() }

///|
fn look_volume(top : String) -> String {
  let found = match attempt(() => lstat(top)) {
    Ok(s) => if s.link { "link" } else { "disk" }
    Err(_) => "none"
  }
  volumes.remove(top)
  volumes.set(top, ((wall_now.val)(), found))
  if volumes.length() > 256 {
    let first : String = volumes.keys().collect()[0]
    volumes.remove(first)
  }
  found
}

///|
fn volume_at(top : String, found : String) -> Where? {
  if found == "disk" {
    Some({ top, helper: true })
  } else {
    None
  }
}

///|
/// fs.ts `volumeKept`.
fn volume_kept(top : String) -> Where? {
  let kept = volumes.get(top)
  let fresh = match kept {
    Some((at, _)) => (wall_now.val)() - at <= volume_fresh_ms
    None => false
  }
  if !fresh {
    look_volume(top) |> ignore
  }
  match kept {
    Some((_, "link")) => None
    Some((_, "none")) if fresh => None
    _ => Some({ top, helper: true })
  }
}

///|
/// fs.ts `protectedPlace`.
pub fn protected_place(
  path : String,
  home : String,
  mounts : Array[String],
) -> Where? {
  match by_name(path, home, mounts) {
    Some(Volume(v)) => volume_kept(v)
    Some(At(w)) => Some(w)
    None => None
  }
}

///|
/// fs.ts `protectedTop`.
pub fn protected_top(
  path : String,
  home : String,
  mounts : Array[String],
) -> String? {
  match protected_place(path, home, mounts) {
    Some({ helper: true, top }) => Some(top)
    _ => None
  }
}

///|
/// fs.ts `protectedPlaceSoon`: what is in /Volumes looked at first.
pub fn protected_place_soon(
  path : String,
  home : String,
  mounts : Array[String],
) -> Where? {
  match by_name(path, home, mounts) {
    Some(Volume(v)) => volume_at(v, look_volume(v))
    Some(At(w)) => Some(w)
    None => None
  }
}

///|
/// fs.ts `protectedTopSoon`.
pub fn protected_top_soon(
  path : String,
  home : String,
  mounts : Array[String],
) -> String? {
  match protected_place_soon(path, home, mounts) {
    Some({ helper: true, top }) => Some(top)
    _ => None
  }
}

///|
/// fs.ts `Protected`: the drive's way to still.fail Helper's side.
pub(all) struct Protected {
  /// The helper's operations, for a request that may reach `roots` and none of `protect`.
  fs : (Array[String], Array[String]) -> Fs
  /// What is known of a protected folder (its top): its grant and state (granted, denied, unknown); None before known.
  known : (String) -> (String, String)?
  /// Looked at in the background.
  check : (Array[String]) -> Unit
  /// The helper's window asking for `grant` on this Mac: up, closed or none.
  ask : (String, String) -> String
}
