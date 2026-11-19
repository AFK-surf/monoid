// The station's endpoint kept by the MoonBit front (station/src/mesh/front.ts; the front is mb/src/front/mesh.mbt): what
// binding an endpoint gives is asked of the front on its Unix socket, a JSON object a line both ways, and each stream
// comes as a Unix socket of its own to this program's (its head the connection's id and the stream's), its bytes as
// frames: a length (4 bytes, big-endian) then the bytes, its end or what failed it as a frame of its own; what is
// written the same, its end finishing the stream. The front keeps the endpoint across a station's handovers: the next
// one binds the same, and the devices' connections come to it. Where the front goes (the launcher starts another), the
// link is made again, a while after each try that fails, and what the endpoint was told given again.
//
// The machine's sockets are given (`Sockets`: the shell's `unix.open`, `unix.listen`, `tcp.*`), and so is the wait
// between tries, so a test's front and clock are the ones it runs on.

///|
/// What frames say besides a length (client/shell's PIPE_END, PIPE_FAILED); the longest a frame written here is.
pub let front_end : UInt = 0xfffffffeU

///|
pub let front_failed : UInt = 0xfffffffdU

///|
pub let frame_most : Int = 1 << 20

///|
/// One socket of this machine's: read as it comes (None at its end), written, its sending half ended, let go.
pub(all) struct Sock {
  read : async () -> Bytes?
  write : async (Bytes) -> Unit
  end : async () -> Unit
  destroy : () -> Unit
}

///|
/// A Unix socket listened on: the sockets that connect to it, as they come (None once it is closed).
pub(all) struct SockListener {
  accept : async () -> Sock?
  close : () -> Unit
}

///|
/// This machine's Unix sockets (`node:net` for the TypeScript).
pub(all) struct Sockets {
  connect : async (String) -> Sock
  listen : async (String) -> SockListener
  remove : async (String) -> Unit
}

///|
/// The shell's Unix sockets.
pub fn shell_sockets(host : @host.Host) -> Sockets {
  let sock = (id : Json) => {
    let gone = Ref(false)
    let s : Sock = {
      read: async fn() -> Bytes? {
        let (said, bytes) = host.shell("tcp.read", { "id": id })
        match (said, bytes) {
          ({ "end": True, .. }, _) => None
          (_, Some(b)) => Some(b)
          _ => None
        }
      },
      write: async fn(b) { ignore(host.shell("tcp.write", { "id": id }, bytes=b)) },
      end: async fn() { ignore(host.shell("tcp.end", { "id": id })) },
      destroy: () => if !gone.val {
        gone.val = true
        ignore(host.rt.fork(() => ignore(host.shell("tcp.close", { "id": id })) catch { _ => () }))
      },
    }
    s
  }
  {
    connect: async fn(path) {
      let (said, _) = host.shell("unix.open", { "path": jstr(path) })
      sock(field(said, "id").unwrap_or(Json::null()))
    },
    listen: async fn(path) {
      let (said, _) = host.shell("unix.listen", { "path": jstr(path) })
      let id = field(said, "id").unwrap_or(Json::null())
      let closed = Ref(false)
      {
        accept: async fn() -> Sock? {
          let got = accept_through(closed=() => closed.val, async fn() {
            host.shell("tcp.accept", { "id": id }).0
          })
          got.map(got => sock(field(got, "id").unwrap_or(Json::null())))
        },
        close: () => if !closed.val {
          closed.val = true
          ignore(host.rt.fork(() => ignore(host.shell("listen.close", { "id": id })) catch { _ => () }))
        },
      }
    },
    remove: async fn(path) { ignore(host.shell("fs.remove", { "path": jstr(path) })) catch { _ => () } },
  }
}

///|
/// A socket as the front's link keeps it: whether it was let go, or its sending half ended. The shell keeps a socket
/// until it is told to close it (`tcp.close`), even when both halves are over, so the socket is let go once its read
/// side has ended and its sending half has been ended, as Node closes a half-open socket then by itself. Until then it
/// stays counted as open (`on_close`, as Node's `close`), so a connection's close or the front's end still lets it go.
priv struct Held {
  sock : Sock
  mut destroyed : Bool
  mut ended : Bool
  mut sent_end : Bool
  mut read_over : Bool
  mut closed : Bool
  on_close : Array[() -> Unit]
}

///|
fn Held::new(sock : Sock) -> Held {
  { sock, destroyed: false, ended: false, sent_end: false, read_over: false, closed: false, on_close: [] }
}

///|
fn Held::destroy(self : Held) -> Unit {
  if self.destroyed {
    return
  }
  self.destroyed = true
  (self.sock.destroy)()
  self.closed_now()
}

///|
fn Held::closed_now(self : Held) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  for f in self.on_close.copy() {
    f()
  }
}

///|
/// Its read side ended: let go once its sending half is over too.
fn Held::read_ended(self : Held) -> Unit {
  self.read_over = true
  if self.sent_end {
    self.destroy()
  }
}

///|
async fn Held::end(self : Held) -> Unit {
  if self.ended || self.destroyed {
    return
  }
  self.ended = true
  (self.sock.end)() catch { _ => () }
  self.sent_end = true
  if self.read_over {
    self.destroy()
  }
}

///|
/// A stream's socket as it came: its socket, what came with its head, its id.
pub struct Came {
  priv held : Held
  carry : Bytes
  id : Int64
}

///|
/// What a connection's other end opened, taken in turn in the order it opened them; none once the connection is gone
/// (`Incoming`): one with its index waits for those before it; one from a front before the index goes as it came.
pub struct Incoming {
  priv came : Array[Came]
  priv early : Map[Int64, Came?]
  priv mut next_index : Int64
  priv mut taker : @effect.Deferred[Came?]?
  priv mut ended : Bool
}

///|
pub fn Incoming::new() -> Incoming {
  { came: [], early: Map([]), next_index: 0L, taker: None, ended: false }
}

