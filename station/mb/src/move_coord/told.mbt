// Told steps (station/src/move/told.ts; move/AGENTS.md): what one station asks of another in a move whose work grows
// with a chat or a repository is never done inside the request. The station asked starts the step and answers at
// once (`under`), or, where it ended already, gives its result again; the step tells its asker how it goes
// (`move.told`) every TOLD_EVERY_MS while it works, and its end until that is answered. The asker waits on its end
// however long it takes; told nothing for TOLD_SILENT_MS, or heard from again after a silence, it asks the same step
// again, and only that ask failing fails it. A step is known by a key its asker makes, the same in every ask of it.

///|
pub let told_every_ms : Int = 5_000

///|
pub let told_silent_ms : Int = 3 * told_every_ms

///|
let heard_again_ms : Int = 2 * told_every_ms

///|
let ended_most : Int = 256

///|
/// A failed step is tried again after this, twice as long each time, up to RETRY_MOST_MS (replica/retire.ts).
pub let retry_ms : Int = 10_000

///|
pub let retry_most_ms : Int = 10 * 60_000

///|
/// The station's clock (ops/fibers.ts `Fibers`): its time, a deadline, a beat (`f` every `ms`, the first `ms` from
/// now, each after the last ended), and work that goes on by itself; each of the first two given back what stops it.
pub(all) struct Clock {
  now : () -> Int64
  after : (Int, () -> Unit) -> (() -> Unit)
  every : (Int, async () -> Unit) -> (() -> Unit)
  spawn : (async () -> Unit) -> Unit
}

///|
/// How this station asks another: a request, with the bytes that follow it where it carries some.
pub(all) struct Ask {
  ask : async (String, J, Bytes_?) -> J
}

///|
/// Bytes a request carries (mesh/bus.ts `withBytes`): a file's, from `offset`, `size` of them (mesh/files.ts
/// `fileBytes`), or those that came with a request, read a piece at a time.
pub(all) enum Bytes_ {
  FileBytes(String, Int64, Int64)
  Came(async () -> Bytes?)
}

///|
/// What a told step's request answers while it works.
pub fn is_under(answer : J, key : String) -> Bool {
  is_true(get(Some(answer), "under")) && text(get(Some(answer), "told")) == Some(key)
}

///|
priv struct Waiter {
  to : String
  key : String
  make : () -> (J, Bytes_?)
  progress : ((J) -> Unit)?
  done : @effect.Deferred[J]
  mut silent : () -> Unit
  mut heard : Int64
  mut asking : Bool
  mut over : Bool
}

///|
priv enum Step {
  Running
  Ended(J?, String?)
}

///|
pub(all) struct ToldDeps {
  clock : Clock
  ask : Ask
  hold : (() -> (() -> Unit))?
  say : Say
}

///|
pub struct Told {
  priv d : ToldDeps
  priv waiting : Map[String, Waiter]
  priv steps : Map[String, Step]
  priv running : Map[String, @effect.Deferred[Unit]]
  priv stops : Array[(Int, () -> Unit)]
  priv mut next_stop : Int
  priv mut closed : Bool
}

///|
pub fn Told::new(d : ToldDeps) -> Told {
  { d, waiting: {}, steps: {}, running: {}, stops: [], next_stop: 0, closed: false }
}

///|
fn Told::add_stop(self : Told, f : () -> Unit) -> Int {
  self.next_stop += 1
  self.stops.push((self.next_stop, f))
  self.next_stop
}

///|
fn Told::drop_stop(self : Told, id : Int) -> Unit {
  match self.stops.search_by(p => p.0 == id) {
    Some(i) => ignore(self.stops.remove(i))
    None => ()
  }
}

// ── the station that asks ──

///|
/// Step `key` asked of station `to` (`make` makes its request anew each time), waited on to its end: its result, or
/// what it failed with. `progress`: what the step told of how far it is.
pub async fn Told::asked(
  self : Told,
  to : String,
  key : String,
  make : () -> (J, Bytes_?),
  progress? : (J) -> Unit,
) -> J {
  if self.closed {
    raise Failed("this station is stopping")
  }
  let at = "\{to}\n\{key}"
  let w : Waiter = {
    to,
    key,
    make,
    progress,
    done: @effect.Deferred::new(),
    silent: () => (),
    heard: (self.d.clock.now)(),
    asking: false,
    over: false,
  }
  self.waiting[at] = w
  self.ask_again(w)
  w.done.wait()
}

