// What these parts are given of the world (the TypeScript's imports, made parameters): a DevTools connection, the
// clock and its fibers, the station's log, the files, the screens. The station's program gives the machine's
// (host_io.mbt); a test gives its own (harness.mbt).

///|
/// An event Chrome's DevTools told (`CdpEvent`).
pub(all) struct CdpEvent {
  method : String
  params : J
  session_id : String?
}

///|
/// A connection to Chrome's DevTools protocol (cdp.ts `Cdp`).
pub(all) struct Cdp {
  /// A command sent now (as the TypeScript's `send` sends it as it is called), its result later: it fails with
  /// Chrome's error message, or when the connection is gone.
  post : (String, J, String?) -> Later[J]
  /// Hears every event; the returned function stops hearing.
  on : ((CdpEvent) -> Unit) -> () -> Unit
  /// Returns once the connection is gone, whichever side ended it.
  closed : async () -> Unit
  close : () -> Unit
}

///|
/// `await cdp.send(method, params, session)`.
pub async fn Cdp::send(self : Cdp, method : String, params : J, session : String?) -> J {
  (self.post)(method, params, session).wait()
}

///|
/// `await cdp.send(method, params)`.
pub async fn Cdp::ask(self : Cdp, method : String, params? : J = Obj([]), session? : String) -> J {
  (self.post)(method, params, session).wait()
}

///|
/// `void cdp.send(…).catch(() => {})`: sent now, its answer let go.
pub fn Cdp::tell(self : Cdp, method : String, params : J, session : String?) -> Unit {
  ignore((self.post)(method, params, session))
}

///|
/// The clock of a part (ops/fibers.ts `Fibers`): its time, a timer, a fiber of its own.
pub(all) struct Clock {
  /// Milliseconds.
  now : () -> Double
  /// `f` once, `ms` from now, unless called off (the function returned).
  after : (Double, async () -> Unit) -> () -> Unit
  /// `f` set going (`void f()`).
  spawn : (async () -> Unit) -> Unit
  /// Waits `ms` (Chrome's own time: `wall.sleep`).
  sleep : async (Double) -> Unit
}

///|
/// The station's log (ops/log.ts): a part, what happened, its fields.
pub(all) struct Log {
  info : (String, String, J) -> Unit
  warn : (String, String, J) -> Unit
}

///|
pub fn Log::silent() -> Log {
  { info: (_, _, _) => (), warn: (_, _, _) => () }
}

