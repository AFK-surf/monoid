// The shell's sockets (client/shell's `tcp.*`, `unix.*`, `listen.*`) as this program uses them: the one place they are
// asked by name (scripts/mb-station.ts holds the rest to it). A connection is a `@net.Socket` (its handle closed once,
// however it ends), a listening socket a `@net.Listener` or its id with its accept; what passes a connection's bytes on
// whole without this program (`tcp.pipe`) and the few steps on a handle a caller keeps by its id are here too.
// Every socket listened on is this machine's own: a port of 127.0.0.1, a descriptor handed down, a Unix socket's path.

///|
/// Whether a failed `tcp.accept` says its listener is gone (closed here: the shell's `no handle <id>`; never one: `not a
/// listening socket`), rather than one try failed.
pub fn listener_gone(e : Error) -> Bool {
  let said = "\{e}"
  said.contains("no handle") || said.contains("not a listening socket")
}

///|
/// A connection of the shell's: its handle there (`id`, what `tcp.pipe` and a caller keeping it by its id take), who it
/// came from where it was accepted (`peer`, "" else), and the connection.
pub struct Conn {
  id : Json
  peer : String
  socket : @net.Socket
}

///|
/// A socket listened on: its handle at the shell and, for a TCP one, its port (0 for a Unix socket).
pub struct Listening {
  id : Json
  port : Int
}

///|
fn handle_of(said : Json, what : String) -> Json raise {
  guard said is { "id": id, .. } && !(id is Null) else { fail("the shell gave no \{what}") }
  id
}

///|
/// What came next on connection `id`; None at its end.
pub async fn Host::tcp_read(self : Host, id : Json) -> Bytes? {
  let (said, bytes) = self.shell("tcp.read", { "id": id })
  match (said, bytes) {
    ({ "end": True, .. }, _) | (_, None) => None
    (_, Some(b)) => Some(b)
  }
}

///|
/// `data` written on connection `id`.
pub async fn Host::tcp_write(self : Host, id : Json, data : Bytes) -> Unit {
  ignore(self.shell("tcp.write", { "id": id }, bytes=data))
}

///|
/// Connection `id`'s sending half ended (its reads go on).
pub async fn Host::tcp_end(self : Host, id : Json) -> Unit {
  ignore(self.shell("tcp.end", { "id": id }))
}

///|
/// The handle `id` let go at the shell (a connection or a listening socket): what that fails with is let go.
pub async fn Host::tcp_close(self : Host, id : Json) -> Unit noraise {
  ignore(self.shell("tcp.close", { "id": id })) catch {
    _ => ()
  }
}

///|
/// Connection `id` as a socket: closed at the shell once, as both its halves are done or it is destroyed.
pub fn Host::socket_of(self : Host, id : Json) -> @net.Socket {
  @net.Socket::new(
    read=async fn() { self.tcp_read(id) },
    write=async fn(data) { self.tcp_write(id, data) },
    end_write=async fn() { self.tcp_end(id) },
    close=async fn() { self.tcp_close(id) },
  )
}

///|
/// A connection the shell holds already, by its handle (one another part opened and handed on by its id).
pub fn Host::conn(self : Host, id : Json, peer? : String = "") -> Conn {
  { id, peer, socket: self.socket_of(id) }
}

///|
fn Host::conn_of(self : Host, said : Json) -> Conn raise {
  let id = handle_of(said, "connection")
  let peer = match said {
    { "peer": String(p), .. } => p
    _ => ""
  }
  self.conn(id, peer~)
}

///|
/// A connection to 127.0.0.1:`port`.
pub async fn Host::tcp_open(self : Host, port : Int) -> Conn {
  let (said, _) = self.shell("tcp.open", { "port": Json::number(port.to_double()) })
  self.conn_of(said)
}

///|
/// A connection to the Unix socket at `path` (a named pipe on Windows).
pub async fn Host::unix_open(self : Host, path : String) -> Conn {
  let (said, _) = self.shell("unix.open", { "path": Json::string(path) })
  self.conn_of(said)
}

///|
fn listening_of(said : Json) -> Listening raise {
  let id = handle_of(said, "listening socket")
  let port = match said {
    { "port": Number(p, ..), .. } => p.to_int()
    _ => 0
  }
  { id, port }
}

///|
/// A port of 127.0.0.1 listened on (`port` 0: any free one), its port said.
pub async fn Host::tcp_listen_local(self : Host, port : Int) -> Listening {
  let (said, _) = self.shell("tcp.listen", { "host": "127.0.0.1", "port": Json::number(port.to_double()) })
  listening_of(said)
}

///|
/// A socket handed down to this process by its descriptor (a launcher's, bound by it on 127.0.0.1), listened on.
pub async fn Host::tcp_listen_fd(self : Host, fd : Int) -> Listening {
  let (said, _) = self.shell("tcp.listen", { "fd": Json::number(fd.to_double()) })
  listening_of(said)
}

///|
/// A Unix socket listened on at `path` (one there before replaced).
pub async fn Host::unix_listen(self : Host, path : String) -> Listening {
  let (said, _) = self.shell("unix.listen", { "path": Json::string(path) })
  listening_of(said)
}

///|
/// The next connection to listening socket `listening`.
pub async fn Host::accept(self : Host, listening : Json) -> Conn {
  let (said, _) = self.shell("tcp.accept", { "id": listening })
  self.conn_of(said)
}

///|
/// Listening socket `listening` let go: what that fails with is let go.
pub async fn Host::listen_close(self : Host, listening : Json) -> Unit noraise {
  ignore(self.shell("listen.close", { "id": listening })) catch {
    _ => ()
  }
}

///|
/// Listening socket `listening` as a listener: a failed accept tried again after `retry_ms`, but one that says the
/// listener is gone (`listener_gone`).
pub fn Host::listener_of(self : Host, listening : Json, retry_ms? : Int = 100) -> @net.Listener[Conn] {
  @net.Listener::new(
    accept=async fn() { Some(self.accept(listening)) },
    close=async fn() { self.listen_close(listening) },
    is_fatal=listener_gone,
    retry_ms~,
  )
}

///|
/// Connections `a` and `b` carried into each other by the shell, both ways, each side's end passed on to the other;
/// returns once both ways ended. Both handles are the pipe's from then on: none of their bytes pass through here.
pub async fn Host::tcp_pipe(self : Host, a : Json, b : Json) -> Unit {
  ignore(self.shell("tcp.pipe", { "ids": [a, b] }))
}