///|
/// A stream that came (`index`: its place on its connection, where the front says it).
pub fn Incoming::give(self : Incoming, s : Came, index? : Int64? = None) -> Unit {
  if self.ended {
    return s.held.destroy()
  }
  guard index is Some(i) else { return self.put(s) }
  if i != self.next_index {
    self.early[i] = Some(s)
    return
  }
  self.put(s)
  self.on_from(self.next_index + 1L)
}

///|
/// The stream of index `index` is not coming here (the front answers it).
pub fn Incoming::skip(self : Incoming, index : Int64) -> Unit {
  if self.ended {
    return
  }
  if index != self.next_index {
    self.early[index] = None
    return
  }
  self.on_from(index + 1L)
}

///|
fn Incoming::on_from(self : Incoming, from : Int64) -> Unit {
  self.next_index = from
  while self.early.get(self.next_index) is Some(next) {
    self.early.remove(self.next_index)
    if next is Some(s) {
      self.put(s)
    }
    self.next_index += 1L
  }
}

///|
fn Incoming::put(self : Incoming, s : Came) -> Unit {
  match self.taker {
    Some(t) => {
      self.taker = None
      ignore(t.succeed(Some(s)))
    }
    None => self.came.push(s)
  }
}

///|
/// The next stream, in turn; None once the connection is gone.
pub async fn Incoming::take(self : Incoming) -> Came? {
  if self.came.length() > 0 {
    return Some(self.came.remove(0))
  }
  if self.ended {
    return None
  }
  let d : @effect.Deferred[Came?] = @effect.Deferred::new()
  self.taker = Some(d)
  d.wait()
}

///|
pub fn Incoming::end(self : Incoming) -> Unit {
  self.ended = true
  for s in self.came {
    s.held.destroy()
  }
  self.came.clear()
  for _, s in self.early {
    if s is Some(c) {
      c.held.destroy()
    }
  }
  self.early.clear()
  if self.taker is Some(t) {
    self.taker = None
    ignore(t.succeed(None))
  }
}

///|
fn u64_at(b : Bytes, at : Int) -> Int64 {
  let mut v = 0L
  for i in 0..<8 {
    v = (v << 8) | b[at + i].to_int64()
  }
  v
}

///|
/// One station's link to the front (`Front`): its asks and answers, and the streams it is given.
pub struct Front {
  priv control : Held
  priv server : SockListener
  priv sockets : Sockets
  streams_path : String
  priv rt : @effect.Runtime
  priv mut next : Int
  priv asked : Map[Int, @effect.Deferred[Json]]
  priv waiting_sockets : Map[Int64, (Int64, Came)]
  priv wanted : Map[Int64, (Int64, @effect.Deferred[Came])]
  priv incoming : Map[Int64, Incoming]
  priv open_ : Array[Held]
  priv conn_sockets : Map[Int64, Array[Held]]
  priv forgotten : Array[Int64]
  priv mut gone : String?
  priv went : @effect.Deferred[Unit]
  priv said : Said
  /// What the front said last of its endpoint's mesh scopes (`meshScopes`), and who is told it as it says it.
  priv mut mesh_scopes : Array[Json]?
  priv mut on_mesh_scopes : (Array[Json]) -> Unit
}

///|
/// How many links this program made (each binding its own streams' socket).
let opened_links : Ref[Int] = Ref(0)

///|
pub fn dirname(path : String) -> String {
  // (the last `/` or `\`: a Windows socket's path has the one, any other's the other)
  let mut at = -1
  for i in 0..<path.length() {
    let c = path.code_unit_at(i)
    if c == '/' || c == '\\' {
      at = i
    }
  }
  if at < 0 {
    return "."
  }
  let root = at == 0 ||
    (at == 2 && path.length() >= 3 && path.code_unit_at(1) == ':')
  if root {
    // (a root's directory is the root itself: `/`, `C:\`)
    path.clamped_view(end=at + 1).to_owned()
  } else {
    path.clamped_view(end=at).to_owned()
  }
}

///|
/// Where the front's streams' socket is beside `socket` (`mesh-<pid>-<n>.sock`), by that path's own separator.
pub fn streams_path_of(socket : String, pid : Int, n : Int) -> String {
  let sep = if socket.contains("\\") && !socket.contains("/") { "\\" } else { "/" }
  let dir = dirname(socket)
  let joined = if dir.has_suffix(sep) { dir } else { dir + sep }
  "\{joined}mesh-\{pid}-\{n}.sock"
}

///|
/// A link to the front at `socket` (`Front.open`): its streams' socket listened on beside it (`pid`: this process's).
pub async fn Front::open(sockets : Sockets, socket : String, pid : Int, rt : @effect.Runtime, said : Said) -> Front {
  opened_links.val += 1
  let streams_path = streams_path_of(socket, pid, opened_links.val)
  (sockets.remove)(streams_path)
  let server = (sockets.listen)(streams_path)
  let control = (sockets.connect)(socket) catch {
    e => {
      (server.close)()
      (sockets.remove)(streams_path)
      raise e
    }
  }
  let front : Front = {
    control: Held::new(control),
    server,
    sockets,
    streams_path,
    rt,
    next: 0,
    asked: Map([]),
    waiting_sockets: Map([]),
    wanted: Map([]),
    incoming: Map([]),
    open_: [],
    conn_sockets: Map([]),
    forgotten: [],
    gone: None,
    went: @effect.Deferred::new(),
    said,
    mesh_scopes: None,
    on_mesh_scopes: _ => (),
  }
  ignore(
    rt.fork(name="front control", () => {
      let lines = @wire.Lines::new()
      while (control.read)() is Some(bytes) {
        for line in lines.push(bytes[:]) {
          let got = @json.parse(line) catch {
            _ => {
              said("warn", "mesh", "the front said what is not JSON", jobj([("line", jstr(line.clamped_view(end=200).to_owned()))]))
              continue
            }
          }
          if field(got, "event") is Some(String("meshScopes")) {
            if field(got, "scopes") is Some(Array(scopes)) && scopes.length() <= 32 {
              front.mesh_scopes = Some(scopes)
              (front.on_mesh_scopes)(scopes)
            }
            continue
          }
          guard field(got, "id") is Some(Number(n, ..)) && front.asked.get(n.to_int()) is Some(d) else { continue }
          front.asked.remove(n.to_int())
          match field(got, "error") {
            Some(e) if !(e is Null) => ignore(d.fail(Failure(str_of(Some(e)).unwrap_or(js_stringify(e)))))
            _ => ignore(d.succeed(field(got, "ok").unwrap_or(Json::null())))
          }
        }
      }
      front.end_("the front is gone")
      // (its read side over and the link gone: nothing writes on it again, so it is let go, whichever end went first)
      front.control.destroy()
    } catch {
      _ => {
        front.end_("the front is gone")
        front.control.destroy()
      }
    }),
  )
  ignore(
    rt.fork(name="front streams", () => {
      while (server.accept)() is Some(s) {
        let held = Held::new(s)
        ignore(rt.fork(name="front stream", () => front.took(held) catch { _ => held.destroy() }))
      }
    } catch {
      _ => ()
    }),
  )
  front
}

