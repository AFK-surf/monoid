// What these parts ask of the world, as records of functions: the host's (`host_io.mbt`, over the shell), or a test's
// (the harness's world, every answer given and every ask written down). Nothing here reaches the machine by itself.

///|
/// The words people read (station/src/ops/i18n.ts `tr`): a language, a key, its values.
pub(all) struct Words {
  tr : (String, String, Array[(String, String)]) -> String
}

///|
/// A failure whose message is for people, in their language (i18n.ts `Said`).
pub(all) suberror Said {
  Said(String)
}

///|
/// Its words alone, as the TypeScript's `message` (a suberror shows its constructor's path otherwise).
pub impl Show for Said with output(self, logger) {
  match self {
    Said(m) => logger.write_string(m)
  }
}

///|
/// A sign-in that can no longer be renewed (console.ts `RenewRefused`): its refresh token turned down (`status`), or
/// none kept. It is a `Said` too: what it says is for people.
pub(all) suberror RenewRefused {
  RenewRefused(Int?, String)
}

///|
pub impl Show for RenewRefused with output(self, logger) {
  match self {
    RenewRefused(_, m) => logger.write_string(m)
  }
}

///|
/// Any other failure (an `Error` with its message).
pub(all) suberror Failed {
  Failed(String)
}

///|
pub impl Show for Failed with output(self, logger) {
  match self {
    Failed(m) => logger.write_string(m)
  }
}

///|
/// A file system's failure: its code (ENOENT, EEXIST…) and its words.
pub(all) suberror FsError {
  FsError(String, String)
}

///|
pub impl Show for FsError with output(self, logger) {
  match self {
    FsError(_, m) => logger.write_string(m)
  }
}

///|
/// The words of a failure, as `(error as Error).message` says them.
pub fn message_of(e : Error) -> String {
  match e {
    Said(m) => m
    RenewRefused(_, m) => m
    Failed(m) => m
    FsError(_, m) => m
    JsonError(m) => m
    _ => e.to_string()
  }
}

///|
fn code_of(e : Error) -> String {
  match e {
    FsError(c, _) => c
    _ => ""
  }
}

///|
/// An environment, its variables in order.
pub type Env = Map[String, String]

///|
pub(all) struct Request {
  url : String
  method_ : String
  headers : Array[(String, String)]
  body : String?
  timeout_ms : Int
  /// `redirect: "manual"`.
  manual : Bool
}

///|
pub(all) struct Response {
  status : Int
  headers : Array[(String, String)]
  body : String
}

///|
fn Response::ok(self : Response) -> Bool {
  self.status >= 200 && self.status <= 299
}

///|
/// A header's value, by its name in any case.
fn Response::header(self : Response, name : String) -> String? {
  for h in self.headers {
    if lower(h.0) == name {
      return Some(h.1)
    }
  }
  None
}

///|
/// What `fs.stat` says of a path, of what tells one apart from another.
pub(all) struct Stat {
  dev : Double
  ino : Double
  size : Double
  mtime_ms : Double
}

///|
/// A folder held open (oauth.ts's lock's `fd`).
pub(all) struct Held {
  stat : async () -> Stat
  utimes : async (Int64) -> Unit
  close : async () -> Unit
}

///|
/// Time, the network, files and what is said in the logs.
pub(all) struct Io {
  /// The part's clock (a Fibers' `now`).
  now : () -> Int64
  /// The machine's (`wall.now`): expiries, what is written for other programs.
  wall : () -> Int64
  sleep : async (Int) -> Unit
  /// `f` once, `ms` from now; what it gives calls it off.
  after : (Int64, () -> Unit) -> () -> Unit
  /// `f` every `ms`; what it gives stops it.
  every : (Int64, () -> Unit) -> () -> Unit
  /// Work going on by itself (a promise not waited for).
  spawn : (async () -> Unit) -> Unit
  fetch : async (Request) -> Response
  /// A file's text (`readFile(…, "utf8")`).
  read : async (String) -> String
  /// A file written whole where only its owner reads it (files.ts `writePrivateSoon`).
  write_private : async (String, String) -> Unit
  /// `writeFile`.
  write : async (String, String) -> Unit
  /// `mkdir`, with its folders (`recursive`) or alone (EEXIST where it is).
  mkdir : async (String, Bool) -> Unit
  rmdir : async (String) -> Unit
  /// `rm` (`recursive`, `force`).
  rm : async (String, Bool) -> Unit
  stat : async (String) -> Stat
  /// `access`: whether it is there.
  exists : async (String) -> Bool
  realpath : async (String) -> String
  readdir : async (String) -> Array[String]
  /// `open(path, "r")`.
  hold : async (String) -> Held
  /// `log.info`/`log.warn`: its level, part, words and fields.
  log : (String, String, String, Json) -> Unit
}

///|
/// How a command ended: not found (ENOENT, its words), killed at its deadline, or ended (its code: none for a
/// signal; what it wrote).
pub(all) enum Ran {
  NotFound(String)
  TimedOut
  Ended(Int?, String, String)
}

///|
/// The station's platform, as far as these parts run commands on it.
pub(all) struct Commands {
  /// A command run to its end in `env` only (the shell's PATH found first: shell-path.ts `withShellCommand`), given
  /// `ms` (execFile's `timeout`, killed then).
  run : async (String, Array[String], Env, Int) -> Ran
}
