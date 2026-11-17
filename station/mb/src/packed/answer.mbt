// What the station asks of the program that puts transcripts and workspaces away (`--builder packed`,
// station/src/sessions/packed-mb.ts for sessions/archive.ts): a line of JSON an ask, `{id, op, …}`, answered `{id, …}`
// (or `{id, error}`), one at a time, nothing kept between them. The station holds the transcript's or the room's lock
// and renames what this made into place: this only makes the temporary (or the tree) it is given and says whether it
// reads back as it must. A workspace's tar is written and read by the shell (client/shell `tar.pack`, `tar.unpack`,
// `tar.file`), a block at a time: none of its bytes come through here.

///|
/// What failed, said to the station as its error.
pub suberror Failed {
  Failed(String)
}

///|
/// Its words as they are where it is said (`to_string`), not its type's name.
pub impl Show for Failed with output(self, logger) {
  match self {
    Failed(m) => logger.write_string(m)
  }
}

///|
fn field(j : Json, key : String) -> Json? {
  if j is Object(o) {
    o.get(key)
  } else {
    None
  }
}

///|
fn str_of(ask : Json, key : String) -> String raise Failed {
  match field(ask, key) {
    Some(String(s)) => s
    _ => raise Failed("no \{key}")
  }
}

///|
/// An answer that says nothing but that it is done.
fn done() -> Json {
  Json::object(Map([]))
}

///|
fn num(v : Int64) -> Json {
  Json::number(v.to_double())
}

///|
/// The shell's answer to `op` (its JSON).
async fn shell(host : @host.Host, op : String, args : Map[String, Json], bytes? : Bytes) -> Json {
  let (json, _) = match bytes {
    Some(b) => host.shell(op, Json::object(args), bytes=b)
    None => host.shell(op, Json::object(args))
  }
  json
}

///|
/// `length` bytes of the file at `path` from `at`; a file that ends before is a failure, as is one not there.
async fn bytes_at(host : @host.Host, path : String, at : Int64, length : Int64) -> Bytes {
  let v = shell(host, "fs.bytes", { "path": Json::string(path), "from": num(at), "length": num(length), "exact": true })
  guard v is String(hex) else { raise Failed("\{path}: not there") }
  @hex.decode(hex)
}

///|
/// A put-away transcript's frames, from its table: None without one, or one that does not add up to the file
/// (reference/packed.ts `framesOf`).
async fn frames_of(host : @host.Host, path : String) -> Array[Frame]? {
  let size = match shell(host, "fs.meta", { "path": Json::string(path) }) {
    { "size": Number(size, ..), .. } => size.to_int64()
    _ => raise Failed("\{path}: not there")
  }
  if size < 8L + footer.to_int64() {
    return None
  }
  guard table_length(size, bytes_at(host, path, size - footer.to_int64(), footer.to_int64())[:]) is Some((length, entry)) else {
    return None
  }
  frames_in(size, bytes_at(host, path, size - length, length)[:], entry)
}

///|
/// Whether a put-away transcript is in segments as it is put away now: with its table, and every segment compressed
/// (reference/packed.ts `segmentedSoon`); false where it does not read.
async fn segmented(host : @host.Host, path : String) -> Bool {
  let frames = frames_of(host, path) catch { _ => return false }
  guard frames is Some(frames) else { return false }
  for f in frames {
    if f.packed < 5L {
      continue
    }
    let head = bytes_at(host, path, f.at, 5L) catch { _ => return false }
    if stored(head[:]) {
      return false
    }
  }
  true
}

///|
/// The file at `out` made of `path` in segments (its zstd frames' content with `unzstd`), its table after them, on
/// disk; its frames as its table says them.
async fn segment_into(host : @host.Host, path : String, out : String, unzstd : Bool) -> Array[Frame] {
  let made = shell(host, "zstd.segments", {
    "path": Json::string(path),
    "out": Json::string(out),
    "unzstd": Json::boolean(unzstd),
    "segment": num(segment.to_int64()),
  })
  guard made is { "frames": Array(listed), .. } else { raise Failed("no frames made of \{path}") }
  let sizes = []
  for f in listed {
    guard f is Array([Number(packed, ..), Number(size, ..)]) else { raise Failed("no frames made of \{path}") }
    sizes.push((packed.to_int64(), size.to_int64()))
  }
  ignore(shell(host, "fs.put", { "path": Json::string(out), "sync": true }, bytes=seek_table(sizes)))
  // (read back as any reader reads it: by the table written)
  guard frames_of(host, out) is Some(frames) && frames.length() == sizes.length() else {
    raise Failed("\{out}: its table does not read back")
  }
  frames
}

///|
/// What reading the file at `path` through says (`zstd.check`): by its table's frames, where it has one.
async fn check(host : @host.Host, path : String, frames : Array[Frame]?, into? : String, same? : String) -> Json {
  let args : Map[String, Json] = { "path": Json::string(path) }
  if frames is Some(frames) {
    args["frames"] = Json::array(frames.map(f => Json::array([num(f.at), num(f.packed), num(f.size)])))
  }
  if into is Some(into) {
    args["into"] = Json::string(into)
  }
  if same is Some(same) {
    args["same"] = Json::string(same)
  }
  shell(host, "zstd.check", args)
}