///|
/// Whether the link is gone.
pub fn Front::is_gone(self : Front) -> Bool {
  self.gone is Some(_)
}

///|
/// Once the link is gone.
pub async fn Front::gone_wait(self : Front) -> Unit {
  self.went.wait()
}

///|
/// An ask (`id`: told its number as it is sent); raises what the front said, or the link gone.
pub async fn Front::ask(self : Front, op : String, args? : Array[(String, Json)] = [], id? : (Int) -> Unit = _ => ()) -> Json {
  if self.gone is Some(g) {
    raise Failure(g)
  }
  self.next += 1
  let n = self.next
  id(n)
  let d : @effect.Deferred[Json] = @effect.Deferred::new()
  self.asked[n] = d
  let line = [("id", jnum(n.to_double())), ("op", jstr(op))]
  for a in args {
    line.push(a)
  }
  (self.control.sock.write)(@utf8.encode(js_stringify(jobj(line)) + "\n")) catch {
    _ => self.end_("the front is gone")
  }
  d.wait()
}

///|
/// The streams the other end of connection `conn` opens.
pub fn Front::incoming_of(self : Front, conn : Int64) -> Incoming {
  match self.incoming.get(conn) {
    Some(i) => i
    None => {
      let i = Incoming::new()
      self.incoming[conn] = i
      i
    }
  }
}

///|
/// A connection gone (`forget`): the streams it had and nobody took with it, and its sockets.
pub fn Front::forget(self : Front, conn : Int64) -> Unit {
  self.forgotten.push(conn)
  if self.forgotten.length() > 1024 {
    ignore(self.forgotten.remove(0))
  }
  if self.incoming.get(conn) is Some(i) {
    i.end()
  }
  self.incoming.remove(conn)
  if self.conn_sockets.get(conn) is Some(held) {
    self.conn_sockets.remove(conn)
    for h in held {
      ignore(self.rt.fork(() => h.end()))
    }
  }
  let gone = []
  for id, w in self.wanted {
    if w.0 == conn {
      gone.push(id)
    }
  }
  for id in gone {
    if self.wanted.get(id) is Some((_, d)) {
      self.wanted.remove(id)
      ignore(d.fail(Failure("the connection is closed")))
    }
  }
  let dropped = []
  for id, s in self.waiting_sockets {
    if s.0 == conn {
      dropped.push(id)
    }
  }
  for id in dropped {
    if self.waiting_sockets.get(id) is Some((_, c)) {
      self.waiting_sockets.remove(id)
      c.held.destroy()
    }
  }
}

///|
/// The socket of stream `id`, once it came.
pub async fn Front::socket_of(self : Front, id : Int64, conn : Int64) -> Came {
  if self.waiting_sockets.get(id) is Some((_, c)) {
    self.waiting_sockets.remove(id)
    return c
  }
  if self.gone is Some(g) {
    raise Failure(g)
  }
  if self.forgotten.contains(conn) {
    raise Failure("the connection is closed")
  }
  let d : @effect.Deferred[Came] = @effect.Deferred::new()
  self.wanted[id] = (conn, d)
  d.wait()
}

///|
/// A stream's socket the front gave: its head read, then handed to what waits for it (`#took`).
async fn Front::took(self : Front, held : Held) -> Unit {
  self.open_.push(held)
  held.on_close.push(() => self.open_.retain(h => !physical_equal(h, held)))
  let parts = []
  let mut size = 0
  let mut head = b""
  while true {
    guard (held.sock.read)() is Some(more) else {
      held.destroy()
      return
    }
    parts.push(more)
    size += more.length()
    head = @door.concat(parts)
    if size < 17 {
      continue
    }
    let kind = head[16].to_int()
    if (kind == 2 || kind == 3) && size < 25 {
      continue
    }
    break
  }
  let conn = u64_at(head, 0)
  let id = u64_at(head, 8)
  let kind = head[16].to_int()
  if kind == 3 {
    held.destroy()
    if !self.forgotten.contains(conn) {
      self.incoming_of(conn).skip(u64_at(head, 17))
    }
    return
  }
  if self.forgotten.contains(conn) {
    return held.destroy()
  }
  let by_conn = match self.conn_sockets.get(conn) {
    Some(a) => a
    None => {
      let a = []
      self.conn_sockets[conn] = a
      a
    }
  }
  by_conn.push(held)
  held.on_close.push(() => {
    by_conn.retain(h => !physical_equal(h, held))
    if by_conn.length() == 0 && self.conn_sockets.get(conn) is Some(a) && physical_equal(a, by_conn) {
      self.conn_sockets.remove(conn)
    }
  })
  if kind == 2 {
    return self.incoming_of(conn).give({ held, carry: @door.own(head[25:]), id }, index=Some(u64_at(head, 17)))
  }
  let came : Came = { held, carry: @door.own(head[17:]), id }
  if kind == 0 {
    return self.incoming_of(conn).give(came)
  }
  match self.wanted.get(id) {
    Some((_, d)) => {
      self.wanted.remove(id)
      ignore(d.succeed(came))
    }
    None => self.waiting_sockets[id] = (conn, came)
  }
}

