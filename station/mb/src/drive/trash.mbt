// What the drive deletes goes where the machine's own file browser puts it (trash.ts): Finder's ~/.Trash, the
// freedesktop trash a Linux desktop empties, so a delete is undone there as one made on the machine is. A file on
// another disk goes to that disk's own trash (`.Trashes/<uid>` on macOS, `.Trash-<uid>` on Linux): it is moved, never
// copied. Where there is none to move it to (Windows, a disk that will not take one), the caller is told (None).

///|
/// trash.ts `toTrash`: moved to the trash `kind`, where it is there now; None where no trash takes it. `home`: whose
/// trash (the machine's own, its XDG data folder followed, when none is given); `now`: when, for the freedesktop's note.
pub fn to_trash(
  entry : String,
  kind : String?,
  now : Double,
  home : String?,
) -> String? raise {
  guard kind is Some(kind) else { return None }
  let uid = uid()
  let dev = stat(dirname(entry)).dev
  let xdg = match home {
    None =>
      match env("XDG_DATA_HOME") {
        Some(v) if v != "" => Some(v)
        _ => None
      }
    Some(_) => None
  }
  let home = home.unwrap_or(homedir())
  let data = xdg.unwrap_or(join([home, ".local", "share"]))
  let home_trash = if kind == "finder" {
    join([home, ".Trash"])
  } else {
    join([data, "Trash"])
  }
  let on_home_disk = match attempt(() => stat(home)) {
    Ok(s) => s.dev == dev
    Err(_) => false
  }
  let trash = if on_home_disk {
    home_trash
  } else {
    join([
      top_of(dirname(entry), dev),
      if kind == "finder" {
        join([".Trashes", uid.to_string()])
      } else {
        ".Trash-\{uid}"
      },
    ])
  }
  try {
    Some(
      if kind == "finder" {
        into_mac(entry, trash)
      } else {
        into_freedesktop(entry, trash, now)
      },
    )
  } catch {
    FsError({ code: "EXDEV" | "EACCES" | "EPERM" | "EROFS", .. }) => None
    e => raise e
  }
}

///|
/// The top of the disk `dir` is on: the last folder up from it on the same device.
fn top_of(dir : String, dev : Double) -> String {
  let mut at = dir
  while true {
    let up = dirname(at)
    if up == at {
      return at
    }
    match attempt(() => stat(up)) {
      Ok(s) if s.dev == dev => at = up
      _ => return at
    }
  }
  at
}

///|
/// Finder's: the trash folder itself, a name taken given ` 2`, ` 3`…
fn into_mac(entry : String, trash : String) -> String raise {
  mkdir(trash, true, mode=0o700)
  let name = basename(entry)
  let mut n = 1
  while true {
    let to = join([trash, if n == 1 { name } else { with_number(name, n) }])
    if !exists(to) {
      rename(entry, to)
      return to
    }
    n += 1
  }
  ""
}

///|
/// The freedesktop trash: `files/` beside `info/`, where a `.trashinfo` (made first, which claims the name) says where
/// it was and when.
fn into_freedesktop(entry : String, trash : String, now : Double) -> String raise {
  let files = join([trash, "files"])
  let info = join([trash, "info"])
  mkdir(files, true, mode=0o700)
  mkdir(info, true, mode=0o700)
  let name = basename(entry)
  let mut n = 1
  while true {
    let as_ = if n == 1 { name } else { with_number(name, n) }
    n += 1
    let (y, mo, d, h, mi, s) = local_time(now)
    let pad = (v : Int) => if v < 10 { "0\{v}" } else { v.to_string() }
    let date = "\{y}-\{pad(mo + 1)}-\{pad(d)}T\{pad(h)}:\{pad(mi)}:\{pad(s)}"
    let claimed = try {
      create_excl(
        join([info, "\{as_}.trashinfo"]),
        "[Trash Info]\nPath=\{encode_uri(entry)}\nDeletionDate=\{date}\n",
      )
      true
    } catch {
      FsError({ code: "EEXIST", .. }) => false
      e => raise e
    }
    if !claimed {
      continue
    }
    let to = join([files, as_])
    if exists(to) {
      continue
    }
    rename(entry, to)
    return to
  }
  ""
}

///|
/// `name` with a number before its extension (`report 2.pdf`; a folder or a name without one: at its end).
fn with_number(name : String, n : Int) -> String {
  match name.rev_find(".") {
    Some(dot) if dot > 0 =>
      "\{name.unsafe_substring(start=0, end=dot)} \{n}\{name.unsafe_substring(start=dot, end=name.length())}"
    _ => "\{name} \{n}"
  }
}

///|
/// trash.ts `exists`: anything there, or what is there cannot be told (any failure but ENOENT).
fn exists(path : String) -> Bool {
  match attempt(() => stat(path)) {
    Ok(_) => true
    Err(FsError({ code: "ENOENT", .. })) => false
    Err(_) => true
  }
}

///|
/// encodeURI: what is not a letter, a digit or one of `;,/?:@&=+$-_.!~*'()#` as %XX of its UTF-8.
pub fn encode_uri(s : String) -> String {
  @url.encode_uri(s)
}