///|
/// A file system's failure: its code (`ENOENT`…) and words.
pub(all) suberror FsError {
  FsError(String, String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for FsError with output(self, logger) {
  match self {
    FsError(_, m) => logger.write_string(m)
  }
}

///|
/// The machine's files, as these parts ask them (node:fs/promises, ops/files.ts).
pub(all) struct Files {
  /// `readFile(path, "utf8")`; None where it cannot be read.
  read : async (String) -> String?
  /// `writePrivateSoon`: its directory made, written beside it (0600) and renamed into place.
  write_private : async (String, String) -> Unit raise
  /// `writeFile(path, text, { mode })` (its directory must be there).
  write : async (String, String, Int) -> Unit raise
  /// `open(path, "w", 0o600)`, written and synced: a FsError("ENOENT") where its directory is not there.
  create : async (String, String) -> Unit raise
  rename : async (String, String) -> Unit raise
  /// `unlink`.
  unlink : async (String) -> Unit raise
  /// `mkdir(path, { recursive: true, mode })`.
  mkdir : async (String, Int) -> Unit raise
  /// `rm(path, { recursive, force: true })`.
  rm : async (String, Bool) -> Unit raise
  /// `readdir`; a FsError where it cannot be listed.
  readdir : async (String) -> Array[String] raise
  /// `access`: whether it is there.
  exists : async (String) -> Bool
  /// `stat(path).mtimeMs`; a FsError where there is none.
  mtime : async (String) -> Double raise
}

///|
/// What a screen's viewer takes (screens/source.ts `ViewOptions`), as JSON: `codecs`, `maxWidth`, `maxHeight`, `peek`,
/// `fit`.
pub(all) struct ViewOptions {
  codecs : Array[String]
  max_width : Double
  max_height : Double
  peek : Bool
  /// The viewer's phone: its width, height and scale.
  fit : (Double, Double, Double)?
  passkeys : Bool?
  quality : String?
}

///|
pub fn ViewOptions::of_j(v : J) -> ViewOptions {
  let fit = match at(Some(v), "fit") {
    Some(Obj(_) as f) =>
      Some((js_num(at(Some(f), "width")), js_num(at(Some(f), "height")), js_num(at(Some(f), "scale"))))
    _ => None
  }
  {
    codecs: arr(at(Some(v), "codecs")).filter_map(x => str_of(Some(x))),
    max_width: js_num(at(Some(v), "maxWidth")),
    max_height: js_num(at(Some(v), "maxHeight")),
    peek: is_true(at(Some(v), "peek")),
    fit,
    passkeys: match at(Some(v), "passkeys") {
      Some(Bool(b)) => Some(b)
      _ => None
    },
    quality: str_of(at(Some(v), "quality")),
  }
}

///|
/// A frame a view gives (screens/source.ts `Frame`): its config where it changed (codec, width, height), whether it
/// is a key frame, its time (µs), its bytes.
pub(all) struct Frame {
  config : (String, Double, Double)?
  key : Bool
  ts : Double
  data : Bytes
}

///|
/// A clipboard's text (screens/source.ts `Clip`, of type text).
pub(all) struct Clip {
  type_ : String
  text : String
}

///|
/// A person's view of a screen (screens/source.ts `ScreenView`), what of it these parts give.
pub(all) struct ScreenView {
  next : async () -> Frame?
  keyframe : () -> Unit
  input : async (J) -> Unit
  set_clipboard : async (Clip, Bool) -> Unit
  watch_clipboard : ((Clip) -> Unit) -> () -> Unit
  /// The login field in focus (`{host, field}` or null), until the returned function.
  watch_login : ((J) -> Unit) -> () -> Unit
  fill : async (J) -> Unit
  /// A page's passkey sign-ins (`PasskeyAsk` or null), until the returned function.
  watch_passkey : ((J) -> Unit) -> () -> Unit
  passkey : async (J) -> Unit
  bounds : (Double, Double) -> Unit
  rate : ((Double) -> Unit)?
  video : () -> J
  viewport : () -> (Double, Double)
  /// A tab its page opened, by its screen's id, until the returned function.
  watch_child : ((String) -> Unit) -> () -> Unit
  close : () -> Unit
  /// A preview's (it is not brought forward).
  peek : Bool
}

///|
/// One of the station's screens (screens/source.ts `ScreenSource`), as these parts make them: a tab of Chrome's, a
/// person's own page, a chat's Farview tab.
pub(all) struct ScreenSource {
  id : String
  kind : String
  peek : () -> Bool
  title : () -> String
  site : () -> String?
  address : () -> String
  size : () -> (Double, Double)
  clipboard : () -> Array[String]
  opened_by : () -> String?
  open : async (ViewOptions) -> ScreenView
  open_url : (async (String) -> Unit)?
  reload : (async () -> Unit)?
  back : (async () -> Unit)?
  forward : (async () -> Unit)?
  discard : (async () -> Unit)?
  sleep : (async () -> Unit)?
  /// A person's own page (user-tabs.ts): `user_tab`, `popup`, `sleeping`.
  user_tab : Bool
  popup : Bool
  sleeping : () -> Bool
  /// A chat's Farview tab.
  farview : Bool
}

///|
/// Where the tabs are added as screens (screens/source.ts `Screens`): the function returned takes one out again;
/// `changed` says a title or a size changed (None: a registry that cannot say so, told by adding it again).
pub(all) struct Screens {
  add : (ScreenSource) -> () -> Unit
  changed : (() -> Unit)?
  /// Registers the station's browser so members can open persistent user pages (`POST /screens/browser`).
  set_browser : ((ScreenBrowser?) -> Unit)?
}

///|
/// The station's browser as the screens know it (screens/source.ts `ScreenBrowser`).
pub(all) struct ScreenBrowser {
  available : () -> Bool
  open_user_tab : async (String, String?) -> String
}

///|
fn told_changed(screens : Screens?) -> Unit {
  match screens {
    Some({ changed: Some(f), .. }) => f()
    _ => ()
  }
}

///|
/// The fields a log line carries.
fn fields(fs : Array[(String, J)]) -> J {
  jo(fs)
}

///|
/// A list of promises waited on together (`Promise.all`), each set going in turn on `clock`; the first failure is
/// raised once every one has ended.
async fn all_of(clock : Clock, fs : Array[async () -> Unit]) -> Unit {
  if fs.length() == 0 {
    return
  }
  if fs.length() == 1 {
    fs[0]()
    return
  }
  let done : Array[@effect.Deferred[Unit]] = []
  for f in fs {
    let d : @effect.Deferred[Unit] = @effect.Deferred::new()
    done.push(d)
    (clock.spawn)(async fn() {
      f() catch {
        e => {
          ignore(d.fail(e))
          return
        }
      }
      ignore(d.succeed(()))
    })
  }
  let mut first : Error? = None
  for d in done {
    d.wait() catch {
      e => if first is None { first = Some(e) }
    }
  }
  match first {
    Some(e) => raise e
    None => ()
  }
}

///|
/// A promise kept as a value (what the TypeScript keeps in a field to wait on later): set going on `clock`, its value
/// or failure kept for every waiter.
pub struct Later[X] {
  done : @effect.Deferred[X]
}

///|
pub fn[X] Later::start(clock : Clock, f : async () -> X) -> Later[X] {
  let d : @effect.Deferred[X] = @effect.Deferred::new()
  (clock.spawn)(async fn() {
    let v = f() catch {
      e => {
        ignore(d.fail(e))
        return
      }
    }
    ignore(d.succeed(v))
  })
  { done: d }
}

///|
/// A promise that is settled by whoever holds `d`.
pub fn[X] Later::of(d : @effect.Deferred[X]) -> Later[X] {
  { done: d }
}

///|
pub fn[X] Later::resolved(x : X) -> Later[X] {
  let d : @effect.Deferred[X] = @effect.Deferred::new()
  ignore(d.succeed(x))
  { done: d }
}

///|
pub async fn[X] Later::wait(self : Later[X]) -> X {
  self.done.wait()
}

///|
pub fn[X] Later::is_done(self : Later[X]) -> Bool {
  self.done.is_done()
}

///|
/// Physical identity of two kept promises.
fn[X] Later::same(self : Later[X], other : Later[X]) -> Bool {
  physical_equal(self.done, other.done)
}

///|
/// What `f` gave, or what it raised (`try?`).
pub async fn[X] attempt(f : async () -> X) -> Result[X, Error] {
  try Ok(f()) catch {
    e => Err(e)
  }
}
