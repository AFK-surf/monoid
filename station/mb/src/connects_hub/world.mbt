// What these parts are given of the station and the machine (the TypeScript's imports: its clock, its log, node:fs,
// its words), each a value of functions, so that the station's own program gives its own and the harness asks the test
// (harness.mbt). Nothing here reaches anything by itself.

///|
/// The clock its waits run on (Effect's `Clock`: a TestClock in tests): the time now, in ms, and a wait.
pub(all) struct Clock {
  now : () -> Double
  sleep : async (Double) -> Unit
}

///|
/// The clock of the program's own runtime.
pub fn Clock::live() -> Clock {
  {
    now: () => @effect.now().to_double(),
    sleep: async fn(ms) {
      let n = if ms <= 0.0 { 0 } else if ms >= 2147483647.0 { 2147483647 } else { ms.ceil().to_int() }
      @effect.sleep(n)
    },
  }
}

///|
/// The station's log (`log.info`, `log.warn`, `log.error`): its level, part, words and fields.
pub(all) struct Log {
  write : (String, String, String, J) -> Unit
}

///|
pub fn Log::info(self : Log, part : String, words : String, fields : J) -> Unit {
  (self.write)("info", part, words, fields)
}

///|
pub fn Log::warn(self : Log, part : String, words : String, fields : J) -> Unit {
  (self.write)("warn", part, words, fields)
}

///|
pub fn Log::error(self : Log, part : String, words : String, fields : J) -> Unit {
  (self.write)("error", part, words, fields)
}

///|
/// The files (node:fs's promises). A file that is not there raises `Thrown("ENOENT", ...)`; `sep` joins a path.
pub(all) struct Fs {
  sep : String
  read_text : async (String) -> String
  read_bytes : async (String) -> Bytes
  /// Up to `length` bytes of it from `offset` (a `FileHandle`'s `read`): a file read a piece at a time.
  read_part : async (String, Double, Double) -> Bytes
  /// Its size in bytes (`stat`).
  size : async (String) -> Double
  write_text : async (String, String) -> Unit
  write_bytes : async (String, Bytes) -> Unit
  append_text : async (String, String) -> Unit
  rename : async (String, String) -> Unit
  /// `rm(path, { recursive: true, force: true })`.
  rm : async (String) -> Unit
  /// `mkdir(path, { recursive: true })`.
  mkdir : async (String) -> Unit
  readdir : async (String) -> Array[String]
  /// ops/files.ts `writePrivateSoon`: written whole (its directory made), readable by the station's user only.
  write_private : async (String, String) -> Unit
}

///|
/// `join(...parts)`.
pub fn Fs::join(self : Fs, parts : Array[String]) -> String {
  let kept = parts.filter(p => p != "")
  let out = StringBuilder()
  for i, p in kept {
    if i > 0 && !p.has_prefix(self.sep) && !out.to_string().has_suffix(self.sep) {
      out.write_string(self.sep)
    }
    out.write_string(p)
  }
  out.to_string()
}

///|
/// `dirname(path)`.
pub fn Fs::dirname(self : Fs, path : String) -> String {
  @nodepath.dirname(self.sep, path)
}

///|
/// `basename(path)`.
pub fn basename(path : String, sep : String) -> String {
  @nodepath.basename(sep, path)
}

///|
/// Whether a file's absence is what raised.
pub fn not_there(e : Error) -> Bool {
  thrown_kind(e) == "ENOENT"
}

///|
/// Runs `f` as a fiber of its own, nothing waiting for it; what it raises is let go (a `void f().catch(() => {})`). As
/// a promise's function does, it runs at once until it first waits (with what was ready to run already).
pub fn spawn(f : async () -> Unit) -> Unit {
  let rt = @effect.runtime()
  ignore(rt.fork_daemon("connects", on_error=_ => (), () => f() catch { _ => () }))
  ignore(rt.run_ready())
}

///|
/// Runs `f` in `scope`, nothing waiting for it; what it raises is let go. Ended with the scope. It runs at once until it
/// first waits, as `spawn`'s does.
pub fn spawn_in(scope : @effect.Scope, f : async () -> Unit) -> Unit {
  if scope.is_closed() {
    return
  }
  ignore(scope.fork_daemon("connects", on_error=_ => (), () => f() catch { _ => () }))
  ignore(@effect.runtime().run_ready())
}

///|
/// A chain of turns (`chain = chain.then(f)`): each starts once the one before it ended, whatever came of it.
pub struct Turns {
  priv mut tail : @effect.Deferred[Unit]?
}

///|
pub fn Turns::new() -> Turns {
  { tail: None }
}

///|
/// `f`, after every turn asked before it.
pub async fn[X] Turns::run(self : Turns, f : async () -> X) -> X {
  let before = self.tail
  let mine : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.tail = Some(mine)
  defer {
    ignore(mine.succeed(()))
    if self.tail is Some(t) && physical_equal(t, mine) {
      self.tail = None
    }
  }
  match before {
    Some(d) => d.wait() catch { _ => () }
    None => ()
  }
  f()
}

///|
/// Whether no turn is asked or under way.
pub fn Turns::idle(self : Turns) -> Bool {
  self.tail is None
}

///|
/// The words of the station (`tr`), and its own language (`stationLang()`).
pub(all) struct Speech {
  words : @session_chats.Words
  lang : Ref[String]
}

///|
pub fn Speech::tr(self : Speech, lang : String, key : String, args? : Array[(String, String)] = []) -> String {
  self.words.tr(lang, key, args~)
}

///|
/// The station's own language now.
pub fn Speech::station_lang(self : Speech) -> String {
  self.lang.val
}

///|
/// Once every turn asked so far has ended.
pub async fn Turns::settled(self : Turns) -> Unit {
  match self.tail {
    Some(d) => d.wait() catch { _ => () }
    None => ()
  }
}

///|
/// `f` as a turn of its own, nothing waiting for it: its place taken now (`chain = chain.then(f)` said at once), what
/// it raises let go.
pub fn Turns::run_soon(self : Turns, f : async () -> Unit) -> Unit {
  let before = self.tail
  let mine : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.tail = Some(mine)
  spawn(async fn() {
    defer {
      ignore(mine.succeed(()))
      if self.tail is Some(t) && physical_equal(t, mine) {
        self.tail = None
      }
    }
    match before {
      Some(d) => d.wait() catch { _ => () }
      None => ()
    }
    f()
  })
}