///|
fn Told::end(self : Told, w : Waiter) -> Unit {
  w.over = true
  (w.silent)()
  let at = "\{w.to}\n\{w.key}"
  match self.waiting.get(at) {
    Some(x) if physical_equal(x, w) => self.waiting.remove(at)
    _ => ()
  }
}

///|
fn Told::resolve(self : Told, w : Waiter, v : J) -> Unit {
  if w.done.is_done() {
    return
  }
  self.end(w)
  ignore(w.done.succeed(v))
}

///|
fn Told::reject(self : Told, w : Waiter, e : Error) -> Unit {
  if w.done.is_done() {
    return
  }
  self.end(w)
  ignore(w.done.fail(e))
}

///|
fn Told::ask_again(self : Told, w : Waiter) -> Unit {
  if w.over || w.asking {
    return
  }
  w.asking = true
  (w.silent)()
  let (request, bytes) = (w.make)()
  (self.d.clock.spawn)(async fn() {
    let answer = try Ok((self.d.ask.ask)(w.to, request, bytes)) catch { e => Err(e) }
    w.asking = false
    if w.over {
      return
    }
    match answer {
      Ok(a) => if is_under(a, w.key) { self.arm(w) } else { self.resolve(w, a) }
      Err(e) => self.reject(w, e)
    }
  })
}

///|
fn Told::arm(self : Told, w : Waiter) -> Unit {
  (w.silent)()
  // timer: a deadline (told nothing that long, the step is asked again)
  w.silent = (self.d.clock.after)(told_silent_ms, () => self.ask_again(w))
}

///|
/// What a station running a step of this one's told (`move.told`): how far it is, or its end.
pub fn Told::heard(self : Told, peer : String, request : J) -> J {
  let key = text(get(Some(request), "told")).unwrap_or("")
  let ok = jo([("ok", jb(true))])
  let w = match self.waiting.get("\{peer}\n\{key}") {
    Some(w) if !w.over => w
    _ => return ok
  }
  w.heard = (self.d.clock.now)()
  if is_true(get(Some(request), "ended")) {
    match get(Some(request), "error") {
      Some(Str(u)) => self.reject(w, Refused(@jsjson.sanitize_str(u)))
      _ =>
        self.resolve(w, match get(Some(request), "result") {
          Some(r) => r
          None => Null
        })
    }
    return ok
  }
  if present(get(Some(request), "progress")) {
    match w.progress {
      Some(f) => f(get(Some(request), "progress").unwrap())
      None => ()
    }
  }
  if !w.asking {
    self.arm(w)
  }
  ok
}

///|
/// Step `key` of station `to` no longer waited on: failed here with `error` at once.
pub fn Told::let_go(self : Told, to : String, key : String, error : Error) -> Unit {
  match self.waiting.get("\{to}\n\{key}") {
    Some(w) => self.reject(w, error)
    None => ()
  }
}

///|
/// Station `peer` heard from: each step of it waited on with no word for a while asked again now.
pub fn Told::reached(self : Told, peer : String) -> Unit {
  let now = (self.d.clock.now)()
  for w in self.waiting.values().collect() {
    if w.to == peer && now - w.heard >= heard_again_ms.to_int64() {
      w.heard = now
      self.ask_again(w)
    }
  }
}

// ── the station asked ──

