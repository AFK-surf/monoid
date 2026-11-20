// A station program's host: the program's one thread runs an effect runtime on the machine's clock, and between its
// turns waits (host.c) for what comes from outside: the lines its parent writes on stdin (and the shell's answers from
// its own threads, client/shell, once a call of it that answers later is asked). Nothing waits for real time but that
// one wait, for the next of those or the runtime's next timer.

///|
#borrow(dir)
extern "C" fn start_ffi(dir : Bytes) -> Int = "sfh_start"

///|
extern "C" fn wait_ffi(ms : Int64) -> Bytes = "sfh_wait"

///|
#borrow(b)
extern "C" fn out_ffi(b : Bytes) -> Int = "sfh_out"

///|
extern "C" fn now_ffi() -> Int64 = "sfh_now"

///|
extern "C" fn wall_ms_ffi() -> Int64 = "sfh_wall_ms"

///|
#borrow(op, json)
extern "C" fn shell_sync_ffi(op : Bytes, json : Bytes) -> Bytes = "sfh_shell_sync"

///|
#borrow(op, json, bytes)
extern "C" fn shell_call_ffi(id : Int64, op : Bytes, json : Bytes, bytes : Bytes, has : Int) = "sfh_shell_call"

///|
/// What the program is given: its stdin's lines, the shell, its stdout.
pub struct Host {
  rt : @effect.Runtime
  lines : @effect.Queue[String]
  /// Stdin's bytes, made lines.
  priv input : @wire.Lines
  /// The shell's calls not answered yet, by their ids.
  priv waiting : Map[Int64, @effect.Deferred[(Json, Bytes?)]]
  priv mut next : Int64
  /// What the program's own C tells (host.c `sfh_push_sys`), by the id it was given: each told as it comes.
  priv sys : Map[Int64, (Bytes) -> Unit]
}

///|
/// An id for what the program's own C will tell (`sfh_push_sys`), each told to `told` until `Host::sys_done`.
pub fn Host::sys_listen(self : Host, told : (Bytes) -> Unit) -> Int64 {
  self.next += 1L
  let id = self.next
  self.sys[id] = told
  id
}

///|
/// Nothing more is told of `id`.
pub fn Host::sys_done(self : Host, id : Int64) -> Unit {
  self.sys.remove(id)
}

///|
/// A C string: `s` in UTF-8, NUL-terminated.
fn cstr(s : String) -> Bytes {
  let b = @utf8.encode(s)
  let out = FixedArray::make(b.length() + 1, b'\x00')
  for i = 0; i < b.length(); i = i + 1 {
    out[i] = b[i]
  }
  Bytes::from_array(out)
}

///|
/// Asks the shell at once (what it answers on the calling thread: `sql.*`).
pub fn Host::shell_sync(self : Host, op : String, args : Json) -> Json raise @wire.ShellError {
  ignore(self)
  let out = shell_sync_ffi(cstr(op), @utf8.encode(args.stringify()))
  @wire.answered(@utf8.decode_lossy(out))
}

///|
/// Asks the shell what it answers later (its network, its sockets: client/shell's `run`), with `bytes` where the call
/// carries them; its JSON and the bytes its answer carries. Other fibers go on meanwhile. `called` is told the call's
/// id as it is asked: what gives up a call the shell lets be given up (`fetch.cancel`: a fetch, a dial).
pub async fn Host::shell(
  self : Host,
  op : String,
  args : Json,
  bytes? : Bytes,
  called? : (Int64) -> Unit,
) -> (Json, Bytes?) {
  self.next += 1L
  let id = self.next
  if called is Some(f) {
    f(id)
  }
  let done = @effect.Deferred::new()
  self.waiting[id] = done
  match bytes {
    Some(b) => shell_call_ffi(id, cstr(op), @utf8.encode(args.stringify()), b, 1)
    None => shell_call_ffi(id, cstr(op), @utf8.encode(args.stringify()), b"", 0)
  }
  // (given up before its answer, interrupted: its answer, should one still come, finds no one waiting and is let go)
  errdefer self.waiting.remove(id)
  done.wait()
}

///|
/// The next line its parent wrote (without its newline); None once stdin has ended.
pub async fn Host::line(self : Host) -> String? {
  Some(self.lines.take()) catch {
    @effect.QueueShutdown => None
    e => raise e
  }
}

///|
/// What stdin said after its last newline: once it has ended, its last line where that had none (a hook's input, as a
/// program writes it whole and closes its stdin).
pub fn Host::unended(self : Host) -> String {
  self.input.unended()
}

///|
/// Writes `text` and a newline to stdout, U+2028 and U+2029 written as JSON escapes (`\u2028`, `\u2029`): the station
/// reads each line with node:readline, which ends a line at either of them too, so a chat's text with one cut the
/// answer that held it in two, neither JSON, and its read was never answered (2026-11-14). A line said here is JSON,
/// where they can stand only in a string, and so are the same escaped.
pub fn Host::say(self : Host, text : String) -> Unit {
  ignore(self)
  let line = if text.contains("\u{2028}") || text.contains("\u{2029}") {
    text.replace_all(old="\u{2028}", new="\\u2028").replace_all(old="\u{2029}", new="\\u2029")
  } else {
    text
  }
  // (a line of MBs and its end written one after the other: not copied again to end it)
  if line.length() > 64 * 1024 {
    ignore(out_ffi(@utf8.encode(line)))
    ignore(out_ffi(b"\n"))
  } else {
    ignore(out_ffi(@utf8.encode(line + "\n")))
  }
}