///|
/// What the shell is asked for a workspace's ask `op` (`workspace.pack`, `.unpack`, `.file`): its op and arguments, each
/// given (a path's components only as strings), else what is missing said.
fn workspace_call(op : String, ask : Json) -> (String, Map[String, Json]) raise Failed {
  let given = (key : String) => Json::string(str_of(ask, key))
  match op {
    "workspace.pack" => ("tar.pack", { "dir": given("dir"), "out": given("out") })
    "workspace.unpack" => {
      let args : Map[String, Json] = { "path": given("path"), "dest": given("dest") }
      match field(ask, "prefix") {
        None | Some(Null) => ()
        Some(String(prefix)) => args["prefix"] = Json::string(prefix)
        Some(_) => raise Failed("no prefix")
      }
      ("tar.unpack", args)
    }
    "workspace.file" => {
      guard field(ask, "wanted") is Some(Array(wanted)) && wanted.iter().all(p => p is String(_)) else {
        raise Failed("no wanted")
      }
      ("tar.file", { "path": given("path"), "wanted": Json::array(wanted), "out": given("out") })
    }
    _ => raise Failed("no such ask")
  }
}

///|
/// The answer to one ask (its `id` put on by the caller):
/// - `pack {path, temp}`: the transcript at `path` put away into `temp`, read back and found to be the transcript
///   still, byte for byte (archive.ts `packFileIf`);
/// - `check {path}`: a transcript put away read through whole (`packFileIf` where only it is left);
/// - `segment {path, source, temp}`: one put away before it was in segments, or with a segment stored as it is, put
///   away again into `temp`, what it holds the same: `{segmented}`, false where it was already (`segmentFile`);
/// - `restore {source, temp}`: one put away written back whole into `temp` (`restoreFile`);
/// - `segmented {path}`, `frames {path}`, `table {frames}`: what the format says of a file, and a table's bytes (hex);
/// - `workspace.pack {dir, out}`: the workspace at `dir` put away into `out` (a GNU tar in zstd, as the Rust station's),
///   read back whole and the workspace found unchanged meanwhile (archive.ts `packWorkspaceIf`);
/// - `workspace.unpack {path, dest, prefix?}`: the archive at `path` made in `dest`, only its files and directories
///   under `prefix` where given: `{refused}`, the links the machine refused, `[path, target]` each (`restoreWorkspace`,
///   `emptyWorkspace`);
/// - `workspace.file {path, wanted, out}`: the file of the archive at `path` whose path's components are `wanted`,
///   written to `out`: `{found}` (`workspaceFile`).
pub async fn answer(host : @host.Host, ask : Json) -> Json {
  match field(ask, "op") {
    Some(String("pack")) => {
      let path = str_of(ask, "path")
      let temp = str_of(ask, "temp")
      let frames = segment_into(host, path, temp, false)
      match check(host, temp, Some(frames), same=path) {
        { "differs": String("shortened"), .. } => raise Failed("transcript shortened while archiving")
        { "differs": String(_), .. } => raise Failed("transcript changed while archiving \{path}")
        _ => done()
      }
    }
    Some(String("check")) => {
      let path = str_of(ask, "path")
      ignore(check(host, path, frames_of(host, path)))
      done()
    }
    Some(String("segment")) => {
      let source = str_of(ask, "source")
      if segmented(host, source) {
        return { "segmented": false }
      }
      let theirs = check(host, source, frames_of(host, source))
      let frames = segment_into(host, source, str_of(ask, "temp"), true)
      let mine = check(host, str_of(ask, "temp"), Some(frames))
      if field(mine, "sha256") is None || field(mine, "sha256") != field(theirs, "sha256") {
        raise Failed("transcript not the same in segments \{str_of(ask, "path")}")
      }
      { "segmented": true }
    }
    Some(String("restore")) => {
      let source = str_of(ask, "source")
      ignore(check(host, source, frames_of(host, source), into=str_of(ask, "temp")))
      done()
    }
    Some(String("segmented")) => { "segmented": Json::boolean(segmented(host, str_of(ask, "path"))) }
    Some(String("frames")) =>
      match frames_of(host, str_of(ask, "path")) {
        Some(frames) =>
          {
            "frames": Json::array(
              frames.map(f => Json::array([num(f.at), num(f.packed), num(f.from), num(f.size)])),
            ),
          }
        None => { "frames": Json::null() }
      }
    Some(String("table")) => {
      let sizes = []
      if field(ask, "frames") is Some(Array(listed)) {
        for f in listed {
          guard f is Array([Number(packed, ..), Number(size, ..)]) else { raise Failed("bad frame") }
          sizes.push((packed.to_int64(), size.to_int64()))
        }
      }
      { "table": Json::string(@hex.encode(seek_table(sizes))) }
    }
    Some(String("workspace.pack")) => {
      let (op, args) = workspace_call("workspace.pack", ask)
      ignore(shell(host, op, args))
      done()
    }
    Some(String("workspace.unpack")) => {
      let (op, args) = workspace_call("workspace.unpack", ask)
      match shell(host, op, args) {
        { "refused": Array(refused), .. } => { "refused": Json::array(refused) }
        _ => raise Failed("\{str_of(ask, "path")}: not unpacked")
      }
    }
    Some(String("workspace.file")) => {
      let (op, args) = workspace_call("workspace.file", ask)
      match shell(host, op, args) {
        { "found": True, .. } => { "found": true }
        _ => { "found": false }
      }
    }
    _ => raise Failed("no such ask")
  }
}