///|
fn Front::end_(self : Front, error : String) -> Unit {
  if self.gone is Some(_) {
    return
  }
  self.gone = Some(error)
  ignore(self.went.succeed(()))
  for _, d in self.asked {
    ignore(d.fail(Failure(error)))
  }
  self.asked.clear()
  for _, w in self.wanted {
    ignore(w.1.fail(Failure(error)))
  }
  self.wanted.clear()
  for _, i in self.incoming {
    i.end()
  }
  self.incoming.clear()
  for h in self.open_.copy() {
    h.destroy()
  }
  self.open_.clear()
  self.conn_sockets.clear()
  self.forgotten.clear()
  self.waiting_sockets.clear()
  (self.server.close)()
  let path = self.streams_path
  let sockets = self.sockets
  ignore(self.rt.fork(() => (sockets.remove)(path)))
}

///|
/// The link closed here.
pub fn Front::close(self : Front) -> Unit {
  ignore(self.rt.fork(() => self.control.end()))
  self.end_("the endpoint is closed")
}

///|
/// What a stream gives: its bytes, its end (None) or what failed it.
priv enum Piece {
  Bytes_(Bytes)
  End
  Failed(String)
}

///|
/// A stream the front gave (`FrontStream`): its socket, frames each way. `both`: a stream both ways (`stopped` answers
/// None where it is gone; one way, it fails).
priv struct FrontStream {
  front : Front
  id : Int64
  held : Held
  both : Bool
  mut head : Bytes
  mut left : Int
  frames : Array[Piece]
  mut reader : @effect.Deferred[Piece]?
  mut over : Bool
  mut reset_ : Bool
}

///|
fn FrontStream::new(front : Front, id : Int64, came : Came, both : Bool) -> FrontStream {
  let s : FrontStream = {
    front,
    id,
    held: came.held,
    both,
    head: b"",
    left: 0,
    frames: [],
    reader: None,
    over: false,
    reset_: false,
  }
  s.parse(came.carry)
  ignore(
    front.rt.fork(name="front stream reads", () => {
      while (s.held.sock.read)() is Some(d) {
        s.parse(d)
      }
      // (a send-only stream has no read side: its end must not close its write side)
      if s.both && !s.over && !s.held.ended {
        s.held.end()
      }
      s.came(Failed("the stream's way to the front ended"))
      s.held.read_ended()
    } catch {
      _ => {
        s.came(Failed("the stream's way to the front ended"))
        s.held.destroy()
      }
    }),
  )
  s
}

///|
fn FrontStream::parse(self : FrontStream, data : Bytes) -> Unit {
  let mut d = data
  while !self.over && d.length() > 0 {
    if self.left > 0 {
      let take = if self.left < d.length() { self.left } else { d.length() }
      self.give(Bytes_(@door.own(d[0:take])))
      self.left -= take
      d = @door.own(d[take:])
      continue
    }
    let head = if self.head.length() == 0 { d } else { @door.concat([self.head, d]) }
    if head.length() < 4 {
      self.head = head
      return
    }
    let n = (head[0].to_uint() << 24) | (head[1].to_uint() << 16) | (head[2].to_uint() << 8) | head[3].to_uint()
    if n == front_end {
      self.head = b""
      return self.came(End)
    }
    if n == front_failed {
      if head.length() < 8 {
        self.head = head
        return
      }
      let len = ((head[4].to_uint() << 24) | (head[5].to_uint() << 16) | (head[6].to_uint() << 8) | head[7].to_uint()).reinterpret_as_int()
      if head.length() < 8 + len {
        self.head = head
        return
      }
      self.head = b""
      return self.came(Failed(@utf8.decode_lossy(head[8:8 + len])))
    }
    self.head = b""
    self.left = n.reinterpret_as_int()
    d = @door.own(head[4:])
  }
}

///|
fn FrontStream::came(self : FrontStream, last : Piece) -> Unit {
  if self.over {
    return
  }
  self.over = true
  self.give(last)
}

///|
fn FrontStream::give(self : FrontStream, f : Piece) -> Unit {
  match self.reader {
    Some(r) => {
      self.reader = None
      ignore(r.succeed(f))
    }
    None => self.frames.push(f)
  }
}

///|
async fn FrontStream::read(self : FrontStream) -> Bytes? {
  if self.reset_ {
    return None
  }
  let f = if self.frames.length() > 0 {
    self.frames.remove(0)
  } else {
    let d : @effect.Deferred[Piece] = @effect.Deferred::new()
    self.reader = Some(d)
    d.wait()
  }
  if self.reset_ {
    return None
  }
  match f {
    Bytes_(b) => Some(b)
    End => None
    Failed(m) => raise Failure(m)
  }
}

///|
async fn FrontStream::send(self : FrontStream, bytes : Bytes) -> Unit {
  if self.held.destroyed || self.held.ended {
    raise Failure(if self.reset_ { "the stream was reset" } else { "the stream is gone" })
  }
  (self.held.sock.write)(bytes)
}

///|
fn be32(n : UInt) -> Bytes {
  let b = @buffer.Buffer(size_hint=4)
  b.write_uint_be(n)
  b.to_bytes()
}

///|
async fn FrontStream::write(self : FrontStream, bytes : Bytes) -> Unit {
  let mut at = 0
  while at < bytes.length() {
    let to = if at + frame_most < bytes.length() { at + frame_most } else { bytes.length() }
    self.send(@door.concat([be32((to - at).reinterpret_as_uint()), @door.own(bytes[at:to])]))
    at = to
  }
}

///|
async fn FrontStream::finish(self : FrontStream) -> Unit {
  self.send(be32(front_end))
  self.held.end()
}

///|
async fn FrontStream::stopped(self : FrontStream) -> Int? {
  let said = self.front.ask("stopped", args=[("stream", jnum(self.id.to_double()))]) catch {
    e => if self.both { return None } else { raise e }
  }
  match field(said, "code") {
    Some(Number(c, ..)) => Some(c.to_int())
    _ => None
  }
}

