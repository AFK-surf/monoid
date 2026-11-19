// What the drivers wait on, as the TypeScript's promises and timers are: a `Later` is a value or an error to come, its
// continuations run in turn by the loop it belongs to (as JavaScript's microtasks), never in the middle of what
// settled it. Time is the loop's clock (`Clock`): a station's, or a test's that moves only as it is told.

///|
pub(all) suberror DriverError {
  /// What failed, in the TypeScript's words.
  Failed(String)
  /// What is said to people by a key of the station's words (ops/i18n.ts `Said`).
  Said(String)
  /// A login's renewal refused (accounts/console.ts `RenewRefused`).
  RenewRefused(String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for DriverError with output(self, logger) {
  match self {
    Failed(m) => logger.write_string(m)
    Said(key) => logger.write_string(key)
    RenewRefused(m) => logger.write_string(m)
  }
}

///|
/// An error's words: a `Said`'s key.
pub fn words_of(e : Error) -> String {
  match e {
    Failed(m) => m
    Said(k) => k
    RenewRefused(m) => m
    _ => "\{e}"
  }
}

///|
/// Continuations to run, in turn, and timers by when they are due.
pub struct Loop {
  queue : Array[() -> Unit]
  timers : Array[(Double, Int, () -> Unit)]
  mut seq : Int
  mut now : Double
}

///|
pub fn Loop::new(now? : Double = 0.0) -> Loop {
  { queue: [], timers: [], seq: 0, now }
}

///|
/// `f` once what is queued before it ran.
pub fn Loop::soon(self : Loop, f : () -> Unit) -> Unit {
  self.queue.push(f)
}

///|
/// `f` in `ms` (`wall.after`): what calls it off.
pub fn Loop::after(self : Loop, ms : Double, f : () -> Unit) -> () -> Unit {
  self.seq += 1
  let id = self.seq
  self.timers.push((self.now + ms, id, f))
  () => {
    let at = self.timers.search_by(t => t.1 == id)
    if at is Some(i) {
      self.timers.remove(i) |> ignore
    }
  }
}

///|
/// Runs what is queued until nothing is.
pub fn Loop::run(self : Loop) -> Unit {
  while self.queue.length() > 0 {
    let f = self.queue.remove(0)
    f()
  }
}

///|
/// The clock moved on to `to`: each timer due by then run at its time, what it queued after it.
pub fn Loop::advance(self : Loop, to : Double) -> Unit {
  self.run()
  while true {
    let mut best : Int? = None
    for i, t in self.timers {
      if t.0 <= to {
        match best {
          Some(j) =>
            if t.0 < self.timers[j].0 ||
              (t.0 == self.timers[j].0 && t.1 < self.timers[j].1) {
              best = Some(i)
            }
          None => best = Some(i)
        }
      }
    }
    guard best is Some(i) else { break }
    let (at, _, f) = self.timers.remove(i)
    if at > self.now {
      self.now = at
    }
    f()
    self.run()
  }
  if to > self.now {
    self.now = to
  }
}

///|
pub enum LaterState[T] {
  Waiting
  Done(T)
  Broke(Error)
}

///|
/// A value or an error to come.
pub struct Later[T] {
  lp : Loop
  mut state : LaterState[T]
  then : Array[(Result[T, Error]) -> Unit]
}

///|
pub fn[T] Later::new(lp : Loop) -> Later[T] {
  { lp, state: Waiting, then: [] }
}

///|
pub fn[T] Later::ok(lp : Loop, v : T) -> Later[T] {
  { lp, state: Done(v), then: [] }
}

///|
pub fn[T] Later::fail(lp : Loop, e : Error) -> Later[T] {
  { lp, state: Broke(e), then: [] }
}

///|
pub fn[T] Later::settled(self : Later[T]) -> Bool {
  !(self.state is Waiting)
}

///|
pub fn[T] Later::tell(self : Later[T], r : Result[T, Error]) -> Unit {
  let waiting = self.then.copy()
  self.then.clear()
  for k in waiting {
    self.lp.soon(() => k(r))
  }
}

///|
pub fn[T] Later::resolve(self : Later[T], v : T) -> Unit {
  guard self.state is Waiting else { return }
  self.state = Done(v)
  self.tell(Ok(v))
}

///|
pub fn[T] Later::reject(self : Later[T], e : Error) -> Unit {
  guard self.state is Waiting else { return }
  self.state = Broke(e)
  self.tell(Err(e))
}

///|
/// `k` with how it ended, once it has.
pub fn[T] Later::on(self : Later[T], k : (Result[T, Error]) -> Unit) -> Unit {
  match self.state {
    Waiting => self.then.push(k)
    Done(v) => self.lp.soon(() => k(Ok(v)))
    Broke(e) => self.lp.soon(() => k(Err(e)))
  }
}

///|
/// `.then(f)`: what `f` makes of the value, an error carried on.
pub fn[T, U] Later::map(self : Later[T], f : (T) -> U raise) -> Later[U] {
  let out = Later::new(self.lp)
  self.on(r => match r {
    Ok(v) =>
      match (try Ok(f(v)) catch { e => Err(e) }) {
        Ok(u) => out.resolve(u)
        Err(e) => out.reject(e)
      }
    Err(e) => out.reject(e)
  })
  out
}

///|
/// `.then(f)` where `f` makes another to wait on.
pub fn[T, U] Later::bind(self : Later[T], f : (T) -> Later[U] raise) -> Later[U] {
  let out = Later::new(self.lp)
  self.on(r => match r {
    Ok(v) =>
      match (try Ok(f(v)) catch { e => Err(e) }) {
        Ok(next) =>
          next.on(r2 => match r2 {
            Ok(u) => out.resolve(u)
            Err(e) => out.reject(e)
          })
        Err(e) => out.reject(e)
      }
    Err(e) => out.reject(e)
  })
  out
}

///|
/// `.catch(f)`.
pub fn[T] Later::recover(self : Later[T], f : (Error) -> Later[T] raise) -> Later[T] {
  let out = Later::new(self.lp)
  self.on(r => match r {
    Ok(v) => out.resolve(v)
    Err(e) =>
      match (try Ok(f(e)) catch { e => Err(e) }) {
        Ok(next) =>
          next.on(r2 => match r2 {
            Ok(u) => out.resolve(u)
            Err(e2) => out.reject(e2)
          })
        Err(e2) => out.reject(e2)
      }
  })
  out
}

///|
/// `.finally(f)`.
pub fn[T] Later::always(self : Later[T], f : () -> Unit) -> Later[T] {
  let out = Later::new(self.lp)
  self.on(r => {
    f()
    match r {
      Ok(v) => out.resolve(v)
      Err(e) => out.reject(e)
    }
  })
  out
}

///|
/// Nothing, done.
pub fn done(lp : Loop) -> Later[Unit] {
  Later::ok(lp, ())
}

///|
/// `Promise.all`.
pub fn[T] all(lp : Loop, items : Array[Later[T]]) -> Later[Array[T]] {
  let out = Later::new(lp)
  let got : Array[T?] = items.map(_ => None)
  let mut left = items.length()
  if left == 0 {
    out.resolve([])
    return out
  }
  for i, it in items {
    it.on(r => match r {
      Ok(v) => {
        got[i] = Some(v)
        left -= 1
        if left == 0 {
          out.resolve(got.map(x => x.unwrap()))
        }
      }
      Err(e) => out.reject(e)
    })
  }
  out
}

///|
/// Steps one after another: `step(i)` for each `i` below `count`, each once the one before it is done.
pub fn each_in_turn(lp : Loop, count : Int, step : (Int) -> Later[Unit]) -> Later[Unit] {
  let out = Later::new(lp)
  fn go(i : Int) -> Unit {
    if i >= count {
      out.resolve(())
      return
    }
    step(i).on(r => match r {
      Ok(_) => go(i + 1)
      Err(e) => out.reject(e)
    })
  }

  go(0)
  out
}