///|
/// Writes a line already UTF-8 (`bytes`, none of its own ends in it) and its end: one of MBs not copied again.
pub fn Host::say_bytes(self : Host, bytes : Bytes) -> Unit {
  ignore(self)
  ignore(out_ffi(bytes))
  ignore(out_ffi(b"\n"))
}

///|
/// Writes `bytes` to stdout as they are (after a line that says how many: what reads them knows).
pub fn Host::out(self : Host, bytes : Bytes) -> Unit {
  ignore(self)
  ignore(out_ffi(bytes))
}

///|
/// Writes `text` and a newline to stderr, for the station's log.
pub fn note(text : String) -> Unit {
  match note_sink.val {
    Some(sink) => sink(text)
    None => eprintln(text)
  }
}

///|
/// Where `note` writes in a program that keeps a log of its own (the station's `run`: each line with its time, and
/// heard as its own lines are); none, stderr as it is.
pub let note_sink : Ref[((String) -> Unit)?] = Ref(None)

///|
fn Host::dispatch(self : Host, e : Bytes) -> Unit {
  if e.length() >= 9 && e[0] == b'\x04' {
    let mut id = 0L
    for i = 8; i >= 1; i = i - 1 {
      id = (id << 8) | e[i].to_int64()
    }
    if self.sys.get(id) is Some(told) {
      told(e[9:].to_owned())
    }
    return
  }
  match @wire.Event::read(e) {
    Input(data) => for line in self.input.push(data) { ignore(self.lines.try_offer(line)) }
    End => self.lines.shutdown()
    Answer(id, answer, carried) =>
      match self.waiting.get(id) {
        Some(done) => {
          self.waiting.remove(id)
          match answer {
            Ok(json) => ignore(done.succeed((json, carried)))
            Err(e) => ignore(done.fail(e))
          }
        }
        None => ()
      }
    Other => ()
  }
}

///|
/// Runs `main` to its end on this thread with the shell keeping its files in `shell_dir` (none: no shell), answering
/// stdin's lines and the shell's answers as they come; the program's exit code.
pub fn run(shell_dir? : String, main : async (Host) -> Unit) -> Int {
  let dir = match shell_dir {
    Some(d) => cstr(d)
    None => b"\x00"
  }
  if start_ffi(dir) == 0 {
    note("the shell did not start")
    return 1
  }
  let rt = @effect.Runtime::live(now_ffi)
  let failed = Ref(false)
  rt.on_defect(e => {
    note("failed: \{e}")
    failed.val = true
  })
  let host = {
    rt,
    lines: @effect.Queue::unbounded(),
    input: @wire.Lines::new(),
    waiting: Map([]),
    next: 0L,
    sys: Map([]),
  }
  let fiber = rt.fork(() => main(host), name="main")
  while true {
    rt.tick()
    if fiber.is_done() {
      break
    }
    let wait = if !rt.idle() {
      0L
    } else {
      match rt.next_timer() {
        Some(at) => {
          let left = at - now_ffi()
          if left < 0L {
            0L
          } else {
            left
          }
        }
        None => -1L
      }
    }
    let first = wait_ffi(wait)
    if first.length() > 0 {
      host.dispatch(first)
      // what else came meanwhile, before the runtime's next turn (bounded so a flooding C thread cannot starve timers or fibers)
      let mut drained = 1
      while drained < 64 {
        let more = wait_ffi(0L)
        if more.length() == 0 {
          break
        }
        host.dispatch(more)
        drained += 1
      }
    }
  }
  match fiber.poll() {
    Some(Failed(e)) => {
      note("failed: \{e}")
      1
    }
    Some(_) => if failed.val { 1 } else { 0 }
    None => 1
  }
}

///|
extern "C" fn exit_ffi(code : Int) = "exit"

///|
/// Ends the program with `code`.
pub fn exit(code : Int) -> Unit {
  exit_ffi(code)
}

///|
extern "C" fn args_ffi() -> Bytes = "sfh_args"

///|
/// The program's arguments, its own name first (as the system gives them, whatever the target the program was made
/// for: host.c `sfh_args`).
pub fn args() -> Array[String] {
  let all = args_ffi()
  let out = []
  let mut start = 0
  for i = 0; i < all.length(); i = i + 1 {
    if all[i] == b'\x00' {
      out.push(@utf8.decode_lossy(all[start:i]))
      start = i + 1
    }
  }
  out
}

///|
/// A clock that never goes back, in ms from the machine's start (host.c `sfh_now`): it times waits, deadlines and
/// durations only, never a time of the world's (a date in January 1970). That is `wall_ms` or `epoch_ms`.
pub fn now() -> Int64 {
  now_ffi()
}

///|
/// Now, in ms since 1970, as the system's wall clock says (host.c `sfh_wall_ms`): it goes back or jumps when the
/// machine's time is set. What is shared with other programs (file times, a process's start) is in this.
pub fn wall_ms() -> Int64 {
  wall_ms_ffi()
}

///|
/// The wall's time and `now` as `epoch_ms` was first asked, taken then rather than as the program starts.
let epoch_anchor : Ref[(Int64, Int64)?] = Ref(None)

///|
/// Now, in ms since 1970, going on as `now` goes from the wall's time when first asked: what a part keeps or compares
/// as a time of the world's (a record's `at`, an expiry, a sample's time), never going back.
pub fn epoch_ms() -> Int64 {
  let (wall_0, mono_0) = match epoch_anchor.val {
    Some(a) => a
    None => {
      let a = (wall_ms_ffi(), now_ffi())
      epoch_anchor.val = Some(a)
      a
    }
  }
  wall_0 + (now_ffi() - mono_0)
}

///|
extern "C" fn pid_ffi() -> Int = "sfh_pid"

///|
/// This process's id.
pub fn pid() -> Int {
  pid_ffi()
}
