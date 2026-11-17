// Folders of the drive shown in a client, watched while they are (watch.ts): a client follows `GET /drive/watch` as
// events, told `changed` each time something in the folder changes, for as long as it keeps the stream open
// (`follow`). A client from before asks it again and again instead, answered as soon as something changes, else after
// a while with nothing (`changed`): each such asking has its own watch (`id`), kept a minute past its last asking, so a
// change between two askings is told at the next one, not lost. The clock and the system's watch are given (the
// program's runtime, and what watches a folder where it runs), as watch.ts is given a clock and `open`.

///|
/// How long one asking is held, nothing having changed.
pub let held_ms : Double = 25000.0

///|
/// How long a watch is kept with nobody asking.
pub let watch_kept_ms : Double = 60000.0

///|
/// The most watches at once.
pub let most_watches : Int = 256

///|
/// A burst of writes is one change.
pub let settle_ms : Double = 250.0

///|
/// A clock (ops/fibers.ts `Fibers`): its time, and `f` after `ms` (the function given back calls it off).
pub(all) struct Clock {
  now : () -> Double
  after : (Double, () -> Unit) -> () -> Unit
}

///|
/// A folder's watch as the system gives it (node:fs `watch`): closed with `close`.
pub(all) struct Watcher {
  close : () -> Unit
}

///|
priv struct Watched {
  watcher : Ref[Watcher?]
  mut changed : Bool
  waiting : Array[(Int, () -> Unit)]
  mut drop : (() -> Unit)?
  mut settle : (() -> Unit)?
  mut asked : Double
}

///|
/// watch.ts `FolderWatches`.
pub struct FolderWatches {
  priv by : Map[String, Watched]
  priv held : Double
  priv kept : Double
  priv time : Clock
  /// The system's watch of `dir`, told each change and when it fails (gone).
  priv open : (String, () -> Unit, () -> Unit) -> Watcher raise
  priv mut followers : Int
  priv mut wakes : Int
}

///|
pub fn FolderWatches::new(
  held? : Double = held_ms,
  kept? : Double = watch_kept_ms,
  time : Clock,
  open : (String, () -> Unit, () -> Unit) -> Watcher raise,
) -> FolderWatches {
  { by: {}, held, kept, time, open, followers: 0, wakes: 0 }
}

///|
fn FolderWatches::wake_id(self : FolderWatches) -> Int {
  self.wakes += 1
  self.wakes
}

///|
fn remove_wake(w : Watched, id : Int) -> Unit {
  for i, p in w.waiting {
    if p.0 == id {
      w.waiting.remove(i) |> ignore
      return
    }
  }
}

///|
/// watch.ts `changed`: whether the folder at `dir` changed since `id` last asked (at once if it did), else as soon as
/// it does, `held` at most; told to `done`.
pub fn FolderWatches::changed(
  self : FolderWatches,
  dir : String,
  id : String,
  done : (Bool) -> Unit,
) -> Unit {
  let key = "\{id}\u{0}\{dir}"
  let w = match self.by.get(key) {
    Some(w) => w
    None =>
      match self.watch(key, dir) {
        Some(made) => made
        None => {
          (self.time.after)(self.held, () => done(false)) |> ignore
          return
        }
      }
  }
  if w.drop is Some(f) {
    f()
  }
  w.drop = None
  w.asked = (self.time.now)()
  if w.changed {
    w.changed = false
    self.let_go(key, w)
    done(true)
    return
  }
  let wid = self.wake_id()
  let mut told = false
  let timer : Ref[() -> Unit] = { val: () => () }
  let finish = (yes : Bool) => {
    if told {
      return
    }
    told = true
    remove_wake(w, wid)
    if yes {
      w.changed = false
    }
    self.let_go(key, w)
    done(yes)
  }
  timer.val = (self.time.after)(self.held, () => finish(false))
  w.waiting.push((wid, fn() {
    (timer.val)()
    finish(true)
  }))
}

///|
/// watch.ts `follow`: tells `told` each time the folder at `dir` changes (a burst once), and once more if it goes,
/// until the function given back is called; None when it cannot be watched.
pub fn FolderWatches::follow(
  self : FolderWatches,
  dir : String,
  told : () -> Unit,
) -> (() -> Unit)? {
  self.followers += 1
  let key = "\u{1}\{self.followers}\u{0}\{dir}"
  guard self.watch(key, dir) is Some(w) else { return None }
  if w.drop is Some(f) {
    f()
  }
  w.drop = None
  let wid = self.wake_id()
  w.waiting.push((wid, told))
  Some(fn() {
    remove_wake(w, wid)
    self.close_one(key, w)
  })
}

///|
/// Every watch closed (the station stopping).
pub fn FolderWatches::close(self : FolderWatches) -> Unit {
  let all = self.by.to_array()
  for p in all {
    self.close_one(p.0, p.1)
  }
}

///|
/// How many watches are open.
pub fn FolderWatches::size(self : FolderWatches) -> Int {
  self.by.length()
}

///|
fn FolderWatches::watch(self : FolderWatches, key : String, dir : String) -> Watched? {
  if self.by.length() >= most_watches {
    let idle = self.by.to_array().filter(p => p.1.waiting.is_empty())
    let sorted = stable_sort(idle, (a, b) => {
      let d = a.1.asked - b.1.asked
      if d < 0.0 {
        -1
      } else if d > 0.0 {
        1
      } else {
        0
      }
    })
    if sorted.is_empty() {
      return None
    }
    self.close_one(sorted[0].0, sorted[0].1)
  }
  let w : Watched = {
    watcher: { val: None },
    changed: false,
    waiting: [],
    drop: None,
    settle: None,
    asked: (self.time.now)(),
  }
  let on_change = () => if w.settle is None {
    w.settle = Some(
      (self.time.after)(settle_ms, fn() {
        w.settle = None
        if w.waiting.length() > 0 {
          for p in w.waiting.copy() {
            (p.1)()
          }
        } else {
          w.changed = true
        }
      }),
    )
  }
  let on_error = () => {
    self.close_one(key, w)
    for p in w.waiting.copy() {
      (p.1)()
    }
  }
  let watcher = (self.open)(dir, on_change, on_error) catch { _ => return None }
  w.watcher.val = Some(watcher)
  self.by.set(key, w)
  Some(w)
}

///|
fn FolderWatches::let_go(self : FolderWatches, key : String, w : Watched) -> Unit {
  if w.waiting.length() > 0 || !(self.by.get(key) is Some(x) && physical_equal(x, w)) {
    return
  }
  if w.drop is Some(f) {
    f()
  }
  w.drop = Some((self.time.after)(self.kept, () => self.close_one(key, w)))
}

///|
fn FolderWatches::close_one(self : FolderWatches, key : String, w : Watched) -> Unit {
  if self.by.get(key) is Some(x) && physical_equal(x, w) {
    self.by.remove(key)
  }
  if w.drop is Some(f) {
    f()
  }
  if w.settle is Some(f) {
    f()
  }
  if w.watcher.val is Some(x) {
    (x.close)()
  }
}
