// A TCP connection to any address and a serial port (live_p5_4_io.c): what the shell's `tcp.open` (127.0.0.1 only)
// does not reach, a thread of its own reading each, what it read told on the program's queue (`Host::sys_listen`).

///|
#borrow(host)
extern "C" fn p54io_tcp_open_ffi(id : Int64, host : Bytes, port : Int) -> Int = "p54io_tcp_open"

///|
#borrow(path)
extern "C" fn p54io_serial_open_ffi(id : Int64, path : Bytes, baud : Int) -> Int = "p54io_serial_open"

///|
#borrow(data)
extern "C" fn p54io_write_ffi(slot : Int, data : Bytes) -> Int = "p54io_write"

///|
extern "C" fn p54io_end_ffi(slot : Int) = "p54io_end"

///|
extern "C" fn p54io_close_ffi(slot : Int) = "p54io_close"

///|
#borrow(path, line)
extern "C" fn p54io_unix_rpc_ffi(path : Bytes, line : Bytes, lines : Int, timeout_ms : Int) -> Bytes = "p54io_unix_rpc"

///|
/// A connection or a port of live_p5_4_io.c's: what it read, in order, its end None. Its slot is let go once it is
/// closed, which its end does too.
priv struct P54Net {
  slot : Int
  came : @effect.Queue[Bytes?]
  mut ended : Bool
  mut closed : Bool
}

///|
/// Opened by `open` (given the listener's id): once it says it is connected; raises why it is not. Called off before
/// then (a timeout, the caller interrupted), its slot is let go and what it listened to with it: a connection made
/// after that is closed by its thread (live_p5_4_io.c checks the slot is still this one's).
async fn p54_net_open(host : @host.Host, open : (Int64) -> Int) -> P54Net {
  let came : @effect.Queue[Bytes?] = @effect.Queue::unbounded()
  let ready : @effect.Deferred[String?] = @effect.Deferred::new()
  let listened = Ref(0L)
  let listening = Ref(true)
  let stop_listening = () => if listening.val {
    listening.val = false
    host.sys_done(listened.val)
  }
  let id = host.sys_listen(b => {
    if b.length() == 0 {
      return
    }
    let rest = b[1:].to_owned()
    match b[0] {
      b'c' => ignore(ready.succeed(None))
      b'f' => {
        ignore(ready.succeed(Some(@utf8.decode_lossy(rest))))
        stop_listening()
      }
      b'd' => ignore(came.try_offer(Some(rest)))
      b'e' => {
        ignore(came.try_offer(None))
        stop_listening()
      }
      _ => ()
    }
  })
  listened.val = id
  let slot = open(id)
  let opened = Ref(false)
  defer {
    if !opened.val {
      if slot >= 0 {
        p54io_close_ffi(slot)
      }
      stop_listening()
    }
  }
  if slot < 0 {
    let said = (try { Ok(ready.poll()) } catch { e => Err(e) })
    match said {
      Ok(Some(Some(why))) => raise Failure(why)
      _ => raise Failure("no room for another connection")
    }
  }
  match ready.wait() {
    None => ()
    Some(why) => raise Failure(why)
  }
  opened.val = true
  { slot, came, ended: false, closed: false }
}

///|
/// A TCP connection to `host`:`port` (a name or an address of any network this machine is on).
async fn p54_net_tcp(host : @host.Host, to : String, port : Int) -> P54Net {
  p54_net_open(host, id => p54io_tcp_open_ffi(id, cstr(to), port))
}

///|
/// A serial port opened raw at `baud`.
async fn p54_net_serial(host : @host.Host, path : String, baud : Int) -> P54Net {
  p54_net_open(host, id => p54io_serial_open_ffi(id, cstr(path), baud))
}

///|
async fn P54Net::read(self : P54Net) -> Bytes? {
  if self.ended {
    return None
  }
  let got = self.came.take()
  if got is None {
    // (its end: the slot let go, its descriptor closed)
    self.ended = true
    self.close()
  }
  got
}

///|
fn P54Net::write(self : P54Net, b : Bytes) -> Bool {
  p54io_write_ffi(self.slot, b) != 0
}

///|
fn P54Net::end(self : P54Net) -> Unit {
  p54io_end_ffi(self.slot)
}

///|
fn P54Net::close(self : P54Net) -> Unit {
  if !self.closed {
    self.closed = true
    p54io_close_ffi(self.slot)
  }
}

///|
/// `request` written on still.fail Helper's socket at once (macOS), what it answers read until `lines` lines came (0:
/// until it ends); empty where it gave nothing in time.
fn p54_unix_rpc(path : String, request : Bytes, lines : Int, timeout_ms : Int) -> Bytes {
  p54io_unix_rpc_ffi(cstr(path), request, lines, timeout_ms)
}

///|
/// How many slots of live_p5_4_io.c are held now (a test's: what an end lets go).
extern "C" fn p54io_held_ffi() -> Int = "p54io_held"