///|
/// Step `key` of station `origin`'s asked of this one: started (`work`, given how to say how far it is; `started`
/// told as it starts), answered at once as under way; the same asked again while it runs, under way; ended, its result
/// again (its error refused again). `measure`: how far it is, asked at each beat.
pub fn Told::run(
  self : Told,
  origin : String,
  key : String,
  work : async ((J) -> Unit) -> J?,
  measure? : async () -> J,
  started? : () -> Unit,
) -> J raise MoveError {
  let at = "\{origin}\n\{key}"
  let under = jo([("under", jb(true)), ("told", js(key))])
  match self.steps.get(at) {
    Some(Running) => return under
    Some(Ended(result, error)) => {
      if error is Some(e) {
        raise Refused(e)
      }
      return result.unwrap_or(Null)
    }
    None => ()
  }
  if self.closed {
    raise Refused("this station is stopping: ask again in a moment")
  }
  self.steps[at] = Running
  let let_go = match self.d.hold {
    Some(h) => h()
    None => () => ()
  }
  let told : Ref[J?] = Ref(None)
  let tell = async fn(body : J) -> J {
    (self.d.ask.ask)(
      origin,
      spread(jo([("method", js("move.told")), ("told", js(key))]), body),
      None,
    )
  }
  // timer: a heartbeat (a step under way tells it still works)
  let beat = (self.d.clock.every)(told_every_ms, async fn() {
    if self.closed {
      return
    }
    match measure {
      Some(m) => told.val = Some(m()) catch { _ => told.val }
      None => ()
    }
    ignore(
      (try Ok(tell(jo([("progress", told.val.unwrap_or(jo([])))]))) catch { e => Err(e) }),
    )
  })
  let beat_id = self.add_stop(beat)
  let done : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.running[at] = done
  match started {
    Some(f) => f()
    None => ()
  }
  (self.d.clock.spawn)(async fn() {
    let (result, error) = {
      let r = try Ok(work(p => told.val = Some(p))) catch { e => Err(e) }
      beat()
      self.drop_stop(beat_id)
      let_go()
      match r {
        Ok(v) => (v, None)
        Err(e) => (None, Some(message_of(e)))
      }
    }
    self.steps[at] = Ended(result, error)
    if self.steps.length() > ended_most {
      for k in self.steps.keys().collect() {
        if self.steps.length() <= ended_most {
          break
        }
        if self.steps.get(k) is Some(Ended(_, _)) {
          self.steps.remove(k)
        }
      }
    }
    match error {
      Some(e) =>
        self.d.say.log(
          "info",
          "a step asked of this station failed",
          jo([
            ("station", js(slice_to(origin, 12))),
            ("step", js(key.split(":").next().map(v => v.to_string()).unwrap_or(""))),
            ("error", js(e)),
          ]),
        )
      None => ()
    }
    let end = match error {
      Some(e) => jo([("ended", jb(true)), ("error", js(e))])
      None =>
        match result {
          Some(r) => jo([("ended", jb(true)), ("result", r)])
          None => jo([("ended", jb(true))])
        }
    }
    self.tell_end(tell, end, 0)
    match self.running.get(at) {
      Some(x) if physical_equal(x, done) => self.running.remove(at)
      _ => ()
    }
    ignore(done.succeed(()))
  })
  under
}

///|
/// A step's end told until it is answered (a refusal is an answer), with the backoff a hand-over's retries keep.
async fn Told::tell_end(
  self : Told,
  tell : async (J) -> J,
  body : J,
  n : Int,
) -> Unit {
  if self.closed {
    return
  }
  match (try Ok(tell(body)) catch { e => Err(e) }) {
    Ok(_) => ()
    Err(e) => {
      if is_refused(e) || self.closed {
        return
      }
      let mut wait = retry_ms
      for _ in 0..<n {
        wait = wait * 2
        if wait >= retry_most_ms {
          wait = retry_most_ms
          break
        }
      }
      if wait > retry_most_ms {
        wait = retry_most_ms
      }
      let id : Ref[Int] = Ref(0)
      // timer: a retry after a failure
      let again = (self.d.clock.after)(wait, () => (self.d.clock.spawn)(async fn() {
        self.drop_stop(id.val)
        self.tell_end(tell, body, n + 1)
      }))
      id.val = self.add_stop(again)
    }
  }
}

///|
/// The steps under way here brought to their end (a test's).
pub async fn Told::settle(self : Told) -> Unit {
  while self.running.length() > 0 {
    for d in self.running.values().collect() {
      d.wait()
    }
  }
}

///|
/// This process stopping: nothing more told or waited on.
pub fn Told::close(self : Told) -> Unit {
  self.closed = true
  for s in self.stops.copy() {
    (s.1)()
  }
  self.stops.clear()
  for w in self.waiting.values().collect() {
    self.reject(w, Failed("this station is stopping"))
  }
}