///|
async fn FrontStream::reset(self : FrontStream, code : Int) -> Unit {
  self.reset_ = true
  if self.reader is Some(r) {
    self.reader = None
    ignore(r.succeed(End))
  }
  ignore(self.front.ask("reset", args=[("stream", jnum(self.id.to_double())), ("code", jnum(code.to_double()))])) catch {
    _ => ()
  }
  self.held.destroy()
}

///|
fn FrontStream::as_stream(self : FrontStream) -> @door.Stream {
  {
    read: () => self.read(),
    write: b => self.write(b),
    finish: () => self.finish(),
    stopped: () => self.stopped(),
    reset: c => self.reset(c),
  }
}

///|
/// A way of a connection as the front says it (`{selected, relay, ip, rttMs, txPackets, lostPackets}`).
fn path_of(v : Json) -> @door.Path {
  {
    selected: field(v, "selected") is Some(True),
    relay: str_of(field(v, "relay")),
    ip: str_of(field(v, "ip")),
    rtt_ms: num_of(field(v, "rttMs")),
    tx_packets: num_of(field(v, "txPackets")).unwrap_or(0.0),
    lost_packets: num_of(field(v, "lostPackets")).unwrap_or(0.0),
  }
}

///|
/// A connection the front has for this program (`FrontConnection`).
priv struct FrontConnection {
  front : Front
  conn : Int64
  remote : String
  alpn : String
  mut seen : Json
  mut asking : Bool
  mut closed : Json?
  ended : @effect.Deferred[String]
  incoming : Incoming
}

///|
fn FrontConnection::new(front : Front, seen : Json) -> FrontConnection {
  let conn = num_of(field(seen, "conn")).unwrap_or(0.0).to_int64()
  let c : FrontConnection = {
    front,
    conn,
    remote: str_of(field(seen, "remote")).unwrap_or(""),
    alpn: str_of(field(seen, "alpn")).unwrap_or(""),
    seen,
    asking: false,
    closed: None,
    ended: @effect.Deferred::new(),
    incoming: front.incoming_of(conn),
  }
  ignore(
    front.rt.fork(name="front conn closed", () => {
      let info = front.ask("conn.closed", args=[("conn", jnum(conn.to_double()))]) catch {
        e => {
          if c.closed is None {
            c.closed = Some(jobj([("kind", jstr("other")), ("reason", jstr(message_of(e)))]))
          }
          ignore(c.ended.succeed(message_of(e)))
          return
        }
      }
      c.closed = Some(info)
      front.forget(conn)
      let words = match (str_of(field(info, "text")), str_of(field(info, "reason"))) {
        (Some(t), _) => t
        (None, Some(r)) => r
        _ => "closed"
      }
      ignore(c.ended.succeed(words))
    }),
  )
  c
}

///|
/// What the front says of it now, asked again as what it said last is read.
fn FrontConnection::again(self : FrontConnection) -> Unit {
  if self.asking || self.closed is Some(_) {
    return
  }
  self.asking = true
  ignore(
    self.front.rt.fork(name="front conn seen", () => {
      let seen = self.front.ask("conn.seen", args=[("conn", jnum(self.conn.to_double()))]) catch {
        _ => {
          self.asking = false
          return
        }
      }
      self.seen = seen
      self.asking = false
    }),
  )
}

///|
async fn FrontConnection::stream(self : FrontConnection, op : String) -> @door.Stream? {
  let said = self.front.ask(op, args=[("conn", jnum(self.conn.to_double()))])
  if field(said, "end") is Some(True) {
    return None
  }
  let id = num_of(field(said, "stream")).unwrap_or(0.0).to_int64()
  let came = self.front.socket_of(id, self.conn)
  Some(FrontStream::new(self.front, id, came, op != "openUni").as_stream())
}

///|
fn FrontConnection::as_connection(self : FrontConnection) -> @door.Connection {
  {
    remote_id: () => self.remote,
    alpn: () => self.alpn,
    via: () => {
      self.again()
      str_of(field(self.seen, "via"))
    },
    paths: Some(() => {
      self.again()
      match field(self.seen, "paths") {
        Some(Array(ps)) => ps.map(path_of)
        _ => []
      }
    }),
    accept_bi: async fn() -> @door.Stream? {
      guard self.incoming.take() is Some(came) else { return None }
      Some(FrontStream::new(self.front, came.id, came, true).as_stream())
    },
    open_bi: async fn() -> @door.Stream { self.stream("openBi").unwrap() },
    answers: Some(async fn(within) {
      let v = self.front.ask("conn.answers", args=[("conn", jnum(self.conn.to_double())), ("within", jnum(within.to_double()))]) catch {
        _ => return false
      }
      v is True
    }),
    stats: Some(() => {
      self.again()
      let m : Map[String, Double] = Map([])
      if field(self.seen, "stats") is Some(Object(s)) {
        for k, v in s {
          if v is Number(n, ..) {
            m[k] = n
          }
        }
      }
      m
    }),
    close: (code, reason) => {
      if self.closed is None {
        self.closed = Some(jobj([("kind", jstr("local")), ("reason", jstr(""))]))
      }
      ignore(
        self.front.rt.fork(() => ignore(
          self.front.ask(
            "conn.close",
            args=[("conn", jnum(self.conn.to_double())), ("code", jnum(code.to_double())), ("reason", jstr(reason))],
          ),
        ) catch {
          _ => ()
        }),
      )
    },
    is_closed: () => self.closed is Some(_),
    closed: async fn() -> String { self.ended.wait() },
    close_reason: Some(() => match self.closed {
      Some(c) => Some((str_of(field(c, "kind")).unwrap_or(""), str_of(field(c, "reason")).unwrap_or("")))
      None => None
    }),
    handed: Some(self.conn.to_int()),
  }
}

