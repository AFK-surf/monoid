// What the TypeScript's promises and sockets are here: a piece of work shared by whoever asks for it while it goes
// (`this.#x ??= work().finally(() => (this.#x = null))`), and a connection as node:net's Socket is to its listeners
// (each event told to every one, what comes held while it is paused or nobody reads it).

///|
/// One piece of work at a time, shared by whoever asks while it goes; let go of once it is done, before those
/// waiting on it go on.
struct Shared[T] {
  mut going : @effect.Deferred[T]?
}

///|
fn[T] Shared::new() -> Shared[T] {
  { going: None }
}

///|
/// The work going, or `work` started (on a fiber of its own) and then gone.
fn[T] Shared::start(self : Shared[T], io : Io, work : async () -> T) -> @effect.Deferred[T] {
  match self.going {
    Some(d) => d
    None => {
      let d : @effect.Deferred[T] = @effect.Deferred::new()
      self.going = Some(d)
      (io.spawn)(async fn() {
        // (called off meanwhile, the work is let go and its waiters told: a later ask starts it anew)
        defer {
          match self.going {
            Some(x) if physical_equal(x, d) => self.going = None
            _ => ()
          }
          if !d.is_done() {
            ignore(d.fail(fail("the work was called off")))
          }
        }
        let result = try Ok(work()) catch { e => Err(e) }
        match self.going {
          Some(x) if physical_equal(x, d) => self.going = None
          _ => ()
        }
        match result {
          Ok(v) => ignore(d.succeed(v))
          Err(e) => ignore(d.fail(e))
        }
      })
      d
    }
  }
}

///|
fn[T] Shared::is_going(self : Shared[T]) -> Bool {
  self.going is Some(_)
}

///|
/// A settled value (a promise resolved or rejected) told at once to who waits for it now or later.
fn[T] settled(v : T) -> @effect.Deferred[T] {
  let d = @effect.Deferred::new()
  ignore(d.succeed(v))
  d
}

///|
/// A connection as node:net's Socket is to these parts: its listeners told each event, in the order they listened;
/// what comes kept while it is paused or nobody reads it (as a socket not read keeps it).
pub struct Sock {
  priv mut conn : Conn?
  priv data_l : Array[(Int, (Bytes) -> Unit)]
  priv close_l : Array[(Int, () -> Unit)]
  priv error_l : Array[(Int, (String) -> Unit)]
  priv connect_l : Array[(Int, () -> Unit)]
  priv kept : Array[Bytes]
  priv mut paused : Bool
  priv mut is_destroyed : Bool
  priv mut next : Int
}

///|
fn Sock::new() -> Sock {
  {
    conn: None,
    data_l: [],
    close_l: [],
    error_l: [],
    connect_l: [],
    kept: [],
    paused: false,
    is_destroyed: false,
    next: 0,
  }
}

///|
/// `net.createConnection(target)`: connecting, its events told as they come.
pub fn Sock::create(io : Io, target : Target) -> Sock {
  let s = Sock::new()
  s.conn = Some(
    (io.net.connect)(target, {
      connect: () => for l in s.connect_l.copy() {
        (l.1)()
      },
      data: b => s.heard(b),
      error: e => for l in s.error_l.copy() {
        (l.1)(e)
      },
      close: () => {
        for l in s.close_l.copy() {
          (l.1)()
        }
      },
    }),
  )
  s
}

///|
fn Sock::id(self : Sock) -> Int {
  self.next += 1
  self.next
}

///|
fn Sock::heard(self : Sock, b : Bytes) -> Unit {
  if self.paused || self.data_l.length() == 0 {
    self.kept.push(b)
    return
  }
  for l in self.data_l.copy() {
    (l.1)(b)
  }
}

///|
fn Sock::flow(self : Sock) -> Unit {
  while !self.paused && self.data_l.length() > 0 && self.kept.length() > 0 {
    let b = self.kept.remove(0)
    for l in self.data_l.copy() {
      (l.1)(b)
    }
  }
}

///|
/// `socket.on("data", f)`: reading from now (what was kept first), unless it is paused.
pub fn Sock::on_data(self : Sock, f : (Bytes) -> Unit) -> Int {
  let id = self.id()
  self.data_l.push((id, f))
  self.flow()
  id
}

///|
pub fn Sock::on_close(self : Sock, f : () -> Unit) -> Int {
  let id = self.id()
  self.close_l.push((id, f))
  id
}

