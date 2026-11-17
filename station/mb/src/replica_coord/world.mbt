// What the station is to these parts, and the bytes they send and are sent.

///|
/// The bytes a request or an answer carries after it (mesh/bus.ts `Bytes`): whole, a file's range read as it goes
/// (mesh/files.ts `fileBytes`), or made as it is read (a pack, pack.mbt).
pub enum Body {
  Whole(Bytes)
  File(String, Double, Double)
  Stream(async () -> Bytes?)
}

///|
/// The bytes of `body`, a piece at a time (None: its end).
pub fn Body::reader(self : Body, fs : Fs) -> async () -> Bytes? {
  match self {
    Whole(b) => {
      let given = Ref(false)
      async fn() {
        if given.val {
          None
        } else {
          given.val = true
          Some(b)
        }
      }
    }
    File(path, from, size) => {
      let at = Ref(from)
      let end = from + size
      async fn() {
        if at.val >= end {
          return None
        }
        let n = if end - at.val > piece { piece } else { end - at.val }
        let b = fs.files.read_range(path, at.val, n)
        if b.length() == 0 {
          // (shorter than it was said: mesh/files.ts's `got shorter`)
          raise failed("\{path} got shorter as it was sent")
        }
        at.val += b.length().to_double()
        Some(b)
      }
    }
    Stream(next) => next
  }
}

///|
/// All the bytes of `body`, at most `most` (mesh/files.ts `readBytes`).
pub async fn Body::whole(self : Body, fs : Fs, most? : Double = 268435456.0) -> Bytes {
  let next = self.reader(fs)
  let out = @buffer.new()
  while next() is Some(b) {
    out.write_bytes(b)
    if out.length().to_double() > most {
      raise refused("more than \{num_text(most)} bytes")
    }
  }
  out.to_bytes()
}

///|
let piece : Double = 1048576.0

///|
/// What another station answered: its value, and the bytes after it.
pub struct Answer {
  value : J
  body : Body?
}

///|
/// The station's clock and its timers (ops/fibers.ts `Fibers`): `after` sets one, what it gives back calls it off.
pub struct Clock {
  now : () -> Double
  after : (Double, () -> Unit) -> () -> Unit
}

///|
/// What the station is to these parts. `call` asks a part by name (`store.getSession`, `hub.holdChat`...), its
/// arguments as the TypeScript gives them; `ask` another station (mesh/bus.ts `ask`, `askItself` with `itself`);
/// `log` the station's log; `words` what it says; `fork` work let go on (a `void` promise).
pub struct World {
  host : @host.Host
  fs : Fs
  call : async (String, Array[J]) -> J
  ask_peer : async (String, J, Body?, Bool) -> Answer
  clock : Clock
  log : (String, String, String, J) -> Unit
  words : @session_chats.Words
  lang : Ref[String]
  fork : (async () -> Unit) -> Unit
  /// What the station is told and answers nothing of (`changed`, an update held and let go): said, not waited on.
  tell : (String, Array[J]) -> Unit
}

///|
pub async fn World::ask(self : World, station : String, request : J, body? : Body) -> J {
  (self.ask_peer)(station, request, body, false).value
}

///|
pub async fn World::ask_bytes(self : World, station : String, request : J, body? : Body) -> Answer {
  (self.ask_peer)(station, request, body, false)
}

///|
pub async fn World::ask_itself(self : World, station : String, request : J) -> J {
  (self.ask_peer)(station, request, None, true).value
}

///|
pub fn World::now(self : World) -> Double {
  (self.clock.now)()
}

///|
pub fn World::after(self : World, ms : Double, f : () -> Unit) -> () -> Unit {
  (self.clock.after)(ms, f)
}

///|
pub fn World::warn(self : World, part : String, words : String, fields : J) -> Unit {
  (self.log)("warn", part, words, fields)
}

///|
pub fn World::info(self : World, part : String, words : String, fields : J) -> Unit {
  (self.log)("info", part, words, fields)
}

///|
/// `tr(stationLang(), key, args)`.
pub fn World::tr(self : World, key : String, args? : Array[(String, String)] = []) -> String {
  self.words.tr(self.lang.val, key, args~)
}

///|
/// A part of the station asked; what it threw raises as it threw it.
pub async fn World::part(self : World, name : String, args : Array[J]) -> J {
  (self.call)(name, args)
}

///|
pub fn World::part_tell(self : World, name : String, args : Array[J]) -> Unit {
  (self.tell)(name, args)
}

///|
/// `void promise`: let go on its own, what it throws let go.
pub fn World::go(self : World, f : async () -> Unit) -> Unit {
  (self.fork)(f)
}

// ── a promise kept: one run others wait for ──

///|
/// What one piece of work comes to, waited for by any number (a Promise held: `#passing`, `#running`...).
pub struct Run {
  done : @effect.Deferred[Result[Unit, Error]]
}

///|
pub fn World::run(self : World, f : async () -> Unit) -> Run {
  let r : Run = { done: @effect.Deferred::new() }
  self.go(async fn() {
    let out = try f() catch {
      e => Err(e)
    } noraise {
      _ => Ok(())
    }
    ignore(r.done.succeed(out))
  })
  r
}

///|
/// Its end, what it threw raised.
pub async fn Run::wait(self : Run) -> Unit {
  match self.done.wait() {
    Ok(_) => ()
    Err(e) => raise e
  }
}

///|
/// Its end, whatever it came to (`.catch(() => {})`).
pub async fn Run::settled(self : Run) -> Unit {
  ignore(self.done.wait()) catch {
    _ => ()
  }
}

///|
pub fn Run::is_done(self : Run) -> Bool {
  self.done.is_done()
}

///|
/// A run already over.
pub fn Run::over() -> Run {
  let r : Run = { done: @effect.Deferred::new() }
  ignore(r.done.succeed(Ok(())))
  r
}

///|
/// A promise to be kept later (`new Promise(resolve => ...)`), resolved once.
pub struct Later[T] {
  d : @effect.Deferred[T]
}

///|
pub fn[T] Later::new() -> Later[T] {
  { d: @effect.Deferred::new() }
}

///|
pub fn[T] Later::resolve(self : Later[T], v : T) -> Unit {
  ignore(self.d.succeed(v))
}

///|
pub async fn[T] Later::wait(self : Later[T]) -> T {
  self.d.wait()
}

///|
pub fn[T] Later::is_done(self : Later[T]) -> Bool {
  self.d.is_done()
}