///|
/// A relay's URL as compared: no trailing slash.
pub fn bare(url : String) -> String {
  let mut end = url.length()
  while end > 0 && url.code_unit_at(end - 1) == '/' {
    end -= 1
  }
  url.clamped_view(end~).to_owned()
}

///|
/// The station's endpoint at the front (`FrontEndpoint`), its link to it made again where it went: bound again as it
/// was, what it accepts from then on the new link's.
pub struct FrontEndpoint {
  priv sockets : Sockets
  priv socket : String
  priv pid : Int
  priv bind_ : Map[String, Json]
  priv mut front : Front
  priv mut said : Json
  priv mut relays : Json
  priv mut asking : Bool
  priv mut closed : Bool
  priv mut again : @effect.Deferred[Unit]?
  priv mut routed : Json?
  priv disabled : Map[String, Json]
  /// The mesh scopes as last asked (a config, or None: removed till the front says so), given again to a front linked
  /// to anew: a reply lost leaves what was asked unknown, so it is asked again before anything is served.
  priv mesh_wanted : Map[String, Json?]
  priv mesh_listeners : Map[Int, (Array[Json]) -> Unit]
  priv mut mesh_next : Int
  priv closing : () -> Unit
  priv rt : @effect.Runtime
  priv sleep : async (Int) -> Unit
  priv log : Said
}

///|
/// What a bind asks of the front (`FrontEndpoint.bind`): the key and the options as the addon takes them.
pub fn front_bind_options(
  secret_key : Bytes,
  alpns : Array[Bytes],
  relay_urls : Array[String],
  discovery? : Bool = true,
  bind_addr? : String? = None,
  relay_only? : Bool = false,
  congestion? : String? = None,
  dscp? : Double? = None,
) -> Map[String, Json] {
  let options = [
    ("alpns", Json::array(alpns.map(a => jstr(@hex.encode(a[:]))))),
    ("relayUrls", Json::array(relay_urls.map(jstr))),
    ("discovery", Json::boolean(discovery)),
  ]
  if bind_addr is Some(a) && a != "" {
    options.push(("bindAddr", jstr(a)))
  }
  if relay_only {
    options.push(("relayOnly", Json::boolean(true)))
  }
  if congestion is Some(c) && c != "" {
    options.push(("congestion", jstr(c)))
  }
  if dscp is Some(d) {
    options.push(("dscp", jnum(d)))
  }
  Map([("key", jstr(@hex.encode(secret_key[:]))), ("options", jobj(options))])
}

///|
async fn FrontEndpoint::link(
  sockets : Sockets,
  socket : String,
  pid : Int,
  bind : Map[String, Json],
  rt : @effect.Runtime,
  log : Said,
) -> (Front, Json) {
  let front = Front::open(sockets, socket, pid, rt, log)
  let args = [("streams", jstr(front.streams_path))]
  for k, v in bind {
    args.push((k, v))
  }
  let said = front.ask("bind", args~) catch {
    e => {
      front.close()
      raise e
    }
  }
  (front, said)
}

///|
/// The endpoint bound at the front at `socket`; `sleep`: the wait between tries to link again.
pub async fn FrontEndpoint::bind(
  sockets : Sockets,
  socket : String,
  pid : Int,
  bind : Map[String, Json],
  rt : @effect.Runtime,
  sleep : async (Int) -> Unit,
  log : Said,
  closing? : () -> Unit = () => (),
) -> FrontEndpoint {
  let (front, said) = FrontEndpoint::link(sockets, socket, pid, bind, rt, log)
  let e : FrontEndpoint = {
    sockets,
    socket,
    pid,
    bind_: bind,
    front,
    said,
    relays: Json::array([]),
    asking: false,
    closed: false,
    again: None,
    routed: None,
    disabled: Map([]),
    mesh_wanted: Map([]),
    mesh_listeners: Map([]),
    mesh_next: 0,
    closing,
    rt,
    sleep,
    log,
  }
  e.relays = front.ask("relayStatus") catch { _ => Json::array([]) }
  e.attach_mesh(front)
  e.watch(front)
  e
}

///|
/// What `front` says of its scopes told this endpoint's listeners while it is the front linked to.
fn FrontEndpoint::attach_mesh(self : FrontEndpoint, front : Front) -> Unit {
  front.on_mesh_scopes = scopes => if physical_equal(self.front, front) && !self.closed {
    for _, f in self.mesh_listeners {
      f(scopes)
    }
  }
  match front.mesh_scopes {
    Some(scopes) => (front.on_mesh_scopes)(scopes)
    None => ()
  }
}

///|
/// Told what the front says of the endpoint's mesh scopes (`meshListen`), what it said last at once.
pub fn FrontEndpoint::mesh_listen(self : FrontEndpoint, f : (Array[Json]) -> Unit) -> () -> Unit {
  self.mesh_next += 1
  let id = self.mesh_next
  self.mesh_listeners[id] = f
  match self.front.mesh_scopes {
    Some(scopes) => f(scopes)
    None => ()
  }
  () => self.mesh_listeners.remove(id)
}

///|
async fn FrontEndpoint::mesh_change(self : FrontEndpoint, scope : String, config : Json?) -> Json {
  if self.again is Some(a) {
    a.wait()
  }
  let front = self.front
  let before = self.mesh_wanted.get(scope)
  if before is None && self.mesh_wanted.length() >= 32 {
    raise Failure("too many mesh scopes")
  }
  self.mesh_wanted[scope] = config
  let asked = (match config {
    Some(c) => front.ask("meshConfigure", args=[("args", c)])
    None => front.ask("meshRemove", args=[("args", jobj([("scope", jstr(scope))]))])
  }) catch {
    e => {
      // (a refusal leaves what was there; a link lost leaves it unknown, asked again before serving)
      if !front.is_gone() {
        match before {
          Some(b) => self.mesh_wanted[scope] = b
          None => self.mesh_wanted.remove(scope)
        }
      }
      raise e
    }
  }
  if config is None && self.mesh_wanted.get(scope) is Some(None) {
    self.mesh_wanted.remove(scope)
  }
  asked
}