///|
pub fn Sock::on_error(self : Sock, f : (String) -> Unit) -> Int {
  let id = self.id()
  self.error_l.push((id, f))
  id
}

///|
pub fn Sock::on_connect(self : Sock, f : () -> Unit) -> Int {
  let id = self.id()
  self.connect_l.push((id, f))
  id
}

///|
/// A listener taken off (`socket.off`).
pub fn Sock::off(self : Sock, id : Int) -> Unit {
  take_out(self.data_l, id)
  take_out(self.close_l, id)
  take_out(self.error_l, id)
  take_out(self.connect_l, id)
}

///|
pub fn Sock::pause(self : Sock) -> Unit {
  self.paused = true
  match self.conn {
    Some(c) => (c.pause)()
    None => ()
  }
}

///|
pub fn Sock::flow_again(self : Sock) -> Unit {
  self.paused = false
  match self.conn {
    Some(c) => (c.flow_again)()
    None => ()
  }
  self.flow()
}

///|
pub fn Sock::write(self : Sock, b : Bytes) -> Unit {
  match self.conn {
    Some(c) => (c.write)(b)
    None => ()
  }
}

///|
pub fn Sock::destroy(self : Sock) -> Unit {
  self.is_destroyed = true
  match self.conn {
    Some(c) => (c.destroy)()
    None => ()
  }
}

///|
pub fn Sock::destroyed(self : Sock) -> Bool {
  self.is_destroyed ||
  (match self.conn {
    Some(c) => (c.destroyed)()
    None => false
  })
}

///|
/// A connection to `target`, once it is open; its failure as Node says it.
pub async fn dial(io : Io, target : Target) -> Sock {
  let s = Sock::create(io, target)
  let d : @effect.Deferred[Unit] = @effect.Deferred::new()
  let on_err = s.on_error(e => {
    // (Node's words, `connect ENOENT /path`: its code the second)
    let words = e.split(" ").map(w => w.to_string()).collect()
    ignore(d.fail(Failed(e, if words.length() > 1 { jo([("code", js(words[1]))]) } else { Null })))
  })
  ignore(
    s.on_connect(() => {
      s.off(on_err)
      ignore(d.succeed(()))
    }),
  )
  d.wait()
  s
}

///|
/// Which separator a path is written with: Windows' where it starts as a share (`\\`) or a drive (`X:`), or has `\`
/// and no `/`; else POSIX's.
fn sep_of(path : String) -> String {
  let cs = path.to_array()
  let drive = cs.length() >= 2 && cs[1] == ':' && ((cs[0] >= 'A' && cs[0] <= 'Z') || (cs[0] >= 'a' && cs[0] <= 'z'))
  if path.has_prefix("\\\\") || drive || (path.contains("\\") && !path.contains("/")) {
    "\\"
  } else {
    "/"
  }
}

///|
/// `path.join(…)` as the machine the first part is written for has it (path.win32's for a Windows path, path.posix's
/// else).
fn pj(parts : Array[String]) -> String {
  let first = parts.iter().find_first(p => p != "").unwrap_or("")
  @nodepath.join(sep_of(first), parts)
}

///|
/// Work done one after another (a promise chain: `this.#x = this.#x.then(work)`), each step waiting for the one
/// before it to settle, whatever it came to.
struct Chain {
  mut last : @effect.Deferred[Unit]
}

///|
fn Chain::new() -> Chain {
  { last: settled(()) }
}

///|
/// `work` after what is chained already; the chain goes on after it.
async fn[T] Chain::then(self : Chain, io : Io, work : async () -> T) -> T {
  let before = self.last
  let mine : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.last = mine
  let result : @effect.Deferred[T] = @effect.Deferred::new()
  (io.spawn)(async fn() {
    before.wait() catch { _ => () }
    match (try Ok(work()) catch { e => Err(e) }) {
      Ok(v) => ignore(result.succeed(v))
      Err(e) => ignore(result.fail(e))
    }
    ignore(mine.succeed(()))
  })
  result.wait()
}

///|
/// `work` chained after the rest, not waited on.
fn Chain::after(self : Chain, io : Io, work : async () -> Unit) -> Unit {
  let before = self.last
  let mine : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.last = mine
  (io.spawn)(async fn() {
    before.wait() catch { _ => () }
    work() catch { _ => () }
    ignore(mine.succeed(()))
  })
}

///|
/// Until what is chained now has settled.
async fn Chain::idle(self : Chain) -> Unit {
  self.last.wait() catch { _ => () }
}
