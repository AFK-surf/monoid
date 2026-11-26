// The filesystem and the programs run, as these parts use them, through the shell (client/shell `fs.*`, `proc.run`):
// off this program's thread, each a failure where node:fs/promises' would be one.

///|
suberror FsError {
  FsError(String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
impl Show for FsError with output(self, logger) {
  match self {
    FsError(m) => logger.write_string(m)
  }
}

///|
/// What the shell answered, its `value` where it says one.
fn answered(json : Json) -> Json {
  match json {
    { "value": v, .. } => v
    v => v
  }
}

///|
async fn ask(host : @host.Host, op : String, args : Json) -> Json raise {
  try {
    let (json, _) = host.shell(op, args)
    answered(json)
  } catch {
    FsError(_) as e => raise e
    e => raise FsError("\{op}: \{e}")
  }
}

///|
async fn ask_or_null(host : @host.Host, op : String, args : Json) -> Json {
  ask(host, op, args) catch {
    _ => Json::null()
  }
}

///|
/// `readFile(path, "utf8")`, none where it does not read.
async fn read_text(host : @host.Host, path : String) -> String? {
  match ask_or_null(host, "fs.read", { "path": Json::string(path) }) {
    String(s) => Some(s)
    _ => None
  }
}

///|
/// `readdir(dir, { withFileTypes: true })`: each name with its kind ("file", "dir", "link", "other"); none where it
/// does not read.
async fn read_dir(host : @host.Host, path : String) -> Array[(String, String)] {
  match ask_or_null(host, "fs.readdir", { "path": Json::string(path), "types": Json::boolean(true) }) {
    Array(items) =>
      items.filter_map(e => match e {
        [String(name), String(kind)] => Some((name, kind))
        _ => None
      })
    _ => []
  }
}

///|
/// `readdir(dir)`: the names; none where it does not read (a failure with `strict`).
async fn read_names(host : @host.Host, path : String) -> Array[String]? {
  match ask_or_null(host, "fs.readdir", { "path": Json::string(path) }) {
    Array(items) =>
      Some(
        items.filter_map(e => match e {
          String(name) => Some(name)
          _ => None
        }),
      )
    _ => None
  }
}

///|
/// What `stat(path)` says it is ("file", "dir", "other"), links followed; none where nothing is there.
async fn stat_kind(host : @host.Host, path : String) -> String? {
  match ask_or_null(host, "fs.stat", { "path": Json::string(path) }) {
    String(k) => Some(k)
    _ => None
  }
}

///|
/// `access(path)`: whether something is there (links followed).
async fn exists(host : @host.Host, path : String) -> Bool {
  stat_kind(host, path) is Some(_)
}

///|
/// `mkdir(path, { recursive: true })`.
async fn make_dir(host : @host.Host, path : String) -> Unit raise {
  ask(host, "fs.mkdir", { "path": Json::string(path) }) |> ignore
}

///|
/// `writeFile(path, text)`: whole, its folder there; `mode` set after.
async fn write_file(host : @host.Host, path : String, text : String, mode? : Int) -> Unit raise {
  ask(host, "fs.write", { "path": Json::string(path), "text": Json::string(text) }) |> ignore
  if mode is Some(m) {
    ask(host, "fs.chmod", { "path": Json::string(path), "mode": Json::number(m.to_double()) }) |> ignore
  }
}

///|
/// `appendFile(path, text)`.
async fn append_file(host : @host.Host, path : String, text : String) -> Unit raise {
  try {
    host.shell("fs.put", { "path": Json::string(path) }, bytes=@utf8.encode(text)) |> ignore
  } catch {
    e => raise FsError("fs.put: \{e}")
  }
}

///|
/// `rm(path, { recursive, force: true })`.
async fn remove(host : @host.Host, path : String, recursive? : Bool = false) -> Unit raise {
  ask(host, "fs.remove", { "path": Json::string(path), "recursive": Json::boolean(recursive) }) |> ignore
}

///|
/// `symlink(target, path)`.
async fn symlink(host : @host.Host, target : String, path : String) -> Unit raise {
  ask(host, "fs.symlink", { "target": Json::string(target), "path": Json::string(path) }) |> ignore
}

///|
/// A program run to its end (`execFile`): its exit code and stdout, none where it did not end by itself in `timeout_ms`
/// (not started, killed, a signal).
async fn run_program(
  host : @host.Host,
  command : String,
  args : Array[String],
  timeout_ms? : Int = 5000,
  env? : Map[String, String],
) -> (Int, String)? {
  let a : Map[String, Json] = {
    "command": Json::string(command),
    "args": Json::array(args.map(x => Json::string(x))),
    "timeoutMs": Json::number(timeout_ms.to_double()),
    "code": Json::boolean(true),
  }
  if env is Some(e) {
    a["env"] = Json::object(e.map((_, v) => Json::string(v)))
  }
  match ask_or_null(host, "proc.run", Json::object(a)) {
    { "code": Number(code, ..), "out": String(out), .. } => Some((code.to_int(), out))
    _ => None
  }
}