///|
/// A scope configured on the endpoint (`meshConfigure`): this station's descriptor in it.
pub async fn FrontEndpoint::mesh_configure(self : FrontEndpoint, config : Json) -> Json {
  let scope = match config {
    Object(m) => str_of(m.get("scope")).unwrap_or("")
    _ => ""
  }
  self.mesh_change(scope, Some(config))
}

///|
pub async fn FrontEndpoint::mesh_remove(self : FrontEndpoint, scope : String) -> Unit {
  ignore(self.mesh_change(scope, None))
}

///|
/// A member's connection the front holds (`handed`) let into a scope as a leaf (`meshAttachLeaf`).
pub async fn FrontEndpoint::mesh_attach_leaf(self : FrontEndpoint, handed : Int?, value : Json) -> Json {
  guard handed is Some(h) else { raise Failure("leaf connection is not held by this front") }
  let args = match value {
    Object(m) => {
      let out : Map[String, Json] = Map([])
      for k, v in m {
        out[k] = v
      }
      out["connection"] = jnum(h.to_double())
      Json::object(out)
    }
    _ => jobj([("connection", jnum(h.to_double()))])
  }
  self.ask("meshAttachLeaf", args=[("args", args)])
}

///|
pub async fn FrontEndpoint::mesh_detach_leaf(self : FrontEndpoint, value : Json) -> Unit {
  ignore(self.ask("meshDetachLeaf", args=[("args", value)]))
}


///|
/// The link gone while the endpoint is open: made again, a while after each try that fails.
fn FrontEndpoint::watch(self : FrontEndpoint, front : Front) -> Unit {
  ignore(
    self.rt.fork(name="front watch", () => {
      front.gone_wait()
      if self.closed || !physical_equal(self.front, front) {
        return
      }
      (self.log)("warn", "mesh", "the front is gone; linking to it again", Json::null())
      let again : @effect.Deferred[Unit] = @effect.Deferred::new()
      self.again = Some(again)
      let mut wait = 250
      while !self.closed {
        (self.sleep)(wait)
        let linked = (async fn() -> Bool {
          let (next, said) = FrontEndpoint::link(self.sockets, self.socket, self.pid, self.bind_, self.rt, self.log)
          if self.closed {
            next.close()
            return true
          }
          (async fn() {
            for _, args in self.disabled {
              ignore(next.ask("disabledRelays", args=[("args", args)]))
            }
            for pair in self.mesh_wanted.to_array() {
              let (scope, wanted) = pair
              match wanted {
                Some(config) => ignore(next.ask("meshConfigure", args=[("args", config)]))
                None => {
                  ignore(next.ask("meshRemove", args=[("args", jobj([("scope", jstr(scope))]))]))
                  self.mesh_wanted.remove(scope)
                }
              }
            }
            if self.routed is Some(Object(r)) {
              ignore(next.ask("route", args=r.to_array()))
            }
            self.relays = next.ask("relayStatus") catch { _ => Json::array([]) }
          })() catch {
            e => {
              next.close()
              raise e
            }
          }
          self.front = next
          self.said = said
          self.attach_mesh(next)
          self.watch(next)
          (self.log)("info", "mesh", "linked to the front again", jobj([("station", field(said, "id").unwrap_or(Json::null()))]))
          true
        })() catch {
          e => {
            let later = if wait * 2 < 8000 { wait * 2 } else { 8000 }
            (self.log)(
              "warn",
              "mesh",
              "the front not reached",
              jobj([("error", jstr(message_of(e))), ("again", jstr("\{later} ms"))]),
            )
            false
          }
        }
        if linked {
          break
        }
        wait = if wait * 2 < 8000 { wait * 2 } else { 8000 }
      }
      self.again = None
      ignore(again.succeed(()))
    }),
  )
}

///|
async fn FrontEndpoint::ask(self : FrontEndpoint, op : String, args? : Array[(String, Json)] = []) -> Json {
  if self.again is Some(a) {
    a.wait()
  }
  self.front.ask(op, args~)
}

///|
/// Linked to the front now: not linking to it again after its link went.
pub fn FrontEndpoint::linked(self : FrontEndpoint) -> Bool {
  self.closed || (self.again is None && !self.front.is_gone())
}

///|
pub fn FrontEndpoint::id(self : FrontEndpoint) -> String {
  str_of(field(self.said, "id")).unwrap_or("")
}

///|
pub fn FrontEndpoint::sockets(self : FrontEndpoint) -> Array[String] {
  strs(field(self.said, "sockets"))
}

///|
pub async fn FrontEndpoint::online(self : FrontEndpoint) -> Unit {
  ignore(self.ask("online"))
}

///|
fn FrontEndpoint::relays_again(self : FrontEndpoint) -> Unit {
  if self.asking {
    return
  }
  self.asking = true
  ignore(
    self.rt.fork(name="front relays", () => {
      let r = self.ask("relayStatus") catch {
        _ => {
          self.asking = false
          return
        }
      }
      self.relays = r
      self.asking = false
    }),
  )
}

///|
/// The relay the endpoint is home on, as said last (asked again).
pub fn FrontEndpoint::home(self : FrontEndpoint) -> String? {
  self.relays_again()
  match self.relays {
    Array(rs) if rs.length() > 0 => str_of(field(rs[0], "url"))
    _ => None
  }
}

///|
pub fn FrontEndpoint::relay_status(self : FrontEndpoint) -> Json {
  self.relays_again()
  self.relays
}

///|
/// The relays a station is not reached through (`disabledRelays`), given again to a front linked to anew.
pub async fn FrontEndpoint::disabled_relays(self : FrontEndpoint, id : String, relays : Array[String], no_public : Bool) -> Unit {
  let args = jobj([("peer", jstr(id)), ("relays", Json::array(relays.map(jstr))), ("public", Json::boolean(no_public))])
  let before = self.disabled.get(id)
  self.disabled[id] = args
  let failed = (async fn() { ignore(self.ask("disabledRelays", args=[("args", args)])) })() catch {
    e => Some(e)
  } noraise {
    _ => None
  }
  match failed {
    None =>
      if relays.length() == 0 && !no_public && self.disabled.get(id).map(a => physical_equal(a, args)).unwrap_or(false) {
        self.disabled.remove(id)
      }
    Some(e) => {
      let words = message_of(e)
      if (words.contains("no operation") || words.contains("not a function")) &&
        self.disabled.get(id).map(a => physical_equal(a, args)).unwrap_or(false) {
        match before {
          Some(b) => self.disabled[id] = b
          None => self.disabled.remove(id)
        }
      }
      raise e
    }
  }
}

