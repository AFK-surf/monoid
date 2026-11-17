// The file system as these parts ask it of the shell (client/shell's `fs.*`, answered at once): what is at a path,
// a directory's names, a file's text, writes and removals. What none of its calls says (a file's blocks, a file
// system's room, a watch) is what Node gives the program where it needs it.

///|
/// The shell's file system, as these parts use it.
pub struct Fs {
  host : @host.Host
}

///|
pub fn Fs::new(host : @host.Host) -> Fs {
  { host, }
}

///|
fn Fs::call(self : Fs, op : String, args : Json) -> Json raise {
  self.host.shell_sync(op, args)
}

///|
/// What lstat says (links not followed), None where nothing is there.
pub(all) struct Lstat {
  kind : String
  size : Double
  mode : Double
  ino : Double
  mtime_ms : Double
}

///|
pub fn Fs::lstat(self : Fs, path : String) -> Lstat? raise {
  match self.call("fs.lstat", { "path": js(path) }) {
    Object(_) as j =>
      Some({
        kind: str_or(j, "kind", "other"),
        size: num_field(j, "size").unwrap_or(0.0),
        mode: num_field(j, "mode").unwrap_or(0.0),
        ino: num_field(j, "ino").unwrap_or(0.0),
        mtime_ms: num_field(j, "mtimeMs").unwrap_or(0.0),
      })
    _ => None
  }
}

///|
/// A path's kind, links followed (`file`, `dir`, `other`); None where it cannot be stated.
pub fn Fs::kind(self : Fs, path : String) -> String? raise {
  match self.call("fs.stat", { "path": js(path) }) {
    String(k) => Some(k)
    _ => None
  }
}

///|
/// A path's device (`fs.scan`: lstat, or stat where `follow`), None where nothing is there.
pub fn Fs::dev(self : Fs, path : String, follow? : Bool = false) -> Double? raise {
  match self.call("fs.scan", { "paths": [js(path)], "follow": jb(follow) }) {
    Array([Object(_) as j, ..]) => num_field(j, "dev")
    _ => None
  }
}

///|
/// A directory's names with their kinds (`file`, `dir`, `link`, `other`), in Node's readdir order; None where it does
/// not list.
pub fn Fs::readdir(self : Fs, path : String) -> Array[(String, String)]? raise {
  match self.call("fs.readdir", { "path": js(path), "types": true }) {
    Array(a) =>
      Some(
        a.filter_map(e => match e {
          Array([String(n), String(k)]) => Some((n, k))
          _ => None
        }),
      )
    _ => None
  }
}

///|
/// A directory's names, None where it does not list.
pub fn Fs::names(self : Fs, path : String) -> Array[String]? raise {
  self.readdir(path).map(a => a.map(p => p.0))
}

///|
/// A file's text (as readFileSync's utf8), None where it does not read.
pub fn Fs::read(self : Fs, path : String) -> String? raise {
  match self.call("fs.read", { "path": js(path) }) {
    String(s) => Some(s)
    _ => None
  }
}

///|
/// A file's size and mtime (links followed), None where nothing is there.
pub fn Fs::meta(self : Fs, path : String) -> (Double, Double, Bool)? raise {
  match self.call("fs.meta", { "path": js(path) }) {
    Object(_) as j =>
      Some((num_field(j, "size").unwrap_or(0.0), num_field(j, "mtime").unwrap_or(0.0), bool_field(j, "dir")))
    _ => None
  }
}

///|
/// A file's size and mtime in whole ms (as `mtimeNs / 1_000_000n`; None before 1970), whether a folder; None where
/// nothing is there.
pub fn Fs::meta_ms(self : Fs, path : String) -> (Double, Double?, Bool)? raise {
  match self.call("fs.meta", { "path": js(path) }) {
    Object(_) as j => Some((num_field(j, "size").unwrap_or(0.0), num_field(j, "mtimeMs"), bool_field(j, "dir")))
    _ => None
  }
}

///|
/// What a link names, None where it is no link.
pub fn Fs::readlink(self : Fs, path : String) -> String? raise {
  match self.call("fs.readlink", { "path": js(path) }) {
    String(s) => Some(s)
    _ => None
  }
}

///|
/// A path with its links followed, as realpath has it; None where a part is not there.
pub fn Fs::realpath(self : Fs, path : String) -> String? raise {
  match self.call("fs.realpath", { "path": js(path) }) {
    String(s) => Some(s)
    _ => None
  }
}

///|
/// `text` written whole at `path` (beside and renamed into place, its folders made).
pub fn Fs::write(self : Fs, path : String, text : String) -> Unit raise {
  ignore(self.call("fs.write", { "path": js(path), "text": js(text) }))
}

///|
pub fn Fs::rename(self : Fs, from : String, to : String) -> Unit raise {
  ignore(self.call("fs.rename", { "from": js(from), "to": js(to) }))
}

///|
/// What is at `path` let go (with all it holds where `recursive`); nothing there is no failure.
pub fn Fs::remove(self : Fs, path : String, recursive? : Bool = false) -> Unit raise {
  ignore(self.call("fs.remove", { "path": js(path), "recursive": jb(recursive) }))
}

///|
pub fn Fs::mkdir(self : Fs, path : String) -> Unit raise {
  ignore(self.call("fs.mkdir", { "path": js(path) }))
}

///|
pub fn Fs::chmod(self : Fs, path : String, mode : Int) -> Unit raise {
  ignore(self.call("fs.chmod", { "path": js(path), "mode": ji(mode) }))
}

///|
/// A program run to its end (`proc.run`): its stdout where it ended well, None otherwise.
pub fn Fs::run(self : Fs, command : String, args : Array[String], timeout_ms? : Int = 5000) -> String? raise {
  match self.call("proc.run", { "command": js(command), "args": jstrs(args), "timeoutMs": ji(timeout_ms) }) {
    String(s) => Some(s)
    _ => None
  }
}