///|
fn FrontEndpoint::relay_urls(self : FrontEndpoint, change : (Array[String]) -> Array[String]) -> Unit {
  guard self.bind_.get("options") is Some(Object(o)) else { return }
  o["relayUrls"] = Json::array(change(strs(o.get("relayUrls"))).map(jstr))
}

///|
pub async fn FrontEndpoint::insert_relay(self : FrontEndpoint, url : String) -> Unit {
  ignore(self.ask("insertRelay", args=[("args", jobj([("url", jstr(url))]))]))
  self.relay_urls(urls => if urls.iter().any(u => bare(u) == bare(url)) { urls } else { [..urls, url] })
}

///|
pub async fn FrontEndpoint::remove_relay(self : FrontEndpoint, url : String) -> Unit {
  ignore(self.ask("removeRelay", args=[("args", jobj([("url", jstr(url))]))]))
  self.relay_urls(urls => urls.filter(u => bare(u) != bare(url)))
}

///|
pub async fn FrontEndpoint::public_relays(self : FrontEndpoint, on : Bool) -> Unit {
  ignore(self.ask("publicRelays", args=[("args", jobj([("on", Json::boolean(on))]))]))
}

///|
/// Asked and let be (`keep`, `setCongestion`, `holdIncoming`, `addAddr`): what fails is said or let go.
fn FrontEndpoint::tell(self : FrontEndpoint, op : String, args : Array[(String, Json)], failed : (Error) -> Unit) -> Unit {
  ignore(self.rt.fork(() => ignore(self.ask(op, args~)) catch { e => failed(e) }))
}

///|
pub fn FrontEndpoint::keep(self : FrontEndpoint, urls : Array[String]) -> Unit {
  self.tell("keep", [("args", jobj([("urls", Json::array(urls.map(jstr)))]))], e => (self.log)(
    "warn",
    "mesh",
    "relays not kept",
    jobj([("error", jstr(message_of(e)))]),
  ))
}

///|
pub fn FrontEndpoint::set_congestion(self : FrontEndpoint, congestion : String) -> Unit {
  self.tell("setCongestion", [("args", jobj([("congestion", jstr(congestion))]))], _ => ())
}

///|
pub fn FrontEndpoint::hold_incoming(self : FrontEndpoint, n : Int) -> Unit {
  self.tell("holdIncoming", [("args", jobj([("n", jnum(n.to_double()))]))], _ => ())
}

///|
pub fn FrontEndpoint::add_addr(self : FrontEndpoint, addr : Json) -> Unit {
  self.tell("addAddr", [("addr", addr)], _ => ())
}

///|
pub async fn FrontEndpoint::set_relay_entries(self : FrontEndpoint, entries : Json) -> Unit {
  ignore(self.ask("setRelayEntries", args=[("args", jobj([("entries", entries)]))]))
}

///|
pub async fn FrontEndpoint::network_change(self : FrontEndpoint) -> Unit {
  ignore(self.ask("networkChange"))
}

///|
/// The requests of `routes` on `alpn` go to the front's `to` instead (`route`): whether the front took it.
pub async fn FrontEndpoint::route(self : FrontEndpoint, alpn : Bytes, to : Array[String], routes : Array[String]) -> Bool {
  let routed = jobj([
    ("alpn", jstr(@hex.encode(alpn[:]))),
    ("front", Json::array(to.map(jstr))),
    ("routes", Json::array(routes.map(jstr))),
  ])
  self.routed = Some(routed)
  match routed {
    Object(r) => (async fn() -> Bool {
      ignore(self.ask("route", args=r.to_array()))
      true
    })() catch {
      _ => false
    }
    _ => false
  }
}

///|
/// The next connection taken, None once the endpoint is closed.
pub async fn FrontEndpoint::accept(self : FrontEndpoint) -> @door.Connection? {
  while true {
    let front = self.front
    let said = front.ask("accept") catch { _ => jobj([("end", Json::boolean(true))]) }
    if !(field(said, "end") is Some(True)) {
      return Some(FrontConnection::new(front, said).as_connection())
    }
    if self.closed {
      return None
    }
    match self.again {
      Some(a) => a.wait()
      None => if physical_equal(self.front, front) { front.gone_wait() }
    }
    if self.closed {
      return None
    }
  }
  None
}

///|
/// A connection made to `addr` on `alpn`; `given_up`: once it is, the front is told to give it up.
pub async fn FrontEndpoint::connect(
  self : FrontEndpoint,
  addr : Json,
  alpn : Bytes,
  additional? : Array[Bytes] = [],
  given_up? : @effect.Deferred[Unit]? = None,
) -> @door.Connection {
  let front = self.front
  let asked = Ref(0)
  if given_up is Some(g) {
    ignore(
      self.rt.fork(() => {
        g.wait()
        ignore(front.ask("giveUp", args=[("of", jnum(asked.val.to_double()))]))
      } catch {
        _ => ()
      }),
    )
  }
  let seen = front.ask(
    "connect",
    args=[
      ("addr", addr),
      ("alpn", jstr(@hex.encode(alpn[:]))),
      ("additional", Json::array(additional.map(a => jstr(@hex.encode(a[:]))))),
    ],
    id=n => asked.val = n,
  )
  FrontConnection::new(front, seen).as_connection()
}

///|
pub async fn FrontEndpoint::close(self : FrontEndpoint) -> Unit {
  self.closed = true
  (self.closing)()
  ignore(self.front.ask("close")) catch { _ => () }
  self.front.close()
}
